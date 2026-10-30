#!/usr/bin/env python3
"""Exercise real, built CLI boundaries without a database or vendor process."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
plan = json.loads((ROOT / "dist-newstyle/cache/plan.json").read_text())
binaries = {e["component-name"][4:]: e["bin-file"] for e in plan["install-plan"]
            if e.get("pkg-name", "").startswith("shikigami")
            and e.get("component-name", "").startswith("exe:")}
checks = 0

def run(binary, args, code=0, data=b"", env=None):
    global checks
    result = subprocess.run([binaries[binary], *args, "+RTS", "-N2", "-RTS"],
                            input=data, capture_output=True, timeout=8,
                            env=env, cwd=ROOT)
    assert result.returncode == code, (binary, args, result.returncode,
                                       result.stdout, result.stderr)
    checks += 1
    return result.stdout + result.stderr

with tempfile.TemporaryDirectory(prefix="shikigami-cli-contract-") as directory:
    poison = Path(directory) / "must-not-open.fifo"
    os.mkfifo(poison)
    clean = {key: value for key, value in os.environ.items()
             if not key.startswith(("SHIKIGAMI_", "PG", "DATABASE_URL", "OPENAI_", "ANTHROPIC_"))}
    for binary in ["shikigami", "shikigami-server", "shikigami-worker",
                   "shikigami-scheduler", "shikigami-consume-stream",
                   "shikigami-consume-events", "shikigami-agent-run",
                   "shikigami-run-behavior", "shikigami-agent-launch",
                   "shikigami-client", "shikigami-migrate"]:
        assert b"0.1.0.0" in run(binary, ["--version"], env=clean)
        assert b"Usage:" in run(binary, ["--help"], env=clean)
    for binary, prefix in [("shikigami", []), ("shikigami-client", []),
                           ("shikigami-agent-launch", ["interactive"])]:
        for flag in ["--describe-config", "--describe-config-json"]:
            output = run(binary, prefix + ["--config", str(poison), flag], env=clean)
            assert output
    for shell in ["bash", "zsh", "fish"]:
        output = run("shikigami", [f"--{shell}-completion-script", "shikigami"], env=clean)
        assert b"shikigami" in output
    client = "shikigami-client"
    for flag in ["--check-config", "--explain-config", "--explain-config-json"]:
        run(client, [flag], env=clean)
    run(client, ["--config", str(Path(directory) / "missing"), "--check-config"], 3, env=clean)
    run(client, ["--set", "server.base-url=invalid", "--check-config"], 4, env=clean)
    run(client, ["--not-an-option"], 2, env=clean)
    sentinel = b"PRIVATE_PAYLOAD_SENTINEL"
    for flag in ["--stdin", "--payload"]:
        args = ["runs", "request", "heartbeat", "--key", "unused", flag]
        if flag == "--payload":
            args.append("-")
        assert sentinel not in run(client, args, 1, sentinel, clean)
    oversized = b'{"value":"' + b"x" * (4 * 1024 * 1024) + b'"}'
    output = run(client, ["runs", "request", "heartbeat", "--key", "unused", "--stdin"], 1, oversized, clean)
    assert b"exceeds 4 MiB" in output
print(f"CLI contracts: {checks} real-process checks passed (no database or vendor).")
