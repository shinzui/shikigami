{-# LANGUAGE DataKinds #-}

-- | Imperative delegation from one durable agent run to another.
module Shikigami.Agent.Delegate
  ( Delegated (..),
    DelegationRequest (..),
    PreparedDelegation (..),
    DelegationBatchPreflightError (..),
    DelegationBatchFailure (..),
    delegate,
    delegateAssignment,
    delegateBatch,
    preflightDelegationBatch,
    awaitDelegated,
    awaitAllDelegated,
    cancelDelegated,
    cancelSiblingsOnFailure,
    delegatedWorkflowIdV2,
  )
where

import Control.Exception (Exception, fromException)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.List (find)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, (:>))
import Effectful.Exception (catchSync, throwIO, trySync)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowJournalEvent (..), appendJournalEntry, currentWorkflow)
import Keiro.Workflow.Child (ChildHandle, WorkflowChildCancelled (..), WorkflowChildFailed (..), awaitChild, cancelChild, spawnChild)
import Kiroku.Store.Effect (Store)
import Numeric.Natural (Natural)
import Shikigami.Agent.Decl (AgentDecl (..), IdentityDecl (..), RouterPolicy (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Delegate.Context (DelegateCtx (..), DelegationError (..), assertMayDelegate, checkCycle, checkDepth)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.Run.Key (runKeyFromUUID)
import Shikigami.Agent.RunFailure (AgentRunFailure (..), agentRunFailureDetail)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (AgentWorkflowRoute), TriggerKind (TriggeredByDelegation))
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName, ingestJobStepName)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Delegation.BudgetStore
  ( BatchReservationResult (..),
    BudgetReservationError (..),
    ReservationResult (..),
    delegationBudgetIdFor,
    reserveDelegationSlot,
    reserveDelegationSlots,
    reserveEnrolledDelegationSlots,
  )
import Shikigami.Directory (DirectoryHandle)
import Shikigami.Directory qualified as Directory
import Shikigami.Execution.Request (ExecutionRequest)
import Shikigami.Prelude hiding ((.=))
import Shikigami.Router.Catalog (CandidateAvailability (..), CandidateCatalog (..), CandidateEntry (..), ExclusionReason)
import Shikigami.Router.SelectionLimit (selectionLimitNatural)

-- | A pending delegated child run. The phantom @a@ is the value expected from
-- the child's behavior output.
newtype Delegated a = Delegated (ChildHandle (Either AgentRunFailure AgentRunResult))

-- | One member of a delegation batch.  The key is stable call-site vocabulary,
-- never an ordinal derived from evaluation order.
data DelegationRequest = DelegationRequest
  { key :: !Text,
    target :: !AgentName,
    payload :: !Aeson.Value
  }
  deriving stock (Eq, Show)

-- | A request whose deterministic child identity has been computed before the
-- store is touched.
data PreparedDelegation = PreparedDelegation
  { request :: !DelegationRequest,
    childWorkflowId :: !WorkflowId
  }
  deriving stock (Eq, Show)

-- | Independently actionable reasons a complete batch cannot be reserved.
data DelegationBatchPreflightError
  = DelegationBatchRoutingPolicyMissing
  | DelegationBatchSelectionLimitExceeded !Natural !Natural
  | DelegationBatchDuplicateKey !Text
  | DelegationBatchCatalogRouterMismatch !AgentName !AgentName
  | DelegationBatchCatalogTargetMissing !AgentName
  | DelegationBatchCatalogTargetUnavailable !AgentName !ExclusionReason
  | DelegationBatchGovernanceRejected !(Maybe AgentName) !DelegationError
  | DelegationBatchSessionMissing
  deriving stock (Eq, Show)

newtype DelegationBatchFailure = DelegationBatchFailure (NonEmpty DelegationBatchPreflightError)
  deriving stock (Eq, Show)

instance Exception DelegationBatchFailure

-- | Start @childAgent@ as a child agent-run workflow without blocking.
delegate ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  [AgentDecl] ->
  DirectoryHandle ->
  AgentDecl ->
  DelegateCtx ->
  Text ->
  AgentName ->
  Aeson.Value ->
  Eff es (Delegated Aeson.Value)
delegate = delegateWith Nothing Nothing

-- | Continuing assignments pin the recorded target and carry the caller's
-- explicit model requirements through the existing child admission boundary.
delegateAssignment ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  AgentIdentity -> Maybe ExecutionRequest -> [AgentDecl] -> DirectoryHandle -> AgentDecl -> DelegateCtx -> Text -> AgentName -> Aeson.Value -> Eff es (Delegated Aeson.Value)
delegateAssignment identity request = delegateWith (Just identity) request

