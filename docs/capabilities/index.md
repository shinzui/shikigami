---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Capability

- [Addressed durable conversations](addressed-conversations.md) - Consume addressed messages, preserve conversation turns, and rotate a durable workflow generation after every reply.
- [Advisory practice-review orchestration](advisory-practice-review.md) - Run a registered advisory review flow with pinned evidence contracts, validated verdicts, review memory, and deduplicated attention.
- [Agent memory and sessions](agent-memory-and-sessions.md) - Recall prior agent learnings and record session outcomes with configurable automatic memory policy.
- [Authorized sink delivery and outbox](authorized-sink-outbox.md) - Dispatch declared external outputs with permission checks, durable intents, retry classification, and delivery receipts.
- [Database migrations and bootstrap](database-migrations-and-bootstrap.md) - Apply a dependency-ordered database plan, reconcile memory read models, and refuse incompatible migration history at runtime startup.
- [Declared-agent HTTP catalog](declared-agent-http-catalog.md) - Discover boot-loaded declarations and current lifecycle admission through authenticated HTTP, Relay pages, and a typed client.
- [Durable agent runs and Flows](durable-agent-flows.md) - Resume agent lifecycles and compiled Haskell Flows from journaled steps after suspension or restart.
- [Durable human approval](durable-human-approval.md) - Park workflow work for an approval answer or deadline and suppress protected output on rejection or timeout.
- [Durable trigger intake](durable-trigger-intake.md) - Turn cron ticks, matching activity envelopes, and addressed integration events into durable run jobs.
- [Exact external-action authorization](exact-action-authorization.md) - Require a verified authorization decision immediately before acquiring providers, calling tools, or delivering protected sinks.
- [Foreground agent launches](foreground-agent-launches.md) - Launch attended vendor terminal sessions or named unattended jobs with explicit authority and preserved exit status.
- [Governed routing and delegation](governed-routing-and-delegation.md) - Validate routing decisions and run bounded durable child agents with deterministic identities and retained lineage.
- [Agent-run lifecycle and HTTP acceptance history](http-agent-run-lifecycle.md) - Read durable run outcomes, page HTTP acceptance receipts, and reconcile retained pre-workflow dead letters through HTTP and operator clients.
- [HTTP caller authentication](http-caller-authentication.md) - Verify configured bearer credentials at the agents mount and propagate a credential-free caller identity to run acceptance.
- [Typed HTTP health contract](http-health-contract.md) - Serve separate liveness and readiness endpoints with a shared typed client, OpenAPI description, and problem response conventions.
- [Idempotent addressed runs over HTTP](idempotent-http-agent-runs.md) - Atomically accept an addressed run and queue it once under a server-owned identity, with safe request replay and conflict detection.
- [Local integration fixtures](local-integration-fixtures.md) - Exercise activity intake and sink HTTP contracts with fixture publication, authenticated local stubs, and an outbound conversation probe.
- [Principal lifecycle and continuity](principal-lifecycle-and-continuity.md) - Gate runs on a validated directory snapshot and preserve principal-based memory and grants across presentation renames.
- [Program and Skill execution](program-and-skill-execution.md) - Execute registered programs or instruction-directory Skills and return JSON, with a bounded tool loop for Skills.
- [Revision-pinned tool overlays](revision-pinned-tool-overlays.md) - Resolve additive Skill tools against an operator catalog, acquire exact-revision leases, and release them on every exit.
- [Run evidence and compliance records](run-evidence-and-compliance.md) - Collect correlated call evidence, evaluate execution compliance, and persist a checked lifecycle with guarded queries.
- [Sanctioned execution profile pinning](sanctioned-execution-profiles.md) - Resolve an immutable execution policy before a run and retain its exact provider, model, and option constraints on replay.
- [Typed agent declarations](typed-agent-declarations.md) - Load typed Dhall manifests with identity, behavior, triggers, sinks, memory, delegation, and overlay policy.
- [Governed typed decisions in durable Flows](typed-flow-decisions.md) - Pin typed programs and admitted model aliases, journal validated outcomes, and retain actual-attempt evidence across retries and restart.
- [Worker operations and telemetry](worker-operations-and-telemetry.md) - Operate supervised background roles with bounded recovery, configuration diagnostics, runtime inspection, and exported run metrics.
