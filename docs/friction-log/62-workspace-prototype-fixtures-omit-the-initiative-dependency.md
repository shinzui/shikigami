---
type: Friction Entry
title: "Workspace prototype fixtures omit the initiative dependency"
description: "The all-components build reaches stale workspace fixture constructors that predate the required initiative seed."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-05T13:20:41Z"
frictionId: FRIC-62
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/124-remove-handan-by-owning-the-shikumi-execution-adapter-in-shikigami.md"
workaround: "Supply the existing disabledInitiatives seed in both prototype fixture constructors, matching the other existing test environments."
resolution: "Both workspace prototype constructors now provide disabledInitiatives and the isolated all-components build passes."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-05T13:28:26Z"
    change: "Repaired the stale fixture constructors without enabling initiative behavior."
---
# Workspace prototype fixtures omit the initiative dependency

## Attempted

cabal build all using the committed isolated project and build/handan-removal.

## Encountered

Durable.hs omits the strict initiatives field of AgentRunDeps; the positional Adaptive.hs constructor shifts all later arguments for the same missing value.

```text
Durable.hs:154:11: Constructor Agent.AgentRunDeps does not have required strict field initiatives; Adaptive.hs:350 expects InitiativeSeed where declarations is supplied.
```

## Workaround

Supply the existing disabledInitiatives seed in both prototype fixture constructors, matching the other existing test environments.
