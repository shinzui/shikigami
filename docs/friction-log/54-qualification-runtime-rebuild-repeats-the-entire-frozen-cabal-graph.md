---
type: Friction Entry
title: "Qualification runtime rebuild repeats the entire frozen Cabal graph"
description: "The monolithic native qualification derivation recompiles all dependency packages after a fixture-only source change, delaying each Linux iteration."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-04T03:17:53Z"
frictionId: FRIC-54
status: logged
impact: slowdown
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/86-qualify-integrated-adaptive-autonomous-delivery.md"
---
# Qualification runtime rebuild repeats the entire frozen Cabal graph

## Attempted

Build the updated workspace-linux-fixture through the configured Nix remote builder with two cores after a local compile.

## Encountered

A fixture-only change started compiling the full frozen dependency graph rather than reusing compiled libraries.

```text
The Nix build log compiles postgresql-libpq, filelock and the other dependency libraries before reaching the changed fixture executable.
```
