---
id: 30
slug: operator-cli-inspect-runs-agents-dead-letters-and-cancel
title: "Operator CLI: inspect runs, agents, dead letters, and cancel"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tyx3yehmsq9eyywdcf5c7"
master_plan: "docs/masterplans/6-operations-and-observability-run-shikigami-as-a-real-service.md"
---

# Operator CLI: inspect runs, agents, dead letters, and cancel

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

An operator of shikigami today cannot answer basic questions from the command line. There is no
way to list the declared agents and their load state, no way to list or inspect runs (an agent
run is a keiro workflow plus a kioku session), no way to cancel a stuck run, no tooling for
dead-lettered jobs (poison run jobs are pgmq-archived and then invisible), and no way to see the
outbox's pending or dead-lettered sink intents. The `shikigami` CLI has twelve subcommands, all
of them "do work" verbs (`worker`, `scheduler`, `consume-stream`, `enqueue-run`, ...) — none is
an operator inspection or control verb. When a workflow is stuck, keiro supports cancellation
and the worker already handles a `Cancelled` outcome (`shikigami-core/src/Shikigami/Worker.hs:190`),
but nothing in shikigami can *issue* a cancel.

After this plan, an operator has a read-mostly, safe-by-default set of subcommands:
`shikigami agents list` (declared agents with load state and a trigger summary),
`shikigami runs list` and `shikigami runs show <id>` (keiro workflow status joined with the
kioku session), `shikigami runs cancel <workflow-id>` (issue a keiro cancellation; destructive,
needs `--confirm`), `shikigami dlq list` and `shikigami dlq replay <msg-id>` (inspect the pgmq
archive of poison run jobs and re-enqueue one; replay needs `--confirm`), and
`shikigami outbox status` (counts of pending and dead-lettered sink intents from the keiro
outbox). Every destructive operation refuses to run without `--confirm`.

The user-visible proof: with a run in flight, `shikigami runs list` prints a table with its
workflow id and status `running`; `shikigami runs cancel <id> --confirm` flips it, and a
follow-up `shikigami runs show <id>` reports status `cancelled`; a poison job enqueued and
drained appears in `shikigami dlq list`, and `shikigami dlq replay <msg-id> --confirm` puts it
back on the live queue.


## Progress

- [ ] M1: `shikigami agents list` — loads manifests from `--agents`, prints name, behavior kind,
      trigger summary, and load state (loaded / failed-to-parse).
- [ ] M2: `Shikigami.Operator.Query` module with read-only hasql statements over
      `keiro.keiro_workflows`, `kiroku.kioku_sessions`, `keiro.keiro_workflow_steps`, and the
      pgmq archive; `shikigami runs list` and `shikigami runs show <id>` built on it.
- [ ] M3: `shikigami runs cancel <workflow-id> --confirm` issues a keiro cancellation
      (`appendJournalEntry … WorkflowCancelled`); verified to flip `keiro.keiro_workflows.status`
      to `cancelled`.
- [ ] M4: `shikigami dlq list` and `shikigami dlq replay <msg-id> --confirm` over the pgmq
      archive table `pgmq.a_shikigami_run_jobs`; replay re-sends the archived body to the live
      queue.
