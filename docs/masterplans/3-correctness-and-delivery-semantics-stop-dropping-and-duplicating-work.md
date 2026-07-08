---
id: 3
slug: correctness-and-delivery-semantics-stop-dropping-and-duplicating-work
title: "Correctness and Delivery Semantics: Stop Dropping and Duplicating Work"
kind: master-plan
created_at: 2026-07-08T20:13:36Z
intention: "intention_01kx1tykwvek587vr2gwtcf81j"
---

# Correctness and Delivery Semantics: Stop Dropping and Duplicating Work

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Shikigami is a declared-agent runtime: agents are declared in Dhall manifests, triggers (cron schedules via keiro durable timers, the `activity.v1` Kafka stream via the keiro idempotent inbox, and addressed integration events) all converge on one pgmq queue named `shikigami_run_jobs`, a shibuya `QueueProcessor` drains that queue into keiro durable workflows with journaled steps, and sink deliveries go out asynchronously through a keiro transactional outbox. Each of those hand-offs currently has a correctness hole that either drops work (an event that never becomes a run, a run whose failure is silently archived, a sink that is never actually delivered) or duplicates it (a redelivered long run executing concurrently with itself, a scheduler replaying a day of missed cron ticks, a retried sink double-posting to a downstream service).

After this initiative, every hand-off is honest. A behavior failure caused by a flaky LLM or HTTP call is genuinely re-executed on retry instead of being replayed from the journal three times and archived. A run that takes longer than 30 seconds — that is, any real LLM call — is no longer redelivered mid-flight into a concurrent duplicate execution. A Kafka event whose processing hits a transient Postgres outage is retried instead of being permanently skipped by an unconditional offset commit; and once the inbox accepts an event, the corresponding run job is enqueued in the same database transaction, so a crash cannot strand an event in the "processed but never enqueued" state. A run record that says a sink was "Delivered" actually means the downstream HTTP call succeeded, not merely that a row was inserted into the outbox; retried sink publishes no longer duplicate kizashi signals or orphan danwa conversations. Routing of run jobs is decided by the job's declared trigger kind, the scheduler applies an explicit catch-up policy after downtime instead of firing every missed minute, and failures that today vanish (kioku session/memory write errors, unloadable agent manifests, unparseable crons) are loud.

In scope: retry/timeout/heartbeat semantics of the run-job worker (`shikigami-core/src/Shikigami/Worker.hs`, `shikigami-core/src/Shikigami/Agent/Workflow.hs`); atomicity of the Kafka consumer path (`shikigami-core/src/Shikigami/Trigger/Consumer.hs`, `shikigami-core/src/Shikigami/Trigger/Enqueue.hs`); truthfulness of sink outcomes and client-side idempotency toward kawa, kizashi, and danwa (`shikigami-core/src/Shikigami/Agent/Workflow.hs`, `shikigami-core/src/Shikigami/Sink/*`); and explicit routing, scheduler catch-up, and loud failure reporting (`shikigami-core/src/Shikigami/Trigger/Scheduler.hs`, the three CLI loaders under `shikigami-cli/src/Shikigami/Cli/Commands/`).

Explicitly excluded: structured logging/metrics infrastructure (docs/plans/28), health/liveness and loop supervision (docs/plans/29), the operator CLI for inspecting runs and dead letters (docs/plans/30), per-agent lifecycle state recorded against meibo principals (docs/plans/23, MasterPlan 4 — this initiative only stops the silence around manifest load failures), consolidation of the duplicated sink-intent machinery (docs/plans/27, MasterPlan 5 — this initiative fixes the semantics of that machinery in place), and upstream API changes to kizashi or danwa to add server-side idempotency keys (documented as follow-ups inside EP-3; this initiative delivers client-side mitigations only).


## Decomposition Strategy

The initiative decomposes along the four independent hand-off boundaries of the runtime, because each boundary has its own failure mode, its own files, and its own independently observable fix. The queue-to-workflow boundary (EP-1) is about what "retry" means once a job is in a handler: journaled step results versus thrown exceptions, visibility timeouts, and wall-clock budgets. The stream-to-queue boundary (EP-2) is about transactional atomicity between three stores: Kafka offsets, the keiro inbox table, and the pgmq queue — all decisions there are commit-ordering decisions. The workflow-to-downstream boundary (EP-3) is about what "Delivered" means and how retried publishes behave against three concrete downstream APIs. The trigger-and-configuration surface (EP-4) is a set of smaller, related correctness fixes — routing, scheduler catch-up, swallowed errors — that individually would be too thin for standalone plans but together form one coherent "the system tells the truth about what it is doing" work stream.

