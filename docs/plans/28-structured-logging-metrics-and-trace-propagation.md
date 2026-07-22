---
id: 28
slug: structured-logging-metrics-and-trace-propagation
title: "Structured logging, metrics, and trace propagation"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tyx3yehmsq9eyywdcf5c7"
master_plan: "docs/masterplans/6-operations-and-observability-run-shikigami-as-a-real-service.md"
---

# Structured logging, metrics, and trace propagation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

An operator running shikigami today is nearly blind. Every log line in the runtime is a bare
`hPutStrLn stderr` with an ad-hoc bracket prefix (`[shikigami.worker] ...`, `[stream] ...`,
`[sink] ...`), impossible to filter or aggregate by field; the per-sink result logger is a
literal no-op (`logSinkResult _job _result = pure ()`,
`shikigami-core/src/Shikigami/Agent/Workflow.hs:629-630`). Every metrics hook the substrate
already exposes is filled with `Nothing`, so nothing counts runs, queue depth, outbox lag, or
consumer throughput. Tracing exists only inside the `worker` command; the scheduler and both
consumers run a no-op tracer, and the trace dies at the outbox: the `sink.dispatch` producer
span is never connected to the asynchronous HTTP publish that actually delivers the sink.

After this plan, every process emits one structured JSON object per log line (parse them with
`jq`), the standard `OTEL_EXPORTER_OTLP_ENDPOINT` variable turns on both traces and metrics
for every long-running command, keiro's outbox/timer/workflow instruments report real numbers,
shikigami-specific counters cover runs started/completed/failed, queue depth, and consumer
throughput, and a single distributed trace connects `agent.run` → `sink.dispatch` → the
outbound HTTP POST, across the outbox boundary, via a W3C `traceparent`. This plan also fixes
the observability *vocabulary* — metric names, log event names, attribute keys — that plans in
MasterPlans 2 through 5 will emit against.

The user-visible proof: run the worker with `OTEL_EXPORTER_OTLP_ENDPOINT` pointed at a local
collector, enqueue one run, and see (a) JSON log lines that `jq .event` can filter, (b) a
`shikigami.runs.completed` counter increment, and (c) one connected trace whose leaf span is
the HTTP POST to the sink endpoint.


## Progress

- [ ] M1: `Shikigami.Log` module written (JSON-lines logger, levels, event names, key-value
      fields); vocabulary documented in the module header.
- [ ] M1: every `hPutStrLn stderr` call site in `Shikigami.Worker`, `Shikigami.Sink`,
      `Shikigami.Trigger.Consumer`, and the CLI command modules replaced with `Shikigami.Log`.
- [ ] M1: `logSinkResult` (Workflow.hs:629) implemented: one structured line per sink result
      with agent, run id, sink kind, and outcome.
- [ ] M2 (spike): a `Meter` built from the hs-opentelemetry SDK exports a test counter via
      OTLP; promotion criteria met (or fallback recorded in the Decision Log).
- [ ] M2: `Shikigami.Telemetry.Metrics` written (`ShikigamiMetrics` record +
      `newShikigamiMetrics`); `Shikigami.Telemetry.withRunTelemetry` supersedes `withRunTracer`
      and also yields `Maybe KeiroMetrics` and `ShikigamiMetrics`.
- [ ] M2: `AppEnv.metrics` populated (`Just`) in all construction sites; `Nothing` arguments at
      `Worker.hs:108` and `Worker.hs:119` replaced; queue-depth and outbox-backlog samplers
      running in the worker; consumer throughput counters in `Trigger.Consumer`.
- [ ] M3: scheduler and both consumers run a real tracer (`withRunTelemetry`), not `noopTracer`.
- [ ] M3: `sinkIntentEvent` and the `Shikigami.Flow.SinkOutbox` builder populate
      `IntegrationEvent.traceContext`; test proves `keiro.keiro_outbox.traceparent` is non-null
      after `enqueueSinkIntents`.
