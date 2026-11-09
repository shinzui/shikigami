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
                            {"repositories": ["/user/repo"]}, {"runtime": "/user/executable"},
                            {"scenario": "unqualified"}, {"scenario": True}]:
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
        config = json.loads((driver.FIXTURE / "fixture.yaml").read_text()) | {
            "runtime": "/nix/store/" + "a" * 32 + "-fixture", "scenario": "baseline"}
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
        value = {"format": 1, "status": "Completed", "rootId": "same-root", "sessionMessageResultCounts": [4, 5, 5],
                 "root": {"active": 0, "unknown": 0},
                 "providerCalls": {name: (4 if name == "consumer" else 2)
                                   for name in ["producer", "producer-review", "consumer", "consumer-review"]},
                 "integrated": {"journey": {"exitCode": 0}, "repositories": combined}}
        artifact = evidence / "adaptive-evidence.json"
        artifact.write_text(json.dumps(value))
        (evidence / "adaptive-recovery.json").write_text(json.dumps({
            "format": 1, "adaptation_commit_restart": {"exitCode": 86, "markerObserved": True},
            "committed_boundary_restarts": {
                "outcome": {"signal": 9, "controllerStoppedBeforeSnapshot": True, "records": [{"operationId": "tool-outcome"}]},
                "result": {"signal": 9, "controllerStoppedBeforeSnapshot": True,
                           "records": [{"assignmentId": "worker-result", "sessionId": "session", "consumedCursor": 2,
                                        "receipt": {"assignmentId": "worker-result", "sessionId": "session", "cursor": 3}}]},
                "followup": {"signal": 9, "controllerStoppedBeforeSnapshot": True,
                             "records": [{"operationId": "accepted-followup", "sequence": 1}]}},
            "action_denial": {"exitCode": 1, "noProviderCalls": True,
                              "authorized": {"tag": "EventsIntegratedReply", "contents": {"tag": "EventsCaughtUp", "contents": 3}},
                              "restored": {"tag": "EventsIntegratedReply", "contents": {"tag": "EventsCaughtUp", "contents": 3}}},
            "worker_selections": self.worker_selections(value),
            "terminal_replay": {"sameEvidence": True, "providerCallsBefore": "a" * 64,
                                "providerCallsAfter": "a" * 64}}))
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

    def test_native_replay_cannot_repeat_provider_work(self):
        with tempfile.TemporaryDirectory() as raw, tempfile.TemporaryDirectory(
                prefix="shikigami-workspace-run.", dir="/tmp") as native:
            path = Path(raw)
            starts, _, _, _ = self.native_artifacts(path, Path(native))
            artifact = Path(native) / "evidence/adaptive-recovery.json"
            value = json.loads(artifact.read_text())
            value["terminal_replay"]["providerCallsAfter"] = "b" * 64
            artifact.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "completed replay evidence differs"):
                driver.native_evidence(path, starts)

    def test_native_restart_requires_a_committed_owner_record(self):
        with tempfile.TemporaryDirectory() as raw, tempfile.TemporaryDirectory(
                prefix="shikigami-workspace-run.", dir="/tmp") as native:
            path = Path(raw)
            starts, _, _, _ = self.native_artifacts(path, Path(native))
            artifact = Path(native) / "evidence/adaptive-recovery.json"
            value = json.loads(artifact.read_text())
            for records in [[], ["not an owner record"]]:
                value["committed_boundary_restarts"]["outcome"]["records"] = records
                artifact.write_text(json.dumps(value))
                with self.assertRaisesRegex(ValueError, "restart records invalid"):
                    driver.native_evidence(path, starts)

    def test_native_authority_refusal_requires_the_same_command_to_pass_with_authority(self):
        with tempfile.TemporaryDirectory() as raw, tempfile.TemporaryDirectory(
                prefix="shikigami-workspace-run.", dir="/tmp") as native:
            path = Path(raw)
            starts, _, _, _ = self.native_artifacts(path, Path(native))
            artifact = Path(native) / "evidence/adaptive-recovery.json"
            value = json.loads(artifact.read_text())
            value["action_denial"]["restored"] = {"tag": "EventsUnavailable"}
            artifact.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "identical authorized controls"):
                driver.native_evidence(path, starts)

    def test_native_result_cut_must_precede_its_consumer_integration(self):
        with tempfile.TemporaryDirectory() as raw, tempfile.TemporaryDirectory(
                prefix="shikigami-workspace-run.", dir="/tmp") as native:
            path = Path(raw)
            starts, _, _, _ = self.native_artifacts(path, Path(native))
            artifact = Path(native) / "evidence/adaptive-recovery.json"
            value = json.loads(artifact.read_text())
            value["committed_boundary_restarts"]["result"]["records"][0]["consumedCursor"] = 3
            artifact.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "unconsumed exact receipt"):
                driver.native_evidence(path, starts)

    def test_transfer_selection_cannot_be_satisfied_by_a_legacy_runtime(self):
        config = json.loads((driver.FIXTURE / "fixture.yaml").read_text()) | {
            "scenario": "transfer", "runtime": "/nix/store/" + "a" * 32 + "-fixture"}
        with tempfile.TemporaryDirectory() as raw, \
                patch.object(driver.shutil, "which", return_value="available"), \
                patch.object(driver, "run_case", return_value={"state": "passed"}) as run, \
                patch.object(driver, "native_evidence", return_value={"format": 1, "status": "Completed"}):
            manifest = driver.qualify(Path(raw), config, "fixture")
            self.assertEqual(manifest["state"], "failed")
            self.assertIn("--adaptive-transfer-only", run.call_args.args[2])

    def test_native_ownership_cut_requires_a_fenced_pending_session_and_real_successor(self):
        with tempfile.TemporaryDirectory() as raw, tempfile.TemporaryDirectory(
                prefix="shikigami-workspace-run.", dir="/tmp") as native:
            path = Path(raw)
            starts, value, artifact, _ = self.native_artifacts(path, Path(native))
            workspace = {"provider": "native-workspace", "resource": "retained-workspace"}
            value["format"] = 2
            probes, unknown_restart = self.transfer_probes()
            value.update({key: entry for key, entry in probes.items() if key != "providerCalls"})
            value["providerCalls"].update(consumer=2, **{"consumer-successor": 2})
            value["ownership"] = {
                "intent": {"oldOwner": "original", "newOwner": "successor", "oldEpoch": 0, "newEpoch": 1,
                           "workspace": workspace, "sessionId": "consumer-session", "objective": "objective", "operationId": "transfer"},
                "fence": {"workspace": workspace, "oldEpoch": 0, "newEpoch": 1},
                "receipt": {"objective": "objective", "operationId": "transfer"},
                "sessionOwner": "original", "sessionEpoch": 0,
                "assignment": {"definition": {"owner": "successor"}, "ownerEpoch": 1},
                "oldWriteDenied": True, "earlySuccessorWriteDenied": True}
            recovery_path = Path(native) / "evidence/adaptive-recovery.json"
            recovery = json.loads(recovery_path.read_text())
            recovery["ownership_commit_restart"] = {"exitCode": 91, "markerObserved": True}
            recovery.update(unknown_restart)
            recovery["worker_selections"] = self.worker_selections(value)
            recovery_path.write_text(json.dumps(recovery))
            for changes in [{"sessionOwner": "successor"}, {"oldWriteDenied": False},
                            {"earlySuccessorWriteDenied": False}]:
                altered = copy.deepcopy(value)
                altered["ownership"].update(changes)
                artifact.write_text(json.dumps(altered))
                with self.assertRaisesRegex(ValueError, "fenced owner and successor receipts"):
                    driver.native_evidence(path, starts)
            artifact.write_text(json.dumps(value))
            self.assertEqual(driver.native_evidence(path, starts)["format"], 2)

    @staticmethod
    def worker_selections(value):
        return [{"assignmentId": role + "-assignment", "selection": {
                    "rootId": value["rootId"], "source": "DeclaredAlias", "permittedAliases": [role],
                    "descriptor": {"alias": role, "version": "1", "digest": role + "-digest", "modelId": role,
                                   "provider": "stub", "api": "stub", "endpointClass": "in-process", "thinking": None,
                                   "bindingId": "adaptive-fixture-" + role, "bindingVersion": "1"}},
                 "calls": [{"attemptId": f"{role}-attempt-{n}", "operationId": f"{role}-operation-{n}",
                            "ordinal": n, "rootId": value["rootId"], "phase": "CallTerminal"} for n in range(count)]}
                for role, count in value["providerCalls"].items()]

    def test_worker_calls_must_retain_their_admitted_tuple_and_unique_terminal_receipts(self):
        roles = ["producer", "producer-review", "consumer", "consumer-review"]
        value = {"rootId": "same-root", "providerCalls": dict.fromkeys(roles, 2)}
        recovery = {"worker_selections": self.worker_selections(value)}
        driver.validate_worker_selections(value, recovery, roles)
        mutations = [lambda r: r[0]["selection"]["descriptor"].update(modelId="process-default"),
                     lambda r: r[0]["selection"].update(permittedAliases=roles),
                     lambda r: r[0]["selection"].update(source="ProcessDefault"),
                     lambda r: r[0]["selection"].update(rootId="other-root"),
                     lambda r: r[0]["calls"][1].update(attemptId=r[0]["calls"][0]["attemptId"]),
                     lambda r: r[0]["calls"][0].update(phase="CallTransportUnknown"),
                     lambda r: r[0]["calls"].pop()]
        for mutate in mutations:
            altered = copy.deepcopy(recovery)
            mutate(altered["worker_selections"])
            with self.assertRaises(ValueError):
                driver.validate_worker_selections(value, altered, roles)

    def live_worker_records(self):
        roles = ["producer", "producer-review", "consumer", "consumer-review"]
        # Deliberately vary calls by role and exceed the scripted four-call bound.
        value = {"rootId": "same-root", "providerCalls": dict(zip(roles, [1, 3, 5, 2]))}
        selections = self.worker_selections(value)
        admitted = {}
        for record in selections:
            descriptor = record["selection"]["descriptor"]
            role = descriptor["alias"]
            descriptor.update(provider="anthropic", api="messages", endpointClass="https",
                              modelId="exact-provider-model", bindingId="reviewed-" + role)
            admitted[role] = copy.deepcopy(descriptor)
            for call in record["calls"]:
                call["receipt"] = {"assignmentId": record["assignmentId"], "rootId": value["rootId"],
                                   "ordinal": call["ordinal"], "fingerprint": "request-commitment",
                                   "request": {key: call[key] for key in ["attemptId", "operationId"]}}
                call["outcome"] = {"phase": "CallTerminal", "missing": [],
                                   "reportedModel": descriptor["modelId"], "providerCallId": call["attemptId"],
                                   "known": {"Tokens": 31, "CostMicroUsd": 2}, "compliance": {
                                       "format": 1, "requestedAlias": role,
                                       "requestedModelId": descriptor["modelId"], "resolvedModelId": descriptor["modelId"],
                                       "providerCallId": call["attemptId"], "tokens": 31, "costUncertain": False,
                                       "status": "succeeded", "strength": "model_observed", "thinking": {"requested": None}, "endpoint": {
                                           "provider": "anthropic", "api": "anthropic-messages",
                                           "transport": "http_api", "endpoint": "https://api.example.invalid/v1/messages"}}}
        return value, {"worker_selections": selections}, roles, admitted

    def test_live_workers_match_admission_without_scripted_model_ids_or_call_counts(self):
        value, recovery, roles, admitted = self.live_worker_records()
        driver.validate_worker_selections(value, recovery, roles, admitted=admitted)
        # The fixture path retains its original strict binding requirements.
        with self.assertRaises(ValueError):
            driver.validate_worker_selections(value, recovery, roles)

    def test_scripted_bindings_cannot_supply_live_worker_evidence(self):
        value, recovery, roles, admitted = self.live_worker_records()
        scripted = {"worker_selections": self.worker_selections(value)}
        with self.assertRaises(ValueError):
            driver.validate_worker_selections(value, scripted, roles, admitted=admitted)
        scripted_admission = {r["selection"]["descriptor"]["alias"]: r["selection"]["descriptor"]
                              for r in scripted["worker_selections"]}
        with self.assertRaises(ValueError):
            driver.validate_worker_selections(value, scripted, roles, admitted=scripted_admission)

    def test_live_worker_evidence_rejects_drift_unknown_billing_and_fabricated_receipt_links(self):
        value, recovery, roles, admitted = self.live_worker_records()
        mutations = [lambda r: r["selection"]["descriptor"].update(modelId="other"),
                     lambda r: r["selection"]["descriptor"].update(bindingVersion="other"),
                     lambda r: r["calls"][0]["receipt"].update(rootId="other"),
                     lambda r: r["calls"][0]["receipt"].update(assignmentId="other"),
                     lambda r: r["calls"][0]["receipt"]["request"].update(attemptId="other"),
                     lambda r: r["calls"][0]["outcome"].update(phase="CallTransportUnknown"),
                     lambda r: r["calls"][0]["outcome"].update(missing=["CostMicroUsd"]),
                     lambda r: r["calls"][0]["outcome"].update(providerCallId=""),
                     lambda r: r["calls"][0]["outcome"].update(reportedModel="other"),
                     lambda r: r["calls"][0]["outcome"]["compliance"].update(requestedAlias="other"),
                     lambda r: r["calls"][0]["outcome"]["compliance"].update(tokens=True),
                     lambda r: r["calls"][0]["outcome"]["known"].update(Tokens=32),
                     lambda r: r["calls"][0]["outcome"]["compliance"]["endpoint"].update(provider="other"),
                     lambda r: r["calls"][0]["outcome"]["compliance"]["endpoint"].update(api="openai-responses"),
                     lambda r: r["calls"][0]["outcome"]["compliance"]["endpoint"].update(transport="agent_run"),
                     lambda r: r["calls"][0]["outcome"]["compliance"].update(strength="requested_only"),
                     lambda r: r["calls"][0]["outcome"]["compliance"].update(costUncertain=True),
                     lambda r: r["calls"][0]["outcome"]["compliance"]["thinking"].update(requested="high") ]
        for mutate in mutations:
            altered = copy.deepcopy(recovery)
            mutate(altered["worker_selections"][0])
            with self.assertRaises(ValueError):
                driver.validate_worker_selections(value, altered, roles, admitted=admitted)

    def test_live_envelope_requires_finite_enforced_limits_and_no_held_work(self):
        instant = driver.datetime(2026, 11, 9, tzinfo=driver.timezone.utc)
        limits = {dimension: {"tag": "Limited", "contents": 1000} for dimension in
                  ["ActiveWork", "LifetimeDescendants", "ModelAttempts", "ToolAttempts", "Tokens"]}
        limits["CostMicroUsd"] = {"tag": "ExplicitlyUnbounded"}
        envelope = {"limits": limits, "cutoff": "2026-11-09T00:20:00Z"}
        root = {"envelope": copy.deepcopy(envelope), "active": 0, "unknown": 0,
                "cancelled": False, "overage": False, "usage": {"held": {}, "settled": {"Tokens": 31}}}
        driver.validate_live_root(root, envelope, admitted_at=instant)
        for field in ["active", "unknown", "cancelled", "overage"]:
            altered = copy.deepcopy(root)
            altered[field] = True if field in ["cancelled", "overage"] else 1
            with self.assertRaises(ValueError):
                driver.validate_live_root(altered, envelope, admitted_at=instant)
        for mutate in [lambda e: e["limits"].pop("Tokens"),
                       lambda e: e["limits"].update(Tokens={"tag": "ExplicitlyUnbounded"}),
                       lambda e: e["limits"].update(ModelAttempts={"tag": "Limited", "contents": True}),
                       lambda e: e["limits"].update(CostMicroUsd={"tag": "Limited", "contents": 1}),
                       lambda e: e.update(cutoff="2026-11-08T00:00:00Z"),
                       lambda e: e.update(cutoff="2026-11-09T02:00:00Z")]:
            altered = copy.deepcopy(envelope)
            mutate(altered)
            with self.assertRaises(ValueError):
                driver.validate_live_root(root | {"envelope": altered}, altered, admitted_at=instant)
        changed = copy.deepcopy(root)
        changed["envelope"]["limits"]["ModelAttempts"]["contents"] = 1
        with self.assertRaises(ValueError):
            driver.validate_live_root(changed, envelope, admitted_at=instant)
        for usage in [{"held": {"Tokens": 1}, "settled": {}},
                      {"held": {}, "settled": {"Tokens": 1001}}]:
            with self.assertRaises(ValueError):
                driver.validate_live_root(root | {"usage": usage}, envelope, admitted_at=instant)

    @staticmethod
    def transfer_probes():
        reference = {"attemptId": "edit-attempt", "operationId": "edit-operation", "executionId": "execution"}
        workspace = {"provider": "native-workspace", "resource": "retained-workspace"}
        return {"rootId": "same-root", "objective": "objective", "ownership": {"intent": {
                    "newOwner": "successor", "newEpoch": 1, "sessionId": "consumer-session", "workspace": workspace}}, "completionHold": {
                    "rootId": "same-root", "objective": "objective", "validProposal": True,
                    "unchangedObjective": True, "refusal": {"tag": "ObjectiveUnresolved"}, "activeAtCut": 1, "unknownAtCut": 1,
                    "scope": "resource admission only; no external dispatch"}, "unknown": {
                    "reference": reference, "phase": "AttemptCommitted", "outcome": "outcome-ref", "lateReceipt": "receipt-ref",
                    "observed": {"rootId": "same-root", "reference": reference,
                                 "probe": "production workspace owner; publisher paused", "originalOwnerAdmitted": True,
                                 "sameRootAfterProbe": True,
                                 "successor": "successor", "successorEpoch": 1, "sessionId": "consumer-session", "workspace": workspace,
                                 "root": {"active": 1, "unknown": 1}, "successorWriteDenied": True,
                                 "completionDenied": True, "status": "Open"}},
                "rootRace": {"rootId": "same-root", "accepted": 1, "refused": 1, "activeAtCut": 1,
                             "activeAfter": 0, "unknownAfter": 0, "loserAbsent": True, "sameRootAfterRetry": True,
                             "winner": {"attemptId": "winner", "operationId": "winner-operation"},
                             "loser": {"attemptId": "loser", "operationId": "loser-operation"},
                             "scope": "resource admission only; no external dispatch"},
                "aliasPolicy": {"rootId": "same-root", "allowedAlias": "consumer", "forbiddenAlias": "producer",
                                "admitted": True, "refused": True, "dispatches": 0},
                "targetRefusal": {"rootId": "same-root", "target": "forbidden-role", "refused": True,
                                  "unchangedCheckpoint": True, "sessionsAtCut": 0},
                "initialProcessDefault": "original", "resumedProcessDefault": "forbidden-process-default",
                "providerCalls": {}}, {"unknown_effect_restart": {"exitCode": 92, "markerObserved": True}}

    def test_unknown_edit_requires_the_same_held_root_and_original_receipt(self):
        value, recovery = self.transfer_probes()
        driver.validate_transfer_probes(value, recovery)
        mutations = [lambda v: v["unknown"]["observed"].update(rootId="other-root"),
                     lambda v: v["unknown"]["observed"].update(reference={"attemptId": "different"}),
                     lambda v: v["unknown"]["observed"]["root"].update(unknown=0),
                     lambda v: v["unknown"]["observed"].update(successorWriteDenied=False),
                     lambda v: v["unknown"]["observed"].update(successor="unadmitted-owner"),
                     lambda v: v["unknown"]["observed"].update(originalOwnerAdmitted=False),
                     lambda v: v["unknown"]["observed"].update(sameRootAfterProbe=False),
                     lambda v: v["unknown"].update(lateReceipt=None),
                     lambda v: v["unknown"].update(phase="AttemptUncertain")]
        for mutate in mutations:
            altered = copy.deepcopy(value)
            mutate(altered)
            with self.assertRaisesRegex(ValueError, "recovered original receipt"):
                driver.validate_transfer_probes(altered, recovery)

    def test_reservations_refusals_and_default_changes_must_match_the_native_root(self):
        value, recovery = self.transfer_probes()
        mutations = [lambda v: v["rootRace"].update(accepted=2),
                     lambda v: v["rootRace"].update(rootId="other-root"),
                     lambda v: v["rootRace"].update(loserAbsent=False),
                     lambda v: v["rootRace"].update(activeAfter=1),
                     lambda v: v["aliasPolicy"].update(dispatches=1),
                     lambda v: v["targetRefusal"].update(unchangedCheckpoint=False),
                     lambda v: v["targetRefusal"].update(sessionsAtCut=1),
                     lambda v: v["completionHold"].update(validProposal=False),
                     lambda v: v["completionHold"].update(refusal="ObjectiveInvalidEvidence"),
                     lambda v: v["completionHold"].update(refusal={"tag": "ObjectiveInvalidEvidence"}),
                     lambda v: v.update(resumedProcessDefault="original"),
                     lambda v: v["providerCalls"].update({"forbidden-process-default": 1})]
        for mutate in mutations:
            altered = copy.deepcopy(value)
            mutate(altered)
            with self.assertRaises(ValueError):
                driver.validate_transfer_probes(altered, recovery)

    def test_missing_native_prerequisite_cannot_pass_the_fixture(self):
        config = json.loads((driver.FIXTURE / "fixture.yaml").read_text())
        with tempfile.TemporaryDirectory() as raw, patch.object(driver, "run_case", return_value={"state": "blocked"}):
            manifest = driver.qualify(Path(raw), config, "fixture")
            self.assertNotEqual(manifest["state"], "passed")

    def test_only_the_verified_full_matrix_can_pass_the_fixture_verdict(self):
        config = json.loads((driver.FIXTURE / "fixture.yaml").read_text()) | {
            "runtime": "/nix/store/" + "a" * 32 + "-fixture"}
        for scenario, version, expected in [("baseline", 1, "blocked"), ("transfer", 2, "passed")]:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as raw, \
                    patch.object(driver.shutil, "which", return_value="available"), \
                    patch.object(driver, "run_case", return_value={"state": "passed"}), \
                    patch.object(driver, "native_evidence", return_value={"format": version, "status": "Completed"}):
                manifest = driver.qualify(Path(raw), config | {"scenario": scenario}, "fixture")
                self.assertEqual(manifest["state"], expected)
                if expected == "passed":
                    self.assertIn("live model/production-authority", manifest["limitations"][0])


if __name__ == "__main__":
    unittest.main()
