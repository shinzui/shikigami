---
id: 90
slug: accept-addressed-agent-runs-over-http-with-server-owned-idempotency
title: "Accept addressed agent runs over HTTP with server-owned idempotency"
kind: exec-plan
created_at: 2026-10-22T02:39:24Z
intention: "intention_01m5gqm5sxeb7bxpd8dsranfy2"
master_plan: "docs/masterplans/15-expose-declared-agents-and-agent-runs-over-the-public-http-api.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-22T02:39:24Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T23:28:37Z
      mode: "implement"
      note: "Implement atomic acceptance ledger and authenticated run submission"
---

# Accept addressed agent runs over HTTP with server-owned idempotency

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan is a child of
`docs/masterplans/15-expose-declared-agents-and-agent-runs-over-the-public-http-api.md` and
implements [IR-8](../improvement-requests/expose-addressed-agent-runs-over-http.md). Read the
MasterPlan's Integration Points section before starting.


## Purpose / Big Picture

An external service can already ask Shikigami which agents exist. After this plan it can ask
Shikigami to run one: `POST /agents/{agentName}/runs` with a body naming the caller's
idempotency key and a JSON object payload answers `202 Accepted` with a stable `runId` and a
`Location` header pointing at the run resource. Repeating the identical request answers
`200 OK` with the same `runId` and starts no second run; reusing the key for a different
payload answers `409 idempotency_key_conflict`; naming an agent that does not exist answers
`404 agent_not_found`; naming one that is disabled, paused, or deactivated answers
`409 agent_not_runnable`. The accepted run is an ordinary run job on the `shikigami_run_jobs`
queue, byte-identical to what `shikigami enqueue-run` produces, so the worker, the scheduler,
and every operator verb treat it like any other run.

This is what `mori://shinzui/mori` needs for its `Agent` reaction action
(`mori://shinzui/mori/plans/281-invoke-shikigami-agents-from-mori-reactions`): a boundary it can
retry across, because its reaction executor can redeliver an event, and a run identifier it can
record. You can see it working with `shikigami-client runs request heartbeat --key demo-1`,
which prints `accepted <runId>`, and a second identical call, which prints `replayed <runId>`
with the same identifier, while `shikigami runs show shikigami.agent-run <runId>` shows the run
once a worker has drained it.


## Progress

- [x] M1 (2026-10-25; concurrency and queue payload tests pass): The acceptance ledger exists: migration `agent-run-requests` creates
      `shikigami.agent_run_requests`; `Shikigami.AgentRun.Ledger.acceptRunRequest` sends the run
      job and inserts the row in one transaction; a core test proves one accept, one replay, one
      conflict, and a two-caller race produce exactly one queue message.
- [x] M2 (2026-10-25; typed wire/schema and database-backed HTTP tests pass): `POST /agents/{agentName}/runs` is served and documented with every arm (202, 200,
      404, 409, 409, 413, 503); the regenerated `docs/api/openapi.json` lists
      `postAgentsByAgentNameRuns`; wire tests pin the request and both success bodies; the
      server test drives every arm against a real database.
- [x] M3 (2026-10-25; 21 Hurl requests and live client accept/replay pass): `shikigami-client runs request` works; `tests/hurl/agent-runs.hurl` proves the
      contract against the live server; IR-8 is marked completed and the acceptance-ledger ADR
      exists.


## Surprises & Discoveries

Hasql `Pool.release` releases connections but deliberately leaves the pool usable;
it cannot simulate a closed store. The store-error test instead removes the ledger
inside its disposable database and proves the acceptance transaction returns `Left`
without retaining a queue send. The installed MultiVerb `WithHeaders` takes three
type arguments, including its handler return type; success arms use the supported
`(body, location)` tuple.


## Decision Log

- Decision: The run key of an HTTP-requested run is `<agentName>:http:<idempotencyKey>` and the
  public `runId` is `runJobWorkflowId` of that key.
  Rationale: the key namespace keeps HTTP runs apart from the `:evt:` and `:sched:` producers,
  and the identifier is the one keiro, the worker's logs, the sink receipts, and `runs show`
  already share; IR-10 requires exactly one definition.
  Date: 2026-10-22

