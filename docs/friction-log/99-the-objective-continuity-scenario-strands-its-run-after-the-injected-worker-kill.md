---
type: Friction Entry
title: "The objective continuity scenario strands its run after the injected worker kill"
description: "tests/objective-tracking/run.sh, unrun since M2, now composes the Kikan distribution but its restart-recovery step leaves the agent run and its execution child suspended with nothing to wake them."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T19:47:30Z"
frictionId: FRIC-99
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/135-move-the-kikan-service-bindings-out-of-shikigami-core-and-compose-a-kikan-distribution.md"
workaround: "M5 acceptance for the conversation rests on the moved conversation tests in shikigami-core-postgres-test (549/549) and the binding's Danwa channel tests; the scenario's composition fix is committed and its recovery defect is left for a follow-up."
resolution: "Root cause was a capacity deadlock, not a missing wake: the killed worker's dispatched tool attempt kept its only runtime permit (ADR-109), and the replacement that would settle it was never admitted, so the 60-second observation timer re-enqueued a delivery that always deferred. ADR-132 makes a stopped process instance a stop acknowledgement; the unmodified scenario now passes at the default capacity of one."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-17T23:40:00Z"
    change: "Diagnosed and resolved by ADR-132 (process-instance permits); the scenario's fixture now reads the Kikan configuration with the binding's settings."
tags:
  - "restart-recovery"
  - "objectives"
---
# The objective continuity scenario strands its run after the injected worker kill

## Attempted

EP-10 M5: point tests/objective-tracking/run.sh and continuity.py at kikan-shikigami-server, kikan-shikigami-worker and kikan-shikigami (the stock worker refuses mode=kikan since M2), then run bash tests/objective-tracking/run.sh.

## Encountered

continuity.py times out at run_done("triage", bootstrap) (line 204) after the scripted kill of the worker holding the objective command's protected insert. At the timeout keiro.keiro_workflows holds the shikigami.agent-run and its shikigami.execution child, both suspended with no lease and no wake_after; the run-job queue and its DLQ are empty; the execution's last journal entries are advance-execution ObserveExecution and its awakeable, so it waits on an observation nothing will deliver. The conversation step after it was not reached.

```text
AssertionError: timed out: run a1a6ded1-fdcc-57be-a25b-1b94e3de795a
shikigami.agent-run | a1a6ded1-... | suspended | 0 attempts | no lease | no wake_after
shikigami.execution | 1e38df2c-... | suspended | 0 attempts | no lease | no wake_after
pgmq.q_shikigami_run_jobs: 0 rows; pgmq.q_shikigami_run_jobs_dlq: 0 rows
```

## Workaround

M5 acceptance for the conversation rests on the moved conversation tests in shikigami-core-postgres-test (549/549) and the binding's Danwa channel tests; the scenario's composition fix is committed and its recovery defect is left for a follow-up.

## Resolution

The run was not stranded. The execution kept rotating on its 60-second observation timer.
`shikigami.execution_capacity_tickets` showed the killed worker's superseded tool attempt
still `active` under its dead owner, holding the deployment's single permit, with the
replacement attempt `waiting` behind it. Every queue delivery of the replacement deferred
(`ExecutionCapacityUnavailable` maps to `ExecutorDeferred` and then `Done`), which is why the
queue was empty. The objective tool would record the superseded attempt's receipt, settling
that permit, only when the replacement ran. With `worker.capacity.execution` at 2, the
scenario passed its restart step.

[ADR-132](../adr/0132-a-stopped-process-instance-releases-its-runtime-permits.md) lets a
process claim under an enrolled instance whose PostgreSQL session lock lasts as long as the
process does. A claim reclaims the permits of dispatched attempts whose instance lock is
free. A second defect surfaced once the restart step passed: `shikigami-objective-fixture`
loaded the scenario's configuration with the stock loader, which refuses the Kikan
authorization keys. It now loads with the binding's `authoritySettings`. The unmodified
`bash tests/objective-tracking/run.sh` passes every step at capacity one.
