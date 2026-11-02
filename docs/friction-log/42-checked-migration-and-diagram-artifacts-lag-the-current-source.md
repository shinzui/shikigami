---
type: Friction Entry
title: "Checked migration and diagram artifacts lag the current source"
description: "The final host suite found pre-existing checksum lock, schema snapshot and lifecycle atlas drift after the objective migrations, requiring regeneration before qualification."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-02T18:24:43Z"
frictionId: FRIC-42
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "Regenerate the checked artifacts using the repository commands, inspect their changes against current source, then rerun the failed suites."
---
# Checked migration and diagram artifacts lag the current source

## Attempted

nix develop --no-write-lock-file -c cabal test all --test-options=-j2 --test-show-details=direct

## Encountered

Migration integrity reports migration checksum lock differs from source payloads; the schema smoke test reports unreviewed objective tracker tables; the lifecycle diagram test reports atlas drift.

```text
Two migration definition cases, one schema snapshot case and the lifecycle atlas drift check fail with no migration or core-source changes in this implementation.
```

## Workaround

Regenerate the checked artifacts using the repository commands, inspect their changes against current source, then rerun the failed suites.
