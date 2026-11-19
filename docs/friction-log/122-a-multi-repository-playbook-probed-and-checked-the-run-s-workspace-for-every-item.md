---
type: Friction Entry
title: "A multi-repository playbook probed and checked the run's workspace for every item"
description: "Probe and Tool steps had no workspace, so in a run over keiei and danwa every readiness probe, build and `just check` of danwa ran in keiei, while danwa's coding agents worked in danwa."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-19T00:10:00Z"
frictionId: FRIC-122
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "Declined danwa's readiness review so the run stopped before any edge; danwa's readiness commit was kept."
resolution: "Fixed by the ToolIn and ProbeIn steps: a Tool or Probe that names a workspace, routed by the local operator tier to that repository's worktree of the run under its own grant, as a coding agent in another repository already was. The campaign playbook uses them for every probe and check."
tags:
  - "playbook"
  - "local-operator"
  - "campaign"
---
# A multi-repository playbook probed and checked the run's workspace for every item

## Attempted

Run EP-7 M4 batch A, one keiro-modernization run with workspace `mori://shinzui/keiei` and
payload `{"repos": ["mori://shinzui/keiei", "mori://shinzui/danwa"]}` (run
1290d348-df05-547e-9578-4862f762034a).

## Encountered

keiei finished cleanly. On danwa, the readiness prompt quoted keiei's HEAD (c53c66d), mori
project and keiro 0.25 as danwa's probe output, and the readiness review offered c53c66d, a
keiei commit, as danwa's reset point. Every `Probe` and `Tool` step ran through
`runDeclaredTool` in the run's own worktree; only `CodingAgent` and `Reflect` had a
`workspace`. danwa's builds and `just check` after each edge would have checked keiei. The
readiness agent noticed the mismatch and probed danwa itself, which is why the work it did
(82738d0) was correct.

Koyomi, the M3 pilot, was a one-repository run, so the gap did not show there.

## Workaround

Declined the readiness review so the run stopped before danwa's first edge, and kept 82738d0.
