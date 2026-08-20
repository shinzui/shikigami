---
id: 29
slug: health-liveness-and-worker-loop-supervision
title: "Health, liveness, and worker loop supervision"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tyx3yehmsq9eyywdcf5c7"
master_plan: "docs/masterplans/6-operations-and-observability-run-shikigami-as-a-real-service.md"
---

# Health, liveness, and worker loop supervision

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

**This plan was refreshed on 2026-08-19 against the delivered tree, and it got materially
smaller.** Its upstream blocker is discharged, roughly half of Milestone 1 has already shipped
inside another plan, and two of its starting-state claims are no longer true of the code. See the
Revision Note of 2026-08-19.


## Purpose / Big Picture

The `shikigami-worker` executable runs four concurrent loops — the run-job queue processor, the
keiro workflow-resume worker, the sink outbox publisher, and the keiro timer worker. They are
composed with nested `concurrently_` in
`shikigami-workers/src/Shikigami/Workers/Registry.hs:41-46`. Three of the four can still die, or
wedge, while the process stays alive and looks fine.

The resume loop is the worst of them: `runResumeWorker`
(`shikigami-workers/src/Shikigami/Agent/Workflow/Resume.hs:36-42`) calls keiro's resume worker
*once*, and on a `Left` store error it logs one line and returns — permanently. There is no
surrounding `forever`. From that moment on, no suspended workflow in the process is ever resumed
again, and nothing anywhere says so. The outbox publisher
(`shikigami-workers/src/Shikigami/Flow/SinkOutbox/Publisher.hs:36-52`) and the timer worker
(`shikigami-workers/src/Shikigami/Trigger/Timer.hs:32-41`) each `forever` { do one pass; log a
`Left`; sleep a second }, which is right for a transient store fault and wrong for a programming
exception — any exception their bodies throw escapes into `concurrently_` and takes the process
down, which is actually the behaviour we want, but nothing distinguishes that from a clean exit.
The queue processor runs under shibuya's `IgnoreFailures` strategy
(`Registry.hs:72`), which by definition never restarts or propagates a failed child; if it stops,
`waitApp` returns, `runQueueWorker` falls through to `pure ()` (`Registry.hs:84`), and the
remaining three loops keep running around a corpse.

A silently dead loop means runs stop being resumed, sinks stop being delivered, or timers stop
firing — with no signal to any operator or supervisor. And while the HTTP server now answers
`GET /health/live` and `GET /health/ready`, its liveness check is "we answered the request" and
its readiness check is an empty list (`shikigami-server/src/Shikigami/Health/Handler.hs:58-67`).
No worker-role process serves a probe at all, so there is nothing for process-compose, systemd,
or a load balancer to poll for the loops that do the actual work.

After this plan, three things are true.

Each loop records a heartbeat timestamp when it makes progress, and the worker-role processes
serve the same `GET /health/live` and `GET /health/ready` contract the server already serves —
using the released external `servant-health` package directly, so no worker package acquires a
dependency on a Shikigami sibling. `/health/live` returns 200 only when every loop's heartbeat is
recent; `/health/ready` returns 200 only when PostgreSQL is reachable. Kafka and downstream HTTP
services are deliberately not readiness dependencies: an outage there must not cascade by removing
otherwise healthy pods.

Any loop's death terminates the process with a non-zero exit, so a supervisor restarts a clean
process rather than letting a partial one limp.

And the server's own readiness check stops being a placeholder.

These endpoints are what
`docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md` wires its
readiness probes to.

The user-visible proof: start the worker, `curl -s localhost:8091/health/live` returns 200 with
`{"status":"ok","check":"all","failingSince":null}`; point the process at an unreachable Postgres
and watch `/health/ready` return 503 naming the failed `postgres` check and when it began failing;
and fault-inject a loop crash and watch the whole process exit non-zero instead of limping along
with a dead loop.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-19) Prerequisite audit. Plans 36, 37, 47, and 53 have landed; plan 28's Milestone 1
      (`Shikigami.Log`) has landed, so the "soft dependency" on structured logging is now a real
      module every loop already uses; plan 17 has landed through Milestone 4; plan 18's Kafka
      reconnect work has landed.
- [x] (2026-08-19) Citation audit. Every `shikigami-core/src/Shikigami/Worker.hs:NN` pointer in
      this plan referred to a file plan 36 deleted. All are re-resolved against
      `shikigami-workers/`; see Context and Orientation.
- [x] (2026-08-19) **Upstream prerequisite discharged in substance.** Shibuya IR-1 asked for two
      things and both are now available from released packages: `shibuya-core 0.9.0.0` exports a
      public non-blocking processor snapshot, and `servant-health 0.1.0.0` is a released external
      probe surface a worker executable may depend on directly. Evidence in Surprises &
      Discoveries; the residual ask is recorded there too.
- [x] (2026-08-19, delivered by plan 36) **M1, server half.** `Shikigami.Health.Api`
      (`shikigami-api/src/Shikigami/Health/Api.hs`) mounts `servant-health`'s `HealthApi` under
      `health` on the umbrella route; `Shikigami.Health.Handler`
      (`shikigami-server/src/Shikigami/Health/Handler.hs`) builds the two checks once at boot with
      failure-onset tracking, an outside-in probe timeout, and exception containment;
      `Shikigami.Server.Boot.newServerEnvWith` injects them for the conformance test; the OpenAPI
      artifact is generated from the served proxy by the `shikigami-openapi` executable and
      checked in at `docs/api/openapi.json`.
- [x] (2026-08-20) M1 (server): readiness pings PostgreSQL through the pool `runServer` now
      brackets around the listener. The ping itself is `Shikigami.Health.Ping.databaseReachable`
      in `shikigami-core`, shared with the worker probe because neither package may depend on the
      other. `ServerRole` gained `database.connection_string` as a required key.
- [x] (2026-08-20) M1 (workers): `shikigami-workers/src/Shikigami/Health/Worker.hs` owns the
      loop-name type, the heartbeat registry, the checks, and the Warp listener, and depends on
      `servant-health`/`servant-server`/`warp` and no Shikigami sibling. All four worker-role
      executables serve it via `serveProbesWith`. Proved by `servant-health:testkit`'s
      conformance suite plus eleven liveness cases in `Shikigami.Health.WorkerSpec`.
- [x] (2026-08-20) M1 (config): `health.port` declared, with `defaultHealthPort` holding the
      per-role table 8091–8094 and `healthPortFor` applying it.
- [x] (2026-08-20) M2: the outbox, timer, and scheduler loops beat at the bottom of each pass;
      `loopLivenessAt` reports the first stale loop in `LoopName` order and dates `failingSince`
      at the threshold crossing rather than the observation.
- [x] (2026-08-20) M2: the queue processor reports through shibuya's `ProcessorMetrics` via
      `supervisedLoopVerdict`, registered once `runQueueWorker` holds the `Master`. **Both**
      consumers do the same rather than beating per record — see Surprises & Discoveries for why
      the plan's per-record heartbeat would have failed an idle topic.
- [x] (2026-08-20) M2: readiness pings PostgreSQL through the process's real pool on every worker
      role; Kafka and downstream HTTP are not consulted.
- [x] (2026-08-20) M3: `Shikigami.Workers.Supervision.superviseLoops` replaces the nested
      `concurrently_`. Any loop ending — by throwing or by returning — cancels the siblings and
      propagates, so the process exits non-zero. Proven by four cases in
      `Shikigami.Workers.SupervisionSpec` over injected loop actions rather than by a private
      fault-injection hook on `WorkerEnv`; see the Decision Log.
- [x] (2026-08-20) M3: `runResumeWorker` restarts its runner with capped backoff
      (1s→30s, ceiling 5) and exits with `LoopExited ResumeLoop` once exhausted. A run that lasted
      long enough resets the tally. The plan's premise about this loop was wrong — see Surprises &
      Discoveries.
