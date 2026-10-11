---
type: Improvement Request
title: Add governed, versioned agent evolution to Shikigami
description: Control candidate agent artifacts from evaluation through approval, rollout, rollback, and audit.
timestamp: "2026-07-30T00:44:00Z"
generated:
  by: process:codex
  at: "2026-10-11T03:04:54Z"
requestId: IR-5
status: proposed
origin: mori://shinzui/kikan
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-21T18:03:06Z"
    document_timestamp: "2026-09-21T18:03:06Z"
    scope: catalog-metadata
    outcome: approved
    context: Audited lifecycle status and plan coverage against the current plans, master plans, Git history, and repository tree; no accepted Shikigami delivery plan currently fulfils this request.
    provider: openai
    model: gpt-5.6-sol
    effort: high
---

# Improvement Request: add governed, versioned agent evolution to Shikigami

**Authored by:** `shinzui/kikan` agents following the recursive self-improvement research note and
`mori://shinzui/kikan/okf/use-cases/concepts/UC-7`.
**Addressed to:** `shinzui/shikigami` agents, with `shinzui/shikumi` producing candidate artifacts
and evaluation reports, Mori resolving source identity, and Kotei executing builds and rollouts.
**Status:** proposed; required for use case 007.
**Contracts:** C1, C3, C5, C10, C11, and C13, plus proposed C16 and C17.
**Created:** 2026-07-26.


## Status

**Proposed; no implementation plan selected for governed agent evolution.**
[Plan 33: Agent schema evolution: identity, memory policy, and enablement](../plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md) delivered declaration identity, memory policy, and enablement.
Versioned behavior artifacts, optimizer governance, approval, shadow/canary rollout,
and rollback remain outside that completed plan's scope.

## Why

Shikigami can durably run declared behaviors, remember across runs through Kioku, deliver sinks through
an outbox, delegate child workflows, and resume Keiro workflows after failure. It cannot yet represent
or control the lifecycle of an improved agent behavior.

The canonical C5 declaration in `schema/Agent.dhall` has `name`, `description`, `trigger`, `behavior`,
and `sinks`. It does not identify the declaration revision or behavior artifact, declare which parts may
be optimized, pin runs to an immutable version, relate a candidate to its baseline, or express approval
and rollout policy. An operator therefore cannot answer “which behavior produced this run?” or keep a
baseline and candidate active simultaneously.

Shikigami's Durable Evolution MasterPlan solves a different problem: replay safety when the Haskell
implementation of a long-lived workflow changes. That work remains a prerequisite. This request adds
behavioral evolution driven by production evidence while preserving deterministic workflow replay.


## Requested model

### Immutable agent artifact

Introduce an immutable identity for the complete behavior resolved for one run. The wire representation
may differ, but it must carry the following information without relying on an ambient branch or mutable
path:

```text
agent name
agent version
declaration schema version
declaration digest
behavior kind
behavior artifact digest
source RepoRef when source-backed
tool-catalog digest
grounding-bundle refs and revisions
created-at and created-by principal
```

For a `ShikumiProgram`, the behavior artifact is the serialized `CompiledProgram` plus its structural
fingerprint and schema version. A run records the resolved artifact before behavior execution begins.
Replaying the run resolves that same artifact even if a newer version is now active.

Do not overload the current agent `name` as a version. Multiple immutable versions of one logical agent
must coexist during evaluation, shadowing, canarying, rollback, and old-workflow replay.


### Evolution policy

Extend the declaration or its deployment record with an optional policy that defines:

- the allowed mutation grade: memory, typed program parameters, declaration/skill, or source/runtime;
- the evidence window and minimum labeled sample count;
- the Shikumi optimizer and hard cost/candidate budget;
- required quality, safety, cost, and latency constraints;
- which dataset splits may be used for proposal, selection, and final comparison;
- the required approval grade and approving principal or group;
- shadow/canary cohort, observation duration, and maximum exposure;
- automatic rollback thresholds;
- cooldown, attempt, token, monetary, and concurrent-candidate limits.

Unknown policy fields, optimizer ids, mutation grades, artifact schemas, or metric ids fail closed.
Policy is configuration evaluated by trusted runtime code; a prompt cannot broaden it.


### Candidate lineage and lifecycle

Add a durable evolution aggregate with an idempotent state machine equivalent to:

```text
Proposed -> Evaluating -> Evaluated -> AwaitingApproval -> Approved
         -> Shadowing -> Canarying -> Promoted

Proposed/Evaluating/Evaluated/AwaitingApproval -> Rejected
Shadowing/Canarying/Promoted                    -> RolledBack
any non-terminal state                          -> Cancelled or Expired
```

Every state transition records the evolution id, logical agent, baseline version, candidate version,
parent lineage, evidence-dataset digest, evaluation-report digest, actor, authorization decision,
timestamp, reason, and distributed trace context. Repeated commands with the same idempotency key must
not create another candidate, optimizer job, approval, deployment, or rollback.

A candidate may be promoted only when its report was produced for the exact baseline, candidate,
dataset, metric policy, and artifact digests in the pending evolution. A report for one agent or one
dataset cannot authorize another promotion.


## Runtime behavior

### Version resolution

