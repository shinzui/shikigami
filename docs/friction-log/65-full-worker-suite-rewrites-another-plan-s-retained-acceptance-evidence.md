---
type: Friction Entry
title: "Full worker suite rewrites another plan’s retained acceptance evidence"
description: "The default worker qualification suite overwrites a retained Plan 113 artifact with fresh fixture identities during unrelated regression runs."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-09T02:06:17Z"
frictionId: FRIC-65
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/87-supervise-recurring-objectives-from-current-durable-checkpoints.md"
workaround: "Restore the test-owned artifact from HEAD after the suite; retain recurrence results in Plan 87 evidence."
resolution: "Keep historical Plan 113 evidence unchanged after unrelated full worker runs; record this plan’s results separately. Artifact-writer opt-in is outside recurrence scope."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-09T02:07:02Z"
    change: "Accept the bounded artifact-restoration workaround for this implementation; all worker assertions passed."
---
# Full worker suite rewrites another plan’s retained acceptance evidence

## Attempted

Run the complete shikigami-workers-test regression suite for Plan 87.

## Encountered

WatchdogQualificationSpec rewrote docs/evidence/plan-113/acceptance.json despite this being a recurrence regression run.

## Workaround

Restore the test-owned artifact from HEAD after the suite; retain recurrence results in Plan 87 evidence.
