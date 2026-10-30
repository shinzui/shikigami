# Released cohort and fresh schema qualification

Plan 92 starts from `dc19c4f1d3068b6f73384f2e82588d6ad690e16c`, with a clean
working tree. The source is unused under ADR-27's reconfirmation on 2026-10-30.
No developer database was reset. All database evidence uses task-owned ephemeral
PostgreSQL 18 databases; no populated legacy upgrade is claimed.

`released-cohort.json` records the fixed Hackage index, released descriptor hashes,
selected versions and verified upstream release commits. Keiro and DSL are 0.22.0.0.
Kikan uses a published immutable source commit instead of a sibling path. Kioku
0.12.0.0 and the Kiroku adapter 0.7.0.0 preserve the compatible Baikai/Store cohorts;
newer incompatible releases are not forced through allow-newer. Pg-migrate 1.2
removes the old fixture bound exception. The unrelated claude bound exception stays.

The PGMQ component replaces the vendored baseline. Its 0007 and Kiroku 0012–0016
are asserted in the applied ledger. The unused suppression table now belongs to
`shikigami.fired`; no runtime code referred to its old name. SQL, manifest and
`sql-migrations/migrations.lock` establish the new first-release source identity.
The nine-case normal migration suite checks source membership, source/embedded
agreement, checksums, body qualification and component order. Its mutation cases
reject changed payload bytes, an unlisted sibling, unqualified DDL and search_path.

The eleven-case native suite applies all five component owners, verifies the
ledger read-only, rejects missing/pending/unknown/drifted history, proves a no-op
second apply, and checks database isolation and cleanup. It also compares a fresh
application schema with the reviewed 800-line `expected-schema.txt`, then adds a
column in its disposable clone and proves that live-object verification refuses
it independently of the ledger. The migration executable exposes the same public
verification boundary as `verify-schema`. The released framework checker supports
PostgreSQL 18 and explicitly refuses other majors; this is not certification of
its schema snapshot on PostgreSQL 17.

Regenerate an intentional application schema change only with the explicit flag,
review the snapshot diff, then run the normal suite with the flag absent:

```bash
SHIKIGAMI_REGENERATE_EXPECTED_SCHEMA=1 nix develop --no-write-lock-file -c \
  cabal test shikigami-migrations-smoke --test-options='--num-threads=1 +RTS -N2 -RTS'
nix develop --no-write-lock-file -c cabal test \
  shikigami-migrations-test shikigami-migrations-smoke \
  --test-options='--num-threads=1 +RTS -N2 -RTS'
bash tools/check-migration-schema-isolation.sh
```

`check.json` and `inspect.json` record strict candidate Language 6 checking for all
ten workspace members. `generation.json` records a byte-identical second scaffold,
including preservation of application holes. All 122 service conformance checks
pass in `conformance.txt`. The dependency-only diff and replay reports contain no
semantic findings; later plan 93 baseline changes require their own strict report.

These results do not certify the final deployment closure, Linux runtime, full
inspection surface or whole MasterPlan. Plan 95 owns final candidate qualification.
