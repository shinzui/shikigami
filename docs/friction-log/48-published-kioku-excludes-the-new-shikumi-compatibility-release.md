---
type: Friction Entry
title: "Published Kioku excludes the new Shikumi compatibility release"
description: "Kioku core 0.12.0.1 admits Baikai 0.10 but requires Shikumi below 0.5, blocking the released application closure after Shikumi 0.5 was published."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-03T02:17:48Z"
frictionId: FRIC-48
status: "resolved"
impact: blocked
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/kioku/packages/kioku-core"
affectedVersion: "0.12.0.1"
plan: "docs/plans/80-configure-model-providers-and-agent-launches-through-baikai.md"
resolution: "Published Kioku API/core/migrations 0.12.0.2 admits Shikumi 0.5 and Baikai 0.10; the full candidate application solve succeeds with Effectful 2.7 and its required strict-mutable-base 2.0 dependency."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-03T03:43:19Z"
    change: "Verified Hackage descriptors and v0.12.0.2 tag at 5a62c3ef29cad50543f7bae97126e0431225998d, then solved the application against the fixed 2026-11-03T02:59:02Z index without new bounds overrides."
---
# Published Kioku excludes the new Shikumi compatibility release

## Attempted

After verifying the released Shikumi family, solve base, baikai ==0.10.0.0, shikumi ==0.5.0.0 and kioku-core ==0.12.0.1 in an isolated project at index-state 2026-11-03T02:09:47Z without allow-newer or sibling sources.

## Encountered

The Baikai/Shikumi-only dry-run succeeds; adding Kioku fails Cabal-7107 because its published shikumi ^>=0.4.1.1 bound excludes 0.5.0.0.

```text
rejecting: kioku-core-0.12.0.1 (conflict: shikumi==0.5.0.0, kioku-core => shikumi^>=0.4.1.1)
```
