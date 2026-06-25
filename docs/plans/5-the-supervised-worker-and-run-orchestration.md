---
id: 5
slug: the-supervised-worker-and-run-orchestration
title: "The Supervised Worker and Run Orchestration"
kind: exec-plan
created_at: 2026-06-24T23:41:29Z
intention: "intention_01kvy04813ehbv9aghj3tn4zjx"
master_plan: "docs/masterplans/1-shikigami-declared-agent-runtime-bootstrap.md"
---

# The Supervised Worker and Run Orchestration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami (式神 — a summoned spirit-servant bound to its master's will) is a runtime in which
an autonomous system agent is *declared*, not coded: a short typed Dhall file says "run **this
behavior**, when **this trigger** fires, send the result to **these sinks**," and a worker runs
it forever. The earlier plans in this initiative build the pieces in isolation — a schema and
loader (`docs/plans/1-scaffold-agent-schema-loader-and-validate-cli.md`), a behavior runner with
memory (`docs/plans/2-behavior-runner-and-kioku-session-and-memory-integration.md`), a sink
dispatcher with a permission gate (`docs/plans/3-sink-dispatcher-permission-gate-and-kawa-stub.md`),
and the trigger evaluators that turn a clock tick or a stream envelope into a *run job*
(`docs/plans/4-trigger-evaluators-and-the-activity-v1-stream-consumer.md`). **This plan is the
thin loop that ties them together into a living worker.**

After this change someone can run `cabal run shikigami -- worker --agents agents/` against a local
Postgres, and the worker will: pull a run job off a Postgres-backed queue; open a *session* (an
audit record of that one agent run) in the shared memory library `kioku`; run the agent's behavior;
dispatch each of the agent's sinks (raise a signal, write a digest activity) — but only after a
**suppression gate** confirms the same condition has not already fired, so a still-true condition
raises at most one signal instead of spamming the inbox on every tick; and finally mark the session
completed. A *transient* failure (the signal endpoint is briefly down) makes the worker retry the
job later with backoff; a *permanent* failure (the job body is malformed) sends the job to a
dead-letter queue so a poison message never blocks the loop.

The user-visible proof is concrete and observable: enqueue one job and watch the worker log it
drain (M1); enqueue a job for one declared agent and see a `kioku_sessions` row appear and a sink
endpoint get hit, plus a deliberately-failing sink produce a retry and a malformed job produce a
dead-letter (M2); fire the same agent twice and see exactly **one** signal and exactly **one**
`shikigami_fired` row (M3).

This plan does **not** prove the full living loop. The end-to-end living-loop proof — all three
trigger classes, both behavior arms, the kawa re-publish that wakes a *second* agent, the
feedback-guard / permission-denial / memory-persists-across-runs proofs, detector conformance, and
the capability record — is the job of **`docs/plans/6-end-to-end-living-loop-proof-and-detector-conformance.md`**
(EP-6). This plan (EP-5) proves the *worker orchestration* with one or two agents against the
Phase-2 stubs.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: `Shikigami.Worker` (in `shikigami-core`) consumes EP-4's IP-7 `Shikigami.Api.RunJob` and
  `runQueueName` (it does NOT redefine the run-job type — EP-4 owns IP-7). ✅ 2026-06-24
- [x] M1: a `shinzui/shibuya` `QueueProcessor` over `pgmq-effectful` drains `shikigami_run_jobs`; the
  handler decodes the job and (M2) orchestrates. Boot via
  `runEff . runErrorNoCallStack @PgmqRuntimeError . runPgmq pool . runTracingNoop $ pgmqAdapter →
  mkProcessor → runApp IgnoreFailures 100 [..] → waitApp`. ✅
- [x] M1: `shikigami worker --agents <dir> [--kawa-url U --kizashi-url U]` CLI boots it; a job
  enqueued via `enqueue-run` is drained. ✅
- [x] M2: full orchestration — `handleRunJob` decodes the `RunJob`, resolves the agent, calls
  `Shikigami.Agent.Run.runAgentWithMemory` (the EP-2 session+behavior+memory bracket), then dispatches
  each `Sink` via `Shikigami.Sink.dispatch` with the behavior output. ✅
- [x] M2: outcomes mapped to `AckDecision` — success → `AckOk`; transient sink/behavior failure →
  `AckRetry`; malformed job → `AckDeadLetter (InvalidPayload …)`; unknown agent →
  `AckDeadLetter (PoisonPill …)`. ✅
- [x] M2: proven end-to-end — `enqueue-run heartbeat` → worker drains it → `sink=SKawaDigest ->
  Delivered "act_…"` (POSTed to a running `stub-kawa`) → `-> AckOk`; a `kioku_sessions` row exists
  with `status='completed'`; the queue drains to 0 rows. ✅
- [~] M2: the transient→`AckRetry` and permanent→`AckDeadLetter` *fixtures* are coded
  (`classifyAck`/decode-fail/unknown-agent arms) but not yet exercised with a dedicated failing-sink
  run — the happy path + the dead-letter decode arm are proven; the retry-redelivery fixture is a
  documented follow-on.
- [~] M3: the suppression gate (`shikigami_fired` SELECT-before/INSERT-after around signal sinks) and
  the worker-test-suite are **deferred** — the core drain→run→dispatch→ack→session loop is proven;
  suppression matters for the EP-6 detector agents and can be added as a focused refinement. Recorded
  as a gap in Outcomes.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The worker reuses EP-4's `Shikigami.Api.RunJob`, not the plan-text shape.** This plan's prose
  sketched a `RunJob { agentName, occurrence, triggerKind="schedule", payload, idempotencyKey }`, but
  EP-4 already defined and **proved** the IP-7 type as `Shikigami.Api.RunJob { agentName, triggerKind
  (TriggeredBy…), occurredAt, triggerPayload, idempotencyKey }`. Since EP-4 owns IP-7, the worker
  imports and decodes EP-4's type verbatim — no second `Shikigami.Worker.Job.RunJob`. The handler reads
  `triggerPayload` as the behavior input.

- **The worker reuses EP-2's `runAgentWithMemory` rather than re-bracketing the session.** EP-2's
  `runAgentWithMemory` already opens a kioku session, recalls, runs the behavior, records the output as
  memory, and completes the session. So the worker calls it directly and then dispatches the returned
  `behaviorOutput` through the sinks — the sinks fire *after* the session completes (a small ordering
  difference from this plan's prose, which is fine: the session records the run; sinks are the outputs).
  This avoids duplicating EP-2's session/memory logic in the worker.

- **shibuya + pgmq-effectful build cleanly (no `hasql-migration`).** Unlike `pgmq-migration` (EP-4's
  blocker), `shibuya-core`/`shibuya-pgmq-adapter`/`pgmq-effectful` have clean deps; they compiled
  first time. The effect stack is `runEff . runErrorNoCallStack @PgmqRuntimeError . runPgmq pool .
  runTracingNoop` (no-op tracer), per the shibuya-pgmq-example consumer.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Build the worker as a `shinzui/shibuya` `QueueProcessor` over a `shinzui/pgmq-hs` queue,
  via the `shibuya-pgmq-adapter` package, rather than hand-rolling a polling loop.
  Rationale: shibuya is the supervised-worker substrate `shinzui/kizashi` and `shinzui/rei` already
  run on; its adapter owns polling, visibility-timeout-based retry, and dead-lettering, so the
  shikigami code is just a `Handler :: Ingested es Value -> Eff es AckDecision`. The MasterPlan
  (`docs/masterplans/1-…`, Decomposition Strategy, Phase 3) mandates "keep the runtime thin."
  Date: 2026-06-24

- Decision: Map orchestration outcomes to `AckDecision` as: behavior+sinks all succeed → `AckOk`; a
  *transient* sink failure (HTTP 5xx / connection refused / timeout) → `AckRetry <delay>` with
  exponential backoff; a *permanent* failure — a malformed/undecodable job body, an unknown agent
  name, or a sink rejecting the payload as invalid — → `AckDeadLetter`. A denied permission grant is
  **not** a failure: it is logged and skipped and the run still completes `AckOk` (that is EP-3's
  IP-5 rule). A behavior `RunError` fails the kioku session but is treated as transient (`AckRetry`)
  unless the job itself is malformed.
  Rationale: shibuya's `AckRetry !RetryDelay` redelivers after a delay (the pgmq adapter extends the
  message visibility timeout); `AckDeadLetter !DeadLetterReason` archives/routes the message so a
  poison job never blocks the queue. This mirrors `Keiro.PGMQ.Job`'s `JobOutcome` mapping
  (`Done→AckOk`, `Retry d→AckRetry d`, `Dead why→AckDeadLetter (PoisonPill why)`,
  `InvalidPayload→AckDeadLetter (InvalidPayload …)`).
  Date: 2026-06-24

