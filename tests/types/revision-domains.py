#!/usr/bin/env python3
"""Compile the positive boundary before checking rejected revision substitutions."""
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
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedRecordDot #-}
module RevisionBoundary where
import Data.Coerce (coerce)
import Data.Int (Int64)
import Data.KindID.V7 qualified as KindID
import Data.String (fromString)
import Data.Text (Text)
import Numeric.Natural (Natural)
import Shikigami.PracticeReview qualified as Review
import Shikigami.PracticeReview.Evidence qualified as ReviewEvidence
import Shikigami.Agent.Name qualified as Name
import Shikigami.Agent.ExpertiseKey qualified as Expertise
import Shikigami.Agent.Delegate.Depth qualified as Depth
import Shikigami.Router.SelectionLimit qualified as Limit
import Shikigami.Agent.Decl qualified as Agent
import Shikigami.Router.Decision qualified as Route
import Shikigami.Agent.Run.Key (RunKey)
import Shikigami.Agent.Run.Key qualified as FullKey
import Shikigami.Trigger.RequestKey qualified as Addressed
import Shikigami.Directory.Store qualified as Directory
import Shikigami.AgentRun.Ledger qualified as Ledger
import Shikigami.AgentRun.RequestKey
import Shikigami.Agent.Principal (AgentPrincipal)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Claim
import Shikigami.Execution.Payload qualified as Payload
import Shikigami.Execution.Store qualified as PayloadStore
import Shikigami.Execution.AssignmentKey
import Shikigami.Execution.Selection qualified as Selection
import Shikigami.Objective.Keys qualified as Objective
import Shikigami.Execution.Identity qualified as Entity
import Shikigami.Execution.Counter
import Shikigami.Execution.Quantity
import Shikigami.StateRevision
import Shikigami.WorkerSession.Capability (WorkerCommand (CancelWorker))
import Shikigami.WorkerSession.Input
import Shikigami.WorkerSession.Types (WorkerSessionId)
import Shikigami.WorkerSession.Types qualified as WorkerSession
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.Transcript qualified as Execution
import Shikigami.Execution.SelectionStore qualified as Calls
import Shikigami.Execution.ToolPosition
import Shikigami.Execution.Progress
import Shikigami.Execution.Policy.Limits
import Shikigami.Execution.Policy.Types qualified as Policy
'''
CASES = [
    ('allocated-resource-values', 'root :: Text -> Either Text Entity.ExecutionRootId\nroot = Entity.parseExecutionRootId\nattempt :: Text -> Either Text Entity.AttemptId\nattempt = Entity.parseAttemptId\nallocation :: Text -> Either Text Entity.AllocationId\nallocation = Entity.parseAllocationId\n', True),
    ('resource-ExecutionRootId-constructor', 'value :: KindID.KindID "shikigami_execution_root" -> Entity.ExecutionRootId\nvalue = Entity.ExecutionRootId\n', False),
    ('resource-ExecutionRootId-coercion', 'value :: KindID.KindID "shikigami_execution_root" -> Entity.ExecutionRootId\nvalue = coerce\n', False),
    ('resource-ExecutionRootId-literal', 'value :: Entity.ExecutionRootId\nvalue = fromString "invalid"\n', False),
    ('resource-AttemptId-constructor', 'value :: KindID.KindID "shikigami_execution_attempt" -> Entity.AttemptId\nvalue = Entity.AttemptId\n', False),
    ('resource-AttemptId-coercion', 'value :: KindID.KindID "shikigami_execution_attempt" -> Entity.AttemptId\nvalue = coerce\n', False),
    ('resource-AttemptId-literal', 'value :: Entity.AttemptId\nvalue = fromString "invalid"\n', False),
    ('resource-AllocationId-constructor', 'value :: KindID.KindID "shikigami_execution_allocation" -> Entity.AllocationId\nvalue = Entity.AllocationId\n', False),
    ('resource-AllocationId-coercion', 'value :: KindID.KindID "shikigami_execution_allocation" -> Entity.AllocationId\nvalue = coerce\n', False),
    ('resource-AllocationId-literal', 'value :: Entity.AllocationId\nvalue = fromString "invalid"\n', False),
    ('resource-ExecutionRootId-is-not-AttemptId', 'value :: Entity.ExecutionRootId -> Entity.AttemptId\nvalue = id\n', False),
    ('resource-AttemptId-is-not-AllocationId', 'value :: Entity.AttemptId -> Entity.AllocationId\nvalue = id\n', False),
    ('resource-AllocationId-is-not-ExecutionRootId', 'value :: Entity.AllocationId -> Entity.ExecutionRootId\nvalue = id\n', False),

    ('allocated-review-values', 'parseReview :: Text -> Either Text Review.ReviewId\nparseReview = Review.parseReviewId\nparseResolution :: Text -> Either Text Review.ResolutionId\nparseResolution = Review.parseResolutionId\nidentity :: Review.PracticeReviewVerdict -> Review.ReviewId\nidentity value = value.reviewId\n', True),
    ('review-kindid-coercion', 'value :: KindID.KindID "shikigami_practice_review" -> Review.ReviewId\nvalue = coerce\n', False),
    ('resolution-kindid-coercion', 'value :: KindID.KindID "shikigami_practice_review_resolution" -> Review.ResolutionId\nvalue = coerce\n', False),
    ('review-id-constructor', 'value :: Text -> Review.ReviewId\nvalue = Review.ReviewId\n', False),
    ('resolution-id-constructor', 'value :: Text -> Review.ResolutionId\nvalue = Review.ResolutionId\n', False),
    ('review-id-coercion', 'value :: Text -> Review.ReviewId\nvalue = coerce\n', False),
    ('resolution-id-coercion', 'value :: Text -> Review.ResolutionId\nvalue = coerce\n', False),
    ('review-id-literal', 'value :: Review.ReviewId\nvalue = fromString "invalid"\n', False),
    ('resolution-id-literal', 'value :: Review.ResolutionId\nvalue = fromString "invalid"\n', False),
    ('resolution-is-not-review', 'value :: Review.ResolutionId -> Review.ReviewId\nvalue = id\n', False),
    ('retained-review-scalar-fields', 'practice :: Review.PracticeReviewVerdict -> Review.PracticeKey\npractice value = value.practice\nowner :: Review.PracticeReviewResolution -> Review.OwnerPrincipal\nowner value = value.resolver\nlabel :: Review.EvidenceItem -> Review.EvidenceId\nlabel value = value.evidenceId\nclaim :: Review.PracticeReviewClaim -> Review.ClaimId\nclaim value = value.claimId\nhash :: Review.ContentReference -> Review.ContentHash\nhash value = value.contentHash\nconfidence :: Review.PracticeReviewVerdict -> Review.Confidence\nconfidence value = value.confidence\nrawHash :: ReviewEvidence.PinnedContent -> Text\nrawHash value = value.contentHash\nparsed :: Integer -> Either Text Review.Confidence\nparsed = Review.parseConfidence\n', True),
    ('unchecked-review-PracticeKey-coercion', 'value :: Text -> Review.PracticeKey\nvalue = coerce\n', False),
    ('unchecked-review-PracticeKey-constructor', 'value :: Text -> Review.PracticeKey\nvalue = Review.PracticeKey\n', False),
    ('unchecked-review-PracticeKey-literal', 'value :: Review.PracticeKey\nvalue = fromString "invalid"\n', False),
    ('unchecked-review-OwnerPrincipal-coercion', 'value :: Text -> Review.OwnerPrincipal\nvalue = coerce\n', False),
    ('unchecked-review-OwnerPrincipal-constructor', 'value :: Text -> Review.OwnerPrincipal\nvalue = Review.OwnerPrincipal\n', False),
    ('unchecked-review-OwnerPrincipal-literal', 'value :: Review.OwnerPrincipal\nvalue = fromString "invalid"\n', False),
    ('unchecked-review-EvidenceId-coercion', 'value :: Text -> Review.EvidenceId\nvalue = coerce\n', False),
    ('unchecked-review-EvidenceId-constructor', 'value :: Text -> Review.EvidenceId\nvalue = Review.EvidenceId\n', False),
    ('unchecked-review-EvidenceId-literal', 'value :: Review.EvidenceId\nvalue = fromString "invalid"\n', False),
    ('unchecked-review-ClaimId-coercion', 'value :: Text -> Review.ClaimId\nvalue = coerce\n', False),
    ('unchecked-review-ClaimId-constructor', 'value :: Text -> Review.ClaimId\nvalue = Review.ClaimId\n', False),
    ('unchecked-review-ClaimId-literal', 'value :: Review.ClaimId\nvalue = fromString "invalid"\n', False),
    ('unchecked-review-ContentHash-coercion', 'value :: Text -> Review.ContentHash\nvalue = coerce\n', False),
    ('unchecked-review-ContentHash-constructor', 'value :: Text -> Review.ContentHash\nvalue = Review.ContentHash\n', False),
    ('unchecked-review-ContentHash-literal', 'value :: Review.ContentHash\nvalue = fromString "invalid"\n', False),
    ('unchecked-review-Confidence-coercion', 'value :: Int -> Review.Confidence\nvalue = coerce\n', False),
    ('unchecked-review-Confidence-constructor', 'value :: Int -> Review.Confidence\nvalue = Review.Confidence\n', False),
    ('unchecked-review-Confidence-literal', 'value :: Review.Confidence\nvalue = -1\n', False),
    ('practice-is-not-owner', 'value :: Review.PracticeKey -> Review.OwnerPrincipal\nvalue = id\n', False),
    ('evidence-is-not-claim', 'value :: Review.EvidenceId -> Review.ClaimId\nvalue = id\n', False),
    ('hash-is-not-evidence', 'value :: Review.ContentHash -> Review.EvidenceId\nvalue = id\n', False),
    ('call-ordinal-is-not-confidence', 'value :: CallOrdinal -> Review.Confidence\nvalue = id\n', False),
    ('execution-uncertainty-and-call-ordinal', 'uncertainty :: Execution.Operation -> Execution.OperationUncertainty\nuncertainty value = value.uncertain\nordinal :: Calls.CallReceipt -> CallOrdinal\nordinal value = value.ordinal\nfirst :: Either Text CallOrdinal\nfirst = nextCallOrdinal noAttempts\n', True),
    ('boolean-is-not-operation-uncertainty', 'value :: Bool -> Execution.OperationUncertainty\nvalue = id\n', False),
    ('cancellation-is-not-operation-uncertainty', 'value :: Resources.Cancellation -> Execution.OperationUncertainty\nvalue = id\n', False),
    ('attempt-count-is-not-call-ordinal', 'value :: AttemptCount "selection-calls" -> CallOrdinal\nvalue = id\n', False),
    ('unchecked-call-ordinal-coercion', 'value :: Int64 -> CallOrdinal\nvalue = coerce\n', False),
    ('unchecked-call-ordinal-constructor', 'value :: Int64 -> CallOrdinal\nvalue = CallOrdinal\n', False),
    ('unchecked-call-ordinal-numeric', 'value :: CallOrdinal\nvalue = 0\n', False),
    ('retained-payload-values', 'locator :: Execution.PayloadRef -> Payload.PayloadId\nlocator ref = ref.payloadId\ndigest :: Execution.PayloadRef -> Payload.PayloadDigest\ndigest ref = ref.digest\nbytes :: Execution.PayloadRef -> Payload.PayloadByteCount\nbytes ref = ref.bytes\nbinding :: PayloadStore.ExecutionBinding -> Payload.PayloadDigest\nbinding ref = ref.snapshotDigest\n', True),
    ('unchecked-PayloadId-coercion', 'value :: Text -> Payload.PayloadId\nvalue = coerce\n', False),
    ('unchecked-PayloadId-constructor', 'value :: Text -> Payload.PayloadId\nvalue = Payload.PayloadId\n', False),
    ('unchecked-PayloadId-literal', 'value :: Payload.PayloadId\nvalue = fromString "value"\n', False),
    ('unchecked-PayloadDigest-coercion', 'value :: Text -> Payload.PayloadDigest\nvalue = coerce\n', False),
    ('unchecked-PayloadDigest-constructor', 'value :: Text -> Payload.PayloadDigest\nvalue = Payload.PayloadDigest\n', False),
    ('unchecked-PayloadDigest-literal', 'value :: Payload.PayloadDigest\nvalue = fromString "value"\n', False),
    ('unchecked-PayloadByteCount-coercion', 'value :: Integer -> Payload.PayloadByteCount\nvalue = coerce\n', False),
    ('unchecked-PayloadByteCount-constructor', 'value :: Integer -> Payload.PayloadByteCount\nvalue = Payload.PayloadByteCount\n', False),
    ('unchecked-PayloadByteCount-literal', 'value :: Payload.PayloadByteCount\nvalue = 1\n', False),
    ('payload-id-is-not-digest', 'value :: Payload.PayloadId -> Payload.PayloadDigest\nvalue key = key\n', False),
    ('resource-amount-is-not-payload-bytes', 'value :: ResourceAmount -> Payload.PayloadByteCount\nvalue amount = amount\n', False),
    ('full-run-key-fields', 'full :: Ledger.RunRequestRow -> RunKey\nfull row = row.runKey\nskip :: Directory.RunSkip -> RunKey\nskip row = row.idempotencyKey\ncaller :: Text -> Either Text Addressed.RequestKey\ncaller = Addressed.parseRequestKey\n', True),
    ('unchecked-full-run-key-coercion', 'value :: Text -> FullKey.RunKey\nvalue = coerce\n', False),
    ('unchecked-full-run-key-constructor', 'value :: Text -> FullKey.RunKey\nvalue = FullKey.RunKey\n', False),
    ('unchecked-full-run-key-literal', 'value :: FullKey.RunKey\nvalue = fromString "key"\n', False),
    ('unchecked-addressed-request-key-coercion', 'value :: Text -> Addressed.RequestKey\nvalue = coerce\n', False),
    ('unchecked-addressed-request-key-constructor', 'value :: Text -> Addressed.RequestKey\nvalue = Addressed.RequestKey\n', False),
    ('unchecked-addressed-request-key-literal', 'value :: Addressed.RequestKey\nvalue = fromString "key"\n', False),
    ('http-request-key-is-not-addressed', 'value :: RequestKey -> Addressed.RequestKey\nvalue key = key\n', False),
    ('full-run-key-is-not-addressed', 'value :: RunKey -> Addressed.RequestKey\nvalue key = key\n', False),
    ("retained-agent-values", '''name :: Agent.AgentDecl -> Name.AgentName
