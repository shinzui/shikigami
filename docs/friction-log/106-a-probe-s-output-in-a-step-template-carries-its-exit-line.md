---
type: Friction Entry
title: "A probe's output in a step template carries its exit line"
description: "{{steps.start.output}} renders as 'exit 0\\n<sha>\\n', so the readiness approval reads 'It started at exit 0 6f792c7...; git reset --hard to that commit undoes it'."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T23:54:53Z"
frictionId: FRIC-106
status: logged
impact: nuisance
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "Read the commit out of the text by hand."
tags:
  - "playbook"
  - "templates"
---
# A probe's output in a step template carries its exit line

## Attempted

Read the koyomi readiness-review approval prompt.

## Encountered

Accept the readiness work in mori://shinzui/koyomi ...? It started at exit 0\n6f792c7d6e52e7d8fe67e58887e2f6da4d83d7b8\n; `git reset --hard` to that commit undoes it.

## Workaround

Read the commit out of the text by hand.
