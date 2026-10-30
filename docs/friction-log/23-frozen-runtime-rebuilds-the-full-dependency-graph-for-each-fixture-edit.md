---
type: Friction Entry
title: "Frozen runtime rebuilds the full dependency graph for each fixture edit"
description: "The single frozen runtime derivation recompiles hundreds of dependencies after a small Linux fixture edit, making each integration iteration take about thirty minutes on the configured builder."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-30T01:52:58Z"
frictionId: FRIC-23
status: logged
impact: slowdown
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "Explore the cached controller with a temporary fixture-only HTTP metadata correction while the corrected candidate builds; final acceptance still requires the corrected candidate."
---
# Frozen runtime rebuilds the full dependency graph for each fixture edit

## Attempted

Rebuild packages.x86_64-linux.shikigami-workspace-prototype after correcting fixture HTTP proof metadata.

## Encountered

Both completed candidates rebuilt the full frozen Cabal graph and took approximately thirty minutes, delaying native integration debugging.

```text
/tmp/shikigami-96-prototype-remote-build.log; /tmp/shikigami-96-prototype-final-remote-build.log
```

## Workaround

Explore the cached controller with a temporary fixture-only HTTP metadata correction while the corrected candidate builds; final acceptance still requires the corrected candidate.
