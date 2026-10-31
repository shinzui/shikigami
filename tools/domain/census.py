#!/usr/bin/env python3
"""Inventory hand-owned declarations from this candidate's compiled interfaces.

This is an audit worklist, not a domain/boundary classifier or compliance gate.
The source path, source hash and complete compiler-rendered declaration remain
available for semantic review. Never inspect a dependency or store directory.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DECL = re.compile(r"(?m)^  (data|newtype) ([A-Z][\w']*)\b")
ALIAS = re.compile(r"(?m)^  type ([A-Z][\w']*)(?: [^\n=]*)?\s*=", re.M)
END = re.compile(r"(?m)^(?:[0-9a-f]{32}$|  (?:type|data|newtype|class|instance)\b|  [a-zA-Z_$][\w'$]* ::)")
SOURCES = {"src", "inspection", "test-support", "app"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def local_path(path, base):
    if not path.is_relative_to(base) or ".." in path.parts:
        return False
    current = base
    for part in path.relative_to(base).parts:
        current = current / part
        if current.is_symlink():
            return False
    return True


def declarations(text):
    result = []
    for pattern, alias in [(DECL, False), (ALIAS, True)]:
        for match in pattern.finditer(text):
            end = END.search(text, match.end())
            body = text[match.start():end.start() if end else len(text)].strip()
            name = match[1] if alias else match[2]
            result.append({"name": name, "kind": "alias" if alias else match[1],
                           "declaration": "\n".join(line.rstrip() for line in body.splitlines())})
    return sorted(result, key=lambda item: item["name"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-root", type=Path,
                        default=ROOT / "dist-newstyle/build/aarch64-osx/ghc-9.12.4")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    build = args.build_root.absolute()
    assert ".." not in build.parts and build.is_relative_to(ROOT / "dist-newstyle/build"), "only this checkout's build artifacts are allowed"
    current = ROOT
    for part in build.relative_to(ROOT).parts:
        current = current / part
        assert not current.is_symlink(), "a build-root symlink is not an audit input"
    listed = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=ROOT, text=True).splitlines()
    modules = []
    entrypoints = []
    for name in sorted(set(listed)):
        path = Path(name)
        if (path.suffix != ".hs" or len(path.parts) < 3 or
                not path.parts[0].startswith("shikigami-") or
                path.parts[1] not in SOURCES or "Generated" in path.parts or
                any(part.startswith("keiro-dsl-conformance.") for part in path.parts)):
            continue
        source = ROOT / path
        assert local_path(source, ROOT), f"source symlink is not an audit input: {path}"
        if not source.is_file():
            continue  # A removed tracked path during a reviewed move.
        body = source.read_text()
        module = re.search(r"(?m)^module\s+(Shikigami(?:\.\w+)*)\b", body)
        if not module:
            entrypoints.append({"sourcePath": name, "sourceSha256": digest(source.read_bytes()),
                                "declarations": re.findall(r"(?m)^(?:data|newtype|type)\s+([A-Z]\w*)", body)})
            continue
        cabal = ROOT / path.parts[0] / (path.parts[0] + ".cabal")
        assert local_path(cabal, ROOT), "a package descriptor symlink is not an audit input"
        version = re.search(r"(?m)^version:\s*(\S+)", cabal.read_text())
        assert version, (cabal, "missing package version")
        package = build / (path.parts[0] + "-" + version[1])
        assert not package.is_symlink(), "a store/sibling package is not a census input"
        relative = module[1].replace(".", "/") + ".hi"
        if path.parts[1] == "src":
            candidates = [package / "build" / relative]
        elif path.parts[1] in {"inspection", "test-support"}:
            component = path.parts[1]
            candidates = [package / "l" / component / "build" / component / relative]
        else:
            candidates = list((package / "x").rglob(relative))
        candidates = [p for p in candidates if local_path(p, build) and p.is_file()]
        assert len(candidates) == 1, (name, "expected one compiled interface", [str(p) for p in candidates])
        modules.append((name, module[1], candidates[0]))

    def inspect(item):
        name, module, interface = item
        output = subprocess.check_output(["ghc", "--show-iface", str(interface)], cwd=ROOT, text=True)
        return {"sourcePath": name, "sourceSha256": digest((ROOT / name).read_bytes()),
                "module": module, "interfaceSha256": digest(interface.read_bytes()),
                "declarations": declarations(output)}

    with ThreadPoolExecutor(max_workers=2) as executor:
        records = list(executor.map(inspect, modules))
    result = {"schemaVersion": 1, "purpose": "unclassified audit worklist; not a compliance claim",
              "sourceParent": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "buildRoot": str(build.relative_to(ROOT)),
              "compiler": subprocess.check_output(["ghc", "--numeric-version"], text=True).strip(),
              "toolSha256": digest(Path(__file__).read_bytes()), "modules": records,
              "entrypoints": entrypoints}
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Census: {len(records)} modules, {sum(len(m['declarations']) for m in records)} declarations; {len(entrypoints)} role entrypoints separately enumerated.")


if __name__ == "__main__":
    main()
