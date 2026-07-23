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

In scope: the pg-migrate transition that makes every new correctness table part of one
complete component plan; retry/timeout/heartbeat semantics of the run-job worker;
atomicity of the Kafka consumer path; truthfulness of sink outcomes and client-side
idempotency toward kawa, kizashi, and danwa; and explicit routing, scheduler catch-up,
and loud failure reporting. Package placement follows plan 36 rather than the legacy
`shikigami-cli` paths, and all process configuration follows plan 37.

Explicitly excluded: structured logging/metrics infrastructure (docs/plans/28), health/liveness and loop supervision (docs/plans/29), the operator CLI for inspecting runs and dead letters (docs/plans/30), per-agent lifecycle state recorded against meibo principals (docs/plans/23, MasterPlan 4 — this initiative only stops the silence around manifest load failures), consolidation of the duplicated sink-intent machinery (docs/plans/27, MasterPlan 5 — this initiative fixes the semantics of that machinery in place), and upstream API changes to kizashi or danwa to add server-side idempotency keys (documented as follow-ups inside EP-3; this initiative delivers client-side mitigations only).


## Decomposition Strategy

The initiative has one database-evolution foundation and four independent hand-off
boundaries. F1 replaces Codd with the fleet pg-migrate component/manifest/application-
plan model before any child adds tables. The queue-to-workflow boundary (EP-1) is about
what "retry" means once a job is in a handler, including PGMQ's one-based attempt
number and shibuya's framework-owned acknowledgement. The stream-to-queue boundary
(EP-2) is about transactional atomicity between Kafka offsets, the keiro inbox table,
and pgmq. The workflow-to-downstream boundary (EP-3) is about truthful receipts and
retry behavior. The trigger surface (EP-4) owns explicit routing, scheduler catch-up,
and loud failures; configuration itself belongs to plan 37.

Alternatives considered. A single "fix all correctness bugs" ExecPlan was rejected: it would span more than ten files across four unrelated subsystems and exceed five milestones, and the four streams need no shared code to proceed. Splitting EP-4 into three micro-plans (routing, scheduler, loudness) was rejected because each is one to two milestones and they share the same review context (the trigger surface) and the same test modules. Merging EP-1 and EP-4 because both edit `Shikigami/Worker.hs` was rejected: the ack-classification concern (EP-1) and the routing concern (EP-4) touch adjacent but different functions, and the seam between them is narrow enough to manage as an integration point rather than a merge. Sequencing EP-3 behind the MasterPlan-5 consolidation (docs/plans/27) was rejected: the consolidation is refactoring and should preserve semantics, so the semantics should be fixed first (see Integration Points).

Each plan is independently verifiable: EP-1 by tests that fail a behavior transiently and observe re-execution instead of journal replay; EP-2 by tests that assert an inbox row and a pgmq message appear or vanish together; EP-3 by stub HTTP servers counting downstream requests across retried publishes; EP-4 by scheduler tests firing stale timers and loader tests over the checked-in `agents/broken.dhall`.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| F1 | Migrate Shikigami database evolution from Codd to pg-migrate | docs/plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md | cross-MP: plans 36 and 37 | None | Not Started |
| 1 | Behavior retry semantics, run timeouts, and visibility heartbeat | docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md | cross-MP: plans 36 and 37 | None | Not Started |
| 2 | Atomic stream consumption: offsets, inbox, and enqueue in one boundary | docs/plans/18-atomic-stream-consumption-offsets-inbox-and-enqueue-in-one-boundary.md | cross-MP: plans 36 and 37 | None | Not Started |
| 3 | Sink delivery truth and downstream idempotency | docs/plans/19-sink-delivery-truth-and-downstream-idempotency.md | F1; cross-MP: plans 16 and 28 M1 | None | Not Started |
| 4 | Explicit trigger routing, scheduler catch-up policy, and loud failures | docs/plans/20-explicit-trigger-routing-scheduler-catch-up-policy-and-loud-failures.md | EP-1, EP-2; cross-MP: plan 37 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

