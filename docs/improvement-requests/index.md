---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Improvement Request

Lifecycle and selected plans audited 2026-10-29 against child Progress/Outcomes
and the parent acceptance matrices. Completed foundation plans do not close a
request whose integrated acceptance is still open. Proposed requests have no
selected plan for their full contract; related work is identified separately.
Historical review/completion records retain their original dates.

| Request | Lifecycle | Selected implementation owner | Coverage and remaining gates |
| --- | --- | --- | --- |
| [IR-1](consult-meibo-agent-lifecycle.md) | Completed | [Plan 23](../plans/23-agent-lifecycle-control-with-meibo-principals.md) | Lifecycle admission delivered |
| [IR-2](authorized-cross-cluster-diagnostic-tools.md) | Proposed | None selected | Plan 77 is related same-cluster work only |
| [IR-3](add-declarative-router-agents.md) | Completed | [MasterPlan 8](../masterplans/8-declarative-router-agents.md) | Plans 40–42 complete |
| [IR-4](add-architecture-practice-review-flow.md) | In progress | [MasterPlan 9](../masterplans/9-architecture-practice-review-flow.md) | Plans 43–45 complete; 46 and 60–63 remain |
| [IR-5](governed-agent-evolution.md) | Proposed | None selected | Plan 33 is related schema work only |
| [IR-6](support-a2a-cross-runtime-agent-interoperability.md) | Proposed | None selected | Existing local delegation is not cross-runtime A2A |
| [IR-7](attest-sanctioned-agent-execution.md) | In progress | [MasterPlan 10](../masterplans/10-sanctioned-execution-attestation-for-agent-runs.md) | Plans 49–51 complete; 52 remains |
| [IR-8](expose-addressed-agent-runs-over-http.md) | Completed | [MasterPlan 15](../masterplans/15-expose-declared-agents-and-agent-runs-over-the-public-http-api.md) | Plan 90 complete |
| [IR-9](key-agent-continuity-by-meibo-principal.md) | Completed | [Plan 54](../plans/54-key-durable-agent-state-by-meibo-principal.md) | Plan 54 complete |
| [IR-10](expose-agent-run-status-over-http.md) | Completed | [MasterPlan 15](../masterplans/15-expose-declared-agents-and-agent-runs-over-the-public-http-api.md) | Plan 91 complete |
| [IR-11](provide-governed-mutable-repository-workspaces.md) | In progress | [Plan 96](../plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md) | Catalog admission delivered; durable mutation/fencing remains |
| [IR-12](compose-shikumi-decisions-in-durable-flows.md) | Completed | [MasterPlan 13](../masterplans/13-compose-shikumi-decisions-in-durable-flows.md) | Plans 73–76 complete |
| [IR-13](support-optional-major-task-tracking.md) | Accepted | [MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md) | Plans 98–102 not started; 97 superseded |
| [IR-14](record-durable-model-tool-turns-and-compose-harness-policies.md) | In progress | [Plan 83](../plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md) | 83 complete; continuing/integrated acceptance in 84/86 remains |
| [IR-15](support-continuing-worker-sessions.md) | In progress | [Plan 84](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md) | 84 partial; real IR-11/13 providers remain gates |
| [IR-16](support-adaptive-durable-orchestration.md) | In progress | [MasterPlan 14](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md) | 81 complete; 85/86 not started |
| [IR-17](select-governed-models-for-agent-runs.md) | In progress | [Plan 82](../plans/82-pin-governed-execution-settings-for-agent-assignments.md) | 82/83 complete; continued assignments, escalation and Flow regression remain |
| [IR-18](support-recurring-objective-supervision.md) | Accepted | [Plan 87](../plans/87-supervise-recurring-objectives-from-current-durable-checkpoints.md) | 87 not started; finite foundations do not enable recurrence |

