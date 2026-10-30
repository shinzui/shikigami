---
id: 94
slug: adopt-current-runtime-lifecycle-patterns-and-bounded-operator-inspection
title: "Adopt current runtime lifecycle patterns and bounded operator inspection"
kind: exec-plan
created_at: 2026-10-28T13:08:12Z
intention: "intention_01m61agcfzek98hqzkb0kxcfmg"
master_plan: "docs/masterplans/16-upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-28T13:08:12Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-28T13:21:22Z
      mode: "update"
      note: "Complete source-grounded draft and link the requested Mina intention"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-30T19:46:17Z
      mode: "update"
      note: "Expand unused-service adoption to six children, current domain census, HTTP/live inspection, Haskell corpus and first-release qualification."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T13:29:30Z
      verdict: "approved"
      note: "Lifecycle and bounded inspection scope is coherent; add current ADR 0054 context when reconciling plan 83."
---

# Adopt current runtime lifecycle patterns and bounded operator inspection

## Purpose / Big Picture

Make actual queue, trigger, subscription and workflow paths correct under the new delivery and resource-lifetime semantics. Inspection hosting is now owned by plan 106.

## Progress

- [ ] M1: Startup, delivery admission, finalization and shutdown have native failure-path evidence.
- [ ] M2: Every registered workflow and custom wake path passes same-build restart, cancellation and ownership-loss recovery.

## Surprises & Discoveries

The October 28 scope assumed a deployed population and an older domain census. The user and current tree invalidate those assumptions; no implementation acceptance is claimed.

## Decision Log

2026-10-30: Apply the user's first-release policy and exhaustive current-guide adoption. Replace old-history qualification with fresh provisioning and same-build recovery. Preserve real transaction, authority and privacy invariants.

## Outcomes & Retrospective

Not implemented. Record outcomes, remaining profile limitations and triaged friction at completion.

## Context and Orientation

Shikigami has seven packages: core domain/runtime, API contracts, HTTP server, workers, client/CLI, migrations and the lightweight agent runner. The last is the deliberate ADR-3 exception to the six-package pattern. Work from this repository root and locate dependencies through Mori before using their APIs. Never traverse `/nix/store`. Current objective work under MasterPlan 17 edits configuration, generated catalogs, migrations and core tests; preserve and reconcile that work rather than reverting it. The workspace currently has ten members, including ExecutionDriver, WorkerSession, ContinuingWorker and Objective. Recount from `domain/shikigami.keiro-workspace` at implementation; neither six members nor two aggregates is a valid fixed inventory.

On 2026-10-30 the user confirmed Shikigami is unused. [ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) and [ADR-37](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md) apply: establish one current first-release contract, remove obsolete compatibility branches/readers, and allow deliberate schema/wire changes. Do not require old binaries, old populated databases or cross-build replay as acceptance. This does not authorize deleting a developer database or weakening external authorization, accounting, protected payloads or same-build replay. Record exact breaking DSL findings and establish the accepted baseline without suppressing the differ. `docs/workflow-versioning.md` still governs durable bodies after that baseline.

The frozen guide inventory is `docs/architecture/keiro-0.22-coverage.json`: canonical resource, producer revision, relative source path, SHA-256, child owner, pending disposition and evidence. The readable audit is `docs/architecture/keiro-0.22-pattern-audit.md`. Pending rows are planned work, not compliance claims. Every applicable clause requires an implemented behavior or justified existing implementation and current evidence. Strict unprefixed fields, explicit deriving strategies and isolated generic-lens orphan imports apply to all touched Haskell and examples.

`Shikigami.Runtime`, `Shikigami.Workflow.Registry`, worker `Agent/Workflow/Resume.hs`, `Trigger/Consumer.hs`, `Trigger/Timer.hs`, `Trigger/Scheduler.hs`, `Workers/Subscription.hs`, `Agent/RunJob/Worker.hs` and `Health/Worker.hs` own runtime assembly. Trigger.Consumer directly constructs Shibuya AppConfig and exposes a process-local supervisor. `Execution.Store`, `Execution.Timer` and the workflow await paths own generation-specific wakes. [ADR-38](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md) defines startup, retention and resource-aware resume; [ADR-54](../adr/0054-execution-attempts-own-dispatch-fences-and-generation-wakes.md) defines dispatch and generation authority. The filename retains its historical inspection wording to preserve links; plan 106 exclusively owns that work now.

## Plan of Work

