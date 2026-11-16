---
type: Friction Entry
title: "A coding agent refuses a local checkout whose file identity is longer than 128 characters"
description: "mkCodingAgentTarget capped the repository at 128 characters, so a playbook run on a local checkout under a long path could not launch any coding agent."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-16T03:07:28Z"
frictionId: FRIC-78
status: "resolved"
impact: blocked
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
tags:
  - "playbook"
  - "coding-agent"
resolution: "The repository field of a coding-agent target now allows up to 4096 characters; AuthoritySpec covers a 350-character file identity."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-16T03:07:36Z"
    change: "Status set to resolved."
---
# A coding agent refuses a local checkout whose file identity is longer than 128 characters

## Attempted

shikigami-agent-run --agent build-repair-agent.dhall --workspace <scratchpad>/build-fixture (a 125-character path)

## Encountered

The fix-build step failed before launch and the run stopped.

```text
coding-agent: coding agent failed: workspace unavailable: repository must be at most 128 characters
```
