---
id: 106
slug: expose-bounded-administrative-inspection-and-live-feeds
title: "Expose bounded administrative inspection and live feeds"
kind: exec-plan
created_at: 2026-10-30T19:39:42Z
intention: "intention_01m61agcfzek98hqzkb0kxcfmg"
master_plan: "docs/masterplans/16-upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-30T19:39:42Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-30T21:54:48Z
      mode: "implement"
      note: "Begin safe aggregate catalogs and isolated authenticated inspection after accepted runtime ownership"
---

# Expose bounded administrative inspection and live feeds

## Purpose / Big Picture

Provide safe native CLI inspection plus authenticated administrative HTTP and bounded live feeds for actual runtime state.

## Progress

- [x] (2026-10-30) M1: All four generated aggregate descriptors have explicit safe display encoders; native CLI type/list/show/snapshot and bounded workflow/timer/projection reads pass, with typed cursor/limit and corrupt-history refusal evidence. The complete server suite passes 71 cases. See [M1 evidence](../evidence/keiro-0.22/native-inspection-cli.md).
- [ ] M2: Administrative HTTP surfaces use dedicated capacity, explicit authorization and native mutation policy.
- [ ] M3: Live feeds pass overflow, slow-client, schema, cancellation and joined-shutdown tests.

## Surprises & Discoveries

The October 28 scope assumed a deployed population and an older domain census. The current census has four aggregates. Keiro 0.22 publicly exports the invocation/global option records, so the old database-URL environment adapter is unnecessary: the resolved Settei value now goes directly into the native invocation.

## Decision Log

2026-10-30: Apply the user's first-release policy and exhaustive current-guide adoption. Replace old-history qualification with fresh provisioning and same-build recovery. Preserve real transaction, authority and privacy invariants.

## Outcomes & Retrospective

Not implemented. Record outcomes, remaining profile limitations and triaged friction at completion.

## Context and Orientation

Shikigami has seven packages: core domain/runtime, API contracts, HTTP server, workers, client/CLI, migrations and the lightweight agent runner. The last is the deliberate ADR-3 exception to the six-package pattern. Work from this repository root and locate dependencies through Mori before using their APIs. Never traverse `/nix/store`. Current objective work under MasterPlan 17 edits configuration, generated catalogs, migrations and core tests; preserve and reconcile that work rather than reverting it. The workspace currently has ten members, including ExecutionDriver, WorkerSession, ContinuingWorker and Objective. Recount from `domain/shikigami.keiro-workspace` at implementation; neither six members nor two aggregates is a valid fixed inventory.

On 2026-10-30 the user confirmed Shikigami is unused. [ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) and [ADR-37](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md) apply: establish one current first-release contract, remove obsolete compatibility branches/readers, and allow deliberate schema/wire changes. Do not require old binaries, old populated databases or cross-build replay as acceptance. This does not authorize deleting a developer database or weakening external authorization, accounting, protected payloads or same-build replay. Record exact breaking DSL findings and establish the accepted baseline without suppressing the differ. `docs/workflow-versioning.md` still governs durable bodies after that baseline.

The frozen guide inventory is `docs/architecture/keiro-0.22-coverage.json`: canonical resource, producer revision, relative source path, SHA-256, child owner, pending disposition and evidence. The readable audit is `docs/architecture/keiro-0.22-pattern-audit.md`. Pending rows are planned work, not compliance claims. Every applicable clause requires an implemented behavior or justified existing implementation and current evidence. Strict unprefixed fields, explicit deriving strategies and isolated generic-lens orphan imports apply to all touched Haskell and examples.

`shikigami-server/src/Shikigami/Server/Command/Ops.hs` already uses emptyAppHooks and the upstream parser with replay-audit/catalog hooks; unlike Kotei it has no duplicated group whitelist to replace. Runtime hooks do not currently expose safe aggregate descriptors. Create `shikigami-core/src/Shikigami/Inspection/Aggregates.hs` and `shikigami-server/src/Shikigami/Server/Inspection.hs`, registering them in Cabal and the package architecture tests. Add a worker-owned host for Shibuya process-local metrics; a server cannot inspect an AppHandle it does not own. [ADR-71](../adr/0071-first-release-inspection-is-an-isolated-administrative-runtime.md) defines this selected host boundary. Consult `mori://shinzui/keiro/okf/adrs/concepts/ADR-28` and `mori://shinzui/keiro/okf/adrs/concepts/ADR-54` for public operations and safe hydration.

## Plan of Work