- [Add the architecture-practice review flow](add-architecture-practice-review-flow.md) - Orchestrate advisory architecture review against revision-pinned practice evidence.
- [Add declarative router agents](add-declarative-router-agents.md) - Declare specialist expertise and route work through durable, typed delegation.
- [Attest sanctioned model execution for agent runs](attest-sanctioned-agent-execution.md) - Resolve a versioned execution profile before a run, collect every correlated model call, bind the result to the exact reviewed artifact and agent version, and issue a signed tamper-evident run attestation.
- [Add authorized cross-cluster diagnostic tools to Shikigami](authorized-cross-cluster-diagnostic-tools.md) - Add durable broker, probe, authorization, and typed telemetry-tool paths without exposing production credentials.
- [Compose Shikumi decisions in durable Flows with per-step model selection](compose-shikumi-decisions-in-durable-flows.md) - Let compiled Flows invoke registered typed Shikumi programs at named, replay-safe decision steps and select an authorized model for each invocation.
- [Consult the Meibo directory for agent lifecycle and fleet identity](consult-meibo-agent-lifecycle.md) - Gate agent execution on canonical Meibo lifecycle state and fleet identity.
- [Expose addressed agent runs over the public HTTP API](expose-addressed-agent-runs-over-http.md) - Add an agent-run vertical to ShikigamiApi so an external service can request a run for a named agent across the service boundary, with server-owned idempotency on a caller-supplied key, instead of writing into the shared run-job queue.
- [Expose terminal agent-run status over the public HTTP API](expose-agent-run-status-over-http.md) - Publish a typed, idempotent run-status read endpoint so callers that requested an addressed agent run can observe its durable running, succeeded, or failed outcome without reading Shikigami's private workflow or session storage.
- [Add governed, versioned agent evolution to Shikigami](governed-agent-evolution.md) - Control candidate agent artifacts from evaluation through approval, rollout, rollback, and audit.
- [Key durable agent continuity and outbound attribution by Meibo principal](key-agent-continuity-by-meibo-principal.md) - Make the immutable Meibo agent principal the durable key for memory, grants, run lineage, and outbound authorship while preserving name-based history through an explicit migration and compatibility boundary.
- [Provide governed mutable repository workspaces for durable agent runs](provide-governed-mutable-repository-workspaces.md) - Let a declared durable agent resolve an operator-approved repository into an isolated worktree and use bounded read, edit, validation, and Git capabilities under exact per-action authorization, returning structured change evidence.
- [Record durable model and tool turns and compose harness policies](record-durable-model-tool-turns-and-compose-harness-policies.md) - Resume Skill execution from recorded model and tool outcomes and compose context, permission, budget, and termination policies over durable execution state.
- [Select governed models and reasoning settings for agent runs](select-governed-models-for-agent-runs.md) - Resolve and pin operator-approved provider, model, and reasoning choices per agent or delegated assignment so coordinators and workers can use different execution settings within shared authority.
- [Support A2A cross-runtime agent interoperability](support-a2a-cross-runtime-agent-interoperability.md) - Implement authenticated, authorized, durable delegation between independently deployed Shikigami runtimes.
- [Support adaptive durable orchestration with shared resource limits](support-adaptive-durable-orchestration.md) - Let a coordinator revise work decomposition, assignments, hierarchy, and concurrency through validated durable decisions while preserving ownership, authority, and shared execution budgets.
- [Support continuing worker sessions with durable coordination](support-continuing-worker-sessions.md) - Let a coordinator address continuing workers, deliver follow-up assignments, observe progress and completion, and transfer ownership without losing accepted work or duplicating writers.
- [Support optional major-task tracking for Shikigami agents without Rei](support-optional-major-task-tracking.md) - Give agents and users an explicit, durable view of progress on multi-step goals across runs without requiring a Rei intention, while preserving replay-safe updates and governed access.
- [Support recurring objective supervision with durable checkpoints](support-recurring-objective-supervision.md) - Resume an explicitly authorized ongoing objective from authoritative checkpoints and events, coalesce overlapping wakeups, and enforce cadence, shared limits, expiry, and stop conditions.
