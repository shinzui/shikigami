---
type: "Reference"
title: "CLI Reference"
description: "Look up Shikigami commands, options, and database recipes."
docId: "DOC-13"
tags: ["cli", "commands"]
generated:
  by: process:shikigami-user-docs-okf-migration
  at: 2026-09-07T14:41:30Z
---

# CLI Reference

Shikigami is **several binaries, not one**. The `shikigami` administrative dispatcher does not start worker roles: each long-running role is its own executable so an operator can scale, restart, and
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
shikigami enqueue-run <AGENT> [--payload <JSON>] [--conversation] [--key <TEXT>]
shikigami resolve-approval <TOKEN> (--approve | --reject <REASON>)
shikigami publish-fixture <FILE> [--broker <HOST:PORT>] [--topic <TOPIC>]
shikigami stub-kawa --port <PORT> [--republish-topic <TOPIC>] [--broker <HOST:PORT>]
shikigami danwa-spike --human <PARTICIPANT> --agent <PARTICIPANT> [--danwa-url <URL>]
shikigami grants list [--limit <N>] [--after <AGENT:KIND>]
shikigami grants grant <AGENT> <KIND> [--by <WHO>]
shikigami grants revoke <AGENT> <KIND> [--by <WHO>]
shikigami stub-kanmon --port <PORT> [--allow-conversation <KEY>]
shikigami agents list [--json]
shikigami agents sync [--json] [--alias <LEGACY_NAME=agent_...>]
shikigami runs show <WORKFLOW-NAME> <WORKFLOW-ID> [--json]
shikigami resources inspect <ROOT> [--json]
shikigami executions inspect <EXECUTION> [--json] [--after <POSITION>] [--limit <N>]
shikigami workers inspect <SESSION> [--json] [--after <POSITION>] [--limit <N>]
shikigami workers send|interrupt|cancel|transfer|reconcile|reconcile-checkpoint|integrate ...
shikigami objectives create|inspect|history|command ...
shikigami objectives trackers bind|command|inspect|proposals|deliveries|operation ...
shikigami proposals inspect|list|candidates|admissions|prune ...
shikigami proposals policy install|list|revoke ...
shikigami watchdog inspect [--agents DIR] [--grace SECONDS] [--fail-when-overdue] [--json]
shikigami watchdog episodes [--open] [--objective ID] [--after ID] [--limit N] [--json]
shikigami watchdog findings EPISODE_ID [--after ID] [--limit N] [--json]
```

The administrative binary also mounts Keiro's `wf`, `timer`, `outbox`, `inbox`,
`pgmq`, `projection`, `shard`, `snapshot`, and `stream` commands. See the
[operator CLI](../operations/operator-cli.md) for their usage and mutation previews.

**One-off agent runs** — from `shikigami-agent`, which links none of the platform's messaging,
queueing, or telemetry stack, so a consumer who is not running the Kikan platform can build and
use just these:

```text
shikigami-run-behavior --agent <FILE> [--payload <JSON>] [--workspace <DIR>]
shikigami-agent-run --agent <NAME|FILE> [--from-activity <FILE>] [--workspace <DIR>]
```

**Long-running roles** — from `shikigami-workers`:

```text
shikigami-worker [--agents <DIR>] [--kawa-url <URL>] [--kizashi-url <URL>] [--kanmon-url <URL>] [--danwa-url <URL>] [--danwa-agent <PARTICIPANT>]
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
(`shikigami-agent-run`, `shikigami enqueue-run`, `shikigami resolve-approval`, `shikigami-consume-stream`,
`shikigami-consume-events`, `shikigami-worker`, `shikigami-scheduler`) need the
`database.connection_string` setting and a migrated database (`just create-database`). The
dev shell exports `PG_CONNECTION_STRING`, the environment variable bound to that setting.
`shikigami validate`, `shikigami render-lifecycle`, and `shikigami-run-behavior` need neither a
database nor a model key.

Application-configured binaries also accept `--config PATH`, `--set KEY=VALUE`, and the five configuration
diagnostics (`--describe-config`, `--describe-config-json`, `--explain-config`,
`--explain-config-json`, `--check-config`). See
[Configuration](../operations/configuration.md) for the complete accepted surface, the
precedence order, and which binary refuses to start without what. The migration
CLI uses its own command parser and `DATABASE_URL`; `shikigami-openapi` takes no
arguments or configuration options. `shikigami-client` has a separate parser:
`shikigami-client health [--server URL]` queries both probes (default server
`http://localhost:8080`) and does not accept the shared configuration flags.

## `shikigami-client` — remote agents and runs

The client also provides these HTTP commands. Each accepts `--server URL` with
the same localhost default:

```text
shikigami-client [--token TOKEN] agents list [--first N] [--after CURSOR]
shikigami-client [--token TOKEN] agents show NAME
shikigami-client [--token TOKEN] runs request AGENT --key KEY [--payload JSON]
shikigami-client [--token TOKEN] runs show AGENT RUN_ID
shikigami-client [--token TOKEN] runs list AGENT [--first N] [--after CURSOR]
shikigami-client [--token TOKEN] runs wait AGENT RUN_ID [--timeout SECONDS] [--interval SECONDS]
```

