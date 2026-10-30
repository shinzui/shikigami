---
type: Friction Entry
title: "Normal workflow qualification waits for a complete runtime rebuild"
description: "The normal parent-child Linux fixture change rebuilds the monolithic frozen dependency graph, delaying its first native run by more than fifteen minutes."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-30T13:30:36Z"
frictionId: FRIC-26
status: logged
impact: slowdown
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "Continue the independent terminal cleanup implementation and native C qualification while the committed workflow candidate builds."
---
# Normal workflow qualification waits for a complete runtime rebuild

## Attempted

Run bash tests/workspace/run-apple.sh --workflow for commit 4941dab.

## Encountered

The configured remote builder rebuilds the full frozen runtime rather than reusing dependency build products; native fixture execution has not started after fifteen minutes.

```text
/tmp/shikigami-workspace-run.cG0nUZ/build.log; runtime derivation shikigami-workspace-prototype-0.1.0.0-4941dab
```

## Workaround

Continue the independent terminal cleanup implementation and native C qualification while the committed workflow candidate builds.
