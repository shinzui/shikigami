---
type: Capability
title: "Independent active-work watchdog"
description: "In the Kikan distribution, observe retained active work with bounded read authority and deliver coalesced quiet-work and cited drift advisories."
capabilityId: CAP-32
provider: mori://shinzui/shikigami
status: shipped
stability: experimental
since: unreleased
packages: [flow-pack-watchdog, kikan-shikigami, shikigami-core, shikigami-workers, shikigami-migrations]
interface: [FlowPack.Watchdog, watchdog-sweep, watchdog, kikan-shikigami watchdog]
tags: [watchdog, supervision]
generated:
  by: process:codex-cli
  at: "2026-11-06T17:20:00Z"
requires: [CAP-1, CAP-4, CAP-21, CAP-26]
evidence:
  - kind: test
    resource: packs/flow-pack-watchdog/test/FlowPack/Watchdog/ClassifySpec.hs
    proves: "Semantic progress, waiting deadlines, uncertainty and separate coordinator classification."
  - kind: test
    resource: packs/flow-pack-watchdog/test/FlowPack/Watchdog/ObservationSpec.hs
    proves: "Bounded lock-free owner metadata, exact approval associations and protected-body exclusion."
  - kind: test
    resource: packs/flow-pack-watchdog/test/FlowPack/Watchdog/SweepSpec.hs
    proves: "Durable episode, decision and delivery recovery with separate accounting and authority refusal."
  - kind: test
    resource: packs/kikan-shikigami/test/Kikan/WatchdogQualificationSpec.hs
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
independent worker sampler exports completion age as the pack gauge `sweep.age` on
`shikigami.pack.gauges`; sweep, finding and refusal events are counted on
`shikigami.pack.events` with `pack=watchdog`.

## Adopt

The capability ships as the flow pack `packs/flow-pack-watchdog` and runs from the
`kikan-shikigami` distribution (`kikan-shikigami-scheduler`, `kikan-shikigami-worker`,
`kikan-shikigami watchdog`); the stock executables do not offer it and refuse the `watchdog`
key. Follow the [operations guide](../operations/watchdog.md) and
[notice guide](../user/watchdog.md). Configure the verified principal, schedule,
observation scope/windows, operator allowance, model binding and sink/action grants.

Builds on [typed declarations](typed-agent-declarations.md),
[durable Flows](durable-agent-flows.md), [typed decisions](typed-flow-decisions.md)
and [root accounting](root-resource-accounting.md).

## Evidence

- [Classifier](../../packs/flow-pack-watchdog/test/FlowPack/Watchdog/ClassifySpec.hs): semantic marks and deadlines.
- [Observation](../../packs/flow-pack-watchdog/test/FlowPack/Watchdog/ObservationSpec.hs): bounded metadata and owner isolation.
- [Sweep](../../packs/flow-pack-watchdog/test/FlowPack/Watchdog/SweepSpec.hs): retained decisions, episodes, delivery and replay.
- [Qualification](../../packs/kikan-shikigami/test/Kikan/WatchdogQualificationSpec.hs): eight scheduled IR-19 cases.
- [Operations](../operations/watchdog.md): configuration, inspection and limits.

## Limits

Observation is bounded per sweep and relationship, with explicit incomplete
coverage. It excludes transcripts and protected bodies. Findings are advisory and
supply no cancellation, transfer, mutation or completion authority. Drift quality
depends on the selected model and bounded evidence. Unknown usage remains held;
lost result appends can cause another separately charged call. Runtime counters
are at least once; exact counts come from the ledger. Native and live-model trials
are separate from deterministic acceptance. Experimental and unreleased.
