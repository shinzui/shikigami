---
type: Friction Entry
title: "The campaign quoted a whole multi-edge migration window into one 64 KiB coding-agent prompt"
description: "The keiro playbook's apply step embeds seihou's rendered guidance for the selected window, and koyomi's 0.22 to 0.25 window rendered 122 KB, so the step was refused after three operator approvals and the run ended."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-18T01:05:39Z"
frictionId: FRIC-112
status: logged
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "The select skill now emits one entry per release edge, the MasterPlan skill shares one ExecPlan across a blueprint's edges, and the implement step fixes only the current edge; a new run replaces the stopped one."
tags:
  - "playbook"
  - "coding-agent"
  - "seihou"
---
# The campaign quoted a whole multi-edge migration window into one 64 KiB coding-agent prompt

## Attempted

Approve koyomi's MasterPlan review; the run then rendered seihou agent --debug migrate keiro-upgrade --from=0.22.0.0 --to=0.25.0.0 into repos.0.modernize.blueprint-plans.0.apply.

## Encountered

repos.0.modernize.blueprint-plans.0.apply: a coding-agent prompt is at most 64 KiB (shikigami-core/src/Shikigami/CodingAgent/Types.hs). The guidance covers six edges, four of them entailed; per keiro edge it is 42775, 20882 and 58738 bytes, and it tells the agent to work only on the current edge. Nothing checks a rendered prompt's size before the run's approvals.

## Workaround

The select skill now emits one entry per release edge, the MasterPlan skill shares one ExecPlan across a blueprint's edges, and the implement step fixes only the current edge; a new run replaces the stopped one.
