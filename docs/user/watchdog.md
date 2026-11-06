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

## Inspect notices and coverage

With the watchdog configured and its scheduled declaration loaded, an operator
can inspect the ledger without waiting for another sweep:

```bash
shikigami --config config.json watchdog inspect --agents agents --json
shikigami --config config.json watchdog episodes --open --limit 20 --json
shikigami --config config.json watchdog findings EPISODE_ID --limit 20 --json
```

Replace `EPISODE_ID` with an identity from the episode page. Episode pages accept
`--objective OBJECTIVE_ID`; both page commands accept `--after ID`. Pages default
to 20 entries and allow 1–100. Reads stay within the configured principal and scope.
Inspection shows the latest attempt separately from the last completed sweep,
coverage and refusals. Unavailable coverage is not an empty population, and an
incomplete pass cannot clear an episode.

`watchdog inspect --fail-when-overdue` checks the actual cron declaration and exits
2 when completion is overdue, absent or its schedule cannot be computed. Grace
defaults to 60 seconds. A newer unfinished attempt does not reset the completion
clock. Run this from an independent monitor; HTTP health probes do not check
watchdog cadence. The independent telemetry sampler also exports sweep age when
OTel is configured; monitor the age point's timestamp as well as its value.

See the [operations guide](../operations/watchdog.md) for enabling the schedule,
selecting windows, funding its independent allowance and interpreting telemetry.
The [eight-case qualification](../evidence/plan-113/acceptance.md) covers scheduled
admission, replay, bounded evidence, accounting and authority with deterministic
providers. Live-model quality and native command trials remain separate evidence.
