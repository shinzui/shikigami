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
Kubernetes, or a load balancer.

After this plan, each loop records a heartbeat timestamp when it makes progress, a tiny warp
HTTP server on every long-running command exposes `GET /healthz` (liveness) and
`GET /readyz` (readiness), and any loop's death terminates the process with a non-zero exit so
a supervisor restarts it. `/healthz` returns 200 only when the process is up and every loop's
heartbeat is recent; `/readyz` returns 200 only when the dependencies that command needs are
reachable (Postgres for all; Kafka additionally for the consumers). These endpoints are what
`docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md` wires
its readiness probes to.

The user-visible proof: start the worker, `curl -s localhost:8091/healthz` returns 200 with a
JSON body naming each loop and its last-heartbeat age; point the process at an unreachable
Postgres and watch `/readyz` return 503; and fault-inject a loop crash and watch the whole
process exit non-zero (which under process-compose or systemd triggers a restart) instead of
limping along with a dead loop.


## Progress

- [ ] M1: `Shikigami.Health` module with a `HealthState` (per-loop heartbeat registry) and a
      warp `Application` serving `/healthz` and `/readyz`; unit-tested with `wai` test helpers.
- [ ] M1: `--health-port` flag (distinct default per command) added to the four long-running
      commands; server started alongside the loops.
- [ ] M2: each worker loop records a heartbeat into `HealthState` on each successful iteration;
      `/healthz` reflects per-loop staleness.
- [ ] M2: readiness checks wired — Postgres ping for all; Kafka metadata fetch for the two
      consumers; `/readyz` returns 503 when a dependency is unreachable.
- [ ] M3: fail-fast supervision — any loop's termination (normal or exceptional) tears down the
      siblings and exits the process non-zero; proven by fault injection.
- [ ] M3: the resume loop's permanent-return-on-store-error (`Worker.hs:98-101`) converted to a
      restart-with-backoff iteration so a transient store blip does not require a full process
      restart, while a persistent failure still surfaces via `/healthz` staleness and (after the
      backoff ceiling) fail-fast.


## Surprises & Discoveries

(None yet.)


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
  `restart: on_failure`, systemd `Restart=always` — both defined by `docs/plans/31-...md`)
  restart a clean process. Restart-with-backoff *per loop* is added only for the resume loop's
  transient store errors, because a momentary connection blip should not cause a full cold
  restart; a persistent failure still trips the backoff ceiling and exits. Alternative rejected:
  in-process per-loop restart supervision (a home-grown supervisor tree) — more code, duplicates
  what an external supervisor does better, and risks masking a genuine fault as an infinite
  restart loop.
  Date: 2026-07-08

- Decision: Serve health over a minimal warp server rather than adding a health field to the
  metrics/OTLP pipeline.
  Rationale: `wai`/`warp` are already direct dependencies of shikigami-core
  (`shikigami-core.cabal:113-114`) and already used for the `stub-kawa` server
  (`shikigami-core/src/Shikigami/Sink/KawaStub.hs`), so there is a proven in-repo pattern and no
  new dependency. Health must be pull-able by dumb probes (process-compose `http_get`, k8s),
  which is an HTTP GET, not an OTLP export.
  Date: 2026-07-08

- Decision: Heartbeats are per-loop `IORef UTCTime` timestamps updated on each successful
  iteration; `/healthz` fails a loop whose heartbeat is older than a per-loop staleness bound.
  Rationale: a boolean "alive" flag cannot distinguish a wedged loop (blocked forever inside one
  iteration) from a healthy idle loop. A timestamp does, and the outbox/timer loops already
  iterate on a 1-second `threadDelay` (`Worker.hs:112,123`), giving a natural heartbeat cadence;
  the queue processor's cadence is shibuya's poll interval. Staleness bounds are generous
  multiples of each loop's expected period so an idle-but-healthy loop is not flagged.
  Date: 2026-07-08

