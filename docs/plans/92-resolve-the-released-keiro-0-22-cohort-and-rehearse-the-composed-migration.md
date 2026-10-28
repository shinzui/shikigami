---
id: 92
slug: resolve-the-released-keiro-0-22-cohort-and-rehearse-the-composed-migration
title: "Resolve the released Keiro 0.22 cohort and rehearse the composed migration"
kind: exec-plan
created_at: 2026-10-28T13:08:03Z
intention: "intention_01m61agcfzek98hqzkb0kxcfmg"
master_plan: "docs/masterplans/16-upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-28T13:08:03Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-28T13:21:22Z
      mode: "update"
      note: "Complete source-grounded draft and link the requested Mina intention"
---

# Resolve the released Keiro 0.22 cohort and rehearse the composed migration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture


Make Shikigami build and migrate against the released Keiro 0.22 family without local dependency overrides. A contributor can reproduce the solve, build all service packages, migrate a disposable database carrying the old schema/data and see the new binaries pass startup verification. The old PostgreSQL-fixture `allow-newer` exception disappears because its compatible replacement is released.


## Progress


- [ ] M1: A release-only solve selects the compatible 0.22 cohort, removes the superseded fixture relaxation and compiles the service and regenerated conformance package.
- [ ] M2: Fresh and 0.18-baseline disposable databases reach the complete schema, preserve seeded data, verify startup, and accept a second migration pass without changes.


## Surprises & Discoveries


None yet.


## Decision Log


2026-10-28: Target Keiro 0.22.0.0 with its compatible released substrate. Do not select Kiroku Store 0.13 merely because it is newer: published Keiro/Kioku bounds require 0.12. Preserve all historical application migration bytes, including the vendored PGMQ baseline.


## Outcomes & Retrospective


To be filled during implementation.


## Context and Orientation


A cohort is the set of dependency versions that can compile and run together. `cabal.project` currently pins seven Keiro packages and the DSL at 0.18.0.0, Kioku at 0.7.0.0, Kiroku Store at 0.8.0.1, PGMQ at 0.6.1.0 and pg-migrate at 1.1. The immutable Nix closure under `nix/qualification/` is a separate compiled artifact; the final packaging update belongs to `docs/plans/95-close-the-runtime-pattern-audit-and-qualify-the-keiro-0-22-rollout.md`.

Mori locates dependency sources. Start with `mori registry list`, `mori registry search keiro`, then `mori registry show shinzui/keiro --full` and `mori registry docs shinzui/keiro`. Cross-repository references are canonical URIs. In `mori://shinzui/keiro`, the project-relative `CHANGELOG.md` and `blueprints/keiro-upgrade/migrations/` describe the consecutive 0.18→0.19→0.20→0.21→0.22 edges; artifact-level source URIs are pending. Read every intervening edge and its entailed dependency migrations rather than extrapolating from 0.22 alone.

On 2026-10-28 Hackage and remote tags verified all eight Keiro packages at 0.22.0.0, common peeled commit `b28201f2063fa4f6dcb724cbf474959107e36b74`. Existing consumers use seven; adding HTTP operations is not required. Published Kioku 0.12.0.0 admits this cohort. Keiro requires Kiroku Store `^>=0.12.0.0`, store migrations `^>=0.7.2.0`, Shibuya Core `^>=0.12.0.0`, its PGMQ adapter `^>=0.18.0.0`, PGMQ `>=0.7 && <0.8` and pg-migrate 1.2. Select compatible patch versions by an actual solve and verify their published descriptors/tags. Effectful 2.6 remains admitted; if the solve moves to 2.7, exclude effectful-core 2.7.0.0–2.7.1.0 exactly as released bounds require.

