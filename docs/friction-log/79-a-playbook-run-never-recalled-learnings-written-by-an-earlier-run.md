---
type: Friction Entry
title: "A playbook run never recalled learnings written by an earlier run"
description: "runPlaybook recalled with the keyword query NAME, which kioku's all-words keyword search matched only in run-outcome memories, so the tag filter left nothing and every run started with no learnings."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-16T03:07:30Z"
frictionId: FRIC-79
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "None needed after the fix; EP-4 had shown only learnings passed within one run."
tags:
  - "playbook"
  - "memory"
resolution: "The learnings memory is headed 'Learnings of playbook NAME' and recalled by that header; the build-repair runs showed the second run quoting the first run's learnings."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-16T03:07:37Z"
    change: "Status set to resolved."
---
# A playbook run never recalled learnings written by an earlier run

## Attempted

Two runs of agents/playbooks/build-repair-agent.dhall; the second run's fix-build prompt should quote the first run's three learnings

## Encountered

The second run printed 'recalled 3 prior memories' and its prompt said '(no learnings yet)'; the learnings memory (tags playbook, build-repair) existed in kioku.memories.

## Workaround

None needed after the fix; EP-4 had shown only learnings passed within one run.
