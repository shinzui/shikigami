---
type: Friction Entry
title: "Automatic PGMQ exhaustion bypasses the domain disposition hook"
description: "Keiro dead-letters exhausted messages before the domain handler and exposes no terminal callback to persist an HTTP receipt."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-25T23:53:31Z"
frictionId: FRIC-7
status: "resolved"
impact: blocked
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/keiro"
affectedVersion: "0.18.0.0"
plan: "docs/plans/91-expose-agent-run-status-and-history-over-http.md"
promotedTo: "mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-10"
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-25T23:55:55Z"
    change: "IR-10 and plan 91 retain the automatic-disposition acceptance gate as an explicit owner-release prerequisite."
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-26T02:23:28Z"
    change: "Resolved the handler-hook gap using existing released APIs; no owner callback or release is required. ADR 0050 records the retention condition."
resolution: "Status lookup now reconciles retained pre-workflow dead letters through the released PGMQ containment-filtered read and commits the receipt atomically. Automatic exhaustion, temporary leases, rollback/retry, and persistence after archive/purge are verified; cleanup follows receipt verification."
---
# Automatic PGMQ exhaustion bypasses the domain disposition hook

## Attempted

Prove that every accepted run dead-lettered before workflow creation reaches a terminal public lifecycle.

## Encountered

After five expired leases, the real Keiro drain creates one DLQ entry with zero handler calls; deriveRunStatus still reports accepted.

```text
StatusSpec automatic retry exhaustion: handler calls = 0; DLQ queue length = 1; lifecycle = Accepted. Hackage and the 0.21.0.0 upstream tag also expose no disposition callback.
```