M1 discovers aggregates from the current generated streams/audit/catalog, including RunEvidence, ExecutionLifecycle, WorkerSession and Objective when present. Do not hardcode two descriptors. Use Keiro.Inspection.Aggregate with narrow lifecycle, identity and revision display encoders; never serialize rich replay snapshots, tool arguments, model history or credentials as public display. Prove one ExecutionLifecycle instance through CLI type/list/show before expanding. Include bounded workflow/timer/projection/shard reads and typed InspectionFailed, filter-bound cursors and honest snapshot/hydration status. Mount process-manager inspectors only for actual compiled reactions; durable workflows are not process managers. Keep ordinary provenance capture disabled, and never fabricate modern reaction provenance.

M2 uses released Keiro.Ops.Http and composeSurfaces for `/keiro`, `/kiroku`, `/shibuya` and `/pgmq` where the actual runtime owns the necessary provider. Allocate applications/pools/feed handles before routing; join dependents before releasing pools. Use dedicated inspection capacity, finite connect/acquisition/statement/lock/read/encoding/delivery limits and loopback defaults. Resolve configuration with Settei and fail invalid limits before listener allocation. Integrate explicit administrative authentication/authorization independently of browser Origin/CORS policy. Mutations require deliberate enablement, authorization, preview/confirmation and audit; preserve governed erasure, live-only reset prohibitions and resource-aware resume restrictions. PGMQ dlq read leases messages and is not a harmless browse. Preserve raw encoded mount paths and upstream request/error semantics. The worker hosts its live Shibuya metrics using plan 94's lifetime; do not introduce a second trigger consumer merely to expose metrics. Document each host's address, process owner, metric scope and credential source.

M3 mounts released first-page workflow/timer/projection feeds and applicable companion feeds with their own protocol semantics. Test idle handles without polling/wake cursor, shared HTTP admission, count/byte/in-flight budgets, schema verification on refresh, retiring-view refusal, overflow recovery, reconnect, slow delivery cancellation and bounded joined shutdown. Snapshot metrics resynchronize by snapshot; durable event tails resume by cursor. Missing optional metrics remain unavailable rather than zero. Measure worker progress under inspection load because separate connections do not isolate database CPU/locks. Preserve protocol signed-int64 IDs and document lossless client handling.

Extend `shikigami-server/test/Shikigami/InspectionSpec.hs` and worker lifecycle tests, creating/registering the former if needed. An actual authenticated listener and WebSocket client in a disposable local fixture must prove the behavior; parser tests alone cannot qualify the host.

## Concrete Steps

Run from the repository root in the declared development shell. Use disposable task-owned databases and the existing source-owned fixtures. These are implementation commands, not evidence of tests already run:

```bash
mori registry docs shinzui/keiro-runtime-patterns
nix develop --no-write-lock-file -c cabal run shikigami -- ops --help
nix develop --no-write-lock-file -c cabal test shikigami-server-test shikigami-workers-test
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test --test-options=-j1
```

Record actual cases and concise output under `docs/evidence/keiro-0.22/`. Database tests that skip are not accepted. Before claiming Linux is unavailable, inspect `container --help`, `container list --all` and `tests/workspace/build-apple.sh`; use native ARM64 Apple containers, retaining the documented remote-builder fallback only when needed. Do not claim runtime containment from compilation alone.

## Validation and Acceptance

CLI and HTTP expose the same safe lifecycle facts. Unauthorized requests fail; invalid Origin and non-JSON confirmation fail before mutation. Slow/overflowing/cancelled clients release admission and owned resources. No protected payload is disclosed and no inspection-only query is inserted into command hot paths. Record concrete listener configuration and curl/WebSocket test invocations in the evidence and runbook once implemented.

## Idempotence and Recovery

Repeat generation against an isolated coherent candidate so concurrent uncommitted work cannot masquerade as generated drift. Preserve create-once holes. Recreate only task-owned disposable fixtures after failure; never clear shared journals, leases or bindings to obtain a passing test. Record the source/dirty diff and current input artifacts for reproducibility, without requiring a successful old build before refactoring. A released-schema rollback is not promised. Future post-release evolution resumes the ordinary versioning rules. Record friction through `agents/skills/exec-plan/FRICTION.md`, promote durable decisions through the local plain-Markdown ADR convention, and scan touched code and prose for stale prefixed fields.

## Interfaces and Dependencies

Requires plan 92 Complete. Plan 94 is a soft dependency for stable runtime metrics hooks; use an isolated AppHandle fixture until integration, then require the real owner lifetime before completion. Plan 93 is an integration peer for validated catalogs, never a second fold. Own inspection modules/configuration and tests; final qualification in plan 95 consumes the accepted host.

## Revision Notes

2026-10-30: Expanded MasterPlan 16 under the user's unused-service confirmation; replaced compatibility-driven scope with current-contract adoption and explicit behavioral evidence. Previous provenance entries and review verdicts remain historical and do not certify this revision.
