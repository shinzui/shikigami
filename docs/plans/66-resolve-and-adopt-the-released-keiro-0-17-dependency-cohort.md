---
id: 66
slug: resolve-and-adopt-the-released-keiro-0-17-dependency-cohort
title: "Resolve and adopt the released Keiro 0.17 dependency cohort"
kind: exec-plan
created_at: 2026-09-18T16:22:03Z
master_plan: "docs/masterplans/12-adopt-keiro-0-17-and-applicable-runtime-haskell-and-postgresql-patterns.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-18T16:22:03Z
---

# Resolve and adopt the released Keiro 0.17 dependency cohort

This ExecPlan is a living document governed by agents/skills/exec-plan/PLANS.md. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Update durable decisions in docs/adr/ when implementation changes them.


## Purpose / Big Picture


Make the seven Shikigami packages build and run their existing behavior against one released Keiro 0.17 dependency set. A successful Cabal solve must use Hackage releases without a local checkout hiding incompatible bounds. This is the foundation for subsequent Language 6 and runtime adoption, not a claim that the complete initiative is deployed.


## Progress


No implementation has started. Populate a timestamped checklist at the first implementation step.


## Surprises & Discoveries


None during implementation yet. The verified release prerequisite is recorded below.


## Decision Log


2026-09-18: Treat compatible published Kioku bounds as an external prerequisite, rather than introducing a broad allow-newer escape. Prefer a validated compatibility revision/release retaining the current Kioku API if available; do not assume the newer AI API is required to use Keiro 0.17.


## Outcomes & Retrospective


To be filled during implementation, including the actual selected package versions, source revisions, solver result and unresolved release prerequisites.


## Context and Orientation


Work from the repository root. cabal.project pins all seven Keiro packages to 0.15.0.0, PGMQ core/hasql/effectful to 0.5.0.0, shibuya-pgmq-adapter to 0.14.0.0 and Kioku api/core/migrations to 0.5.2.0. Package-level constraints also exist in shikigami-core/shikigami-core.cabal, shikigami-server/shikigami-server.cabal and shikigami-migrations/shikigami-migrations.cabal. cabal.project.local carries unrelated compatibility allowances; inspect and preserve user edits, and prove the final solve without depending on local-only overrides.

A cohort is a set of package versions whose constraints can be solved together. On 2026-09-18 Hackage served all seven Keiro 0.17.0.0 descriptions and their upstream tags peeled to 11e0bba4f634ac6fa4526e2814bd5a8177e3f050. The authoritative source owner is mori://shinzui/keiro; CHANGELOG.md and each package's Cabal file are project-relative source locations, artifact-level URIs pending. Runtime packages keep Keiki 0.9, Kiroku 0.8 and Shibuya core 0.9 ranges, but keiro-pgmq requires PGMQ >=0.6 && <0.7 and shibuya-pgmq-adapter ^>=0.16.0.0.

mori://shinzui/kioku/packages/kioku-core version 0.5.2.0 requires Keiro ^>=0.15.0.0. Its latest published 0.6.0.0 requires ^>=0.16.0.0, also excluding 0.17. Kioku 0.6 changes AIRuntime, recall and distillation APIs and raises Baikai/Shikumi dependencies. Neither current release can simply be repinned to satisfy the requested upgrade. The API and migration packages must move consistently with core.

[ADR 0037](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md) requires real released contracts and generated runtime authority. [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md) requires read-only schema verification before resources and keeps core independent of migrations. The earlier implementation evidence is docs/dependency-cohort.md and docs/plans/65-migrate-shikigami-to-the-keiro-0-15-cohort-and-the-idiomatic-v2-record-model.md. Do not reset its durable baseline.


## Plan of Work


### Milestone 1 — Resolve release compatibility and pattern ownership

Recheck Hackage preferred versions and current package descriptions, including revisions, and upstream tag hashes for the seven Keiro packages, Kioku, PGMQ and its Shibuya adapter. Use Mori to locate each dependency before examining APIs. Capture compact evidence in docs/evidence/keiro-0.17/release-cohort.md. Establish whether a compatible Kioku revision/release has appeared. If none has, record the precise failing bounds and the requested upstream compatibility work. An isolated compatibility probe may demonstrate that the Kioku 0.5.2 API can compile with 0.17; label its result experimental and never use it as the final released solve. External publication is a prerequisite, not implicitly authorized work in another repository.

Create docs/architecture/keiro-0.17-pattern-adoption.md by enumerating the three corpus indexes and registered docs, then reconciling them with their current files. Include every normative pattern, canonical URI, corpus commit and dirty-state observation, applicability, source evidence, owning child path, and acceptance condition. Allocate runtime architecture/DSL/Keiki/projections to docs/plans/67-adopt-language-6-and-executable-nominal-domain-contracts.md; messaging to docs/plans/68-qualify-keiro-0-17-queue-inbox-and-delivery-semantics.md; runtime/Kiroku/migrations/PostgreSQL to docs/plans/69-adopt-guarded-timer-recovery-and-schema-isolated-migrations.md; Haskell/config/deployment to docs/plans/70-apply-haskell-service-api-and-cli-patterns-with-wire-compatibility.md. Unknown applicability remains open. Acceptance is a complete inventory and either a released solvable cohort or an explicit external prerequisite; the latter does not complete this plan.

