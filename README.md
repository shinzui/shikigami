# Shikigami

Shikigami is a declared-agent runtime for the Kikan platform. It runs autonomous
system agents from typed Dhall declarations, with an embedded Haskell `Flow` DSL
available when the behavior is too stateful for declaration alone. When a
trigger fires, Shikigami runs the selected behavior, dispatches the declared
sinks, and records memory across runs through `kioku`.

An agent is usually a declaration, not a bespoke service:

```text
behavior  = what the agent does
trigger   = when it runs
sinks     = what it produces
identity  = under whose authority it acts
memory    = what it carries forward across runs
```

For synchronous agents, Dhall names a registered `shikumi` / `handan` program
or a `baikai` skill. The schema also accepts `Deterministic` rules, but the
current runner rejects that arm as unsupported. For lifecycle-backed work, Dhall
names a compiled Haskell `FlowDef`; the Haskell flow owns the durable control flow, journaled
steps, waits, mid-run sink emissions, memory writes, and timeout or
acknowledgement branches.

This makes routine coordination part of the platform's living loop: events
become memory, memory and stream activity trigger agents, agents produce signals,
digests, actions, or conversations, and those outputs can re-enter the stream for
other humans and agents to observe.

## Why The Name

The project name is written as **式神** and read **Shikigami**.

In Japanese folklore, a shikigami is a summoned spirit-servant bound to its
master's will. That is the intended metaphor here: a small, declared agent that
can be summoned by the system to observe, decide, coordinate, and act within the
authority it has been granted.

Within **Kikan** (機関), the AI-native organization platform, Shikigami is the
augmentation-layer runtime for autonomous system agents. Kikan is the broader
institutional mechanism: humans, agents, memory, awareness, conversations, and
flows working as one inspectable system. Shikigami is one way that mechanism acts.

## What It Does

The [capability catalog](docs/capabilities/index.md) documents the current provision
surface with stable `CAP-N` handles, adoption steps, evidence, and implementation
limits. Its [maintenance guide](docs/capabilities-maintenance.md) explains the OKF
profile and validation commands.

- Loads and validates typed Dhall agent declarations from `agents/*.dhall`.
- Supports schedule, activity-stream, and addressed-event triggers.
- Runs registered `shikumi` / `handan` programs, `baikai` skills, and
  durable Haskell `Flow` behaviors on `keiro`.
- Dispatches permission-gated sinks such as Kawa digests, Kizashi signals, Rei
  actions, and Danwa conversations.
- Records sessions and reusable memory through `kioku` so agents do not start
  blank on every run.
- Provides supervised workers and command-line tools for validating, running,
  enqueueing, and consuming agent work.

## Repository Shape

Shikigami is seven Cabal packages, with dependency direction enforced by Cabal and by a test.
See [docs/architecture/packages.md](docs/architecture/packages.md) for the authoritative map.

```text
shikigami-core/        Domain: declarations, agent runs, behaviors, flows, sinks, memory
shikigami-core/src/Shikigami/Flow/
                       Haskell Flow DSL definitions and registered flow bodies
shikigami-agent/       One-off agent runs, for consumers not operating the platform
shikigami-api/         Public HTTP contract: route records, DTOs, OpenAPI generation
shikigami-server/      Servant/WAI execution and the administrative `shikigami` command
shikigami-workers/     Supervised background loops: queue, streams, scheduler, timers
shikigami-client/      Typed HTTP client derived from the served route type
shikigami-migrations/  Database migrations for Shikigami and composed Kioku state
domain/                The checked keiro-dsl service specification
agents/                Example and proof agent declarations
schema/                Dhall schema for declared agents
docs/architecture/     Package map, implementation order, domain inventory
docs/adr/              Architecture decision records
docs/user/             User guide and CLI reference
docs/capabilities/     Evidence-backed OKF capability catalog
docs/plans/            ExecPlans for the runtime build-out
docs/initial-spec.md   Original architecture spec
```

## Quick Start

Enter the development shell:

```sh
nix develop
```

The current project also requires the co-developed Kikan-En contract and client
checkout at the sibling paths listed in `cabal.project`. See the
[dependency cohort](docs/dependency-cohort.md) for source pins, local prerequisites,
and migration qualification status. Build inside the development shell:

```sh
cabal build all
```

Validate a sample declared agent:

