---
type: Improvement Request
title: Support optional major-task tracking for Shikigami agents without Rei
description: Give agents and users an explicit, durable view of progress on multi-step goals across runs without requiring a Rei intention, while preserving replay-safe updates and governed access.
timestamp: "2026-10-30T19:36:00Z"
generated:
  by: process:codex
  at: "2026-10-29T13:33:46Z"
requestId: IR-13
status: in-progress
targetPlan: docs/masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md
origin: mori://shinzui/shikigami
---

# Improvement Request: support optional major-task tracking for Shikigami agents without Rei

## Status

**In progress; owned by [MasterPlan 17: Track durable objectives and authoritative assignment checkpoints without Rei](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md).**
Shikigami owns the authoritative record, which the design names an objective (this request's
"major task"). Five child plans deliver it: [plan 98](../plans/98-persist-authoritative-objectives-and-conditional-commands.md)
persists objectives behind one conditional command executor; [plan 99](../plans/99-supply-trusted-objective-associations-and-the-real-checkpoint-ownership-and-scope-providers.md)
adds trusted run/conversation associations and the real checkpoint, ownership and coordination-scope
providers that close plan 84's IR-13 gate; [plan 100](../plans/100-expose-governed-objective-inspection-through-the-api-and-cli.md)
exposes the authenticated `/objectives` API and operator CLI; [plan 101](../plans/101-make-objective-capabilities-durable-for-agents-and-conversations.md)
makes the capability durable for Skills, Flows and conversations; and [plan 102](../plans/102-qualify-no-rei-objective-continuity-and-close-ir-13.md)
qualifies no-Rei continuity and completes this request. Plan 98 implements the objective
store and conditional command owner, with 19 new PostgreSQL cases covering concurrency,
rollback, source receipts and recovery after process exit. Real providers, API/CLI, durable
tools and integrated no-Rei qualification remain plans 99–102; this request is not complete.
The research baseline below is retained as the evidence the design started from.
The earlier [plan 97](../plans/97-track-durable-tasks-and-authoritative-assignment-checkpoints-without-rei.md) is superseded by MasterPlan 17 and is not a second implementation lane.

[UC-1: Adaptive autonomous delivery](../use-cases/adaptive-autonomous-delivery.md) is a
concrete consumer: its coordinator must recover current owners, assignment dependencies,
accepted artifacts, and next actions across worker turns and supervision cycles. MasterPlan 17
supplies this task/checkpoint store.

[MasterPlan 14: Deliver adaptive autonomous objectives with durable workers](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md)
consumes this request as a separately owned prerequisite. [Plan 84: Coordinate continuing worker sessions and fenced handoffs](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md),
[Plan 85: Adapt durable delivery through validated coordinator decisions](../plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md), and
[Plan 87: Supervise recurring objectives from current durable checkpoints](../plans/87-supervise-recurring-objectives-from-current-durable-checkpoints.md)
require authoritative checkpoint integration, but leave the task/checkpoint store
owned by this request. Their consumer contracts and fixture adapters do not fulfill it;
plan 99 under MasterPlan 17 delivers the real integration.

## Problem

A Shikigami run has a durable execution history, and an agent can recall memories from earlier
runs. Neither gives a user an authoritative view of one major task: its goal, completion criteria,
steps, current progress, evidence, and next action. A task may span several runs, restarts, and
conversations. Recall is relevance-ranked and bounded, so an agent cannot rely on retrieving every
prior update. A run's status describes that execution, not the outcome of the larger task.

The existing `ReiAction` sink can record a note against a known Rei intention when a Rei endpoint
is configured. Some users will not use Rei but still want their agents to keep track of a major
task. That need should not require a Rei deployment or an intention ID.

## Research baseline

- [Memory and sessions](../user/memory.md) records agent-scoped sessions and optional learning
  across runs. Recall uses a bounded hybrid query; `Shared` recall is not yet implemented. This is
  useful context for an agent, but it is not a complete task record.
- [Flows](../user/flows.md) journal steps, wait, resume, and branch within a durable run.
  [Operator run inspection](../operations/operator-cli.md) joins one workflow instance to its
  memory session. Neither supplies a goal and progress record spanning several runs.
- [The ReiAction contract](../user/sinks.md) records an action against an existing Rei intention
  through Rei's API; delivery depends on a configured endpoint. It does not create independent
  Shikigami task state.
- [ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) makes an
  overlay an additive set of model-facing tools requested by an agent and selected by an
  operator-owned catalog. Descriptors classify tools as observations, idempotent mutations, or
  irreversible emissions. Resolution currently admits only observations for durable runs and
  only Skill behavior. One-off mutation requires explicit local policy; the current one-off
  commands install a deny-all authorizer, as documented in the [CLI guide](../user/cli.md).
