---
type: Friction Entry
title: "The scheduler logs an error for every memory-session timer it does not own"
description: "The worker's timer fallback logs scheduler.timer.unknown_kind at error level for timers whose payload kind is final, idle or absent, which a healthy run produces."
generated:
  by: "claude-code/claude-fable-5-2"
  at: "2026-11-16T19:10:38Z"
frictionId: FRIC-87
status: logged
impact: nuisance
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/131-shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems.md"
tags:
  - "observability"
  - "real-use"
---
# The scheduler logs an error for every memory-session timer it does not own

## Attempted

Reading the worker log of the plan 131 M4 real run for the reason a run failed.

## Encountered

Each completed run left one or two scheduler.timer.unknown_kind error lines (timer_kind final, then null). The rows in keiro.keiro_timers carry memorySpaceId and turnCount, so they belong to the memory session's own timers, which share the table with the kinds shikigamiTimerFallback dispatches. The run was healthy; the error lines were the only errors in the log and pointed away from the real fault. One such timer was left in status firing.

```text
{"event":"scheduler.timer.unknown_kind","level":"error","timer_id":"14c1ed8a-...","timer_kind":"final"}
```
