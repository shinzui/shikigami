---
type: Friction Entry
title: "A declaration grant can be confirmed only by a run in a terminal"
description: "shikigami-agent-run asks for the grant only on a TTY, so confirming means running the whole run in the foreground, and redirecting output (for example through tee) silently turns the prompt into a refusal."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T23:54:46Z"
frictionId: FRIC-102
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "Opened a Rex window running the command with a real TTY; the operator answered there, and later runs used --no-confirm."
tags:
  - "local-operator"
  - "grant"
resolution: "Fixed in 77c7fb39: shikigami-local grant <declaration> --in <repository> confirms a grant in a terminal without starting a run, and the unattended refusal, the run prompt and doctor --workspace name that command. It still refuses without a terminal, and the refusal says why (a pipe such as tee)."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-18T21:25:00Z"
    change: "Status set to resolved."
---
# A declaration grant can be confirmed only by a run in a terminal

## Attempted

Start the koyomi campaign run so the operator could confirm the grant while an agent watched the output.

## Encountered

With --no-confirm: no stored grant for this declaration; run it once in a terminal to confirm it. A pane that piped the run through tee would not have prompted. There is no shikigami-local command to confirm a grant without starting a run.

## Workaround

Opened a Rex window running the command with a real TTY; the operator answered there, and later runs used --no-confirm.