```sh
cabal run shikigami -- validate agents/heartbeat.dhall
```

Run only its behavior with deterministic stubs, without a database or model key:

```sh
cabal run shikigami-run-behavior -- --agent agents/heartbeat.dhall
```

The one-off commands recognize `--workspace` for declared `workspace.read` overlays,
but their current action authorizer denies capability acquisition. The workspace proof
manifest therefore reports an authorization refusal; it is not a working local-read
quick start. Ordinary agents without overlays can still run.

Start the bundled PostgreSQL service in a separate dev-shell terminal:

```sh
process-compose up
```

It creates and migrates the database after PostgreSQL is ready. If PostgreSQL is
already running, create and migrate explicitly:

```sh
just create-database
```

Run an agent through the full memory-backed lifecycle:

```sh
cabal run shikigami-agent-run -- --agent heartbeat
```

For a fuller walkthrough, start with
[docs/user/getting-started.md](docs/user/getting-started.md).

## Main Commands

Shikigami is several binaries, not one. Each long-running role is its own executable so an
operator can scale and restart them independently.

```text
shikigami validate <FILE>              # administrative, from shikigami-server
shikigami render-lifecycle <FILE>
shikigami enqueue-run <AGENT> [--payload <JSON>]
shikigami grants list|grant|revoke

shikigami-run-behavior --agent <FILE> [--workspace <DIR>]  # one-off, from shikigami-agent
shikigami-agent-run --agent <NAME|FILE> [--workspace <DIR>]

shikigami-worker [--agents <DIR>]      # long-running, from shikigami-workers
shikigami-scheduler [--agents <DIR>]
shikigami-consume-stream [--agents <DIR>]
shikigami-consume-events [--agents <DIR>]

shikigami-server                       # the public HTTP API
shikigami-migrate up                   # database migrations
```

`shikigami-run-behavior` and `shikigami-agent-run` live in `shikigami-agent`, which depends
only on `shikigami-core`. A consumer who is not running the Kikan platform can build and use
just those two without acquiring the messaging, queueing, or telemetry stack the deployed
service needs. Both commands accept `--workspace`, but currently use a deny-all action authorizer,
so requesting an overlay does not authorize its acquisition. See the
[CLI reference](docs/user/cli.md) for current one-off limitations.

See [docs/user/cli.md](docs/user/cli.md) for the full command reference.

## Documentation

- [Use cases](docs/use-cases/index.md) connect intended outcomes to feature coverage,
  improvement requests, existing plans, and acceptance scenarios. Start with
  [adaptive autonomous delivery](docs/use-cases/adaptive-autonomous-delivery.md).
- [User guide](docs/user/README.md) explains the declared-agent model.
- [Getting started](docs/user/getting-started.md) covers local setup and the
  first validate/run path.
- [Writing agents](docs/user/writing-agents.md) explains the Dhall declaration
  schema.
- [Triggers](docs/user/triggers.md), [behaviors](docs/user/behaviors.md),
  [sinks](docs/user/sinks.md), and [memory](docs/user/memory.md) cover the four
  main runtime parts.
- [Flows](docs/user/flows.md) covers the embedded Haskell DSL for durable agent
  behaviors.
- [The living loop](docs/user/living-loop.md) shows Shikigami operating end to
  end with the stream and stub services.
- [Operator CLI](docs/operations/operator-cli.md),
  [configuration](docs/operations/configuration.md), and
  [action authorization](docs/operations/action-authorization.md) cover deployment.
- [Workflow versioning](docs/workflow-versioning.md) governs durable code changes.
- [Initial architecture spec](docs/initial-spec.md) records the original design
  and Kikan contract context.

## Status

Shikigami is active Haskell work in the `shinzui/kikan` portfolio. Some adjacent
services are still proven through stubs or fixtures in this repository; the
contract shapes are represented here, while live service ownership remains with
the corresponding Kikan projects.

Model response options and foreground coding-agent launches are described in [Baikai execution](docs/operations/baikai-execution.md). HTTP supports Anthropic, OpenAI Chat Completions and OpenAI Responses; `shikigami-agent-launch` mounts interactive and unattended Baikai surfaces. Background CLI responses require enforced deadlines, bounded output and descendant confinement. [Typed Flow judgments](docs/shikumi-flow-decisions.md) also support an explicitly selected TypeSafe decision binding.