delegateWith ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  Maybe AgentIdentity -> Maybe ExecutionRequest -> [AgentDecl] -> DirectoryHandle -> AgentDecl -> DelegateCtx -> Text -> AgentName -> Aeson.Value -> Eff es (Delegated Aeson.Value)
delegateWith expectedIdentity executionRequest declarations directory decl ctx delegationKey childAgent payload = do
  either throwIO pure (assertMayDelegate decl childAgent)
  either throwIO pure (checkCycle ctx childAgent)
  childCtx <- either throwIO pure (checkDepth ctx)
  childDecl <-
    maybe
      (throwIO (DelegationIdentityRefused ("unknown agent declaration: " <> agentNameText childAgent)))
      pure
      (find (\AgentDecl {name = declaredName} -> declaredName == childAgent) declarations)
  childIdentity <-
    liftIO (Directory.identityAdmission directory (declaredPrincipalId childDecl) childAgent)
      >>= either (throwIO . DelegationIdentityRefused) pure
  unless (maybe True (== childIdentity) expectedIdentity) (throwIO (DelegationIdentityRefused "continuing worker identity changed"))
  let DelegateCtx
        { sessionId = currentCtxSessionId,
          lineage = currentLineage,
          delegationBudgetId = existingBudgetId,
          budgetLimit = currentBudgetLimit
        } = ctx
      DelegateCtx {depth = childDepth} = childCtx
  currentSession <-
    case currentCtxSessionId of
      Just sid -> pure sid
      Nothing -> throwIO DelegationMissingSessionId
  (_, parentWorkflowId) <- currentWorkflow
  let childUuid = delegatedUuidV2 parentWorkflowId childAgent delegationKey
      childWorkflowId = WorkflowId (UUID.toText childUuid)
      (budgetId, seed) =
        case existingBudgetId of
          Just existing -> (existing, Nothing)
          Nothing ->
            let created = delegationBudgetIdFor parentWorkflowId
             in (created, Just (parentWorkflowId, currentBudgetLimit))
  now <- liftIO getCurrentTime
  reserved <- case ctx.executionRootId of
    Nothing -> reserveDelegationSlot budgetId seed childWorkflowId now
    Just root -> fmap (fmap toSingle) (reserveEnrolledDelegationSlots root budgetId seed (childWorkflowId :| []) now)
  case reserved of
    Left (DelegationBudgetLedgerMissing missing) ->
      throwIO (DelegationBudgetUnavailable (Text.pack (show missing)))
    Left (DelegationResourceRefused refusal) -> throwIO (DelegationBudgetUnavailable (Text.pack (show refusal)))
    Right DelegationSlotsExhausted -> throwIO DelegationBudgetExhausted
    Right DelegationSlotReserved -> pure ()
    Right DelegationSlotAlreadyReserved -> pure ()
  let childJob =
        RunJob
          { agentName = childAgent,
            identity = childIdentity,
            triggerKind = TriggeredByDelegation,
            routeKind = AgentWorkflowRoute,
            occurredAt = now,
            triggerPayload = payload,
            idempotencyKey = runKeyFromUUID childUuid,
            parentSessionId = Just currentSession,
            parentRunWorkflowId = Just parentWorkflowId,
            delegationDepth = Just childDepth,
            lineage = currentLineage <> [childAgent],
            delegationBudgetId = Just budgetId,
            executionRootId = ctx.executionRootId,
            executionRequest,
            executionPermissions = ctx.executionPermissions
          }
  handle <-
    spawnChild
      agentRunWorkflowName
      childWorkflowId
      (pure (Left (PermanentAgentRunFailure "delegated child is driven from the agent-run registry")))
  appendJournalEntry
    agentRunWorkflowName
    childWorkflowId
    StepRecorded
      { stepName = unStepName ingestJobStepName,
        result = Aeson.toJSON childJob,
        recordedAt = now
      }
  pure (Delegated handle)
  where
    toSingle DelegationBatchExhausted = DelegationSlotsExhausted
    toSingle (DelegationBatchReserved 1 _) = DelegationSlotReserved
    toSingle (DelegationBatchReserved _ _) = DelegationSlotAlreadyReserved

