---
type: Friction Entry
title: "Authorization tests share a process-global model provider key"
description: "Parallel core tests collide in the global model provider registry, causing the dynamic authorization fixture to miss its invocation check."
generated:
  by: "codex-cli/gpt-6-astra"
  at: "2026-10-28T20:17:44Z"
frictionId: FRIC-15
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "Give typed and dynamic fixtures distinct provider registry keys"
resolution: "Typed and dynamic authorization tests now use distinct provider keys; all 511 core tests pass with default parallelism."
amended:
  - by: "codex-cli/gpt-6-astra"
    at: "2026-10-28T20:18:06Z"
    change: "Isolate authorization fixture registry keys and verify the parallel core suite"
---
# Authorization tests share a process-global model provider key

## Attempted

Run the full shikigami-core-test suite after catalog admission changes

## Encountered

Dynamic callback is denied observed ConnectCapability without InvokeCapabilityTool; all 511 tests pass serially

## Workaround

Give typed and dynamic fixtures distinct provider registry keys
