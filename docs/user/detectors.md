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
signal. The manifests in [agents/detectors](../../agents/detectors/) include both
executable examples and declarations for behavior that is not implemented yet.

## Current catalog

| Manifest | Current execution behavior |
| --- | --- |
| [stalled-intention.dhall](../../agents/detectors/stalled-intention.dhall) | Parses, but the runner rejects its `Deterministic` arm with `UnsupportedBehavior`. |
| [at-risk-customer.dhall](../../agents/detectors/at-risk-customer.dhall) | Parses, but its `at-risk-customer` task is absent from the program registry and fails with `UnknownTask`. |
| [at-risk-customer-flow.dhall](../../agents/detectors/at-risk-customer-flow.dhall) | Names the registered durable `at-risk-customer` Flow, with classification, alert, acknowledgement, and timeout branches. |

The program declaration's `preferEnrichment`, `grounding`, and `enabledBy` fields
are not interpreted by the dispatcher. Setting `TOMOSHIBI_ENABLE_LLM_DETECTORS`
does not install the missing classifier or gate execution. See
[Behaviors](./behaviors.md) and [Flows](./flows.md).

## Load and run a detector

1. Author a manifest using [the canonical schema](../../schema/Agent.dhall).
   Select an existing program, Skill, or Flow; new compiled behavior requires a
   registry entry and rebuild.
2. Validate it with `cabal run shikigami -- validate agents/detectors/<name>.dhall`.
   Parsing does not prove that a program task or deterministic rule can execute.
3. Point both `shikigami-worker` and `shikigami-consume-stream` at
   `--agents agents/detectors`. Directory loading is not recursive. Disable or
   remove non-executable seed manifests from a deployed manifest directory.
4. Configure the agent directory, sink grants, and
   [per-action authorization](../operations/action-authorization.md) before expecting
   external signals. For a Flow, follow the [workflow versioning rules](../workflow-versioning.md).

## Suppression status

The migrations include a `shikigami_fired` table for detector/subject/window
suppression, but no current runtime path reads or writes it. The intended
stalled-intention episode suppression is therefore not implemented. Durable inbox
and sink idempotency handle delivery duplicates; they do not implement a
semantic detector window. Practice-review attention has its own implemented
reservation mechanism, described in [Architecture-practice reviews](./architecture-practice-reviews.md).
