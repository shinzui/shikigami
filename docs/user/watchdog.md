---
type: Guide
title: "Active-work watchdog notices"
description: "Understand quiet-work and drift notices and inspect their bounded evidence before acting."
docId: DOC-20
tags: [watchdog, supervision]
generated:
  by: process:codex-cli
  at: "2026-11-06T17:20:00Z"
---

# Active-work watchdog notices

A watchdog notice says that retained work has stayed quiet beyond a configured
window, an operation remains unresolved, an idle coordinator has not advanced,
or accepted operations may be drifting from an objective. It links a subject,
its evidence, the observation window and the limits of that observation.

The watchdog reads metadata, not your prompts, tool arguments/results or approval
bodies. A live permission, approval or command wait suppresses quiet-work findings
until its deadline. Repeated observations of the same episode usually produce no
new notice. Missing or incomplete coverage does not prove that all work is healthy.

Objective findings go to the conversation bound by trusted admission. Other
findings go to the configured operator. Instructions inside observed work cannot
change the destination, choose a different subject or authorize a cancellation.

Inspect the linked objective, session or execution before acting. The watchdog
cannot cancel, transfer, rewrite or complete it. Use your existing authorized
[objective commands](objectives.md) and operator workflow to decide what to do.
A drift notice is an advisory assessment, not proof that the objective failed.

An operator can run `shikigami watchdog inspect --json` to see completed sweeps,
coverage and refusals, and use `episodes` and `findings` to page their evidence.
`inspect --fail-when-overdue` reports a missed cadence independently of the
watchdog itself. See the [operations guide](../operations/watchdog.md) for enabling
it, selecting windows, funding its independent allowance and monitoring its age.
