#!/usr/bin/env python3
"""The checked resume policy is constructible only through its public factory."""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
plan = json.loads((ROOT / "dist-newstyle/cache/plan.json").read_text())
units = [entry["id"] for entry in plan["install-plan"]
         if entry["pkg-name"] == "shikigami-workers" and entry.get("component-name") == "lib"]
assert len(units) == 1, units
header = '''{-# LANGUAGE ImportQualifiedPost #-}
module ResumeBoundary where
import Data.Coerce (coerce)
import Data.Text (Text)
import Data.Time (NominalDiffTime)
import GHC.Generics qualified as Generic
import Shikigami.Agent.Workflow.Resume qualified as Resume
'''
with tempfile.TemporaryDirectory(prefix="shikigami-resume-policy-") as directory:
    source = Path(directory) / "ResumeBoundary.hs"

    def compile(body):
        source.write_text(header + body)
        return subprocess.run(
            ["cabal", "exec", "--", "ghc", "-fno-code", "-package-id", units[0], str(source)],
            cwd=ROOT, capture_output=True, text=True, timeout=45)

    positive = compile('checked :: Int -> Int -> Int -> NominalDiffTime -> Either Text Resume.ResumeRetry\nchecked = Resume.mkResumeRetry\nproduction :: Resume.ResumeRetry\nproduction = Resume.defaultResumeRetry\n')
    assert positive.returncode == 0, (positive.stdout, positive.stderr)
    print("resume policy: public factory and production default: passed", flush=True)
    for label, body, expected in [
            ("constructor", 'bypass = Resume.ResumeRetry\n', ["ResumeRetry", "Illegal term-level"]),
            ("Generic", 'bypass :: Resume.ResumeRetry -> ()\nbypass value = Generic.from value `seq` ()\n', ["Generic", "ResumeRetry"]),
            ("representation coercion", 'bypass :: (Int, Int, Int, NominalDiffTime) -> Resume.ResumeRetry\nbypass = coerce\n', ["ResumeRetry", "match"])]:
        result = compile(body)
        assert result.returncode != 0 and all(part in result.stderr for part in expected), (label, result.stderr)
        print("resume policy: " + label + " bypass refused: passed", flush=True)