- [ ] M4: `shikigami outbox status` — counts of `keiro.keiro_outbox` rows by status.
- [ ] M5: `--confirm` gate on every destructive subcommand; a test proves the gate refuses
      without it.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Issue run cancellation by appending keiro's terminal `WorkflowCancelled` journal
  marker via `Keiro.Workflow.appendJournalEntry`, not via a bespoke SQL `UPDATE`.
  Rationale: keiro has no top-level "cancel workflow by id" function; cancellation is modeled as
  appending `WorkflowCancelled { recordedAt }` (constructor at
  `/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Workflow/Types.hs:194`) through the public
  helper `appendJournalEntry :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId ->
  WorkflowJournalEvent -> Eff es ()`
  (`/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Workflow.hs:745-746`). That helper runs
  the same transaction keiro uses internally: it writes the journal event, the
  `keiro.keiro_workflow_steps` index row, and upserts `keiro.keiro_workflows.status` to
  `cancelled` (via `instanceStatusForEvent`, keiro `Workflow.hs:828-832`). On the next resume,
  `runWorkflow` short-circuits to the `Cancelled` outcome, which the shikigami worker already
  maps to a dead-letter ack (`Worker.hs:190`). A raw `UPDATE` would bypass the journal (the
  source of truth for replay) and desynchronize it from the status table. `cancelChild`
  (keiro `Workflow/Child.hs:272-284`) is only for parent→child cancellation and is not used
  here.
  Rationale continued: the agent-run workflow name is fixed —
  `Shikigami.Agent.Workflow.Name.agentRunWorkflowName = WorkflowName "shikigami.agent-run"`; the
  conversation workflow is `WorkflowName "shikigami.danwa-conversation"`
  (`shikigami-core/src/Shikigami/Agent/Conversation.hs:90-91`). `runs show`/`runs list` display
  the `workflow_name`, and `runs cancel` looks it up so the operator passes only the id.
  Date: 2026-07-08

- Decision: Inspection subcommands are read-only SQL against the substrate's tables; there is no
  new "runs" table.
  Rationale: an agent run's durable state already lives across two tables — keiro's
  `keiro.keiro_workflows` (workflow status: the DDL's `status` column is one of
  `running`/`suspended`/`completed`/`cancelled`/`failed`, keiro-migrations
  `2026-06-15-15-07-25-keiro-workflows-instances.sql:4-20`) and kioku's `kiroku.kioku_sessions`
  (session lifecycle: `session_id`, `agent_id`, `status`, `started_at`, `completed_at`,
  `summary`, `error_message`; kioku-migrations `2026-06-24-00-00-00-kioku-base.sql:35-52`, note
  the schema is `kiroku`, not `kioku`). Shikigami mints the workflow id and the session id from
  the same run identity, so they join on `keiro.keiro_workflows.workflow_id =
  kiroku.kioku_sessions.session_id` (verify the exact correspondence against the run's
  `idempotencyKey`/`SessionId` minting in `Shikigami.Agent.Workflow` before relying on it — see
  M2). Reading these directly is simpler and truthful; a synthesized runs table would duplicate
  and risk drifting from the source of truth.
  Date: 2026-07-08

- Decision: Dead-letter tooling reads the pgmq archive table `pgmq.a_shikigami_run_jobs`
  directly and replays by re-sending the archived message body to the live queue.
  Rationale: shikigami's shibuya pgmq adapter is configured with `deadLetterConfig = Nothing`
  (the default from `Shibuya.Adapter.Pgmq.Config.defaultConfig`,
  `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/.../Config.hs:288`), so
  poison jobs are pgmq-*archived* (moved from `pgmq.q_shikigami_run_jobs` to
  `pgmq.a_shikigami_run_jobs` — the archive table pgmq creates per queue, DDL embedded in
  `shikigami-migrations/sql-migrations/2026-06-24-13-00-00-pgmq-schema.sql:1120-1160`, columns
  `msg_id, read_ct, enqueued_at, archived_at, vt, message, headers`) rather than routed to a
  DLQ. pgmq-hs exposes no "read archive" function (verified), so `dlq list` runs a plain hasql
  `SELECT` over `pgmq.a_shikigami_run_jobs`. Replay reuses shikigami's own
  `Shikigami.Trigger.Enqueue.enqueueRunJob` path (which `sendMessage`s to the live queue), so a
  replayed job re-enters the exact drain path a fresh job would; it does not delete the archive
  row (archives are permanent), keeping replay idempotent and auditable.
  Date: 2026-07-08

- Decision: Read-only by default; every destructive subcommand (`runs cancel`, `dlq replay`)
  requires an explicit `--confirm` flag and prints what it will do first.
  Rationale: the MasterPlan scopes this plan as "read-mostly and safe". A single `--confirm`
  switch (optparse `switch`) is unambiguous and testable; without it the command prints the
  intended action and exits non-zero. `runs cancel` and `dlq replay` are the only two write
  paths; everything else is a `SELECT` or a manifest read.
  Date: 2026-07-08