### Milestone 2 — Adopt the supported cohort and mechanical API changes

Once compatible Kioku packages exist, update cabal.project, package bounds, mori.dhall dependency metadata and docs/dependency-cohort.md together. Select all seven Keiro packages at 0.17.0.0, the compatible 0.6 PGMQ family including transitive pgmq-config, and adapter 0.16.0.0, verifying their publication. Keep unrelated versions unless a documented constraint requires movement. If the only supported Kioku path uses the new AI API, first inventory the actual Shikigami call sites, update this plan with concrete migration steps and acceptance, and reconcile the Baikai/Shikumi/Handan graph; an unresolved AI migration cannot be hidden in a solver allowance.

In shikigami-core/src/Shikigami/RunJobs.hs, construct Job with jobOrdering = Policy.jobOrdering, preserving Unordered. Search direct record construction and exhaustive matches for QueueMetrics, DlqEntry and PurgeDlqResult; fix actual call sites rather than adding compatibility aliases. Keep source Language 5 during this mechanical stage, regenerate with the pinned 0.17 scaffolder, and reconcile its Cabal fragment. This plan owns that initial regeneration; the Language 6 child owns subsequent generated work. Acceptance is a clean solve and build with the same durable codecs and queue identity.

### Milestone 3 — Verify the release boundary

Run the generated conformance and existing tests on isolated databases. Capture the selected install plan and compiler version. Verify pure wire fixtures and the offline stub behavior, with no live model credentials. Update dependency documentation and the adoption matrix. This milestone proves compatibility, not the final rollout; migration 0032 and timer safety belong to the database child.


## Concrete Steps


Run from /Users/shinzui/Keikaku/bokuno/shikigami. These initial checks are read-only:

```bash
mori registry search keiro
mori registry search kioku
mori registry search pgmq-hs
mori registry search shibuya-pgmq-adapter
curl -fsSL https://hackage.haskell.org/package/kioku-core/preferred.json
curl -fsSL https://hackage.haskell.org/package/kioku-core-0.6.0.0/kioku-core.cabal
git ls-remote --tags https://github.com/shinzui/keiro.git '*0.17.0.0*'
cabal build all --dry-run
```

After compatible releases and edits, use the repository development shell if the compiler or PostgreSQL executables are missing:

```bash
nix develop
cabal build all
cabal run -v0 keiro-dsl -- scaffold domain/shikigami.keiro-workspace --help
just keiro-check
just keiro-inspect
cabal test keiro-shikigami-conformance shikigami-core-test shikigami-migrations-test
cabal test shikigami-migrations-smoke shikigami-workers-test
```

Use the exact scaffold invocation from justfile to regenerate, then commit the generated output before running its no-drift recipe. Expected outcomes are a successful solver with Keiro 0.17, all named suites passing, and no old wire fixture changes. Preserve the baseline git revision in release-cohort.md for later evolution comparisons.


## Validation and Acceptance


All seven Keiro packages resolve to 0.17.0.0 in the Cabal plan; no source-repository-package, local checkout or new allow-newer entry masks a Kioku/Keiro conflict. The build includes all seven application packages and generated conformance. Queue payload and workflow fixture bytes remain unchanged. Shikigami.RunJobs.runJob carries the exact generated ordering. The matrix covers all three corpora and assigns every unresolved row. Any still-incompatible upstream release keeps this plan In Progress with an external prerequisite, and dependent plans cannot be marked complete.


## Idempotence and Recovery


Pin edits are reversible source changes before deployment. Never rewrite an applied migration or run migration commands against a developer/shared database during compatibility probing. Tests use the owned ephemeral database fixture. Preserve cabal.project.local; use a disposable checkout without local overrides for the independent solve. No branch is required. A failed solve should leave concrete evidence and no broadened production bounds.


## Interfaces and Dependencies


There are no hard child dependencies. This plan provides a compilable package cohort and the initial adoption matrix to the Language 6, messaging and database plans. Shikigami.RunJobs.runJob remains Job RunJob; runJobCodec remains JobCodec RunJob. Source-language migration is owned by docs/plans/67-adopt-language-6-and-executable-nominal-domain-contracts.md. Runtime semantics are owned by docs/plans/68-qualify-keiro-0-17-queue-inbox-and-delivery-semantics.md and docs/plans/69-adopt-guarded-timer-recovery-and-schema-isolated-migrations.md. Cite dependencies using mori://shinzui/keiro/packages/keiro, mori://shinzui/kioku/packages/kioku-core and their corresponding package handles. Do not infer future deprecation promises; the observed mintIntegrationEvent deprecation is distinct from hypothetical future removals.
