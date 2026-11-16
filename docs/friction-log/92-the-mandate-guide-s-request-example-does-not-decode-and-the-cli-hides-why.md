---
type: Friction Entry
title: "The mandate guide's request example does not decode, and the CLI hides why"
description: "docs/operations/recurring-objectives.md wrote scope as an array of strings while ObjectiveAssignmentId decodes only {\"value\": ...}, and readDocument in Shikigami.Server.Command.Objectives replaces the decoder's error with one fixed message."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-16T22:01:26Z"
frictionId: FRIC-92
status: "resolved"
impact: slowdown
kind: documentation
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/131-shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems.md"
workaround: "Read Mandate.Types and Objective.Keys; write scope as [{\"value\": \"deliver\"}]; the guide is corrected"
resolution: "docs/operations/recurring-objectives.md now writes scope as [{\"value\": ...}] and says so; the CLI still replaces the decoder's message."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-16T22:32:16Z"
    change: "Triage at plan 131 completion: resolved for the guide."
---
# The mandate guide's request example does not decode, and the CLI hides why

## Attempted

EP-6 M7: kikan-shikigami mandates create --file mandate.json written from the operations guide

## Encountered

invalid closed objective JSON document, with no field named

## Workaround

Read Mandate.Types and Objective.Keys; write scope as [{"value": "deliver"}]; the guide is corrected
