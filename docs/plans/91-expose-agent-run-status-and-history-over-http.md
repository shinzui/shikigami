---
id: 91
slug: expose-agent-run-status-and-history-over-http
title: "Expose agent-run status and history over HTTP"
kind: exec-plan
created_at: 2026-10-22T02:39:24Z
intention: "intention_01m5gqm5sxeb7bxpd8dsranfy2"
master_plan: "docs/masterplans/15-expose-declared-agents-and-agent-runs-over-the-public-http-api.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-22T02:39:24Z
---

# Expose agent-run status and history over HTTP

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan is a child of
`docs/masterplans/15-expose-declared-agents-and-agent-runs-over-the-public-http-api.md` and
implements [IR-10](../improvement-requests/expose-agent-run-status-over-http.md). Read the
MasterPlan's Integration Points section before starting.


## Purpose / Big Picture

A caller that requested a run and received a `runId` can now follow it:
`GET /agents/{agentName}/runs/{runId}` answers one closed lifecycle value, `accepted`,
`running`, `succeeded`, `failed`, or `cancelled`, with the acceptance, start, and completion
times, the kioku session identifier once one exists, a bounded summary on success, and a
bounded, kind-tagged failure reason otherwise. An unknown identifier answers `404
run_not_found`, and a database outage answers `503 unavailable`, never a false `failed`.
`GET /agents/{agentName}/runs` lists the runs requested for an agent as a relay-paginated page
of acceptance facts, newest first. Operators get the same classification from
`shikigami runs show --json`, which gains a `lifecycle` object derived by the same code.

This is the second half of what `mori://shinzui/mori` needs: its plan
`mori://shinzui/mori/plans/282-track-agent-runs-to-terminal-workflow-outcomes` polls this route
and closes a dependency-cascade step only when the agent has actually finished. You can see it
working with `shikigami-client runs wait heartbeat <runId>`, which polls until the run is
terminal and exits 0 on `succeeded`.


## Progress

- [ ] M1: `Shikigami.AgentRun.Status.deriveRunStatus` classifies a run from the ledger, keiro,
      kioku, and the run-skip evidence; the ledger gains a dead-letter disposition written by the
      worker; a worker-suite test produces every lifecycle value on real runs and a store outage
      yields an error rather than `failed`; `shikigami runs show --json` reports `lifecycle`.
- [ ] M2: `GET /agents/{agentName}/runs/{runId}` and `GET /agents/{agentName}/runs` are served
      and documented; the regenerated `docs/api/openapi.json` lists
      `getAgentsByAgentNameRunsByRunId` and `getAgentsByAgentNameRuns`; wire tests pin every
      lifecycle value and optional field; the relay conformance walk passes on the list route.
- [ ] M3: `shikigami-client runs show`, `runs list`, and `runs wait` work; the hurl suite covers
      the accepted, unknown, cross-agent, and list cases; IR-10 is marked completed and the
      status-composition ADR exists.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The closed lifecycle is `accepted`, `running`, `succeeded`, `failed`, and
  `cancelled`; a failure carries a `kind` of `refused`, `dead_lettered`, `behavior_failed`, or
  `workflow_failed`.
  Rationale: IR-10 requires at least the first four; keiro's own vocabulary has a distinct
  cancelled state that an operator can produce with `wf cancel`, and folding it into `failed`
  would lie. The failure kinds let a caller tell a configuration refusal from a run that
  executed and failed without a second status field.
  Date: 2026-10-22

- Decision: Success is read from the journal, not from the keiro status alone. A `WfCompleted`
  instance is `succeeded` only when its `complete` step is recorded as produced; otherwise it is
  `failed`.
  Rationale: the agent-run workflow completes normally with a `Left` failure (a permanent
  behaviour or approval failure ends in `fail-session`, and the worker dead-letters the job),
  so `WfCompleted` means "the workflow ran to its end", not "the agent succeeded".
  Date: 2026-10-22

