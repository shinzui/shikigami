---
type: "Capability"
title: "Authorized sink delivery and outbox"
description: "Dispatch declared external outputs with permission checks, durable intents, retry classification, and delivery receipts."
capabilityId: "CAP-9"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core", "shikigami-workers", "shikigami-migrations", "kikan-shikigami-binding", "kikan-shikigami"]
interface: ["Shikigami.Sink", "Shikigami.Agent.Workflow.publishSinkIntent", "shikigami grants", "shikigami-worker"]
tags: ["authorized-sink-outbox"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:45:29Z"
requires: ["CAP-7"]
evidence:
  - kind: test
    resource: "packs/kikan-shikigami-binding/test/Kikan/Shikigami/Binding/SinkHonestySpec.hs"
    proves: "Real configured action POSTs, missing-endpoint failure, recipient limits, and truthful outcome classification."
  - kind: test
    resource: "packs/kikan-shikigami/test/Kikan/OutputDeliverySpec.hs"
    proves: "HTTP receipt-gap redelivery, transient retries, permanent rejection, and downstream deduplication."
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs"
    proves: "Revocation after enqueue prevents publication."
---

# Authorized sink delivery and outbox

## Provides

The kernel resolves the declaration’s `outputs` against the running composition. Local runs deliver [reports](../user/outputs.md) directly. In the Kikan distribution consumers declare Kawa digests, Kizashi signals, Rei actions, Danwa conversations, or channel egress. The durable path stores deterministic sink intents and publishes them through checked HTTP clients with outcome receipts. Flow bodies can emit intents before final completion. Publication rechecks current permission, so an earlier enqueue does not bypass revocation.

## Adopt

Configure endpoints, credentials, recipient defaults, sink-kind grants, and exact-action authority as described in [Sinks](../user/sinks.md). The Kikan output kinds are registered by the Kikan binding, so run the outbox publisher through `kikan-shikigami-worker`. Each intent carries the run that enqueued it: the publish-time authority decision and an `output.delivered` entry (step `outbox-publish`) land in that run's action record, so `record check` pairs the delivery with its decision.

Builds on [CAP-7: Exact external-action authorization](exact-action-authorization.md).

## Evidence

- [SinkHonestySpec.hs](../../packs/kikan-shikigami-binding/test/Kikan/Shikigami/Binding/SinkHonestySpec.hs): Real configured action POSTs, missing-endpoint failure, recipient limits, and truthful outcome classification.
- [OutputDeliverySpec.hs](../../packs/kikan-shikigami/test/Kikan/OutputDeliverySpec.hs): HTTP receipt-gap redelivery, transient retries, permanent rejection, and downstream deduplication.
- [AgentWorkflowSpec.hs](../../shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs): Revocation after enqueue prevents publication.

## Limits

An unconfigured endpoint reports failure rather than fabricated delivery. Exactly-once effects across HTTP require downstream idempotency; journal replay alone cannot guarantee them. Directory-based recipient strategies need explicit defaults because ownership-directory resolution is unavailable. External services own their outputs after accepting them.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