name decl = decl.name
expertise :: Agent.ExpertiseDecl -> Expertise.ExpertiseKey
expertise decl = decl.key
limit :: Agent.RouterPolicy -> Limit.SelectionLimit
limit policy = policy.maxSelections
target :: Route.RouteSelection -> Name.AgentName
target choice = choice.agent
''', True),
    ('unchecked-AgentName-coercion', 'value :: Text -> Name.AgentName\nvalue = coerce\n', False),
    ('unchecked-AgentName-constructor', 'value :: Text -> Name.AgentName\nvalue = Name.AgentName\n', False),
    ('unchecked-AgentName-literal', 'value :: Name.AgentName\nvalue = fromString "fixture"\n', False),
    ('unchecked-ExpertiseKey-coercion', 'value :: Text -> Expertise.ExpertiseKey\nvalue = coerce\n', False),
    ('unchecked-ExpertiseKey-constructor', 'value :: Text -> Expertise.ExpertiseKey\nvalue = Expertise.ExpertiseKey\n', False),
    ('unchecked-ExpertiseKey-literal', 'value :: Expertise.ExpertiseKey\nvalue = fromString "fixture"\n', False),
    ('unchecked-DelegationDepth-coercion', 'value :: Int -> Depth.DelegationDepth\nvalue = coerce\n', False),
    ('unchecked-DelegationDepth-constructor', 'value :: Int -> Depth.DelegationDepth\nvalue = Depth.DelegationDepth\n', False),
    ('unchecked-DelegationDepth-numeric', 'value :: Depth.DelegationDepth\nvalue = 1\n', False),
    ('unchecked-SelectionLimit-coercion', 'value :: Natural -> Limit.SelectionLimit\nvalue = coerce\n', False),
    ('unchecked-SelectionLimit-constructor', 'value :: Natural -> Limit.SelectionLimit\nvalue = Limit.SelectionLimit\n', False),
    ('unchecked-SelectionLimit-numeric', 'value :: Limit.SelectionLimit\nvalue = 1\n', False),
    ("http-request-key", '''key :: Ledger.RunRequestRow -> RequestKey