- Decision: The run list returns ledger facts only, with no live status per row.
  Rationale: live status costs a keiro read, a journal read, and a kioku read per run; a page of
  fifty would multiply that by fifty. The detail route is the status; the list is the index.
  Date: 2026-10-22

- Decision: The dead-letter disposition is recorded by the worker on the ledger, best effort,
  after the job outcome is known.
  Rationale: a job that is dead-lettered before any workflow instance exists (for example after
  the queue's retry budget is exhausted by store failures) has no keiro row to read, and
  without a disposition the run would report `accepted` forever, which violates IR-10's
  acceptance. The write is additive, outside every workflow body, and ignored for runs with no
  ledger row.
  Date: 2026-10-22


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

An agent run's durable state lives in two libraries that know nothing about each other. *Keiro*
owns the workflow instance: `Keiro.Workflow.Instance.lookupInstance name id` returns a
`WorkflowInstanceRow` with `status` (`WfRunning`, `WfSuspended`, `WfCompleted`, `WfCancelled`,
`WfFailed`), `generation`, `attempts`, `lastError`, `createdAt`, `updatedAt`, and
`completedAt`, and `Keiro.Workflow.loadStepIndex name id generation` returns the recorded step
results as `Map Text Value`. *Kioku* owns the session: `Kioku.Session.getById space sid` returns
a `SessionRow` with `status` (`running`, `awaiting`, `completed`, `failed`, `interactive`),
`summary`, `errorMessage`, `startedAt`, and `completedAt`. The agent-run workflow in
`shikigami-core/src/Shikigami/Agent/Workflow.hs` journals its steps under fixed names:
`ingest-job` (the `RunJob` itself), `lookup-agent`, `open-session` (the session id, wrapped in
`StepResult` so a kioku refusal is `StepRefused detail`), `record`, `complete` on success, and
`fail-session` on failure. The operator command `shikigami runs show` in
`shikigami-server/src/Shikigami/Server/Command/Runs.hs` already composes exactly these reads
(`gather`, `sessionStep`, `resolveSession`); its module comment explains why there is no SQL,
and [ADR 0021](../adr/0021-operator-verbs-wrap-the-owning-library.md) and Keiro's
`mori://shinzui/keiro/okf/adrs/concepts/ADR-28` make that a rule: read keiro and kioku only
through their exported operations. The worker in
`shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs` maps workflow outcomes to queue
outcomes in `agentJobOutcome`: a `Completed (Left PermanentAgentRunFailure)`, a `Cancelled`, or
a `Failed` becomes `Dead reason` and the message goes to the dead-letter queue; a lifecycle
refusal at drain time is recorded in `shikigami.run_skips` by `recordRunSkip`
(`shikigami-core/src/Shikigami/Directory/Store.hs`) with stage `drain` and the job's
idempotency key, and the message is acknowledged.

The previous plan, `docs/plans/90-accept-addressed-agent-runs-over-http-with-server-owned-idempotency.md`,
added the acceptance ledger `shikigami.agent_run_requests` and `Shikigami.AgentRun.Ledger`
(`httpRunKey`, `RunRequestRow`, `lookupRunRequest`), the `AgentRunApi` record in
`shikigami-api/src/Shikigami/AgentRun/Api.hs` with its `request` field, the handler module
`shikigami-server/src/Shikigami/AgentRun/Handler.hs`, and the `pool` field of `ServerEnv`. The
public `runId` is the keiro workflow id of the run key, and the workflow name of every agent
run is `Shikigami.Agent.Workflow.Name.agentRunWorkflowName` (`shikigami.agent-run`). Relay
pagination over a Shikigami-owned table uses `Relay.Pagination.Hasql.paginate` with a
`SortSpec` of typed key columns; the standard is
`mori://shinzui/haskell-jitsurei/docs/api-relay-pagination` and the catalog plan
`docs/plans/88-serve-the-declared-agent-catalog-over-http.md` already uses the same packages.

Two ADRs bound this plan's shape beyond those named.
[ADR 0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md) is the
precedent for a Shikigami-owned receipt written by the worker after a library boundary, which
the dead-letter disposition copies. [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md)
and `docs/workflow-versioning.md` forbid changing a workflow body without a patch; this plan
adds no step and changes no file under `shikigami-core/src/Shikigami/Agent/` or
`shikigami-core/src/Shikigami/Flow/`, and proves it with `just keiro-gate`.


## Plan of Work

### Milestone 1: the classification, the disposition, and the operator view

Scaffold `just new-migration agent-run-request-dispositions` adding to
`shikigami.agent_run_requests` the columns `disposition text NOT NULL DEFAULT 'accepted' CHECK
(disposition IN ('accepted', 'dead_lettered'))`, `disposition_detail text`, and
`disposition_at timestamptz`. Extend `Shikigami.AgentRun.Ledger` with `recordDeadLetter :: Pool
-> RunKey -> Text -> IO (Either Text Bool)` (true when a row was updated, false when the key
has no ledger row) and `listRunRequests`, a keyset page over the table ordered by `accepted_at
DESC, run_id ASC` built with `Relay.Pagination.Hasql.paginate` and a `SortSpec` of
`timestamptzKey` and `textKey`.

Create `shikigami-core/src/Shikigami/AgentRun/Status.hs`:

```haskell
data RunLifecycle = Accepted | Running | Succeeded | Failed | Cancelled
data RunFailureKind = Refused | DeadLettered | BehaviorFailed | WorkflowFailed
data RunFailure = RunFailure { kind :: !RunFailureKind, reason :: !Text }  -- reason is bounded
data RunStatusView = RunStatusView
  { runId :: !Text, agentName :: !Text, lifecycle :: !RunLifecycle, trigger :: !(Maybe Text),
    acceptedAt :: !(Maybe UTCTime), startedAt :: !(Maybe UTCTime), completedAt :: !(Maybe UTCTime),
    sessionId :: !(Maybe Text), summary :: !(Maybe Text), failure :: !(Maybe RunFailure) }

data RunFacts = RunFacts   -- everything gathered, before classification
  { request :: !(Maybe RunRequestRow), instance_ :: !(Maybe WorkflowInstanceRow),
    steps :: !(Map Text Value), session :: !(Maybe SessionRow), skip :: !(Maybe RunSkip) }

gatherRunFacts :: Pool -> AgentName -> Text -> IO (Either Text (Maybe RunFacts))
classifyRun :: AgentName -> Text -> RunFacts -> RunStatusView
deriveRunStatus :: Pool -> AgentName -> Text -> IO (Either Text (Maybe RunStatusView))
```

`gatherRunFacts` reads the ledger row by `(agent, runId)`, then keiro's instance for
`(agentRunWorkflowName, WorkflowId runId)`, then the step index for the instance's generation,
then the session named by `open-session` through kioku, then the drain-stage run skip for the
run key. If neither a ledger row nor an instance exists the result is `Nothing`. If an instance
exists without a ledger row, the run was produced by the CLI, a stream, or a schedule: decode
the `ingest-job` step as a `RunJob` and treat the run as unknown unless its `agentName` equals
the requested agent, so one agent's runs are never readable under another agent's path. Any
store error is `Left`; it is never turned into a lifecycle value.

`classifyRun` is pure and applies this precedence: a `WfCancelled` instance is `Cancelled`; a
`WfFailed` instance is `Failed` with kind `workflow_failed` and the bounded `lastError`; a
`WfRunning` or `WfSuspended` instance is `Running`; a `WfCompleted` instance is `Succeeded`
when the `complete` step decodes as `StepProduced ()`, otherwise `Failed` with kind
`behavior_failed` and a reason taken from the session's `errorMessage`, else from a
`StepRefused` detail on `open-session`, `record`, or `complete`, else from `lastError`, else
the fixed text "run completed without a successful session"; with no instance, a ledger
disposition of `dead_lettered` is `Failed` with kind `dead_lettered` and the stored detail; a
drain-stage run skip is `Failed` with kind `refused` and its reason; otherwise the run is
`Accepted`. Times come from the ledger (`acceptedAt`), the instance (`createdAt` as
`startedAt`, `completedAt`), and the session; `summary` is the session summary bounded to 2000
characters; every reason passes through `Shikigami.Behavior.Error.boundedBehaviorDetail`;
`trigger` is the `ingest-job` job's trigger kind rendered as `event`, `stream`, `schedule`, or
`delegation`.

In the worker, after `handleRunJob` has decided its `JobOutcome` and before returning it, call
`recordDeadLetter` with the job's idempotency key when the outcome is `Dead reason`; log
`worker.job.disposition_failed` on `Left` and continue, because the queue outcome is the
authority and the ledger is advisory. Add a `WorkerSpec` case: a job whose ledger row exists and
whose workflow fails permanently leaves the row `dead_lettered` with the reason; a job with no
ledger row leaves nothing.

Change `Shikigami.Server.Command.Runs` so `runs show --json` adds a `lifecycle` object
(`status`, optional `failure`) computed by `classifyRun` over the facts it already gathers plus
a ledger lookup, leaving the text rendering and every existing JSON key unchanged.

Add `shikigami-workers/test/Shikigami/AgentRun/StatusSpec.hs` against a fresh database,
reusing the job-driving fixtures of `shikigami-workers/test/Shikigami/Agent/RunJob/WorkerSpec.hs`:
a ledger row alone classifies as `accepted`; a job driven through `handleRunJob` with the stub
provider and a succeeding declaration classifies as `succeeded` with a session id and a
summary; a declaration whose behavior fails permanently classifies as `failed` with kind
`behavior_failed`; a paused principal in a static directory classifies as `failed` with kind
`refused`; a dead-lettered job without an instance classifies as `failed` with kind
`dead_lettered`; `Keiro.Workflow.Instance.cancelWorkflow` on a running instance classifies as
`cancelled`; an instance whose `ingest-job` names another agent is unknown under this agent;
a closed pool yields `Left`.

### Milestone 2: the two routes

Extend `Shikigami.AgentRun.Api` with the wire types and fields:

```haskell
data AgentRunStatus = AgentRunStatus
  { runId :: !Text, agentName :: !Text, status :: !Text, trigger :: !(Maybe Text),
    acceptedAt :: !(Maybe UTCTime), startedAt :: !(Maybe UTCTime), completedAt :: !(Maybe UTCTime),
    sessionId :: !(Maybe Text), summary :: !(Maybe Text), failure :: !(Maybe RunFailureView) }
data RunFailureView = RunFailureView { kind :: !Text, reason :: !Text }
data RunRequestView = RunRequestView
  { runId :: !Text, idempotencyKey :: !Text, acceptedAt :: !UTCTime, requestedBy :: !Text,
    disposition :: !Text }

-- added to AgentRunApi
show :: mode :- Capture "runId" Text :> MultiVerb 'GET '[JSON] RunShowResponses RunShowResult
list :: mode :- RelayPage 50 200 :> MultiVerb 'GET '[JSON] RunListResponses RunListResult
```

`RunShowResponses` is 200 "The run's lifecycle" `AgentRunStatus`, then `RespondAs ProblemJSON`
arms for 404 `agent_not_found`, 404 `run_not_found`, and 503. `RunListResponses` is 200 "A page
of accepted run requests" `Connection RunRequestView`, then 400 (`invalid_url`, a cursor that
does not belong to the route), 404 `agent_not_found`, and 503. Add `RunNotFound` to
`ProblemCode` (`run_not_found`, 404, not retryable, title "Run not found"). Give the DTOs
schemas from their Aeson options; `status` and `kind` are documented as enumerations in their
`ToSchema` instances so the OpenAPI document lists the closed vocabularies.

