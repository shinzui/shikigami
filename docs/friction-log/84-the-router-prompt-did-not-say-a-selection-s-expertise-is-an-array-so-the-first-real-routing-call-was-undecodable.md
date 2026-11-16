---
type: Friction Entry
title: "The router prompt did not say a selection's expertise is an array, so the first real routing call was undecodable"
description: "Shikigami.Flow.Routing named the expertise field without its shape, and a real model answered with a string that the RouteSelection decoder refuses on every resume."
generated:
  by: "claude-code/claude-fable-5-2"
  at: "2026-11-16T15:52:35Z"
frictionId: FRIC-84
status: logged
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/131-shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems.md"
workaround: "Commit 60938b9a changes the system prompt to say expertise is a non-empty JSON array of the candidate's expertise keys. The rerun routed and the specialist completed. A JSON-schema response format would remove the dependence on prompt wording."
tags:
  - "routing"
  - "real-use"
---
# The router prompt did not say a selection's expertise is an array, so the first real routing call was undecodable

## Attempted

Plan 131 M3 baseline: shikigami-worker with behavior.provider=openai and behavior.model=gpt-5.4-mini, then shikigami enqueue-run architecture-practice-router with a version-1 target-change trigger for mori://shinzui/fsrs-hs.

## Encountered

The model matched opentelemetry-practice-reviewer with high confidence and returned "expertise": "opentelemetry". The decision was journaled, the decoder failed on each of five resumes, and the run was marked failed. No test had exercised the router with a real model; every fixture supplies a hand-built decision.

```text
ResumeWorkflowMarkedFailed "shikigami.agent-run" "0161c772-f4b3-508e-970e-46218f186929" "RoutingDecisionDecodeFailed \"parsing [] failed, expected Array, but encountered String\""
```

## Workaround

Commit 60938b9a changes the system prompt to say expertise is a non-empty JSON array of the candidate's expertise keys. The rerun routed and the specialist completed. A JSON-schema response format would remove the dependence on prompt wording.
