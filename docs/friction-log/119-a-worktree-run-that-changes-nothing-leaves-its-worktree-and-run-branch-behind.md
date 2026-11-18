---
type: Friction Entry
title: "A worktree run that changes nothing leaves its worktree and run branch behind"
description: "A separate-worktree run that commits nothing still leaves its git worktree under the state directory and its shikigami/<agent>/<id> branch in the operator's repository."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-18T04:39:54Z"
frictionId: FRIC-119
status: logged
impact: nuisance
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md"
workaround: "Left in place for the operator to remove (git worktree remove, git branch -D)."
tags:
  - "local-operator"
  - "worktree"
---
# A worktree run that changes nothing leaves its worktree and run branch behind

## Attempted

Run the read-only mori-status playbook and the repo-digest routine agent on kanmon (EP-11 M2 real runs).

## Encountered

git worktree list in kanmon: .local/state/shikigami/worktrees/shinzui-kanmon/63076b91cad2 [shikigami/mori-status/63076b91cad2] and …/767f7c09c54f [shikigami/repo-digest/767f7c09c54f], both at master's bec8597 with no commit of their own.

## Workaround

Left in place for the operator to remove (git worktree remove, git branch -D).
