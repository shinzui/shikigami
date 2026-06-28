---
id: 8
slug: conversational-agent-loop-bound-to-danwa
title: "Conversational agent loop bound to danwa"
kind: exec-plan
created_at: 2026-06-27T16:23:56Z
intention: "intention_01kw4y6ktdebtscmdds2ydv24e"
---

# Conversational agent loop bound to danwa

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami should let a Danwa conversation address an agent, run the agent against the
message, remember the conversation in Kioku, and reply through Danwa's public HTTP API.

The trigger boundary is Danwa's public integration-event topic. Danwa owns detection of
agent-addressed messages and publishes `danwa.message-addressed-to-agent` events to the
configured topic. Shikigami consumes that topic with its Keiro inbox-backed Kafka consumer,
matches declared `Event` triggers, enqueues a durable run job, and posts replies with the
Danwa HTTP client.

Shikigami must not read another service's database. It must not depend on Danwa private
events, projection tables, outbox tables, or schema names.


## Progress

- [x] Implemented the Danwa conversation workflow in `Shikigami.Agent.Conversation`.
- [x] Implemented Danwa replies through `Shikigami.Sink.Danwa`.
- [x] Removed the old Danwa polling bridge and its CLI command.
- [x] Added `Shikigami.Integration.Danwa` for the public addressed-message payload.
- [x] Added integration-event topic consumption for `Trigger.Event` agents.
- [x] Updated `agents/danwa-heartbeat.dhall` to listen for `danwa.message-addressed-to-agent`.
- [ ] Run the full build and test suite after the bridge removal.
- [ ] Verify manually against a Danwa worker configured to publish integration events.


## Surprises & Discoveries

- Danwa now publishes a public integration event when integration publishing is enabled.
  That makes the earlier bridge unnecessary and incorrect.
- The public payload field is `agentParticipantId`; the old local bridge payload used a
  different field name. Shikigami now follows Danwa's public contract.


## Decision Log

- Decision: Shikigami consumes Danwa through public integration events only.
  Rationale: Danwa internals belong to Danwa. The stable boundary is the public event topic
  plus Danwa's public HTTP API for commands.
  Date: 2026-06-27

- Decision: Remove the Danwa bridge CLI instead of keeping it as a fallback.
  Rationale: A fallback that connects to another service's storage will be used under
  pressure and become architecture. The correct degraded mode is "no event received", not
  "read the producer's database".
  Date: 2026-06-27

- Decision: Match Danwa conversation agents by `Trigger.Event.eventType`.
  Rationale: `Stream` triggers are for activity envelopes; Danwa publishes an integration
  event with its own payload.
  Date: 2026-06-27


## Outcomes & Retrospective

The obsolete bridge is no longer part of source, tests, CLI, or the live agent manifest.
The supported path is:

```text
Danwa command -> Danwa private handling -> Danwa public integration event topic
  -> Shikigami integration-event consumer -> shikigami_run_jobs
  -> Shikigami worker -> Danwa HTTP reply
```


## Context and Orientation

Relevant files in this repository:

- `shikigami-core/src/Shikigami/Integration/Danwa.hs` defines the public payload Shikigami
  accepts from Danwa.
- `shikigami-core/src/Shikigami/Trigger/Consumer.hs` contains the Kafka integration-event
  consumer and the Keiro inbox dedupe path.
- `shikigami-cli/src/Shikigami/Cli/Commands/ConsumeStream.hs` exposes `consume-events`,
  which consumes a public integration-event topic and enqueues matching event-trigger runs.
- `shikigami-core/src/Shikigami/Agent/Conversation.hs` runs the durable multi-turn Danwa
  conversation workflow.
- `shikigami-core/src/Shikigami/Sink/Danwa.hs` posts replies through Danwa's public HTTP API.
- `agents/danwa-heartbeat.dhall` is the sample addressed-message agent.

Danwa's public event contract:

```text
eventType = "danwa.message-addressed-to-agent"
topic     = "danwa.message-addressed.v1"
payload   = MessageAddressedToAgentV1 JSON
```


## Plan of Work

1. Keep the pure addressed-message payload in Shikigami, mirroring Danwa's public JSON
   contract without importing Danwa implementation modules.
2. Consume public integration events through the existing Kafka/Keiro inbox path.
3. For each matching `Event` trigger, enqueue a `TriggeredByEvent` run job with an
   idempotency key derived from the agent name and integration message id.
4. Let the existing worker decode the addressed-message payload and drive the Danwa
   conversation workflow.
5. Post replies only through the Danwa HTTP sink.
6. Keep direct producer-database access out of Shikigami permanently.


## Concrete Steps

Build and test from the Shikigami repository root:

```bash
cabal build all
cabal test all
```

Run the Danwa event consumer against a configured broker:

```bash
cabal run shikigami -- consume-events \
  --agents agents \
  --broker 127.0.0.1:9092 \
  --topic danwa.message-addressed.v1 \
  --group shikigami-danwa
```

Run the worker that drains the resulting jobs:

```bash
cabal run shikigami -- worker \
  --agents agents \
  --danwa-url http://localhost:8080 \
  --danwa-agent part_shikigami
```


## Validation and Acceptance

Acceptance criteria:

- `shikigami --help` has no command that asks for a Danwa database connection string.
- Searching source and tests finds no module that reads Danwa storage directly.
- A Danwa `danwa.message-addressed-to-agent` integration event on
  `danwa.message-addressed.v1` enqueues one `TriggeredByEvent` run for each matching agent.
- Re-delivery of the same integration message is deduped by the Keiro inbox and does not
  enqueue a duplicate run.
- The worker posts a reply through Danwa's public HTTP API.


## Idempotence and Recovery

Kafka redelivery is expected. Keiro inbox dedupe uses the integration message id, and the
run-job idempotency key includes that id. If the consumer crashes after processing but before
offset commit, a restart may observe the record again, but the inbox should classify it as a
duplicate.

If Danwa integration publishing is disabled or the topic is unavailable, Shikigami should
wait for public events. It should not fall back to storage reads.


## Interfaces and Dependencies

Shikigami consumes:

```haskell
data AddressedMessage = AddressedMessage
  { conversationId :: Text
  , messageId :: Text
  , parentMessageId :: Maybe Text
  , author :: Text
  , content :: Text
  , agentParticipantId :: Text
  , embellishmentId :: Text
  , mentionedBy :: Text
  , occurredAt :: UTCTime
  }
```

Shikigami command interface:

```text
shikigami consume-events --topic danwa.message-addressed.v1
```

Shikigami must use these Danwa-facing boundaries:

- public Kafka-compatible integration-event topic for triggers;
- Danwa HTTP API for replies and commands.
