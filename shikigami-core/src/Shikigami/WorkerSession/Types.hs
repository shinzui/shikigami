-- | Continuing-session state is distinct from Kioku memory and Danwa epochs.
-- Objective identifiers are consumer references to the separately owned store.
module Shikigami.WorkerSession.Types where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (nub)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID
import Keiro.Workflow.Awakeable (AwakeableId)
import Keiro.Workflow.Types (mkWorkflowId)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Delegate.Context (DelegateCtx (..), assertMayDelegate, checkCycle, checkDepth)
import Shikigami.Agent.Delegate.Depth (depthInt)
import Shikigami.Agent.Name (AgentName (..), agentNameText)
import Shikigami.Agent.Principal (AgentIdentity (..), identityText)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId)
import Shikigami.Execution.Request (ExecutionRequest)
import Shikigami.Execution.Transcript (ExecutionId, PayloadRef)
import Shikigami.Id.Name (nameBytes)
import Shikigami.Prelude

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
  { format :: !Int,
    scope :: !SessionScope,
    objective :: !ObjectiveRef,
    delegator :: !AgentDecl,
    context :: !DelegateCtx,
    worker :: !AgentName,
    identity :: !AgentIdentity,
    maximumAssignments :: !Int,
    mailboxLimit :: !Int
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

data SessionPhase = Idle | Active | Parked | Unresolved | Failed | Cancelled
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data SessionState = SessionState
  { format :: !Int,
    sessionId :: !WorkerSessionId,
    revision :: !Integer,
    phase :: !SessionPhase,
    owner :: !AgentIdentity,
    epoch :: !Integer,
    activeAssignment :: !(Maybe AssignmentId),
    nextSequence :: !Integer,
    eventCursor :: !Integer,
    consumedCursor :: !Integer,
    checkpointIntent :: !(Maybe OperationId),
    wake :: !(Maybe PayloadRef)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON SessionState where
  parseJSON = Aeson.withObject "SessionState" \fields -> do
    state <- SessionState <$> fields Aeson..: "format" <*> fields Aeson..: "sessionId" <*> fields Aeson..: "revision" <*> fields Aeson..: "phase" <*> fields Aeson..: "owner" <*> fields Aeson..: "epoch" <*> fields Aeson..: "activeAssignment" <*> fields Aeson..: "nextSequence" <*> fields Aeson..: "eventCursor" <*> fields Aeson..: "consumedCursor" <*> fields Aeson..:? "checkpointIntent" <*> fields Aeson..:? "wake"
    unless (state.format == 1 && all (>= 0) [state.revision, state.epoch, state.nextSequence, state.eventCursor, state.consumedCursor] && state.consumedCursor <= state.eventCursor && state.nextSequence <= 10000) (fail "unsupported worker session state")
    pure state

data SessionWake = SessionWake {token :: !AwakeableId, generation :: !Int}
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show SessionWake where show _ = "SessionWake <protected>"

data MessageKind = FollowUp | Interrupt !AssignmentId
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Instruction = Instruction
  { format :: !Int,
    kind :: !MessageKind,
    text :: !Text,
    objectiveRevision :: !Integer,
    assignmentRevision :: !Integer,
    criteriaRevision :: !Integer,
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
  { format :: !Int,
    sessionId :: !WorkerSessionId,
    sequence :: !Integer,
    assignmentId :: !AssignmentId,
    operationId :: !OperationId,
    fingerprint :: !Text,
    kind :: !MessageKind,
    input :: !PayloadRef,
    assignmentRevision :: !Integer,
    epoch :: !Integer,
    phase :: !AssignmentPhase,
    childWorkflowId :: !(Maybe Text),
    executionId :: !(Maybe ExecutionId),
    context :: !(Maybe PayloadRef)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON MessageReceipt where
  parseJSON = Aeson.withObject "MessageReceipt" \fields -> do
    context <- fields Aeson..:? "context"
    message <- Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object (KeyMap.insert "context" (toJSON (context :: Maybe PayloadRef)) fields))
    unless (message.format == 1 && message.sequence >= 0 && message.sequence < 10000 && message.assignmentRevision >= 0 && message.epoch >= 0 && message.assignmentId == assignmentIdFor message.sessionId message.sequence message.operationId) (fail "unsupported assignment receipt identity")
    _ <- traverse (either (fail . show) pure . mkWorkflowId) message.childWorkflowId
    unless (if message.phase == Queued then isNothing message.childWorkflowId else isJust message.childWorkflowId) (fail "assignment child mapping is missing or premature")
    pure message

data RetainedFinding = RetainedFinding {receipt :: !ResultReceipt, output :: !(Maybe Aeson.Value)}
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show RetainedFinding where show _ = "RetainedFinding <protected>"

data ResultDisposition = AssignmentSucceeded | AssignmentFailed | AssignmentCancelled
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AssignmentResult = AssignmentResult
  { format :: !Int,
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
  { format :: !Int,
    sessionId :: !WorkerSessionId,
    assignmentId :: !AssignmentId,
    operationId :: !OperationId,
    fingerprint :: !Text,
    disposition :: !ResultDisposition,
    output :: !PayloadRef,
    cursor :: !Integer
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data SessionEvent = MessageAccepted !MessageReceipt | AssignmentStarted !MessageReceipt | ResultAvailable !ResultReceipt | AssignmentStatusChanged !AssignmentId !AssignmentPhase
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data EventReceipt = EventReceipt {cursor :: !Integer, event :: !SessionEvent}
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

assignmentIdFor :: WorkerSessionId -> Integer -> OperationId -> AssignmentId
assignmentIdFor session sequence operation = AssignmentId (UUID.toText (UUID.generateNamed UUID.namespaceURL (nameBytes (versionedDigest "shikigami.worker-assignment/1" (toJSON (session, sequence, operation))))))

validateAdmission :: SessionAdmission -> Either SessionError ()
validateAdmission admission = do
  unless (admission.format == 1 && admission.maximumAssignments >= 1 && admission.maximumAssignments <= 1000 && admission.mailboxLimit >= 1 && admission.mailboxLimit <= 128) (Left (SessionInputRefused "invalid session bounds"))
  unless (all validKey [admission.scope.parent, admission.scope.workerKey, admission.objective.provider, admission.objective.key, agentNameText admission.worker, admission.delegator.name]) (Left (SessionInputRefused "invalid session scope or objective reference"))
  unless (isJust admission.context.executionRootId && isJust admission.context.sessionId) (Left (SessionInputRefused "continuing work requires an admitted root and parent memory session"))
  unless (length admission.context.lineage == depthInt admission.context.depth + 1 && length (nub admission.context.lineage) == length admission.context.lineage && take 1 (reverse admission.context.lineage) == [AgentName admission.delegator.name]) (Left (SessionInputRefused "delegation lineage does not match its parent and depth"))
  _ <- either (const (Left SessionOwnerRefused)) Right (identityText admission.context.identity)
  _ <- either (const (Left SessionOwnerRefused)) Right (identityText admission.identity)
  either (const (Left SessionOwnerRefused)) Right (assertMayDelegate admission.delegator (agentNameText admission.worker))
  either (const (Left SessionOwnerRefused)) Right (checkCycle admission.context (agentNameText admission.worker))
  void (either (const (Left SessionOwnerRefused)) Right (checkDepth admission.context))
  where
    validKey value = not (Text.null value) && Text.length value <= 256

validateInstruction :: Instruction -> Either SessionError ()
validateInstruction instruction =
  unless (instruction.format == 1 && not (Text.null (Text.strip instruction.text)) && all (>= 0) [instruction.objectiveRevision, instruction.assignmentRevision, instruction.criteriaRevision]) (Left (SessionInputRefused "invalid instruction or objective/assignment revision"))
