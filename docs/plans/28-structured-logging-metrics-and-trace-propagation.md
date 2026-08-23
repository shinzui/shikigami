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

Milestone 1 made long-running Shikigami application logs structured JSON and exposed per-sink
results, but the runtime is still operationally incomplete. Every metrics hook the substrate
exposes is filled with `Nothing`, so nothing counts runs, queue depth, outbox lag, or consumer
throughput. Tracing exists only inside the worker command; the scheduler and both consumers
run a no-op tracer, and the trace dies at the outbox: the `sink.dispatch` producer span is never
connected to the asynchronous HTTP publish that actually delivers the sink. The HTTP server
also lacks bounded, trace-correlated production request logs and bracketed provider shutdown.

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

- [x] Prerequisites: plans 22/36/37/47 complete for this plan's integration surfaces;
      telemetry lifecycle remains owned by the server and workers process composition roots.
      Verified 2026-08-23.
- [x] Pre-implementation refresh: reconciled Milestones 2-4 with the current seven-package
      layout, Keiro 0.14.0.0, hs-opentelemetry 1.0.0.0, Kioku 0.5.0.0, Shibuya 0.9.0.0,
      the public PGMQ queue-metrics API, and the current workflow-versioning rules.
      Done 2026-08-23.

- [x] M1: `Shikigami.Log` module written (JSON-lines logger, levels, event names, key-value
      fields); vocabulary documented in the module header. Done 2026-08-05, with a sibling
      `Shikigami.Log.Correlation` carrying the run and call identifiers — see the Decision Log
      for why they are a separate module.
- [x] M1: every stderr write in the long-running processes replaced with `Shikigami.Log` —
      the four worker loops (`Shikigami.Workers.Registry`, `Shikigami.Agent.RunJob.Worker`,
      `Shikigami.Agent.Workflow.Resume`, `Shikigami.Trigger.Timer`,
      `Shikigami.Flow.SinkOutbox.Publisher`), the scheduler, both Kafka consumers
      (`Shikigami.Trigger.Consumer`, `Shikigami.Workers.Subscription`),
      `Shikigami.Sink`, and `Shikigami.Behavior.Provider`. Done 2026-08-05.
- [x] M1: `logSinkResult` implemented: one structured line per sink result with agent, run id,
      sink kind, and outcome. Done 2026-08-05. Verified live — see Outcomes.
- [x] M1: acceptance run performed 2026-08-05 against a fresh migrated database: worker
      started, one run enqueued, `jq -r .event` parsed every application line with no errors,
      and `sink.result` appeared with `outcome=delivered`. Transcript in Outcomes.
- [ ] M1 (remaining): one-shot CLI commands still write human-readable text. This is a
      deliberate scope decision, not an omission — see the Decision Log.
- [ ] M1 (remaining, deferred to M4): the GHC runtime's uncaught-exception dump is the only
      non-JSON output left on a worker's stderr, and it appears on abrupt termination. See
      Surprises & Discoveries.
- [x] M2 (provider proof): a `Meter` built from the hs-opentelemetry 1.0.0.0 SDK exports all
      seven Shikigami instruments on provider force-flush. Done 2026-08-23.
- [x] M2: `Shikigami.Telemetry.Metrics` written (`ShikigamiMetrics` record +
      `newShikigamiMetrics`); `Shikigami.Telemetry.withRunTelemetry` supersedes `withRunTracer`
      and also yields `Maybe KeiroMetrics` and `ShikigamiMetrics`. Done 2026-08-23.
- [x] M2: production `AppEnv.metrics` construction sites populated; Keiro workflow, resume,
      outbox, timer, and scheduler options receive process telemetry; queue-depth and
      outbox-backlog sampler supervised; run and consumer counters recorded. Done 2026-08-23.
- [x] M3: scheduler and both consumers run a real tracer (`withRunTelemetry`), not
      `noopTracer`. Done as part of M2 process wiring 2026-08-23.
- [x] M3: `sinkIntentEvent` and the `Shikigami.Flow.SinkOutbox` builder populate
      `IntegrationEvent.traceContext`; test proves `keiro.keiro_outbox.traceparent` is non-null
      after `enqueueSinkIntents`. Done 2026-08-23.
- [x] M3: `publishSinkIntent` opens a `sink.publish` span parented on the stored trace context,
      and the outbound HTTP POST carries a `traceparent` header through plan 22's
      `postJSONWithHeaders`; Kawa, Kizashi, Rei, and Danwa recording stubs all prove the wire
      header. Done 2026-08-23.
- [ ] M4: bracket tracer/meter/exporter providers through graceful shutdown and flush;
      bounded HTTP request logging runs inside OTel, excludes health paths, and records no bodies/query/auth/cookies/arbitrary headers.


## Surprises & Discoveries

**The refresh found a seven-package deployed layout, not the six-package layout recorded in
the 2026-08-05 note.** Plan 22 subsequently introduced the deliberately light
`shikigami-agent` package alongside `shikigami-core`, `shikigami-api`, `shikigami-server`,
`shikigami-workers`, `shikigami-client`, and `shikigami-migrations`. ADR 0003 requires the
agent package to avoid the exporter stack, so provider construction cannot move into core as
the old Milestone 2 text proposed. Provider-free instruments and trace-context helpers belong
in core; the server and workers packages each own their provider lifecycle at the process
composition root.

**The metrics spike no longer needs to decide whether hs-opentelemetry metrics can export.**
The released 1.0.0.0 SDK has an OTLP metric exporter, a periodic reader, global meter-provider
initialization, force-flush, and shutdown APIs. The authoritative Hackage registry and upstream
release tags agree with the versions already selected by `cabal.project`. M2 keeps a small
export/flush integration proof, but the log-exposition fallback in the old plan is removed:
it would create a second metrics system after the selected SDK has already supplied the required
one.

