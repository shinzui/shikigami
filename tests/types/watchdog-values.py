#!/usr/bin/env python3
"""Watchdog public adapters compile; opaque values and authority cannot be forged."""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
plan = json.loads((ROOT / "dist-newstyle/cache/plan.json").read_text())
units = [entry["id"] for entry in plan["install-plan"]
         if entry["pkg-name"] == "shikigami-core" and entry.get("component-name") == "lib"]
assert len(units) == 1, units
# The watchdog vocabulary lives in its flow pack; the probes compile against
# the pack's bodies and library components beside the core.
pack_units = [entry["id"] for entry in plan["install-plan"]
              if entry["pkg-name"] == "flow-pack-watchdog" and entry.get("component-name") in ("lib:bodies", "lib")]
assert len(pack_units) == 2, pack_units
HEADER = '''{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE ImportQualifiedPost #-}
module WatchdogBoundary where
import Data.Aeson qualified as Aeson
import Data.Coerce (coerce)
import Data.Text (Text)
import GHC.Generics qualified as Generics
import Shikigami.Agent.Principal (AgentIdentity)
import FlowPack.Watchdog.Types qualified as Types
import FlowPack.Watchdog.Grant qualified as Grant
import FlowPack.Watchdog.Classify qualified as Classify
import FlowPack.Watchdog.Episode qualified as Episode
import FlowPack.Watchdog.Program.Drift qualified as Drift
import Data.List.NonEmpty (NonEmpty)
'''
POSITIVE = '''
sweep :: Text -> Either Text Types.SweepId
sweep = Types.parseSweepId
subject :: Text -> Either Text Types.Subject
subject = Types.parseSubjectKey
view :: Grant.ObservationGrant -> Grant.GrantSnapshot
view = Grant.snapshotGrant
restore :: Grant.GrantSnapshot -> AgentIdentity -> Maybe Grant.WatchdogSettings -> Either Grant.GrantRefusal Grant.ObservationGrant
restore = Grant.restoreGrant
codec :: Types.FindingView -> Aeson.Value
codec = Aeson.toJSON
summary :: Text -> Either Text Classify.SummaryDigest
summary = Classify.parseSummaryDigest
finding :: Episode.Finding -> Types.FindingView
finding = Episode.findingView
assessment :: Drift.DriftAssessment -> NonEmpty Drift.DriftSubjectAssessment
assessment = Drift.assessmentView
rationale :: Text -> Either Text Drift.Rationale
rationale = Drift.parseRationale
'''
with tempfile.TemporaryDirectory(prefix="shikigami-watchdog-values-") as directory:
    source = Path(directory) / "WatchdogBoundary.hs"
    def compile(body):
        source.write_text(HEADER + body)
        return subprocess.run(["cabal", "exec", "--", "ghc", "-fno-code", "-package-id", units[0], *[flag for unit in pack_units for flag in ("-package-id", unit)], str(source)],
                              cwd=ROOT, capture_output=True, text=True, timeout=45)
    result = compile(POSITIVE)
    assert result.returncode == 0, (result.stdout, result.stderr)
    print("watchdog values: public parsers and views compile", flush=True)
    for module, name in [("Types", "SweepId"), ("Types", "EpisodeId"), ("Types", "FindingId"),
                         ("Types", "MarkDigest"), ("Classify", "SummaryDigest"), ("Types", "SubjectKey"), ("Grant", "ObservationGrant"), ("Episode", "Finding"), ("Drift", "DriftAssessment"), ("Drift", "Rationale")]:
        owner = f"{module}.{name}"
        for label, body in [
            ("constructor", f"bypass = {owner}\n"),
            ("coerce", f"bypass :: Text -> {owner}\nbypass = coerce\n"),
            ("Generic", f"bypass :: {owner} -> {owner}\nbypass = Generics.to . Generics.from\n"),
            ("record update", f"bypass :: {owner} -> Text -> {owner}\nbypass value raw = value {{ {module}.value = raw }}\n"),
        ]:
            result = compile(body)
            assert result.returncode != 0, (owner, label, result.stdout)
            print(f"watchdog values: {owner} {label} refused", flush=True)
    result = compile("bypass :: Aeson.Value -> Aeson.Result Grant.ObservationGrant\nbypass = Aeson.fromJSON\n")
    assert result.returncode != 0 and "FromJSON" in result.stderr, result.stderr
    result = compile("bypass :: Aeson.Value -> Aeson.Result Episode.Finding\nbypass = Aeson.fromJSON\n")
    assert result.returncode != 0 and "FromJSON" in result.stderr, result.stderr
    result = compile("bypass :: Types.FindingView -> Episode.Finding\nbypass = coerce\n")
    assert result.returncode != 0, result.stdout
    result = compile("bypass :: Aeson.Value -> Aeson.Result Drift.DriftAssessment\nbypass = Aeson.fromJSON\n")
    assert result.returncode != 0 and "FromJSON" in result.stderr, result.stderr
    result = compile("bypass :: NonEmpty Drift.DriftSubjectAssessment -> Drift.DriftAssessment\nbypass = coerce\n")
    assert result.returncode != 0, result.stdout
    for target in ['Types.WatchdogLimit "subjects"', 'Types.WatchdogLimit "bytes"', 'Types.WatchdogLimit "drift-subjects"']:
        result = compile(f'bypass :: Types.WatchdogLimit "rows" -> {target}\nbypass = coerce\n')
        assert result.returncode != 0, result.stdout
    print("watchdog values: grant/finding decoding, finding-view coercion and scoped limit substitution refused", flush=True)
