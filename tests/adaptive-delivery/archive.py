#!/usr/bin/env python3
"""Retain local Git objects before disposing of the qualification guest.

Read only fixture-owned metadata selected by the authoritative bindings. These
archives are forensic artifacts; they do not settle an unknown tool outcome.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

REPOSITORIES = {"mori://fixture/adaptive-producer", "mori://fixture/adaptive-consumer"}


def bundle(metadata, target, env):
    command = ["git", "-c", "core.hooksPath=/dev/null", "--git-dir", str(metadata)]
    head = subprocess.run([*command, "rev-parse", "HEAD"], capture_output=True, text=True,
                          check=True, env=env, timeout=10).stdout.strip()
    if not re.fullmatch("[a-f0-9]{40}", head):
        raise ValueError("invalid retained HEAD")
    subprocess.run([*command, "bundle", "create", str(target), "HEAD"], capture_output=True,
                   check=True, env=env, timeout=10)
    if target.stat().st_size > 1048576:
        raise ValueError("fixture Git bundle exceeds 1 MiB")
    captured = subprocess.run([*command, "bundle", "list-heads", str(target)], capture_output=True,
                              text=True, check=True, env=env, timeout=10).stdout.strip()
    if captured != f"{head} HEAD":
        raise ValueError("HEAD changed while retaining the artifact")
    return head, hashlib.sha256(target.read_bytes()).hexdigest()


def archive(prefix):
    if not re.fullmatch(r"/var/lib/shikigami-prototype-[a-zA-Z0-9]+", str(prefix)):
        raise ValueError("disposable prefix refused")
    bindings = json.loads((prefix / "adaptive-bindings.json").read_text()) or []
    if len(bindings) > 6:
        raise ValueError("fixture workspace count exceeded")
    directory = prefix / "adaptive-artifacts"
    directory.mkdir(mode=0o700, exist_ok=True)
    entries = []
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
    for index, binding in enumerate(bindings):
        resource = binding["workspace"]["resource"]
        if (binding["repository"] not in REPOSITORIES or not re.fullmatch("[a-f0-9]{64}", resource)
                or binding["storageRoot"] != str(prefix / "workspaces")):
            raise ValueError("workspace binding differs from the disposable fixture")
        metadata = prefix / "workspaces" / resource / "metadata"
        if metadata.is_symlink() or metadata.resolve() != metadata:
            raise ValueError("substituted workspace metadata")
        if not metadata.is_dir():
            # A reserved allocation may never have created its files.
            continue
        target = directory / f"workspace-{index}.bundle"
        head, digest = bundle(metadata, target, env)
        entries.append({"repository": binding["repository"], "base": binding["base"], "head": head,
                        "bundle": target.name, "sha256": digest})
    expected = prefix / "adaptive-evidence.json"
    if expected.is_file():
        facts = json.loads(expected.read_text())
        required = {(entry["repository"], revision) for entry in facts["integrated"]["repositories"]
                    for revision in [entry["combined"]["result"], *[worker["revision"] for worker in entry["workers"]]]}
        if {(entry["repository"], entry["head"]) for entry in entries} != required or len(entries) != 6:
            raise ValueError("Git bundles do not retain every exact worker and integrated revision")
    (directory / "manifest.json").write_text(json.dumps(
        {"format": 1, "scope": "forensic local artifacts; no outcome reconciliation implied", "artifacts": entries},
        indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    archive(args.prefix)
