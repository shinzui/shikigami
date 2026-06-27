---
id: 10
slug: timer-driven-schedules-mid-run-resume-and-run-tracing
title: "Timer-driven schedules, mid-run resume, and run tracing"
kind: exec-plan
created_at: 2026-06-27T16:23:56Z
intention: "intention_01kw4y6m1we4ptk3wm2t9px38b"
---

# Timer-driven schedules, mid-run resume, and run tracing

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today `shinzui/shikigami` — the project that turns a declared agent (a small Dhall file naming
a trigger, a behavior, and some sinks) into running work — has three holes that keep its
agents from being trustworthy autonomous workers. This plan closes all three so that, after
implementation, a person can observe these concrete behaviors that are impossible now:

1. **A scheduled agent actually fires on its own.** Declare an agent with a `Schedule` trigger
   of `"* * * * *"` (cron for "every minute"), start the runtime, walk away, and one minute
   later a run has happened: a `kioku_sessions` row exists, the agent's behavior ran, and its
   sinks dispatched. Right now nothing fires — `shikigami` can *evaluate* whether a cron is due
   (`Shikigami.Trigger.Schedule.isDue`) but **nothing drives the clock**, so a `Schedule`
   trigger is inert.

2. **A run that crashes halfway resumes from where it stopped, instead of starting over.** Kill
   the worker process while an agent run is between its "record memory" and "complete session"
   steps; restart it; the run finishes *without re-running the steps that already completed*
   (no duplicate memory, no re-execution of an expensive behavior). Right now a crash leaves a
   half-finished `kioku` session marked `Started`, and the next attempt re-runs the agent from
   the very top.

3. **A run is traceable end to end.** With an OpenTelemetry collector configured, a single run
   appears as a span tree — a parent `agent.run` span with child spans for `trigger`,
   `behavior`, and each `sink.dispatch`, and the behavior's model calls carry GenAI semantic
   attributes (`gen_ai.request.model`, `gen_ai.usage.input_tokens`, …). Right now the worker is
   wired to `runTracingNoop` (a tracer that drops everything), so a run is invisible.

"OpenTelemetry" (OTel) is the vendor-neutral standard for emitting traces; a "span" is one
timed unit of work with a name, attributes, and a parent, and spans nest into a tree that a
tool like Jaeger or Honeycomb renders as a flame graph. "GenAI semantic conventions" are the
agreed attribute names OTel defines for LLM calls (the `gen_ai.*` keys above), so any backend
understands them without custom parsing.

These three items share one substrate: `shinzui/keiro`, the event-sourcing and workflow engine
that already provides durable **timers** and durable **workflow journaling**. This plan does
not build new durable infrastructure; it wires shikigami onto keiro's existing primitives and
onto the OTel tracing that `baikai`/`shikumi`/`shibuya` already ship.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone A — timer-driven schedule firing:

- [ ] Add `nextDue :: CronSchedule -> UTCTime -> Maybe UTCTime` to `Shikigami.Trigger.Schedule`.
- [ ] Add `TriggeredBySchedule` to `TriggerKind` in `Shikigami.Api.RunJob`.
- [ ] Create `Shikigami.Trigger.Scheduler` with the schedule-timer payload, deterministic
      timer id, arming function, and the timer `fire` action that enqueues a run job and re-arms.
- [ ] Add a `scheduler` CLI subcommand that arms all scheduled agents once at boot and runs the
      keiro timer worker loop.
- [ ] Unit tests: `nextDue`, payload round-trip, deterministic timer id, fire-action enqueues + re-arms.
- [ ] End-to-end: a `"* * * * *"` agent produces a `kioku_sessions` row within ~70s of boot.

Milestone B — mid-run resume on the keiro workflow substrate (depends on plan 7):

- [ ] Confirm plan 7 (`docs/plans/7-agent-runs-as-durable-keiro-workflows.md`) has landed and
      `runAgentWorkflow` (or equivalent) exists; if not, block this milestone and note it here.
- [ ] Re-platform `Shikigami.Agent.Run.runAgentWithMemory` so its five phases are named keiro
      `step`s journaled under `wf:shikigami.agent-run-<sessionId>`.
- [ ] Add a resume entry point that, on worker boot, finds unfinished agent-run workflows and
      re-invokes `runWorkflow` so they continue from the journal.
- [ ] Test: kill between `record-memory` and `complete-session`; restart; assert exactly one
      memory row and a `Completed` session (no re-run of completed steps).

Milestone C — real OTel tracing through the run:

- [ ] Add `Shikigami.Telemetry` with `withRunTracer` (build a real `Tracer` from env, else noop).
- [ ] Replace `runTracingNoop` in `Shikigami.Worker.runWorker` with `runTracing tracer`.
- [ ] Emit `agent.run` parent span with `trigger`, `behavior`, `sink.dispatch` child spans;
      attach GenAI attributes via baikai's `otelSink` on the behavior's model calls.
- [ ] Wire the CLI to build the tracer from `OTEL_EXPORTER_OTLP_ENDPOINT` (noop when unset).
- [ ] Demonstrate spans for one run against a local collector (or the debug span processor).

(Replace this seed checklist with the true state as work proceeds; split any partially done item.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision (cross-plan coherence review, 2026-06-27): Milestone B **consumes plan 7's
  `agentRunWorkflow`** (constant name `WorkflowName "shikigami.agent-run"`, the 8-step decomposition,
  sinks dispatched inside the workflow) and plan 7's `runWorkflowResumeWorker`; it no longer defines a
  divergent 5-step `WorkflowName "agent-run"` with sinks dispatched outside. The schedule timer is
  routed through the **single** `runWorkflowTimerWorker` fallback shared with plan 7's approval-timeout
  timers (one `shikigamiTimerFallback` keyed by payload `"kind"`), not a second worker loop. The
  validation SQL now matches `wf:shikigami.agent-run-%`.
  Rationale: The audit of plans 7–11 found this plan had independently re-platformed the run with a
  different workflow name, step set, sink boundary, and a parallel timer worker — all of which would
  collide with plan 7 (the keystone). Pinning to plan 7's artifacts removes the duplication and keeps
  the five plans coherent; this plan's genuine contribution (scheduler arming + tracing + a resume
  *acceptance test*) is unaffected. The sink-dispatch question (C3) was subsequently resolved as Option 3
  (transactional outbox) in plan 7's Decision Log — this plan conforms (see its Revision Notes C3
  follow-up).
  Date: 2026-06-27

