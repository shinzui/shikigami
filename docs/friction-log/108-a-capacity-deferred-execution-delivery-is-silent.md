---
type: Friction Entry
title: "A capacity-deferred execution delivery is silent"
description: "ExecutorDeferred maps to Done with no log or metric, so an execution starved of runtime capacity looks like one waiting on a wake that nothing delivers."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T23:54:57Z"
frictionId: FRIC-108
status: logged
impact: slowdown
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "Inspected the capacity tickets and attempts in the scenario's kept database."
tags:
  - "observability"
  - "execution"
  - "capacity"
---
# A capacity-deferred execution delivery is silent

## Attempted

Diagnose FRIC-99's stranded objective run.

## Encountered

The worker log showed no line for any execution-route delivery; pgmq had deleted five messages. The deadlock was found only by reading shikigami.execution_capacity_tickets.

## Workaround

Inspected the capacity tickets and attempts in the scenario's kept database.