key row = row.idempotencyKey
''', True),
    ("run-key-is-not-http-request-key", '''key :: RunKey -> RequestKey
key value = value
''', False),
    ("unchecked-http-request-key-coercion", '''key :: Text -> RequestKey
key = coerce
''', False),
    ("unchecked-http-request-key-literal", '''key :: RequestKey
key = fromString "key"
''', False),
    ("attempt-fence", '''generation :: Attempt.AttemptClaim -> StateRevision "execution-attempt"
generation claim = claim.generation
owner :: Attempt.AttemptClaim -> ClaimOwner
owner claim = claim.owner
wake :: Attempt.ExecutionWake -> Int
wake value = value.generation
''', True),
    ("worker-epoch-is-not-attempt-generation", '''generation :: StateRevision "worker-owner" -> StateRevision "execution-attempt"
generation value = value
''', False),
    ("native-generation-is-not-attempt-generation", '''generation :: Attempt.ExecutionWake -> StateRevision "execution-attempt"
generation value = value.generation
''', False),
    ("unchecked-attempt-generation", '''generation :: StateRevision "execution-attempt"
generation = 1
''', False),
    ("principal-is-not-claim-owner", '''owner :: AgentPrincipal -> ClaimOwner
owner value = value
''', False),
    ("unchecked-claim-owner-literal", '''owner :: ClaimOwner
