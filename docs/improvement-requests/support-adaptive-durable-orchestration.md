---
type: Improvement Request
title: Support adaptive durable orchestration with shared resource limits
description: Let a coordinator revise work decomposition, assignments, hierarchy, and concurrency through validated durable decisions while preserving ownership, authority, and shared execution budgets.
timestamp: "2026-10-29T13:33:46Z"
generated:
  by: process:codex
  at: "2026-10-29T13:33:46Z"
requestId: IR-16
status: in-progress
targetPlan: docs/masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md
origin: mori://shinzui/shikigami
---

# Support adaptive durable orchestration with shared resource limits

## Status

**In progress.** [MasterPlan 14](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md) coordinates this request. [plan 81](../plans/81-enforce-root-resource-reservations-across-durable-work.md) is complete and supplies
root-owned reservations, shared accounting, cutoff admission and conservative uncertain
usage. [plan 82](../plans/82-pin-governed-execution-settings-for-agent-assignments.md) selection and [plan 83](../plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md) recovery are complete supporting foundations;
[plan 84](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md) continuing sessions remain in progress.

[plan 85](../plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md) adaptive proposals, validation and execution-capacity policy, and [plan 86](../plans/86-qualify-integrated-adaptive-autonomous-delivery.md)
combined-artifact/live delivery qualification are not started. The root accounting
slice satisfies the foundation of acceptance 4, which plan 85 must recheck; it does not
satisfy the remaining adaptive/integrated acceptance cases. The dependency and acceptance
matrix in MasterPlan 14 remains authoritative. Real workspace fences from [plan 96](../plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md)
and objective/checkpoint providers from [MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md) / [plan 99](../plans/99-supply-trusted-objective-associations-and-the-real-checkpoint-ownership-and-scope-providers.md) remain gates.
Typed decisions in [MasterPlan 13](../masterplans/13-compose-shikumi-decisions-in-durable-flows.md) / plans 73–76 are complete prerequisites, not blockers
for lack of implementation. This request owns adaptive coordination and integrated
[UC-1](../use-cases/adaptive-autonomous-delivery.md) delivery, while recurring mandates
remain separately owned by [IR-18](support-recurring-objective-supervision.md).

## Problem and current coverage

The fixed non-Flow supervisor still runs its declared delegate list; an ordinary
Skill with delegates does not become an adaptive coordinator. Admitted `CoordinatingSkill`
and Flow worker capabilities now share a governed session command owner from [plan 84](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md).
Their authority comes from a retained trusted scope and fresh exact authorization, not
Skill instructions. Real provider qualification remains open.

Root concurrency/attempt/token/cost/time policies now have the accounting foundation
from [plan 81](../plans/81-enforce-root-resource-reservations-across-durable-work.md). This does not prove adaptive fairness, useful overlap or combined-result
quality. [plan 85](../plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md) and [plan 86](../plans/86-qualify-integrated-adaptive-autonomous-delivery.md) still own those accepted delivery gates.

[MasterPlan 13](../masterplans/13-compose-shikumi-decisions-in-durable-flows.md) / plans 73–76 now deliver typed governed decisions and mixed-model replay.
Their finite example is a reusable decision primitive, not an implemented adaptive
continuing coordinator. The proposed coordinator must consume the real workspace and
objective/checkpoint providers rather than treating deterministic adapters as production
acceptance.

## Requested change

1. Persist an admitted objective, acceptance criteria, scope, authority, resource envelope,
   current assignment graph, dependencies, owners, and artifact identities. A coordinator
   can work directly, delegate to workers, or delegate a bounded outcome to a permitted
   local orchestrator. No roster, number of workers, or hierarchy is mandatory.
2. Add a typed proposal contract for bounded work decomposition and subsequent adaptations:
   create or narrow assignments, send new context, split or consolidate workstreams,
   transfer ownership, select permitted execution settings, and change concurrency.
   Journal proposals and validated decisions before dispatch. Validate targets, dependency
   consistency, resource ownership, cycle/depth limits, and current authority. Model output
   remains a proposal; it cannot create arbitrary workflow code or executable tool names.
3. Let a coordinator consume authoritative progress and completion events, integrate useful
   results incrementally, and reflect at meaningful boundaries such as an early finding,
   repeated failure, integration, or changed critical path. Record the observed friction,
   proposed change, expected benefit, and subsequent evidence. Silence, elapsed time, and
   agent activity are not evidence of failure, completion, or quality.