`shikigami-migrations/src/Shikigami/Migrations.hs` composes Kiroku, Keiro, Kioku and application components. Its historical `2026-06-24-13-00-00-pgmq-schema.sql` vendors PGMQ; the new upstream PGMQ 0007 cannot be assumed to arrive through Keiro's composed plan. Migration 0012 in Kiroku backfills category junctions and prohibits old writers; 0013/0014 change subscriptions, 0015 adds a potentially blocking stream index, and 0016 supports namespace bindings. Discover exact identities and prerequisites through Mori and released sources.

Consult [ADR 0037](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md) for released contracts, [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md) for migration-first startup, [ADR 0039](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md) for packaging, and `docs/workflow-versioning.md` for durable bodies. `docs/architecture/keiro-0.22-pattern-audit.md` records the initial findings. Dependency owners are `mori://shinzui/kioku`, `mori://shinzui/kiroku`, `mori://shinzui/shibuya`, `mori://shinzui/pgmq-hs`, `mori://shinzui/shibuya-pgmq-adapter`, `mori://shinzui/shibuya-kafka-adapter` and `mori://shinzui/pg-migrate`. The obsolete fixture bound belongs to `mori://shinzui/pg-migrate/packages/pg-migrate-test-support`. The working tree includes plan 83 execution changes; inventory and preserve them before adapting descriptors or regenerated files.


## Plan of Work


### M1 — One released build graph

Record the current candidate revision and dirty paths, including any ignored `cabal.project.local` or `.dev` project. Use the existing isolation approach documented in `tools/qualification/README.md` and `docs/dependency-cohort.md`; do not qualify a sibling-checkout override as a released solve. Preserve the separately pinned Kikan source exception from ADR 0039 and record it explicitly; it does not justify source overrides for this upgrade's runtime dependencies.

Verify current Hackage metadata and upstream tags before editing dependency pins. Move the UTC index snapshot far enough to include the selected releases and revisions. Update explicit bounds in every affected `.cabal`, `cabal.project` and `mori.dhall` consistently, including Kioku and pg-migrate consumers. Remove only `pg-migrate-test-support:ephemeral-pg`: released 1.2.0.0 admits `ephemeral-pg >=0.3.1 && <0.4`. Evaluate the unrelated `claude:http-client-tls` exception separately, retaining it unless published metadata actually fixes it. Do not broaden `allow-newer` to suppress runtime major bounds.

Compile and adapt mandatory API changes using Mori-resolved released source. Default-record updates should absorb new fields. Direct Shibuya `AppConfig` construction in `shikigami-workers/src/Shikigami/Trigger/Consumer.hs` must use `defaultAppConfig`; explicit `Ingested` fixtures must supply delivery status; `ProcessorState` health matches must handle Paused. Update subscription capacity constructors, startup exceptions and custom effect interpreters where actually used. These edits preserve current behavior; deeper adoption belongs to the runtime child.

Regenerate all six current workspace members with the pinned DSL. Update whole-logical-name queue/query symbols and every generated aggregate `BehaviorContract` consumer for the 0.21 changes. Preserve create-once holes and real history-backed witnesses. Update the generated Cabal fragment/module list and compile generated service conformance. Take a second generated-tree snapshot and prove identical bytes on another scaffold. Do not require zero whole-tree Git diff when unrelated hand-owned execution edits are present; FRIC-6 documents that recipe limitation. Keep gate strength by comparing the reviewed candidate index or an isolated candidate snapshot.

M1 accepts a clean released solve, a successful all-package build and generated service conformance, with recorded selected versions and no new solver relaxation.

### M2 — Fresh and retained-schema migration

Extend the composed migration path and tests for every intervening upstream prerequisite. Resolve the historical PGMQ ownership explicitly: prove the current vendored schema/ledger state, use the owning package's supported adoption path if available, otherwise add a new application migration containing the required forward delta with attribution and invariant checks. Never edit the old snapshot/checksum or apply a second fresh baseline over existing objects. Record the chosen ownership in ADR 0038 and the audit.

