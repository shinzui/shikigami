---
id: 12
slug: adopt-keiro-0-17-and-applicable-runtime-haskell-and-postgresql-patterns
title: "Adopt Keiro 0.17 and applicable runtime Haskell and PostgreSQL patterns"
kind: master-plan
created_at: 2026-09-18T16:21:53Z
intention: intention_01m2trbg5ze1dt6dfz50mxg4bq
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-18T16:21:53Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-18T17:18:35Z
      mode: "implement"
      note: "Started EP-1 and linked the initiative intention"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-19T00:14:28Z
      mode: "implement"
      note: "Integrated EP-2 through EP-6 implementation and qualification evidence"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-19T02:23:08Z
      mode: "implement"
      note: "Completed the clean all-Hackage qualification and initiative"
---

# Adopt Keiro 0.17 and applicable runtime Haskell and PostgreSQL patterns

This MasterPlan is a living document governed by agents/skills/master-plan/MASTERPLAN.md. Update its registry and living sections as implementation proceeds. The repository implementation and qualification are complete; deployment to a live environment was outside this plan.


## Vision & Scope

Shikigami should build against the released Keiro 0.17 family, execute Language 6 generated contracts, and retain correct agent runs, conversation generations, approval children, evidence queries, and delivery behavior across restart. Operators should have a rehearsed database upgrade and timer-writer cutover. Every applicable pattern in the three requested corpora must have concrete adoption evidence, or an explicit unresolved prerequisite that prevents declaring this initiative complete.

The baseline is the completed docs/plans/65-migrate-shikigami-to-the-keiro-0-15-cohort-and-the-idiomatic-v2-record-model.md. The seven application packages already use GHC2024, concise records, idiomatic-v2 generation, a generated run queue, a validated live-only evidence catalog, isolated database fixtures, and shared runtime owners. Preserve these achievements and qualify them on 0.17.

Release research retrieved all seven Keiro 0.17.0.0 package descriptions from Hackage. The seven upstream package tags peel to 11e0bba4f634ac6fa4526e2814bd5a8177e3f050 in mori://shinzui/keiro. Its 0.17 queue package requires the 0.6 PGMQ family and shibuya-pgmq-adapter 0.16.0.0. Kioku 0.7 was published from clean commit 37c3acd2d16e18c49217bc6189ea20b496907e3b and its public packages admit Keiro 0.17. A clean worktree resolved the complete cohort from Hackage and passed the aggregate qualification without `cabal.project.local`.

Scope includes the source-language move, queue policy and dead-letter contracts, schema isolation, timer claim recovery, applicable nominal types, Haskell conventions, API/CLI/configuration/observability standards, and comprehensive qualification. Adding FIFO ordering, delegated inboxes, process reactions, Kafka-generated publishers for HTTP sinks, partitioned queues, or a new inspection UI merely because the release offers them is outside scope. Reassess their applicability against actual domain invariants and record the result. Applicable gaps must be implemented; non-applicability is not a synonym for expensive.

The three normative owners are mori://shinzui/keiro-runtime-patterns, mori://shinzui/haskell-jitsurei, and mori://shinzui/postgresql-jitsurei. Mori registry content was older than the runtime-patterns files dated September 18; inspect resolved files and record revisions. The AGENTS.md record-pattern path is stale; the registered mori://shinzui/haskell-jitsurei/docs/core-record-patterns resolves to the current patterns/core/record-patterns.md.


## Decomposition Strategy

Separate release resolution, generated domain contracts, delivery semantics, database/runtime operations, general Haskell service conventions, and final deployment qualification. These have distinct observable outcomes and distinct owners. A single version-bump plan would conceal Language 6 and timer rollout work; repeating the previous full-adoption plan would duplicate completed work.

Relevant local decisions consulted are [ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md), which requires generated contracts to execute on the runtime path; [ADR 0004](../adr/0004-one-options-value-and-a-checked-patch-set.md), which assigns one workflow-options owner; [ADR 0009](../adr/0009-kafka-offsets-advance-only-after-durable-dispositions.md), which makes inbox and queue writes atomic before acknowledgement; [ADR 0010](../adr/0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md), which preserves atomic rich evidence; [ADR 0027](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md), whose unused-state exception must be reverified; and [ADR 0037](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md) and [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md), which record the completed cohort, generated record model, startup, resumption and maintenance decisions. The normative docs/workflow-versioning.md applies to all workflow-body changes.

