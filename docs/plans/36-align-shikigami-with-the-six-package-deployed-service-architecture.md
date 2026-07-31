---
id: 36
slug: align-shikigami-with-the-six-package-deployed-service-architecture
title: "Align Shikigami with the six-package deployed-service architecture"
kind: exec-plan
created_at: 2026-07-22T20:55:26Z
master_plan: "docs/masterplans/2-production-reality-de-stub-the-runtime-behavior-and-integration-path.md"
---

# Align Shikigami with the six-package deployed-service architecture

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami is intended to run as a deployed Keiro service, but its HTTP servers, worker
loops, domain code, operator commands, and dependency acquisition currently share four
Cabal packages whose boundaries do not match the fleet architecture. After this change the
repository has exactly six service packages—`shikigami-core`, `shikigami-api`,
`shikigami-server`, `shikigami-workers`, `shikigami-migrations`, and
`shikigami-client`—with dependency direction enforced by Cabal and package-focused tests.

Existing user-facing capabilities remain available, but long-running worker-role binary names
become explicit and their executables live in the package that owns their runtime role. A
developer can prove the split with `cabal build all`, run
the server and worker independently, and inspect a dependency test that rejects a worker
importing the HTTP API or server implementation.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-07-31T04:44:50Z) M1: add `Shikigami.Prelude` and `Shikigami.App.Config` ownership to core; document the six-package map and executable ownership.
      Done: `Shikigami.Prelude` moved from `shikigami-api` to `shikigami-core`; the three
      declared-agent domain modules moved with it and were renamed to concept names
      (`Shikigami.Api.Agent` → `Shikigami.Agent.Decl`, `Shikigami.Api.Activity` →
      `Shikigami.Activity`, `Shikigami.Api.RunJob` → `Shikigami.Agent.RunJob`);
      `shikigami-core` no longer depends on `shikigami-api` and `shikigami-api` now depends
      on `shikigami-core`; `Shikigami.App.Config` added as the process-configuration
      ownership marker; `Shikigami.Api.Problem` added as the single RFC 7807 body;
      `docs/architecture/packages.md` written; `shikigami-api-test` added, whose
      `package boundary` case is the import proof. `cabal build all` and `cabal test all`
      pass (49 core tests, 8 api tests).