Use disposable PostgreSQL fixtures to apply the old qualified 0.18 composed plan, seed representative event streams, workflow rows, queue messages and live-only evidence/execution rows, then stop all old writers and apply the new composition. Preserve subscription checkpoint meaning, retained queue bodies and protected payload references. Include Kioku registry reconciliation through its released API. On large stores, the runbook must budget the category backfill and index lock and schedule the documented post-migration VACUUM outside a transaction.

Prove fresh application, retained-schema application, read-only startup refusal before migration, success afterwards, and a no-op second application. The upstream count of 48 migrations describes its own composition, not Shikigami's total. Assert component identities and order rather than copying that count. No production database is touched by this plan.


## Concrete Steps


Run from the repository root in the declared Nix development shell. Keep independent build output directories for old and new sources.

```bash
mori registry search keiro
mori registry show shinzui/keiro --full
mori registry docs shinzui/keiro
curl -fsSL https://hackage.haskell.org/package/keiro.json
git ls-remote --tags https://github.com/shinzui/keiro.git 'refs/tags/*0.22.0.0*'
nix develop --no-write-lock-file -c cabal build all --dry-run
nix develop --no-write-lock-file -c cabal build all
nix develop --no-write-lock-file -c just keiro-check
nix develop --no-write-lock-file -c just keiro-inspect
nix develop --no-write-lock-file -c cabal run -v0 keiro-dsl -- scaffold domain/shikigami.keiro-workspace --out shikigami-core/src
nix develop --no-write-lock-file -c cabal test keiro-shikigami-conformance
nix develop --no-write-lock-file -c cabal test shikigami-migrations-test shikigami-migrations-smoke --test-options=-j1
bash tools/check-migration-schema-isolation.sh
git diff --check
```

Expected results: seven existing Keiro packages and the DSL are exactly 0.22.0.0, every current workspace member declares candidate Language 6, conformance passes, and migration fixtures pass without the removed fixture relaxation. If ambient project paths are missing, use the documented isolated project generated from the same candidate and record its path and inputs; do not change the target cohort to make ambient overrides work. Save concise release/solve/migration evidence under `docs/evidence/keiro-0.22/` when implementing.


## Validation and Acceptance


M1 proves that generated runtime consumers and real service packages compile together, not just the upstream tool. Compare wire/replay diagnostics against the recorded pre-upgrade application revision and report source-only churn separately. M2's upgrade fixture must actually begin from the old schema; fresh migrations alone do not prove upgrade safety. Seeded data and checkpoints survive, missing schema refuses startup before intake, the second pass writes no migrations, and schema isolation passes. Failure or an incompatible published dependency is recorded as a concrete blocker with evidence, not bypassed with `allow-newer`. Final retained-history and Nix qualification remain separately owned by `docs/plans/95-close-the-runtime-pattern-audit-and-qualify-the-keiro-0-22-rollout.md`.


## Idempotence and Recovery


Dependency edits, compilation and scaffold are repeatable against the candidate. Preserve hand-owned holes and unrelated dirty changes. Allocate any new application migration only during implementation; applied files remain checksum-immutable. Fixture failures are retried in new disposable databases. The 0.18→0.22 writer/schema changes forbid claiming ordinary binary rollback after migration: restored old binaries need a compatible restored database or a separately proved forward recovery procedure. Keep old build and fixture artifacts for comparison. Do not exploit the historical pre-v1 reset exception.


## Interfaces and Dependencies


This child has no hard predecessor. It owns the released dependency selection, mandatory compile adaptations, generated baseline and composed migration path. `docs/plans/93-adopt-guarded-catalog-commands-and-qualify-current-dsl-consumer-contracts.md` and `docs/plans/94-adopt-current-runtime-lifecycle-patterns-and-bounded-operator-inspection.md` cannot begin until this whole child is Complete. Their consumer interfaces are the real 0.22 Keiro command/catalog/inspection modules, 0.12 Shibuya and Kiroku lifecycle types, current generated symbols and passing migration fixtures. The final packaging child consumes the recorded solve; it owns re-exporting the final runtime closure after later changes.
