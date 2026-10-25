---
type: Friction Entry
title: "Parallel PostgreSQL suite exhausts ephemeral connection capacity"
description: "The full core PostgreSQL test suite hits the ephemeral database connection limit with default concurrency."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-25T23:22:48Z"
frictionId: FRIC-5
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/88-serve-the-declared-agent-catalog-over-http.md"
workaround: "Rerun shikigami-core-postgres-test with --test-options=--num-threads=1."
resolution: "Run the full core PostgreSQL suite serially in this environment; all 225 tests then pass."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-25T23:24:02Z"
    change: "Serial execution verified the full suite without exceeding connection capacity."
---
# Parallel PostgreSQL suite exhausts ephemeral connection capacity

## Attempted

cabal test shikigami-core

## Encountered

40 of 225 tests failed, including FATAL: sorry, too many clients already.

## Workaround

Rerun shikigami-core-postgres-test with --test-options=--num-threads=1.
