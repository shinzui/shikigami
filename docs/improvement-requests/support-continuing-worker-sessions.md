---
type: Improvement Request
title: Support continuing worker sessions with durable coordination
description: Let a coordinator address continuing workers, deliver follow-up assignments, observe progress and completion, and transfer ownership without losing accepted work or duplicating writers.
timestamp: "2026-10-29T13:33:46Z"
generated:
  by: process:codex
  at: "2026-10-29T13:33:46Z"
requestId: IR-15
status: in-progress
targetPlan: docs/plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md
origin: mori://shinzui/shikigami
---

# Support continuing worker sessions with durable coordination

## Status

**In progress under [plan 84](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md) and [MasterPlan 14](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md).** Ordered mailboxes, stable assignment
identities, retained results/events, recoverable assignment workflows, checkpoint intents,
fenced-handoff mechanics and governed Flow/Skill/operator commands are implemented against
deterministic adapters. The plan's real-provider runtime qualification remains open.

Full completion requires actual workspace/process fences from [plan 96](../plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md)
([IR-11](provide-governed-mutable-repository-workspaces.md)) and trusted objective,
checkpoint, ownership and scope providers from [MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md), especially [plan 99](../plans/99-supply-trusted-objective-associations-and-the-real-checkpoint-ownership-and-scope-providers.md)
([IR-13](support-optional-major-task-tracking.md)). Neither provider is complete.
[plan 86](../plans/86-qualify-integrated-adaptive-autonomous-delivery.md) supplies the integrated delivery trial after the required providers and
coordinator are ready. Fixtures do not close the real handoff acceptance case.
See [worker operations](../operations/operator-cli.md) for the implemented surface
and its default-host refusals.

## Problem and current coverage

One-shot [plan 9](../plans/9-multi-agent-delegation-primitive.md) delegation and [plan 42](../plans/42-execute-replay-safe-typed-routing-and-delegation.md) routing supply child-run primitives, not a
continuing worker address. [plan 84](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md) now adds the continuing-session store, one-assignment
workflow generations, ordered follow-ups, result/event cursors and governed control owner.
Kioku memory and addressed Danwa conversations remain separate lifecycle concerns.

The [public run-start API](expose-addressed-agent-runs-over-http.md) and
[run-status API](expose-agent-run-status-over-http.md) are completed individual-run
surfaces under [MasterPlan 15](../masterplans/15-expose-declared-agents-and-agent-runs-over-the-public-http-api.md); they do not provide general worker control. The default
operator host still lacks the real checkpoint and workspace providers needed for new
follow-ups, integration and transfer. [A2A interoperability](support-a2a-cross-runtime-agent-interoperability.md)
remains proposed and is not required for same-deployment session mechanics.

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