**Keiro 0.14 exposes context capture but not generic remote-parent continuation.**
`Keiro.Telemetry.traceContextFromCurrentSpan` is public and produces the exact
`IntegrationEvent.traceContext` value this plan needs. Keiro's W3C extraction helper,
`withRemoteParent`, is private, while the public `withConsumerSpan` is specialized to Kafka
records. Therefore the outbox publisher cannot implement `sink.publish` from the released API
alone. M3 adds one narrow provider-free helper in Shikigami core using the same released
`hs-opentelemetry-propagator-w3c` context attach/detach mechanism Keiro uses internally. It is
only a bridge from Keiro's public `TraceContext`; it does not define another wire format.

**The PGMQ adapter already exposes queue depth without table-name coupling.**
`Pgmq.Hasql.Sessions.queueMetrics` returns `QueueMetrics` with strict `queueLength` and
`queueVisibleLength` fields. The sampler should use that public API instead of querying
`pgmq.q_shikigami_run_jobs` directly, which would couple Shikigami to PGMQ's physical schema.

**Danwa's generated Servant actions have no per-request header parameter.** The released
`servant-client` `ClientEnv` exposes `makeClientRequest`, which can be composed for one
`runClientM` call. M3 uses a record-updated environment for each dispatch, filters additions to
`traceparent` and `tracestate`, and leaves Danwa's dedicated manager hook as the only owner of
authorization. This avoids mutable manager state and prevents concurrent deliveries from
observing one another's trace context.

**Workflow telemetry must pass through Shikigami's single options authority.**
Keiro 0.14's `WorkflowRunOptions` carries both `tracer` and `metrics`, but
`Shikigami.Workflow.Versioning` currently constructs one static value with neither populated.
Parameterizing that module from `AppEnv` preserves its ownership of patches and resume options;
threading process dependencies into options does not alter durable step shape and requires no
workflow patch under `docs/workflow-versioning.md`.

**The SDK's meter initializer defaults to an OTLP exporter even without an endpoint.** That is
correct SDK behavior, but it is not Shikigami's existing opt-in contract: a process with no
`OTEL_EXPORTER_OTLP_ENDPOINT` must not start a localhost exporter loop. `withRunTelemetry`
therefore performs the single endpoint-presence check already permitted by the configuration
policy, installs global no-op tracer/meter providers when absent, and delegates all other
`OTEL_*` parsing to the SDK when present.

**The original plan named locations the code no longer occupies.** This plan was written before
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md` landed,
and it points at two different absent layouts. `shikigami-core/src/Shikigami/Worker.hs` is the
pre-split past: plan 36 moved that code into `shikigami-workers`. `shikigami-cli` is the
opposite — a *planned* package that does not exist yet, so those references may become correct
again when it lands, and should be re-pointed to today's locations rather than treated as
errors to delete. The real 2026-08-05 locations are:

| Plan said | Actually |
|---|---|
| `shikigami-core/src/Shikigami/Worker.hs` | `shikigami-workers/src/Shikigami/Workers/Registry.hs` (loops) and `.../Shikigami/Agent/RunJob/Worker.hs` (job handling) |
| `WorkerEnv` in `Worker.hs:55-63` | `shikigami-workers/src/Shikigami/Workers/Config.hs` |
| `shikigami-cli/.../Commands/Worker.hs` | `shikigami-workers/src/Shikigami/Workers/Command/Worker.hs` |
| `shikigami-cli/.../Commands/ConsumeStream.hs` | `shikigami-workers/src/Shikigami/Workers/Subscription.hs` |
| `shikigami-core/src/Shikigami/Telemetry.hs` | `shikigami-workers/src/Shikigami/Telemetry.hs` |

The Context, Plan of Work, and Interfaces sections were re-pointed to the current locations on
2026-08-23. When `shikigami-cli` lands, command-module references should be revisited rather
than assumed wrong.

**`Control.Lens` exports a `Level` type, so the plan's `data Level` was ambiguous on sight.**
`Shikigami.Prelude` re-exports `module Control.Lens`, which brings
`Control.Lens.Internal.Level` into scope in every module that imports the prelude:

```text
src/Shikigami/Log.hs:146:38: error: [GHC-87543]
    Ambiguous occurrence 'Level'.
    It could refer to either 'Shikigami.Prelude.Level',
        imported from 'Shikigami.Prelude' ...
        (and originally defined in 'Control.Lens.Internal.Level'),
      or 'Shikigami.Log.Level', defined at src/Shikigami/Log.hs:101:1.
```

Fixed by `import Shikigami.Prelude hiding (Level)` inside `Shikigami.Log`. Call sites name a
constructor (`Log.Info`), not the type, so the collision stops at that one module. Any later
plan adding a type to `Shikigami.Log` should check the lens namespace first.

**`DuplicateRecordFields` makes a shared field name unusable as a bare selector.** Three records
now carry a `logger` field — `WorkerEnv`, `AgentRunDeps`, `SinkContext` — and any module with
two of them in scope cannot write `logger x`:

```text
src/Shikigami/Agent/Workflow.hs:233:41: error: [GHC-87543]
    Ambiguous occurrence 'logger'.
    It could refer to either the field 'logger' of record 'AgentRunDeps',
      or the field 'logger' of record 'SinkContext', imported from 'Shikigami.Sink'
```

Resolved with named accessors (`depsLogger`, `envLogger`) that pattern-match on the
constructor. Milestone 2 adds a `metrics` field to some of the same records and will hit this
again; define the accessor with the field.

**One stderr write hid from the obvious grep.** `Shikigami.Behavior.Provider` announced the
selected model provider with `TextIO.hPutStrLn IO.stderr`, which a search for
`hPutStrLn stderr` does not match. It was invisible until the first live worker run, where it
was the single line that made `jq` fail on the whole stream. The grep that actually finds every
one is:

```bash
grep -rnE "hPutStr(Ln)? *(IO\.)?stderr|hPrint *(IO\.)?stderr" --include='*.hs' \
  shikigami-core/src shikigami-workers/src shikigami-server/src shikigami-client/src
```

**The last non-JSON line on a worker's stderr belongs to the GHC runtime, not to this plan.**
On abrupt termination the worker prints the top-level uncaught-exception dump:

```text
shikigami-worker: Uncaught exception ghc-internal:GHC.Internal.IO.Exception.SomeAsyncException:
ExceptionInLinkedThread (ThreadId 29) thread blocked indefinitely in an STM transaction
HasCallStack backtrace:
  throwIO, called at ./Control/Concurrent/Async/Internal.hs:755:24 in sync-2.2.6-...
