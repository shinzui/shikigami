---
type: Friction Entry
title: "Current baseline requires a cold native dependency cache"
description: "The plan 86 live adapter must rebuild the frozen Linux dependency cache for the current baseline before its consumer can run."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-09T05:51:32Z"
frictionId: FRIC-67
status: "resolved"
impact: slowdown
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/86-qualify-integrated-adaptive-autonomous-delivery.md"
workaround: "Keep application assembly serial and preserve the warmed dependency output for the final candidate."
resolution: "The current baseline dependency output is published and the final Linux candidate reuses it; this resolves this cache miss without changing the frozen solve."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-09T06:42:33Z"
    change: "Retain the completed immutable cache and passing final native fixture evidence."
---
# Current baseline requires a cold native dependency cache

## Attempted

nix build .#packages.x86_64-linux.shikigami-workspace-prototype --max-jobs 0 --cores 2 --no-link --no-write-lock-file --json

## Encountered

The current qualification dependency derivation is absent and recompiles the frozen dependency graph; after ten minutes the builder is still compiling dependencies, with 13 GiB free.

```text
The qualification-dependencies derivation began on the configured builder; five GHC processes were active during the ten-minute read-only process check.
```

## Workaround

Keep application assembly serial and preserve the warmed dependency output for the final candidate.