- [x] (2026-07-31T05:05:00Z) M2: create `shikigami-server`, move WAI/Warp and public HTTP composition into it, and add server tests.
      Done: `shikigami-server` created with `Shikigami.Server.{App,Boot,Config,Seam}` and the
      `Shikigami.Health.Handler` concept handler; `Shikigami.Sink.KawaStub`,
      `Shikigami.Sink.KawaStub.Republish`, and `Shikigami.Trigger.Publish` moved out of core
      into it, so core's library no longer depends on `wai` or `warp`; core's test suite
      gained its own `Shikigami.Fixture.KawaStub` doorway. `shikigami-api` gained the
      umbrella `Shikigami.Api` `NamedRoutes` record, `Shikigami.Health.Api` (the owned name
      for `servant-health`'s `MultiVerb` 200/503 probe routes), and `Shikigami.Api.OpenApi`;
      the `shikigami-openapi` executable generates `docs/api/openapi.json`, which is checked
      in. Twelve server tests pass, including `servant-health`'s probe conformance kit, the
      documented-equals-served path check, the 404 and 405 problem renderings, and the proof
      that a passing probe is *not* problem details; fifteen api tests pass, including
      artifact freshness, typed-alternative coverage, operation-id determinism, and schema
      validation of encoded `ProbeStatus` and `ProblemDetails` values.
      Remaining, by design: administrative and test-stub commands still live in
      `shikigami-cli`, which now depends on `shikigami-server` for the moved modules; M4
      redistributes them and deletes that package.
- [x] (2026-07-31T05:25:00Z) M3: create `shikigami-workers`, move queue, subscription, scheduler, outbox, timer, and resume composition into it, and add worker tests.
      Done: `shikigami-workers` created. The old `Shikigami.Worker` — one 230-line module
      holding four loops — was split into vertical modules
      (`Shikigami.Agent.RunJob.Worker`, `Shikigami.Agent.Workflow.Resume`,
      `Shikigami.Flow.SinkOutbox.Publisher`, `Shikigami.Trigger.Timer`) with
      `Shikigami.Workers.Config` holding the shared `WorkerEnv` and each loop's derived
      environment, and `Shikigami.Workers.Registry` doing nothing but starting them.
      `Shikigami.Trigger.Consumer`, `Shikigami.Trigger.Scheduler`, and `Shikigami.Telemetry`
      moved across unchanged; `SchedulerSpec` moved to the new
      `shikigami-workers-test` suite, which provisions through
      `shikigami-migrations:test-support`. Core's library now depends on none of `wai`,
      `warp`, `hs-opentelemetry-sdk`, `hs-opentelemetry-exporter-otlp`, `hw-kafka-client`,
      `kafka-effectful`, `pgmq-effectful`, or `shibuya-pgmq-adapter`; it keeps
      `shibuya-core` for the telemetry effect `Shikigami.Agent.Approval` uses, and
      `pgmq-hasql` for the shared run-job producer. `rg 'shikigami-(api|server)'
      shikigami-workers` prints nothing. Tests: api 15, server 12, core 45, workers 4.
      Remaining, by design: `Shikigami.Workers.Subscription` and the worker executables
      arrive in M4 with the commands they compose.
- [x] (2026-07-31T05:50:00Z) M4: create `shikigami-client`, derive the typed client from `shikigami-api`, redistribute existing CLI executables without adding a seventh package, and remove `shikigami-cli`.
      Done: `shikigami-client` created with `Shikigami.Client` (derived from the served route
      record with `genericClient`, so a call that does not match the API fails to compile)
      and a `shikigami-client health` command. `shikigami-cli` deleted; its eleven command
      modules moved to their owning packages — six to
      `Shikigami.Server.Command.*` behind the `shikigami` administrative executable, five to
      `Shikigami.Workers.{Command.*,Subscription}` behind the six worker-role executables.
      The four duplicated directory loaders became one `Shikigami.Agent.Loader.loadAgentsIn`
      in core. Every parser produces an `IO ()`, so `--help` smoke tests drive
      `execParserPure` directly instead of shelling out: seventeen server tests and twelve
      worker tests now include per-command help coverage, plus three client tests.
      `cabal run shikigami -- --help`, `cabal run shikigami-worker -- --help`, and
      `cabal run shikigami-client -- --help` all render.
      Executables now: `shikigami-server`, `shikigami` (server); `shikigami-worker`,
      `shikigami-scheduler`, `shikigami-consume-stream`, `shikigami-consume-events`,
      `shikigami-run-behavior`, `shikigami-agent-run` (workers); `shikigami-migrate`
      (migrations); `shikigami-client` (client); `shikigami-openapi` (api).
- [ ] M5: enforce package dependency and test-layout invariants; `cabal build all` and `cabal test all` pass.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-31, M1: every build and test command in this plan must run inside the Nix dev
  shell. A bare `cabal build all` compiles every module and then fails at link time
  because `librdkafka` is not on the linker path:

  ```text
  [44 of 44] Compiling Shikigami.Worker ( src/Shikigami/Worker.hs, ... )
  ld: library not found for -lrdkafka
  clang: error: linker command failed with exit code 1
  Error: [Cabal-7125]
  Failed to build shikigami-core-0.1.0.0
  ```

  The dev shell supplies it (`rdkafka-2.13.0-dev` on `PKG_CONFIG_PATH`). Use
  `nix develop --command cabal build all` — or run inside `nix develop` — for every
  command in this plan.

- 2026-07-31, M1: the target dependency graph requires `shikigami-api` to depend on
  `shikigami-core`, which is the reverse of the arrow that existed. Everything that made
  the old arrow necessary — `AgentDecl`, `ActivityEnvelope`, `RunJob`, and the project
  prelude — is domain, not HTTP contract, so the fix was to move those four modules into
  core rather than to weaken the graph. Nothing in `shikigami-api` was left behind, so
  the package was re-founded around the public HTTP contract it is named for.

- 2026-07-31, M1: `servant-health 0.1.0.0` (Hackage, `shinzui/servant-health`) already
  ships exactly the probe surface this plan's first route needs — `HealthApi`,
  `ProbeStatus`, typed 200/503 `MultiVerb` responses, a check seam, path constants, and
  a `testkit` sublibrary that proves a service's own wiring. It also pins the OpenAPI
  cohort question: it depends on `openapi-hs >=5.0 && <5.1` and documents that the
  upstream `openapi3`/`servant-openapi3` lineage has no `HasOpenApi` instance for
  `MultiVerb` at all. That settles the cohort as `openapi-hs 5.0` /
  `servant-openapi-hs 5.1` / `servant 0.20.3`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Treat Shikigami as a deployed Keiro service and adopt the six-package split without an exception.
  Rationale: MasterPlan 6 explicitly turns Shikigami into an operated service. The teaching-repository exception therefore does not apply.
  Date: 2026-07-22
- Decision: Preserve command capabilities as executable components inside the six packages
  rather than retaining `shikigami-cli` as a seventh package. The target executables are:
  `shikigami-server`; server-owned `shikigami` for direct administrative, validation,
  enqueue, and test-stub commands; `shikigami-worker`, `shikigami-scheduler`,
  `shikigami-consume-stream`, `shikigami-consume-events`, `shikigami-run-behavior`, and
  `shikigami-agent-run` in workers; `shikigami-migrate`; and `shikigami-client`.
  Rationale: Cabal packages are dependency boundaries; a package may own several executables.
  Keeping the server-owned administrative spelling minimizes unnecessary churn, while a
  single umbrella process dispatcher cannot honestly import both server and worker
  implementation without violating the dependency graph. Deployment docs and aliases migrate
  the four long-running worker spellings atomically.
  Date: 2026-07-22
- Decision: Make the new server boundary conform to the complete API standard from its first route.
  Rationale: Health is the first production HTTP surface. Defining it as a typed Servant API avoids creating a hand-written WAI route that would immediately need replacement.
  Date: 2026-07-22

- Decision: Move the declared-agent domain types into `shikigami-core` and rename them to
  concept-first module names: `Shikigami.Api.Agent` → `Shikigami.Agent.Decl`,
  `Shikigami.Api.Activity` → `Shikigami.Activity`, `Shikigami.Api.RunJob` →
  `Shikigami.Agent.RunJob`.
  Rationale: the target graph has `shikigami-api` depending on `shikigami-core`, and core
  imports all three types everywhere, so leaving them in the api package would be a cycle.
  They are Dhall-decoded domain declarations and queue payloads, not HTTP DTOs, so core is
  where they belong. The rename follows because `Api` is a layer name, and after this plan
  `Shikigami.Api` is the umbrella route record — a `Shikigami.Api` in one package and a
  `Shikigami.Api.Agent` in another would read as a single hierarchy that is not one.
  The cost is that other plan documents cite the old paths; those citations are updated
  when each plan is implemented, and this entry is the mapping they need.
  Date: 2026-07-31

- Decision: Read "a core-only test build must not link ... a queue adapter" as the
  supervised consumer side — `shibuya-pgmq-adapter` and `pgmq-effectful` — and keep
  `pgmq-hasql` in `shikigami-core`.
  Rationale: `Shikigami.Trigger.Enqueue` is the domain contract for *producing* a run job,
  and two packages that may not see each other legitimately produce them: the workers'
  scheduler and the server-owned `enqueue-run` command. Core is the only place both may
  reach. Moving it to workers would force `shikigami-server` to depend on
  `shikigami-workers`, which the graph forbids; duplicating it would give the queue two
  producers that could drift. The forbidden thing — a supervised processor draining a
  queue inside core — remains forbidden and is asserted by the M5 invariant test.
  Date: 2026-07-31

- Decision: Extend the composition-module allowlist with `Shikigami.Server.Command`,
  `Shikigami.Server.Command.*`, `Shikigami.Workers.Command`, and
  `Shikigami.Workers.Command.*`.
  Rationale: this plan requires a `--help` smoke test for every executable component. With
  the option parsers buried in each executable's `app/` directory, a test could only shell
  out to a built binary, which needs `build-tool-depends`, is slow, and proves less.
  Exposing one parser module per package lets the tests drive `optparse-applicative`'s
  `execParserPure` directly. The allowlist is recorded in `docs/architecture/packages.md`
  so the extension is explicit rather than a quiet exception.
  Date: 2026-07-31

- Decision: Build the first route on `servant-health 0.1.0.0` rather than hand-rolling a
  health route, and expose it as the Shikigami-owned name `Shikigami.Health.Api`.
  Rationale: it is a released fleet package providing exactly the standard this plan
  demands — two routes, `MultiVerb` 200/503 alternatives, a fixed probe body with a
  non-orphan `ToSchema`, and a conformance testkit. Wrapping it in an owned module gives
  `docs/plans/29-health-liveness-and-worker-loop-supervision.md` one module to extend.
  Date: 2026-07-31

- Decision: Error bodies carry a fixed per-code `detail` and never the parser's own
  message.
  Rationale: Servant's parse messages can echo the request body — which may contain a
  secret the caller sent — and name internal types. The API standard forbids exposing
  internal or security-sensitive detail. Operators get specifics from structured logging
  (`docs/plans/28-structured-logging-metrics-and-trace-propagation.md`); callers get a
  stable `code` to branch on.
  Date: 2026-07-31

- Decision: `Shikigami.Telemetry` — the OpenTelemetry provider and exporter bootstrap —
  moves to `shikigami-workers` rather than staying in core or being duplicated.
  Rationale: it constructs an SDK tracer provider and an OTLP exporter, which the
  architecture puts at executable boundaries, and today only the worker executable calls
  it. `shikigami-server` cannot import it (server may not depend on workers), and there is
  no shared non-core home; when the server needs its own OTLP bootstrap it defines one
  under `Shikigami.Server.Boot`. Plans 28 and 31 cite the old core path
  (`shikigami-core/src/Shikigami/Telemetry.hs`) and update to the workers path when they
  are implemented.
  Date: 2026-07-31

- Decision: Split the old `Shikigami.Worker` into one module per loop rather than moving
  it across intact.
  Rationale: the plan requires domain-first module paths in the workers package and a
  `Shikigami.Workers.Registry` that composes processors without absorbing their behavior.
  One module holding the queue processor, the resume worker, the outbox publisher, the
  timer loop, and the environment plumbing is the opposite of that: every later plan that
  touches one loop — 17 for retry semantics, 19 for delivery truth, 20 for routing — would
  edit the same file. The split is behavior-preserving; only the module boundaries moved.
  Date: 2026-07-31

- Decision: Core's test suite keeps its own minimal kawa doorway fixture
  (`shikigami-core/test/Shikigami/Fixture/KawaStub.hs`) rather than importing the
  production `stub-kawa` server.
  Rationale: the production stub is a listener, so it moved to `shikigami-server`, and core
  may not depend on that package. The kawa sink client still needs a downstream to POST
  against, and the plan explicitly allows test-only downstream stubs to live with their
  owning fixture. The fixture is the doorway contract only — accept
  `POST /v1/sources/{source}/events`, deduplicate on `(source, source_event_id)` — with no
  Kafka re-publishing, and mints counter ids so a failing assertion prints `act_1` rather
  than a random TypeID.
  Date: 2026-07-31

- Decision: The problem catalog has one `invalid_url` code rather than separate
  `invalid_path` and `invalid_query` codes.
  Rationale: Servant routes both capture failures and query-parameter failures through a
  single `urlParseErrorFormatter` with no reliable way to tell them apart, so two codes
  would mean guessing, and a guessed code is worse than a coarser true one.
  Date: 2026-07-31


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository currently contains `shikigami-core`, `shikigami-api`, `shikigami-cli`, and
`shikigami-migrations`. `shikigami-core/shikigami-core.cabal` directly depends on WAI,
Warp, Kafka clients, Shibuya, OpenTelemetry SDK/exporter packages, and the domain/runtime
libraries. Its exposed modules include `Shikigami.Worker`, trigger consumers, HTTP sink
stubs, and telemetry. `shikigami-cli/shikigami-cli.cabal` owns the `shikigami`
executable and composes workers, schedulers, consumers, stubs, validation, and operator
commands. `shikigami-api` currently owns `Shikigami.Prelude`, even though the fleet rule
places the custom Prelude in core.

A package is a compile-time dependency boundary. A vertical is a domain concept, such as
agent runs, conversations, sinks, or integrations, whose modules keep the same
`Shikigami.<Concept>.*` prefix across packages. Package names express runtime layers;
module names express concepts. Technical composition modules are limited to the standard
allowlist: `Shikigami.Server.{App,Boot,Config,Seam}` and
`Shikigami.Workers.{Config,Registry,Subscription}`.

The target dependency graph is:

```text
shikigami-core          <- api, server, workers
shikigami-api           <- server, client
shikigami-server        <- core, api
shikigami-workers       <- core
shikigami-migrations    <- no Shikigami sibling production library
shikigami-client        <- api
```

Production test suites may depend on the public
`shikigami-migrations:test-support` sublibrary. Production libraries may not.


## Plan of Work

Milestone 1 establishes ownership before moving behavior. Create
`shikigami-core/src/Shikigami/Prelude.hs` following the repository's GHC2024 custom-Prelude
pattern and move shared exports out of `shikigami-api/src/Shikigami/Prelude.hs`. The
Prelude must not re-export `Data.Generics.Labels`; modules using `#field` import that
instance locally. Add a placeholder `Shikigami.App.Config` module whose real Settei
surface is owned by `docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md`.
Write `docs/architecture/packages.md` with the six packages, executable ownership, allowed
dependency arrows, and module-placement rules. Acceptance is a core build and an import
test proving API can consume core without a cycle.

Milestone 2 creates `shikigami-server/shikigami-server.cabal`. Move production WAI/Warp
composition and health serving out of core. The server package owns
`Shikigami.Server.App`, `Shikigami.Server.Boot`, `Shikigami.Server.Config`,
`Shikigami.Server.Seam`, and per-concept handlers. Test-only downstream stubs may remain
with their owning integration test fixture, but no production listener stays in core.
Define an umbrella `Shikigami.Api` `NamedRoutes` record in `shikigami-api`; every terminal
route uses `MultiVerb`. Application JSON errors use RFC 7807 problem details with
`application/problem+json`. Define one `ProblemDetails` codec/schema whose exact wire keys are
`type`, `title`, `status`, `detail`, `code`, and `retryable`; keep `type = "about:blank"` until
real documentation URIs exist, make title stable per code, and never expose internal/security
detail. Declare each problem alternative with `RespondAs ProblemJSON` in the terminal response
list and map domain faults through one total catalog/result function. Server error formatters
cover body, URL, header, and not-found failures; a narrow WAI rewrite covers Servant's otherwise
empty 405 response. Auth/rate-limit middleware uses the same renderer. Health status bodies are
explicitly exempt. Generate
`docs/api/openapi.json` from the exact served proxy using a dedicated executable in the
API package and a coherent released `openapi-hs`/`servant-openapi-hs` cohort; verify Hackage
and upstream tags before choosing bounds and never substitute the `openapi3` packages, whose
current lineage omits `MultiVerb` responses. Never hand-edit the artifact. Assign stable
deterministic `operationId`s, provide wire-accurate `ToSchema`/`ToParamSchema` instances
(including explicit `additionalProperties` for opaque `Value` and `oneOf` for hand-written
tagged unions where applicable), and have the client package consume the same route type.
Add dispatch tests for same-typed routes. Add conformance tests proving the generated path set
equals the served set, every typed response/status/media type appears, representative encoded
DTOs validate against their schemas, and regeneration leaves the checked artifact clean in CI.
Relay keyset pagination is required only when a public list endpoint is later introduced; this
plan creates none.

Milestone 3 creates `shikigami-workers/shikigami-workers.cabal`. Move
`Shikigami.Worker`, queue processing, Kafka/Kiroku subscriptions, scheduler composition,
outbox publishing, workflow resumption, and timer loops under domain-first module paths in
the workers package. `Shikigami.Workers.Registry` composes processors but does not absorb
their behavior. The package depends on core, Keiro, Shibuya, and adapters, never API or
server. In particular, worker-role probe servers come from the external released
`shibuya-metrics` surface required by plan 29; workers do not import the sibling
`Shikigami.Health.Api` route tree merely to expose health. Add worker tests under
`shikigami-workers/test/Shikigami/<Concept>/...` using the migrations test-support database.

Milestone 4 creates `shikigami-client/shikigami-client.cabal` and derives a typed client
with `genericClient` from `shikigami-api`. Remove the `shikigami-cli` package after moving
its executable components: worker/scheduler/consumer entry points into workers, server and
direct administrative commands into server, migration commands into migrations, and
remote client commands into client. Implement the explicit executable map in the Decision
Log, update docs/process definitions atomically, and add `--help` smoke tests for every
component. Do not introduce a cross-package umbrella dispatcher or utility package.

Milestone 5 removes now-illegal dependencies from core. OpenTelemetry SDK/exporter and WAI
instrumentation belong at executable boundaries; core may retain only domain-level OTel API
types required by Keiro. Add a repository test that parses the Cabal files and asserts the
six package names and forbidden sibling edges. Mirror source verticals in core, server, and
worker tests. Finish with the full build and test suite.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`:

```bash
nix develop
cabal build all
cabal test all
```

Inspect the package set and forbidden edges:

```bash
find . -maxdepth 2 -name '*.cabal' -print | sort
rg 'shikigami-(api|server)' shikigami-workers
rg 'servant-server|warp|hs-opentelemetry-sdk' shikigami-core/shikigami-core.cabal
```

The first command lists exactly the six Shikigami package files. The two `rg` checks print
no production dependency violations. Regenerate and check the public API artifact:

```bash
cabal run shikigami-openapi
git diff --exit-code docs/api/openapi.json
```


## Validation and Acceptance

Acceptance requires all six packages to build independently and `cabal test all` to pass.
Starting `shikigami-server` must not start background workers; starting
`shikigami-worker` must not open an application HTTP API listener. The health API added by
plan 29 must be served through the same typed route proxy used by OpenAPI generation. A
core-only test build must not link Warp, servant-server, an OTel SDK/exporter, or a queue
adapter. Database-backed core/server/worker tests must provision through
`shikigami-migrations:test-support`.


## Idempotence and Recovery

Move modules in small compiling slices and keep temporary re-export modules when needed so
each commit builds. Do not delete `shikigami-cli` until every command has an owning
executable and its smoke test passes. Cabal moves are recoverable by restoring the prior
module and package declaration; no database or wire format changes occur in this plan.


## Portfolio Reconciliation (2026-07-30)

This remains the first foundation plan and has no plan-47 dependency. It must land before
plan 37 and define the package/composition-root ownership into which Settei and the dependency
cohort are ported. Avoid temporary package shapes that the upgrade would immediately remove.


## Interfaces and Dependencies

This plan hard-precedes `docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md`
because Settei's per-binary config modules need stable package owners. It also precedes
plans 28–31 and plan 39. `shikigami-api` owns route records and DTOs but not handler
execution. `shikigami-server` owns Servant/WAI execution, bounded request logging, and HTTP
provider lifetimes. `shikigami-workers` owns Shibuya-supervised loops and graceful drain.
`shikigami-client` owns the typed client. All new Haskell records use direct, unprefixed,
strict fields, explicit deriving strategies, and generic-lens access/update where the
record derives `Generic`.


Revision note (2026-07-22): Created from the portfolio conformance review so every later
production, configuration, API, worker, and deployment plan has stable package boundaries.