```

No logging module can intercept that without installing a top-level handler, and the underlying
complaint — a linked thread deadlocking in STM rather than shutting down — is a graceful-shutdown
defect. Both belong to Milestone 4, which already owns "bracket tracer/meter/exporter providers
through graceful shutdown". Recorded here so M4 knows it has a reproducer: start the worker,
enqueue one run, terminate the process.

**keiro writes its own unstructured lines, which this repository cannot convert.** A worker
against a partially-migrated database produced:

```text
keiro resume worker: pass failed: UnexpectedServerError "42P01" "relation \"keiro.keiro_awakeables\" does not exist"
```

That line is printed by the keiro library, not by shikigami. A worker's stderr is therefore
all-JSON only while keiro's own loops stay quiet, and an upstream request would be needed to
close that gap properly. No milestone here depends on it.

**One core test failed once and did not reproduce.** A `cabal test all` run reported
`1 out of 157 tests failed` without my capturing which; two subsequent full runs of the same
command were green (157/157 twice, plus all other suites). The suites provision ephemeral
PostgreSQL clusters concurrently and a dev cluster was running at the same time, which is the
most likely cause. Noted rather than resolved: it is not attributable to this plan's changes,
and it should be watched for.


## Decision Log

- Decision: Process composition roots acquire and bracket OTel providers/exporters,
  flush on graceful shutdown, and place bounded request logging inside trace middleware.
  Rationale: global/unbracketed providers lose tail telemetry and cannot reliably
  correlate request logs with active trace/span ids.
  Date: 2026-07-22
- Decision: Production access logs use the fixed API-standard whitelist: UTC time, method,
  raw path without query, status, monotonic duration, optional trace/span IDs, and bounded
  user agent. They never use `wai-extra`'s body-capturing JSON formatter.
  Rationale: bodies, arbitrary headers, and query strings are credential-bearing surfaces;
  a small in-repo WAI middleware can observe status and active OTel context without consuming
  either body.
  Date: 2026-07-22
- Decision: Standard `OTEL_*` variables remain SDK-owned; any Shikigami-specific
  telemetry setting is declared through plan 37's Settei config.
  Rationale: re-parsing the standard SDK surface creates divergent precedence/behavior.
  Date: 2026-07-22

- Decision: Keep provider/exporter construction in the `shikigami-workers` and
  `shikigami-server` composition roots; put only instruments and propagation helpers in
  `shikigami-core`.
  Rationale: this follows the seven-package boundary and ADR 0003's requirement that the
  `shikigami-agent` closure remain free of the telemetry exporter stack.
  Date: 2026-08-23

- Decision: Parameterize `Shikigami.Workflow.Versioning` with `AppEnv` and derive Keiro's
  workflow `tracer` and `metrics` options there.
  Rationale: the module remains the only authority that constructs Shikigami workflow and
  resume options, while every run receives the process telemetry already stored in `AppEnv`.
  This dependency threading changes no durable workflow step shape and needs no patch id.
  Date: 2026-08-23

- Decision: Sample PGMQ depth through `Pgmq.Hasql.Sessions.queueMetrics`, recording total
  `queueLength`, and sample Keiro outbox backlog through `sampleOutboxBacklog`.
  Rationale: both are released public APIs and avoid coupling observability to either
  dependency's physical table schema. Total queue length includes in-flight work and is the
  most useful saturation signal; visible length can be added later under a distinct metric.
  Date: 2026-08-23

- Decision: Add a narrow local `withRemoteTraceContext` helper over
  `hs-opentelemetry-propagator-w3c` for `sink.publish`.
  Rationale: Keiro 0.14 publicly captures `TraceContext` but its generic remote-parent helper
  is private. Copying the released library's attach/detach pattern lets Shikigami consume
  Keiro's public wire type without inventing a format or waiting on a cross-repository release.
  Date: 2026-08-23

- Decision: Add Danwa W3C propagation by composing `ClientEnv.makeClientRequest` for each
  generated-client invocation.
  Rationale: the generated API has no header arguments, while a per-call environment update is
  concurrency-safe and preserves the existing host-scoped opaque-authentication manager hook.
  Date: 2026-08-23

- Decision: Count `runs.started` immediately before dispatch of an admitted job;
  `runs.completed` only for a terminal successful run; `runs.failed` for each unsuccessful
  attempt; and `runs.retried` or `runs.dead_lettered` additionally at the matching queue
  disposition. Suspended or continued-as-new workflows are neither completed nor failed.
  Rationale: these decision points match actual lifecycle transitions and keep a retry visible
  as both a failed attempt and a scheduled retry without falsely presenting workflow suspension
  as success.
  Date: 2026-08-23

- Decision: Put the run and call correlation identifiers in a sibling module,
  `Shikigami.Log.Correlation`, re-exported from `Shikigami.Log`.
  Rationale: the 2026-08-05 Portfolio Reconciliation makes these identifiers durable audit
  evidence for `docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md`, which stores
  them. A module that needs to *store* a correlation identifier should not have to depend on a
  logging surface to name its type. Re-exporting keeps the single-import path for callers that
  only log.
  Date: 2026-08-05

- Decision: A `CallCorrelationId` is derived from `(run id, journaled step name, ordinal)` and
  renders as `<run id>/<step>/<ordinal>`; there is deliberately no constructor from a raw
  `Text`.
  Rationale: the reconciliation requires these to be stable and reproducible across
  crash-and-resume, not merely unique within one process. Anything drawn from process-local
  state — a counter, a fresh UUID, a clock reading — changes after a resume and breaks the join
  between the log lines written before a crash and those written after. All three inputs are
  values keiro's journal replays, so re-deriving in a different process yields the same string.
  A readable path was chosen over a hash so an operator holding a log line can read the run and
  step straight off the identifier. Because plan 51 persists it, the rendering is pinned
  byte-for-byte in `Shikigami.LogSpec`; changing it later is a migration, not a refactor.
  Date: 2026-08-05

- Decision: Milestone 1 converts the long-running processes and leaves one-shot CLI commands
  writing human-readable text.
  Rationale: this plan's own acceptance is about a *worker's* stderr being machine-parseable.
  The commands left alone — `validate`, `enqueue-run`, `render-lifecycle`, `agent-run`,
  `run-behavior`, `publish-fixture`, `danwa-spike`, and the client checks — are user
  interfaces, not log streams; `render-lifecycle` emits a mermaid diagram a human pipes to a
  file, and wrapping `OK: 1 agent parsed.` in a JSON envelope would break the contract without
  making anything filterable. This plan's Context section names exactly the three long-running
  command modules, which confirms the original intent. `Shikigami.App.Config.Load`'s
  configuration-error reporting is likewise left alone: it runs before a logger exists and is
  what an operator sees when a process refuses to start.
  Date: 2026-08-05

- Decision: `sink_kind` values reuse `Shikigami.Sink.Permission.sinkKindText` (`KawaDigest`,
  `KizashiSignal`, …) rather than a new snake_case spelling.
  Rationale: that renderer already exists and already appears in permission-denial reasons.
  A second spelling of the same five values would mean a log query and a denial reason
  disagreeing about the name of the same thing.
  Date: 2026-08-05

- Decision: Build a minimal in-repo JSON-lines logger (`Shikigami.Log`) instead of adopting
  katip, co-log, or monad-logger.
  Rationale: the substrate was surveyed on 2026-07-08 (keiro, shibuya-core, kizashi-core,
  kioku, kawa — `.cabal` build-depends and source greps for katip/co-log/monad-logger/
  fast-logger/LogAction): none uses a logging framework. The ecosystem idiom is plain stderr
  lines plus OpenTelemetry spans for deep diagnostics (`Shibuya.Telemetry.Effect` is the shared
  tracing surface; `AppEnv.tracer` in `mori://shinzui/kioku` at
  `kioku-core/src/Kioku/App.hs`). Following the ecosystem
  means staying framework-free; what is missing is *structure*, not a framework. A ~100-line
  module over `aeson` (already a dependency) gives machine-parseable lines with zero new
  dependencies and no effect-system friction, and can be swapped later if the platform ever
  standardizes on a framework.
  Date: 2026-07-08