- [x] (2026-08-20) M3: `runQueueWorker` logs the full shibuya metrics map and throws
      `LoopExited QueueLoop` when `waitApp` returns, instead of falling through to `pure ()`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **(Review-time, 2026-07-22)** The six-package standard forbids `shikigami-workers` from
  depending on `shikigami-api` or `shikigami-server`, so the original idea of importing the
  service route tree into every worker executable was architecturally impossible.

- **(2026-08-19, refresh) Shibuya IR-1 is discharged in substance, and this plan is no longer
  blocked.** The IR is `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-1`, "Expose a
  public worker probe contract", still `status: proposed`. It asked for two separable things.

  Its first ask — "a narrow public probe/snapshot contract for a running `App`… distinguish at
  least not-started, healthy/running, stopping, stopped, and unexpected loop exit/failure, and
  include enough stable identity to attribute the failed worker… reading it must be non-blocking"
  — is satisfied by `shibuya-core 0.9.0.0`. `Shibuya.App` exports `getAppMetrics :: AppHandle es
  -> Eff es MetricsMap`, `getAllMetrics`/`getAllMetricsIO`, and
  `getProcessorMetrics`/`getProcessorMetricsIO`, keyed by `ProcessorId`
  (`shibuya-core/src/Shibuya/App.hs:12-39`). `ProcessorMetrics` carries
  `{state, stats, batch, startedAt}` and `ProcessorState` is
  `Idle | Processing !InFlightInfo !UTCTime | Failed !Text !UTCTime | Stopped`
  (`shibuya-core/src/Shibuya/Core/Metrics.hs:94-103,179-190`). That is a non-blocking read
  distinguishing running, idle, failed-with-reason-and-time, and stopped, attributed by processor
  id. It is exactly what M2's queue-loop heartbeat needs, and it is better than a heartbeat
  callback because it reports *last activity* rather than *last time we remembered to call `beat`*.

  Its second ask — an injectable generic WAI `probeApplication` in `shibuya-metrics` — is moot
  rather than satisfied. `servant-health 0.1.0.0` is published on Hackage
  (`mori://shinzui/servant-health`; the repository already consumes it from `shikigami-api`,
  `shikigami-server`, and `shikigami-client`). It is an *external* package, not a Shikigami
  sibling, so a worker executable depending on it violates nothing in the six-package standard —
  which was the entire reason the IR routed the request through shibuya. The worker probe can be
  built today.

  What remains genuinely un-provided upstream: nothing this plan needs. Leave the IR open — a
  generic probe application still belongs in shibuya for consumers that do not want servant — but
  stop treating it as this plan's gate.

- **(2026-08-19, refresh) `Shikigami.Log` exists, so the loop-lifecycle events this plan wanted
  to add are already structured.** Plan 28's Milestone 1 landed. Every loop already emits JSON
  lines through it: `worker.loop.started` (`Workers/Registry.hs:43`), `worker.queue.reconciled`
  (`Registry.hs:64-69`), `worker.queue.failed` (`Registry.hs:82`), `worker.loop.failed`
  (`Registry.hs:77`), `worker.resume.started`/`worker.resume.failed`
  (`Agent/Workflow/Resume.hs:38,41`), `worker.outbox.started`/`worker.outbox.failed`
  (`Flow/SinkOutbox/Publisher.hs:38,50`), `worker.timer.started`/`worker.timer.failed`
  (`Trigger/Timer.hs:34,39`). The MasterPlan's IP-B ("soft consumption, not a compile dependency")
  is now a plain fact: use the logger, do not invent a second one.

- **(2026-08-19, refresh) The Kafka consumer no longer dies on a `KafkaError`, so this plan's
  2026-07-22 readiness rationale needs correcting rather than repeating.** Plan 18's work landed
  (commits `bb13a23`, `b1f2a60`, and `docs/adr/0009-kafka-offsets-advance-only-after-durable-dispositions.md`).
  `runSubscription` (`shikigami-workers/src/Shikigami/Trigger/Consumer.hs:153-209`) is now a
  `reconnect backoffSeconds` loop with capped exponential backoff (`min 30 (backoffSeconds * 2)`),
  logging `<prefix>.consumer.reconnecting` and retrying, and it distinguishes three outcomes: a
  Kafka error retries, a configuration error fails loudly, and a captured programming failure is
  rethrown. The *conclusion* of the old decision is unchanged and still right — Kafka stays out of
  readiness — but the reason "the loop currently dies on any `KafkaError`" is no longer true.

- **(2026-08-20, implementation) The plan's consumer heartbeat would have failed an idle topic,
  so both consumers report through shibuya instead.** M2 specified beating "after each successful
  record disposition ... and also on each reconnect attempt". A consumer on a quiet topic does
  neither: it holds one connection and processes no records, so it would have gone stale after
  60 seconds and failed liveness for having no work — the exact false positive the staleness
  bounds were chosen to avoid. The plan's own M2 text anticipated this ("beat on each poll
  *attempt* rather than only on work"), but the poll is inside shibuya's Kafka adapter and
  shikigami has no hook there.

  What shibuya does expose is the same thing the queue loop uses. `runSubscription` already runs
  its processor under `Shibuya.runApp` with `ProcessorId streamTopic`, so a consumer waiting on a
  quiet topic reports `Idle` — healthy — and one stuck on a record reports `Processing info
  lastActivity` with a `lastActivity` that stops advancing. `supervisedLoopVerdict` therefore
  serves both loop families, and `Consumer.hs` gained one narrow callback
  (`type OnSupervisor = Maybe (Master, ProcessorId) -> IO ()`) that reports what it has rather
  than what it means; `Subscription.hs` translates. Between connections there is no supervisor to
  ask, so the loop falls back to a heartbeat beaten on each reconnect attempt — which is what
  keeps a broker outage looking like a loop retrying rather than a loop wedged.

  This also improved the queue loop beyond what the plan asked for. `Processing` is not by itself
  good news: a record in flight for ten minutes is a wedge, so `processorStateVerdict` treats a
  `Processing` whose `lastActivity` is past the loop's bound as unhealthy. A bare state check
  would have called it healthy.

- **(2026-08-20, implementation) The server acquired a required database key.** Giving
  `/health/ready` a real PostgreSQL ping means a server with no connection string can never report
  ready. `roleRequiredKeys ServerRole` therefore gained `database.connection_string`, so the
  failure is a named key at configuration time rather than a process that binds a socket and then
  fails every probe forever. `AppConfigSpec`'s precedence helper — which deliberately used the
  role with no required keys — moved to `AdminRole`.

- **(2026-08-20, implementation) The Postgres ping could not live in either probe owner.**
  `shikigami-server` and `shikigami-workers` both answer `/health/ready` and neither may depend on
  the other, so a shared definition has to sit in `shikigami-core`. But core cannot depend on
  `servant-health`, which pulls in `servant-server`, and `Shikigami.PackageArchitectureSpec`
  fails the build when the domain library links HTTP route execution. `Shikigami.Health.Ping`
  therefore stops at `databaseReachable :: Pool -> IO Bool` plus the operator-facing check name,
  and each probe owner wraps that in its own `boolCheck`.

- **(2026-08-20, implementation) The resume loop's headline defect was not what the plan said,
  and the correct fix is narrower.** The plan calls `runResumeWorker` "the worst of them": it
  "calls keiro's resume worker *once*, and on a `Left` store error it logs one line and returns —
  permanently ... There is no surrounding `forever`."

  There is a `forever` — it is one level down.
  `Keiro.Workflow.Resume.runWorkflowResumeWorkerWith` (keiro's
  `keiro/src/Keiro/Workflow/Resume.hs:675-684`) is itself
  `forever $ do resumeWorkflowsOnce ... \`catchError\` logPass \`catchSync\` logPass;
  threadDelay (pollInterval opts)`. A transient store error during a pass is caught by keiro,
  logged as `ResumePassFailed`, and the loop continues. It never reached shikigami's `Left` arm.

  What does reach that arm is a failure of the runner *as a whole* — the store resource failing
  to acquire, for instance — returned as `Left` by `runAppIO`. That case was exactly as bad as
  the plan described: one log line, a return, and three loops running on with nothing resuming
  workflows. A `Right ()` return is equally wrong, because a `forever` loop returning normally
  means something ended it.

  So the fix is restart-with-backoff around the whole runner rather than around a single pass,
  and both return shapes are treated as "the runner stopped".

