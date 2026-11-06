---
type: Capability
title: "Independent active-work watchdog"
description: "Observe retained active work with bounded read authority and deliver coalesced quiet-work and cited drift advisories."
capabilityId: CAP-32
provider: mori://shinzui/shikigami
status: shipped
stability: experimental
since: unreleased
packages: [shikigami-core, shikigami-workers, shikigami-server, shikigami-migrations]
interface: [Shikigami.Flow.Watchdog, Shikigami.Watchdog.Store, shikigami watchdog]
tags: [watchdog, supervision]
generated:
  by: process:codex-cli
  at: "2026-11-06T17:20:00Z"
requires: [CAP-1, CAP-4, CAP-21, CAP-26]
evidence:
  - kind: test
    resource: shikigami-core/test/Shikigami/WatchdogClassifySpec.hs
    proves: "Semantic progress, waiting deadlines, uncertainty and separate coordinator classification."
  - kind: test
    resource: shikigami-core/test-postgres/Shikigami/WatchdogObservationSpec.hs
    proves: "Bounded lock-free owner metadata, exact approval associations and protected-body exclusion."
  - kind: test
    resource: shikigami-core/test-postgres/Shikigami/WatchdogSweepSpec.hs
    proves: "Durable episode, decision and delivery recovery with separate accounting and authority refusal."
  - kind: test
    resource: shikigami-workers/test/Shikigami/WatchdogQualificationSpec.hs
    proves: "Eight integrated IR-19 cases through scheduled ticks, queue admission and resume."
  - kind: guide
    resource: docs/operations/watchdog.md
    proves: "Operator configuration, inspection, telemetry and intervention limits."
---

# Independent active-work watchdog

## Provides

A scheduled `watchdog-sweep` Flow uses a sealed read grant to observe objectives,
coordinators, continuing sessions and executions without taking their mutation
locks. Semantic marks distinguish progress from quiet work, retained episodes
coalesce repeated notices, and a registered input-bound typed Drift assessment
cites accepted metadata. Independent per-tick roots fund its decisions even when
observed roots are stopped. Trusted associations choose notice destinations.

Scoped read-only commands page the ledger and report overdue completions. An
independent worker sampler exports completion age; fixed-tag counters report
runtime sweep, finding and refusal callbacks.

## Adopt

Follow the [operations guide](../operations/watchdog.md) and
[notice guide](../user/watchdog.md). Configure the verified principal, schedule,
observation scope/windows, operator allowance, model binding and sink/action grants.

Builds on [typed declarations](typed-agent-declarations.md),
[durable Flows](durable-agent-flows.md), [typed decisions](typed-flow-decisions.md)
and [root accounting](root-resource-accounting.md).

## Evidence

- [Classifier](../../shikigami-core/test/Shikigami/WatchdogClassifySpec.hs): semantic marks and deadlines.
- [Observation](../../shikigami-core/test-postgres/Shikigami/WatchdogObservationSpec.hs): bounded metadata and owner isolation.
- [Sweep](../../shikigami-core/test-postgres/Shikigami/WatchdogSweepSpec.hs): retained decisions, episodes, delivery and replay.
- [Qualification](../../shikigami-workers/test/Shikigami/WatchdogQualificationSpec.hs): eight scheduled IR-19 cases.
- [Operations](../operations/watchdog.md): configuration, inspection and limits.

## Limits

Observation is bounded per sweep and relationship, with explicit incomplete
coverage. It excludes transcripts and protected bodies. Findings are advisory and
supply no cancellation, transfer, mutation or completion authority. Drift quality
depends on the selected model and bounded evidence. Unknown usage remains held;
lost result appends can cause another separately charged call. Runtime counters
are at least once; exact counts come from the ledger. Native and live-model trials
are separate from deterministic acceptance. Experimental and unreleased.