In `Shikigami.AgentRun.Handler`, the show handler checks the catalog (404 `agent_not_found`),
calls `deriveRunStatus env.pool agent runId`, maps `Nothing` to `run_not_found`, `Left` to 503,
and renders the view (`status` and `kind` as the lowercase snake-case words of the Decision
Log). The list handler checks the catalog, calls `listRunRequests` with the validated
`PageRequest`, maps a cursor error to the 400 arm and a store error to 503. The run-id capture
is plain `Text` bounded by the same length and character rules as the idempotency key; a value
outside them is 404 rather than 400, because a caller cannot tell the two apart usefully.

Regenerate `docs/api/openapi.json`; extend `OpenApiSpec` with the two operations; extend
`shikigami-api/test/Shikigami/AgentRun/ApiSpec.hs` with literal pins of one status body per
lifecycle value (including a `failure` object and the null optional fields of an `accepted`
run) and one `RunRequestView`; extend `ProblemSpec` and `DispatchSpec` (substitute a known run
id). Extend `shikigami-server/test/Shikigami/AgentRun/HandlerSpec.hs`: a run accepted through
the request route reads back as `accepted` with the same `acceptedAt`; an unknown run id is
404 `run_not_found`; the run read under another agent's path is 404; after
`Keiro.Workflow.runWorkflow agentRunWorkflowName (WorkflowId runId) (pure ())` has created a
completed instance with no `complete` step, the run reads as `failed` with kind
`behavior_failed`; the list route returns the accepted run first and `testConformance` walks
seven seeded rows with page size three.

