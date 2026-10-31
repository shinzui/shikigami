{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}

-- | Checked lifecycle events and protected replay data commit together. The
-- generated stream is the lifecycle authority; these rows retain its rich data.
module Shikigami.Execution.Store
  ( ReplayAccess,
    ExecutionBinding (..),
    ExecutionEffects,
    ExecutionReadEffects,
    admitExecution,
    authorizeReplay,
    loadExecution,
    inspectExecution,
    inspectExecutionPage,
    inspectOperation,
    readReplayPayload,
    acceptOperation,
    submitExecutionAttemptWith,
    recoverExecutionAttemptWith,
    toolAttemptRequest,
    inspectExecutionAttempt,
    publishExecutionWake,
    refreshExecutionWake,
    refreshExecutionControlWake,
    stopExecution,
    inspectOperationAttempts,
    loadModelReplayWindow,
    refuseUndispatchedExecutionAttempt,
    claimExecutionAttempt,
    startExecutionAttempt,
    checkStartedExecutionAttempt,
    abandonExecutionAttempt,
    completeExecutionAttempt,
    markExecutionAttemptUncertain,
    markExpiredExecutionAttemptUncertain,
    recordLateExecutionReceipt,
    recordIndependentToolReceipt,
    reconcileExecutionAttempt,
    reconcileExecutionControlAttempt,
    parkOperationPermission,
    resolveOperationPermission,
    resolveOperationControlPermission,
    recordOutcomeAndAdvance,
    recordOutcomeAndAdvanceWith,
    finishExecution,
    payloadReference,
    outcomeReference,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip5)
import Control.Exception (Exception, fromException, throw)
import Control.Monad (foldM, join)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Lazy
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, tryError)
import Effectful.Exception (catchSync, throwIO)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Keiro.Command (CommandError (CommandRejected, RetryExhausted, StoreFailed), DomainCommandHandler (..), DomainCommandOutcome (..), DomainDecision (..), SilentDomainDecision (SilentRejected))
import Keiro.Projection (DomainProjectionCommandOutcome (..), GuardedCatalogOutcome (..), runDomainCommandWithCatalogProjectionsGuarded)
import Keiro.ReadModel (runQuery)
import Keiro.Stream qualified as Stream
import Keiro.Workflow (JournalAppendOutcome (..), WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), awakeableStepPrefix, currentGeneration, prepareJournalAppend)
import Keiro.Workflow.Awakeable (awakeableIdText, awakeableIdToUuid)
import Keiro.Workflow.Awakeable.Schema (AwakeableRow (..), AwakeableStatus (Completed), completeAwakeableTx, lookupAwakeable, lookupAwakeableStatusTx)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Approval (ApprovalDecision (..), ReviewRequestId, reviewRequestIdFor)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.App (CommandEffects, commandOptions)
import Shikigami.Decision.Contract (ModelDescriptor, versionedDigest)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Catalog (withLiveExecution)
import Shikigami.Execution.Identity (AttemptId (..), ExecutionRootId, OperationId (..))
import Shikigami.Execution.Policy (ContextView (..), ModelOperationInput (..), validateTerminalOutput, validateToolInvocation)
import Shikigami.Execution.Policy.Types (HarnessPolicy (..), RecoveryClass (..), ToolInvoiceCost (..))
import Shikigami.Execution.Quantity (oneAmount, zeroAmount)
import Shikigami.Execution.Resources (Admission (..))
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.SelectionStore qualified as Calls
import Shikigami.Execution.Transcript
import Shikigami.ExecutionLifecycle.Generated.Domain qualified as Generated
import Shikigami.ExecutionLifecycle.Generated.EventStream (executionLifecycleCategory, executionLifecycleEventStream)
import Shikigami.ExecutionLookup.Generated.ReadModel (executionLookupReadModel)
import Shikigami.Prelude hiding ((.=))
import Shikigami.StateRevision

type ExecutionReadEffects es = (IOE :> es, Store :> es, Error StoreError :> es)

type ExecutionEffects es = (ExecutionReadEffects es, KirokuStoreResource :> es, CommandEffects es)