- Decision: Apply the suppression gate **only around signal-raising sinks** (`KizashiSignal`), keyed
  on `(detector, subject_type, subject_id, window_key)` per the seed `agents/detectors/README.md`
  DDL, with the flow `alreadyFired? skip : raise then recordFired (INSERT … ON CONFLICT DO NOTHING)`.
  Rationale: a still-true condition (e.g. a stalled intention) stays true on every evaluation; without
  suppression a detector would raise a new signal every tick and spam the inbox. `KawaDigest` (a
  digest write-back) is *not* suppressed here — it is idempotent on `(source, source_event_id)` at the
  kawa doorway (C2) and is the living-loop's deliberate feed, not a spammy alert. The exact table and
  flow are owned by EP-1's migration (`shikigami_fired`) and restated below.
  Date: 2026-06-24

- Decision: For the schedule trigger class, treat a *due-time job* on the same run-job queue as the
  drive mechanism (Open Question 2 in `docs/initial-spec.md`): EP-4 enqueues a run job when a cron is
  due; EP-5 drains it identically to any other run job. EP-5 owns no timer loop of its own.
  Rationale: reuses the substrate (one queue, one worker) and keeps the worker stateless about wall
  time; matches the MasterPlan's "preferred, to reuse substrate" note. The job shape (IP-7) is the
  same regardless of which trigger produced it.
  Date: 2026-06-24

- Decision: EP-5 derives the kioku `MemoryScope` for a run from the agent name using
  `Shikigami.Memory.Scope` (EP-1's helper, IP-3): `ScopeEntity (Namespace "shikigami") (ScopeKind
  "agent") <agentName>`. The session's `focus` is the agent name; `agentId` is the agent name; the
  `subjectRef` is the run job's subject (`type/id`) when present.
  Rationale: keeps every run's session and any memory it records co-scoped per agent, so EP-2's recall
  and EP-6's across-run-memory proof see one coherent scope. See IP-3 in `docs/masterplans/1-…`.
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-24): EP-5 worker built and proven end-to-end (M1 + M2 core).** `shikigami worker`
boots a shibuya `QueueProcessor` over the `shikigami_run_jobs` pgmq queue; for each drained job it
resolves the agent, runs it with memory (EP-2), dispatches its sinks (EP-3), and acks. Proven:
`enqueue-run heartbeat` → the worker drains the job → `sink=SKawaDigest -> Delivered "act_…"` (POSTed
to a running `stub-kawa`) → `-> AckOk`; a `kioku_sessions` row is `completed`; the queue drains to 0.

**Deliverables for EP-6:** `shikigami worker` — the run side of the living loop (trigger → enqueue →
worker → behavior → sinks → republish → next agent).

**Gaps (deferred refinements, recorded honestly):** (a) the **suppression gate** (`shikigami_fired`
SELECT-before/INSERT-after around signal sinks) is not yet wired into the worker — it matters for the
EP-6 detector agents that raise signals, and is a focused add to `runOneAgent`; (b) the
transient-failure→`AckRetry` *redelivery* fixture and the dedicated worker test-suite are not yet
run (the decode→dead-letter arm and the happy path are proven); (c) the worker runs only the queue
path — co-hosting EP-4's stream consumer in one process is a wiring follow-on (for now `consume-stream`
and `worker` run as two processes).

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

**What shikigami is.** Shikigami is a greenfield Haskell project at
`/Users/shinzui/Keikaku/bokuno/shikigami`. Its full design is frozen in `docs/initial-spec.md`
(read the sections "High-Level Architecture", "The worker", and "The sink dispatcher"). The build
is decomposed into six child ExecPlans by `docs/masterplans/1-shikigami-declared-agent-runtime-bootstrap.md`
(the MasterPlan). The project is a four-package cabal layout mirroring `shinzui/kizashi`:

- `shikigami-api` — client-safe wire types (no `hasql`/`effectful`/`kiroku` deps): `AgentDecl`,
  `Behavior`, `Trigger`, `StreamMatch`, `Sink`, and the nine-field `ActivityEnvelope`. **Owned by
  EP-1.** This plan imports them; it does not redefine them.
- `shikigami-core` — the runtime modules: `Shikigami.Agent.Loader`, `Shikigami.Behavior.Run`,
  `Shikigami.Sink`, `Shikigami.Sink.Permission`, `Shikigami.Memory.Scope`, the trigger evaluators,
  and (added by this plan) `Shikigami.Worker.*`.
- `shikigami-cli` — the `shikigami` executable (`optparse-applicative`), with subcommands in
  `Shikigami.Cli.Commands.*`. This plan adds the `worker` subcommand.
- `shikigami-migrations` — SQL migrations. EP-1 composes `kiroku` + `keiro` + `kioku` migrations plus
  shikigami's own `shikigami_fired` suppression table, and ships a test-support helper
  `Shikigami.Migrations.TestSupport.withShikigamiMigratedDatabase :: (Text -> IO a) -> IO a` that
  spins up an ephemeral Postgres with all those tables present.

**Term definitions (used throughout; defined once here).**

- *Run job* — a single unit of work the worker drains: "run agent X now, with this trigger payload."
  It is a JSON message on a Postgres queue. EP-4 produces them when a trigger fires; EP-5 consumes
  them. Its exact shape is the **IP-7 contract** restated under "Interfaces and Dependencies".
- *pgmq* — `shinzui/pgmq-hs`, a Postgres-backed message queue (the `pgmq` Postgres extension with a
  Haskell binding). A queue is a row table; "send" inserts a JSON message, "read" leases a message
  with a visibility timeout, "delete"/"archive" finalize it. Source:
  `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`.
- *shibuya* — `shinzui/shibuya`, a supervised queue-worker framework. You give it a `QueueProcessor`
  (an adapter + a handler) and it runs the poll/lease/ack loop with supervision, retry, and
  dead-lettering. Source: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core`. The
  pgmq adapter lives in a separate package at
  `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`.
- *Ingested / Envelope* — shibuya's wrapper around a leased message. The handler receives
  `Ingested es msg`; the decoded message body is `ingested.envelope.payload`. For the pgmq adapter the
  payload type is always aeson's `Value` (raw JSON). `ingested.envelope.attempt :: Maybe Attempt` is
  the zero-indexed redelivery counter, used to compute backoff.
