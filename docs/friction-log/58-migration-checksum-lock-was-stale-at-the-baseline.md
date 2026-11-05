---
type: Friction Entry
title: "Migration checksum lock was stale at the baseline"
description: "shikigami-migrations/sql-migrations/migrations.lock stopped at 0037 although the manifest reached 0042, so the migration integrity test was already failing before any initiative change and new-migration does not maintain the lock."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-05T01:10:05Z"
frictionId: FRIC-58
status: logged
impact: slowdown
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami/plans/114-bound-observation-with-observer-allowances-source-adapters-a-deterministic-pre-filter-and-the-proposal-ledger"
plan: "docs/plans/114-bound-observation-with-observer-allowances-source-adapters-a-deterministic-pre-filter-and-the-proposal-ledger.md"
workaround: "regenerated the whole lock from the manifest; entries 0001-0037 were unchanged"
---
# Migration checksum lock was stale at the baseline

## Attempted

Append the ledger migration and run shikigami-migrations-test

## Encountered

migration checksum lock differs from source payloads, for entries this plan did not add

## Workaround

regenerated the whole lock from the manifest; entries 0001-0037 were unchanged
