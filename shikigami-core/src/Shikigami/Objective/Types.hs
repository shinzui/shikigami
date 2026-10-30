-- | Durable values are identities and evidence references, never authority.
-- Authentication and fresh action decisions belong to Objective.Capability.
module Shikigami.Objective.Types where

import Data.Aeson ((.!=), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (nub)
import Data.Text qualified as Text
import Keiki.Shape (CanonicalTypeName (..))
import Shikigami.Agent.Principal (AgentIdentity, identityText, mkAgentPrincipal)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId)
import Shikigami.Prelude
import Shikigami.WorkerSession.Types (AssignmentId, ResultReceipt, WorkerSessionId)

newtype ObjectiveId = ObjectiveId {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

newtype ObjectiveAssignmentId = ObjectiveAssignmentId {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AccessPrincipal = VerifiedCaller !Text | RecordedAgent !AgentIdentity | LocalOperator !Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Role = Owner | Coordinator | Worker | Reader | Completer
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Member = Member {principal :: !AccessPrincipal, roles :: ![Role]}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Status = Open | Blocked | Completed | Cancelled
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AssignmentState = Pending | Working | Done | Withdrawn
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CriterionKind = Automatic | HumanVerifiable
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Criterion = Criterion {key :: !Text, description :: !Text, kind :: !CriterionKind, journeyRequired :: !Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ExternalReference = ReiIntention !Text | ExecPlan !Text | ProtocolTask !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Supplied by trusted adapters after checking the owning records. No public
-- command or creation document includes this field.
data CreationOrigin
  = ExecutionOrigin {runId :: !Text, executionId :: !Text, operationId :: !OperationId}
  | ConversationOrigin {conversationId :: !Text, turnId :: !Text, runId :: !Text, operationId :: !OperationId}
  | FlowOrigin {workflowId :: !Text, generation :: !Integer, label :: !Text, operationId :: !OperationId}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AssignmentDraft = AssignmentDraft
  { assignmentId :: !ObjectiveAssignmentId,
    instructions :: !Text,
    dependencies :: ![ObjectiveAssignmentId],
    owner :: !AgentIdentity,
    state :: !AssignmentState,
    sessionId :: !(Maybe WorkerSessionId),
    rootId :: !(Maybe ExecutionRootId),
    cutoff :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Assignment = Assignment
  { definition :: !AssignmentDraft,
    revision :: !Integer,
    instructionsRevision :: !Integer,
    ownerEpoch :: !Integer,
    acceptedResults :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Immutable sources are resolved by their owner, not by model-authored
-- pass/fail flags. Worker results are additionally checked in the SQL boundary.
data ResultReference
  = WorkerResult {receipt :: !ResultReceipt, artifact :: !Text}
  | RetainedResult {runId :: !Text, executionId :: !Text, digest :: !Text, artifact :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data EvidenceInput
  = ResultEvidence {key :: !Text, criterion :: !Text, result :: !ResultReference, journey :: !Bool}
  | Attestation {key :: !Text, criterion :: !Text, artifact :: !Text, statement :: !Text, journey :: !Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CheckDisposition = CheckPassed | CheckFailed | ResultObserved
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A verifier-owned interpretation of retained output. Ordinary child success
-- is ResultObserved; only a verifier may attest a criterion or a user journey.
data EvidenceVerification = EvidenceVerification
  { disposition :: !CheckDisposition,
    criterion :: !(Maybe Text),
    journey :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Evidence = Evidence
  { input :: !EvidenceInput,
    verification :: !EvidenceVerification,
    assignmentId :: !ObjectiveAssignmentId,
    assignmentDigest :: !Text,
    recordedBy :: !AccessPrincipal,
    revision :: !Integer,
    instructionsRevision :: !Integer,
    criteriaRevision :: !Integer
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CompletionProposal = CompletionProposal
  { objectiveRevision :: !Integer,
    instructionsRevision :: !Integer,
    criteriaRevision :: !Integer,
    artifacts :: ![Text],
    checks :: ![Text],
    limitations :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ObjectiveAcceptance = ObjectiveAcceptance
  { objectiveId :: !ObjectiveId,
    proposal :: !CompletionProposal,
    proposer :: !AccessPrincipal,
    approvingAuthority :: !AccessPrincipal
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data UnresolvedOperation = UnresolvedOperation {assignmentId :: !ObjectiveAssignmentId, owner :: !CreationOrigin, operationId :: !OperationId}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Objective = Objective
  { objectiveId :: !ObjectiveId,
    owner :: !AccessPrincipal,
    members :: ![Member],
    title :: !Text,
    goal :: !Text,
    instructions :: !Text,
    revision :: !Integer,
    instructionsRevision :: !Integer,
    criteriaRevision :: !Integer,
    criteria :: ![Criterion],
    status :: !Status,
    assignments :: ![Assignment],
    evidence :: ![Evidence],
    decisions :: ![Text],
    assumptions :: ![Text],
    nextActions :: ![Text],
    external :: ![ExternalReference],
    unresolved :: ![UnresolvedOperation],
    proposed :: !(Maybe (CompletionProposal, AccessPrincipal)),
    acceptance :: !(Maybe ObjectiveAcceptance)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show Objective where show _ = "Objective <protected>"

data CreateRequest = CreateRequest {title :: !Text, goal :: !Text, instructions :: !Text, criteria :: ![Criterion], external :: ![ExternalReference]}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Receipt = Receipt
  { objectiveId :: !ObjectiveId,
    operationId :: !OperationId,
    fingerprint :: !Text,
    revision :: !Integer,
    payloadDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ObjectiveError
  = ObjectiveMissing
  | ObjectiveDenied
  | ObjectiveConflict
  | ObjectiveInvalid !Text
  | ObjectiveInvalidEvidence
  | ObjectiveUnavailable
  | ObjectiveUnresolved
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data OperatorPolicy = OwnObjectivesOnly | AdministerAll
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ObjectiveSettings = ObjectiveSettings
  { enabled :: !Bool,
    operator :: !(Maybe Text),
    administration :: !OperatorPolicy,
    agentCreation :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON ObjectiveSettings where
  parseJSON = Aeson.withObject "objective settings" \o -> do
    unless (all (`elem` ["enabled", "operator", "administration", "agentCreation"]) (KeyMap.keys o)) (fail "unknown objective setting")
    settings <- ObjectiveSettings <$> o .:? "enabled" .!= False <*> o .:? "operator" <*> o .:? "administration" .!= OwnObjectivesOnly <*> o .:? "agentCreation" .!= []
    either (fail . Text.unpack) (const (pure settings)) (validateSettings settings)

defaultObjectiveSettings :: ObjectiveSettings
defaultObjectiveSettings = ObjectiveSettings False Nothing OwnObjectivesOnly []

validateSettings :: ObjectiveSettings -> Either Text ()
validateSettings settings = do
  unless (length settings.agentCreation <= 256 && length (nub settings.agentCreation) == length settings.agentCreation) (Left "invalid agent creation grants")
  forM_ settings.operator \identity -> unless (validKey identity) (Left "invalid local operator identity")
  when (settings.administration == AdministerAll && isNothing settings.operator) (Left "administration requires a local operator identity")
  forM_ settings.agentCreation (void . mkAgentPrincipal)

validKey :: Text -> Bool
validKey value = not (Text.null value) && Text.length value <= 256 && Text.all (\c -> c > ' ' && c /= '\DEL') value

validPrincipal :: AccessPrincipal -> Bool
validPrincipal = \case
  VerifiedCaller value -> validKey value
  LocalOperator value -> validKey value
  RecordedAgent identity -> either (const False) validKey (identityText identity)

instance CanonicalTypeName ObjectiveId where
  canonicalTypeName _ = "shikigami.ObjectiveId.v1"