The cross-repository decision mori://shinzui/keiro-runtime-patterns/okf/adrs/concepts/ADR-6 assigns runtime and general Haskell guidance to separate owners. Preserve that division. This plan does not amend accepted architecture merely by proposing work; implementation must update ADRs when the selected policy changes durable behavior.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Resolve and adopt released cohort | docs/plans/66-resolve-and-adopt-the-released-keiro-0-17-dependency-cohort.md | None | None | Complete |
| EP-2 | Language 6 and nominal contracts | docs/plans/67-adopt-language-6-and-executable-nominal-domain-contracts.md | EP-1 | None | Complete |
| EP-3 | Queue, inbox and delivery semantics | docs/plans/68-qualify-keiro-0-17-queue-inbox-and-delivery-semantics.md | EP-1 | EP-2, EP-4 | Complete |
| EP-4 | Timer recovery and schema isolation | docs/plans/69-adopt-guarded-timer-recovery-and-schema-isolated-migrations.md | EP-1 | None | Complete |
| EP-5 | Haskell, API and CLI patterns | docs/plans/70-apply-haskell-service-api-and-cli-patterns-with-wire-compatibility.md | None | EP-1, EP-2 | Complete |
| EP-6 | Rollout and coverage qualification | docs/plans/71-qualify-the-keiro-0-17-rollout-and-close-pattern-coverage.md | EP-2, EP-3, EP-4, EP-5 | None | Complete |


## Dependency Graph

EP-1 supplies the buildable released cohort used by EP-2 through EP-4 for generated contracts and 0.17 runtime APIs. EP-2, EP-3 and EP-4 proceeded independently with the integration boundaries below. EP-3 retains Unordered queue behavior, so it does not require a FIFO schema or EP-2's source-language move. EP-6 integrates all implementation streams because it tests their combined restart, migration and deployment behavior. The registry transitively includes EP-1 through EP-2/3/4.


## Integration Points

EP-1 owns dependency pins, release evidence and initial mechanical compile repairs in cabal.project, the seven Cabal files, mori.dhall and docs/dependency-cohort.md. Later plans may extend package module/test lists, but must preserve its chosen dependency bounds. EP-1 initially adds jobOrdering = Policy.jobOrdering to Shikigami.RunJobs.runJob; EP-3 thereafter owns its runtime policy. EP-2 exclusively owns domain declarations, scaffolder-owned output and generated conformance expectations. EP-3 requests any later queue declaration change through that owner.

EP-2 owns nominal adapter and codec changes in shikigami-core/src/Shikigami/RunJobs.hs; EP-3 owns its job construction, retry and ordering policy. Agree at runJobCodec :: JobCodec RunJob and the unchanged physical queue identity. EP-5 does not independently rename these same types; it supplies record-convention findings to EP-2. Generated code is never hand-edited.

EP-4 owns Shikigami.Migrations, SQL manifests, the test-support sublibrary, Trigger.Timer, and the database/timer portions of Server.Command.Ops. EP-3 owns delivery/DLQ portions of that operator integration; EP-5 owns presentation and CLI ergonomics. Keep upstream operations as the mutation owner and preserve preview/force semantics. EP-4 provides schema capability evidence to EP-3 before final combined qualification.

EP-1 creates docs/architecture/keiro-0.17-pattern-adoption.md: one row per normative document with canonical URI, inspected revision/date, applicability, current evidence, gap, owner, disposition and acceptance evidence. EP-2 owns architecture/Keiki/DSL/projection rows; EP-3 messaging rows; EP-4 runtime assembly, workflows, timers, Kiroku, migration and PostgreSQL rows; EP-5 Haskell, configuration and deployment rows. Navigation, legacy and governance documents are classified explicitly. EP-6 owns final reconciliation and rejects missing rows, unresolved applicable gaps, or unsupported completeness claims.