M1 validates migration handshake before intake, telemetry before store acquisition, validated event streams/catalog before queries and workers, and bracketed shutdown. Preserve each source's projection set as execution, evidence, worker-session and objective owners are composed. Use defaultAppConfig with the existing StopAllOnFailure, serial strict ordering and inbox bounds. Distinguish Paused from failed and drained. Exercise deliveryStatus admission so superseded deliveries invoke neither handler nor finalizer, and permanent finalizer failure reaches supervision. Native adapters own acknowledgement/finalization; do not duplicate their counters or retry ownership. Deterministic configuration failure must not reconnect forever.

For each real subscription, validate capacities, missing-checkpoint policy, target identity, startup/decode failure, retry budget and checkpoint-after-success. Use namespace targets only when the intended input domain actually spans that namespace; exact category consumers keep their scope. Record stopped-owner resize/rebind constraints. Retain PGMQ polling after 0007 removes partitioned-queue notifications. Test visibility extension, duplicate deliveries, poison/exhausted jobs, original_queue DLQ metadata and native redrive authorization. Kafka offsets advance only after the service's durable disposition; test unavailable persistence rather than logging acceptance. HTTP sink outbox delivery retains its own receipt and uncertainty semantics.

M2 recenses the workflow registry and tests every real family, including execution drivers and continuing workers, rather than the old fixed three. Reuse Kioku resource-aware resume without casts/private APIs; remove adapters only when current released APIs genuinely replace their capability. Prove one generation-specific wake before extending fixtures: accepted wake and exact await name, rotation/cancellation races, stale owner/claim refusal, terminal instances not revived, durable resolution/abandonment, and no duplicate external dispatch on replay. Keep allocated opaque IDs and authoritative receipts within the new same-build baseline. Preserve late outcomes as reconciliation evidence and unknown effects as unresolved; expiry is not proof an external process stopped. Maintain one timer dispatcher and explicit workflow GC/idempotency horizon, distinct from protected payload and application retention.

Workflow shape cleanup is coordinated with plan 93. No fake historical patch branch is required, but same-build restart still cannot repeat committed model/tool/accounting work. Hand plan 106 a bracketed process-local metrics provider owned by the real Shibuya AppHandle; inspection must not allocate a second runtime.

## Concrete Steps

Run from the repository root in the declared development shell. Use disposable task-owned databases and the existing source-owned fixtures. These are implementation commands, not evidence of tests already run:

```bash
nix develop --no-write-lock-file -c cabal test shikigami-workers-test shikigami-core-test
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test --test-options=-j1
nix develop --no-write-lock-file -c cabal test keiro-shikigami-conformance
nix develop --no-write-lock-file -c just keiro-check
```

Record actual cases and concise output under `docs/evidence/keiro-0.22/`. Database tests that skip are not accepted. Before claiming Linux is unavailable, inspect `container --help`, `container list --all` and `tests/workspace/build-apple.sh`; use native ARM64 Apple containers, retaining the documented remote-builder fallback only when needed. Do not claim runtime containment from compilation alone.

## Validation and Acceptance

Regression cases cover ordinary and superseded delivery, poison/no checkpoint advance, finalizer failure, deterministic startup refusal, cancellation and joined cleanup. Every current workflow family resumes from its own new-build suspended state; stale wakes/claims cannot resurrect work or settle twice. Record actual test names and owner/source inventory. Dead-timer recovery uses supported claims and rejects stale tokens.

## Idempotence and Recovery

Repeat generation against an isolated coherent candidate so concurrent uncommitted work cannot masquerade as generated drift. Preserve create-once holes. Recreate only task-owned disposable fixtures after failure; never clear shared journals, leases or bindings to obtain a passing test. Record the source/dirty diff and current input artifacts for reproducibility, without requiring a successful old build before refactoring. A released-schema rollback is not promised. Future post-release evolution resumes the ordinary versioning rules. Record friction through `agents/skills/exec-plan/FRICTION.md`, promote durable decisions through the local plain-Markdown ADR convention, and scan touched code and prose for stale prefixed fields.

## Interfaces and Dependencies

Requires plan 92 Complete. Plan 93 is a soft dependency and integration peer for command result meanings and workflow baseline; coordinate edits to Execution.Store with its owner. Own runtime lifecycle and the process-local metrics lifetime consumed by plan 106. Plan 95 requires this child Complete.

## Revision Notes

2026-10-30: Expanded MasterPlan 16 under the user's unused-service confirmation; replaced compatibility-driven scope with current-contract adoption and explicit behavioral evidence. Previous provenance entries and review verdicts remain historical and do not certify this revision.