- Decision: Replay versus conflict is decided by a fingerprint of the payload stored on the
  ledger row, not by storing the payload.
  Rationale: the payload is already journaled by keiro once the run starts; storing it twice
  invites drift, and a fingerprint is enough to tell "the same request again" from "a different
  request with a stolen key".
  Date: 2026-10-22

- Decision: Operator runs from `shikigami enqueue-run` do not write the ledger.
  Rationale: IR-8 asks that the CLI remain exactly as it is; those runs remain visible through
  `runs show`, and the status plan serves them when it can verify the agent from the journal.
  Date: 2026-10-22

- Decision: A request payload must be a JSON object of at most 65536 encoded bytes; larger
  answers 413 `payload_too_large`.
  Rationale: the payload becomes the journaled `triggerPayload` of a durable workflow, so an
  unbounded body is an unbounded journal row; the object requirement is IR-8's stated shape.
  Date: 2026-10-22


## Outcomes & Retrospective

Completed 2026-10-25. The acceptance ledger commits exactly one ordinary run
job with the acceptance fact; replay retains its original identifier, timestamp,
and caller. The twenty-request race, rollback/error and exact queue-body checks
pass. API, server, client and core unit suites pass; Hurl passes 21 requests and
the live client prints accepted/replayed with the same UUID. All request arms,
including unavailable storage and directory, have assembled HTTP tests. The
migration/schema-isolation checks and full keiro gate pass with no contract
findings. IR-8 is completed and its bundle validates. ADR 0048 records the ledger
and identity contract. FRIC-6 is accepted: stage core edits before the scaffold
no-op check. Validation uses the inherited isolated Cabal project.


## Context and Orientation

A *run job* is the message that asks a worker to run one declared agent once: the `RunJob`
record in `shikigami-core/src/Shikigami/Agent/RunJob.hs` (agent name, admitted identity,
trigger kind, declared route, occurrence time, trigger payload, idempotency key, delegation
fields). Producers send it to the `shikigami_run_jobs` PGMQ queue through
`shikigami-core/src/Shikigami/Trigger/Enqueue.hs`; `enqueueAddressedRunWithKey` builds and sends
an event-triggered job, `enqueueRunJobTx :: RunJob -> Transaction MessageId` sends one inside a
caller-owned hasql transaction, and `ensureRunQueue` reconciles the queue once at process start.
The operator command `shikigami enqueue-run` in
`shikigami-server/src/Shikigami/Server/Command/EnqueueRun.hs` is the existing producer this
plan fronts: it loads the agent, admits its identity through the lifecycle directory, and sends
the job. The worker in `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs` drains the queue,
re-admits the job (`admitRunJobWith`), and runs the durable agent-run workflow under the
workflow id `runJobWorkflowId job`, which is the job's idempotency key when that text is a valid
keiro workflow id and a deterministic UUIDv5 of it otherwise.
[ADR 0014](../adr/0014-a-run-job-declares-its-route-rather-than-being-guessed.md) is why the
job carries `routeKind = AgentWorkflowRoute` explicitly.

Keiro keys a workflow instance by `(workflow name, workflow id)`; a second message with the
same key would replay the same instance, which is wasteful at best. The dedupe therefore has to
happen before a second message exists, in the process that accepts the request. That is the
*acceptance ledger* this plan adds: a Shikigami-owned table, written in the same transaction as
the queue send, modelled on the receipts of
[ADR 0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md). The
run-skip evidence in `shikigami-core/src/Shikigami/Directory/Store.hs` (`recordRunSkipTx`) is
the precedent for a Shikigami-owned table written through hasql with schema-qualified
statements, and `shikigami-migrations/sql-migrations/2026-08-23-00-41-28-agent-load-state-and-run-skips.sql`
is the precedent migration. New migrations are scaffolded with `just new-migration <slug>` and
checked by `just migration-schema-isolation`.

