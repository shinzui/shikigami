#!/usr/bin/env python3
"""Relocate the committed Cabal project without inheriting adjacent overrides."""
import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile


def relocate(source: str, root: Path) -> str:
    """Keep all bytes except package path declarations; reject relocation hazards."""
    result = []
    paths = None
    section = False
    section_fields = set()
    seen = set()
    for number, line in enumerate(source.splitlines(keepends=True), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("--"):
            result.append(line)
            continue
        if not line[0].isspace():
            paths = None
            section = False
            match = re.match(r"([a-z][a-z0-9-]*):\s*(.*)", stripped)
            if match:
                key, value = match.groups()
                if key not in {"packages", "optional-packages", "extra-packages", "with-compiler", "index-state", "constraints", "allow-newer"}:
                    raise ValueError(f"line {number}: unsupported project field {key}")
                if key == "with-compiler" and ("/" in value or "$" in value):
                    raise ValueError(f"line {number}: compiler must be a literal executable name")
                if key in {"packages", "optional-packages"}:
                    if key in seen:
                        raise ValueError(f"line {number}: repeated {key} declaration")
                    seen.add(key)
                    paths = key
                    result.append(f"{key}:\n")
                    if not value:
                        continue
                    line = "  " + value + "\n"
                    stripped = value
            elif stripped == "source-repository-package" or re.fullmatch(r"package [A-Za-z0-9*_-]+", stripped):
                section = True
                section_fields = {"type", "location", "tag", "subdir"} if stripped == "source-repository-package" else {"flags", "ghc-options"}
            else:
                raise ValueError(f"line {number}: unsupported Cabal stanza: {stripped}")
        if paths:
            if "--" in stripped or "," in stripped or "{" in stripped or "}" in stripped:
                raise ValueError(f"line {number}: unsupported package path syntax")
            for path in shlex.split(stripped):
                if "://" in path or path.startswith("~") or "$" in path or "\\" in path:
                    raise ValueError(f"line {number}: package path must be a local literal")
                absolute = os.path.normpath(str(root / path))
                # Cabal paths use double quotes when whitespace is present.
                if '"' in absolute or "\n" in absolute:
                    raise ValueError("checkout path cannot contain quotes or newlines")
                result.append('  "' + absolute + '"\n')
        else:
            # Sections and scalar field continuations are preserved verbatim.
            if section and line[0].isspace() and ":" in stripped:
                field, value = stripped.split(":", 1)
                if field not in section_fields:
                    raise ValueError(f"line {number}: unsupported section field {field}")
                if field == "location" and not re.match(r"\s*(https://|git://|ssh://)", value):
                    raise ValueError(f"line {number}: relative repository location unsupported")
            result.append(line)
    if "packages" not in seen:
        raise ValueError("no packages declaration")
    return "".join(result)


def prepare(root: Path, parent: Path | None = None) -> Path:
    source = subprocess.run(["git", "show", "HEAD:cabal.project"], cwd=root,
                            check=True, capture_output=True, text=True).stdout
    output = relocate(source, root)
    directory = Path(tempfile.mkdtemp(prefix="shikigami-qualification-", dir=parent))
    directory.chmod(0o700)
    project = directory / "cabal.project"
    project.write_text(output)
    project.chmod(0o600)
    return project


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--parent", type=Path)
    args = parser.parse_args()
    try:
        print(prepare(args.root.resolve(), args.parent))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"prepare-project: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
