---
type: Friction Entry
title: "A declaration's grant digest depended on how its path was spelled"
description: "A playbook campaign confirmed through an absolute path was reported as not granted when the same file was named by a relative path, because the bundle path anchored beside the declaration is part of the digest."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-18T21:45:00Z"
frictionId: FRIC-121
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "Named the declaration by the same absolute path the grants were confirmed with."
resolution: "Fixed in 77933ad0: loadAgentFile loads a declaration from its canonical path, and every local command and the worker's directory loader use it, so one file has one digest. loadAgent keeps the path as given for the API baseline corpus."
tags:
  - "local-operator"
  - "grant"
  - "playbook"
---
# A declaration's grant digest depended on how its path was spelled

## Attempted

Confirm keiro-modernization in place on the five EP-7 M4 batch repositories with
`shikigami-local grant <absolute path> --in mori://shinzui/<repo> --placement in-place`, then
check them with `shikigami-local doctor --agent agents/campaigns/keiro-modernization/keiro-modernization.dhall --workspace mori://shinzui/<repo>`.

## Encountered

All five grants were stored, but doctor reported `no stored grant` for each. With the absolute
path it reported them granted. `loadAgent` anchors a relative playbook bundle at
`takeDirectory path`, and the declaration's journal JSON, which the grant digest hashes, carries
that anchored path.

## Workaround

Named the declaration by the same absolute path. Fixed the same day in 77933ad0.
