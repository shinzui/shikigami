# Shikigami package architecture

Shikigami is a deployed service, so the repository follows the fleet's six-package
deployed-service layout — **plus one**, `shikigami-agent`, for the one-off runs described
under [Two ways to use Shikigami](#two-ways-to-use-shikigami). This document is the
authoritative statement of which package owns what, which dependency arrows are legal, where a new module belongs, and which
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
express concepts.** `Shikigami.Sink.Delivery` is the outbox delivery record wherever it lives;
the package it lives in tells you whether it is domain logic, server wiring, or a
worker loop.

A *composition module* is a module whose job is wiring rather than behavior — building
an `Application`, assembling a processor registry, resolving configuration. Composition
modules are the one place technical names are allowed, and only from a fixed allowlist
(below).


## Two ways to use Shikigami

Shikigami is deliberately usable two ways, and the second is a requirement rather than a
side effect.

The **deployed service** is the one the six-package layout is built for: a server, supervised
background loops, Kafka, PGMQ, Postgres, and the Kikan platform around it.

A **one-off agent run** is the other. Someone who is *not* running Kikan takes a declared
agent and runs it once, from a command line, against a payload or a repository. This is what
makes Shikigami versatile to consumers with simpler needs, and **Kikan itself does not use
it**. It is served by `shikigami-agent`, which depends on `shikigami-core` and the migration library for its read-only startup check,
so a consumer building it acquires none of the platform's messaging, queueing, or
telemetry-export stack — in particular not `librdkafka`, the C library behind
`hw-kafka-client`.

Treat that as a constraint on future changes, not a convenience. It has been lost once: plan
36 deleted the `shikigami-cli` package in 2026-07-30 as an umbrella dispatcher, correctly on
the architecture, without knowing the package also carried this use case — because the use
case was written down nowhere. It is written down here now so the next architecture change has
to argue against it explicitly.


## The seven packages

| Package | Role | Depends on (Shikigami siblings) |
|---|---|---|
| `shikigami-core` | Domain: declarations, agent runs, behaviors, flows, sinks, memory, durable workflow logic | none |
| `shikigami-agent` | One-off agent runs for consumers not operating the platform | `shikigami-core`, `shikigami-migrations` |
| `shikigami-api` | Public HTTP contract: Servant route records, DTOs, problem details, OpenAPI generation | `shikigami-core` |
| `shikigami-server` | Servant/WAI execution, HTTP provider lifetimes, administrative and test-stub commands | `shikigami-core`, `shikigami-api`, `shikigami-migrations` |
| `shikigami-workers` | Supervised background loops: queue processing, stream subscriptions, scheduler, outbox, timers, resume | `shikigami-core`, `shikigami-migrations` |
| `shikigami-migrations` | Database evolution and the public `test-support` sublibrary | none |
| `shikigami-client` | Typed HTTP client derived from the served route type | `shikigami-api` |

The legal arrows, and only these:

```text
shikigami-agent   -> shikigami-core, shikigami-migrations
shikigami-api     -> shikigami-core
shikigami-server  -> shikigami-core, shikigami-api, shikigami-migrations
shikigami-workers -> shikigami-core, shikigami-migrations
shikigami-client  -> shikigami-api
```

Read the other way round: `shikigami-core` is consumed by agent, api, server, and workers;
`shikigami-api` is consumed by server and client. Every other sibling edge is
forbidden. In particular `shikigami-workers` must never depend on `shikigami-api` or
`shikigami-server`, `shikigami-server` must never depend on `shikigami-workers`, and
`shikigami-core` must never depend on any sibling.

The workspace supervisor's wire codecs and bounded, peer-checked Unix client
live in core (`Workspace.Protocol`, `Workspace.RpcClient` and
`Workspace.TransferClient`) so worker and administrative roles share them.
Listener adoption, supervisor dispatch and process execution remain in workers;
operator transfer control does not introduce a server-to-workers dependency.

`shikigami-migrations` depends on no Shikigami sibling *production library*. Production
test suites in any package may depend on the public `shikigami-migrations:test-support`
sublibrary; production libraries may not.


## Flow packs

[ADR 0129](../adr/0129-the-kernel-owns-primitives-and-use-cases-ship-as-declarations-or-packs.md)
moves the extension point out of `shikigami-core`. A use case that needs Haskell ships as a
*flow pack*, and a *distribution* composes packs into executables. Neither is one of the seven
packages, and neither takes the `shikigami-` prefix. They live under `packs/` or in another
repository. [Flows](../user/flows.md#flow-packs) walks through writing one.

`shikigami-core` exposes two public sublibraries for them, both re-exporting facade modules
of the main library:

| Component | Re-exports | Imported by |
| --- | --- | --- |
| `shikigami-core:flow-sdk` | `Shikigami.Flow.Sdk`, `Shikigami.Flow.Sdk.Program`, and the kernel vocabulary a body names | flow bodies and the pack value |
| `shikigami-core:pack-sdk` | `Shikigami.Pack.Sdk`, and the kernel modules an interpreter calls | a pack's interpreter |

Both stanzas also re-export whole kernel modules. The exact lists are the
`reexported-modules` of each stanza, pinned in `kernel.sdkModules` of
`tools/style/module-ownership.json`.

The legal arrows are:

```text
pack bodies sublibrary -> shikigami-core:flow-sdk
pack library           -> shikigami-core:flow-sdk, shikigami-core:pack-sdk, its own bodies
distribution           -> packs, and the role packages whose entry points it calls
```

None of the seven packages may depend on a pack or a distribution. A pack holds a library, a
`bodies` sublibrary and a test suite, and no executable. A distribution holds executables and
no library; each `main` passes its packs to `agentRunRoleInfoWith`, `workerRoleInfoWith` or
`runAdminWith`. A pack's test suite may depend on `shikigami-core` and on
`shikigami-migrations:test-support`; its libraries may not.

`packs/kikan-shikigami` is the distribution for organizational use. It composes the Kikan
binding and every pack into `kikan-shikigami-worker`, `kikan-shikigami-server`, `kikan-shikigami-scheduler`, `kikan-shikigami-consume-stream`, `kikan-shikigami-consume-events`,
the `kikan-shikigami` admin command and `kikan-shikigami-agent-run`, all reading one list in
`src-shared/Packs.hs`. The two consumers are the only stream consumers there are: their Kafka
transport and roles are the binding's `intake` library (`Kikan.Shikigami.Binding.Intake`), kept
apart from the binding so nothing else links a Kafka client, and the record processing they
hand each delivery to is the kernel's `Shikigami.Trigger.Intake` in `shikigami-workers`
(plan 135, M5). The admin command also mounts the Kikan service stubs, `stub-kawa` and
`stub-kanmon`, and the `publish-fixture` producer, compiled from `admin/`. Its test suite, `kikan-shikigami-test`, holds what needs composed use cases
together, such as the watchdog observing work the initiative pack admitted, the Kikan
outputs delivered through the kernel's publisher, and the stubs.

`packs/kikan-shikigami-binding` is the *Kikan binding*: the one pack that knows Kikan's
services. It is held to the same rule as any pack library (the two SDK components, nothing a
light package forbids), and [plan 135](../plans/135-move-the-kikan-service-bindings-out-of-shikigami-core-and-compose-a-kikan-distribution.md)
moved the Kikan-En authority (M2), the Kikan outputs, their clients, settings and approval
channels (M3), the Rei objective tracker provider (M4, with its real-Rei qualification
suite), and the Danwa conversation channel and the Kawa intake (M5) into it from
`shikigami-core`. The conversation workflow itself stays a kernel primitive; the binding's
`Kikan.Shikigami.Binding.Conversation` is its Danwa channel. The binding also publishes
`kikan-shikigami-binding:outputs`, the typed output configurations and directing helpers
(`toRecipient`, `inThread`) a pack's bodies may import, `kikan-shikigami-binding:intake`, the
Kafka transport and the two consumer roles (the only library here that links a Kafka client,
and the only one that may depend on `shikigami-workers`), and
`kikan-shikigami-binding:test-support`, its fixtures. The boundary check refuses any stock
stanza that depends on a Kikan client or stream library and any stock source that imports a
Kikan module ([ADR-131](../adr/0131-one-kernel-is-composed-two-ways-and-kikan-services-are-bindings.md)).
`kikan-shikigami flows` lists it under `packs:` with what it contributes; the stock
`shikigami flows` does not list it.

A pack contributes these through its one `FlowPack` value: `flows`, with decision
programs and tasks; `settings`, the configuration keys it owns; `triggers`, its say over
stream intake and scheduled ticks for the agents that run its flows; `adminVerbs`, its
operator verbs; `gauges`, levels the worker samples for it; `authorities`, the action
authorities it registers; `outputs`, the output kinds it delivers
(`Shikigami.Output.Registration`); `approvalChannels`, the channels it can ask a person
through (`Shikigami.Approval.Channel`); `trackerProviders`, the objective tracker providers
it installs by adapter revision (`Shikigami.Objective.Tracker.Provider`); and, at run time,
events on the kernel's `shikigami.pack.events` counter. A pack may also publish a
`test-support` sublibrary for tests; that one may depend on the worker package, which the
pack's own library may not. The stock
executables run kernel behaviors and declared agents only; a use case that ships as a pack
runs from the distribution.

The stock executables compose only the builtin pack (`Shikigami.Flow.Builtin`), which holds
the two flows that are kernel primitives, `run-declared-tool` and `adaptive-delivery`, so the
frozen Nix closure of
[ADR-39](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md) and the light
one-off package of ADR-3 are unchanged. The Nix role packages in `flake.module.nix` are built
from the stock executables and therefore offer none of the packs below; the distribution has
no Nix role package yet. `packs/flow-pack-examples` and `packs/examples-distribution` were the
first pair.

[ADR 0130](../adr/0130-use-case-subsystems-leave-the-kernel-by-recorded-disposition.md)
records which subsystems left the core and which stayed. Router, recurring mandates and the
adaptive-delivery coordinator are kernel; the watchdog, unrequested-work proposals, practice
review and the teaching flows are the four packs in the table below.

| Pack | Flows | Setting | Tables it owns |
| --- | --- | --- | --- |
| `flow-pack-examples` | `at-risk-customer`, `objective-example`, `shikumi-decision-example`, `shikumi-judgment-example`, `delegation-proof` | none | none |
| `flow-pack-practice-review` | `architecture-practice-router`, `opentelemetry-practice-review` | `practice_review.attention_recipients` | `shikigami.practice_review_attention`, `shikigami.practice_review_attention_reviews` (migration `0012`), `shikigami.practice_review_identities` (`0032`) |
| `flow-pack-initiative` | `propose-work` | `initiatives` | `shikigami.initiative_candidates`, `shikigami.initiative_proposals` and the other tables of migrations `0043` and `0044` |
| `flow-pack-watchdog` | `watchdog-sweep` | `watchdog` | the `shikigami.watchdog_*` tables |

A pack's tables stay in `shikigami-migrations/sql-migrations/`: migrations are one ordered,
locked chain for one schema, and this table records which pack reads and writes each.

`just kernel-fitness` enforces these arrows, pins both stanzas' `reexported-modules` and each
facade's export list (`shikigami-core/test/golden/sdk/`), and refuses a new use-case namespace
in the core.


## Optional administrative serving component

Plan 106 and [ADR-71](../adr/0071-first-release-inspection-is-an-isolated-administrative-runtime.md)
add the public `shikigami-core:inspection` sublibrary. It compiles the shared
administrative catalog, observed-store acquisition and authenticated HTTP/feed
host from `shikigami-core/inspection/`. It depends on the domain's main library;
the domain main library does not depend on it. Only the server and workers opt
in. This preserves all seven package arrows and keeps the one-off agent main
library free of listeners, inspection providers, exporters and queue interpreters.
The worker still supplies its actual Shibuya master and owns its lifetime; no
public Servant routes or second consumer enter this component.

Pure aggregate display descriptions and the Settei inspection settings remain
in the domain main library. Browser authority excludes raw workflow journals,
event bodies and queue messages; the local trusted administrative console retains
the owning native operations. The architecture tests enforce this optional
component boundary in addition to the existing main-library dependency budgets.

## What may not appear in `shikigami-core`

`shikigami-core` is the domain. Its **library** stanza must not depend on:

- `wai`, `warp`, `servant-server` — HTTP serving belongs to `shikigami-server`.
- `hs-opentelemetry-sdk`, `hs-opentelemetry-exporter-otlp` — provider and exporter
  lifetimes belong at executable boundaries. Core may depend on
  `hs-opentelemetry-api` for the domain-level span/tracer types Keiro requires.
- `shibuya-pgmq-adapter`, `pgmq-effectful` — the supervised queue *adapter* and its
  effect interpreter belong to `shikigami-workers`.
- `hw-kafka-client`, `kafka-effectful` — no stock package links a Kafka client. The
  consumers are the Kikan binding's `intake` library and the fixture producer is a verb of
  the distribution's admin command (plan 135, M5).

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

Capability overlays follow the same domain/leaf split. `shikigami-core` owns the pure
`Shikigami.Capability.Overlay` vocabulary and `Shikigami.Capability.Catalog` resolution
contract because both durable workflows and one-off runs consume them. The generic
provider-registry and lease bracket also belong in core; they contain no concrete workspace,
MCP, queue, or server adapter. The immutable `workspace.read` revision `1` descriptor,
canonical Git-worktree scope, bounded local read/grep/glob provider, and one-off CLI wiring
live in `shikigami-agent`. That provider uses only observation tools, resolves the worktree
lazily for a requesting identity-bearing Skill, and never enters `FlowEffects`. Base
capabilities — including Flow, Memory, Sink,
Workflow, profile enforcement, and provider selection — stay structurally outside the
overlay registry and cannot be replaced by an adapter.


## Module placement rules

1. A module lands in the package that owns its *runtime role*, and keeps the module
   name of its *concept*. Moving the trigger intake from core to workers did
   not rename it; it is still the trigger vertical (`Shikigami.Trigger.Intake`).
2. Technical composition module names are limited to this allowlist:
   - `Shikigami.Runtime`, `Shikigami.Workflow.Registry` — validated runtime startup
     wiring and the shared five-family workflow registry (plan 65 / ADR 0038).
   - `Shikigami.App.Config`, `Shikigami.App.Config.Load` — the one process-configuration
     declaration and its loader, in `shikigami-core`. Application-configured executables
     resolve their settings from these two modules. The migration CLI owns its
     `DATABASE_URL` boundary, the client owns its leaf Settei configuration (including `--server` and `--token`), the OpenAPI generator takes no
     configuration, and
     standard `OTEL_*` variables remain SDK-owned. See `docs/operations/configuration.md`.
   - `Shikigami.Server.App`, `Shikigami.Server.Boot`, `Shikigami.Server.Config`,
     `Shikigami.Server.Seam`
   - `Shikigami.Workers.Config`, `Shikigami.Workers.Registry`
   - `Shikigami.App.Role` — the `RoleInfo` record and `runRole`, in `shikigami-core`.
     Application-configured executables resolve configuration through it, for the same
     reason they all resolve settings through `Shikigami.App.Config`: `runRole` *is* the
     resolution order (parse, resolve, act), and two copies could disagree about when
     `--check-config` runs relative to the action opening a database.
   - `Shikigami.Server.Command`, `Shikigami.Server.Command.*`,
     `Shikigami.Workers.Command`, `Shikigami.Workers.Command.*`,
     `Shikigami.Agent.Command`, `Shikigami.Agent.Command.*` — the option parsers
     and entry actions of each package's executables. These are exposed rather than
     buried in `app/` so that a `--help` smoke test can drive the parser purely with
     `optparse-applicative`'s `execParserPure` instead of shelling out to a built
     binary.
   Everything else is a concept module.
   The complete current composition budget and concept namespaces are now
   machine-readable in `tools/style/module-ownership.json`, with the narrow
   service-specific extensions explained by [ADR-75](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md).
   `just haskell-conventions` rejects unlisted technical modules and obsolete
   Core/Id/Store buckets. The real renderer is `Shikigami.Diagrams`.
   Consumer app ownership lives in `Integration.ConsumerRuntime`, loop health in
   `Health.Supervision`, and host bridges in `Inspection.Consumer`/`Inspection.Server`.
   Concept-owned mappings live in `Execution.Bindings`, `WorkerSession.Bindings`
   and `RunJobs.Bindings`; no current mapping needs a service-wide DomainBindings bucket.
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
| `shikigami-server` | `shikigami-server` | Serves the public HTTP API, including the declared-agent catalog, and refreshes its lifecycle directory. Starts no background workers. |
| `shikigami` | `shikigami-server` | Administrative, validation, enqueue, approval-resolution, and fixture commands: `validate`, `render-lifecycle`, `enqueue-run`, `resolve-approval`, `flows`, `grants`, `agents`, and `runs` (plus the mounted Keiro operator tree). |
| `shikigami-worker` | `shikigami-workers` | Drains `shikigami_run_jobs`, runs agents, dispatches sinks, publishes the outbox, resumes workflows, fires timers. Opens no application HTTP listener. |
| `shikigami-scheduler` | `shikigami-workers` | Arms Schedule triggers and drives keiro timer firing. |
| `shikigami-run-behavior` | `shikigami-agent` | Runs a registered program or Skill without a database; the provider defaults to a stub. Workspace requests currently fail action authorization. |
| `shikigami-agent-run` | `shikigami-agent` | Runs one agent through the kioku session/memory lifecycle; a workspace overlay lease covers only the behavior call. |
| `shikigami-migrate` | `shikigami-migrations` | Applies database migrations. |
| `shikigami-client` | `shikigami-client` | Calls a running server through the typed client. |
| `shikigami-openapi` | `shikigami-api` | Regenerates `docs/api/openapi.json` from the served route proxy. |

There is no umbrella dispatcher binary. A single process that dispatched into both server
and worker implementations could not honestly satisfy the dependency graph, which is why
`shikigami-cli` was retired in 2026-07-30.

`shikigami-agent` is not a counterexample and not a utility package. The objection to
`shikigami-cli` was that it depended on `shikigami-api`, `shikigami-core`,
`shikigami-server`, **and** `shikigami-workers` at once, so it sat above every other package
and its one binary linked all of them. `shikigami-agent` depends on `shikigami-core` and the migration startup library: it
is a lighter leaf under the domain, not a lid over the graph. The distinguishing rule is
enforced — `Shikigami.PackageArchitectureSpec` fails if any executable in any package depends
on a sibling library other than its own package's.

That rule exists because the weaker one was not enough. Between 2026-07-30 and 2026-08-19 the
two one-off commands lived in `shikigami-workers`, where every executable depends on the whole
library, so `shikigami-run-behavior` linked Kafka, PGMQ, Shibuya, and an OTLP exporter while
this table described it as needing no database and no key. The sibling-edge rule could not see
it, because the coupling was inside a package rather than between two.


## The public HTTP API standard

`shikigami-api` owns the contract; `shikigami-server` owns execution.

- One umbrella `Shikigami.Api` record with `NamedRoutes`. Every application result route uses
  `MultiVerb` so that each status code, media type, and response body is part of the type.
- Application JSON errors are RFC 9457 problem details served as
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
  degraded health check is a status report, not an error. Native Relay pagination
  errors retain the public `RelayPageError` JSON protocol. `/openapi` is a pure
  single-status document route using the same proxy as the server and client.
- `docs/api/openapi.json` is generated, never hand-edited, from the exact proxy the
  server serves, using the released `openapi-hs` / `servant-openapi-hs` cohort. The
  `openapi3` lineage is not a substitute: it does not model `MultiVerb` responses.
- Operation ids are stable and deterministic. `ToSchema` / `ToParamSchema` instances are
  wire-accurate, including explicit `additionalProperties` for opaque `Value` and
  `oneOf` for hand-written tagged unions.
- Relay keyset pagination is required for public list endpoints. The agent catalog
  and HTTP run acceptance history implement it; see [the HTTP guide](../user/http-api.md).

Regenerate and verify with:

```bash
cabal run shikigami-openapi
git diff --exit-code docs/api/openapi.json
```

## Runtime startup and maintenance

[Plan 65](../plans/65-migrate-shikigami-to-the-keiro-0-15-cohort-and-the-idiomatic-v2-record-model.md)
and [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md)
extend the role packages' legal arrows with the migration library. Its read-only
handshake runs before telemetry, pools, catalog registration and listeners. Core has
no production sibling dependency. The migration executable remains independently
configured and never imports the application roles.

Core owns the complete workflow registry and retention policy, including agent runs,
approvals, conversations, execution drivers and continuing worker sessions. Workers
own the continuous runners, bounded resume command, shared timer dispatcher and hourly
terminal GC. The server mounts lifecycle replay audit and preserve-only catalog
operations; its embedded resume hook remains absent because its effects do not match
Kioku's resource-aware workflows.

## Foreground Baikai launch boundary (plan 80)

`shikigami-agent` also owns `shikigami-agent-launch`, its interactive resolver and the mounted public Baikai unattended command tree. Direct vendor/agent dependencies remain at that composition leaf. The shared HTTP response builder and pure request compatibility check live in `shikigami-core`; workers and server reuse them. Foreground process results do not replace durable behavior Responses. [ADR 0040](../adr/0040-response-options-and-foreground-launches-have-separate-authority.md) records this boundary.

## Execution and continuing-work ownership

Core owns root accounting, immutable execution selection, protected transcripts,
accepted operations, continuing-session state, coordination commands and repository
catalog validation. Workers compose submit/observe executors, workflow runners,
durable event waits and timer recovery. Server owns bounded metadata inspection
through `resources`, `executions` and `workers`; API/client packages retain the
implemented agent/run HTTP contract. Objective API/CLI routes remain planned in
MasterPlan 17. The pure repository catalog does not allocate worktrees or install
mutation providers. See [the current domain inventory](shikigami-domain-inventory.md)
and [capability census](../capabilities-coverage.md).
