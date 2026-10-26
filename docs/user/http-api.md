---
type: "Guide"
title: "HTTP API — agents and runs"
description: "Authenticate, discover declared agents, request an idempotent run, and follow its lifecycle through the typed client or HTTP."
docId: "DOC-14"
tags: ["http", "agents", "runs"]
generated:
  by: process:shikigami-documentation-refresh
  at: 2026-10-25T00:00:00Z
---

# HTTP API — agents and runs

The public API serves the deployment's declared-agent catalog and durable agent
runs. Use `shikigami-client` from another process, or integrate against the
[OpenAPI contract](../api/openapi.json). The server accepts work into PostgreSQL;
`shikigami-worker` executes it independently.

## Start a local server and worker

Follow [Getting Started](getting-started.md) to build and migrate the database.
Server and worker must use the same database and agent directory. Directory
loading is not recursive. Both roles need the execution and authorization
configuration appropriate to the selected agents.

For local bearer authentication, set these in each server/client terminal:

```sh
export SHIKIGAMI_HTTP_AUTH_MODE=bearer
export SHIKIGAMI_HTTP_AUTH_CALLER=local-operator
export SHIKIGAMI_API_TOKEN=local-development-token-change-me
```

Start these roles in separate terminals:

```sh
cabal run shikigami-server:exe:shikigami-server -- --set agents.directory=agents
cabal run shikigami-worker -- --agents agents
```

The default server URL is `http://localhost:8080`. Each client subcommand accepts
`--server URL`. Authentication defaults to disabled; bearer mode requires a
token of at least sixteen characters and applies to every `/agents` route.
Health probes remain public. The client reads `SHIKIGAMI_API_TOKEN`, or accepts
a global `--token TOKEN` before the subcommand. See
[configuration](../operations/configuration.md#inbound-api-authentication).

The configured credential identifies one caller. There are no per-caller agent
permissions in this verifier. Agent lifecycle, execution profiles, sink grants,
and exact-action authorization still apply during admission and execution.

## Discover agents

```sh
cabal run shikigami-client -- agents list --first 10
cabal run shikigami-client -- agents show heartbeat
```

`GET /agents` returns a Relay connection with `edges` and `pageInfo`.
`GET /agents/{agentName}` returns one agent. Views include description,
enablement, trigger/behavior kinds, sink kinds, delegates, declared principal,
lifecycle, and `runnable`.

Declarations are loaded at server boot, including disabled manifests; restart
the server to reload edits. Lifecycle comes from the current directory. With
directory checks disabled, the view says `unverified`. `runnable` describes
enablement and lifecycle admission; it does not prove that a provider, profile,
tool lease, or sink will succeed. An unavailable directory returns 503.

Agent pages sort by name ascending. Use `--after CURSOR` with the client or
`?first=10&after=CURSOR` over HTTP. HTTP also supports `last`/`before` for backward
pagination. The default size is 50 and the maximum is 200. Use cursors issued by
the same route; malformed cursors and invalid sizes return 400.

## Request a run

```sh
cabal run shikigami-client -- runs request heartbeat \
  --key heartbeat-manual-1 --payload '{"source":"manual"}'
```

The command prints the run ID and its `Location`. The equivalent request is:

```sh
curl -i http://localhost:8080/agents/heartbeat/runs \
  -H "Authorization: Bearer $SHIKIGAMI_API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"idempotencyKey":"heartbeat-manual-1","payload":{"source":"manual"}}'
```

The first acceptance returns **202**, with `runId`, `agentName`,
`idempotencyKey`, `status: "accepted"`, `acceptedAt`, and a `Location` header.
Acceptance and queue send commit together. Use the returned run ID verbatim;
it is also the durable workflow ID.

Keys are scoped to the agent, contain 1–200 characters, and cannot contain control
characters. Repeating a key with the same JSON payload returns **200** and the
original acceptance without another queued job. Reusing it with different payload
returns **409** (`idempotency_key_conflict`). JSON object member order does not
change the payload identity. Replays still undergo current declaration/lifecycle
admission, and their response remains an acceptance receipt; read status separately.

`payload` must be a JSON object whose encoded size is at most 65,536 bytes.
Missing fields or invalid values return 400; an oversized payload returns 413.
Unknown agents return 404, disabled or lifecycle-refused agents return 409, and
unavailable stores/directories return 503. Invalid bearer credentials return
401 with `WWW-Authenticate`. Errors use `application/problem+json`.

An HTTP request addresses the agent directly, independently of its declared
schedule, stream, or event matcher. Acceptance does not establish execution or
sink delivery. A run can stay accepted until a worker drains its queue.

## Follow status and history

Replace `RUN_ID` with the ID returned above:

```sh
cabal run shikigami-client -- runs show heartbeat RUN_ID
cabal run shikigami-client -- runs wait heartbeat RUN_ID --timeout 600 --interval 5
cabal run shikigami-client -- runs list heartbeat --first 10
```

`GET /agents/{agentName}/runs/{runId}` derives status from acceptance, workflow
journals, session state, and admission/dead-letter receipts:

| Status | Meaning |
| --- | --- |
| `accepted` | Durable request exists; no workflow or terminal refusal is visible yet. |
| `running` | Workflow is running or suspended, including a durable human wait. |
| `succeeded` | Workflow completed with a successful `complete` step. |
| `failed` | Admission refusal, dead letter, behavior failure, or workflow failure. |
| `cancelled` | Workflow was cancelled. |

The response includes available acceptance/start/completion timestamps, session
ID, a bounded successful summary, and structured failure kind/reason. Failure
kinds are `refused`, `dead_lettered`, `behavior_failed`, and `workflow_failed`.
A storage failure returns 503; it does not mean the agent failed. A missing run
or a run belonging to another agent returns 404. Status can also find non-HTTP
agent runs once their workflow has journaled ownership, with no HTTP acceptance
timestamp.

`runs wait` polls using seconds for timeout/interval and exits **0** on success,
**1** on failure/cancellation, **2** on timeout, and **3** on a request error.

`GET /agents/{agentName}/runs` lists **HTTP acceptance receipts**, newest first,
with run ID as the tie-breaker. Rows contain the key, accepting caller, acceptance
time, and disposition (`accepted` or `dead_lettered`). This is not a list of all
scheduled, stream, or delegated runs, and disposition is not the workflow's current
status. Use each row's run ID for lifecycle details. Pagination has the same
50-default/200-maximum bounds as the catalog.

## Recover a pre-workflow dead letter

A job can exhaust retries before a workflow exists. A status read reconciles a
retained matching dead letter and persists `failed` / `dead_lettered`. It leaves
the entry available, increments its DLQ read count, and can be delayed by an
operator's inspection lease. Retain that evidence until the terminal receipt is
recorded; archive, redrive, or purge beforehand can erase the only evidence.
History listing alone does not perform this reconciliation.

The [operator runbook](../operations/operator-cli.md) documents the retention and
recovery procedure, including `shikigami runs show shikigami.agent-run RUN_ID --json`
before a workflow exists. Workflow state takes precedence if a redrive later
creates a workflow. Sink delivery remains a separate receipt: successful agent
completion is not a remote delivery acknowledgement.

The current HTTP surface does not expose manifest editing, cancellation commands,
grants, approval resolution, decision reports, or signed attestations. Use the
[CLI reference](cli.md) and operator tools for those implemented administrative
operations; signing remains unimplemented.
