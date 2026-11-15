---
type: Friction Entry
title: "shikigami-agent launch tests hang under parallel tasty threads"
description: "LaunchSpec's fake-vendor tests read stdin to EOF, and with TASTY_NUM_THREADS=2 one test's spawned child holds the other test's stdin pipe open, so the suite hangs for its 600 s timeout."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-15T18:14:44Z"
frictionId: FRIC-75
status: logged
impact: slowdown
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/127-run-claude-code-and-codex-as-durable-harness-workers-inside-agent-runs.md"
workaround: "Run the shikigami-agent suite with TASTY_NUM_THREADS=1."
tags:
  - "tests"
---
# shikigami-agent launch tests hang under parallel tasty threads

## Attempted

TASTY_NUM_THREADS=2 cabal test shikigami-agent:test:shikigami-agent-test (EP-2 M1 validation)

## Encountered

'unattended executed nonzero exit passes through and ceiling refusal starts nothing' ran 605 s and failed; the fake vendor (cat >/dev/null) was still waiting; closing the suite's stdin did not help; TASTY_NUM_THREADS=1 passes all 39 in 0.93 s.

## Workaround

Run the shikigami-agent suite with TASTY_NUM_THREADS=1.
