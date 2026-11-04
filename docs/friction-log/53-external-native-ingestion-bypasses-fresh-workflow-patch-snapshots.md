---
type: Friction Entry
title: "External native ingestion bypasses fresh workflow patch snapshots"
description: "Delegated and session producers append ingestion before first execution, so new workflow patches are absent and associated child guards never run."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-03T23:33:46Z"
frictionId: FRIC-53
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md"
workaround: "Prepare the deployment patch set and first ingestion in one transaction under the native ingestion step lock; preserve any existing ingestion or patch snapshot."
resolution: "The Versioning owner atomically seeds deployment patches with first external native input through public lifecycle/ingestion locks; existing inputs and snapshots retain historical behavior, with three PostgreSQL regression cases."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-04T00:13:49Z"
    change: "Resolve fresh external ingestion patch loss for delegated, session and adaptive native children without rewriting historical snapshots."
---
# External native ingestion bypasses fresh workflow patch snapshots

## Attempted

Execute the adaptive Flow through real continuing-worker and AgentRun child producers.

## Encountered

The associated-session and objective-tracking patches evaluated false on newly admitted children because ingestion had already made their journals nonempty.

```text
AdaptiveWorkflowSpec: fresh assignment authority refused: Native worker objective association is unavailable; Keiro recordPatchSetIfFresh only seeds an empty generation.
```

## Workaround

Prepare the deployment patch set and first ingestion in one transaction under the native ingestion step lock; preserve any existing ingestion or patch snapshot.
