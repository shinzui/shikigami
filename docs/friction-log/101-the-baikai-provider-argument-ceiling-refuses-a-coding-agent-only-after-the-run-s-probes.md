---
type: Friction Entry
title: "The Baikai provider-argument ceiling refuses a coding agent only after the run's probes"
description: "Without allow-provider-args in ~/.config/baikai/agents.kdl, every coding agent with declared tools is refused, and a run learns this only when its first coding-agent step starts."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T23:54:44Z"
frictionId: FRIC-101
status: "resolved"
impact: detour
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "Created ~/.config/baikai/agents.kdl with policy { allow-provider-args #true }, with the user's approval."
tags:
  - "local-operator"
  - "baikai"
  - "preflight"
resolution: "Fixed in a5f59a45: the preflight builds the runner's job (provider args for declared tools, 32 MiB output) and checks it against the operator's Baikai ceiling before the first step; doctor --workspace also reports whether the declaration is granted there."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-18T12:29:00Z"
    change: "Status set to resolved."
---
# The Baikai provider-argument ceiling refuses a coding agent only after the run's probes

## Attempted

Resume the koyomi campaign run after fixing PATH (run 3).

## Encountered

coding agent failed: refused by the operator's Baikai ceiling: raw provider arguments are not permitted; 5 requested. ~/.config/baikai/ did not exist on this machine. The requirement is documented only in docs/user/declared-tools.md.

## Workaround

Created ~/.config/baikai/agents.kdl with policy { allow-provider-args #true }, with the user's approval.
