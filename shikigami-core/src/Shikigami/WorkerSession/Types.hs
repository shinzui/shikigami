{-# LANGUAGE DataKinds #-}

-- | Continuing-session state is distinct from Kioku memory and Danwa epochs.
-- Objective identifiers are consumer references to the separately owned store.
module Shikigami.WorkerSession.Types where

import Data.Aeson ((.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (nub)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID
import Keiki.Shape (CanonicalTypeName (..))
import Keiro.Workflow.Awakeable (AwakeableId)
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName (..), mkWorkflowId)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Delegate.Context (DelegateCtx (..), assertMayDelegate, checkCycle, checkDepth)
import Shikigami.Agent.Delegate.Depth (depthInt)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.Principal (AgentIdentity (..), identityText)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Decision.ModelAlias (ModelAlias)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId)
import Shikigami.Execution.Request (ExecutionRequest)
import Shikigami.Execution.Transcript (ExecutionId, PayloadRef)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Prelude hiding ((.=))
import Shikigami.StateRevision
import Shikigami.WorkerSession.Input
import Shikigami.WorkerSession.Position

newtype WorkerSessionId = WorkerSessionId {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

newtype AssignmentId = AssignmentId {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

data ObjectiveRef = ObjectiveRef {provider :: !Text, key :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data SessionScope = SessionScope {parent :: !Text, workerKey :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- Frozen delegation authority is protected input, not an executable grant.
-- The runtime still checks current lifecycle, root and exact external actions.
data SessionAdmission = SessionAdmission
  { format :: !(FormatVersion "session-admission"),
    scope :: !SessionScope,
    objective :: !ObjectiveRef,
    delegator :: !AgentDecl,
    context :: !DelegateCtx,
    worker :: !AgentName,
    identity :: !AgentIdentity,
    maximumAssignments :: !MaximumAssignments,
    mailboxLimit :: !MailboxLimit
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance Show SessionAdmission where show _ = "SessionAdmission <protected>"

instance FromJSON SessionAdmission where
  parseJSON value = do
    admission <- Aeson.genericParseJSON Aeson.defaultOptions value
    either (fail . show) (const (pure admission)) (validateAdmission admission)

data SessionBinding = SessionBinding
  { sessionId :: !WorkerSessionId,
    scopeDigest :: !Text,
    scope :: !SessionScope,
    objective :: !ObjectiveRef,
    parentIdentity :: !AgentIdentity,
    initialWorker :: !AgentIdentity,
    rootId :: !ExecutionRootId,
    admission :: !PayloadRef
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data SessionPhase = Idle | Active | Parked | Unresolved | Transferring | Failed | Cancelled
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data SessionState = SessionState
  { format :: !(FormatVersion "session-state"),
    sessionId :: !WorkerSessionId,
    revision :: !(StateRevision "worker-session"),
    phase :: !SessionPhase,
    owner :: !AgentIdentity,
    epoch :: !(StateRevision "worker-owner"),
    activeAssignment :: !(Maybe AssignmentId),
    nextSequence :: !(StateRevision "worker-message"),
    eventCursor :: !(StateRevision "worker-event"),
    consumedCursor :: !(StateRevision "worker-event"),
    checkpointIntent :: !(Maybe OperationId),
    wake :: !(Maybe PayloadRef),
    worker :: !(Maybe AgentName),
    handoff :: !(Maybe HandoffProgress),
    listeners :: ![PayloadRef]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON SessionState where
  parseJSON = Aeson.withObject "SessionState" \fields -> do
    state <- SessionState <$> fields .: "format" <*> fields .: "sessionId" <*> fields .: "revision" <*> fields .: "phase" <*> fields .: "owner" <*> fields .: "epoch" <*> fields .: "activeAssignment" <*> fields .: "nextSequence" <*> fields .: "eventCursor" <*> fields .: "consumedCursor" <*> fields .:? "checkpointIntent" <*> fields .:? "wake" <*> fields .:? "worker" <*> fields .:? "handoff" <*> (fields .:? "listeners" .!= [])
    unless (state.format == V1 && state.consumedCursor <= state.eventCursor && revisionNumber state.eventCursor <= 100000 && revisionNumber state.nextSequence <= 10000 && length state.listeners <= 32) (fail "unsupported worker session state")
    pure state

data SessionListener = SessionListener
  { token :: !AwakeableId,
    generation :: !Int,
    ownerName :: !WorkflowName,
    ownerId :: !WorkflowId,
    after :: !(StateRevision "worker-event")
  }
  deriving stock (Eq, Generic)

-- Runtime-owned identities stay native through the owner checks. The retained
-- JSON is the existing text adapter, including historical spellings.
instance ToJSON SessionListener where
  toJSON SessionListener {token, generation, ownerName, ownerId, after} =
    Aeson.object
      [ "token" .= token,
        "generation" .= generation,
        "ownerName" .= ownerName.unWorkflowName,
        "ownerId" .= ownerId.unWorkflowId,
        "after" .= after
      ]

instance FromJSON SessionListener where
  parseJSON = Aeson.withObject "SessionListener" \fields ->
    SessionListener
      <$> fields .: "token"
      <*> fields .: "generation"
      <*> (WorkflowName <$> fields .: "ownerName")
      <*> (WorkflowId <$> fields .: "ownerId")
      <*> fields .: "after"

instance Show SessionListener where show _ = "SessionListener <protected>"

data SessionWake = SessionWake {token :: !AwakeableId, generation :: !Int}
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show SessionWake where show _ = "SessionWake <protected>"

data HandoffStage = TransferRequested | TransferReconciling | TransferUnresolved | TransferFenced | TransferEstablished
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data HandoffProgress = HandoffProgress
  { operationId :: !OperationId,
    intent :: !PayloadRef,
    stage :: !HandoffStage,
    fence :: !(Maybe PayloadRef),
    checkpoint :: !(Maybe PayloadRef)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data MessageKind = FollowUp | Interrupt !AssignmentId
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Instruction = Instruction
  { format :: !(FormatVersion "worker-instruction"),
    kind :: !MessageKind,
    text :: !InstructionText,
    objectiveRevision :: !(StateRevision "objective"),
    assignmentRevision :: !(StateRevision "objective-assignment"),
    criteriaRevision :: !(StateRevision "objective-criteria"),
    selection :: !(Maybe ExecutionRequest)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance FromJSON Instruction where
  parseJSON value = do
    instruction <- Aeson.genericParseJSON Aeson.defaultOptions value
    either (fail . show) (const (pure instruction)) (validateInstruction instruction)

instance Show Instruction where show _ = "Instruction <protected>"

data AssignmentPhase = Queued | Running | AssignmentParked | AssignmentUnresolved | AssignmentFinished
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data MessageReceipt = MessageReceipt
  { format :: !(FormatVersion "worker-message"),
    sessionId :: !WorkerSessionId,
    sequence :: !(StateRevision "worker-message"),
    assignmentId :: !AssignmentId,
    operationId :: !OperationId,
    fingerprint :: !Text,
    kind :: !MessageKind,
    input :: !PayloadRef,
    assignmentRevision :: !(StateRevision "objective-assignment"),
    epoch :: !(StateRevision "worker-owner"),
    phase :: !AssignmentPhase,
    childWorkflowId :: !(Maybe Text),
    executionId :: !(Maybe ExecutionId),
    context :: !(Maybe PayloadRef),
    permittedAliases :: !(Maybe [ModelAlias])
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON MessageReceipt where
  parseJSON = Aeson.withObject "MessageReceipt" \fields -> do
    context <- fields .:? "context"
    aliases <- fields .:? "permittedAliases"
    message <- Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object (KeyMap.insert "permittedAliases" (toJSON (aliases :: Maybe [ModelAlias])) (KeyMap.insert "context" (toJSON (context :: Maybe PayloadRef)) fields)))
    unless (message.format == V1 && revisionNumber message.sequence < 10000 && message.assignmentId == assignmentIdFor message.sessionId message.sequence message.operationId) (fail "unsupported assignment receipt identity")
    _ <- traverse (either (fail . show) pure . mkWorkflowId) message.childWorkflowId
    unless (if message.phase == Queued then isNothing message.childWorkflowId else isJust message.childWorkflowId) (fail "assignment child mapping is missing or premature")
    pure message

data RetainedFinding = RetainedFinding {receipt :: !ResultReceipt, output :: !(Maybe Aeson.Value)}
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show RetainedFinding where show _ = "RetainedFinding <protected>"

data SessionInspection = SessionInspection
  { state :: !SessionState,
    binding :: !SessionBinding,
    messages :: ![MessageReceipt],
    active :: !(Maybe MessageReceipt),
    results :: ![ResultReceipt],
    nextCursor :: !MessagePosition,
    truncated :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ResultDisposition = AssignmentSucceeded | AssignmentFailed | AssignmentCancelled
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AssignmentResult = AssignmentResult
  { format :: !(FormatVersion "assignment-result"),
    assignmentId :: !AssignmentId,
    disposition :: !ResultDisposition,
    executionId :: !(Maybe ExecutionId),
    output :: !Aeson.Value,
    artifacts :: ![Text]
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show AssignmentResult where show _ = "AssignmentResult <protected>"

data ResultReceipt = ResultReceipt
  { format :: !(FormatVersion "worker-result"),
    sessionId :: !WorkerSessionId,
    assignmentId :: !AssignmentId,
    operationId :: !OperationId,
    fingerprint :: !Text,
    disposition :: !ResultDisposition,
    output :: !PayloadRef,
    cursor :: !(StateRevision "worker-event")
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data SessionEvent = MessageAccepted !MessageReceipt | AssignmentStarted !MessageReceipt | ResultAvailable !ResultReceipt | AssignmentStatusChanged !AssignmentId !AssignmentPhase | TransferStatusChanged !OperationId !HandoffStage | SessionClosedEvent !SessionPhase
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data EventReceipt = EventReceipt {cursor :: !(StateRevision "worker-event"), event :: !SessionEvent}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data SessionError
  = SessionMissing
  | SessionRevisionConflict
  | SessionBindingConflict
  | SessionOwnerRefused
  | SessionClosed
  | SessionMailboxFull
  | SessionLimitExceeded
  | MessageConflict
  | AssignmentMissing
  | AssignmentConflict
  | AssignmentStillActive
  | InterruptTargetChanged
  | SessionInputRefused !Text
  | SessionPayloadTooLarge
  | SessionStorageUnavailable
  | SessionProjectionUnavailable
  | SessionCommandRefused
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

scopeDigestFor :: SessionAdmission -> Text
scopeDigestFor admission = versionedDigest "shikigami.worker-session-scope/1" (toJSON (admission.scope, admission.context.identity, admission.identity))

-- Deterministic session/assignment correlation coordinates are UUIDv5 values;
-- they are not allocated directory or Kioku entity identifiers.
sessionIdFor :: SessionAdmission -> WorkerSessionId
sessionIdFor = WorkerSessionId . UUID.toText . UUID.generateNamed UUID.namespaceURL . nameBytes . ("shikigami.worker-session:" <>) . scopeDigestFor

assignmentIdFor :: WorkerSessionId -> StateRevision "worker-message" -> OperationId -> AssignmentId
assignmentIdFor session sequence operation = AssignmentId (UUID.toText (UUID.generateNamed UUID.namespaceURL (nameBytes (versionedDigest "shikigami.worker-assignment/1" (toJSON (session, sequence, operation))))))

validateAdmission :: SessionAdmission -> Either SessionError ()
validateAdmission admission = do
  unless (admission.identity /= admission.context.identity) (Left SessionOwnerRefused)
  unless (admission.format == V1) (Left (SessionInputRefused "invalid session bounds"))
  unless (all validKey [admission.scope.parent, admission.scope.workerKey, admission.objective.provider, admission.objective.key, agentNameText admission.worker, agentNameText admission.delegator.name]) (Left (SessionInputRefused "invalid session scope or objective reference"))
  unless (isJust admission.context.executionRootId && isJust admission.context.sessionId) (Left (SessionInputRefused "continuing work requires an admitted root and parent memory session"))
  unless (length admission.context.lineage == depthInt admission.context.depth + 1 && length (nub admission.context.lineage) == length admission.context.lineage && take 1 (reverse admission.context.lineage) == [admission.delegator.name]) (Left (SessionInputRefused "delegation lineage does not match its parent and depth"))
  _ <- either (const (Left SessionOwnerRefused)) Right (identityText admission.context.identity)
  _ <- either (const (Left SessionOwnerRefused)) Right (identityText admission.identity)
  either (const (Left SessionOwnerRefused)) Right (assertMayDelegate admission.delegator admission.worker)
  either (const (Left SessionOwnerRefused)) Right (checkCycle admission.context admission.worker)
  void (either (const (Left SessionOwnerRefused)) Right (checkDepth admission.context))
  where
    validKey value = not (Text.null value) && Text.length value <= 256

validateInstruction :: Instruction -> Either SessionError ()
validateInstruction instruction =
  unless (instruction.format == V1) (Left (SessionInputRefused "invalid instruction or objective/assignment revision"))

instance CanonicalTypeName WorkerSessionId where
  canonicalTypeName _ = "shikigami.WorkerSessionId.v1"
