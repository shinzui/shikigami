#!/usr/bin/env python3
"""Validate the frozen 0.22 upgrade scope without claiming the deferred audit."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DOMAIN = 'mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids'
FOLLOW_UP = 'docs/plans/108-complete-the-remaining-domain-scalar-identity-and-decoder-audit.md'
DECISION = 'docs/adr/0106-the-keiro-upgrade-closes-on-a-bounded-macos-profile.md'
SOURCE_KEYS = ('source', 'sourceRevision', 'sourcePath', 'sourceSha256')
RELEASE_KEYS = ('id', 'source', 'sourceRevision', 'sourcePath', 'section', 'feature')


def fingerprint(rows, keys):
    values = [{k: r[k] for k in keys} for r in rows]
    values.sort(key=lambda v: json.dumps(v, sort_keys=True))
    return hashlib.sha256(json.dumps(values, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()


def validate(sources, releases, root=ROOT, corpora=None):
    errors = []
    def require(condition, reason):
        if not condition:
            errors.append(reason)
    def local(path):
        value = Path(path)
        return not value.is_absolute() and '..' not in value.parts and (root / value).is_file()
    def disposition(row, key):
        state = row.get('status')
        require(state in {'implemented', 'existing', 'not-applicable', 'deferred'}, f'{key}: pending/unknown status')
        require(local(row.get('owner', '')), f'{key}: missing owner')
        evidence = row.get('evidence', [])
        require(bool(evidence) and all(local(p) for p in evidence), f'{key}: missing evidence')
        if state == 'not-applicable':
            reason = row.get('rationale', '').strip()
            require(len(reason) >= 40 and reason.lower().rstrip('.') not in {'not applicable', 'not needed'}, f'{key}: unsupported exclusion')
        if state == 'deferred':
            require(key == DOMAIN and row.get('followUp') == FOLLOW_UP and row.get('scopeDecision') == DECISION and local(FOLLOW_UP) and local(DECISION), f'{key}: unsupported deferral')
    rows, features = sources.get('sources', []), releases.get('features', [])
    require(len(rows) == 124 and len({r.get('source') for r in rows}) == 124, 'source denominator missing/duplicate')
    require(len(features) == 93 and {r.get('id') for r in features} == {f'REL-{i}' for i in range(1, 94)}, 'release denominator missing/duplicate')
    for data, records, keys in [(sources, rows, SOURCE_KEYS), (releases, features, RELEASE_KEYS)]:
        try:
            require(data.get('closureSha256') == fingerprint(records, keys), 'frozen denominator changed')
        except KeyError:
            errors.append('missing frozen source identity')
    for row in rows:
        key = row.get('source', '')
        require(key.startswith('mori://'), 'noncanonical source')
        disposition(row, key)
        clauses = row.get('clauses', [])
        require(bool(clauses) and len({c.get('id') for c in clauses}) == len(clauses), f'{key}: missing/duplicate clause')
        for clause in clauses:
            state = clause.get('disposition')
            require(state in {'implemented', 'existing', 'not-applicable', 'deferred'}, f'{key}: pending clause')
            require(bool(clause.get('rationale', '').strip()), f'{key}: missing clause rationale')
            if state == 'deferred':
                require(key == DOMAIN and clause.get('id') == 'complete-domain-scalar-and-identity-census' and row.get('status') == 'deferred', f'{key}: unsupported deferred clause')
        if corpora:
            project = next((p for p in corpora if key.startswith(p + '/')), None)
            path = corpora[project] / row['sourcePath'] if project else None
            require(path is not None and path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == row['sourceSha256'], f'{key}: source hash drift')
    for row in features:
        disposition(row, row.get('id', ''))
        require(bool(row.get('rationale', '').strip()), f"{row.get('id')}: missing rationale")
        if corpora:
            path = corpora.get(row['source'], Path('/nonexistent-keiro-corpus')) / row['sourcePath']
            require(path.is_file() and ' '.join(row['feature'].split()) in ' '.join(path.read_text().split()), f"{row['id']}: release source changed")
    if corpora:
        for item in releases.get('sourceFiles', []):
            path = corpora[item['project']] / item['sourcePath']
            require(path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == item['sourceSha256'], 'release file drift')
        require(bool(releases.get('sourceFiles')), 'missing release file hashes')
        for project, folder in [('mori://shinzui/keiro-runtime-patterns', 'runtime-patterns'), ('mori://shinzui/haskell-jitsurei', 'patterns')]:
            known = {r['sourcePath'] for r in rows if r['source'].startswith(project + '/')}
            extras = [r for r in sources.get('unregisteredDocuments', []) if r['project'] == project]
            require(all(r.get('reason', '').strip() for r in extras), 'unjustified unregistered document')
            known.update(r['sourcePath'] for r in extras)
            actual = {str(p.relative_to(corpora[project])) for p in (corpora[project] / folder).rglob('*.md')}
            require(actual == known, f'{project}: unregistered document inventory changed')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    corpora = {}
    for project in ['mori://shinzui/keiro-runtime-patterns', 'mori://shinzui/haskell-jitsurei', 'mori://shinzui/keiro']:
        result = subprocess.run(['mori', 'path', project], capture_output=True, text=True, check=True)
        corpora[project] = Path(result.stdout.strip().splitlines()[-1])
    sources = json.loads((args.root / 'docs/architecture/keiro-0.22-coverage.json').read_text())
    releases = json.loads((args.root / 'docs/architecture/keiro-0.22-release-coverage.json').read_text())
    errors = validate(sources, releases, args.root, corpora)
    if errors:
        parser.exit(1, '\n'.join(errors) + '\n')
    print('Keiro 0.22 audit: 124 sources, 93 release items; one explicit follow-up, no pending upgrade gate; frozen files/evidence verified.')


if __name__ == '__main__':
    main()