### Milestone 3: client, hurl, request status, ADR

Add to the client: `runs show AGENT RUN_ID` printing the status as labelled lines and exiting
1 on a problem; `runs list AGENT [--first N] [--after CURSOR]` printing one line per edge and
the end cursor; `runs wait AGENT RUN_ID [--timeout SECONDS] [--interval SECONDS]` polling
`runs show` every interval (default 5) until the status is terminal or the timeout (default
600) elapses, exiting 0 on `succeeded`, 1 on `failed` or `cancelled`, 2 on timeout, and 3 on a
transport or problem response, printing each observed status change. Update the subcommand
test.

Extend `tests/hurl/agent-runs.hurl` after the request blocks: `GET` of the captured run is 200
`application/json` with `status` `accepted`, `acceptedAt` present, `sessionId` null, and
`failure` null; `GET /agents/heartbeat/runs/no-such-run` is 404 `application/problem+json` with
code `run_not_found`; `GET /agents/disabled-heartbeat/runs/{{run_id}}` is 404 `run_not_found`;
`GET /agents/heartbeat/runs?first=10` is 200 with an edge whose node's `runId` equals the
captured id; `GET /agents/heartbeat/runs?first=0` is 400 `application/problem+json`.

Move IR-10 to completed in the same way plan 90 moved IR-8 (status, Status section, log entry,
index table, `just improvement-requests-validate`). Add the HTTP equivalents to the `runs show`
section of `docs/operations/operator-cli.md`. Create the status-composition ADR the MasterPlan
names: HTTP reads over keiro and kioku follow ADR 0021 and compose owning-library operations
with Shikigami-owned receipts; the classification precedence above is the contract; a store
outage is never rendered as a failed run. Allocate the next free number.