The HTTP side is as `docs/plans/88-serve-the-declared-agent-catalog-over-http.md` left it:
`AgentApi` in `shikigami-api/src/Shikigami/Agent/Api.hs` with `list` and `show`, mounted under
`agents` in `shikigami-api/src/Shikigami/Api.hs` behind the `Authenticated` combinator from
`docs/plans/89-authenticate-public-api-callers-with-configured-bearer-credentials.md`
(`Shikigami.Caller.Api`), with handlers in `shikigami-server/src/Shikigami/Agent/Handler.hs`
taking an `ApiCaller`, and `ServerEnv` carrying the logger, the catalog
(`Shikigami.Agent.Catalog`), and the directory handle. The problem catalog is
`shikigami-api/src/Shikigami/Api/Problem.hs`. The server opens its store pool in
`Shikigami.Server.Boot.runServer` (`StoreConnection.withStore`) but today keeps it only for the
readiness probe.

Relevant ADRs beyond those named: [ADR 0021](../adr/0021-operator-verbs-wrap-the-owning-library.md)
(Shikigami writes only its own tables and the join; nothing here touches keiro's or kioku's
schema); [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) and
`docs/workflow-versioning.md` (no workflow body under `shikigami-core/src/Shikigami/Agent/` is
changed by this plan; the one edit under that prefix is none, and `Shikigami.Trigger.Enqueue`
is a producer, not a body).


## Plan of Work

### Milestone 1: the ledger and the transactional accept

Scaffold the migration with `just new-migration agent-run-requests` and give it this content:

```sql
-- Accepted HTTP run requests: the HTTP boundary's durable truth before a workflow exists.
CREATE SCHEMA IF NOT EXISTS shikigami;

CREATE TABLE shikigami.agent_run_requests (
  agent_name text NOT NULL,
  idempotency_key text NOT NULL,
  run_id text NOT NULL,
  run_key text NOT NULL,
  payload_fingerprint text NOT NULL,
  requested_by text NOT NULL,
  queue_message_id bigint NOT NULL,
  accepted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agent_name, idempotency_key),
  UNIQUE (agent_name, run_id),
  UNIQUE (run_key)
);

CREATE INDEX agent_run_requests_agent_accepted_idx
  ON shikigami.agent_run_requests (agent_name, accepted_at DESC, run_id);
```

Factor a pure constructor out of `enqueueAddressedRunWithKey` in `Shikigami.Trigger.Enqueue`:
`addressedRunJob :: UTCTime -> AgentIdentity -> Text -> RunRouteKind -> Value -> RunKey ->
RunJob`, and make the existing function call it so the CLI's job and the HTTP job are built by
one function. This is a behaviour-preserving refactor; `shikigami-core/test/Shikigami/WireCompatSpec.hs`
already pins the job's bytes.

Create `shikigami-core/src/Shikigami/AgentRun/Ledger.hs`:

```haskell
httpRunKey :: AgentName -> Text -> RunKey          -- RunKey (agent <> ":http:" <> key)
payloadFingerprint :: Value -> Text                -- UUIDv5 over the canonical encoding

data RunRequestRow = RunRequestRow
  { agentName :: !Text, idempotencyKey :: !Text, runId :: !Text, runKey :: !Text,
    payloadFingerprint :: !Text, requestedBy :: !Text, queueMessageId :: !Int64,
    acceptedAt :: !UTCTime }

data AcceptOutcome = Accepted !RunRequestRow | Replayed !RunRequestRow | Conflicting !RunRequestRow

acceptRunRequest :: Pool -> RunJob -> Text -> IO (Either Text AcceptOutcome)
lookupRunRequest :: Pool -> AgentName -> Text -> IO (Either Text (Maybe RunRequestRow))
```

