---
type: Friction Entry
title: "Plan test filters use a pattern syntax tasty refuses"
description: "ExecPlans 114-118 give test-options -p A|B filters, which tasty rejects as an invalid pattern, so every named acceptance command must be rewritten as an awk-style expression."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-05T01:02:36Z"
frictionId: FRIC-57
status: "accepted"
impact: nuisance
kind: documentation
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami/plans/114-bound-observation-with-observer-allowances-source-adapters-a-deterministic-pre-filter-and-the-proposal-ledger"
plan: "docs/plans/114-bound-observation-with-observer-allowances-source-adapters-a-deterministic-pre-filter-and-the-proposal-ledger.md"
workaround: "use --test-option=-p with an awk-style /A/||/B/ expression"
resolution: "The plans keep their original commands; the working form is recorded in plan 114 and the acceptance notes."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-05T02:59:25Z"
    change: "Status set to accepted."
---
# Plan test filters use a pattern syntax tasty refuses

## Attempted

Run the plan's cabal test group filter

## Encountered

option -p: Could not parse: A|B is not a valid pattern

## Workaround

use --test-option=-p with an awk-style /A/||/B/ expression
