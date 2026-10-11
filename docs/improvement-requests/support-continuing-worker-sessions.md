---
type: Improvement Request
title: Support continuing worker sessions with durable coordination
description: Let a coordinator address continuing workers, deliver follow-up assignments, observe progress and completion, and transfer ownership without losing accepted work or duplicating writers.
timestamp: "2026-10-10T23:44:58Z"
generated:
  by: process:codex
  at: "2026-10-11T03:04:54Z"
requestId: IR-15
status: accepted
targetPlan: docs/plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md
origin: mori://shinzui/shikigami
---

# Support continuing worker sessions with durable coordination

## Status

**Accepted; implementation planned but not started.** [MasterPlan 14](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md) assigns
continuing sessions, ordered messages, events and ownership transfer to [plan 84](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md).
[plan 86](../plans/86-qualify-integrated-adaptive-autonomous-delivery.md) exercises their integrated delivery behavior. This remains the
session-coordination requirement of
[UC-1: Adaptive autonomous delivery](../use-cases/adaptive-autonomous-delivery.md)
and extends existing governed child-run machinery. Full completion retains explicit
IR-11 workspace-fencing and IR-13 checkpoint integration gates; fixture adapters do not
satisfy those gates.

## Problem and current coverage

The [Delegate capability](../../shikigami-core/src/Shikigami/Flow/Delegate.hs) can spawn,
await, and cancel bounded child runs. It does not give a coordinator a continuing worker
address, mailbox, progress events, follow-up turns, or an ownership-transfer operation.
Kioku's recorded session is not by itself a live, addressable worker. Addressed Danwa
conversations provide a separate conversational lifecycle, not this coordination contract.

[Plan 9](../plans/9-multi-agent-delegation-primitive.md) and
[plan 42](../plans/42-execute-replay-safe-typed-routing-and-delegation.md) delivered child
orchestration and routing. They do not cover these continuing interactions. The proposed
[public run-start API](expose-addressed-agent-runs-over-http.md) and
[run-status API](expose-agent-run-status-over-http.md) concern individual runs and explicitly
omit general control. [A2A interoperability](support-a2a-cross-runtime-agent-interoperability.md)
concerns independently deployed runtimes and is not required for a local first slice.

## Requested change

1. Define a stable worker-session identity and its relationship to an agent principal,
   parent coordinator, objective, assignment, workflow generations, runs, and memory
   sessions. A continuing worker may own bounded work or coordinate permitted descendants;
   every descendant inherits scope and shared limits rather than receiving a fresh budget.
2. Supply typed coordination operations for creating or finding a session, sending
   follow-up instructions, inspecting bounded progress and results, waiting for relevant
   events, and requesting interruption or cancellation. Define accepted, active, parked,
   idle, completed, failed, cancelled, and unresolved states as appropriate. Silence or
   idle state must not be interpreted as completion or permission to discard work.
3. Give messages stable operation identities, ordered durable acceptance, and explicit
   acknowledgement/processing state. Redelivery or replay must not duplicate an assignment.
   Define when new instructions become effective during active work and how concurrent
   follow-ups and terminal results are reconciled. Preserve the lineage of each accepted
   instruction and the result it produced.
4. Produce durable, correlated progress/completion events. A resumed coordinator reconciles
   authoritative state and consumes events from a saved cursor rather than continuously
   polling or creating a replacement worker on silence. Events may be redelivered; handling
   them must be idempotent. Result availability and event-delivery failure are distinct facts.
5. Transfer or narrow assignment ownership explicitly. Before another worker writes the
   same resource, reconcile in-flight effects and fence the previous owner's write authority.
   Preserve its accepted results, workspace identity, pending operations, and useful context.
   A stop request must not falsely report that an external process or uncertain mutation
   has stopped. Retain an inspectable unresolved handoff when safety cannot be established.
6. Expose these operations through replay-safe Flow capabilities and the admitted model-tool
   surface used by a coordinator. Preserve parent/target allow-lists, principal lifecycle,
   cycle/depth checks, exact action authorization, and root budgets. Skill instructions do
   not grant permission to spawn, message, or control arbitrary sessions.
7. Define bounded context handoff and retention. Durable execution history, model context,
   semantic memory, and authoritative assignment state have different purposes. Follow-up
   work can retain relevant prior context without copying every parent conversation or
   erasing budget usage through compaction. Operators can inspect ownership, state, pending
   messages, and result references through supported Shikigami surfaces.

## Acceptance

1. A coordinator delegates an investigation, receives its result, sends a new bounded
   assignment to the same worker session, and receives a second result using relevant
   retained context. Restarting either process preserves the same identities and outcomes.
2. Redeliver a follow-up and its completion event before and after a restart. Exactly one
   logical assignment is accepted and the coordinator integrates the result once.
3. Deliver a follow-up while the worker is active and another after completion. The defined
   ordering is inspectable; neither instruction is silently lost or applied to the wrong turn.
4. Transfer a repository assignment while its original owner has an in-flight operation.
   The successor cannot write until transfer is established. A late operation from the old
   owner is fenced, and an uncertain external effect remains unresolved until reconciled.
5. An idle worker with saved work is retained. A denied target, forbidden descendant,
   exhausted root budget, or unauthorized cancellation produces no protected effect.
6. Restart a coordinator after a child finishes but before notification is consumed. It
   discovers the existing result without spawning a duplicate child. A bounded consultation
   can still use the existing one-shot delegation path without a continuing session.

## Dependencies and scope

- [IR-14](record-durable-model-tool-turns-and-compose-harness-policies.md) supplies recovery
  within worker turns and context reconstruction.
- [IR-13](support-optional-major-task-tracking.md) supplies objective and assignment references;
  authoritative session state must remain readable without relevance-ranked recall.
- [IR-11](provide-governed-mutable-repository-workspaces.md) supplies workspace ownership and
  fencing when a worker edits repositories. Read-only sessions need no mutation provider.
- Existing [routing/delegation](../capabilities/governed-routing-and-delegation.md) and
  [exact authorization](../capabilities/exact-action-authorization.md) remain enforcing boundaries.

The first implementation may stay within one Shikigami deployment. It need not implement
A2A, every public HTTP control endpoint, vendor terminal-session attachment, or a new
project-management service. Any workflow-body changes follow
[workflow versioning](../workflow-versioning.md), including checked labels, patching, and
generation rotation for continuing work.
