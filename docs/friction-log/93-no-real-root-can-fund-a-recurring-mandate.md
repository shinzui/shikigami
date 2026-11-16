---
type: Friction Entry
title: "No real root can fund a recurring mandate"
description: "Shikigami.Mandate.Store.checkRoot refuses any root with an ExplicitlyUnbounded limit, while every route that enrolls a real root (the local one-off, initiative evaluation and standing-policy admission, the watchdog allowance) requires CostMicroUsd to be explicitly unbounded, so mandates create answers ObjectiveDenied for every root an operator can obtain."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-16T22:05:23Z"
frictionId: FRIC-93
status: "resolved"
impact: blocked
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/131-shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems.md"
resolution: "Shikigami.Mandate.Store.fundsRecurrence admits a root whose cost alone is unbounded when active work, attempts and tokens are finite (user decision 2026-11-16; ADR-121 amended); a real mandate cycle completed on a standing-policy root."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-16T22:32:17Z"
    change: "Triage at plan 131 completion: resolved."
---
# No real root can fund a recurring mandate

## Attempted

EP-6 M7: a kernel mandate cycle on a standing-policy objective's admitted root, as the operations guide describes

## Encountered

mandates create: objective command refused: ObjectiveDenied; a policy with a finite cost is refused at install: per-objective envelope must name ActiveWork, ModelAttempts, Tokens and an unbounded CostMicroUsd

```text
Mandate/Store.hs:160 requires every limit Limited; Initiative/Policy.hs:277, Initiative/Settings.hs:178, Watchdog/Settings.hs:76 and Agent/Command/AgentRun.hs:410 require or set CostMicroUsd ExplicitlyUnbounded
```
