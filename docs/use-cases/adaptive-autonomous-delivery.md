---
type: Use Case
title: Adaptive autonomous delivery
description: Deliver a verified outcome through a recoverable coordinator that adapts worker assignments, context, models, hierarchy, and concurrency within explicit authority and shared limits.
generated:
  by: process:codex
  at: "2026-10-10T18:29:20Z"
useCaseId: UC-1
status: draft
origin: mori://shinzui/shikigami
tags: [autonomous-delivery, coordination, durable-agents, repository-work, recovery]
themes: [autonomous-work]
jobs:
  - name: deliver-verified-outcome
    actor: developer or operator
    situation: a substantial implementation, investigation, or migration spans several decisions or workstreams
    motivation: delegate an outcome without manually directing every worker and handoff
    outcome: a preserved result with acceptance evidence, unresolved limitations, and attributable execution
  - name: improve-work-organization
    actor: coordinating agent
    situation: findings, integration friction, or resource contention make the initial organization ineffective
    motivation: revise boundaries, context, specialization, models, hierarchy, and concurrency while retaining useful work
    outcome: a validated adaptation followed by observable quality and useful-progress evidence
  - name: recover-continuing-work
    actor: developer, operator, or resumed coordinator
    situation: a worker or coordinator restarts, receives a follow-up, or hands off ownership
    motivation: recover current intent, accepted work, and pending operations without duplicate writers or reset budgets
    outcome: the same objective continues from authoritative state with honest unresolved effects
  - name: supervise-recurring-objective
    actor: operator or coordinating agent
    situation: an explicitly authorized ongoing objective needs event-driven follow-up and scheduled recovery checks
    motivation: keep useful bounded cycles running until cancellation or expiry
    outcome: current checkpoints and watermarks advance without overlapping work, stale instructions, or work admitted after cutoff
