---
type: Friction Entry
title: "A run kept the in-place lock of every other repository it worked in"
description: "A playbook run released only its own repository's in-place lock when its process ended, so after batch A stopped, danwa stayed locked by the finished run and a new run on danwa was refused."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-19T00:30:00Z"
frictionId: FRIC-123
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "Removed ~/.local/state/shikigami/locks/shinzui-danwa.lock after checking that its holder, run 1290d348, had finished."
resolution: "The local operator tier records every worktree a run opens in another repository and releases each with the run's own when the process ends, as it already did for the run's repository."
tags:
  - "local-operator"
  - "playbook"
  - "workspace"
---
# A run kept the in-place lock of every other repository it worked in

## Attempted

Start keiro-modernization on danwa alone (workspace `mori://shinzui/danwa`) after batch A's
run 1290d348-df05-547e-9578-4862f762034a had stopped at danwa's readiness review (FRIC-122).

## Encountered

```text
agent-run: another run (1290d348-df05-547e-9578-4862f762034a) holds this checkout
```

The finished run's `release` called `releaseRunWorktree` for keiei's worktree only. danwa's
in-place worktree, opened for the run's danwa steps, kept its lock file.

## Workaround

Removed the lock file after checking that its holder had finished.
