---
type: "Tutorial"
title: "The Living Loop — running agents end to end"
description: "Exercise the worker, stream feedback loop, addressed conversations, and delegation."
docId: "DOC-12"
tags: ["workers", "events", "delegation"]
generated:
  by: process:shikigami-user-docs-okf-migration
  at: 2026-09-07T14:41:30Z
---

# The Living Loop — running agents end to end

The "living loop" is the system feeding itself: an agent produces a `KawaDigest`, that digest
reappears on the `activity.v1` stream, and a *second* agent fires on it — produced by no
human, written by no bespoke service. This guide runs the whole pipeline locally with the
worker, the kawa stub, and the fixture stream.

```text
publish-fixture ──▶ activity.v1 ──▶ consume-stream (matches agents) ──▶ enqueue run job
                                                                              │
                                                                              ▼
                                          worker: run behavior ─▶ dispatch sinks ─▶ record session
                                                                              │
                                          KawaDigest ─▶ stub-kawa ──┐          │
                                                                    │ republish │
                                                                    ▼          ▼
                                                          activity.v1 (loop closes — a 2nd agent fires)
```

## Pieces

| Command | Role |
| --- | --- |
| `worker` | drains the run-job queue: runs each agent, dispatches its sinks, records the session |
| `stub-kawa` | a kawa ingest doorway stub; with `--republish-topic` it re-publishes accepted digests onto the stream |
| `publish-fixture` | publishes one Activity Envelope (JSON) onto `activity.v1` with the required `keiro-*` headers |
| `consume-stream` | consumes `activity.v1`, matches declared Stream agents, enqueues run jobs |
| `consume-events` | consumes a public integration-event topic, matches declared Event agents, enqueues run jobs |
| `enqueue-run` | enqueues an addressed run job for a named agent (the Event path) |

## Prerequisites

- Inside the nix dev shell, with Postgres running and migrated:
  ```console
  $ process-compose up        # postgres + just create-database
  ```
- The globally managed Redpanda broker reachable at `127.0.0.1:9092`. Verify it before
  starting a stream command:

  ```console
  $ rpk cluster info --brokers 127.0.0.1:9092
  ```

  The stream commands default to that broker and topic `activity.v1`; point `--broker` at
  another broker only when intentionally testing a different cluster.

  > The bundled `process-compose.yaml` starts **Postgres only**. Run a broker separately (or
  > skip the stream and use the addressed `enqueue-run` path, which needs no broker). In the
  > standard development environment, the separate broker is the global Redpanda service;
  > do not start a repository-private broker on the same port.

The sink-producing parts below additionally require an active verified Meibo agent
identity, a database sink grant, and the complete Kikan action-authorization trust
configuration. Configure these for every process admitting work; see
[operator inventory and sync](../operations/operator-cli.md) and
[action authorization](../operations/action-authorization.md). Default disabled
authorization permits no protected external action, even against a downstream stub.
The proof manifests need matching directory handles or declared principal ids.

With the shared environment configured, bind the heartbeat grant before starting:

```bash
$ cabal run shikigami -- grants grant heartbeat KawaDigest --by operator
$ cabal run shikigami -- --set agents.directory=agents/proof agents sync
```

## Walkthrough

### 1. Start the kawa stub (republishing)

```bash
$ cabal run shikigami -- stub-kawa --port 8088 \
    --republish-topic activity.v1 --broker 127.0.0.1:9092
```