`payloadFingerprint` hashes `Aeson.encode` of the value with the same UUIDv5 construction
`addressedRunKey` uses (`Data.UUID.V5.generateNamed` over `Shikigami.Id.Name.nameBytes`);
aeson's ordered key map makes the encoding deterministic. `acceptRunRequest pool job
requestedBy` runs one read-committed write transaction: send the job with `enqueueRunJobTx`,
then `INSERT ... ON CONFLICT (agent_name, idempotency_key) DO NOTHING RETURNING accepted_at`
with the row derived from the job (`run_id` is `(runJobWorkflowId job).unWorkflowId`,
`payload_fingerprint` is the fingerprint of `job.triggerPayload`). If the insert returned a
row, the transaction commits and the outcome is `Accepted`. If it returned nothing, call
`Hasql.Transaction.condemn` so the queue send rolls back with the transaction, then read the
existing row in a fresh statement and answer `Replayed` when its fingerprint equals the new
job's and `Conflicting` otherwise. Every statement is schema-qualified. Hasql errors come back
as `Left` with a secret-free rendering, exactly as `recordRunSkip` does.

Add `shikigami-core/test/Shikigami/AgentRun/LedgerSpec.hs` against a migrated database
(`Shikigami.Migrations.TestSupport.withShikigamiFreshDatabase`, as
`shikigami-core/test/Shikigami/EnqueueHardeningSpec.hs` does): the first accept is `Accepted`
and the queue holds one message whose body decodes to the job; the same job again is `Replayed`
and the queue still holds one message; the same key with a different payload is `Conflicting`;
twenty concurrent accepts of the same job (`Control.Concurrent.Async.replicateConcurrently`)
yield one `Accepted`, nineteen `Replayed`, and one message; an unavailable ledger in a disposable database yields `Left`.

### Milestone 2: the route and the handler

Create `shikigami-api/src/Shikigami/AgentRun/Api.hs`:

```haskell
data AgentRunRequest = AgentRunRequest { idempotencyKey :: !Text, payload :: !Value }
  -- FromJSON rejects an empty key, a key over 200 characters or containing control
  -- characters, and a payload that is not a JSON object; a rejection is a body parse
  -- failure and therefore an invalid_body problem.

data AgentRunAccepted = AgentRunAccepted
  { runId :: !Text, agentName :: !Text, idempotencyKey :: !Text,
    status :: !Text {- "accepted" -}, acceptedAt :: !UTCTime }

data AgentRunApi mode = AgentRunApi
  { request :: mode :- ReqBody '[JSON] AgentRunRequest
                     :> MultiVerb 'POST '[JSON] RunRequestResponses RunRequestResult
  }
```

`RunRequestResponses` is, in order: 202 "Run accepted" and 200 "Run already accepted", both
`AgentRunAccepted` wrapped in `WithHeaders '[Header "Location" Text]` so the resource path
`/agents/{agentName}/runs/{runId}` is returned; then `RespondAs ProblemJSON` arms for 404
(`agent_not_found`), 409 (`agent_not_runnable`), 409 (`idempotency_key_conflict`), 413
(`payload_too_large`), and 503 (`unavailable`). The two 409 arms carry different descriptions
and the client distinguishes them by `code`. Write the `AsUnion` instance by hand. Add
`AgentNotRunnable`, `IdempotencyKeyConflict`, and `PayloadTooLarge` to `ProblemCode` with the
codes, titles, statuses, and retryability the MasterPlan's Integration Points table states. Add
the field `runs :: mode :- Capture "agentName" AgentName :> "runs" :> NamedRoutes AgentRunApi`
to `AgentApi`. Give the DTOs `ToSchema` instances from the same Aeson options as their codecs.

Add `pool :: Pool` to `ServerEnv`, pass the store's pool from `runServer` (it is already open
there), call `ensureRunQueue` at boot and refuse to start if it fails (the CLI does the same),
and extend `newServerEnvWith` and its test call sites.

