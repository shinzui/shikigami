import unittest
from module_ownership import check_module_ownership


class ModuleOwnershipTests(unittest.TestCase):
    def check(self, module):
        path = "shikigami-core/src/" + module.replace(".", "/") + ".hs"
        return check_module_ownership(path, "module " + module + " where\n")

    def test_concepts_and_reviewed_composition_are_allowed(self):
        for module in ["Shikigami.Objective.Store", "Shikigami.Integration.ConsumerRuntime",
                       "Shikigami.Runtime", "Shikigami.Diagrams"]:
            self.assertEqual(self.check(module), [])

    def test_technology_buckets_and_placeholder_are_refused(self):
        for module in ["Shikigami.Store.Execution", "Shikigami.Id.Name", "Shikigami.Core"]:
            self.assertTrue(self.check(module), module)

    def test_unreviewed_composition_is_refused(self):
        for module in ["Shikigami.Workers.Utilities", "Shikigami.Technology.Http"]:
            self.assertTrue(self.check(module), module)

    def test_header_cannot_hide_a_different_owner(self):
        self.assertTrue(check_module_ownership(
            "shikigami-core/src/Shikigami/Store/Execution.hs",
            "module Shikigami.Objective.Store where\n"))
