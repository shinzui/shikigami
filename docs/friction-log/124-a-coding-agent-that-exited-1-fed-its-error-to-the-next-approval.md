---
type: Friction Entry
title: "A coding agent that exited 1 fed its error to the next approval"
description: "When the Claude login expired, batch B's blueprint selection agent exited 1, the step counted as completed, and the select-review gate asked the operator to run a selection that was only the authentication error."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-19T23:50:00Z"
frictionId: FRIC-124
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "Rejected the gate, which ended run f2dac461, logged in again with `claude auth login`, and started batch B again."
resolution: "A coding-agent step whose agent exits nonzero stops the run with the agent's first line as the reason, and a local run's preflight (and `shikigami-local doctor`) checks that the vendor CLI is logged in."
tags:
  - "playbook"
  - "coding-agent"
  - "preflight"
---
# A coding agent that exited 1 fed its error to the next approval

## Attempted

Resume keiro-modernization batch B (run f2dac461-0743-556d-9e88-e8e47cc6de17) after
approving meibo's readiness review.

## Encountered

The `select` coding agent exited 1 without a change:

```text
coding-agent: coding agent completed with exit 1, no change from 77bfbee, 0 files changed
Run f2dac461-0743-556d-9e88-e8e47cc6de17 waits for approval:
  shikigami-local approvals resolve review_17da48c0-4108-55f3-afc2-35432192cfd2    # Run these blueprints in mori://shinzui/meibo?

Failed to authenticate: this login reached its time limit and cannot be renewed. Run `claude auth login` to sign in again, ...
```

The playbook runner treated any agent that ran to an end as a completed step, whatever
its exit code, so `{{steps.select.output}}` was the error. A run cannot retry a step, so
the only correct answer was to reject the gate and end the run. Preflight had not caught
it: it checked that `claude` was on `PATH` but not that it was logged in, and
`claude auth status` exits 0 either way.

## Workaround

Rejected the gate, logged in again and started a new run. meibo's readiness work was
already committed, so the new run's readiness step had nothing left to do.
