# Configuring Shikigami

Every Shikigami executable — the HTTP server, the six worker roles, the administrative
commands — is configured the same way, from one declaration. This document is the
operator-facing description of that surface. It is owned by
`docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md`.

The authoritative source is the declaration itself, in
`shikigami-core/src/Shikigami/App/Config.hs`. Every binary can print it:

```bash
$ shikigami-worker --describe-config
```

If this document and that output ever disagree, the output is right.

The one exception is `shikigami-migrate`, which reads `DATABASE_URL` itself. See
[The two exceptions](#the-two-exceptions) below.


## Where values come from

Sources are resolved from lowest precedence to highest. A later source wins, and the
earlier candidate stays visible in `--explain-config` rather than disappearing.

1. **Declared defaults.** Every setting except the database connection string has one,
   so a process starts with no configuration at all and behaves the way a development
   machine expects.
2. **`--config PATH`**, once per file, in the order the options appear. Files are YAML.
3. **Environment variables**, but only the ones explicitly bound below. A variable that
   is not in that table does nothing, however plausible its name.
4. **Named flags** such as `--broker`, `--agents`, or `--kawa-url`. These are not
   separate parsers: each one sets a declared key, so `--broker HOST:PORT` and
   `--set kafka.broker=HOST:PORT` are the same thing.
5. **`--set KEY=VALUE`**, once per override, in the order the options appear.

Files sit below the environment so a deployment can override a checked-in file without
editing it. Both sit below the command line so that a flag typed during an incident wins.

Three rules follow from this and are worth stating outright. A key that no source supplies
takes its declared default. A key that more than one source supplies takes the value from
the highest one. And a key that the *highest* source supplies badly is fatal — resolution
never quietly falls back to a lower candidate, because starting on a port nobody chose is
worse than not starting.

**Unknown keys are rejected.** A misspelled key in a configuration file is
indistinguishable at runtime from a key that was never set, so it fails the process
instead of being warned about and ignored.


## Asking a binary what it accepts

Five options are available on every configurable executable. All five complete before the
process opens a database connection, binds a socket, joins a consumer group, or registers
a worker — so they are safe to run anywhere, including in a container with nothing mounted.

| Option | What it does |
|---|---|
| `--describe-config` | Print the complete accepted schema as text. Loads no source. |
| `--describe-config-json` | The same schema as JSON. |
| `--explain-config` | Print every resolved value, where it came from, and what it shadowed. |
| `--explain-config-json` | The same report as JSON. |
| `--check-config` | Resolve, validate, and exit. Prints `configuration valid`. |

```bash
$ shikigami-worker --check-config --config /etc/shikigami/worker.yaml
configuration valid
```

```bash
$ shikigami-server --explain-config --port 9000
agents.directory = agents
  from default rule agents-directory
database.connection_string = <redacted>
  from environment variable PG_CONNECTION_STRING
http.host = 127.0.0.1
  from default rule loopback
http.port = "9000"
  from command-line option --port
...
```


## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success, including every diagnostic mode. |
| `2` | Command-line usage error — an unknown flag, a missing argument. |
| `3` | A source could not be read or parsed: a missing file, unreadable bytes, invalid YAML. |
| `4` | Configuration is invalid: a value that would not decode, an unknown key, or a key this binary requires that nothing supplied. |

```bash
$ shikigami-server --set http.port=not-a-port
http.port: expected a TCP port between 1 and 65535 from command-line option --set http.port occurrence 1, rejected "not-a-port"
$ echo $?
4
```

Note what that message does *not* contain: for a secret setting, the rejected value is
redacted rather than echoed.


## The settings

Keys are hierarchical and dotted. In a YAML file, `kafka.broker` is written as `broker`
nested under `kafka`.

| Key | Default | Environment variable | What it is |
|---|---|---|---|
| `database.connection_string` | *(none — secret)* | `PG_CONNECTION_STRING` | PostgreSQL connection string, libpq URI or key/value form. |
| `agents.directory` | `agents` | `SHIKIGAMI_AGENTS_DIRECTORY` | Directory holding the `.dhall` agent manifests. |
| `agents.strict` | `false` | `SHIKIGAMI_AGENTS_STRICT` | Refuse to start when any agent manifest fails to load, or when a scheduled agent's declared cron does not parse. Every offender is reported before the refusal, so one restart shows them all. Off reports the same lines and starts anyway. |
| `scheduler.catch_up` | `skip_missed` | `SHIKIGAMI_SCHEDULER_CATCH_UP` | What the scheduler does about cron minutes that passed while it was down. `skip_missed` arms the first tick after now, so waking a day late produces one run. `fire_all` arms from the tick that just fired, replaying every missed minute — the pre-policy behavior. |
| `worker.run_timeout_seconds` | `300` | `SHIKIGAMI_RUN_TIMEOUT_SECONDS` | Maximum duration of one synchronous external behavior attempt. |
| `approval.deadline_seconds` | `900` | `SHIKIGAMI_APPROVAL_DEADLINE_SECONDS` | Maximum duration an approval or flow acknowledgement may remain open. |
| `kafka.broker` | `127.0.0.1:9092` | `SHIKIGAMI_KAFKA_BROKER` | Bootstrap broker, `HOST:PORT`. |
| `kafka.activity.topic` | `activity.v1` | `SHIKIGAMI_KAFKA_ACTIVITY_TOPIC` | Topic carrying `activity.v1` envelopes. |
| `kafka.events.topic` | `danwa.message-addressed.v1` | `SHIKIGAMI_KAFKA_EVENTS_TOPIC` | Topic carrying public integration events. |
| `kafka.groups.stream` | `shikigami-stream` | `SHIKIGAMI_KAFKA_STREAM_GROUP` | Consumer group of the activity-stream consumer. |
| `kafka.groups.events` | `shikigami-events` | `SHIKIGAMI_KAFKA_EVENTS_GROUP` | Consumer group of the integration-event consumer. |
| `kafka.dead_letter.queue` | `shikigami_stream_dead_letters` | `SHIKIGAMI_KAFKA_DEAD_LETTER_QUEUE` | PGMQ queue that stores poison Kafka records before their offsets advance. Queue names are non-empty, at most 47 characters, and contain only lowercase letters, digits, and underscores. |
| `kafka.include_agent_actors` | `false` | `SHIKIGAMI_KAFKA_INCLUDE_AGENT_ACTORS` | Whether the stream consumer matches agent-produced activities. Leaving it off is the feedback guard that stops an agent triggering itself. |
| `http.host` | `127.0.0.1` | `SHIKIGAMI_HTTP_HOST` | Interface the API binds. `*` binds every interface. |
| `http.port` | `8080` | `SHIKIGAMI_HTTP_PORT` | Port the API binds. Must be 1–65535; checked at resolution, not at bind. |
| `health.port` | per role — see below | `SHIKIGAMI_HEALTH_PORT` | Port the probe listener binds on a worker-role process. Must be 1–65535; checked at resolution, not at bind. |
| `sinks.kawa.base_url` | `http://localhost:8088` | `SHIKIGAMI_SINKS_KAWA_BASE_URL` | Base URL of the kawa ingest doorway. |
| `sinks.kawa.source_segment` | `shinzui/shikigami` | `SHIKIGAMI_SINKS_KAWA_SOURCE_SEGMENT` | Source segment kawa attributes ingested activity to. |
| `sinks.kizashi.base_url` | `http://localhost:8089` | `SHIKIGAMI_SINKS_KIZASHI_BASE_URL` | Base URL of the kizashi signal service. |
| `sinks.kizashi.default_recipient` | `recipient:default` | `SHIKIGAMI_SINKS_KIZASHI_DEFAULT_RECIPIENT` | Recipient used when a declared signal names none. |
| `sinks.danwa.base_url` | `http://localhost:8080` | `SHIKIGAMI_SINKS_DANWA_BASE_URL` | Base URL of the danwa conversation server. |
| `sinks.danwa.agent_participant` | `part_shikigami` | `SHIKIGAMI_SINKS_DANWA_AGENT_PARTICIPANT` | danwa participant id Shikigami authors messages as. |
| `sinks.rei.base_url` | *(none)* | `SHIKIGAMI_SINKS_REI_BASE_URL` | Base URL of a rei ingestion endpoint. The one sink URL with no default, because rei has no HTTP surface yet; unset means `ReiAction` sinks fail visibly instead of silently. |
| `behavior.provider` | `stub` | `SHIKIGAMI_BEHAVIOR_PROVIDER` | Which model runs a `Skill` behavior: `stub` calls no model, `anthropic` calls a real one. |
| `behavior.model` | `claude-sonnet-4-6` | `SHIKIGAMI_BEHAVIOR_MODEL` | Anthropic model id. Only consulted when the provider is `anthropic`; decoded against baikai's catalog, so an unknown id is rejected here. |
| `credentials.providers.anthropic.api_key` | *(none — secret)* | `ANTHROPIC_API_KEY` | Anthropic API key. **Required** when the provider is `anthropic`, unused otherwise. |

Both duration settings are whole seconds in the range 1–86400. The upper bound keeps
conversion to the microsecond timeout representation safe on the 64-bit platforms
supported by the deployment flake. `worker.run_timeout_seconds` bounds each synchronous
provider or program attempt; it does not time an entire durable workflow or a suspended
approval. The resume worker derives its workflow-instance lease as the run timeout plus a
30-second scheduling/database margin. Queue delivery visibility is a separate 10/30-second
heartbeat policy and is not configured by either key.

Environment bindings are explicit, one variable to one key. Nothing scans for a prefix, so
a typo is a variable that does nothing rather than a value landing on the wrong key.

Two variables keep an unprefixed spelling: `PG_CONNECTION_STRING`, which the dev shell
already exports, and `ANTHROPIC_API_KEY`, which is what the ecosystem calls that
credential. Binding the second one here is what keeps it flowing through Settei's
precedence and redaction instead of being read behind Settei's back by the client library.


## Choosing a model provider

`behavior.provider` is the only conditional part of the surface, and the only one whose
default is a deliberate fiction. Left alone it selects the **stub**: a provider that loads
the skill, builds the same request a real model would get, and answers with a fixed
sentence. That is what makes the test suite deterministic and key-free — and it is also
what a misconfigured production worker would quietly do, which is why the stub is never
silent. Every process announces its provider on standard error before it does any work:

```text
[shikigami.behavior] model provider: STUB — no model will be called; set behavior.provider=anthropic to use a real model
[shikigami.behavior] model provider: anthropic model=claude-haiku-4-5 credential=present
```

The model id is also written into the kioku session row as `modelUsed`, so a run made by
the stub stays distinguishable from a real one long after the log has rotated.

Setting `behavior.provider: anthropic` makes `credentials.providers.anthropic.api_key`
required. There is no partially-configured state: a worker asked for a real provider
without a credential fails at configuration time, with the reserved exit code `4`, before
it drains a single job.

```text
$ shikigami-worker --check-config --set behavior.provider=anthropic
credentials.providers.anthropic.api_key: required value is missing
$ echo $?
4
```

`--describe-config` states the relationship rather than leaving it to be discovered:

```text
behavior.model [optional, conditional, public] ...
credentials.providers.anthropic.api_key [required, conditional, secret] ...
condition 1: behavior.provider -> behavior.model, credentials.providers.anthropic.api_key
```

`shikigami-run-behavior` opens no database and joins no queue, so it is the cheapest way to
check a provider end to end:

```bash
$ shikigami-run-behavior --config /run/secrets/anthropic.yaml \
    --agent agents/triage-note.dhall --payload '{"text":"the export button crashes"}'
```


## Which binary needs what

Every binary accepts every key, so one configuration file can serve a whole deployment.
What differs is which keys a binary refuses to start without. `--check-config` answers for
the binary you ran it on.

| Binary | Refuses to start without |
|---|---|
| `shikigami-worker` | `database.connection_string` |
| `shikigami-scheduler` | `database.connection_string` |
| `shikigami-consume-stream` | `database.connection_string` |
| `shikigami-consume-events` | `database.connection_string` |
| `shikigami-agent-run` | `database.connection_string` |
| `shikigami-server` | `database.connection_string` |
| `shikigami-run-behavior` | nothing |
| `shikigami` | nothing at the top level |

`shikigami-server` is on the database list because its readiness probe pings PostgreSQL. A
server started without a connection string could never report ready, so it would bind its
socket and then fail every probe forever; failing at configuration time with the key named
is the better outcome.

`shikigami` is deliberately absent from the database list: `shikigami validate` and
`shikigami render-lifecycle` read a manifest and never connect, so requiring a connection
string for the whole command line would break an offline command. `shikigami enqueue-run`
asks for the value at the point it opens the store, and fails with exit code `4` and the
same key name if it is missing.

```text
$ shikigami-worker
shikigami-worker: database.connection_string is required by this process but no source supplied it
```


## Health probe ports

Every worker-role process serves `GET /health/live` and `GET /health/ready` on its own
listener, answering the same contract and the same body shape the server answers on its
`http.port` listener. `shikigami-server` does **not** open a second socket, so `health.port`
does nothing on it.

`health.port` has no single default, because the four worker processes routinely run on one
host and a shared default would leave three of them unable to bind. Each role has its own:

| Binary | Default probe port |
|---|---|
| `shikigami-worker` | `8091` |
| `shikigami-scheduler` | `8092` |
| `shikigami-consume-stream` | `8093` |
| `shikigami-consume-events` | `8094` |
| `shikigami-server` | none — probes are served on `http.port` |

Setting `health.port` overrides the role default. Because one declaration serves every
binary, setting it in a shared file gives every worker the *same* port, which is what the
per-role defaults exist to avoid — override it per process, not fleet-wide.

The listener binds the interface named by `http.host`, so the same setting decides whether a
development process stays on loopback or a deployed one is reachable by a probe from outside
its container.

`/health/live` reports whether this process's loops are still making progress; its failure
means restart the process. `/health/ready` reports whether PostgreSQL is reachable; its
failure means take the process out of load balancing but leave it running. Kafka and the
downstream HTTP sinks are deliberately **not** readiness dependencies: an outage there cannot
be repaired by restarting a pod, so making it readiness-critical would amplify one upstream
outage across the fleet.

```bash
$ curl -sS -o /dev/null -w '%{http_code}\n' localhost:8091/health/live
200
$ curl -sS localhost:8091/health/ready
{"check":"all","failingSince":null,"status":"ok"}
```

A failing probe names the check that failed and when it began failing, so a dashboard shows
one incident rather than a fresh one on every scrape:

```text
{"check":"postgres","failingSince":"2026-08-20T20:34:46.985935Z","status":"failed"}
```


## Named flags and the keys they set

The flags an operator already knew still work. Each is a command-line source for a
declared key, so it shows up in `--explain-config` with its spelling.

| Binary | Flag | Key |
|---|---|---|
| `shikigami-server` | `--host`, `--port` | `http.host`, `http.port` |
| `shikigami-worker` | `--agents` | `agents.directory` |
| | `--kawa-url` | `sinks.kawa.base_url` |
| | `--kizashi-url` | `sinks.kizashi.base_url` |
| | `--danwa-url` | `sinks.danwa.base_url` |
| | `--danwa-agent` | `sinks.danwa.agent_participant` |
| `shikigami-scheduler` | `--agents` | `agents.directory` |
| `shikigami-consume-stream` | `--agents`, `--broker` | `agents.directory`, `kafka.broker` |
| | `--topic`, `--group` | `kafka.activity.topic`, `kafka.groups.stream` |
| | `--include-agent-actors` | `kafka.include_agent_actors` (sets it to `true`) |
| `shikigami-consume-events` | `--agents`, `--broker` | `agents.directory`, `kafka.broker` |
| | `--topic`, `--group` | `kafka.events.topic`, `kafka.groups.events` |
| `shikigami publish-fixture` | `--broker`, `--topic` | `kafka.broker`, `kafka.activity.topic` |
| `shikigami stub-kawa` | `--broker` | `kafka.broker` |
| `shikigami danwa-spike` | `--danwa-url` | `sinks.danwa.base_url` |

Note that `--topic` and `--group` mean different keys on the two consumers, because the
two consumers read different topics. That is why they are separate binaries.

Flags that are *not* configuration stay ordinary arguments, because they name what a single
invocation is about rather than how the deployment is set up: `shikigami stub-kawa --port`
and `--republish-topic`, `shikigami danwa-spike --human` and `--agent`,
`shikigami-run-behavior --agent` and `--payload`, `shikigami-agent-run --agent` and
`--from-activity`, and the file or agent arguments of `validate`, `render-lifecycle`,
`enqueue-run`, and `publish-fixture`.

For `shikigami`, the configuration and diagnostic options are global and go *before* the
subcommand:

```bash
$ shikigami --config /etc/shikigami/admin.yaml enqueue-run heartbeat
$ shikigami --describe-config
```


## Configuration files

Files are YAML. `config/shikigami.example.yaml` in this repository is a complete example.

```yaml
database:
  connection_string: postgresql:///shikigami

agents:
  directory: /srv/shikigami/agents

worker:
  run_timeout_seconds: 300

approval:
  deadline_seconds: 900

kafka:
  broker: kafka.internal:9092
  activity:
    topic: activity.v1
  groups:
    stream: shikigami-stream
```

Pass one or several:

```bash
$ shikigami-worker --config /etc/shikigami/base.yaml --config /etc/shikigami/worker.yaml
```

Because unknown keys are rejected, a file may only contain keys from the table above. A
file is not per-binary: every binary accepts the whole surface, so one file works for all
of them.


## Secrets

`database.connection_string` is declared as a secret. That is a property of the
declaration, not of where the value came from, so it is redacted whatever supplied it:

- `--explain-config` prints `<redacted>` rather than the value, in text and in JSON.
- `--describe-config` never prints values at all.
- A decode failure names the key and the expected shape without echoing what was rejected.
- The resolved value has no `Show`, `Read`, or JSON instance in the code, so it cannot be
  logged or serialized by accident.

The test suite plants a unique token as the connection string, supplies it from a file,
from the environment, and from `--set` in turn, and asserts it appears in no rendering —
including the renderings produced by a *failing* resolution, which is where a raw value
most easily escapes. See `shikigami-core/test/Shikigami/AppConfigSpec.hs`.

A secret still reaches plaintext at exactly one place: `revealSecretText`, called where a
library demands the raw string. Grep for it to review every such point.


## The two exceptions

Two sets of environment variables are read by libraries rather than by this declaration,
because those libraries own the names and parse them themselves.

**OpenTelemetry (`OTEL_*`).** The OpenTelemetry SDK reads its standard variables —
`OTEL_EXPORTER_OTLP_ENDPOINT` and the rest — exactly as it does in every other service in
the fleet. Re-declaring them here would create a second, subtly different parser for names
an operator already knows, and would not stop the SDK reading them anyway. See
`shikigami-workers/src/Shikigami/Telemetry.hs`. A Shikigami-specific tracing *policy* would
be an ordinary setting; the standard variables stay SDK-owned.

**`DATABASE_URL`, for `shikigami-migrate` only.** This one is not a design preference. The
`shikigami-core` test suite depends on `shikigami-migrations`' public `test-support`
sublibrary, so adding `shikigami-core` to the migration executable makes the two packages
mutually dependent, and cabal's solver rejects the project outright. Until that boundary is
restructured, `shikigami-migrate` reads one variable itself; see the `migrate` recipe in
`Justfile`. Unifying this surface belongs to
`docs/plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md`, which owns
the migration CLI.


## Adding a setting

New settings are declared in `shikigami-core/src/Shikigami/App/Config.hs` and nowhere else.
Reading the environment directly, or writing a one-off parser, is not permitted — that is
the whole point of this plan. To add one:

1. Add a stable key next to the others, and a `Setting` with a description and a decoder.
   Use a bounded decoder for anything with a valid range, so `--check-config` catches a bad
   value rather than the code that later uses it.
2. Add a field to `AppConfig` named after the key, and a line to `appConfig` — `optional`
   for something a process can run without, `withDefault` otherwise. Every default carries
   a rule name and an explanation, which is what `--explain-config` prints.
3. Give every public setting a renderer, even a textual one where the renderer is `id`.
   Without it, `--explain-config` prints `<derived>` for a defaulted value, which tells an
   operator that a rule fired but not what it chose.
4. Use `secretSetting` for anything sensitive, and wrap the decoded value in `SecretText`.
   Do not derive `Show` or JSON for it.
5. Add an environment binding, spelled `SHIKIGAMI_` plus the key with dots and separators
   as underscores.
6. Extend the key list and the binding list in
   `shikigami-core/test/Shikigami/AppConfigSpec.hs`, and this document's table.

Only declare a setting something actually reads. A key that no code consults is a lie told
by `--describe-config`.
