import importlib.util
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("adaptive_delivery", HERE / "adaptive-delivery.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
archive_spec = importlib.util.spec_from_file_location("adaptive_archive", driver.FIXTURE / "archive.py")
archive = importlib.util.module_from_spec(archive_spec)
archive_spec.loader.exec_module(archive)


class AdaptiveDeliveryTests(unittest.TestCase):
    def test_git_bundle_restores_the_exact_returned_tree_after_source_removal(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw)
            sources = path / "sources"
            seeds = driver.prepare.prepare(sources)
            producer = sources / "producer"
            (producer / "delivery.txt").write_text("done\n")
            driver.prepare.git(producer, "add", "--", "delivery.txt")
            driver.prepare.git(producer, "commit", "-m", "feat: bounded fixture change")
            tree = driver.prepare.git(producer, "rev-parse", "HEAD^{tree}")
            target = path / "returned.bundle"
            env = {"PATH": os.environ["PATH"], "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
            head, digest = archive.bundle(producer / ".git", target, env)
            self.assertNotEqual(head, seeds[0]["base"])
            self.assertEqual(digest, driver.hashlib.sha256(target.read_bytes()).hexdigest())
            # Rename rather than delete: restoration has only the returned bundle.
            producer.rename(path / "unavailable-source")
            restored = path / "restored"
            restored.mkdir()
            driver.prepare.git(restored, "init")
            driver.prepare.git(restored, "fetch", str(target), "HEAD")
            driver.prepare.git(restored, "checkout", "--detach", "FETCH_HEAD")
            self.assertEqual(driver.prepare.git(restored, "rev-parse", "HEAD"), head)
            self.assertEqual(driver.prepare.git(restored, "rev-parse", "HEAD^{tree}"), tree)
            self.assertEqual((restored / "delivery.txt").read_text(), "done\n")

    def test_seeds_are_deterministic_and_sources_stay_clean(self):
        with tempfile.TemporaryDirectory() as raw:
            parent = Path(raw)
            one = driver.prepare.prepare(parent / "one")
            two = driver.prepare.prepare(parent / "two")
            self.assertEqual(one, two)
            self.assertEqual([r["identity"] for r in one], driver.prepare.REPOSITORIES)
            for name in ["producer", "consumer"]:
                self.assertEqual(driver.prepare.git(parent / "one" / name, "status", "--porcelain"), "")
            with self.assertRaises(FileExistsError):
                driver.prepare.prepare(parent / "one")

    def test_local_checks_pass_but_combined_requires_correction(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw)
            _, cases = driver.fixture_mechanics(path)
            self.assertEqual([case["state"] for case in cases], ["passed"] * 3)
            self.assertEqual(cases[-1]["exit_code"], 1)
            consumer = path / "repositories/consumer"
            (consumer / "contract.json").write_text('{"version":2,"path":["value","text"]}\n')
            check = driver.run_case(path, "corrected-journey", [sys.executable, "-I", str(driver.FIXTURE / "journey.py"),
                                      "--producer", str(path / "repositories/producer/record.json"),
                                      "--consumer", str(consumer / "contract.json")], 10)
            self.assertEqual(check["state"], "passed")
            self.assertNotEqual(driver.prepare.git(consumer, "diff"), "")

    def test_private_artifact_directory_refuses_symlink_and_public_mode(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            public = root / "public"
            public.mkdir(mode=0o755)
            with self.assertRaises(ValueError):
                driver.private_directory(public)
            link = root / "link"
            link.symlink_to(root, target_is_directory=True)
            with self.assertRaises(ValueError):
                driver.private_directory(link)

    def test_configuration_rejects_credentials_paths_modes_and_unbounded_limits(self):
        baseline = json.loads((driver.FIXTURE / "fixture.yaml").read_text())
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "config.yaml"
            for changes in [{"mode": "live"}, {"format": True}, {"max_model_attempts": True}, {"timeout_seconds": 0},
                            {"timeout_seconds": 3601}, {"credentials": {"secret": "PRIVATE_MARKER"}},
                            {"repositories": ["/user/repo"]}, {"runtime": "/user/executable"}]:
                path.write_text(json.dumps(baseline | changes))
                with self.subTest(changes=changes), self.assertRaises(ValueError):
                    driver.load_config(path, "fixture")

    def test_missing_configuration_writes_blocked_manifest_without_private_values(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            directory = root / "evidence"
            result = subprocess.run([sys.executable, str(HERE / "adaptive-delivery.py"), "--mode", "live",
                                     "--config", str(root / "PRIVATE_MARKER"), "--artifact-dir", str(directory)],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            manifest = next(directory.glob("*/manifest.json")).read_text()
            self.assertEqual(json.loads(manifest)["state"], "blocked")
            self.assertNotIn("PRIVATE_MARKER", manifest + result.stdout + result.stderr)
            self.assertEqual(next(directory.glob("*/manifest.json")).stat().st_mode & 0o077, 0)

    def test_live_never_falls_back_to_scripted_native_provider(self):
        config = json.loads((driver.FIXTURE / "fixture.yaml").read_text()) | {"mode": "live"}
        with tempfile.TemporaryDirectory() as raw, patch.object(driver, "run_case", wraps=driver.run_case) as run:
            manifest = driver.qualify(Path(raw), config, "live")
            self.assertEqual(manifest["state"], "blocked")
            self.assertEqual(run.call_count, 3)
            self.assertNotIn("native", manifest)

    def test_timeout_stops_owned_process_group_and_retains_failure(self):
        with tempfile.TemporaryDirectory() as raw:
            result = driver.run_case(Path(raw), "timeout", [sys.executable, "-c", "import time; time.sleep(10)"], .1)
            self.assertEqual(result["exit_code"], 124)
            self.assertEqual(result["state"], "failed")

    def test_closed_stdout_does_not_disable_process_deadline(self):
        with tempfile.TemporaryDirectory() as raw:
            result = driver.run_case(Path(raw), "closed", [sys.executable, "-c",
                                    "import os,time; os.close(1); os.close(2); time.sleep(10)"], .1)
            self.assertEqual(result["exit_code"], 124)

    def test_output_bound_does_not_limit_child_artifact_files(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw)
            code = "from pathlib import Path; Path('large-artifact').write_bytes(b'x'*2000000); print('ok')"
            result = driver.run_case(path, "artifact", [sys.executable, "-c", code], 10, cwd=path)
            self.assertEqual(result["state"], "passed")
            self.assertEqual((path / "large-artifact").stat().st_size, 2000000)
            result = driver.run_case(path, "output", [sys.executable, "-c", "print('x'*2000000)"], 10)
            self.assertEqual(result["exit_code"], 125)
            self.assertEqual((path / "output.log").stat().st_size, 1048576)

    def test_a_passing_native_scenario_does_not_close_the_full_fault_gate(self):
        config = json.loads((driver.FIXTURE / "fixture.yaml").read_text()) | {"runtime": "/nix/store/" + "a" * 32 + "-fixture"}
        with tempfile.TemporaryDirectory() as raw, \
                patch.object(driver.shutil, "which", return_value="available"), \
                patch.object(driver, "run_case", return_value={"state": "passed"}), \
                patch.object(driver, "native_evidence", return_value={"status": "Completed"}):
            manifest = driver.qualify(Path(raw), config, "fixture")
            self.assertEqual(manifest["state"], "blocked")
            self.assertEqual(manifest["native"]["status"], "Completed")

    def test_malformed_native_evidence_still_retains_a_failed_manifest(self):
        config = json.loads((driver.FIXTURE / "fixture.yaml").read_text()) | {"runtime": "/nix/store/" + "a" * 32 + "-fixture"}
        with tempfile.TemporaryDirectory() as raw, \
                patch.object(driver.shutil, "which", return_value="available"), \
                patch.object(driver, "run_case", return_value={"state": "passed"}), \
                patch.object(driver, "native_evidence", side_effect=KeyError("PRIVATE_MARKER")):
            manifest = driver.qualify(Path(raw), config, "fixture")
            self.assertEqual(manifest["state"], "failed")
            self.assertNotIn("PRIVATE_MARKER", json.dumps(manifest))

    def test_cold_compilation_is_not_started_inside_the_objective_budget(self):
        config = json.loads((driver.FIXTURE / "fixture.yaml").read_text())
        with tempfile.TemporaryDirectory() as raw, patch.object(driver, "run_case", wraps=driver.run_case) as run:
            manifest = driver.qualify(Path(raw), config, "fixture")
            self.assertEqual(manifest["state"], "blocked")
            self.assertEqual(run.call_count, 3)
            self.assertNotIn("native", manifest)

    def native_artifacts(self, path, native, *, omit_review=False, stale_consumer=False):
        starts = driver.prepare.prepare(path / "sources")
        (path / "native.log").write_text(f"Private fixture evidence: {native}\n")
        evidence = native / "evidence"
        evidence.mkdir()
        archives = evidence / "adaptive-artifacts"
        archives.mkdir()
        combined, inventory = [], []
        env = {"PATH": os.environ["PATH"], "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
        for name, repo in zip(["producer", "consumer"], starts):
            source = path / "sources" / name
            workers = []
            candidate = None
            for role in ["delivery", "review", "combined"]:
                driver.prepare.git(source, "checkout", "--detach", repo["base"])
                if role in ["delivery", "combined"]:
                    (source / "delivery.txt").write_text("done\n")
                    if name == "consumer" and not stale_consumer:
                        (source / "contract.json").write_text('{"version":2,"path":["value","text"]}\n')
                if role == "review" or (role == "combined" and not omit_review):
                    (source / "review.txt").write_text("done\n")
                driver.prepare.git(source, "add", "--", ".")
                driver.prepare.git(source, "commit", "-m", "feat: " + role)
                bundle = f"workspace-{len(inventory)}.bundle"
                head, digest = archive.bundle(source / ".git", archives / bundle, env)
                inventory.append({"repository": repo["identity"], "base": repo["base"], "head": head,
                                  "bundle": bundle, "sha256": digest})
                if role == "combined":
                    candidate = {"parent": repo["base"], "tree": driver.prepare.git(source, "rev-parse", "HEAD^{tree}"),
                                 "result": head}
                else:
                    workers.append({"operationId": name + "-" + role, "base": repo["base"], "revision": head})
            combined.append({"repository": repo["identity"], "base": repo["base"], "workers": workers,
                             "combined": candidate, "validation": {"exitCode": 0, "termination": "ProcessExited",
                                                                    "descendantsEmpty": True, "outputComplete": True}})
        value = {"format": 1, "status": "Completed", "sessionMessageResultCounts": [4, 5, 5],
                 "root": {"active": 0, "unknown": 0},
                 "providerCalls": {name: (4 if name == "consumer" else 2)
                                   for name in ["producer", "producer-review", "consumer", "consumer-review"]},
                 "integrated": {"journey": {"exitCode": 0}, "repositories": combined}}
        artifact = evidence / "adaptive-evidence.json"
        artifact.write_text(json.dumps(value))
        (archives / "manifest.json").write_text(json.dumps({"format": 1, "artifacts": inventory}))
        return starts, value, artifact, archives

    def test_returned_bundle_bytes_must_be_actual_git_objects(self):
        with tempfile.TemporaryDirectory() as raw, tempfile.TemporaryDirectory(
                prefix="shikigami-workspace-run.", dir="/tmp") as native:
            path = Path(raw)
            starts, _, _, archives = self.native_artifacts(path, Path(native))
            inventory = json.loads((archives / "manifest.json").read_text())
            entry = inventory["artifacts"][0]
            content = b"not a Git bundle, even with a matching digest"
            (archives / entry["bundle"]).write_bytes(content)
            entry["sha256"] = driver.hashlib.sha256(content).hexdigest()
            (archives / "manifest.json").write_text(json.dumps(inventory))
            with self.assertRaises(subprocess.CalledProcessError):
                driver.native_evidence(path, starts)

    def test_returned_combined_tree_must_match_the_accepted_tree(self):
        with tempfile.TemporaryDirectory() as raw, tempfile.TemporaryDirectory(
                prefix="shikigami-workspace-run.", dir="/tmp") as native:
            path = Path(raw)
            starts, value, artifact, _ = self.native_artifacts(path, Path(native))
            value["integrated"]["repositories"][0]["combined"]["tree"] = "0" * 40
            artifact.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "combined tree differs"):
                driver.native_evidence(path, starts)

    def test_returned_combination_must_include_both_exact_workers(self):
        with tempfile.TemporaryDirectory() as raw, tempfile.TemporaryDirectory(
                prefix="shikigami-workspace-run.", dir="/tmp") as native:
            path = Path(raw)
            starts, _, _, _ = self.native_artifacts(path, Path(native), omit_review=True)
            with self.assertRaisesRegex(ValueError, "exact worker pair"):
                driver.native_evidence(path, starts)

    def test_returned_pair_with_obsolete_schema_cannot_claim_a_green_journey(self):
        with tempfile.TemporaryDirectory() as raw, tempfile.TemporaryDirectory(
                prefix="shikigami-workspace-run.", dir="/tmp") as native:
            path = Path(raw)
            starts, _, _, _ = self.native_artifacts(path, Path(native), stale_consumer=True)
            with self.assertRaisesRegex(ValueError, "restored artifacts failed"):
                driver.native_evidence(path, starts)

    def test_native_evidence_refuses_stale_artifacts_duplicates_and_unknown_work(self):
        with tempfile.TemporaryDirectory() as raw, tempfile.TemporaryDirectory(
                prefix="shikigami-workspace-run.", dir="/tmp") as native:
            path = Path(raw)
            starts, value, artifact, archives = self.native_artifacts(path, Path(native))
            verified = driver.native_evidence(path, starts)
            self.assertEqual(verified["status"], "Completed")
            self.assertEqual(verified["returned_artifact_verification"]["artifacts"], 6)
            self.assertEqual(verified["returned_artifact_verification"]["worker_pairs_recomputed"], 2)
            mutations = [lambda v: v["root"].update(unknown=1),
                         lambda v: v["integrated"]["repositories"][0].update(base="0" * 40),
                         lambda v: v["integrated"]["repositories"][0]["workers"][1].update(operationId="producer-delivery"),
                         lambda v: v["integrated"]["repositories"][0]["validation"].update(exitCode=False),
                         lambda v: v["integrated"]["journey"].update(exitCode=1)]
            for mutate in mutations:
                altered = copy.deepcopy(value)
                mutate(altered)
                artifact.write_text(json.dumps(altered))
                with self.assertRaises(ValueError):
                    driver.native_evidence(path, starts)

    def test_missing_native_prerequisite_cannot_pass_the_fixture(self):
        config = json.loads((driver.FIXTURE / "fixture.yaml").read_text())
        with tempfile.TemporaryDirectory() as raw, patch.object(driver, "run_case", return_value={"state": "blocked"}):
            manifest = driver.qualify(Path(raw), config, "fixture")
            self.assertNotEqual(manifest["state"], "passed")


if __name__ == "__main__":
    unittest.main()
