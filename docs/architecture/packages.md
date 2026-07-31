# Shikigami package architecture

Shikigami is a deployed service, so the repository follows the fleet's six-package
deployed-service layout. This document is the authoritative statement of which package
owns what, which dependency arrows are legal, where a new module belongs, and which
executable owns each user-facing command. It is owned by
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`;
change it only through a plan revision.


## Vocabulary

A *package* is a Cabal package — a compile-time dependency boundary. Cabal, not
convention, enforces the arrows below: if `shikigami-workers` does not list
`shikigami-api` in `build-depends`, a worker module physically cannot import an HTTP
route type.

A *vertical* is a domain concept — agent runs, activities, triggers, sinks, flows,
memory, health. A vertical keeps the same `Shikigami.<Concept>.*` module prefix in
every package it appears in. **Package names express runtime layers; module names
express concepts.** `Shikigami.Sink.Danwa` is the danwa sink wherever it lives;
the package it lives in tells you whether it is domain logic, server wiring, or a
worker loop.

A *composition module* is a module whose job is wiring rather than behavior — building
an `Application`, assembling a processor registry, resolving configuration. Composition
modules are the one place technical names are allowed, and only from a fixed allowlist
(below).


## The six packages

| Package | Role | Depends on (Shikigami siblings) |
|---|---|---|
| `shikigami-core` | Domain: declarations, agent runs, behaviors, flows, sinks, memory, durable workflow logic | none |
| `shikigami-api` | Public HTTP contract: Servant route records, DTOs, problem details, OpenAPI generation | `shikigami-core` |
| `shikigami-server` | Servant/WAI execution, HTTP provider lifetimes, administrative and test-stub commands | `shikigami-core`, `shikigami-api` |
| `shikigami-workers` | Supervised background loops: queue processing, stream subscriptions, scheduler, outbox, timers, resume | `shikigami-core` |
| `shikigami-migrations` | Database evolution and the public `test-support` sublibrary | none |
| `shikigami-client` | Typed HTTP client derived from the served route type | `shikigami-api` |

The legal arrows, and only these:

```text
shikigami-api     -> shikigami-core
shikigami-server  -> shikigami-core, shikigami-api
shikigami-workers -> shikigami-core
shikigami-client  -> shikigami-api
```

Read the other way round: `shikigami-core` is consumed by api, server, and workers;
`shikigami-api` is consumed by server and client. Every other sibling edge is
forbidden. In particular `shikigami-workers` must never depend on `shikigami-api` or
`shikigami-server`, `shikigami-server` must never depend on `shikigami-workers`, and
`shikigami-core` must never depend on any sibling.

`shikigami-migrations` depends on no Shikigami sibling *production library*. Production
test suites in any package may depend on the public `shikigami-migrations:test-support`
sublibrary; production libraries may not.


## What may not appear in `shikigami-core`

`shikigami-core` is the domain. Its **library** stanza must not depend on:

- `wai`, `warp`, `servant-server` — HTTP serving belongs to `shikigami-server`.
- `hs-opentelemetry-sdk`, `hs-opentelemetry-exporter-otlp` — provider and exporter
  lifetimes belong at executable boundaries. Core may depend on
  `hs-opentelemetry-api` for the domain-level span/tracer types Keiro requires.
- `shibuya-pgmq-adapter`, `pgmq-effectful` — the supervised queue *adapter* and its
  effect interpreter belong to `shikigami-workers`.
- `hw-kafka-client`, `kafka-effectful` — stream consumers belong to
  `shikigami-workers`; the fixture producer belongs to `shikigami-server`.

Core *does* keep `pgmq-hasql`. `Shikigami.Trigger.Enqueue` is the domain contract for
producing a run job — a `SendMessage` against a named queue through the shared hasql
pool. Both the workers' scheduler and the server's `enqueue-run` command legitimately
produce run jobs, and both may only reach it through core. The forbidden thing is the
*consumer* side: the shibuya adapter and its supervised processors.

Test suites are held to a weaker rule. A test suite may run a WAI/Warp downstream stub
so that an HTTP sink client can be exercised end to end; that is what "test-only
downstream stubs may remain with their owning integration test fixture" means. The
mechanical invariant asserted by
`shikigami-core/test/Shikigami/PackageArchitectureSpec.hs` is stated over library
stanzas.


## Module placement rules

1. A module lands in the package that owns its *runtime role*, and keeps the module
   name of its *concept*. Moving `Shikigami.Trigger.Consumer` from core to workers does
   not rename it; it is still the trigger vertical.
2. Technical composition module names are limited to this allowlist:
   - `Shikigami.Server.App`, `Shikigami.Server.Boot`, `Shikigami.Server.Config`,
     `Shikigami.Server.Seam`
   - `Shikigami.Workers.Config`, `Shikigami.Workers.Registry`,
     `Shikigami.Workers.Subscription`
   - `Shikigami.Server.Command`, `Shikigami.Server.Command.*`,
     `Shikigami.Workers.Command`, `Shikigami.Workers.Command.*` — the option parsers
     and entry actions of each package's executables. These are exposed rather than
     buried in `app/` so that a `--help` smoke test can drive the parser purely with
     `optparse-applicative`'s `execParserPure` instead of shelling out to a built
     binary.
   Everything else is a concept module.
3. A composition module composes; it does not absorb behavior. `Shikigami.Workers.Registry`
   builds the processor map, but each processor's logic lives in its own vertical module.
4. New Haskell records use direct, unprefixed, strict fields, explicit deriving
   strategies, and generic-lens access where the record derives `Generic`.
5. `Shikigami.Prelude` lives in `shikigami-core` and is the project-wide prelude. It must
   not re-export `Data.Generics.Labels`; modules using `#field` import that instance
   locally, because the label syntax collides with the keiki builder DSL.


