---
type: "Capability"
title: "Agent-run lifecycle and HTTP acceptance history"
description: "Read durable run outcomes, page HTTP acceptance receipts, and reconcile retained pre-workflow dead letters through HTTP and operator clients."
capabilityId: "CAP-25"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core","shikigami-api","shikigami-server","shikigami-client","shikigami-workers"]
interface: ["GET /agents/{agentName}/runs/{runId}","GET /agents/{agentName}/runs","shikigami-client runs show|list|wait","shikigami runs show --json"]
tags: ["http-agent-run-lifecycle"]
generated:
  by: "process:shikigami-documentation-refresh"
  at: "2026-10-25T00:00:00Z"
requires: ["CAP-24"]
evidence:
  - kind: module
    resource: "shikigami-core/src/Shikigami/AgentRun/Status.hs"
    proves: "Status composes owning workflow/session reads, successful completion steps, refusals, and acceptance receipts."
  - kind: test
    resource: "shikigami-workers/test/Shikigami/AgentRun/StatusSpec.hs"
    proves: "Automatic pre-workflow exhaustion, targeted reconciliation, operator leases, receipt rollback, cancellation, completion, and refusal."
  - kind: test
    resource: "shikigami-server/test/Shikigami/AgentRun/HandlerSpec.hs"
    proves: "HTTP status, cross-agent isolation, acceptance pagination, and terminal receipt survival after DLQ purge."
---

# Agent-run lifecycle and HTTP acceptance history

## Provides

Status reads derive `accepted`, `running`, `succeeded`, `failed`, or `cancelled` from durable facts, including timestamps, session linkage, bounded successful summary, and structured failure kind/reason. Suspended workflows remain running. Workflow completion without a successful `complete` step is failed. An unavailable read is 503, never a fabricated agent failure.

The separate history connection lists HTTP acceptance receipts newest first with caller, key, time, and disposition. A pre-workflow status read can reconcile automatic retry exhaustion by original queue message ID and persist a terminal dead-letter receipt.

## Adopt

Use `shikigami-client runs show AGENT RUN_ID`, `runs list AGENT`, and `runs wait AGENT RUN_ID`. Pass the returned workflow UUID verbatim. See the [HTTP API guide](../user/http-api.md#follow-status-and-history) for status meanings and wait exit codes, and the [operator runbook](../operations/operator-cli.md) for pre-workflow JSON inspection and DLQ retention.

Builds on [CAP-24: Idempotent addressed runs over HTTP](idempotent-http-agent-runs.md).

## Evidence

- [Status.hs](../../shikigami-core/src/Shikigami/AgentRun/Status.hs): Status composes owning workflow/session reads, successful completion steps, refusals, and acceptance receipts.
- [StatusSpec.hs](../../shikigami-workers/test/Shikigami/AgentRun/StatusSpec.hs): Automatic pre-workflow exhaustion, targeted reconciliation, operator leases, receipt rollback, cancellation, completion, and refusal.
- [HandlerSpec.hs](../../shikigami-server/test/Shikigami/AgentRun/HandlerSpec.hs): HTTP status, cross-agent isolation, acceptance pagination, and terminal receipt survival after DLQ purge.

## Limits

History includes HTTP acceptances, not every scheduled/stream/delegated run, and its disposition is not lifecycle status. Status can inspect other agent workflows after their ownership is journaled. Retain dead letters until status reconciliation commits; prior cleanup can erase the only terminal evidence. An inspection lease can delay reconciliation, which increments the DLQ read count but leaves the entry available. No HTTP cancellation endpoint or sink-delivery guarantee is added.

This provision is experimental and unreleased; its implementation does not establish a released compatibility promise.

