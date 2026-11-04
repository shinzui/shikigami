---
type: Friction Entry
title: "Continuing-worker child admission drops its objective association"
description: "The continuing-worker producer transports an objective only as prompt data, so a delegated local coordinator cannot acquire the objective-owned worker capability."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-03T22:47:19Z"
frictionId: FRIC-52
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md"
workaround: "Add an owner-verified association callback and a patch-gated associated-delegation path; preserve the original child-input branch for historical generations."
resolution: "Continuing-worker native admission now retains the exact child objective association before ingestion behind a compatible patch; the full adaptive hierarchy exercises a local coordinator and its descendants."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-04T00:13:43Z"
    change: "Resolve the child association gap through the native owner and qualify pinned descendant admission."
---
# Continuing-worker child admission drops its objective association

## Attempted

Run a permitted local coordinator with continuing-worker descendants through the accepted objective provider.

## Encountered

Agent.Delegate.delegateWith always sets childJob.objective to Nothing; WorkerSession.Workflow only puts the ObjectiveRef in triggerPayload, and Objective.Coordination requires an authoritative run association.

```text
shikigami-core/src/Shikigami/Agent/Delegate.hs: objective = Nothing; shikigami-core/src/Shikigami/WorkerSession/Workflow.hs: objective is passed only in payload
```

## Workaround

Add an owner-verified association callback and a patch-gated associated-delegation path; preserve the original child-input branch for historical generations.