- Decision: Implement metrics through the OpenTelemetry `Meter` — `newKeiroMetrics` for the
  substrate instruments plus a sibling `ShikigamiMetrics` record for shikigami's own — rather
  than a Prometheus endpoint.
  Rationale: the hooks shikigami must fill are typed for this. `AppEnv.metrics ::
  Maybe KeiroMetrics` (`mori://shinzui/kioku`, `kioku-core/src/Kioku/App.hs`), and Keiro's constructor is
  `newKeiroMetrics :: MonadIO m => Meter -> m KeiroMetrics`
  (`mori://shinzui/keiro`, `keiro/src/Keiro/Telemetry.hs`) over hs-opentelemetry
  instruments; there is no Prometheus-based builder in keiro. shibuya's Prometheus exposition
  (`shibuya-metrics`) reads shibuya's internal always-on `MetricsMap` and is not a hook
  shikigami can populate. One OTel pipeline, gated by the already-honored
  `OTEL_EXPORTER_OTLP_ENDPOINT`, carries traces and metrics through the same collector. The
  2026-08-23 refresh verified the released SDK's OTLP metric path and lifecycle APIs; M2 keeps
  an export/flush proof but no longer carries a parallel log-exposition fallback.
  Date: 2026-07-08

- Decision: Propagate trace context through the outbox as a W3C `traceparent` using Keiro's
  existing `IntegrationEvent.traceContext` field, and give the asynchronous publish its own
  `sink.publish` span parented on it.
  Rationale: keiro already models this end to end — `traceContext :: Maybe TraceContext` on
  `IntegrationEvent` (`mori://shinzui/keiro`,
  `keiro-core/src/Keiro/Integration/Event.hs`), `TraceContext
  { traceparent :: Text, tracestate :: Maybe Text }`, persisted in the
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
  contract, now at `shikigami-workers/src/Shikigami/Telemetry.hs`), and `newKeiroMetrics` is
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

### Milestone 1 — complete 2026-08-05

`Shikigami.Log` and `Shikigami.Log.Correlation` exist in `shikigami-core`, every long-running
process emits one JSON object per log line, and `logSinkResult` is no longer a no-op.

The acceptance run used a fresh database rather than the repository's dev database, because the
latter is in a half-applied migration state that is plan 38's to repair
(`chk_streams_stream_name_length ... already exists`). Setup and run:

```bash
createdb -h "$PWD/db" shikigami_logproof
DATABASE_URL="host=$PWD/db dbname=shikigami_logproof user=$(id -un)" \
  cabal run shikigami-migrate -- up
PG_CONNECTION_STRING="postgresql://<urlencoded $PWD/db>/shikigami_logproof" \
  cabal list-bin shikigami-worker | xargs -I{} {} --agents agents 2>worker.log &
cabal list-bin shikigami | xargs -I{} {} enqueue-run heartbeat
```

`jq -r '.event' < worker.log` over the eight application lines exits 0 and yields:

```text
worker.agents.loaded
behavior.provider.selected
worker.loop.started
worker.resume.started
worker.timer.started
worker.outbox.started
sink.result
worker.job.completed
```

The two lines that carry the milestone's claims:

```json
{"event":"sink.result","agent":"heartbeat","run_id":"heartbeat:evt:2026-08-05T16:39:04.839229Z","outcome":"delivered","sink_kind":"KawaDigest"}
{"event":"worker.job.completed","agent":"heartbeat","run_id":"heartbeat:evt:2026-08-05T16:39:04.839229Z"}
```

`sink.result` appearing at all is the proof that the no-op is gone, and the shared `run_id`
across both lines is the join a later plan's audit record needs.

Tests: `cabal test all` green — 157 in `shikigami-core-test` (15 of them new, in
`Shikigami.LogSpec`), plus 21 workers, 20 server, 15 api, 3 client, 3+2 migrations.

