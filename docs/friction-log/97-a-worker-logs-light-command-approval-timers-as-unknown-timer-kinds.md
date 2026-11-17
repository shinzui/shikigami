---
type: Friction Entry
title: "A worker logs light-command approval timers as unknown timer kinds"
description: "When shikigami-agent-run and shikigami-worker share a database, the worker's timer loop reports each approval timer the light command armed as scheduler.timer.unknown_kind at error level."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T04:07:26Z"
frictionId: FRIC-97
status: logged
impact: nuisance
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md"
tags:
  - "ep-8"
---
# A worker logs light-command approval timers as unknown timer kinds

## Attempted

Starting shikigami-worker on the M3 scratch database after a local-operator run had parked and resolved a local.report approval.

## Encountered

Four error lines: {"event":"scheduler.timer.unknown_kind","level":"error","timer_kind":"final"} and one with timer_kind null.
