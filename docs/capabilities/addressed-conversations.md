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
interface: ["Shikigami.Integration.Danwa", "Shikigami.Agent.Conversation", "shikigami-consume-events"]
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
  - kind: example
    resource: "agents/danwa-heartbeat.dhall"
    proves: "An event-triggered conversation declaration."
---

# Addressed durable conversations

## Provides

The integration consumer decodes the public addressed-message envelope and routes it to a conversation workflow. The runtime restores the session, records user and assistant turns, replies through the external conversation API, and uses `continueAsNew` after each turn. Between-turn idle timeout ends an epoch; a later message starts a linked session.

## Adopt

Declare the addressed event type and consume its public topic, following [Triggers](../user/triggers.md). Configure conversation endpoint, credentials, policy, and workers. Intake does not read another service's private database.

Builds on [CAP-2: Durable trigger intake](durable-trigger-intake.md), [CAP-3: Program and Skill execution](program-and-skill-execution.md).

## Evidence

- [AgentWorkflowSpec.hs](../../shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs): Conversation parking, live-generation delivery, per-turn rotation, idle timeout, epoch lineage, and overlay refusal.
- [Conversation.hs](../../shikigami-core/src/Shikigami/Agent/Conversation.hs): Bounded one-turn generations, session restoration, and typed turn failures.
- [danwa-heartbeat.dhall](../../agents/danwa-heartbeat.dhall): An event-triggered conversation declaration.

## Limits

This path requires the external conversation service and public event publication. It is not an arbitrary inbound chat HTTP API. Conversations currently refuse declared capability overlays and retain a name-keyed scope even when storing the verified principal. A message arriving without an armed promise is redelivered rather than inventing a fresh wait.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
