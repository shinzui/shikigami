# Keiro 0.18 qualification

Plan 72 qualified the released Keiro 0.18 family against baseline
`eb8395ac2646f742dad2e8dc6ced9640a6b4dd1e` on 2026-09-21. The authoritative
Hackage snapshot is `2026-09-21T20:25:14Z`; all seven upstream release tags peel
to `b12bbdd7abc8c1a59e7a09891471ef182a4d801a` in
`mori://shinzui/keiro`.

## Resolved cohort

| Package | Version |
|---|---|
| `keiro`, `keiro-core`, `keiro-dsl`, `keiro-migrations`, `keiro-ops`, `keiro-pgmq`, `keiro-test-support` | `0.18.0.0` |
| `kioku-api`, `kioku-core`, `kioku-migrations` | `0.7.0.0` |
| `ephemeral-pg` | `0.3.1.0` |
| `pg-migrate-test-support` | `1.1.0.0` |
| `kiroku-store`, `kiroku-store-migrations` | `0.8.0.1`, `0.4.0.0` |
| `shibuya-core`, `shibuya-kafka-adapter`, `shibuya-kiroku-adapter` | `0.9.0.3`, `0.9.0.1`, `0.5.1.2` |
| `pgmq-core`, `pgmq-effectful`, `pgmq-hasql`, `pgmq-config` | `0.6.1.0` |
| `shibuya-pgmq-adapter` | `0.16.0.0` |

Release resolution temporarily excluded the ignored `cabal.project.local`, which
points at a pre-Hackage-revision Kioku checkout still capped to Keiro 0.17. The file
was restored unchanged after every release-only command. Kioku 0.7.0.0 Hackage
revision 1 admits `keiro >=0.17 && <0.19`. The plan contains only the existing
`claude:http-client-tls` exception and the qualified
`pg-migrate-test-support:ephemeral-pg` exception.

## Generated and durable-contract evidence

The first 0.18 scaffold changed 28 generated artifacts. Every change was a one-line
0.17-to-0.18 provenance-banner restamp; the generated semantic diff hash remained
`c1cb828c0c35309c5105ca46c43745a1c68234019c190ce63364a7d3e633d4af`.
A second scaffold reported every path unchanged. `just keiro-diff` reported no
compatibility finding and `replay-neutral` impact.

All five workspace members remain explicitly declared at candidate Language 6.
There are no opaque persisted roots or binding obligations. The three intentional
hand-owned holes remain the live projection handler, read-model SQL, and executed
behavior witnesses. No migration, workflow patch, queue envelope, event codec, or
identifier-admission change was introduced.

## Executed checks

The following release-only commands exited successfully:

```bash
nix develop --command cabal build all --enable-tests
nix develop --command cabal test shikigami-migrations:shikigami-migrations-smoke --test-show-details=direct
nix develop --command cabal test keiro-shikigami-conformance --test-show-details=direct
nix develop --command cabal test all --test-show-details=direct
just migration-schema-isolation
just keiro-gate eb8395ac2646f742dad2e8dc6ced9640a6b4dd1e
bash tests/hurl/run.sh
```

The migration smoke suite passed all nine cases, including fresh application,
no-op reapplication, the 0.15-to-0032 upgrade, four-component composition,
template isolation, and exception cleanup on `ephemeral-pg` 0.3.1.0. The generated
behavior report filled all 56 required obligations: 50 verified and six expected
honest unverified identity/register equality guards, with no pending, missing,
duplicate, stale, or failed key. Migration schema isolation passed. The disposable
Hurl environment applied the unchanged Keiro plan through migration 0032 and
passed two files, four requests, with no failures.