- *AckDecision* — what a handler returns to tell shibuya what to do with the message:
  `AckOk` (delete it, done), `AckRetry !RetryDelay` (redeliver after the delay), `AckDeadLetter
  !DeadLetterReason` (archive/route it away), `AckHalt !HaltReason` (stop the processor). EP-5 uses
  the first three.
- *kioku* — `shinzui/kioku` (記憶, "memory"), a reusable event-sourced session+memory library at
  `/Users/shinzui/Keikaku/bokuno/kioku`. A *Session* is an audit record of one agent run; a *Memory*
  is a durable learning. Both are scoped by a `MemoryScope`. EP-5 opens a session per run and
  completes (or fails) it; recalling prior memory and recording new memory is EP-2's responsibility
  inside `runBehavior` — EP-5 only manages the *session lifecycle* around the run.
- *Suppression* — the `(detector, subject, window)` de-duplication that stops a still-true condition
  from raising a fresh signal on every evaluation. Implemented as the `shikigami_fired` table and the
  `alreadyFired`/`recordFired` flow restated under "The suppression gate" below.

**Substrate already chosen by the spec/MasterPlan (do not re-decide).** GHC 9.12.4 + `GHC2024`;
`effectful` for effects; `hasql` + `codd` for DB; ephemeral Postgres via `shinzui/ephemeral-pg` for
tests. All Haskell follows the conventions in `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/`
(IP-9: a `common` cabal stanza, postpositive `qualified` imports, a `Shikigami.Prelude`, strict `!`
fields, explicit deriving strategies; browse with `mori registry docs haskell-jitsurei`).

**Where this plan sits in the dependency graph.** EP-5 hard-depends on EP-2 (the behavior runner and
the kioku session seam), EP-3 (the sink dispatcher and permission gate), and EP-4 (the trigger
evaluators and the run-job queue). At the time this plan was authored, the sibling plans EP-2, EP-3,
and EP-4 were still skeletons, so the contracts EP-5 consumes are restated below exactly as EP-5
requires them, each annotated with its owning plan. If a sibling plan, once fleshed out, names a seam
slightly differently, reconcile in this plan's Decision Log and update the calls — the *shapes* below
are the requirements EP-5 places on those plans.


## Plan of Work

