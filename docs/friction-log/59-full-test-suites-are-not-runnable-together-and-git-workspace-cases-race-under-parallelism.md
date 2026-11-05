---
type: Friction Entry
title: "Full test suites are not runnable together and git workspace cases race under parallelism"
description: "Running the database suites through one cabal test invocation exhausts the shared ephemeral PostgreSQL, and WorkspaceGitProviderSpec has timing-sensitive cases that fail at four test threads but pass serially, so the plans' combined suite command cannot produce a clean result."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-05T01:36:34Z"
frictionId: FRIC-59
status: "accepted"
impact: slowdown
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami/plans/115-assess-candidates-with-a-registered-typed-decision-whose-output-cannot-select-repository-authority-or-recipient"
plan: "docs/plans/115-assess-candidates-with-a-registered-typed-decision-whose-output-cannot-select-repository-authority-or-recipient.md"
workaround: "run each suite alone, core postgres at four threads and the Git group of the workers suite at one thread"
resolution: "Run suites one at a time, core PostgreSQL at four threads and the Git group at one thread. Recurs FRIC-2, FRIC-5, FRIC-17 and FRIC-51; the plans should stop naming a combined command."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-05T02:59:27Z"
    change: "Status set to accepted."
---
# Full test suites are not runnable together and git workspace cases race under parallelism

## Attempted

Run all suites as the plan's Concrete Steps state

## Encountered

FATAL: sorry, too many clients already; then GitApplied expected but GitPublishRequested at four threads

## Workaround

run each suite alone, core postgres at four threads and the Git group of the workers suite at one thread
