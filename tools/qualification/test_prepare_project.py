import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess

spec = importlib.util.spec_from_file_location("prepare_project", Path(__file__).with_name("prepare-project.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RelocationTests(unittest.TestCase):
    def test_only_package_paths_change(self):
        root = Path("/checkout with spaces/project")
        source = """-- cohort stays unchanged
packages:
  core ../client
optional-packages: core/generated.*/*.cabal
with-compiler: ghc-9.12.4
index-state: 2026-09-21T20:25:14Z
constraints: keiro-dsl ==0.18.0.0
source-repository-package
  type: git
  location: https://example.com/fixture-dependency.git
  tag: 0123456789abcdef0123456789abcdef01234567
  subdir: fixture-dependency-core
package blake3
  flags: -avx512 -avx2
allow-newer:
  claude:http-client-tls,
  pg-migrate-test-support:ephemeral-pg
"""
        result = module.relocate(source, root)
        self.assertIn('  "/checkout with spaces/project/core"\n', result)
        self.assertIn('  "/checkout with spaces/client"\n', result)
        self.assertIn('  "/checkout with spaces/project/core/generated.*/*.cabal"', result)
        self.assertEqual(result[result.index("with-compiler:"):], source[source.index("with-compiler:"):])

    def test_rejects_relocation_hazards(self):
        for source in [
            "import: other.project\npackages: core\n",
            "packages: https://example.com/a.tar.gz\n",
            "packages: ~/core\n",
            "packages: core, client\n",
            "packages: core -- ambiguous inline comment\n",
            "packages: core\npackages: client\n",
            "if os(darwin)\n  packages: core\n",
            "packages: core\nsource-repository-package\n  location: ../library\n",
            "packages: core\nbuilddir: ../build\n",
            "packages: core\nextra-prog-path: ../tools\n",
            "packages: core\nwith-compiler: ../tools/ghc\n",
            "packages: core\npackage core\n  extra-lib-dirs: ../libs\n",
        ]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                module.relocate(source, Path("/checkout"))

    def test_reads_committed_project_and_avoids_local_override(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "cabal.project").write_text("not the committed project")
            override = root / "cabal.project.local"
            override.write_text("packages: incompatible-kioku")
            with patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "packages: core\nindex-state: fixed\n")) as read:
                project = module.prepare(root, root)
            self.assertEqual(read.call_args.args[0], ["git", "show", "HEAD:cabal.project"])
            self.assertNotEqual(project.parent, root)
            self.assertFalse(project.with_suffix(".project.local").exists())
            self.assertEqual(override.read_text(), "packages: incompatible-kioku")
            self.assertIn("index-state: fixed", project.read_text())


if __name__ == "__main__":
    unittest.main()
