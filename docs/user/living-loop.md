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
| `enqueue-run` | enqueues an addressed run job for a named agent (the Event path) |

## Prerequisites

- Inside the nix dev shell, with Postgres running and migrated:
  ```console
  $ process-compose up        # postgres + just create-database
  ```
- A Kafka/Redpanda broker reachable for the stream commands. The stream commands default to
  broker `127.0.0.1:9092` and topic `activity.v1`; point `--broker` at your broker.

  > The bundled `process-compose.yaml` starts **Postgres only**. Run a broker separately (or
  > skip the stream and use the addressed `enqueue-run` path, which needs no broker).

## Walkthrough

### 1. Start the kawa stub (republishing)

```console
$ cabal run shikigami -- stub-kawa --port 8088 \
    --republish-topic activity.v1 --broker 127.0.0.1:9092
```

The stub accepts `POST /v1/sources/{source_id}/events`, returns
`{ "activity_id": "<uuid>", "deduplicated": false }`, enforces idempotency on
`(source, source_event_id)`, logs each envelope, and — with `--republish-topic` — re-publishes
each accepted `KawaDigest` back onto the stream (exactly what real kawa's outbox will do).

### 2. Start the worker

```console
$ cabal run shikigami -- worker --agents agents \
    --kawa-url http://localhost:8088 --kizashi-url http://localhost:8089
[worker] loaded N agents
```

The worker loads every `.dhall` in `--agents`, then drains `shikigami_run_jobs`: for each job
it runs the agent's behavior, dispatches its (permission-gated) sinks to the configured kawa
and kizashi URLs, and records a kioku session.

### 3. Feed the stream

Publish a fixture envelope and let the consumer match it:

```console
$ cabal run shikigami -- consume-stream --agents agents --broker 127.0.0.1:9092 &
$ cabal run shikigami -- publish-fixture fixtures/envelope.json --broker 127.0.0.1:9092
```

`consume-stream` matches the envelope against each declared **Stream** agent's predicate and
enqueues a run job for every match. The worker (step 2) then runs the agent.

### 4. Watch the loop close

An agent whose sink is a `KawaDigest` (e.g. the heartbeat) produces a digest → the worker
POSTs it to `stub-kawa` → the stub republishes it onto `activity.v1` → `consume-stream` sees
it → a *second* agent (e.g. `agents/proof/digest-watcher.dhall`) matches and fires. The system
fed itself.

### The feedback guard

The republished digest carries `actor.kind = "agent"`. By default `consume-stream` **excludes
agent-produced activities**, so a digest only triggers agents that explicitly opt in. To let
meta-detectors match agent output:

```console
$ cabal run shikigami -- consume-stream --agents agents --include-agent-actors
```

Publishing `fixtures/envelope-agent.json` (an `actor.kind: "agent"` envelope) without that
flag fires nothing — the guard in action.

## The addressed path (no broker)

You don't need the stream to exercise the worker. Enqueue an addressed run directly:

```console
$ cabal run shikigami -- enqueue-run heartbeat --payload '{}'
# the running worker drains the job and runs `heartbeat`
```

This is the **Event** trigger class — the path a `mori` automation action or a `kanmon`
channel-inbound event uses to address an agent directly.

## Delegation

The proof agents under `agents/proof/` show the imperative parent/child path. The supervisor
agent starts two named specialists, parks durably while they run, and resumes with both results.

Start the worker against the proof manifests:

```console
$ cabal run shikigami -- worker --agents agents/proof
```

In another shell, enqueue the supervisor:

```console
$ cabal run shikigami -- enqueue-run research-supervisor \
    --payload '{"topic":"durable workflows"}'
```

The worker first logs the supervisor as suspended, then the resume worker drives
`web-researcher` and `code-researcher`, and then the supervisor completes. The synthesized
result is recorded in kioku as the supervisor run's behavior output.

To inspect lineage, query the session rows after the run:

```sql
SELECT session_id, agent_id, parent_session_id, delegation_depth, status
FROM kioku_sessions
WHERE agent_id IN ('research-supervisor', 'web-researcher', 'code-researcher')
ORDER BY started_at;
```

The supervisor row has `parent_session_id` `NULL` and `delegation_depth` `0`; both specialist
rows point at the supervisor session id and have `delegation_depth` `1`. If the worker exits
after the supervisor suspends, restart it with the same command: the parent workflow replays its
journal, observes the child results when they are available, and resumes instead of starting over.
