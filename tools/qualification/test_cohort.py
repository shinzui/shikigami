import importlib.util
from pathlib import Path
import tempfile
import unittest


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


export = load("export_cohort", "export-cohort.py")
verify = load("verify_cohort", "verify-cohort.py")


class CohortTests(unittest.TestCase):
    def test_closure_follows_legacy_component_edges_and_excludes_tests(self):
        entries = []
        for name in ["core", "agent", "api", "client", "workers", "server", "migrations"]:
            entries.append({"type": "configured", "id": name, "pkg-name": "shikigami-" + name,
                            "pkg-version": "0.1.0.0", "component-name": "lib", "pkg-src": {"type": "local"},
                            "depends": ["legacy"]})
        entries.extend([
            {"type": "configured", "id": "legacy", "pkg-name": "legacy", "pkg-version": "1.0",
             "pkg-src": {"type": "repo-tar"}, "components": {"lib": {"depends": ["base"], "exe-depends": ["generator"]}}},
            {"type": "configured", "id": "generator", "pkg-name": "generator", "pkg-version": "1.0",
             "pkg-src": {"type": "repo-tar"}, "component-name": "exe:generator"},
            {"type": "pre-existing", "id": "base", "pkg-name": "base"},
            {"type": "configured", "id": "test", "pkg-name": "shikigami-core", "pkg-version": "0.1.0.0",
             "component-name": "test:suite", "pkg-src": {"type": "local"}, "depends": ["unused-test-dependency"]},
        ])
        packages = export.closure({"install-plan": entries})
        self.assertEqual(packages["legacy"]["components"], ["lib"])
        self.assertEqual(packages["generator"]["components"], ["exe:generator"])
        self.assertNotIn("base", packages)
        self.assertEqual(packages["shikigami-core"]["components"], ["lib"])

    def test_unused_executable_is_disabled_without_changing_selected_library(self):
        source = """name: example
library
 build-depends: base
 exposed-modules: Example

executable example-cli
 main-is: Main.hs
 build-depends: example, unused-cli-dependency
"""
        with tempfile.TemporaryDirectory() as directory:
            packages = Path(directory)
            (packages / "example").mkdir()
            descriptor = packages / "example/example.cabal"
            descriptor.write_text(source)
            verify.restrict_components({"packages": {"example": {"components": ["lib"]}}}, packages)
            result = descriptor.read_text()
            self.assertEqual(result.split("executable")[0], source.split("executable")[0])
            self.assertTrue(result.endswith(" buildable: False\n"))


if __name__ == "__main__":
    unittest.main()