- [ ] M3: `publishSinkIntent` opens a `sink.publish` span parented on the stored trace context,
      and the outbound HTTP POST carries a `traceparent` header through plan 22's
      `postJSONWithHeaders`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Build a minimal in-repo JSON-lines logger (`Shikigami.Log`) instead of adopting
  katip, co-log, or monad-logger.
  Rationale: the substrate was surveyed on 2026-07-08 (keiro, shibuya-core, kizashi-core,
  kioku, kawa — `.cabal` build-depends and source greps for katip/co-log/monad-logger/
  fast-logger/LogAction): none uses a logging framework. The ecosystem idiom is plain stderr
  lines plus OpenTelemetry spans for deep diagnostics (`Shibuya.Telemetry.Effect` is the shared
  tracing surface; `AppEnv.tracer` at
  `/Users/shinzui/Keikaku/bokuno/kioku/kioku-core/src/Kioku/App.hs:26`). Following the ecosystem
  means staying framework-free; what is missing is *structure*, not a framework. A ~100-line
  module over `aeson` (already a dependency) gives machine-parseable lines with zero new
  dependencies and no effect-system friction, and can be swapped later if the platform ever
  standardizes on a framework.
  Date: 2026-07-08

- Decision: Implement metrics through the OpenTelemetry `Meter` — `newKeiroMetrics` for the
  substrate instruments plus a sibling `ShikigamiMetrics` record for shikigami's own — rather
  than a Prometheus endpoint.
  Rationale: the hooks shikigami must fill are typed for this. `AppEnv.metrics ::
  Maybe KeiroMetrics` (`kioku-core/src/Kioku/App.hs:25-29`), and keiro's only constructor is
  `newKeiroMetrics :: MonadIO m => Meter -> m KeiroMetrics`
  (`/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Telemetry.hs:643`) over hs-opentelemetry
  instruments; there is no Prometheus-based builder in keiro. shibuya's Prometheus exposition
  (`shibuya-metrics`) reads shibuya's internal always-on `MetricsMap` and is not a hook
  shikigami can populate. One OTel pipeline, gated by the already-honored
  `OTEL_EXPORTER_OTLP_ENDPOINT`, carries traces and metrics through the same collector. M2
  starts with a spike because the hs-opentelemetry *metrics* export path is less traveled than
  its trace path; the fallback, if the SDK cannot export metrics, is a small periodic
  log-exposition loop over the same instruments, recorded here before promotion.
  Date: 2026-07-08

- Decision: Propagate trace context through the outbox as a W3C `traceparent` using keiro's
  existing `IntegrationEvent.traceContext` field, and give the asynchronous publish its own
  `sink.publish` span parented on it.
  Rationale: keiro already models this end to end — `traceContext :: Maybe TraceContext` on
  `IntegrationEvent` (`keiro-core/src/Keiro/Integration/Event.hs:107`), `TraceContext
  { traceparent :: Text, tracestate :: Maybe Text }` (`Event.hs:146-150`), persisted in the
  `keiro.keiro_outbox` columns `traceparent`/`tracestate` (keiro-migrations,
  `2026-05-19-12-55-02-keiro-outbox.sql:18-19`) and carried as Kafka headers. Shikigami just
  never fills it (`traceContext = Nothing`, `Shikigami/Agent/Workflow.hs:541`). Using the field
  the substrate already persists beats inventing a side channel.
  Date: 2026-07-08

- Decision: Milestone 3 consumes the authenticated `HttpEnv` and
  `postJSONWithHeaders` defined by
  `docs/plans/22-outbound-authentication-for-sink-clients.md`; it does not create a
  second header helper.
  Rationale: trace headers must compose with authorization headers and the shared
  timeout/manager policy. Extending the plan-22 seam preserves both while keeping
  bearer-token handling out of this observability plan.
  Date: 2026-07-22

