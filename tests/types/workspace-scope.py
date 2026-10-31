#!/usr/bin/env python3
"""A resolved Git root is the only public source of a one-off workspace scope."""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PLAN = json.loads((ROOT / "dist-newstyle/cache/plan.json").read_text())
UNITS = [entry["id"] for entry in PLAN["install-plan"]
         if entry["pkg-name"] == "shikigami-agent" and entry.get("component-name") == "lib"]
assert len(UNITS) == 1, UNITS
HEADER = '''{-# LANGUAGE ImportQualifiedPost #-}
module WorkspaceBoundary where
import Data.Coerce (coerce)
import GHC.Generics qualified as Generic
import Shikigami.Agent.Capability.Workspace qualified as Workspace
'''
POSITIVE = '''resolve :: Maybe FilePath -> IO (Either Workspace.WorkspaceError Workspace.WorkspaceScope)
resolve = Workspace.resolveWorkspaceScope
render :: Workspace.WorkspaceScope -> FilePath
render = Workspace.workspaceRoot
'''
CASES = [
    ("constructor", "bypass :: FilePath -> Workspace.WorkspaceScope\nbypass = Workspace.WorkspaceScope\n", ["WorkspaceScope"], ["not in scope", "does not export", "illegal term-level"]),
    ("coercion", "bypass :: FilePath -> Workspace.WorkspaceScope\nbypass = coerce\n", ["WorkspaceScope"], ["couldn't match", "could not deduce"]),
    ("record update", 'bypass :: Workspace.WorkspaceScope -> Workspace.WorkspaceScope\nbypass scope = scope {Workspace.root = "/"}\n', ["root"], ["not in scope", "does not export"]),
    ("Generic", "bypass :: Workspace.WorkspaceScope -> ()\nbypass scope = Generic.from scope `seq` ()\n", ["Generic", "WorkspaceScope"], ["no instance"]),
]

with tempfile.TemporaryDirectory(prefix="shikigami-workspace-types-") as directory:
    source = Path(directory) / "WorkspaceBoundary.hs"

    def compile_client(body):
        source.write_text(HEADER + body)
        return subprocess.run(["cabal", "exec", "--", "ghc", "-fno-code", "-package-id", UNITS[0], str(source)],
                              cwd=ROOT, capture_output=True, text=True, timeout=45)

    result = compile_client(POSITIVE)
    assert result.returncode == 0, (result.stdout, result.stderr)
    print("workspace scope: public resolver/renderer: passed", flush=True)
    for name, body, fragments, reasons in CASES:
        result = compile_client(body)
        assert result.returncode != 0, (name, "bypass still compiles")
        assert all(fragment in result.stderr for fragment in fragments), (name, result.stderr)
        assert any(reason in result.stderr.lower() for reason in reasons), (name, result.stderr)
        print(f"workspace scope: {name} refused: passed", flush=True)
