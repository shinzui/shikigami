---
type: Improvement Request
title: Provide governed mutable repository workspaces for durable agent runs
description: Let a declared durable agent resolve an operator-approved repository into an isolated worktree and use bounded read, edit, validation, and Git capabilities under exact per-action authorization, returning structured change evidence.
timestamp: "2026-09-20T20:31:12Z"
generated:
  by: process:codex
  at: "2026-09-20T20:31:12Z"
requestId: IR-11
status: proposed
origin: mori://shinzui/mori
---

# Improvement Request: provide governed mutable repository workspaces for durable agent runs

## Status

**Proposed.** This request supplies the execution capability needed by the agent-driven upgrade
portion of `mori://shinzui/mori/okf/use-cases/concepts/UC-2`. The existing one-off
`workspace.read` overlay is observation-only, is currently blocked by a deny-all authorizer, and is
not installed in the durable worker, whose capability runtime is empty. It therefore cannot bump a
dependency, repair a build, run validation, or commit a result.

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
2. Allocate one isolated worktree or equivalent sandbox per run, keyed by the stable run id. Two
   concurrent upgrades of one repository must not share mutable files or Git index state. Resume
   must find the same workspace, while terminal cleanup must be explicit, bounded, and recoverable.
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

## Non-goals

This request does not let an HTTP caller choose arbitrary host paths, expose an unrestricted shell,
store source-control credentials in agent payloads, merge directly to a protected branch, or make
instructions an authorization boundary. Opening a pull request or pushing a commit may be a later
sink or capability once its separate credentials and policy are defined; UC-2 can be proven with a
local committed fixture result.

## Dependencies

- `mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-8` supplies addressed durable
  runs and caller-owned idempotency.
- `mori://shinzui/kikan-en` supplies fresh exact action authorization for protected tools.
- `mori://shinzui/mori/okf/use-cases/concepts/UC-2` supplies the dependency-upgrade behavior and
  end-to-end acceptance scenario.
- `mori://shinzui/shikigami` project-relative
  `docs/adr/0036-external-agent-actions-require-fresh-exact-authorization.md` records the binding
  authorization rule. An artifact-level Mori URI is not currently registered.
