#!/usr/bin/env python3
"""Check source-bound audit coverage; semantic review remains a human obligation."""
import argparse
from collections import Counter
import json
import hashlib
from pathlib import Path
import sys
import re

from census import ROOT, digest, discover_sources, local_path, tool_hashes
from source_declarations import source_declarations

CLASSIFICATIONS = {"domain-value", "owned-identity", "external-identity", "runtime-opaque",
                   "locator", "boundary-dto", "incidental", "structural"}
DISPOSITIONS = {"compliant", "violation", "not-applicable"}
KEY_FIELDS = ("sourcePath", "module", "declaration", "member")
GUIDE_FIELDS = ("source", "sourceRevision", "sourcePath", "sourceSha256")


def checked_file(root, relative, prefix=None):
    path = Path(relative)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"nonlocal evidence path: {relative}")
    target = root / path
    if prefix is not None and not target.is_relative_to(prefix):
        raise ValueError(f"not a checkout-local build artifact: {relative}")
    if not local_path(target, root) or not target.is_file():
        raise ValueError(f"missing or symlinked audit input: {relative}")
    return target


def expected_keys(census, root=ROOT, discover=discover_sources):
    if census.get("schemaVersion") != 2:
        raise ValueError("census schemaVersion must be 2; rebuild and refresh")
    if census.get("toolHashes") != tool_hashes() or census.get("toolSha256") != tool_hashes()["census.py"]:
        raise ValueError("census tool hash drift; refresh with current tools")
    build = root / census["buildRoot"]
    if not build.is_relative_to(root / "dist-newstyle/build") or ".." in build.parts:
        raise ValueError("census build root must be checkout-local")
    records = census["modules"] + census["entrypoints"]
    counts = Counter(record["sourcePath"] for record in records)
    duplicates = [path for path, count in counts.items() if count != 1]
    if duplicates:
        raise ValueError(f"duplicate census sources: {duplicates}")
    current = {str(p) for p in discover(root)}
    if current != set(counts):
        raise ValueError(f"source set drift: missing {sorted(current - set(counts))}, extra {sorted(set(counts) - current)}")
    expected = {}
    for record in records:
        name = record["sourcePath"]
        source = checked_file(root, name)
        if digest(source.read_bytes()) != record["sourceSha256"]:
            raise ValueError(f"source hash drift: {name}")
        module = re.search(r"(?m)^module\s+([A-Z][\w.]*)\b", source.read_text())
        if not module or module[1] != record["module"]:
            raise ValueError(f"source module drift: {name}")
        parsed = source_declarations(source.read_text(), name)
        saved = record["declarations"]
        projection = lambda declarations: [{k: d[k] for k in ["name", "kind", "members", "sourceDeclaration"]}
                                           for d in declarations]
        if projection(parsed) != projection(saved):
            raise ValueError(f"source declaration/member drift: {name}")
        interface = checked_file(root, record["interfacePath"], build)
        package_name = Path(name).parts[0]
        package_dir = interface.relative_to(build).parts[0]
        if not package_dir.startswith(package_name + "-") or not str(interface).endswith(record["module"].replace(".", "/") + ".hi"):
            raise ValueError(f"foreign interface: {name}")
        if digest(interface.read_bytes()) != record["interfaceSha256"]:
            raise ValueError(f"interface hash drift: {name}")
        if record.get("compiledSourceMd5") != hashlib.md5(source.read_bytes()).hexdigest():
            raise ValueError(f"compiled source fingerprint drift: {name}")
        for declaration in parsed:
            for member in ["$self"] + [m["member"] for m in declaration["members"]]:
                key = (name, record["module"], declaration["name"], member)
                if key in expected:
                    raise ValueError(f"duplicate source declaration/member: {key}")
                expected[key] = record["sourceSha256"]
    return expected


def check(classification, census, census_bytes, root=ROOT, require_resolved=False,
          discover=discover_sources):
    if classification.get("schemaVersion") != 1:
        raise ValueError("classification schemaVersion must be 1")
    if classification.get("censusSha256") != digest(census_bytes):
        raise ValueError("classification census hash drift")
    coverage = json.loads(checked_file(root, "docs/architecture/keiro-0.22-coverage.json").read_text())
    guide = next(row for row in coverage["sources"] if row["source"].endswith("/architecture-domain-newtypes-and-typeids"))
    if any(classification.get(k) != guide[k] for k in GUIDE_FIELDS):
        raise ValueError("classification frozen guide identity drift")
    expected = expected_keys(census, root, discover)
    seen, dispositions = set(), Counter()
    for entry in classification["entries"]:
        key = tuple(entry[field] for field in KEY_FIELDS)
        if key in seen:
            raise ValueError(f"duplicate classification key: {key}")
        seen.add(key)
        if key not in expected:
            raise ValueError(f"extra classification key: {key}")
        if entry.get("sourceSha256") != expected[key]:
            raise ValueError(f"classification source hash drift: {key}")
        if entry.get("classification") not in CLASSIFICATIONS:
            raise ValueError(f"unknown classification: {key}")
        if entry.get("disposition") not in DISPOSITIONS:
            raise ValueError(f"pending or unknown disposition: {key}")
        for field in ["invariant", "authority", "boundaryOwner", "rationale"]:
            if not isinstance(entry.get(field), str) or not entry[field].strip():
                raise ValueError(f"missing {field}: {key}")
        if not isinstance(entry.get("evidence"), list) or not entry["evidence"]:
            raise ValueError(f"missing evidence: {key}")
        for evidence in entry["evidence"]:
            if not isinstance(evidence, str) or not evidence.strip():
                raise ValueError(f"invalid evidence: {key}")
            checked_file(root, evidence.split("#", 1)[0])
        dispositions[entry["disposition"]] += 1
    missing = set(expected) - seen
    if missing:
        raise ValueError(f"missing {len(missing)} classification keys: {sorted(missing)[:8]}")
    if require_resolved and dispositions["violation"]:
        raise ValueError(f"unresolved violations: {dispositions['violation']}")
    return dispositions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--classification", type=Path, required=True)
    parser.add_argument("--census", type=Path, required=True)
    parser.add_argument("--require-resolved", action="store_true")
    args = parser.parse_args()
    try:
        census_bytes = args.census.read_bytes()
        counts = check(json.loads(args.classification.read_text()), json.loads(census_bytes),
                       census_bytes, require_resolved=args.require_resolved)
    except (ValueError, KeyError, TypeError, OSError, StopIteration) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"PASS: {sum(counts.values())} classified declarations/members; "
          f"{counts['violation']} violations; no pending entries; source/build/tool hashes fresh.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
