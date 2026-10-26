---
type: "Capability"
title: "Idempotent addressed runs over HTTP"
description: "Atomically accept an addressed run and queue it once under a server-owned identity, with safe request replay and conflict detection."
capabilityId: "CAP-24"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core","shikigami-api","shikigami-server","shikigami-client","shikigami-migrations"]
interface: ["POST /agents/{agentName}/runs","Shikigami.AgentRun.Ledger","shikigami-client runs request"]
tags: ["idempotent-http-agent-runs"]
generated:
  by: "process:shikigami-documentation-refresh"
  at: "2026-10-25T00:00:00Z"
requires: ["CAP-22","CAP-2"]
evidence:
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/AgentRun/LedgerSpec.hs"
    proves: "Atomic send/accept, replay/conflict, twenty concurrent accepts yielding one send, and rollback on store failure."
  - kind: test
    resource: "shikigami-server/test/Shikigami/AgentRun/HandlerSpec.hs"
    proves: "HTTP acceptance/replay, typed conflicts, invalid bodies, payload bounds, and lifecycle/store refusals."
---

# Idempotent addressed runs over HTTP

## Provides

An authenticated client addresses any enabled, lifecycle-admitted declared agent without matching its normal trigger. Acceptance and queue send share one transaction. The server derives the workflow ID from its agent-scoped HTTP key; the response returns that run ID, the original acceptance timestamp, and its resource Location. First acceptance returns 202; matching payload replay returns 200 without another committed message; changed payload returns 409.

## Adopt

Follow [Request a run](../user/http-api.md#request-a-run). Supply a 1–200 character non-control idempotency key and a JSON-object payload of at most 65,536 encoded bytes. Run the server and worker against the same migrated database and declaration set. Use `shikigami-client runs request AGENT --key KEY --payload JSON` and retain the returned ID for status reads.

Builds on [CAP-22: Declared-agent HTTP catalog](declared-agent-http-catalog.md) and [CAP-2: Durable trigger intake](durable-trigger-intake.md).

## Evidence

- [LedgerSpec.hs](../../shikigami-core/test-postgres/Shikigami/AgentRun/LedgerSpec.hs): Atomic send/accept, replay/conflict, twenty concurrent accepts yielding one send, and rollback on store failure.
- [HandlerSpec.hs](../../shikigami-server/test/Shikigami/AgentRun/HandlerSpec.hs): HTTP acceptance/replay, typed conflicts, invalid bodies, payload bounds, and lifecycle/store refusals.

## Limits

Acceptance establishes queued work, not successful execution or sink delivery. Retries still check current declaration/lifecycle admission before replay lookup. Keys belong to an agent, not a caller, and the credential provides no per-agent permission partition. Background worker execution, profiles, tool authorization, and sink gates remain independent requirements.

This provision is experimental and unreleased; its implementation does not establish a released compatibility promise.

