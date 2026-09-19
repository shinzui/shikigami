# Keiro 0.17 integration qualification

This record separates the implemented Shikigami qualification from the final
all-released consumer proof. The implementation run uses Kioku's clean 0.7.0.0
release source at commit `37c3acd2d16e18c49217bc6189ea20b496907e3b`, selected by the
developer-local and gitignored `cabal.project.local`. No solver relaxation is
present in the repository.

## Implementation-revision results

The run used GHC 9.12.4 on aarch64 Darwin. PostgreSQL-backed tests started an
isolated PostgreSQL 18.6 instance; they were executed rather than skipped.

| Gate | Result | Evidence |
|---|---|---|
| Application test matrix | Pass | All explicitly selected Shikigami, migration, generated-conformance, API, agent, server, client and worker suites passed. This included 197 `shikigami-core-postgres-test` cases and 88 `shikigami-workers-test` cases. |
| Keiro structural check | Pass | Language floor 6, warnings denied, binding explanations and opaque-boundary coverage completed with no binding obligation or opaque persisted root. |
| Keiro source inspection | Pass | All five workspace members declare effective Language 6. The registry metadata reports Language 6 as `candidate`. |
| Keiro evolution diff | Pass | The five source-language changes are additive; Keiro reported stored-data replay as unchanged from baseline `cd36433`. |
| OpenAPI regeneration | Pass | `cabal run -v0 shikigami-openapi` left `docs/api/openapi.json` byte-identical. |
| Migration schema-isolation scan | Pass | Application SQL is schema-qualified. The one checksum-immutable historical `search_path` migration remains an explicit exception; vendored PGMQ SQL does not mutate the session path. |
| HTTP smoke | Pass | Both Hurl files and all four requests passed against an isolated migrated database and local server. |
| Nix check outputs | Pass | The exported `checks.aarch64-darwin.treefmt` and `checks.aarch64-darwin.pre-commit` derivations built successfully with the complete staged source. |
| Deterministic scaffold | Pending | Run after the implementation commit; the gate requires an otherwise clean generated tree. |

The application matrix command intentionally enumerated Shikigami's suites:

```bash
nix develop --command cabal test \
  shikigami-core-test shikigami-core-postgres-test \
  shikigami-core-domain-test shikigami-core-diagrams-test \
  shikigami-migrations-test shikigami-migrations-smoke \
  shikigami-api-test shikigami-agent-test shikigami-server-test \
  shikigami-client-test shikigami-workers-test \
  keiro-shikigami-conformance --test-show-details=direct
```

This keeps a stale test fixture in the local Kioku source checkout from being
misreported as a Shikigami failure: `kioku-migrations-test` expects an old
frozen schema checksum (`be5f…`) while its current embedded schema produces
`d085…`. That dependency-owned test suite is not part of a Hackage dependency
build. Shikigami's own old-to-new migration smoke uses Kioku 0.7's actual
embedded migrations and passed.

The repository's broader `nix flake check` also attempts to build
`packages.aarch64-darwin.default`. Its pre-existing `callCabal2nix` definition
points at the multi-package repository root, where no root `.cabal` file exists,
so Cabal2nix rejects that package output. The two actual exported Nix checks pass;
the complete application build is qualified by Cabal above.

## Public-release gate

At 2026-09-19T00:27Z, a fresh `cabal update` still reported public index-state
`2026-09-18T23:13:22Z`. The authoritative index could not resolve any of
`kioku-api-0.7.0.0`, `kioku-core-0.7.0.0`, or
`kioku-migrations-0.7.0.0`; the first lookup failed with:

```text
There is no available version of kioku-api that satisfies ==0.7.0.0
```

The final qualification must repeat the solve and aggregate gates in a clean
checkout with no `cabal.project.local` once those releases become visible.
Until then, EP-1 and the dependent completion gates remain in progress.