Create `shikigami-server/src/Shikigami/AgentRun/Handler.hs` with `agentRunServer :: ServerEnv ->
ApiCaller -> AgentName -> AgentRunApi (AsServerT ServerM)`. The request handler, in order:
looks the agent up in the catalog and answers the 404 arm when absent; answers the 409
`agent_not_runnable` arm with detail "The agent is disabled in its declaration." when
`enabled` is false; calls `Directory.identityAdmission env.directory (declared principal)
name`, answering 503 when the reason begins with `directory unavailable` and the 409
`agent_not_runnable` arm with the reason otherwise; answers 413 when the encoded payload
exceeds 65536 bytes; builds the job with `addressedRunJob now identity name
AgentWorkflowRoute payload (httpRunKey name key)`; calls `acceptRunRequest env.pool job
caller.callerId`; and maps `Accepted` to 202, `Replayed` to 200, `Conflicting` to the 409
`idempotency_key_conflict` arm, and `Left` to 503. Log one line per outcome
(`server.run.accepted`, `server.run.replayed`, `server.run.conflict`) with agent, run id, and
caller, never the payload. Wire `runs = agentRunServer env caller` into `agentServer`.

Regenerate `docs/api/openapi.json`; extend `OpenApiSpec` with the new path and operation id;
add `shikigami-api/test/Shikigami/AgentRun/ApiSpec.hs` pinning the exact bytes of one request
and one accepted body and validating both against their schemas; extend `ProblemSpec` for the
three codes; extend `DispatchSpec`'s capture substitution. Add
`shikigami-server/test/Shikigami/AgentRun/HandlerSpec.hs` against a fresh database with a
catalog of a runnable agent and a disabled one and a static directory holding one paused
principal, driving the assembled application through `Shikigami.Client`: 202 with a `Location`
header and a `runId` equal to the workflow id of the expected key; the same request again is
200 with the same body; a different payload is 409 `idempotency_key_conflict`; an unknown agent
is 404; the disabled agent and the paused agent are 409 `agent_not_runnable`; a body whose
payload is an array is 400 `invalid_body`; a 70 KiB payload is 413; after two identical posts
the queue holds one message.

### Milestone 3: client, hurl, request status, ADR

Add `runs request AGENT --key KEY [--payload JSON] [--server URL]` to
`shikigami-client/src/Shikigami/Client/Command.hs`, printing `accepted <runId>` or
`replayed <runId>` and the `Location`, exiting 1 on any problem response with the code on
stderr. Update the subcommand test.

Add `tests/hurl/agent-runs.hurl`, every block carrying `Authorization: Bearer {{token}}`: a
post for `heartbeat` with key `hurl-1` is 202 with `Location` matching
`/agents/heartbeat/runs/`, captures `run_id` from the body; the same post is 200 with the same
`runId`; the same key with a different payload is 409 `idempotency_key_conflict`; an unknown
agent is 404 `agent_not_found`; `disabled-heartbeat` is 409 `agent_not_runnable`; a body
without `idempotencyKey` is 400 `invalid_body`. The runner's database is disposable and no
worker drains it, so the message simply remains queued.

Move IR-8 to completed: set `status: completed` in
`docs/improvement-requests/expose-addressed-agent-runs-over-http.md`, keep its `targetPlan`,
rewrite its Status section to name this plan and the route, refresh `generated.at`, add a dated
entry to `docs/improvement-requests/log.md`, update the status table in
`docs/improvement-requests/index.md`, and run `just improvement-requests-validate`. Create the
acceptance-ledger ADR the MasterPlan names (ledger as the HTTP boundary's durable truth, the
transactional accept with `condemn`, replay versus conflict by fingerprint, and the run identity
contract), allocating the next free number.


## Concrete Steps

All commands run from the repository root inside the development shell.

```bash
nix develop -c just new-migration agent-run-requests
nix develop -c just migration-schema-isolation
nix develop -c just migrate
nix develop -c cabal build all
nix develop -c cabal test shikigami-core shikigami-api shikigami-server shikigami-client
nix develop -c cabal run shikigami-openapi
git diff --stat docs/api/openapi.json
nix develop -c just keiro-gate
```

