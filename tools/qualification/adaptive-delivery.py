#!/usr/bin/env python3
"""Bounded finite delivery qualification; absent native/live proof stays blocked."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "tests/adaptive-delivery"
spec = importlib.util.spec_from_file_location("adaptive_prepare", FIXTURE / "prepare.py")
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


def stamp():
    return datetime.now(timezone.utc).isoformat()


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink() or not path.is_dir() or path.stat().st_mode & 0o077:
        raise ValueError("artifact directory must be a private directory (chmod 700)")


def load_config(path, mode):
    # JSON is an intentionally restricted, dependency-free subset of YAML.
    if path.stat().st_size > 65536:
        raise ValueError("configuration exceeds 64 KiB")
    value = json.loads(path.read_text())
    allowed = {"format", "mode", "timeout_seconds", "max_model_attempts", "repositories", "runtime"}
    if not isinstance(value, dict) or set(value) - allowed:
        raise ValueError("configuration has unknown fields; credentials belong in private runtime configuration")
    if type(value.get("format")) is not int or value["format"] != 1 or value.get("mode") != mode:
        raise ValueError("configuration format or mode differs")
    if value.get("repositories") != prepare.REPOSITORIES:
        raise ValueError("only the two canonical fixture repositories are admitted")
    for field, maximum in [("timeout_seconds", 3600), ("max_model_attempts", 128)]:
        number = value.get(field)
        if type(number) is not int or not 1 <= number <= maximum:
            raise ValueError(f"{field} must be an integer between 1 and {maximum}")
    if "runtime" in value and (not isinstance(value["runtime"], str) or not value["runtime"].startswith("/nix/store/")):
        raise ValueError("runtime must name an explicitly built Nix runtime output")
    return value


def run_case(directory, name, command, timeout, *, cwd=ROOT, expected=0):
    """One owned process group, bounded output, and durable private log."""
    # Do not inherit a runtime database, provider key, Git config, or Python path.
    env = {key: os.environ[key] for key in ["PATH", "HOME", "TMPDIR", "USER", "NIX_SSL_CERT_FILE"]
           if key in os.environ}
    env.update(PYTHONDONTWRITEBYTECODE="1", PYTHONNOUSERSITE="1", TASTY_NUM_THREADS="2")
    log = directory / f"{name}.log"
    started = time.monotonic()
    result = {"case": name, "started_at": stamp(), "log": log.name, "expected_exit": expected}
    with log.open("xb") as output:
        try:
            child = subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, start_new_session=True)
            forced = None
            size = 0
            with selectors.DefaultSelector() as selector:
                selector.register(child.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    if time.monotonic() - started >= timeout:
                        forced = 124
                        break
                    for selected, _ in selector.select(.1):
                        chunk = os.read(selected.fd, 65536)
                        if not chunk:
                            selector.unregister(selected.fileobj)
                            continue
                        output.write(chunk[:max(0, 1048576 - size)])
                        size += len(chunk)
                        if size > 1048576:
                            forced = 125
                            break
                    if forced is not None:
                        break
            if forced is None:
                try:
                    child.wait(timeout=max(.01, timeout - (time.monotonic() - started)))
                except subprocess.TimeoutExpired:
                    forced = 124
            if forced is not None:
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    child.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    pass
                # Also settle descendants after a leader exits on SIGTERM.
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            child.stdout.close()
            code = forced if forced is not None else child.returncode
            child.wait()
            result.update(exit_code=code, state="passed" if code == expected else "failed")
        except FileNotFoundError:
            result.update(state="blocked", reason="required executable unavailable")
    result.update(finished_at=stamp(), elapsed_seconds=round(time.monotonic() - started, 3))
    return result


def fixture_mechanics(directory):
    repositories = prepare.prepare(directory / "repositories")
    cases = [run_case(directory, f"{name}-local", [sys.executable, "-I", "local_check.py"], 30,
                      cwd=directory / "repositories" / name) for name in ["producer", "consumer"]]
    cases.append(run_case(directory, "initial-combined-refusal",
                          [sys.executable, "-I", str(FIXTURE / "journey.py"), "--producer",
                           str(directory / "repositories/producer/record.json"), "--consumer",
                           str(directory / "repositories/consumer/contract.json")], 30, expected=1))
    return repositories, cases


def verify_git_artifacts(directory, combined, records):
    """Restore only returned bundles; never consult guest paths or worker trees."""
    restored = directory / "restored-artifacts"
    restored.mkdir(mode=0o700)
    env = {key: os.environ[key] for key in ["PATH", "TMPDIR"] if key in os.environ}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_TERMINAL_PROMPT="0", GIT_NO_REPLACE_OBJECTS="1")

    def git(repository, *args):
        return subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-C", str(repository), *args],
                              env=env, capture_output=True, check=True, timeout=30).stdout

    exact = {}
    for index, entry in enumerate(records):
        repository = restored / str(index)
        repository.mkdir(mode=0o700)
        bundle = directory / "git-artifacts" / entry["bundle"]
        git(repository, "init", "--bare", "--object-format=sha1")
        heads = git(repository, "bundle", "list-heads", str(bundle)).decode().strip()
        if heads != f"{entry['head']} HEAD":
            raise ValueError("retained bundle HEAD differs from its artifact identity")
        git(repository, "fetch", "--no-tags", str(bundle), "HEAD")
        revision = git(repository, "rev-parse", "FETCH_HEAD^{commit}").decode().strip()
        parents = git(repository, "show", "-s", "--format=%P", revision).decode().strip()
        if revision != entry["head"] or parents != entry["base"]:
            raise ValueError("retained artifact is not a direct commit from its admitted base")
        git(repository, "fsck", "--strict", "--no-reflogs", revision)
        exact[entry["repository"], revision] = repository

    files = {}
    for entry in combined:
        identity = entry["repository"]
        candidate = entry["combined"]
        repository = exact[identity, candidate["result"]]
        tree = git(repository, "rev-parse", candidate["result"] + "^{tree}").decode().strip()
        if tree != candidate["tree"]:
            raise ValueError("returned combined tree differs from the accepted tree")
        # Recompute integration from the independently retained worker commits.
        for worker in entry["workers"]:
            source = exact[identity, worker["revision"]]
            git(repository, "fetch", "--no-tags", str(source), worker["revision"])
        merged = git(repository, "merge-tree", "--write-tree", *[w["revision"] for w in entry["workers"]])
        if merged.decode().strip() != tree:
            raise ValueError("returned combined tree does not integrate the exact worker pair")
        name = "record.json" if identity == prepare.REPOSITORIES[0] else "contract.json"
        content = git(repository, "show", candidate["result"] + ":" + name)
        if len(content) > 4096:
            raise ValueError("returned journey blob exceeds the fixture bound")
        path = restored / name
        path.write_bytes(content)
        files[name] = path
    check = run_case(directory, "returned-exact-pair-journey",
                     [sys.executable, "-I", str(FIXTURE / "journey.py"),
                      "--producer", str(files["record.json"]), "--consumer", str(files["contract.json"])], 10)
    if check["state"] != "passed":
        raise ValueError("journey on independently restored artifacts failed")
    return {"artifacts": len(exact), "worker_pairs_recomputed": len(combined), "journey": check}


def native_evidence(directory, repositories):
    text = (directory / "native.log").read_text()
    matches = re.findall(r"^Private fixture evidence: (/tmp/shikigami-workspace-run\.[a-zA-Z0-9_]+)$", text, re.M)
    if len(matches) != 1:
        raise ValueError("native evidence location missing")
    path = Path(matches[0]) / "evidence/adaptive-evidence.json"
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1048576:
        raise ValueError("native evidence is not a bounded regular artifact")
    value = json.loads(path.read_text())
    combined = value["integrated"]["repositories"]
    if value["format"] != 1 or value["status"] != "Completed" or len(combined) != 2:
        raise ValueError("finite objective did not complete against two integrated repositories")
    if value["sessionMessageResultCounts"] != [4, 5, 5]:
        raise ValueError("native recovery counts differ")
    if value["root"]["active"] != 0 or value["root"]["unknown"] != 0:
        raise ValueError("native root has unsettled work")
    for name in ["producer", "producer-review", "consumer", "consumer-review"]:
        if value["providerCalls"][name] != (4 if name == "consumer" else 2):
            raise ValueError("native provider calls repeated or omitted completed turns")
    starts = {entry["identity"]: entry["base"] for entry in repositories}
    if {entry["repository"] for entry in combined} != set(starts):
        raise ValueError("integrated repositories differ from the admitted fixture")
    for entry in combined:
        base = starts[entry["repository"]]
        validation = entry["validation"]
        candidate = entry["combined"]
        workers = entry["workers"]
        if (entry["base"] != base or candidate["parent"] != base or len(workers) != 2
                or len({worker["operationId"] for worker in workers}) != 2
                or any(worker["base"] != base for worker in workers)
                or any(not re.fullmatch("[0-9a-f]{40}", worker["revision"]) for worker in workers)
                or any(not re.fullmatch("[0-9a-f]{40}", candidate[field]) for field in ["parent", "tree", "result"])
                or type(validation["exitCode"]) is not int or validation["exitCode"] != 0
                or validation["termination"] != "ProcessExited"
                or validation["descendantsEmpty"] is not True or validation["outputComplete"] is not True):
            raise ValueError("native exact artifact or validation evidence is incomplete")
    if value["integrated"]["journey"]["exitCode"] != 0:
        raise ValueError("combined journey failed")
    recovery_path = path.parent / "adaptive-recovery.json"
    if recovery_path.is_symlink() or not recovery_path.is_file() or recovery_path.stat().st_size > 65536:
        raise ValueError("bounded native recovery evidence missing")
    recovery = json.loads(recovery_path.read_text())
    restart = recovery["adaptation_commit_restart"]
    replay = recovery["terminal_replay"]
    if (recovery["format"] != 1 or type(restart["exitCode"]) is not int or restart["exitCode"] != 86
            or restart["markerObserved"] is not True or replay["sameEvidence"] is not True
            or not re.fullmatch("[0-9a-f]{64}", replay["providerCallsBefore"])
            or replay["providerCallsBefore"] != replay["providerCallsAfter"]):
        raise ValueError("native restart or completed replay evidence differs")
    boundaries = recovery["committed_boundary_restarts"]
    if set(boundaries) != {"outcome", "result", "followup"}:
        raise ValueError("native committed-boundary restart evidence missing")
    for name, key in [("outcome", "operationId"), ("result", "assignmentId"), ("followup", "operationId")]:
        case = boundaries[name]
        if (type(case["signal"]) is not int or case["signal"] != 9
                or case["controllerStoppedBeforeSnapshot"] is not True
                or not isinstance(case["records"], list) or not 1 <= len(case["records"]) <= 128
                or any(not isinstance(record, dict) or not isinstance(record.get(key), str)
                       or not record[key] for record in case["records"])):
            raise ValueError("native committed-boundary restart records invalid")
    value["recovery"] = recovery
    archives = path.parent / "adaptive-artifacts"
    inventory = archives / "manifest.json"
    if inventory.is_symlink() or not inventory.is_file() or inventory.stat().st_size > 65536:
        raise ValueError("bounded Git artifact inventory missing")
    captured = json.loads(inventory.read_text())
    required = {(entry["repository"], revision) for entry in combined
                for revision in [entry["combined"]["result"], *[worker["revision"] for worker in entry["workers"]]]}
    records = captured["artifacts"]
    if (captured["format"] != 1 or len(records) != 6
            or {(entry["repository"], entry["head"]) for entry in records} != required
            or len({entry["bundle"] for entry in records}) != 6):
        raise ValueError("not every exact native Git artifact was retained")
    target = directory / "git-artifacts"
    target.mkdir(mode=0o700, exist_ok=True)
    for entry in records:
        if not re.fullmatch(r"workspace-[0-5]\.bundle", entry["bundle"]) or entry["base"] != starts[entry["repository"]]:
            raise ValueError("Git artifact identity differs")
        bundle = archives / entry["bundle"]
        if bundle.is_symlink() or not bundle.is_file() or not 0 < bundle.stat().st_size <= 1048576:
            raise ValueError("Git artifact is not a bounded regular file")
        content = bundle.read_bytes()
        if hashlib.sha256(content).hexdigest() != entry["sha256"]:
            raise ValueError("Git artifact bytes differ from the retained commitment")
        (target / entry["bundle"]).write_bytes(content)
    (target / "manifest.json").write_text(json.dumps(captured, indent=2) + "\n")
    value["git_artifacts"] = captured
    value["returned_artifact_verification"] = verify_git_artifacts(directory, combined, records)
    shutil.copyfile(recovery_path, directory / "native-recovery.json")
    shutil.copyfile(path, directory / "native-evidence.json")
    return value


def qualify(directory, config, mode):
    manifest = {"format": 1, "mode": mode, "state": "blocked", "started_at": stamp(),
                "scope": "finite isolated fixture; local edits/tests only; no recurrence or publication",
                "cases": [], "limitations": [], "repositories": []}
    if "runtime" in config:
        manifest["runtime"] = config["runtime"]
    try:
        manifest["source_revision"] = prepare.git(ROOT, "rev-parse", "HEAD")
        manifest["source_dirty"] = bool(prepare.git(ROOT, "status", "--porcelain"))
        manifest["repositories"], manifest["cases"] = fixture_mechanics(directory)
        if any(case["state"] != "passed" for case in manifest["cases"]):
            manifest["state"] = "failed"
        else:
            if mode == "live":
                manifest["limitations"].append(
                    "An explicitly supplied live provider configuration, fresh authorization and enforceable limits are required")
            elif config["max_model_attempts"] != 48:
                manifest["limitations"].append("native fixture currently admits exactly the declared 48-call ceiling")
            elif "runtime" not in config:
                manifest["limitations"].append(
                    "an explicitly built Linux runtime is required; supply runtime in a private configuration before bounded objective admission")
            elif any(shutil.which(name) is None for name in ["container", "nix"]):
                manifest["limitations"].append("the Apple container and Nix executables are required for native qualification")
            else:
                command = ["bash", "tests/workspace/run-apple.sh", "--adaptive-only"]
                if "runtime" in config:
                    command.append(config["runtime"])
                case = run_case(directory, "native", command, config["timeout_seconds"])
                manifest["cases"].append(case)
                if case["state"] == "passed":
                    manifest["native"] = native_evidence(directory, manifest["repositories"])
                else:
                    manifest["state"] = case["state"]
                manifest["limitations"].append(
                    "The complete coupled fault/refusal matrix remains required before fixture qualification passes")
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        # Configuration or exception representations can contain private values.
        manifest["state"] = "failed"
        manifest["limitations"].append("fixture preparation failed; no native delivery is claimed")
    manifest["finished_at"] = stamp()
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["fixture", "live"], required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        private_directory(args.artifact_dir)
        directory = args.artifact_dir.resolve() / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + "-" + args.mode)
        directory.mkdir(mode=0o700)
        try:
            config = load_config(args.config, args.mode)
        except (OSError, ValueError, TypeError):
            manifest = {"format": 1, "mode": args.mode, "state": "blocked", "cases": [],
                        "limitations": ["explicit valid configuration is missing; no runtime was started"]}
        else:
            manifest = qualify(directory, config, args.mode)
        (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"{manifest['state']}; evidence: {directory / 'manifest.json'}")
        return {"passed": 0, "failed": 1, "blocked": 2}[manifest["state"]]
    except (OSError, ValueError):
        parser.exit(2, "private artifact directory unavailable\n")


if __name__ == "__main__":
    sys.exit(main())
