---
type: Friction Entry
title: "Systemd timeout evidence can omit numeric wait status"
description: "The qualified Linux systemd service retained a timeout result and empty cgroup but no numeric main wait status, requiring repeated probes and an explicit unavailable-status receipt contract."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-29T20:29:47Z"
frictionId: FRIC-18
status: "accepted"
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://systemd/systemd"
affectedVersion: "257"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "Represent unavailable numeric status explicitly for timeout/cancellation only; require normal exit with confirmed code zero for validation success, and retain exact boot/invocation, bounded output and empty-cgroup evidence for settlement."
resolution: "Keep absent numeric status explicit for timeout/cancellation only; normal validation still requires a confirmed zero exit."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-02T18:43:36Z"
    change: "Triage the observed qualification constraint with its retained bounded workaround."
---
# Systemd timeout evidence can omit numeric wait status

## Attempted

Run bash tests/workspace/probe-collector-apple.sh with the shared production profile and RuntimeMaxSec=3.

## Encountered

The command wrote its launch marker, then the retained failed unit reported Result=timeout, MainPID=0, ExecMainCode=0, ExecMainStatus=0 and an empty ControlGroup.

```text
The repeated disposable Apple-container probe reached collector stage 12; systemctl showed MemoryPeak=2310144 and ExecMainPID=1088, with no numeric wait status.
```

## Workaround

Represent unavailable numeric status explicitly for timeout/cancellation only; require normal exit with confirmed code zero for validation success, and retain exact boot/invocation, bounded output and empty-cgroup evidence for settlement.
