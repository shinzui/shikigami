#!/usr/bin/env python3
"""Positive public factories first; generic APIs must not bypass opaque owners."""
from pathlib import Path
import json
import subprocess
import tempfile
import argparse
import re

arguments = argparse.ArgumentParser(description=__doc__)
arguments.add_argument("--match", help="filter parameterized controls; public adapters and fixed smoke checks always run")
pattern = arguments.parse_args().match
selected = re.compile(pattern).search if pattern else lambda _: True

ROOT = Path(__file__).resolve().parents[2]
PLAN = json.loads((ROOT / "dist-newstyle/cache/plan.json").read_text())
CORE_UNITS = [entry["id"] for entry in PLAN["install-plan"]
              if entry["pkg-name"] == "shikigami-core" and entry.get("component-name") == "lib"]
assert len(CORE_UNITS) == 1, CORE_UNITS
CORE_UNIT = CORE_UNITS[0]
HEADER = '''{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE ImportQualifiedPost #-}
module OpaqueBoundary where
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.Coerce (coerce)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Int (Int64)
import Data.UUID (UUID)
import Pgmq (MessageId)
import Kioku.Id (SessionId)
import Numeric.Natural (Natural)
import GHC.Generics qualified as Generic
import Keiro.Workflow.Types (WorkflowId, WorkflowName, StepName)
import Shikigami.Agent.Delegate.Depth qualified as Depth
import Shikigami.Agent.ExpertiseKey qualified as Expertise
import Shikigami.Agent.Name qualified as Name
import Shikigami.Router.SelectionLimit qualified as Limit
import Shikigami.Objective.Types qualified as Objective
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.Agent.DeclarationValue qualified as DeclValue
import Shikigami.Activity qualified as Activity
import Shikigami.Activity.Coordinate qualified as ActivityValue
import Shikigami.Directory qualified as Directory
import Shikigami.Trigger.Schedule qualified as Schedule
import Shikigami.Execution.Start qualified as Start
import Shikigami.Capability.Provider qualified as Capability
import Shikigami.Agent.Principal qualified as Principal
import Shikigami.App.Config qualified as Config
import Shikigami.Attestation.Compliance qualified as Compliance
import Shikigami.Attestation.CallFacts qualified as CallFacts
import Shikigami.Attestation.Evidence qualified as RunEvidence
import Shikigami.Attestation.Envelope qualified as Attestation
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve qualified as Snapshot
import Shikigami.Attestation.PolicyValue qualified as Policy
import Shikigami.Attestation.Reviewed qualified as Reviewed
import Shikigami.Capability.Overlay qualified as Overlay
import Shikigami.AgentRun.Ledger qualified as Ledger
import Shikigami.Directory.Store qualified as DirectoryStore
import Shikigami.Sink.Delivery qualified as Delivery
import Shikigami.Sink.Intent qualified as SinkIntent
import Shikigami.Sink.Coordinate qualified as SinkCoordinate
import Shikigami.AgentRun.RequestKey qualified as Request
import Shikigami.Agent.Run.Key qualified as FullKey
import Shikigami.Trigger.RequestKey qualified as Addressed
import Shikigami.FormatVersion qualified as Format
import Shikigami.Execution.Coordinate qualified as ExecutionValue
import Shikigami.Execution.Runner qualified as Runner
import Shikigami.Execution.Transcript qualified as Transcript
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Identity qualified as Entity
import Shikigami.Execution.Claim qualified as Claim
import Shikigami.Execution.Counter qualified as Counter
import Shikigami.Execution.Payload qualified as Payload
import Shikigami.Execution.AssignmentKey qualified as Assignment
import Shikigami.Execution.ToolPosition qualified as Position
import Shikigami.Decision.Contract qualified as Decision
import Shikigami.Decision.Evidence qualified as DecisionEvidence
import Shikigami.Log.Correlation qualified as Correlation
import Shikigami.PracticeReview.Identity qualified as ReviewId
import Shikigami.PracticeReview.Authorization qualified as ReviewAuth
import Shikigami.PracticeReview.Capability qualified as ReviewCapability
import Shikigami.PracticeReview.IdentityStore qualified as ReviewIdentity
import Shikigami.PracticeReview qualified as Review
import Shikigami.PracticeReview.Evidence qualified as Evidence
import Shikigami.Router.Declaration qualified as Declaration
import Shikigami.Workspace.Instructions qualified as Instructions
import Shikigami.WorkerSession.Input qualified as WorkerInput
import Shikigami.WorkerSession.Types qualified as WorkerSession
import Shikigami.Workspace.Types qualified as Workspace
import Shikigami.Workspace.Store qualified as WorkspaceStore
import Shikigami.Workspace.ProcessPolicy qualified as ProcessPolicy
import Shikigami.Decision.ModelAlias qualified as Alias
import Shikigami.Behavior.Provider.Coordinate qualified as ProviderCoordinate
import Shikigami.Inspection.Settings qualified as Inspection
import Shikigami.Repository qualified as Repository
import Shikigami.Router.Decision qualified as Router
import Shikigami.Sink.Auth qualified as Auth
'''
POSITIVE = '''declarationTask :: Text -> DeclValue.DeclarationCoordinate "task"
declarationTask = DeclValue.declarationCoordinate
activityVerb :: Text -> ActivityValue.ActivityCoordinate "verb"
activityVerb = ActivityValue.activityCoordinate
signalImportance :: Natural -> Either Text DeclValue.SignalImportance
signalImportance = DeclValue.parseSignalImportance
contextReference :: Text -> Either Text ActivityValue.ContextReference
contextReference = ActivityValue.parseContextReference
directoryVersion :: Text -> Either Text Directory.DirectorySnapshotVersion
directoryVersion = Directory.parseDirectorySnapshotVersion
cronClaim :: Text -> Schedule.CronExpressionClaim
cronClaim = Schedule.cronExpressionClaim
cron :: Text -> Either Text Schedule.CronSchedule
cron = Schedule.parseCron
executionWorkflow :: Transcript.ExecutionSnapshot -> WorkflowId
executionWorkflow value = value.runId
workspaceWorkflow :: Workspace.WorkspaceRequest -> WorkflowId
workspaceWorkflow value = value.runId
capabilityPrincipal :: Capability.CapabilityScope -> DeclValue.DeclarationCoordinate "principal"
capabilityPrincipal value = value.principal
executionIdentity :: Text -> Transcript.ExecutionId
executionIdentity = ExecutionValue.executionIdentity
executionRead :: Transcript.ExecutionId -> Text
executionRead value = value.value
workerRead :: WorkerSession.WorkerSessionId -> Text
workerRead value = value.value
assignmentRead :: WorkerSession.AssignmentId -> Text
assignmentRead value = value.value
operationKey :: Runner.OperationContext -> Entity.OperationId
operationKey value = value.idempotencyKey
toolName :: Transcript.ToolBinding -> ExecutionValue.ExecutionCoordinate "tool-name"
toolName value = value.name
policyCommitment :: Text -> ExecutionValue.ExecutionDigest "policy"
policyCommitment = ExecutionValue.executionDigest
contextPosition :: Int -> Either Text ExecutionValue.ContextPosition
contextPosition = ExecutionValue.parseContextPosition
replayModel :: Transcript.ProviderReplay -> ProviderCoordinate.ProviderCoordinate "provider-model-id"
replayModel value = value.model
replayCall :: Transcript.ToolInvocation -> ProviderCoordinate.ProviderCoordinate "provider-tool-call-id"
replayCall value = value.callId
requestContext :: ExecutionValue.ReplayContextFormat
requestContext = ExecutionValue.RequestContext
workerScope :: WorkerSession.SessionScope -> WorkerInput.WorkerCoordinate "parent-scope"
workerScope value = value.parent
workerAssignment :: Aeson.Value -> WorkerSession.AssignmentId
workerAssignment = WorkerInput.assignmentIdForDigest
workerCommitment :: Text -> Aeson.Value -> WorkerInput.WorkerCommitment "checkpoint"
workerCommitment = WorkerInput.workerCommitmentFor
workerTechnicalIdentity :: Text -> WorkerSession.WorkerSessionId
workerTechnicalIdentity = WorkerInput.workerSessionId
workerGeneration :: Int -> Either Text WorkerInput.WorkflowGeneration
workerGeneration = WorkerInput.parseWorkflowGeneration
reviewDependency :: Text -> Either Text Review.DependencyName
reviewDependency = Review.parseDependencyName
reviewLineageSession :: Review.ReviewLineage -> SessionId
reviewLineageSession value = value.childSessionId
reviewSpecialist :: Review.PracticeReviewVerdict -> Name.AgentName
reviewSpecialist value = value.specialist
reviewAttention :: Text -> ReviewId.AttentionKey
reviewAttention = ReviewId.attentionKeyForDigest
reviewPageSize :: Int -> Either Text Evidence.EvidencePageSize
reviewPageSize = Evidence.parseEvidencePageSize
nativeAttestationSession :: Attestation.AttestationPayload -> Maybe SessionId
nativeAttestationSession value = value.sessionId
nativeEvidenceSteps :: RunEvidence.RunEvidence -> [StepName]
nativeEvidenceSteps value = value.deterministicSteps
providerAttempt :: Natural -> RunEvidence.ProviderAttempt
providerAttempt = RunEvidence.providerAttempt
measuredTokens :: Natural -> CallFacts.MeasuredTokens
measuredTokens = CallFacts.measuredTokens
measuredCost :: Rational -> CallFacts.MeasuredMicroUsd
measuredCost = CallFacts.measuredMicroUsd
objectiveCaller :: Text -> Either Text Objective.CallerId
objectiveCaller = Objective.parseCallerId
objectiveConversation :: Text -> Either Text Objective.ConversationRef
objectiveConversation = Objective.parseConversationRef
objectiveFingerprint :: Objective.Receipt -> Objective.MutationFingerprint
objectiveFingerprint value = value.fingerprint
objectiveJourney :: Objective.EvidenceVerification -> Objective.JourneyEvidence
objectiveJourney value = value.journey
listenerWorkflow :: WorkerSession.SessionListener -> WorkflowId
listenerWorkflow value = value.ownerId
listenerDefinition :: WorkerSession.SessionListener -> WorkflowName
listenerDefinition value = value.ownerName
currentFormat :: Format.FormatVersion "execution-state"
currentFormat = Format.V1
executionFormat :: Transcript.ExecutionState -> Format.FormatVersion "execution-state"
executionFormat value = value.format
jobFormat :: Attempt.JobReference -> Format.FormatVersion "execution-job"
jobFormat value = value.format
sinkPosition :: Integer -> Either Text SinkCoordinate.SinkOrdinal
sinkPosition = SinkCoordinate.parseSinkOrdinal
sinkSession :: SinkIntent.SinkIntent -> SessionId
sinkSession value = value.runId
receiptSession :: Delivery.DeliveryReceipt -> SessionId
receiptSession value = value.runId
sinkAgent :: SinkIntent.SinkIntent -> Name.AgentName
sinkAgent value = value.agent
openWorkspace :: WorkspaceStore.FreezeState
openWorkspace = WorkspaceStore.AdmissionOpen
sinkMessage :: Text -> Delivery.SinkMessageId
sinkMessage = Delivery.sinkMessageId
receiptKey :: Text -> Delivery.ReceiptKey
receiptKey = Delivery.deliveryReceiptKey
reportedPrincipal :: Text -> DirectoryStore.ReportedPrincipalClaim
reportedPrincipal = DirectoryStore.reportedPrincipalClaim
requestFingerprint :: Text -> Either Text Ledger.PayloadFingerprint
requestFingerprint = Ledger.parsePayloadFingerprint
requestCaller :: Text -> Ledger.CallerAttribution
requestCaller = Ledger.callerAttribution
acceptedWorkflow :: Ledger.RunRequestRow -> WorkflowId
acceptedWorkflow value = value.runId
acceptedQueueMessage :: Ledger.RunRequestRow -> MessageId
acceptedQueueMessage value = value.queueMessageId
profileSnapshot :: Profile.SanctionedExecutionProfile -> Snapshot.ResolvedProfile
profileSnapshot = Snapshot.resolvedProfileFor
snapshotView :: Snapshot.ResolvedProfile -> Snapshot.ResolvedProfileView
snapshotView = Snapshot.resolvedProfileView
checkedSnapshot :: Profile.SanctionedExecutionProfile -> Profile.SanctionedExecutionProfileRef -> Either Text Snapshot.ResolvedProfile
checkedSnapshot = Snapshot.parseResolvedProfile
ordinarySnapshotView :: Snapshot.ResolvedProfileView -> ()
ordinarySnapshotView value = Generic.from value `seq` ()
profileDigest :: Text -> Either Text Profile.ProfileDigest
profileDigest = Profile.parseProfileDigest
attestationDigest :: Text -> Either Text Attestation.PayloadDigest
attestationDigest = Attestation.parsePayloadDigest
attestationVersion :: Text -> Either Text Attestation.SchemaVersion
attestationVersion = Attestation.parseSchemaVersion
policyCeiling :: Int -> Either Text (Policy.Ceiling "calls" Int)
policyCeiling = Policy.mkCeiling
policyPermission :: Policy.Permission "aliasesAllowed"
policyPermission = Policy.Permitted
policyCoordinate :: Text -> Policy.PolicyCoordinate "signing-key-id"
policyCoordinate = Policy.policyCoordinate
preparation :: Text -> Either Text Decision.DecisionPreparationId
preparation = Decision.parseDecisionPreparationId
slotLabel :: Text -> Either Text Decision.DecisionSlotLabel
slotLabel = Decision.parseDecisionSlotLabel
decisionGeneration :: Integer -> Either Text Decision.DecisionGeneration
decisionGeneration = Decision.parseDecisionGeneration
attemptCount :: Integer -> Either Text (Counter.AttemptCount "selection-calls")
attemptCount = Counter.parseAttemptCount
nativeWorkflow :: Decision.PreparedDecision -> WorkflowId
nativeWorkflow value = value.workflowId
storedCorrelation :: DecisionEvidence.StoredDecisionCall -> Correlation.CallCorrelationId
storedCorrelation value = value.correlationId
runDisposition :: Ledger.RunDisposition
runDisposition = Ledger.RunAccepted
runDispositionText :: Text
runDispositionText = Ledger.renderRunDisposition Ledger.RunDeadLettered
policyFormat :: ProcessPolicy.ProcessPolicyFormat
policyFormat = ProcessPolicy.ProcessPolicyV1
programIdentity :: Text -> Either Text (Decision.ProgramIdentity "program-id")
programIdentity = Decision.parseProgramIdentity
programDigest :: Text -> Either Text Decision.ProgramParameterDigest
programDigest = Decision.parseProgramParameterDigest
decisionCall :: Text -> Either Text Decision.DecisionCallId
decisionCall = Decision.parseDecisionCallId
decisionOrdinal :: Integer -> Either Text Decision.DecisionCallOrdinal
decisionOrdinal = Decision.parseDecisionCallOrdinal
operation :: Text -> Either Text Entity.OperationId
operation = Entity.parseOperationId
root :: Text -> Either Text Entity.ExecutionRootId
root = Entity.parseExecutionRootId
attempt :: Text -> Either Text Entity.AttemptId
attempt = Entity.parseAttemptId
allocation :: Text -> Either Text Entity.AllocationId
allocation = Entity.parseAllocationId
reviewId :: Text -> Either Text Review.ReviewId
reviewId = Review.parseReviewId
resolutionId :: Text -> Either Text Review.ResolutionId
resolutionId = Review.parseResolutionId
practiceKey :: Text -> Either Text Review.PracticeKey
practiceKey = Review.parsePracticeKey
ownerPrincipal :: Text -> Either Text Review.OwnerPrincipal
ownerPrincipal = Review.parseOwnerPrincipal
evidenceId :: Text -> Either Text Review.EvidenceId
evidenceId = Review.parseEvidenceId
claimId :: Text -> Either Text Review.ClaimId
claimId = Review.parseClaimId
contentHash :: Text -> Either Text Review.ContentHash
contentHash = Review.parseContentHash
confidence :: Integer -> Either Text Review.Confidence
confidence = Review.parseConfidence
callOrdinal :: Integer -> Either Text Counter.CallOrdinal
callOrdinal = Counter.parseCallOrdinal
payloadId :: Text -> Either Text Payload.PayloadId
payloadId = Payload.parsePayloadId
payloadDigest :: Text -> Either Text Payload.PayloadDigest
payloadDigest = Payload.parsePayloadDigest
payloadBytes :: Integer -> Either Text Payload.PayloadByteCount
payloadBytes = Payload.parsePayloadByteCount
fullKey :: Text -> Either Text FullKey.RunKey
fullKey = FullKey.parseRunKey
addressedKey :: Text -> Either Text Addressed.RequestKey
addressedKey = Addressed.parseRequestKey
agentName :: Text -> Either Text Name.AgentName
agentName = Name.mkAgentName
expertise :: Text -> Either Text Expertise.ExpertiseKey
expertise = Expertise.parseExpertiseKey
depth :: Integer -> Either Text Depth.DelegationDepth
depth = Depth.parseDelegationDepth
limit :: Limit.SelectionLimit -> Int
limit = Limit.selectionLimitInt
principal :: Text -> Either Text Principal.AgentPrincipal
principal = Principal.mkAgentPrincipal
port :: Int -> Either Text Config.Port
port = Config.mkPort
bytes :: Int -> Either Text Config.ByteLimit
bytes = Config.mkByteLimit
secret :: Config.SecretText -> Text
secret = Config.revealSecretText
commit :: Text -> Either Text Reviewed.FullCommit
commit = Reviewed.mkFullCommit
capability :: Text -> Either Overlay.CapabilityIdError Overlay.CapabilityId
capability = Overlay.mkCapabilityId
capabilityRevision :: Text -> Either Overlay.CapabilityRevisionError Overlay.CapabilityRevision
capabilityRevision = Overlay.mkCapabilityRevision
emptyCapabilities :: Overlay.ResolvedCapabilitySet
emptyCapabilities = Overlay.emptyResolvedCapabilitySet
inspection :: Inspection.InspectionCredential "read" -> Text
inspection = Inspection.revealInspectionCredential
revision :: Text -> Either Text Repository.Revision
revision = Repository.mkRevision
path :: Text -> Either Text Repository.RelativePath
path = Repository.mkRelativePath
route :: Router.ValidatedRouteDecision -> Router.RouteDecision
route = Router.validatedRouteDecision
bearer :: Auth.BearerToken -> ByteString -> Bool
bearer = Auth.matchesBearerHeader
failure :: Decision.FailureCode -> Text -> Decision.DecisionFailure
failure = Decision.decisionFailure
requestKey :: Text -> Either Text Request.RequestKey
requestKey = Request.parseRequestKey
claimOwner :: Text -> Either Text Claim.ClaimOwner
claimOwner = Claim.parseClaimOwner
assignment :: Text -> Either Text Assignment.AssignmentKey
assignment = Assignment.parseAssignmentKey
position :: Integer -> Either Text Position.ToolPosition
position = Position.parseToolPosition
run :: Text -> Correlation.RunCorrelationId
run = Correlation.runCorrelationId
call :: Correlation.RunCorrelationId -> Text -> Int -> Correlation.CallCorrelationId
call = Correlation.callCorrelationId
bundle :: Int -> Text -> Text -> [(Text, Text)] -> Either Instructions.InstructionError Instructions.InstructionBundle
bundle = Instructions.mkInstructionBundle
router :: AgentDecl -> Either [Declaration.RouterDeclarationError] Declaration.ValidatedRouterDeclaration
router = Declaration.validateRouterDeclaration
routerView :: Declaration.ValidatedRouterDeclaration -> Declaration.RouterDeclarationView
routerView = Declaration.validatedRouterDeclaration
pin :: Evidence.EvidenceLimits -> Repository.RepositoryId -> Repository.Revision -> Repository.Revision -> Maybe Repository.RelativePath -> Evidence.PinnedDiff -> Either Evidence.EvidenceProblem Evidence.ValidatedPinnedDiff
pin = Evidence.validatePinnedDiff
pinnedView :: Evidence.ValidatedPinnedDiff -> Evidence.PinnedDiffView
pinnedView = Evidence.validatedPinnedDiff
ordinaryRouterRecord :: Declaration.RouterDeclarationView -> ()
ordinaryRouterRecord value = Generic.from value `seq` ()
ordinaryPinnedRecord :: Evidence.PinnedDiffView -> ()
ordinaryPinnedRecord value = Generic.from value `seq` ()
'''
CASES = [
    ('DeclValue.DeclarationCoordinate "task"', 'generic'),
    ('ActivityValue.ActivityCoordinate "verb"', 'generic'),
    ('DeclValue.SignalImportance', 'generic'),
    ('ActivityValue.ContextReference', 'generic'),
    ('Directory.DirectorySnapshotVersion', 'generic'),
    ('Schedule.CronExpressionClaim', 'generic'),
    ('Transcript.ExecutionId', 'generic'),
    ('ExecutionValue.ExecutionCoordinate "tool-name"', 'generic'),
    ('ExecutionValue.ExecutionCoordinate "tool-revision"', 'generic'),
    ('ExecutionValue.ExecutionDigest "input"', 'generic'),
    ('ExecutionValue.ExecutionDigest "policy"', 'generic'),
    ('ExecutionValue.ContextPosition', 'generic'),
    ('ExecutionValue.ExecutionGeneration', 'generic'),
    ('WorkerSession.WorkerSessionId', 'generic'),
    ('WorkerSession.AssignmentId', 'generic'),
    ('WorkerInput.WorkerCoordinate "worker-slot"', 'generic'),
    ('WorkerInput.WorkerCommitment "session-command"', 'generic'),
    ('WorkerInput.ArtifactReference', 'generic'),
    ('WorkerInput.ProviderReceipt', 'generic'),
    ('WorkerInput.WorkflowGeneration', 'generic'),
    ('WorkerInput.AssignmentPageSize', 'generic'),
    ('WorkerInput.EventPageSize', 'generic'),
    ('Review.DependencyName', 'generic'),
    ('Review.DocumentId', 'generic'),
    ('Review.TriggerKey', 'generic'),
    ('Review.ResolutionKey', 'generic'),
    ('ReviewAuth.ResolutionAuthorizationId', 'generic'),
    ('ReviewAuth.ResolutionSourceRef', 'generic'),
    ('ReviewId.AttentionKey', 'generic'),
    ('ReviewCapability.AttentionRecipient', 'generic'),
    ('Evidence.MutableGitRef', 'generic'),
    ('Evidence.EvidencePageSize', 'generic'),
    ('Reviewed.PullRequestRef', 'generic'),
    ('Reviewed.ReviewPath', 'generic'),
    ('Attestation.ReviewClass', 'generic'),
    ('Attestation.AttestationSignature', 'generic'),
    ('Attestation.MerkleCommitment', 'generic'),
    ('RunEvidence.ProviderAttempt', 'generic'),
    ('CallFacts.MeasuredTokens', 'generic'),
    ('CallFacts.MeasuredMicroUsd', 'generic'),
    ('Inspection.InspectionLimit "maxViews"', 'generic'),
    ('Inspection.InspectionPort', 'generic'),
    ('Inspection.InspectionHost', 'generic'),
    ('Inspection.InspectionOrigin', 'generic'),
    ('Objective.CallerId', 'generic'),
    ('Objective.OperatorId', 'generic'),
    ('Objective.ConversationRef', 'generic'),
    ('Objective.IntentionRef', 'generic'),
    ('Objective.ExecPlanRef', 'generic'),
    ('Objective.ProtocolTaskRef', 'generic'),
    ('Objective.ResultCommitment', 'generic'),
    ('Objective.RunReference', 'generic'),
    ('Objective.TurnReference', 'generic'),
    ('Objective.OriginLabel', 'generic'),
    ('Objective.AssignmentDigest', 'generic'),
    ('Objective.MutationFingerprint', 'generic'),
    ('Objective.ObjectivePayloadDigest', 'generic'),

    ('Format.FormatVersion "execution-state"', 'generic'),
    ('Format.FormatVersion "execution-state"', 'parse'),
    ('SinkCoordinate.SinkOrdinal', 'generic'),
    ('Delivery.SinkMessageId', 'generic'),
    ('Delivery.ReceiptKey', 'generic'),
    ('DirectoryStore.ReportedPrincipalClaim', 'generic'),
    ('Ledger.PayloadFingerprint', 'generic'),
    ('Ledger.CallerAttribution', 'generic'),
    ('Snapshot.ResolvedProfile', 'generic'),
    ('Profile.ProfileDigest', 'generic'),
    ('Attestation.PayloadDigest', 'generic'),
    ('Attestation.SchemaVersion', 'generic'),
    ('Policy.Ceiling "calls" Int', 'generic'),
    ('Policy.Permission "aliasesAllowed"', 'generic'),
    ('Policy.PolicyCoordinate "signing-key-id"', 'generic'),
    ('Decision.DecisionPreparationId', 'generic'),
    ('Decision.DecisionSlotLabel', 'generic'),
    ('Decision.DecisionGeneration', 'generic'),
    ('Decision.ProgramIdentity "program-id"', 'generic'),
    ('Decision.ProgramParameterDigest', 'generic'),
    ('ProcessPolicy.ProcessPolicyFormat', 'generic'),
    ('Ledger.RunDisposition', 'generic'),
    ('Decision.DecisionCallId', 'generic'),
    ('Decision.DecisionCallOrdinal', 'generic'),
    ('Decision.ModelRegistration "model-version"', 'generic'),
    ('Decision.ModelDescriptorDigest', 'generic'),
    ('ProviderCoordinate.ProviderCoordinate "provider-model-id"', 'generic'),
    ('Alias.ModelAlias', 'generic'),
    ('Workspace.WorkspaceId', 'generic'),
    ('Entity.OperationId', 'generic'),
    ('Entity.ExecutionRootId', 'generic'),
    ('Entity.AttemptId', 'generic'),
    ('Entity.AllocationId', 'generic'),
    ('ReviewIdentity.ReviewIdentityRef', 'generic'),
    ('Review.ValidatedResolutionRequest', 'generic'),
    ('Review.ReviewId', 'parse'),
    ('Review.ResolutionId', 'parse'),
    ('Review.PracticeKey', 'parse'),
    ('Review.OwnerPrincipal', 'parse'),
    ('Review.EvidenceId', 'parse'),
    ('Review.ClaimId', 'parse'),
    ('Review.ContentHash', 'parse'),
    ('Review.Confidence', 'parse'),
    ('Counter.CallOrdinal', 'parse'),
    ('Payload.PayloadId', 'parse'),
    ('Payload.PayloadDigest', 'parse'),
    ('Payload.PayloadByteCount', 'parse'),
    ('FullKey.RunKey', 'parse'),
    ('Addressed.RequestKey', 'parse'),
    ('Name.AgentName', 'parse'),
    ('Expertise.ExpertiseKey', 'parse'),
    ('Depth.DelegationDepth', 'parse'),
    ('Limit.SelectionLimit', 'parse'),
    ('Principal.AgentPrincipal', 'parse'),
    ('Config.Port', 'parse'),
    ('Config.ByteLimit', 'parse'),
    ('Config.SecretText', 'render'),
    ('Reviewed.FullCommit', 'parse'),
    ('Overlay.CapabilityId', 'parse'),
    ('Overlay.CapabilityRevision', 'parse'),
    ('Overlay.ResolvedCapabilitySet', 'parse'),
    ('Inspection.InspectionCredential "read"', 'render'),
    ('Repository.Revision', 'parse'),
    ('Repository.RelativePath', 'parse'),
    ('Router.ValidatedRouteDecision', 'parse'),
    ('Auth.BearerToken', 'render'),
    ('Position.ToolPosition', 'parse'),
    ('Assignment.AssignmentKey', 'parse'),
    ('Claim.ClaimOwner', 'parse'),
    ('Request.RequestKey', 'parse'),
    ('Decision.DecisionFailure', 'parse'),
    ('Correlation.RunCorrelationId', 'parse'),
    ('Correlation.CallCorrelationId', 'parse'),
    ('Instructions.InstructionBundle', 'parse'),
    ('Declaration.ValidatedRouterDeclaration', 'generic'),
    ('Evidence.ValidatedPinnedDiff', 'generic'),
]

