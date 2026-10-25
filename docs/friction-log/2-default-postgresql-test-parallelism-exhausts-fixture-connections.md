---
type: Friction Entry
title: "Default PostgreSQL test parallelism exhausts fixture connections"
description: "The core PostgreSQL suite inherits all CPU capabilities and starts enough isolated test pools to exceed the ephemeral server client ceiling."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-25T21:03:47Z"
frictionId: FRIC-2
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/75-persist-decision-call-evidence-across-retries-and-restarts.md"
workaround: "Run the PostgreSQL suite with --test-options=-j1 so only one isolated database fixture opens its pools at a time."
resolution: "Use --test-options=-j1 for the PostgreSQL suite; its isolated pools then fit within the ephemeral server connection ceiling."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-25T21:07:50Z"
    change: "Serial test scheduling passed all 208 PostgreSQL cases without changing the fixture server or application pools."
---
# Default PostgreSQL test parallelism exhausts fixture connections

## Attempted

cabal test shikigami-core-postgres-test --test-show-details=direct in the GHC 9.12.4 development shell

## Encountered

Multiple unrelated fixtures fail with FATAL: sorry, too many clients already while Tasty runs all tests concurrently.

```text
ConnectionUsageError (OtherConnectionError: FATAL: sorry, too many clients already)
```

## Workaround

Run the PostgreSQL suite with --test-options=-j1 so only one isolated database fixture opens its pools at a time.
