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


## Purpose / Big Picture

Shikigami's `worker` command runs four concurrent loops — the pgmq queue processor, the keiro
workflow-resume worker, the keiro outbox publisher, and the keiro timer worker
(`shikigami-core/src/Shikigami/Worker.hs:70`). Today any one of them can die while the process
stays alive and healthy-looking: the queue processor runs under shibuya's `IgnoreFailures`
strategy (`Worker.hs:78`), which explicitly does not restart or propagate a failed processor;
the resume loop returns permanently on the first store error (`Worker.hs:98-101`, no retry
loop); and the outbox and timer loops catch every error, log it, and spin again
(`Worker.hs:110,121`). A silently dead loop means runs stop being resumed, sinks stop being
delivered, or timers stop firing — with no signal to any operator or supervisor. There is no
HTTP health endpoint anywhere in the runtime; nothing can be probed by process-compose,
systemd, or a load balancer.

After this plan, each loop records a heartbeat timestamp when it makes progress, and the
plan-36 server package exposes typed Servant `NamedRoutes` for exact `GET /health/live` and
`GET /health/ready`, and any loop's death terminates the process with a non-zero exit so
a supervisor restarts it. `/health/live` returns 200 only when the process is up and every
loop's heartbeat is recent; `/health/ready` returns 200 only when PostgreSQL is reachable.
Kafka and downstream HTTP services are deliberately not readiness dependencies: an outage
there must not cascade by removing otherwise healthy pods. These endpoints are what
`docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md` wires
its readiness probes to.

The user-visible proof: start the worker, `curl -s localhost:8091/health/live` returns 200 with
`{"status":"ok","check":"all","failingSince":null}`; point the process at an unreachable
Postgres and watch `/health/ready` return 503 naming the failed `postgres` check and when it
began failing; and fault-inject a loop crash and watch the whole process exit non-zero (which
under process-compose or systemd triggers a restart) instead of limping along with a dead loop.


## Progress

- [ ] Upstream prerequisite: a released `shibuya-metrics` probe surface exposes injectable
      `ProbeCheck`s through exact `NamedRoutes`/terminal `MultiVerb` `/health/live` and
      `/health/ready` routes, the standard `ProbeStatus` wire shape, and same-proxy OpenAPI;
      verify the release through Mori, Hackage, and upstream tags before selecting bounds.
- [ ] M1: the Shikigami server extends its plan-36 umbrella API with the same exact health
      contract; worker-role executables use the released Shibuya probe surface without a
      dependency on `shikigami-api` or `shikigami-server`.
- [ ] Prerequisites: plans 36/37 and the upstream Shibuya probe contract complete;
      server/API ownership and Settei port settings are settled.
- [ ] M1: plan 36's dedicated OpenAPI executable regenerates from the extended served API
      proxy; artifact and response-schema conformance checks pass.
- [ ] M2: each worker loop records a heartbeat through the worker registry on each successful
      iteration; the worker-role liveness check reports the first stale loop and its
      `failingSince` timestamp.
- [ ] M2: readiness checks wired — PostgreSQL ping for every DB-backed process;
      `/health/ready` returns 503 when that required dependency is unreachable, without
      probing Kafka or downstream HTTP services.
- [ ] M3: fail-fast supervision — any loop's termination (normal or exceptional) tears down the
      siblings and exits the process non-zero; proven by fault injection.
- [ ] M3: the resume loop's permanent-return-on-store-error (`Worker.hs:98-101`) converted to a
      restart-with-backoff iteration so a transient store blip does not require a full process
      restart, while a persistent failure still surfaces via `/health/live` staleness and (after the
      backoff ceiling) fail-fast.


## Surprises & Discoveries

- (Review-time) The six-package standard forbids `shikigami-workers` from depending on
  `shikigami-api` or `shikigami-server`, so the original idea of importing the service route
  tree into every worker executable was architecturally impossible. Mori showed that the
  current `shibuya-metrics` already owns worker HTTP health serving, but its implementation is
  a handwritten `pathInfo` router, accepts paths without an exact-method guard, and returns
  older `alive`/`ready` bodies rather than the standard `ProbeStatus`. This plan therefore
  requires an additive released Shibuya probe API before consuming it; it does not punch a
  forbidden sibling dependency through plan 36.


## Decision Log

