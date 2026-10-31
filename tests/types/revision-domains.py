#!/usr/bin/env python3
"""Compile the positive boundary before checking rejected revision substitutions."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HEADER = '''{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedRecordDot #-}
module RevisionBoundary where
import Data.Coerce (coerce)
import Data.Text (Text)
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
import Shikigami.Execution.Progress
import Shikigami.Execution.Policy.Limits
import Shikigami.Execution.Policy.Types qualified as Policy
'''
CASES = [
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
                                 "-package", "shikigami-core", str(source)],
                                cwd=ROOT, capture_output=True, text=True, timeout=45)
        assert (result.returncode == 0) == expected, (name, result.stdout, result.stderr)
        if not expected:
            fragments = {
                "event-is-not-message-sequence": ["Couldn't match type", "worker-message", "worker-event"],
                "execution-root-is-not-execution": ["Couldn't match type", "execution-root", "execution"],
                "operation-is-not-execution-revision": ["Couldn't match type", "execution-operation", "execution"],
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