## Executable ownership

A Cabal package may own several executables. Long-running role binaries are named for
their role and live in the package that owns that role.

| Executable | Package | What it does |
|---|---|---|
| `shikigami-server` | `shikigami-server` | Serves the public HTTP API. Starts no background workers. |
| `shikigami` | `shikigami-server` | Administrative, validation, enqueue, and test-stub commands: `validate`, `render-lifecycle`, `enqueue-run`, `publish-fixture`, `stub-kawa`, `danwa-spike`. |
| `shikigami-worker` | `shikigami-workers` | Drains `shikigami_run_jobs`, runs agents, dispatches sinks, publishes the outbox, resumes workflows, fires timers. Opens no application HTTP listener. |
| `shikigami-scheduler` | `shikigami-workers` | Arms Schedule triggers and drives keiro timer firing. |
| `shikigami-consume-stream` | `shikigami-workers` | Consumes `activity.v1` and enqueues matching run jobs. |
| `shikigami-consume-events` | `shikigami-workers` | Consumes public integration events and enqueues addressed run jobs. |
| `shikigami-run-behavior` | `shikigami-workers` | Runs one agent's behavior with deterministic stubs (no database, no key). |
| `shikigami-agent-run` | `shikigami-workers` | Runs one agent through the kioku session/memory lifecycle. |
| `shikigami-migrate` | `shikigami-migrations` | Applies database migrations. |
| `shikigami-client` | `shikigami-client` | Calls a running server through the typed client. |
| `shikigami-openapi` | `shikigami-api` | Regenerates `docs/api/openapi.json` from the served route proxy. |

There is no umbrella dispatcher binary and no utility package. A single process that
dispatched into both server and worker implementations could not honestly satisfy the
dependency graph.


## The public HTTP API standard

`shikigami-api` owns the contract; `shikigami-server` owns execution.

- One umbrella `Shikigami.Api` record with `NamedRoutes`. Every terminal route uses
  `MultiVerb` so that each status code, media type, and response body is part of the type.
- Application JSON errors are RFC 7807 problem details served as
  `application/problem+json`. There is exactly one `ProblemDetails` codec and schema
  (`Shikigami.Api.Problem`) whose wire keys are exactly `type`, `title`, `status`,
  `detail`, `code`, and `retryable`. `type` stays `"about:blank"` until real
  documentation URIs exist; `title` is stable per `code`; neither carries internal or
  security-sensitive detail.
- Each problem alternative is declared with `RespondAs ProblemJSON` in the terminal
  response list, and domain faults map to it through one total catalog function.
- Server error formatters cover body, URL, header, and not-found failures, and a narrow
  WAI rewrite covers Servant's otherwise empty 405 response. Auth and rate-limit
  middleware use the same renderer. Health status bodies are explicitly exempt: a
  degraded health check is a status report, not an error.
- `docs/api/openapi.json` is generated, never hand-edited, from the exact proxy the
  server serves, using the released `openapi-hs` / `servant-openapi-hs` cohort. The
  `openapi3` lineage is not a substitute: it does not model `MultiVerb` responses.
- Operation ids are stable and deterministic. `ToSchema` / `ToParamSchema` instances are
  wire-accurate, including explicit `additionalProperties` for opaque `Value` and
  `oneOf` for hand-written tagged unions.
- Relay keyset pagination is required for any public list endpoint. This plan introduces
  none.

Regenerate and verify with:

```bash
cabal run shikigami-openapi
git diff --exit-code docs/api/openapi.json
```
