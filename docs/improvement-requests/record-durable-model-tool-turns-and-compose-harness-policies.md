---
type: Improvement Request
title: Record durable model and tool turns and compose harness policies
description: Resume Skill execution from recorded model and tool outcomes and compose context, permission, budget, and termination policies over durable execution state.
timestamp: "2026-10-10T23:44:58Z"
generated:
  by: process:codex
  at: "2026-10-11T03:04:54Z"
requestId: IR-14
status: accepted
targetPlan: docs/plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md
origin: mori://shinzui/shikigami
---

# Improvement Request: record durable model and tool turns and compose harness policies

## Status

**Accepted; implementation planned but not started.** [MasterPlan 14](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md) coordinates this
request with IR-15 through IR-18 for
[UC-1: Adaptive autonomous delivery](../use-cases/adaptive-autonomous-delivery.md).
[plan 83](../plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md) owns durable model/tool turns and composed policies;
[plan 84](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md) closes the continuing-message recovery integration, and
[plan 86](../plans/86-qualify-integrated-adaptive-autonomous-delivery.md) qualifies the integrated delivery scenario. Shared resource
accounting and pinned settings come from [plan 81](../plans/81-enforce-root-resource-reservations-across-durable-work.md) and [plan 82](../plans/82-pin-governed-execution-settings-for-agent-assignments.md).
All these plans are not started. The evidence persistence planned in
[plan 75](../plans/75-persist-decision-call-evidence-across-retries-and-restarts.md)
records typed decision-call evidence; it does not recover a Skill's model/tool transcript.

## Problem

An ordinary Skill executes its model and tool loop inside one journaled `run-behavior-v2`
step. Intermediate model responses, tool requests, and tool observations are held in the
behavior's in-memory context. If the worker crashes before the behavior result commits,
the next attempt can repeat already completed model calls and tool work. This increases
cost, loses the prior conversation's decisions, and makes future mutation tools harder to
recover safely. A completed outer workflow step does not protect each action within it.

Harness policies control what the model sees and what work may execute: context selection
and compaction, permissions, budgets, output validation, and termination. As these policies
grow, they need a shared durable account of execution and explicit composition rules.
Compacting the model context must not erase budget usage or pending permission decisions;
changing an offered tool list must not bypass authorization or restore an exhausted budget.

## Current boundaries

- [Agent workflow execution](../../shikigami-core/src/Shikigami/Agent/Workflow.hs) journals
  an ordinary synchronous behavior as one step; explicit Flow capabilities have their own
  replay-safe boundaries.
- [Skill execution](../../shikigami-core/src/Shikigami/Behavior/Skill.hs) appends tool
  observations to an in-memory context and applies a model-turn ceiling. The
  [conversation workflow](../../shikigami-core/src/Shikigami/Agent/Conversation.hs) also
  journals behavior as one step within each conversation turn. Rotating after that turn
  does not checkpoint the model and tool exchanges inside it.
- [Capability overlays](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md)
  pin approved descriptors and bracket provider leases. Durable overlays currently admit
  observations only; recording turns must not implicitly enable mutations or conversation
  overlays.
- [Action authorization](../operations/action-authorization.md) requires a fresh exact
  decision before protected external IO. Recorded harness permission is not a reusable
  authorization proof.

## Requested change

1. Give each accepted model request and tool operation a stable durable identity associated
   with its run or conversation, behavior execution, and preceding recorded decision.
   Record the accepted request before dispatch and its validated response, failure,
   cancellation, or unresolved outcome afterward. Correlate multiple tool calls in one
   model response without relying on provider call ids or counters that reset on retry.
2. Reconstruct the model context, completed work, pending operations, and terminal result
   from durable records. Resume from the first unfinished operation and reuse committed
   model and tool outcomes. Outcome recording and the progress that enables subsequent
   work must have an atomic boundary so a crash cannot skip or duplicate a logical turn.
   Reacquire pinned capability providers when needed without replaying completed tools.
3. Define recovery for an operation whose external effect may have succeeded without a
   recorded result. Reuse stable idempotency keys where the provider supports them and
   otherwise specify reconciliation, safe retry, or a visible unresolved outcome by
   operation class. Do not claim exactly-once external execution. Cancellation and timeout
   must preserve completed work and must not report an uncertain mutation as undone.
4. Introduce independently composable harness policies over validated durable state.
   Initial policies should cover context selection and compaction, tool permission,
   execution budgets, output validation, and termination. Policies derive model context
   or execution proposals; interpreters own external IO and its recording boundary.
   Persist any model-assisted policy result, such as a summary, as recoverable work.
5. Specify deterministic policy composition and execution admission. An exhausted budget,
   denied permission, cancellation, or terminal output-validation failure cannot be
   bypassed by another policy offering a tool or proposing a model call. Reserve applicable budget before
   dispatch, record measured usage afterward, and account explicitly for unknown usage.
   Compaction changes the model-facing context while preserving execution facts and usage.
   Pending human decisions can suspend and resume without restarting the whole behavior.
