---
type: "Capability"
title: "Local integration fixtures"
description: "Exercise activity intake and sink HTTP contracts with fixture publication, authenticated local stubs, and an outbound conversation probe."
capabilityId: "CAP-20"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-server"]
interface: ["shikigami publish-fixture", "shikigami stub-kawa", "shikigami stub-kanmon", "shikigami danwa-spike"]
tags: ["fixtures", "integration", "local-development"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:55:22Z"
evidence:
  - kind: test
    resource: "shikigami-server/test/Shikigami/Server/KawaStubSpec.hs"
    proves: "The local ingest doorway accepts configured credentials and refuses missing or incorrect credentials before body decoding."
  - kind: test
    resource: "shikigami-server/test/Shikigami/Server/KanmonStubSpec.hs"
    proves: "The channel fixture validates routes and destinations and deduplicates keyed accepted effects."
  - kind: module
    resource: "shikigami-server/src/Shikigami/Server/Command/PublishFixture.hs"
    proves: "A JSON activity envelope is decoded and published through the configured Kafka producer."
  - kind: module
    resource: "shikigami-server/src/Shikigami/Sink/KawaStub/Republish.hs"
    proves: "Accepted fixture digests can re-enter Kafka with the integration header shape."
  - kind: module
    resource: "shikigami-server/src/Shikigami/Server/Command/DanwaSpike.hs"
    proves: "The probe creates a conversation, joins participants, posts a human message, and replies through the public client."
---

# Local integration fixtures

## Provides

The administrative binary publishes JSON activity fixtures and hosts local HTTP
stubs for digest ingest and channel egress. The stubs can require configured
bearer credentials and deduplicate keyed requests in memory. Digest ingest can
optionally republish accepted envelopes into a Kafka fixture topic to exercise
feedback intake. A separate outbound conversation probe exercises conversation
creation, participant joins, posting, and replies against a configured service.

## Adopt

Use `publish-fixture` with an activity envelope and configured broker/topic.
Start `stub-kawa` with an optional `--republish-topic`, or `stub-kanmon` with its
destination allow-list. `danwa-spike` accepts the chosen human and agent
participants. [The Living Loop](../user/living-loop.md) describes the local
topology; configure the current authorization prerequisites separately before
expecting protected agent outputs to reach a stub.

## Evidence

- [KawaStubSpec.hs](../../shikigami-server/test/Shikigami/Server/KawaStubSpec.hs): authenticated fixture ingest.
- [KanmonStubSpec.hs](../../shikigami-server/test/Shikigami/Server/KanmonStubSpec.hs): routing, destination policy, and idempotency.
- [PublishFixture.hs](../../shikigami-server/src/Shikigami/Server/Command/PublishFixture.hs): fixture publication.
- [Republish.hs](../../shikigami-server/src/Shikigami/Sink/KawaStub/Republish.hs): optional feedback publication.
- [DanwaSpike.hs](../../shikigami-server/src/Shikigami/Server/Command/DanwaSpike.hs): outbound probe implementation.

## Limits

These are development fixtures, not production replacements for the downstream
services. Stub state disappears on restart. Fixture publication and feedback
need Kafka; the conversation probe needs the configured external service.
The digest stub logs republish failures instead of failing its ingest response,
so acceptance is not proof of durable Kafka publication. Direct fixture/probe
commands do not create a governed agent run or bypass the run's authorization
checks. The older living-loop walkthrough is topology guidance, not a claim that
the default deny-all deployment can dispatch protected sinks.
