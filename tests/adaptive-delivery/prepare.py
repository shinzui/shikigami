#!/usr/bin/env python3
"""Create deterministic, isolated Git seeds. Never use an operator repository."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
REPOSITORIES = ["mori://fixture/adaptive-producer", "mori://fixture/adaptive-consumer"]


def git(path, *args):
    # Ignore host Git configuration, hooks, credential helpers and signing.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_AUTHOR_NAME="Adaptive fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
               GIT_COMMITTER_NAME="Adaptive fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid",
               GIT_AUTHOR_DATE="2000-01-01T00:00:00Z", GIT_COMMITTER_DATE="2000-01-01T00:00:00Z")
    return subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                           "-C", str(path), *args], env=env, check=True, capture_output=True,
                          text=True, timeout=30).stdout.strip()


def prepare(directory):
    # Exclusive creation makes retries use a fresh attempt, never overwrite work.
    directory.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.mkdir(mode=0o700)
    result = []
    for name, identity in zip(["producer", "consumer"], REPOSITORIES):
        target = directory / name
        target.mkdir()
        for source in sorted((HERE / name).iterdir()):
            if source.is_file():
                shutil.copyfile(source, target / source.name)
                (target / source.name).chmod(0o644)
        git(target, "init", "--initial-branch=main", "--object-format=sha1")
        git(target, "add", "--", ".")
        git(target, "commit", "-m", "test: seed finite adaptive delivery")
        result.append({"identity": identity, "base": git(target, "rev-parse", "HEAD"),
                       "tree": git(target, "rev-parse", "HEAD^{tree}"),
                       "files": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in sorted(target.iterdir()) if p.is_file()}})
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.directory), indent=2))
