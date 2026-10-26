---
type: "Capability"
title: "Durable trigger intake"
description: "Turn cron ticks, matching activity envelopes, and addressed integration events into durable run jobs."
capabilityId: "CAP-2"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core", "shikigami-workers", "shikigami-migrations"]
interface: ["shikigami-scheduler", "shikigami-consume-stream", "shikigami-consume-events", "shikigami enqueue-run", "Shikigami.RunJobs", "Shikigami.Trigger.Enqueue"]
tags: ["durable-trigger-intake"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:55:22Z"
requires: ["CAP-1"]
evidence:
  - kind: module
    resource: "shikigami-server/src/Shikigami/Server/Command/EnqueueRun.hs"
    proves: "Direct addressed enqueue with identity admission, stable or explicit keys, and explicit conversation routing."
  - kind: test
    resource: "shikigami-workers/test/Shikigami/SchedulerSpec.hs"
    proves: "Timer rearming, paused-agent skips, missed-tick policy, and failed enqueue recovery."
  - kind: test
    resource: "shikigami-workers/test/Shikigami/StreamInboxSpec.hs"
    proves: "Atomic inbox/enqueue, duplicate delivery, rollback, and durable poison-record disposition."
  - kind: test
    resource: "shikigami-workers/test/Shikigami/Agent/RunJob/WorkerSpec.hs"
    proves: "Generated producer/consumer envelope compatibility and explicit route selection."
---

# Durable trigger intake

## Provides

The scheduler arms durable timers from five-field cron declarations. Stream and integration consumers record intake disposition before advancing delivery, and enqueue through the checked run-job envelope. Duplicate intake and failed transactions have distinct outcomes; malformed records enter a durable dead-letter path.

## Adopt

Choose a trigger in [Triggers](../user/triggers.md), migrate the database, and run the corresponding worker role. Stream matching combines the declared verb, source, subject type, and verb-list predicates. `shikigami enqueue-run AGENT --payload JSON` supplies a direct addressed job; `--key` selects the logical idempotency key and `--conversation` explicitly selects the conversation route. Without a key override, the key derives from the agent and payload rather than wall-clock time.

Builds on [CAP-1: Typed agent declarations](typed-agent-declarations.md).

## Evidence

- [EnqueueRun.hs](../../shikigami-server/src/Shikigami/Server/Command/EnqueueRun.hs): direct addressed-run command.
- [SchedulerSpec.hs](../../shikigami-workers/test/Shikigami/SchedulerSpec.hs): Timer rearming, paused-agent skips, missed-tick policy, and failed enqueue recovery.
- [StreamInboxSpec.hs](../../shikigami-workers/test/Shikigami/StreamInboxSpec.hs): Atomic inbox/enqueue, duplicate delivery, rollback, and durable poison-record disposition.
- [WorkerSpec.hs](../../shikigami-workers/test/Shikigami/Agent/RunJob/WorkerSpec.hs): Generated producer/consumer envelope compatibility and explicit route selection.

## Limits

Stream triggers observe `activity.v1`; they do not subscribe to arbitrary service topics. Agent actors are excluded by default unless explicitly enabled. Kafka intake requires a broker and PostgreSQL. The separate [HTTP run acceptance capability](idempotent-http-agent-runs.md) atomically records addressed requests and queues them without a broker.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