owner = fromString "owner"
''', False),
    ("unchecked-claim-owner-coercion", '''owner :: Text -> ClaimOwner
owner = coerce
''', False),
    ("execution-assignment-key", '''key :: Selection.ExecutionSelection -> AssignmentKey
key selection = selection.assignmentId
''', True),
    ("objective-assignment-is-not-execution-key", '''key :: Objective.ObjectiveAssignmentId -> AssignmentKey
key value = value
''', False),
    ("worker-assignment-is-not-execution-key", '''key :: WorkerSession.AssignmentId -> AssignmentKey
key value = value
''', False),
    ("unchecked-assignment-key-coercion", '''key :: Text -> AssignmentKey
key = coerce
''', False),
    ("tool-position", '''position :: Execution.ToolOperationInput -> ToolPosition
position input = input.position
''', True),
    ("operation-is-not-tool-position", '''position :: Execution.Operation -> ToolPosition
position operation = operation.position
''', False),
    ("unchecked-tool-position-arithmetic", '''position :: ToolPosition
position = 0
''', False),
    ("unchecked-tool-position-coercion", '''position :: Int -> ToolPosition
position = coerce
''', False),
    ("root-cancellation", '''cancel :: Resources.Root -> Resources.Cancellation
cancel root = root.cancelled
''', True),
    ("overage-is-not-cancellation", '''cancel :: Resources.Root -> Resources.Cancellation