F1 follows plans 36 and 37 and gates every new Shikigami migration. EP-1 and EP-2 can
then start independently. EP-3 starts after F1 and plan 28 Milestone 1 defines
`Shikigami.Log`. EP-4 hard-depends on EP-1 and EP-2 so it consumes the final ack taxonomy
and `ensureRunQueue`/transactional enqueue seam instead of shipping conditional duplicate
implementations. Three additional coordination edges exist.

EP-1 precedes EP-4. Both edit the run-job handler in `shikigami-core/src/Shikigami/Worker.hs`: EP-1 defines the typed outcome-to-`AckDecision` classification, and EP-4 routes its malformed-payload errors through that taxonomy.

EP-2 precedes EP-4 on `shikigami-core/src/Shikigami/Trigger/Enqueue.hs`. EP-2 adds
`enqueueRunJobTx` and `ensureRunQueue`; EP-4 hardens the IO-level helpers by consuming
those artifacts and never conditionally invents them.

EP-3 has cross-MasterPlan integration edges with plan 27 (consolidation) and plans 22/32
(typed HTTP classification). EP-3 lands before plan 32 and defines `Enqueued`,
`PermanentFailure`, per-sink outbox keys, delivery receipts, and the Keiro-owned terminal
publish outcome; plan 27 must preserve them. All journaled-value changes in EP-1/EP-3 also
respect plan 24's additive-only versioning discipline.

EP-3 hard-depends on plan 28 Milestone 1, which defines `Shikigami.Log`, and preferably
follows plan 16, which makes each sink handler truthful. EP-3 then records delivery semantics
using the final sink outcomes and structured logger; plan 27 lands afterward and consolidates
the settled semantics. The sink chain is plan 16 plus plan 28 M1 → EP-3 → plan 27.

EP-1 and EP-2 can proceed in parallel while F1 and plan 28 M1 land; EP-3 follows those
milestone, and EP-4 starts after EP-1 and EP-2. This is the MasterPlan-3 slice of the
canonical MP-2 through MP-7 waves recorded in MasterPlan 2.


## Integration Points

Worker handler and ack classification — server/worker modules assigned by plan 36.
Involved: EP-1, EP-4. EP-1 keeps shibuya's `QueueProcessor` as the sole acknowledgement
owner, carries its lease for heartbeat, normalizes PGMQ's first delivery to attempt 1,
and derives retry delay with the shared `mkRetryPolicy` vocabulary. EP-4 consumes that
taxonomy and routes from an explicit `triggerKind` discriminator; payload decodability
is never used as the route selector.

Run-job enqueue module — core/worker modules assigned by plan 36. Involved: EP-2,
EP-4. EP-2 defines `enqueueRunJobTx :: RunJob -> Tx.Transaction MessageId` with no
queue creation inside the transaction and a startup `ensureRunQueue`. Every inbox
record reaches one explicit terminal disposition: enqueued, duplicate, permanent
dead-letter, or transient failure with no offset commit. Kafka processing keeps
durable dead-letter/halt behavior and uses shibuya's serial/framework-owned commit
boundary rather than a parallel acknowledgement loop. EP-4 consumes that seam.

Database evolution — plan 38 owns the `pg-migrate` component, exact-byte manifest,
complete application plan, compatibility import, CLI, and test-support contract. EP-3
adds delivery receipts only through that component; plans 21 and 23 do the same for
their tables. No child creates timestamped Codd files or replays legacy DDL.

Journaled sink outcome values—`SinkOutcome` and the values journaled by `dispatch-sinks` and
per-reply steps. Involved: EP-3 here; plans 22/32 for typed HTTP failures; plans 24/27 in
MasterPlan 5. EP-3 owns additive `Enqueued` and `PermanentFailure` constructors, per-sink
keys, and the released Keiro `PublishRejected` terminal mapping; old `Delivered`/`Failed`
values remain decodable. Journaled step names are never renamed and value evolution stays
backward-compatible. Plan 27 preserves these final semantics.

