{-# LANGUAGE DataKinds #-}

-- | Durable values are identities and evidence references, never authority.
-- Authentication and fresh action decisions belong to Objective.Capability.
module Shikigami.Objective.Types (module Shikigami.Objective.Types, module Shikigami.Objective.Keys, module Shikigami.Objective.Content, module Shikigami.StateRevision, ObjectiveId, parseObjectiveId, objectiveIdText) where

import Data.Aeson ((.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (nub)
import Data.Text qualified as Text
import Keiro.Workflow.Types (WorkflowId (..))
import Shikigami.Agent.Principal (AgentIdentity, AgentPrincipal, identityText, mkAgentPrincipal, principalText)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId)
import Shikigami.Execution.Transcript (ExecutionId)
import Shikigami.Generated.Nominals (ObjectiveId, objectiveIdText, parseObjectiveId)
import Shikigami.Objective.Content
import Shikigami.Objective.Keys
import Shikigami.Prelude hiding ((.=))
import Shikigami.StateRevision
import Shikigami.WorkerSession.Types (AssignmentId, ResultReceipt, WorkerSessionId)

data AccessPrincipal = VerifiedCaller !CallerId | RecordedAgent !AgentIdentity | LocalOperator !OperatorId
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

data Criterion = Criterion {key :: !CriterionKey, description :: !CriterionDescription, kind :: !CriterionKind, journeyRequired :: !JourneyRequirement}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ExternalReference = ReiIntention !IntentionRef | ExecPlan !ExecPlanRef | ProtocolTask !ProtocolTaskRef
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Supplied by trusted adapters after checking the owning records. No public
-- command or creation document includes this field.
data CreationOrigin
  = ExecutionOrigin {runId :: !RunReference, executionId :: !ExecutionId, operationId :: !OperationId}
  | ConversationOrigin {conversationId :: !ConversationRef, turnId :: !TurnReference, runId :: !RunReference, operationId :: !OperationId}
  | FlowOrigin {workflowId :: !WorkflowId, generation :: !(StateRevision "objective-origin-generation"), label :: !OriginLabel, operationId :: !OperationId}
  deriving stock (Eq, Show, Generic)

data AssignmentDraft = AssignmentDraft
  { assignmentId :: !ObjectiveAssignmentId,
    instructions :: !Instructions,
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
    revision :: !(StateRevision "objective-assignment"),
    instructionsRevision :: !(StateRevision "assignment-instructions"),
    ownerEpoch :: !(StateRevision "worker-owner"),
    acceptedResults :: ![EvidenceKey]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Immutable sources are resolved by their owner, not by model-authored
-- pass/fail flags. Worker results are additionally checked in the SQL boundary.
data ResultReference
  = WorkerResult {receipt :: !ResultReceipt, artifact :: !ArtifactRef}
  | RetainedResult {runId :: !RunReference, executionId :: !ExecutionId, digest :: !ResultCommitment, artifact :: !ArtifactRef}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data EvidenceInput
  = ResultEvidence {key :: !EvidenceKey, criterion :: !CriterionKey, result :: !ResultReference, journey :: !JourneyEvidence}
  | Attestation {key :: !EvidenceKey, criterion :: !CriterionKey, artifact :: !ArtifactRef, statement :: !AttestationStatement, journey :: !JourneyEvidence}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CheckDisposition = CheckPassed | CheckFailed | ResultObserved
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A verifier-owned interpretation of retained output. Ordinary child success
-- is ResultObserved; only a verifier may attest a criterion or a user journey.
data EvidenceVerification = EvidenceVerification
  { disposition :: !CheckDisposition,
    criterion :: !(Maybe CriterionKey),
    journey :: !JourneyEvidence
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Evidence = Evidence
  { input :: !EvidenceInput,
    verification :: !EvidenceVerification,
    assignmentId :: !ObjectiveAssignmentId,
    assignmentDigest :: !AssignmentDigest,
    recordedBy :: !AccessPrincipal,
    revision :: !(StateRevision "objective"),
    instructionsRevision :: !(StateRevision "objective-instructions"),
    criteriaRevision :: !(StateRevision "objective-criteria")
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CompletionProposal = CompletionProposal
  { objectiveRevision :: !(StateRevision "objective"),
    instructionsRevision :: !(StateRevision "objective-instructions"),
    criteriaRevision :: !(StateRevision "objective-criteria"),
    artifacts :: ![ArtifactRef],
    checks :: ![EvidenceKey],
    limitations :: ![CompletionLimitation]
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

-- | A source observation, without a criterion or an assertion of acceptance.
-- Full output remains with the session owner; receipts retain its commitment.
data ReportedResult = ReportedResult
  { assignmentId :: !ObjectiveAssignmentId,
    receipt :: !ResultReceipt,
    artifacts :: ![ArtifactRef]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Objective = Objective
  { objectiveId :: !ObjectiveId,
    owner :: !AccessPrincipal,
    members :: ![Member],
    title :: !Title,
    goal :: !Goal,
    instructions :: !Instructions,
    revision :: !(StateRevision "objective"),
    instructionsRevision :: !(StateRevision "objective-instructions"),
    criteriaRevision :: !(StateRevision "objective-criteria"),
    criteria :: ![Criterion],
    status :: !Status,
    assignments :: ![Assignment],
    evidence :: ![Evidence],
    reportedResults :: ![ReportedResult],
    decisions :: ![DecisionNote],
    assumptions :: ![AssumptionNote],
    nextActions :: ![NextAction],
    external :: ![ExternalReference],
    unresolved :: ![UnresolvedOperation],
    proposed :: !(Maybe (CompletionProposal, AccessPrincipal)),
    acceptance :: !(Maybe ObjectiveAcceptance)
  }
  deriving stock (Eq, Generic)

instance ToJSON Objective where
  toJSON objective = case Aeson.genericToJSON Aeson.defaultOptions objective of
    Aeson.Object fields | null objective.reportedResults -> Aeson.Object (KeyMap.delete "reportedResults" fields)
    value -> value

instance FromJSON Objective where
  parseJSON = Aeson.withObject "Objective" \fields ->
    Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object (if KeyMap.member "reportedResults" fields then fields else KeyMap.insert "reportedResults" (toJSON ([] :: [ReportedResult])) fields))

instance Show Objective where show _ = "Objective <protected>"

data CreateRequest = CreateRequest {title :: !Title, goal :: !Goal, instructions :: !Instructions, criteria :: ![Criterion], external :: ![ExternalReference]}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Receipt = Receipt
  { objectiveId :: !ObjectiveId,
    operationId :: !OperationId,
    fingerprint :: !MutationFingerprint,
    revision :: !(StateRevision "objective"),
    payloadDigest :: !ObjectivePayloadDigest
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
  { enabled :: !ObjectiveService,
    operator :: !(Maybe OperatorId),
    administration :: !OperatorPolicy,
    agentCreation :: ![AgentPrincipal]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ObjectiveSettings where
  toJSON settings = Aeson.object ["enabled" .= settings.enabled, "operator" .= settings.operator, "administration" .= settings.administration, "agentCreation" .= map principalText settings.agentCreation]

instance FromJSON ObjectiveSettings where
  parseJSON = Aeson.withObject "objective settings" \o -> do
    unless (all (`elem` ["enabled", "operator", "administration", "agentCreation"]) (KeyMap.keys o)) (fail "unknown objective setting")
    settings <- ObjectiveSettings <$> o .:? "enabled" .!= ObjectivesDisabled <*> o .:? "operator" <*> o .:? "administration" .!= OwnObjectivesOnly <*> (o .:? "agentCreation" .!= [] >>= traverse (either (fail . Text.unpack) pure . mkAgentPrincipal))
    either (fail . Text.unpack) (const (pure settings)) (validateSettings settings)

defaultObjectiveSettings :: ObjectiveSettings
defaultObjectiveSettings = ObjectiveSettings ObjectivesDisabled Nothing OwnObjectivesOnly []

validateSettings :: ObjectiveSettings -> Either Text ()
validateSettings settings = do
  unless (length settings.agentCreation <= 256 && length (nub settings.agentCreation) == length settings.agentCreation) (Left "invalid agent creation grants")
  forM_ settings.operator \identity -> unless (validKey (operatorIdText identity)) (Left "invalid local operator identity")
  when (settings.administration == AdministerAll && isNothing settings.operator) (Left "administration requires a local operator identity")

validPrincipal :: AccessPrincipal -> Bool
validPrincipal = \case
  VerifiedCaller value -> validKey (callerIdText value)
  LocalOperator value -> validKey (operatorIdText value)
  RecordedAgent identity -> either (const False) validKey (identityText identity)

-- Preserve the original boolean wire representation while separating its role.
data JourneyRequirement = JourneyOptional | JourneyRequired
  deriving stock (Eq, Ord, Show)

instance ToJSON JourneyRequirement where
  toJSON value = toJSON (value == JourneyRequired)
  toEncoding value = toEncoding (value == JourneyRequired)

instance FromJSON JourneyRequirement where
  parseJSON value = (\allowed -> if allowed then JourneyRequired else JourneyOptional) <$> parseJSON @Bool value

-- Preserve the original boolean wire representation while separating its role.
data JourneyEvidence = NoJourney | JourneyObserved
  deriving stock (Eq, Ord, Show)

instance ToJSON JourneyEvidence where
  toJSON value = toJSON (value == JourneyObserved)
  toEncoding value = toEncoding (value == JourneyObserved)

instance FromJSON JourneyEvidence where
  parseJSON value = (\allowed -> if allowed then JourneyObserved else NoJourney) <$> parseJSON @Bool value

-- Preserve the original boolean wire representation while separating its role.
data ObjectiveService = ObjectivesDisabled | ObjectivesEnabled
  deriving stock (Eq, Ord, Show)

instance ToJSON ObjectiveService where
  toJSON value = toJSON (value == ObjectivesEnabled)
  toEncoding value = toEncoding (value == ObjectivesEnabled)

instance FromJSON ObjectiveService where
  parseJSON value = (\allowed -> if allowed then ObjectivesEnabled else ObjectivesDisabled) <$> parseJSON @Bool value

-- Preserve the original boolean wire representation while separating its role.
data BlockState = Unblocked | IsBlocked
  deriving stock (Eq, Ord, Show)

instance ToJSON BlockState where
  toJSON value = toJSON (value == IsBlocked)
  toEncoding value = toEncoding (value == IsBlocked)

instance FromJSON BlockState where
  parseJSON value = (\allowed -> if allowed then IsBlocked else Unblocked) <$> parseJSON @Bool value

-- WorkflowId has no JSON instance. Render only at this retained codec boundary,
-- preserving historical spellings admitted by the original origin verifier.
instance ToJSON CreationOrigin where
  toJSON = \case
    ExecutionOrigin run execution operation -> Aeson.object ["tag" .= ("ExecutionOrigin" :: Text), "runId" .= run, "executionId" .= execution, "operationId" .= operation]
    ConversationOrigin conversation turn run operation -> Aeson.object ["tag" .= ("ConversationOrigin" :: Text), "conversationId" .= conversation, "turnId" .= turn, "runId" .= run, "operationId" .= operation]
    FlowOrigin workflow generation label operation -> Aeson.object ["tag" .= ("FlowOrigin" :: Text), "workflowId" .= workflow.unWorkflowId, "generation" .= generation, "label" .= label, "operationId" .= operation]

instance FromJSON CreationOrigin where
  parseJSON = Aeson.withObject "objective creation origin" \o -> do
    tag <- o .: "tag"
    case tag :: Text of
      "ExecutionOrigin" -> ExecutionOrigin <$> o .: "runId" <*> o .: "executionId" <*> o .: "operationId"
      "ConversationOrigin" -> ConversationOrigin <$> o .: "conversationId" <*> o .: "turnId" <*> o .: "runId" <*> o .: "operationId"
      "FlowOrigin" -> FlowOrigin <$> (WorkflowId <$> o .: "workflowId") <*> o .: "generation" <*> o .: "label" <*> o .: "operationId"
      _ -> fail "unknown objective origin"
