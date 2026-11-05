---
type: Friction Entry
title: "Concurrent dependency edits invalidate ambient qualification"
description: "Concurrent edits to shared dependency inputs caused a second ambient reconfiguration and require isolated committed-source validation."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-05T13:14:32Z"
frictionId: FRIC-61
status: logged
impact: detour
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/124-remove-handan-by-owning-the-shikumi-execution-adapter-in-shikigami.md"
workaround: "Stage only Handan-removal hunks in shared files and qualify the committed project in a fresh isolated build directory; preserve the independent edits for reconciliation."
---
# Concurrent dependency edits invalidate ambient qualification

## Attempted

Run the focused and full core suites before the final isolated solve.

## Encountered

Another session changed the Biscuit source pin, Mori declarations and frozen cohort while the first build was running; the next ambient command selected the new pin and recompiled dependents.

## Workaround

Stage only Handan-removal hunks in shared files and qualify the committed project in a fresh isolated build directory; preserve the independent edits for reconciliation.
