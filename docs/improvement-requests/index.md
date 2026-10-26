---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Improvement Request

IR-12 completed on 2026-10-25 with MasterPlan 13 acceptance and evolution gates passing.
Other status and selected implementation plans were audited on 2026-10-22 UTC (2026-10-21 local) against the current
plan progress, recorded acceptance evidence, and repository tree. Accepted requests
have selected plans whose implementation has not started. Proposed requests have no
selected plan for their full contract; related and consuming plans are linked in the
individual requests.

| Request | Status | Selected implementation plan |
| --- | --- | --- |
| [IR-1](consult-meibo-agent-lifecycle.md) | Completed | [Plan 23](../plans/23-agent-lifecycle-control-with-meibo-principals.md) |
| [IR-2](authorized-cross-cluster-diagnostic-tools.md) | Proposed | None |
| [IR-3](add-declarative-router-agents.md) | Completed | [MasterPlan 8](../masterplans/8-declarative-router-agents.md), plans 40–42 |
| [IR-4](add-architecture-practice-review-flow.md) | In progress | [MasterPlan 9](../masterplans/9-architecture-practice-review-flow.md), plans 43–46 and closeout plans 60–63 |
| [IR-5](governed-agent-evolution.md) | Proposed | None |
| [IR-6](support-a2a-cross-runtime-agent-interoperability.md) | Proposed | None |
| [IR-7](attest-sanctioned-agent-execution.md) | In progress | [MasterPlan 10](../masterplans/10-sanctioned-execution-attestation-for-agent-runs.md), plans 49–52 |
| [IR-8](expose-addressed-agent-runs-over-http.md) | Completed | [Plan 90](../plans/90-accept-addressed-agent-runs-over-http-with-server-owned-idempotency.md), under [MasterPlan 15](../masterplans/15-expose-declared-agents-and-agent-runs-over-the-public-http-api.md) |
| [IR-9](key-agent-continuity-by-meibo-principal.md) | Completed | [Plan 54](../plans/54-key-durable-agent-state-by-meibo-principal.md) |
| [IR-10](expose-agent-run-status-over-http.md) | In progress | [Plan 91](../plans/91-expose-agent-run-status-and-history-over-http.md), under [MasterPlan 15](../masterplans/15-expose-declared-agents-and-agent-runs-over-the-public-http-api.md) |
| [IR-11](provide-governed-mutable-repository-workspaces.md) | Proposed | None |
| [IR-12](compose-shikumi-decisions-in-durable-flows.md) | Completed | [MasterPlan 13](../masterplans/13-compose-shikumi-decisions-in-durable-flows.md), plans 73–76 |
| [IR-13](support-optional-major-task-tracking.md) | Proposed | None |
| [IR-14](record-durable-model-tool-turns-and-compose-harness-policies.md) | Accepted | [Plan 83](../plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md), under [MasterPlan 14](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md) |
| [IR-15](support-continuing-worker-sessions.md) | Accepted | [Plan 84](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md), under [MasterPlan 14](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md) |
| [IR-16](support-adaptive-durable-orchestration.md) | Accepted | [MasterPlan 14](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md), plans 81, 85, and 86 |
| [IR-17](select-governed-models-for-agent-runs.md) | Accepted | [Plan 82](../plans/82-pin-governed-execution-settings-for-agent-assignments.md), under [MasterPlan 14](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md) |
| [IR-18](support-recurring-objective-supervision.md) | Accepted | [Plan 87](../plans/87-supervise-recurring-objectives-from-current-durable-checkpoints.md), under [MasterPlan 14](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md) |

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
