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
import Data.String (fromString)
import Data.Text (Text)
import Shikigami.Agent.Run.Key (RunKey)
import Shikigami.AgentRun.Ledger qualified as Ledger
import Shikigami.AgentRun.RequestKey
import Shikigami.Agent.Principal (AgentPrincipal)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Claim
import Shikigami.Execution.AssignmentKey
import Shikigami.Execution.Selection qualified as Selection
import Shikigami.Objective.Keys qualified as Objective
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
            assert all(fragment in result.stderr for fragment in fragments[name]), (name, result.stderr)
        print(f"revision boundary: {name}: passed")
