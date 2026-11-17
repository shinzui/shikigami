---
type: Friction Entry
title: "Playbook runs report a stub model provider and an unexplained minute budget"
description: "Every playbook run logs 'model provider: STUB - no model will be called', which does not apply to its Claude Code steps, and the grant prompt's '60 minutes' does not say it is the resource root's cutoff for model and tool executions."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T23:54:55Z"
frictionId: FRIC-107
status: logged
impact: nuisance
kind: documentation
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "Read the source to judge whether a multi-hour run would hit the cutoff."
tags:
  - "playbook"
  - "local-operator"
  - "logging"
---
# Playbook runs report a stub model provider and an unexplained minute budget

## Attempted

Confirm and run the koyomi campaign.

## Encountered

behavior.provider.selected provider=stub on each launch; budget 30 model attempts, 120 tool attempts, 3000000 tokens, 60 minutes. Its meaning was found only in grantEnvelope (shikigami-agent/src/Shikigami/Agent/Command/AgentRun.hs).

## Workaround

Read the source to judge whether a multi-hour run would hit the cutoff.