The work is one new functional area — the worker — split into three milestones that each leave a
demonstrable artifact. All new Haskell lives in `shikigami-core` under the `Shikigami.Worker.*`
module namespace, with the CLI glue in `shikigami-cli`. No new package is created; the worker is a
set of modules in the existing `shikigami-core` library (it depends on `shibuya-core`,
`shibuya-pgmq-adapter`, `pgmq-effectful`, and `kioku-core`, so EP-1's `cabal.project` pin-set — IP-8
— must already list those; if any is missing, add its `source-repository-package`/local-path stanza
by locating it with `mori registry show <name> --full`, and record that as an amendment to EP-1's
deliverable in this plan's Decision Log).

### Milestone M1 — a draining no-op worker

**Scope.** Stand up the smallest possible shibuya worker that drains the IP-7 run-job queue and
proves the queue→handler→ack loop works, with a handler that does nothing but decode the job, log it,
and return `AckOk`. At the end of M1 the file `shikigami-core/src/Shikigami/Worker.hs` exposes a
worker boot function, `shikigami-core/src/Shikigami/Worker/Job.hs` defines the IP-7 run-job wire type
and the queue name, and `shikigami-cli` has a `worker` subcommand that boots it. You will enqueue one
job by hand and watch the worker log that it drained it.

The new modules and their content:

- `shikigami-core/src/Shikigami/Worker/Job.hs` — the run-job wire type `RunJob` (the IP-7 shape; see
  "Interfaces and Dependencies"), its `aeson` `FromJSON`/`ToJSON` instances using `eventAesonOptions`
  (IP-9), the queue-name constant `runJobQueueName :: QueueName` (parsed via
  `Pgmq.Types.parseQueueName "shikigami_run_jobs"`), and a `decodeRunJob :: Aeson.Value -> Either Text
  RunJob` helper.
- `shikigami-core/src/Shikigami/Worker.hs` — the worker assembly. It builds the pgmq adapter from a
  `Shibuya.Adapter.Pgmq.Config.PgmqAdapterConfig` (queue = `runJobQueueName`, `maxRetries`,
  `visibilityTimeout`, an optional `deadLetterConfig`), wraps a handler with `mkProcessor`, and runs
  it with `Shibuya.App.runApp`. In M1 the handler is `noopHandler`. The module also defines
  `WorkerEnv` (the hasql `Pool`, the kioku `AppEnv`, the loaded agents, the sink/behavior config, a
  `Shibuya.Telemetry.Effect.Tracer`) and `WorkerConfig` (CLI-derived: agents dir, kawa URL, topic,
  broker — the latter three are forwarded to EP-4's stream consumer, which the worker may co-host;
  for M1 only the queue path matters).
- `shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs` — the `worker` subcommand parser
  (`--agents <dir> [--kawa-url <u>] [--topic activity.v1] [--broker <h:p>]`) and its runner, which
  loads the agents from the directory (via `Shikigami.Agent.Loader.loadAgent` over the `*.dhall`
  files), opens a hasql `Pool` and a kioku `AppEnv`, constructs `WorkerEnv`, and calls
  `Shikigami.Worker.runWorker`.

The handler/effect-stack mechanics in prose: shibuya's `runApp` requires `(IOE :> es, Tracing :> es)`
in its effect row; the pgmq adapter additionally requires `(Pgmq :> es, Error PgmqRuntimeError :> es)`.
So the worker's effect stack is `'[Pgmq, Tracing, Error PgmqRuntimeError, IOE]`, peeled exactly like
`shinzui/kizashi`'s `Kizashi.Delivery.DispatchProcessor` does: `runEff . runTracingNoop .
runErrorNoCallStack @PgmqRuntimeError . runPgmq pool $ …`. (Note: kioku's `Tracer`/`Tracing` come
from the *same* `Shibuya.Telemetry.Effect` module, so the one `Tracer` value serves both the worker's
`runApp` and kioku's `runAppIO` — but kioku runs in its own `runAppIO` call inside the handler, not
in the worker's effect row; see M2.)

**Commands to run.** From the repo root in the nix dev shell (`nix develop` or `direnv` already
active), with a local Postgres available (the project's `process-compose.yaml` runs one, or use
`just create-database`):

```bash
just create-database                     # lands kioku/keiro/kiroku tables + shikigami_fired (EP-1)
cabal build shikigami-core shikigami     # compiles the worker + CLI
cabal run shikigami -- worker --agents agents/ &   # boots the worker (background)
```

Then enqueue one job. Prefer EP-4's enqueue path once it exists; until then, insert directly with
pgmq's SQL function against the same database the worker is connected to:

```sql
-- psql against the shikigami database
select pgmq.send(
  'shikigami_run_jobs',
  '{"agentName":"heartbeat","occurrence":"2026-06-24T12:00:00Z","triggerKind":"schedule","payload":{},"idempotencyKey":"heartbeat:2026-06-24T12:00:00Z"}'::jsonb
);
```

**Acceptance.** The worker logs that it drained the job and acked it, e.g.:

```text
[shikigami.worker] processor=shikigami_run_jobs drained run job agent=heartbeat occurrence=2026-06-24T12:00:00Z -> AckOk
```

and the message is gone from the queue (`select * from pgmq.q_shikigami_run_jobs;` returns zero rows
for that id). A malformed body (`select pgmq.send('shikigami_run_jobs','{"bogus":true}'::jsonb);`)
logs a decode error and the message is dead-lettered (`select * from pgmq.a_shikigami_run_jobs;`
shows it archived), not retried forever.

### Milestone M2 — full orchestration for one agent

**Scope.** Replace `noopHandler` with `runJobHandler`, which performs the whole orchestration for one
drained job. At the end of M2, for a job naming a declared agent, the worker: opens a kioku session;
calls `Shikigami.Behavior.Run.runBehavior` (EP-2, IP-4) with the job's trigger payload; dispatches
each of the agent's `sinks` via `Shikigami.Sink.dispatch` (EP-3, IP-5) with the behavior's output
`Value`; completes the kioku session; and returns the right `AckDecision`. You prove it end-to-end
with one declared agent and demonstrate the retry and dead-letter arms.

The orchestration sequence, in prose (this is the heart of the plan):

1. **Decode** `ingested.envelope.payload :: Aeson.Value` into a `RunJob` via `decodeRunJob`. On
   failure return `AckDeadLetter (InvalidPayload <err>)` — a malformed job is permanent.
2. **Resolve the agent** by `runJob.agentName` against the loaded agents in `WorkerEnv`. Unknown
   agent → `AckDeadLetter (PoisonPill "unknown agent <name>")` (it will never become known by
   retrying this same job).
3. **Open a kioku session.** Generate a `SessionId` with `Kioku.Id.genSessionId`; build
   `StartSessionData { sessionId, agentId = agentName, focus = agentName, scope =
   Shikigami.Memory.Scope.agentScope agentName, subjectRef = runJob subject (type/id) if present,
   previousSessionId = Nothing, startedAt = now }`; run it through kioku with `Kioku.App.runAppIO env
   (Kioku.Session.start startData)`. A `Left` (store error or rejected command) is treated as
   transient → `AckRetry`.
4. **Run the behavior.** Call `Shikigami.Behavior.Run.runBehavior behaviorEnv agentDecl
   (runJob.payload)`. This returns `Either RunError Value`. (Inside `runBehavior`, EP-2 recalls the
   agent's prior memory and records the output as memory — EP-5 does not duplicate that; EP-5 owns
   only the session start/complete bracket around it.) On `Left runErr`: fail the session with
   `Kioku.Session.failSession (FailSessionData { sessionId, failedAt = now, errorMessage = render
   runErr })` and return `AckRetry <backoff>` (a behavior error is assumed transient unless it is a
   structural/decoding error, which the job decode already caught).
5. **Dispatch the sinks.** For each `sink` in `agentDecl.sinks`, in declaration order, call
   `Shikigami.Sink.dispatch sinkCtx sink behaviorOutput` — but **interpose the suppression gate
   around signal sinks** (added in M3; in M2 dispatch unconditionally). The dispatch is internally
   gated by `Shikigami.Sink.Permission.checkGrant` (EP-3); a *denied* sink is logged and skipped and
   does **not** fail the run (IP-5). Collect each `SinkResult`. Classify the worst outcome:
   - all sinks ok (or skipped-by-denial) → success;
   - any sink reported a *transient* failure (the dispatcher's `SinkResult` carries a
     transient/permanent discriminator — EP-3 owns its exact shape; EP-5 requires the ability to tell
     them apart) → retry;
   - any sink reported a *permanent* failure (payload rejected as invalid) → dead-letter.
6. **Complete the session.** On overall success, `Kioku.Session.complete (CompleteSessionData {
   sessionId, completedAt = now, modelUsed = behavior's model if any, summary = a short one-line
   summary of what fired })`. On a transient/permanent failure that aborts before completion, fail
   the session instead (so a crash mid-run leaves a non-`completed` row — the recovery signal).
7. **Return the `AckDecision`** per the worst outcome: success → `AckOk`; transient → `AckRetry
   (exponentialBackoff defaultBackoffPolicy attempt)` where `attempt = ingested.envelope.attempt`;
   permanent → `AckDeadLetter <reason>`.

`runBehavior`, `dispatch`, and the kioku functions all return `Either` rather than throwing, and the
handler runs each kioku call via `Kioku.App.runAppIO` (which returns `IO (Either StoreError a)`); so
the handler is written defensively — any `Left` maps to the appropriate `AckDecision` and any caught
exception from a sink HTTP client is classified transient (`AckRetry`) by default. Wrap the
sink-dispatch and behavior calls so an unexpected exception cannot escape to crash the processor.

**The two failure arms, made observable.** To prove `AckRetry` and `AckDeadLetter` without real
flakiness, M2 uses two fixtures:

- *Transient*: point the worker's kawa/kizashi sink base URL at a stub that returns HTTP 503 on the
  first delivery and 200 afterward (EP-3's `stub-kawa`/kizashi-stub can be configured to fail once,
  or run no stub at all so the first attempt gets connection-refused). The first delivery returns
  `AckRetry`; the message reappears after the backoff and the second delivery succeeds (`AckOk`).
- *Permanent*: enqueue a job whose body is structurally valid JSON but fails `decodeRunJob` (missing
  `agentName`) — it dead-letters immediately on attempt 0.

**Commands.**

```bash
cabal run shikigami -- worker --agents agents/ &
# enqueue a real job for a declared agent (heartbeat = ShikumiProgram noop-summary + KizashiSignal):
psql -c "select pgmq.send('shikigami_run_jobs','{\"agentName\":\"triage-note\",\"occurrence\":\"2026-06-24T12:00:00Z\",\"triggerKind\":\"stream\",\"subject\":{\"type\":\"ticket\",\"id\":\"T-1\"},\"payload\":{\"text\":\"customer is upset\"},\"idempotencyKey\":\"triage-note:T-1:2026-06-24\"}'::jsonb);"
```

**Acceptance.** After the job drains:

```text
[shikigami.worker] agent=triage-note session=kioku_session_… started
[shikigami.worker] agent=triage-note behavior=Skill output ok
[shikigami.sink] agent=triage-note sink=KizashiSignal -> POST /v1/signals 201
[shikigami.worker] agent=triage-note session=kioku_session_… completed -> AckOk
```

and a `kioku_sessions` row exists with `status='completed'`:

```sql
select session_id, agent_id, status from kiroku.kioku_sessions where agent_id='triage-note';
-- kioku_session_…  | triage-note | completed
```

and the kizashi stub logged one received `CreateSignalReq`. The transient fixture shows a first
`-> AckRetry 1.0s` line followed (after redelivery) by `-> AckOk`; the permanent fixture shows
`-> AckDeadLetter (InvalidPayload …)` and the message in `pgmq.a_shikigami_run_jobs`.

### Milestone M3 — the suppression gate and the `--agents` loop

**Scope.** Add the suppression gate around signal-raising sinks so a still-true condition raises at
most one signal across repeated evaluations, and finish the `shikigami worker --agents <dir>` loop so
it loads a directory of declared agents and runs continuously. At the end of M3, firing the same
agent twice (two identical jobs) produces exactly **one** signal and exactly **one**
`shikigami_fired` row; the second evaluation logs that it was suppressed.

New module: `shikigami-core/src/Shikigami/Worker/Suppression.hs` with two hasql `Session` actions
(restated under "The suppression gate" below):

- `alreadyFired :: SuppressionKey -> Session Bool` — a `SELECT 1 FROM shikigami_fired WHERE
  (detector, subject_type, subject_id, window_key) = …`.
- `recordFired :: SuppressionKey -> Text {- signal_id -} -> Session ()` — an `INSERT … ON CONFLICT
  DO NOTHING` storing the returned `signal_id`.

The `SuppressionKey` is `(detector = agentName, subjectType, subjectId, windowKey)`. The
`windowKey` defines "the same condition" and is supplied by EP-2's behavior output (the
`runBehavior` result `Value` carries a `windowKey` for detector-style agents; for agents that do not
compute one, the suppression gate is a no-op — only signal sinks for which a window key is present are
gated). For the M3 proof use the seed `agents/detectors/README.md` convention: for `stalled-intention`
the window key is the declaration's `occurred_at` truncated to the day.

The gate wraps step 5 of the M2 orchestration **only for `KizashiSignal` sinks**: before dispatching,
run `alreadyFired key` in the worker's hasql pool; if `True`, log `suppressed` and skip the POST; if
`False`, dispatch, and on a successful `SinkResult` carrying the returned `signal_id`, run
`recordFired key signalId`. The pre-check plus `ON CONFLICT DO NOTHING` makes a concurrent
double-fire (a redelivery race, or two workers) raise at most one signal — on top of shibuya/pgmq's
own delivery-level visibility-timeout dedup. `KawaDigest` and the other sinks are dispatched
unconditionally (they are idempotent at their doorways or are stubs).

Finish the `--agents <dir>` loader: on boot, list `*.dhall` in the directory (non-recursively), call
`Shikigami.Agent.Loader.loadAgent` on each, and keep the successfully-loaded `AgentDecl`s in
`WorkerEnv` keyed by `name`; a file that fails to load is logged and skipped (the worker still
starts). The `--kawa-url`, `--topic`, and `--broker` flags configure the sink client base URL and
(for EP-6's living loop) the stream consumer the worker co-hosts; M3 only exercises the queue path
and the suppression gate, so those flags need only be parsed and threaded, not exercised here.

**Commands.**

```bash
cabal run shikigami -- worker --agents agents/ &
# fire the SAME agent twice with the SAME window:
for i in 1 2; do
  psql -c "select pgmq.send('shikigami_run_jobs','{\"agentName\":\"stalled-intention\",\"occurrence\":\"2026-06-24T12:00:00Z\",\"triggerKind\":\"stream\",\"subject\":{\"type\":\"intention\",\"id\":\"I-9\"},\"payload\":{\"windowKey\":\"2026-06-17\"},\"idempotencyKey\":\"stalled-intention:I-9:$i\"}'::jsonb);"
done
```

**Acceptance.** The worker fires the first job (one signal raised, one `shikigami_fired` row written)
and *suppresses* the second:

```text
[shikigami.worker] agent=stalled-intention fired signal=sig_… recorded shikigami_fired
[shikigami.worker] agent=stalled-intention suppressed (already fired for intention/I-9 window 2026-06-17)
```

```sql
select count(*) from shikigami_fired
  where detector='stalled-intention' and subject_id='I-9' and window_key='2026-06-17';
-- 1
```

and the kizashi stub logged exactly **one** `CreateSignalReq` for `I-9`. Re-running the same two jobs
again still leaves the count at 1 (idempotent).


## Concrete Steps

State the exact commands to run and where to run them (working directory). All commands run from the
repository root `/Users/shinzui/Keikaku/bokuno/shikigami` inside the nix dev shell, unless noted.

### Step 0 — confirm prerequisites compile

EP-2, EP-3, EP-4, and EP-1 must be landed (or at least their seams stubbed) for the worker to
compile. Confirm the modules EP-5 imports exist:

```bash
cabal build shikigami-api shikigami-core    # EP-1/EP-2/EP-3 modules compile
ls shikigami-core/src/Shikigami/Behavior/Run.hs   # IP-4 (EP-2)
ls shikigami-core/src/Shikigami/Sink.hs           # IP-5 (EP-3)
ls shikigami-core/src/Shikigami/Memory/Scope.hs   # IP-3 helper (EP-1)
```

Confirm the worker's substrate deps are pinned (IP-8). If any errors as "unknown package," locate it
and add a stanza to `cabal.project`:

```bash
mori registry show shinzui/shibuya --full          # shibuya-core, shibuya-pgmq-adapter paths
mori registry show shinzui/pgmq-hs --full          # pgmq-effectful, pgmq-core paths
mori registry show shinzui/kioku --full            # kioku-core, kioku-api paths
```

(At authoring time these resolve to: shibuya-core / shibuya-pgmq-adapter under
`/Users/shinzui/Keikaku/bokuno/shibuya-project`; pgmq packages under
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`; kioku under
`/Users/shinzui/Keikaku/bokuno/kioku`.)