cancel root = root.overage
''', False),
    ("execution-termination", '''mode :: Execution.Termination
mode = Execution.StopAsCancelled
''', True),
    ("cancellation-is-not-termination", '''mode :: Resources.Cancellation -> Execution.Termination
mode cancel = cancel
''', False),
    ("worker-assignment-limit", '''limit :: WorkerSession.SessionAdmission -> MaximumAssignments
limit admission = admission.maximumAssignments
capacity :: MaximumSessions
capacity = maximumSessionCapacity
''', True),
    ("mailbox-is-not-assignment-limit", '''limit :: WorkerSession.SessionAdmission -> MaximumAssignments
limit admission = admission.mailboxLimit
''', False),
    ("unchecked-session-limit-arithmetic", '''zero :: MaximumAssignments
zero = 0
''', False),
    ("unchecked-session-limit-coercion", '''unchecked :: Int -> MaximumSessions
unchecked = coerce
''', False),
    ("worker-instruction", '''text :: WorkerSession.Instruction -> InstructionText
text instruction = instruction.text
''', True),
    ("unchecked-instruction-coercion", '''unchecked :: Text -> InstructionText
unchecked = coerce
''', False),
    ("valid", '''value :: StateRevision "objective"
value = advanceRevision initialRevision
number :: Integer
number = revisionNumber value
''', True),
    ("resource-root", '''rootRevision :: Resources.Root -> StateRevision "execution-root"
rootRevision root = root.revision
''', True),
    ("execution-revision", '''executionRevision :: Execution.ExecutionState -> StateRevision "execution"
executionRevision state = state.revision
''', True),
    ("execution-operation-position", '''operationPosition :: Execution.Operation -> StateRevision "execution-operation"
operationPosition operation = operation.position
''', True),
    ("execution-root-is-not-execution", '''executionRevision :: Resources.Root -> StateRevision "execution"
executionRevision root = root.revision
''', False),
    ("operation-is-not-execution-revision", '''executionRevision :: Execution.ExecutionState -> StateRevision "execution"
executionRevision state = state.cursor
''', False),
    ("model-turn-count", '''turns :: Execution.ExecutionState -> ModelTurnCount
turns state = state.modelTurns
''', True),
    ("repair-is-not-turn-count", '''turns :: Execution.ExecutionState -> ModelTurnCount
turns state = state.repairs
''', False),
    ("unchecked-progress-arithmetic", '''large :: PendingReceiptCount
large = 1000001
''', False),
    ("unchecked-progress-coercion", '''unchecked :: Integer -> PendingReceiptCount
unchecked = coerce
''', False),
    ("model-turn-limit", '''turns :: Policy.HarnessPolicy -> ModelTurnLimit
turns policy = policy.maxModelTurns
''', True),
    ("context-is-not-turn-limit", '''turns :: Policy.HarnessPolicy -> ModelTurnLimit
turns policy = policy.contextBytes
''', False),
    ("unchecked-policy-arithmetic", '''zero :: ModelTurnLimit
