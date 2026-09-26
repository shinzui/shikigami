---
type: Improvement Request
title: Support optional major-task tracking for Shikigami agents without Rei
description: Give agents and users an explicit, durable view of progress on multi-step goals across runs without requiring a Rei intention, while preserving replay-safe updates and governed access.
timestamp: "2026-09-26T22:03:32Z"
generated:
  by: process:codex
  at: "2026-09-26T22:03:32Z"
requestId: IR-13
status: proposed
origin: mori://shinzui/shikigami
---

# Improvement Request: support optional major-task tracking for Shikigami agents without Rei

## Status

**Proposed for further design.** No task store, provider, API, or implementation plan is selected
by this request. It records the user need and the current runtime constraints so a later design
can start from evidence rather than rediscovering them.

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

## Questions before planning

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

## Scope boundary

This request is for continuity and progress on an agent's major task. It does not prescribe a
general project-management product, a storage engine, a specific overlay tool set, or an A2A wire
representation. The proposed lifecycle and implementation scope should be decided after the
questions above are answered.
