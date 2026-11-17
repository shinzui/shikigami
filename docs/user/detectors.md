---
type: "Guide"
title: "Detectors — the intelligence layer as declared agents"
description: "Check detector execution support and configure supported agents."
docId: "DOC-11"
tags: ["detectors", "agents"]
generated:
  by: process:shikigami-user-docs-okf-migration
  at: 2026-09-07T14:41:30Z
---

# Detectors — the intelligence layer as declared agents

A detector is a declared agent that matches activity and produces an awareness
signal. It is an ordinary agent on a stream trigger; nothing in the schema marks
it as a detector.

## Current catalog

| Manifest | Current execution behavior |
| --- | --- |
| [at-risk-customer-flow.dhall](../../packs/flow-pack-examples/agents/at-risk-customer-flow.dhall) | Names the durable `at-risk-customer` Flow of the examples [flow pack](flows.md#flow-packs), with classification, alert, acknowledgement, and timeout branches. Run it with `shikigami-examples-agent-run`; the stock executables do not have the flow. |

The seed manifests that used to live under `agents/detectors/` are gone. One named
a rule arm with no runner and the other a classifier task that was never registered,
so neither could run. See [Behaviors](./behaviors.md) and [Flows](./flows.md).

## Load and run a detector

1. Author a manifest using [the canonical schema](../../schema/Agent.dhall).
   Select an existing program, Skill, or Flow; new compiled behavior requires a
   registry entry and rebuild.
2. Validate it with `cabal run shikigami -- validate <file>.dhall`. Validation
   refuses a Flow the executable was not composed with; it does not prove that a
   program task can execute.
3. Point both `kikan-shikigami-worker` and `kikan-shikigami-consume-stream` at the directory
   that holds it with `--agents`. Directory loading is not recursive.
4. Configure the agent directory, sink grants, and
   [per-action authorization](../operations/action-authorization.md) before expecting
   external signals. For a Flow, follow the [workflow versioning rules](../workflow-versioning.md).

## Suppression status

Shikigami has no semantic suppression window for a detector: a condition that is
still true can raise its signal again on a later matching activity. Durable inbox
and sink idempotency handle delivery duplicates only. Practice-review attention
has its own implemented reservation mechanism, described in
[Architecture-practice reviews](./architecture-practice-reviews.md).
