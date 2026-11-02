---
type: Friction Entry
title: "Migration scaffolder refuses the existing manifest gap"
description: "The new-migration recipe requires contiguous filenames while the checked-in manifest intentionally skips 0002, so it cannot scaffold an additive migration."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-02T03:10:40Z"
frictionId: FRIC-39
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/99-supply-trusted-objective-associations-and-the-real-checkpoint-ownership-and-scope-providers.md"
workaround: "Validate monotonic migration filenames and allocate above the greatest existing number, preserving deployed manifest identities."
resolution: "The scaffolder accepts strictly increasing historical filenames and allocates above the highest existing number; the requested 0035 migration was generated successfully without renumbering."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-02T03:18:40Z"
    change: "Fix migration scaffolding to preserve deployed filename gaps."
---
# Migration scaffolder refuses the existing manifest gap

## Attempted

just new-migration objective-conversation-admissions

## Encountered

The recipe stopped before writing the migration because the existing second manifest entry is 0003.

```text
error: expected migration 0002-<slug>.sql, got 0003-sink-grants.sql
```

## Workaround

Validate monotonic migration filenames and allocate above the greatest existing number, preserving deployed manifest identities.
