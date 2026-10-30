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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T13:33:35Z
      mode: "update"
      note: "Apply review: require pre-edit baseline handoff and preserve late-write rollback outside typed preconditions."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-30T19:46:17Z
      mode: "update"
      note: "Expand unused-service adoption to six children, current domain census, HTTP/live inspection, Haskell corpus and first-release qualification."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-30T20:18:57Z
      mode: "implement"
      note: "Begin released cohort resolution under plan 92"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T13:29:30Z
      verdict: "changes-requested"
      note: "Capture the old source and solve before EP-1 edits; resolve EP-2 late-refusal callback semantics."
---

# Upgrade Shikigami to Keiro 0.22 and adopt current runtime and Haskell practices

## Vision & Scope

Run one released Keiro 0.22 cohort with current generated domain contracts, correct durable delivery/recovery, useful administrative CLI/HTTP/live inspection and complete current-guide evidence. The user confirmed on 2026-10-30 that Shikigami is unused and refactoring is cheap. Apply ADR-27: establish the intended first-release schema, codecs and workflow baseline; remove obsolete readers and patch branches rather than adding historical compatibility. Do not require an old successful build, populated upgrade or cross-build replay. Fresh provisioning and same-build crash/restart, accounting, authorization and protected evidence remain mandatory.

This refresh expands the existing MasterPlan 16 and preserves intention `intention_01m61agcfzek98hqzkb0kxcfmg`; unrelated completed EP-16 is unchanged. All applicable features across the 0.18→0.22 gap must receive evidence-backed adoption. A non-applicable disposition needs a specific absent consumer or genuine upstream capability limitation, never refactoring cost or obsolete bytes. Do not fabricate a process manager from a workflow or a Kafka publisher from an HTTP sink.

Hackage and remote tags were rechecked on 2026-10-30: 0.22.0.0 is the latest listed Keiro release and tag keiro-0.22.0.0 peels to b28201f2063fa4f6dcb724cbf474959107e36b74. Verify companion releases before pinning; latest compatible cohort does not mean latest independent major of every library. Source owner is `mori://shinzui/keiro`. Kotei's analogous initiative is `mori://shinzui/kotei/masterplans/21-migrate-kotei-to-keiro-0-22-and-adopt-current-runtime-practices`; it supplies no Shikigami implementation evidence.

## Decomposition Strategy

Expand four children into six independent behaviors. Preserve plans 92–95 and their provenance, but separate inspection hosting and Haskell/service refactoring from lifecycle and final qualification. This keeps significant implementation out of an audit-only final plan and gives host/resource boundaries a single owner.

Consulted decisions: [ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) and [ADR-37](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md) permit clean adoption; [ADR-38](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md) keeps migration/startup/recovery ownership; [ADR-39](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md) requires one frozen closure; [ADR-53](../adr/0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md) and [ADR-54](../adr/0054-execution-attempts-own-dispatch-fences-and-generation-wakes.md) preserve atomic outcomes and dispatch fences. [ADR-71](../adr/0071-first-release-inspection-is-an-isolated-administrative-runtime.md) records the new inspection boundary. ADR-1's declare-only-executed rule and ADR-3's seventh-package exception remain. Cross-repository ADR-28 and ADR-54 were resolved with Mori and read: `mori://shinzui/keiro/okf/adrs/concepts/ADR-28` and `mori://shinzui/keiro/okf/adrs/concepts/ADR-54`.

## Exec-Plan Registry

| # | Workstream | Path | Hard Deps | Soft Deps | Status |
|---|---|---|---|---|---|
| EP-1 | Released cohort and fresh schema | [92](../plans/92-resolve-the-released-keiro-0-22-cohort-and-rehearse-the-composed-migration.md) | None | None | Complete |
| EP-2 | Guarded commands and complete domain adoption | [93](../plans/93-adopt-guarded-catalog-commands-and-qualify-current-dsl-consumer-contracts.md) | EP-1 | None | Complete |
| EP-3 | Native delivery and workflow recovery | [94](../plans/94-adopt-current-runtime-lifecycle-patterns-and-bounded-operator-inspection.md) | EP-1 | EP-2 | Complete |
| EP-4 | Administrative CLI, HTTP and live inspection | [106](../plans/106-expose-bounded-administrative-inspection-and-live-feeds.md) | EP-1 | EP-3 | Not Started |
| EP-5 | Haskell and service architecture practices | [107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md) | EP-1 | None | Not Started |
| EP-6 | Integrated first-release qualification | [95](../plans/95-close-the-runtime-pattern-audit-and-qualify-the-keiro-0-22-rollout.md) | EP-1, EP-2, EP-3, EP-4, EP-5 | None | Not Started |

