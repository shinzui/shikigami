---
type: Friction Entry
title: "keiro-gate refuses any uncommitted change under shikigami-core/src"
description: "just keiro-gate runs keiro-scaffold, which ends with git diff --exit-code over all of shikigami-core/src, so the gate cannot be run on a work-in-progress tree and reports an unrelated source diff as a stale generated layer."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-15T15:54:21Z"
frictionId: FRIC-73
status: logged
impact: slowdown
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md"
workaround: "commit first, then run just keiro-gate against the previous commit"
---
# keiro-gate refuses any uncommitted change under shikigami-core/src

## Attempted

Run just keiro-gate HEAD before committing the M1 refactor

## Encountered

keiro-scaffold: the committed generated layer is out of date; commit the regeneration, after printing the diff of hand-written Workspace/Provider.hs

## Workaround

commit first, then run just keiro-gate against the previous commit
