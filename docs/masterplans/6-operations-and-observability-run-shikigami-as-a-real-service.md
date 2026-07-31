---
id: 6
slug: operations-and-observability-run-shikigami-as-a-real-service
title: "Operations and Observability: Run Shikigami as a Real Service"
kind: master-plan
created_at: 2026-07-08T20:13:36Z
intention: "intention_01kx1tyx3yehmsq9eyywdcf5c7"
---

# Operations and Observability: Run Shikigami as a Real Service

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Shikigami is a declared-agent runtime — a CLI whose long-running commands (`worker`,
`scheduler`, `consume-stream`, `consume-events`) drive declared agents over a Postgres + Kafka
substrate. It works, but it cannot yet be *operated*. Every log line is a bare `hPutStrLn
stderr`; every metrics hook the substrate exposes is filled with `Nothing`; tracing exists only
inside the worker and dies at the outbox boundary; any of the worker's four concurrent loops can
die silently while the process lingers; there is no health endpoint to probe; there is no way to
list agents, list or cancel runs, or inspect dead letters; and the whole thing runs only inside
a nix dev shell, with `process-compose` starting Postgres and nothing else.

After this initiative, shikigami runs as a real service. An operator sees structured JSON logs,
real metrics and end-to-end traces exported over OTLP, and exact HTTP `/health/live`/`/health/ready`
endpoints on every long-running command. The public server uses Shikigami's typed Servant API;
worker roles consume the equivalent released injectable probe surface from
`shibuya-metrics`, preserving the rule that `shikigami-workers` never depends on the sibling
API or server package. Both use `NamedRoutes` and terminal `MultiVerb`; OpenAPI is generated
from each served route type, non-health errors use RFC 7807 problem details, and bounded request logs run inside OTel
middleware with health paths excluded. A dead loop takes the process down
so a supervisor restarts it. From the command line an operator can list agents, list and inspect
runs (keiro workflow status joined with the kioku session), cancel a stuck run, and inspect and
replay dead-lettered jobs — all read-mostly, with destructive actions gated behind `--confirm`.
One command, `just dev`, boots the entire local stack (Postgres, Kafka/Redpanda, migrations, the
stub sink, the worker, the scheduler, both consumers) with health-check-based ordering; and a
NixOS module plus a single configuration reference make the runtime installable outside the dev
shell.

In scope: observability (logs, metrics, traces), liveness/readiness and loop supervision, an
operator CLI, and the deployable stack (process-compose, packaging, configuration reference).
Explicitly out of scope: the Kafka consume-loop *reconnect* fix (owned by
`docs/plans/18-atomic-stream-consumption-offsets-inbox-and-enqueue-in-one-boundary.md` in
MasterPlan 3 — this initiative only makes that death observable); in-workflow run timeouts
(owned by `docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md` in
MasterPlan 3 — this initiative owns only the operator-issued cancel); and the definition of the
model-provider and outbound-credential configuration (owned by `docs/plans/13-...` and
`docs/plans/22-...` — the configuration reference documents their settled surfaces).


## Decomposition Strategy

The initiative splits along four operational concerns, each independently demonstrable, each
producing a distinct user-visible capability:

1. **Observability (EP-1, plan 28)** — structured logging, metrics, and trace propagation. This
   is the "can I see what it's doing" layer. It is first because it defines the observability
   *vocabulary* (metric names, log event names, attribute keys) that every other plan — and
   every plan in MasterPlans 2-5 — emits against.
2. **Health & supervision (EP-2, plan 29)** — per-loop heartbeats, `/health/live`/`/health/ready`, and
   fail-fast supervision. This is the "is it alive, and does it die honestly" layer. Its
   endpoints feed EP-4's readiness probes.
3. **Operator CLI (EP-3, plan 30)** — `agents list`, `runs list/show/cancel`, `dlq list/replay`,
   `outbox status`. This is the "can I inspect and control it" layer, pure surface over the
   existing substrate tables.