- Decision: Keep the "no endpoint set → no-op providers" behavior of
  `Shikigami.Telemetry.withRunTracer` in its successor `withRunTelemetry`.
  Rationale: callers must not need separate traced and untraced code paths (the existing
  contract, `shikigami-core/src/Shikigami/Telemetry.hs:15-23`), and `newKeiroMetrics` is
  documented safe under a no-op meter (keiro `Telemetry.hs:636-641`), so `Just metrics` can be
  passed unconditionally.
  Date: 2026-07-08

- Decision: This plan owns the observability vocabulary: metric names are dot-namespaced under
  `shikigami.` (`shikigami.runs.started|completed|failed|retried|dead_lettered`,
  `shikigami.queue.depth`, `shikigami.consumer.records`), attribute keys reuse the span
  attribute names already in the code (`agent.name`, `trigger.kind`, `run.idempotency_key`,
  plus `sink.kind`, `outcome`, `topic`), and log events are `component.subject.verb`
  (`worker.job.dead_lettered`, `stream.record.matched`). Substrate instrument names inside
  `KeiroMetrics` are keiro's to define and are not renamed.
  Rationale: plans in MasterPlans 2-5 will emit logs and metrics; a single owner prevents
  vocabulary drift. Recorded as an Integration Point in the MasterPlan.
  Date: 2026-07-08


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a declared-agent runtime: one executable, `shikigami`, whose long-running
subcommands form the runtime. The `worker` command
(`shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs`) boots four concurrent loops
(`shikigami-core/src/Shikigami/Worker.hs:70`): a queue processor draining the
`shikigami_run_jobs` pgmq queue, a keiro workflow-resume worker, a keiro outbox publisher
(which delivers "sink intents" — queued outbound effects — over HTTP), and a keiro timer
worker. The `scheduler` command fires cron triggers; `consume-stream`/`consume-events`
(`shikigami-cli/src/Shikigami/Cli/Commands/ConsumeStream.hs`) consume Kafka topics and enqueue
run jobs. The shared environment type is kioku's `AppEnv`
(`/Users/shinzui/Keikaku/bokuno/kioku/kioku-core/src/Kioku/App.hs:25-29`):

```haskell
data AppEnv = AppEnv
  { store :: !KirokuStore,
    tracer :: !Tracer,
    metrics :: !(Maybe KeiroMetrics)
  }
```

Three terms of art. *keiro* is the durable-workflow engine over Postgres (source:
`/Users/shinzui/Keikaku/bokuno/keiro`); an agent run is a keiro workflow, and outbound sink
deliveries go through keiro's transactional *outbox* (a table, `keiro.keiro_outbox`, drained
by a publisher loop). *shibuya* is the supervised queue-processor library the worker's drain
loop runs on. *OTLP* is the OpenTelemetry wire protocol; `Shikigami.Telemetry.withRunTracer`
(`shikigami-core/src/Shikigami/Telemetry.hs:18-41`) builds an OTLP-exporting tracer iff
`OTEL_EXPORTER_OTLP_ENDPOINT` is set, else a no-op one.

The current state, verified per file:

Logging. Everything is `hPutStrLn stderr`: the worker loops (`Worker.hs:69,80,83,88,100,105,
110,116,121`), job handling (`Worker.hs:136,160,177,180,183,188`), the sink permission gate
(`shikigami-core/src/Shikigami/Sink.hs:45`), the stream/event consumers
(`shikigami-core/src/Shikigami/Trigger/Consumer.hs:86,113,150,157-160,184,190-194`), and the
CLI command modules (`putStrLn`/`hPutStrLn` in `Commands/Worker.hs:27`,
`Commands/Scheduler.hs:35,46,56`, `Commands/ConsumeStream.hs`). `logSinkResult` is a no-op
(`Workflow.hs:629-630`), so per-sink outcomes are recorded in the workflow journal but never
logged.

