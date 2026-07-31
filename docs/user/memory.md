# Memory & Sessions

An agent that runs every hour should not start blank each time. Shikigami records every agent
run as a **session** and every learning as a durable **memory**, both via **kioku** (記憶,
"memory"), a reusable event-sourced memory/session library. Before each run the agent
**recalls** its prior learnings; after each run it **records** a new one. Knowledge
accumulates across runs.

> kioku replaces the design's original bespoke `agent_runs` SQL table. A run is a kioku
> **Session**; a learning is a kioku **Memory**. Both are scoped to the agent by its stable
> `name`, so memory accumulates per agent.

## The run lifecycle

`agent-run` (and the worker) execute this lifecycle for each run:

```text
1. open session     ── scoped to the agent name; focus = the behavior arm
2. recall            ── fetch the agent's prior learnings for this scope
3. run behavior      ── Deterministic / ShikumiProgram / Skill
4. record learning   ── the behavior's output becomes a durable memory (on success)
5. complete session  ── (or fail the session on a behavior error — no memory recorded)
```

A behavior error **fails** the session and records **no** learning; the run reports the
error. A successful run records one memory tagged `agent-run` plus the behavior-arm label.

## Recall — what the agent already knows

Recall is scoped to the agent and runs a **hybrid** query (vector + scope) for up to 10 prior
memories, falling back to "active memories for this scope" when vector search is unavailable
(e.g. the Postgres vector extension isn't present). The query is built from the agent's name,
its behavior arm, and learning-oriented terms — so an agent recalls *its own* relevant past
output, not the whole store.

The behavior's output is distilled into a memory's content: a `summary` or `reply` string
field is used directly; otherwise the compact JSON encoding is stored.

## Run an agent with memory

```bash
$ cabal run shikigami -- agent-run --agent heartbeat
agent "heartbeat" run run_01k…
recalled 0 prior memories:
recorded learning mem_01k…
```

Run it again and `recalled` grows — the previous run's learning comes back:

```bash
$ cabal run shikigami -- agent-run --agent heartbeat
agent "heartbeat" run run_01k…
recalled 1 prior memories:
  - mem_01k… [Pattern/Medium] <the prior run's summary>
recorded learning mem_01k…
```

The agent name resolves to `agents/<name>.dhall`; a path with `/` or a `.dhall` suffix is
used as-is. This command needs the database — run `just create-database` first, and ensure
`database.connection_string` is set. The dev shell exports `PG_CONNECTION_STRING`, which is
the environment variable bound to that setting; see
[Configuration](../operations/configuration.md) for the other ways to supply it.

## Recording an activity as memory

Instead of running the behavior, you can fold an `activity.v1` envelope **directly into the
agent's memory** with `--from-activity`. The envelope's `payload` becomes the memory content
and its `verb`/`subject.type` become searchable tags:

```bash
$ cabal run shikigami -- agent-run --agent triage-note --from-activity fixtures/envelope.json
recorded activity memory mem_01k…
```

This is how an agent captures something it observed (including its own agent-produced output)
as a learning it can recall later.

## Why this matters

- **Stateful agents.** A recurring agent builds context over time instead of re-deriving it.
- **Auditability.** Sessions are an event-sourced trail: start, complete, or fail — a crash
  mid-run leaves a started-but-not-completed session as the recovery signal.
- **No table to build.** kioku owns the storage; shikigami just maps runs and learnings onto
  it. `just migrate` installs kioku's schema alongside shikigami's own.

The full data shapes live in the kioku library; shikigami consumes it as a pinned dependency.
