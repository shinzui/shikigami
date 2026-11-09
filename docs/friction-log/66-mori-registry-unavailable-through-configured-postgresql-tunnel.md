---
type: Friction Entry
title: "Mori registry unavailable through configured PostgreSQL tunnel"
description: "The configured Mori PostgreSQL tunnel refuses connections, blocking dependency corpus discovery."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-09T04:57:23Z"
frictionId: FRIC-66
status: logged
impact: blocked
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/mori"
plan: "docs/plans/86-qualify-integrated-adaptive-autonomous-delivery.md"
---
# Mori registry unavailable through configured PostgreSQL tunnel

## Attempted

mori registry list; mori registry search baikai

## Encountered

Configured Sungkyung socket refuses connections; the running local PostgreSQL instance has no mori database.

```text
NotifierConnectError: connection refused at sungkyung-clients/postgresql/.s.PGSQL.5432
```