- Decision: `/readyz` for the consumers checks Kafka reachability, but the KafkaError-kills-the-
  loop reconnect *fix* itself is out of scope here.
  Rationale: the consume loop dies on any `KafkaError`
  (`shikigami-core/src/Shikigami/Trigger/Consumer.hs:84-87` and `:111-114` — the error is logged
  and the loop returns), and the proper fix (reconnect/backoff, atomic offset+inbox+enqueue)
  belongs to
  `docs/plans/18-atomic-stream-consumption-offsets-inbox-and-enqueue-in-one-boundary.md`
  (MasterPlan 3). This plan makes that death *observable* (readiness flips, process exits) so a
  supervisor restarts the consumer; it does not duplicate plan 18's in-loop recovery. Recorded
  as a cross-MasterPlan hand-off in the MasterPlan.
  Date: 2026-07-08


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
and `warp` are already dependencies (`shikigami-core.cabal:113-114`). That module is the
template to copy for the health server: build an `Application`, dispatch on
`pathInfo`/`requestMethod`, respond with `responseLBS`.

The consumers (`shikigami-cli/src/Shikigami/Cli/Commands/ConsumeStream.hs`,
`shikigami-core/src/Shikigami/Trigger/Consumer.hs`) run a Kafka poll loop
(`Consumer.hs:89-97` and `:116-124`); on a `KafkaError` the `runError` wrapper yields `Left`,
which is logged (`Consumer.hs:86`, `:113`) and the loop ends. The scheduler
(`shikigami-cli/src/Shikigami/Cli/Commands/Scheduler.hs`) is a single `forever` timer loop
(`Scheduler.hs:42-48`).

Two sibling plans matter. `docs/plans/28-structured-logging-metrics-and-trace-propagation.md`
(EP-1) introduces `Shikigami.Log`; if it has landed, emit loop-lifecycle events through it,
otherwise the health server can ship first and adopt structured logging later (soft dependency,
not blocking). `docs/plans/31-...md` (EP-4) consumes the endpoints this plan creates as its
process-compose/systemd readiness probes.


## Plan of Work

### Milestone 1 — the health server and endpoints

Scope: a health module, a warp server, and a `--health-port` flag on the four commands. At the
end, `/healthz` and `/readyz` answer on every long-running command (with liveness always true
and readiness a fixed dependency check, before per-loop heartbeats are wired in M2).

Create `shikigami-core/src/Shikigami/Health.hs`, module `Shikigami.Health`:

```haskell
data HealthState = HealthState
  { heartbeats :: !(Map LoopName (IORef UTCTime)),
    readiness  :: !(IO ReadyReport)     -- command-specific dependency check
  }

data LoopName = QueueLoop | ResumeLoop | OutboxLoop | TimerLoop | ConsumerLoop | SchedulerLoop
newtype ReadyReport = ReadyReport [(Text, Bool)]      -- e.g. [("postgres", True), ("kafka", False)]

newHealthState :: [LoopName] -> IO ReadyReport -> IO HealthState
beat :: HealthState -> LoopName -> IO ()              -- writes getCurrentTime
healthApp :: NominalDiffTime -> HealthState -> Application   -- staleness bound → wai app
runHealthServer :: Int -> HealthState -> IO ()               -- Warp.run port (healthApp ... state)
```

`healthApp` responds to `GET /healthz` with 200 and a JSON body
`{"status":"ok","loops":[{"name":"outbox","age_s":0.4},...]}` when every heartbeat is younger
than the staleness bound, else 503 with the offending loops flagged; `GET /readyz` runs the
`readiness` action and returns 200 iff every pair is `True`, else 503 with the failing
dependencies. Copy the request-dispatch shape from `KawaStub.hs`. Add `Shikigami.Health` to
`shikigami-core.cabal` `exposed-modules`.

Add `--health-port PORT` to the four commands in `shikigami-cli/src/Shikigami/Cli.hs` (worker
default 8091, scheduler 8092, consume-stream 8093, consume-events 8094 — distinct so they can
coexist on one host). Thread the port through each command wrapper.

In each command, construct a `HealthState` and run `runHealthServer` concurrently with the
existing work (extend the `concurrently_` nest in `runWorker`, add a `concurrently_` in the
scheduler/consumers). The readiness action for the worker/scheduler is a Postgres ping
(`Hasql.Pool.use pool` over a `select 1` session mapped to a `Bool`); for the consumers it is
the Postgres ping plus a Kafka metadata fetch against the configured broker (use
`hw-kafka-client`'s metadata call; if that is awkward from the effectful wrapper, a short-lived
raw consumer that fetches metadata with a timeout is acceptable — record the choice).

