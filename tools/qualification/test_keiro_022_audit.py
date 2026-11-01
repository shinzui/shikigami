import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).with_name('keiro_022_audit.py')
spec = importlib.util.spec_from_file_location('keiro_audit', MODULE)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.sources = json.loads((audit.ROOT / 'docs/architecture/keiro-0.22-coverage.json').read_text())
        self.releases = json.loads((audit.ROOT / 'docs/architecture/keiro-0.22-release-coverage.json').read_text())

    def errors(self):
        return audit.validate(self.sources, self.releases)

    def test_current_scoped_closure_passes(self):
        self.assertEqual(self.errors(), [])

    def test_missing_source_refuses(self):
        self.sources['sources'].pop()
        self.assertTrue(self.errors())

    def test_duplicate_source_refuses(self):
        self.sources['sources'][0] = copy.deepcopy(self.sources['sources'][1])
        self.assertTrue(self.errors())

    def test_source_hash_drift_refuses(self):
        self.sources['sources'][0]['sourceSha256'] = '0' * 64
        self.assertIn('frozen denominator changed', self.errors())

    def test_missing_release_refuses(self):
        self.releases['features'].pop()
        self.assertTrue(self.errors())

    def test_changed_release_text_refuses(self):
        self.releases['features'][0]['feature'] += ' drift'
        self.assertIn('frozen denominator changed', self.errors())

    def test_pending_refuses(self):
        self.sources['sources'][0]['clauses'][0]['disposition'] = 'pending'
        self.assertTrue(self.errors())

    def test_unowned_source_refuses(self):
        self.sources['sources'][0]['owner'] = ''
        self.assertTrue(self.errors())

    def test_missing_evidence_refuses(self):
        self.sources['sources'][0]['evidence'] = ['docs/evidence/absent-qualification.txt']
        self.assertTrue(self.errors())

    def test_unsupported_exclusion_refuses(self):
        self.releases['features'][0].update(status='not-applicable', rationale='not applicable')
        self.assertTrue(self.errors())

    def test_arbitrary_deferral_refuses(self):
        self.releases['features'][0].update(status='deferred', followUp=audit.FOLLOW_UP, scopeDecision=audit.DECISION)
        self.assertTrue(self.errors())

    def test_named_follow_up_is_required(self):
        row = next(r for r in self.sources['sources'] if r['source'] == audit.DOMAIN)
        row.update(status='deferred', followUp='docs/plans/missing.md', scopeDecision=audit.DECISION)
        self.assertTrue(self.errors())

    def test_duplicate_clause_refuses(self):
        row = self.sources['sources'][0]
        row['clauses'].append(copy.deepcopy(row['clauses'][0]))
        self.assertTrue(self.errors())

    def test_unregistered_file_is_detected(self):
        # Empty stand-in corpus cannot satisfy the frozen source/file inventories.
        with tempfile.TemporaryDirectory() as directory:
            roots = {p: Path(directory) for p in ['mori://shinzui/keiro-runtime-patterns', 'mori://shinzui/haskell-jitsurei', 'mori://shinzui/keiro']}
            errors = audit.validate(self.sources, self.releases, corpora=roots)
            self.assertTrue(any('source hash drift' in e for e in errors))
            self.assertTrue(any('unregistered document inventory changed' in e for e in errors))


if __name__ == '__main__':
    unittest.main()
