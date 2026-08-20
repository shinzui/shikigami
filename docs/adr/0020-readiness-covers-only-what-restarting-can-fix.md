# 0020. Readiness covers only what restarting or eviction can fix

Date: 2026-08-20

Status: accepted


## Context

Every Shikigami process now answers two probes: `GET /health/live` and
`GET /health/ready`. They exist to be polled by something that will act on the
answer — process-compose, systemd, a Kubernetes kubelet, a load balancer — and the
action differs. A failed liveness probe means restart this process. A failed
readiness probe means take it out of rotation but leave it running.

That difference is the whole design constraint, and it is easy to lose. Collapsing
the two into one route throws it away. So does adding a dependency to readiness
because the process happens to use it.

Shikigami touches PostgreSQL, Kafka, and four downstream HTTP services (kawa,
kizashi, danwa, rei). Only one of those is a dependency whose failure the
supervisor's response repairs.

There is also a packaging constraint. Two packages answer these routes:
`shikigami-server` for the HTTP role and `shikigami-workers` for the four worker
roles. The six-package architecture forbids `shikigami-workers` from depending on
`shikigami-api` or `shikigami-server`, and
`Shikigami.PackageArchitectureSpec` fails the build if it tries. Without a
deliberate answer, the two families would grow two implementations of one wire
contract.


## Decision

**`/health/ready` reports only PostgreSQL reachability. `/health/live` reports only
in-process progress and performs no network or database IO. Both process families
serve one contract from one external library.**

Concretely:

* Readiness pings PostgreSQL through the pool the process already uses, so it
  reflects the same connection path real work takes rather than a private
  connection that could succeed while the application's pool is exhausted. The
  check is named `postgres`, which appears verbatim in the 503 body and is
  therefore an operator-facing string.
* Kafka and the downstream HTTP services are **not** readiness dependencies. A
  broker or sink outage cannot be repaired by restarting a process or by evicting
  it from load balancing, so making it readiness-critical would amplify one
  upstream outage across the whole fleet. Consumer trouble surfaces through
  liveness and through the fail-fast rule in
  [0019](0019-a-loop-that-stops-stops-the-process.md) instead.
* Liveness on a worker reports whether its loops are still making progress, read
  from in-memory heartbeats and Shibuya's own processor metrics. It never touches
  the network, so a probe cannot be slowed or failed by the very outage readiness
  exists to report. On the server, which runs no loops, liveness is "the handler
  thread answered", which is the whole of what liveness can honestly mean there.
* Both families mount `servant-health`'s `HealthApi` and are proved by the same
  `servant-health:testkit` conformance suite. `servant-health` is an *external*
  package, so `shikigami-workers` depending on it introduces no sibling dependency
  and the boundary holds unchanged.
* Anything both families need below the route layer lives in `shikigami-core` and
  stops short of HTTP types. `Shikigami.Health.Ping` exposes
  `databaseReachable :: Pool -> IO Bool`, because a `ProbeCheck` would require
  `servant-health`, which pulls in `servant-server`, which the domain library must
  not link.
* Three hardening rules apply to every check in both families: wrap each check in
  `safeCheck`, put `withProbeTimeout` *outside* `safeCheck` and only on liveness,
  and build each probe's failure tracker once at boot. The nesting order matters —
  the timeout interrupts with an asynchronous exception that `safeCheck`
  deliberately lets through, so reversed, a deadlocked process would hang its
  liveness probe instead of failing it.


## Alternatives rejected

**Readiness checks every dependency the process uses.** It reads as thorough and
behaves as an outage amplifier: one broker hiccup removes every otherwise-healthy
pod from rotation at once, turning a degraded system into a down one.

**A single combined health route.** Cheaper to serve and impossible to act on: the
poller cannot tell "restart me" from "stop sending me traffic".

**A worker probe implemented separately from the server's.** Two implementations
of one wire contract drift, and the drift shows up in a dashboard or a runbook
rather than in a test. Adopting one external library gives both families the same
route type, the same body, and the same conformance suite.

**Routing the worker probe through Shibuya** (the original plan, via an
improvement request for a generic WAI probe application). Moot once it was noticed
that the constraint was only ever "no Shikigami sibling" — an external package
satisfies it directly.


## Consequences

`shikigami-server` cannot start without `database.connection_string`; it is now on
the required-key list. A server that cannot reach its database could never report
ready, so starting one without a connection string would bind a socket and then
fail every probe forever. Failing at configuration time with the key named is the
better outcome.

A worker will rarely serve a readiness 503 for its own database, because losing
PostgreSQL trips the fail-fast rule and the process exits within about a second.
The 503 is reachable for partial faults — pool exhaustion, a refused connection
against a live server — and readily observable on the server, which survives the
outage.

The probe body is a fixed three-key document: `status`, `check`, `failingSince`.
Resist adding per-loop detail to it. `failingSince` is the instant the failure
began, not the moment of observation, so a dashboard shows one incident rather
than a fresh one on every scrape; that is what the per-probe failure tracker buys
and why the checks are built once at boot.

Health responses are the deliberate exception to the RFC 7807
`application/problem+json` rule that governs every other JSON error, because probe
clients need a small stable status document rather than an error object.

A ping that names its own column types can be wrong about them. The first version
of `databaseReachable` decoded `select 1` as `int8` — it is `int4` — and so
reported every healthy database as unreachable, with every unit test passing,
because the conformance kit injects its own checks and nothing in the suite ran
the query. It runs through `Hasql.Session.script` now, which collects no result.
The general lesson is the reason acceptance for probe work is a live `curl` and
not only a green suite.
