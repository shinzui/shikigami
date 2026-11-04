---
type: Friction Entry
title: "Resuming adaptive qualification rebuilds the frozen native graph"
description: "The monolithic Linux qualification derivation recompiles the frozen dependency cohort while resuming the unqualified adaptive fixture, delaying runtime feedback."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-04T05:47:53Z"
frictionId: FRIC-56
status: logged
impact: slowdown
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/86-qualify-integrated-adaptive-autonomous-delivery.md"
---
# Resuming adaptive qualification rebuilds the frozen native graph

## Attempted

nix build .#packages.x86_64-linux.shikigami-workspace-prototype --max-jobs 0 --cores 2 --no-link --no-write-lock-file --json at clean 64d9e4f4

## Encountered

The new source revision selects another whole-cohort derivation; after more than fifteen minutes it is still compiling dependency packages, before the adaptive consumer can run.

```text
Remote builder process inspection shows the openai-2.5.4 and rei-api-contract-0.2.0.0 GHC builds still active; no runtime output has been published.
```