**What remains open, and why.** One-shot CLI commands still print human-readable text (a scope
decision, below). The GHC runtime's crash dump on abrupt shutdown is still non-JSON, and belongs
to Milestone 4. keiro's own log lines are not convertible from this repository.

**Lesson for milestones 2 through 4.** The paths and dependency assumptions needed a fresh
audit after the package split. That audit and re-pointing were completed on 2026-08-23 before
M2 began; see Surprises & Discoveries for the resulting boundary decisions.

### Milestone 2 — complete 2026-08-23

`Shikigami.Telemetry.Metrics` now owns seven provider-free instruments and bounded recording
helpers. `shikigami-workers` brackets the global tracer and meter providers in each worker,
scheduler, and subscription process, constructs Keiro and Shikigami metrics once, force-flushes
before shutdown, and restores no-op globals after release. No configured endpoint still means
no exporter; configured processes delegate the remaining standard environment surface to the
1.0.0.0 SDK.

The same process telemetry now reaches Kioku `AppEnv`, Keiro workflow and resume options,
outbox publication, timers, and the scheduler. The worker records admitted attempts and exact
terminal/retry/dead-letter decisions. Both Kafka consumers count delivered records by topic.
A supervised 15-second sampler reads PGMQ total depth through `queueMetrics` and Keiro outbox
backlog through `sampleOutboxBacklog`; either failure is a structured warning and does not
suppress the independent sample or stop durable work.

The provider proof uses hs-opentelemetry's released in-memory metric exporter. One force-flush
exports all seven exact names. A second focused test proves a queue sampling failure still runs
the outbox sampler. `cabal test shikigami-core-test shikigami-workers-test` passes: 454 core
tests and 80 worker tests. The workflow-versioning tests remain green without a new patch id,
confirming that telemetry dependency threading did not alter durable step shape.

### Milestone 3 — complete 2026-08-23

Both sink-intent producers now capture the active W3C context into Keiro's existing durable
outbox columns. Publication attaches that stored remote parent, opens a Consumer-kind
`sink.publish` span with only `sink.kind`, captures the child context, and restores the prior
thread-local context even on exceptions. Invalid stored context is isolated as an unparented
publish and emits a structured warning instead of failing delivery.

All four HTTP sinks consume dispatch-scoped W3C headers. Kawa, Kizashi, and Rei use plan 22's
bounded authenticated `postJSONWithHeaders` path; Danwa uses a per-call Servant environment
transform while retaining its dedicated auth manager. The focused tests query
`keiro.keiro_outbox.traceparent`, compare exported producer/publish parent ids, compare the
outgoing header to the `sink.publish` span id, prove invalid-context isolation/restoration, and
record the header at Kawa, Kizashi, Rei, and Danwa stubs. The `traceparent` pattern runs six
tests successfully.


## Context and Orientation

Shikigami is a declared-agent runtime split across seven packages. `shikigami-workers` owns
the worker, scheduler, activity-stream consumer, and integration-event consumer executables;
`shikigami-server` owns the HTTP server; `shikigami-core` owns durable workflows and the sink
dispatcher; and `shikigami-agent` deliberately stays free of provider/exporter dependencies.
`Shikigami.Workers.Registry` supervises the run-job drain, workflow-resume, outbox-publisher,
timer, and optional directory-consumer loops. `Shikigami.Workers.Command.Worker`,
`Shikigami.Workers.Scheduler`, and `Shikigami.Workers.Subscription` are their composition
roots. `Shikigami.Server.Boot` is the HTTP composition root.