The global token falls back to `SHIKIGAMI_API_TOKEN`. List sizes default to 50;
the API maximum is 200. Request payload defaults to `{}`. First acceptance prints
`accepted RUN_ID`; matching request replay prints `replayed RUN_ID`, followed by
the same resource Location. Neither response is a terminal result.

Wait defaults to a 600-second timeout and a 5-second interval. Exit codes are 0
for success, 1 for failure/cancellation, 2 for timeout, and 3 for a transport or
problem response. History lists HTTP acceptance receipts; use `runs show` for
lifecycle. The [HTTP API guide](http-api.md) covers setup, authentication,
idempotency, state meanings, and dead-letter retention.

For local database inspection, `shikigami runs show shikigami.agent-run RUN_ID
--json` includes the same derived lifecycle alongside workflow and session
objects. It also works for HTTP acceptances before a workflow exists, with those
objects null. See the [operator runbook](../operations/operator-cli.md).

## Objectives, proposals and watchdog inspection

These local administrative commands use the migrated database and shared
configuration flags. Objective and tracker mutations act as the configured local
operator. The remote `shikigami-client` commands above cover agents and runs;
use the documented local commands for these additional surfaces.

```bash
shikigami --config config.json objectives inspect OBJECTIVE_ID --after 0 --limit 20 --json
shikigami --config config.json objectives history OBJECTIVE_ID --limit 20 --json
shikigami --config config.json objectives trackers inspect OBJECTIVE_ID --json
```

Objective creation and conditional commands use JSON documents, stable operation
keys and expected revisions. Tracker commands retain their own operation keys,
proposal pages and delivery receipts. See [objectives](objectives.md) and
[external trackers](objective-trackers.md) for the exact documents and retry rules.
Objective inspection includes bounded adaptive hierarchy, decision and accounting
metadata; follow both page cursors as described in
[finite adaptive delivery](adaptive-delivery.md).

```bash
shikigami --config config.json proposals inspect --fail-when-exhausted --json
shikigami --config config.json proposals list --status pending --json
shikigami --config config.json proposals candidates --principal agent_shikigami_proposer --json
shikigami --config config.json proposals admissions --json
shikigami --config config.json proposals policy list --json
```

Proposal inspection includes configured observers even when they have no usage,
and reports live policy capacity. `--fail-when-exhausted` exits nonzero when an
observer window is full. Policy installation takes `--file FILE`; revocation takes
`POLICY_ID --expected-revision N`. Revocation stops fresh admission and leaves
already admitted work under its objective/root controls. See
[proposal operations](../operations/unrequested-work.md) for setup, policy
documents, filtering and pruning, and [unrequested work](unrequested-work.md) for
the person's acceptance path.

```bash
shikigami --config config.json watchdog inspect --agents agents --fail-when-overdue --json
shikigami --config config.json watchdog episodes --open --limit 20 --json
shikigami --config config.json watchdog findings EPISODE_ID --limit 20 --json
```

Watchdog reads use the configured principal and observation scope. `inspect`
requires the actual scheduled `watchdog-sweep` declaration (`--agents` defaults
to `agents`). It distinguishes the latest attempt from the last completion.
`--grace` defaults to 60 seconds and must be nonnegative. With
`--fail-when-overdue`, exit 2 means overdue, no completion or an uncomputable
schedule. Configuration/storage failures fail the command. Episode and finding
pages default to 20 and accept 1–100 entries with `--after` cursors; episodes also
filter by objective and open state. See [watchdog notices](watchdog.md) and
[watchdog operations](../operations/watchdog.md). These checks can run independently
of the supervised workflows; HTTP readiness and liveness do not include them.

---

## `shikigami validate`

```bash
$ shikigami validate <FILE>
```