- Decision: Drive scheduled (cron) agents with **keiro durable timers** (`keiro_timers`), not a
  bespoke in-process timer loop and not a bare pgmq message carrying a `delay`. The timer's
  `fire` action enqueues a normal run job onto the existing `shikigami_run_jobs` pgmq queue and
  arms the next occurrence.
  Rationale: This resolves the spec's Open Question 2 (`docs/initial-spec.md` line 934:
  "Schedule drive mechanism. Timer loop vs. enqueue-a-due-time-message"). EP-4's plan already
  leaned toward "enqueue a due-time run job onto pgmq" (`docs/plans/4-…md` Decision on Open
  Question 2), but left *who computes the due time and arms it* unspecified. A keiro timer **is**
  a durable due-time message: a `keiro_timers` row with a `fire_at`, claimed exactly once with
  `FOR UPDATE SKIP LOCKED` and recovered after a stale claim (`Keiro.Timer.runTimerWorker`).
  Choosing it over the two alternatives: (1) a hand-rolled timer loop that polls `isDue` every
  minute is exactly the "timer loop" the spec wanted to avoid — it needs its own liveness,
  leader election, and crash recovery; (2) a bare pgmq message with `delay` (visibility timeout)
  fires once but does not *recur*, so cron re-arming would still need a driver, and pgmq's delay
  is a best-effort visibility timeout, not a deterministic due-time row with idempotent ids. The
  keiro timer gives deterministic, idempotent timer ids (re-arming the same id is a no-op), and —
  decisively — **the same timer worker also drains plan 7's workflow sleeps** (the `awaitApproval`
  / `sleep` suspensions), so one timer subsystem serves both scheduling and mid-run suspension.
  We keep the existing `shikigami_run_jobs` pgmq queue as the single worker ingestion path, so
  the worker (EP-5) drains schedule-fired jobs identically to stream/event jobs.
  Date: 2026-06-27

