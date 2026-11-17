---
type: Friction Entry
title: "shikigami-worker's default health port collides with process-compose on this Mac"
description: "The worker binds health.port 8091 by default, which the dev process-compose already listens on, and exits at startup."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T04:07:24Z"
frictionId: FRIC-96
status: logged
impact: nuisance
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md"
workaround: "Set health.port to a free loopback port (18971) in the scratch config."
tags:
  - "ep-8"
---
# shikigami-worker's default health port collides with process-compose on this Mac

## Attempted

Starting shikigami-worker --config <scratch config> beside the running dev process-compose.

## Encountered

Network.Socket.bind: resource busy (Address already in use) after worker.health.listening port 8091.

## Workaround

Set health.port to a free loopback port (18971) in the scratch config.
