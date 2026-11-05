---
type: Friction Entry
title: "Workspace prototype fixtures omit the initiative dependency"
description: "The all-components build reaches stale workspace fixture constructors that predate the required initiative seed."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-05T13:20:41Z"
frictionId: FRIC-62
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/124-remove-handan-by-owning-the-shikumi-execution-adapter-in-shikigami.md"
workaround: "Supply the existing disabledInitiatives seed in both prototype fixture constructors, matching the other existing test environments."
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
