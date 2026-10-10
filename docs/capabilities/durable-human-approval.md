---
type: "Capability"
title: "Durable human approval"
description: "Park workflow work for an approval answer or deadline and suppress protected output on rejection or timeout."
capabilityId: "CAP-10"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core", "shikigami-server", "shikigami-workers"]
interface: ["Shikigami.Agent.Approval.Workflow", "Shikigami.Flow.Acknowledgement", "shikigami resolve-approval"]
tags: ["durable-human-approval"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:45:29Z"
requires: ["CAP-4"]
evidence:
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs"
    proves: "Approval/rejection/timeout resume, notification failure classification, stable decision tokens, and late timers."
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/FlowLifecycleSpec.hs"
    proves: "The registered alert Flow parks, resumes on acknowledgement, or escalates after timeout."
  - kind: module
    resource: "shikigami-core/src/Shikigami/Agent/Approval/Workflow.hs"
    proves: "Dedicated child workflow, notifier seam, and result types."
---

# Durable human approval

## Provides

The parent requests a durable approval child that journals intake, notification, and decision. An opaque wake token identifies the actual wait independently of the review-request identity. Answers and timeout fire actions resume the child and parent; rejected or timed-out approvals suppress sink dispatch. Flows expose the same machinery as an acknowledgement capability.

## Adopt

Configure approval policy and a production notifier, then deliver an answer with `shikigami resolve-approval` using the recorded decision token. See [Flows](../user/flows.md) and [operator commands](../operations/operator-cli.md).

Builds on [CAP-4: Durable agent runs and Flows](durable-agent-flows.md).

## Evidence

- [AgentWorkflowSpec.hs](../../shikigami-core/test-postgres/Shikigami/AgentWorkflowSpec.hs): Approval/rejection/timeout resume, notification failure classification, stable decision tokens, and late timers.
- [FlowLifecycleSpec.hs](../../shikigami-core/test-postgres/Shikigami/FlowLifecycleSpec.hs): The registered alert Flow parks, resumes on acknowledgement, or escalates after timeout.
- [Workflow.hs](../../shikigami-core/src/Shikigami/Agent/Approval/Workflow.hs): Dedicated child workflow, notifier seam, and result types.

## Limits

The default notifier is an inert composition seam; human-visible delivery requires a configured notifier. Approval does not replace sink-kind or exact-action authorization. This capability does not supply an authenticated public HTTP approval ingress.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