Workflow result encoding — `agentRunWorkflow`'s return type `Either Text AgentRunResult` (journaled by keiro as the workflow completion value). Involved: EP-1. Decision recorded here so no plan trips over it: EP-1 does not change this type. Transient failures are expressed by throwing (never journaled), so a journaled `Left` comes to mean "permanent failure" without any encoding change to already-completed workflows.

Agent loading boundary. EP-4 owns `AgentLoadReport`, the single directory traversal, and
loud/strict failure behavior. Plan 30 renders that report in `agents list`; plan 33 adds
enabled-agent selection; plan 23 persists the report and annotates the existing command with
lifecycle state. EP-4 must not implement persistence, enabled filtering, or operator output.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-1: Milestone 1 — transient/permanent behavior failure taxonomy; transient failures throw instead of journaling
- [ ] F1: Milestones 1–4 — pg-migrate component, exact manifest, complete plan, Codd ledger-only import, CLI/test/deployment cutover
- [ ] EP-1: Milestone 2 — one-based PGMQ attempts, shared retry policy, framework-owned ack classification, and a real dead-letter queue
- [ ] EP-1: Milestone 3 — visibility heartbeat via the shibuya lease during long-running handlers
- [ ] EP-1: Milestone 4 — explicit wall-clock run timeout and configurable approval deadline
- [ ] EP-2: Milestone 1 — transactional enqueue: inbox transaction and pgmq send commit atomically
- [ ] EP-2: Milestone 2 — offset commit only after an explicit terminal inbox disposition; transient/store errors do not commit
- [ ] EP-2: Milestone 3 — supervised serial Kafka loop with reconnect backoff and durable dead-letter/halt poison policy
- [ ] EP-3: Milestone 1 — additive Enqueued/PermanentFailure outcomes and released Keiro PublishRejected; logSinkResult implemented
- [ ] EP-3: Milestone 2 — pg-migrate-managed sink delivery receipts table; publish outcomes and reconciliation state recorded and queryable
- [ ] EP-3: Milestone 3 — retry-safe dispatch: kizashi send-guard and danwa conversation reuse
- [ ] EP-3: Milestone 4 — per-sink outbox keys; head-of-line isolation between a run's sinks
- [ ] EP-4: Milestone 1 — routing on an explicit RunJob trigger discriminator with typed failure for mismatched/undecodable payloads
- [ ] EP-4: Milestone 2 — scheduler catch-up policy (skip-missed/coalesce default) and timer-kind dispatch fix
- [ ] EP-4: Milestone 3 — critical kioku errors propagate to retry/failure; best-effort writes are explicitly classified and logged
- [ ] EP-4: Milestone 4 — loud agent/cron loading with strict mode; enqueue-path hardening (keys, queue creation, epoch fallback, UUIDv5 bytes)


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Planning research (2026-07-08): keiro has no per-step retry policy or step options at all — the framework's documented contract (keiro `Keiro/Workflow.hs` module haddock and the `Step` handler, which journals only after the step body returns) is that transient failures should be thrown so the step re-runs on the next execution. This turned EP-1's design from "add a retry policy" into "stop journaling transient failures", which is a smaller and more idiomatic change.
- Planning research (2026-07-08): the shibuya version shikigami pins (cabal.project tag `3f276ee` of shinzui/shibuya) already exposes `lease :: Maybe (Lease es)` on the `Ingested` value the handler receives, and the pinned pgmq adapter populates it. EP-1's heartbeat needs no dependency bump.
- Planning research (2026-07-08): neither kizashi's create-signal endpoint nor danwa's start/join/post endpoints accept any client-supplied id or idempotency key, and danwa has no lookup-by-external-key. EP-3's downstream idempotency is therefore necessarily client-side (a delivery-receipt guard in shikigami's own database), with upstream API changes recorded as follow-ups.
- Fleet conformance audit (2026-07-22): `pg-migrate` already supplies the component,
  manifest, complete application-plan, Codd ledger importer, CLI, and test support this
  initiative needs. Continuing to author Codd migrations would create a second schema
  authority and make delivery-receipt rollout unverifiable.
