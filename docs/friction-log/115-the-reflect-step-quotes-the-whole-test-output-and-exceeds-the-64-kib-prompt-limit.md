---
type: Friction Entry
title: "The Reflect step quotes the whole test output and exceeds the 64 KiB prompt limit"
description: "The keiro playbook's Reflect prompt embeds {{steps.tests.output}}, and koyomi's 178 KB test output made the step refuse, so the second repository's run recorded no learnings."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-18T02:47:32Z"
frictionId: FRIC-115
status: logged
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "None for this run; the reflect prompt must summarize or omit large step outputs."
tags:
  - "playbook"
  - "reflect"
  - "coding-agent"
---
# The Reflect step quotes the whole test output and exceeds the 64 KiB prompt limit

## Attempted

Approve koyomi's close review; the run then started repos.0.modernize.reflect.

## Encountered

stopped repos.0.modernize.reflect: a coding-agent prompt is at most 64 KiB. learnings: [], proposal: null. FRIC-112 is the same limit hit by blueprint guidance.

## Workaround

None for this run; the reflect prompt must summarize or omit large step outputs.
