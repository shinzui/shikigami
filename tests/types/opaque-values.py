#!/usr/bin/env python3
"""Positive public factories first; generic APIs must not bypass opaque owners."""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PLAN = json.loads((ROOT / "dist-newstyle/cache/plan.json").read_text())
CORE_UNITS = [entry["id"] for entry in PLAN["install-plan"]
              if entry["pkg-name"] == "shikigami-core" and entry.get("component-name") == "lib"]
assert len(CORE_UNITS) == 1, CORE_UNITS
CORE_UNIT = CORE_UNITS[0]
HEADER = '''{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE ImportQualifiedPost #-}
module OpaqueBoundary where
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.Coerce (coerce)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Numeric.Natural (Natural)
import GHC.Generics qualified as Generic
import Keiro.Workflow.Types (WorkflowId)
import Shikigami.Agent.Delegate.Depth qualified as Depth
import Shikigami.Agent.ExpertiseKey qualified as Expertise
import Shikigami.Agent.Name qualified as Name
import Shikigami.Router.SelectionLimit qualified as Limit
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.Agent.Principal qualified as Principal
import Shikigami.App.Config qualified as Config
import Shikigami.Attestation.Envelope qualified as Attestation
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve qualified as Snapshot
import Shikigami.Attestation.PolicyValue qualified as Policy
import Shikigami.Attestation.Reviewed qualified as Reviewed
import Shikigami.Capability.Overlay qualified as Overlay
import Shikigami.AgentRun.Ledger qualified as Ledger
import Shikigami.Sink.Delivery qualified as Delivery
import Shikigami.AgentRun.RequestKey qualified as Request
import Shikigami.Agent.Run.Key qualified as FullKey
import Shikigami.Trigger.RequestKey qualified as Addressed
import Shikigami.Execution.Identity qualified as Entity
import Shikigami.Execution.Claim qualified as Claim
import Shikigami.Execution.Counter qualified as Counter
import Shikigami.Execution.Payload qualified as Payload
import Shikigami.Execution.AssignmentKey qualified as Assignment
import Shikigami.Execution.ToolPosition qualified as Position
import Shikigami.Decision.Contract qualified as Decision
import Shikigami.Decision.Evidence qualified as DecisionEvidence
import Shikigami.Log.Correlation qualified as Correlation
import Shikigami.PracticeReview.IdentityStore qualified as ReviewIdentity
import Shikigami.PracticeReview qualified as Review
import Shikigami.PracticeReview.Evidence qualified as Evidence
import Shikigami.Router.Declaration qualified as Declaration
import Shikigami.Workspace.Instructions qualified as Instructions
import Shikigami.Workspace.Types qualified as Workspace
import Shikigami.Workspace.ProcessPolicy qualified as ProcessPolicy
import Shikigami.Decision.ModelAlias qualified as Alias
import Shikigami.Behavior.Provider.Coordinate qualified as ProviderCoordinate
import Shikigami.Inspection.Settings qualified as Inspection
import Shikigami.Repository qualified as Repository
import Shikigami.Router.Decision qualified as Router
import Shikigami.Sink.Auth qualified as Auth
'''
POSITIVE = '''profileSnapshot :: Profile.SanctionedExecutionProfile -> Snapshot.ResolvedProfile
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
inspection :: Inspection.InspectionCredential -> Text
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
    ('Inspection.InspectionCredential', 'render'),
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
        result = compile('bypass :: ' + signature + '\nbypass = ' + expression + '\n')
        assert result.returncode != 0 and 'Not in scope' not in result.stderr, (label, result.stderr)
        print('opaque boundary: ' + label + ' substitution refused: passed', flush=True)
    for kind, representation in [
        ('Snapshot.ResolvedProfile', 'Snapshot.ResolvedProfileView'),
        ('Profile.ProfileDigest', 'Text'),
        ('Attestation.PayloadDigest', 'Text'),
        ('Attestation.SchemaVersion', 'Text'),
        ('Decision.DecisionPreparationId', 'Text'),
        ('Decision.DecisionSlotLabel', 'Text'),
        ('Decision.DecisionGeneration', 'Natural')]:
        result = compile('bypass :: ' + representation + ' -> ' + kind + '\nbypass = ' + kind + '\n')
        assert result.returncode != 0 and kind.split('.')[-1] in result.stderr, (kind, result.stderr)
        assert any(fragment in result.stderr.lower() for fragment in ['not in scope', 'does not export', 'illegal term-level use']), (kind, result.stderr)
        print('opaque boundary: ' + kind + ' constructor refused: passed', flush=True)
    result = compile('bypass :: DecisionEvidence.StoredDecisionCall -> Text\nbypass value = value.correlationId\n')
    assert result.returncode != 0 and 'CallCorrelationId' in result.stderr and 'Text' in result.stderr, result.stderr
    print('opaque boundary: stored call retains native correlation: passed', flush=True)
    for kind, operation in CASES:
        if operation == 'parse':
            body = 'bypass :: Aeson.Value -> Parser ' + kind + '\nbypass = Aeson.genericParseJSON Aeson.defaultOptions\n'
        elif operation == 'render':
            body = 'bypass :: ' + kind + ' -> Aeson.Value\nbypass = Aeson.genericToJSON Aeson.defaultOptions\n'
        else:
            body = 'bypass :: ' + kind + ' -> ()\nbypass value = Generic.from value `seq` ()\n'
        result = compile(body)
        assert result.returncode != 0, (kind, 'generic bypass still compiles')
        assert all(fragment in result.stderr for fragment in ['Generic', kind.split('.')[-1].split()[0]]), (kind, result.stderr)
        print('opaque boundary: ' + kind + ' generic ' + operation + ' refused: passed', flush=True)

    for kind, view in [('Declaration.ValidatedRouterDeclaration', 'Declaration.RouterDeclarationView'), ('Evidence.ValidatedPinnedDiff', 'Evidence.PinnedDiffView')]:
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
