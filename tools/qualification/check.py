#!/usr/bin/env python3
"""Bounded qualification checks. Raw logs remain in a private evidence directory."""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("prepare_project", Path(__file__).with_name("prepare-project.py"))
project_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(project_module)


def stamp():
    return datetime.now(timezone.utc).isoformat()


def git(*args, cwd=ROOT):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


def private_directory(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or path.stat().st_mode & 0o077:
        raise ValueError(f"artifact directory must be private (chmod 700): {path}")


def run_case(directory, case, command, timeout, env, *, cwd=ROOT):
    started = stamp()
    print(f"{case}: running", flush=True)
    log = directory / f"{case}.log"
    result = {"case": case, "command": command, "started_at": started, "evidence": [log.name]}
    with log.open("x") as output:
        os.chmod(log, 0o600)
        try:
            child = subprocess.Popen(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT,
                                     env=env, start_new_session=True)
            try:
                code = child.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                # This process group belongs exclusively to this check.
                import signal
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
                code = 124
            result.update(exit_code=code, outcome="pass" if code == 0 else "fail",
                          reason="exited zero" if code == 0 else f"exit {code}; inspect private log")
        except FileNotFoundError as error:
            result.update(outcome="blocked", reason=f"required executable unavailable: {error.filename}")
    result["finished_at"] = stamp()
    print(f"{case}: {result['outcome']}", flush=True)
    return result


def baseline(directory, env, timeout):
    project = project_module.prepare(ROOT, directory)
    metadata = {"architecture": platform.machine(), "system": platform.system(),
                "project_file": str(project), "project_source": "HEAD:cabal.project",
                "config_required": False, "sources": []}
    # Record actual mutable sibling sources, rather than implying an immutable build.
    source = project.read_text()
    import shlex
    paths = False
    for line in source.splitlines():
        if line.startswith("packages:"):
            paths = True
            continue
        if line and not line[0].isspace() and not line.startswith("--"):
            paths = False
        if paths and line.strip() and not line.strip().startswith("--"):
            for raw in shlex.split(line):
                package = Path(raw)
                metadata["sources"].append({"package": str(package),
                                            "revision": git("rev-parse", "HEAD", cwd=package),
                                            "dirty": git("status", "--porcelain", cwd=package)})
    (directory / "baseline.json").write_text(json.dumps(metadata, indent=2) + "\n")
    flag = f"--project-file={project}"
    commands = [
        ("compiler", ["ghc", "--numeric-version"]),
        ("cabal", ["cabal", "--version"]),
        ("nix-exports", ["nix", "eval", "--json", ".#packages.aarch64-darwin", "--apply", "builtins.attrNames"]),
        ("nix-default", ["nix", "eval", "--raw", ".#packages.aarch64-darwin.default.drvPath"]),
        ("ambient-solve", ["cabal", "build", "all", "--dry-run"]),
        ("isolated-solve", ["cabal", "build", "all", "--dry-run", flag]),
        ("migration-schema", ["bash", "tools/check-migration-schema-isolation.sh"]),
        ("build", ["cabal", "build", "all", "--enable-tests", flag]),
        ("pure-tests", ["cabal", "test", "shikigami-core-test", "shikigami-workers-test", "shikigami-server-test", "shikigami-migrations-test", flag, "--test-show-details=direct"]),
        ("postgres-tests", ["cabal", "test", "shikigami-core-postgres-test", "shikigami-migrations-smoke", flag, "--test-show-details=direct"]),
        ("workflow-check", ["cabal", "run", "-v0", flag, "keiro-dsl", "--", "check", "domain/shikigami.keiro-workspace", "--min-language", "6", "--deny-warnings", "--explain-bindings", "--report-out", str(directory / "keiro-check.json"), "--coverage-report", str(directory / "keiro-coverage.json"), "--fail-on-opaque"]),
        ("conformance", ["cabal", "test", "keiro-shikigami-conformance", flag, "--test-show-details=direct"]),
    ]
    results = []
    build_ok = False
    for case, command in commands:
        if command[0] == "cabal":
            # Native link dependencies belong to the declared project shell.
            command = ["nix", "develop", "--command", *command]
        if case in {"pure-tests", "postgres-tests", "workflow-check", "conformance"} and not build_ok:
            results.append({"case": case, "outcome": "blocked", "reason": "fresh build did not pass", "command": command, "evidence": []})
        else:
            result = run_case(directory, case, command, timeout, env)
            results.append(result)
            if case == "build":
                build_ok = result["outcome"] == "pass"
        # Write each completed case immediately so an interrupted phase retains evidence.
        (directory / "cases.json").write_text(json.dumps(results, indent=2) + "\n")
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", choices=["baseline", "host", "report", "recovery", "waits"], default="baseline")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, default=3600)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.timeout_seconds <= 0 or args.timeout_seconds > 14400:
            raise ValueError("timeout must be between 1 and 14400 seconds")
        private_directory(args.artifact_dir)
        directory = args.artifact_dir / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + args.phase + "-" + str(os.getpid()))
        private_directory(directory)
        summary = {"revision": git("rev-parse", "HEAD"), "dirty_tree": git("status", "--porcelain"),
                   "phase": args.phase, "started_at": stamp(), "config": str(args.config), "cases": []}
        print(f"Evidence: {directory}", flush=True)
        # Existing integration tests own ephemeral PostgreSQL. Inherited runtime URLs
        # and provider secrets must not select a user's database or paid provider.
        env = {key: value for key, value in os.environ.items() if not key.startswith(("PG", "SHIKIGAMI", "ANTHROPIC", "KIOKU", "SHOMEI", "KIKAN", "KANMON")) and key not in {"DATABASE_URL", "CLAUDE_API_KEY"}}
        if args.phase == "baseline":
            summary["cases"] = baseline(directory, env, args.timeout_seconds)
        else:
            # Never turn missing deployment acceptance into a simulated green phase.
            summary["cases"] = [{"case": "deployment", "outcome": "blocked",
                                  "reason": "immutable role build and validated private deployment inventory are required; live phase not yet implemented", "evidence": []}]
        summary["finished_at"] = stamp()
        outcomes = {case["outcome"] for case in summary["cases"]}
        summary["outcome"] = "fail" if "fail" in outcomes else "blocked" if "blocked" in outcomes else "pass"
        (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(f"{args.phase}: {summary['outcome']}; evidence: {directory / 'summary.json'}")
        return 0 if summary["outcome"] == "pass" else 1
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"qualification: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