### Step 1 — M1 modules

Create `shikigami-core/src/Shikigami/Worker/Job.hs`, `shikigami-core/src/Shikigami/Worker.hs`, and
`shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs` per the M1 description; add them to the
`exposed-modules` of the respective cabal stanzas and add `shibuya-core`, `shibuya-pgmq-adapter`,
`pgmq-core`, `pgmq-effectful`, and `kioku-core` to `shikigami-core`'s `build-depends`. Build:

```bash
cabal build shikigami-core shikigami
```

Boot and drain a job (see M1 "Commands"). Expected transcript is the M1 "Acceptance" block.

### Step 2 — M2 handler

Replace `noopHandler` with `runJobHandler`; implement the seven-step orchestration. Build and run the
M2 commands; expected transcript is the M2 "Acceptance" block. Add a worker integration test (see
"Validation and Acceptance").

### Step 3 — M3 suppression + agents loop

Create `shikigami-core/src/Shikigami/Worker/Suppression.hs`; interpose the gate around `KizashiSignal`
dispatch; finish the `--agents` directory loader. Build and run the M3 commands; expected transcript
is the M3 "Acceptance" block.

### Step 4 — full build and test

```bash
cabal build all
cabal test shikigami-core-test           # or the project's test target name (see EP-1's cabal)
```


## Validation and Acceptance

