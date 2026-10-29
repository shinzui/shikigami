---
type: Improvement Request
title: Support recurring objective supervision with durable checkpoints
description: Resume an explicitly authorized ongoing objective from authoritative checkpoints and events, coalesce overlapping wakeups, and enforce cadence, shared limits, expiry, and stop conditions.
timestamp: "2026-10-29T13:33:46Z"
generated:
  by: process:codex
  at: "2026-10-29T13:33:46Z"
requestId: IR-18
status: accepted
targetPlan: docs/plans/87-supervise-recurring-objectives-from-current-durable-checkpoints.md
origin: mori://shinzui/shikigami
---

# Support recurring objective supervision with durable checkpoints

## Status

**Accepted; implementation planned but not started.** [MasterPlan 14](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md) assigns
explicit recurring mandates, checkpoint wakeups, coalescing and stop semantics to
[plan 87](../plans/87-supervise-recurring-objectives-from-current-durable-checkpoints.md). This is a separate optional phase of
[UC-1](../use-cases/adaptive-autonomous-delivery.md), following the finite coordinator
foundations and the IR-13 checkpoint prerequisite. Finite delivery qualification does
not require recurring automation to be enabled. The plan is not started. Its real checkpoint prerequisite is owned by
[MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md) / [plan 99](../plans/99-supply-trusted-objective-associations-and-the-real-checkpoint-ownership-and-scope-providers.md), while [plan 85](../plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md) supplies the finite coordinator.
Completed resource and recovery foundations in plans 81–83 do not start this recurring phase.

## Problem and current coverage

[Schedule, stream, and addressed triggers](../capabilities/durable-trigger-intake.md)
durably start work, and Flows can wait and resume. A cron agent runs about the current
tick; its existence does not establish a recurring objective's current owner, checkpoint,
watermark, overlap policy, expiry, or completed-versus-ongoing meaning. Memory recall
cannot substitute for an authoritative mandate record.

[Plan 20](../plans/20-explicit-trigger-routing-scheduler-catch-up-policy-and-loud-failures.md)
establishes trigger routing and catch-up semantics. Conversation idle timeout and generation
rotation in [plan 26](../plans/26-conversation-workflow-lifecycle-idle-timeout-journal-rotation-session-completion.md)
belong to the conversation lifecycle. Neither supplies an ongoing objective contract.
Reuse the existing scheduler/timer/event infrastructure; a second general cron service
or an agent sleep loop is unnecessary.

## Requested change

1. Persist an explicitly admitted recurring mandate: objective, scope, current authority,
   cadence/next due time, evidence sources, owner, last processed watermark, shared resource
   envelope, expiry, and stop condition. Distinguish finite work from an ongoing service.
   Installation, a planning request, or one successful cycle cannot create or expand a mandate.
2. Define continuing-coordinator wakeup and fresh-run wakeup semantics. A fresh run receives
   a stable mandate/checkpoint reference and reads current state; it must not assume the
   old model context or scheduled prompt is still authoritative. Reconcile newer user
   instructions, owners, completed work, and in-flight external operations before acting.
3. Prefer completion/progress events for timely work and use scheduled wakeups as a recovery
   backstop. Persist cursors and due times, coalesce duplicate or overlapping wakeups, and
   enforce one active owner for shared writes. Define recovery for stale ownership through
   leases/fencing without assuming that a lease expiry has stopped external work.
4. Process bounded new evidence or a useful pending dependency. Advance watermarks and
   checkpoints atomically with accepted logical progress. When no actionable delta exists,
   avoid duplicate audits/workers and repetitive notifications; preserve the mandate and
   apply configured backoff within its authorized cadence.
5. A completed cycle retains an ongoing mandate. Finite completion, expiry, cancellation,
   or exhausted authority stops new admission. Reconcile already admitted effects, preserve
   unknown outcomes, checkpoint the handoff, and release/disable the appropriate schedule.
   A schedule edit or mandate extension requires authority; old wakeups cannot revive it.
6. Keep budgets and permissions attached to the mandate/root objective across wakeups,
   runs, model-context compaction, and restarts. Recheck principal lifecycle and exact action
   authorization before protected effects. Scope changes and cadence/expiry extensions
   cannot be introduced by a worker's narrative or a historical scheduled instruction.
7. Expose mandate state, last cycle, watermark, owner, next due time, stop reason, and
   unresolved work through supported inspection and control surfaces. Continuing journal
   generations and retention must preserve every record still needed for replay.

## Acceptance

1. Admit an ongoing fixture with a finite resource envelope and expiry. A successful first
   cycle schedules the next; an equivalent finite objective stops after verified completion.
2. Deliver completion events and duplicate timer wakeups while a cycle is active. They
   coalesce or reconcile without duplicate accepted work, conflicting writers, or new owners.
3. Restart after processing evidence but before the next wakeup is scheduled. The committed
   watermark and due time recover, and already processed evidence is not handled twice.
4. Replace an assignment and update user instructions before an old wakeup fires. The resumed
   coordinator follows current state and does not recreate the old owner or replay a stale plan.
5. Reach expiry, revoke authority, and cancel a mandate in separate trials. No new work is
   admitted; in-flight and uncertain operations remain inspectable. Late events cannot revive
   a stopped mandate, and repeated wakeups do not replenish root budget.
6. Several cycles with no new evidence produce no duplicate worker or audit and no repetitive
   user notification. A later relevant event resumes useful authorized work.

## Dependencies and scope

- [IR-13](support-optional-major-task-tracking.md) supplies authoritative objective/checkpoint
  state; mandate fields and control belong here, not to every ordinary task.
- [IR-15](support-continuing-worker-sessions.md) supplies worker events and ownership transfer
  when the mandate supervises continuing sessions.
- [IR-16](support-adaptive-durable-orchestration.md) supplies adaptive coordination and shared
  reservations when the mandate manages a worker hierarchy.
- [IR-14](record-durable-model-tool-turns-and-compose-harness-policies.md) supplies durable
  execution within each cycle; existing triggers, timers, and authorization are reused.

Planning may implement a bounded recurring fixture before the adaptive hierarchy. This
request does not require a new scheduler, indefinite authorization, or an external task
service. Changes to durable bodies follow [workflow versioning](../workflow-versioning.md).
