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

- [ ] M1: add `Shikigami.Prelude` and `Shikigami.App.Config` ownership to core; document the six-package map and executable ownership.
- [ ] M2: create `shikigami-server`, move WAI/Warp and public HTTP composition into it, and add server tests.
- [ ] M3: create `shikigami-workers`, move queue, subscription, scheduler, outbox, timer, and resume composition into it, and add worker tests.
- [ ] M4: create `shikigami-client`, derive the typed client from `shikigami-api`, redistribute existing CLI executables without adding a seventh package, and remove `shikigami-cli`.
- [ ] M5: enforce package dependency and test-layout invariants; `cabal build all` and `cabal test all` pass.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


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
