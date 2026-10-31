# Plan 108 acceptance evidence

Implementation is in progress. No milestone or exhaustive semantic compliance is
accepted yet. The frozen domain guide remains deferred.

The starting revision is `914ec061f637aab50adbe480eff691406671b8c4` on arm64
macOS with GHC 9.12.4. The frozen guide was read at its recorded revision through
Mori; its SHA-256 is
`c9bb6e61d42c1345f23529b211f66d7485200aa2bfda41ef9966e8a13970a844`, matching
the coverage row. Its canonical authority is
`mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids`.

The initial coherent build passed:

```bash
nix develop --no-write-lock-file -c cabal build all --enable-tests -j1
```

The schema-2 census refresh passed on that build: 322 library/application modules,
913 declarations in those modules, and fourteen executable entrypoints. The
migration entrypoint adds one declaration. Enumerating declaration `$self` keys
and constructor members gives 3,988 audit keys (914 declarations and 3,074 members).
These are coverage counts, not semantic verdicts.

```bash
nix develop --no-write-lock-file -c python3 tools/domain/census.py --output docs/evidence/keiro-0.22/domain-declarations.json
python3 -m unittest discover -s tools/domain -p 'test_*.py' -v
```

All 24 tooling tests pass. They exercise positive record, shared selector,
positional, newtype, alias, nullary, GADT and entrypoint shapes, and reject missing,
extra, duplicate, pending, stale, omitted-source/member and unresolved-violation
mutations. Both library and executable interfaces participate in freshness checks.
GHC's embedded `src_hash` must equal the source byte fingerprint before a census
record is emitted; interface timestamps are insufficient because GHC/Cabal may
retain a byte-identical interface after source files are touched. SHA-256 binds
the emitted census to the exact source, interface and tool bytes.

Semantic classification, decoder remediation and final behavioral/compiler
acceptance remain outstanding. No PostgreSQL or final acceptance result is claimed
by the tooling checks above.