-- | Validate and identify every child without touching durable state.
--
-- The recorded catalog is checked again here even though route-decision
-- validation already established availability.  This keeps the complete
-- all-targets-before-spawn contract local to the delegation boundary.
preflightDelegationBatch ::
  AgentDecl ->
  DelegateCtx ->
  CandidateCatalog ->
  WorkflowId ->
  NonEmpty DelegationRequest ->
  Either (NonEmpty DelegationBatchPreflightError) (NonEmpty PreparedDelegation)
preflightDelegationBatch decl@AgentDecl {name = delegatingAgent, routing} ctx@DelegateCtx {sessionId = currentSessionId} CandidateCatalog {router, candidates = catalogCandidates} parentWorkflowId requests =
  case NonEmpty.nonEmpty errors of
    Just failures -> Left failures
    Nothing -> Right (prepare <$> requests)
  where
    requestList = NonEmpty.toList requests
    errors =
      [DelegationBatchRoutingPolicyMissing | isNothing routing]
        <> selectionLimitErrors
        <> (DelegationBatchDuplicateKey <$> duplicateKeys)
        <> [DelegationBatchCatalogRouterMismatch delegatingAgent router | router /= delegatingAgent]
        <> [DelegationBatchSessionMissing | isNothing currentSessionId]
        <> depthErrors
        <> concatMap requestErrors requestList

    selectionLimitErrors = case routing of
      Nothing -> []
      Just RouterPolicy {maxSelections} ->
        [ DelegationBatchSelectionLimitExceeded (fromIntegral (length requestList)) (selectionLimitNatural maxSelections)
        | fromIntegral (length requestList) > selectionLimitNatural maxSelections
        ]

    duplicateKeys = duplicatesInOrder [key | DelegationRequest {key} <- requestList]

    depthErrors = case checkDepth ctx of
      Left failure -> [DelegationBatchGovernanceRejected Nothing failure]
      Right _ -> []

    candidatesByName =
      Map.fromList [(candidateName, candidate) | candidate@CandidateEntry {name = candidateName} <- catalogCandidates]

    requestErrors DelegationRequest {target} =
      governanceError target (assertMayDelegate decl target)
        <> governanceError target (checkCycle ctx target)
        <> catalogErrors target

    governanceError targetName = \case
      Left failure -> [DelegationBatchGovernanceRejected (Just targetName) failure]
      Right () -> []

    catalogErrors targetName = case Map.lookup targetName candidatesByName of
      Nothing -> [DelegationBatchCatalogTargetMissing targetName]
      Just CandidateEntry {availability = Available} -> []
      Just CandidateEntry {availability = Excluded reason} -> [DelegationBatchCatalogTargetUnavailable targetName reason]

    prepare request@DelegationRequest {key, target} =
      PreparedDelegation
        { request,
          childWorkflowId = delegatedWorkflowIdV2 parentWorkflowId target key
        }

-- | Reserve the complete routed batch before invoking the existing governed
-- single-child spawn boundary for any member.
delegateBatch ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  [AgentDecl] ->
  DirectoryHandle ->
  AgentDecl ->
  DelegateCtx ->
  CandidateCatalog ->
  NonEmpty DelegationRequest ->
  Eff es (NonEmpty (Delegated Aeson.Value))
delegateBatch declarations directory decl ctx catalog requests = do
  (_, parentWorkflowId) <- currentWorkflow
  prepared <-
    either
      (throwIO . DelegationBatchFailure)
      pure
      (preflightDelegationBatch decl ctx catalog parentWorkflowId requests)
  let DelegateCtx
        { delegationBudgetId = existingBudgetId,
          budgetLimit = currentBudgetLimit
        } = ctx
      (budgetId, seed) =
        case existingBudgetId of
          Just existing -> (existing, Nothing)
          Nothing ->
            let created = delegationBudgetIdFor parentWorkflowId
             in (created, Just (parentWorkflowId, currentBudgetLimit))
  now <- liftIO getCurrentTime
  reserved <- case ctx.executionRootId of
    Nothing -> reserveDelegationSlots budgetId seed ((.childWorkflowId) <$> prepared) now
    Just root -> reserveEnrolledDelegationSlots root budgetId seed ((.childWorkflowId) <$> prepared) now
  case reserved of
    Left (DelegationBudgetLedgerMissing missing) ->
      throwIO (DelegationBudgetUnavailable (Text.pack (show missing)))
    Left (DelegationResourceRefused refusal) -> throwIO (DelegationBudgetUnavailable (Text.pack (show refusal)))
    Right DelegationBatchExhausted -> throwIO DelegationBudgetExhausted
    Right (DelegationBatchReserved _ _) -> pure ()
  traverse spawnPrepared prepared
  where
    spawnPrepared PreparedDelegation {request = DelegationRequest {key, target, payload}} =
      delegate declarations directory decl ctx key target payload

