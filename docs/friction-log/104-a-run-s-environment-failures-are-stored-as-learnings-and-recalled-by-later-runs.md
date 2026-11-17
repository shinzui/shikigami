---
type: Friction Entry
title: "A run's environment failures are stored as learnings and recalled by later runs"
description: "Each failed koyomi launch recorded its step failure (for example 'shikigami-local: createProcess: execvp: does not exist') as a Kioku memory, and the next run recalled it as a prior memory of the campaign."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T23:54:50Z"
frictionId: FRIC-104
status: logged
impact: slowdown
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "None yet; the memories remain."
tags:
  - "kioku"
  - "learnings"
  - "playbook"
---
# A run's environment failures are stored as learnings and recalled by later runs

## Attempted

Relaunch the koyomi campaign run after environment fixes.

## Encountered

Run 3 recalled kioku_memory_01m7ny1kw7ef2t7350v7hddn01 (repos.0.start: declared tool failed: shikigami-local ... does not exist) and run 4 recalled the shikigami-agent-launch failure, beside older pilot memories. Machine setup failures are not lessons about the repository or the playbook.

## Workaround

None yet; the memories remain.
