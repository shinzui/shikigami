---
type: Improvement Request
title: Expose addressed agent runs over the public HTTP API
description: Add an agent-run vertical to ShikigamiApi so an external service can request a run for a named agent across the service boundary, with server-owned idempotency on a caller-supplied key, instead of writing into the shared run-job queue.
timestamp: "2026-08-07T00:00:00Z"
generated:
  by: process:codex
  at: "2026-09-21T18:03:06Z"
requestId: IR-8
status: proposed
origin: mori://shinzui/mori
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-21T18:03:06Z"
    document_timestamp: "2026-09-21T18:03:06Z"
    scope: catalog-metadata
    outcome: approved
    context: Audited lifecycle status and plan coverage against the current plans, master plans, Git history, and repository tree; the public addressed-run API remains unplanned and undelivered.
    provider: openai
    model: gpt-5.6-sol
    effort: high
---

# Improvement Request: expose addressed agent runs over the public HTTP API

## Why

Mori's automation engine matches repository events and fires reactions. Kikan contract C5
asks that a matched event be able to address a declared Shikigami agent, so that "a
repository event, matched by mori, fires an agent". Mori is adding an `Agent` reaction
action for exactly this
(`mori://shinzui/mori/plans/150-add-an-agent-automation-action-that-invokes-shikigami-agents-from-reactions`).

That plan originally intended to enqueue a `RunJob` directly onto the shared
`shikigami_run_jobs` pgmq queue, mirroring Shikigami's message shape. **Mori has since
rejected that design on service-boundary grounds** and needs an HTTP surface instead.

The objection is not about Shikigami's queue being unsuitable — it is that reaching into
it makes two independently deployed services one deployment:

- Both services must share a single PostgreSQL database, or mori must hold a second
  connection pool into Shikigami's.
- Shikigami's internal run-job shape becomes part of mori's compile-time surface, so a
  change to how Shikigami schedules work is a breaking change for mori.
- Shikigami loses the ability to change or replace its scheduling substrate without
  coordinating a release with an unrelated service.

An HTTP call restores the boundary: mori states *what* it wants — run this agent with
this payload — and Shikigami owns *how*, including whether a queue is involved at all.

Shikigami already models this concept internally. `Shikigami.Trigger.Enqueue` exports
`enqueueAddressedRun` and `enqueueAddressedRunWithKey`, described as "the producer side of
the IP-7 run-job contract", and `shikigami-server` already owns an `enqueue-run` CLI
command over it. **This request is to put a typed HTTP face on a capability that exists**,
not to build new machinery.

## What mori needs

One vertical on `ShikigamiApi`, in the shape plan 36 established for the health vertical:

```
POST /agents/{agentName}/runs
  request:  { "payload": <json object>, "idempotencyKey": <string> }
  200/202:  { "runId": <string>, "status": <string> }
  404:      unknown agent           (ProblemJSON)
  409:      duplicate idempotency key — returns the existing run
```

Exact paths, names, and status codes are Shikigami's to choose. Four properties are what
mori actually depends on, in priority order:

1. **Idempotency is server-side, on a caller-supplied key.** Mori derives a stable key
   from `(repoId, reactionId, actionIndex)`. The same key must never start a second run.
   Mori's reaction executor can redeliver an event, so without this the boundary is not
   safe to retry across — and mori cannot fix it from its side.

   Note that `enqueueAddressedRun` currently derives its default key from the wall clock
   (`agent <> ":evt:" <> iso8601Show now`), which is *not* stable across retries. The
   endpoint must take the caller's key rather than synthesize one.

2. **Unknown agent is a distinct, non-retryable failure.** Mori reports a configuration
   error to the operator who wrote the reaction, rather than retrying a transport error
   forever. Any typed problem response that distinguishes "this agent does not exist" from
   "try again later" satisfies this.

3. **A run identifier comes back**, so mori can record something in its `ReactionResult`
   that an operator can follow into Shikigami.

4. **Accept-and-schedule is sufficient.** Mori does not need the run to have finished, or
   even started — only to have been durably accepted. A 202 with a run id is a complete
   answer.

## What this is not

- **Not A2A.** IR-6 adopts the Agent2Agent protocol as the surface between independently
  deployed *Shikigami runtimes*, where the caller is itself an agent runtime participating
  in delegation, lineage, and task lifecycle. Mori is not a Shikigami runtime and is not
  delegating; it is an ordinary service asking for one run. Serving that through A2A would
  require mori to implement a protocol whose semantics it does not need. If Shikigami
  later prefers one external surface, this endpoint is a candidate to fold in — but it
  should not wait on A2A, which is a substantially larger commitment.

- **Not a request for a general control API.** Mori needs to *start* runs. Listing,
  cancelling, streaming, or inspecting runs are out of scope here.

- **Not an authorization model.** Mori invokes; it does not decide what the agent may then
  do. Authorization remains Shikigami/kikan's (contract EP-10, shomei). Whatever
  authentication the endpoint requires — bearer token, mTLS, none on a trusted network —
  mori will carry.

## Acceptance

- `ShikigamiApi` gains an agent-run vertical, served by `shikigami-server` and reachable
  through `shikigami-client`'s derived typed client, appearing in the generated
  `docs/api/openapi.json` — the structural guarantee plan 36 established, that a route
  cannot be served without appearing in the document.
- Requesting a run for a declared agent returns a run identifier and results in exactly
  one run.
- Repeating the identical request with the same idempotency key returns the same run and
  starts no second run.
- Requesting a run for an undeclared agent returns a typed, non-retryable problem
  response.
- A wire-compatibility test pins the request and response shapes, in the manner of
  `Shikigami.WireCompatSpec`.

## Non-goals

- Replacing the internal queue path. `enqueueAddressedRun`, the scheduler, and the
  `enqueue-run` CLI command remain exactly as they are; this adds a caller, not a
  migration.
- Changing the `RunJob` wire shape. Plan 47 deliberately froze it as a bare JSON run job,
  and nothing here disturbs that.
- Any mori-side Haskell dependency on Shikigami packages. Mori will bind to the JSON
  contract and pin it with a golden fixture, not link `shikigami-client`.

## References

- `mori://shinzui/mori/plans/150-add-an-agent-automation-action-that-invokes-shikigami-agents-from-reactions`
  — the consuming plan, whose Decision Log records the boundary rationale and whose
  Surprises section carries the 2026-08-07 audit this request came out of.
- `mori://shinzui/mori/masterplans/20-close-the-kikan-integration-and-phase-2-readiness-gaps`
  — the initiative that owns mori's side.
- `docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`
  — established the six-package boundary, the umbrella `ShikigamiApi` record, and the
  API standard a new vertical should follow.
- `docs/improvement-requests/support-a2a-cross-runtime-agent-interoperability.md` — IR-6,
  the adjacent but distinct runtime-to-runtime surface.
- `shikigami-core/src/Shikigami/Trigger/Enqueue.hs` — the existing internal producer this
  endpoint would front.
