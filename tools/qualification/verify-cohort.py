#!/usr/bin/env python3
"""Refuse modified descriptor bytes or missing staged runtime sources."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re


def verify(lock, packages):
    for name, record in lock["packages"].items():
        descriptor = packages / name / f"{name}.cabal"
        if not descriptor.is_file():
            raise ValueError(f"missing package descriptor: {name}")
        if record["source"]["type"] == "hackage":
            actual = "sha256-" + base64.b64encode(hashlib.sha256(descriptor.read_bytes()).digest()).decode()
            if actual != record["source"]["metadata_hash"]:
                raise ValueError(f"Cabal metadata hash mismatch: {name}")


def restrict_components(lock, packages):
    # Cabal treats source packages as local solver goals, including executables
    # that were never part of the solved runtime. Disable only those absent
    # components after verifying the original descriptor. Library dependencies,
    # versions, flags and the selected components' bytes remain unchanged.
    for name, record in lock["packages"].items():
        descriptor = packages / name / f"{name}.cabal"
        selected = set(record["components"])
        lines = descriptor.read_text().splitlines(keepends=True)
        result = []
        disabled = False
        indent = 2
        for line in lines:
            if line and not line[0].isspace() and not line.startswith("--") and line.strip():
                if disabled:
                    result.append(" " * indent + "buildable: False\n\n")
                    disabled = False
                match = re.fullmatch(r"(library|executable)(?:\s+([A-Za-z0-9_.-]+))?", line.strip(), flags=re.IGNORECASE)
                if match:
                    kind, component = match.groups()
                    key = ("lib" if kind.lower() == "library" else "exe") + (":" + component if component else "")
                    disabled = key not in selected
                    indent = 2
            elif disabled and line.strip() and not line.lstrip().startswith("--"):
                indent = min(indent, len(line) - len(line.lstrip()))
            result.append(line)
        if disabled:
            result.append(" " * indent + "buildable: False\n")
        descriptor.write_text("".join(result))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--packages", type=Path, required=True)
    parser.add_argument("--restrict-components", action="store_true")
    args = parser.parse_args()
    try:
        lock = json.loads(args.lock.read_text())
        verify(lock, args.packages)
        if args.restrict_components:
            restrict_components(lock, args.packages)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"verify-cohort: {error}\n")
    print(f"verified {len(lock['packages'])} staged package descriptors")


if __name__ == "__main__":
    main()