Parse a `.dhall` manifest, decode it into the typed `AgentDecl`, and pretty-print it. For a
**skill-agent** it also loads `SKILL.md` and requires `name` and `description`
frontmatter keys. It does not enforce the full skill specification. Exits 0 on
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
$ shikigami-run-behavior --agent <FILE> [--payload <JSON>] [--workspace <DIR>]
```

Load a manifest and run **only a registered program or Skill**, printing the output
JSON. `behavior.provider` defaults to `stub`; an explicitly configured Anthropic
provider makes real model calls. Does not touch the DB or dispatch sinks. `--payload` supplies the trigger payload as
JSON (defaults to `null`; invalid JSON exits non-zero). **No DB or key.**

An identity-bearing Skill agent may declare the `workspace.read` capability overlay. Only
then does the command resolve `--workspace` (or the Git worktree containing the current
directory) and prepare the bounded observation tools
`overlay__workspace-read__read`, `overlay__workspace-read__grep`, and
`overlay__workspace-read__glob`. Paths must be relative to that worktree; absolute paths,
traversal, symlinks, Git internals, noisy build directories, binary files, and excessive
input or output are refused. Agents without the request receive no workspace tools, and the
command performs no Git discovery for them.

**Current limitation:** both one-off commands install `denyAllActionAuthorizer`.
A workspace request therefore fails before acquiring its provider; neither
`--workspace` nor Kikan authorization settings override that wiring. These commands
do not currently provide a working workspace-read run.

`shikigami-run-behavior` rejects sanctioned-profile requirements before dispatch;
use `shikigami-agent-run` to resolve those from the database. It also rejects
`Flow` and `Deterministic` behavior arms.

→ See [Behaviors](./behaviors.md).

## `shikigami-agent-run`

```bash
$ shikigami-agent-run --agent <NAME|FILE> [--from-activity <FILE>] [--workspace <DIR>]
```

Run an agent through the full **kioku** lifecycle — open session, recall prior learnings, run
behavior, record the new learning, complete — and print the across-run report. A bare `<NAME>`
resolves to `agents/<NAME>.dhall`; a path (contains `/` or ends in `.dhall`) is used as-is.

With `--from-activity <FILE>`, instead of running the behavior it folds an `activity.v1`
envelope (JSON) directly into the agent's memory (payload → content; verb/subject → tags).
**Needs the DB** (`database.connection_string`).

For a normal behavior run, `--workspace` requests the same opt-in `workspace.read` overlay as
`shikigami-run-behavior`. Its provider lease is scoped to the behavior call:
the acquisition boundary is after memory recall and release precedes learning
recording. The deny-all authorizer currently prevents acquisition. The activity-ingest
branch does not resolve or use a workspace. One-off runs use compatibility identity
and also deny protected sink actions; they do not publish an agent's sinks to services.

→ See [Memory & Sessions](./memory.md).

## `shikigami enqueue-run`

```bash
$ shikigami enqueue-run <AGENT> [--payload <JSON>] [--conversation] [--key <TEXT>]
```

Enqueue an **addressed run job** for a named agent onto the worker's `shikigami_run_jobs`
queue — the Event trigger class. `--payload` is the addressed run payload as JSON. A running
`worker` drains and executes it. `--conversation` selects the Danwa conversation
route explicitly; `--key` overrides the idempotency key. By default that key is
derived from the agent and payload, so repeat submissions can deduplicate.

→ See [Triggers](./triggers.md), [The Living Loop](./living-loop.md).

## `shikigami resolve-approval`

```bash
$ shikigami resolve-approval <TOKEN> --approve
$ shikigami resolve-approval <TOKEN> --reject "reason"
```

Resolve the opaque UUID token printed in a Danwa or Kizashi approval ask. Exactly one decision
is required. The first successful resolution prints `resolved: true` and exits 0; an unknown,
timed-out, or already-resolved token prints `resolved: false (unknown or already resolved)` and
exits 1. The command only signals the durable awakeable. A running worker resumes the approval
child and its parent, dispatching an approved sink or suppressing a rejected one.

**Needs the DB** (`database.connection_string`).

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
$ shikigami-worker [--agents <DIR>] [--kawa-url <URL>] [--kizashi-url <URL>] [--kanmon-url <URL>] [--danwa-url <URL>] [--danwa-agent <PARTICIPANT>]
```

Boot the supervised worker. Loads every `.dhall` in `--agents`, then drains
`shikigami_run_jobs`: for each job, run the agent's behavior, dispatch its (permission-gated)
sinks to the configured services, and record a kioku session. Defaults:
`--agents agents`, `--kawa-url http://localhost:8088`, `--kizashi-url http://localhost:8089`,
`--kanmon-url http://localhost:8090`, `--danwa-url http://localhost:8080`,
`--danwa-agent part_shikigami`. Each of those flags
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
| `just migrate` | apply Kiroku, Keiro, Kioku, and Shikigami components and reconcile read models |
| `just migrate-status` | inspect the migration status |
| `just new-migration <slug>` | scaffold the next numbered migration file (e.g. `0031-<slug>.sql`) and append it to the manifest |

→ See [Getting Started](./getting-started.md).

## Durable execution and continuing workers

`resources inspect` reports root limits, held reservations, actual usage and unknown
attempts. `executions inspect` pages accepted operation metadata (1–20 per page)
without revealing transcript bodies. `workers inspect` pages assignments/results,
owner epochs and pending checkpoints/handoffs. These reads require the database.
See [resource accounting](../operations/execution-resources.md),
[execution recovery](../operations/durable-execution.md) and the
[operator command forms](../operations/operator-cli.md).

Worker mutations require stable operation keys, fresh parent authority and the
relevant revision/epoch. With objective tracking and trusted associations configured,
the CLI uses the authoritative checkpoint/ownership providers for follow-ups and
integration. Transfer additionally requires the process-backed workspace supervisor;
file-only workspace settings cannot fence a former writer. See
[workspace setup](../operations/workspaces.md) and the
[accepted worker matrix](../evidence/plan-84/acceptance.md) for the qualified
configuration and recovery boundaries.
