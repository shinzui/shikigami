---
type: Friction Entry
title: "workers integration test fails under parallel tasty threads"
description: "WorkspaceWorkflowSpec 'accepted integration combines two retained worker artifacts in a third clean workspace' fails with 'expected successful integration' when the workers suite runs with TASTY_NUM_THREADS=2, and passes alone."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-15T19:05:14Z"
frictionId: FRIC-76
status: "accepted"
impact: slowdown
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/127-run-claude-code-and-codex-as-durable-harness-workers-inside-agent-runs.md"
workaround: "Rerun the failing case alone with TASTY_NUM_THREADS=1."
tags:
  - "tests"
resolution: "Likely cause: WorkspaceGitProviderSpec's withIntegration reserves the fixed identity range 62002-62020 for every case, so two cases running at once collide. The 'workspace accepted Git provider' group fails at TASTY_NUM_THREADS=2 and passes at 1 (17/17). Rerun it singly until the fixture allocates per case."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-15T19:12:34Z"
    change: "Status set to accepted."
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-15T19:24:50Z"
    change: "Recorded the likely cause and the group-level reproduction."
---
# workers integration test fails under parallel tasty threads

## Attempted

TASTY_NUM_THREADS=2 cabal test shikigami-workers:test:shikigami-workers-test (EP-2 M1 and M2b validation)

## Encountered

1 of 354 failed twice in the full suite; the same test passes in about 12 s with TASTY_NUM_THREADS=1 and a pattern.

## Workaround

Rerun the failing case alone with TASTY_NUM_THREADS=1.
