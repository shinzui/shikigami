---
type: Friction Entry
title: "Keiro scaffold drift check includes hand-owned core edits"
description: "The keiro-scaffold recipe checks all core source changes rather than only generated files."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-25T23:35:11Z"
frictionId: FRIC-6
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/90-accept-addressed-agent-runs-over-http-with-server-owned-idempotency.md"
workaround: "Stage reviewed core edits before running the recipe, so git diff measures regeneration against the candidate index."
resolution: "Stage reviewed core source changes before the scaffold no-op check so it compares regeneration to the candidate index."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-25T23:36:59Z"
    change: "The complete keiro gate passes with zero durable-contract findings."
---
# Keiro scaffold drift check includes hand-owned core edits

## Attempted

just keiro-gate after the producer and ledger edits

## Encountered

keiro-scaffold rejects unchanged generation because git diff includes hand-owned Trigger.Enqueue and other core edits.

## Workaround

Stage reviewed core edits before running the recipe, so git diff measures regeneration against the candidate index.
