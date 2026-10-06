#!/usr/bin/env python3
"""Export the resolved runtime closure and exact Cabal metadata for offline packaging.

Run after the isolated build has passed. This consumes the secure Cabal index only
to recover descriptor bytes with the hashes already recorded in the solved plan.
"""
import argparse
import base64
import hashlib
import gzip
import io
import json
from pathlib import Path
import subprocess
import tarfile


def sri(hexadecimal):
    return "sha256-" + base64.b64encode(bytes.fromhex(hexadecimal)).decode()


def closure(plan):
    entries = {entry["id"]: entry for entry in plan["install-plan"]}
    roots = [entry["id"] for entry in entries.values()
             if entry["pkg-name"].startswith("shikigami-")
             and entry.get("component-name", "").split(":")[0] in {"lib", "exe"}]
    pending = roots[:]
    seen = set()
    while pending:
        unit = pending.pop()
        if unit in seen:
            continue
        seen.add(unit)
        entry = entries[unit]
        pending.extend(entry.get("depends", []))
        pending.extend(entry.get("exe-depends", []))
        for component in entry.get("components", {}).values():
            pending.extend(component.get("depends", []))
            pending.extend(component.get("exe-depends", []))
    packages = {}
    for unit in sorted(seen):
        entry = entries[unit]
        if entry["type"] == "pre-existing":
            continue
        name = entry["pkg-name"]
        record = {"version": entry["pkg-version"], "flags": entry.get("flags", {}),
                  "source": entry["pkg-src"], "tarball_hash": entry.get("pkg-src-sha256"),
                  "cabal_hash": entry.get("pkg-cabal-sha256")}
        if name in packages and packages[name] != record:
            raise ValueError(f"multiple incompatible instances of {name}")
        packages[name] = record
    for name, record in packages.items():
        components = set()
        for unit in seen:
            entry = entries[unit]
            if entry["pkg-name"] == name:
                if "component-name" in entry:
                    components.add(entry["component-name"])
                components.update(entry.get("components", {}).keys())
        record["components"] = sorted(components)
    if len([name for name in packages if name.startswith("shikigami-")]) != 7:
        raise ValueError("expected all seven local Shikigami packages")
    return dict(sorted(packages.items()))


def descriptors(packages, index, output):
    wanted = {f"{name}/{record['version']}/{name}.cabal": (name, record["cabal_hash"])
              for name, record in packages.items() if record["source"]["type"] == "repo-tar"}
    found = set()
    with tarfile.open(index, "r|") as archive:
        for member in archive:
            if member.name not in wanted or not member.isfile():
                continue
            name, expected = wanted[member.name]
            if name in found:
                continue
            data = archive.extractfile(member).read()
            if hashlib.sha256(data).hexdigest() != expected:
                continue
            (output / f"{name}.cabal").write_bytes(data)
            found.add(name)
    missing = set(name for name, _ in wanted.values()) - found
    if missing:
        raise ValueError(f"secure index lacks selected metadata hashes: {sorted(missing)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--index", type=Path, default=Path.home() / ".cabal/packages/hackage.haskell.org/01-index.tar")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text())
    packages = closure(plan)
    args.output.mkdir(parents=True, exist_ok=True)
    metadata = args.output / "metadata"
    metadata.mkdir(exist_ok=True)
    descriptors(packages, args.index, metadata)
    repositories = {}
    for name, record in packages.items():
        source = record["source"]
        if source["type"] == "repo-tar":
            record["source"] = {"type": "hackage", "url": f"https://hackage.haskell.org/package/{name}-{record['version']}/{name}-{record['version']}.tar.gz",
                                "hash": sri(record.pop("tarball_hash")), "metadata_hash": sri(record["cabal_hash"])}
        elif source["type"] in {"source-repo", "local"}:
            if source["type"] == "local":
                if name.startswith("shikigami-"):
                    record["source"] = {"type": "local", "path": name}
                    record.pop("tarball_hash", None)
                    record.pop("cabal_hash", None)
                    continue
                if name not in {"kikan-en-client", "kikan-en-contract"}:
                    raise ValueError(f"unowned local source {name}")
                path = Path(source["path"])
                if subprocess.check_output(["git", "status", "--porcelain"], cwd=path, text=True).strip():
                    raise ValueError("Kikan-En source must be clean before pinning")
                revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=path, text=True).strip()
                owner, repo, subdir = "shinzui", "kikan-en", name
                vendor = args.output / "vendor"
                vendor.mkdir(exist_ok=True)
                archive = vendor / "kikan-en.tar"
                # Regenerate from the recorded revision on every export. An old
                # archive must never acquire the identity of a newer checkout.
                archived = subprocess.check_output(["git", "archive", "--format=tar", revision, "kikan-en-client", "kikan-en-contract"], cwd=path.parent)
                archive.write_bytes(archived)
                record["source"] = {"type": "vendored", "path": "vendor/kikan-en.tar", "subdir": subdir,
                                    "revision": revision, "mori_uri": "mori://shinzui/kikan-en/repos/kikan-en",
                                    "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                                    "hash": sri(hashlib.sha256(archive.read_bytes()).hexdigest())}
                record.pop("tarball_hash", None)
                record.pop("cabal_hash", None)
                continue
            else:
                repository = source["source-repo"]
                url = repository["location"]
                if not url.startswith("https://github.com/") or not url.endswith(".git"):
                    raise ValueError(f"unsupported repository source {url}")
                owner, repo = url.removeprefix("https://github.com/").removesuffix(".git").split("/")
                revision, subdir = repository["tag"], repository.get("subdir", ".")
            if len(revision) != 40:
                raise ValueError("repository pin must be a full commit")
            key = f"{owner}/{repo}/{revision}"
            if key not in repositories:
                fetched = json.loads(subprocess.check_output(["nix", "flake", "prefetch", f"github:{key}", "--json"], text=True))
                repositories[key] = {"type": "github", "owner": owner, "repo": repo, "rev": revision, "narHash": fetched["hash"]}
            record["source"] = {"type": "github", "repository": key, "subdir": subdir}
        else:
            raise ValueError(f"unsupported source {source['type']}")
        record.pop("tarball_hash", None)
        record.pop("cabal_hash", None)
    lock = {"schema_version": 1, "compiler": plan["compiler-id"], "packages": packages, "repositories": repositories}
    # Keep the exact descriptors as a deterministic archive, rather than adding
    # hundreds of generated files to every packaging review.
    with (args.output / "metadata.tar.gz").open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as archive:
                for name, record in packages.items():
                    if record["source"]["type"] == "hackage":
                        data = (metadata / f"{name}.cabal").read_bytes()
                        member = tarfile.TarInfo(f"{name}.cabal")
                        member.size, member.mode, member.mtime = len(data), 0o644, 0
                        archive.addfile(member, io.BytesIO(data))
    (args.output / "cohort.json").write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
    print(f"exported {len(packages)} runtime packages and {len(repositories)} immutable repositories")


if __name__ == "__main__":
    main()