## Dependency Graph

Default order is 92, 93, 94, 106, 107, 95. All hard dependencies name whole completed children. The released build/schema enables each implementation stream. Plans 93, 94, 106 and 107 can proceed independently after 92 with coordinated edits: soft dependencies provide stable domain/metrics context without inventing a prerequisite on the entire ongoing product initiative. Plan 95 requires every implemented surface to qualify one final candidate.

MasterPlans 14, 17 and 18 own evolving execution, objective and tracker capabilities. This upgrade does not replace those product semantics. Capture a coherent current source identity and reconcile their accepted interfaces before touching shared files; no requirement to preserve old successful binaries remains. Refresh evidence when concurrent changes alter the candidate. Never drop objective/worker/session projections to restore the old census.

## Integration Points

EP-1 owns dependency descriptors, source provenance, index-state, mandatory compiling generation and composed schema. It provides plan 106's inspection dependencies as one compatible cohort. EP-2 owns subsequent DSL/domain semantics, current codec baseline and generated artifacts, plus guarded command refusal mapping. Preserve the reviewed distinction: the typed guard is pre-inline; post-write hook/accounting failure still requires exception-triggered whole-transaction rollback. Early proof covers accepted outcome, typed refusal, late refusal after tentative writes and rebuild fencing before broad conversion.

EP-3 owns Shikigami.Runtime, workflow registry, subscription/queue/trigger lifecycle and wake recovery. EP-4 consumes actual worker-local AppHandle metrics, owns shared safe inspector descriptors, host configuration, dedicated inspection pools and listener/feed shutdown. Its first producer/consumer check is one real ExecutionLifecycle state through CLI and HTTP; then expand to the actual aggregate census. Neither child creates a second registry/fold or changes rich-payload authority. EP-5 owns residual Haskell/API/CLI/configuration fixes and package/style gates; coordinate shared Cabal/App.Config edits with the relevant owner instead of doing simultaneous incompatible rewrites.

EP-6 owns final source/release inventory validation, exact-candidate evidence, frozen Nix closure and first-deployment runbook. Every child supplies clause-level findings and evidence in the audit. Shared source inventory rows name exactly one accountable child; a cross-cutting source may link several contributors. EP-2 owns source/fold/snapshot reset decisions; EP-1 owns migration composition; EP-4 owns administrative exposure; EP-6 distills final durable decisions into the plain-Markdown ADR corpus.

## Progress

2026-10-30: EP-1, EP-2 and EP-3 are Complete. The released schema/cohort, current
domain contract and native delivery/recovery are accepted. Latest candidate passes
539 pure,375 PostgreSQL and258 worker tests, including ten consumer policy/lifecycle
cases and two store/options cases. The five-family registry and generation-specific
wakes are covered. Shared source-guide clauses retain explicit pending owners for
106's selected inspection/provider work and95's final artifact/Linux/load evidence.
EP-4 is next; EP-5 and the final whole-corpus gate remain outstanding.

## Surprises & Discoveries

EP-1 adopts upstream PGMQ ownership and removes the vendored baseline. Source
integrity now runs independently of stale compilation, and migration operations
separate ledger verification from live-object drift. The released framework
snapshot supports PostgreSQL 18 only; no PostgreSQL 17 schema-check qualification
is claimed. Release-audit ownership was reconciled so HTTP/header inspection,
worker lifecycle and final release-tooling clauses remain with their consumers.

The previous plan hardcoded six workspace members/two aggregates; the current workspace has ten members including new objective work. RunJobs is currently schema version 4 with three historical upcasters; they are cleanup candidates under the unused-service confirmation. Trigger.Consumer directly constructs Shibuya AppConfig. Ops already uses emptyAppHooks and the native tree; Kotei's duplicated-parser finding does not apply here. Rich evidence is not reconstructible from lifecycle events, so first-release freedom does not license destructive replay of those live-only targets.

## Decision Log

2026-10-30: Supersede October 28's retained-history/old-build requirement and CLI-only exclusion under the user's explicit unused-service confirmation. Preserve the earlier review's late-write rollback correction. Add dedicated inspection and Haskell/service implementation children, preserving existing plan identities and intention. Every applicable guide/release capability must be implemented or verified; exclusions need a real product/capability reason.

## Outcomes & Retrospective

EP-1 is accepted; five children and the integrated first-release gate remain.
No final release or deployment is certified.

## Revision Notes

2026-10-30: Replaced compatibility-driven scope with a clean first-release baseline; expanded four children to six, refreshed the domain census, added Haskell and complete release inventories, and selected administrative HTTP/live feeds. Existing provenance is preserved.