- Decision: This plan owns the `agents` operator command group but consumes plan 20's
  `AgentLoadReport`; plan 23 later extends the command with principal/lifecycle state and
  adds `sync`.
  Rationale: plan 20 is the sole directory traversal and preserves parse failures, while
  the operations initiative owns presentation and CLI parsing. This division prevents a
  second loader here and a second `agents` command in plan 23.
  Date: 2026-07-22


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a declared-agent runtime: agents are Dhall manifests in `agents/`
(`AgentDecl`, `shikigami-core/src/Shikigami/Api/Agent.hs`), and one executable, `shikigami`
(dispatcher `shikigami-cli/src/Shikigami/Cli.hs`), exposes twelve subcommands. The dispatcher is
a single `optparse-applicative` `subparser` (Cli.hs:36-151) over a `Command` sum type
(Cli.hs:17-29); each command has a wrapper module under
`shikigami-cli/src/Shikigami/Cli/Commands/`. Adding subcommands means adding constructors and
`command` blocks there and new wrapper modules. The command modules already show the two things
this plan needs: how to load agents (`loadAgents` in `Commands/ConsumeStream.hs:90-94` reads
every `*.dhall` from a directory via `Shikigami.Agent.Loader.loadAgent`, skipping parse
failures) and how to reach Postgres (`getEnv "PG_CONNECTION_STRING"` then
`Kiroku.Store.Connection.withStore`, e.g. `Commands/Scheduler.hs:36-37`, exposing a hasql `Pool`
via `StoreConnection.pool st`).

Terms of art. An *agent run* is one execution of a declared agent. Its durable state spans two
libraries. *keiro* is the durable-workflow engine; a run is a keiro *workflow*, and its status
lives in table `keiro.keiro_workflows` (schema `keiro`): columns include `workflow_id`,
`workflow_name`, `status`, `attempts`, `last_error`, `created_at`, `updated_at`, `completed_at`,
with `status` constrained to `running`/`suspended`/`completed`/`cancelled`/`failed` (keiro
migration `2026-06-15-15-07-25-keiro-workflows-instances.sql:4-20`). A companion table
`keiro.keiro_workflow_steps` (schema `keiro`, DDL
`2026-06-03-16-10-05-keiro-workflow-steps.sql:11-19`; columns `workflow_id`, `workflow_name`,
`step_name`, `result jsonb`, `recorded_at`) is the fast index of journaled steps — useful for
`runs show` to display the step trail. *kioku* is the session/memory store; a run opens a
*session* in table `kiroku.kioku_sessions` (schema `kiroku`, DDL
`2026-06-24-00-00-00-kioku-base.sql:35-52`; columns `session_id`, `agent_id`, `focus`, `status`,
`started_at`, `completed_at`, `model_used`, `summary`, `error_message`). *pgmq* is the Postgres
message queue; the run-job queue is `shikigami_run_jobs`, so its live table is
`pgmq.q_shikigami_run_jobs` and its archive is `pgmq.a_shikigami_run_jobs`. The keiro *outbox*
(`keiro.keiro_outbox`, DDL `2026-05-19-12-55-02-keiro-outbox.sql:1-31`; `status` defaults to
`pending`, becomes `sent` or `dead`) holds queued sink intents.

Cancellation today: keiro has no "cancel by id" function. The worker maps a `Cancelled` workflow
outcome to a dead-letter ack (`Worker.hs:190`), but nothing issues the cancel. The mechanism is
to append the terminal marker `WorkflowCancelled { recordedAt }` (keiro `Workflow/Types.hs:194`)
via `appendJournalEntry` (keiro `Workflow.hs:745-746`), which writes journal + step-index +
`keiro.keiro_workflows.status = 'cancelled'` in one transaction (keiro `Workflow.hs:828-832`).
The workflow name to pass is `agentRunWorkflowName = WorkflowName "shikigami.agent-run"`
(`shikigami-core/src/Shikigami/Agent/Workflow/Name.hs`) for agent runs, or
`WorkflowName "shikigami.danwa-conversation"` (`Shikigami/Agent/Conversation.hs:90-91`) for
conversations.

