---
type: Friction Entry
title: "A 100 ms judgment deadline test fails under full-suite load"
description: "TypeSafeDecisionSpec's 'application deadline bounds a stalled judgment' case uses a 100 ms deadline and failed twice in a full shikigami-core-test run but passed three of three runs alone, so a full-suite failure needs a rerun to tell it from a regression."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-15T15:54:19Z"
frictionId: FRIC-72
status: logged
impact: nuisance
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md"
workaround: "reran the case alone three times; it passed each time"
---
# A 100 ms judgment deadline test fails under full-suite load

## Attempted

Run the full shikigami-core-test suite after the authority refactor

## Encountered

2 out of 882 tests failed: expected 1 but got 0 call records at TypeSafeDecisionSpec.hs:350

## Workaround

reran the case alone three times; it passed each time