- **(2026-08-20, implementation) The resume loop cannot have a heartbeat, so it is covered by
  fail-fast alone.** Because its passes happen inside keiro's `forever`, shikigami never gets
  control per pass. The one hook available, `WorkflowResumeOptions.logEvent`, receives only
  `ResumeLogEvent` values, and every constructor is a failure — `ResumeUnknownName`,
  `ResumeTransientError`, `ResumeWorkflowCrashed`, `ResumeCrashRecordSkipped`,
  `ResumeWorkflowMarkedFailed`, `ResumePassFailed`. There is no per-pass success event to beat
  on, so a healthy quiet resume loop would beat nothing and a registered staleness bound would
  fail liveness on a perfectly working loop. `ResumeLoop` is therefore deliberately absent from
  every heartbeat registry. Its coverage is complete anyway: the only way the loop can stop is by
  returning, and returning now exits the process. A per-pass success event in keiro would let
  this loop join the others; that is a reasonable upstream ask but not one this plan needs.

- **(2026-08-20, implementation) The first PostgreSQL ping reported every healthy database as
  unreachable, and only a live probe caught it.** `databaseReachable` decoded `select 1` as
  `int8`. The literal `1` is `int4`, so the decode failed, `Pool.use` returned `Left`, and the
  check reported `postgres` down against a database that was up and accepting connections. Every
  unit test passed throughout: the conformance kit injects its own checks, so nothing in the
  suite ever ran this query. It surfaced on the first `curl` — `/health/live` 200 and
  `/health/ready` 503 with Postgres demonstrably running. Fixed by running the ping through
  `Hasql.Session.script`, which cannot collect a result: a ping that names its own column types
  can be wrong about them; one that reads nothing cannot.

- **(2026-08-20, implementation) A worker cannot serve a 503 for its own database, because losing
  Postgres kills it.** The plan's user-visible proof was "point the process at an unreachable
  Postgres and watch `/health/ready` return 503". A worker pointed at a dead database does not
  start at all — `Kiroku.Store.Connection.withStore` starts a notifier that connects eagerly and
  throws `NotifierStartError`. And a worker whose database dies *while running* exits within
  about a second, by the fail-fast path below. So the worker's readiness check only ever reports
  a partial fault (pool exhaustion, a refused connection against a live server), not a dead
  database.

  The 503 is demonstrable on the server, which runs no loops and therefore survives the outage.
  Verified live: `/health/ready` went 200 → 503 with `"check":"postgres"`, `/health/live` stayed
  200 throughout — the two probes are genuinely independent — and `failingSince` was byte-for-byte
  identical across probes four seconds apart, which is the failure tracker reporting onset rather
  than observation.

- **(2026-08-20, implementation) Fail-fast was proved by a real fault, not just by the unit
  test.** Killing PostgreSQL under a running `shikigami-worker` produced exactly the designed
  chain: the shibuya processor stopped, `waitApp` returned cleanly (the silent-death hole),
  `worker.queue.stopped` was logged, `LoopExited QueueLoop` was thrown, `superviseLoops` cancelled
  the three siblings, and the process exited `1`. Before this plan the same fault would have
  fallen through to `pure ()` and left three loops running around a dead queue processor.

  One honest limitation: the `worker.queue.stopped` line logged `"processors":{}`. Shibuya clears
  its metrics map on master shutdown, so when the whole supervisor goes the states are already
  gone. The line still earns its place — a failed processor under a master still standing does
  populate it, and an empty map is itself the signal that the whole supervisor went — but it is
  not the rich diagnostic the plan imagined for this particular path. The code comment says so.

- **(2026-08-20, implementation) The consumer's supervisor-report design was verified past the
  point where the plan's design would have failed.** `shikigami-consume-stream` pointed at an
  unreachable broker held `/health/live` and `/health/ready` at 200 for 100 seconds — well past
  the 60-second consumer staleness bound at which a per-record heartbeat would have gone stale
  and had the pod restarted for a fault it could not fix. Kafka being unreachable changed neither
  probe, which is the blast-radius property the readiness decision was made for.