- [The durable overlay implementation](../../shikigami-core/src/Shikigami/Capability/Catalog.hs)
  rejects every non-observation tool. Overlay resolution is journaled, and each behavior retry
  reacquires the pinned provider revision. A lease releases resources but cannot undo a tool
  write. [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md)
  documents an earlier duplicate-memory defect caused by an unjournaled Flow write and the
  deterministic-id approach used to make memory writes safe at an at-least-once step boundary.
- [IR-11](provide-governed-mutable-repository-workspaces.md) already asks for governed mutation
  tools in durable runs. Its replay, authorization, and provider work should be considered when
  designing task updates. [IR-6](support-a2a-cross-runtime-agent-interoperability.md) concerns
  A2A task execution across runtimes; whether that protocol task and a user's major goal share an
  identity or merely link to each other remains undecided.

## Requested outcome

1. Let a user or authorized agent establish a durable major-task identity and inspect its goal,
   completion criteria, steps or checkpoints, progress, supporting evidence, and next action across
   runs. The authoritative record must be available without Rei.
2. Associate agent runs and, where appropriate, conversations with that task so a completed or
   failed run can be understood in the context of the larger goal. Do not equate one successful
   run with completion of the whole task.
3. Give an authorized agent a way to read task state and propose or record progress. Define who
   may create, modify, and complete a task, and how conflicting updates are handled. A model's
   access to a tool alone must not grant authority to modify another user's task.
4. Make durable task mutations safe across crashes, timeouts, and worker retries. The design must
   supply stable operation identity and duplicate protection in addition to workflow journaling;
   a descriptor's `IdempotentMutation` label alone is not a deduplication mechanism.
5. Keep Rei an optional integration. A user who has Rei may link or mirror task progress to an
   intention, while a user without Rei receives the same core tracking behavior.
6. For coordinated work, retain a versioned checkpoint of current assignments and owners,
   dependencies, accepted artifact/evidence identities, decisions and assumptions, unresolved
   operations, and next actions. Link it to the authoritative session/mandate/budget records
   instead of copying their independently mutable state. A resumed coordinator reads current
   instructions and state before acting; a historical scheduled prompt cannot restore an
   obsolete assignment graph.
7. Define conflict/version checks and atomic progress updates sufficient for multiple workers
   and a coordinator. Preserve accepted work through explicit handoff. Completion records must
   identify the integrated artifact and acceptance evidence; a child-run success alone cannot
   complete its parent objective.

## Questions before planning

These questions are answered in the Decision Log of MasterPlan 17 and are retained here for
the record.

- Should the authoritative task record be Shikigami-owned, supplied by a separate task service,
  or selected from operator-configured providers? What is the smallest useful persistent model?
- Should Skill task writes extend the durable overlay contract, use a dedicated replay-safe Flow
  capability, or use both through one underlying command contract? How will Danwa conversations
  gain the same capability without borrowing an agent-run journal snapshot?
- What is the identity and ownership scope of a task: user, agent principal, conversation, or
  organization? How are handoff, multiple agents, and concurrent edits represented?
- Which progress fields are structured state, and which are narrative evidence? What action is
  required to declare completion, and can an agent do that without human review?
- How should this task identity relate to a Keiro workflow id, a Kioku session, a Rei intention,
  an ExecPlan, and an A2A protocol Task? These have different lifecycles.
- Which task operations need a CLI, public API, or model tool in the first slice? Should an
  offline or one-off agent be able to use the same store?

## Acceptance to refine during design

1. Without a Rei endpoint, a user starts a multi-step task, sees its current progress, and can
   resume work on it in a later agent run or conversation without relying on memory recall alone.
2. A crash after a task update but before the behavior result is journaled does not create a
   duplicate step, regress status, or falsely complete the task when the run retries.
3. Two agents updating one task either produce an explicitly ordered result or a visible conflict;
   one agent cannot silently overwrite the other's progress.
4. An agent without task authority cannot read or mutate protected task state. An authorized user
   can inspect which run produced each recorded update.
5. Restart a UC-1 coordinator after an ownership change and accepted worker result. Its checkpoint
   identifies the current owner, result revision, unresolved operations, and next action without
   depending on semantic recall. A stale concurrent update conflicts rather than resurrecting
   the old owner or erasing the accepted result.
6. A completed worker leaves the parent objective open until its integrated acceptance evidence
   is recorded. A later run can continue the same objective without a Rei deployment.

## Scope boundary

This request is for continuity and progress on an agent's major task. It does not prescribe a
general project-management product, a storage engine, a specific overlay tool set, or an A2A wire
representation. The proposed lifecycle and implementation scope should be decided after the
questions above are answered.

[IR-15](support-continuing-worker-sessions.md) owns live session/message semantics,
[IR-16](support-adaptive-durable-orchestration.md) owns adaptive decisions and shared resource
accounting, and [IR-18](support-recurring-objective-supervision.md) owns recurring cadence,
expiry, watermark, and overlap admission. This task record links those authorities; it
does not become another session runtime, budget ledger, or scheduler. The same checkpoint
facility must remain usable for an ordinary finite task.
