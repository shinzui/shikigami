---
type: Friction Entry
title: "Workspace placement cannot be chosen at the grant prompt or declared by a campaign"
description: "Placement comes only from the approvals file's repositories entry and defaults to a separate worktree, though the keiro campaign requires in-place work on each repository's current branch."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T23:54:48Z"
frictionId: FRIC-103
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "Wrote ~/.config/shikigami/local-operator.dhall placing the six campaign repositories InPlace, with no agent approvals; cancelled and relaunched the prompt."
tags:
  - "local-operator"
  - "placement"
resolution: "Fixed in 77c7fb39: shikigami-local grant --placement in-place|separate-worktree chooses where a declaration works on a repository, a run works under its grant's placement (before, the stored placement was never read), and approvals and doctor show each grant's placement. A declaration does not choose its placement: that stays the operator's decision about their checkout."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-18T21:25:00Z"
    change: "Status set to resolved."
---
# Workspace placement cannot be chosen at the grant prompt or declared by a campaign

## Attempted

Confirm the keiro-modernization grant for koyomi.

## Encountered

The prompt showed 'placement separate worktree on a run branch' with no way to change it. ~/.config/shikigami/local-operator.dhall did not exist on this machine, though kizashi had run in place on 2026-11-15.

## Workaround

Wrote ~/.config/shikigami/local-operator.dhall placing the six campaign repositories InPlace, with no agent approvals; cancelled and relaunched the prompt.
