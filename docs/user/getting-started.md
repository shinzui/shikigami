---
type: "Tutorial"
title: "Getting Started"
description: "Try a stock declaration without services, then run a local agent with a migrated database."
docId: "DOC-2"
tags: ["getting-started", "installation"]
generated:
  by: process:shikigami-user-docs-okf-migration
  at: 2026-09-07T14:41:30Z
---

# Getting Started

This guide takes you from a fresh checkout to validating your first declared agent and
running its behavior — with no model key and no running services required.

## Prerequisites

Shikigami is a Haskell project (GHC 9.12.4) built with a Nix dev shell. From the repository
root:

```bash
$ nix develop        # or `direnv allow` if you use direnv — see .envrc
```

The dev shell provides GHC, `cabal`, `psql`/`createdb`, and the `PG*` environment variables
(`PGHOST` is a Unix-socket directory inside the repo; `PGDATABASE=shikigami`). Everything
below assumes you are **inside the dev shell**.

Cabal resolves the pinned dependencies from [cabal.project](../../cabal.project).
Build the commands for this tutorial from the repository root.

```bash
cabal build exe:shikigami exe:shikigami-run-behavior exe:shikigami-local
```

## Validate a stock declaration

[Portable note](../../agents/proof/portable-note.dhall) declares a Skill and a
principal. Omitting `trigger` gives it a manual trigger. Omitting `outputs` lets
the running composition choose the destination.

```bash
cabal run shikigami -- validate agents/proof/portable-note.dhall
```

The stock validator prints the decoded declaration, its output choice and
`OK: 1 agent parsed (skill agents/skills/portable-note valid).` A malformed
manifest such as `agents/broken.dhall` exits nonzero. To validate a declaration
that explicitly requests Kawa, use the Kikan distribution's validator.

```bash
cabal run kikan-shikigami:exe:kikan-shikigami -- validate agents/heartbeat.dhall
```

## Run a behavior without services

The synchronous runner can execute a registered program or a Skill and print its
JSON result. Try this deterministic program with the default stub provider.

```bash
cabal run shikigami-run-behavior -- --agent agents/proof/code-researcher.dhall
```

Its output names `code-researcher` and includes a `finding`. This checks the
behavior locally. The next path adds durable execution and memory.

## Set up the database (for sessions, queues, and consumers)

The `agent-run` and `worker` commands record sessions and memory via **kioku**. The
`enqueue-run`, `consume-stream`, and `consume-events` commands use the run queue or Keiro
inbox. All of those paths need Postgres. Start the bundled service in another dev-shell
terminal; it runs `just create-database` after PostgreSQL is ready:

```bash
$ process-compose up
```

If PostgreSQL is already running, create and migrate the dev database explicitly:

```bash
$ just create-database     # creates the DB if missing, then runs `just migrate`
```

This applies the Kiroku, Keiro, Kioku, and Shikigami migration components in
dependency order and reconciles Keiro's read-model registry. The connection string is exposed as
`PG_CONNECTION_STRING` by the dev shell, which is the environment variable bound to the
`database.connection_string` setting, so runtime commands pick it up automatically. See
[Configuration](../operations/configuration.md) for the full surface and for the
`--check-config` / `--explain-config` diagnostics application-configured binaries offer.

## Run a local agent with memory

From the checkout, run the portable declaration with an explicit task.

```bash
cabal run shikigami-local -- run agents/proof/portable-note.dhall "Summarize this note: the build passed."
cabal run shikigami-local -- runs
```

At the first interactive run, review the declaration and repository and confirm
the grant. The run opens a session, applies its memory policy and reports the
path of its local output. The default model stub exercises this lifecycle. Use
the [local-operator guide](local-operator.md) to configure a real provider,
or [create your own routine agent](routine-agents.md).

## Next steps

- **[Writing Agents](./writing-agents.md)** — author your own `.dhall` declaration.
- **[HTTP API — agents and runs](./http-api.md)** — discover agents, submit work, and wait for its durable result.
- **[Typed decisions in Flows](./typed-decisions.md)** — run governed triage and investigation with two model aliases.
- **[The Living Loop](./living-loop.md)** — run the worker and watch an agent's output
  trigger a second agent.
- **[CLI Reference](./cli.md)** — every subcommand and flag.
