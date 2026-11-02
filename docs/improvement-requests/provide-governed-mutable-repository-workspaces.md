---
type: Improvement Request
title: Provide governed mutable repository workspaces for durable agent runs
description: Let a declared durable agent resolve an operator-approved repository into an isolated worktree and use bounded read, edit, validation, and Git capabilities under exact per-action authorization, returning structured change evidence.
timestamp: "2026-11-02T19:57:20Z"
generated:
  by: process:codex
  at: "2026-10-11T03:04:54Z"
requestId: IR-11
status: completed
completedAt: "2026-11-02T19:57:20Z"
resolution: "Implemented by plan 96; all 25 native cases and final host checks pass, including real ownership receipt recovery, accepted successor effects and exact integrated artifacts."
targetPlan: docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md
origin: mori://shinzui/mori
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-21T18:03:06Z"
    document_timestamp: "2026-09-21T18:03:06Z"
    scope: catalog-metadata
    outcome: approved
    context: Audited lifecycle status and plan coverage against the current plans, master plans, Git history, and repository tree; the governed mutable-workspace capability remains unplanned and undelivered.
    provider: openai
    model: gpt-5.6-sol
    effort: high
---

# Improvement Request: provide governed mutable repository workspaces for durable agent runs

## Status

**In progress under [plan 96](../plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md).**
The configured durable worker now admits isolated workspaces, freezes scoped
repository instructions, applies governed edits, runs contained validation and
returns exact local commits. The fourteen-case native matrix proves the normal
parent/child upgrade across worker restart and independent file/process/Git
recovery. Operator listing and terminal cleanup are implemented. Concrete
workspace fencing, retained successor/followup authority and exact-artifact
integration planning pass the complete 22-case workspace-owned native matrix,
including exact combined-tree validation and a combined-only failure.
[Bounded native facts](../evidence/plan-96/native-workspace-facts.json) retain
the artifacts, statuses, follow-up ownership and fence. Production remains on
the qualified earlier adapter revisions until
native successor-write/handoff gates pass. Full reassignment acceptance remains
open alongside the separately owned real objective ownership provider from
[plan 99](../plans/99-supply-trusted-objective-associations-and-the-real-checkpoint-ownership-and-scope-providers.md).

This request supplies the execution capability needed by the agent-driven
upgrade portion of `mori://shinzui/mori/okf/use-cases/concepts/UC-2`. The original
one-off `workspace.read` overlay remains distinct and observation-only.

It also supplies repository execution for
[UC-1: Adaptive autonomous delivery](../use-cases/adaptive-autonomous-delivery.md).
[Plan 48](../plans/48-add-a-portable-one-off-repository-agent-harness.md) retains
unimplemented edit, command, sandbox, and executable milestones; its delivered read-only
slice in [plan 59](../plans/59-adopt-capability-overlays-in-the-portable-one-off-repository-harness.md)
does not implement this durable-run request. Plan 96 owns the complete durable mutable-workspace path.

[MasterPlan 14: Deliver adaptive autonomous objectives with durable workers](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md)
consumes this request as a separately owned prerequisite. [Plan 84: Coordinate continuing worker sessions and fenced handoffs](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md)
and [Plan 86: Qualify integrated adaptive autonomous delivery](../plans/86-qualify-integrated-adaptive-autonomous-delivery.md)
require real workspace fencing and integrated-revision evidence before their joint
acceptance can pass; they do not implement this workspace provider.
[Plan 78: Run external operations from durable Flows through idempotent shiki jobs](../plans/78-run-external-operations-from-durable-flows-through-idempotent-shiki-jobs.md)
is related external-executor work, not a selected mutable-workspace implementation.

## Context

An addressed Shikigami agent can receive Mori's release and workflow payload, but an instruction
alone does not grant access to the dependent repository. A dependency-upgrade agent needs a real,
isolated workspace and a bounded set of tools. Supplying a caller-controlled absolute directory or
an ambient current working directory would make the HTTP caller choose host filesystem authority,
allow concurrent runs to corrupt one checkout, and bypass Shikigami's declared capability and
per-action authorization model.

Shikigami already separates a declared capability catalog from runtime providers and requires a
fresh exact authorization decision immediately before protected external IO. The missing piece is
an operator-owned durable-run provider for repository work that preserves those boundaries.

## Requested Change

1. Introduce an operator-configured repository-workspace resolver. A run names a canonical project
   or repository identity plus an optional immutable starting revision; it never supplies a local
   absolute path. The operator configuration maps that identity to an allowed checkout source or
   worktree strategy and rejects unknown or ambiguous identities.
2. Allocate one isolated worktree or equivalent sandbox per admitted assignment, with a stable
   mapping from its run and continuing-session identities. A one-run upgrade can use its run id.
   Two concurrent assignments for one repository must not share mutable files or Git index state.
   Resume and authorized follow-up work must find the same workspace; terminal cleanup must be
   explicit, bounded, and recoverable. Session idleness alone is not permission to delete it.
3. Add declared capability overlays for the minimum repository operations needed by a coding
   agent: bounded read/search, structured file edits, process execution under an allowlisted and
   timeout-limited validation policy, and Git status/diff/commit operations. Exact names and tool
   grouping are Shikigami-owned; mutation must be distinct from the existing observation-only
   `workspace.read` capability.
