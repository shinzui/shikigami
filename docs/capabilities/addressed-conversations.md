---
type: "Capability"
title: "Addressed durable conversations"
description: "Consume addressed messages, preserve conversation turns, and rotate a durable workflow generation after every reply."
capabilityId: "CAP-11"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core", "shikigami-workers", "shikigami-migrations"]
interface: ["Shikigami.Agent.Conversation", "Shikigami.Agent.Conversation.Channel", "Kikan.Shikigami.Binding.Conversation", "kikan-shikigami-consume-events"]
tags: ["addressed-conversations"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:45:29Z"
requires: ["CAP-2", "CAP-3"]
evidence:
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs"
    proves: "Conversation parking, live-generation delivery, per-turn rotation, idle timeout, epoch lineage, and overlay refusal."
  - kind: module
    resource: "shikigami-core/src/Shikigami/Agent/Conversation.hs"
    proves: "Bounded one-turn generations, session restoration, and typed turn failures."
  - kind: test
    resource: "packs/kikan-shikigami-binding/test/Kikan/Shikigami/Binding/ConversationSpec.hs"
    proves: "The Danwa channel reads Danwa's addressed-message payload into the kernel's message and replies with a valid danwa.conversation output."
  - kind: example
    resource: "agents/danwa-heartbeat.dhall"
    proves: "An event-triggered conversation declaration."
---

# Addressed durable conversations

## Provides

The conversation workflow is the kernel's (`shikigami.conversation`); a pack connects it to a chat service with a conversation channel (`Shikigami.Agent.Conversation.Channel`) that names the integration event addressing an agent, reads its payload into the kernel's message, and names the reply output. The Kikan binding's Danwa channel is the one that ships (plan 135, M5). An agent whose `Trigger.Event` names a channel's event type takes a conversation turn: the integration consumer routes it to the conversation workflow, and the worker decodes the payload through that channel. The runtime restores the session, records user and assistant turns, replies through the external conversation API, and uses `continueAsNew` after each turn. Between-turn idle timeout ends an epoch; a later message starts a linked session.

## Adopt

Declare the addressed event type and consume its public topic with the Kikan distribution's `kikan-shikigami-consume-events`, following [Triggers](../user/triggers.md); the stock composition registers no conversation channel and refuses a conversation turn for an agent no channel serves. Configure conversation endpoint, credentials, policy, and workers. Intake does not read another service's private database.

Builds on [CAP-2: Durable trigger intake](durable-trigger-intake.md), [CAP-3: Program and Skill execution](program-and-skill-execution.md).

## Evidence

- [AgentWorkflowSpec.hs](../../shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs): Conversation parking, live-generation delivery, per-turn rotation, idle timeout, epoch lineage, and overlay refusal.
- [Conversation.hs](../../shikigami-core/src/Shikigami/Agent/Conversation.hs): Bounded one-turn generations, session restoration, and typed turn failures.
- [ConversationSpec.hs](../../packs/kikan-shikigami-binding/test/Kikan/Shikigami/Binding/ConversationSpec.hs): The Danwa channel's decoding and reply.
- [danwa-heartbeat.dhall](../../agents/danwa-heartbeat.dhall): An event-triggered conversation declaration.

## Limits

This path requires the external conversation service and public event publication. It is not an arbitrary inbound chat HTTP API. Conversations currently refuse declared capability overlays and retain a name-keyed scope even when storing the verified principal. A message arriving without an armed promise is redelivered rather than inventing a fresh wait.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
