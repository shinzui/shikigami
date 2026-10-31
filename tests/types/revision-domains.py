#!/usr/bin/env python3
"""Compile the positive boundary before checking rejected revision substitutions."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HEADER = '''{-# LANGUAGE DataKinds #-}
module RevisionBoundary where
import Data.Coerce (coerce)
import Shikigami.StateRevision
import Shikigami.WorkerSession.Capability (WorkerCommand (CancelWorker))
import Shikigami.WorkerSession.Types (WorkerSessionId)
'''
CASES = [
    ("valid", '''value :: StateRevision "objective"
value = advanceRevision initialRevision
number :: Integer
number = revisionNumber value
''', True),
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
                "wrong-worker-revision": ["Couldn't match type", "worker-session", "objective"],
                "scope-coercion": ["Couldn't match type", "objective", "objective-criteria"],
                "representation-coercion": ["StateRevision", "Integer"],
                "unchecked-arithmetic": ["StateRevision", "Num"],
            }
            assert all(fragment in result.stderr for fragment in fragments[name]), (name, result.stderr)
        print(f"revision boundary: {name}: passed")