Dead letters today: the adapter's `deadLetterConfig = Nothing`
(`Shibuya.Adapter.Pgmq.Config.defaultConfig`, Config.hs:288; used at `Worker.hs:76` via
`defaultConfig runQueueName`) means over-retried/poison jobs are pgmq-archived into
`pgmq.a_shikigami_run_jobs`. pgmq-hs offers no archive-reader, so inspection is a direct
`SELECT`; re-enqueue reuses `Shikigami.Trigger.Enqueue.enqueueRunJob`
(`shikigami-core/src/Shikigami/Trigger/Enqueue.hs:52-61`, which `createQueue` + `sendMessage`s a
`RunJob` to `shikigami_run_jobs`). The `RunJob` shape is `Shikigami.Api.RunJob`
(`shikigami-core/src/Shikigami/Api/RunJob.hs`); an archived row's `message` column is the JSON of
one such `RunJob`.

`hasql` and `hasql-pool` are already dependencies of both `shikigami-core` and (transitively)
the CLI; the CLI already pulls `kiroku-store` (`shikigami-cli.cabal:50`), so opening a `Pool`
needs no new dependency.

Two sibling plans matter. `docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md`
owns *in-workflow* run timeouts (a run that cancels itself when it overruns); this plan owns the
*operator-issued* cancel of a live run — the same `WorkflowCancelled` marker, different trigger.
`docs/plans/28-structured-logging-metrics-and-trace-propagation.md` introduces `Shikigami.Log`;
if landed, these subcommands should log through it, but they are plain one-shot CLIs so it is not
required.


## Plan of Work

### Milestone 1 — `agents list`

Scope: the simplest read-only subcommand, establishing the `agents` command group and the output
convention (a compact aligned table by default; `--json` for machine consumption).

Add an `Agents AgentsSub` constructor and an `agents` `command` with a `list` subparser to
`Cli.hs`. Create `shikigami-cli/src/Shikigami/Cli/Commands/Agents.hs` (`runAgentsList ::
FilePath -> Bool -> IO ()`, taking `--agents DIR` (default `agents`) and `--json`). Consume
`Shikigami.Agent.Loader.loadAgentsReport` from plan 20 and render every
`AgentLoaded`/`AgentLoadFailed` entry, so an operator sees broken manifests without a second
directory traversal. For each loaded `AgentDecl`, print name,
behavior kind (reuse `Shikigami.Agent.Run.behaviorKindText`), and a trigger summary (`schedule
<cron>` / `stream <topic/match>` / `event <eventType>` derived from the `Trigger` constructor).

Acceptance: `shikigami agents list --agents agents` prints one row per manifest, including a
`failed` row for `agents/broken.dhall` (which exists in the repo).

### Milestone 2 — `runs list` / `runs show` (read-only queries)

