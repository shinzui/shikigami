{-# LANGUAGE DataKinds #-}

-- | Runtime source proofs have no wire decoder. Model input cannot construct
-- the replay permit or native Workflow context that produces these values.
module Shikigami.Objective.Origin
  ( OriginAuthority,
    executionAuthority,
    conversationAuthority,
    flowAuthority,
    authorityOrigin,
    verifyCreationOrigin,
    lookupCreatedInScope,
  )
where

import Data.Char (isAlphaNum, isAscii)
import Data.Text qualified as Text
import Effectful (Eff, (:>))
import Keiro.Workflow (Workflow, WorkflowId (..), WorkflowName (..), currentRunGeneration, currentWorkflow)
import Kioku.Id (idText)
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.App (AppEffects)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.AssignmentKey (conversationAssignmentIdFor)
import Shikigami.Execution.Identity (OperationId, operationIdWithPrefix)
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript qualified as Execution
import Shikigami.Objective.Capability qualified as Capability
import Shikigami.Objective.Conversation (TurnAdmission (..))
import Shikigami.Objective.Types
import Shikigami.Prelude

-- Keiro retains workflow/generation coordinates. The Flow constructor is private
-- and obtainable only from that owning effect, with a checked static label.
-- Execution constructors retain the owning store's opaque replay authority.
data OriginAuthority
  = ExecutionAuthority !Execution.ReplayAccess !AgentIdentity !CreationOrigin
  | ConversationAuthority !Execution.ReplayAccess !AgentIdentity !CreationOrigin
  | FlowAuthority !AgentIdentity !WorkflowName !CreationOrigin

authorityOrigin :: OriginAuthority -> CreationOrigin
authorityOrigin = \case
  ExecutionAuthority _ _ origin -> origin
  ConversationAuthority _ _ origin -> origin
  FlowAuthority _ _ origin -> origin

executionAuthority :: Execution.ReplayAccess -> OperationId -> Eff AppEffects (Either ObjectiveError OriginAuthority)
executionAuthority access operation = do
  source <- acceptedOperation access operation
  pure do
    snapshot <- source
    pure (ExecutionAuthority access snapshot.identity (ExecutionOrigin (runReference snapshot.runId.unWorkflowId) snapshot.executionId operation))

conversationAuthority :: Capability.ObjectiveHost -> Execution.ReplayAccess -> ConversationRef -> TurnReference -> OperationId -> Eff AppEffects (Either ObjectiveError OriginAuthority)
conversationAuthority host access conversation turn operation = do
  source <- acceptedOperation access operation
  case source of
    Left err -> pure (Left err)
    Right snapshot -> do
      admitted <- Capability.readConversationTurn host (runReference snapshot.runId.unWorkflowId) turn conversation
      pure do
        recorded <- admitted >>= maybe (Left ObjectiveDenied) Right
        unless (recorded.participant == snapshot.identity && recorded.sessionId == idText snapshot.sessionId) (Left ObjectiveDenied)
        -- Conversation records the addressed message under this stable user
        -- turn key; the execution owner derives its assignment from the same
        -- workflow/message pair. Another turn in this session is insufficient.
        message <- maybe (Left ObjectiveDenied) Right (Text.stripPrefix "danwa:user:" (turnReferenceText turn))
        unless (not (Text.null message) && snapshot.selection.assignmentId == conversationAssignmentIdFor snapshot.runId.unWorkflowId message) (Left ObjectiveDenied)
        pure (ConversationAuthority access snapshot.identity (ConversationOrigin conversation turn (runReference snapshot.runId.unWorkflowId) operation))

flowAuthority :: (Workflow :> es) => AgentIdentity -> OriginLabel -> Eff es (Either ObjectiveError OriginAuthority)
flowAuthority identity label = do
  (WorkflowName name, workflow@(WorkflowId key)) <- currentWorkflow
  generation <- currentRunGeneration
  pure do
    _ <- either (const (Left ObjectiveDenied)) Right (identityText identity)
    let raw = originLabelText label
    unless (not (Text.null raw) && Text.length raw <= 100 && Text.all (\c -> isAscii c && (isAlphaNum c || c `elem` ['_', '-'])) raw && maybe False (isAlphaNum . fst) (Text.uncons raw)) (Left (ObjectiveInvalid "origin requires a static workflow label"))
    version <- either (const (Left ObjectiveDenied)) Right (parseRevision (toInteger generation))
    let operation = flowOperation name key (toInteger generation) label
    pure (FlowAuthority identity (WorkflowName name) (FlowOrigin workflow version label operation))

verifyCreationOrigin :: OriginAuthority -> AccessPrincipal -> CreationOrigin -> Eff AppEffects (Either ObjectiveError ())
verifyCreationOrigin authority actor candidate
  | candidate /= authorityOrigin authority = pure (Left ObjectiveDenied)
  | otherwise = case authority of
      FlowAuthority identity _ _ -> pure (requireActor identity)
      ExecutionAuthority access identity origin -> validate access identity origin
      ConversationAuthority access identity origin -> validate access identity origin
  where
    requireActor identity = unless (actor == RecordedAgent identity) (Left ObjectiveDenied)
    validate access identity origin = case requireActor identity of
      Left err -> pure (Left err)
      Right () -> do
        source <- acceptedOperation access origin.operationId
        pure do
          snapshot <- source
          unless (snapshot.identity == identity && runReference snapshot.runId.unWorkflowId == origin.runId) (Left ObjectiveDenied)
          case origin of
            ExecutionOrigin {executionId} -> unless (executionId == snapshot.executionId) (Left ObjectiveDenied)
            ConversationOrigin {} -> pure () -- its retained turn was checked by the factory
            FlowOrigin {} -> Left ObjectiveDenied

-- | A later operation in the same frozen creation scope can address a goal
-- created by an earlier operation. Ownership alone never widens that scope.
lookupCreatedInScope :: OriginAuthority -> Capability.ObjectiveHost -> ObjectiveId -> Eff AppEffects (Either ObjectiveError (Maybe Receipt))
lookupCreatedInScope authority host objective = do
  let actor = case authority of
        ExecutionAuthority _ identity _ -> RecordedAgent identity
        ConversationAuthority _ identity _ -> RecordedAgent identity
        FlowAuthority identity _ _ -> RecordedAgent identity
      current = authorityOrigin authority
  verified <- verifyCreationOrigin authority actor current
  case verified of
    Left err -> pure (Left err)
    Right () -> Capability.lookupCreatedInScope host actor objective current within
  where
    within historical = case (authority, authorityOrigin authority, historical) of
      (ExecutionAuthority {}, ExecutionOrigin run execution _, ExecutionOrigin oldRun oldExecution _) -> run == oldRun && execution == oldExecution
      (ConversationAuthority {}, ConversationOrigin conversation turn run _, ConversationOrigin oldConversation oldTurn oldRun _) -> conversation == oldConversation && turn == oldTurn && run == oldRun
      (FlowAuthority _ (WorkflowName name) _, FlowOrigin workflow generation _ _, FlowOrigin oldWorkflow oldGeneration label operation) -> workflow == oldWorkflow && generation == oldGeneration && operation == flowOperation name workflow.unWorkflowId (revisionNumber generation) label
      _ -> False

flowOperation :: Text -> Text -> Integer -> OriginLabel -> OperationId
flowOperation name workflow generation label = operationIdWithPrefix ('o' :| "bjective-flow-create:") (versionedDigest "shikigami.objective-flow-create/1" (toJSON (name, workflow, generation, label)))

acceptedOperation :: Execution.ReplayAccess -> OperationId -> Eff AppEffects (Either ObjectiveError Execution.ExecutionSnapshot)
acceptedOperation access operation = do
  loaded <- Execution.loadExecution access
  recorded <- Execution.inspectOperation operation
  pure do
    (snapshot, state) <- either (Left . sourceError) Right loaded
    accepted <- either (Left . sourceError) Right recorded >>= maybe (Left ObjectiveDenied) Right
    unless (state.phase == Execution.Active && state.activeOperation == Just operation && accepted.executionId == snapshot.executionId && accepted.specification.operationId == operation && accepted.specification.kind == Execution.ToolOperation && isNothing accepted.outcome) (Left ObjectiveDenied)
    pure snapshot

sourceError :: Execution.ExecutionError -> ObjectiveError
sourceError = \case
  Execution.ExecutionStorageUnavailable -> ObjectiveUnavailable
  Execution.CorruptReplay -> ObjectiveUnavailable
  _ -> ObjectiveDenied
