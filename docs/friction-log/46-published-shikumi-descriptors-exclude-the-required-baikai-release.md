---
type: Friction Entry
title: "Published Shikumi descriptors exclude the required Baikai release"
description: "The published Shikumi family excludes Baikai 0.10 and prevents the plan 80 release-only adoption and TypeSafe consumer qualification."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-03T00:26:14Z"
frictionId: FRIC-46
status: logged
impact: blocked
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikumi/packages/shikumi"
affectedVersion: "0.4.1.1"
plan: "docs/plans/80-configure-model-providers-and-agent-launches-through-baikai.md"
---
# Published Shikumi descriptors exclude the required Baikai release

## Attempted

Resolve an isolated library depending only on base, baikai ==0.10.0.0 and shikumi ==0.4.1.1 with cabal build all --dry-run at index-state 2026-11-02T23:00:00Z after cabal update.

## Encountered

Cabal-7107 refuses the dependency pair; all six current published Shikumi descriptors retain the Baikai upper bound below 0.9. The local unreleased decision APIs cannot qualify the requested released consumer.

```text
rejecting: baikai-0.10.0.0 (conflict: shikumi => baikai>=0.8.0.0 && <0.9)
```
