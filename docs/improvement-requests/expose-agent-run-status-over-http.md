---
type: Improvement Request
title: Expose terminal agent-run status over the public HTTP API
description: Publish a typed, idempotent run-status read endpoint so callers that requested an addressed agent run can observe its durable running, succeeded, or failed outcome without reading Shikigami's private workflow or session storage.
timestamp: "2026-09-20T20:31:12Z"
generated:
  by: process:claude-code
  at: "2026-10-26T02:23:58Z"
requestId: IR-10
status: completed
completedAt: "2026-10-26T02:23:58Z"
resolution: "Plan 91 under MasterPlan 15 serves the typed lifecycle/history API and client. Real worker, PostgreSQL and HTTP tests verify success, permanent failure, cancellation, refusal and automatic pre-workflow dead-letter reconciliation; durable receipts survive later cleanup under the documented retention policy."
targetPlan: docs/masterplans/15-expose-declared-agents-and-agent-runs-over-the-public-http-api.md
origin: mori://shinzui/mori
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-21T18:03:06Z"
    document_timestamp: "2026-09-21T18:03:06Z"
    scope: catalog-metadata
    outcome: approved
    context: Audited lifecycle status and plan coverage against the current plans, master plans, Git history, and repository tree; the run-status API remains unplanned and depends on IR-8's identifier contract.
    provider: openai
    model: gpt-5.6-sol
    effort: high
---

# Improvement Request: expose terminal agent-run status over the public HTTP API

## Status

**Completed by [plan 91](../plans/91-expose-agent-run-status-and-history-over-http.md)
on 2026-10-26 under [MasterPlan 15](../masterplans/15-expose-declared-agents-and-agent-runs-over-the-public-http-api.md).**
Authenticated lifecycle and paginated history reads, typed client show/list/wait,
shared operator JSON and generated OpenAPI are implemented and verified. Real
worker execution covers success and permanent failure; workflow tests cover
cancellation and refusal.

Automatic retry exhaustion before workflow creation is closed through the
released PGMQ read API: status lookup filters by the original accepted queue id
and commits a bounded failure receipt in the same transaction. The real consumer
and HTTP tests prove failed/dead_lettered with zero handler calls and stable
status after archive/purge. Tests cover temporary operator leases, unrelated
entries, malformed evidence, and write rollback/retry. No new callback, dependency
release or workflow-body change is needed. Retain DLQ evidence until its receipt
is verified before cleanup; the operator runbook documents that condition.
See [ADR 0050](../adr/0050-run-status-reconciles-retained-dead-letters-through-the-released-read-api.md)
and resolved [FRIC-7](../friction-log/7-automatic-pgmq-exhaustion-bypasses-the-domain-disposition-hook.md).

## Context

Mori's dependency-cascade workflow must not release downstream repositories merely because
Shikigami accepted an upgrade-agent request. It must wait until the agent has actually completed
the constraint change and build repair, then close the corresponding workflow step as succeeded or
failed.

Shikigami already owns the required durable truth. `shikigami runs show` joins the Keiro workflow
instance to the Kioku session through the recorded `open-session` step and reports workflow status,
session status, summary, and error. The public `ShikigamiApi` still exposes only health, however,
so a service caller cannot perform that supported join. Reading Keiro or Kioku tables from Mori
would violate both projects' ownership boundaries.

## Requested Change

1. Add a typed read route to `ShikigamiApi` for the identifier returned by the addressed-run
   endpoint. The exact path is Shikigami-owned; a shape such as
   `GET /agents/{agentName}/runs/{runId}` is sufficient.
2. Return one closed lifecycle with at least `accepted`, `running`, `succeeded`, and `failed`.
   Terminal responses include the run identifier, agent identity, completion time, and a bounded
   result summary or bounded failure detail. If a session was opened, include its identifier.
3. Define the run identifier once. The `runId` returned by IR-8 must be the lookup key accepted by
   this endpoint, including after caller retries with the same idempotency key.
4. Implement the read through the supported Keiro and Kioku operations already composed by
   `shikigami runs show`. Do not expose private table names or make the HTTP DTO mirror a framework
   row.
5. Distinguish an unknown run from a known non-terminal run with typed problem details and stable
   HTTP statuses. A transient backing-store failure must not be rendered as `failed`, because that
   would turn an unavailable read into a false agent outcome.
6. Serve the route from `shikigami-server`, derive the corresponding function in
   `shikigami-client`, include it in generated OpenAPI, and pin the request and every response arm
   with wire-compatibility tests.

## Acceptance

1. Request a declared agent through the IR-8 endpoint and receive `runId = R`. Reading `R` before
   execution finishes reports `accepted` or `running`, never a terminal guess.
2. A successful run eventually reports `succeeded` with its session identifier, completion time,
   and bounded summary. Repeating the read returns the same terminal facts.
3. A permanently failed or dead-lettered run eventually reports `failed` with a bounded reason;
   it never remains `running` indefinitely after the durable workflow is terminal.
4. Repeating the original request with the same idempotency key returns the same `runId`, and both
   callers observe the same status resource.
5. An unknown identifier returns a typed not-found problem. A storage outage returns a retryable
   service problem and does not claim that the agent failed.
6. The generated OpenAPI document and typed client expose the route, and a wire test pins all
   lifecycle values and optional fields.

## Non-goals

This request does not add cancellation, listing, streaming, callbacks, or direct access to the
Keiro journal or Kioku session APIs. It does not require Mori to link `shikigami-client`; Mori may
continue binding to the JSON contract through its own golden fixtures. It also does not define how
an agent gains repository mutation capabilities; that is a separate request.

## Dependencies

- `mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-8` supplies the addressed-run
  request and stable run identifier.
- `mori://shinzui/mori/okf/use-cases/concepts/UC-2` supplies the end-to-end workflow requirement.
- `mori://shinzui/shikigami` project-relative
  `docs/adr/0021-operator-verbs-wrap-the-owning-library.md` records why the status join must use
  supported Keiro and Kioku operations. An artifact-level Mori URI is not currently registered.
