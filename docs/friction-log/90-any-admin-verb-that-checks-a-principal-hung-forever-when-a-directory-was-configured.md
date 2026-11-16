---
type: Friction Entry
title: "Any admin verb that checks a principal hung forever when a directory was configured"
description: "The admin context ran the directory's periodic refresh loop as cleanup after its one liveness read, and that loop never returns, so proposals policy install never finished under directory.mode file."
generated:
  by: "claude-code/claude-fable-5-2"
  at: "2026-11-16T21:27:53Z"
frictionId: FRIC-90
status: logged
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/131-shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems.md"
workaround: "The cleanup is removed: startDirectory has already loaded the projection once. CommandSpec now checks that the principal check returns for a known and an unknown principal under a file directory."
tags:
  - "real-use"
---
# Any admin verb that checks a principal hung forever when a directory was configured

## Attempted

kikan-shikigami --config config.json proposals policy install --file policy.json --json, with a file directory.

## Encountered

No output and no row after five minutes; a sample showed the process idle in the event manager. adminContext.principalActive wrapped consultLifecycle in finally with directoryRuntime.refresher, which is refreshLoop, a forever loop a long-lived role supervises. The code predates the pack work. The policy tests pass a constant liveness check, so nothing exercised the real one.

## Workaround

The cleanup is removed: startDirectory has already loaded the projection once. CommandSpec now checks that the principal check returns for a known and an unknown principal under a file directory.
