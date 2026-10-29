---
type: Friction Entry
title: "Full PostgreSQL suite exceeds shared fixture connection capacity"
description: "The default Tasty parallelism opens enough fixture pools to exceed the shared ephemeral PostgreSQL connection limit."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-29T17:39:02Z"
frictionId: FRIC-17
status: logged
impact: detour
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "Rerun the PostgreSQL suite with --test-options=-j2 and preserve its behavioral checks."
---
# Full PostgreSQL suite exceeds shared fixture connection capacity

## Attempted

Run cabal test shikigami-core-postgres-test --test-show-details=direct for the governed-workspace workflow change.

## Encountered

The first HTTP acceptance test failed with FATAL: sorry, too many clients already while other fixture tests ran concurrently.

```text
ConnectionUsageError: connection to shared ephpg-keiro Unix socket failed: FATAL: sorry, too many clients already
```

## Workaround

Rerun the PostgreSQL suite with --test-options=-j2 and preserve its behavioral checks.
