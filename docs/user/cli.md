# CLI Reference

All functionality is exposed by the single `shikigami` executable. In the dev shell, invoke it
through cabal:

```console
$ cabal run shikigami -- <command> [options]
```

```text
shikigami validate <FILE>
shikigami run-behavior --agent <FILE> [--payload <JSON>]
shikigami agent-run --agent <NAME|FILE> [--from-activity <FILE>]
shikigami enqueue-run <AGENT> [--payload <JSON>]
shikigami stub-kawa --port <PORT> [--republish-topic <TOPIC> --broker <HOST:PORT>]
shikigami publish-fixture <FILE> [--broker <HOST:PORT>] [--topic <TOPIC>]
shikigami consume-stream [--agents <DIR>] [--broker <HOST:PORT>] [--topic <TOPIC>] [--group <GROUP>] [--include-agent-actors]
shikigami worker [--agents <DIR>] [--kawa-url <URL>] [--kizashi-url <URL>]
```

Commands that record sessions/memory (`agent-run`, `worker`) read the connection string from
the `PG_CONNECTION_STRING` environment variable (set by the dev shell) and need a migrated
database (`just create-database`).

---

## `validate`

```console
$ shikigami validate <FILE>
```

Parse a `.dhall` manifest, decode it into the typed `AgentDecl`, and pretty-print it. For a
**skill-agent** it also validates the skill directory and `SKILL.md` frontmatter. Exits 0 on
success, non-zero with a typed error on any load/skill failure. **No DB or key.**

→ See [Getting Started](./getting-started.md), [Writing Agents](./writing-agents.md).

## `run-behavior`

```console
$ shikigami run-behavior --agent <FILE> [--payload <JSON>]
```

Load a manifest and run **only its behavior** with deterministic stubs, printing the output
JSON. Does not touch the DB or dispatch sinks. `--payload` supplies the trigger payload as
JSON (defaults to `null`; invalid JSON exits non-zero). **No DB or key.**

→ See [Behaviors](./behaviors.md).

## `agent-run`

```console
$ shikigami agent-run --agent <NAME|FILE> [--from-activity <FILE>]
```

Run an agent through the full **kioku** lifecycle — open session, recall prior learnings, run
behavior, record the new learning, complete — and print the across-run report. A bare `<NAME>`
resolves to `agents/<NAME>.dhall`; a path (contains `/` or ends in `.dhall`) is used as-is.

With `--from-activity <FILE>`, instead of running the behavior it folds an `activity.v1`
envelope (JSON) directly into the agent's memory (payload → content; verb/subject → tags).
**Needs the DB** (`PG_CONNECTION_STRING`).

→ See [Memory & Sessions](./memory.md).

## `enqueue-run`

```console
$ shikigami enqueue-run <AGENT> [--payload <JSON>]
```

Enqueue an **addressed run job** for a named agent onto the worker's `shikigami_run_jobs`
queue — the Event trigger class. `--payload` is the addressed run payload as JSON. A running
`worker` drains and executes it.

→ See [Triggers](./triggers.md), [The Living Loop](./living-loop.md).

## `stub-kawa`

```console
$ shikigami stub-kawa --port <PORT> [--republish-topic <TOPIC>] [--broker <HOST:PORT>]
```

Run the **kawa ingest doorway stub** (contract C2). Accepts
`POST /v1/sources/{source_id}/events`, returns `{ "activity_id": "<uuid>", "deduplicated": false }`,
enforces idempotency on `(source, source_event_id)`, and logs each envelope. With
`--republish-topic` (and `--broker`) it re-publishes each accepted envelope onto that Kafka
topic — the mechanism that **closes the living loop**.

→ See [The Living Loop](./living-loop.md), [Sinks](./sinks.md).

## `publish-fixture`

```console
$ shikigami publish-fixture <FILE> [--broker <HOST:PORT>] [--topic <TOPIC>]
```

Publish one Activity Envelope (JSON) onto the activity stream **with the required `keiro-*`
headers** so the keiro inbox accepts it. Defaults: `--broker 127.0.0.1:9092`,
`--topic activity.v1`. Useful for driving the stream from fixtures (`fixtures/*.json`).

→ See [The Living Loop](./living-loop.md).

## `consume-stream`

```console
$ shikigami consume-stream [--agents <DIR>] [--broker <HOST:PORT>] [--topic <TOPIC>] [--group <GROUP>] [--include-agent-actors]
```

Consume the `activity.v1` stream, reconstruct each envelope (deduped via the keiro idempotent
inbox), match it against every declared **Stream** agent's predicate, and enqueue a run job per
match. Defaults: `--agents agents`, `--broker 127.0.0.1:9092`, `--topic activity.v1`,
`--group shikigami-stream`.

`--include-agent-actors` matches agent-produced activities too (meta-detectors); **off by
default** is the feedback guard.

→ See [Triggers](./triggers.md), [Detectors](./detectors.md).

## `worker`

```console
$ shikigami worker [--agents <DIR>] [--kawa-url <URL>] [--kizashi-url <URL>]
```

Boot the supervised worker. Loads every `.dhall` in `--agents`, then drains
`shikigami_run_jobs`: for each job, run the agent's behavior, dispatch its (permission-gated)
sinks to the configured services, and record a kioku session. Defaults:
`--agents agents`, `--kawa-url http://localhost:8088`, `--kizashi-url http://localhost:8089`.
**Needs the DB** (`PG_CONNECTION_STRING`).

→ See [The Living Loop](./living-loop.md).

---

## `just` recipes (database)

| Recipe | Effect |
| --- | --- |
| `just create-database` | create the dev DB if missing, then `just migrate` (idempotent) |
| `just migrate` | apply the kiroku event-store schema + shikigami's read-model migrations |
| `just new-migration name=<slug>` | scaffold a new timestamped migration file |

→ See [Getting Started](./getting-started.md).
