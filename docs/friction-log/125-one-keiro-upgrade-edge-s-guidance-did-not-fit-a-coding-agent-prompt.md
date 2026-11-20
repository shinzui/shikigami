---
type: Friction Entry
title: "One keiro-upgrade edge's guidance did not fit a coding-agent prompt"
description: "Seihou's guidance for meibo's keiro 0.19.0.1 to 0.20.0.0 edge is 65,261 bytes, so the apply prompt that quotes it would exceed the 64 KiB coding-agent prompt cap and stop batch B after three committed edges."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-20T02:10:00Z"
frictionId: FRIC-125
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "Found at the select-review gate, before any edge ran: the selection agent reported the edge at 63.7 KB, and rendering it in meibo measured 65,261 bytes."
resolution: "A coding-agent prompt holds at most 256 KiB, the same as a declared tool's kept output, and a playbook step's quoted output keeps as much. Baikai passes the prompt on standard input, so no argument limit applies."
tags:
  - "playbook"
  - "coding-agent"
  - "seihou"
---
# One keiro-upgrade edge's guidance did not fit a coding-agent prompt

## Attempted

Review batch B's blueprint selection for meibo (run 44500c5b-3407-5077-9d0a-4a6c3ef0fbe3):
nine keiro-upgrade edges from 0.16.0.0 to 0.25.0.0, one coding agent per edge.

## Encountered

The per-edge apply prompt quotes `{{steps.guidance.output}}` (the probe's `exit 0` line and
Seihou's rendered guidance) together with the template and `{{learnings}}`.

```text
seihou agent --debug migrate keiro-upgrade --from=0.19.0.1 --to=0.20.0.0   65261 bytes
seihou agent --debug migrate keiro-upgrade --from=0.24.0.0 --to=0.25.0.0   59284 bytes
```

`mkCodingAgentPrompt` refused anything over 65,536 bytes, a bound set when the coding-agent
step was introduced (d08cdbd8) with no stated reason. The 0.20 edge, which carries two
entailed kiroku edges, cannot be split further, so the run would have stopped there, by
its environment, after committing the 0.17 to 0.19 edges.

## Workaround

None needed: the gate waited while the bound was raised. A looser check admits every
prompt the old one did, so the paused run resumes on the new build.