Acceptance: start the worker; `curl -sS localhost:8091/healthz` returns 200; `curl -sS
localhost:8091/readyz` returns 200 while Postgres is up.

### Milestone 2 — per-loop heartbeats and real readiness

Scope: make `/healthz` reflect actual loop progress and `/readyz` reflect actual dependency
state.

Pass the `HealthState` into `WorkerEnv` (`Worker.hs:55-63`) and call `beat state <LoopName>` at
the point each loop completes a unit of work: after a successful queue-job path (inside
`runJobHandler` or the shibuya processor callback), after each `runWorkflowResumeWorker` return
in the resume loop, at the bottom of each `forever` body in `runOutboxPublisher`
(`Worker.hs:111`) and `runTimerWorker` (`Worker.hs:122`), before the `threadDelay`. For the
consumers, `beat state ConsumerLoop` after each `commitOffsetMessage` (`Consumer.hs:96`,
`:123`); for the scheduler, after each timer pass (`Scheduler.hs:47`).

Set each loop's staleness bound relative to its cadence: the outbox and timer loops poll every
1 s, so a 10 s bound flags a wedged loop quickly without false positives; the queue processor
and consumers may idle legitimately when there is no work, so give them longer bounds (e.g.
60 s) and, if idleness makes bounds unreliable, have the loop `beat` on each poll *attempt*
(including empty polls) rather than only on work — the empty-poll heartbeat is the honest "loop
is alive" signal. Record which choice was made.

Acceptance: with the worker idle, `/healthz` stays 200 (empty-poll heartbeats keep loops fresh);
point it at an unreachable Postgres and `/readyz` returns 503 naming `postgres`; for a consumer,
stop the broker and `/readyz` names `kafka`.

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
interval (start 1 s, cap at, say, 30 s, reset on success), beats the health state, and retries;
on repeated failure past a ceiling count, throw `LoopExited ResumeLoop` to trip fail-fast. A
clean return (no more work) simply loops again after a short delay, exactly like the
outbox/timer loops.

Prove it by fault injection. Add a hidden/test-only way to force a loop to throw — the cleanest
is a small `WorkerEnv` field (or an env var read at boot) that, when set, makes one loop body
`throwIO (userError "fault-injected loop death")` after N iterations. With it set, start the
worker under process-compose (or `bash -c 'shikigami worker ...; echo exited $?'`) and observe a
non-zero exit and a supervisor restart, versus the current behavior where the process keeps
running.

Acceptance: fault-injected loop death exits the process non-zero (visible as a process-compose
restart or `echo exited $?` printing non-zero); a transient store error in the resume loop is
retried with backoff and does not exit; a persistent one exits after the ceiling.


## Concrete Steps

All commands run from the repo root inside `nix develop`. A running Postgres with
`PG_CONNECTION_STRING` set is assumed (use the stack from `docs/plans/31-...md`, or a manual
Postgres).

Build and unit-test the health app (M1):

```bash
cabal build all
cabal test all
```

Expected: `Test suite shikigami-core-test: PASS`. The health-app unit test uses `wai`'s test
helpers (`Network.Wai.Test`) to assert `/healthz` → 200 and, with a stale heartbeat injected,
→ 503, needing no server socket.

Probe a live worker (M1/M2):

```bash
cabal run shikigami -- worker --agents agents --health-port 8091 &
sleep 3
curl -sS -o /dev/null -w '%{http_code}\n' localhost:8091/healthz
curl -sS localhost:8091/readyz | jq .
```

Expected:

```text
200
{
  "status": "ok",
  "checks": [ { "name": "postgres", "ok": true } ]
}
```

Readiness failure (M2) — point the worker at an unreachable Postgres and re-probe:

```bash
PG_CONNECTION_STRING='postgresql://127.0.0.1:1/nope' cabal run shikigami -- worker --agents agents --health-port 8091 &
sleep 3
curl -sS -o /dev/null -w '%{http_code}\n' localhost:8091/readyz
```

Expected:

```text
503
```

Fail-fast (M3) — with fault injection enabled (mechanism chosen in M3), confirm the process
exits non-zero rather than limping:

```bash
SHIKIGAMI_FAULT_INJECT=outbox bash -c 'cabal run shikigami -- worker --agents agents --health-port 8091; echo "exited $?"'
```

