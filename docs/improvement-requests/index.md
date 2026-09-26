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
- [Consult the Meibo directory for agent lifecycle and fleet identity](consult-meibo-agent-lifecycle.md) - Gate agent execution on canonical Meibo lifecycle state and fleet identity.
- [Expose addressed agent runs over the public HTTP API](expose-addressed-agent-runs-over-http.md) - Add an agent-run vertical to ShikigamiApi so an external service can request a run for a named agent across the service boundary, with server-owned idempotency on a caller-supplied key, instead of writing into the shared run-job queue.
- [Expose terminal agent-run status over the public HTTP API](expose-agent-run-status-over-http.md) - Publish a typed, idempotent run-status read endpoint so callers that requested an addressed agent run can observe its durable running, succeeded, or failed outcome without reading Shikigami's private workflow or session storage.
- [Add governed, versioned agent evolution to Shikigami](governed-agent-evolution.md) - Control candidate agent artifacts from evaluation through approval, rollout, rollback, and audit.
- [Key durable agent continuity and outbound attribution by Meibo principal](key-agent-continuity-by-meibo-principal.md) - Make the immutable Meibo agent principal the durable key for memory, grants, run lineage, and outbound authorship while preserving name-based history through an explicit migration and compatibility boundary.
- [Provide governed mutable repository workspaces for durable agent runs](provide-governed-mutable-repository-workspaces.md) - Let a declared durable agent resolve an operator-approved repository into an isolated worktree and use bounded read, edit, validation, and Git capabilities under exact per-action authorization, returning structured change evidence.
- [Support A2A cross-runtime agent interoperability](support-a2a-cross-runtime-agent-interoperability.md) - Implement authenticated, authorized, durable delegation between independently deployed Shikigami runtimes.
- [Compose Shikumi decisions in durable Flows with per-step model selection](compose-shikumi-decisions-in-durable-flows.md) - Journal typed Shikumi decisions inside Flows and select a governed model for each decision step.
