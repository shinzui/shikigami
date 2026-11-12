---
type: Friction Entry
title: "Reviewed schema snapshot omits recurring mandate tables"
description: "Migration smoke stopped released-cohort regression because the expected schema omitted objects already created by migration 0049."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-12T19:19:30Z"
frictionId: FRIC-68
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/80-configure-model-providers-and-agent-launches-through-baikai.md"
workaround: "Verify additions against migration 0049 and regenerate expected-schema.txt with the native fixture before rerunning smoke."
resolution: "Regenerated the reviewed snapshot using the native migration fixture, verified its 34 additions against migration 0049, rebuilt the embedded verifier and passed all 11 smoke checks."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-12T19:21:06Z"
    change: "Resolve stale expected schema after native regeneration and full smoke acceptance."
---
# Reviewed schema snapshot omits recurring mandate tables

## Attempted

Run the serial released-cohort migration smoke suite.

## Encountered

Fresh schema comparison reported unexpected mandates, mandate_receipts and mandate_cycles objects.

```text
UnexpectedObject column mandate_cycles.cycle bigint not null; UnexpectedObject table mandates kind=r
```

## Workaround

Verify additions against migration 0049 and regenerate expected-schema.txt with the native fixture before rerunning smoke.