6. Pin the effective policy configuration and version for a durable execution. Export
   defaults and expose supported overrides through an agent or operator surface within
   the admitted execution profile. Make truncation, budget exhaustion, and other policy
   effects inspectable. Manifest edits or changed defaults must not silently alter an
   in-flight loop. Harness policy may narrow authority but must not widen capabilities,
   permitted models, or the existing fresh per-action authorization boundary.
7. Integrate records with existing run evidence, session completion, memory recording, and
   sink delivery so recovery produces one logical terminal result. Define which bounded
   request and response data is needed for replay and which uses protected durable payload
   references. Set access, retention, and checkpoint rules that preserve live replay data
   and keep credentials and authorization proofs out of journals and ordinary logs.
   Call evidence and a replay transcript have distinct purposes; correlate them without
   creating contradictory execution histories.
8. Apply the same turn and policy semantics to durable Skill agent runs and conversation
   behavior execution, with explicit ownership for each lifecycle. Preserve simple
   single-completion Skills and define the one-off commands' recording mode. Follow
   [workflow versioning](../workflow-versioning.md) for existing journals, result codecs,
   generation rotation, patch guards, and checked declarations. Document a composed-policy
   example and expose bounded turn progress and unresolved operations to operators.

9. Compose continuing-session coordination and shared resource policies over the same
   durable execution state. Accepted follow-up messages and ownership operations retain
   their operation identities through retries; compaction and a new assignment do not
   clear root reservations, unknown usage, pending instructions, or pinned settings.
   Reconstruct relevant context from accepted history without treating relevance-ranked
   memory as the authoritative assignment or budget record.

## Acceptance

1. A fixture Skill executes multiple model and tool turns. Restart after each committed
   outcome, including a tool result recorded before the next model request. Completed
   operations are not dispatched again, the recovered context matches the committed
   history, and one final session result, memory record under the declared policy, and
   set of sink intents are produced.
2. Crash after an external operation succeeds but before recording its result. An
   idempotent fixture reuses the same operation key; a fixture without a safe retry
   contract enters an inspectable unresolved state or reconciliation path. Neither
   falsely reports exactly-once execution or completed cancellation.
3. Compose compaction, permissions, and a tool budget. Exhaust the budget, compact older
   messages, restart, and change the offered tool set. Usage remains accounted for and
   the exhausted budget still blocks tool dispatch. Permission denial blocks a call even
   when other policies propose it; concurrent proposals cannot overspend a reservation.
4. Park for a human permission decision, restart, then accept or deny it. The same pending
   operation resumes, and a protected action still obtains fresh exact authorization.
   Revoking authority while parked prevents dispatch despite an earlier harness approval.
5. Change policy defaults and manifest configuration while a run is suspended. The run
   retains its recorded configuration; a fresh run uses the new admitted configuration.
   Corrupt or incompatible turn records fail with a bounded diagnostic before dispatch.
6. Resume a conversation in the middle of its Skill's model and tool exchanges. Completed
   exchanges are reused and one assistant reply is enqueued. Conversation rotation and
   transcript retention preserve all records still needed by live executions.
7. An uninterrupted fixture and its crash/resume variants reach equivalent logical
   outcomes and policy decisions. Operator inspection shows pending, completed, denied,
   cancelled, and unresolved work without leaking protected payloads. Old and new
   workflow populations pass the required evolution and conformance gates.

8. A UC-1 worker accepts a follow-up assignment, compacts earlier context, and resumes after
   a crash. Relevant accepted work, pinned execution settings, pending coordination messages,
   and shared usage/reservations are retained. A replayed coordination tool does not create
   another logical assignment, message, or ownership transfer.

## Scope boundary

This request concerns durable harness execution, not semantic memory recall, a general task
store, or arbitrary workflow scripting. It does not select an event store, require a new
framework dependency, promise token-by-token stream recovery, or grant new mutation tools.
Implementation should reuse existing durable infrastructure where its contracts fit and
keep the Flow capability boundary intact.

For UC-1, harness policies must compose with the root resource ledger owned by
[IR-16](support-adaptive-durable-orchestration.md), rather than maintaining resettable
per-worker counters as the sole authority. Follow-up turns and context compaction retain
that ledger's reservations and unknown usage. Accepted coordination operations use the
stable identities and reconciliation contract in
[IR-15](support-continuing-worker-sessions.md), and execution settings come from
[IR-17](select-governed-models-for-agent-runs.md). This request records and recovers those
operations; it does not independently define session mailboxes or adaptive scheduling.

## Related requests

- [IR-7](attest-sanctioned-agent-execution.md) supplies pinned execution profiles and
  correlated provider-call evidence; durable turn recovery must preserve that evidence.
- [IR-11](provide-governed-mutable-repository-workspaces.md) requests mutation tools whose
  recovery needs stable operation identity and an independent idempotency contract.
- [IR-12](compose-shikumi-decisions-in-durable-flows.md) concerns typed decision invocations
  in Flows. This request adds recovery and policy composition inside an interactive loop.
- [IR-13](support-optional-major-task-tracking.md) concerns progress across runs; harness
  execution records do not replace an authoritative major-task record.
