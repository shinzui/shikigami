---
type: Friction Entry
title: "Joint successor qualification waits for a cold frozen runtime build"
description: "The Linux qualification derivation recompiles the frozen dependency cohort after controller and worker changes, delaying the real ownership gate beyond the completed host checks."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-02T18:31:55Z"
frictionId: FRIC-43
status: logged
impact: slowdown
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
---
# Joint successor qualification waits for a cold frozen runtime build

## Attempted

bash tests/workspace/run-apple.sh --qualify on candidate 8d1ee35e

## Encountered

The configured remote builder stages the complete frozen cohort and rebuilds the monolithic runtime; the native fixture cannot start until that output is available.

```text
Host build, all Cabal tests, Nix checks and the workflow gate pass while /tmp/shikigami-workspace-run.fbQWG9/build.log remains in the remote runtime build.
```
