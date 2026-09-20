---
type: Improvement Request
title: Expose terminal agent-run status over the public HTTP API
description: Publish a typed, idempotent run-status read endpoint so callers that requested an addressed agent run can observe its durable running, succeeded, or failed outcome without reading Shikigami's private workflow or session storage.
timestamp: "2026-09-20T20:31:12Z"
generated:
  by: process:codex
  at: "2026-09-20T20:31:12Z"
requestId: IR-10
status: proposed
origin: mori://shinzui/mori
---

# Improvement Request: expose terminal agent-run status over the public HTTP API

## Status

**Proposed.** This request complements
`mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-8`. IR-8 lets an
external caller request a run and receive its stable run identifier. This request lets that
caller follow the identifier to the run's durable outcome. Together they support the agent-driven
upgrade portion of `mori://shinzui/mori/okf/use-cases/concepts/UC-2` without exposing a Shikigami
database, queue, or workflow-journal schema.

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