Expected (non-zero code; exact value depends on the exception):

```text
exited 1
```


## Validation and Acceptance

Acceptance is observable behavior:

1. Liveness: `curl -s -o /dev/null -w '%{http_code}' localhost:8091/healthz` prints `200` for a
   healthy worker and the body lists each loop with a fresh `age_s`. Injecting a stale heartbeat
   (unit test) yields `503`.
2. Readiness: `/readyz` returns `200` when Postgres (and, for consumers, Kafka) is reachable and
   `503` naming the failing dependency otherwise. Demonstrated with the unreachable-Postgres run
   above and, for a consumer, a stopped broker.
3. Fail-fast: a fault-injected loop death exits the whole process with a non-zero status (shown
   by the `echo "exited $?"` transcript, and by a process-compose restart when run under the
   stack), instead of the current silent-dead-loop behavior. A transient store error in the
   resume loop is retried with backoff and does not exit.
4. Regression: `cabal build all` and `cabal test all` pass; all four commands still start and do
   their existing work; the health port is configurable and defaults are distinct so the full
   stack can run every command on one host.


## Idempotence and Recovery

The endpoints are read-only and safe to poll at any frequency. All code changes are additive (a
new module, a new flag, extra `concurrently_` branches) except the M3 change to loop
error-handling, which is the point of the plan; each milestone leaves `cabal test all` green, so
work can stop at a milestone boundary. If the fail-fast change proves too aggressive in practice
(e.g. a loop that legitimately returns is misread as a death), the fix is local — widen what
counts as "clean return" for that loop — and does not affect the health server or heartbeats.
The health server binding to a busy port fails loudly at boot; choosing distinct per-command
defaults (and honoring `--health-port`) avoids collisions. No database or schema changes are
made, so there is nothing to roll back on the data side.


## Interfaces and Dependencies

Dependencies: `wai` and `warp` (already in `shikigami-core.cabal:113-114`); `hasql`/`hasql-pool`
for the Postgres readiness ping (already present); `hw-kafka-client`/`kafka-effectful` for the
Kafka metadata check (already present, `shikigami-core.cabal`). No new dependencies. shibuya's
supervision types are consumed as-is (`Shibuya.App (SupervisionStrategy (IgnoreFailures),
runApp, waitApp)`, already imported at `Worker.hs:34`); this plan does not change the shibuya
call, only what happens when `waitApp` returns.

Signatures that must exist at the end of each milestone (full module paths):

- M1: `Shikigami.Health.HealthState`, `Shikigami.Health.LoopName`,
  `Shikigami.Health.newHealthState :: [LoopName] -> IO ReadyReport -> IO HealthState`,
  `Shikigami.Health.beat :: HealthState -> LoopName -> IO ()`,
  `Shikigami.Health.healthApp :: NominalDiffTime -> HealthState -> Network.Wai.Application`,
  `Shikigami.Health.runHealthServer :: Int -> HealthState -> IO ()`; `--health-port` present on
  the four commands in `Shikigami.Cli`.
- M2: `Shikigami.Worker.WorkerEnv` gains `health :: !HealthState`; `beat` called in every loop;
  the consumers' `subscribeActivityStream`/`subscribeIntegrationEventStream` accept a
  `HealthState` (or a `beat` callback) to heartbeat per commit.
- M3: a `LoopExited` exception type (in `Shikigami.Worker` or `Shikigami.Health`) thrown when a
  loop dies; `runResumeWorker` becomes a bounded-backoff retry loop; `runQueueWorker` treats a
  `waitApp` return as fatal.

Cross-plan contracts (mirrored in the MasterPlan's Integration Points): `/readyz` and `/healthz`
and the `--health-port` flag are consumed by
`docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md` as
process-compose `http_get` probes and systemd health config — that plan must add `--health-port`
to the configuration reference. The Kafka consume-loop reconnect fix is owned by
`docs/plans/18-atomic-stream-consumption-offsets-inbox-and-enqueue-in-one-boundary.md`; this
plan only surfaces the death via readiness and fail-fast. If
`docs/plans/28-structured-logging-metrics-and-trace-propagation.md` has landed, loop-lifecycle
and fail-fast events should be emitted through `Shikigami.Log` (soft dependency).
