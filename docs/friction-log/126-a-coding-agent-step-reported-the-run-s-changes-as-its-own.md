---
type: Friction Entry
title: "A coding-agent step reported the run's changes as its own"
description: "A coding-agent step measured its change summary and its no-change check from the commit the run opened the repository at, so later steps reported up to 200 files changed, and a step that changed nothing reported the previous step's commit as its own."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-20T15:30:00Z"
frictionId: FRIC-126
status: "resolved"
impact: cosmetic
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "Read each step's commit with `git show --stat` instead of trusting the step summary."
resolution: "A coding-agent step's base is the worktree's HEAD when the step starts, so its change summary and its no-change check cover only that step."
tags:
  - "coding-agent"
  - "local-operator"
---
# A coding-agent step reported the run's changes as its own

## Attempted

Review batch B's step summaries (run 44500c5b-3407-5077-9d0a-4a6c3ef0fbe3) before approving
meibo's and jinmyaku's close reviews.

## Encountered

```text
repos.0.modernize.close-plans   coding agent completed with exit 0, commit 6830863, 80 files changed
repos.1.modernize.fix-build     coding agent completed with exit 0, commit 7101d6c, 200 files changed
```

6830863 touches two files. jinmyaku's `fix-build` changed nothing: 7101d6c is the commit of
the EP-11 step before it. The local runner set a step's `base` to the run worktree's base, the
commit the run opened the repository at, and `changeSummary` and the no-change check in
`commitChanges` both compare with it. Every step after the first in a repository therefore
reported the run's whole diff (capped at 200 files), and a no-op step reported HEAD as its commit.

## Workaround

Checked each commit with `git show --stat`.