EP-4 owns docs/operations/keiro-0.17-rollout.md; EP-6 adds rehearsal evidence. EP-2 owns domain inventory updates; EP-1 owns cohort documentation. Each plan owns its test additions, and edits to shared test entry points must retain all other registered tests. Evidence belongs under docs/evidence/keiro-0.17/ with plan-specific filenames.

Cross-plan ADR candidates are the explicit Language 6 baseline despite Candidate metadata, preservation of transactional inbox ownership, guarded timer recovery and coordinated writer rollout, schema-qualified component isolation, nominal admission at generated boundaries, and any retained deviations. At completion EP-6 distills these with the local ADR convention; do not migrate the ADR corpus format as incidental work.


## Progress

- [x] (2026-09-19T02:23:08Z) EP-1: Resolved and adopted the released Keiro 0.17 and Kioku 0.7 dependency cohort.
- [x] (2026-09-19T02:23:08Z) EP-2: Adopted Language 6 and qualified executable boundaries.
- [x] (2026-09-19T02:23:08Z) EP-3: Qualified queue, inbox, DLQ and delivery semantics.
- [x] (2026-09-19T02:23:08Z) EP-4: Added guarded timer recovery and real schema-isolated upgrade evidence.
- [x] (2026-09-18T18:03:00Z) EP-5: Applied Haskell service, API and CLI patterns with wire compatibility.
- [x] (2026-09-19T02:23:08Z) EP-6: Completed pattern coverage, rollout evidence, and the public-release clean-checkout gate.


## Surprises & Discoveries

2026-09-18: EP-1 rechecked Hackage and upstream tags. At that index-state, the newest published Kioku Core was 0.6.0.0 and required Keiro below 0.17, so Cabal could not solve an all-released Keiro 0.17/Kioku cohort. EP-1 stayed open on that external prerequisite while EP-5 proceeded independently.

2026-09-18: EP-5 completed independently. Its 35 matrix rows are closed, the
Haskell/API/CLI changes pass package, black-box HTTP, OpenAPI, and workflow
compatibility checks, and no durable workflow shape changed. At that point the
initiative was blocked at EP-1's published Kioku compatibility prerequisite.

2026-09-18: EP-2 through EP-4 are implemented against the exact Kioku 0.7
release source. Language 6 remains intentionally Candidate in the released Keiro
registry. No reviewed scalar is a total nominal isomorphism. The composed upgrade
now proves migration 0032 under a hostile schema path, guarded timer recovery is
tested through the serving boundary, and selected PGMQ operator operations execute
against the installed SQL.

2026-09-18: EP-6 reconciled 116 corpus rows with no open applicability or owner
disposition. Final completion remains gated by aggregate checks and the public
Hackage solve without the ignored source override.

2026-09-19: Kioku 0.7 appeared in Hackage index-state
`2026-09-19T01:06:24Z`. A clean detached worktree downloaded all three packages
from Hackage, built the seven application packages, and passed every aggregate
gate without `cabal.project.local`. This cleared EP-1 and every dependent plan.


## Decision Log

2026-09-18: Use six functional streams and a final coverage gate. This makes all applicable standards accountable while allowing general Haskell work before the dependency release prerequisite clears.

2026-09-18: Adopt Language 6 deliberately. The September 18 pattern policy requires it on 0.17 even though released toolchain metadata labels it Candidate and new skeletons still default to 5. Preserve that fact in documentation and check the exact adopted version.

2026-09-18: Preserve current durable behavior by default. Neither the historical pre-v1 exception nor the availability of new producer, inbox, FIFO and reaction APIs proves an identity change is safe or useful.

2026-09-18: A compatible published Kioku cohort is a completion gate. Do not silently turn this Shikigami planning task into upstream publishing or an AI-platform migration; resolve and document the concrete release path in EP-1.


## Outcomes & Retrospective

Complete. Implementation and child evidence are integrated. All applicable pattern rows are
closed, ADRs 0037 and 0038 carry the durable decisions, and the rollout procedure
records the writer cutover and rollback boundary. The clean public-Hackage checkout
passed the full application, PostgreSQL, migration, generation, evolution, HTTP,
OpenAPI, schema-isolation and Nix check suite.
