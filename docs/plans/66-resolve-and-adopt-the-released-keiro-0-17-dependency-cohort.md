---
id: 66
slug: resolve-and-adopt-the-released-keiro-0-17-dependency-cohort
title: "Resolve and adopt the released Keiro 0.17 dependency cohort"
kind: exec-plan
created_at: 2026-09-18T16:22:03Z
intention: intention_01m2trbg5ze1dt6dfz50mxg4bq
master_plan: "docs/masterplans/12-adopt-keiro-0-17-and-applicable-runtime-haskell-and-postgresql-patterns.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-18T16:22:03Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-18T17:18:36Z
      mode: "implement"
      note: "Started release-cohort resolution and linked the inherited intention"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-19T02:23:08Z
      mode: "implement"
      note: "Completed the clean all-Hackage release-boundary qualification"
---

# Resolve and adopt the released Keiro 0.17 dependency cohort

This ExecPlan is a living document governed by agents/skills/exec-plan/PLANS.md. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Update durable decisions in docs/adr/ when implementation changes them.


## Purpose / Big Picture


Make the seven Shikigami packages build and run their existing behavior against one released Keiro 0.17 dependency set. A successful Cabal solve must use Hackage releases without a local checkout hiding incompatible bounds. This is the foundation for subsequent Language 6 and runtime adoption, not a claim that the complete initiative is deployed.


## Progress


- [x] (2026-09-19T02:23:08Z) Milestone 1: Resolved release compatibility and pattern ownership.
  - [x] (2026-09-18T17:20:00Z) Rechecked authoritative package catalogs and tags and captured the isolated solver failure in `docs/evidence/keiro-0.17/release-cohort.md`.
  - [x] (2026-09-18T17:22:00Z) Inventoried every Mori-registered document in the three corpora and assigned an owning child plan in `docs/architecture/keiro-0.17-pattern-adoption.md`.
  - [x] (2026-09-19T00:06:28Z) Qualified the clean Kioku 0.7 release commit and recorded the publisher-reported upload.
  - [x] (2026-09-19T02:23:08Z) Verified all three Kioku 0.7 packages in the public index and completed the all-released solve.
- [x] (2026-09-19T00:06:28Z) Milestone 2: Adopted the 0.17/0.7/PGMQ 0.6 cohort and mechanical API changes against the exact Kioku release commit.
- [x] (2026-09-19T02:23:08Z) Milestone 3: Verified the final public-release boundary in a clean detached worktree without `cabal.project.local`.


## Surprises & Discoveries


2026-09-18: The external release prerequisite still exists. Hackage has no Kioku release newer than 0.6.0.0, and that release excludes Keiro 0.17. An isolated Cabal solve rejects every published Kioku Core version. Evidence is in `docs/evidence/keiro-0.17/release-cohort.md`.

2026-09-18: The owner reported publishing Kioku 0.7. Clean commit
`37c3acd2d16e18c49217bc6189ea20b496907e3b` supplies coherent 0.7 packages,
and Shikigami builds against them. At public Hackage index-state
`2026-09-18T23:13:22Z`, the catalog still listed only through 0.6 and the 0.7
package page was 404, so the final no-local-override solve was deferred until
the propagation recorded below.

2026-09-18: Kioku 0.7 requires an explicit host-owned AI runtime. Shikigami now
loads it from the versioned configuration boundary, resolves `QueryEmbedding`,
uses Kioku's required 1536-dimensional vector contract, and preserves keyword
fallback when AI is disabled.

2026-09-19: Hackage index-state `2026-09-19T01:06:24Z` exposes all three Kioku
0.7.0.0 packages. A clean detached worktree downloaded them from Hackage, built
all application packages, and passed the complete Shikigami test matrix without
`cabal.project.local` or a Kioku package path.


## Decision Log


2026-09-18: Treat compatible published Kioku bounds as an external prerequisite, rather than introducing a broad allow-newer escape. Prefer a validated compatibility revision/release retaining the current Kioku API if available; do not assume the newer AI API is required to use Keiro 0.17.

2026-09-18: Pin `baikai-effectful` to 0.4.0.1. The later 0.4.0.2 requires
effectful-core 2.7, which the Keiro/Kioku cohort excludes; 0.4.0.1 is explicitly
admitted by Kioku 0.7.


## Outcomes & Retrospective


Complete. The code selects Keiro 0.17.0.0, Kioku 0.7.0.0, PGMQ 0.6.1.0,
shibuya-pgmq-adapter 0.16.0.0, Shikumi 0.4 and Baikai 0.7. Mechanical API
changes compile across all packages, `RunJobs` supplies generated ordering, and
Kioku recall uses the new explicit AI runtime. The final clean worktree resolved
and downloaded Kioku 0.7 exclusively from Hackage and passed every release-boundary
gate.


## Context and Orientation


At plan start, cabal.project pinned all seven Keiro packages to 0.15.0.0, PGMQ core/hasql/effectful to 0.5.0.0, shibuya-pgmq-adapter to 0.14.0.0 and Kioku api/core/migrations to 0.5.2.0. Package-level constraints also exist in shikigami-core/shikigami-core.cabal, shikigami-server/shikigami-server.cabal and shikigami-migrations/shikigami-migrations.cabal. The final solve was required to preserve user-local configuration while proving that no local-only override participates.

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
