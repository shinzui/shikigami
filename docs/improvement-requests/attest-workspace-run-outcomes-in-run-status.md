---
type: Improvement Request
title: Attest workspace run outcomes in run status
description: Let a declared workspace agent require a validated commit for success, fail the run when that outcome is missing, and expose the commit and validation facts recorded by Shikigami's own tools on the public status response.
timestamp: "2026-11-11T18:18:36Z"
generated:
  by: process:claude-code
  at: "2026-11-11T18:18:36Z"
requestId: IR-22
status: proposed
origin: mori://shinzui/mori
---

# Attest workspace run outcomes in run status

## Status

**Proposed; no implementation plan selected.** This request was raised by
`mori://shinzui/mori/masterplans/38-close-uc-2-with-constraint-aware-agent-driven-dependency-upgrades`,
which reviewed Shikigami at commit `86f31b08`. It is a hard gate on
`mori://shinzui/mori/plans/283-prove-agent-driven-dependency-upgrades-and-close-uc-2` and therefore
on `mori://shinzui/mori/okf/use-cases/concepts/UC-2`.

## Problem and current coverage

Mori starts an upgrade run with `POST /agents/{agentName}/runs` and polls
`GET /agents/{agentName}/runs/{runId}` until the run is terminal. It releases the next wave of a
dependency-ordered cascade only when the status is `succeeded`. Mori does not read Shikigami's
database and does not interpret model text, so that status is the only signal it has.

Today the status does not say whether the upgrade worked.

- A Skill whose model ends its turn without a tool call returns normally
  (`shikigami-core/src/Shikigami/Behavior/Skill.hs`). The workflow records and completes, and
  `classifyRun` in `shikigami-core/src/Shikigami/AgentRun/Status.hs` reports `succeeded`.
- A validation command that exits non-zero is a tool result the model sees. Nothing connects it to
  the run status. `behavior_failed` arises only from infrastructure faults such as a provider
  error, the tool-turn limit, a timeout, or a refused step.
- `completeSession` in `shikigami-core/src/Shikigami/Agent/Workflow.hs` writes the constant
  summary `agent-run completed`. The status response carries no commit or validation fact.

So a model that runs a failing build and then stops produces `succeeded`, and Mori starts the
dependents. [IR-11](provide-governed-mutable-repository-workspaces.md) asked for "structured terminal
evidence from the run" in its sixth requested change. That evidence exists in workspace receipts and
tool results, but it does not reach the public status response or influence the status.

Shikigami's objective tools can record `CheckPassed` and `CheckFailed` evidence, readable over
HTTP. They do not solve this: the model asserts that evidence, and it does not change the run status.

## Requested change

1. Let an agent declaration, or its operator grant, name a required outcome for a workspace run. The
   minimum useful outcome is a commit made in the run's workspace plus one or more named validation
   rules that passed against that commit's exact tree.
2. Decide the outcome from what Shikigami's workspace tools recorded, at completion. A run that ends
   without meeting its required outcome is `failed`, whatever the model wrote. Give this its own
   failure kind, distinct from the four existing ones, so a caller can tell "the task did not work"
   from "the runtime broke".
3. A validation result counts only for the tree it ran against. An edit after the last passing
   validation, or a commit whose tree differs from the validated tree, does not meet the outcome.
4. Expose the attested facts on `GET /agents/{agentName}/runs/{runId}`, for both met and unmet
   outcomes: repository identity, base revision, commit id, parent, tree id, and each required
   validation rule with its exit status. Keep it bounded and free of command output, patches, tool
   inputs, and credentials.
5. Document the contract in `docs/user/http-api.md` and `docs/api/openapi.json`, including the new
   failure kind and the response members. Existing agents with no required outcome keep today's
   behavior and response.

The declaration syntax, member names, and failure-kind name are Shikigami's to choose.

## Acceptance

1. A workspace Skill with a required outcome, whose model runs a failing validation rule and then
   ends its turn normally, ends `failed` with the new failure kind.
2. The same Skill, whose model makes no commit, ends `failed` with the new failure kind.
3. The same Skill, whose model edits a file after its last passing validation and then commits, ends
   `failed`.
4. When the validation passes and the commit is made, the run ends `succeeded`, and the status
   response carries the commit id, parent, tree id, and validation result. The tree id equals the one
   `git` computes for the committed content.
5. None of the reported facts can be changed by model output. A scripted model that claims success in
   its final text does not alter cases 1 to 3.
6. An agent with no required outcome behaves and responds exactly as before.
7. The status response for a replayed or restarted run reports the same facts.

## Dependencies and scope

This builds on the workspace receipts delivered by
[IR-11](provide-governed-mutable-repository-workspaces.md) and the status endpoint delivered by
[IR-10](expose-agent-run-status-over-http.md). It does not ask for publication of the commit, which
is [IR-23](publish-workspace-commits-to-the-source-repository.md), and it does not ask for HTTP
cancellation or callbacks. Mori will store the attested facts uninterpreted and keep gating on the
status alone.
