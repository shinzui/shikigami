---
type: Friction Entry
title: "A worker given a scratch database in its config file attached to the development database"
description: "PG_CONNECTION_STRING from the development shell overrides database.connection_string in a --config file, so a worker meant for an isolated database resumed parked runs in the development one."
generated:
  by: "claude-code/claude-fable-5-2"
  at: "2026-11-16T06:07:31Z"
frictionId: FRIC-83
status: logged
impact: detour
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/131-shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems.md"
workaround: "Stopped the worker by PID, confirmed no agent process or worktree existed, then set PG_CONNECTION_STRING and PGDATABASE in the environment of every process that must use the isolated database. --check-config did not reveal the override."
tags:
  - "configuration"
---
# A worker given a scratch database in its config file attached to the development database

## Attempted

Plan 131 M2 real run: createdb shikigami_ep6_m2, migrate it, write config.json with database.connection_string naming it, and start kikan-shikigami-worker --config config.json from the repository's development shell.

## Encountered

The worker and enqueue-run used the development database named by the shell's PG_CONNECTION_STRING. The resume loop advanced its parked runs: campaign run c4341273-0d66-516c-a51b-b840d26be160 completed after its coding-agent child was refused at admission (TierRefused under the contained tier), run 56d2d81c completed after its approval failed to notify, and run 7a28975f now crashes on a stale journal shape. No coding agent was launched, kizashi is untouched at 75b4308, no output was emitted, and no credentials were configured.

```text
enqueued run job MessageId {unMessageId = 134} (a fresh database would say 1)
shikigami.agent-run c4341273-...|completed; child ...blueprint-plans.1.implement admit = Left TierRefused "coding agents are admitted only under the local-operator trust tier"
```

## Workaround

Stopped the worker by PID, confirmed no agent process or worktree existed, then set PG_CONNECTION_STRING and PGDATABASE in the environment of every process that must use the isolated database. --check-config did not reveal the override.