zero = 0
''', False),
    ("unchecked-policy-coercion", '''unchecked :: Int -> ModelTurnLimit
unchecked = coerce
''', False),
    ("selection-call-limit", '''calls :: Calls.CallLimits -> Maybe (AttemptLimit "selection-calls")
calls limits = limits.calls
''', True),
    ("active-limit-is-not-call-limit", '''calls :: Calls.CallLimits -> Maybe (AttemptLimit "selection-calls")
calls limits = limits.concurrency
''', False),
    ("root-attempt-count", '''active :: Resources.Root -> AttemptCount "root-active"
active root = root.active
''', True),
    ("root-unknown-is-not-active", '''active :: Resources.Root -> AttemptCount "root-active"
active root = root.unknown
''', False),
    ("attempt-count-scope-coercion", '''wrong :: AttemptCount "root-active" -> AttemptCount "root-unknown"
wrong = coerce
''', False),
    ("unchecked-attempt-count", '''negative :: AttemptCount "root-active"
negative = -1
''', False),
    ("resource-amount", '''amount :: Integer -> Either Text ResourceAmount
amount = parseResourceAmount
units :: ResourceAmount -> Integer
units = amountUnits
''', True),
    ("unchecked-resource-arithmetic", '''negative :: ResourceAmount
negative = -1
''', False),
    ("unchecked-resource-coercion", '''unchecked :: Integer -> ResourceAmount
unchecked = coerce
''', False),
    ("wrong-root-revision", '''rootRevision :: Resources.Root -> StateRevision "worker-session"
rootRevision root = root.revision
''', False),
    ("message-sequence", '''messageSequence :: WorkerSession.SessionState -> StateRevision "worker-message"
messageSequence state = state.nextSequence
''', True),
    ("event-is-not-message-sequence", '''eventAsSequence :: WorkerSession.SessionState -> StateRevision "worker-message"
eventAsSequence state = state.eventCursor
''', False),
    ("worker-command", '''command :: WorkerSessionId -> StateRevision "worker-session" -> StateRevision "worker-owner" -> WorkerCommand
command = CancelWorker
''', True),
    ("wrong-worker-revision", '''command :: WorkerSessionId -> StateRevision "objective" -> StateRevision "worker-owner" -> WorkerCommand
command = CancelWorker
''', False),
    ("scope-coercion", '''swapScope :: StateRevision "objective" -> StateRevision "objective-criteria"
swapScope = coerce
''', False),
    ("representation-coercion", '''unchecked :: Integer -> StateRevision "objective"
unchecked = coerce
''', False),
    ("unchecked-arithmetic", '''negative :: StateRevision "objective"
