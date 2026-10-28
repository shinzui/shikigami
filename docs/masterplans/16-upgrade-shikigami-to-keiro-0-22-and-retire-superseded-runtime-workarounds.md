---
id: 16
slug: upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds
title: "Upgrade Shikigami to Keiro 0.22 and retire superseded runtime workarounds"
kind: master-plan
created_at: 2026-10-28T13:07:57Z
intention: "intention_01m61agcfzek98hqzkb0kxcfmg"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-28T13:07:57Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-28T13:21:22Z
      mode: "update"
      note: "Complete source-grounded draft and link the requested Mina intention"
---

# Upgrade Shikigami to Keiro 0.22 and retire superseded runtime workarounds

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope


Upgrade Shikigami's selected Keiro 0.18 runtime to the latest released Keiro family, verified on 2026-10-28 as 0.22.0.0. After completion, deployed roles use one reproducible released dependency cohort, existing histories and queued jobs remain readable, execution command refusals use supported atomic catalog preconditions, and operators can inspect application aggregates through bounded upstream APIs. The initiative also closes an evidence-backed audit against `mori://shinzui/keiro-runtime-patterns` at revision `62531b00b415785be61584a3c44b569fdfb35c4e`.

The initial findings and feature dispositions are in [the audit](../architecture/keiro-0.22-pattern-audit.md). Hackage reports all eight Keiro packages at 0.22.0.0; their peeled upstream tags share commit `b28201f2063fa4f6dcb724cbf474959107e36b74` in `mori://shinzui/keiro`. Seven existing packages must advance together. The eighth, `mori://shinzui/keiro/packages/keiro-ops-http`, remains optional because no operational HTTP listener is selected by this initiative. Recheck release evidence at implementation start; a newer major requires an explicit plan revision rather than silently changing this qualified target.

Include the necessary Kioku, Kiroku, Shibuya, PGMQ and pg-migrate compatibility work; generated Haskell and conformance changes; removal of superseded workarounds; runtime lifecycle checks; immutable deployment packaging; migration rehearsal; and retained-history qualification. Adopt applicable features on executed paths. Record capability-specific reasons for retaining application code where upstream still cannot replace it. This creates plans and an initial source audit; it does not implement the upgrade or certify deployment readiness.

General agent orchestration remains owned by [MasterPlan 14](14-deliver-adaptive-autonomous-objectives-with-durable-workers.md), particularly its in-progress [plan 83](../plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md). Preserve its accepted execution contracts and current work. Do not add a dashboard, operational HTTP/WebSocket listener, new process manager, namespace subscription, destructive projection rebuild, queue drain, or production deployment merely to demonstrate a new upstream feature.


## Decomposition Strategy


Use four behavior-oriented children. EP-1 produces a compilable released cohort and a demonstrated migration path. EP-2 replaces execution refusal plumbing with the released guarded command protocol and qualifies DSL consumers without inventing schema migrations. EP-3 integrates lifecycle semantics and bounded application inspection. EP-4 owns the final cross-build compatibility proof, deployment artifacts, audit closure and operator runbook. Combining them would obscure the difference between successful dependency resolution, correct atomic refusal, useful runtime integration and safe deployment.

Relevant local decisions consulted are [ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md), which permits declarations only on executed paths; [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md), which requires real patch guards for released workflow changes; [ADR 0037](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md), which requires released dependency evidence and honest adoption; [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md), which preserves startup, timer, registry and retention owners; [ADR 0039](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md), which requires one immutable deployment closure; and [ADR 0053](../adr/0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md), which requires atomic execution history, payload, accounting and progress. The pre-v1 exception in ADR 0037 is historical evidence, not current authorization to discard data.

Cross-repository decisions consulted are `mori://shinzui/keiro/okf/adrs/concepts/ADR-28` (operator commands wrap their owning public library) and `mori://shinzui/keiro/okf/adrs/concepts/ADR-54` (explicit aggregate inspection reuses hydration without charging command paths). Canonical handles were discovered through Mori. Implementation must promote durable changes to the corresponding local ADRs; this planning proposal does not mark a new architecture decision accepted.


## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Released cohort and composed migration | [Plan 92](../plans/92-resolve-the-released-keiro-0-22-cohort-and-rehearse-the-composed-migration.md) | None | None | Not Started |
| EP-2 | Guarded commands and DSL consumer contracts | [Plan 93](../plans/93-adopt-guarded-catalog-commands-and-qualify-current-dsl-consumer-contracts.md) | EP-1 | None | Not Started |
| EP-3 | Runtime lifecycle and operator inspection | [Plan 94](../plans/94-adopt-current-runtime-lifecycle-patterns-and-bounded-operator-inspection.md) | EP-1 | EP-2 | Not Started |
| EP-4 | Audit closure and rollout qualification | [Plan 95](../plans/95-close-the-runtime-pattern-audit-and-qualify-the-keiro-0-22-rollout.md) | EP-2, EP-3 | None | Not Started |

Status values are Not Started, In Progress, Complete and Cancelled. All hard dependencies above name whole children.


## Dependency Graph