The stub accepts `POST /v1/sources/{source_id}/events`, returns
`{ "activity_id": "<uuid>", "deduplicated": false }`, enforces idempotency on
`(source, source_event_id)`, logs each envelope, and — with `--republish-topic` — re-publishes
each accepted `KawaDigest` back onto the stream (exactly what real kawa's outbox will do).

### 2. Start the worker

```bash
$ cabal run shikigami-worker -- --agents agents/proof \
    --kawa-url http://localhost:8088 --kizashi-url http://localhost:8089
{"event":"agents.manifest.loaded", ...}
```

The worker loads every `.dhall` in `--agents`, then drains `shikigami_run_jobs`: for each job
it runs the agent's behavior, dispatches its (permission-gated) sinks to the configured kawa
and kizashi URLs, and records a kioku session.

### 3. Start the consumer and enqueue the heartbeat

Run the consumer in a separate terminal against the same proof directory. Enable
agent-produced activity so `digest-watcher` can observe the heartbeat output:

```bash
$ cabal run shikigami-consume-stream -- --agents agents/proof \
    --broker 127.0.0.1:9092 --include-agent-actors
```

Then enqueue the producer (the worker alone does not arm Schedule triggers):

```bash
$ cabal run shikigami -- enqueue-run heartbeat --payload '{}' --key living-loop-1
```

Use a new `--key` when deliberately starting another run. To test ordinary stream
matching independently, `shikigami publish-fixture fixtures/envelope.json` publishes
the ticket fixture, but it does not address the Schedule-triggered heartbeat.

### 4. Watch the loop close

An agent whose sink is a `KawaDigest` (e.g. the heartbeat) produces a digest → the worker
POSTs it to `stub-kawa` → the stub republishes it onto `activity.v1` → `consume-stream` sees
it → a *second* agent (e.g. `agents/proof/digest-watcher.dhall`) matches and fires. The system
fed itself.

### The feedback guard

The republished digest carries `actor.kind = "agent"`. By default `consume-stream` **excludes
agent-produced activities**, so the consumer must explicitly opt in for this walkthrough. To let
meta-detectors match agent output:

```bash
$ cabal run shikigami-consume-stream -- --agents agents/proof --include-agent-actors
```

Publishing `fixtures/envelope-agent.json` (an `actor.kind: "agent"` envelope) without that
flag fires nothing — the guard in action.

## The addressed path (no broker)

You don't need the stream to exercise the worker. Enqueue an addressed run directly:

```bash
$ cabal run shikigami -- enqueue-run heartbeat --payload '{}'
# the running worker drains the job and runs `heartbeat`
```

This is the **Event** trigger class — the path a `mori` automation action or a `kanmon`
channel-inbound event uses to address an agent directly.

## Danwa addressed conversations (public topic)

Danwa can publish public integration events for messages addressed to an agent. When Danwa is
configured with integration publishing enabled, it emits
`danwa.message-addressed-to-agent` events on `danwa.message-addressed.v1`.

Start the event consumer:

```bash
$ cabal run shikigami-consume-events -- \
    --agents agents \
    --broker 127.0.0.1:9092 \
    --topic danwa.message-addressed.v1 \
    --group shikigami-danwa
```

Then start the worker with Danwa HTTP settings:

```bash
$ cabal run shikigami-worker -- --agents agents \
    --danwa-url http://localhost:8080 \
    --danwa-agent part_shikigami
```

The sample `agents/danwa-heartbeat.dhall` listens for
`danwa.message-addressed-to-agent` and replies through `DanwaConversation`. Shikigami only
uses Danwa's public integration topic and HTTP API in this path. It never reads Danwa's
database, event store, read models, or outbox tables.

## Delegation

The proof agents under `agents/proof/` show the governed parent/child path.
The two specialists return fixed proof findings; they do not perform live web or code research. The supervisor
agent starts two named specialists, parks durably while they run, and resumes with both results.

Start the worker against the proof manifests:

```bash
$ cabal run shikigami-worker -- --agents agents/proof
```

In another shell, enqueue the supervisor:

```bash
$ cabal run shikigami -- enqueue-run research-supervisor \
    --payload '{"topic":"durable workflows"}'
```

The worker first logs the supervisor as suspended, then the resume worker drives
`web-researcher` and `code-researcher`, and then the supervisor completes. The synthesized
result is recorded in kioku as the supervisor run's behavior output.

To inspect the parent and child runs, use the supported operator commands:

```bash
$ cabal run shikigami -- wf list --name shikigami.agent-run
$ cabal run shikigami -- runs show shikigami.agent-run <workflow-id> --json
```

The run/session evidence records parent session identity and delegation depth.
See [the operator CLI](../operations/operator-cli.md) for journal and lifecycle inspection.
If the worker exits
after the supervisor suspends, restart it with the same command: the parent workflow replays its
journal, observes the child results when they are available, and resumes instead of starting over.