The keiro gate must report no durable-contract change, because this plan edits no workflow
body and no file under `domain/`.

Start the server in bearer mode and request a run twice:

```bash
PG_CONNECTION_STRING="host=$PWD/db dbname=shikigami user=$(id -un)" \
SHIKIGAMI_API_TOKEN=0123456789abcdefXYZ \
  nix develop -c cabal run shikigami-server -- --host 127.0.0.1 --port 8080 --set http.auth.mode=bearer
nix develop -c cabal run shikigami-client -- --token 0123456789abcdefXYZ \
  runs request heartbeat --key demo-1 --payload '{"task":"say hello"}'
nix develop -c cabal run shikigami-client -- --token 0123456789abcdefXYZ \
  runs request heartbeat --key demo-1 --payload '{"task":"say hello"}'
```

Expected:

```text
accepted <the UUIDv5 workflow id>
replayed <the same UUIDv5 workflow id>
```

The colon-delimited HTTP run key fails Keiro's workflow-id grammar, so
`runJobWorkflowId` derives a deterministic UUIDv5. Use the returned `runId` verbatim
with `shikigami runs show shikigami.agent-run <runId>` after a worker drains it.


## Validation and Acceptance

Required: the LedgerSpec race proves exactly one queue message for twenty concurrent accepts;
every arm of the route is exercised by HandlerSpec against a real database; the wire pins and
the OpenAPI drift check pass; `just hurl` passes; the keiro gate passes; the two client calls
above print the same identifier. The early integration check named by the MasterPlan is the
LedgerSpec race, which must pass before the route is built.

IR-8's own acceptance maps as follows: the vertical appears in `docs/api/openapi.json` and is
reachable through `shikigami-client` (M2, M3); requesting a declared agent returns a run
identifier and results in exactly one run (M1 race, M2); repeating with the same key returns
the same run and starts no second one (M1, M2, hurl); an undeclared agent returns a typed
non-retryable problem (M2, hurl); a wire-compatibility test pins the shapes (M2).


## Idempotence and Recovery

The migration is additive and pg-migrate records it; rerunning `just migrate` is a no-op. The
accept transaction is the idempotency mechanism itself: a crash after the send and before the
commit rolls both back, and the caller's retry starts from nothing. If the server starts but
`ensureRunQueue` fails, the process exits with the error on stderr; run `just migrate` and
start again. To retract an accepted request before a worker drains it, an operator uses the
mounted `pgmq` verbs on the queue, not the ledger; the ledger row stays as the record that the
request was accepted.


## Interfaces and Dependencies

Hard prerequisites, both whole plans: `docs/plans/88-serve-the-declared-agent-catalog-over-http.md`
(catalog, directory handle, `AgentName` capture, `agent_not_found`, `AgentApi`) and
`docs/plans/89-authenticate-public-api-callers-with-configured-bearer-credentials.md`
(`Authenticated` mount, `ApiCaller`).

This plan owns, for `docs/plans/91-expose-agent-run-status-and-history-over-http.md`: the table
`shikigami.agent_run_requests`; `Shikigami.AgentRun.Ledger` (`httpRunKey`,
`payloadFingerprint`, `RunRequestRow`, `acceptRunRequest`, `lookupRunRequest`);
`Shikigami.AgentRun.Api` (`AgentRunApi` with `request`; the status plan adds `show` and `list`);
`Shikigami.AgentRun.Handler` (`agentRunServer`); the `pool` field of `ServerEnv`; the three
problem codes; `tests/hurl/agent-runs.hurl`; and the `runs request` client command.

Libraries whose choice matters: `hasql`, `hasql-transaction` (`condemn`), `hasql-pool`,
`pgmq-hasql` through `enqueueRunJobTx`, `uuid` for the fingerprint, and `servant`'s
`WithHeaders` for the `Location` header. Verify the released versions against `cabal.project`
and the registry before changing a bound.