## Concrete Steps

All commands run from the repository root inside the development shell.

```bash
nix develop -c just new-migration agent-run-request-dispositions
nix develop -c just migration-schema-isolation
nix develop -c just migrate
nix develop -c cabal build all
nix develop -c cabal test shikigami-core shikigami-workers shikigami-api shikigami-server shikigami-client
nix develop -c cabal run shikigami-openapi
git diff --stat docs/api/openapi.json
nix develop -c just keiro-gate
```

Live check, with the server in bearer mode as in the previous plan and a worker running
(`cabal run shikigami-worker` with the same `PG_CONNECTION_STRING`):

```bash
nix develop -c cabal run shikigami-client -- --token 0123456789abcdefXYZ \
  runs request heartbeat --key demo-2 --payload '{"task":"say hello"}'
nix develop -c cabal run shikigami-client -- --token 0123456789abcdefXYZ \
  runs wait heartbeat heartbeat:http:demo-2 --timeout 120
nix develop -c cabal run shikigami -- runs show shikigami.agent-run heartbeat:http:demo-2 --json | jq .lifecycle
```

Expected from `runs wait`, the exact timings varying:

```text
accepted
running
succeeded (session ses_...)
```

and from `runs show --json`, `{"status":"succeeded","failure":null}`. Stop the worker, request
a run with a new key, and `runs show` over HTTP answers `accepted` for as long as nothing drains
it; stop PostgreSQL and the same request answers 503 `unavailable`, not `failed`.