The trigger inbox resolves the active agent version once, journals it with the run request, and passes
that immutable reference through session creation, behavior execution, tool calls, sinks, memory writes,
and activity events. Activation of a newer version does not change an already accepted run.

Every output that can influence evaluation carries at least the logical agent, exact version, run id,
and trace id. This includes Kioku memories, Kawa activities, Kizashi signals, tool-call evidence, cost
records, and terminal outcomes.


### Proposal and evaluation

Shikigami requests a candidate from Shikumi by passing the baseline artifact, sealed training evidence,
metric policy, optimizer selection, and budget. Shikumi returns an immutable candidate artifact and a
separate evaluation report; it does not activate the candidate.

The first release permits automatic proposals only for the `ShikumiProgram` parameter surface:
instructions and demonstrations whose structural fingerprint matches the baseline. A structural change,
skill edit, tool-catalog change, source patch, or runtime patch must be rejected by this path.


### Approval and authorization

Promotion and rollback are checked actions, not ordinary model tools. Shomei proves the requesting and
approving principals; Kikan-En decides whether they may propose, approve, promote, pause, or roll back
the named agent and mutation grade. The proposer may not approve its own candidate unless an explicitly
ratified policy permits automatic promotion for that grade.

Approval uses Shikigami's durable approval machinery with a deadline and a complete comparison summary.
Expiry or an unavailable authorization service fails closed. A model-generated approval string has no
authority.


### Shadow, canary, promotion, and rollback

Shadow execution sends the same eligible input to the active and candidate versions but exposes only
the baseline's sinks. Candidate tool operations must be read-only or simulated unless separately
authorized. Canary execution exposes candidate effects only for the deterministic cohort selected by
policy.

Promotion atomically changes the active-version pointer without deleting the previous version. Automatic
rollback returns the pointer to the last known-good version when a deterministic policy threshold is
crossed. In-flight runs remain pinned to their resolved versions. Rollout and rollback jobs are delegated
to Kotei, but Shikigami owns the lifecycle decision and journals the resulting deployment identity.


## Self context

Expose a read-only, revision-pinned `SelfContext` to an agent and its operator. Mori supplies registered
identity and content discovery; Shikigami adds runtime state. It should include:

- the logical and active agent versions;
- declaration and behavior artifact refs;
- allowed mutation grade and current policy;
- tool and grounding catalogs;
- relevant source and documentation `RepoRef`s;
- recent evolution attempts and their terminal results;
- pause, budget, and rollout state.

This is navigation and introspection, not authority. Reading a source location does not grant permission
to edit or activate it.


## Evidence, memory, and audit behavior

Publish versioned lifecycle events for proposal, evaluation, approval, rejection, rollout, promotion,
rollback, cancellation, and expiry. Kawa/Kiroku retain the canonical organizational evidence outside the
agent workspace. Kioku may remember summaries and rejected-experiment lessons with provenance and
supersession links, but a memory cannot substitute for the lifecycle event or evaluation artifact.

Prompts, tool output, raw production evidence, credentials, and private examples must follow their
existing audience and retention rules. Promotion events include hashes and references, not an
unbounded copy of the dataset.


## Required tests

The implementation must add deterministic tests proving:

1. every accepted run remains pinned to its resolved version across activation and workflow replay;
2. the same evolution idempotency key creates at most one candidate and one external job;
3. a report with a mismatched baseline, candidate, dataset, policy, or digest cannot be approved;
4. proposal, approval, promotion, pause, and rollback permissions fail closed;
5. the first-release path rejects structural, skill, tool, source, and runtime mutations;
6. shadow candidate sinks are suppressed and canary exposure is bounded to the selected cohort;
7. a crash at each lifecycle transition resumes without repeating optimizer or deployment effects;
8. promotion retains the prior artifact and rollback restores it;
9. in-flight baseline and candidate runs complete under the versions they started with;
10. all run, memory, activity, cost, and outcome records carry the exact agent version;
11. canonical lifecycle history is unavailable for mutation from the agent workspace;
12. the complete use case 007 fixture improves the held-out metric and can be rolled back by a forced
    canary regression.


## Acceptance

With the use case 007 fixture running, an operator can select one deployed Shikumi-backed agent and
observe one evolution from sealed evidence to candidate. The console or CLI shows the baseline and
candidate artifacts, lineage, dataset digest, optimizer budget, comparison report, approval, rollout,
and active version. A deliberately corrupted report is rejected. An approved candidate enters shadow
and then canary service without duplicating baseline sinks. A forced regression restores the baseline,
while a healthy candidate becomes active. Replaying any earlier run uses its original artifact.


## Non-goals and sequencing

This request does not allow an agent to rewrite or restart the Shikigami runtime, push to a repository,
change its own authorization policy, approve its own high-grade mutation, train directly on a protected
holdout, or delete canonical history.

Land the replay-safety work from Shikigami MasterPlan 5 and the content-plane/`ToolEnv` prerequisites in
Kikan plan 29 before enabling evolution in production. The reusable sandbox/workspace provider is a hard
precondition for declaration, skill, source, tool, or runtime mutation, but not for the first immutable
compiled-parameter slice when optimization and evaluation execute in a sealed Kotei job.