data ExecutionBinding = ExecutionBinding
  { identity :: !AgentIdentity,
    rootId :: !(Maybe ExecutionRootId),
    assignmentId :: !Text,
    descriptor :: !ModelDescriptor,
    snapshotDigest :: !Text,
    policyDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- Constructor is private. The permit is process-local, identity/execution-bound
-- and short-lived; ordinary inspection never obtains one or reads payloads.
data ReplayAccess = ReplayAccess !ExecutionId !AgentIdentity !UTCTime

data PayloadEnvelope = PayloadEnvelope
  { format :: !Int,
    kind :: !Text,
    content :: !Aeson.Value
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

newtype ExecutionAbort = ExecutionAbort ExecutionError
  deriving stock (Show)

instance Exception ExecutionAbort

data PersistenceFailure = EventRejected | CheckFailed !ExecutionError

abort :: ExecutionError -> Transaction a
abort = throw . ExecutionAbort

require :: Either ExecutionError a -> Transaction a
require = either abort pure

payloadReference :: Aeson.Value -> Either ExecutionError PayloadRef
payloadReference body = do
  let bytes = toInteger (Lazy.length (Aeson.encode body))
      digest = versionedDigest "shikigami.execution-payload/1" body
  when (bytes > 1048576) (Left PayloadTooLarge)
  pure (PayloadRef ("payload:" <> digest) digest bytes)

envelope :: (ToJSON a) => Text -> a -> Aeson.Value
envelope kind value = toJSON (PayloadEnvelope 1 kind (toJSON value))

outcomeReference :: OperationOutcome -> Either ExecutionError PayloadRef
outcomeReference = payloadReference . envelope "operation-outcome"

writePayload :: ExecutionId -> Aeson.Value -> Transaction PayloadRef
writePayload execution body = do
  ref <- require (payloadReference body)
  Tx.statement (execution.value, ref.payloadId, ref.digest, fromInteger ref.bytes, body) insertPayload
  stored <- Tx.statement (execution.value, ref.payloadId) selectPayload
  unless (stored == Just (ref.digest, ref.bytes, body)) (abort CorruptReplay)
  pure ref

admitExecution :: (ExecutionEffects es) => ExecutionSnapshot -> Eff es (Either ExecutionError Admission)
admitExecution snapshot
  | Left err <- validateSnapshot snapshot = pure (Left err)
  | otherwise = catchExecutionWith id $ case payloadReference body of
      Left refusal -> pure (Left refusal)
      Right ref -> do
        let execution = snapshot.executionId
            binding = ExecutionBinding snapshot.identity snapshot.selection.rootId snapshot.selection.assignmentId snapshot.selection.descriptor ref.digest (versionedDigest "shikigami.harness-policy/1" (toJSON snapshot.policy))
            state = ExecutionState 1 execution initialRevision Active initialRevision NeedModel ref Nothing Nothing 0 0 Nothing Nothing 0
        result <- persistChecked
          execution
          (Generated.AdmitExecution (Generated.AdmitExecutionData execution ref.digest))
          ( do
              checkedLockRoot binding.rootId
              checkedAdmissionRoot binding.rootId
              existing <- checkedStatement execution.value lockExecution
              when (isJust existing) (throwE ExecutionIdentityConflict)
              pure ()
          )
          \() -> do
            Tx.statement (execution.value, state, binding) insertExecution
            actual <- writePayload execution body
            unless (actual == ref) (abort CorruptReplay)
        case result of
          Right () -> pure (Right Accepted)
          Left EventRejected -> do
            existing <- readMetadata (Tx.statement execution.value selectExecution)
            pure case existing of
              Just (previous, previousBinding) | previous.snapshot == ref && previousBinding == binding -> Right AlreadyAccepted
              _ -> Left ExecutionIdentityConflict
          Left (CheckFailed err) -> pure (Left err)
  where
    body = envelope "snapshot" snapshot

authorizeReplay :: (ExecutionEffects es) => ExecutionId -> AgentIdentity -> IO (Either Text ()) -> Eff es (Either ExecutionError ReplayAccess)
authorizeReplay execution identity authority = catchExecutionWith id do
  current <- liftIO authority
  now <- liftIO getCurrentTime
  existing <- readMetadata (Tx.statement execution.value selectExecution)
  pure case (current, existing) of
    (Right (), Just (_, binding)) | identity == binding.identity -> Right (ReplayAccess execution identity (addUTCTime 60 now))
    _ -> Left ReplayReadRefused

checkAccess :: ReplayAccess -> ExecutionBinding -> Transaction ExecutionId
checkAccess (ReplayAccess execution identity expires) binding = do
  now <- Tx.statement () currentTime
  unless (identity == binding.identity && now < expires) (abort ReplayReadRefused)
  pure execution

-- An already accepted operation may record its facts after revocation or a
-- read permit's expiry. This grants no replay read or fresh dispatch authority.

loadExecution :: (ExecutionEffects es) => ReplayAccess -> Eff es (Either ExecutionError (ExecutionSnapshot, ExecutionState))
loadExecution access@(ReplayAccess execution _ _) = protected do
  (state, binding) <- getExecution execution
  _ <- checkAccess access binding
  snapshot <- readPayload access binding "snapshot" state.snapshot
  unless (state.snapshot.digest == binding.snapshotDigest && snapshot.executionId == execution && snapshot.selection.assignmentId == binding.assignmentId && snapshot.identity == binding.identity && snapshot.selection.rootId == binding.rootId && snapshot.selection.descriptor == binding.descriptor && versionedDigest "shikigami.harness-policy/1" (toJSON snapshot.policy) == binding.policyDigest) (abort CorruptReplay)
  pure (snapshot, state)

-- Bounded metadata only. Protected body columns are never selected here.
inspectExecution :: (ExecutionReadEffects es) => ExecutionId -> Eff es (Either ExecutionError (Maybe (ExecutionState, ExecutionBinding, [Operation])))
inspectExecution execution = protected do
  existing <- Tx.statement execution.value selectExecution
  traverse (\(state, binding) -> (state,binding,) <$> Tx.statement execution.value listOperations) existing

-- Operational JSON is assembled from typed metadata only. No payload body or
-- wake is selected; active work stays visible even outside the history page.
inspectExecutionPage :: (ExecutionReadEffects es) => ExecutionId -> Integer -> Int -> Eff es (Either ExecutionError (Maybe Aeson.Value))
inspectExecutionPage execution after limit
  | after < -1 || after > 10000 || limit < 1 || limit > 20 = pure (Left (ExecutionPolicyRefused "inspection page requires after -1..10000 and limit 1..20"))
  | otherwise = protected do
      stored <- Tx.statement execution.value selectExecution
      forM stored \(state, binding) -> do
        selected <- Tx.statement (execution.value, fromInteger after, fromIntegral (limit + 1)) operationPage
        operations <- traverse operationView (take limit selected)
        active <- traverse (\key -> Tx.statement (operationKey key) selectOperation >>= traverse operationView) state.activeOperation
        resources <- traverse (\root -> Roots.inspectRootTx root >>= either (abort . ResourceAdmissionRefused . Text.pack . show) pure) binding.rootId
        pure
          ( Aeson.object
              [ "schema" .= ("shikigami.execution-inspection/1" :: Text),
                "executionId" .= execution,
                "phase" .= state.phase,
                "revision" .= state.revision,
                "cursor" .= state.cursor,
                "next" .= state.next,
                "modelTurns" .= state.modelTurns,
                "repairs" .= state.repairs,
                "pendingReceipts" .= state.pendingReceipts,
                "result" .= state.result,
                "failure" .= state.failure,
                "snapshot" .= state.snapshot,
                "binding" .= binding,
                "resources" .= resources,
                "activeOperation" .= join active,
                "operations" .= operations,
                "nextAfter" .= (if length selected > limit then (.position) <$> listToMaybe (reverse (take limit selected)) else Nothing),
                "limit" .= limit
              ]
          )
  where
    operationView :: Operation -> Transaction Aeson.Value
    operationView operation = do
      (total, unknown) <- Tx.statement (operationKey operation.specification.operationId) inspectionAttemptCounts
      attempts <- Tx.statement (operationKey operation.specification.operationId) inspectionAttempts
      let safeAttempt attempt = case toJSON attempt of
            Aeson.Object fields -> Aeson.Object (KeyMap.delete "wake" fields)
            value -> value
      pure (Aeson.object ["operation" .= operation, "attemptCount" .= total, "unresolvedAttempts" .= unknown, "attempts" .= map safeAttempt attempts, "attemptsTruncated" .= (total > fromIntegral (length attempts))])

inspectOperation :: (ExecutionReadEffects es) => OperationId -> Eff es (Either ExecutionError (Maybe Operation))
inspectOperation operation = protected (Tx.statement (operationKey operation) selectOperation)

findOperation :: (ExecutionReadEffects es) => OperationId -> Eff es (Maybe Operation)
findOperation operation = readMetadata (Tx.statement (operationKey operation) selectOperation)

readReplayPayload :: forall a es. (ExecutionReadEffects es, FromJSON a, ToJSON a) => ReplayAccess -> Text -> PayloadRef -> Eff es (Either ExecutionError a)
readReplayPayload access@(ReplayAccess execution _ _) kind ref = protected do
  (_, binding) <- getExecution execution
  readPayload access binding kind ref

readPayload :: (FromJSON a) => ReplayAccess -> ExecutionBinding -> Text -> PayloadRef -> Transaction a
readPayload access binding kind ref = do
  execution <- checkAccess access binding
  stored <- Tx.statement (execution.value, ref.payloadId) selectPayload
  case stored of
    Just (digest, bytes, body) | digest == ref.digest && bytes == ref.bytes -> do
      actual <- require (payloadReference body)
      unless (actual == ref) (abort CorruptReplay)
      PayloadEnvelope format actualKind content <- decode body
      unless (format == 1 && actualKind == kind) (abort UnsupportedReplay)
      decode content
    _ -> abort CorruptReplay

acceptOperation :: (ExecutionEffects es) => ReplayAccess -> StateRevision "execution" -> OperationSpec -> Aeson.Value -> Eff es (Either ExecutionError (Admission, Operation))
acceptOperation access@(ReplayAccess execution _ _) expected specification input = catchExecutionWith id do
  stored <- readMetadata (Tx.statement execution.value selectExecution)
  case stored of
    Nothing -> pure (Left ExecutionMissing)
    Just (state, binding) -> case payloadReference body of
      Left err -> pure (Left err)
      Right ref -> do
        let fingerprint = versionedDigest "shikigami.execution-operation-request/1" (toJSON (specification, ref, binding.snapshotDigest))
            operation = Operation 1 execution state.cursor specification fingerprint ref Nothing Nothing False Nothing
        old <- findOperation specification.operationId
        case old of
          Just previous -> pure (duplicate fingerprint previous)
          Nothing -> do
            result <- persistChecked
              execution
              (advance execution expected)
              ( do
                  checkedLockRoot binding.rootId
                  (current, actualBinding) <- checkedExecution execution
                  _ <- checkedAccess access actualBinding
                  checkedRevision expected current
                  unless (current.phase == Active && isNothing current.activeOperation && revisionNumber current.cursor < 10000) (throwE ExecutionNotActive)
                  unless (specification.operationId == operationIdFor execution current.cursor) (throwE OperationConflict)
                  except (validateOperation specification)
                  unless (specification.policyDigest == actualBinding.policyDigest) (throwE OperationConflict)
                  snapshot <- checkedPayload access actualBinding "snapshot" current.snapshot
                  let modelOperation = specification.kind `elem` [ModelTurn, ModelSummary, ModelRepair]
                  when (modelOperation && current.modelTurns >= (snapshot :: ExecutionSnapshot).policy.maxModelTurns) (throwE (ResourceAdmissionRefused "model-turn limit exhausted"))
                  when (specification.kind == ModelRepair && current.repairs >= snapshot.policy.outputRepairs) (throwE ExecutionOutputInvalid)
                  when (specification.kind == ModelSummary && isNothing snapshot.policy.summaryTokens) (throwE (ExecutionPolicyRefused "model summaries are disabled"))
                  checkedOperationInput access actualBinding current snapshot specification input
                  checkedAdmissionRoot actualBinding.rootId
                  pure (current, modelOperation)
              )
              \(current, modelOperation) -> do
                actual <- writePayload execution body
                unless (actual == ref) (abort CorruptReplay)
                Tx.statement (operationKey specification.operationId, execution.value, fromInteger (revisionNumber current.cursor), operation) insertOperation
                saveExecution (current & #revision .~ (advanceRevision expected) & #activeOperation .~ Just specification.operationId & #modelTurns .~ (current.modelTurns + if modelOperation then 1 else 0) & #repairs .~ (current.repairs + if specification.kind == ModelRepair then 1 else 0))
            case result of
              Right () -> pure (Right (Accepted, operation))
              Left EventRejected -> do
                replay <- findOperation specification.operationId
                pure (maybe (Left ExecutionRevisionConflict) (duplicate fingerprint) replay)
              Left (CheckFailed err) -> pure (Left err)
  where
    body = envelope "operation-input" input
    duplicate fingerprint operation
      | operation.executionId == execution && operation.fingerprint == fingerprint = Right (AlreadyAccepted, operation)
      | otherwise = Left OperationConflict

-- Park the accepted tool itself. No new logical/model turn is allocated.
-- The review identity is independent of driver generation and wake tokens.
parkOperationPermission :: (ExecutionEffects es) => ReplayAccess -> StateRevision "execution" -> OperationId -> Eff es (Either ExecutionError PermissionBinding)
parkOperationPermission access@(ReplayAccess execution _ _) expected operationId = catchExecutionWith id do
  operation <- findOperation operationId >>= maybe (throwIO (ExecutionAbort OperationMissing)) pure
  if operation.executionId /= execution
    then pure (Left OperationConflict)
    else case operation.permission of
      Just binding -> pure (Right binding)
      Nothing -> do
        (_, binding) <- readMetadata (getExecution execution)
        result <- persistChecked
          execution
          (Generated.ParkExecution (Generated.ParkExecutionData execution (fromInteger (revisionNumber expected)) (fromInteger (revisionNumber (advanceRevision expected)))))
          ( do
              checkedLockRoot binding.rootId
              checkedAdmissionRoot binding.rootId
              (state, actualBinding) <- checkedExecution execution
              _ <- checkedAccess access actualBinding
              checkedRevision expected state
              unless (state.phase == Active && state.activeOperation == Just operationId) (throwE OperationConflict)
              current <- checkedStatement (operationKey operationId) lockOperation >>= maybe (throwE OperationMissing) pure
              unless (current == operation && isNothing current.outcome) (throwE OperationConflict)
              snapshot <- checkedPayload access actualBinding "snapshot" state.snapshot
              unless (operation.specification.kind == ToolOperation && operation.specification.name `elem` (snapshot :: ExecutionSnapshot).policy.humanTools && operation.specification.name `notElem` snapshot.policy.deniedTools) (throwE (ExecutionPolicyRefused "tool permission is outside the pinned policy"))
              now <- checkedStatement () currentTime
              let review = reviewRequestIdFor (WorkflowName "shikigami.execution") (executionWorkflowId execution) 0 (operationKey operationId <> ":" <> operation.fingerprint)
                  permission = PermissionBinding review operation.fingerprint operation.specification.scopeDigest operation.specification.policyDigest (addUTCTime (fromIntegral snapshot.policy.permissionSeconds) now) Nothing
              pure (state, current, permission)
          )
          \(state, current, permission) -> do
            Tx.statement (operationKey operationId, current & #permission .~ Just permission) updateOperation
            saveExecution (state & #revision .~ (advanceRevision expected) & #phase .~ Parked)
        case result of
          Left (CheckFailed err) -> pure (Left err)
          _ -> do
            stored <- findOperation operationId
            pure (maybe (Left ExecutionRevisionConflict) Right (stored >>= (.permission)))

-- Only the approval child result enters here; the opaque token is resolved by
-- the existing approval library. A review id alone never supplies a decision.
resolveOperationPermission :: (ExecutionEffects es) => ReplayAccess -> StateRevision "execution" -> OperationId -> ReviewRequestId -> ApprovalDecision -> Eff es (Either ExecutionError Admission)
resolveOperationPermission access@(ReplayAccess execution _ _) expected operationId review decision = catchExecutionWith id do
  operation <- findOperation operationId >>= maybe (throwIO (ExecutionAbort OperationMissing)) pure
  permission <- maybe (throwIO (ExecutionAbort OperationConflict)) pure operation.permission
  unless (operation.executionId == execution && permission.reviewRequestId == review && permission.fingerprint == operation.fingerprint && permission.scopeDigest == operation.specification.scopeDigest && permission.policyDigest == operation.specification.policyDigest) (throwIO (ExecutionAbort OperationConflict))
  let resolution = case decision of Approved _ -> PermissionApproved; Rejected _ -> PermissionDenied; TimedOut -> PermissionExpired
  case permission.resolution of
    Just previous -> pure (if previous == resolution then Right AlreadyAccepted else Left OperationConflict)
    Nothing -> do
      (_, binding) <- readMetadata (getExecution execution)
      result <- persistChecked
        execution
        (Generated.ResumeExecution (Generated.ResumeExecutionData execution (fromInteger (revisionNumber expected)) (fromInteger (revisionNumber (advanceRevision expected)))))
        ( do
            checkedLockRoot binding.rootId
            (state, actualBinding) <- checkedExecution execution
            _ <- checkedAccess access actualBinding
            checkedRevision expected state
            unless (state.phase == Parked && state.activeOperation == Just operationId) (throwE OperationConflict)
            current <- checkedStatement (operationKey operationId) lockOperation >>= maybe (throwE OperationMissing) pure
            unless (current == operation && isNothing current.outcome) (throwE OperationConflict)
            now <- checkedStatement () currentTime
            when (now >= permission.expiresAt && resolution /= PermissionExpired) (throwE (ExecutionPolicyRefused "tool permission expired"))
            when (now < permission.expiresAt && resolution == PermissionExpired) (throwE (ExecutionPolicyRefused "tool permission deadline has not elapsed"))
            pure (state, current)
        )
        \(state, current) -> do
          Tx.statement (operationKey operationId, current & #permission .~ Just (permission & #resolution .~ Just resolution)) updateOperation
          saveExecution (state & #revision .~ (advanceRevision expected) & #phase .~ Active)
      case result of
        Right () -> pure (Right Accepted)
        Left (CheckFailed err) -> pure (Left err)
        Left EventRejected -> do
          stored <- findOperation operationId
          pure (if (stored >>= (.permission) >>= (.resolution)) == Just resolution then Right AlreadyAccepted else Left OperationConflict)

-- A child decision records facts after waiting without reusing an expired read
-- permit. It grants neither replay reads nor a new effect authorization.
resolveOperationControlPermission :: (ExecutionEffects es) => AgentIdentity -> ExecutionId -> StateRevision "execution" -> OperationId -> ReviewRequestId -> ApprovalDecision -> Eff es (Either ExecutionError Admission)
resolveOperationControlPermission identity execution expected operation review decision = catchExecutionWith id do
  (_, binding) <- readMetadata (getExecution execution)
  unless (identity == binding.identity) (throwIO (ExecutionAbort ExecutionIdentityConflict))
  now <- liftIO getCurrentTime
  resolveOperationPermission (ReplayAccess execution identity (addUTCTime 60 now)) expected operation review decision

checkedOperationInput :: ReplayAccess -> ExecutionBinding -> ExecutionState -> ExecutionSnapshot -> OperationSpec -> Aeson.Value -> ExecutionCheck ()
checkedOperationInput access binding state snapshot specification input = case specification.kind of
  ToolOperation -> do
    tool <- checkedDecode @ToolOperationInput input
    unless (state.next == NeedTool tool.response tool.position && specification.responsePosition == Just tool.position && specification.name == tool.invocation.name && specification.name == tool.binding.name && specification.recovery == tool.binding.recovery && specification.scopeDigest == toolScopeDigest tool.binding) (throwE OperationConflict)
    outcome <- checkedPayload access binding "operation-outcome" tool.response
    case outcome of
      ModelReturned assistant _ -> do
        _ <- except (validateToolInvocation snapshot.policy snapshot.toolBindings snapshot.toolBindings assistant tool.position)
        unless (take 1 (drop tool.position (toolInvocations assistant)) == [tool.invocation] && tool.binding `elem` snapshot.toolBindings) (throwE OperationConflict)
      _ -> throwE OperationConflict
  ModelRepair -> case state.next of
    NeedValidation response -> do
      outcome <- checkedPayload access binding "operation-outcome" response
      case outcome of
        ModelReturned assistant _ -> case validateTerminalOutput snapshot.policy assistant of
          Left ExecutionOutputInvalid -> pure ()
          _ -> throwE OperationConflict
        _ -> throwE OperationConflict
    _ -> throwE OperationConflict
  _ -> unless (state.next == NeedModel) (throwE OperationConflict)

-- Reservation, prepared attempt and queue acceptance share this transaction.
-- The callback is the existing queue owner's transaction, not external IO.
submitExecutionAttemptWith :: (ExecutionEffects es) => ReplayAccess -> StateRevision "execution" -> Attempt.AttemptSubmission -> (Attempt.JobReference -> Transaction ()) -> Eff es (Either ExecutionError (Admission, Attempt.ExecutionAttempt))
submitExecutionAttemptWith = submitAttempt Nothing

-- Retirement of the unknown actual attempt, reservation of its replacement,
-- queue acceptance and reopening logical progress commit together. A refusal
-- leaves the original unresolved work and accounting untouched.
recoverExecutionAttemptWith :: (ExecutionEffects es) => ReplayAccess -> StateRevision "execution" -> AttemptId -> Attempt.AttemptSubmission -> (Attempt.JobReference -> Transaction ()) -> Eff es (Either ExecutionError (Admission, Attempt.ExecutionAttempt))
recoverExecutionAttemptWith access expected previous = submitAttempt (Just previous) access expected

submitAttempt :: (ExecutionEffects es) => Maybe AttemptId -> ReplayAccess -> StateRevision "execution" -> Attempt.AttemptSubmission -> (Attempt.JobReference -> Transaction ()) -> Eff es (Either ExecutionError (Admission, Attempt.ExecutionAttempt))
submitAttempt retired access@(ReplayAccess execution _ _) expected submission enqueue = catchExecutionWith id do
  when (retired == Just submission.request.attemptId) (throwIO (ExecutionAbort AttemptConflict))
  (_, binding) <- readMetadata (getExecution execution)
  operation <- findOperation submission.request.operationId >>= maybe (throwIO (ExecutionAbort OperationMissing)) pure
  wakeRef <- either (throwIO . ExecutionAbort) pure (payloadReference wakeBody)
  let fingerprint = versionedDigest "shikigami.execution-attempt/1" (toJSON (operation.fingerprint, submission.request, submission.modelCall, wakeRef))
      reference = Attempt.JobReference 1 execution submission.request.operationId submission.request.attemptId
      duplicate existing = if existing.executionId == execution && existing.operationId == submission.request.operationId && existing.request == submission.request && existing.fingerprint == fingerprint then Right (AlreadyAccepted, existing) else Left AttemptConflict
  old <- readMetadata (Tx.statement (attemptKey submission.request.attemptId) selectExecutionAttempt)
  case old of
    Just existing -> pure (duplicate existing)
    Nothing -> do
      result <- persistChecked
        execution
        (if isJust retired then Generated.RetryExecution (Generated.RetryExecutionData execution (fromInteger (revisionNumber expected)) (fromInteger (revisionNumber (advanceRevision expected)))) else advance execution expected)
        ( do
            checkedLockRoot binding.rootId
            checkedAdmissionRoot binding.rootId
            (current, actualBinding) <- checkedExecution execution
            _ <- checkedAccess access actualBinding
            checkedRevision expected current
            unless (current.activeOperation == Just operation.specification.operationId && operation.executionId == execution && current.cursor == operation.position) (throwE OperationConflict)
            snapshot <- checkedPayload @ExecutionSnapshot access actualBinding "snapshot" current.snapshot
            retiring <- case retired of
              Nothing -> do
                unless (current.phase == Active && isNothing operation.outcome && not operation.uncertain) (throwE OperationConflict)
                pure Nothing
              Just previousId -> do
                unless (current.phase == Unresolved && operation.uncertain && operation.specification.recovery `elem` [RepeatableObservation, IdempotentEffect]) (throwE UnresolvedOperation)
                previous <- checkedAttempt (Attempt.JobReference 1 execution operation.specification.operationId previousId)
                unless (previous.phase == Attempt.AttemptUncertain && isNothing previous.lateReceipt && isJust previous.uncertainty && operation.outcome == previous.uncertainty) (throwE AttemptConflict)
                attempts <- checkedStatement (operationKey operation.specification.operationId) listOperationAttempts
                unless (length (filter (\attempt -> attempt.phase == Attempt.AttemptSuperseded) attempts) < snapshot.policy.recoveryAttempts) (throwE (ExecutionPolicyRefused "recovery attempt ceiling exhausted"))
                pure (Just previous)
            void (checkedStatement ("shikigami.execution-attempt:" <> attemptKey submission.request.attemptId) lockAttemptIdentity)
            collision <- checkedStatement (attemptKey submission.request.attemptId) selectExecutionAttempt
            when (isJust collision) (throwE AttemptConflict)
            except (either (const (Left AttemptConflict)) Right (Resources.validateKey (attemptKey submission.request.attemptId)))
            (count, pending) <- checkedStatement (operationKey operation.specification.operationId) executionAttemptInventory
            when (isNothing retired && pending) (throwE AttemptConflict)
            when (count >= 1000) (throwE (ExecutionPolicyRefused "operation attempt storage ceiling exceeded"))
            resumeNext <-
              if isJust retired && operation.specification.kind == ToolOperation
                then do
                  input <- checkedPayload @ToolOperationInput access actualBinding "operation-input" operation.input
                  pure (NeedTool input.response input.position)
                else pure current.next
            now <- checkedStatement () currentTime
            checkedDispatchPermission now operation snapshot
            checkedSubmission access actualBinding snapshot operation submission
            pure (current, actualBinding, snapshot, retiring, resumeNext, now)
        )
        \(current, actualBinding, snapshot, retiring, resumeNext, now) -> do
          forM_ retiring \previous -> do
            saveAttempt (previous & #phase .~ Attempt.AttemptSuperseded)
            Tx.statement (operationKey operation.specification.operationId, operation & #outcome .~ Nothing & #continuation .~ Nothing & #uncertain .~ False) updateOperation
          -- Retirement changes pending membership. This integrity check must
          -- observe the tentative write and retain whole-transaction rollback.
          when (isJust retiring) do
            (_, pending) <- Tx.statement (operationKey operation.specification.operationId) executionAttemptInventory
            when pending (abort AttemptConflict)
          receipt <- case (operation.specification.kind, submission.modelCall) of
            (ToolOperation, Nothing) -> do
              void (readPayload @ToolOperationInput access actualBinding "operation-input" operation.input)
              forM_ actualBinding.rootId \rootId -> do
                root <- Roots.inspectRootTx rootId >>= either (abort . ResourceAdmissionRefused . Text.pack . show) pure
                let request = Resources.OperationRequest operation.specification.operationId Nothing Resources.ToolOperation Map.empty operation.fingerprint
                Roots.reserveOperationsTx rootId root.revision [request] now >>= either (abort . ResourceAdmissionRefused . Text.pack . show) (const (pure ()))
                Roots.beginAttemptTx rootId root.revision submission.request now >>= either (abort . ResourceAdmissionRefused . Text.pack . show) (const (pure ()))
              pure Nothing
            (kind, Just prepared) | kind `elem` [ModelTurn, ModelRepair, ModelSummary] -> do
              reservation <- Calls.reserveSelectionCallTx snapshot.selection prepared.limits submission.request prepared.fingerprint now >>= either (abort . ResourceAdmissionRefused . Text.pack . show) pure
              case reservation of Calls.NewCall receipt -> pure (Just receipt); _ -> abort AttemptConflict
            _ -> abort AttemptConflict
          actualWake <- writePayload execution wakeBody
          unless (actualWake == wakeRef) (abort CorruptReplay)
          let attempt = Attempt.ExecutionAttempt 1 execution operation.specification.operationId submission.request fingerprint receipt wakeRef Attempt.AwaitingDispatch Nothing 0 Nothing Nothing Nothing Nothing
          Tx.statement (attemptKey submission.request.attemptId, execution.value, operationKey operation.specification.operationId, attempt) insertExecutionAttempt
          enqueue reference
          saveExecution (current & #revision .~ (advanceRevision expected) & #phase .~ Active & #next .~ resumeNext & #pendingReceipts .~ (current.pendingReceipts + if isJust retired then 1 else 0))
      case result of
        Left (CheckFailed err) -> pure (Left err)
        _ -> do
          stored <- readMetadata (Tx.statement (attemptKey submission.request.attemptId) selectExecutionAttempt)
          pure (maybe (Left ExecutionRevisionConflict) (case result of Right () -> fmap (\(_, attempt) -> (Accepted, attempt)) . duplicate; _ -> duplicate) stored)
  where
    wakeBody = envelope "execution-wake" (toJSON submission.wake)

inspectExecutionAttempt :: (ExecutionReadEffects es) => AttemptId -> Eff es (Either ExecutionError (Maybe Attempt.ExecutionAttempt))
inspectExecutionAttempt attempt = protected (Tx.statement (attemptKey attempt) selectExecutionAttempt)

-- Rotation publishes a new generation's wake without changing the accepted
-- request/attempt fingerprint. Completion always signals the latest publication.
refreshExecutionWake :: (ExecutionEffects es) => ReplayAccess -> StateRevision "execution" -> Attempt.ExecutionWake -> Eff es (Either ExecutionError Admission)
refreshExecutionWake access@(ReplayAccess execution _ _) expected wake = catchExecutionWith id do
  (state, binding) <- readMetadata (getExecution execution)
  ref <- either (throwIO . ExecutionAbort) pure (payloadReference body)
  if state.wake == Just ref
    then pure (Right AlreadyAccepted)
    else do
      let command = if state.phase == Unresolved then Generated.MarkExecutionUnresolved (Generated.MarkExecutionUnresolvedData execution (fromInteger (revisionNumber expected)) (fromInteger (revisionNumber (advanceRevision expected)))) else advance execution expected
      result <- persistChecked
        execution
        command
        ( do
            checkedLockRoot binding.rootId
            (current, actualBinding) <- checkedExecution execution
            _ <- checkedAccess access actualBinding
            checkedRevision expected current
            unless (current.phase `elem` [Active, Unresolved]) (throwE ExecutionNotActive)
            pure current
        )
        \current -> do
          actual <- writePayload execution body
          unless (actual == ref) (abort CorruptReplay)
          saveExecution (current & #revision .~ (advanceRevision expected) & #wake .~ Just ref)
      pure (case result of Right () -> Right Accepted; Left (CheckFailed err) -> Left err; Left EventRejected -> Left ExecutionRevisionConflict)
  where
    body = envelope "execution-wake" (toJSON wake)

-- Updating a wake hint grants no replay read or dispatch authority. This
-- restricted writer keeps accepted work observable after principal revocation.
refreshExecutionControlWake :: (ExecutionEffects es) => AgentIdentity -> ExecutionId -> StateRevision "execution" -> Attempt.ExecutionWake -> Eff es (Either ExecutionError Admission)
refreshExecutionControlWake identity execution expected wake = catchExecutionWith id do
  (_, binding) <- readMetadata (getExecution execution)
  unless (identity == binding.identity) (throwIO (ExecutionAbort ExecutionIdentityConflict))
  now <- liftIO getCurrentTime
  refreshExecutionWake (ReplayAccess execution identity (addUTCTime 60 now)) expected wake

stopExecution :: (ExecutionEffects es) => AgentIdentity -> ExecutionId -> StateRevision "execution" -> Bool -> ExecutionError -> Eff es (Either ExecutionError Admission)
stopExecution identity execution expected cancelled reason = catchExecutionWith id do
  (stored, binding) <- readMetadata (getExecution execution)
  unless (identity == binding.identity) (throwIO (ExecutionAbort ExecutionIdentityConflict))
  if stored.phase `elem` [Failed, Cancelled] && stored.failure == Just reason
    then pure (Right AlreadyAccepted)
    else do
      let command = if stored.pendingReceipts > 0 then (if cancelled then Generated.CancelExecutionPendingReceipts (Generated.CancelExecutionPendingReceiptsData execution (fromInteger (revisionNumber expected)) (fromInteger (revisionNumber (advanceRevision expected)))) else Generated.FailExecutionPendingReceipts (Generated.FailExecutionPendingReceiptsData execution (fromInteger (revisionNumber expected)) (fromInteger (revisionNumber (advanceRevision expected))))) else if cancelled then Generated.CancelExecution (Generated.CancelExecutionData execution (fromInteger (revisionNumber expected)) (fromInteger (revisionNumber (advanceRevision expected)))) else Generated.FailExecution (Generated.FailExecutionData execution (fromInteger (revisionNumber expected)) (fromInteger (revisionNumber (advanceRevision expected))))
      result <- persistChecked
        execution
        command
        ( do
            checkedLockRoot binding.rootId
            (state, actualBinding) <- checkedExecution execution
            unless (actualBinding.identity == identity) (throwE ExecutionIdentityConflict)
            checkedRevision expected state
            unless (state.phase `elem` [Active, Parked]) (throwE UnresolvedOperation)
            pendingOperation <- forM state.activeOperation \operationId -> do
              (_, pending) <- checkedStatement (operationKey operationId) executionAttemptInventory
              when pending (throwE UnresolvedOperation)
              operation <- checkedStatement (operationKey operationId) lockOperation >>= maybe (throwE OperationMissing) pure
              unless (isNothing operation.outcome && not operation.uncertain) (throwE UnresolvedOperation)
              pure (operationId, operation)
            when cancelled do
              root <- maybe (throwE OperationConflict) pure actualBinding.rootId
              result <- lift (Roots.inspectRootTx root)
              status <- either (throwE . ResourceAdmissionRefused . Text.pack . show) pure result
              unless status.cancelled (throwE OperationConflict)
            unless (Lazy.length (Aeson.encode reason) <= 1024) (throwE UnsupportedReplay)
            pure (state, pendingOperation)
        )
        \(state, pendingOperation) -> do
          forM_ pendingOperation \(operationId, operation) -> do
            denied <- writePayload execution (envelope "operation-outcome" (toJSON (OperationDenied "execution stopped before dispatch")))
            Tx.statement (operationKey operationId, operation & #outcome .~ Just denied & #continuation .~ Just WorkFinished) updateOperation
          ref <- writePayload execution (envelope "execution-failure" (toJSON reason))
          saveExecution (state & #revision .~ (advanceRevision expected) & #phase .~ (if cancelled then Cancelled else Failed) & #next .~ WorkFinished & #result .~ Just ref & #failure .~ Just reason & #activeOperation .~ Nothing)
      pure (case result of Right () -> Right Accepted; Left (CheckFailed err) -> Left err; Left EventRejected -> Left ExecutionRevisionConflict)

inspectOperationAttempts :: (ExecutionReadEffects es) => OperationId -> Eff es (Either ExecutionError [Attempt.ExecutionAttempt])
inspectOperationAttempts operation = protected (Tx.statement (operationKey operation) listOperationAttempts)

-- Reconstruct from the last accepted model-facing checkpoint, then append its
-- response and following tool observations. Earlier accepted payloads remain
-- immutable and reachable through the previous model-input reference.
loadModelReplayWindow :: (ExecutionReadEffects es) => ReplayAccess -> Eff es (Either ExecutionError (ReplayContext, Maybe PayloadRef, Maybe (Operation, ModelOperationInput, ReplayAssistant)))
loadModelReplayWindow access@(ReplayAccess execution _ _) = protected do
  (state, binding) <- getExecution execution
  _ <- checkAccess access binding
  snapshot <- readPayload @ExecutionSnapshot access binding "snapshot" state.snapshot
  lastModel <- Tx.statement execution.value lastAcceptedModelOperation
  (base, after, predecessor) <- case lastModel of
    Nothing -> pure (snapshot.initialContext, -1, Nothing)
    Just operation -> do
      input <- readPayload @ModelOperationInput access binding "operation-input" operation.input
      ref <- maybe (abort CorruptReplay) pure operation.outcome
      outcome <- readPayload @OperationOutcome access binding "operation-outcome" ref
      case outcome of
        ModelReturned assistant _ -> pure (input.view.context & #messages %~ (<> [AssistantTurn assistant]), revisionNumber operation.position, Just operation.input)
        _ -> abort CorruptReplay
  tail <- Tx.statement (execution.value, fromInteger after) acceptedOperationsAfter
  (context, summary, _) <- foldM (append binding snapshot.policy.contextBytes) (base, Nothing, []) tail
  pure (context, predecessor, summary)
  where
    append binding byteLimit (context, summary, group) operation = case operation.specification.kind of
      ModelSummary -> do
        input <- readPayload @ModelOperationInput access binding "operation-input" operation.input
        outcome <- maybe (abort CorruptReplay) (readPayload @OperationOutcome access binding "operation-outcome") operation.outcome
        case outcome of ModelReturned assistant _ -> pure (context, Just (operation, input, assistant), group); _ -> abort CorruptReplay
      ToolOperation -> do
        input <- readPayload @ToolOperationInput access binding "operation-input" operation.input
        outcome <- maybe (abort CorruptReplay) (readPayload @OperationOutcome access binding "operation-outcome") operation.outcome
        message <- case outcome of
          ToolReturned blocks failed -> pure (ToolTurn input.invocation.callId input.invocation.name blocks failed Nothing)
          RichToolReturned result -> pure (ToolTurn input.invocation.callId input.invocation.name (observationBlocks result) result.failed Nothing)
          OperationDenied reason -> pure (ToolTurn input.invocation.callId input.invocation.name [TextBlock reason] True Nothing)
          _ -> abort UnresolvedOperation
        let pending = group <> [message]
        unless (Lazy.length (Aeson.encode pending) <= fromIntegral byteLimit) (abort (ExecutionPolicyRefused "required tool observations exceed the context ceiling"))
        pure (context & #messages %~ (<> [message]), summary, pending)
      _ -> pure (context, summary, group)

-- Accepted state is a sufficient authority to publish its wake hint. This
-- method never returns the opaque token or grants new reads/dispatch authority,
-- so a revoked principal cannot strand an already committed outcome.
publishExecutionWake :: (ExecutionReadEffects es) => Attempt.JobReference -> Eff es (Either ExecutionError ())
publishExecutionWake reference = catchExecutionWith id do
  loaded <- protected do
    current <- getAttempt reference
    if current.phase == Attempt.AttemptSuperseded
      then pure Nothing
      else do
        unless (current.phase `elem` [Attempt.AttemptCommitted, Attempt.AttemptAbandoned, Attempt.AttemptUncertain]) (abort ExecutionNotActive)
        (state, binding) <- getExecution reference.executionId
        now <- Tx.statement () currentTime
        Just <$> readPayload (ReplayAccess reference.executionId binding.identity (addUTCTime 60 now)) binding "execution-wake" (fromMaybe current.wake state.wake)
  case loaded of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right ())
    Right (Just (wake :: Attempt.ExecutionWake)) ->
      lookupAwakeable (awakeableIdToUuid wake.token) >>= \case
        Nothing -> pure (Left (ExecutionPolicyRefused "execution wake is unavailable"))
        Just row -> do
          generation <- currentGeneration (WorkflowName row.ownerWorkflowName) (WorkflowId row.ownerWorkflowId)
          if generation /= wake.generation
            then pure (Right ())
            else do
              now <- liftIO getCurrentTime
              append <- prepareJournalAppend (WorkflowName row.ownerWorkflowName) (WorkflowId row.ownerWorkflowId) wake.generation (StepRecorded (awakeableStepPrefix <> awakeableIdText wake.token) (toJSON reference) now)
              runTransaction do
                transitioned <- completeAwakeableTx (awakeableIdToUuid wake.token) (toJSON reference) now
                status <- lookupAwakeableStatusTx (awakeableIdToUuid wake.token)
                if transitioned || status == Just Completed
                  then
                    append >>= \case
                      JournalAppendConflict {} -> Tx.condemn >> pure (Left ExecutionStorageUnavailable)
                      _ -> pure (Right ())
                  else pure (Right ())

-- The queue's admitted identity can record a conditional pre-dispatch refusal
-- even after revocation. No protected replay body is read or returned here.
refuseUndispatchedExecutionAttempt :: (ExecutionEffects es) => AgentIdentity -> StateRevision "execution" -> Attempt.JobReference -> Eff es (Either ExecutionError Admission)
refuseUndispatchedExecutionAttempt identity expected reference = catchExecutionWith id do
  (_, binding) <- readMetadata (getExecution reference.executionId)
  unless (identity == binding.identity) (throwIO (ExecutionAbort ExecutionIdentityConflict))
  now <- liftIO getCurrentTime
  abandonExecutionAttempt (ReplayAccess reference.executionId identity now) expected reference

claimExecutionAttempt :: (ExecutionEffects es) => ReplayAccess -> StateRevision "execution" -> Attempt.JobReference -> Text -> Int -> Eff es (Either ExecutionError Attempt.ClaimResult)
claimExecutionAttempt access@(ReplayAccess execution _ _) expected reference owner seconds = catchExecutionWith id do
  unless (reference.format == 1 && reference.executionId == execution && not (Text.null owner) && Text.length owner <= 256 && seconds >= 1 && seconds <= 3600) (throwIO (ExecutionAbort AttemptConflict))
  (_, binding) <- readMetadata (getExecution execution)
  previous <- readMetadata (Tx.statement (attemptKey reference.attemptId) selectExecutionAttempt) >>= maybe (throwIO (ExecutionAbort AttemptMissing)) pure
  unless (matchesReference reference previous) (throwIO (ExecutionAbort AttemptConflict))
  now <- liftIO getCurrentTime
  let observation
        | previous.phase `elem` [Attempt.AttemptCommitted, Attempt.AttemptAbandoned, Attempt.AttemptSuperseded] = Just Attempt.AttemptFinished
        | previous.phase == Attempt.AttemptUncertain || (previous.phase == Attempt.DispatchStarted && maybe True (now >=) previous.expiresAt) = Just Attempt.AttemptNeedsReconciliation
        | previous.phase == Attempt.DispatchStarted || (previous.phase == Attempt.Claimed && maybe False (now <) previous.expiresAt) = Just Attempt.AttemptBusy
        | otherwise = Nothing
  case observation of
    Just value -> pure (Right value)
    Nothing -> do
      result <- persistChecked
        execution
        (advance execution expected)
        ( do
            checkedLockRoot binding.rootId
            checkedAdmissionRoot binding.rootId
            (state, actualBinding) <- checkedExecution execution
            _ <- checkedAccess access actualBinding
            checkedRevision expected state
            unless (state.phase == Active && state.activeOperation == Just reference.operationId) (throwE OperationConflict)
            current <- checkedAttempt reference
            instant <- checkedStatement () currentTime
            unless (current == previous && (current.phase == Attempt.AwaitingDispatch || (current.phase == Attempt.Claimed && maybe False (instant >=) current.expiresAt))) (throwE AttemptClaimLost)
            pure (state, current, instant)
        )
        \(state, current, instant) -> do
          let claimed = current & #phase .~ Attempt.Claimed & #owner .~ Just owner & #generation .~ (current.generation + 1) & #expiresAt .~ Just (addUTCTime (fromIntegral seconds) instant)
          saveAttempt claimed
          saveExecution (state & #revision .~ (advanceRevision expected))
      pure case result of
        Right () -> Right (Attempt.ClaimGranted (Attempt.AttemptClaim reference owner (previous.generation + 1)))
        Left (CheckFailed err) -> Left err
        Left EventRejected -> Left ExecutionRevisionConflict

-- Only a successful transition from Claimed may run IO. Repeated start calls
-- return AlreadyAccepted, which is observation and never dispatch permission.
startExecutionAttempt :: (ExecutionEffects es) => ReplayAccess -> StateRevision "execution" -> Attempt.AttemptClaim -> Eff es (Either ExecutionError Admission)
startExecutionAttempt access@(ReplayAccess execution _ _) expected claim = catchExecutionWith id do
  (_, binding) <- readMetadata (getExecution execution)
  previous <- readMetadata (Tx.statement (attemptKey claim.reference.attemptId) selectExecutionAttempt) >>= maybe (throwIO (ExecutionAbort AttemptMissing)) pure
  if claimMatches claim previous && previous.phase == Attempt.DispatchStarted
    then pure (Right AlreadyAccepted)
    else do
      result <- persistChecked
        execution
        (advance execution expected)
        ( do
            checkedLockRoot binding.rootId
            checkedAdmissionRoot binding.rootId
            (state, actualBinding) <- checkedExecution execution
            _ <- checkedAccess access actualBinding
            checkedRevision expected state
            unless (state.phase == Active && state.activeOperation == Just claim.reference.operationId) (throwE OperationConflict)
            current <- checkedAttempt claim.reference
            now <- checkedStatement () currentTime
            unless (claimMatches claim current && current.phase == Attempt.Claimed && maybe False (now <) current.expiresAt) (throwE AttemptClaimLost)
            operation <- checkedStatement (operationKey current.operationId) lockOperation >>= maybe (throwE OperationMissing) pure
            snapshot <- checkedPayload access actualBinding "snapshot" state.snapshot
            checkedDispatchPermission now operation snapshot
            pure (state, current)
        )
        \(state, current) -> do
          saveAttempt (current & #phase .~ Attempt.DispatchStarted)
          saveExecution (state & #revision .~ (advanceRevision expected))
      pure (case result of Right () -> Right Accepted; Left (CheckFailed err) -> Left err; Left EventRejected -> Left ExecutionRevisionConflict)

checkStartedExecutionAttempt :: (ExecutionReadEffects es) => ReplayAccess -> Attempt.AttemptClaim -> Eff es (Either ExecutionError ())
checkStartedExecutionAttempt access@(ReplayAccess execution _ _) claim = protected do
  (_, binding) <- Tx.statement execution.value selectExecution >>= maybe (abort ExecutionMissing) pure
  lockRoot binding.rootId
  validateAdmissionRoot binding.rootId
  (state, actualBinding) <- getExecution execution
  _ <- checkAccess access actualBinding
  unless (state.phase == Active && state.activeOperation == Just claim.reference.operationId) (abort OperationConflict)
  current <- getAttempt claim.reference
  now <- Tx.statement () currentTime
  unless (claimMatches claim current && current.phase == Attempt.DispatchStarted && maybe False (now <) current.expiresAt) (abort AttemptClaimLost)
  operation <- Tx.statement (operationKey current.operationId) lockOperation >>= maybe (abort OperationMissing) pure
  forM_ operation.permission \permission -> unless (permission.resolution == Just PermissionApproved && now < permission.expiresAt) (abort (ExecutionPolicyRefused "tool permission is unavailable or expired"))

-- A conditional refusal before dispatch is known to have made no external
-- call. It releases active capacity, retains the accounted attempt and permits
-- a safe new transport attempt under the same logical operation key.
abandonExecutionAttempt :: (ExecutionEffects es) => ReplayAccess -> StateRevision "execution" -> Attempt.JobReference -> Eff es (Either ExecutionError Admission)
abandonExecutionAttempt access@(ReplayAccess execution _ _) expected reference = catchExecutionWith id do
  unless (reference.executionId == execution) (throwIO (ExecutionAbort AttemptConflict))
  previous <- readMetadata (Tx.statement (attemptKey reference.attemptId) selectExecutionAttempt) >>= maybe (throwIO (ExecutionAbort AttemptMissing)) pure
  unless (matchesReference reference previous) (throwIO (ExecutionAbort AttemptConflict))
  if previous.phase == Attempt.AttemptAbandoned
    then pure (Right AlreadyAccepted)
    else do
      (_, binding) <- readMetadata (getExecution execution)
      result <- persistChecked
        execution
        (advance execution expected)
        ( do
            checkedLockRoot binding.rootId
            (state, actualBinding) <- checkedExecution execution
            checkedOutcomeIdentity access actualBinding
            checkedRevision expected state
            unless (state.phase == Active && state.activeOperation == Just reference.operationId) (throwE OperationConflict)
            current <- checkedAttempt reference
            unless (current == previous && current.phase `elem` [Attempt.AwaitingDispatch, Attempt.Claimed]) (throwE AttemptClaimLost)
            pure (state, actualBinding, current)
        )
        \(state, actualBinding, current) -> do
          let terminal = Calls.CallOutcome Calls.CallRefused Map.empty [] Nothing Nothing Nothing
              receipt = Attempt.AttemptResult (OperationDenied "attempt refused before dispatch") state.next (terminal <$ current.call)
          case current.call of
            Just call -> Calls.finishSelectionCallTx call terminal >>= either (abort . ResourceAdmissionRefused . Text.pack . show) (const (pure ()))
            Nothing -> forM_ actualBinding.rootId \root -> Roots.settleAttemptTx root current.request.attemptId (Resources.KnownUsage zeroModelBilling) >>= either (abort . ResourceAdmissionRefused . Text.pack . show) (const (pure ()))
          ref <- writePayload execution (envelope "attempt-result" (toJSON receipt))
          saveAttempt (current & #phase .~ Attempt.AttemptAbandoned & #outcome .~ Just ref)
          saveExecution (state & #revision .~ (advanceRevision expected))
      pure (case result of Right () -> Right Accepted; Left (CheckFailed err) -> Left err; Left EventRejected -> Left ExecutionRevisionConflict)

completeExecutionAttempt :: (ExecutionEffects es) => ReplayAccess -> StateRevision "execution" -> Attempt.AttemptClaim -> Attempt.AttemptResult -> Eff es (Either ExecutionError Admission)
completeExecutionAttempt access@(ReplayAccess execution _ _) expected claim result = catchExecutionWith id do
  previous <- readMetadata (Tx.statement (attemptKey claim.reference.attemptId) selectExecutionAttempt) >>= maybe (throwIO (ExecutionAbort AttemptMissing)) pure
  unless (claim.reference.executionId == execution && claimMatches claim previous) (throwIO (ExecutionAbort AttemptClaimLost))
  when (previous.phase `elem` [Attempt.AttemptUncertain, Attempt.AttemptSuperseded]) (throwIO (ExecutionAbort AttemptClaimLost))
  ref <- either (throwIO . ExecutionAbort) pure (payloadReference body)
  if previous.phase == Attempt.AttemptCommitted
    then pure (if previous.outcome == Just ref then Right AlreadyAccepted else Left AttemptConflict)
    else do
      let accounting = case (previous.call, result.accounting) of (Just receipt, Just outcome) -> Just (receipt, outcome); _ -> Nothing
      unless (isJust previous.call == isJust result.accounting && maybe True (\outcome -> outcome.phase /= Calls.CallTransportUnknown) result.accounting) (throwIO (ExecutionAbort AttemptConflict))
      recordOutcomeAndAdvanceWith access expected previous.operationId result.outcome result.next accounting do
        current <- getAttempt claim.reference
        now <- Tx.statement () currentTime
        unless (claimMatches claim current && current.phase == Attempt.DispatchStarted && maybe False (now <) current.expiresAt) (abort AttemptClaimLost)
        case result.outcome of OperationUnresolved {} -> abort AttemptConflict; _ -> pure ()
        (_, binding) <- getExecution execution
        when (isNothing previous.call) $ forM_ binding.rootId \root -> Roots.settleAttemptTx root previous.request.attemptId (toolSettlement previous.request) >>= either (abort . ResourceAdmissionRefused . Text.pack . show) (const (pure ()))
        actual <- writePayload execution body
        unless (actual == ref) (abort CorruptReplay)
        saveAttempt (current & #phase .~ Attempt.AttemptCommitted & #outcome .~ Just ref)
        pure (Right ())
  where
    body = envelope "attempt-result" (toJSON result)

markExpiredExecutionAttemptUncertain :: (ExecutionEffects es) => AgentIdentity -> StateRevision "execution" -> Attempt.JobReference -> Eff es (Either ExecutionError Admission)
markExpiredExecutionAttemptUncertain identity expected reference = catchExecutionWith id do
  (_, binding) <- readMetadata (getExecution reference.executionId)
  unless (identity == binding.identity) (throwIO (ExecutionAbort ExecutionIdentityConflict))
  attempt <- readMetadata (Tx.statement (attemptKey reference.attemptId) selectExecutionAttempt) >>= maybe (throwIO (ExecutionAbort AttemptMissing)) pure
  now <- liftIO getCurrentTime
  unless (matchesReference reference attempt && attempt.phase == Attempt.DispatchStarted && maybe False (now >=) attempt.expiresAt) (throwIO (ExecutionAbort AttemptClaimLost))
  let claim = Attempt.AttemptClaim reference (fromMaybe "" attempt.owner) attempt.generation
  markExecutionAttemptUncertain (ReplayAccess reference.executionId identity now) expected claim

markExecutionAttemptUncertain :: (ExecutionEffects es) => ReplayAccess -> StateRevision "execution" -> Attempt.AttemptClaim -> Eff es (Either ExecutionError Admission)
markExecutionAttemptUncertain access@(ReplayAccess execution _ _) expected claim = catchExecutionWith id do
  previous <- readMetadata (Tx.statement (attemptKey claim.reference.attemptId) selectExecutionAttempt) >>= maybe (throwIO (ExecutionAbort AttemptMissing)) pure
  unless (claim.reference.executionId == execution && claimMatches claim previous) (throwIO (ExecutionAbort AttemptClaimLost))
  if previous.phase `elem` [Attempt.AttemptUncertain, Attempt.AttemptSuperseded]
    then pure (Right AlreadyAccepted)
    else do
      (state, _) <- readMetadata (getExecution execution)
      let accounting = (\receipt -> (receipt, Calls.CallOutcome Calls.CallTransportUnknown Map.empty [] Nothing Nothing Nothing)) <$> previous.call
      recordOutcomeAndAdvanceWith access expected previous.operationId (OperationUnresolved "executor dispatch outcome is unavailable") state.next accounting do
        current <- getAttempt claim.reference
        unless (claimMatches claim current && current.phase == Attempt.DispatchStarted) (abort AttemptClaimLost)
        (_, binding) <- getExecution execution
        when (isNothing current.call) $ forM_ binding.rootId \root -> Roots.settleAttemptTx root current.request.attemptId (Resources.UnknownUsage "executor dispatch outcome is unavailable") >>= either (abort . ResourceAdmissionRefused . Text.pack . show) (const (pure ()))
        unknownRef <- require (outcomeReference (OperationUnresolved "executor dispatch outcome is unavailable"))
        saveAttempt (current & #phase .~ Attempt.AttemptUncertain & #uncertainty .~ Just unknownRef)
        pure (Right ())

-- A former owner retains its actual receipt without changing the chosen
-- logical result. Superseded receipts settle only their own actual accounting.
recordLateExecutionReceipt :: (ExecutionEffects es) => ReplayAccess -> StateRevision "execution" -> Attempt.AttemptClaim -> Attempt.AttemptResult -> Eff es (Either ExecutionError Admission)
recordLateExecutionReceipt access@(ReplayAccess execution _ _) expected claim receipt = catchExecutionWith id do
  previous <- readMetadata (Tx.statement (attemptKey claim.reference.attemptId) selectExecutionAttempt) >>= maybe (throwIO (ExecutionAbort AttemptMissing)) pure
  if previous.phase == Attempt.AttemptSuperseded
    then recordSupersededReceipt access expected claim receipt
    else do
      unless (claim.reference.executionId == execution && claimMatches claim previous && previous.phase == Attempt.AttemptUncertain) (throwIO (ExecutionAbort AttemptClaimLost))
      ref <- either (throwIO . ExecutionAbort) pure (payloadReference body)
      case previous.lateReceipt of
        Just existing -> pure (if existing == ref then Right AlreadyAccepted else Left AttemptConflict)
        Nothing -> do
          (_, binding) <- readMetadata (getExecution execution)
          result <- persistChecked
            execution
            (Generated.MarkExecutionUnresolved (Generated.MarkExecutionUnresolvedData execution (fromInteger (revisionNumber expected)) (fromInteger (revisionNumber (advanceRevision expected)))))
            ( do
                checkedLockRoot binding.rootId
                (state, actualBinding) <- checkedExecution execution
                checkedOutcomeIdentity access actualBinding
                checkedRevision expected state
                unless (state.phase == Unresolved && state.activeOperation == Just previous.operationId) (throwE OperationConflict)
                current <- checkedAttempt claim.reference
                unless (current == previous && claimMatches claim current) (throwE AttemptClaimLost)
                pure (state, current)
            )
            \(state, current) -> do
              actual <- writePayload execution body
              unless (actual == ref) (abort CorruptReplay)
              saveAttempt (current & #lateReceipt .~ Just ref)
              saveExecution (state & #revision .~ (advanceRevision expected))
          pure (case result of Right () -> Right Accepted; Left (CheckFailed err) -> Left err; Left EventRejected -> Left ExecutionRevisionConflict)
  where
    body = envelope "late-attempt-receipt" (toJSON receipt)

-- Trusted independent providers call this only after validating their retained
-- factual receipt. Socket/model callers must never supply the result body.
-- Like factual control reconciliation, this returns metadata and no replay
-- permit. It confers neither fresh dispatch nor protected replay-read authority.
recordIndependentToolReceipt :: (ExecutionEffects es) => AgentIdentity -> StateRevision "execution" -> Attempt.AttemptClaim -> Attempt.AttemptResult -> Eff es (Either ExecutionError Admission)
recordIndependentToolReceipt identity expected claim receipt = catchExecutionWith id do
  let execution = claim.reference.executionId
  (_, binding) <- readMetadata (getExecution execution)
  unless (identity == binding.identity) (throwIO (ExecutionAbort ExecutionIdentityConflict))
  previous <- readMetadata (Tx.statement (attemptKey claim.reference.attemptId) selectExecutionAttempt) >>= maybe (throwIO (ExecutionAbort AttemptMissing)) pure
  unless (claimMatches claim previous && isNothing previous.call && isNothing receipt.accounting) (throwIO (ExecutionAbort AttemptConflict))
  operation <- readMetadata (Tx.statement (operationKey previous.operationId) selectOperation) >>= maybe (throwIO (ExecutionAbort OperationMissing)) pure
  unless (operation.executionId == execution && operation.specification.kind == ToolOperation) (throwIO (ExecutionAbort AttemptConflict))
  case receipt.outcome of
    ToolReturned {} -> pure ()
    RichToolReturned {} -> pure ()
    _ -> throwIO (ExecutionAbort AttemptConflict)
  case receipt.next of
    NeedModel -> pure ()
    NeedTool _ position | position > 0 -> pure ()
    _ -> throwIO (ExecutionAbort AttemptConflict)
  if previous.phase == Attempt.AttemptCommitted
    then do
      reference <- either (throwIO . ExecutionAbort) pure (payloadReference (envelope "attempt-result" (toJSON receipt)))
      pure (if previous.outcome == Just reference then Right AlreadyAccepted else Left AttemptConflict)
    else do
      now <- liftIO getCurrentTime
      recordLateExecutionReceipt (ReplayAccess execution identity now) expected claim receipt

-- A superseded owner's receipt settles that actual attempt only. The logical
-- operation, chosen result and cursor remain exactly as the replacement left
-- them, including after the execution child has completed.
recordSupersededReceipt :: (ExecutionEffects es) => ReplayAccess -> StateRevision "execution" -> Attempt.AttemptClaim -> Attempt.AttemptResult -> Eff es (Either ExecutionError Admission)
recordSupersededReceipt access@(ReplayAccess execution _ _) expected claim receipt = do
  (stored, binding) <- readMetadata (getExecution execution)
  previous <- readMetadata (Tx.statement (attemptKey claim.reference.attemptId) selectExecutionAttempt) >>= maybe (throwIO (ExecutionAbort AttemptMissing)) pure
  unless (claim.reference.executionId == execution && claimMatches claim previous && previous.phase == Attempt.AttemptSuperseded) (throwIO (ExecutionAbort AttemptClaimLost))
  ref <- either (throwIO . ExecutionAbort) pure (payloadReference body)
  case previous.lateReceipt of
    Just old -> pure (if old == ref then Right AlreadyAccepted else Left AttemptConflict)
    Nothing -> do
      result <- persistChecked
        execution
        (Generated.SettleExecutionReceipt (Generated.SettleExecutionReceiptData execution (fromInteger (revisionNumber expected)) (fromInteger (revisionNumber (advanceRevision expected))) (stored.pendingReceipts - 1)))
        ( do
            checkedLockRoot binding.rootId
            (state, actualBinding) <- checkedExecution execution
            checkedOutcomeIdentity access actualBinding
            checkedRevision expected state
            unless (state.pendingReceipts > 0 && state.pendingReceipts == stored.pendingReceipts) (throwE AttemptConflict)
            current <- checkedAttempt claim.reference
            unless (current == previous && claimMatches claim current) (throwE AttemptClaimLost)
            operation <- checkedStatement (operationKey current.operationId) lockOperation >>= maybe (throwE OperationMissing) pure
            checkedAttemptReceipt operation receipt
            pure (state, actualBinding, current)
        )
        \(state, actualBinding, current) -> do
          settleRetainedReceipt actualBinding current receipt
          actual <- writePayload execution body
          unless (actual == ref) (abort CorruptReplay)
          resultRef <- writePayload execution (envelope "attempt-result" (toJSON receipt))
          saveAttempt (current & #lateReceipt .~ Just ref & #outcome .~ Just resultRef)
          saveExecution (state & #revision .~ (advanceRevision expected) & #pendingReceipts .~ (state.pendingReceipts - 1))
      pure (case result of Right () -> Right Accepted; Left (CheckFailed err) -> Left err; Left EventRejected -> Left ExecutionRevisionConflict)
  where
    body = envelope "late-attempt-receipt" (toJSON receipt)

checkedAttemptReceipt :: Operation -> Attempt.AttemptResult -> ExecutionCheck ()
checkedAttemptReceipt operation receipt = do
  case receipt.outcome of
    ModelReturned {} -> unless (operation.specification.kind `elem` [ModelTurn, ModelRepair, ModelSummary] && isJust receipt.accounting) (throwE AttemptConflict)
    RichToolReturned {} -> unless (operation.specification.kind == ToolOperation && isNothing receipt.accounting) (throwE AttemptConflict)
    ToolReturned {} -> unless (operation.specification.kind == ToolOperation && isNothing receipt.accounting) (throwE AttemptConflict)
    OperationDenied {} -> pure ()
    _ -> throwE AttemptConflict
  when (maybe False (\accounting -> accounting.phase == Calls.CallTransportUnknown) receipt.accounting) (throwE AttemptConflict)

settleRetainedReceipt :: ExecutionBinding -> Attempt.ExecutionAttempt -> Attempt.AttemptResult -> Transaction ()
settleRetainedReceipt binding attempt receipt = case (attempt.call, receipt.accounting) of
  (Just call, Just terminal) -> Calls.reconcileSelectionCallTx call terminal >>= either (abort . ResourceAdmissionRefused . Text.pack . show) (const (pure ()))
  (Nothing, Nothing) -> forM_ binding.rootId \root -> Roots.reconcileSettlementTx root attempt.request.attemptId (toolSettlement attempt.request) >>= either (abort . ResourceAdmissionRefused . Text.pack . show) (const (pure ()))
  _ -> abort AttemptConflict

-- Reconciliation consumes the retained former owner's actual receipt. It
-- never samples another result, dispatches IO or invents zero measurements.
reconcileExecutionAttempt :: (ExecutionEffects es) => ReplayAccess -> StateRevision "execution" -> AttemptId -> Eff es (Either ExecutionError Admission)
reconcileExecutionAttempt access@(ReplayAccess execution _ _) expected attemptId = catchExecutionWith id do
  previous <- readMetadata (Tx.statement (attemptKey attemptId) selectExecutionAttempt) >>= maybe (throwIO (ExecutionAbort AttemptMissing)) pure
  unless (previous.executionId == execution) (throwIO (ExecutionAbort AttemptConflict))
  if previous.phase `elem` [Attempt.AttemptCommitted, Attempt.AttemptSuperseded] && isJust previous.lateReceipt
    then pure (Right AlreadyAccepted)
    else do
      (_, binding) <- readMetadata (getExecution execution)
      result <- persistChecked
        execution
        (Generated.ReconcileExecution (Generated.ReconcileExecutionData execution (fromInteger (revisionNumber expected)) (fromInteger (revisionNumber (advanceRevision expected)))))
        ( do
            checkedLockRoot binding.rootId
            (state, actualBinding) <- checkedExecution execution
            checkedOutcomeIdentity access actualBinding
            checkedRevision expected state
            unless (state.phase == Unresolved && state.activeOperation == Just previous.operationId) (throwE OperationConflict)
            current <- checkedStatement (attemptKey attemptId) lockExecutionAttempt >>= maybe (throwE AttemptMissing) pure
            unless (current == previous && current.phase == Attempt.AttemptUncertain) (throwE AttemptConflict)
            late <- maybe (throwE UnresolvedOperation) pure current.lateReceipt
            now <- checkedStatement () currentTime
            receipt <- checkedPayload @Attempt.AttemptResult (ReplayAccess execution actualBinding.identity (addUTCTime 60 now)) actualBinding "late-attempt-receipt" late
            operation <- checkedStatement (operationKey current.operationId) lockOperation >>= maybe (throwE OperationMissing) pure
            unless (operation.uncertain && operation.outcome == current.uncertainty && isJust current.uncertainty) (throwE OperationConflict)
            checkedAttemptReceipt operation receipt
            pure (state, actualBinding, current, receipt, operation)
        )
        \(state, actualBinding, current, receipt, operation) -> do
          settleRetainedReceipt actualBinding current receipt
          outcomeRef <- writePayload execution (envelope "operation-outcome" (toJSON receipt.outcome))
          resultRef <- writePayload execution (envelope "attempt-result" (toJSON receipt))
          Tx.statement (operationKey current.operationId, operation & #outcome .~ Just outcomeRef & #continuation .~ Just receipt.next & #uncertain .~ False) updateOperation
          saveAttempt (current & #phase .~ Attempt.AttemptCommitted & #outcome .~ Just resultRef)
          saveExecution (state & #revision .~ (advanceRevision expected) & #phase .~ Active & #activeOperation .~ Nothing & #cursor .~ (advanceRevision state.cursor) & #next .~ receipt.next)
      pure (case result of Right () -> Right Accepted; Left (CheckFailed err) -> Left err; Left EventRejected -> Left ExecutionRevisionConflict)

-- Applying a retained receipt records accepted facts and returns admission
-- metadata only, including when its principal can no longer read replay bodies.
reconcileExecutionControlAttempt :: (ExecutionEffects es) => AgentIdentity -> ExecutionId -> StateRevision "execution" -> AttemptId -> Eff es (Either ExecutionError Admission)
reconcileExecutionControlAttempt identity execution expected attempt = catchExecutionWith id do
  (_, binding) <- readMetadata (getExecution execution)
  unless (identity == binding.identity) (throwIO (ExecutionAbort ExecutionIdentityConflict))
  now <- liftIO getCurrentTime
  reconcileExecutionAttempt (ReplayAccess execution identity now) expected attempt

matchesReference :: Attempt.JobReference -> Attempt.ExecutionAttempt -> Bool
matchesReference reference attempt = reference.format == 1 && reference.executionId == attempt.executionId && reference.operationId == attempt.operationId && reference.attemptId == attempt.request.attemptId

claimMatches :: Attempt.AttemptClaim -> Attempt.ExecutionAttempt -> Bool
claimMatches claim attempt = matchesReference claim.reference attempt && attempt.owner == Just claim.owner && attempt.generation == claim.generation

getAttempt :: Attempt.JobReference -> Transaction Attempt.ExecutionAttempt
getAttempt reference = do
  attempt <- Tx.statement (attemptKey reference.attemptId) lockExecutionAttempt >>= maybe (abort AttemptMissing) pure
  unless (matchesReference reference attempt) (abort AttemptConflict)
  pure attempt

saveAttempt :: Attempt.ExecutionAttempt -> Transaction ()
saveAttempt attempt = Tx.statement (attemptKey attempt.request.attemptId, operationKey attempt.operationId, attempt) updateExecutionAttempt

attemptKey :: AttemptId -> Text
attemptKey (AttemptId key) = key

recordOutcomeAndAdvance :: (ExecutionEffects es) => ReplayAccess -> StateRevision "execution" -> OperationId -> OperationOutcome -> NextWork -> Maybe (Calls.CallReceipt, Calls.CallOutcome) -> Eff es (Either ExecutionError Admission)
recordOutcomeAndAdvance access revision operation outcome next accounting = recordOutcomeAndAdvanceWith access revision operation outcome next accounting (pure (Right ()))

-- The final transaction hook admits claim/fence checks and deliberate fault
-- injection. A refusal rolls back lifecycle, payload, cursor and accounting.
recordOutcomeAndAdvanceWith :: (ExecutionEffects es) => ReplayAccess -> StateRevision "execution" -> OperationId -> OperationOutcome -> NextWork -> Maybe (Calls.CallReceipt, Calls.CallOutcome) -> Transaction (Either ExecutionError ()) -> Eff es (Either ExecutionError Admission)
recordOutcomeAndAdvanceWith access@(ReplayAccess execution _ _) expected operationId outcome next accounting finalCheck = catchExecutionWith id do
  previous <- findOperation operationId
  case (previous, payloadReference body) of
    (Nothing, _) -> pure (Left OperationMissing)
    (_, Left err) -> pure (Left err)
    (Just operation, Right ref)
      | ModelReturned {} <- outcome, isNothing accounting -> pure (Left OperationConflict)
      | operation.executionId /= execution -> pure (Left OperationConflict)
      | operation.outcome == Just ref && operation.continuation == Just next -> pure (Right AlreadyAccepted)
      | isJust operation.outcome -> pure (Left OperationConflict)
      | otherwise -> do
          stored <- readMetadata (Tx.statement execution.value selectExecution)
          case stored of
            Nothing -> pure (Left ExecutionMissing)
            Just (_, binding) -> do
              let unresolved = case outcome of OperationUnresolved {} -> True; _ -> False
                  command = if unresolved then Generated.MarkExecutionUnresolved (Generated.MarkExecutionUnresolvedData execution (fromInteger (revisionNumber expected)) (fromInteger (revisionNumber (advanceRevision expected)))) else advance execution expected
              let precondition = outcomePrecondition access expected operation outcome accounting binding
              result <- persistGuarded execution command precondition do
                -- The precondition retains root/execution/operation row locks.
                -- Reread transaction-local state rather than retaining callback cells.
                (state, _) <- getExecution execution
                forM_ accounting \(receipt, terminal) ->
                  Calls.finishSelectionCallTx receipt terminal >>= either (abort . ResourceAdmissionRefused . Text.pack . show) (const (pure ()))
                actual <- writePayload execution body
                unless (actual == ref) (abort CorruptReplay)
                Tx.statement (operationKey operationId, operation & #outcome .~ Just ref & #continuation .~ Just next & #uncertain .~ unresolved) updateOperation
                saveExecution (state & #revision .~ (advanceRevision expected) & #cursor .~ (if unresolved then state.cursor else advanceRevision state.cursor) & #phase .~ (if unresolved then Unresolved else Active) & #activeOperation .~ (if unresolved then Just operationId else Nothing) & #next .~ next)
                finalCheck >>= require
              case result of
                Right () -> pure (Right Accepted)
                Left EventRejected -> do
                  recorded <- findOperation operationId
                  pure (if maybe False (\stored -> stored.outcome == Just ref && stored.continuation == Just next) recorded then Right AlreadyAccepted else Left ExecutionRevisionConflict)
                Left (CheckFailed err) -> pure (Left err)
  where
    body = envelope "operation-outcome" outcome

-- Bounded command authority under the same root -> execution -> operation lock
-- order as the inline writer. Accounting settlement and final hooks stay late:
-- their failures must escape the transaction through ExecutionAbort.
outcomePrecondition :: ReplayAccess -> StateRevision "execution" -> Operation -> OperationOutcome -> Maybe (Calls.CallReceipt, Calls.CallOutcome) -> ExecutionBinding -> Transaction (Either ExecutionError ())
outcomePrecondition (ReplayAccess execution identity _) expected operation outcome accounting binding = do
  root <- traverse Roots.inspectRootTx binding.rootId
  case sequence root of
    Left err -> pure (Left (ResourceAdmissionRefused (Text.pack (show err))))
    Right _ -> do
      stored <- Tx.statement execution.value lockExecution
      actual <- Tx.statement (operationKey operation.specification.operationId) lockOperation
      pure do
        (state, actualBinding) <- maybe (Left ExecutionMissing) Right stored
        unless (identity == actualBinding.identity) (Left ReplayReadRefused)
        unless (revisionNumber expected < toInteger (maxBound :: Int) && state.revision == expected) (Left ExecutionRevisionConflict)
        unless (state.activeOperation == Just operation.specification.operationId && state.phase == Active) (Left OperationConflict)
        actualOperation <- maybe (Left OperationMissing) Right actual
        unless (actualOperation == operation) (Left OperationConflict)
        forM_ accounting \(receipt, _) ->
          unless (receipt.request.operationId == operation.specification.operationId && receipt.rootId == actualBinding.rootId && receipt.assignmentId == actualBinding.assignmentId) (Left OperationConflict)
        case outcome of
          ModelReturned {} -> unless (actualOperation.specification.kind `elem` [ModelTurn, ModelRepair, ModelSummary]) (Left OperationConflict)
          RichToolReturned {} -> toolOutcome actualOperation
          ToolReturned {} -> toolOutcome actualOperation
          TerminalResult {} -> Left OperationConflict
          _ -> Right ()
  where
    toolOutcome actualOperation = do
      unless (actualOperation.specification.kind == ToolOperation && isNothing accounting) (Left OperationConflict)
      forM_ actualOperation.permission \permission ->
        unless (permission.resolution == Just PermissionApproved) (Left (ExecutionPolicyRefused "tool permission was not approved"))

finishExecution :: (ExecutionEffects es) => ReplayAccess -> StateRevision "execution" -> Aeson.Value -> Eff es (Either ExecutionError Admission)
finishExecution access@(ReplayAccess execution _ _) expected result = catchExecutionWith id $ case payloadReference body of
  Left err -> pure (Left err)
  Right ref -> do
    recorded <- readMetadata (Tx.statement execution.value selectExecution)
    case recorded of
      Just (state, _) | state.phase == Succeeded && state.result == Just ref -> pure (Right AlreadyAccepted)
      Nothing -> pure (Left ExecutionMissing)
      Just (stored, binding) -> do
        let command = if stored.pendingReceipts > 0 then Generated.FinishExecutionPendingReceipts (Generated.FinishExecutionPendingReceiptsData execution (fromInteger (revisionNumber expected)) (fromInteger (revisionNumber (advanceRevision expected)))) else Generated.FinishExecution (Generated.FinishExecutionData execution (fromInteger (revisionNumber expected)) (fromInteger (revisionNumber (advanceRevision expected))))
        committed <- persistChecked
          execution
          command
          ( do
              checkedLockRoot binding.rootId
              checkedAdmissionRoot binding.rootId
              (state, actualBinding) <- checkedExecution execution
              _ <- checkedAccess access actualBinding
              checkedRevision expected state
              unless (isNothing state.activeOperation) (throwE OperationConflict)
              case state.next of
                NeedValidation responseRef -> do
                  response <- checkedPayload access actualBinding "operation-outcome" responseRef
                  snapshot <- checkedPayload access actualBinding "snapshot" state.snapshot
                  case response of
                    ModelReturned assistant _ -> do
                      validated <- except (validateTerminalOutput (snapshot :: ExecutionSnapshot).policy assistant)
                      unless (validated == result) (throwE ExecutionOutputInvalid)
                    _ -> throwE ExecutionOutputInvalid
                _ -> throwE ExecutionOutputInvalid
              pure state
          )
          \state -> do
            actual <- writePayload execution body
            unless (actual == ref) (abort CorruptReplay)
            saveExecution (state & #revision .~ (advanceRevision expected) & #phase .~ Succeeded & #result .~ Just ref & #next .~ WorkFinished)
        case committed of
          Right () -> pure (Right Accepted)
          Left (CheckFailed err) -> pure (Left err)
          Left EventRejected -> do
            stored <- readMetadata (Tx.statement execution.value selectExecution)
            pure case stored of
              Just (state, _) | state.phase == Succeeded && state.result == Just ref -> Right AlreadyAccepted
              _ -> Left ExecutionCommandRefused
  where
    body = envelope "execution-result" result

validateOperation :: OperationSpec -> Either ExecutionError ()
validateOperation specification = do
  unless (all (\text -> not (Text.null text) && Text.length text <= 256) [specification.name, specification.policyDigest, specification.scopeDigest]) (Left OperationConflict)
  unless (maybe True (\n -> n >= 0 && n < 256) specification.responsePosition) (Left OperationConflict)

advance :: ExecutionId -> StateRevision "execution" -> Generated.ExecutionLifecycleCommand
advance execution expected = Generated.AdvanceExecution (Generated.AdvanceExecutionData execution (fromInteger (revisionNumber expected)) (fromInteger (revisionNumber (advanceRevision expected))))

getExecution :: ExecutionId -> Transaction (ExecutionState, ExecutionBinding)
getExecution execution = Tx.statement execution.value lockExecution >>= maybe (abort ExecutionMissing) pure

lockRoot :: Maybe ExecutionRootId -> Transaction ()
lockRoot = mapM_ (\root -> Roots.inspectRootTx root >>= either (abort . ResourceAdmissionRefused . Text.pack . show) (const (pure ())))

validateAdmissionRoot :: Maybe ExecutionRootId -> Transaction ()
validateAdmissionRoot = mapM_ \root -> do
  state <- Roots.inspectRootTx root >>= either (abort . ResourceAdmissionRefused . Text.pack . show) pure
  now <- Tx.statement () currentTime
  either (abort . ResourceAdmissionRefused . Text.pack . show) pure (Resources.checkRoot now state.revision state)

-- Every current lifecycle live edge emits an event. An unexpected future silent
-- edge refuses explicitly; it cannot fabricate an accepted persistence receipt.
persistGuarded :: (ExecutionEffects es) => ExecutionId -> Generated.ExecutionLifecycleCommand -> Transaction (Either ExecutionError ()) -> Transaction () -> Eff es (Either PersistenceFailure ())
persistGuarded execution command precondition action = catchExecutionWith CheckFailed do
  let (catalog, projections) = withLiveExecution (\_ _ -> action)
      handler = DomainCommandHandler {eventStream = executionLifecycleEventStream, classifySilent = \_ -> SilentRejected ExecutionCommandRefused}
  options <- commandOptions
  result <- runDomainCommandWithCatalogProjectionsGuarded options handler (Stream.entityStream executionLifecycleCategory execution.value) command catalog projections (const precondition)
  pure case result of
    Right (PreconditionRefused refusal) -> Left (CheckFailed refusal)
    Right (CatalogCommandOutcome (DomainProjectionCommandApplied DomainCommandOutcome {decision = DomainAccepted _})) -> Right ()
    Right (CatalogCommandOutcome (DomainProjectionCommandApplied DomainCommandOutcome {decision = DomainRejected refusal})) -> Left (CheckFailed refusal)
    Right _ -> Left (CheckFailed ProjectionUnavailable)
    Left CommandRejected -> Left EventRejected
    Left (StoreFailed _) -> Left (CheckFailed ExecutionStorageUnavailable)
    Left (RetryExhausted _ _) -> Left (CheckFailed ExecutionStorageUnavailable)
    Left _ -> Left (CheckFailed ExecutionCommandRefused)

protected :: (ExecutionReadEffects es, ToJSON a, FromJSON a) => Transaction a -> Eff es (Either ExecutionError a)
protected action = catchExecutionWith id do
  queried <- runQuery Nothing executionLookupReadModel (toJSON <$> action)
  pure case queried of
    Left _ -> Left ProjectionUnavailable
    Right raw -> case Aeson.fromJSON raw of
      Aeson.Success value -> Right value
      Aeson.Error _ -> Left CorruptReplay

readMetadata :: (ExecutionReadEffects es, ToJSON a, FromJSON a) => Transaction a -> Eff es a
readMetadata action = protected action >>= either (throwIO . ExecutionAbort) pure

catchExecutionWith :: (ExecutionReadEffects es) => (ExecutionError -> failure) -> Eff es (Either failure a) -> Eff es (Either failure a)
catchExecutionWith wrap action = do
  attempted <- tryError @StoreError (catchSync action handler)
  pure (either (const (Left (wrap ExecutionStorageUnavailable))) id attempted)
  where
    handler exception = case fromException exception of
      Just (ExecutionAbort err) -> pure (Left (wrap err))
      Nothing -> throwIO exception

decode :: (FromJSON a) => Aeson.Value -> Transaction a
decode value = case Aeson.fromJSON value of Aeson.Success result -> pure result; Aeson.Error _ -> abort CorruptReplay

operationKey :: OperationId -> Text
operationKey (OperationId key) = key

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

jsonParam :: (ToJSON a) => E.Params a
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

jsonRow :: (FromJSON a) => D.Row a
jsonRow = D.column (D.nonNullable (D.refine parse D.jsonb))
  where
    parse value = case Aeson.fromJSON value of Aeson.Success result -> Right result; Aeson.Error _ -> Left "corrupt execution metadata"

executionRow :: D.Row (ExecutionState, ExecutionBinding)
executionRow = (,) <$> jsonRow <*> jsonRow

selectExecution, lockExecution :: Statement Text (Maybe (ExecutionState, ExecutionBinding))
selectExecution = preparable "SELECT state,binding FROM shikigami.executions WHERE execution_id=$1" textParam (D.rowMaybe executionRow)
lockExecution = preparable "SELECT state,binding FROM shikigami.executions WHERE execution_id=$1 FOR UPDATE" textParam (D.rowMaybe executionRow)

insertExecution :: Statement (Text, ExecutionState, ExecutionBinding) ()
insertExecution = preparable "INSERT INTO shikigami.executions(execution_id,state,binding) VALUES ($1,$2,$3)" (contrazip3 textParam jsonParam jsonParam) D.noResult

saveExecution :: ExecutionState -> Transaction ()
saveExecution state = Tx.statement (state.executionId.value, state) updateExecution

updateExecution :: Statement (Text, ExecutionState) ()
updateExecution = preparable "UPDATE shikigami.executions SET state=$2,updated_at=now() WHERE execution_id=$1" (contrazip2 textParam jsonParam) D.noResult

insertPayload :: Statement (Text, Text, Text, Int64, Aeson.Value) ()
insertPayload = preparable "INSERT INTO shikigami.execution_payloads(execution_id,payload_id,digest,bytes,body) VALUES ($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING" (contrazip5 textParam textParam textParam (E.param (E.nonNullable E.int8)) jsonParam) D.noResult

selectPayload :: Statement (Text, Text) (Maybe (Text, Integer, Aeson.Value))
selectPayload = preparable "SELECT digest,bytes,body FROM shikigami.execution_payloads WHERE execution_id=$1 AND payload_id=$2" (contrazip2 textParam textParam) (D.rowMaybe ((,,) <$> D.column (D.nonNullable D.text) <*> (toInteger <$> D.column (D.nonNullable D.int8)) <*> D.column (D.nonNullable D.jsonb)))

insertOperation :: Statement (Text, Text, Int64, Operation) ()
insertOperation = preparable "INSERT INTO shikigami.execution_transcript_operations(operation_id,execution_id,position,state) VALUES ($1,$2,$3,$4)" (contrazip4 textParam textParam (E.param (E.nonNullable E.int8)) jsonParam) D.noResult

selectOperation, lockOperation :: Statement Text (Maybe Operation)
selectOperation = preparable "SELECT state FROM shikigami.execution_transcript_operations WHERE operation_id=$1" textParam (D.rowMaybe jsonRow)
lockOperation = preparable "SELECT state FROM shikigami.execution_transcript_operations WHERE operation_id=$1 FOR UPDATE" textParam (D.rowMaybe jsonRow)

updateOperation :: Statement (Text, Operation) ()
updateOperation = preparable "UPDATE shikigami.execution_transcript_operations SET state=$2 WHERE operation_id=$1" (contrazip2 textParam jsonParam) D.noResult

listOperations :: Statement Text [Operation]
listOperations = preparable "SELECT state FROM shikigami.execution_transcript_operations WHERE execution_id=$1 ORDER BY position LIMIT 100" textParam (D.rowList jsonRow)

operationPage :: Statement (Text, Int64, Int64) [Operation]
operationPage = preparable "SELECT state FROM shikigami.execution_transcript_operations WHERE execution_id=$1 AND position>$2 ORDER BY position LIMIT $3" (contrazip3 textParam (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.int8))) (D.rowList jsonRow)

inspectionAttempts :: Statement Text [Attempt.ExecutionAttempt]
inspectionAttempts = preparable "SELECT value FROM shikigami.execution_transcript_operations,LATERAL jsonb_each(dispatches) WHERE operation_id=$1 ORDER BY CASE WHEN value->>'phase' IN ('AwaitingDispatch','Claimed','DispatchStarted','AttemptUncertain') THEN 0 WHEN value->>'phase'='AttemptSuperseded' AND value->'lateReceipt'='null'::jsonb THEN 1 ELSE 2 END,key LIMIT 10" textParam (D.rowList jsonRow)

inspectionAttemptCounts :: Statement Text (Int64, Int64)
inspectionAttemptCounts = preparable "SELECT count(*),count(*) FILTER (WHERE value->>'phase'='AttemptUncertain' OR (value->>'phase'='AttemptSuperseded' AND value->'lateReceipt'='null'::jsonb)) FROM shikigami.execution_transcript_operations,LATERAL jsonb_each(dispatches) WHERE operation_id=$1" textParam (D.singleRow ((,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8)))

currentTime :: Statement () UTCTime
currentTime = preparable "SELECT clock_timestamp()" E.noParams (D.singleRow (D.column (D.nonNullable D.timestamptz)))

-- Attempt metadata lives beside its logical operation, under the existing
-- catalog target/fence. Queries project one value instead of decoding the map.
selectExecutionAttempt, lockExecutionAttempt :: Statement Text (Maybe Attempt.ExecutionAttempt)
selectExecutionAttempt = preparable "SELECT dispatches->$1 FROM shikigami.execution_transcript_operations WHERE dispatches ? $1" textParam (D.rowMaybe jsonRow)
lockExecutionAttempt = preparable "SELECT dispatches->$1 FROM shikigami.execution_transcript_operations WHERE dispatches ? $1 FOR UPDATE" textParam (D.rowMaybe jsonRow)

insertExecutionAttempt :: Statement (Text, Text, Text, Attempt.ExecutionAttempt) ()
insertExecutionAttempt = preparable "UPDATE shikigami.execution_transcript_operations SET dispatches=jsonb_set(dispatches,ARRAY[$1],$4,true) WHERE execution_id=$2 AND operation_id=$3 AND NOT (dispatches ? $1)" (contrazip4 textParam textParam textParam jsonParam) D.noResult

updateExecutionAttempt :: Statement (Text, Text, Attempt.ExecutionAttempt) ()
updateExecutionAttempt = preparable "UPDATE shikigami.execution_transcript_operations SET dispatches=jsonb_set(dispatches,ARRAY[$1],$3,true) WHERE operation_id=$2 AND dispatches ? $1" (contrazip3 textParam textParam jsonParam) D.noResult

executionAttemptInventory :: Statement Text (Int64, Bool)
executionAttemptInventory = preparable "SELECT count(*),COALESCE(bool_or(COALESCE(value->>'phase','invalid') NOT IN ('AttemptAbandoned','AttemptSuperseded')),false) FROM shikigami.execution_transcript_operations,LATERAL jsonb_each(dispatches) WHERE operation_id=$1" textParam (D.singleRow ((,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.bool)))

-- ReadCommitted is the store interpreter's public transaction contract. This
-- nominal lock serializes collision checks across different execution roots.
lockAttemptIdentity :: Statement Text Int
lockAttemptIdentity = preparable "SELECT 1::int4 FROM pg_advisory_xact_lock(hashtextextended($1,0))" textParam (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int4)))

-- The tool interpreter admits no nested model calls. Native tool transports
-- therefore reserve and settle an enforced zero for model token/invoice usage.
zeroModelBilling :: Resources.Quantities
zeroModelBilling = Map.fromList [(Resources.Tokens, zeroAmount), (Resources.CostMicroUsd, zeroAmount)]

toolAttemptRequest :: AttemptId -> OperationId -> ToolBinding -> Resources.AttemptRequest
toolAttemptRequest attempt operation binding = Resources.AttemptRequest attempt operation (Map.fromList ([(Resources.ActiveWork, oneAmount), (Resources.ToolAttempts, oneAmount), (Resources.Tokens, zeroAmount)] <> [(Resources.CostMicroUsd, zeroAmount) | binding.invoiceCost == NoInvoiceCost])) Resources.EnforcedCeiling

toolSettlement :: Resources.AttemptRequest -> Resources.Settlement
toolSettlement request
  | Map.member Resources.CostMicroUsd request.quantities = Resources.KnownUsage zeroModelBilling
  | otherwise = Resources.PartialUsage (Map.singleton Resources.Tokens zeroAmount) [Resources.CostMicroUsd] "tool invoice billing is unavailable"

listOperationAttempts :: Statement Text [Attempt.ExecutionAttempt]
listOperationAttempts = preparable "SELECT value FROM shikigami.execution_transcript_operations,LATERAL jsonb_each(dispatches) WHERE operation_id=$1 ORDER BY key LIMIT 1000" textParam (D.rowList jsonRow)

lastAcceptedModelOperation :: Statement Text (Maybe Operation)
lastAcceptedModelOperation = preparable "SELECT state FROM shikigami.execution_transcript_operations WHERE execution_id=$1 AND state#>>'{specification,kind}' IN ('ModelTurn','ModelRepair') AND state->'outcome' <> 'null'::jsonb ORDER BY position DESC LIMIT 1" textParam (D.rowMaybe jsonRow)

acceptedOperationsAfter :: Statement (Text, Int64) [Operation]
acceptedOperationsAfter = preparable "SELECT state FROM shikigami.execution_transcript_operations WHERE execution_id=$1 AND position>$2 AND state->'outcome' <> 'null'::jsonb ORDER BY position LIMIT 10000" (contrazip2 textParam (E.param (E.nonNullable E.int8))) (D.rowList jsonRow)

-- Only bounded SQL reads/row locks and pure validation belong in preparation.
-- Reservations, settlements and publications remain in the inline writer.
type ExecutionCheck a = ExceptT ExecutionError Transaction a

persistChecked :: (ExecutionEffects es) => ExecutionId -> Generated.ExecutionLifecycleCommand -> ExecutionCheck a -> (a -> Transaction ()) -> Eff es (Either PersistenceFailure ())
persistChecked execution command prepare write =
  persistGuarded execution command (fmap (fmap (const ())) (runExceptT prepare)) do
    -- No mutable cross-callback value: reread the same locked rows. A late
    -- access expiry or integrity failure still rolls back the whole transaction.
    prepared <- runExceptT prepare
    either abort write prepared

checkedStatement :: parameters -> Statement parameters result -> ExecutionCheck result
checkedStatement parameters statement = lift (Tx.statement parameters statement)

checkedExecution :: ExecutionId -> ExecutionCheck (ExecutionState, ExecutionBinding)
checkedExecution execution = checkedStatement execution.value lockExecution >>= maybe (throwE ExecutionMissing) pure

checkedLockRoot :: Maybe ExecutionRootId -> ExecutionCheck ()
checkedLockRoot = mapM_ \root -> do
  result <- lift (Roots.inspectRootTx root)
  either (throwE . ResourceAdmissionRefused . Text.pack . show) (const (pure ())) result

checkedAdmissionRoot :: Maybe ExecutionRootId -> ExecutionCheck ()
checkedAdmissionRoot = mapM_ \root -> do
  result <- lift (Roots.inspectRootTx root)
  state <- either (throwE . ResourceAdmissionRefused . Text.pack . show) pure result
  now <- checkedStatement () currentTime
  either (throwE . ResourceAdmissionRefused . Text.pack . show) pure (Resources.checkRoot now state.revision state)

checkedAccess :: ReplayAccess -> ExecutionBinding -> ExecutionCheck ExecutionId
checkedAccess (ReplayAccess execution identity expires) binding = do
  now <- checkedStatement () currentTime
  unless (identity == binding.identity && now < expires) (throwE ReplayReadRefused)
  pure execution

checkedRevision :: StateRevision "execution" -> ExecutionState -> ExecutionCheck ()
checkedRevision expected state = except do
  unless (revisionNumber expected < toInteger (maxBound :: Int) && state.revision == expected) (Left ExecutionRevisionConflict)

checkedOutcomeIdentity :: ReplayAccess -> ExecutionBinding -> ExecutionCheck ()
checkedOutcomeIdentity (ReplayAccess _ identity _) binding = unless (identity == binding.identity) (throwE ReplayReadRefused)

checkedAttempt :: Attempt.JobReference -> ExecutionCheck Attempt.ExecutionAttempt
checkedAttempt reference = do
  attempt <- checkedStatement (attemptKey reference.attemptId) lockExecutionAttempt >>= maybe (throwE AttemptMissing) pure
  unless (matchesReference reference attempt) (throwE AttemptConflict)
  pure attempt

-- Protected decode/access errors retain their read-side transaction boundary.
checkedPayload :: (FromJSON a) => ReplayAccess -> ExecutionBinding -> Text -> PayloadRef -> ExecutionCheck a
checkedPayload access binding kind reference = lift (readPayload access binding kind reference)

checkedDecode :: (FromJSON a) => Aeson.Value -> ExecutionCheck a
checkedDecode = lift . decode

checkedDispatchPermission :: UTCTime -> Operation -> ExecutionSnapshot -> ExecutionCheck ()
checkedDispatchPermission now operation snapshot = when (operation.specification.kind == ToolOperation) do
  when (operation.specification.name `elem` snapshot.policy.deniedTools) (throwE (ExecutionPolicyRefused "tool is denied by policy"))
  when (operation.specification.name `elem` snapshot.policy.humanTools) do
    permission <- maybe (throwE (ExecutionPolicyRefused "tool requires human permission")) pure operation.permission
    unless (permission.fingerprint == operation.fingerprint && permission.policyDigest == operation.specification.policyDigest && permission.scopeDigest == operation.specification.scopeDigest && permission.resolution == Just PermissionApproved && now < permission.expiresAt) (throwE (ExecutionPolicyRefused "tool permission is unavailable or expired"))

checkedSubmission :: ReplayAccess -> ExecutionBinding -> ExecutionSnapshot -> Operation -> Attempt.AttemptSubmission -> ExecutionCheck ()
checkedSubmission access binding snapshot operation submission =
  case (operation.specification.kind, submission.modelCall) of
    (ToolOperation, Nothing) -> do
      input <- checkedPayload @ToolOperationInput access binding "operation-input" operation.input
      unless (submission.request == toolAttemptRequest submission.request.attemptId operation.specification.operationId input.binding) (throwE AttemptConflict)
      forM_ binding.rootId \rootId -> do
        result <- lift (Roots.inspectRootTx rootId)
        root <- either (throwE . ResourceAdmissionRefused . Text.pack . show) pure result
        case (input.binding.invoiceCost, Map.lookup Resources.CostMicroUsd root.envelope.limits) of
          (_, Nothing) -> throwE (ResourceAdmissionRefused "tool invoice usage is not admitted")
          (UnreportedInvoiceCost, Just (Resources.Limited _)) -> throwE (ResourceAdmissionRefused "tool invoice ceiling is unsupported")
          _ -> pure ()
    (kind, Just prepared)
      | kind `elem` [ModelTurn, ModelRepair, ModelSummary] ->
          unless (Calls.callLimitsWithin prepared.limits (Calls.callLimitsFor snapshot.selection snapshot.sanctionedProfile)) (throwE (ExecutionPolicyRefused "prepared call limits exceed the pinned profile"))
    _ -> throwE AttemptConflict
