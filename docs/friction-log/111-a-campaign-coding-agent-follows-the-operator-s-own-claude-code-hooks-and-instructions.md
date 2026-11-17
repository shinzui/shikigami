---
type: Friction Entry
title: "A campaign coding agent follows the operator's own Claude Code hooks and instructions"
description: "The readiness coding agent reported that it did not rename the Rex session because rex is not a permitted command, so the operator's user-level SessionStart hook and instructions reached an agent meant to see only the campaign's skill and declared tools."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T23:55:03Z"
frictionId: FRIC-111
status: logged
impact: nuisance
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "None needed for this run; the gate refused the command."
tags:
  - "coding-agent"
  - "isolation"
---
# A campaign coding agent follows the operator's own Claude Code hooks and instructions

## Attempted

Run the koyomi readiness coding agent through Claude Code under the campaign's gate.

## Encountered

Readiness report: 'Rex session: not renamed, because rex is not among the permitted commands.' The report also called its two edits 'uncommitted changes', though Shikigami commits them (071e89f).

## Workaround

None needed for this run; the gate refused the command.