4. **Deployable stack (EP-4, plan 31)** — full `process-compose` stack, `just dev`, a NixOS
   module, and the configuration reference. This is the "can I run and install it" layer.

Boundaries were drawn to minimize cross-plan coupling and maximize independent verifiability.
Observability, health, and the operator CLI touch largely disjoint code — logging/metrics
plumbing, a health server, and read-only queries respectively — so they proceed in parallel.
The deployable stack is deliberately last-and-thin: it is mostly configuration (YAML, nix,
Markdown) and consumes the others' outputs (health endpoints as probes, the config surface as a
reference) without needing their internals.

Alternatives considered and rejected. *One "observability" plan folding health in*: rejected
because health/supervision is a behavioral change (fail-fast, loop death) with its own risk
profile and its own acceptance (a process that exits non-zero), distinct from the additive
logging/metrics work. *Merging the operator CLI into the deployable stack*: rejected because the
CLI is Haskell code with database queries and a confirm-gate test, while the stack is
configuration; merging would produce one lopsided plan. *A separate plan for a Prometheus
endpoint*: rejected because the substrate's metrics hooks are typed for the OpenTelemetry
`Meter`, so metrics belong with the OTLP work in EP-1 (see EP-1's Decision Log).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Structured logging, metrics, and trace propagation | docs/plans/28-structured-logging-metrics-and-trace-propagation.md | cross-MP: plans 36, 37, and 47 | cross-MP: plan 22 (MasterPlan 4, required for M3) | Not Started |
| EP-2 | Health, liveness, and worker loop supervision | docs/plans/29-health-liveness-and-worker-loop-supervision.md | cross-MP: plans 36, 37, and 47; upstream Shibuya IR-1 for worker probe | EP-1 | Not Started |
| EP-3 | Operator CLI: inspect runs, agents, dead letters, and cancel | docs/plans/30-operator-cli-inspect-runs-agents-dead-letters-and-cancel.md | cross-MP: plans 20, 36, 37, and 47 | EP-1 | Not Started |
| EP-4 | Deployable service stack: process-compose, packaging, and configuration | docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md | cross-MP: plans 36–38 and 47 | EP-1, EP-2; cross-MP: plans 13 (MasterPlan 2), 22 (MasterPlan 4), 32 (MasterPlan 7) | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their EP-# prefix.


## Dependency Graph

Plans 36 and 37 precede every child; plan 38 additionally precedes EP-4. EP-2 also waits for
the additive released Shibuya probe contract specified by plan 29, because importing the
Shikigami API/server route tree into workers would violate plan 36. After those
foundations, EP-1 and EP-2 can start independently. EP-3 hard-depends on plan 20's canonical
`AgentLoadReport`; it owns presentation of that report through `agents list`. EP-1 milestones
1 and 2 can start immediately, while its HTTP trace-propagation milestone waits for plan 22's
authenticated `postJSONWithHeaders` seam.

EP-1 (observability) is the natural first mover because it defines the observability vocabulary
and the `Shikigami.Log` module that EP-2 and EP-3 would ideally emit through. But EP-2 and EP-3
do not block on it: EP-2's health server can ship with plain logging and adopt `Shikigami.Log`
later; EP-3's subcommands are one-shot CLIs that need no structured logging at all. That is why
EP-1 is a *soft* dep of both, not a hard one.

After plan 20 supplies EP-3's cross-MasterPlan loader dependency, EP-2 and EP-3 are
independent of each other's internals — health plumbing versus read-only operator queries
touch disjoint code — so they can run in parallel with each other and with EP-1.

EP-4 (deployable stack) hard-depends on the package, Settei, and pg-migrate foundations
and softly depends on EP-1 and EP-2: its process-compose and systemd readiness probes
are best pointed at EP-2's `/health/ready` endpoint. Until EP-2 lands, EP-4 ships with exec-based and
`process_started` probes and upgrades them afterward (EP-4 spells this out). EP-4 also consumes
plan 37's Settei surface — every operational setting must appear in EP-4's
configuration reference. Standard `OTEL_*` variables remain SDK-owned. Cross-MasterPlan plans 13, 22, and 32 own provider, sink-auth, and
channel-egress configuration; EP-4 should land after those surfaces stabilize rather than
publish reserved placeholders. The pragmatic sequence is plan 22 → EP-1 M3; plan 20 → EP-3;
EP-1/EP-2 and the external configuration owners → EP-4. This is the MasterPlan-6 slice of the
canonical MP-2 through MP-7 waves in MasterPlan 2.


## Integration Points

**IP-A — The observability vocabulary (EP-1 defines; all plans consume).** EP-1 owns the naming
conventions: metric names dot-namespaced under `shikigami.`
(`shikigami.runs.started|completed|failed|retried|dead_lettered`, `shikigami.queue.depth`,
`shikigami.consumer.records`), log event names as `component.subject.verb`
(`worker.job.dead_lettered`, `stream.record.matched`), and attribute keys reusing the existing
span attribute names (`agent.name`, `trigger.kind`, `run.idempotency_key`, plus `sink.kind`,
`outcome`, `topic`). EP-2 and EP-3 emit loop-lifecycle and audit events using these conventions;
plans in MasterPlans 2-5 (which emit run/sink/timer events) follow the same vocabulary. The
artifact is documented in EP-1's Decision Log; changes to it are made in EP-1 first.

**IP-B — `Shikigami.Log` (EP-1 defines; EP-2, EP-3 consume).** EP-1 creates
`shikigami-core/src/Shikigami/Log.hs`. EP-2's loop-supervision events and EP-3's destructive-
action audit lines should go through it once it exists. Because both can function without it,
this is a soft consumption, not a compile dependency.

**IP-C — Typed service API and health endpoints (plan 36 and upstream Shibuya define; EP-2
extends; EP-4 consumes).** The server package exposes the Shikigami `NamedRoutes`; worker
roles consume the released external `shibuya-metrics` probe application without a sibling
API/server dependency. Both terminal status variants use typed `MultiVerb` with handwritten
`AsUnion`. `GET /health/live` and `GET /health/ready` are exact, unauthenticated,
redirect-free routes returning the standard `ProbeStatus {status, check, failingSince}`;
they are the deliberate exception to the RFC 7807 error envelope. EP-2 adds their checks,
EP-4 wires process-compose and systemd probes, and plan 37 owns the health-port
setting/binding. Each owner derives its artifact from the exact served proxy and checks
schema/response conformance. No handwritten WAI health router remains.

**IP-C2 — Request observability (EP-1/EP-2).** OTel middleware wraps the bounded
request logger so log records can include trace/span correlation. The logger records
only UTC time, method, raw path without query, status, monotonic duration, a bounded user
agent, and optional trace/span IDs. It never logs bodies, body sizes, query values,
credentials, cookies, application error details, or arbitrary headers, and excludes exact
`/health/live` and `/health/ready` paths.

**IP-D — Configuration surface (plan 37 defines; EP-4 documents).** EP-4 owns
`docs/operations/configuration.md`, the single enumeration of every Settei key, source,
legacy environment binding, and flag. EP-1 may add typed observability settings, but
standard `OTEL_*` variables remain SDK-owned. EP-4's reference also includes
sections for the model-provider config owned by
`docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md` (MasterPlan 2), the
outbound-credential config owned by `docs/plans/22-outbound-authentication-for-sink-clients.md`
(MasterPlan 4), and channel-egress config from plan 32. EP-4 lands after those surfaces and
documents their actual names rather than reserved placeholders.

**IP-E — Cross-MasterPlan cancellation surface (EP-3 with MasterPlan 3's plan 17).** EP-3's
`runs cancel <workflow-id>` and plan 17's in-workflow run timeout both write keiro's terminal
`WorkflowCancelled` journal marker (`Keiro.Workflow.Types.WorkflowCancelled`, appended via
`Keiro.Workflow.appendJournalEntry`). Plan 17 owns the automatic self-cancel on overrun; EP-3
owns the operator-issued cancel. If plan 17 lands a shared cancel helper, EP-3 should call it
rather than duplicate the append.

**IP-F — Cross-MasterPlan consume-loop death (EP-2 with MasterPlan 3's plan 18).** EP-2 makes a
dead Kafka consume loop observable through its heartbeat and fail-fast process exit, so a
supervisor restarts it without making Kafka a readiness dependency. The actual reconnect/backoff fix — so the loop recovers without a full
restart — is owned by
`docs/plans/18-atomic-stream-consumption-offsets-inbox-and-enqueue-in-one-boundary.md`. EP-2
must not duplicate plan 18's in-loop recovery.

**IP-G — Authenticated HTTP tracing (EP-1 with plan 22).** Plan 22 owns `HttpEnv`,
`TokenSource`, and `postJSONWithHeaders`. EP-1 Milestone 3 adds `traceparent` through that
helper so auth, timeouts, and trace propagation share one request path. Plan 32 consumes the
same helper for kanmon.

**IP-H — Agent inspection (EP-3 with plans 20, 33, and 23).** Plan 20 owns
`AgentLoadReport`; EP-3 renders it and owns the `agents` command group. Plan 33 adds enabled
state to declarations, and plan 23 later extends EP-3's output with principal/lifecycle state
and adds `sync`. No other plan creates an `agents list` parser or walks the directory.

**IP-I — Operator data and dead letters (EP-3 with plans 17 and 38).** Queries use the
public store/query modules or schema-qualified SQL against documented tables; they do
not depend on unqualified `search_path`. Plan 17 creates the real run-job dead-letter
queue. EP-3 provides inspect, repair/replay, and discard commands against that queue,
with confirmation/audit tests. It does not treat PGMQ's incidental archive table as the
operational DLQ. Any operator-side schema change is delivered through plan 38.


## Progress

Milestone-level checklist across all four child plans. Update as each milestone completes.

EP-1 — Structured logging, metrics, and trace propagation:

- [ ] EP-1 M1: `Shikigami.Log` module + every `hPutStrLn stderr` call site replaced;
      `logSinkResult` implemented (no longer a no-op).
- [ ] EP-1 M2: metrics spike promoted; `ShikigamiMetrics` + `withRunTelemetry`; `AppEnv.metrics`
      populated everywhere; queue-depth/outbox/consumer instruments live.
- [ ] EP-1 M3: scheduler and consumers traced; `traceparent` propagated into the outbox;
      `sink.publish` span wraps the outbound HTTP POST with a `traceparent` header.
- [ ] EP-1 M4: OTel provider/exporter lifecycle is bracketed at process composition roots;
      bounded request logging runs inside OTel and excludes health paths.

EP-2 — Health, liveness, and worker loop supervision:

- [ ] EP-2 prerequisite/M1: the released Shibuya probe API and Shikigami server API serve
      exact typed `NamedRoutes`/`MultiVerb` `/health/live` and `/health/ready` routes;
      OpenAPI is generated from each served proxy; Settei owns port configuration.
- [ ] EP-2 M2: per-loop heartbeats feed worker-role `/health/live`; PostgreSQL readiness is exposed
      through `/health/ready` without Kafka or downstream HTTP cascade dependencies.
- [ ] EP-2 M3: fail-fast supervision (loop death exits non-zero); resume loop
      restart-with-backoff.

EP-3 — Operator CLI:

- [ ] EP-3 M1: `agents list`.
- [ ] EP-3 M2: `Shikigami.Operator.Query` + `runs list` / `runs show`.
- [ ] EP-3 M3: `runs cancel --confirm`.
- [ ] EP-3 M4: schema-qualified `dlq inspect|repair|replay|discard` against the real
      dead-letter queue plus `outbox status`.
- [ ] EP-3 M5: confirmation, audit, parser, and command-dispatch gates proven by CLI tests.

EP-4 — Deployable service stack:

- [ ] EP-4 M1: Kafka in the dev shell + full `process-compose` stack + `just dev`.
- [ ] EP-4 M2: end-to-end smoke through the composed stack.
- [ ] EP-4 M3: NixOS module exported + flake eval check.
- [ ] EP-4 M4: Settei configuration reference, pg-migrate startup gate, and graceful
      shutdown/drain behavior documented and proven.


## Surprises & Discoveries

(None yet.)

Seeded research findings that shaped the decomposition (verified 2026-07-08):

- The kikan ecosystem uses **no** structured-logging framework (keiro, shibuya-core,
  kizashi-core, kioku, kawa — no katip/co-log/monad-logger). The idiom is stderr lines plus
  OpenTelemetry spans. This is why EP-1 adds a minimal in-repo JSON logger rather than adopting a
  framework.
- shibuya offers **no** processor-level restart supervision — only `IgnoreFailures` and
  `StopAllOnFailure` (`Shibuya.App:89-98`), neither of which restarts a failed child. This is
  why EP-2 chooses fail-fast + external supervisor rather than in-process restart.
- keiro has **no** top-level "cancel workflow by id"; cancellation is appending the
  `WorkflowCancelled` marker via `appendJournalEntry`. This is why EP-3's `runs cancel` uses the
  journal, not a raw `UPDATE`, and why IP-E exists.
- The current runtime archives poison run jobs because `deadLetterConfig = Nothing`.
  Plan 17 replaces that incidental archive with a real dead-letter queue; EP-3 targets
  the real queue and never couples operator behavior to PGMQ's private archive layout.
- API conformance audit (2026-07-22): health and OTel were covered previously, but the
  plans omitted `NamedRoutes`/`MultiVerb`, same-type OpenAPI generation, RFC 7807,
  middleware ordering, and a bounded request-log whitelist. IP-C/IP-C2 now make the entire HTTP
  contract explicit. Relay pagination is intentionally not required because no public
  list endpoint is planned; any future list endpoint must add it before implementation.
- Package/API conformance audit (2026-07-22): serving the Shikigami server route tree from
  worker executables would violate the six-package dependency budget. Current
  `shibuya-metrics` already owns worker health HTTP, but its handwritten router and legacy
  bodies do not meet the new API standard. EP-2 now hard-depends on an additive released
  Shibuya probe surface with injectable checks, standard typed routes/status documents, and
  same-proxy OpenAPI.
- Deployment conformance audit (2026-07-22): this repository targets process-compose
  locally and a NixOS module in deployment. Kubernetes overlays are therefore not
  applicable unless the deployment target changes; no speculative manifests are added.


## Decision Log

- Decision: Require plan 47 for all operations children and block only plan 29's Shibuya
  worker-probe slice on Shibuya IR-1.
  Rationale: OTel/Shibuya APIs must be ported coherently, but the typed health server and local
  loop-supervision work remain independently deliverable.
  Date: 2026-07-30


- Decision: Decompose Operations & Observability into four plans — observability (28), health &
  supervision (29), operator CLI (30), deployable stack (31) — with EP-1 as the soft-first
  vocabulary owner and no original intra-MasterPlan hard dependencies. The 2026-07-22
  portfolio revision adds plan 20 as EP-3's cross-MasterPlan hard dependency.
  Rationale: the four concerns touch largely disjoint code and each yields a distinct operator-
  visible capability, so they are independently verifiable and can run in parallel. Folding
  health into observability, or the CLI into the stack, was rejected as producing lopsided plans
  with mixed risk profiles (see Decomposition Strategy).
  Date: 2026-07-22

- Decision: Keep intra-MasterPlan dependencies soft, but make plan 20 a cross-MasterPlan
  hard dependency of EP-3. EP-1 M3 also waits for plan 22's authenticated HTTP seam.
  Rationale: health and operator queries remain independent, but `agents list` now consumes
  a concrete shared report and HTTP tracing must compose with authentication rather than
  create a second helper.
  Date: 2026-07-22

- Decision: EP-1 owns the observability vocabulary as an explicit Integration Point (IP-A) that
  MasterPlans 2-5 also consume.
  Rationale: those MasterPlans' plans emit run/sink/timer logs and metrics; without a single
  naming owner the vocabulary would drift across a dozen plans. Centralizing the convention in
  EP-1's Decision Log gives one place to change it.
  Date: 2026-07-08

- Decision: Route the two cross-MasterPlan overlaps (cancellation with plan 17; consume-loop
  death with plan 18) through named integration points (IP-E, IP-F) rather than absorbing that
  work here.
  Rationale: plan 17 owns in-workflow timeout and plan 18 owns Kafka reconnect/atomic
  consumption; this MasterPlan owns only the operator-facing cancel surface and the *observability*
  of loop death. Naming the seams prevents duplicated or conflicting implementations of the same
  keiro marker and the same consume loop.
  Date: 2026-07-08
- Decision: EP-4 is the operations-closure plan and should land after plans 13, 22, and
  32 plus EP-1/EP-2 have stabilized their configuration and health surfaces.
  Rationale: a configuration reference with placeholders immediately becomes stale;
  packaging last lets `just dev` and the NixOS module prove the actual final surface.
  Date: 2026-07-22
- Decision: EP-3 owns the `agents` command group, plan 20 owns its report, and plan 23
  extends it after plan 33 defines declared identity.
  Rationale: this eliminates duplicate CLI parsers and directory traversal across three
  MasterPlans.
  Date: 2026-07-22
- Decision: The public service boundary follows the full API pattern: `NamedRoutes`,
  terminal `MultiVerb`, OpenAPI from the served proxy, RFC 7807 for non-health errors,
  and bounded request logging inside OTel. Health reports are the documented exception.
  Rationale: one typed route tree keeps server behavior, documentation, error variants,
  middleware, and contract tests from drifting.
  Date: 2026-07-22
- Decision: Health uses two package-correct implementations of one wire contract: the public
  server extends `shikigami-api`, while workers consume a released external
  `shibuya-metrics` probe application. Workers never import sibling API/server packages.
  Rationale: this is the only route that preserves both the strict six-package dependency
  graph and exact health endpoints on every deployed process without duplicating a
  handwritten local WAI server.
  Date: 2026-07-22
- Decision: EP-3 operates on plan 17's real dead-letter queue and exposes inspect,
  repair/replay, and discard with confirmation and audit coverage.
  Rationale: PGMQ archive internals are not an operational contract and cannot support
  a truthful remediation workflow.
  Date: 2026-07-22
- Decision: EP-4 deploys through process-compose and NixOS, uses plan 37's Settei
  configuration and plan 38's migration gate, and proves graceful drain/shutdown.
  Kubernetes overlays are out of scope while no Kubernetes target exists.
  Rationale: deployment artifacts should match the actual target and lifecycle instead
  of creating untested parallel configuration surfaces.
  Date: 2026-07-22


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Revision Notes

- 2026-07-30: Added plan 47 and Shibuya IR-1, separated startable health/supervision work
  from the blocked public worker-probe adapter, and reaffirmed the NixOS/non-Kubernetes target.

- 2026-07-22: Added plan 20 as EP-3's hard dependency, routed HTTP tracing through plan
  22, assigned `agents` command ownership, and made EP-4 the portfolio's configuration/
  packaging closure. These changes align MasterPlan 6 with the MP-2 through MP-7 waves.
- 2026-07-22: Split server and worker probe ownership across Shikigami and a required released
  Shibuya probe API so health conformance no longer violates the six-package dependency graph.
- 2026-07-22: Added architecture/Settei/pg-migrate foundations; completed the API best-
  practices pass; corrected DLQ operations; and added OTel lifecycle, graceful shutdown,
  schema qualification, and the explicit NixOS-not-Kubernetes deployment decision.
