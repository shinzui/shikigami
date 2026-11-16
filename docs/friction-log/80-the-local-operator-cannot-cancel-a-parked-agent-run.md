---
type: Friction Entry
title: "The local operator cannot cancel a parked agent run"
description: "Neither shikigami-local nor shikigami-agent-run can cancel a run that waits on a durable wake, so an abandoned campaign run stays non-terminal and only declining a later approval would end it."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-16T03:08:08Z"
frictionId: FRIC-80
status: logged
impact: nuisance
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
tags:
  - "playbook"
  - "local-operator"
---
# The local operator cannot cancel a parked agent run

## Attempted

Stopping kizashi campaign run c4341273-0d66-516c-a51b-b840d26be160 after its keiro-upgrade apply step, to finish the work by hand

## Encountered

shikigami-local runs/approvals and shikigami-agent-run --help offer no cancel; resuming would launch the next coding agent in kizashi before any approval could be declined.
