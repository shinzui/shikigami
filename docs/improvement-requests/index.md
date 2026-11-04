---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Improvement Request

- [Add the architecture-practice review flow](add-architecture-practice-review-flow.md) - Orchestrate advisory architecture review against revision-pinned practice evidence.
- [Add declarative router agents](add-declarative-router-agents.md) - Declare specialist expertise and route work through durable, typed delegation.
- [Attest sanctioned model execution for agent runs](attest-sanctioned-agent-execution.md) - Resolve a versioned execution profile before a run, collect every correlated model call, bind the result to the exact reviewed artifact and agent version, and issue a signed tamper-evident run attestation.
- [Add authorized cross-cluster diagnostic tools to Shikigami](authorized-cross-cluster-diagnostic-tools.md) - Add durable broker, probe, authorization, and typed telemetry-tool paths without exposing production credentials.
- [Compose Shikumi decisions in durable Flows with per-step model selection](compose-shikumi-decisions-in-durable-flows.md) - Let compiled Flows invoke registered typed Shikumi programs at named, replay-safe decision steps and select an authorized model for each invocation.
- [Consult the Meibo directory for agent lifecycle and fleet identity](consult-meibo-agent-lifecycle.md) - Gate agent execution on canonical Meibo lifecycle state and fleet identity.
- [Execute governed work through enrolled machine daemons](execute-governed-work-through-machine-daemons.md) - Let a central Shikigami runtime run durable workspace operations on enrolled machines through an outbound daemon that enforces its own local limits, so a compromised runtime cannot reach beyond each machine's grant.
- [Expose addressed agent runs over the public HTTP API](expose-addressed-agent-runs-over-http.md) - Add an agent-run vertical to ShikigamiApi so an external service can request a run for a named agent across the service boundary, with server-owned idempotency on a caller-supplied key, instead of writing into the shared run-job queue.
- [Expose terminal agent-run status over the public HTTP API](expose-agent-run-status-over-http.md) - Publish a typed, idempotent run-status read endpoint so callers that requested an addressed agent run can observe its durable running, succeeded, or failed outcome without reading Shikigami's private workflow or session storage.
- [Add governed, versioned agent evolution to Shikigami](governed-agent-evolution.md) - Control candidate agent artifacts from evaluation through approval, rollout, rollback, and audit.
- [Key durable agent continuity and outbound attribution by Meibo principal](key-agent-continuity-by-meibo-principal.md) - Make the immutable Meibo agent principal the durable key for memory, grants, run lineage, and outbound authorship while preserving name-based history through an explicit migration and compatibility boundary.
- [Propose unrequested work from observed activity](propose-unrequested-work-from-observed-activity.md) - Let an agent notice actionable work nobody asked it to do and propose a governed objective, starting it only under an explicit, bounded and revocable standing policy.
- [Provide governed mutable repository workspaces for durable agent runs](provide-governed-mutable-repository-workspaces.md) - Let a declared durable agent resolve an operator-approved repository into an isolated worktree and use bounded read, edit, validation, and Git capabilities under exact per-action authorization, returning structured change evidence.
- [Record durable model and tool turns and compose harness policies](record-durable-model-tool-turns-and-compose-harness-policies.md) - Resume Skill execution from recorded model and tool outcomes and compose context, permission, budget, and termination policies over durable execution state.
- [Select governed models and reasoning settings for agent runs](select-governed-models-for-agent-runs.md) - Resolve and pin operator-approved provider, model, and reasoning choices per agent or delegated assignment so coordinators and workers can use different execution settings within shared authority.
- [Supervise active work with an independent watchdog agent](supervise-active-work-with-an-independent-watchdog-agent.md) - Detect stuck or drifting coordinators and workers from authoritative durable state, and raise bounded, deduplicated findings without gaining authority over the work observed.
- [Support A2A cross-runtime agent interoperability](support-a2a-cross-runtime-agent-interoperability.md) - Implement authenticated, authorized, durable delegation between independently deployed Shikigami runtimes.
- [Support adaptive durable orchestration with shared resource limits](support-adaptive-durable-orchestration.md) - Let a coordinator revise work decomposition, assignments, hierarchy, and concurrency through validated durable decisions while preserving ownership, authority, and shared execution budgets.
- [Support continuing worker sessions with durable coordination](support-continuing-worker-sessions.md) - Let a coordinator address continuing workers, deliver follow-up assignments, observe progress and completion, and transfer ownership without losing accepted work or duplicating writers.
- [Support optional major-task tracking for Shikigami agents without Rei](support-optional-major-task-tracking.md) - Give agents and users an explicit, durable view of progress on multi-step goals across runs without requiring a Rei intention, while preserving replay-safe updates and governed access.
- [Support recurring objective supervision with durable checkpoints](support-recurring-objective-supervision.md) - Resume an explicitly authorized ongoing objective from authoritative checkpoints and events, coalesce overlapping wakeups, and enforce cadence, shared limits, expiry, and stop conditions.