Scope: a query module and the two read commands. First verify the join key. Read
`Shikigami.Agent.Workflow` to confirm how the workflow id (`WorkflowId (jobIdempotencyKey job)`,
`Workflow.hs:150-153`) relates to the session id opened in `openSession`
(`Workflow.hs:248-275`, `genSessionId`). If they are equal, join on it; if the session id is
independent, `runs list` keys on `keiro.keiro_workflows` alone and `runs show` looks the session
up by the run's agent + time window, or by a stored linkage — record the finding in Surprises &
Discoveries and adjust. (The Decision Log's join assumption is the hypothesis; M2 verifies it.)

Create `shikigami-cli/src/Shikigami/Cli/Commands/Runs.hs` and a query module
`shikigami-cli/src/Shikigami/Operator/Query.hs` (or under `shikigami-core` if shared) holding
read-only hasql `Statement`s:

```haskell
listRuns   :: Maybe Text -> Statement () [RunRow]     -- optional status filter
showRun    :: Text -> Statement () (Maybe RunDetail)  -- by workflow id
listSteps  :: Text -> Statement () [StepRow]          -- keiro.keiro_workflow_steps for one run
```

`listRuns` selects `workflow_id, workflow_name, status, attempts, created_at, updated_at,
completed_at` from `keiro.keiro_workflows` (optionally `WHERE status = $1`), left-joined to
`kiroku.kioku_sessions` on the verified key for `agent_id`, `summary`, `error_message`.
`showRun` returns one run plus its session fields; `runs show` additionally prints the step trail
from `listSteps`. `runs list` accepts `--status running|suspended|...` and `--json`.

Acceptance: with a run in flight (enqueue one, worker draining), `shikigami runs list` shows its
id and `running`; `shikigami runs show <id>` prints the joined session and the step names
recorded so far.

### Milestone 3 — `runs cancel`

Scope: the first write path, gated by `--confirm`. In `Commands/Runs.hs`, add `runRunsCancel ::
Text -> Bool -> IO ()`. Without `--confirm`, print `would cancel workflow <id> (<name>, status
<current>)` and exit non-zero. With it, look up the workflow's `workflow_name` (needed by
`appendJournalEntry`) via `showRun`, then run keiro's append in the store effect:
`appendJournalEntry name (WorkflowId id) (WorkflowCancelled recordedAt)` inside `runStorePool`
over the pool (mirror the effect-runner in `Commands/Scheduler.hs:71-75`). Refuse to cancel a
run already in a terminal status (`completed`/`cancelled`/`failed`) with a clear message.

Acceptance: `shikigami runs cancel <id> --confirm` on a `running` run makes a subsequent
`shikigami runs show <id>` report `cancelled`; without `--confirm` it prints the plan and changes
nothing.

### Milestone 4 — `dlq list` / `dlq replay` and `outbox status`

Scope: dead-letter inspection and replay, plus outbox counts. Add a `Dlq DlqSub` and
`Outbox OutboxSub` command group. In a new `Commands/Dlq.hs`: `runDlqList` runs a read-only
`SELECT msg_id, enqueued_at, archived_at, read_ct, message FROM pgmq.a_shikigami_run_jobs ORDER
BY archived_at DESC` and prints msg id, archived-at, read count, and the agent name pulled from
the `message` JSON (`RunJob.agentName`); `runDlqReplay :: Integer -> Bool -> IO ()` selects the
one archived row by `msg_id`, decodes its `message` to a `Shikigami.Api.RunJob`, and (with
`--confirm`) calls `Shikigami.Trigger.Enqueue.enqueueRunJob pool job` to re-enqueue it onto the
live queue; without `--confirm` it prints `would replay msg <id> for agent <name>` and exits
non-zero. It does not delete the archive row. In `Commands/Outbox.hs`: `runOutboxStatus` runs
`SELECT status, count(*) FROM keiro.keiro_outbox GROUP BY status` and prints a small table
(`pending`, `sent`, `dead`).

Acceptance: enqueue a deliberately malformed job (an agent name that does not exist triggers the
`PoisonPill` dead-letter path, `Worker.hs:146`), let the worker drain it, then
`shikigami dlq list` shows its archived msg id; `shikigami dlq replay <msg-id> --confirm`
re-enqueues it (a fresh `enqueue-run`-style message id is returned). `shikigami outbox status`
prints nonzero counts after a run with sinks.

### Milestone 5 — confirm-gate test

Scope: prove the safety gate. Add a test to `shikigami-core-test` (or a new CLI test target if
the CLI grows one) that calls the cancel/replay handlers with `confirm = False` against a
`withShikigamiMigratedDatabase` database seeded with one running workflow / one archived job, and
asserts no state changed (status still `running`; archive row still present; live queue still
empty). This is the observable proof that destructive commands are safe by default.

Acceptance: the test fails before the gate is added (or with the gate inverted) and passes with
it.


## Concrete Steps

