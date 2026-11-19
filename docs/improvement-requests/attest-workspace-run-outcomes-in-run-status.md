---
type: Improvement Request
title: Attest run outcomes in run status
description: Let a declared workspace agent require a validated commit for success, never report succeeded for a run whose behavior says it stopped, such as a stopped playbook, and expose the outcome facts recorded by Shikigami itself on the public status response.
timestamp: "2026-11-11T18:18:36Z"
generated:
  by: process:claude-code
  at: "2026-11-18T23:58:00Z"
requestId: IR-22
status: proposed
origin: mori://shinzui/mori
---

# Attest run outcomes in run status

## Status

**Proposed; no implementation plan selected.** This request was raised by
`mori://shinzui/mori/masterplans/38-close-uc-2-with-constraint-aware-agent-driven-dependency-upgrades`,
which reviewed Shikigami at commit `86f31b08`. It is a hard gate on
`mori://shinzui/mori/plans/283-prove-agent-driven-dependency-upgrades-and-close-uc-2` and therefore
on `mori://shinzui/mori/okf/use-cases/concepts/UC-2`.

Widened on 2026-11-18 after a review of Shikigami at commit `1c98508d`. That review found a second way
for `succeeded` to hide a task that did not finish: a playbook that stops. The request now covers any
behavior whose own result says it stopped, not only workspace Skills. The workspace part is unchanged,
and the file name is kept so existing links resolve.

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
dependents.

Playbooks have the same gap, and there no model text is involved at all:

- `runPlaybook` in `shikigami-core/src/Shikigami/Playbook/Run.hs` returns an ordinary JSON value
  when a step stops the run. The value carries `"outcome": "stopped"` and a `stoppedBy` of `work`
  (for example a failed Tool or Probe step, or a declined approval) or `environment` (for example a
  missing helper or a ceiling refusal).
- The durable agent-run workflow runs a `Playbook` behavior like any other
  (`shikigami-core/src/Shikigami/Agent/Workflow.hs`, where the behavior dispatch admits `Playbook {}`),
  so that value is a normal behavior result. The workflow records and completes, and `classifyRun`
  reports `succeeded`.
- The only code that reads `stopped` is the learning step, which skips recording a lesson when
  `stoppedByEnvironment` holds. Nothing connects it to the run status.

So the playbook already knows it did not finish, and the public status says the opposite. [IR-11](provide-governed-mutable-repository-workspaces.md) asked for "structured terminal
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
5. Never report `succeeded` for a run whose behavior's own structured result says it did not finish.
   For a playbook that is `"outcome": "stopped"`. Such a run is `failed`, with a failure kind that
   tells a stop caused by the work (`stoppedBy: work`) from one caused by the machine
   (`stoppedBy: environment`); whether those are one kind with a detail member or two kinds is
   Shikigami's to choose. Expose the stopping step's declared key and `stoppedBy` on the status
   response, not the step's free-text summary. Apply the same rule to any later behavior kind that
   returns such a verdict, so the guarantee does not depend on which behavior a declaration uses.
   This should be the default, because a stopped playbook did not do its task. If the stability
   rules of the v1 baseline (ADR 133) require an opt-in, a declaration-level switch is acceptable.
6. Document the contract in `docs/user/http-api.md` and `docs/api/openapi.json`, including the new
   failure kinds and the response members. Existing workspace agents with no required outcome keep
   today's behavior and response, and the learning step's handling of environmental stops is
   unchanged.

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
8. A playbook run in which a Tool or Probe step fails, or an approval is declined, ends `failed`
   with the work-stop failure kind, and the status response names the stopping step's key.
9. A playbook run that stops because a required helper is missing ends `failed` with the
   environment-stop failure kind, and still records no learning.
10. A playbook run whose steps all complete ends `succeeded`, exactly as before.

## Dependencies and scope

This builds on the workspace receipts delivered by
[IR-11](provide-governed-mutable-repository-workspaces.md) and the status endpoint delivered by
[IR-10](expose-agent-run-status-over-http.md). It does not ask for publication of the commit, which
is [IR-23](publish-workspace-commits-to-the-source-repository.md), and it does not ask for HTTP
cancellation or callbacks. The playbook part needs no workspace and can be delivered on its own,
before or after the workspace part. The new failure kinds are additive enumeration values under the
v1 baseline's rules for the stable `http-api` surface. Mori will store the attested facts uninterpreted and keep gating on the
status alone.