## Validation and Acceptance

Required: StatusSpec produces every lifecycle value on real runs and proves the cross-agent
guard and the outage behaviour; HandlerSpec covers every arm of both routes; the wire pins
cover every lifecycle value; the OpenAPI drift check, `just hurl`, and `just keiro-gate` pass;
the live transcript above matches.

IR-10's own acceptance maps as follows: reading before execution finishes reports `accepted`
or `running`, never a terminal guess (M1 precedence, hurl); a successful run reports
`succeeded` with session id, completion time, and bounded summary, and repeating the read
returns the same facts (StatusSpec, live check); a permanently failed or dead-lettered run
reports `failed` with a bounded reason and never stays `running` after the workflow is terminal
(StatusSpec, the disposition hook); two callers with the same key observe the same resource
(plan 90's replay plus this route); an unknown identifier is a typed not-found and a storage
outage is a retryable service problem (HandlerSpec, live check); the document and client expose
the route and the wire test pins the lifecycle values (M2).


## Idempotence and Recovery

Every read is side-effect free and may be repeated. The disposition migration is additive with
a default, so existing rows need no backfill. The worker's disposition write is idempotent (an
update to the same value) and its failure never changes the queue outcome; if a row is found
`accepted` after its message was dead-lettered before this plan was deployed, the operator reads
the dead-letter queue with the mounted `pgmq dlq read` verb, and the hook covers every job
from then on. If the OpenAPI drift test fails, regenerate and commit the artifact.


## Interfaces and Dependencies

Hard prerequisite, the whole plan:
`docs/plans/90-accept-addressed-agent-runs-over-http-with-server-owned-idempotency.md`, which
supplies the ledger table and module, the run identity, the `AgentRunApi` record, the handler
module, the pool in `ServerEnv`, and the hurl file this plan extends. Through it, the catalog
and authentication plans are also complete.

This plan owns `Shikigami.AgentRun.Status`, the disposition columns and `recordDeadLetter` and
`listRunRequests` on `Shikigami.AgentRun.Ledger`, the `show` and `list` fields of
`AgentRunApi` with `AgentRunStatus`, `RunFailureView`, and `RunRequestView`, the `RunNotFound`
problem code, the worker's disposition hook, the `lifecycle` key of `runs show --json`, and the
`runs show`, `runs list`, and `runs wait` client commands. No later plan in the MasterPlan
depends on it.

Libraries whose choice matters: `keiro` 0.18 (`lookupInstance`, `loadStepIndex`,
`cancelWorkflow`, the status constructors), `kioku-core` (`getById`, `SessionRow`),
`relay-pagination-hasql` (`paginate`, `SortSpec`, `timestamptzKey`, `textKey`), and `hasql`.
Verify the released versions against `cabal.project` and the registry before changing a bound.