All commands run from the repo root inside `nix develop`, with `PG_CONNECTION_STRING` set (use
the stack from
`docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md`
or a manual Postgres).

Build:

```bash
cabal build all
cabal test all
```

Expected: `Test suite shikigami-core-test: PASS`.

M1:

```bash
cabal run shikigami -- agents list --agents agents
```

Expected (columns; broken.dhall shows a failed load-state):

```text
NAME              BEHAVIOR   TRIGGER                 STATE
heartbeat         flow       schedule */5 * * * *    loaded
triage-note       ...        event ...               loaded
broken            -          -                       failed
```

M2 (with a worker draining and a job enqueued in another terminal):

```bash
cabal run shikigami -- enqueue-run heartbeat
cabal run shikigami -- runs list --status running
cabal run shikigami -- runs show heartbeat:<activity-id>
```

Expected `runs list` row and `runs show` detail:

```text
WORKFLOW_ID              NAME                  STATUS   AGENT      UPDATED_AT
heartbeat:...            shikigami.agent-run   running  heartbeat  2026-07-08T...
```

M3:

```bash
cabal run shikigami -- runs cancel heartbeat:<activity-id>          # prints plan, exits non-zero
cabal run shikigami -- runs cancel heartbeat:<activity-id> --confirm
cabal run shikigami -- runs show heartbeat:<activity-id>
```

Expected: the confirmed cancel returns, and `runs show` now reports `cancelled`. Cross-check in
SQL:

```bash
psql "$PG_CONNECTION_STRING" -c \
  "select status from keiro.keiro_workflows where workflow_id = 'heartbeat:<activity-id>'"
```

```text
  status
-----------
 cancelled
```

M4:

```bash
cabal run shikigami -- enqueue-run does-not-exist    # poison: unknown agent → dead-letter
# (let the worker drain it)
cabal run shikigami -- dlq list
cabal run shikigami -- dlq replay <msg-id>            # prints plan, exits non-zero
cabal run shikigami -- dlq replay <msg-id> --confirm  # re-enqueues
cabal run shikigami -- outbox status
```

Expected `dlq list` and `outbox status`:

```text
MSG_ID  ARCHIVED_AT           READ_CT  AGENT
42      2026-07-08T...        3        does-not-exist

STATUS   COUNT
pending  0
sent     5
dead     0
```


## Validation and Acceptance

Acceptance is behavior an operator can observe:

1. `shikigami agents list` enumerates every manifest with its trigger summary and a `failed` row
   for `agents/broken.dhall`.
2. `shikigami runs list` and `runs show <id>` reflect live `keiro.keiro_workflows` status joined
   with the kioku session; a run in flight shows `running`, a finished one `completed`.
3. `shikigami runs cancel <id> --confirm` flips a running workflow to `cancelled` (verified via
   `runs show` and a direct `SELECT status FROM keiro.keiro_workflows`); without `--confirm` it
   changes nothing and exits non-zero.
4. `shikigami dlq list` shows archived poison run jobs from `pgmq.a_shikigami_run_jobs`;
   `dlq replay <msg-id> --confirm` re-enqueues one onto `shikigami_run_jobs` (a new message id is
   returned) and leaves the archive row intact.
5. `shikigami outbox status` prints per-status counts from `keiro.keiro_outbox`.
6. The M5 test proves the `--confirm` gate: with `confirm = False`, cancel/replay make no state
   change.
7. Regression: `cabal build all` and `cabal test all` pass; the twelve existing subcommands are
   unchanged.


## Idempotence and Recovery

All inspection subcommands are pure reads and safe to run repeatedly. `runs cancel` is
idempotent at the keiro level — appending `WorkflowCancelled` to an already-cancelled workflow is
a no-op transition (keiro upserts the same terminal status), and the command additionally refuses
to act on an already-terminal run, so a double-cancel is harmless. `dlq replay` re-sends a copy
to the live queue and never deletes the archive row, so re-running it enqueues another copy; the
run's own idempotency key (the `RunJob.idempotencyKey`, which is the keiro workflow id) means the
worker de-duplicates a replayed job that already ran to completion (the workflow is already
`completed`), so replay is safe though not automatically deduped at the queue level — the
`--confirm` prompt names the agent so the operator does not fat-finger it. No schema changes are
made; nothing to roll back on the data side.