Alternatives considered. A single "fix all correctness bugs" ExecPlan was rejected: it would span more than ten files across four unrelated subsystems and exceed five milestones, and the four streams need no shared code to proceed. Splitting EP-4 into three micro-plans (routing, scheduler, loudness) was rejected because each is one to two milestones and they share the same review context (the trigger surface) and the same test modules. Merging EP-1 and EP-4 because both edit `Shikigami/Worker.hs` was rejected: the ack-classification concern (EP-1) and the routing concern (EP-4) touch adjacent but different functions, and the seam between them is narrow enough to manage as an integration point rather than a merge. Sequencing EP-3 behind the MasterPlan-5 consolidation (docs/plans/27) was rejected: the consolidation is refactoring and should preserve semantics, so the semantics should be fixed first (see Integration Points).

Each plan is independently verifiable: EP-1 by tests that fail a behavior transiently and observe re-execution instead of journal replay; EP-2 by tests that assert an inbox row and a pgmq message appear or vanish together; EP-3 by stub HTTP servers counting downstream requests across retried publishes; EP-4 by scheduler tests firing stale timers and loader tests over the checked-in `agents/broken.dhall`.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Behavior retry semantics, run timeouts, and visibility heartbeat | docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md | None | None | Not Started |
| 2 | Atomic stream consumption: offsets, inbox, and enqueue in one boundary | docs/plans/18-atomic-stream-consumption-offsets-inbox-and-enqueue-in-one-boundary.md | None | None | Not Started |
| 3 | Sink delivery truth and downstream idempotency | docs/plans/19-sink-delivery-truth-and-downstream-idempotency.md | None | None | Not Started |
| 4 | Explicit trigger routing, scheduler catch-up policy, and loud failures | docs/plans/20-explicit-trigger-routing-scheduler-catch-up-policy-and-loud-failures.md | None | EP-1 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

There are no hard dependencies: all four plans compile and are testable independently, and any of them can be picked up first. Three coordination edges exist.

EP-4 has a soft dependency on EP-1. Both edit the run-job handler in `shikigami-core/src/Shikigami/Worker.hs`: EP-1 restructures `runOneAgent`'s outcome-to-`AckDecision` mapping into an extracted, typed classification (replacing the `"unknown agent "` string-prefix match and the fixed one-second retry), and EP-4 restructures `handleRunJob`'s route selection (replacing the duck-typed `AddressedMessage` decode with routing on `RunJob.triggerKind`). If EP-1 lands first, EP-4 routes into EP-1's classified handler and dead-letters malformed conversation payloads through EP-1's taxonomy; if EP-4 must land first, it keeps the existing ack mapping untouched and EP-1 rebases over the routing change. Either order works; simultaneous implementation in separate branches requires reconciling `handleRunJob` (see Integration Points).

EP-2 and EP-4 share an integration dependency on `shikigami-core/src/Shikigami/Trigger/Enqueue.hs`. EP-2 adds a transaction-composable enqueue (`enqueueRunJobTx`) and a startup-time `ensureRunQueue`; EP-4 hardens the existing IO-level enqueue helpers in the same module (removing the per-enqueue `createQueue`, the timestamp-bearing idempotency key, and the epoch fallback). Neither blocks the other, but EP-4 must consume EP-2's `ensureRunQueue` if it exists rather than inventing a second one, and EP-2's transactional path must not reintroduce per-enqueue queue creation.

EP-3 has a cross-MasterPlan integration edge, not with a plan in this registry but with docs/plans/27-consolidate-sink-intent-and-run-lifecycle-machinery.md (MasterPlan 5), which plans to consolidate the very sink-intent machinery EP-3 modifies. EP-3 should land first; if the consolidation proceeds concurrently, it must preserve EP-3's semantics (the `Enqueued` outcome, per-sink outbox keys, and the delivery-receipt guard). All journaled-value changes in EP-1 and EP-3 must also respect the versioning discipline that docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md (MasterPlan 5) establishes: additive only — no renames of journaled step names, no encoding changes that fail to decode already-journaled values.