- (Findings from implementation go below this line.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Adopt fail-fast at the process boundary (any loop death exits the process non-zero),
  with bounded restart-with-backoff only *inside* individual loops for transient errors.
  Rationale: shibuya offers no processor-level restart — its only two strategies are
  `IgnoreFailures` and `StopAllOnFailure`
  (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/src/Shibuya/App.hs:89-98`),
  neither of which restarts a failed child; shibuya's retry story is per-message, not per-loop.
  The four loops are combined with `concurrently_`, which already propagates an exception from any
  branch by cancelling the others — but the loops currently swallow their errors before
  `concurrently_` can see them. The simplest correct supervisor is therefore: let a genuinely dead
  loop throw, let `concurrently_` tear the process down, and let the external supervisor
  (process-compose `restart: on_failure`, systemd `Restart=always`, both defined by
  `docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md`) restart
  a clean process. Restart-with-backoff *per loop* is added only for the resume loop's transient
  store errors, because a momentary connection blip should not cause a full cold restart; a
  persistent failure still trips the backoff ceiling and exits. Alternative rejected: in-process
  per-loop restart supervision — more code, duplicates what an external supervisor does better,
  and risks masking a genuine fault as an infinite restart loop.
  Date: 2026-07-08
  Re-verified 2026-08-19: `SupervisionStrategy` at `shibuya-core 0.9.0.0` is still exactly
  `IgnoreFailures | StopAllOnFailure` (`Shibuya/App.hs:89-98`). The rationale stands unchanged.
  The composition point moved from `Shikigami/Worker.hs:70` to
  `shikigami-workers/src/Shikigami/Workers/Registry.hs:44-46`, and it is still nested
  `concurrently_`.

- Decision: Host the typed health routes with Warp in plan 36's server package rather than
  representing health as an OTLP-only signal.
  Rationale: probes require a pull-based HTTP GET. Warp is the server runtime beneath the typed
  Servant API; route declaration and dispatch remain in `NamedRoutes`, not a parallel handwritten
  WAI application.
  Date: 2026-07-08
  Status 2026-08-19: **done.** `Shikigami.Server.Boot.runServer` binds Warp and serves
  `shikigamiApplication`; there is no handwritten health router anywhere.

- Decision: Health is part of the typed server API: `NamedRoutes`, terminal `MultiVerb` with
  handwritten `AsUnion`, and OpenAPI generated by a dedicated executable from the exact served
  proxy. No handwritten WAI dispatcher is permitted.
  Rationale: server behavior, status variants, schema, and contract tests must share one route
  tree. Health response bodies are the deliberate exception to RFC 7807 because probe clients
  require a small stable status document.
  Date: 2026-07-22
  Status 2026-08-19: **done, and by a better route than this plan imagined.** Rather than
  hand-writing the `MultiVerb` union in `shikigami-api`, plan 36 adopted `servant-health`, which
  owns `HealthApi`, `ProbeResponses`, `ProbeResult`, the `AsUnion` instance, `ProbeStatus` with a
  non-orphan `ToSchema` derived from the same `Options` value as its codec, and a `testkit`
  sublibrary for conformance. `Shikigami.Health.Api` is a thin re-export that gives the fleet type
  a Shikigami-owned name. Do not reinstate a hand-written union.

- Decision: Health routes are the standard exact `GET /health/live` and `GET /health/ready`,
  unauthenticated, redirect-free, excluded from production request logs, and returning only
  documented 200/503 variants. OTel metrics and Kubernetes/systemd events remain the probe-failure
  observability surfaces. Other JSON API errors use RFC 7807 `application/problem+json`.
  Rationale: probes must be cheap and deterministic while the rest of the API retains a uniform
  machine-readable error contract.
  Date: 2026-07-22
  Status 2026-08-19: paths and exemption are done —
  `Servant.Health.Paths` supplies `healthMountSegment`, `liveRawPath`, `readyRawPath`, and
  `healthRawPaths`, and `Shikigami.Health.Api`'s header records the RFC 7807 exemption and why.
  Request-log exclusion belongs to plan 28's request-logging work and is not yet done.

- Decision: The HTTP server and worker roles expose the same standard probe wire contract through
  different package owners, and worker-role executables never import `shikigami-api` or
  `shikigami-server`.
  Rationale: the six-package architecture deliberately prevents workers from acquiring a sibling
  HTTP application dependency.
  Date: 2026-07-22
  **Amended 2026-08-19: the owner changed, the boundary did not.** The 2026-07-22 form of this
  decision named `shibuya-metrics` as the worker-side owner and made a released Shibuya probe
  application a hard prerequisite. That is no longer the cheapest correct answer.
  `servant-health 0.1.0.0` is a released *external* package; `shikigami-workers` depending on it —
  together with `servant-server` and `warp` — introduces no sibling dependency and satisfies the
  boundary exactly as intended, while giving both process families the identical route type,
  identical wire body, and identical conformance testkit rather than two implementations of one
  contract. The worker probe therefore lives in `Shikigami.Health.Worker` inside
  `shikigami-workers` and serves `servant-health`'s `HealthApi` on its own listener. Shibuya IR-1
  stays open on its merits for non-servant consumers, but it is no longer this plan's gate.

- Decision: Both 200 and 503 use the standard strict `ProbeStatus` document with direct fields
  `status`, `check`, and `failingSince`. A passing probe is `("ok", "all", Nothing)`; a failing
  probe is `("failed", <stable-check-name>, Just <first-failure-time>)`.
  Rationale: a probe is a status report rather than an RFC 7807 error, but operators still need
  the failed check and the start of the incident. Detailed loop ages belong in metrics, not an
  expanding probe payload.
  Date: 2026-07-22
  Status 2026-08-19: **done, and owned upstream.** `Servant.Health.ProbeStatus` is exactly those
  three fields with `probeJsonOptions = defaultOptions` driving both the codec and the schema.
  `ProbeVerdict = Healthy | Unhealthy {failedCheck, since}` is the check seam.

- Decision: Heartbeats are per-loop `IORef UTCTime` timestamps updated on each successful
  iteration; `/health/live` fails a loop whose heartbeat is older than a per-loop staleness bound.
  Rationale: a boolean "alive" flag cannot distinguish a wedged loop (blocked forever inside one
  iteration) from a healthy idle loop. A timestamp does, and the outbox and timer loops already
  iterate on a 1-second `threadDelay`, giving a natural heartbeat cadence. Staleness bounds are
  generous multiples of each loop's expected period so an idle-but-healthy loop is not flagged.
  Date: 2026-07-08
  Amended 2026-08-19 for the queue loop only. The three `forever` loops keep the `IORef UTCTime`
  design; their `threadDelay 1_000_000` bottoms are still the natural beat points
  (`Flow/SinkOutbox/Publisher.hs:52`, `Trigger/Timer.hs:41`, and the scheduler's
  `Workers/Command/Scheduler.hs:57`). The queue processor does **not** get a threaded `beat`
  callback: shibuya already tracks its own liveness, and `getAppMetrics` on the `AppHandle` that
  `runJobWorkers` returns gives `ProcessorState` with a `Processing … lastActivity` timestamp and
  a `Failed err ts` variant. Reading that is strictly more truthful than a callback, because a
  callback reports when shikigami last remembered to call it and the metrics report what the
  processor actually did. It also removes the awkward question of where to hook `beat` inside
  `jobProcessorWithContext`.

- Decision: `/health/ready` does not check Kafka or downstream HTTP services.
  Rationale (2026-07-22, corrected 2026-08-19): a broker outage cannot be repaired by restarting
  this pod, so making it readiness-critical would amplify an upstream outage across the fleet.
  The original rationale also said the consume loop dies on any `KafkaError` and that in-loop
  recovery belonged to plan 18; plan 18 has landed and the loop now reconnects with capped
  backoff (`Trigger/Consumer.hs:153-209`), so that half of the reasoning is obsolete. The
  conclusion is unchanged and now rests only on the blast-radius argument, which is the stronger
  one anyway. Consumer-loop death is still surfaced through the in-process heartbeat and
  fail-fast supervision.
  Date: 2026-07-22, amended 2026-08-19


- Decision: Prove fail-fast with injected loop actions rather than a fault-injection hook on
  `WorkerEnv`.
  Rationale: the plan specified "a private test hook that makes one loop body `throwIO` after N
  iterations". Extracting `superviseLoops :: Log.Logger -> [(LoopName, IO ())] -> IO ()` reaches
  the same proof without putting a test seam on a production record — a test supplies whatever
  loop actions it wants, including throwing and returning ones. It is also a better design
  independently: the nested `concurrently_` it replaced had no name, no place to log which loop
  died, and no way to treat a clean return as fatal. The same reasoning produced
  `runResumeLoopWith` (the retry policy over an injected runner and sleeper),
  `loopLivenessAt` (the liveness verdict at an injected instant), and `processorStateVerdict`
  (the supervisor-state mapping without a running supervisor). All four are ordinary parameters,
  not flags, so no production path can select test behavior.
  Date: 2026-08-20

- Decision: Both Kafka consumers report liveness through shibuya's `ProcessorMetrics` rather than
  beating per record, and a `Processing` state whose `lastActivity` is past the loop's bound is
  unhealthy.
  Rationale: a consumer on a quiet topic processes no records, so the plan's per-record heartbeat
  would have gone stale and failed liveness for having no work. Shibuya reports that consumer as
  `Idle`, which is the honest answer. Reading the supervisor also catches the opposite error a
  bare state check would miss: `Processing` is not by itself good news, since a record in flight
  for ten minutes is a wedge. `Consumer.hs` gained one narrow callback
  (`type OnSupervisor = Maybe (Master, ProcessorId) -> IO ()`) reporting what it has rather than
  what that means, so the acknowledgement boundary keeps no health vocabulary; `Subscription.hs`
  translates. Between connections the loop falls back to a heartbeat beaten on each reconnect
  attempt, which keeps a broker outage looking like a loop retrying.
  Date: 2026-08-20

- Decision: The PostgreSQL ping lives in `shikigami-core` as `Shikigami.Health.Ping`, stopping at
  `IO Bool` rather than producing a `ProbeCheck`.
  Rationale: `shikigami-server` and `shikigami-workers` both answer `/health/ready` and neither
  may depend on the other, so one definition of "reachable" has to sit in core. But core cannot
  depend on `servant-health`, which pulls in `servant-server`, and
  `Shikigami.PackageArchitectureSpec` fails the build when the domain library links HTTP route
  execution. Each probe owner wraps the `Bool` in its own `boolCheck` under the shared operator-
  facing name `postgres`.
  Date: 2026-08-20

- Decision: `roleRequiredKeys ServerRole` gains `database.connection_string`.
  Rationale: giving `/health/ready` a real PostgreSQL ping means a server with no connection
  string can never report ready. Failing at configuration time with a named key beats a process
  that binds a socket and then fails every probe forever. `AppConfigSpec`'s precedence helper,
  which deliberately used the role with no required keys, moved to `AdminRole`.
  Date: 2026-08-20

- Decision: `health.port` is declared optional with a per-role default table
  (`defaultHealthPort`) rather than a single Settei `withDefault`.
  Rationale: the four worker processes routinely run on one host, so a shared default would make
  three of them fail to bind; and one `Config AppConfig` declaration cannot express four
  role-dependent defaults. Roles with no probe listener of their own map to `Nothing`, so
  `shikigami-server` keeps answering on its `http.port` listener instead of opening a second
  socket.
  Date: 2026-08-20


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

All shikigami paths are repository-relative to `/Users/shinzui/Keikaku/bokuno/shikigami`.
Dependency sources are given as absolute paths into the local checkouts so the reader can open
them; the canonical references are `mori://shinzui/shibuya`, `mori://shinzui/servant-health`, and
`mori://shinzui/keiro`.

### Terms

A **loop** is one of the long-running `IO ()` actions a worker-role process runs concurrently,
each an infinite iteration over a unit of substrate work. A **probe** is an HTTP GET a supervisor
polls. **Liveness** answers "is this process still working?" and its failure means restart the
process. **Readiness** answers "can this process serve traffic right now?" and its failure means
take it out of load balancing but leave it running. Collapsing them into one route throws that
distinction away, which is why there are two and no combined one.

### The package layout, and what moved

`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md` split the
repository into seven packages and **deleted `shikigami-core/src/Shikigami/Worker.hs` and the
whole `shikigami-cli` package**. Every `Worker.hs:NN` citation in the 2026-07-08 draft of this
plan pointed at that file. The current map:

| Was | Is now |
|---|---|
| `Worker.hs:67-70` (`runWorker`, four loops) | `shikigami-workers/src/Shikigami/Workers/Registry.hs:41-46` (`runWorkers`) |
| `Worker.hs:72-84` (`runQueueWorker`) | `Workers/Registry.hs:52-84` |
| `Worker.hs:86-101` (`runResumeWorker`) | `shikigami-workers/src/Shikigami/Agent/Workflow/Resume.hs:36-42` |
| `Worker.hs:103-112` (`runOutboxPublisher`) | `shikigami-workers/src/Shikigami/Flow/SinkOutbox/Publisher.hs:36-52` |
| `Worker.hs:114-123` (`runTimerWorker`) | `shikigami-workers/src/Shikigami/Trigger/Timer.hs:32-41` |
| `shikigami-cli/.../ConsumeStream.hs` | `shikigami-workers/src/Shikigami/Trigger/Consumer.hs` plus the `shikigami-consume-stream` and `shikigami-consume-events` executables |
| `shikigami-cli/.../Scheduler.hs` | `shikigami-workers/src/Shikigami/Workers/Command/Scheduler.hs` and `Shikigami/Trigger/Scheduler.hs` |
| `shikigami-core/src/Shikigami/Sink/KawaStub.hs` | `shikigami-server/src/Shikigami/Sink/KawaStub.hs` |

`shikigami-workers` builds four executables: `shikigami-worker`, `shikigami-scheduler`,
`shikigami-consume-stream`, and `shikigami-consume-events`
(`shikigami-workers/shikigami-workers.cabal:74-107`). Each is a separate process and each needs
its own probe listener.

### What already exists for health

`docs/plans/36-...` did not stop at moving files; it shipped the probe surface this plan's
Milestone 1 was going to build. Read these three files before writing anything:

`shikigami-api/src/Shikigami/Health/Api.hs` is a thin re-export module. It gives Shikigami-owned
names to `servant-health`'s `HealthApi`, `ProbeResponses`, `ProbeResult`, `ProbeStatus`,
`probeJsonOptions`, `ProbeCheck`, `ProbeVerdict`, and the path constants
(`healthMountSegment`, `liveRawPath`, `readyRawPath`, `healthRawPaths`). Its header explains why
there are two routes and why probe bodies are exempt from
`Shikigami.Api.Problem`'s RFC 7807 rule — worth reading, because the same reasoning governs the
worker probe.

`shikigami-server/src/Shikigami/Health/Handler.hs` decides what healthy *means*, and it already
bakes in three things that are easy to get silently wrong. Every check is wrapped in `safeCheck`,
so an exception escaping a check becomes a probe report naming the failed dependency instead of a
500 with a stack trace. `withProbeTimeout` sits *outside* `safeCheck` on liveness, because the
timeout interrupts with an asynchronous exception and `safeCheck` deliberately lets those through
— nested the other way round, a deadlocked process would hang its liveness probe instead of
failing it. And each probe gets its own `newFailureTracker`, so `failingSince` reports when a
failure began rather than when it was last observed, which is why the checks are built once at
boot and stored in the environment rather than rebuilt per request. **The worker probe must
reproduce all three.**

`shikigami-server/src/Shikigami/Server/Boot.hs:46-66` builds the checks at boot
(`newServerEnv`) and offers `newServerEnvWith` so the conformance test can fail liveness and
readiness independently — that indirection exists because both probe routes have the same handler
type, so an umbrella record that swapped them would still compile.

What is *not* done: `readinessCheck = sequenceChecks []`
(`Health/Handler.hs:67`). Its Haddock calls the empty list "the extension point". The server holds
no database handle at all — `ServerEnv` is `{config, appConfig, liveness, readiness}`
(`shikigami-server/src/Shikigami/Server/Seam.hs:44-49`) — so adding the PostgreSQL ping means
adding a pool to `ServerEnv` and opening it in `newServerEnv`.

### `servant-health`

Pinned at `0.1.0.0`, canonical `mori://shinzui/servant-health/packages/servant-health` (local
checkout `/Users/shinzui/Keikaku/bokuno/servant-health`), and already a dependency of `shikigami-api`,
`shikigami-server` (including `servant-health:testkit` in its test stanza), and
`shikigami-client`.

`Servant.Health` exports the wire contract (`ProbeStatus {status, check, failingSince}`,
`probeJsonOptions`), the check seam (`type ProbeCheck = IO ProbeVerdict`,
`ProbeVerdict = Healthy | Unhealthy {failedCheck, since}`), the routes (`HealthApi`,
`ProbeResponses`, `ProbeResult`), and the server (`healthServer`, `runProbe`).
`Servant.Health.Check` exports `boolCheck`, `sequenceChecks`, `safeCheck`, `withProbeTimeout`, and
`newFailureTracker`. The `testkit` sublibrary keeps `tasty`, `warp`, and `http-client` out of
production builds.

### Shibuya's processor snapshot

Pinned at `shibuya-core 0.9.0.0`, local checkout
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

`Shibuya.App` exports `runApp`, `waitApp`, `stopApp`, `stopAppGracefully`, `ShutdownConfig`,
`SupervisionStrategy (IgnoreFailures | StopAllOnFailure)`, `AppHandle`, `getAppMetrics`,
`getAppMaster`, `getAllMetrics`, `getAllMetricsIO`, `getProcessorMetrics`,
`getProcessorMetricsIO`, `ProcessorId`, and `ProcessorMetrics`
(`shibuya-core/src/Shibuya/App.hs:2-40`).

```haskell
-- shibuya-core/src/Shibuya/Core/Metrics.hs:94-103, 179-190
data ProcessorState
  = Idle
  | Processing !InFlightInfo !UTCTime   -- in-flight info, last activity
  | Failed !Text !UTCTime               -- error message, timestamp
  | Stopped

data ProcessorMetrics = ProcessorMetrics
  { state     :: !ProcessorState,
    stats     :: !StreamStats,
    batch     :: !BatchStats,
    startedAt :: !UTCTime
  }

type MetricsMap = Map ProcessorId ProcessorMetrics
```

`getAppMetrics :: (IOE :> es) => AppHandle es -> Eff es MetricsMap` (`Shibuya/App.hs:261-262`).

The queue loop reaches this because `Keiro.PGMQ.runJobWorkers` is a thin wrapper over
`Shibuya.App.runApp`: its type is
`SupervisionStrategy -> Int -> [Eff es (ProcessorId, QueueProcessor es)] -> Eff es (Either AppError (AppHandle es))`
(`/Users/shinzui/Keikaku/bokuno/keiro/keiro-pgmq/src/Keiro/PGMQ/Job.hs:767-775`), and
`runQueueWorker` already binds the handle as `Right app` before calling `waitApp app`
(`Workers/Registry.hs:75-79`).

### The four loops as they stand

`runWorkers` (`Workers/Registry.hs:41-46`):

```haskell
runWorkers env = do
  Log.logInfo (envLogger env) "worker.loop.started" ["queue" Aeson..= ("shikigami_run_jobs" :: Text)]
  concurrently_
    (runQueueWorker env)
    (concurrently_ (runResumeWorker env) (concurrently_ (runOutboxPublisher env) (runTimerWorker env)))
```

`runQueueWorker` (`Registry.hs:52-84`) is the one plan 17 improved. It reconciles the main queue
and its policy-enabled DLQ with `ensureJobQueue runJob`, refusing to start unless both are
available, and it already converts two failure modes into `ioError`: a processor that fails to
start (`:76-78`) and a reconciliation failure (`:81-83`). The remaining hole is `Right () -> pure
()` at `:84` — a clean return from `waitApp` under `IgnoreFailures` is a silent death, and it
falls straight through.

`runResumeWorker` (`Agent/Workflow/Resume.hs:36-42`) calls
`runWorkflowResumeWorkerWith (shikigamiWorkflowResumeOptions runTimeout) (workflowRegistry env)`
once. `Left err` logs `worker.resume.failed` and returns. `Right ()` returns. There is no loop.

`runOutboxPublisher` (`Flow/SinkOutbox/Publisher.hs:36-52`) and `runTimerWorker`
(`Trigger/Timer.hs:32-41`) are each `forever { one pass; log a Left; threadDelay 1_000_000 }`.
Both headers say a store error is logged and the loop continues because the rows and timers are
durable — that reasoning is right and this plan preserves it; what it adds is that a *non*-store
exception must not be swallowed.

The consumers (`Trigger/Consumer.hs:153-209`) reconnect with capped exponential backoff and
rethrow captured programming failures. The scheduler
(`Workers/Command/Scheduler.hs:51-57`) is a single `forever` timer pass with a 1-second delay.

### Configuration

`docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md` landed. One resolved
`Shikigami.App.Config.AppConfig` reaches every process; command modules read no environment and
define no precedence. `Role` is
`ServerRole | AdminRole | WorkerRole | SchedulerRole | StreamConsumerRole | EventConsumerRole |
RunBehaviorRole | AgentRunRole | MigrateRole` (`Shikigami/App/Config.hs:724-734`).

A `Port` newtype exists, range-checked at decode time by `mkPort`/`portDecoder`
(`Shikigami/App/Config.hs:143-158,464-479`), with `portNumber` to hand a listener the plain
number. `http.port` is a stable key defaulting to `Port 8080`
(`Shikigami/App/Config.hs:320,611`). **`health.port` does not exist yet** — this plan adds it.

### Relevant ADRs

- `docs/adr/0009-kafka-offsets-advance-only-after-durable-dispositions.md` — why the consumer's
  acknowledgement path is shaped the way it is. Read it before touching `Trigger/Consumer.hs`; the
  heartbeat this plan adds must not move where an offset is committed.
- `docs/adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md` — the package-boundary
  reasoning that also governs which packages a worker may depend on.

No ADR covers process supervision or probe ownership. If the fail-fast boundary decision survives
implementation, it is durable project context and should be promoted to a new ADR during the
distillation pass.


## Plan of Work

### Milestone 1 — finish the probe surface

Scope: one probe contract, served by every process role. The server half exists; this milestone
gives it a real readiness check and gives the four worker-role executables the same two routes.

**The server's readiness check.** Add a `Hasql.Pool.Pool` to `ServerEnv`
(`shikigami-server/src/Shikigami/Server/Seam.hs:44-49`), open it in `newServerEnv`
(`Shikigami/Server/Boot.hs:46-49`) from the resolved `AppConfig`'s database settings, and replace
`sequenceChecks []` (`Health/Handler.hs:67`) with one check that runs `select 1` through it. Name
the check `postgres` — the name appears verbatim in the 503 body, so it is an operator-facing
string. Keep it inside `safeCheck "readiness"`, and keep `withProbeTimeout` off readiness: a slow
database should report 503 through the check's own failure, not be interrupted by an asynchronous
exception the tracker cannot attribute.

`mkHealthChecks` currently takes no arguments; it becomes
`mkHealthChecks :: Pool -> IO (ProbeCheck, ProbeCheck)`. Thread the pool from `newServerEnv`, not
from a handler.

**The worker probe.** Create `shikigami-workers/src/Shikigami/Health/Worker.hs` — a concept
vertical, not a bare cross-cutting `Shikigami.Health` technical module. It owns the loop-name
type, the heartbeat registry (M2), and the small Warp application that serves `servant-health`'s
`HealthApi`. Add `servant-health`, `servant-server`, and `warp` to
`shikigami-workers/shikigami-workers.cabal`, and `servant-health:testkit` to its test stanza. Add
**no** dependency on `shikigami-api` or `shikigami-server`; the package-boundary test in
`shikigami-api-test` exists to catch that and should be extended to cover the reverse direction if
it does not already.

Reproduce the three hardening decisions from `Shikigami.Health.Handler` verbatim — `safeCheck`
inside, `withProbeTimeout` outside on liveness only, one `newFailureTracker` per probe built once
at boot. The temptation to skip them because "it is only a worker" is exactly how a wedged process
ends up passing its own liveness probe.

Each worker-role executable runs the probe application concurrently with its work. Its readiness
action is a PostgreSQL ping through the real application pool the process already holds
(`StoreConnection.pool st` in `Workers/Command/Worker.hs:52`), so readiness reflects the same
connection path the work uses. Do not add Kafka metadata fetches or downstream HTTP calls.

**The port.** Add `health.port` to `Shikigami.App.Config` following exactly the pattern
`httpPortSetting`/`httpPortKey` establishes (`Shikigami/App/Config.hs:320,464-479,611`), with
per-role defaults so the four processes coexist on one host: 8091 worker, 8092 scheduler, 8093
stream consumer, 8094 event consumer. The server keeps serving health on its existing `http.port`
listener; it does not open a second socket. Thread the validated port through each composition
root.

**Acceptance.** `cabal test all` passes, including a new worker-probe test using
`servant-health:testkit` that asserts exact `GET /health/live` → 200 with the passing body and,
with a check forced to fail, → 503 naming the check. Start the worker and
`curl -sS -o /dev/null -w '%{http_code}\n' localhost:8091/health/live` prints `200`; with Postgres
up, `/health/ready` prints `200`.

### Milestone 2 — real heartbeats and real readiness

Scope: make `/health/live` reflect actual loop progress rather than "the process answered".

Define in `Shikigami.Health.Worker` a `LoopName` sum covering the loops each role runs
(`ResumeLoop`, `OutboxLoop`, `TimerLoop`, `ConsumerLoop`, `SchedulerLoop`), a strict registry
with direct fields, and exactly two exported operations: `beat :: LoopName -> IO ()` and
`loopLivenessCheck :: ProbeCheck`. Consumers accept the narrow `beat` callback, never an HTTP or
server type.

Call `beat` at the bottom of each `forever` body, before the `threadDelay`:
`Flow/SinkOutbox/Publisher.hs:52`, `Trigger/Timer.hs:41`, `Workers/Command/Scheduler.hs:57`. For
the consumers, beat after each successful record disposition inside `runSubscription`
(`Trigger/Consumer.hs:167-176`) — being careful not to move where the offset is committed, per
`docs/adr/0009-...` — and also on each reconnect attempt, so a broker outage keeps the loop
visibly alive while it retries rather than looking wedged. For the resume loop, beat after each
`runWorkflowResumeWorkerWith` return once M3 has made it a loop.

The queue processor gets no `beat` call. Instead, `loopLivenessCheck` reads the shibuya
`AppHandle` that `runQueueWorker` holds and derives the queue loop's verdict from
`ProcessorMetrics`: `Failed err ts` is unhealthy with `failingSince = ts` and the error in the
log (not in the probe body — the body carries only the check name); `Stopped` is unhealthy; `Idle`
and `Processing _ lastActivity` are healthy. This requires passing the handle out of
`runQueueWorker` into the registry, which is a small change to `Workers/Registry.hs` and worth it
for the honesty gained.

The liveness check deterministically selects the *first* stale loop in a fixed order, reports a
stable name such as `loop.outbox`, and sets `failingSince` to the instant its last heartbeat
crossed the threshold — not the moment of observation. It never performs network or database IO.

Set each staleness bound relative to that loop's cadence. The outbox, timer, and scheduler loops
poll every second, so a 10-second bound flags a wedged loop quickly without false positives. The
consumers and the queue processor may idle legitimately when there is no work, so give them
longer bounds — 60 seconds — and beat on each poll *attempt* rather than only on work, because
the empty-poll heartbeat is the honest "loop is alive" signal. Record which choice each loop got
and why.

**Acceptance.** With the worker idle, `/health/live` stays 200 for at least two minutes. A test
that forces one loop's heartbeat stale returns 503 with `check = "loop.outbox"` and the exact
threshold-crossing `failingSince`. Pointing the worker at an unreachable Postgres makes
`/health/ready` return 503 naming `postgres`. Stopping Kafka does not change readiness.

### Milestone 3 — fail-fast supervision and bounded loop retry

Scope: make a genuinely dead loop take the process down, and make the resume loop tolerate a
transient store blip.

**Stop swallowing fatal errors.** The outbox and timer loops keep retrying `StoreError`s — that
is deliberate and their headers explain why — but any *other* exception must propagate out of
`forever` so `concurrently_` (`Workers/Registry.hs:44-46`) cancels the siblings and `runWorkers`
throws. Today the `case result of Left err -> log` arms only catch the `Either StoreError` the
effect runner returns, so this is mostly already true; verify it with a test rather than assuming
it, because an added `catch` anywhere in the chain would silently undo it.

**Close the queue processor's silent-death hole.** `runQueueWorker` (`Registry.hs:75-84`) treats a
return from `waitApp` as success. Under `IgnoreFailures` a stopped processor is a silent death, so
re-throw a `LoopExited QueueLoop` exception instead of falling through to `pure ()`. Before
throwing, read `getAppMetrics` and log which processor stopped and in what state — that is the one
line an operator will want.

**Make the resume loop a loop.** Convert `runResumeWorker`
(`Agent/Workflow/Resume.hs:36-42`) from run-once-and-return into a bounded retry: on a `Left`
store error, log `worker.resume.failed` as it does now, sleep a backoff interval (start 1 s, cap
30 s, reset on success), beat the heartbeat registry, and retry; past a ceiling count of
consecutive failures, throw `LoopExited ResumeLoop` to trip fail-fast. A clean return (no more
work) simply loops again after a short delay, exactly like the outbox and timer loops. Note that
this changes the loop's relationship to `shikigamiWorkflowResumeOptions`' lease TTL, which plan 17
sized above the behavior timeout — do not shorten the backoff below the point where a retry could
contend with a lease the previous pass still holds.

**Prove it by fault injection.** Construct `WorkerEnv` with a private test hook that makes one
loop body `throwIO (userError "fault-injected loop death")` after N iterations. Do not add a
production flag and do not read an environment variable — plan 37 removed every environment read
and this must not reintroduce one. Run that composition under an `async`, assert it terminates
with `LoopExited`, and separately exercise the packaged binary under the external supervisor's
restart policy.

**Acceptance.** A fault-injected loop death exits the process non-zero (visible as `echo "exited
$?"` printing non-zero, and as a process-compose restart when run under the stack). A transient
store error in the resume loop is retried with backoff and does not exit. A persistent one exits
after the ceiling.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shikigami` inside the Nix dev shell. A bare
`cabal build all` outside it fails at link with `ld: library not found for -lrdkafka`.

```bash
nix develop
just create-database
```

Build and unit-test the probe surface (M1):

```bash
cabal build all
cabal test all
```

Expected: the server and worker test suites pass. Their probe tests use `servant-health:testkit`
to assert exact `GET /health/live` → 200 and, with a check forced to fail, → 503, needing no
external socket.

Probe a live worker (M1/M2). The `--config` file is a Settei source; see plan 37's configuration
surface for its shape.

```bash
cabal run shikigami-worker -- --config config/worker-health.yaml &
sleep 3
curl -sS -o /dev/null -w '%{http_code}\n' localhost:8091/health/live
curl -sS localhost:8091/health/ready | jq .
```

Expected:

```text
200
{
  "status": "ok",
  "check": "all",
  "failingSince": null
}
```

Readiness failure (M2) — point the worker at an unreachable Postgres and re-probe:

```bash
cabal run shikigami-worker -- --config config/worker-health-broken-db.yaml &
sleep 3
curl -sS -o /dev/null -w '%{http_code}\n' localhost:8091/health/ready
```

Expected:

```text
503
```

Fail-fast (M3) — run the private test-harness injection:

```bash
cabal test shikigami-workers-test --test-options='--pattern "loop failure cancels siblings"'
```

Expected:

```text
1 test passed
```

Every commit while working on this plan carries both trailers:

```text
ExecPlan: docs/plans/29-health-liveness-and-worker-loop-supervision.md
Intention: intention_01kx1tyx3yehmsq9eyywdcf5c7
```


## Validation and Acceptance

Acceptance is observable behavior.

1. **Liveness.** `curl -s -o /dev/null -w '%{http_code}' localhost:8091/health/live` prints `200`
   for a healthy worker and the body is the passing `ProbeStatus`. Injecting a stale heartbeat
   yields `503` with the stable loop check name and the threshold-crossing `failingSince`. A
   shibuya processor in the `Failed` state yields `503` for the queue loop without any heartbeat
   being involved.
2. **Readiness.** `/health/ready` returns `200` when PostgreSQL is reachable and `503` naming
   `postgres` otherwise, on both the server and every worker role. Kafka and downstream HTTP
   outages do not flip readiness.
3. **Fail-fast.** A fault-injected loop death exits the whole process with a non-zero status. A
   transient store error in the resume loop is retried with backoff and does not exit; a
   persistent one exits after the ceiling.
4. **The silent-death hole is closed.** A test that stops the shibuya app out from under
   `runQueueWorker` makes the process exit rather than continue with three loops.
5. **Package boundary.** `shikigami-workers` depends on `servant-health` and on no Shikigami
   sibling API or server package; the boundary test proves it.
6. **API contract.** Only exact unauthenticated GETs succeed on both listeners; 200/503 bodies
   conform to the artifact generated from the served proxy; no handwritten WAI route exists;
   non-health JSON errors still use RFC 7807.
7. **Regression.** `cabal build all` and `cabal test all` pass; all four worker executables and the
   server still start and do their existing work; health ports are configurable and their defaults
   are distinct so the whole stack runs on one host.


## Idempotence and Recovery

The endpoints are read-only and safe to poll at any frequency. Nearly every change is additive —
a new concept-vertical module in `shikigami-workers`, one new Settei setting, a pool added to
`ServerEnv`, extra `concurrently_` branches — except M3's change to loop error handling, which is
the point of the plan. Each milestone leaves `cabal test all` green, so work can stop at a
milestone boundary.

Two specific recoveries are worth naming. If the fail-fast change proves too aggressive in
practice — a loop that legitimately returns misread as a death — the fix is local: widen what
counts as a clean return for that loop, in that loop's module. It does not affect the probe server
or the heartbeats. And if reading `ProcessorMetrics` for the queue loop turns out to be awkward to
thread out of `runQueueWorker`, fall back to the original design (a threaded `beat` callback
inside the job handler) and record the reason in the Decision Log; the probe contract does not
change either way.

A health listener binding to a busy port fails loudly at boot, which is the desired behaviour;
distinct per-role defaults plus the Settei `health.port` override are what avoid the collision in
the first place. No database or schema change is owned by this plan, so there is nothing to roll
back on the data side.


## Interfaces and Dependencies

**Hard dependencies, all landed:** plans 36 and 37. Plan 28's Milestone 1 (`Shikigami.Log`) has
landed and is now a real dependency rather than a soft one — emit loop-lifecycle and fail-fast
events through it. Plan 17 has landed and shaped `runQueueWorker`; do not undo its queue and DLQ
reconciliation while adding supervision. Plan 18 has landed and shaped the consumer's reconnect
loop; the heartbeat must not move where an offset is committed.

**No blocking upstream prerequisite.** Shibuya IR-1
(`mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-1`) remains open on its merits but is
not this plan's gate; see Surprises & Discoveries.

**Libraries.** `servant-health 0.1.0.0` (`Servant.Health`, `Servant.Health.Check`,
`Servant.Health.Paths`, and `servant-health:testkit` for tests) — new to `shikigami-workers`,
already present in `shikigami-api`, `shikigami-server`, and `shikigami-client`. `servant-server`
and `warp` — new to `shikigami-workers`, already present in `shikigami-server`. `shibuya-core
0.9.0.0` (`Shibuya.App`: `getAppMetrics`, `ProcessorId`, `ProcessorMetrics`, `ProcessorState`,
`SupervisionStrategy`, `waitApp`) — already a transitive dependency via `keiro-pgmq`.
`hasql`/`hasql-pool` for the readiness ping — already present.

**Signatures that must exist at the end**, with full paths:

```haskell
-- shikigami-server/src/Shikigami/Health/Handler.hs (changed)
mkHealthChecks :: Pool -> IO (ProbeCheck, ProbeCheck)

-- shikigami-server/src/Shikigami/Server/Seam.hs (changed)
data ServerEnv = ServerEnv
  { config    :: !ServerConfig,
    appConfig :: !AppConfig,
    pool      :: !Pool,          -- new: what readiness pings
    liveness  :: !ProbeCheck,
    readiness :: !ProbeCheck
  }

-- shikigami-workers/src/Shikigami/Health/Worker.hs (new)
data LoopName = QueueLoop | ResumeLoop | OutboxLoop | TimerLoop | ConsumerLoop | SchedulerLoop
data LoopExited = LoopExited !LoopName        -- Exception instance

newHeartbeats     :: [LoopName] -> IO Heartbeats
beat              :: Heartbeats -> LoopName -> IO ()
loopLivenessCheck :: Heartbeats -> Maybe (AppHandle es) -> ProbeCheck
postgresReadiness :: Pool -> ProbeCheck
runProbeListener  :: Port -> ProbeCheck -> ProbeCheck -> IO ()

-- shikigami-core/src/Shikigami/App/Config.hs (extended)
healthPortKey     :: Key                       -- stableKey "health.port"
-- with per-role defaults 8091 worker / 8092 scheduler / 8093 stream / 8094 events
```

**Cross-plan contracts** (mirrored in MasterPlan 6's Integration Points).
`docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md` consumes
`/health/live`, `/health/ready`, and the `http.port`/`health.port` settings as its process-compose
`http_get` probes and systemd health configuration, and owns
`docs/operations/configuration.md`, which must gain the `health.port` row.
`docs/plans/28-structured-logging-metrics-and-trace-propagation.md` owns the observability
vocabulary (IP-A) and the request-log exclusion of the two health paths; the loop-lifecycle and
fail-fast events this plan emits follow its `component.subject.verb` naming and reuse the existing
`worker.*` event names rather than inventing parallel ones.
`docs/plans/18-atomic-stream-consumption-offsets-inbox-and-enqueue-in-one-boundary.md` owns the
consumer's acknowledgement boundary; this plan adds a heartbeat beside it and moves nothing.
`docs/plans/30-operator-cli-inspect-runs-agents-dead-letters-and-cancel.md` gives an operator the
inspection verbs that answer "why is it unhealthy" once a probe says it is.


## Revision Notes

- 2026-07-22: Rebased on plans 36/37 and completed the API pass: typed `NamedRoutes`/`MultiVerb`,
  same-proxy OpenAPI, health-specific status documents, RFC-7807 non-health errors, exact probe
  behavior, Settei ports, and request-log exclusion.

- 2026-07-22: Aligned probe paths and readiness semantics with the API standard: `/health/live`,
  `/health/ready`, and no Kafka/downstream readiness dependency.

- 2026-08-19: **Full refresh against the delivered tree.** Superseded by this note: the 2026-07-30
  "Portfolio Reconciliation" section, which named Shibuya IR-1 as a blocker.

  *Why the refresh was needed.* `docs/architecture/implementation-order.md` records a standing
  requirement to audit a plan's citations immediately before implementing it, and names this plan
  among the 19 open plans citing `shikigami-core/src/Shikigami/Worker.hs` — a file plan 36
  deleted. Every `Worker.hs:NN` pointer in this plan was wrong. All are re-resolved, and Context
  and Orientation now carries the was/is table so a reader who finds an old citation elsewhere can
  translate it.

  *The blocker is gone.* Shibuya IR-1 asked for two things. `shibuya-core 0.9.0.0` delivers the
  first — a public, non-blocking `ProcessorMetrics` snapshot distinguishing idle, processing with
  last-activity, failed with reason and time, and stopped, keyed by `ProcessorId`. The second, a
  generic WAI probe application, is moot: `servant-health 0.1.0.0` is a released *external*
  package, so a worker executable depending on it introduces no sibling dependency — which was the
  whole reason the request was routed through shibuya. The IR stays open on its merits; it is no
  longer this plan's gate, and the "Upstream prerequisite" progress item is closed.

  *Half of Milestone 1 already shipped.* Plan 36 delivered `Shikigami.Health.Api`,
  `Shikigami.Health.Handler`, `newServerEnvWith`, and the generated OpenAPI artifact, by adopting
  `servant-health` instead of hand-writing the `MultiVerb` union this plan specified. The plan now
  records that as done, names the three hardening decisions already baked into the handler
  (`safeCheck` inside, `withProbeTimeout` outside on liveness, one failure tracker per probe) as
  requirements the worker probe must reproduce, and reduces the server-side remainder to one
  concrete gap: `readinessCheck = sequenceChecks []`, which is empty because `ServerEnv` holds no
  pool.

  *Two starting-state claims were no longer true.* The Kafka consumer does not die on a
  `KafkaError` any more — plan 18 gave it capped exponential reconnect — so the readiness decision
  was re-argued on blast radius alone, which was always the stronger half of it. And the queue
  processor is no longer a bare `runApp`; plan 17 made it reconcile the queue and its DLQ and
  already converts two failure modes into `ioError`, leaving one hole (`waitApp` returning
  cleanly) rather than three.

  *One design change.* The queue loop's heartbeat is no longer a `beat` callback threaded into
  the job handler. It reads shibuya's own `ProcessorMetrics` instead, which reports what the
  processor actually did rather than when shikigami last remembered to call a function, and which
  reports a `Failed` state with its error and timestamp that no callback could report at all.

  *One addition.* `Shikigami.Log` landed with plan 28's Milestone 1, so every loop already emits
  structured lifecycle events. MasterPlan 6's IP-B is no longer a soft consumption; the plan now
  lists the existing event names so this work extends them rather than inventing a parallel set.
