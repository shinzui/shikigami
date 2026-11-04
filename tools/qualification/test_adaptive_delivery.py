import importlib.util
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


class AdaptiveDeliveryTests(unittest.TestCase):
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
            for changes in [{"mode": "live"}, {"max_model_attempts": True}, {"timeout_seconds": 0},
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

    def test_missing_native_prerequisite_cannot_pass_the_fixture(self):
        config = json.loads((driver.FIXTURE / "fixture.yaml").read_text())
        with tempfile.TemporaryDirectory() as raw, patch.object(driver, "run_case", return_value={"state": "blocked"}):
            manifest = driver.qualify(Path(raw), config, "fixture")
            self.assertNotEqual(manifest["state"], "passed")


if __name__ == "__main__":
    unittest.main()
