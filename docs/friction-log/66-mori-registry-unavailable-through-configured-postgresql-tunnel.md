---
type: Friction Entry
title: "Mori registry unavailable through configured PostgreSQL tunnel"
description: "The configured Mori PostgreSQL tunnel refuses connections, blocking dependency corpus discovery."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-09T04:57:23Z"
frictionId: FRIC-66
status: "resolved"
impact: blocked
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/mori"
plan: "docs/plans/86-qualify-integrated-adaptive-autonomous-delivery.md"
resolution: "The operator restored the configured Sungkyung PostgreSQL tunnel; Mori registry list, search, show and docs now succeed."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-09T05:29:59Z"
    change: "Resume plan 86 provider integration with restored dependency lookup."
---
# Mori registry unavailable through configured PostgreSQL tunnel

## Attempted

mori registry list; mori registry search baikai

## Encountered

Configured Sungkyung socket refuses connections; the running local PostgreSQL instance has no mori database.

```text
NotifierConnectError: connection refused at sungkyung-clients/postgresql/.s.PGSQL.5432
```