- Decision: Adopt fail-fast at the process boundary (any loop death exits the process
  non-zero), with bounded restart-with-backoff only *inside* individual loops for transient
  errors.
  Rationale: shibuya offers no processor-level restart — its only two strategies are
  `IgnoreFailures` and `StopAllOnFailure`
  (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/src/Shibuya/App.hs:89-98`),
  neither of which restarts a failed child; shibuya's retry story is per-message
  (`AckRetry`/`RetryDelay`), not per-loop. The four loops are combined with `concurrently_`
  (`Worker.hs:70`), which already propagates an exception from any branch by cancelling the
  others — but the loops currently swallow their errors before `concurrently_` can see them.
  The simplest correct supervisor is therefore: let a genuinely dead loop throw, let
  `concurrently_` tear the process down, and let the external supervisor (process-compose
  `restart: on_failure`, systemd `Restart=always`—both defined by
  `docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md`)
  restart a clean process. Restart-with-backoff *per loop* is added only for the resume loop's
  transient store errors, because a momentary connection blip should not cause a full cold
  restart; a persistent failure still trips the backoff ceiling and exits. Alternative rejected:
  in-process per-loop restart supervision (a home-grown supervisor tree) — more code, duplicates
  what an external supervisor does better, and risks masking a genuine fault as an infinite
  restart loop.
  Date: 2026-07-08

- Decision: Host the typed health routes with Warp in plan 36's server package rather than
  representing health as an OTLP-only signal.
  Rationale: probes require a pull-based HTTP GET. Warp is the server runtime beneath the
  typed Servant API; route declaration and dispatch remain in `NamedRoutes`, not a parallel
  handwritten WAI application.
  Date: 2026-07-08
- Decision: Health is part of the typed server API: `NamedRoutes`, terminal `MultiVerb`
  with handwritten `AsUnion`, and OpenAPI generated by a dedicated executable from the
  exact served proxy. No handwritten WAI dispatcher is permitted.
  Rationale: server behavior, status variants, schema, and contract tests must share one
  route tree. Health response bodies are the deliberate exception to RFC 7807 because
  probe clients require a small stable status document.
  Date: 2026-07-22
- Decision: Health routes are the standard exact `GET /health/live` and `GET /health/ready`,
  unauthenticated, redirect-free, excluded from
  production request logs, and return only documented 200/503 variants. OTel metrics and
  Kubernetes/systemd events remain the probe-failure observability surfaces.
  Other JSON API errors use RFC 7807 `application/problem+json`.
  Rationale: probes must be cheap and deterministic while the rest of the API retains a
  uniform machine-readable error contract.
  Date: 2026-07-22

- Decision: The HTTP server and worker roles expose the same standard probe wire contract
  through different package owners. `shikigami-server` serves `Shikigami.Health.Api` from the
  plan-36 umbrella route. Worker-role executables consume a released injectable probe
  application from external `shibuya-metrics`; they never import the sibling
  `shikigami-api` or `shikigami-server` packages. The upstream route must use exact
  `NamedRoutes`/terminal `MultiVerb` dispatch and derive its own OpenAPI artifact from its
  served proxy.
  Rationale: the six-package architecture deliberately prevents workers from acquiring a
  sibling HTTP application dependency. Shibuya already owns worker metrics and health
  serving, so completing that public surface upstream preserves the package boundary while
  still applying the API standard to every process role.
  Date: 2026-07-22

- Decision: Both 200 and 503 use the standard strict `ProbeStatus` document with direct fields
  `status`, `check`, and `failingSince`. A passing probe is `("ok", "all", Nothing)`; a
  failing probe is `("failed", <stable-check-name>, Just <first-failure-time>)`.
  Rationale: a probe is a status report rather than an RFC 7807 error, but operators still
  need the failed check and the start of the incident. Detailed loop ages belong in metrics,
  not an expanding probe payload.
  Date: 2026-07-22

- Decision: Heartbeats are per-loop `IORef UTCTime` timestamps updated on each successful
  iteration; `/health/live` fails a loop whose heartbeat is older than a per-loop staleness bound.
  Rationale: a boolean "alive" flag cannot distinguish a wedged loop (blocked forever inside one
  iteration) from a healthy idle loop. A timestamp does, and the outbox/timer loops already
  iterate on a 1-second `threadDelay` (`Worker.hs:112,123`), giving a natural heartbeat cadence;
  the queue processor's cadence is shibuya's poll interval. Staleness bounds are generous
  multiples of each loop's expected period so an idle-but-healthy loop is not flagged.
  Date: 2026-07-08

- Decision: `/health/ready` does not check Kafka or downstream HTTP services. Consumer-loop
  failure is surfaced through the in-process heartbeat and fail-fast supervision instead.
  Rationale: the consume loop currently dies on any `KafkaError`
  (`shikigami-core/src/Shikigami/Trigger/Consumer.hs:84-87` and `:111-114` — the error is logged
  and the loop returns), and the proper fix (reconnect/backoff, atomic offset+inbox+enqueue)
  belongs to
  `docs/plans/18-atomic-stream-consumption-offsets-inbox-and-enqueue-in-one-boundary.md`
  (MasterPlan 3). This plan makes that death observable through liveness/fail-fast so a
  supervisor restarts the consumer; it does not duplicate plan 18's in-loop recovery. A broker
  outage cannot be repaired by restarting this pod, so making it readiness-critical would
  amplify an upstream outage across the fleet.
  Date: 2026-07-22


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a declared-agent runtime whose long-running CLI subcommands form the runtime. The
one that matters most here is `worker`
(`shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs` → `Shikigami.Worker.runWorker`,
`shikigami-core/src/Shikigami/Worker.hs:67-70`), which composes four loops with nested
`concurrently_`:

```haskell
runWorker env = do
  hPutStrLn stderr "[shikigami.worker] starting; draining shikigami_run_jobs"
  concurrently_ (runQueueWorker env)
    (concurrently_ (runResumeWorker env)
      (concurrently_ (runOutboxPublisher env) (runTimerWorker env)))
```

Term of art: a *loop* here is one of these four `IO ()` actions, each an infinite iteration over
a unit of substrate work. `runQueueWorker` (`Worker.hs:72-84`) builds a shibuya
`QueueProcessor` over the `shikigami_run_jobs` pgmq queue and runs it under
`runApp IgnoreFailures 100 [...]` then `waitApp`. `runResumeWorker` (`Worker.hs:86-101`) calls
keiro's `runWorkflowResumeWorker` once and returns — on a `Left` store error it logs and returns
permanently (there is no surrounding `forever`). `runOutboxPublisher` (`Worker.hs:103-112`) and
`runTimerWorker` (`Worker.hs:114-123`) each `forever` { do one pass; on `Left` log;
`threadDelay 1_000_000` }.

Why "any loop can die while the process stays up": shibuya's supervision strategy at
`Worker.hs:78` is `IgnoreFailures`, which — per shibuya's own definition
(`Shibuya/App.hs:89-98`) — keeps running and never restarts or propagates a child failure. The
resume loop simply returns on error. The outbox and timer loops catch `Left` and continue, so a
*store-level* fault is retried forever but any exception their bodies throw would escape;
critically, none of the four surfaces its stopped state anywhere.

There is no HTTP server in the runtime except `stub-kawa`
(`shikigami-core/src/Shikigami/Sink/KawaStub.hs`, a `warp` app serving
`POST /v1/sources/{source}/events`, booted with `Warp.run (port opts)` at KawaStub.hs:91). `wai`
and `warp` are already dependencies (`shikigami-core.cabal:113-114`). This is starting-state
evidence only, not a template: plan 36 moves production HTTP ownership to
`shikigami-server`, and health extends its typed Servant application rather than copying the
stub's handwritten `pathInfo`/`requestMethod` dispatcher.

The consumers (`shikigami-cli/src/Shikigami/Cli/Commands/ConsumeStream.hs`,
`shikigami-core/src/Shikigami/Trigger/Consumer.hs`) run a Kafka poll loop
(`Consumer.hs:89-97` and `:116-124`); on a `KafkaError` the `runError` wrapper yields `Left`,
which is logged (`Consumer.hs:86`, `:113`) and the loop ends. The scheduler
(`shikigami-cli/src/Shikigami/Cli/Commands/Scheduler.hs`) is a single `forever` timer loop
(`Scheduler.hs:42-48`).

Two sibling plans matter. `docs/plans/28-structured-logging-metrics-and-trace-propagation.md`
(EP-1) introduces `Shikigami.Log`; if it has landed, emit loop-lifecycle events through it,
otherwise the health server can ship first and adopt structured logging later (soft dependency,
not blocking).
`docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md`
(EP-4) consumes the endpoints this plan creates as its
process-compose/systemd readiness probes.


## Plan of Work

### Milestone 1 — the typed health API and generated contract

Scope: one standard probe contract with package-correct execution. The Shikigami application
server extends its umbrella route; worker, scheduler, and consumer executables run the released
external Shibuya probe application. `/health/live` and `/health/ready` answer exact GETs with
typed 200/503 `MultiVerb` variants before per-loop heartbeats are wired in M2.

In `shikigami-api`, add the concept vertical `Shikigami.Health.Api` and mount its record under
`health` on `Shikigami.Api`. In `shikigami-server`, add `Shikigami.Health.Handler`. Both response
variants carry the same strict direct-field document:

```haskell
data ProbeStatus = ProbeStatus
  { status :: !Text,
    check :: !Text,
    failingSince :: !(Maybe UTCTime)
  }

data ProbeVerdict
  = Healthy
  | Unhealthy {failedCheck :: !Text, since :: !UTCTime}

type ProbeCheck = IO ProbeVerdict

healthServer :: ProbeCheck -> ProbeCheck -> HealthApi (AsServerT AppM)
```

`HealthApi mode` and `HealthApi (AsServerT AppM)` own application-server dispatch; terminal
200/503 results use a handwritten `AsUnion`. The server turns that typed route tree into one
WAI `Application`.
Plan 36's dedicated `shikigami-openapi` executable runs `toOpenApi` on this same extended
top-level proxy, writes the checked artifact, and tests validate both example response
variants against it; this plan does not add a second generator.

The typed handler responds to exact `GET /health/live` with 200 and
`ProbeStatus "ok" "all" Nothing` when its in-process check makes progress within the bounded
liveness timeout, else 503 with the stable failed check and the time failure began.
`GET /health/ready` runs the PostgreSQL check and selects 200/503 the same way. Unsupported
paths/methods use the server's normal typed/RFC-7807 handling; health 200/503 bodies remain
explicit status reports.
Register the routes under plan 36's existing server-level error-formatting and narrow 405
rewrite boundary so framework-generated JSON 400/404/405 responses remain RFC 7807
`application/problem+json`; do not add a health-local renderer or limit the contract to
errors explicitly returned by handlers.

For worker roles, first land and release the additive upstream Shibuya contract described in
Progress. It must export `ProbeStatus`, `ProbeVerdict`, `ProbeCheck`, a `HealthApi` using
`NamedRoutes` and terminal `MultiVerb`, an injectable `probeApplication`, and a same-proxy
OpenAPI generator/test. It must enforce exact GETs and preserve the status-report exemption.
Locate the implementation with `mori registry show shinzui/shibuya --full`, read its source,
and verify the chosen released version on Hackage and against upstream tags; do not consume a
developer checkout or the current handwritten router as if it satisfied this contract.

The application server mounts health on its existing main listener configured by plan 37's
stable `http.port`; it does not open a second health-only socket. Worker roles use plan 37's
stable `health.port` Settei setting, with explicit compatibility bindings and per-process
defaults 8091–8094 so the four local processes coexist. Thread each validated port through its
composition root; command modules do not read environment or define precedence.
Each worker-role executable runs `probeApplication` concurrently with its work, but
`shikigami-workers` gains no sibling-package dependency. Its readiness action is a PostgreSQL
ping through the real application pool (`Hasql.Pool.use pool` over a `select 1` session).
Do not add Kafka metadata fetches or downstream HTTP calls to readiness.

Acceptance: start the worker; `curl -sS localhost:8091/health/live` returns 200; `curl -sS
localhost:8091/health/ready` returns 200 while Postgres is up.

### Milestone 2 — per-loop heartbeats and real readiness

Scope: make `/health/live` reflect actual loop progress and `/health/ready` reflect actual dependency
state.

Define the worker-only heartbeat registry in the `Shikigami.Health.Worker` concept vertical;
do not introduce a bare cross-cutting `Shikigami.Health` technical module. Give it strict
direct fields and expose only
`beat :: LoopName -> IO ()` plus `loopLivenessCheck :: ProbeCheck`. Call `beat <LoopName>` at
the point each loop completes a unit of work: after a successful queue-job path (inside
`runJobHandler` or the shibuya processor callback), after each `runWorkflowResumeWorker` return
in the resume loop, at the bottom of each `forever` body in `runOutboxPublisher`
(`Worker.hs:111`) and `runTimerWorker` (`Worker.hs:122`), before the `threadDelay`. For the
consumers, `beat state ConsumerLoop` after each `commitOffsetMessage` (`Consumer.hs:96`,
`:123`); for the scheduler, after each timer pass (`Scheduler.hs:47`).

The liveness check deterministically selects the first stale loop, reports a stable name such
as `loop.outbox`, and sets `since` to the instant its last heartbeat crossed the configured
staleness threshold. It never performs network or database IO. Set each loop's staleness bound relative to its cadence: the outbox and timer loops poll every
1 s, so a 10 s bound flags a wedged loop quickly without false positives; the queue processor
and consumers may idle legitimately when there is no work, so give them longer bounds (e.g.
60 s) and, if idleness makes bounds unreliable, have the loop `beat` on each poll *attempt*
(including empty polls) rather than only on work — the empty-poll heartbeat is the honest "loop
is alive" signal. Record which choice was made.

Acceptance: with the worker idle, `/health/live` stays 200 (empty-poll heartbeats keep loops
fresh). A forced stale outbox heartbeat returns 503 with `check = "loop.outbox"` and the exact
threshold-crossing `failingSince`. Pointing the worker at unreachable Postgres makes
`/health/ready` return 503 naming `postgres`. Stopping Kafka does not change readiness; if it
kills or wedges a consumer loop, liveness/fail-fast surfaces that condition.

### Milestone 3 — fail-fast supervision and bounded loop retry

Scope: make a genuinely dead loop take the process down, and make the resume loop tolerate a
transient store blip.

First, stop the loops from swallowing fatal errors. The outbox and timer loops should keep
retrying *store* errors (transient) but must not catch and hide a programming exception; keep
the `Left`-logs-and-continues path for `StoreError`, but let any other exception propagate out
of `forever` so `concurrently_` (`Worker.hs:70`) cancels the siblings and `runWorker` throws,
exiting the process non-zero. The queue processor already returns from `waitApp` when shibuya
stops; wrap `runQueueWorker` so that a *return* from `waitApp` (the processor stopped) is
treated as fatal — re-throw a `LoopExited QueueLoop` exception rather than letting
`runQueueWorker` fall through to `pure ()` (`Worker.hs:84`), because under `IgnoreFailures` a
stopped processor is a silent death.

Second, convert the resume loop (`runResumeWorker`, `Worker.hs:86-101`) from run-once-and-return
into a bounded retry: wrap it in a loop that, on a `Left` store error, logs, sleeps a backoff
interval (start 1 s, cap at, say, 30 s, reset on success), beats the worker heartbeat
registry, and retries;
on repeated failure past a ceiling count, throw `LoopExited ResumeLoop` to trip fail-fast. A
clean return (no more work) simply loops again after a short delay, exactly like the
outbox/timer loops.

Prove it by fault injection in the workers test harness. Construct `WorkerEnv` with a private
test hook that makes one loop body `throwIO (userError "fault-injected loop death")` after N
iterations; do not add a production flag or raw environment read. Run that composition under
an `async`, assert that it terminates with `LoopExited`, and separately exercise the packaged
binary under the external supervisor's restart policy.

Acceptance: fault-injected loop death exits the process non-zero (visible as a process-compose
restart or `echo exited $?` printing non-zero); a transient store error in the resume loop is
retried with backoff and does not exit; a persistent one exits after the ceiling.


## Concrete Steps

All commands run from the repo root inside `nix develop`. A running Postgres described by the
checked config source is assumed (use the stack from
`docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md`, or a manual
Postgres).

Build and unit-test the health app (M1):

```bash
cabal build all
cabal test all
```

Expected: the server and worker test suites pass. Their health-app unit tests use `wai`'s test
helpers (`Network.Wai.Test`) to assert exact GET `/health/live` → 200 and, with a stale
heartbeat injected, → 503, needing no server socket. The upstream Shibuya same-proxy
OpenAPI/conformance suite also passes at its selected released version.

Probe a live worker (M1/M2):

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

Fail-fast (M3) — run the private test-harness injection and confirm the supervised worker
terminates rather than limping:

```bash
cabal test shikigami-workers --test-options='--pattern "loop failure cancels siblings"'
```

Expected:

```text
1 tests passed
```


## Validation and Acceptance

Acceptance is observable behavior:

1. Liveness: `curl -s -o /dev/null -w '%{http_code}' localhost:8091/health/live` prints `200` for a
   healthy worker and the body is the standard passing `ProbeStatus`. Injecting a stale
   heartbeat yields `503` with the stable loop check and threshold-crossing `failingSince`.
2. Readiness: `/health/ready` returns `200` when PostgreSQL is reachable and `503` naming it
   otherwise. Kafka and downstream HTTP outages do not flip readiness.
3. Fail-fast: a fault-injected loop death exits the whole process with a non-zero status (shown
   by the `echo "exited $?"` transcript, and by a process-compose restart when run under the
   stack), instead of the current silent-dead-loop behavior. A transient store error in the
   resume loop is retried with backoff and does not exit.
4. Regression: `cabal build all` and `cabal test all` pass; all four commands still start and do
   their existing work; the health port is configurable and defaults are distinct so the full
   stack can run every command on one host.
5. API contract: only exact unauthenticated GETs succeed; 200/503 bodies conform to the
   OpenAPI artifact generated from each served proxy; no redirect or handwritten WAI route
   exists in either Shikigami or the required Shibuya surface; non-health JSON errors use RFC
   7807; request logs omit health paths.


## Idempotence and Recovery

The endpoints are read-only and safe to poll at any frequency. All local code changes are
additive (concept-vertical modules, one Settei setting consumed from plan 37, extra
`concurrently_` branches) except the M3 change to loop
error-handling, which is the point of the plan; each milestone leaves `cabal test all` green, so
work can stop at a milestone boundary. If the fail-fast change proves too aggressive in practice
(e.g. a loop that legitimately returns is misread as a death), the fix is local — widen what
counts as "clean return" for that loop — and does not affect the health server or heartbeats.
The health server binding to a busy port fails loudly at boot; choosing distinct per-command
defaults (and honoring Settei's `health.port`) avoids collisions. No database or schema changes are
made, so there is nothing to roll back on the data side.


## Interfaces and Dependencies

Hard dependencies: plans 36 and 37 plus the released upstream Shibuya probe contract described
above. Use the coherent released `openapi-hs`/`servant-openapi-hs` cohort selected by plan 36
and obtain listener settings from Settei.

Dependencies: `wai`, `warp`, and Servant server packages stay at the `shikigami-server`
boundary; `shikigami-workers` adds the coherent released `shibuya-metrics` package but no
Shikigami sibling API/server dependency. `hasql`/`hasql-pool` provide the PostgreSQL readiness
ping. Shibuya's
supervision types are consumed as-is (`Shibuya.App (SupervisionStrategy (IgnoreFailures),
runApp, waitApp)`, already imported at `Worker.hs:34`); this plan does not change the shibuya
call, only what happens when `waitApp` returns.

Signatures that must exist at the end of each milestone (full module paths):

- M1: `Shikigami.Health.Api` in `shikigami-api`, `Shikigami.Health.Handler` in
  `shikigami-server`, typed 200/503 `MultiVerb` unions, the top-level served `Proxy`, and the
  plan-36 OpenAPI generator. Upstream `shibuya-metrics` supplies the equivalent injectable
  worker `ProbeCheck`/`probeApplication` contract and its own same-proxy artifact. Settei
  `http.port` is present for the application server, and `health.port` listener settings are
  present for all four worker-role processes.
- M2: `Shikigami.Health.Worker` in `shikigami-workers` owns `LoopName`, the strict heartbeat registry,
  `beat :: LoopName -> IO ()`, and `loopLivenessCheck :: ProbeCheck`; consumers accept the
  narrow `beat` callback rather than an HTTP/server type.
- M3: a `LoopExited` exception type in `Shikigami.Health.Worker` (or the owning concept
  worker) thrown when a
  loop dies; `runResumeWorker` becomes a bounded-backoff retry loop; `runQueueWorker` treats a
  `waitApp` return as fatal.

Cross-plan contracts (mirrored in the MasterPlan's Integration Points): `/health/ready` and `/health/live`
and the Settei `http.port`/`health.port` settings are consumed by
`docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md` as
process-compose `http_get` probes and systemd health config — that plan must add both settings
to the configuration reference. The Kafka consume-loop reconnect fix is owned by
`docs/plans/18-atomic-stream-consumption-offsets-inbox-and-enqueue-in-one-boundary.md`; this
plan only surfaces the death via liveness and fail-fast. If
`docs/plans/28-structured-logging-metrics-and-trace-propagation.md` has landed, loop-lifecycle
and fail-fast events should be emitted through `Shikigami.Log` (soft dependency).


## Revision Notes

- 2026-07-22: Rebased on plans 36/37 and completed the API pass: typed
  `NamedRoutes`/`MultiVerb`, same-proxy OpenAPI, health-specific status documents,
  RFC-7807 non-health errors, exact probe behavior, Settei ports, and request-log exclusion.
- 2026-07-22: Aligned probe paths and readiness semantics with the API standard:
  `/health/live`, `/health/ready`, and no Kafka/downstream readiness dependency.
