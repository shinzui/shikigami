# Keiro 0.17 integration qualification

This record contains both the implementation qualification and the final
all-released consumer proof. The final run used detached revision `a7968be` in a
clean sibling worktree with no `cabal.project.local`. Cabal downloaded
`kioku-api`, `kioku-core`, and `kioku-migrations` 0.7.0.0 from Hackage; no solver
relaxation or Kioku package path participated.

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
| Deterministic scaffold | Pass | The committed implementation regenerated all 25 generated modules and the conformance package as `unchanged`; the generated-tree diff stayed empty. |

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

Pass. On 2026-09-19, `cabal update` advanced the authoritative public index to
`2026-09-19T01:06:24Z`. Exact `cabal info` lookups resolved all three Kioku
0.7.0.0 packages and showed the released Keiro 0.17 bounds.

The clean worktree then passed:

- `nix develop --command cabal build all`, with the build plan marking each
  Kioku 0.7 library as requiring download and build;
- the complete application test matrix, including 405 core, 197 PostgreSQL,
  88 worker, 47 server, 30 agent, 15 API, migration smoke and generated
  conformance tests;
- `just keiro-gate cd36433`, whose diff was additive and replay-neutral and
  whose scaffold reported all 25 generated modules unchanged;
- OpenAPI byte-drift, migration schema-isolation, and four-request Hurl checks;
- the exported treefmt and pre-commit Nix checks.

The detached worktree remained free of tracked changes after regeneration. This
completes the public-release boundary for EP-1 and the dependent plans.
