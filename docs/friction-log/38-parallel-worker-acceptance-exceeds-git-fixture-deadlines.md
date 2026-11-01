---
type: Friction Entry
title: "Parallel worker acceptance exceeds Git fixture deadlines"
description: "The full worker suite runs Git acceptance fixtures concurrently and exceeds their five-second executor deadlines; the first failing control passes serially."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-01T14:04:40Z"
frictionId: FRIC-38
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/108-complete-the-remaining-domain-scalar-identity-and-decoder-audit.md"
workaround: "Run the full worker suite with --num-threads=1 while retaining production and fixture deadlines."
---
# Parallel worker acceptance exceeds Git fixture deadlines

## Attempted

Run the six runtime unit suites and domain suite with the Plan 108 final Cabal command.

## Encountered

Thirteen of 280 worker cases failed in the Git-provider group; the first passed alone in 2.00 seconds.

```text
Parallel: expected publication count 1, got 0 (23.89s); isolated --num-threads=1: All 1 tests passed (2.00s).
```

## Workaround

Run the full worker suite with --num-threads=1 while retaining production and fixture deadlines.
