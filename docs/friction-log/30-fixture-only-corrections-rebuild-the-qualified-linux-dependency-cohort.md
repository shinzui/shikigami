---
type: Friction Entry
title: "Fixture-only corrections rebuild the qualified Linux dependency cohort"
description: "A correction confined to native fixture command keys still rebuilds the monolithic frozen dependency cohort before the follow-up qualification can resume."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-30T17:40:30Z"
frictionId: FRIC-30
status: logged
impact: slowdown
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "Batch the remaining controller changes into one candidate and retain the already qualified integration, fencing and host-wide evidence."
---
# Fixture-only corrections rebuild the qualified Linux dependency cohort

## Attempted

Build the corrected 20e8e80 Linux workspace prototype after a8614b2 completed and passed native integration and focused fencing.

## Encountered

The packaging boundary rebuilds external dependencies again despite unchanged product modules; no fixture-only incremental build output is available from the previously qualified runtime.

```text
/tmp/shikigami-96-final-native-build.log; external packages are recompiling for shikigami-workspace-prototype-0.1.0.0-20e8e80.
```

## Workaround

Batch the remaining controller changes into one candidate and retain the already qualified integration, fencing and host-wide evidence.
