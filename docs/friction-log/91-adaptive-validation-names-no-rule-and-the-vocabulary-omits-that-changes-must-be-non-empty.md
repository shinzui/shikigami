---
type: Friction Entry
title: "Adaptive validation names no rule, and the vocabulary omits that changes must be non-empty"
description: "Coordination.Validate collapses every proposal shape rule into ObjectiveInvalid \"invalid adaptive proposal\", and the coordinator's vocabulary never says changes is non-empty, so a real model's empty-change proposal failed and finding why took a journal and source read."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-16T21:58:55Z"
frictionId: FRIC-91
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/131-shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems.md"
workaround: "State in the vocabulary that changes is never empty and that awaiting is one AwaitAssignments change"
resolution: "The coordinator vocabulary says changes holds one to 32 changes and awaiting is one AwaitAssignments change; three later real decisions were accepted. The validator's message still names no rule."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-16T22:32:14Z"
    change: "Triage at plan 131 completion: resolved for the vocabulary."
---
# Adaptive validation names no rule, and the vocabulary omits that changes must be non-empty

## Attempted

EP-6 M7 combined real session: a standing policy admitted a transcript proposal and launched adaptive-delivery

## Encountered

adaptive-validation journaled Left ObjectiveInvalid "invalid adaptive proposal"; the model had returned changes [] with laterEvidence combined-check, and Validate.hs line 58 requires not (null proposal.changes)

```text
child e079d1b2-edce-52a4-8853-75de443592ef: adaptive-validation {"Left": {"tag": "ObjectiveInvalid", "contents": "invalid adaptive proposal"}}
```

## Workaround

State in the vocabulary that changes is never empty and that awaiting is one AwaitAssignments change