Metrics. `metrics = Nothing` at every `AppEnv` construction:
`shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs:32`, `Commands/Scheduler.hs:39`,
`Commands/ConsumeStream.hs:43` and `:73` (also `Commands/AgentRun.hs:40` and the test specs).
The keiro workers that accept `Maybe KeiroMetrics` get `Nothing` literally:
`publishClaimedOutbox (…) defaultPublishOptions Nothing` at `Worker.hs:108` and
`runWorkflowTimerWorker Nothing now (…)` at `Worker.hs:119`. (The scheduler's own timer loop
already threads `metrics appEnv` — `shikigami-core/src/Shikigami/Trigger/Scheduler.hs:118` —
which is `Nothing` today.) `KeiroMetrics` is a record of 33 OTel instruments
(`keiro/src/Keiro/Telemetry.hs:600-634`) including `outboxBacklog :: Gauge Int64`,
`outboxPublished/outboxRetried/outboxDeadlettered :: Counter Int64`, `timerBacklog`,
`timerFireLag :: Histogram`, `workflowActive :: Gauge Int64`; the constructor is
`newKeiroMetrics :: MonadIO m => Meter -> m KeiroMetrics` (`Telemetry.hs:643`). keiro also
offers `sampleOutboxBacklog` and `outboxMaintenancePass` (`keiro/src/Keiro/Outbox.hs:470` and
`:451-455`), both taking `Maybe KeiroMetrics`.

Tracing. Only the worker command builds a real tracer (`Commands/Worker.hs:29`,
`withRunTracer`); the scheduler and consumers call kioku's `noopTracer`
(`Commands/Scheduler.hs:38`, `Commands/ConsumeStream.hs:42,:72`). Spans exist for `agent.run`
(consumer kind, `Worker.hs:168-172`), `trigger` and `behavior` (internal,
`Workflow.hs:170-182`), and `sink.dispatch` (producer, `Workflow.hs:190-193`). But
`sink.dispatch` only *enqueues* outbox messages; the actual HTTP delivery happens later in the
outbox publisher loop via `publishSinkIntent` (`Workflow.hs:561-583`) → `dispatch`
(`Sink.hs:39`) → `postJSON` (`shikigami-core/src/Shikigami/Sink/Http.hs:31-51`), with no span
and no `traceparent` header (`Http.hs:38-43` sets only `content-type`). The link between the
two sides is severed at `sinkIntentEvent`, which constructs the keiro `IntegrationEvent` with
`traceContext = Nothing` (`Workflow.hs:541`). A second, near-duplicate sink-intent builder
lives in `shikigami-core/src/Shikigami/Flow/SinkOutbox.hs` (its `SinkIntent` at lines 33-41
also builds an `IntegrationEvent` without trace context); note that
`docs/plans/27-consolidate-sink-intent-and-run-lifecycle-machinery.md` plans to merge these —
patch both until then.

One API caveat for later readers: shikigami pins shibuya from git (`cabal.project:114`), and
the pinned `runApp` takes `(strategy, inboxSize, processors)` positionally (`Worker.hs:78`)
while newer shibuya sources take an `AppConfig`. This plan does not touch that call; do not
"fix" it in passing.


## Plan of Work

### Milestone 1 — structured logging

Scope: a logging module and the mechanical replacement of every bare stderr write. At the end,
every runtime log line is one JSON object.

Create `shikigami-core/src/Shikigami/Log.hs`, module `Shikigami.Log`, exporting a `Logger`
value-record and constructors:

```haskell
data Level = Debug | Info | Warn | Error
data Logger = Logger { minLevel :: !Level, sink :: !(ByteString -> IO ()) }

newStderrLogger :: Level -> IO Logger        -- line-buffered stderr JSON sink
logEvent :: Logger -> Level -> Text -> [Pair] -> IO ()
-- emits {"ts":"2026-07-08T21:00:00Z","level":"info","event":"worker.job.completed","agent":"heartbeat",...}
```

`Pair` is aeson's key-value type; `ts` is ISO-8601 UTC from `getCurrentTime`. Document the
vocabulary in the module header: `event` is `component.subject.verb`; standard keys are
`agent`, `run_id`, `workflow_id`, `sink_kind`, `outcome`, `topic`, `error`. Add
`Shikigami.Log` to `exposed-modules` in `shikigami-core/shikigami-core.cabal` (no new
dependencies; `aeson`, `bytestring`, `time` are present).