EP-1, EP-2, and EP-3 can proceed fully in parallel. A team of four can run all four concurrently provided the EP-1/EP-4 seam in `Worker.hs` is reconciled at merge time.


## Integration Points

Worker handler and ack classification — `shikigami-core/src/Shikigami/Worker.hs`. Involved: EP-1, EP-4. EP-1 defines the shape: it changes `runJobHandler` to carry the shibuya lease for heartbeating, extracts a pure outcome-to-`AckDecision` classification with attempt-aware backoff, and removes the string-prefix dead-letter matching (today at `Worker.hs:184-185`). EP-4 consumes it: its new `routeRunJob` decides which orchestration path runs (`runConversationAgent` versus `runOneAgent`, today chosen by payload decode at `Worker.hs:139-141`) and must express its own failure cases (for example, a `TriggeredByEvent` job addressed to a conversation agent whose payload does not decode) as values of EP-1's classification rather than ad-hoc `AckDecision`s. Whichever plan lands second updates the other's tests in `shikigami-core/test/` rather than duplicating handler logic.

Run-job enqueue module — `shikigami-core/src/Shikigami/Trigger/Enqueue.hs`. Involved: EP-2, EP-4. EP-2 defines `enqueueRunJobTx :: RunJob -> Tx.Transaction MessageId` (no queue creation inside the transaction) and `ensureRunQueue :: Pool -> IO (Either UsageError ())` called once at process startup. EP-4 extends the module: it removes `createQueue` from the per-enqueue path of `enqueueRunJob` (relying on `ensureRunQueue`), removes or re-keys `enqueueAddressedRun`, and replaces the epoch fallback in `runJobFromEnvelope`. If EP-4 lands first, it introduces `ensureRunQueue` itself and EP-2 adopts it.

Journaled sink outcome values — `shikigami-core/src/Shikigami/Sink/Types.hs` (`SinkOutcome`) and the step values journaled by `shikigami-core/src/Shikigami/Agent/Workflow.hs` (`dispatch-sinks` and the per-reply sink steps). Involved: EP-3 here; docs/plans/24 and docs/plans/27 in MasterPlan 5. EP-3 owns the change: it adds an `Enqueued` constructor (additive — old journaled `Delivered` values must still decode) and re-keys outbox messages per sink ordinal. Constraint on everyone: journaled step names (`ingest-job`, `lookup-agent`, `open-session`, `recall`, `run-behavior`, `dispatch-sinks`, `record`, `complete`, and the conversation steps) are never renamed, and value encodings only change backward-compatibly. The docs/plans/27 consolidation must treat EP-3's final semantics as the specification it preserves.

Workflow result encoding — `agentRunWorkflow`'s return type `Either Text AgentRunResult` (journaled by keiro as the workflow completion value). Involved: EP-1. Decision recorded here so no plan trips over it: EP-1 does not change this type. Transient failures are expressed by throwing (never journaled), so a journaled `Left` comes to mean "permanent failure" without any encoding change to already-completed workflows.