- Runtime-pattern audit (2026-07-22): PGMQ attempts are one-based and shibuya owns
  acknowledgement/commit. Retry and inbox plans were corrected to consume those facts
  rather than layering zero-based math or a second ack loop over the framework.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Decompose into one database foundation plus four ExecPlans along hand-off
  boundaries, registered as F1=plan 38 and EP-1 through EP-4=plans 17–20.
  Rationale: Each boundary has a distinct failure mode, distinct files, and an independently observable fix; one mega-plan would exceed the ExecPlan size guidance and none of the streams share code artifacts that would force merging.
  Date: 2026-07-08

- Decision: EP-4 hard-depends on EP-1 and EP-2; it consumes EP-1's ack taxonomy and
  EP-2's `ensureRunQueue`/transactional enqueue seam.
  Rationale: the earlier soft/integration treatment required conditional duplicate
  implementations in EP-4. Serializing EP-4 behind EP-1/EP-2 removes that ambiguity;
  EP-3 remains independent of them and follows plan 28 Milestone 1.
  Date: 2026-07-22
- Decision: Retry math uses PGMQ's one-based attempt count and the shared
  `mkRetryPolicy`; shibuya remains the sole acknowledgement owner.
  Rationale: preserving adapter/framework ownership prevents off-by-one retry ceilings,
  duplicate acknowledgements, and process-specific retry dialects.
  Date: 2026-07-22
- Decision: Every new Shikigami table is delivered through plan 38's pg-migrate
  component and complete application plan; the Codd transition imports history only.
  Rationale: one schema authority makes fresh installs, upgrades, verification, tests,
  and rollback evidence agree on the exact migration prefix.
  Date: 2026-07-22

- Decision: EP-1 keeps `agentRunWorkflow`'s result type `Either Text AgentRunResult` unchanged and expresses transience by throwing; a journaled `Left` becomes "permanent" by construction.
  Rationale: keiro journals the workflow completion value; changing the type would change the JSON encoding of already-journaled completions and violate the additive-only versioning discipline that docs/plans/24 establishes.
  Date: 2026-07-08

- Decision: EP-3 lands before (or its semantics are treated as the frozen specification by) the docs/plans/27 sink-machinery consolidation in MasterPlan 5.
  Rationale: Refactoring should preserve semantics; therefore semantics must be corrected first. Consolidating first would bake the enqueue-time "Delivered" lie into the consolidated module and force a second pass.
  Date: 2026-07-08

- Decision: EP-4 stops the silence around agent-manifest and cron load failures (logging, counts, strict mode) but does not persist per-agent load state; that persistence belongs to docs/plans/23 in MasterPlan 4.
  Rationale: Load-state persistence requires the meibo principal model that MasterPlan 4 introduces; duplicating a throwaway mechanism here would create migration debt.
  Date: 2026-07-08
- Decision: EP-4 owns the canonical `AgentLoadReport`; plans 30 and 33 consume it for
  inspection and enabled selection, then plan 23 adds durable lifecycle state.
  Rationale: a single report preserves failures and prevents four plans from walking the
  same directory with subtly different semantics.
  Date: 2026-07-22
- Decision: Order the sink path as plan 16 plus plan 28 M1 → EP-3 → plan 27.
  Rationale: handlers become honest first, delivery accounting and logging then settle,
  and consolidation finally moves the stable semantics and trace context once.
  Date: 2026-07-22
- Decision: Make plan 28 Milestone 1 a hard predecessor of EP-3.
  Rationale: EP-3 now emits delivery and publisher events through the concrete
  `Shikigami.Log` API rather than adding temporary stderr logging that a later plan must
  replace.
  Date: 2026-07-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)


## Revision Notes

- 2026-07-22: Converted EP-4's worker/enqueue prerequisites and EP-3's structured-logger
  prerequisite to hard dependencies, assigned canonical loader ownership to EP-4, and
  added the cross-MasterPlan sink landing chain. This aligns MasterPlan 3 with the MP-2
  through MP-7 execution waves.
- 2026-07-22: Added plan 38 as the database foundation; aligned retries, queue attempts,
  acknowledgements, inbox dispositions, Kafka poison behavior, and receipt migrations
  with the verified runtime and pg-migrate patterns.