Thread a `Logger` where the call sites live: add a `logger :: !Logger` field to `WorkerEnv`
(`Worker.hs:55-63`), to `SinkContext` (`shikigami-core/src/Shikigami/Sink/Types.hs` — the
record `dispatch` receives), and pass one into the consumer entry points
(`subscribeActivityStream`/`subscribeIntegrationEventStream` in `Trigger/Consumer.hs`, either
as a parameter or via a small env record). Construct it once per command in the CLI modules.
Then replace each `hPutStrLn stderr`/`putStrLn` call site listed in Context with `logEvent`,
choosing event names per the vocabulary (for example `Worker.hs:136` becomes
`worker.job.dead_lettered` with `error` and the decode message; `Sink.hs:45` becomes
`sink.denied` with `sink_kind` and `reason`). Implement `logSinkResult` (`Workflow.hs:629-630`)
as `sink.result` with `agent`, `run_id` (the job's idempotency key), `sink_kind`, and
`outcome` — it already receives the `RunJob` and `SinkResult`; give it the `Logger` via
`AgentRunDeps` (add a `logger` field, defaulted in `agentRunDeps`, `Worker.hs:194-206`).

Acceptance: `cabal build all` passes; running the worker and enqueueing a run produces only
JSON lines on stderr, and `jq -r .event` over the captured stderr yields event names with no
parse errors.

### Milestone 2 — metrics

Scope: real instruments behind every hook that today gets `Nothing`, plus shikigami's own
counters. Start with a spike (prototyping in the PLANS.md sense) because the metrics export
path of hs-opentelemetry is less proven in this codebase than its trace path: in a scratch
`Main`, build a `MeterProvider`/`Meter` (find the construction API by reading the imports of
`/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Telemetry.hs`, which names the instrument
types shikigami must feed), create one counter, add to it, and confirm the collector receives
it via OTLP. Promotion criterion: the counter is visible in the collector's debug output. If
the SDK cannot export metrics, record it in Surprises & Discoveries and fall back to a periodic
exposition loop that logs instrument readings as `metrics.sample` events through
`Shikigami.Log` — the instrument wiring below is identical either way.

Then extend `shikigami-core/src/Shikigami/Telemetry.hs`: replace `withRunTracer` with

```haskell
withRunTelemetry :: Text -> (Tracer -> Maybe KeiroMetrics -> ShikigamiMetrics -> IO a) -> IO a
```

(the `Text` is the instrumentation-scope name — currently hardcoded to `"shikigami.worker"` at
`Telemetry.hs:26`; each command passes its own). Keep `withRunTracer` as a thin shim during the
migration, delete it at the end. When `OTEL_EXPORTER_OTLP_ENDPOINT` is unset, build the no-op
providers exactly as today — and still return `Just` metrics, which is safe per keiro's
documentation of `newKeiroMetrics` under a no-op meter.

Create `shikigami-core/src/Shikigami/Telemetry/Metrics.hs` with:

```haskell
data ShikigamiMetrics = ShikigamiMetrics
  { runsStarted, runsCompleted, runsFailed, runsRetried, runsDeadLettered :: !(Counter Int64),
    queueDepth :: !(Gauge Int64),
    consumerRecords :: !(Counter Int64)
  }

newShikigamiMetrics :: (MonadIO m) => Meter -> m ShikigamiMetrics
```

instrument names per the vocabulary (`shikigami.runs.started` etc.), attribute sets kept
low-cardinality (`agent`, `trigger.kind`, `outcome`, `topic` only).

Wire it: in each CLI command construct `AppEnv { …, metrics = keiroMetrics }` with the value
from `withRunTelemetry` (`Commands/Worker.hs:32`, `Commands/Scheduler.hs:39`,
`Commands/ConsumeStream.hs:43,:73`); pass the same value to `publishClaimedOutbox` at
`Worker.hs:108` and `runWorkflowTimerWorker` at `Worker.hs:119` (the scheduler's
`Trigger/Scheduler.hs:118` then works for free). Add `ShikigamiMetrics` to `WorkerEnv` and
increment: `runsStarted` on job decode success (`handleRunJob`, `Worker.hs:132`),
`runsCompleted`/`runsFailed`/`runsRetried`/`runsDeadLettered` at each `AckDecision` branch of
`runOneAgent` (`Worker.hs:174-192`) and the dead-letter branches at `Worker.hs:136-137,146`.
In the worker add a sampler loop (a fifth concurrent action in `runWorker`, `Worker.hs:70`)
that once per, say, 15 seconds sets `queueDepth` from
`SELECT count(*) FROM pgmq.q_shikigami_run_jobs` (a hasql statement over `pool`) and calls
keiro's `sampleOutboxBacklog` with the metrics so `outboxBacklog` is live. In
`Trigger/Consumer.hs`, bump `consumerRecords` (attribute `topic`) per record processed in
`processRecord`/`processEventRecord`.

Acceptance: with the collector running, one enqueued run yields `shikigami.runs.started` and
`shikigami.runs.completed` increments and a `shikigami.queue.depth` gauge report; keiro's
`keiro.outbox.*` instruments (names as keiro defines them) appear once sink intents flow.

### Milestone 3 — trace propagation end to end

Scope: every command traced, and one connected trace across the outbox.

First, replace `noopTracer` with `withRunTelemetry` in `Commands/Scheduler.hs:38` and
`Commands/ConsumeStream.hs:42,:72`, scope names `shikigami.scheduler`,
`shikigami.consume-stream`, `shikigami.consume-events`.

Second, capture context at the producer. In `enqueueSinkIntents` (`Workflow.hs:386-440`) the
`sink.dispatch` span is already open when intents are built; obtain the current span's
`SpanContext` (via `OpenTelemetry.Trace.Core.getSpanContext` on the span `withSpan'` provides)
and render the W3C header string `00-<trace-id>-<span-id>-<trace-flags>`. keiro depends on
`hs-opentelemetry-propagator-w3c` for exactly this encoding; add the same package to
`shikigami-core.cabal` and use its encoder rather than hand-formatting (verify the exact
function by reading that package's `OpenTelemetry.Propagator.W3CTraceContext` module source; if
its API is awkward to call outside a propagator, hand-render — the format is stable — and say
so in Surprises & Discoveries). Pass the rendered value into `sinkIntentEvent`
(`Workflow.hs:523-544`) as a new parameter and set
`traceContext = Just TraceContext { traceparent, tracestate = Nothing }` instead of `Nothing`
(`Workflow.hs:541`). Apply the same change to the builder in
`shikigami-core/src/Shikigami/Flow/SinkOutbox.hs`.

Third, continue the trace at the publisher. `publishSinkIntent` (`Workflow.hs:561-583`)
receives the `OutboxRow` whose `event :: IntegrationEvent` now carries `traceContext`. Wrap the
`dispatch` call in a `sink.publish` span (kind Consumer — it continues the producer span) whose
parent is reconstructed from the stored `traceparent`; attributes `agent`, `sink_kind`,
`outbox.message_id`. Fourth, propagate onward over HTTP: consume

```haskell
postJSONWithHeaders :: (ToJSON a) => HttpEnv -> [(HeaderName, ByteString)] -> Text -> a -> IO (Either Text LBS.ByteString)
```

from `Shikigami.Sink.Http` as defined by plan 22, appending the trace header to the
authentication headers already injected from `HttpEnv`; `postJSON env =
postJSONWithHeaders env []`. Have the sink clients
(`Shikigami.Sink.KawaClient`, `Shikigami.Sink.KizashiClient`, `Shikigami.Sink.Danwa`) accept an
optional traceparent from `SinkContext` (add a `traceparent :: Maybe Text` field) and send
`("traceparent", …)`. `publishSinkIntent` fills that field from the row's context.

Acceptance: the Postgres-level proof is a new test (M3 step) in
`shikigami-core/test/Shikigami/AgentWorkflowSpec.hs` — run a workflow that enqueues a sink
intent under a real tracer, then assert `SELECT traceparent FROM keiro.keiro_outbox` is
non-null and starts with `00-`. The wire-level proof is `stub-kawa` logging a `traceparent`
request header (extend its request log while here), or the collector showing `agent.run` and
`sink.publish` in one trace.


## Concrete Steps

All commands run from the repo root inside `nix develop`.

Build and test loop used throughout:

```bash
cabal build all
cabal test all
```

Expected: `Test suite shikigami-core-test: PASS` (the suite provisions ephemeral Postgres via
`withShikigamiMigratedDatabase`, `shikigami-migrations/test-support/Shikigami/Migrations/
TestSupport.hs:12`; no services needed).

M1 verification — capture and parse worker logs (requires the local stack from
`docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md`,
or a manually started Postgres with `PG_CONNECTION_STRING` set):

```bash
cabal run shikigami -- worker --agents agents 2>worker.log &
cabal run shikigami -- enqueue-run heartbeat
sleep 5; kill %1
jq -r '.event' < worker.log | sort | uniq -c
```

Expected shape (names per the vocabulary; counts vary):

```text
   1 worker.loop.started
   1 worker.job.started
   1 worker.job.completed
   2 sink.result
```

Any non-JSON line makes `jq` print a parse error — that is the failure signal.

M2 spike — run a local collector and point the exporter at it (any OTLP collector works; if one
is not installed, `docker run -p 4318:4318 otel/opentelemetry-collector` with a debug exporter
config is the reference setup, or skip to the fallback exposition):

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
cabal run shikigami -- worker --agents agents 2>worker.log
```

Expected: the collector's debug output prints `shikigami.runs.started` datapoints after an
`enqueue-run`.

M3 verification — the DB-level assertion, runnable without any collector:

```bash
cabal test shikigami-core-test --test-options='-p "traceparent"'
```

Expected: the new test case (named to match the pattern `traceparent`) passes, having asserted
a non-null `00-…` value in `keiro.keiro_outbox.traceparent`.


## Validation and Acceptance

Acceptance is behavioral:

1. Structured logs: with the worker running and one run enqueued, stderr contains only JSON
   objects; `jq -r .event` succeeds on every line; `sink.result` events appear (proving
   `logSinkResult` is no longer a no-op).
2. Metrics: with `OTEL_EXPORTER_OTLP_ENDPOINT` set and a collector running, one enqueued run
   produces `shikigami.runs.started` and `shikigami.runs.completed`; `shikigami.queue.depth`
   reports; keiro outbox instruments report once a sink intent is published. With the variable
   unset, all commands run exactly as before (no-op providers, no errors).
3. Traces: `keiro.keiro_outbox.traceparent` is populated for new sink intents (test above);
   the outbound POST carries a `traceparent` header (observed in `stub-kawa`'s request log); in
   a collector UI the `agent.run` trace contains `sink.dispatch` and `sink.publish`.
4. Regression: `cabal build all` and `cabal test all` pass; the scheduler and consumers start
   and run with and without the OTLP endpoint set.


## Idempotence and Recovery

All changes are code-level and additive-then-substitutive; every milestone leaves `cabal test
all` green, so work can pause at any milestone boundary. The log-call replacement in M1 is
mechanical and safe to do file-by-file (each file compiles independently). If the M2 spike
fails, nothing has been wired yet — record the finding, switch to the log-exposition fallback,
and proceed; the instrument call sites are identical. M3's schema is untouched (the outbox
columns already exist), so no migration risk exists; if the `sink.publish` span or header
breaks a sink client, the header addition is behind `postJSONWithHeaders` and reverting to
`postJSON` restores the old wire behavior without touching the propagation of `traceContext`
into the outbox (independently useful and safe — keiro treats it as opaque).


## Interfaces and Dependencies

Dependencies: `hs-opentelemetry-api`, `hs-opentelemetry-sdk`, `hs-opentelemetry-exporter-otlp`
are already in `shikigami-core.cabal:89-91`; add `hs-opentelemetry-propagator-w3c` (keiro
already depends on it — same source tree, `/Users/shinzui/Keikaku/bokuno/keiro`). keiro
provides `Keiro.Telemetry (KeiroMetrics, newKeiroMetrics)` and
`Keiro.Outbox (publishClaimedOutbox, sampleOutboxBacklog)`; kioku provides
`Kioku.App (AppEnv (..))`. No logging framework is added.

Signatures that must exist at the end of each milestone (full module paths):

- M1: `Shikigami.Log.Logger`, `Shikigami.Log.newStderrLogger :: Level -> IO Logger`,
  `Shikigami.Log.logEvent :: Logger -> Level -> Text -> [Data.Aeson.Types.Pair] -> IO ()`;
  `Shikigami.Worker.WorkerEnv` gains `logger :: !Logger`;
  `Shikigami.Agent.Workflow.AgentRunDeps` gains `logger :: !Logger`.
- M2: `Shikigami.Telemetry.Metrics.ShikigamiMetrics`,
  `Shikigami.Telemetry.Metrics.newShikigamiMetrics :: (MonadIO m) => Meter -> m ShikigamiMetrics`,
  `Shikigami.Telemetry.withRunTelemetry :: Text -> (Tracer -> Maybe KeiroMetrics -> ShikigamiMetrics -> IO a) -> IO a`.
  Consumed upstream signatures (verified 2026-07-08):
  `newKeiroMetrics :: (MonadIO m) => Meter -> m KeiroMetrics` (keiro `Telemetry.hs:643`);
  `publishClaimedOutbox :: (IOE :> es, Store :> es) => ([OutboxRow] -> Eff es [(OutboxId, PublishOutcome)]) -> OutboxPublishOptions -> Maybe KeiroMetrics -> Eff es OutboxPublishSummary`
  (keiro `Outbox.hs:297-303`);
  `runWorkflowTimerWorker :: (IOE :> es, Store :> es) => Maybe KeiroMetrics -> UTCTime -> (TimerRow -> Eff es (Maybe EventId)) -> Eff es (Maybe TimerRow)`
  (keiro `Workflow/Sleep.hs:305-311`).
- M3: consume `Shikigami.Sink.Http.postJSONWithHeaders :: (ToJSON a) => HttpEnv -> [(HeaderName, ByteString)] -> Text -> a -> IO (Either Text LBS.ByteString)` from plan 22;
  `Shikigami.Sink.Types.SinkContext` gains `traceparent :: !(Maybe Text)`;
  `sinkIntentEvent` takes the trace context and sets
  `Keiro.Integration.Event.IntegrationEvent.traceContext :: Maybe TraceContext` (field at
  `keiro-core/src/Keiro/Integration/Event.hs:107`; `TraceContext` at `Event.hs:146-150`).

Cross-plan contracts (mirrored in the MasterPlan's Integration Points): Milestones 1 and 2
may proceed independently, but Milestone 3 has a hard milestone dependency on plan 22's
authenticated HTTP seam. The vocabulary defined
here (Decision Log, last entry) is what plans in MasterPlans 2-5 emit against; the new env/flag
surface (none beyond the standard `OTEL_*` family, unless the M2 fallback adds a knob) must be
recorded in `docs/operations/configuration.md` owned by
`docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md`;
`docs/plans/29-health-liveness-and-worker-loop-supervision.md` will reuse `Shikigami.Log` for
its loop-supervision events (soft; this plan does not depend on it).


## Revision Notes

- 2026-07-22: Routed HTTP trace propagation through plan 22's authenticated
  `postJSONWithHeaders` helper. Milestones 1–2 remain independently implementable;
  Milestone 3 waits for plan 22 so auth and tracing compose on one request path.