Agent load-state boundary. Involved: EP-4 and docs/plans/23 (MasterPlan 4). EP-4 only makes manifest and cron load failures loud (per-file logging, counts, a strict mode that refuses to start). Recording per-agent load state durably and gating agents on lifecycle status belongs to docs/plans/23; EP-4 must not build a persistence mechanism for load state.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-1: Milestone 1 — transient/permanent behavior failure taxonomy; transient failures throw instead of journaling
- [ ] EP-1: Milestone 2 — worker ack classification with attempt-aware backoff and a real dead-letter queue
- [ ] EP-1: Milestone 3 — visibility heartbeat via the shibuya lease during long-running handlers
- [ ] EP-1: Milestone 4 — explicit wall-clock run timeout and configurable approval deadline
- [ ] EP-2: Milestone 1 — transactional enqueue: inbox transaction and pgmq send commit atomically
- [ ] EP-2: Milestone 2 — offset commit only on success or handled-skip; store errors do not commit
- [ ] EP-2: Milestone 3 — Kafka reconnect loop with backoff and a logged poison-record policy
- [ ] EP-3: Milestone 1 — journaled outcome renamed to Enqueued; logSinkResult implemented
- [ ] EP-3: Milestone 2 — sink delivery receipts table; publish outcomes recorded and queryable
- [ ] EP-3: Milestone 3 — retry-safe dispatch: kizashi send-guard and danwa conversation reuse
- [ ] EP-3: Milestone 4 — per-sink outbox keys; head-of-line isolation between a run's sinks
- [ ] EP-4: Milestone 1 — routing on RunJob.triggerKind with typed failure for undecodable conversation payloads
- [ ] EP-4: Milestone 2 — scheduler catch-up policy (skip-missed/coalesce default) and timer-kind dispatch fix
- [ ] EP-4: Milestone 3 — kioku errors propagated or logged; no silently discarded store results
- [ ] EP-4: Milestone 4 — loud agent/cron loading with strict mode; enqueue-path hardening (keys, queue creation, epoch fallback, UUIDv5 bytes)


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Planning research (2026-07-08): keiro has no per-step retry policy or step options at all — the framework's documented contract (keiro `Keiro/Workflow.hs` module haddock and the `Step` handler, which journals only after the step body returns) is that transient failures should be thrown so the step re-runs on the next execution. This turned EP-1's design from "add a retry policy" into "stop journaling transient failures", which is a smaller and more idiomatic change.
- Planning research (2026-07-08): the shibuya version shikigami pins (cabal.project tag `3f276ee` of shinzui/shibuya) already exposes `lease :: Maybe (Lease es)` on the `Ingested` value the handler receives, and the pinned pgmq adapter populates it. EP-1's heartbeat needs no dependency bump.
- Planning research (2026-07-08): neither kizashi's create-signal endpoint nor danwa's start/join/post endpoints accept any client-supplied id or idempotency key, and danwa has no lookup-by-external-key. EP-3's downstream idempotency is therefore necessarily client-side (a delivery-receipt guard in shikigami's own database), with upstream API changes recorded as follow-ups.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Decompose into exactly four ExecPlans along hand-off boundaries (queue→workflow, stream→queue, workflow→downstream, trigger/config surface), registered as EP-1=docs/plans/17, EP-2=docs/plans/18, EP-3=docs/plans/19, EP-4=docs/plans/20.
  Rationale: Each boundary has a distinct failure mode, distinct files, and an independently observable fix; one mega-plan would exceed the ExecPlan size guidance and none of the streams share code artifacts that would force merging.
  Date: 2026-07-08

- Decision: No hard dependencies between the four plans; EP-4 takes a soft dependency on EP-1, and EP-2/EP-4 plus EP-1/EP-4 are managed as integration points on `Shikigami/Trigger/Enqueue.hs` and `Shikigami/Worker.hs` respectively.
  Rationale: Maximizes parallelism. The shared files are touched in different functions; a reconciliation note is cheaper than serializing two otherwise-independent work streams.
  Date: 2026-07-08

- Decision: EP-1 keeps `agentRunWorkflow`'s result type `Either Text AgentRunResult` unchanged and expresses transience by throwing; a journaled `Left` becomes "permanent" by construction.
  Rationale: keiro journals the workflow completion value; changing the type would change the JSON encoding of already-journaled completions and violate the additive-only versioning discipline that docs/plans/24 establishes.
  Date: 2026-07-08

- Decision: EP-3 lands before (or its semantics are treated as the frozen specification by) the docs/plans/27 sink-machinery consolidation in MasterPlan 5.
  Rationale: Refactoring should preserve semantics; therefore semantics must be corrected first. Consolidating first would bake the enqueue-time "Delivered" lie into the consolidated module and force a second pass.
  Date: 2026-07-08

- Decision: EP-4 stops the silence around agent-manifest and cron load failures (logging, counts, strict mode) but does not persist per-agent load state; that persistence belongs to docs/plans/23 in MasterPlan 4.
  Rationale: Load-state persistence requires the meibo principal model that MasterPlan 4 introduces; duplicating a throwaway mechanism here would create migration debt.
  Date: 2026-07-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
