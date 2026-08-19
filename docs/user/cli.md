# CLI Reference

Shikigami is **several binaries, not one**. There is no umbrella `shikigami <subcommand>`
dispatcher: each long-running role is its own executable so an operator can scale, restart, and
roll them out independently, and because one process could not honestly link both the HTTP
server and the worker implementations. See
[the package architecture](../architecture/packages.md).

In the dev shell, invoke any of them through cabal:

```bash
$ cabal run <binary> -- [command] [options]
```

**Administrative and offline commands** — the `shikigami` binary, from `shikigami-server`:

```text
shikigami validate <FILE>
shikigami render-lifecycle <FILE>
shikigami enqueue-run <AGENT> [--payload <JSON>]
shikigami publish-fixture <FILE> [--broker <HOST:PORT>] [--topic <TOPIC>]
shikigami stub-kawa --port <PORT> [--republish-topic <TOPIC>] [--broker <HOST:PORT>]
shikigami danwa-spike --human <PARTICIPANT> --agent <PARTICIPANT> [--danwa-url <URL>]
shikigami grants list [--limit <N>] [--after <AGENT:KIND>]
shikigami grants grant <AGENT> <KIND> [--by <WHO>]
shikigami grants revoke <AGENT> <KIND> [--by <WHO>]
```

**One-off agent runs** — from `shikigami-agent`, which links none of the platform's messaging,
queueing, or telemetry stack, so a consumer who is not running the Kikan platform can build and
use just these:

```text
shikigami-run-behavior --agent <FILE> [--payload <JSON>]
shikigami-agent-run --agent <NAME|FILE> [--from-activity <FILE>]
```

**Long-running roles** — from `shikigami-workers`:

```text
shikigami-worker [--agents <DIR>] [--kawa-url <URL>] [--kizashi-url <URL>] [--danwa-url <URL>] [--danwa-agent <PARTICIPANT>]
shikigami-scheduler [--agents <DIR>]
shikigami-consume-stream [--agents <DIR>] [--broker <HOST:PORT>] [--topic <TOPIC>] [--group <GROUP>] [--include-agent-actors]
shikigami-consume-events [--agents <DIR>] [--broker <HOST:PORT>] [--topic <TOPIC>] [--group <GROUP>]
```

**The rest**: `shikigami-server` serves the public HTTP API, `shikigami-client` calls a running
server through the typed client, `shikigami-migrate` applies database migrations, and
`shikigami-openapi` regenerates `docs/api/openapi.json` (it takes no arguments and writes the
file).

One wrinkle worth knowing: `cabal run shikigami-server` is ambiguous, because the name is both a
package and one of that package's two executables. Disambiguate it:

```bash
$ cabal run shikigami-server:exe:shikigami-server
```

Every other binary is unambiguous, because no other executable shares its package's name.

Binaries that record sessions, use the run queue, or use the Keiro inbox
(`shikigami-agent-run`, `shikigami enqueue-run`, `shikigami-consume-stream`,
`shikigami-consume-events`, `shikigami-worker`, `shikigami-scheduler`) need the
`database.connection_string` setting and a migrated database (`just create-database`). The
dev shell exports `PG_CONNECTION_STRING`, the environment variable bound to that setting.
`shikigami validate`, `shikigami render-lifecycle`, and `shikigami-run-behavior` need neither a
database nor a model key.

Every binary also accepts `--config PATH`, `--set KEY=VALUE`, and the five configuration
diagnostics (`--describe-config`, `--describe-config-json`, `--explain-config`,
`--explain-config-json`, `--check-config`). See
[Configuration](../operations/configuration.md) for the complete accepted surface, the
precedence order, and which binary refuses to start without what.

---

## `shikigami validate`

```bash
$ shikigami validate <FILE>
```

Parse a `.dhall` manifest, decode it into the typed `AgentDecl`, and pretty-print it. For a
**skill-agent** it also validates the skill directory and `SKILL.md` frontmatter. Exits 0 on
success, non-zero with a typed error on any load/skill failure. **No DB or key.**

→ See [Getting Started](./getting-started.md), [Writing Agents](./writing-agents.md).

## `shikigami render-lifecycle`

```bash
$ shikigami render-lifecycle <FILE>
```

Render a Flow agent's declared lifecycle as a Mermaid state diagram on standard output. Reads
the manifest, resolves its `Flow{name}` against the registered flows, and prints the diagram
for that flow's Keiki transducer. **No DB or key.**

→ See [Flows](./flows.md).

## `shikigami-run-behavior`

```bash
$ shikigami-run-behavior --agent <FILE> [--payload <JSON>]
```

Load a manifest and run **only its behavior** with deterministic stubs, printing the output
JSON. Does not touch the DB or dispatch sinks. `--payload` supplies the trigger payload as
JSON (defaults to `null`; invalid JSON exits non-zero). **No DB or key.**

→ See [Behaviors](./behaviors.md).

## `shikigami-agent-run`

```bash
$ shikigami-agent-run --agent <NAME|FILE> [--from-activity <FILE>]
```

Run an agent through the full **kioku** lifecycle — open session, recall prior learnings, run
behavior, record the new learning, complete — and print the across-run report. A bare `<NAME>`
resolves to `agents/<NAME>.dhall`; a path (contains `/` or ends in `.dhall`) is used as-is.

With `--from-activity <FILE>`, instead of running the behavior it folds an `activity.v1`
envelope (JSON) directly into the agent's memory (payload → content; verb/subject → tags).
**Needs the DB** (`database.connection_string`).

→ See [Memory & Sessions](./memory.md).

## `shikigami enqueue-run`

```bash
$ shikigami enqueue-run <AGENT> [--payload <JSON>]
```

