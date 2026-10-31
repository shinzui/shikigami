"""Behavioral coverage and refusal tests for the audit tool, using local fixtures."""
import copy
import json
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

from census import digest, discover_sources, tool_hashes
from check_classification import check, GUIDE_FIELDS
from source_declarations import DeclarationError, source_declarations


class DeclarationTests(unittest.TestCase):
    def members(self, source):
        return [m["member"] for d in source_declarations(source, "fixture.hs") for m in d["members"]]

    def test_record_shared_selectors_and_multi_field_signature(self):
        self.assertEqual(self.members("data T = A {x, y :: Int} | B {x :: Int}\n"),
                         ["A.x", "A.y", "B.x"])

    def test_positional_newtype_alias_nullary_and_empty(self):
        declarations = source_declarations(
            'data T = A !Text !(Maybe (Int, Text)) [Bool] | B\n'
            'newtype Id = Id Text deriving stock (Eq)\n'
            'type Name = Text\ndata Empty\n')
        self.assertEqual({d["name"]: [m["member"] for m in d["members"]] for d in declarations},
                         {"Empty": [], "Id": ["Id.#1"], "Name": [], "T": ["A.#1", "A.#2", "A.#3"]})

    def test_gadt_constraints_and_function_arguments(self):
        self.assertEqual(self.members('data Effect :: Type -> Type where\n'
                                     '  Invoke :: forall a. (Show a, Eq a) => (a -> IO ()) -> Int -> Effect a\n'
                                     '  Stop :: Effect ()\n'), ["Invoke.#1", "Invoke.#2"])

    def test_comments_strings_and_pragmas(self):
        self.assertEqual(self.members('{- nested {- data Hidden = Hidden Int -} -}\n'
                                     'data T = T { x :: Proxy "-- not a comment",\n'
                                     ' y :: {-# UNPACK #-} !Int } -- trailing\n'), ["T.x", "T.y"])

    def test_entrypoint_declaration(self):
        self.assertEqual(self.members('module Main where\ndata Command = Migrate MigrationCommand | VerifySchema\n'
                                     'main = pure ()\n'), ["Migrate.#1"])

    def test_unsupported_syntax_names_source(self):
        for source in ["data T = Int :*: Int\n", "data T = T { x :: Int\n", "data family F a\n",
                       "type family F a\n", "type (:+:) a b = (a, b)\n"]:
            with self.subTest(source=source), self.assertRaisesRegex(DeclarationError, "fixture.hs"):
                source_declarations(source, "fixture.hs")


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True)
        self.source_name = "shikigami-example/src/Shikigami/Example.hs"
        self.entrypoint_name = "shikigami-example/app/Main.hs"
        self.source = self.write(self.source_name, "module Shikigami.Example where\ndata T = T Int Text\n")
        self.entrypoint = self.write(self.entrypoint_name, "module Main where\ndata Command = Run Int | Stop\n")
        self.interface_name = "dist-newstyle/build/test/ghc-9.12.4/shikigami-example-0.1/build/Shikigami/Example.hi"
        self.interface = self.write(self.interface_name, "fixture interface bytes")
        self.guide = dict(zip(GUIDE_FIELDS, ["mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids",
                                            "frozen-revision", "guide.md", "guide-sha256"]))
        self.write("docs/architecture/keiro-0.22-coverage.json", json.dumps({"sources": [self.guide]}))
        self.census = {"schemaVersion": 2, "toolHashes": tool_hashes(),
                       "toolSha256": tool_hashes()["census.py"],
                       "buildRoot": "dist-newstyle/build/test/ghc-9.12.4",
                       "modules": [self.record(self.source_name, "Shikigami.Example")],
                       "entrypoints": [self.record(self.entrypoint_name, "Main")]}
        self.census["modules"][0].update(interfacePath=self.interface_name,
                                         interfaceSha256=digest(self.interface.read_bytes()),
                                         compiledSourceMd5=hashlib.md5(self.source.read_bytes()).hexdigest())
        entrypoint_interface = "dist-newstyle/build/test/ghc-9.12.4/shikigami-example-0.1/x/example/build/example/example-tmp/Main.hi"
        self.write(entrypoint_interface, "fixture Main interface bytes")
        self.census["entrypoints"][0].update(interfacePath=entrypoint_interface,
                                             interfaceSha256=digest((self.root / entrypoint_interface).read_bytes()),
                                             compiledSourceMd5=hashlib.md5(self.entrypoint.read_bytes()).hexdigest())
        entries = []
        for record in self.census["modules"] + self.census["entrypoints"]:
            for declaration in record["declarations"]:
                for member in ["$self"] + [m["member"] for m in declaration["members"]]:
                    entries.append({"sourcePath": record["sourcePath"], "module": record["module"],
                                    "declaration": declaration["name"], "member": member,
                                    "sourceSha256": record["sourceSha256"], "classification": "structural",
                                    "disposition": "compliant", "invariant": "fixture sum/arguments",
                                    "authority": "fixture source", "boundaryOwner": "fixture constructor",
                                    "rationale": "fixture for exact set checks", "evidence": [record["sourcePath"]]})
        self.classification = {"schemaVersion": 1, **self.guide, "entries": entries}
        self.refresh_census_hash()

    def write(self, name, body):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
        return path

    def record(self, name, module):
        path = self.root / name
        return {"sourcePath": name, "module": module, "sourceSha256": digest(path.read_bytes()),
                "declarations": source_declarations(path.read_text(), name)}

    def refresh_census_hash(self):
        self.census_bytes = json.dumps(self.census).encode()
        self.classification["censusSha256"] = digest(self.census_bytes)

    def check(self, resolved=False):
        return check(self.classification, self.census, self.census_bytes, self.root, resolved)

    def test_complete_control(self):
        self.assertEqual(self.check(True)["compliant"], 5)

    def test_deleted_key(self):
        self.classification["entries"].pop()
        with self.assertRaisesRegex(ValueError, "missing .*classification keys"):
            self.check()

    def test_duplicate(self):
        self.classification["entries"].append(copy.deepcopy(self.classification["entries"][0]))
        with self.assertRaisesRegex(ValueError, "duplicate classification"):
            self.check()

    def test_extra(self):
        self.classification["entries"][0]["member"] = "Invented.#1"
        with self.assertRaisesRegex(ValueError, "extra classification"):
            self.check()

    def test_census_hash(self):
        self.classification["censusSha256"] = "stale"
        with self.assertRaisesRegex(ValueError, "census hash drift"):
            self.check()

    def test_source_hash(self):
        self.source.write_text(self.source.read_text() + "-- changed\n")
        with self.assertRaisesRegex(ValueError, "source hash drift"):
            self.check()

    def test_entrypoint_hash(self):
        self.entrypoint.write_text(self.entrypoint.read_text() + "-- changed\n")
        with self.assertRaisesRegex(ValueError, "source hash drift"):
            self.check()

    def test_interface_hash(self):
        self.interface.write_text("changed interface")
        with self.assertRaisesRegex(ValueError, "interface hash drift"):
            self.check()

    def test_tool_hash(self):
        self.census["toolHashes"]["source_declarations.py"] = "stale"
        self.refresh_census_hash()
        with self.assertRaisesRegex(ValueError, "tool hash drift"):
            self.check()

    def test_compiled_source_fingerprint(self):
        self.census["modules"][0]["compiledSourceMd5"] = "stale"
        self.refresh_census_hash()
        with self.assertRaisesRegex(ValueError, "compiled source fingerprint drift"):
            self.check()

    def test_entrypoint_interface_hash(self):
        path = self.root / self.census["entrypoints"][0]["interfacePath"]
        path.write_text("changed Main interface")
        with self.assertRaisesRegex(ValueError, "interface hash drift"):
            self.check()

    def test_census_duplicate_source(self):
        self.census["entrypoints"].append(copy.deepcopy(self.census["entrypoints"][0]))
        self.refresh_census_hash()
        with self.assertRaisesRegex(ValueError, "duplicate census sources"):
            self.check()

    def test_build_path_cannot_escape_checkout(self):
        self.census["modules"][0]["interfacePath"] = "../foreign.hi"
        self.refresh_census_hash()
        with self.assertRaisesRegex(ValueError, "nonlocal evidence path"):
            self.check()

    def test_positional_member_omitted_from_census_and_classification(self):
        self.census["modules"][0]["declarations"][0]["members"].pop()
        self.classification["entries"] = [e for e in self.classification["entries"] if e["member"] != "T.#2"]
        self.refresh_census_hash()
        with self.assertRaisesRegex(ValueError, "source declaration/member drift"):
            self.check()

    def test_entrypoint_declaration_omitted(self):
        self.census["entrypoints"][0]["declarations"] = []
        self.classification["entries"] = [e for e in self.classification["entries"] if e["module"] != "Main"]
        self.refresh_census_hash()
        with self.assertRaisesRegex(ValueError, "source declaration/member drift"):
            self.check()

    def test_new_module_and_empty_entrypoint_require_refresh(self):
        for name in ["shikigami-example/src/Shikigami/New.hs", "shikigami-example/app/new/Main.hs"]:
            path = self.write(name, "module Main where\nmain = pure ()\n")
            with self.assertRaisesRegex(ValueError, "source set drift"):
                self.check()
            path.unlink()

    def test_violations_allowed_only_without_require_resolved(self):
        self.classification["entries"][0]["disposition"] = "violation"
        self.assertEqual(self.check()["violation"], 1)
        with self.assertRaisesRegex(ValueError, "unresolved violations"):
            self.check(True)

    def test_pending_and_missing_explanations_fail(self):
        entry = self.classification["entries"][0]
        for field, value in [("disposition", "pending"), ("rationale", ""), ("evidence", []),
                             ("authority", ""), ("boundaryOwner", ""), ("invariant", "")]:
            before = entry[field]
            entry[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check()
            entry[field] = before


if __name__ == "__main__":
    unittest.main()