- Decision: Mid-run resume (Milestone B) is built **on top of plan 7's keystone**
  (`docs/plans/7-agent-runs-as-durable-keiro-workflows.md`, "Agent runs as durable keiro
  workflows"), which re-platforms the behavior runner onto a keiro `Workflow`. This plan does
  not re-implement the workflow substrate; it delivers the *resume behavior* (a crash mid-step
  continues from the journal) and its acceptance test.
  Rationale: keiro's `Keiro.Workflow.runWorkflow` already journals each named `step` and, on
  replay, returns recorded results without re-running side effects — that is precisely
  "resume mid-step". Building resume any other way (e.g. a custom `agent_runs` checkpoint table)
  would duplicate keiro's journal. Milestones A and C do **not** depend on plan 7 and can land
  first.
  Date: 2026-06-27

- Decision: For tracing (Milestone C) **reuse the existing OTel stack** — `Shibuya.Telemetry.Effect`
  (`Tracing`, `runTracing`, `withSpan'`) for the run/trigger/behavior/sink spans, and baikai's
  `Baikai.Trace.Sink.OpenTelemetry.otelSink` for the behavior's model-call spans with GenAI
  attributes — rather than introducing a new tracing API.
  Rationale: `shibuya-core` already defines the `Tracing` effect the worker runs under (the
  worker just passes `runTracingNoop` today); baikai-trace-otel already emits `gen_ai.*` spans;
  shikumi-trace-otel can export a `TraceTree` as nested spans. Wiring is strictly additive: swap
  the noop runner for a real tracer and add `withSpan'` brackets. No new dependency surface.
  Date: 2026-06-27

- Decision: `nextDue` is computed with the Hackage `cron` package's `nextMatch` if exported;
  otherwise by iterating `scheduleMatches` minute-by-minute from `now + 60s` up to a 366-day
  bound and returning the first match (a `Nothing` means "never fires", e.g. Feb 30).
  Rationale: `Shikigami.Trigger.Schedule` already wraps the `cron` package
  (`parseCronSchedule`, `scheduleMatches`); computing the next occurrence is the natural
  extension. The iteration fallback keeps the plan runnable even if `nextMatch` is not exposed
  by the pinned `cron` version, and the 366-day bound makes a "never" terminating.
  Date: 2026-06-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it before touching code.

### What shikigami is and how a run happens today

`shinzui/shikigami` (working tree at `/Users/shinzui/Keikaku/bokuno/shikigami`) is a declarative
agent runtime. An "agent" is a Dhall declaration (`AgentDecl` in
`shikigami-core/src/Shikigami/Api/Agent.hs`) naming three things: a **trigger** (what makes the
agent fire — one of `Schedule` (a cron clock), `Stream` (a Kafka `activity.v1` consumer), or an
addressed `Event`), a **behavior** (`ShikumiProgram`, `Skill`, or `Deterministic` — the work the
agent does), and zero or more **sinks** (where the result goes — `kawa`, `kizashi`, `rei`,
`danwa`).

The runtime is built from four cabal packages declared in `cabal.project`: `shikigami-api`,
`shikigami-core`, `shikigami-cli` (the executable is named `shikigami`, see
`shikigami-cli/shikigami-cli.cabal` line 48), and `shikigami-migrations`.

A run flows through these modules:

- `shikigami-core/src/Shikigami/Trigger/Enqueue.hs` — `Shikigami.Trigger.Enqueue` — the producer
  side. It builds a `RunJob` (`shikigami-api/src/Shikigami/Api/RunJob.hs`) and sends it onto the
  `shikigami_run_jobs` pgmq queue (`runQueueName`). "pgmq" is a Postgres-backed message queue
  (`shinzui/pgmq-hs`). Existing producers: `runJobFromEnvelope` (stream triggers,
  `TriggeredByStream`) and `enqueueAddressedRun` (event triggers, `TriggeredByEvent`). There is
  **no schedule producer** — that is the hole Milestone A fills.
- `shikigami-core/src/Shikigami/Worker.hs` — `Shikigami.Worker` — the consumer side. `runWorker`
  builds a `shibuya` `QueueProcessor` over the same pgmq queue and drains it. `shibuya`
  (`shinzui/shibuya`) is the supervised queue-processor framework. For each drained job,
  `handleRunJob` → `runOneAgent` calls `runAgentWithMemory` (the run) and then `dispatch` for
  each sink. **Line 34 imports `runTracingNoop` and line 61 runs the whole app under it** — that
  is the hole Milestone C fills.
- `shikigami-core/src/Shikigami/Agent/Run.hs` — `Shikigami.Agent.Run` — `runAgentWithMemory`
  performs the run as five sequential phases against `shinzui/kioku` (the session/memory engine):
  (1) `Session.start` opens a `kioku` session (this replaces a bespoke `agent_runs` row), (2)
  `recallPriorLearnings` reads what the agent learned in earlier runs, (3) `runBehavior` runs the
  behavior to completion, (4) `Memory.record` stores the run's output as a durable memory, (5)
  `Session.complete` marks the session done (or `Session.failSession` on error). **These phases
  run straight through with no journaling: a crash after phase 3 but before phase 5 leaves a
  session stuck in `Started`, and the next attempt re-runs from phase 1.** That is the hole
  Milestone B fills.
- `shikigami-core/src/Shikigami/Trigger/Schedule.hs` — `Shikigami.Trigger.Schedule` — wraps the
  Hackage `cron` package. It exposes `parseCron :: Text -> Either Text CronSchedule` and
  `isDue :: CronSchedule -> UTCTime -> Bool` (a pure "does this instant match the cron?"). It has
  **no** "when is the next match?" function and **no** active driver.
- `shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs` — `runWorkerCmd` boots the worker. Note it
  builds the `kioku` `AppEnv` with `noopTracer` (a tracer that drops spans).

A "cron expression" is the five-field string `"min hour day-of-month month day-of-week"`, e.g.
`"*/5 * * * *"` = "every five minutes". `"* * * * *"` = "every minute".

### What keiro gives us (the substrate we wire onto)

`shinzui/keiro` (working tree `/Users/shinzui/Keikaku/bokuno/keiro`) is the event-sourcing
framework and workflow engine. It is already a transitive dependency of shikigami (pinned in
`cabal.project` at tag `f1d67a01…`, subdirs `keiro keiro-core keiro-migrations keiro-pgmq`).
Two of its modules matter here.

**Durable timers — `Keiro.Timer`** (`keiro/src/Keiro/Timer.hs`). A "durable timer" is a row in
the `keiro_timers` table with a `fire_at` time and an opaque JSON `payload`. The key pieces:

- `data TimerRequest = TimerRequest { timerId :: TimerId, processManagerName :: Text,
  correlationId :: Text, fireAt :: UTCTime, payload :: Value }`. The `timerId` is caller-chosen;
  re-scheduling the same id is idempotent.
- `scheduleTimerOnceTx :: TimerRequest -> Tx.Transaction ()` — arm a timer inside a transaction,
  *only if* the id is not already present (the "once" variant — the first `fire_at` wins).
- `runTimerWorker :: (IOE :> es, Store :> es) => Maybe KeiroMetrics -> UTCTime ->
  (TimerRow -> Eff es (Maybe EventId)) -> Eff es (Maybe TimerRow)` — claim at most one due
  timer at `now` and hand it to a caller-supplied `fire` action. The action returns
  `Just eventId` to mark the timer fired, or `Nothing` to leave it claimable later. Firing is
  **at-least-once** (a crash after the action but before `markTimerFired` re-fires), so fire
  actions must be idempotent. `runTimerWorkerWith` takes explicit `TimerWorkerOptions`
  (attempt ceiling, stale-claim requeue TTL).
- `claimDueTimer` / `markTimerFired` / `requeueStuckTimers` are the lower-level pieces
  `runTimerWorker` orchestrates; a caller normally only needs `runTimerWorker` in a loop.

**Durable workflows — `Keiro.Workflow`** (`keiro/src/Keiro/Workflow.hs`). A "workflow" is an
ordinary `effectful` computation run with `runWorkflow`, where each `step name action` is
**journaled**: the first run executes `action` and records its result to a kiroku stream named
`wf:<name>-<id>`; a later run (after a crash) returns the recorded result *without re-running
the side effect*. This is exactly mid-run resume. The key pieces:

- The `Workflow` effect with `step :: (ToJSON a, FromJSON a) => StepName -> Eff es a -> Eff es a`
  (journaled work), `awaitStep` (suspend until an external wake source resolves the step),
  `currentWorkflow`, `freshOrdinal`.
- `runWorkflow :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId ->
  Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)` and the options-taking
  `runWorkflowWith :: WorkflowRunOptions -> …`. `WorkflowOutcome` is
  `Completed a | Suspended | Cancelled | Failed | ContinuedAsNew`.
- `WorkflowRunOptions { snapshotPolicy, pageSize, metrics, tracer :: Maybe Tracer, activePatches }`
  — note it already accepts an OTel `Tracer`, so a workflow run can open its own span.
- `findUnfinishedWorkflowIds :: WorkflowName -> Eff es [WorkflowId]` — discovery for a resume
  worker: which workflows of a given name are not yet terminal.
- **Step side effects are at-least-once at the step boundary** (crash after the action runs but
  before the journal commit re-runs the action on resume), so step bodies that touch external
  systems must be idempotent — derive an idempotency key from the workflow identity + step name.

**Durable sleep / the shared timer worker — `Keiro.Workflow.Sleep`**
(`keiro/src/Keiro/Workflow/Sleep.hs`). This module shows the exact pattern Milestone A reuses for
scheduling: a timer row carries a JSON payload with a `"kind"` discriminator
(`workflowSleepKind = "keiro.workflow.sleep"`); `runWorkflowTimerWorker` is a timer-worker pass
that routes workflow-sleep timers to `workflowSleepFireAction` and delegates any other timer to a
caller-supplied fallback fire action. We add a `"shikigami.schedule"` discriminator and route it
the same way, so **one timer worker** drains both plan 7's workflow sleeps and our schedule
timers.

### What OTel infra already exists (the tracing we wire onto)

- `Shibuya.Telemetry.Effect` (`shibuya-project/shibuya/shibuya-core/src/Shibuya/Telemetry/Effect.hs`)
  defines the `Tracing` effect with `runTracing :: Tracer -> Eff (Tracing : es) a -> Eff es a`,
  `runTracingNoop` (the zero-overhead no-op the worker uses today), and span operations
  `withSpan`, `withSpan' :: Text -> SpanArguments -> (Span -> Eff es a) -> Eff es a`,
  `addAttribute`, `setStatus`, `recordException`, plus re-exports of `OpenTelemetry`'s `Span`,
  `SpanArguments`, `SpanKind (..)`, `defaultSpanArguments`, `toAttribute`.
- `Baikai.Trace.Sink.OpenTelemetry` (`baikai/baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs`)
  exposes `otelSink :: Otel.Tracer -> TraceSink` (and `otelSinkWith`), which emits one OTel span
  per model call carrying GenAI attributes (`gen_ai.operation.name`, `gen_ai.request.model`,
  `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `baikai.cost.usd`,
  `baikai.latency_ms`). `baikai` already routes model calls through a `TraceSink` (`Baikai.Trace`).
- `Shikumi.Trace.OpenTelemetry.exportTree :: Tracer -> TraceTree -> m ()`
  (`shikumi/shikumi-trace-otel/src/Shikumi/Trace/OpenTelemetry.hs`) exports a recorded shikumi
  `TraceTree` (a typed-program execution tree) as nested spans, GenAI attributes included. The
  `ShikumiProgram` behavior arm can export its tree this way.
- A real `Tracer` is built the standard hs-opentelemetry way (mirroring
  `kioku`'s `noopTracer` and shikumi-trace-otel's `exportTreeWith`):
  `OTel.createTracerProvider [processor] OTel.emptyTracerProviderOptions` then
  `OTel.makeTracer provider lib OTel.tracerOptions`. For production, the OTLP exporter
  (`hs-opentelemetry-exporter-otlp`) is wired through `OTEL_EXPORTER_OTLP_ENDPOINT`; for a
  local demo, a stdout/debug span processor suffices.

### Build, run, and test tooling

The dev environment is a nix devShell (`flake.nix`) that exports the `PG*` variables; a
repo-local Postgres is started with process-compose. The relevant commands (all from the repo
root `/Users/shinzui/Keikaku/bokuno/shikigami`):

- `process-compose up` — start the repo-local Postgres (`process-compose.yaml`) and run
  `just create-database` (which calls `just migrate` to install the kiroku event-store schema,
  keiro's `keiro_timers`/`keiro_workflows` schema, and shikigami's read-model migrations).
- `just migrate` — apply migrations idempotently (codd skips already-applied ones).
- `cabal build all` — build every package.
- `cabal test all` — run the test suites (e.g. `shikigami-core-test`, see
  `shikigami-core/shikigami-core.cabal` line 90).
- `cabal run shikigami -- <subcommand> …` — run the CLI (the `worker` subcommand exists today;
  Milestone A adds a `scheduler` subcommand).


## Plan of Work

The work is three milestones, each independently verifiable. Milestones A (scheduler) and C
(tracing) have no dependency on plan 7 and may land first and in either order. Milestone B
(mid-run resume) requires plan 7's keystone (`docs/plans/7-agent-runs-as-durable-keiro-workflows.md`)
to have re-platformed the run onto a keiro workflow; if plan 7 has not landed, do A and C, then
return to B.

### Milestone A — Timer-driven schedule firing

Scope: make a `Schedule`-triggered agent fire on its cron schedule, using keiro durable timers
that enqueue ordinary run jobs. At the end, a deployed `scheduler` process arms a timer per
scheduled agent and a timer-worker loop fires each due timer by enqueuing a run job and arming
the next occurrence; the existing worker drains those jobs unchanged. Acceptance: a
`"* * * * *"` agent yields a fresh `kioku_sessions` row within roughly one minute of boot.

Edits, in order:

1. **`shikigami-core/src/Shikigami/Trigger/Schedule.hs`** — add
   `nextDue :: CronSchedule -> UTCTime -> Maybe UTCTime`. Prefer the `cron` package's `nextMatch`
   if it is exported by the pinned version; otherwise implement by iterating `scheduleMatches`
   from `now` truncated to the next whole minute, stepping 60 seconds at a time up to a 366-day
   bound, returning the first instant that matches (`Nothing` if none within the bound — a
   schedule that can never fire, e.g. an impossible day/month). Truncate seconds so the returned
   instant lands on a minute boundary (cron resolution is one minute). Export `nextDue`.

2. **`shikigami-api/src/Shikigami/Api/RunJob.hs`** — extend the `TriggerKind` sum with a third
   constructor `TriggeredBySchedule`, alongside `TriggeredByStream` and `TriggeredByEvent`. Keep
   its JSON encoding consistent with the existing two (a string tag). This lets the worker and
   any tracing distinguish schedule-fired runs.
   Coherence note (cross-plan review): plan 9 (`docs/plans/9-multi-agent-delegation-primitive.md`)
   *also* extends this same `TriggerKind` sum (adding `TriggeredByDelegation`) and adds optional
   `parentSessionId`/`parentRunWorkflowId`/`delegationDepth` fields to `RunJob`. Both edits are
   additive (the sum derives `ToJSON`/`FromJSON` generically), so whichever lands second simply adds
   its constructor/fields — there is no conflict, but expect to see the other plan's additions
   already present in the file.

3. **New `shikigami-core/src/Shikigami/Trigger/Scheduler.hs`** — `Shikigami.Trigger.Scheduler`,
   modeled on `Keiro.Workflow.Sleep`. It contains:
   - `scheduleTimerKind :: Text` = `"shikigami.schedule"` — the payload discriminator.
   - `scheduleTimerPayload :: Text -> UTCTime -> Value` — build the JSON payload carrying the
     agent name and the due instant: `{ "kind": "shikigami.schedule", "agent": <name>,
     "dueAt": <iso8601> }`.
   - `parseSchedulePayload :: Value -> Maybe (Text, UTCTime)` — recognize and extract
     `(agentName, dueAt)`; `Nothing` for any non-schedule timer.
   - `scheduleTimerId :: Text -> UTCTime -> TimerId` — a deterministic v5 UUID over
     `("shikigami" : "schedule" : agentName : iso8601 dueAt)`, so arming the same agent for the
     same due minute twice collapses to one row (idempotent re-arm), exactly mirroring
     `Keiro.Workflow.Sleep.sleepTimerId`.
   - `armNextRun :: (Store :> es, IOE :> es) => CronSchedule -> Text -> UTCTime -> Eff es ()` —
     compute `nextDue cron now`; when `Just due`, `runTransaction (scheduleTimerOnceTx
     (TimerRequest { timerId = scheduleTimerId name due, processManagerName = "shikigami.scheduler",
     correlationId = name, fireAt = due, payload = scheduleTimerPayload name due }))`. When
     `Nothing`, do nothing (the schedule never fires).
   - `scheduleFireAction :: (Store :> es, IOE :> es) => SchedulerEnv -> TimerRow ->
     Eff es (Maybe EventId)` — for a `TimerRow` whose payload `parseSchedulePayload` recognizes:
     (a) **enqueue** an ordinary run job for the agent onto `shikigami_run_jobs`
     (via a `Scheduler`-flavored producer, see step 4), (b) **re-arm** the next occurrence with
     `armNextRun`, and (c) return `Just eventId` so the worker marks the timer fired. For a
     payload it does not recognize, return `Nothing` so a mixed worker can delegate it (this is
     how the same worker also drains plan 7's workflow sleeps). The enqueue must be idempotent:
     derive the run job's `idempotencyKey` from `agentName <> ":sched:" <> iso8601 dueAt`, so an
     at-least-once timer re-fire does not double-run the agent.
   - `runSchedulerTimerWorker :: … -> Eff es (Maybe TimerRow)` — one timer-worker pass routing
     schedule timers to `scheduleFireAction` and delegating other timers to a supplied fallback
     (default `\_ -> pure Nothing`). This composes with `Keiro.Workflow.Sleep.workflowSleepFireAction`
     so a single process drains schedule timers *and* workflow sleeps.

   Coherence note (cross-plan review — unify on one timer-worker entrypoint): the worker process must
   run exactly **one** timer worker, not two competing ones. Plan 7 Milestone 4 runs keiro's
   `runWorkflowTimerWorker` with a shikigami fallback that handles `awaitApproval` deadline timers
   (kind `shikigami.approval-timeout`, fired by signalling the awakeable with `TimedOut`). This plan's
   schedule timers (kind `shikigami.schedule`) must be routed by **that same** fallback, not by a
   second worker loop. Concretely: define one `shikigamiTimerFallback :: TimerRow -> Eff es (Maybe EventId)`
   that dispatches by the payload's `"kind"` discriminator — `shikigami.schedule` → `scheduleFireAction`,
   `shikigami.approval-timeout` → plan 7's approval fire action, anything else → `Nothing` — and run a
   single `runWorkflowTimerWorker mMetrics now shikigamiTimerFallback` (keiro already routes its own
   `keiro.workflow.sleep` timers internally). `runSchedulerTimerWorker` here is therefore the *schedule
   branch of that one fallback*, not an independent worker. See plan 7's Decision Log for the shared
   ownership of this entrypoint.

4. **`shikigami-core/src/Shikigami/Trigger/Enqueue.hs`** — add
   `enqueueScheduledRun :: Pool -> Text -> UTCTime -> IO (Either UsageError MessageId)` that
   builds a `RunJob { agentName, triggerKind = TriggeredBySchedule, occurredAt = dueAt,
   triggerPayload = <the schedule payload as Value>, idempotencyKey = agent <> ":sched:" <>
   iso8601 dueAt }` and sends it on `runQueueName`, mirroring the existing `enqueueAddressedRun`.
   `scheduleFireAction` calls this. (The producer returns to IO over a hasql `Pool`; the timer
   worker runs in the keiro `Store`/`Eff` row, so the fire action lifts the IO enqueue with
   `liftIO`, reusing the same pool the timer worker is built on.)

5. **`shikigami-cli/src/Shikigami/Cli/Commands/Scheduler.hs`** (new) and its wiring in the CLI
   command parser — a `scheduler --agents <dir>` subcommand that: loads the agent declarations
   (reusing `Shikigami.Agent.Loader.loadAgent` as the existing `worker` command does), filters to
   those with a `Schedule` trigger, **arms each once at boot** with `armNextRun cron name now`,
   then loops `runSchedulerTimerWorker` forever (sleeping ~1s between empty passes). The loop is
   the only long-lived process needed; the existing `worker` continues to drain the run jobs the
   timers enqueue.

Note on the loop's own liveness: the scheduler process can crash and restart freely. On restart
it re-arms each scheduled agent (idempotent — `scheduleTimerOnceTx` + deterministic id make a
re-arm a no-op if the row exists), and the timer worker recovers any timer left `Firing` by the
crash via keiro's stale-claim requeue. No leader election is required for a single scheduler
process; running two is safe because `claimDueTimer` uses `FOR UPDATE SKIP LOCKED` and the
enqueue is idempotency-keyed.

### Milestone B — Mid-run resume on the keiro workflow substrate

Scope: a run that crashes between steps resumes from the journal instead of re-running. This
**depends on plan 7** (`docs/plans/7-agent-runs-as-durable-keiro-workflows.md`, "Agent runs as
durable keiro workflows"), which re-platforms the behavior runner onto a keiro `Workflow`. At
the end, `Shikigami.Agent.Run.runAgentWithMemory`'s five phases are journaled keiro `step`s, and
a worker that boots after a crash finds the unfinished run workflow and continues it. Acceptance:
killing the worker between the `record-memory` and `complete-session` steps, then restarting,
yields exactly one memory row and a `Completed` session — no re-run of completed steps.

If plan 7 has **not** landed when this milestone is reached, stop and record that in Progress and
the Decision Log; do not re-implement the workflow substrate here. Milestones A and C stand alone.

Milestone B **consumes plan 7's workflow; it does not define its own.** Plan 7 already re-platforms
`runAgentWithMemory` onto the keiro workflow `agentRunWorkflow`, run under the constant
`agentRunWorkflowName = WorkflowName "shikigami.agent-run"` with `WorkflowId = RunJob.idempotencyKey`,
journaling the named steps `ingest-job, lookup-agent, open-session, recall, run-behavior,
dispatch-sinks, record, complete`; and it ships `runWorkflowResumeWorker` registered via
`agentRunRegistry`. **This plan must not re-define the workflow name, the step set, or the
sink-dispatch boundary** — those are plan 7's, and an earlier draft of this plan diverged from them
(a 5-step `WorkflowName "agent-run"` with sinks dispatched outside the workflow); that divergence is
removed here. Use plan 7's names verbatim so the journal stream and the resume worker line up.

Milestone B's contribution is therefore narrow — the **resume acceptance test**, not the substrate:

1. **Confirm plan 7's artifacts exist** (`agentRunWorkflow`, `agentRunWorkflowName`,
   `agentRunRegistry`, `runWorkflowResumeWorker`). If plan 7 has not landed, **block Milestone B**
   (do A and C first, which do not depend on plan 7) and note it in the Decision Log.
2. **Ensure the worker boots plan 7's resume worker.** If plan 7's `runWorker` already launches
   `runWorkflowResumeWorker (agentRunRegistry deps)` (it does, per plan 7 M2), Milestone B adds
   nothing here; otherwise register the `agentRunWorkflowName` body with it. Do **not** write a
   bespoke `findUnfinishedWorkflowIds` sweep that duplicates plan 7's resume worker.
3. **Write the crash-resume test** (in `shikigami-core-test`): drive `agentRunWorkflow` to between two
   steps, discard in-process state, re-invoke `runWorkflow agentRunWorkflowName …`, and assert the
   completed steps are not re-run (e.g. the journaled `run-behavior` result is reused, no duplicate
   `kioku` memory). This is the observable behavior Milestone B delivers.

Sink dispatch (audit item **C3**, resolved as Option 3 — see plan 7's Decision Log): plan 7's
`dispatch-sinks` step **enqueues** sink intents into the keiro transactional outbox
(`kiroku.keiro_outbox`) in the journal transaction, and a separate **outbox-publisher** worker
(`Keiro.Outbox.publishClaimedOutbox`) delivers them at-least-once and idempotently. This plan therefore
(a) does not assert the old "dispatch sinks as today (outside the workflow)" model, and (b) its
Milestone B resume test asserts on the *outbox row* (exactly one per sink, by deterministic
`message_id`) rather than on a synchronous POST, and Milestone C's tracing wraps the **enqueue** in the
`sink.dispatch` span while the publisher emits its own delivery spans (see Milestone C).

### Milestone C — Real OTel tracing through the run

Scope: drop `runTracingNoop` and emit a real span tree for each run. At the end, a run is a
parent `agent.run` span with `trigger`, `behavior`, and per-sink `sink.dispatch` child spans, and
the behavior's model calls carry GenAI attributes. Acceptance: with a collector configured (or
the debug span processor), one run produces the expected span tree.

Edits, in order:

1. **New `shikigami-core/src/Shikigami/Telemetry.hs`** — `Shikigami.Telemetry` with
   `withRunTracer :: (Tracer -> IO a) -> IO a`: read `OTEL_EXPORTER_OTLP_ENDPOINT`; when set,
   build a real `TracerProvider` with the OTLP exporter/batch processor
   (`OTel.createTracerProvider [batchProcessor] opts`, `OTel.makeTracer provider
   (InstrumentationLibrary "shikigami" …) tracerOptions`) and shut it down on exit; when unset,
   fall back to the same minimal no-op provider `kioku`'s `noopTracer` builds (so unconfigured
   runs stay zero-overhead). This mirrors shikumi-trace-otel's `exportTreeWith`/`exportTreeLive`
   provider lifecycle.
2. **`shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs`** — wrap the worker boot in
   `withRunTracer`, pass the real `Tracer` into the `kioku` `AppEnv` (replacing `noopTracer`),
   and thread it into `WorkerEnv` so the worker runs under `runTracing tracer`.
3. **`shikigami-core/src/Shikigami/Worker.hs`** — replace `runTracingNoop` (line 61) with
   `runTracing tracer` (taking the tracer from `WorkerEnv`). In `runOneAgent`, open the parent
   span with `withSpan' "agent.run" defaultSpanArguments { kind = Internal } $ \runSpan -> …` and
   attach run-level attributes (`shikigami.agent`, `shikigami.run_id`, `shikigami.trigger.kind`
   from `triggerKind job`). Open child spans: `withSpan' "trigger" …` (kind `Consumer` for
   stream/event, `Internal`/`Producer` for schedule), `withSpan' "behavior" …` around
   `runBehavior` with `kind = Internal`, and `withSpan' "sink.dispatch" …` per sink with the
   sink kind as an attribute (`shikigami.sink.kind`). Set span status from the outcome
   (`setStatus runSpan Ok`/`Error` and `recordException` on failure). Note (C3 = Option 3): the
   `sink.dispatch` span now covers the *outbox enqueue* inside the run (kind `Producer`); the actual
   HTTP delivery happens in the separate outbox-publisher worker (plan 7), which opens its own
   `sink.deliver` spans with `shikigami.sink.kind` + the outbox `message_id`, linked to the run by
   that id rather than nested under `agent.run`.
4. **Behavior model-call spans (GenAI attributes).** Route the `Skill`/`ShikumiProgram` behavior
   arms' model calls through baikai's `otelSink`: pass the run's `Tracer` into
   `Shikigami.Behavior.Run` so the `Skill` arm's baikai request runs `withTrace (otelSink tracer)`,
   producing a child model-call span under `behavior` with `gen_ai.request.model`,
   `gen_ai.usage.input_tokens`, etc. For the `ShikumiProgram` arm, optionally call
   `Shikumi.Trace.OpenTelemetry.exportTree tracer tree` after the program runs to attach the
   program's nested spans. The context propagation is automatic: `withSpan'` installs the parent
   in thread-local context, and the OTel sink's `createSpan` discovers it.


## Concrete Steps

All commands run from the repo root `/Users/shinzui/Keikaku/bokuno/shikigami` inside the nix
devShell (so `PG*` env vars are set). Bring up Postgres and the schema once:

```bash
process-compose up    # starts repo-local Postgres + runs `just create-database` (installs
                      # kiroku, keiro_timers/keiro_workflows, and shikigami migrations)
```

If you prefer not to use process-compose, start Postgres your usual way and run:

```bash
just create-database  # idempotent: creates the db if absent, then `just migrate`
```

Build everything to establish a green baseline before editing:

```bash
cabal build all
```

Expected (abbreviated):

```text
Up to date
```

(or a normal compile of the four packages on a clean tree).

### Milestone A steps

After editing per the Plan of Work, build and run the new unit tests:

```bash
cabal build all
cabal test shikigami-core-test
```

Expected: the suite passes, including the new cases for `nextDue`, `scheduleTimerPayload`
round-trip, `scheduleTimerId` determinism, and `scheduleFireAction` (enqueues a run job + arms
the next timer). A focused run with the tasty pattern:

```bash
cabal test shikigami-core-test --test-options='-p Scheduler'
```

Expected (abbreviated):

```text
Scheduler
  nextDue: next minute for "* * * * *":            OK
  payload round-trips:                             OK
  timer id is deterministic:                       OK
  fire action enqueues a run job and re-arms:      OK
All N tests passed
```

End-to-end manual proof. Put a minimal scheduled agent in a directory, e.g.
`fixtures/agents/tick.dhall`, with a `Schedule` trigger of `"* * * * *"`, a `Deterministic`
behavior, and one cheap sink. In one terminal run the scheduler; in another run the worker:

```bash
# terminal 1 — arm timers and drive the clock
cabal run shikigami -- scheduler --agents fixtures/agents

# terminal 2 — drain the run jobs the timers enqueue
PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
  cabal run shikigami -- worker --agents fixtures/agents \
  --kawa-url http://localhost:9 --kizashi-url http://localhost:9
```

Within ~70 seconds, observe a fresh session for the agent:

```bash
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "select session_id, agent_id, status from kioku_sessions where agent_id='tick' order by started_at desc limit 3;"
```

Expected: at least one row for `agent_id = tick` per elapsed minute, and a `keiro_timers` row
re-armed for the next minute:

```bash
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "select fire_at, status, payload->>'agent' as agent from keiro_timers where payload->>'kind'='shikigami.schedule';"
```

### Milestone B steps

This milestone requires plan 7. First confirm it has landed:

```bash
sed -n '1,40p' docs/plans/7-agent-runs-as-durable-keiro-workflows.md   # check Progress/Outcomes
grep -rn "runAgentWorkflow\|WorkflowName \"agent-run\"\|Keiro.Workflow" shikigami-core/src
```

If plan 7 is not done, record the block in Progress and skip to Milestone C.

After re-platforming the run onto a workflow, build and run a resume test. The test (a new case
in `shikigami-core-test`, or a small `cabal run` harness) must: start a run, simulate a crash by
killing the process (or by throwing inside the `complete-session` step the *first* time), restart,
and assert the journal replayed. Inspect the workflow journal:

```bash
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "select stream_name from kiroku_events where stream_name like 'wf:shikigami.agent-run-%' group by stream_name limit 5;"
```

After the crash-and-restart, assert exactly one memory row and a completed session:

```bash
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "select count(*) from kioku_memories where session_id = :'sid';"   -- expect 1, not 2
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "select status from kioku_sessions where session_id = :'sid';"      -- expect 'Completed'
```

Expected: the run finishes, the `run-behavior` and `record-memory` steps are present in the
journal exactly once, and the restart only runs the not-yet-journaled steps (verifiable by a log
line per executed step versus replayed step, since `runWorkflow` records
`keiro.workflow.steps.replayed` vs `…executed`).

### Milestone C steps

Build, then run a single agent with tracing pointed at a local collector. The easiest local
collector is the OpenTelemetry Collector's debug exporter, or Jaeger all-in-one on
`localhost:4317` (OTLP/gRPC). With one running:

```bash
cabal build all
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
  cabal run shikigami -- worker --agents fixtures/agents \
  --kawa-url http://localhost:9 --kizashi-url http://localhost:9
```

Enqueue one run (e.g. via the addressed-run path or by letting the scheduler fire one), then open
the collector UI. Expected span tree for the run:

```text
agent.run            (shikigami.agent=tick, shikigami.run_id=…, shikigami.trigger.kind=schedule)
├─ trigger
├─ behavior
│  └─ chat           (gen_ai.request.model=…, gen_ai.usage.input_tokens=…)   # only for Skill/Program arms
└─ sink.dispatch     (shikigami.sink.kind=kawa)
```

With `OTEL_EXPORTER_OTLP_ENDPOINT` unset, the same command runs with the no-op tracer and emits
nothing (regression check that tracing is strictly opt-in and zero-overhead by default):

```bash
unset OTEL_EXPORTER_OTLP_ENDPOINT
PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
  cabal run shikigami -- worker --agents fixtures/agents \
  --kawa-url http://localhost:9 --kizashi-url http://localhost:9
# no spans exported; behavior identical to today
```


## Validation and Acceptance

Acceptance is phrased as observable behavior; each milestone is independently checkable.

**Milestone A (scheduler).** Start the `scheduler` and `worker` against an agent whose trigger is
`Schedule "* * * * *"`. Acceptance: within ~70 seconds a new `kioku_sessions` row appears for that
agent (the run happened on its own — no manual enqueue), and a `keiro_timers` row with
`payload->>'kind' = 'shikigami.schedule'` is re-armed with a `fire_at` in the next minute.
Negative check: stop the scheduler; no further sessions appear (firing stops when the driver
stops). Idempotence check: restart the scheduler twice in quick succession; no duplicate timer
rows (deterministic `scheduleTimerId` + `scheduleTimerOnceTx`), and at most one run per minute
(idempotency-keyed enqueue). Unit acceptance: `cabal test shikigami-core-test` passes the new
Scheduler cases.

**Milestone B (mid-run resume).** Drive one run and kill the worker between the `record-memory`
and `complete-session` steps. Restart the worker. Acceptance: the session ends `Completed`, there
is exactly **one** memory row for the run (the `record-memory` step was replayed from the journal,
not re-executed), and the workflow journal `wf:shikigami.agent-run-<runId>` contains each step once. This
fails before the change (a crash leaves a `Started` session and the next attempt re-runs from the
top, producing a duplicate memory) and passes after. Demonstrate beyond compilation by showing
the keiro `keiro.workflow.steps.replayed` count rising on the resumed run while
`…steps.executed` stays flat for the already-journaled steps.

**Milestone C (tracing).** Run one agent with `OTEL_EXPORTER_OTLP_ENDPOINT` set. Acceptance: the
collector shows an `agent.run` parent span with `trigger`, `behavior`, and `sink.dispatch`
children, and (for `Skill`/`ShikumiProgram` behaviors) a model-call child span carrying GenAI
attributes (`gen_ai.request.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`).
A failed run shows the `agent.run` span with an error status and a recorded exception. With the
env var unset, no spans are exported and run behavior is byte-for-byte unchanged.


## Idempotence and Recovery

Every step in this plan is safe to repeat.

- **Schema/migrations** (`just migrate`) are idempotent: codd records applied migrations and
  skips them; re-running installs nothing new. `keiro_timers` and `keiro_workflows` come from
  keiro's own migrations, already installed by `just create-database`.
- **Arming schedule timers** is idempotent: `scheduleTimerId` is a deterministic v5 UUID over
  `(agent, dueMinute)` and `scheduleTimerOnceTx` only inserts when the id is absent, so a
  scheduler restart that re-arms every agent is a no-op against existing rows.
- **Timer firing is at-least-once** (keiro contract): a crash after the fire action but before
  `markTimerFired` re-fires the timer. The fire action is made idempotent by (a) an
  idempotency-keyed run-job enqueue (`agent:sched:<dueAt>`), so a double-fire does not double-run
  the agent, and (b) `scheduleTimerOnceTx` re-arming, so a double-fire does not create two next
  timers. Stale `Firing` rows are auto-requeued by `runTimerWorker` (default
  `requeueStuckAfter = 300s`).
- **Workflow steps are at-least-once** (keiro contract): a crash after a step's side effect but
  before its journal commit re-runs that one step on resume. The resume behavior is correct only
  because every externally-visible step (session start, memory record, session complete) uses a
  **deterministic kioku id derived from the workflow identity**, so a re-execution converges
  rather than duplicates. This is the single most important invariant for Milestone B; verify it
  with the "exactly one memory row" acceptance check.
- **Tracing** is fully opt-in: with `OTEL_EXPORTER_OTLP_ENDPOINT` unset the runtime uses the
  no-op tracer and changes nothing, so enabling/disabling tracing is a safe, reversible toggle.
- **Rollback.** Milestones A and C are additive (a new subcommand, a new module, a swapped
  tracer behind an env gate) and can be reverted by reverting their commits with no data
  migration. Milestone B changes how a run executes; to roll it back, revert to the
  straight-through `runAgentWithMemory` — existing `kioku` sessions are unaffected because the
  workflow journal lives in separate `wf:shikigami.agent-run-*` streams.


## Interfaces and Dependencies

Libraries and services used, with the exact module paths and signatures that must exist at the
end of each milestone.

**Existing, reused (do not modify their APIs):**

- `Keiro.Timer` (`keiro/src/Keiro/Timer.hs`): `TimerRequest(..)`, `TimerId(..)`, `TimerRow`,
  `scheduleTimerOnceTx :: TimerRequest -> Tx.Transaction ()`,
  `runTimerWorker :: Maybe KeiroMetrics -> UTCTime -> (TimerRow -> Eff es (Maybe EventId)) -> Eff es (Maybe TimerRow)`.
- `Keiro.Workflow` (`keiro/src/Keiro/Workflow.hs`): `Workflow`, `step`, `awaitStep`,
  `StepName(..)`, `WorkflowName(..)`, `WorkflowId(..)`, `WorkflowOutcome(..)`,
  `runWorkflow :: WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)`,
  `runWorkflowWith :: WorkflowRunOptions -> …`, `WorkflowRunOptions { …, tracer :: Maybe Tracer }`,
  `findUnfinishedWorkflowIds :: WorkflowName -> Eff es [WorkflowId]`.
- `Keiro.Workflow.Sleep` (`keiro/src/Keiro/Workflow/Sleep.hs`): the pattern template
  (`workflowSleepKind`, `sleepTimerId`, `workflowSleepFireAction`, `runWorkflowTimerWorker`).
- `Shibuya.Telemetry.Effect` (`shibuya-project/shibuya/shibuya-core/src/Shibuya/Telemetry/Effect.hs`):
  `Tracing`, `runTracing :: Tracer -> Eff (Tracing : es) a -> Eff es a`, `runTracingNoop`,
  `withSpan'`, `addAttribute`, `setStatus`, `recordException`, `SpanKind(..)`,
  `defaultSpanArguments`.
- `Baikai.Trace.Sink.OpenTelemetry` (`baikai/baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs`):
  `otelSink :: Otel.Tracer -> TraceSink`.
- `Shikumi.Trace.OpenTelemetry` (`shikumi/shikumi-trace-otel/src/Shikumi/Trace/OpenTelemetry.hs`):
  `exportTree :: (MonadIO m) => Otel.Tracer -> TraceTree -> m ()`.
- `Kioku.App` (`kioku/kioku-core/src/Kioku/App.hs`): `AppEnv(..)` with `tracer :: Tracer`,
  `noopTracer :: IO Tracer` (the no-op fallback pattern).

**New / modified in this plan:**

- `Shikigami.Trigger.Schedule` (`shikigami-core/src/Shikigami/Trigger/Schedule.hs`): add
  `nextDue :: CronSchedule -> UTCTime -> Maybe UTCTime`.
- `Shikigami.Api.RunJob` (`shikigami-api/src/Shikigami/Api/RunJob.hs`): add constructor
  `TriggeredBySchedule` to `TriggerKind`.
- `Shikigami.Trigger.Enqueue` (`shikigami-core/src/Shikigami/Trigger/Enqueue.hs`): add
  `enqueueScheduledRun :: Pool -> Text -> UTCTime -> IO (Either UsageError MessageId)`.
- `Shikigami.Trigger.Scheduler` (new, `shikigami-core/src/Shikigami/Trigger/Scheduler.hs`):
  `scheduleTimerKind :: Text`, `scheduleTimerPayload :: Text -> UTCTime -> Value`,
  `parseSchedulePayload :: Value -> Maybe (Text, UTCTime)`,
  `scheduleTimerId :: Text -> UTCTime -> TimerId`,
  `armNextRun :: (Store :> es, IOE :> es) => CronSchedule -> Text -> UTCTime -> Eff es ()`,
  `scheduleFireAction :: (Store :> es, IOE :> es) => SchedulerEnv -> TimerRow -> Eff es (Maybe EventId)`,
  `runSchedulerTimerWorker :: (Store :> es, IOE :> es) => SchedulerEnv -> UTCTime -> (TimerRow -> Eff es (Maybe EventId)) -> Eff es (Maybe TimerRow)`.
- `Shikigami.Cli.Commands.Scheduler` (new, `shikigami-cli/src/Shikigami/Cli/Commands/Scheduler.hs`):
  `runSchedulerCmd :: FilePath -> IO ()` plus its registration in the CLI command parser.
- `Shikigami.Agent.Run` (`shikigami-core/src/Shikigami/Agent/Run.hs`): `runAgentWithMemory`
  re-expressed as a `Workflow` body with named `step`s (Milestone B). Its public type may change
  to run in the `Workflow`/`Store` effect row or to return a `WorkflowOutcome`; the worker is
  updated in lockstep.
- `Shikigami.Worker` (`shikigami-core/src/Shikigami/Worker.hs`): `runWorker` runs under
  `runTracing tracer` (Milestone C); `runOneAgent` opens the `agent.run`/`trigger`/`behavior`/
  `sink.dispatch` spans and (Milestone B) invokes the run via `runWorkflow` and branches on the
  `WorkflowOutcome`; `WorkerEnv` gains a `workerTracer :: Tracer` field.
- `Shikigami.Telemetry` (new, `shikigami-core/src/Shikigami/Telemetry.hs`):
  `withRunTracer :: (Tracer -> IO a) -> IO a` (real tracer from `OTEL_EXPORTER_OTLP_ENDPOINT`,
  else noop).
- `Shikigami.Behavior.Run` (`shikigami-core/src/Shikigami/Behavior/Run.hs`): `BehaviorEnv` gains
  the `Tracer` (or accepts it per call) so the `Skill`/`ShikumiProgram` arms route model calls
  through baikai's `otelSink` (Milestone C).

**Services:** Postgres (the `keiro_timers`, `keiro_workflows`, `kiroku_events`, `kioku_*`, and
pgmq tables), and — for Milestone C only — an OTLP-compatible collector reachable at
`OTEL_EXPORTER_OTLP_ENDPOINT`.


---

Revision note: Initial authoring of the plan from the skeleton. The plan was grounded by reading
the live keiro APIs (`Keiro.Timer`, `Keiro.Workflow`, `Keiro.Workflow.Sleep`), the existing
shikigami run path (`Shikigami.Worker`, `Shikigami.Agent.Run`, `Shikigami.Trigger.Schedule`,
`Shikigami.Trigger.Enqueue`), the OTel infra (`Shibuya.Telemetry.Effect`, baikai-trace-otel,
shikumi-trace-otel), and the spec's Open Question 2 (`docs/initial-spec.md`). The scheduler-drive
decision (keiro timers over a timer loop or bare pgmq delay) and the plan-7 dependency for
mid-run resume are recorded in the Decision Log with rationale.


## Revision Notes

- 2026-06-27 — **Cross-plan coherence pass (plans 7–11).** Milestone B was re-pointed to consume plan
  7's `agentRunWorkflow`/`agentRunWorkflowName`/`agentRunRegistry`/`runWorkflowResumeWorker` rather than
  re-implement a divergent 5-step `WorkflowName "agent-run"`; its scope narrowed to the resume
  acceptance test. The validation SQL was corrected to `wf:shikigami.agent-run-%`. The timer worker was
  unified onto a single `runWorkflowTimerWorker` fallback (`shikigamiTimerFallback`, routed by payload
  `kind`) shared with plan 7's approval-timeout timers, replacing the implied second worker loop. A
  cross-note was added flagging that plan 9 also extends `TriggerKind`/`RunJob` additively. Reason: the
  audit found this plan had independently re-platformed the run and the timer subsystem, colliding with
  plan 7 (the keystone).
- 2026-06-27 (follow-up) — **C3 resolved as Option 3 (transactional outbox).** Plan 7's `dispatch-sinks`
  step enqueues sink intents into `kiroku.keiro_outbox` in the journal transaction, delivered by a
  separate outbox-publisher worker. Updated accordingly: Milestone B's resume test asserts on the outbox
  row (one per sink, deterministic `message_id`) rather than a synchronous POST, and Milestone C's
  `sink.dispatch` span now wraps the enqueue (kind `Producer`) with the publisher emitting separate
  `sink.deliver` spans. Reason: the team is preparing these projects for `kikan` production, where durable,
  decoupled, exactly-once-enqueued sink delivery is required.
