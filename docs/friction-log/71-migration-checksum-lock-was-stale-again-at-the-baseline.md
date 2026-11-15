---
type: Friction Entry
title: "Migration checksum lock was stale again at the baseline"
description: "shikigami-migrations/sql-migrations/migrations.lock lacked 0049-recurring-mandates although the manifest listed it, so the migration integrity test failed before this plan's change; a recurrence of FRIC-58 because no migration recipe maintains the lock."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-15T15:54:17Z"
frictionId: FRIC-71
status: logged
impact: slowdown
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md"
workaround: "regenerated the lock from the manifest with shasum -a 256; entries 0001-0048 were unchanged"
---
# Migration checksum lock was stale again at the baseline

## Attempted

Append 0050-action-record and its lock line

## Encountered

the lock had 47 lines for a 48-entry manifest; 0049 had no checksum

## Workaround

regenerated the lock from the manifest with shasum -a 256; entries 0001-0048 were unchanged