Enqueue an **addressed run job** for a named agent onto the worker's `shikigami_run_jobs`
queue — the Event trigger class. `--payload` is the addressed run payload as JSON. A running
`worker` drains and executes it.

→ See [Triggers](./triggers.md), [The Living Loop](./living-loop.md).

## `shikigami stub-kawa`

```bash
$ shikigami stub-kawa --port <PORT> [--republish-topic <TOPIC>] [--broker <HOST:PORT>]
```

Run the **kawa ingest doorway stub** (contract C2). Accepts
`POST /v1/sources/{source_id}/events`, returns `{ "activity_id": "<uuid>", "deduplicated": false }`,
enforces idempotency on `(source, source_event_id)`, and logs each envelope. With
`--republish-topic` (and `--broker`) it re-publishes each accepted envelope onto that Kafka
topic — the mechanism that **closes the living loop**.

→ See [The Living Loop](./living-loop.md), [Sinks](./sinks.md).

## `shikigami publish-fixture`

```bash
$ shikigami publish-fixture <FILE> [--broker <HOST:PORT>] [--topic <TOPIC>]
```

Publish one Activity Envelope (JSON) onto the activity stream **with the required `keiro-*`
headers** so the keiro inbox accepts it. Defaults: `--broker 127.0.0.1:9092`,
`--topic activity.v1`. Useful for driving the stream from fixtures (`fixtures/*.json`).

→ See [The Living Loop](./living-loop.md).

## `shikigami-consume-stream`

```bash
$ shikigami-consume-stream [--agents <DIR>] [--broker <HOST:PORT>] [--topic <TOPIC>] [--group <GROUP>] [--include-agent-actors]
```

Consume the `activity.v1` stream, reconstruct each envelope (deduped via the keiro idempotent
inbox), match it against every declared **Stream** agent's predicate, and enqueue a run job per
match. Defaults: `--agents agents`, `--broker 127.0.0.1:9092`, `--topic activity.v1`,
`--group shikigami-stream`.

`--include-agent-actors` matches agent-produced activities too (meta-detectors); **off by
default** is the feedback guard.

→ See [Triggers](./triggers.md), [Detectors](./detectors.md).

## `shikigami-consume-events`

```bash
$ shikigami-consume-events [--agents <DIR>] [--broker <HOST:PORT>] [--topic <TOPIC>] [--group <GROUP>]
```

Consume a public integration-event topic, reconstruct each Keiro integration event, match it
against declared **Event** agents by `eventType`, and enqueue a run job per match. Defaults:
`--agents agents`, `--broker 127.0.0.1:9092`, `--topic danwa.message-addressed.v1`,
`--group shikigami-events`.

Use this for Danwa addressed-message events. Danwa publishes
`danwa.message-addressed-to-agent` on `danwa.message-addressed.v1` when Danwa integration
events are enabled. Shikigami consumes that public topic only; it does not read Danwa's
database, event store, read models, or outbox tables.

→ See [Triggers](./triggers.md), [The Living Loop](./living-loop.md).

## `shikigami-worker`

```bash
$ shikigami-worker [--agents <DIR>] [--kawa-url <URL>] [--kizashi-url <URL>] [--danwa-url <URL>] [--danwa-agent <PARTICIPANT>]
```

Boot the supervised worker. Loads every `.dhall` in `--agents`, then drains
`shikigami_run_jobs`: for each job, run the agent's behavior, dispatch its (permission-gated)
sinks to the configured services, and record a kioku session. Defaults:
`--agents agents`, `--kawa-url http://localhost:8088`, `--kizashi-url http://localhost:8089`,
`--danwa-url http://localhost:8080`, `--danwa-agent part_shikigami`. Each of those flags
sets a declared configuration key, so `--kawa-url URL` and `--set sinks.kawa.base_url=URL`
are the same thing.
**Needs the DB** (`database.connection_string`).

→ See [The Living Loop](./living-loop.md).

## `shikigami-scheduler`

```bash
$ shikigami-scheduler [--agents <DIR>]
```

Arm Schedule triggers and drive Keiro timer firing. Loads every `.dhall` in `--agents`
(default `agents`), computes each schedule agent's next due minute, and arms a Keiro timer for
it; the same loop fires due timers, including approval timeouts.
**Needs the DB** (`database.connection_string`).

→ See [Triggers](./triggers.md).

---

## `shikigami grants`

```bash
$ shikigami grants list [--limit <N>] [--after <AGENT:KIND>]
$ shikigami grants grant <AGENT> <KIND> [--by <WHO>]
$ shikigami grants revoke <AGENT> <KIND> [--by <WHO>]
```

Inspect and change the per-agent sink permission table that gates every dispatch. `KIND` is one
of `KawaDigest`, `KizashiSignal`, `ReiAction`, `DanwaConversation`, `ChannelEgress`. `list`
pages most-significant first (1–200 rows, default 50); `--by` is recorded in the table's
`granted_by` / `revoked_by` column. A worker picks a change up on its next dispatch — there is
no cache to invalidate. **Needs the DB** (`database.connection_string`).

→ See [Sinks](./sinks.md).

## `shikigami danwa-spike`

```bash
$ shikigami danwa-spike --human <PARTICIPANT> --agent <PARTICIPANT> [--danwa-url <URL>]
```

Exercise the Danwa HTTP client end to end by starting a conversation, posting a human message,
and replying as the agent. A development spike for checking connectivity and participant ids
against a running Danwa, not part of the runtime path.

---

## `just` recipes (database)

| Recipe | Effect |
| --- | --- |
| `just create-database` | create the dev DB if missing, then `just migrate` (idempotent) |
| `just migrate` | apply the kiroku event-store schema + shikigami's read-model migrations |
| `just new-migration name=<slug>` | scaffold a new timestamped migration file |

→ See [Getting Started](./getting-started.md).
