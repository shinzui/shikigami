---
type: Friction Entry
title: "A local playbook run finds a missing helper executable only when a step runs it"
description: "shikigami-agent-run spawns shikigami-local, shikigami-agent-launch and shikigami-run-behavior from PATH, and a missing one fails its step mid-run instead of refusing before the first step."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T23:54:42Z"
frictionId: FRIC-100
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "Put the directories of cabal list-bin for shikigami-agent-launch, shikigami-local, shikigami-agent-run and shikigami-run-behavior on PATH."
tags:
  - "local-operator"
  - "playbook"
  - "preflight"
resolution: "Fixed in a5f59a45: shikigami-agent-run refuses to start a local run whose helpers (shikigami-agent-launch, shikigami-local, the vendor CLI) do not resolve, naming the fix; shikigami-local doctor --agent <declaration> runs the same checks (Shikigami.Agent.Preflight)."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-18T12:28:59Z"
    change: "Status set to resolved."
---
# A local playbook run finds a missing helper executable only when a step runs it

## Attempted

Run the keiro-modernization campaign on koyomi with shikigami-agent-run from cabal list-bin, with no Shikigami executables on PATH.

## Encountered

Run 1 stopped at its first probe (shikigami-local: createProcess: execvp: does not exist). Run 2 passed all seven probes, then its readiness coding agent failed (shikigami-agent-launch: does not exist). Neither shikigami-local doctor nor the run checked beforehand.

## Workaround

Put the directories of cabal list-bin for shikigami-agent-launch, shikigami-local, shikigami-agent-run and shikigami-run-behavior on PATH.