negative = -1
''', False),
]
with tempfile.TemporaryDirectory(prefix="shikigami-revision-types-") as directory:
    for name, body, expected in CASES:
        source = Path(directory) / "RevisionBoundary.hs"
        source.write_text(HEADER + body)
        result = subprocess.run(["cabal", "exec", "--", "ghc", "-fno-code",
                                 "-package-id", CORE_UNIT, str(source)],
                                cwd=ROOT, capture_output=True, text=True, timeout=45)
        assert (result.returncode == 0) == expected, (name, result.stdout, result.stderr)
        if not expected:
            fragments = {
                "run-key-is-not-http-request-key": ["Couldn't match", "RunKey", "RequestKey"],
                "unchecked-http-request-key-coercion": ["RequestKey", "Text"],
                "unchecked-http-request-key-literal": ["RequestKey", "IsString"],
                "worker-epoch-is-not-attempt-generation": ["Couldn't match", "worker-owner", "execution-attempt"],
                "native-generation-is-not-attempt-generation": ["Couldn't match", "StateRevision", "Int"],
                "unchecked-attempt-generation": ["StateRevision", "Num"],
                "principal-is-not-claim-owner": ["Couldn't match", "AgentPrincipal", "ClaimOwner"],
                "unchecked-claim-owner-literal": ["ClaimOwner", "IsString"],
                "unchecked-claim-owner-coercion": ["ClaimOwner", "Text"],
                "objective-assignment-is-not-execution-key": ["Couldn't match", "ObjectiveAssignmentId", "AssignmentKey"],
                "worker-assignment-is-not-execution-key": ["Couldn't match", "AssignmentId", "AssignmentKey"],
                "unchecked-assignment-key-coercion": ["AssignmentKey", "Text"],
                "event-is-not-message-sequence": ["Couldn't match type", "worker-message", "worker-event"],
                "execution-root-is-not-execution": ["Couldn't match type", "execution-root", "execution"],
                "operation-is-not-execution-revision": ["Couldn't match type", "execution-operation", "execution"],
                "operation-is-not-tool-position": ["Couldn't match", "ToolPosition", "StateRevision"],
                "unchecked-tool-position-arithmetic": ["ToolPosition", "Num"],
                "unchecked-tool-position-coercion": ["ToolPosition", "Int"],
                "overage-is-not-cancellation": ["Couldn't match", "Cancellation", "Overage"],
                "cancellation-is-not-termination": ["Couldn't match", "Cancellation", "Termination"],
                "mailbox-is-not-assignment-limit": ["Couldn't match", "MaximumAssignments", "MailboxLimit"],
                "unchecked-session-limit-arithmetic": ["MaximumAssignments", "Num"],
                "unchecked-session-limit-coercion": ["MaximumSessions", "Int"],
                "unchecked-instruction-coercion": ["InstructionText", "Text"],
                "repair-is-not-turn-count": ["Couldn't match", "ModelTurnCount", "RepairCount"],
                "unchecked-progress-arithmetic": ["PendingReceiptCount", "Num"],
                "unchecked-progress-coercion": ["PendingReceiptCount", "Integer"],
                "context-is-not-turn-limit": ["Couldn't match", "ModelTurnLimit", "ContextByteLimit"],
                "unchecked-policy-arithmetic": ["ModelTurnLimit", "Num"],
                "unchecked-policy-coercion": ["ModelTurnLimit", "Int"],
                "active-limit-is-not-call-limit": ["Couldn't match type", "selection-active", "selection-calls"],
                "root-unknown-is-not-active": ["Couldn't match type", "root-active", "root-unknown"],
                "attempt-count-scope-coercion": ["Couldn't match type", "root-active", "root-unknown"],
                "unchecked-attempt-count": ["AttemptCount", "Num"],
                "unchecked-resource-arithmetic": ["ResourceAmount", "Num"],
                "unchecked-resource-coercion": ["ResourceAmount", "Integer"],
                "wrong-root-revision": ["Couldn't match type", "worker-session", "execution-root"],
                "wrong-worker-revision": ["Couldn't match type", "worker-session", "objective"],
                "scope-coercion": ["Couldn't match type", "objective", "objective-criteria"],
                "representation-coercion": ["StateRevision", "Integer"],
                "unchecked-arithmetic": ["StateRevision", "Num"],
            }
            for kind, raw in [("AgentName", "Text"), ("ExpertiseKey", "Text"), ("DelegationDepth", "Int"), ("SelectionLimit", "Natural")]:
                fragments["unchecked-" + kind + "-coercion"] = [kind, raw]
                fragments["unchecked-" + kind + "-constructor"] = [kind]
                fragments["unchecked-" + kind + ("-literal" if raw == "Text" else "-numeric")] = [kind, "IsString" if raw == "Text" else "Num"]
            fragments.update({'unchecked-full-run-key-coercion': ['RunKey', 'Text'], 'unchecked-full-run-key-constructor': ['RunKey'], 'unchecked-full-run-key-literal': ['RunKey', 'IsString'], 'unchecked-addressed-request-key-coercion': ['RequestKey', 'Text'], 'unchecked-addressed-request-key-constructor': ['RequestKey'], 'unchecked-addressed-request-key-literal': ['RequestKey', 'IsString'], 'http-request-key-is-not-addressed': ["Couldn't match", 'RequestKey'], 'full-run-key-is-not-addressed': ["Couldn't match", 'RunKey', 'RequestKey']})
            fragments.update({'unchecked-PayloadId-coercion': ['PayloadId', 'Text'], 'unchecked-PayloadId-constructor': ['PayloadId'], 'unchecked-PayloadId-literal': ['PayloadId', 'IsString'], 'unchecked-PayloadDigest-coercion': ['PayloadDigest', 'Text'], 'unchecked-PayloadDigest-constructor': ['PayloadDigest'], 'unchecked-PayloadDigest-literal': ['PayloadDigest', 'IsString'], 'unchecked-PayloadByteCount-coercion': ['PayloadByteCount', 'Integer'], 'unchecked-PayloadByteCount-constructor': ['PayloadByteCount'], 'unchecked-PayloadByteCount-literal': ['PayloadByteCount', 'Num'], 'payload-id-is-not-digest': ["Couldn't match", 'PayloadId', 'PayloadDigest'], 'resource-amount-is-not-payload-bytes': ["Couldn't match", 'ResourceAmount', 'PayloadByteCount']})
            fragments.update({'boolean-is-not-operation-uncertainty': ["Couldn't match", 'Bool', 'OperationUncertainty'], 'cancellation-is-not-operation-uncertainty': ["Couldn't match", 'Cancellation', 'OperationUncertainty'], 'attempt-count-is-not-call-ordinal': ["Couldn't match", 'AttemptCount', 'CallOrdinal'], 'unchecked-call-ordinal-coercion': ['Int64', 'CallOrdinal'], 'unchecked-call-ordinal-constructor': ['CallOrdinal'], 'unchecked-call-ordinal-numeric': ['CallOrdinal', 'Num']})
            fragments.update({'resource-ExecutionRootId-constructor': ['ExecutionRootId'], 'resource-ExecutionRootId-coercion': ['ExecutionRootId'], 'resource-ExecutionRootId-literal': ['ExecutionRootId', 'IsString'], 'resource-AttemptId-constructor': ['AttemptId'], 'resource-AttemptId-coercion': ['AttemptId'], 'resource-AttemptId-literal': ['AttemptId', 'IsString'], 'resource-AllocationId-constructor': ['AllocationId'], 'resource-AllocationId-coercion': ['AllocationId'], 'resource-AllocationId-literal': ['AllocationId', 'IsString'], 'resource-ExecutionRootId-is-not-AttemptId': ["Couldn't match", 'ExecutionRootId', 'AttemptId'], 'resource-AttemptId-is-not-AllocationId': ["Couldn't match", 'AttemptId', 'AllocationId'], 'resource-AllocationId-is-not-ExecutionRootId': ["Couldn't match", 'AllocationId', 'ExecutionRootId']})
            fragments.update({'review-kindid-coercion': ['ReviewId'], 'resolution-kindid-coercion': ['ResolutionId'], 'review-id-constructor': ['ReviewId'], 'resolution-id-constructor': ['ResolutionId'], 'review-id-coercion': ['ReviewId', 'Text'], 'resolution-id-coercion': ['ResolutionId', 'Text'], 'review-id-literal': ['ReviewId', 'IsString'], 'resolution-id-literal': ['ResolutionId', 'IsString'], 'resolution-is-not-review': ["Couldn't match", 'ResolutionId', 'ReviewId'], 'unchecked-review-PracticeKey-coercion': ['PracticeKey', 'Text'], 'unchecked-review-PracticeKey-constructor': ['PracticeKey'], 'unchecked-review-PracticeKey-literal': ['PracticeKey', 'IsString'], 'unchecked-review-OwnerPrincipal-coercion': ['OwnerPrincipal', 'Text'], 'unchecked-review-OwnerPrincipal-constructor': ['OwnerPrincipal'], 'unchecked-review-OwnerPrincipal-literal': ['OwnerPrincipal', 'IsString'], 'unchecked-review-EvidenceId-coercion': ['EvidenceId', 'Text'], 'unchecked-review-EvidenceId-constructor': ['EvidenceId'], 'unchecked-review-EvidenceId-literal': ['EvidenceId', 'IsString'], 'unchecked-review-ClaimId-coercion': ['ClaimId', 'Text'], 'unchecked-review-ClaimId-constructor': ['ClaimId'], 'unchecked-review-ClaimId-literal': ['ClaimId', 'IsString'], 'unchecked-review-ContentHash-coercion': ['ContentHash', 'Text'], 'unchecked-review-ContentHash-constructor': ['ContentHash'], 'unchecked-review-ContentHash-literal': ['ContentHash', 'IsString'], 'unchecked-review-Confidence-coercion': ['Confidence', 'Int'], 'unchecked-review-Confidence-constructor': ['Confidence'], 'unchecked-review-Confidence-literal': ['Confidence', 'Num'], 'practice-is-not-owner': ["Couldn't match", 'PracticeKey', 'OwnerPrincipal'], 'evidence-is-not-claim': ["Couldn't match", 'EvidenceId', 'ClaimId'], 'hash-is-not-evidence': ["Couldn't match", 'ContentHash', 'EvidenceId'], 'call-ordinal-is-not-confidence': ["Couldn't match", 'CallOrdinal', 'Confidence']})
            if name.endswith("-constructor"):
                assert any(marker in result.stderr.lower() for marker in ["not in scope", "does not export", "illegal term-level"]), (name, result.stderr)
            assert all(fragment in result.stderr for fragment in fragments[name]), (name, result.stderr)
        print(f"revision boundary: {name}: passed")
