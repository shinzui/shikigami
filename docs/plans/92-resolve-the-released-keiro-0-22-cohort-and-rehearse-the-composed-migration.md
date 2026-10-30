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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T13:33:35Z
      mode: "update"
      note: "Require verified old source, dependency solve and build artifacts before upgrade edits."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-30T19:46:17Z
      mode: "update"
      note: "Expand unused-service adoption to six children, current domain census, HTTP/live inspection, Haskell corpus and first-release qualification."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-30T20:18:57Z
      mode: "implement"
      note: "Resolve released companion metadata and begin dependency migration"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T13:29:30Z
      verdict: "changes-requested"
      note: "M1 must capture tracked and untracked baseline contents and the old solve before mutation for EP-4."
---

# Resolve the released Keiro 0.22 cohort and rehearse the composed migration

## Purpose / Big Picture

Build and provision Shikigami with one released Keiro 0.22 cohort, including the runtime substrates needed for administrative inspection.

## Progress

- [x] M1 (2026-10-30): Released cohort/DSL compile all packages and test components; strict check, inspection, identical second scaffold and 122 conformance checks pass. Native core (377) and worker (248) tests pass; see `docs/evidence/keiro-0.22/plan-92-results.json`.
- [x] M2 (2026-10-30): Fresh five-component schema, repeat application and read-only startup refusal pass 11 native PostgreSQL smoke tests and nine source/composition tests; evidence under `docs/evidence/keiro-0.22/migrations-*.txt`.

M1 is underway (2026-10-30): the release-only solve passes at the fixed October
30 snapshot, with published Kikan commit 16704290d527d413568bfa40c983f5c3604c35c8.
`docs/evidence/keiro-0.22/released-cohort.json` records descriptor hashes and
selected versions. Strict checking, inspection, deterministic generation and all 122 generated
conformance checks pass. The dependency-only semantic diff is replay-neutral.
Full consumer compilation passes.
M2 now composes the upstream PGMQ owner and removes the vendored baseline;
native smoke acceptance passed all eleven cases. No developer database was changed.

## Surprises & Discoveries

The October 28 scope assumed a deployed population and an older domain census. The user and current tree invalidate those assumptions; fresh-schema acceptance is recorded above.

Kioku 0.12.0.1 requires Baikai Effectful 0.4.0.5/Baikai 0.10; 0.12.0.0 is
compatible with the existing Baikai cohort. Kiroku adapter 0.7.0.1 requires
Store 0.13, outside Keiro 0.22's bound; select adapter 0.7.0.0/Store 0.12.
Kioku requires Relay Pagination 0.1.1.2, so advance its exact old constraint.

## Decision Log

2026-10-30: Apply the user's first-release policy and exhaustive current-guide adoption. Replace old-history qualification with fresh provisioning and same-build recovery. Preserve real transaction, authority and privacy invariants.

2026-10-30: Compose the released PGMQ component and make every application
migration schema-qualified. Retire the old 0.15 ledger fixture, whose claimed
historical bytes no longer describe the current component. ADR-38 records the
owner boundary. Fresh provisioning and repeat-apply/startup refusals remain the
authoritative acceptance checks.

## Outcomes & Retrospective

Completed 2026-10-30. All seven packages and generated consumers build with the
released 0.22 cohort and immutable Kikan source. Native migration acceptance
passes 11 cases; nine default source/composition tests include lock, membership,
body lint and negative mutations. Live framework/application verification has a
public migration CLI command and detects independent schema drift. Conformance
passes 122 checks; core PostgreSQL and worker suites pass 377 and 248 cases.

`docs/evidence/keiro-0.22/cohort-and-schema.md` records source/release selections,
commands and evidence. The schema-check profile is PostgreSQL 18 because the
released framework snapshot explicitly refuses other majors. No populated
legacy upgrade, Linux runtime, exported final closure or final inspection
capability is certified. Plans 93–107 and final plan 95 retain those obligations.
ADR-38 records the upstream PGMQ/application schema owner and startup boundary.
No implementation friction entry was required in this child.

## Context and Orientation

Shikigami has seven packages: core domain/runtime, API contracts, HTTP server, workers, client/CLI, migrations and the lightweight agent runner. The last is the deliberate ADR-3 exception to the six-package pattern. Work from this repository root and locate dependencies through Mori before using their APIs. Never traverse `/nix/store`. Current objective work under MasterPlan 17 edits configuration, generated catalogs, migrations and core tests; preserve and reconcile that work rather than reverting it. The workspace currently has ten members, including ExecutionDriver, WorkerSession, ContinuingWorker and Objective. Recount from `domain/shikigami.keiro-workspace` at implementation; neither six members nor two aggregates is a valid fixed inventory.

On 2026-10-30 the user confirmed Shikigami is unused. [ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) and [ADR-37](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md) apply: establish one current first-release contract, remove obsolete compatibility branches/readers, and allow deliberate schema/wire changes. Do not require old binaries, old populated databases or cross-build replay as acceptance. This does not authorize deleting a developer database or weakening external authorization, accounting, protected payloads or same-build replay. Record exact breaking DSL findings and establish the accepted baseline without suppressing the differ. `docs/workflow-versioning.md` still governs durable bodies after that baseline.

The frozen guide inventory is `docs/architecture/keiro-0.22-coverage.json`: canonical resource, producer revision, relative source path, SHA-256, child owner, pending disposition and evidence. The readable audit is `docs/architecture/keiro-0.22-pattern-audit.md`. Pending rows are planned work, not compliance claims. Every applicable clause requires an implemented behavior or justified existing implementation and current evidence. Strict unprefixed fields, explicit deriving strategies and isolated generic-lens orphan imports apply to all touched Haskell and examples.

