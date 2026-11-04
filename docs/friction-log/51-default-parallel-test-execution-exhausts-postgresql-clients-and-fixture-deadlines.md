---
type: Friction Entry
title: "Default parallel test execution exhausts PostgreSQL clients and fixture deadlines"
description: "Running the prescribed test suites with their default Tasty concurrency exhausted disposable PostgreSQL connections and delayed time-bounded Git fixtures."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-03T20:23:45Z"
frictionId: FRIC-51
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md"
workaround: "Run database and worker suites sequentially with TASTY_NUM_THREADS=2, preserving the required cases."
resolution: "Run broad PostgreSQL and worker suites sequentially with TASTY_NUM_THREADS=2; this bounds disposable connections and fixture scheduling on the development host."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-04T00:13:37Z"
    change: "Document and accept the qualified local test concurrency; the bounded suites pass."
---
# Default parallel test execution exhausts PostgreSQL clients and fixture deadlines

## Attempted

nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-core-postgres-test shikigami-workers-test shikigami-server-test --test-show-details=direct

## Encountered

Baseline core PostgreSQL tests reported eleven failures including too many clients already; worker Git fixtures also missed their bounded receipt windows under the concurrent suite load.

```text
FATAL: sorry, too many clients already; expected GitApplied but got GitReserved
```

## Workaround

Run database and worker suites sequentially with TASTY_NUM_THREADS=2, preserving the required cases.
