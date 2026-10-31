"""The service's explicit concept namespaces and reviewed composition budget."""
import json
from pathlib import Path
import re

POLICY = json.loads(Path(__file__).with_name("module-ownership.json").read_text())


def check_module_ownership(path, source):
    parts = Path(path).parts
    if "Shikigami" not in parts or any(part.startswith("test") and part != "test-support" for part in parts):
        return []
    at = parts.index("Shikigami")
    expected = ".".join((*parts[at:-1], Path(parts[-1]).stem))
    declaration = re.search(r"(?m)^module\s+(Shikigami(?:\.\w+)*)\b", source)
    if not declaration or declaration[1] != expected:
        return [f"{path}:1: module-owner: module header must match {expected}"]
    name = declaration[1]
    root = name.split(".")[1] if "." in name else ""
    if (root in POLICY["domainRoots"] or name in POLICY["compositionModules"]
            or name.startswith(POLICY["generatedRoot"] + ".")):
        return []
    return [f"{path}:1: module-owner: {name} needs a concept owner or a reviewed composition entry"]