`cabal.project` pins Keiro 0.18, Kioku 0.7, Kiroku Store 0.8 and pg-migrate 1.1. It also includes sibling Kikan source paths and several pinned source repositories. `docs/dependency-cohort.md`, `tools/qualification/README.md` and [ADR-39](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md) describe the separate deployment closure. The final closure export belongs to plan 95. [ADR-38](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md) requires migration verification before intake. `shikigami-migrations/src/Shikigami/Migrations.hs` composes upstream and application migrations; historical `0002-pgmq-schema.sql` vendors PGMQ and must not compete with a new upstream baseline.

## Plan of Work

M1 verifies the whole 0.18→0.19→0.20→0.21→0.22 release path, not just the last changelog section. Hackage's registry and remote package tags were rechecked on 2026-10-30: Keiro 0.22.0.0 is released and its tag peels to b28201f2063fa4f6dcb724cbf474959107e36b74. Verify companion published descriptors and tags before selecting exact pins. Include Kioku compatible with Store 0.12, Kiroku migrations 0.7.2, Shibuya 0.12, PGMQ 0.7/adapter 0.18 and pg-migrate 1.2. Include keiro-ops-http 0.22 and verify compatible Kiroku/Shibuya/PGMQ inspection packages for plan 106. Do not blindly select the newest incompatible Store major.

Update every Cabal bound, fixed index-state, Mori dependency declaration and DSL tool selection consistently. Replace source packages with Hackage where available; eliminate sibling paths from reproducible build configuration using verified public immutable upstream sources, or the already documented immutable Kikan artifact where publication is unavailable. Never replace a missing release with an unrecorded corpus override. Remove the obsolete pg-migrate-test-support ephemeral-pg relaxation; independently assess unrelated allow-newer entries rather than broadening them.

Adapt required public constructors/matches using released sources: defaultAppConfig preserves basic metrics, direct Ingested records need deliveryStatus, health handles Paused, new OpsOutcome failures remain errors. Regenerate every actual workspace member and conformance package, correcting generated whole-name stems and history-backed witnesses. Preserve application holes and prove two scaffolds are identical. Deeper domain changes belong to plan 93.

M2 establishes one clean first-release schema. Inspect the vendored PGMQ baseline and adopt the supported upstream migration owner where possible; otherwise provide an attributed application delta with explicit invariant checks. Never apply two competing baselines. Because there is no deployed ledger to preserve, simplify unreleased application composition where justified and regenerate its manifest/checksums together. Keep framework SQL framework-owned and qualify every application object. Ensure PGMQ 0007, Kiroku 0012–0016 and Kioku prerequisites are represented in the composed plan. The upstream 48-entry count is not Shikigami's total. Prove fresh application, read-only verification, refusal on pending/unknown/drifted schema before intake, successful startup afterwards and a no-op second apply. No old database upgrade rehearsal is required.

## Concrete Steps

Run from the repository root in the declared development shell. Use disposable task-owned databases and the existing source-owned fixtures. These are implementation commands, not evidence of tests already run:

```bash
mori show --full
mori registry search keiro
nix develop --no-write-lock-file -c cabal build all
nix develop --no-write-lock-file -c just keiro-check
nix develop --no-write-lock-file -c cabal run -v0 keiro-dsl -- scaffold domain/shikigami.keiro-workspace --out shikigami-core/src
nix develop --no-write-lock-file -c cabal test keiro-shikigami-conformance
nix develop --no-write-lock-file -c cabal test shikigami-migrations-test shikigami-migrations-smoke --test-options=-j1
bash tools/check-migration-schema-isolation.sh
```

Record actual cases and concise output under `docs/evidence/keiro-0.22/`. Database tests that skip are not accepted. Before claiming Linux is unavailable, inspect `container --help`, `container list --all` and `tests/workspace/build-apple.sh`; use native ARM64 Apple containers, retaining the documented remote-builder fallback only when needed. Do not claim runtime containment from compilation alone.

## Validation and Acceptance

An actual recorded solve and build select matching 0.22 packages/tool; native migration cases prove the startup contract. Record changed package provenance, source exceptions and per-component migration identities. No unexplained solver relaxation, sibling dependency or local registry shortcut remains. Save release and migration evidence, including selected companion versions, for the final packaging child.

## Idempotence and Recovery

Repeat generation against an isolated coherent candidate so concurrent uncommitted work cannot masquerade as generated drift. Preserve create-once holes. Recreate only task-owned disposable fixtures after failure; never clear shared journals, leases or bindings to obtain a passing test. Record the source/dirty diff and current input artifacts for reproducibility, without requiring a successful old build before refactoring. A released-schema rollback is not promised. Future post-release evolution resumes the ordinary versioning rules. Record friction through `agents/skills/exec-plan/FRICTION.md`, promote durable decisions through the local plain-Markdown ADR convention, and scan touched code and prose for stale prefixed fields.

## Interfaces and Dependencies

No hard predecessor. Own dependency manifests, mandatory compile regeneration and schema composition. Plans 93, 94, 106 and 107 consume this whole child after completion. Plan 95 owns final exported deployment artifacts.

## Revision Notes

2026-10-30: Expanded MasterPlan 16 under the user's unused-service confirmation; replaced compatibility-driven scope with current-contract adoption and explicit behavioral evidence. Previous provenance entries and review verdicts remain historical and do not certify this revision.