## Interfaces and Dependencies

Dependencies: hard dependency on plan 20's `AgentLoadReport` API; `hasql`, `hasql-pool`,
`kiroku-store` (already in `shikigami-cli.cabal`), plus
`keiro`/`keiro-core` and `kioku` transitively via `shikigami-core`. keiro provides
`Keiro.Workflow (appendJournalEntry, WorkflowId (..), WorkflowName (..))` and
`Keiro.Workflow.Types (WorkflowJournalEvent (WorkflowCancelled))`; shikigami provides
`Shikigami.Trigger.Enqueue (enqueueRunJob, runQueueName)` and
`Shikigami.Api.RunJob (RunJob (..))`; the workflow-name constants are
`Shikigami.Agent.Workflow.Name.agentRunWorkflowName` and
`Shikigami.Agent.Conversation.conversationWorkflowName`. No new external dependency.

Verified upstream signatures (2026-07-08):
`appendJournalEntry :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> WorkflowJournalEvent -> Eff es ()`
(keiro `Workflow.hs:745-746`); `WorkflowCancelled { recordedAt :: !UTCTime }` (keiro
`Workflow/Types.hs:194`); `enqueueRunJob :: Pool -> RunJob -> IO (Either UsageError MessageId)`
(shikigami `Trigger/Enqueue.hs:52`). Archive table `pgmq.a_shikigami_run_jobs` columns
(`msg_id, read_ct, enqueued_at, last_read_at, archived_at, vt, message, headers`) per the
pgmq schema embedded at `shikigami-migrations/sql-migrations/2026-06-24-13-00-00-pgmq-schema.sql:1120-1160`.

New modules/handlers that must exist at the end:

- M1: `Shikigami.Cli.Commands.Agents.runAgentsList :: FilePath -> Bool -> IO ()`.
- M2: `Shikigami.Operator.Query` (read-only `Statement`s over `keiro.keiro_workflows`,
  `kiroku.kioku_sessions`, `keiro.keiro_workflow_steps`); `Shikigami.Cli.Commands.Runs`
  (`runRunsList`, `runRunsShow`).
- M3: `Shikigami.Cli.Commands.Runs.runRunsCancel :: Text -> Bool -> IO ()`.
- M4: `Shikigami.Cli.Commands.Dlq` (`runDlqList`, `runDlqReplay :: Integer -> Bool -> IO ()`);
  `Shikigami.Cli.Commands.Outbox.runOutboxStatus`.
- Cli.hs: new `Command` constructors and `command`/subparser blocks for `agents`, `runs`, `dlq`,
  `outbox`, each destructive leaf carrying a `switch (long "confirm")`.

Cross-plan contracts (mirrored in the MasterPlan's Integration Points):
`docs/plans/20-explicit-trigger-routing-scheduler-catch-up-policy-and-loud-failures.md`
defines the report rendered by `agents list`; do not call `loadAgent` or walk the
directory here. `docs/plans/23-agent-lifecycle-control-with-meibo-principals.md` extends
this command group after plan 33 defines `identity.principal`.
`docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md` owns
in-workflow run timeouts (self-cancel on overrun); this plan owns the operator-issued cancel —
both write the same `WorkflowCancelled` marker, so if plan 17 lands a shared cancel helper, this
plan should call it rather than re-implement the append. If
`docs/plans/28-structured-logging-metrics-and-trace-propagation.md` has landed, the destructive
subcommands should emit an audit `Shikigami.Log` event (soft dependency).


## Revision Notes

- 2026-07-22: Made plan 20's `AgentLoadReport` a hard dependency and assigned this plan
  ownership of the `agents` command group. Plan 23 now extends that command instead of
  defining a competing `agents list`.