The shared runtime environment is Kioku's `AppEnv`
([mori://shinzui/kioku](mori://shinzui/kioku)):

```haskell
data AppEnv = AppEnv
  { connectionSettings :: !ConnectionSettings,
    tracer :: !Tracer,
    metrics :: !(Maybe KeiroMetrics)
  }
```

Three dependency terms matter. *Keiro* ([mori://shinzui/keiro](mori://shinzui/keiro)) is the
durable-workflow engine and transactional outbox. *PGMQ*
([mori://shinzui/pgmq-hs](mori://shinzui/pgmq-hs)) stores run jobs and exposes queue metrics.
*OTLP* is the OpenTelemetry wire protocol; the selected
[hs-opentelemetry source](mori://iand675/hs-opentelemetry) is the released 1.0.0.0 family.
`cabal.project` selects Keiro 0.14.0.0, Kioku 0.5.0.0, Shibuya 0.9.0.0, and
hs-opentelemetry 1.0.0.0, all verified against their authoritative registry versions and
upstream release tags on 2026-08-23.

Logging is already implemented. `Shikigami.Log` emits JSON Lines and
`Shikigami.Log.Correlation` supplies durable run/call identifiers. Runtime composition roots
construct one logger, and worker loops, consumers, workflows, behavior providers, and sinks
use it. The remaining logging work is production HTTP request logging and graceful shutdown.

Metrics and worker tracing are wired. `Shikigami.Telemetry.Metrics` owns provider-free
instruments; the workers composition roots bracket providers and populate `AppEnv`, workflow
options, outbox/timer/scheduler options, counters, and the supervised sampler. Trace context now
crosses both sink-intent producer paths and the durable outbox into `sink.publish`, whose child
context is propagated by Kawa, Kizashi, Rei, and Danwa. The remaining telemetry surface is the
server provider lifecycle, safe request middleware, and supported graceful process shutdown in
M4.

Durable workflow constraints apply to the changes in `Shikigami.Agent` and `Shikigami.Flow`.
Capturing current trace context and threading process telemetry into Keiro options do not add,
remove, reorder, or rename workflow steps; under `docs/workflow-versioning.md` and ADR 0012,
they require no patch id. The two duplicated sink-intent wire records must remain byte-compatible
for historical rows; adding only the existing `IntegrationEvent` metadata leaves their JSON
payload unchanged and is covered by `Shikigami.WireCompatSpec`.


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

Scope: real instruments behind every hook that today gets `Nothing`, plus Shikigami's own
counters and gauges. First add a focused integration proof in the workers test suite: a metric
recorded through the 1.0.0.0 SDK is observed by an exporter after force-flush. This is a
regression test for provider construction and lifecycle, not a go/no-go API spike.

Create `shikigami-core/src/Shikigami/Telemetry/Metrics.hs` with provider-free instruments:

```haskell
data ShikigamiMetrics = ShikigamiMetrics
  { runsStarted :: !(Counter Int64),
    runsCompleted :: !(Counter Int64),
    runsFailed :: !(Counter Int64),
    runsRetried :: !(Counter Int64),
    runsDeadLettered :: !(Counter Int64),
    queueDepth :: !(Gauge Int64),
    consumerRecords :: !(Counter Int64)
  }

newShikigamiMetrics :: (MonadIO m) => Meter -> m ShikigamiMetrics
```

Instrument names are fixed by the Decision Log. Keep attributes low-cardinality: `agent.name`,
`trigger.kind`, `outcome`, and `topic`; never attach run ids, message ids, URLs, or error text to
metrics. Provide named recording functions so call sites do not manipulate raw instruments or
reconstruct attribute sets.

Replace `withRunTracer` in `shikigami-workers/src/Shikigami/Telemetry.hs` with:

```haskell
withRunTelemetry :: Text -> (Tracer -> Maybe KeiroMetrics -> ShikigamiMetrics -> IO a) -> IO a
```

The callback scope name is per process. With no `OTEL_EXPORTER_OTLP_ENDPOINT`, install no-op
providers but still construct `Just KeiroMetrics` and `ShikigamiMetrics`; callers never branch.
With an endpoint, initialize one global tracer provider and one global meter provider using the
SDK's standard `OTEL_*` parsing. The finalizer force-flushes and shuts down both providers.
Delete the transitional `withRunTracer` after all call sites move.

In the worker, scheduler, and subscription composition roots, construct `AppEnv` with the
returned tracer and Keiro metrics. Add `metrics :: !ShikigamiMetrics` to `WorkerEnv` and thread
the Keiro value into `publishClaimedOutbox`, `runWorkflowTimerWorker`, and scheduler paths.
Change `Shikigami.Workflow.Versioning.shikigamiWorkflowRunOptions` and
`shikigamiWorkflowResumeOptions` to derive the Keiro `tracer` and `metrics` options from
`AppEnv`; update the agent and conversation workflow calls without changing workflow steps.

Record run counters in `Shikigami.Agent.RunJob.Worker` according to the lifecycle semantics in
the Decision Log. Record consumer throughput after each decoded stream record reaches its
processor, with `topic` only. Add a supervised telemetry sampler loop at a 15-second cadence:
read total run-job depth with `Pgmq.Hasql.Sessions.queueMetrics`, record
`shikigami.queue.depth`, and call Keiro's `sampleOutboxBacklog`. A sampling error logs one
structured warning and the loop continues; it must never stop job processing.

Acceptance: with the collector running, one enqueued run yields `shikigami.runs.started` and
`shikigami.runs.completed` increments and a `shikigami.queue.depth` gauge report; keiro's
outbox instruments appear once sink intents flow. Unit tests pin instrument names, attributes,
run-outcome accounting, and sampling failure recovery.

### Milestone 3 — trace propagation end to end

Scope: every long-running workers command traced, and one connected trace across the outbox.
M2 already moves scheduler and subscriptions from `noopTracer` to `withRunTelemetry`, using
scope names `shikigami.scheduler`, `shikigami.consume-stream`, and
`shikigami.consume-events`.

At each sink-intent producer, call Keiro's released
`traceContextFromCurrentSpan :: MonadIO m => m (Maybe TraceContext)` while the producer span is
active. Pass the result into `sinkIntentEvent` and populate the existing
`IntegrationEvent.traceContext`. Apply the same change to
`Shikigami.Agent.Workflow` and `Shikigami.Flow.SinkOutbox`; keep their duplicated payload
records identical.

Add `Shikigami.Telemetry.TraceContext.withRemoteTraceContext` in core. It accepts Keiro's
public `TraceContext`, uses `hs-opentelemetry-propagator-w3c` to extract it into an OTel
`Context`, attaches that context only for the supplied action, and always restores the previous
context. Invalid remote context degrades to an unparented span and a structured warning rather
than failing publication.

In `publishSinkIntent`, reconstruct the stored parent and open `sink.publish` with consumer
span kind and the low-cardinality `sink.kind` attribute. Once that span is current, capture its
W3C context and add it to `SinkContext`; the outgoing request must carry the new child span,
not merely replay the producer's stored header. Extend plan 22's existing seam:

```haskell
postJSONWithHeaders :: (ToJSON a) => HttpEnv -> [Header] -> Text -> a -> IO (Either HttpFailure LBS.ByteString)
```

Represent propagated headers as `traceHeaders :: ![Header]` on `SinkContext`. Kawa, Kizashi,
Rei, and Danwa all consume those headers. The first three pass them directly to
`postJSONWithHeaders`; Danwa applies them through its dedicated request path without weakening
the existing host-scoped opaque authorization. Only `traceparent` and optional `tracestate`
are created; caller headers still cannot override content type or authorization.

Acceptance: the Postgres-level proof is a new test in
`shikigami-core/test/Shikigami/SinkDeliverySpec.hs` — run a workflow that enqueues a sink
intent under a real tracer, then assert `SELECT traceparent FROM keiro.keiro_outbox` is
non-null and starts with `00-`. The wire-level proof captures `traceparent` in a test-only
recording stub for each HTTP sink and proves the emitted header names are allowlisted. An
in-memory span exporter proves `sink.publish` has the stored producer span as its parent.

### Milestone 4 — provider lifetime and production request logging

Scope: make telemetry survive normal shutdown and make every served request observable without
creating a credential or memory leak.

Workers lifecycle is implemented in M2. Add the same bracketed tracer/meter ownership to
`Shikigami.Server.Boot`; the relevant executables are already built with `-threaded`.
Initialize and install global providers before constructing
`newOpenTelemetryWaiMiddleware`, pass the same tracer to application dependencies, and on
release stop accepting work, force-flush, then shut down tracer and meter providers. Preserve
the existing no-endpoint no-op behavior and keep standard `OTEL_*` parsing in the SDK.

Add `Shikigami.Server.RequestLog.requestLogMiddleware` in the server package. It emits exactly
one JSON line with UTC `time`, `method`, `path = rawPathInfo` (never the query string), numeric
`status`, monotonic `duration_ms`, optional lowercase `trace_id`/`span_id` read from the active
WAI request context, and the bounded `user_agent` allowlisted header. Truncate the decoded user
agent to 256 Unicode scalar values and mark truncation; do not log request/response bodies,
body sizes, `Authorization`, cookies, arbitrary headers, query values, or application error
details. Render the complete line before one handle write so concurrent requests cannot
interleave it. Exclude exact `/health/live` and `/health/ready` paths.

Compose middleware outside-in as
`otelMiddleware (requestLogMiddleware include (exceptionBoundary servantApp))`. The exception
boundary converts synchronous escaped exceptions to the standard RFC 7807 500 response while
rethrowing asynchronous exceptions; the request logger observes the actual status and never
invents a second renderer. `logStdoutDev` and `wai-extra`'s JSON formatter remain absent from
production boot.

Tests send bodies, query secrets, authorization/cookie headers, long user agents, successful
and failing responses, health probes, and an incoming `traceparent`. They assert one parseable
line per included request, exact field names, truncation, matching trace correlation, no planted
secret, no health lines, and correct middleware ordering. A shutdown test proves queued spans
and metrics are exported before provider teardown. A worker termination test reproduces the
old linked-thread crash, sends the supported graceful signal, and asserts a clean exit with no
GHC uncaught-exception dump.


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
cabal run shikigami-worker -- --config config/worker-observability-dev.yaml 2>worker.log &
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

M2 focused tests exercise instrument construction, force-flush, lifecycle decisions, and the
sampler without an external collector:

```bash
cabal test shikigami-workers-test --test-options='-p "telemetry|metrics|sampler"'
```

Expected: all matching tests pass, including the export-after-flush assertion. A manual OTLP
acceptance run may additionally point `OTEL_EXPORTER_OTLP_ENDPOINT` at any collector and
enqueue one job; its debug exporter then shows `shikigami.runs.started`,
`shikigami.runs.completed`, and `shikigami.queue.depth`.

M3 verification — the DB-level assertion, runnable without any collector:

```bash
cabal test shikigami-core-test --test-options='-p "traceparent"'
```

Expected: the new test case (named to match the pattern `traceparent`) passes, having asserted
a non-null `00-…` value in `keiro.keiro_outbox.traceparent`.

M4 request and shutdown verification:

```bash
cabal test shikigami-server-test --test-options='-p "request log|telemetry shutdown"'
cabal test shikigami-workers-test --test-options='-p "graceful shutdown"'
```

Expected: safe-field request logs parse as JSON, planted secrets are absent, health paths emit
nothing, telemetry is flushed, and the worker exits without a runtime exception dump.


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
all` green, so work can pause at any milestone boundary. M2 installs no-op providers when no
OTLP endpoint is configured, so instrumentation is always safe to retry without separate
call-site branches. M3's schema is untouched (the outbox
columns already exist), so no migration risk exists; if the `sink.publish` span or header
breaks a sink client, the header addition is behind `postJSONWithHeaders` and reverting to
`postJSON` restores the old wire behavior without touching the propagation of `traceContext`
into the outbox (independently useful and safe — keiro treats it as opaque).


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 36, 37, and 47. Target the hs-opentelemetry 1.0.0.0
family and verify exact source through Mori. Settei owns application telemetry policy, while
standard `OTEL_*` exporter variables remain SDK-owned. M1 logging may land early; HTTP trace
propagation waits for plan 22's canonical helper.


## Portfolio Reconciliation (2026-08-05)

Milestone 1 acquired a second consumer with a higher bar.
`docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md` hard-depends on M1 and consumes
**this plan's run and per-call correlation identifiers as durable audit evidence** — every model call
an attested run makes carries the Shikigami run id plus a unique call id, and retry and
parent/child relationships between calls are reconstructed from them. That plan is explicitly
forbidden from minting a parallel scheme, because an operator disputing a compliance verdict must be
able to join the audit record to the log line for the same call.

Two consequences for M1. The identifiers must be stable and reproducible for the life of a run
including across crash-and-resume, not merely unique within one process lifetime. And they are
effectively a persisted contract once plan 51 stores them, so changing their shape later is a
migration rather than a refactor — worth choosing deliberately now. `Shikigami.Log` did not exist in
the tree as of 2026-08-05, so this remains the gate for both plan 19 and plan 51.


## Interfaces and Dependencies

Hard dependencies: plans 22, 36, 37, and 47 are complete for the surfaces consumed here. The
server package owns request middleware and server provider lifecycle; workers own loop
telemetry and their provider lifecycle; core owns only provider-free instruments and context
propagation.

Selected released dependencies, verified 2026-08-23: hs-opentelemetry API/SDK/OTLP/WAI/W3C
1.0.0.0; Keiro 0.14.0.0; Kioku 0.5.0.0; Shibuya 0.9.0.0. Core adds direct
`hs-opentelemetry-propagator-w3c` for the narrow remote-parent bridge. Workers already depend
on the SDK and OTLP exporter. Server adds SDK, OTLP exporter, and WAI instrumentation. Keiro
provides `Keiro.Telemetry (KeiroMetrics, newKeiroMetrics, traceContextFromCurrentSpan)` and
`Keiro.Outbox (publishClaimedOutbox, sampleOutboxBacklog)`; PGMQ provides
`Pgmq.Hasql.Sessions.queueMetrics`; Kioku provides `Kioku.App (AppEnv (..))`. No logging
framework is added.

Signatures that must exist at the end of each milestone (full module paths):

- M1: `Shikigami.Log.Logger`, `Shikigami.Log.newStderrLogger :: Level -> IO Logger`,
  `Shikigami.Log.logEvent :: Logger -> Level -> Text -> [Data.Aeson.Types.Pair] -> IO ()`;
  `Shikigami.Workers.Config.WorkerEnv` gains `logger :: !Logger`;
  `Shikigami.Agent.Workflow.AgentRunDeps` gains `logger :: !Logger`.
- M2: `Shikigami.Telemetry.Metrics.ShikigamiMetrics`,
  `Shikigami.Telemetry.Metrics.newShikigamiMetrics :: (MonadIO m) => Meter -> m ShikigamiMetrics`,
  `Shikigami.Telemetry.withRunTelemetry :: Text -> (Tracer -> Maybe KeiroMetrics -> ShikigamiMetrics -> IO a) -> IO a`,
  `Shikigami.Workflow.Versioning.shikigamiWorkflowRunOptions :: AppEnv -> WorkflowRunOptions`,
  and `shikigamiWorkflowResumeOptions :: AppEnv -> NominalDiffTime -> WorkflowResumeOptions`.
  Consumed upstream signatures (verified against Keiro 0.14.0.0 on 2026-08-23):
  `newKeiroMetrics :: (MonadIO m) => Meter -> m KeiroMetrics`,
  `publishClaimedOutbox :: (IOE :> es, Store :> es) => ([OutboxRow] -> Eff es [(OutboxId, PublishOutcome)]) -> OutboxPublishOptions -> Maybe KeiroMetrics -> Eff es OutboxPublishSummary`,
  `runWorkflowTimerWorker :: (IOE :> es, Store :> es) => Maybe KeiroMetrics -> UTCTime -> (TimerRow -> Eff es (Maybe EventId)) -> Eff es (Maybe TimerRow)`,
  and `queueMetrics :: QueueName -> Session QueueMetrics`.
- M3: consume `Shikigami.Sink.Http.postJSONWithHeaders` and preserve plan 22's typed
  `HttpFailure` classification while adding trace propagation;
  `Shikigami.Sink.Types.SinkContext` gains `traceHeaders :: ![Header]`;
  `Shikigami.Telemetry.TraceContext.withRemoteTraceContext` consumes Keiro's public
  `TraceContext` through the released W3C propagator;
  `sinkIntentEvent` takes the trace context and sets
  `Keiro.Integration.Event.IntegrationEvent.traceContext :: Maybe TraceContext`.
- M4: `Shikigami.Server.RequestLog.requestLogMiddleware :: (Request -> Bool) -> Middleware`;
  the server composition root constructs OTel WAI middleware only after provider installation,
  nests the request logger inside it, and brackets tracer/meter flush and shutdown.

Cross-plan contracts (mirrored in the MasterPlan's Integration Points): Milestones 1 and 2
may proceed independently, but Milestone 3 has a hard milestone dependency on plan 22's
authenticated HTTP seam. The vocabulary defined
here (Decision Log, last entry) is what plans in MasterPlans 2-5 emit against; the new env/flag
surface (none beyond the standard `OTEL_*` family) must be
recorded in `docs/operations/configuration.md` owned by
`docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md`;
`docs/plans/29-health-liveness-and-worker-loop-supervision.md` will reuse `Shikigami.Log` for
its loop-supervision events (soft; this plan does not depend on it).


## Revision Notes

- 2026-08-23: Implemented Milestones 2 and 3 after the refresh. Added and wired all runtime
  metrics, provider lifecycle in workers, the supervised queue/outbox sampler, durable W3C
  capture, stored-parent continuation, the `sink.publish` consumer span, and trace headers for
  all four HTTP sinks. Focused in-memory and database/wire tests prove metric export, sampler
  isolation, non-null outbox `traceparent`, exact span parentage, context restoration, and all
  sink headers. The M3 database proof lives with sink delivery tests rather than the already
  very large agent workflow suite because it exercises enqueue, outbox storage, publication,
  span export, and downstream wire behavior as one delivery contract.

- 2026-08-23: Refreshed Milestones 2-4 before implementation. Reconciled the current
  seven-package boundary, marked prerequisite plans 22/36/37/47 satisfied, verified dependency
  versions against Mori source plus authoritative registries and upstream tags, replaced the
  physical PGMQ table query with the public queue-metrics API, parameterized the workflow
  options authority in the design, and recorded Keiro 0.14's missing public generic
  remote-parent continuation API. The revised design keeps providers in server/workers,
  permits one narrow core W3C continuation helper, and removes the obsolete metrics
  log-exposition fallback.

- 2026-08-05: Milestone 1 implemented. Progress items checked off with the two remaining
  M1-adjacent gaps stated explicitly (one-shot CLI commands by decision, the runtime's shutdown
  crash dump by deferral to M4). Recorded five discoveries — the pre-split paths this plan still
  names throughout, the `Control.Lens` `Level` collision, the `DuplicateRecordFields` selector
  ambiguity that M2 will hit again, the stderr write that hid from the obvious grep, and keiro's
  own unconvertible log lines — plus four decisions and the acceptance transcript. Milestones 2
  through 4 still quote pre-split paths and line numbers and must be re-pointed before starting;
  the corrected map is in Surprises & Discoveries.

- 2026-08-05: Added a Portfolio Reconciliation note recording that Milestone 1's run and per-call
  correlation identifiers become durable audit evidence for MasterPlan 10, which raises their bar:
  stable and reproducible across crash-and-resume, and a persisted contract once stored. No milestone
  scope changed; M1 remains the gate for both plan 19 and plan 51.

- 2026-07-22: Routed HTTP trace propagation through plan 22's authenticated
  `postJSONWithHeaders` helper. Milestones 1–2 remain independently implementable;
  Milestone 3 waits for plan 22 so auth and tracing compose on one request path.
- 2026-07-22: Added OTel lifecycle/flush and safe request-logging middleware ordering;
  made plans 36/37 hard prerequisites while leaving standard `OTEL_*` handling SDK-owned.
- 2026-07-22: Replaced hand-rendered W3C propagation with Keiro's public
  `traceContextFromCurrentSpan` bridge and specified the complete production request-log field,
  redaction, middleware, health-exclusion, and shutdown contract.
