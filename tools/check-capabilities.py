#!/usr/bin/env python3
"""Check repository evidence and links beyond the shared OKF profile's rules."""

import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "docs/capabilities"
HANDLE = re.compile(r'^capabilityId:\s*[\"\']?(CAP-[0-9]+)[\"\']?\s*$', re.MULTILINE)
LINK = re.compile(r'\[[^\]]+\]\(([^\s)]+)\)')


def okf_json(*arguments):
    result = subprocess.run(
        ["okf", *arguments], cwd=ROOT, capture_output=True, text=True, check=True
    )
    return json.loads(result.stdout)


def repository_file(base, resource):
    """Resolve only inside this repository, including after following symlinks."""
    parsed = urlsplit(resource)
    if parsed.scheme or parsed.netloc:
        return None  # Remote provenance needs independent verification.
    path = Path(unquote(parsed.path))
    if path.is_absolute():
        raise ValueError(f"absolute evidence/link path: {resource}")
    resolved = (base / path).resolve()
    if not resolved.is_relative_to(ROOT):
        raise ValueError(f"evidence/link escapes repository: {resource}")
    if not resolved.is_file():
        raise ValueError(f"missing evidence/link file: {resource}")
    return resolved


def check():
    concepts = okf_json("concepts", "docs/capabilities", "--json")
    graph = okf_json("graph", "docs/capabilities", "--json")
    edges = {(edge["source"], edge["target"]) for edge in graph["edges"]}
    files = {}
    bodies = {}
    for path in sorted(BUNDLE.glob("*.md")):
        if path.name in {"index.md", "log.md"}:
            continue
        raw = path.read_text()
        parts = raw.split("---", 2)
        if len(parts) != 3 or parts[0].strip():
            raise ValueError(f"missing frontmatter: {path.name}")
        match = HANDLE.search(parts[1])
        if not match:
            raise ValueError(f"missing CAP handle: {path.name}")
        handle = match.group(1)
        if handle in files:
            raise ValueError(f"duplicate handle: {handle}")
        files[handle] = path
        bodies[handle] = parts[2]

    if not concepts or len(concepts) != len(files):
        raise ValueError("capability concept/file count mismatch or empty catalog")
    evidence_count = 0
    requirement_count = 0
    for concept in concepts:
        handle = concept["capabilityId"]
        path = files[handle]
        body = bodies[handle]
        local_links = set()
        raw_links = set(LINK.findall(body))
        for link in raw_links:
            if not urlsplit(link).path:
                continue  # Anchor in the same document.
            resolved = repository_file(path.parent, link)
            if resolved is not None:
                local_links.add(resolved)

        evidence = concept["evidence"]
        if not evidence:
            raise ValueError(f"{handle}: evidence must not be empty")
        for entry in evidence:
            resource = entry["resource"]
            resolved = repository_file(ROOT, resource)
            if resolved is not None and resolved not in local_links:
                raise ValueError(f"{handle}: evidence missing a body link: {resource}")
            if resolved is None and resource not in raw_links:
                raise ValueError(f"{handle}: remote evidence missing a body link: {resource}")
            evidence_count += 1

        for requirement in concept.get("requires", []):
            if requirement.startswith("CAP-"):
                target = files[requirement]
                if target not in local_links or (path.stem, target.stem) not in edges:
                    raise ValueError(f"{handle}: missing body/graph dependency: {requirement}")
            elif requirement not in raw_links:
                raise ValueError(f"{handle}: missing external dependency link: {requirement}")
            requirement_count += 1

    print(
        f"OK: {len(concepts)} capabilities, {evidence_count} evidence links, "
        f"{requirement_count} mirrored requirements"
    )


if __name__ == "__main__":
    try:
        check()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"Capability check failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
