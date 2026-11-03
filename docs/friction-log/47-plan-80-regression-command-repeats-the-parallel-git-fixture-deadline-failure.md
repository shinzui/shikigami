---
type: Friction Entry
title: "Plan 80 regression command repeats the parallel Git fixture deadline failure"
description: "The plan regression command ran real worker Git fixtures in parallel and exceeded their native deadlines, requiring the established serial qualification recipe."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-03T00:36:13Z"
frictionId: FRIC-47
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/80-configure-model-providers-and-agent-launches-through-baikai.md"
workaround: "Run database-backed suites sequentially with Cabal -j1 and --test-options=--num-threads=1; retain all production and fixture deadlines."
resolution: "Qualify real database-backed suites with Cabal -j1 and --num-threads=1; retain production and fixture deadlines and PostgreSQL connection limits. Plan 80 now specifies this established serial profile."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-03T00:38:07Z"
    change: "Corrected plan 80 regression commands after reproducing the earlier Git-fixture contention and parallel PostgreSQL too-many-clients failures; serial rerun is the accepted qualification path."
---
# Plan 80 regression command repeats the parallel Git fixture deadline failure

## Attempted

Run the plan 80 isolated-project core, agent, worker, server, PostgreSQL and migration suites together with default test concurrency.

## Encountered

WorkspaceGitProviderSpec reports GitReserved instead of GitApplied and receipt mismatches after approximately 32-35 seconds; FRIC-38 already documents the same cause in earlier qualification.

```text
WorkspaceGitProviderSpec.hs:369: expected GitApplied, but got GitReserved (34.08s)
```

## Workaround

Run database-backed suites sequentially with Cabal -j1 and --test-options=--num-threads=1; retain all production and fixture deadlines.