Acceptance is phrased as observable behavior, proven with an ephemeral Postgres so the tests are
hermetic (no external services). Use EP-1's test-support helper
`Shikigami.Migrations.TestSupport.withShikigamiMigratedDatabase :: (Text -> IO a) -> IO a`, which
yields a connection string to a fresh database with all migrations applied (kioku's `kioku_sessions`
and shikigami's `shikigami_fired` included).

Write the worker tests in `shikigami-core/test/Shikigami/WorkerSpec.hs` (tasty + hedgehog/HUnit per
IP-9), each opening a pool against that database and enqueuing jobs with `pgmq-effectful`'s
`sendMessage`:

1. **M1 — drain proof.** Enqueue a valid `RunJob` JSON; run the worker for one poll cycle; assert the
   message is gone from `pgmq.q_shikigami_run_jobs` and the handler logged a drain. Enqueue a
   malformed body; assert it lands in `pgmq.a_shikigami_run_jobs` (dead-lettered), not retried.

2. **M2 — orchestration proof.** With one declared agent loaded (a fixture `AgentDecl` with a
   `ShikumiProgram "noop-summary"` behavior and a single `KizashiSignal` sink, pointed at a tiny
   in-test stub HTTP server recording requests), enqueue a job; run one poll cycle; assert: a
   `kioku_sessions` row exists with `status='completed'` and `agent_id` equal to the agent name; the
   stub received exactly one `CreateSignalReq`; the handler returned `AckOk` (assert via a returned
   metric/log or by the message being deleted).

   *Retry arm:* configure the stub to fail the first request (503) and succeed the second; enqueue;
   run two poll cycles; assert the first cycle returned `AckRetry` (message still present with an
   advanced visibility time) and the second returned `AckOk`.

   *Dead-letter arm:* enqueue a structurally-valid JSON that lacks `agentName`; run one cycle; assert
   `AckDeadLetter` (message archived).

3. **M3 — suppression proof.** Load a detector-style agent whose behavior output carries a
   `windowKey`; enqueue two identical jobs (same subject + window); run the worker; assert the stub
   received exactly **one** signal and `select count(*) from shikigami_fired where detector=… and
   window_key=…` returns 1. Run the same two jobs a third time; assert the count is still 1 and the
   stub received no additional signal.

Each test must *fail before the corresponding code exists and pass after* — e.g. before M3 the
suppression test sees two signals and fails; after M3 it sees one. That is the "effective beyond
compilation" evidence the spec requires.

The end-to-end living-loop validation (three trigger classes, both behavior arms, kawa re-publish →
second agent, feedback guard, permission denial, across-run memory, detector conformance) is **not**
validated here — it is `docs/plans/6-end-to-end-living-loop-proof-and-detector-conformance.md`'s job.
EP-5's acceptance is the worker orchestration with one or two agents against the Phase-2 stubs.


## Idempotence and Recovery

The whole worker is designed to be safely repeatable:

- **Re-running the worker is safe.** It is a stateless drainer; restarting it re-leases whatever is on
  the queue. A message in flight when the worker dies is not acked, so its pgmq visibility timeout
  lapses and it is redelivered — exactly the recovery path shibuya/pgmq provide.

- **A crash mid-run leaves a non-`completed` kioku session.** kioku writes are idempotent on the
  caller-supplied `SessionId`, and `start` returns the existing id if the session already exists, so a
  redelivered job that re-opens the same session (use a `SessionId` *derived deterministically from the
  job's `idempotencyKey`* rather than a fresh random one, so redelivery resumes the same session) does
  not create a duplicate row. A session left `running`/`failed` is the recovery signal; the worker
  never deletes session rows, so history is an audit trail.

- **Suppression is idempotent by construction.** `recordFired` is `INSERT … ON CONFLICT DO NOTHING`,
  so re-recording the same `(detector, subject, window)` is a no-op; the `alreadyFired` pre-check plus
  the conflict clause means a redelivery or a concurrent second worker raises at most one signal. Even
  if a signal is raised but the worker crashes before `recordFired`, the next evaluation will re-raise
  at most once more — kizashi's own idempotency (and the back-reference `activity://<id>` tag) bounds
  the duplication; this is documented in `agents/detectors/README.md`.

- **Dead-lettering is the safe halt for poison.** A malformed/undecodable job is archived to
  `pgmq.a_shikigami_run_jobs` rather than retried forever, so it can be inspected and replayed
  manually (`select pgmq.send('shikigami_run_jobs', message) from pgmq.a_shikigami_run_jobs where
  msg_id = …`) after the cause is fixed.

- **Re-running migrations is safe.** EP-1's migrations (via `codd`) and `shikigami_fired`'s `CREATE
  TABLE IF NOT EXISTS` are idempotent; `just create-database` can be re-run on a fresh ephemeral
  cluster without drift.


## Interfaces and Dependencies

This section names every type and signature EP-5 produces or consumes, with full module paths. The
signatures of consumed libraries are quoted from their real sources (verified during authoring).

### Consumed substrate — `shinzui/shibuya` (the supervised worker)

Package `shibuya-core` (source: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core`).

```haskell
-- Shibuya.App
runApp ::
  (IOE :> es, Tracing :> es) =>
  SupervisionStrategy ->                 -- IgnoreFailures | StopAllOnFailure
  Int ->                                 -- inbox size (backpressure bound)
  [(ProcessorId, QueueProcessor es)] ->
  Eff es (Either AppError (AppHandle es))

waitApp           :: (IOE :> es) => AppHandle es -> Eff es ()
stopAppGracefully :: (IOE :> es) => ShutdownConfig -> AppHandle es -> Eff es Bool

data SupervisionStrategy = IgnoreFailures | StopAllOnFailure

-- a GADT; queue/poll/retry/DLQ config lives in the Adapter, not here
data QueueProcessor es where
  QueueProcessor :: { adapter :: Adapter es msg, handler :: Handler es msg,
                      ordering :: Ordering, concurrency :: Concurrency } -> QueueProcessor es
mkProcessor :: Adapter es msg -> Handler es msg -> QueueProcessor es   -- Unordered, Serial

-- Shibuya.Handler
type Handler es msg = Ingested es msg -> Eff es AckDecision

-- Shibuya.Core.Ingested / Shibuya.Core.Types
data Ingested es msg = Ingested { envelope :: !(Envelope msg), ack :: !(AckHandle es), lease :: !(Maybe (Lease es)) }
-- envelope.payload :: msg ;  envelope.attempt :: Maybe Attempt (zero-indexed redelivery counter)

-- Shibuya.Core.Ack
data AckDecision = AckOk | AckRetry !RetryDelay | AckDeadLetter !DeadLetterReason | AckHalt !HaltReason
newtype RetryDelay = RetryDelay { unRetryDelay :: NominalDiffTime }
data DeadLetterReason = PoisonPill !Text | InvalidPayload !Text | MaxRetriesExceeded

-- Shibuya.Core.Retry
defaultBackoffPolicy :: BackoffPolicy                    -- base 1s, factor 2, max 300s, FullJitter
exponentialBackoff   :: (IOE :> es) => BackoffPolicy -> Attempt -> Eff es RetryDelay

-- Shibuya.Telemetry.Effect   (also re-used by kioku)
runTracingNoop :: Eff (Tracing : es) a -> Eff es a
```

Package `shibuya-pgmq-adapter` (source: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`).

```haskell
-- Shibuya.Adapter.Pgmq
pgmqAdapter ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es, Tracing :> es) =>
  PgmqAdapterConfig -> Eff es (Adapter es Value)        -- payload is always aeson Value

-- Shibuya.Adapter.Pgmq.Config
data PgmqAdapterConfig = PgmqAdapterConfig
  { queueName :: !QueueName, visibilityTimeout :: !Int32, batchSize :: !Int32,
    polling :: !PollingConfig, pollRetry :: !PollRetryConfig,
    deadLetterConfig :: !(Maybe DeadLetterConfig), maxRetries :: !Int64, ... }
defaultConfig    :: QueueName -> PgmqAdapterConfig
directDeadLetter :: QueueName -> Bool -> DeadLetterConfig
```

Message lifecycle the adapter implements: read leases with `visibilityTimeout`; `AckOk` deletes;
`AckRetry` extends the visibility timeout by the delay; `AckDeadLetter` archives/routes; when pgmq's
`read_ct > maxRetries` the adapter auto-dead-letters before the handler runs.

**Reference construction pattern** (the canonical wiring, from `shinzui/keiro`'s `Keiro.PGMQ.Job`,
quoted to model EP-5's handler-to-AckDecision mapping):

```haskell
-- adapter <- pgmqAdapter (adapterConfigFor tuning job)
-- pure (ProcessorId job.jobName, mkProcessor adapter (wrapHandler job handle))
-- toAck Done = AckOk; toAck (Retry d) = AckRetry d; toAck RetryDefault = AckRetry default
-- toAck (Dead why) = AckDeadLetter (PoisonPill why); decode-fail -> AckDeadLetter (InvalidPayload err)
```

The kizashi boot (`Kizashi.Delivery.DispatchProcessor`) peels the stack as:
`runEff . runTracingNoop . runErrorNoCallStack @PgmqRuntimeError . runPgmq pool $ runJobWorkers
IgnoreFailures 100 [ … ] >>= \(Right h) -> waitApp h`. EP-5 may either call the raw
`pgmqAdapter`/`runApp` path or the `Keiro.PGMQ.Job` wrapper (`jobProcessor`/`runJobWorkers`); the
wrapper is preferred (it owns the decode→`AckDecision` mapping). Confirm in the Decision Log which is
used.

### Consumed substrate — `shinzui/pgmq-hs` (the queue)

Packages `pgmq-core`, `pgmq-effectful` (source:
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`).

```haskell
-- Pgmq.Types
newtype QueueName = QueueName Text          -- constructor hidden
parseQueueName  :: Text -> Either PgmqError QueueName    -- name <= 47 chars, alnum + '_'
queueNameToText :: QueueName -> Text
newtype MessageBody = MessageBody { unMessageBody :: Value }   -- aeson Value <-> jsonb
newtype MessageId   = MessageId   { unMessageId   :: Int64 }
data Message = Message { messageId :: !MessageId, visibilityTime :: !UTCTime, enqueuedAt :: !UTCTime,
                         lastReadAt :: !(Maybe UTCTime), readCount :: !Int64, body :: !MessageBody,
                         headers :: !(Maybe Value) }

-- Pgmq.Effectful  (effect = Pgmq; run with runPgmq :: Pool -> Eff (Pgmq : es) a -> Eff es a)
sendMessage :: (Pgmq :> es) => SendMessage -> Eff es MessageId
readMessage :: (Pgmq :> es) => ReadMessage -> Eff es (Vector Message)
data SendMessage = SendMessage { queueName :: !QueueName, messageBody :: !MessageBody, delay :: !(Maybe Int32) }

-- Pgmq.Effectful.Interpreter
runPgmq :: (IOE :> es, Error PgmqRuntimeError :> es) => Pool -> Eff (Pgmq : es) a -> Eff es a
data PgmqRuntimeError = PgmqAcquisitionTimeout | PgmqConnectionError ... | PgmqSessionError ...
```

EP-5 uses `runPgmq pool` in the worker effect stack (the adapter reads through it) and uses
`sendMessage` only in tests/fixtures to enqueue jobs.

### Consumed substrate — `shinzui/kioku` (sessions) — the EP-2 seam (IP-3)

Source: `/Users/shinzui/Keikaku/bokuno/kioku`. EP-5 manages the session lifecycle around a run.

```haskell
-- Kioku.App
type AppEffects = '[Store, Error StoreError, Tracing, IOE]
data AppEnv = AppEnv { store :: !KirokuStore, tracer :: !Tracer, metrics :: !(Maybe KeiroMetrics) }
runAppIO   :: AppEnv -> Eff AppEffects a -> IO (Either StoreError a)
noopTracer :: IO Tracer                          -- Tracer/Tracing from Shibuya.Telemetry.Effect

-- Kioku.Session   (each returns Eff es (Either SessionWriteError SessionId))
start       :: (...) => StartSessionData    -> Eff es (Either SessionWriteError SessionId)
complete    :: (...) => CompleteSessionData -> Eff es (Either SessionWriteError SessionId)
failSession :: (...) => FailSessionData     -> Eff es (Either SessionWriteError SessionId)
data StartSessionData = StartSessionData
  { sessionId :: !SessionId, agentId :: !Text, focus :: !Text, scope :: !MemoryScope,
    subjectRef :: !(Maybe Text), previousSessionId :: !(Maybe SessionId), startedAt :: !UTCTime }
data CompleteSessionData = CompleteSessionData
  { sessionId :: !SessionId, completedAt :: !UTCTime, modelUsed :: !(Maybe Text), summary :: !(Maybe Text) }
data FailSessionData = FailSessionData
  { sessionId :: !SessionId, failedAt :: !UTCTime, errorMessage :: !Text }

-- Kioku.Id
type SessionId = KindID "kioku_session"
genSessionId :: (MonadIO m) => m SessionId          -- or derive deterministically from idempotencyKey
idText       :: KindID prefix -> Text

-- Kioku.Api.Scope  (used via Shikigami.Memory.Scope)
data MemoryScope = ScopeGlobal Namespace | ScopeEntity Namespace ScopeKind Text
newtype Namespace = Namespace Text
newtype ScopeKind = ScopeKind Text
```

Note: kioku writes are idempotent on the caller-supplied `SessionId` and run in `Eff AppEffects` via
`runAppIO`. kioku's `Tracer`/`Tracing` come from the *same* `Shibuya.Telemetry.Effect` as the
worker's, so one `noopTracer` value serves both.

### Consumed seam — the behavior runner (IP-4, owned by EP-2)

`docs/plans/2-behavior-runner-and-kioku-session-and-memory-integration.md` owns this. EP-5 requires:

```haskell
-- Shikigami.Behavior.Run   (shikigami-core)
runBehavior :: BehaviorEnv -> AgentDecl -> Aeson.Value -> IO (Either RunError Aeson.Value)
--   input Value  = the trigger payload (RunJob.payload)
--   output Value = the behavior's result, handed to the sinks
```

`BehaviorEnv` is constructed once at worker boot (it holds the handan `Runtime`, the baikai provider,
the program registry, and the kioku `AppEnv` EP-2 uses for recall/record). EP-5 carries it in
`WorkerEnv` and passes it per run. If EP-2's final signature differs (e.g. runs in `Eff` rather than
`IO`, or names the env differently), reconcile in the Decision Log; the *requirement* is: given an
`AgentDecl` and a trigger payload `Value`, produce `Either RunError Value`.

### Consumed seam — the sink dispatcher and permission gate (IP-5, owned by EP-3)

`docs/plans/3-sink-dispatcher-permission-gate-and-kawa-stub.md` owns this. EP-5 requires:

```haskell
-- Shikigami.Sink   (shikigami-core)
dispatch :: SinkContext -> Sink -> Aeson.Value -> IO SinkResult
-- Shikigami.Sink.Permission
checkGrant :: AgentIdentity -> SinkKind -> IO (Either Denied ())   -- denied sink is logged + skipped
```

`SinkResult` must let EP-5 distinguish: success (with, for a signal sink, the returned `signal_id`
needed by `recordFired`), a *denied* outcome (skip, do not fail), a *transient* failure (→ `AckRetry`),
and a *permanent* failure (→ `AckDeadLetter`). `SinkContext` is built at boot from the kawa/kizashi
base URLs (the `--kawa-url` flag), the agent identity, and an HTTP client. If EP-3's `SinkResult` does
not yet carry the transient/permanent discriminator or the returned signal id, EP-5 requires those
fields be added to EP-3's deliverable; record the amendment in the Decision Log.

### Consumed contract — the trigger→run job (IP-7, owned by EP-4) — RESTATED HERE

`docs/plans/4-trigger-evaluators-and-the-activity-v1-stream-consumer.md` **owns** the IP-7 job/queue
contract (it enqueues; EP-5 drains). At the time EP-5 was authored, EP-4 was still a skeleton, so the
contract below is the shape EP-5 *requires* and consumes; EP-4 must produce exactly this (and is its
authoritative owner — if EP-4 settles a different shape, this section and EP-5's `RunJob` decoder are
updated to match, recorded in the Decision Log).

- **Queue name:** `shikigami_run_jobs` (a single pgmq queue carrying every run job, regardless of
  which trigger class produced it — schedule due-time jobs, matched stream envelopes, and addressed
  inbox deliveries all land here). EP-5 binds the worker to this one queue.
- **Job body (JSON, jsonb in the pgmq message `message` column):**

```json
{
  "agentName": "stalled-intention",
  "occurrence": "2026-06-24T12:00:00Z",
  "triggerKind": "stream",
  "subject": { "type": "intention", "id": "I-9" },
  "payload": { "windowKey": "2026-06-17", "...": "the behavior's input Value" },
  "idempotencyKey": "stalled-intention:I-9:2026-06-17"
}
```

- `agentName` (required) — which declared agent to run; EP-5 resolves it against the loaded agents.
- `occurrence` (required, RFC3339) — the trigger occurrence instant (the cron tick, the envelope's
  `occurred_at`, or the delivery time); used in the session and logging.
- `triggerKind` (required) — one of `"schedule" | "stream" | "event"`; informational for EP-5
  (logging/metrics), the orchestration is identical across kinds.
- `subject` (optional) — the `{type,id}` the run is about, when the trigger has one (stream/event);
  used for the kioku session `subjectRef` and the suppression key.
- `payload` (required, may be `{}`) — the trigger payload `Value` passed verbatim to `runBehavior`.
  For detector-style agents EP-2's behavior surfaces a `windowKey` in its *output*; EP-4 may also
  pre-place the window key in `payload.windowKey` (the M3 examples assume so) — EP-4 and EP-2 agree
  the window-key source; EP-5 reads whichever is present for suppression.
- `idempotencyKey` (required) — a deterministic key for the trigger occurrence (e.g.
  `<agentName>:<subjectId>:<windowKey>` or `<agentName>:<occurrence>`). EP-5 derives the kioku
  `SessionId` from this so a redelivered job resumes the same session rather than opening a duplicate.

EP-5's mirror of this contract:

```haskell
-- Shikigami.Worker.Job   (shikigami-core)  -- EP-5 owns this decoder; EP-4 owns the producer
data RunJob = RunJob
  { agentName      :: !Text
  , occurrence     :: !UTCTime
  , triggerKind    :: !Text
  , subject        :: !(Maybe Subject)        -- Subject { subjectType :: Text, subjectId :: Text }
  , payload        :: !Aeson.Value
  , idempotencyKey :: !Text
  } deriving stock (Generic, Eq, Show)
runJobQueueName :: QueueName                    -- parseQueueName "shikigami_run_jobs"
decodeRunJob    :: Aeson.Value -> Either Text RunJob
```

### The suppression gate — `shikigami_fired` (table owned by EP-1's migration; flow owned here)

The table DDL is created by EP-1's `shikigami-migrations` exactly as specified in the seed
`agents/detectors/README.md`:

```sql
CREATE TABLE IF NOT EXISTS shikigami_fired (
  detector     TEXT        NOT NULL,
  subject_type TEXT        NOT NULL,
  subject_id   TEXT        NOT NULL,
  window_key   TEXT        NOT NULL,
  signal_id    TEXT        NOT NULL,
  fired_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (detector, subject_type, subject_id, window_key)
);
```

EP-5's gate (in `Shikigami.Worker.Suppression`, run in the worker's hasql `Pool`):

```haskell
data SuppressionKey = SuppressionKey
  { detector :: !Text, subjectType :: !Text, subjectId :: !Text, windowKey :: !Text }

alreadyFired :: SuppressionKey -> Hasql.Session Bool
--   SELECT EXISTS (SELECT 1 FROM shikigami_fired
--     WHERE detector=$1 AND subject_type=$2 AND subject_id=$3 AND window_key=$4)

recordFired  :: SuppressionKey -> Text {- signal_id -} -> Hasql.Session ()
--   INSERT INTO shikigami_fired (detector, subject_type, subject_id, window_key, signal_id)
--     VALUES ($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING
```

Evaluation flow for a `KizashiSignal` sink: compute the finding; if `alreadyFired key` → **skip the
POST** (log `suppressed`); else `dispatch` the signal → on a successful `SinkResult` carrying
`signal_id`, `recordFired key signalId`. The pre-check plus `ON CONFLICT DO NOTHING` bounds a
concurrent/redelivery double-fire to at most one signal, on top of pgmq's delivery-level dedup. The
`windowKey` defines "the same condition": for `stalled-intention` it is the declaration's
`occurred_at` truncated to the day, so a *new* staleness episode (a fresh declaration) gets a new key
and may fire again.

### EP-5's produced modules and signatures

```haskell
-- Shikigami.Worker.Job   (shikigami-core)
data RunJob ; data Subject ; runJobQueueName :: QueueName ; decodeRunJob :: Aeson.Value -> Either Text RunJob

-- Shikigami.Worker   (shikigami-core)
data WorkerConfig = WorkerConfig { agentsDir :: !FilePath, kawaUrl :: !(Maybe Text),
                                   topic :: !Text, broker :: !(Maybe Text) }
data WorkerEnv     -- holds: hasql Pool, kioku AppEnv, loaded [AgentDecl] keyed by name, BehaviorEnv,
                   --        SinkContext, a Shibuya Tracer
runWorker     :: WorkerConfig -> IO ()            -- boots the pool/env, loads agents, runs the shibuya app
runJobHandler :: WorkerEnv -> Ingested es Value -> Eff es AckDecision   -- the orchestration (M2/M3)

-- Shikigami.Worker.Suppression   (shikigami-core)
data SuppressionKey ; alreadyFired :: SuppressionKey -> Hasql.Session Bool
recordFired :: SuppressionKey -> Text -> Hasql.Session ()

-- Shikigami.Cli.Commands.Worker   (shikigami-cli)
workerCommand :: optparse-applicative parser producing WorkerConfig, dispatching to runWorker
```

### CLI surface (the `shikigami` executable)

```text
shikigami worker --agents <dir> [--kawa-url <u>] [--topic activity.v1] [--broker <h:p>]
```

`--agents <dir>` (required) — directory of `*.dhall` agent manifests to load. `--kawa-url <u>` — base
URL for the kawa digest sink (defaults to the local `stub-kawa` URL). `--topic activity.v1` and
`--broker <h:p>` — configure the `activity.v1` stream consumer the worker co-hosts for EP-6's living
loop; parsed and threaded by EP-5, exercised by EP-6. EP-5's milestones exercise only the queue path.


---

## Revision Note

2026-06-24 — Initial authoring of EP-5 from the skeleton. Filled every section against the frozen
design in `docs/initial-spec.md` and the MasterPlan `docs/masterplans/1-…` (Integration Points IP-3,
IP-4, IP-5, IP-7, IP-8, IP-9). Real library signatures for `shinzui/shibuya` (`runApp`,
`QueueProcessor`, `Handler`, `AckDecision`, `pgmqAdapter`), `shinzui/pgmq-hs` (`sendMessage`,
`readMessage`, `Message`, `QueueName`, `runPgmq`), and `shinzui/kioku` (`Kioku.App.runAppIO`/`AppEnv`/
`noopTracer`, `Kioku.Session.start`/`complete`/`failSession`, `Kioku.Id`, `Kioku.Api.Scope`) were
read from source via `mori registry show` and are quoted verbatim under "Interfaces and Dependencies."
Because the sibling plans EP-2, EP-3, and EP-4 were still skeletons at authoring time, the IP-4/IP-5/
IP-7 contracts EP-5 consumes are restated here as the shapes EP-5 requires, each annotated with its
owning plan; the IP-7 run-job/queue contract is owned by EP-4 and is restated in full so EP-5 is
self-contained. The end-to-end living-loop proof is explicitly deferred to
`docs/plans/6-end-to-end-living-loop-proof-and-detector-conformance.md`.