Execute EP-1, EP-2, EP-3 and EP-4 in registry order by default. EP-1 must be Complete before EP-2 or EP-3 begins: both require the actual 0.22 public interfaces, regenerated consumers and accepted migration fixture. EP-2 and EP-3 are otherwise independently implementable; EP-3 benefits from EP-2's error mapping but has no hard dependency on it. Their integration dependency is the shared validated catalog and its safe operator display. EP-4 requires both complete because its old/new proof and packaged binaries must exercise the final runtime rather than an intermediate adaptation.

Do not require all of MasterPlan 14 to finish before this upgrade. At EP-1 start, record the accepted execution baseline and preserve any uncommitted work. During EP-2 implementation, serialize edits to execution persistence with plan 83's owner. Resume qualification against the reconciled candidate if those contracts move; never resolve concurrent work by dropping its claims, accounting, continuation or wake behavior.


## Integration Points


**Cohort and generated baseline — EP-1 owns.** `cabal.project`, all package descriptors, `mori.dhall`, initial regenerated files and build-time DSL pin define the released interface consumed by EP-2/EP-3. EP-1 performs only mandatory source adaptations and generation; EP-2 owns subsequent DSL semantic changes. EP-4 owns final `nix/qualification/cohort.json`, `metadata.tar.gz` and role validation. Match the compiled closure to the final Cabal solve rather than retaining the old deployment closure.

**Migration composition — EP-1 owns; EP-4 rehearses final artifacts.** `shikigami-migrations/src/Shikigami/Migrations.hs`, its SQL manifest and startup verification include all upstream prerequisites. Shikigami currently vendors PGMQ SQL under its own historical migration, so upstream PGMQ migration 0007 needs an explicit ledger/schema bridge, not blind composition of a second baseline. Preserve applied names and checksums. EP-1 must prove old-schema upgrade and repeat application before downstream work expands.

**Catalog command boundary — EP-2 owns.** `Shikigami.Execution.Store`, `Shikigami.Execution.Catalog`, generated `ExecutionLifecycle`, and existing resource/selection transaction hooks must agree on accepted versus rolled-back work. Its early producer/consumer proof is one execution outcome with accounting and cursor advancement, then a typed relational refusal and a rebuild fence from another connection. Expand across execution paths only after that proof. Preserve the RunEvidence projection set when capturing execution handlers and vice versa.

**Runtime and inspection — EP-3 owns.** `Shikigami.Runtime`, the shared workflow registry, worker assembly/health, and `Shikigami.Server.Command.Ops` consume the accepted cohort. EP-3 defines a small application-owned aggregate inspector catalog using generated event streams, with safe display encoders. It must not expose protected replay payloads or fabricate process-manager catalogs from ordinary workflows. EP-2 consumes this visibility without introducing a second registry. Mandatory compiling adaptations made by EP-1 are extended here, not redefined.

**Audit and compatibility — EP-4 owns; each child contributes evidence.** `docs/architecture/keiro-0.22-pattern-audit.md` is the shared finding ledger. Each child closes its own rows with actual evidence; EP-4 checks the full current pattern inventory and all feature dispositions. The final proof spans retained workflow journals, event history, snapshots, queue v1/v2/v3 readers and any newer execution input present at handoff, rich live-only rows, and migration handshakes. Every workflow body change follows `docs/workflow-versioning.md`; no child may disable a gate or claim generated-file churn proves persisted compatibility.

Durable ADR subjects are the supported relational-refusal boundary, the scope of synchronous command authority versus live-only data retention, PGMQ migration ownership, inspection display/authorization boundaries, and the final writer cutover/rollback limits. Amend existing decisions where they already own these subjects.


## Progress


2026-10-28: Research and initial source audit are complete; four child ExecPlans are created and Not Started. The current working tree selects Keiro 0.18 and contains ongoing execution work. No dependency, runtime or migration implementation was changed in this planning session. Final integration gates remain the stopped-writer migration rehearsal, typed-refusal atomicity proof, retained-history comparison and matching Nix role closure.


## Surprises & Discoveries


The latest standalone Kiroku Store is 0.13.0.0, but released Keiro 0.22 and Kioku 0.12 require the 0.12 line. “Latest Keiro” therefore means the latest compatible released cohort rather than taking the latest version of every dependency. The initial audit records this distinction and the temporary PostgreSQL fixture relaxation whose replacement is now published.


## Decision Log


2026-10-28: Created and linked the user-requested Mina intention across this MasterPlan and all children.

2026-10-28: Separate release/migration qualification, command semantics, runtime inspection and final integration because each has a different observable acceptance boundary. Preserve whole-child hard dependencies on the accepted cohort.

2026-10-28: Select applicable 0.22 inspection through the existing embedded operator CLI. Operational HTTP and live feeds remain explicitly optional until a hosting requirement exists; their absence does not imply a runtime defect.

2026-10-28: Treat every workaround individually. Remove the obsolete PostgreSQL fixture bound relaxation; replace execution business refusals with supported typed preconditions; retain historical queue readers and rich-payload adapters where upstream still lacks the required contract. Structural enum equality is a capability to apply only to a demonstrated consumer, not a reason to widen or rename existing queue enums.


## Outcomes & Retrospective


To be filled during implementation and final qualification.