4. Establish root-owned resource accounting shared by every descendant and resumed run.
   Bound admitted concurrency, descendant work, model/tool attempts, time, and token/cost
   usage where reliable measurements exist. Reserve applicable capacity atomically before
   dispatch, settle measured usage, and preserve reservations for unknown outcomes until
   reconciliation. Account explicitly for unknown provider usage. A local orchestrator
   can narrow its allocation but cannot mint a new root budget or bypass a cutoff.
5. Define scheduling and fairness sufficient for real worker progress. Avoid holding a
   workflow lease while waiting for long external work. Demonstrate useful overlap on
   independent assignments and serialize shared writers. Raising concurrency must not
   duplicate accepted work, starve unrelated workflows, or exceed execution capacity.
6. Support coordinator instructions alongside admitted coordination capabilities, without
   silently substituting the current fixed supervisor. Planning chooses whether the first
   surface is a compiled Flow using typed decisions, a durable Skill harness with coordination
   tools, or a composition of both. Preserve existing supervisor journals and semantics
   through the required compatibility boundary rather than changing their replay behavior.
7. Bind integration and acceptance to the exact combined source/artifact, tests, evidence,
   and user journey. Workers finishing is not objective completion. Distinguish local edits,
   qualified results, and separately authorized publication/deployment. Keep telemetry
   bounded and record enough to assess rework, latency, accepted outcomes, and uncertainty.

## Acceptance

1. An initial finding causes the coordinator to choose one worker for a small task and a
   bounded hierarchy for a larger fixture. Validated decisions and resulting assignments
   are inspectable; a fixed fan-out to all declared agents does not pass.
2. During a multi-repository fixture, new evidence triggers a changed task boundary or
   temporary specialist. Accepted work and context are retained, ownership is transferred
   safely, and the integrated result passes the fixture's user-journey checks.
3. Replay after a recorded adaptation makes no new model decision or duplicate assignment.
   Resume an unfinished cycle using its pinned decision contract; deploy a changed catalog
   and verify no silent expansion of permitted agents, models, or authority.
4. Two local orchestrators race for the last root capacity reservation. Only admitted work
   dispatches. Restart, context compaction, child replacement, and recurring wakeups do not
   restore consumed budget or lose unresolved usage.
5. Independent fixture workers make observable progress concurrently within the bound.
   Overlapping writers serialize. Reducing concurrency preserves existing work, and an
   exhausted budget or cutoff admits no new work while reconciling in-flight operations.
6. Report a verified integrated outcome and evidence for one organizational adaptation,
   including quality, rework, and elapsed/resource observations with their limits. No
   claimed fleet-wide improvement may be inferred from a small fixture.

## Dependencies and existing plans

- [IR-12](compose-shikumi-decisions-in-durable-flows.md), with unimplemented
  [plans 73–76](../masterplans/13-compose-shikumi-decisions-in-durable-flows.md), supplies typed
  decisions if the coordinator uses Flow composition.
- [IR-15](support-continuing-worker-sessions.md) supplies continuing worker interactions.
- [IR-17](select-governed-models-for-agent-runs.md) supplies role/assignment model selection.
- [IR-14](record-durable-model-tool-turns-and-compose-harness-policies.md) supplies recoverable
  harness execution and enforcement of shared reservations within model/tool turns.
- [IR-13](support-optional-major-task-tracking.md) supplies durable goal and progress state.
- [IR-11](provide-governed-mutable-repository-workspaces.md) supplies coding workspaces.
- [IR-18](support-recurring-objective-supervision.md) supplies optional recurring supervision.
- Unimplemented [plan 78](../plans/78-run-external-operations-from-durable-flows-through-idempotent-shiki-jobs.md)
  supplies a generic submit/observe executor if an external worker backend is selected. It
  does not supply session messaging, workspace integration, or adaptive coordination.

These are compositional dependencies, not a requirement that every first slice implements
every backend or optional recurring mode. Publish a minimal fixture before claiming the
full use case. Follow [workflow versioning](../workflow-versioning.md); repeated cycles
require checked stable identities and bounded journal generations rather than arbitrary
model-generated step names. This request does not require A2A or a new orchestrator framework.