declaredPrincipalId :: AgentDecl -> Maybe (DeclarationCoordinate "principal")
declaredPrincipalId AgentDecl {identity} = (.principal) <$> identity

-- | Suspend until the delegated child completes and decode its behavior output.
awaitDelegated ::
  (Workflow :> es, Store :> es, IOE :> es, Aeson.FromJSON a) =>
  Delegated a ->
  Eff es a
awaitDelegated (Delegated handle) =
  awaitSucceededChild `catchSync` mapChildException
  where
    awaitSucceededChild = do
      awaitChild handle >>= \case
        Left failure -> throwIO (DelegatedChildFailed (agentRunFailureDetail failure))
        Right AgentRunResult {behaviorOutput} ->
          case parseEither Aeson.parseJSON behaviorOutput of
            Right decoded -> pure decoded
            Left err -> throwIO (DelegatedResultDecodeFailed (Text.pack err))

    mapChildException err
      | Just (WorkflowChildCancelled _ _) <- fromException err =
          throwIO DelegatedChildCancelled
      | Just (WorkflowChildFailed _ _ reason) <- fromException err =
          throwIO (DelegatedChildFailed reason)
      | otherwise = throwIO err

-- | Await every child without allowing one failed child to discard its
-- siblings' results. Infrastructure exceptions still escape; only the typed
-- delegation outcomes are collected.
awaitAllDelegated ::
  (Workflow :> es, Store :> es, IOE :> es, Aeson.FromJSON a) =>
  [Delegated a] ->
  Eff es [Either Text a]
awaitAllDelegated = traverse awaitDelegatedEither

-- | Cancel one pending child. 'False' means it had already reached an outcome
-- (or was already cancelled), never that a cancellation was fabricated.
cancelDelegated ::
  (Store :> es, IOE :> es) =>
  Delegated a ->
  Eff es Bool
cancelDelegated (Delegated handle) = cancelChild handle

-- | Await in declaration order and, after the first observed failure, cancel
-- every remaining child that is still running. A child that completed before
-- cancellation is awaited for its truthful stored result.
cancelSiblingsOnFailure ::
  (Workflow :> es, Store :> es, IOE :> es, Aeson.FromJSON a) =>
  [Delegated a] ->
  Eff es [Either Text a]
cancelSiblingsOnFailure = \case
  [] -> pure []
  child : siblings -> do
    result <- awaitDelegatedEither child
    case result of
      Right value -> (Right value :) <$> cancelSiblingsOnFailure siblings
      Left failure -> do
        siblingResults <- traverse cancelOrAwait siblings
        pure (Left failure : siblingResults)
  where
    cancelOrAwait sibling = do
      cancelled <- cancelDelegated sibling
      if cancelled
        then pure (Left "delegated child cancelled after sibling failure")
        else awaitDelegatedEither sibling

awaitDelegatedEither ::
  (Workflow :> es, Store :> es, IOE :> es, Aeson.FromJSON a) =>
  Delegated a ->
  Eff es (Either Text a)
awaitDelegatedEither delegated =
  trySync (awaitDelegated delegated) >>= \case
    Right value -> pure (Right value)
    Left err ->
      case fromException @DelegationError err of
        Just failure -> pure (Left (Text.pack (show failure)))
        Nothing -> throwIO err

delegatedWorkflowIdV2 :: WorkflowId -> AgentName -> Text -> WorkflowId
delegatedWorkflowIdV2 parent child key = WorkflowId (UUID.toText (delegatedUuidV2 parent child key))

delegatedUuidV2 :: WorkflowId -> AgentName -> Text -> UUID.UUID
delegatedUuidV2 (WorkflowId parentWorkflowId) childAgent delegationKey =
  UUID.V5.generateNamed UUID.V5.namespaceURL $
    nameBytes $
      versionedDigest
        "shikigami.delegation-child/2"
        (Aeson.object ["parent" .= parentWorkflowId, "agent" .= childAgent, "key" .= delegationKey])

duplicatesInOrder :: (Ord a) => [a] -> [a]
duplicatesInOrder = go Set.empty Set.empty
  where
    go _ _ [] = []
    go seen reported (value : rest)
      | value `Set.member` reported = go seen reported rest
      | value `Set.member` seen = value : go seen (Set.insert value reported) rest
      | otherwise = go (Set.insert value seen) reported rest