with tempfile.TemporaryDirectory(prefix='shikigami-opaque-types-') as directory:
    source = Path(directory) / 'OpaqueBoundary.hs'
    def compile(body):
        source.write_text(HEADER + body)
        return subprocess.run(['cabal', 'exec', '--', 'ghc', '-fno-code', '-package-id', CORE_UNIT, str(source)], cwd=ROOT, capture_output=True, text=True, timeout=45)
    result = compile(POSITIVE)
    assert result.returncode == 0, (result.stdout, result.stderr)
    print('opaque boundary: public factories/adapters: passed', flush=True)
    result = compile('bypass :: Format.FormatVersion "execution-state"\nbypass = 1\n')
    assert result.returncode != 0 and 'Num' in result.stderr and 'FormatVersion' in result.stderr, result.stderr
    print('opaque boundary: format integer literal refused: passed', flush=True)
    result = compile('bypass :: Int -> Policy.Ceiling "calls" Int\nbypass = Policy.Ceiling\n')
    assert result.returncode != 0 and 'Ceiling' in result.stderr and any(fragment in result.stderr.lower() for fragment in ['not in scope', 'does not export', 'illegal term-level use']), result.stderr
    print('opaque boundary: policy ceiling constructor refused: passed', flush=True)
    for source_kind, body in [
        ('Text', 'bypass :: Text -> Ledger.RunDisposition\nbypass = id\n'),
        ('Text coercion', 'bypass :: Text -> Ledger.RunDisposition\nbypass = coerce\n'),
        ('delivery status', 'bypass :: Delivery.DeliveryStatus -> Ledger.RunDisposition\nbypass = id\n')]:
        result = compile(body)
        assert result.returncode != 0 and 'RunDisposition' in result.stderr, (source_kind, result.stderr)
        print('opaque boundary: run disposition ' + source_kind + ' substitution refused: passed', flush=True)
    for label, signature, expression in [
        ('execution identity record update', 'Transcript.ExecutionId -> Text -> Transcript.ExecutionId', '\\value raw -> value { ExecutionValue.value = raw }'),
        ('execution identity coercion', 'Text -> Transcript.ExecutionId', 'coerce'),
        ('execution coordinate raw coercion', 'Text -> ExecutionValue.ExecutionCoordinate "tool-name"', 'coerce'),
        ('declaration task/skill substitution', 'DeclValue.DeclarationCoordinate "task" -> DeclValue.DeclarationCoordinate "skill-path"', 'coerce'),
        ('declaration channel/action substitution', 'DeclValue.DeclarationCoordinate "channel" -> DeclValue.DeclarationCoordinate "channel-action"', 'coerce'),
        ('activity source/verb substitution', 'ActivityValue.ActivityCoordinate "source" -> ActivityValue.ActivityCoordinate "verb"', 'coerce'),
        ('activity actor/subject substitution', 'ActivityValue.ActivityCoordinate "actor-id" -> ActivityValue.ActivityCoordinate "subject-id"', 'coerce'),
        ('declaration enablement boolean substitution', 'Bool -> DeclValue.AgentEnablement', 'id'),
        ('signal importance raw coercion', 'Int -> DeclValue.SignalImportance', 'coerce'),
        ('activity context reference raw coercion', 'Text -> ActivityValue.ContextReference', 'coerce'),
        ('directory snapshot raw coercion', 'Text -> Directory.DirectorySnapshotVersion', 'coerce'),
        ('cron claim raw coercion', 'Text -> Schedule.CronExpressionClaim', 'coerce'),
        ('execution workflow raw substitution', 'Transcript.ExecutionSnapshot -> Text', '\\value -> value.runId'),
        ('workspace workflow raw substitution', 'Workspace.WorkspaceRequest -> Text', '\\value -> value.runId'),
        ('execution coordinate role substitution', 'ExecutionValue.ExecutionCoordinate "tool-name" -> ExecutionValue.ExecutionCoordinate "tool-revision"', 'coerce'),
        ('execution digest role substitution', 'ExecutionValue.ExecutionDigest "input" -> ExecutionValue.ExecutionDigest "policy"', 'coerce'),
        ('context position coercion', 'Int -> ExecutionValue.ContextPosition', 'coerce'),
        ('execution generation coercion', 'Int -> ExecutionValue.ExecutionGeneration', 'coerce'),
        ('replay format numeric substitution', 'Int -> ExecutionValue.ReplayContextFormat', 'id'),
        ('replay tool result boolean substitution', 'Bool -> ExecutionValue.ToolResultState', 'id'),
        ('replay failure boolean substitution', 'Bool -> ExecutionValue.Retryability', 'id'),
        ('replay state role substitution', 'ExecutionValue.ToolResultState -> ExecutionValue.Retryability', 'id'),
        ('replay provider reference role substitution', 'ProviderCoordinate.ProviderCoordinate "provider-response-id" -> ProviderCoordinate.ProviderCoordinate "provider-tool-call-id"', 'coerce'),
        ('worker session record update', 'WorkerSession.WorkerSessionId -> Text -> WorkerSession.WorkerSessionId', '\\value raw -> value { WorkerSession.value = raw }'),
        ('assignment record update', 'WorkerSession.AssignmentId -> Text -> WorkerSession.AssignmentId', '\\value raw -> value { WorkerSession.value = raw }'),
        ('worker session raw coercion', 'Text -> WorkerSession.WorkerSessionId', 'coerce'),
        ('assignment raw coercion', 'Text -> WorkerSession.AssignmentId', 'coerce'),
        ('worker scope role substitution', 'WorkerInput.WorkerCoordinate "parent-scope" -> WorkerInput.WorkerCoordinate "worker-slot"', 'coerce'),
        ('worker commitment role substitution', 'WorkerInput.WorkerCommitment "session-command" -> WorkerInput.WorkerCommitment "checkpoint"', 'coerce'),
        ('worker generation coercion', 'Int -> WorkerInput.WorkflowGeneration', 'coerce'),
        ('worker page size substitution', 'WorkerInput.AssignmentPageSize -> WorkerInput.EventPageSize', 'coerce'),
        ('objective active boolean substitution', 'Bool -> WorkerInput.ObjectiveActivity', 'id'),
        ('review trigger/resolution substitution', 'Review.TriggerKey -> Review.ResolutionKey', 'coerce'),
        ('review dependency/document substitution', 'Review.DependencyName -> Review.DocumentId', 'coerce'),
        ('review raw key coercion', 'Text -> Review.TriggerKey', 'coerce'),
        ('review authorization coercion', 'UUID -> ReviewAuth.ResolutionAuthorizationId', 'coerce'),
        ('attention UUID coercion', 'UUID -> ReviewId.AttentionKey', 'coerce'),
        ('attention recipient coercion', 'Text -> ReviewCapability.AttentionRecipient', 'coerce'),
        ('review page size coercion', 'Int -> Evidence.EvidencePageSize', 'coerce'),
        ('materiality boolean substitution', 'Bool -> Review.Materiality', 'id'),
        ('format scope substitution', 'Format.FormatVersion \"execution-state\" -> Format.FormatVersion \"execution-job\"', 'id'),
        ('format scope coercion', 'Format.FormatVersion \"execution-state\" -> Format.FormatVersion \"execution-job\"', 'coerce'),
        ('sink ordinal raw coercion', 'Int -> SinkCoordinate.SinkOrdinal', 'coerce'),
        ('objective CallerId raw coercion', 'Text -> Objective.CallerId', 'coerce'),
        ('objective OperatorId raw coercion', 'Text -> Objective.OperatorId', 'coerce'),
        ('objective ConversationRef raw coercion', 'Text -> Objective.ConversationRef', 'coerce'),
        ('objective IntentionRef raw coercion', 'Text -> Objective.IntentionRef', 'coerce'),
        ('objective ExecPlanRef raw coercion', 'Text -> Objective.ExecPlanRef', 'coerce'),
        ('objective ProtocolTaskRef raw coercion', 'Text -> Objective.ProtocolTaskRef', 'coerce'),
        ('objective ResultCommitment raw coercion', 'Text -> Objective.ResultCommitment', 'coerce'),
        ('objective RunReference raw coercion', 'Text -> Objective.RunReference', 'coerce'),
        ('objective TurnReference raw coercion', 'Text -> Objective.TurnReference', 'coerce'),
        ('objective OriginLabel raw coercion', 'Text -> Objective.OriginLabel', 'coerce'),
        ('objective AssignmentDigest raw coercion', 'Text -> Objective.AssignmentDigest', 'coerce'),
        ('objective MutationFingerprint raw coercion', 'Text -> Objective.MutationFingerprint', 'coerce'),
        ('objective ObjectivePayloadDigest raw coercion', 'Text -> Objective.ObjectivePayloadDigest', 'coerce'),
        ('objective caller/operator substitution', 'Objective.CallerId -> Objective.OperatorId', 'coerce'),
        ('objective commitment substitution', 'Objective.AssignmentDigest -> Objective.MutationFingerprint', 'coerce'),
        ('objective journey/requirement substitution', 'Objective.JourneyEvidence -> Objective.JourneyRequirement', 'id'),
        ('objective service/block substitution', 'Objective.ObjectiveService -> Objective.BlockState', 'id'),
        ('inspection token role substitution', 'Inspection.InspectionCredential "read" -> Inspection.InspectionCredential "write"', 'coerce'),
        ('inspection limit scope substitution', 'Inspection.InspectionLimit "maxViews" -> Inspection.InspectionLimit "maxConnections"', 'coerce'),
        ('inspection limit raw coercion', 'Int -> Inspection.InspectionLimit "maxViews"', 'coerce'),
        ('inspection port raw coercion', 'Int -> Inspection.InspectionPort', 'coerce'),
        ('inspection origin raw coercion', 'Text -> Inspection.InspectionOrigin', 'coerce'),
        ('inspection host raw coercion', 'Text -> Inspection.InspectionHost', 'coerce'),
        ('provider attempt coercion', 'Natural -> RunEvidence.ProviderAttempt', 'coerce'),
        ('measured token coercion', 'Natural -> CallFacts.MeasuredTokens', 'coerce'),
        ('measured cost coercion', 'Rational -> CallFacts.MeasuredMicroUsd', 'coerce'),
        ('provider attempt/token substitution', 'RunEvidence.ProviderAttempt -> CallFacts.MeasuredTokens', 'coerce'),
        ('evidence knowledge/cost substitution', 'CallFacts.RelationshipKnowledge -> CallFacts.CostCertainty', 'id'),
        ('Attestation.MerkleCommitment raw coercion', 'Text -> Attestation.MerkleCommitment', 'coerce'),
        ('Attestation.AttestationSignature raw coercion', 'Text -> Attestation.AttestationSignature', 'coerce'),
        ('Attestation.ReviewClass raw coercion', 'Text -> Attestation.ReviewClass', 'coerce'),
        ('Reviewed.ReviewPath raw coercion', 'Text -> Reviewed.ReviewPath', 'coerce'),
        ('Reviewed.PullRequestRef raw coercion', 'Text -> Reviewed.PullRequestRef', 'coerce'),
        ('compliance/journey verdict substitution', 'Compliance.ComplianceDecision -> Objective.JourneyEvidence', 'id'),
        ('attestation/review label substitution', 'Attestation.ReviewClass -> Reviewed.ReviewPath', 'coerce'),
        ('sink ordinal raw substitution', 'Int -> SinkCoordinate.SinkOrdinal', 'id'),
        ('sink session/workflow substitution', 'SessionId -> WorkflowId', 'id'),
        ('freeze boolean substitution', 'Bool -> WorkspaceStore.FreezeState', 'id'),
        ('freeze boolean coercion', 'Bool -> WorkspaceStore.FreezeState', 'coerce'),
        ('sink message raw coercion', 'Text -> Delivery.SinkMessageId', 'coerce'),
        ('receipt key raw coercion', 'Text -> Delivery.ReceiptKey', 'coerce'),
        ('receipt/message substitution', 'Delivery.SinkMessageId -> Delivery.ReceiptKey', 'coerce'),
        ('reported principal raw coercion', 'Text -> DirectoryStore.ReportedPrincipalClaim', 'coerce'),
        ('payload fingerprint UUID coercion', 'UUID -> Ledger.PayloadFingerprint', 'coerce'),
        ('payload fingerprint raw coercion', 'Text -> Ledger.PayloadFingerprint', 'coerce'),
        ('caller attribution raw coercion', 'Text -> Ledger.CallerAttribution', 'coerce'),
        ('snapshot view coercion', 'Snapshot.ResolvedProfileView -> Snapshot.ResolvedProfile', 'coerce'),
        ('profile digest raw coercion', 'Text -> Profile.ProfileDigest', 'coerce'),
        ('attestation digest raw coercion', 'Text -> Attestation.PayloadDigest', 'coerce'),
        ('attestation version raw coercion', 'Text -> Attestation.SchemaVersion', 'coerce'),
        ('attestation/profile commitment substitution', 'Attestation.PayloadDigest -> Profile.ProfileDigest', 'id'),
        ('attestation/profile commitment coercion', 'Attestation.PayloadDigest -> Profile.ProfileDigest', 'coerce'),
        ('ceiling raw coercion', 'Int -> Policy.Ceiling "calls" Int', 'coerce'),
        ('ceiling unit substitution', 'Policy.Ceiling "calls" Int -> Policy.Ceiling "tokens" Int', 'id'),
        ('ceiling unit coercion', 'Policy.Ceiling "calls" Int -> Policy.Ceiling "tokens" Int', 'coerce'),
        ('permission axis substitution', 'Policy.Permission "aliasesAllowed" -> Policy.Permission "providerFallbackAllowed"', 'id'),
        ('permission axis coercion', 'Policy.Permission "aliasesAllowed" -> Policy.Permission "providerFallbackAllowed"', 'coerce'),
        ('coordinate scope coercion', 'Policy.PolicyCoordinate "signing-key-id" -> Policy.PolicyCoordinate "signature-algorithm"', 'coerce'),
        ('preparation Text', 'Text -> Decision.DecisionPreparationId', 'id'),
        ('preparation coercion', 'Text -> Decision.DecisionPreparationId', 'coerce'),
        ('slot Text', 'Text -> Decision.DecisionSlotLabel', 'id'),
        ('slot coercion', 'Text -> Decision.DecisionSlotLabel', 'coerce'),
        ('generation coercion', 'Natural -> Decision.DecisionGeneration', 'coerce'),
        ('unrelated digest', 'Decision.ProgramParameterDigest -> Decision.DecisionPreparationId', 'id'),
        ('unrelated generation', 'Counter.AttemptCount "selection-calls" -> Decision.DecisionGeneration', 'id')]:
        if not selected(label + ' ' + signature):
            continue
        result = compile('bypass :: ' + signature + '\nbypass = ' + expression + '\n')
        assert result.returncode != 0 and ('record update' in label or 'Not in scope' not in result.stderr), (label, result.stderr)
        if 'record update' in label:
            assert 'value' in result.stderr and 'ambiguous' not in result.stderr.lower(), (label, result.stderr)
        print('opaque boundary: ' + label + ' substitution refused: passed', flush=True)
    for kind, representation in [
        ('SinkCoordinate.SinkOrdinal', 'Int'),
        ('DirectoryStore.ReportedPrincipalClaim', 'Text'),
        ('Ledger.PayloadFingerprint', 'Text'),
        ('Ledger.CallerAttribution', 'Text'),
        ('Snapshot.ResolvedProfile', 'Snapshot.ResolvedProfileView'),
        ('Profile.ProfileDigest', 'Text'),
        ('Attestation.PayloadDigest', 'Text'),
        ('Attestation.SchemaVersion', 'Text'),
        ('Decision.DecisionPreparationId', 'Text'),
        ('Decision.DecisionSlotLabel', 'Text'),
        ('Decision.DecisionGeneration', 'Natural')]:
        if not selected(kind):
            continue
        result = compile('bypass :: ' + representation + ' -> ' + kind + '\nbypass = ' + kind + '\n')
        assert result.returncode != 0 and kind.split('.')[-1] in result.stderr, (kind, result.stderr)
        assert any(fragment in result.stderr.lower() for fragment in ['not in scope', 'does not export', 'illegal term-level use']), (kind, result.stderr)
        print('opaque boundary: ' + kind + ' constructor refused: passed', flush=True)
    result = compile('bypass :: DecisionEvidence.StoredDecisionCall -> Text\nbypass value = value.correlationId\n')
    assert result.returncode != 0 and 'CallCorrelationId' in result.stderr and 'Text' in result.stderr, result.stderr
    print('opaque boundary: stored call retains native correlation: passed', flush=True)
    for field, target in [('runId', 'Text'), ('queueMessageId', 'Int64')]:
        result = compile('bypass :: Ledger.RunRequestRow -> ' + target + '\nbypass value = value.' + field + '\n')
        assert result.returncode != 0 and 'Not in scope' not in result.stderr, result.stderr
        print('opaque boundary: accepted ' + field + ' retains native identity: passed', flush=True)
    for field, native in [('ownerId', 'WorkflowId'), ('ownerName', 'WorkflowName')]:
        result = compile('bypass :: WorkerSession.SessionListener -> Text\nbypass value = value.' + field + '\n')
        assert result.returncode != 0 and native in result.stderr and 'match' in result.stderr, result.stderr
        print('opaque boundary: listener ' + field + ' retains native identity: passed', flush=True)
    for kind, operation in CASES:
        if not selected(kind):
            continue
        if operation == 'parse':
            body = 'bypass :: Aeson.Value -> Parser (' + kind + ')\nbypass = Aeson.genericParseJSON Aeson.defaultOptions\n'
        elif operation == 'render':
            body = 'bypass :: ' + kind + ' -> Aeson.Value\nbypass = Aeson.genericToJSON Aeson.defaultOptions\n'
        else:
            body = 'bypass :: ' + kind + ' -> ()\nbypass value = Generic.from value `seq` ()\n'
        result = compile(body)
        assert result.returncode != 0, (kind, 'generic bypass still compiles')
        assert all(fragment in result.stderr for fragment in ['Generic', kind.split('.')[-1].split()[0]]), (kind, result.stderr)
        print('opaque boundary: ' + kind + ' generic ' + operation + ' refused: passed', flush=True)

    for kind, view in [('Declaration.ValidatedRouterDeclaration', 'Declaration.RouterDeclarationView'), ('Evidence.ValidatedPinnedDiff', 'Evidence.PinnedDiffView')]:
        if not selected(kind):
            continue
        result = compile('bypass :: ' + view + ' -> ' + kind + '\nbypass = ' + kind + '\n')
        assert result.returncode != 0, (kind, 'constructor is public')
        assert kind.split('.')[-1].split()[0] in result.stderr and any(fragment in result.stderr.lower() for fragment in ['not in scope', 'does not export', 'illegal term-level use']), (kind, result.stderr)
        print('opaque boundary: ' + kind + ' constructor refused: passed', flush=True)
        result = compile('bypass :: ' + view + ' -> ' + kind + '\nbypass = coerce\n')
        assert result.returncode != 0, (kind, 'representation coercion is public')
        assert all(name.split('.')[-1] in result.stderr for name in [kind, view]), (kind, result.stderr)
        print('opaque boundary: ' + kind + ' coercion refused: passed', flush=True)
        result = compile('bypass :: Aeson.Value -> Parser ' + kind + '\nbypass = Aeson.parseJSON\n')
        assert result.returncode != 0, (kind, 'context-free JSON admission is public')
        assert all(fragment in result.stderr for fragment in ['FromJSON', kind.split('.')[-1].split()[0]]), (kind, result.stderr)
        print('opaque boundary: ' + kind + ' unchecked JSON refused: passed', flush=True)