4. Install the providers in the durable worker composition root. Merely defining tools in the
   one-off `shikigami-agent` executable does not satisfy this request.
5. Apply lifecycle admission, the declared capability overlay, and the fresh exact authorization
   contract before every protected operation. Authorization coordinates include the admitted agent
   principal, repository identity, base revision, operation, and resolved target. Missing or stale
   authorization fails closed without mutating the workspace.
6. Return structured terminal evidence from the run: repository identity, base revision, resulting
   revision when committed, changed paths, validation commands and statuses, and a bounded summary
   or failure reason. Credentials, full patches, tool inputs, and unrestricted command output do
   not enter workflow journals or logs.
7. Define recovery for abandoned worktrees and uncertain Git operations. An operator can list and
   clean terminal or orphaned workspaces without deleting an active run's state.
8. Support explicit ownership transfer and integration for coordinated coding assignments.
   Fence the former writer before admitting a successor and retain accepted changes and pending
   operation evidence. Let an authorized integrator combine revision-pinned worker artifacts in
   a separate workspace, expose conflicts, and rerun validation against the exact integrated
   source. Passing tests in separate worker trees does not qualify their combination.
9. Discover and apply repository instructions in each admitted workspace, including dependency
   lookup and commit/branch conventions. Persist the relevant instruction/configuration identity
   and report conflicts with parent instructions or operator policy; a child cannot expand
   filesystem authority through a repository file. Define bounded process cancellation and
   reconciliation when a validation command survives or has an uncertain result.

## Acceptance

1. Declare an upgrade agent with the mutation capability and address it with a canonical fixture
   repository, exact base revision, dependency name, and target version. The worker creates an
   isolated worktree, changes the constraint, runs the fixture build, and returns a commit plus
   structured validation evidence.
2. Run two upgrades for the same repository concurrently. They use distinct worktrees and Git
   indexes; neither observes the other's uncommitted files.
3. Address an unknown repository, an unapproved revision, a path outside the worktree, a symlink
   escape, a disallowed command, and an expired or denied authorization. Every case fails before the
   protected effect and records a bounded reason.
4. Redeliver one run job. Workflow replay reuses the journaled tool results and workspace identity
   rather than applying the same edit or commit twice.
5. Restart the worker during validation. The run resumes against the same isolated workspace and
   produces one terminal result.
6. A run without the declared mutation overlay receives no edit, process, or Git tools. The
   existing observation-only workspace behavior remains distinct and compatible.
7. Operator cleanup identifies an orphaned terminal fixture worktree, removes only that worktree,
   and refuses to remove a workspace owned by an active run.
8. Two UC-1 workers return exact revisions from isolated trees. An integrator combines them,
   reports any conflict, and runs the fixture's integration checks on the combined revision.
   The result records the worker bases/artifacts and actual integrated test statuses.
9. Reassign an existing workspace with a pending write and resume after a restart. The old
   owner cannot write after the handoff; accepted files and uncertain operations remain visible.
   A continuing idle worker's workspace is retained, and scoped repository instructions apply.

Implementation evidence (2026-11-02): [plan 96](../plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md)
completes this request with [25 native cases](../evidence/plan-96/joint-native-qualification.json) and
[full host qualification](../evidence/plan-96/host-qualification.json).
The evidence includes real objective ownership recovery after acknowledgement
loss and restart, accepted successor edits/validation in the original workspace,
post-establishment old-owner refusal, exact worker/integrated commits and
validation receipts, terminal cleanup, and frozen scoped instructions.
Consumer adaptive coordination and live coding trials remain separately owned.

## Non-goals

This request does not let an HTTP caller choose arbitrary host paths, expose an unrestricted shell,
store source-control credentials in agent payloads, merge directly to a protected branch, or make
instructions an authorization boundary. Opening a pull request or pushing a commit may be a later
sink or capability once its separate credentials and policy are defined; UC-2 can be proven with a
local committed fixture result.

## Dependencies

- [IR-8](expose-addressed-agent-runs-over-http.md) supplies public addressed runs and caller-owned
  idempotency for the external Mori scenario. A CLI-addressed or internally delegated UC-1 fixture
  can use the existing enqueue/delegation path and does not require that HTTP endpoint.
- [IR-14](record-durable-model-tool-turns-and-compose-harness-policies.md) supplies durable
  operation records and recovery within the model/tool loop; an observation descriptor or
  completed outer behavior step alone cannot protect repeated edits.
- [IR-15](support-continuing-worker-sessions.md) owns session interactions and ownership transfer;
  this request enforces the resulting workspace ownership at write boundaries.
- [UC-1](../use-cases/adaptive-autonomous-delivery.md) supplies the coordinated coding and
  integrated-result acceptance scenario without replacing Mori's dependency-upgrade scenario.
- `mori://shinzui/kikan-en` supplies fresh exact action authorization for protected tools.
- `mori://shinzui/mori/okf/use-cases/concepts/UC-2` supplies the dependency-upgrade behavior and
  end-to-end acceptance scenario.
- `mori://shinzui/shikigami` project-relative
  `docs/adr/0036-external-agent-actions-require-fresh-exact-authorization.md` records the binding
  authorization rule. An artifact-level Mori URI is not currently registered.