features:
  - name: durable-orchestration-foundation
    description: Journal compiled Flows and bounded child runs with lineage, waits, cancellation, and validated routing.
    status: delivered
    owners: [mori://shinzui/shikigami]
    acceptance: Existing FlowLifecycle, AgentWorkflow, and RouterWorkflow suites provide replay and child-run evidence for the documented primitives.
    jobs: [deliver-verified-outcome, recover-continuing-work]
  - name: governed-actions-and-human-waits
    description: Enforce principal lifecycle, exact external-action authorization, and durable human approval.
    status: delivered
    owners: [mori://shinzui/shikigami]
    acceptance: Existing authorization and approval evidence demonstrates refusal and durable waits; each deployment still supplies live authority and delivery services.
    jobs: [deliver-verified-outcome, recover-continuing-work]
  - name: recoverable-model-tool-harness
    description: Record accepted model and tool operations and reconstruct context, pending work, and policy state after restart.
    status: discovered
    owners: [mori://shinzui/shikigami]
    acceptance: Restart within a multi-turn worker loop reuses committed outcomes and reconciles uncertain effects without resetting usage.
    jobs: [deliver-verified-outcome, recover-continuing-work]
    improvementRequests: [mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-14]
  - name: continuing-worker-sessions
    description: Address workers across assignments, deliver follow-ups, consume progress events, and transfer ownership safely.
    status: discovered
    owners: [mori://shinzui/shikigami]
    acceptance: A worker handles a follow-up under the same session identity and an ownership transfer fences the previous writer after restart.
    jobs: [improve-work-organization, recover-continuing-work]
    improvementRequests: [mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-15]
  - name: adaptive-coordination-and-shared-limits
    description: Validate and execute organizational changes while reserving concurrency and resource allowances across descendants.
    status: discovered
    owners: [mori://shinzui/shikigami]
    acceptance: New evidence changes a fixture's assignments; root reservation races admit only bounded work and the combined outcome passes acceptance.
    jobs: [deliver-verified-outcome, improve-work-organization, recover-continuing-work]
    improvementRequests: [mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-16]
  - name: role-appropriate-run-models
    description: Resolve and pin permitted provider, model, and reasoning settings for coordinator and worker runs or later assignments.
    status: discovered
    owners: [mori://shinzui/shikigami]
    acceptance: One deployment dispatches distinct permitted coordinator/worker tuples, preserves them on resume, and refuses forbidden choices before dispatch.
    jobs: [deliver-verified-outcome, improve-work-organization]
    improvementRequests: [mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-17]
  - name: typed-coordinator-decisions
    description: Invoke typed Shikumi decisions at governed replay-safe Flow slots with per-decision model selection.
    status: planned
    owners: [mori://shinzui/shikigami]
    acceptance: Plans 73–76 demonstrate typed mixed-model decisions whose committed branches replay without new calls or duplicate children.
    jobs: [deliver-verified-outcome, improve-work-organization]
    improvementRequests: [mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-12]
  - name: isolated-repository-work-and-integration
    description: Give coding assignments isolated recoverable workspaces, authorized edits/tests/Git, and integration evidence for exact artifacts.
    status: discovered
    owners: [mori://shinzui/shikigami]
    acceptance: Two worker artifacts are integrated in a separate workspace and validated together, with safe handoff and uncertain-operation recovery.
    jobs: [deliver-verified-outcome, recover-continuing-work]
    improvementRequests: [mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-11]
  - name: authoritative-objective-checkpoints
    description: Track acceptance, current assignments and owners, dependencies, evidence, and next actions across runs without requiring Rei.
    status: discovered
    owners: [mori://shinzui/shikigami]
    acceptance: A resumed coordinator reads current ownership and accepted artifact identities without relying on semantic memory recall.
    jobs: [deliver-verified-outcome, recover-continuing-work, supervise-recurring-objective]
    improvementRequests: [mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-13]
  - name: recurring-objective-supervision
    description: Resume authorized ongoing work through events and scheduled backstops with coalescing, watermarks, expiry, and explicit stopping.
    status: discovered
    owners: [mori://shinzui/shikigami]
    acceptance: Duplicate wakeups do not duplicate work, a successful ongoing cycle continues, and expiry or cancellation prevents new admission.
    jobs: [supervise-recurring-objective, recover-continuing-work]
    improvementRequests: [mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-18]
improvementRequests:
  - mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-11
  - mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-12
  - mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-13
  - mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-14
  - mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-15
  - mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-16
  - mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-17
  - mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-18
---

# Adaptive autonomous delivery

## Intended outcome and source

A user gives Shikigami an outcome, acceptance criteria, constraints, authority, and resource
preferences. A coordinator performs useful work itself or delegates to workers and local
orchestrators. It revises that organization when evidence warrants a change, preserves
accepted work, and finishes with a verified result or a precise unresolved scope.

The motivating methodology is Evan Boyle's
[autonomous-delivery skill, version 2.1.0](https://gist.github.com/EvanBoyle/8c1a97f682d92dab8c09d0e1ea73f4a0),
read at gist revision `5ce9f9486d3cbed37a8b03b1b0152917b4bdff90` on 2026-10-10. It describes
adaptive coordination and periodic reflection rather than a mandatory delivery pipeline.
This use case belongs to the [autonomous-work theme](themes/autonomous-work.md).
No skill is installed and no recurring automation is started by this documentation.

**Draft; not executable end to end today.** Existing primitives are implemented, but the
continuing harness and coding/coordination requirements below remain missing. The feature
states describe coverage, not a fresh live qualification. The source baseline is Shikigami
commit `51c7b1d`; this documentation change runs catalog checks, not runtime acceptance.

## User journey

1. Admit a finite objective or explicitly authorized ongoing mandate, with canonical repository
   identities when relevant, acceptance criteria, scope, model preferences, shared resource
   limits, and publication/deployment authority. Store its authoritative checkpoint.
2. The coordinator reads applicable repository instructions and existing work/owners, then
   proposes bounded assignments. Simple work can remain with one agent; complex independent
   work can use workers or local orchestrators within the same root authority and budget.
3. Workers gather evidence or execute authorized edits and validation in isolated workspaces.
   They return exact artifact identities, evidence, uncertainties, and progress events.
   Follow-ups retain the worker's useful context and accepted work.
4. On meaningful findings or friction, the coordinator reflects on boundaries, context,
   specialization, hierarchy, model choices, and concurrency. It journals and validates an
   adaptation before execution. Ownership changes reconcile pending effects and fence old
   writers. Measure useful progress and quality with the observation limits made explicit.
5. Integrate completed work incrementally. For code delivery, validate the exact combined
   source and user journey; individual workers' green checks are insufficient. Preserve
   acceptance evidence and report material failures without claiming a successful deployment
   merely from process exit or model prose.
6. Recover after restart from current objective/session/operation state. For ongoing mandates,
   consume completion events and use scheduled recovery wakeups, process bounded new evidence,
   checkpoint watermarks, and coalesce overlap. At completion, cancellation, or expiry, stop
   new admission and reconcile existing work without discarding uncertain effects.

## Capability gaps and request ownership

| Feature | Owning request | Coverage remaining |
| --- | --- | --- |
| Recoverable model/tool harness | [IR-14](../improvement-requests/record-durable-model-tool-turns-and-compose-harness-policies.md) | Proposed; no execution-record/harness plan yet. Updated for follow-ups and shared accounting. |
| Continuing workers | [IR-15](../improvement-requests/support-continuing-worker-sessions.md) | New request for durable messaging/events, retained context, and ownership transfer. |
| Adaptive coordination and shared limits | [IR-16](../improvement-requests/support-adaptive-durable-orchestration.md) | New request for validated adaptations, root reservations, execution capacity, and integrated qualification. |
| Run/assignment model choices | [IR-17](../improvement-requests/select-governed-models-for-agent-runs.md) | New request; process defaults and sanctioned profiles alone do not select different worker models. |
| Typed Flow decisions | [IR-12](../improvement-requests/compose-shikumi-decisions-in-durable-flows.md) | Planned in unimplemented plans 73–76; scope remains per decision invocation. |
| Repository work and integration | [IR-11](../improvement-requests/provide-governed-mutable-repository-workspaces.md) | Proposed durable mutation path; updated for assignment identity, handoff, instructions, and integrated artifacts. |
| Goal and checkpoint continuity | [IR-13](../improvement-requests/support-optional-major-task-tracking.md) | Proposed; updated for versioned assignments, authoritative owner/evidence references, and integrated acceptance. |
| Optional ongoing supervision | [IR-18](../improvement-requests/support-recurring-objective-supervision.md) | New request for admitted mandates, current-state reconciliation, overlap, watermark, expiry, and stop semantics. |

Frontmatter request references mirror this table and the feature-level union. Body links
provide navigation to owning requests; the current bundle graph connects the local use case
and theme, while cross-bundle request relationships use the canonical frontmatter references.
The canonical use-case identity is
`mori://shinzui/shikigami/okf/use-cases/concepts/UC-1`.

## Existing implementation and unimplemented plan coverage

| Implementation or plan | What can be reused | What it does not establish |
| --- | --- | --- |
| [Durable Flows](../capabilities/durable-agent-flows.md), [routing/delegation](../capabilities/governed-routing-and-delegation.md), completed plans [9](../plans/9-multi-agent-delegation-primitive.md) and [42](../plans/42-execute-replay-safe-typed-routing-and-delegation.md) | Compiled lifecycle, child identities, lineage, bounded fan-out, waits and cancellation. | Continuing mailboxes, adaptive organization, or simultaneous useful execution merely from child count. |
| [Exact authorization](../capabilities/exact-action-authorization.md), [human approval](../capabilities/durable-human-approval.md), [principal continuity](../capabilities/principal-lifecycle-and-continuity.md) | Enforcing authority, lifecycle and parked human decisions. | Permission acquired solely from installing a skill or assigning a role. Live services remain deployment prerequisites. |
| [MasterPlan 13](../masterplans/13-compose-shikumi-decisions-in-durable-flows.md), plans [73](../plans/73-define-typed-decision-programs-and-authorized-model-catalogs.md), [74](../plans/74-run-shikumi-decisions-through-governed-provider-calls.md), [75](../plans/75-persist-decision-call-evidence-across-retries-and-restarts.md), [76](../plans/76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md) | Planned typed program/model catalog, governed execution, evidence store, and Flow decision composition. | All four are not started. Their finite example does not deliver a continuing coordinator, worker model selection, or Skill transcript recovery. |
| [Plan 48](../plans/48-add-a-portable-one-off-repository-agent-harness.md) and completed read-only slice [59](../plans/59-adopt-capability-overlays-in-the-portable-one-off-repository-harness.md) | Workspace containment/provider seams and future one-off editing/command design. | Remaining writable/command/executable milestones are unchecked. The worker installs no provider; one-off commands deny acquisition. This is not durable IR-11 delivery. |
| [Plan 78](../plans/78-run-external-operations-from-durable-flows-through-idempotent-shiki-jobs.md) | Optional generic quick submit/observe executor and durable child-job polling. | All implementation milestones are unchecked; it neither retains coding sessions nor integrates workspaces. Production authorization depends on `mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-4`; repeat-safe shiki submission needs `mori://shinzui/shiki/okf/improvement-requests/concepts/IR-1`. These are conditional on backend selection. |
| [Plan 80](../plans/80-configure-model-providers-and-agent-launches-through-baikai.md) and [foreground launch capability](../capabilities/foreground-agent-launches.md) | Implemented HTTP transport/options and foreground vendor-agent launches with operator ceilings. | Background CLI response adapters remain blocked on released cancellation-safe lifecycle support. A foreground unattended process result is not a durable worker job. |
| [Plan 12](../plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md) | Optional planned MCP tool transport. | Still unfinished; MCP configuration alone supplies neither coordination semantics nor mutation authority. It is not mandatory for a native capability first slice. |
| [Plan 79](../plans/79-qualify-local-agent-execution-and-prioritize-production-readiness.md) | Packaging and bounded service-health qualification work. | Its supervised deployment and live/fault milestones remain unfinished; the tool-free reporter does not qualify autonomous coding. |

Two current code boundaries matter. In
[Agent.Workflow](../../shikigami-core/src/Shikigami/Agent/Workflow.hs), a non-Flow agent
with declared delegates takes the fixed supervisor path instead of running its Skill;
delegation plus overlays is refused. In
[Behavior.Skill](../../shikigami-core/src/Shikigami/Behavior/Skill.hs), intermediate model/tool
context is in memory inside one outer behavior step, with a default eight-turn ceiling
from [Behavior.Run](../../shikigami-core/src/Shikigami/Behavior/Run.hs).
[Workers.Config](../../shikigami-workers/src/Shikigami/Workers/Config.hs) installs
`emptyCapabilityRuntime`, and [Capability.Catalog](../../shikigami-core/src/Shikigami/Capability/Catalog.hs)
admits only observations for durable overlays. These prevent an installation-only solution.

## Acceptance scenarios

1. **Adaptive finite delivery:** Start a fixture objective with bounded authority and two
   repository workstreams. An early finding changes the initial organization; the journal
   records the evidence and validated adaptation. Workers return exact artifacts, and the
   integrated result passes the requested user journey and repository checks. Preserve the
   final artifacts, observed resource/latency/rework facts, and material limitations.
2. **Continuing-worker recovery:** Send a follow-up to an existing worker, restart during its
   model/tool loop, redeliver the coordination message and completion event, and resume the
   coordinator. Accepted results and current context recover without a duplicate logical
   assignment. Reconcile effects whose external outcome was not recorded.
3. **Shared ownership and limits:** Race local orchestrators for the last capacity reservation
   and attempt an overlapping write. Only admitted work proceeds, former owners are fenced
   on transfer, and restarts/new workers do not restore consumed or unknown usage. Reject a
   forbidden target/model/action before dispatch.
4. **Pinned execution and evidence:** Use distinct permitted coordinator/worker settings,
   then change deployment defaults while suspended. Replay retains committed decisions and
   effective tuples; pending work retains its binding or fails explicitly. Test evidence is
   bound to the integrated revision, not an obsolete worker artifact or a model claim.
5. **Optional ongoing supervision:** Admit a mandate with cadence, resource envelope and
   expiry. A successful cycle keeps it alive; duplicate wakeups coalesce. New instructions
   override historical checkpoint assumptions. No-delta cycles create no duplicate workers;
   cancellation or expiry admits no new work and preserves unresolved in-flight effects.
6. **Honest stopping:** A blocked or uncertain outcome names its exact unresolved scope and
   preserves useful work. A finite success closes its objective only after acceptance. Local
   edits/test authorization does not imply permission to publish, merge, deploy, or schedule.

Implementation qualification must exercise actual journals, operation recovery, provider and
workspace boundaries, and relevant user journeys. Deterministic fixtures prove mechanics;
at least one bounded live model/coding trial must substantiate the full delivery claim.
Follow [workflow versioning](../workflow-versioning.md), including patch compatibility,
checked declarations, generation rotation, and `just keiro-gate` for workflow-body changes.

## Scope and sequencing

Start with a finite, single-deployment objective. Recoverable turns, checkpoints, and isolated
execution can be qualified before a full adaptive hierarchy. Compose existing decision-plan
work when choosing a Flow coordinator; specify session, ownership, model-catalog, and budget
interfaces before integrating their implementations. Add recurring mandates only for an
explicit ongoing objective. IR-16 owns the final adaptive integration/qualification.

An optional external executor can build on plan 78; native repository tools can build on
IR-11. Neither requires Shikigami to depend on a particular vendor CLI or on shiki. A
single-agent research case needs only its admitted evidence tools, not repository mutation.

Public callers may additionally need [IR-8](../improvement-requests/expose-addressed-agent-runs-over-http.md)
and [IR-10](../improvement-requests/expose-agent-run-status-over-http.md); CLI/internal delegation
does not. [IR-6](../improvement-requests/support-a2a-cross-runtime-agent-interoperability.md)
is conditional on cross-runtime delegation, and remaining signing work in
[IR-7](../improvement-requests/attest-sanctioned-agent-execution.md) is conditional on signed
attestation requirements. Existing profile enforcement and call evidence are reused without
blocking on signatures. [Agent evolution](../improvement-requests/governed-agent-evolution.md)
governs changing the agent artifact itself; changing admitted assignments during a run is
a separate operation. These optional requests are not part of the required feature union.
