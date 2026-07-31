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

Build everything once:

```bash
$ cabal build all
```

## Your first agent: validate

The repository ships sample agents under `agents/`. Validate one:

```bash
$ cabal run shikigami -- validate agents/heartbeat.dhall
AgentDecl {name = "heartbeat", behavior = ShikumiProgram {...}, trigger = ScheduleTrigger {...}, ...}
OK: 1 agent parsed.
```

`validate` parses the Dhall manifest, decodes it into the typed `AgentDecl` record, and
pretty-prints it. For a **skill-agent** it additionally checks the skill directory and its
`SKILL.md` frontmatter:

```bash
$ cabal run shikigami -- validate agents/triage-note.dhall
AgentDecl {name = "triage-note", behavior = Skill {path = "agents/skills/triage-note"}, ...}
OK: 1 agent parsed (skill agents/skills/triage-note valid).
```

A malformed manifest exits non-zero with a typed error:

```bash
$ cabal run shikigami -- validate agents/broken.dhall
validate: load error in agents/broken.dhall:
  <typed Dhall error>
```

## Run a behavior (no DB, no key)

`run-behavior` loads a manifest, runs *only* its behavior with deterministic stubs, and
prints the output JSON. It does not touch the database or dispatch sinks — the fastest way
to see what an agent produces:

```bash
$ cabal run shikigami -- run-behavior --agent agents/heartbeat.dhall
{"summary":"...","...":"..."}
```

Pass a trigger payload as JSON with `--payload`:

```bash
$ cabal run shikigami -- run-behavior --agent agents/triage-note.dhall \
    --payload '{"text":"customer is furious about the outage"}'
```

The `noop-summary` program and the stub `baikai` provider both run **without a model key**,
so this works in CI and on a fresh checkout.

## Set up the database (for sessions, queues, and consumers)

The `agent-run` and `worker` commands record sessions and memory via **kioku**. The
`enqueue-run`, `consume-stream`, and `consume-events` commands use the run queue or Keiro
inbox. All of those paths need Postgres. Create and migrate the dev database (idempotent):

```bash
$ just create-database     # creates the DB if missing, then runs `just migrate`
```

This installs the kiroku event-store schema *and* shikigami's own read-model migrations
(the suppression table) in one pass. The connection string is exposed as
`PG_CONNECTION_STRING` by the dev shell, which is the environment variable bound to the
`database.connection_string` setting, so runtime commands pick it up automatically. See
[Configuration](../operations/configuration.md) for the full surface and for the
`--check-config` / `--explain-config` diagnostics every binary offers.

To run Postgres itself locally, use the bundled process-compose:

```bash
$ process-compose up       # starts postgres and runs `just create-database`
```

## Run an agent end to end with memory

With the database up, `agent-run` runs the full lifecycle — open a session, recall prior
learnings, run the behavior, record the new learning, complete the session — and prints an
across-run report:

```bash
$ cabal run shikigami -- agent-run --agent heartbeat
agent "heartbeat" run run_01k…
recalled 0 prior memories:
recorded learning mem_01k…
```

Run it again and watch `recalled` climb: the agent accumulates knowledge across runs instead
of starting blank each time. See **[Memory & Sessions](./memory.md)** for details.

## Next steps

- **[Writing Agents](./writing-agents.md)** — author your own `.dhall` declaration.
- **[The Living Loop](./living-loop.md)** — run the worker and watch an agent's output
  trigger a second agent.
- **[CLI Reference](./cli.md)** — every subcommand and flag.
