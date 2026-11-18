---
type: Friction Entry
title: "Each migration edge pays for two cold coding-agent sessions and a redundant build probe"
description: "The keiro playbook splits every edge into separate apply and implement coding agents, the second re-reading the repository and plan, and then runs a build probe that the agents' own just check already covered."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-18T02:27:11Z"
frictionId: FRIC-113
status: "resolved"
impact: slowdown
kind: process
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "None in this run; candidate changes for EP-7 M4: one coding-agent step per edge, drop the per-edge build probe when the agent runs just check, and one review for a single-blueprint selection and its MasterPlan."
tags:
  - "playbook"
  - "performance"
resolution: "Fixed in a5f59a45 (corrects the previous resolution text): each blueprint edge is one coding agent (apply) that applies the guidance, fixes the fallout, records it in the ExecPlan and ends with just check; no separate build probe or fix-build agent follows it."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-18T12:29:03Z"
    change: "Status set to resolved."
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-18T12:29:13Z"
    change: "Status set to resolved."
---
# Each migration edge pays for two cold coding-agent sessions and a redundant build probe

## Attempted

Run koyomi's three keiro edges (run aa2b77a1-04e7-5384-8398-07b7e33947e0).

## Encountered

Per edge: apply about 10.5 min, implement about 2.5 min, build 3 s ('Up to date', because the agent had already built), fix-build 3 s. Wall time from readiness to modernize was 36 min, waiting on the approval (FRIC-105) and the operator; the later reviews took 3 and 7.5 min. A by-hand Claude Code session would do the same work in one continuous context.

## Workaround

None in this run; candidate changes for EP-7 M4: one coding-agent step per edge, drop the per-edge build probe when the agent runs just check, and one review for a single-blueprint selection and its MasterPlan.
