---
type: "Explanation"
title: "Memory & Sessions"
description: "Understand how agents recall and record memory across runs and sessions."
docId: "DOC-10"
tags: ["memory", "sessions"]
generated:
  by: process:shikigami-user-docs-okf-migration
  at: 2026-09-07T14:41:30Z
---

# Memory & Sessions

An agent that runs every hour should not start blank each time. Shikigami records every agent
run as a **session** and every learning as a durable **memory**, both via **kioku** (記憶,
"memory"), a reusable event-sourced memory/session library. Before each run the agent
**recalls** its prior learnings; after each run it may **record** a new one, according to the
agent's declared memory policy. Knowledge accumulates across runs without making every
behavior output mandatory memory.

> kioku replaces the design's original bespoke `agent_runs` SQL table. A run is a kioku
> **Session**; a learning is a kioku **Memory**. Verified durable runs use their
> recorded Meibo principal as the agent scope. Directory-disabled and one-off runs
> use an explicit compatibility identity derived from the agent name. Legacy
> name scopes remain readable through operator-managed aliases; see
> [the operator CLI](../operations/operator-cli.md).

## The run lifecycle

`agent-run` (and the worker) execute this lifecycle for each run:

```text
1. open session     ── scoped to the recorded identity; focus = the behavior arm
2. recall            ── fetch the agent's prior learnings for this scope
3. run behavior      ── registered ShikumiProgram / Skill / durable Flow
4. apply record policy ── optionally persist the success or failure as memory
5. complete session    ── or fail the session on a behavior error
```

A successful run normally records one memory tagged `agent-run` plus the behavior-arm
label. A behavior error fails the session and reports the error; whether it first records a
failure memory depends on `recordPolicy`.

## Recall — what the agent already knows

Recall runs a **hybrid** query (vector + scope) for up to `memory.recallLimit` prior memories,
falling back to active memories in the same scope when vector search is unavailable (for
example, when the Postgres vector extension isn't present). The declared limit, which must
be from 1 through 1000, caps both paths. The query is built from the agent's name, its
behavior arm, and learning-oriented terms — so an agent recalls *its own* relevant past
output, not the whole store.

`memory.scope` defaults to `AgentScope`, the currently enforced behavior. The `Shared`
alternative is part of the stable declaration schema but will not provide shared recall
until [plan 34](../plans/34-memory-lifecycle-distillation-retention-and-shared-scope.md)
implements its lifecycle and access rules.

The behavior's output is distilled into a memory's content: a `summary` or `reply` string
field is used directly; otherwise the compact JSON encoding is stored.

## Recording policy

Declare the automatic recording behavior in the manifest:

```dhall
, memory =
    { scope = A.MemoryScope.AgentScope
    , recallLimit = 10
    , recordPolicy = A.RecordPolicy.OnSuccess
    }
```

- `OnSuccess` is the backward-compatible default: successful output is recorded and failed
  output is not.
- `Never` skips the automatic record for a successful run; the session still completes and
  the behavior output is still returned.
- `Always` records successful output and also records failures as `"run failed: …"`, tagged
  with `agent-run` and `failure`, before failing the session.

This policy governs the run lifecycle's automatic record step. A Flow that explicitly calls
`remember` still records, because that call is an explicit instruction rather than lifecycle
bookkeeping.

## Run an agent with memory

```bash
$ cabal run shikigami-agent-run -- --agent heartbeat
agent "heartbeat" run run_01k…
recalled 0 prior memories:
recorded learning mem_01k…
```

Run it again and `recalled` grows — the previous run's learning comes back:

```bash
$ cabal run shikigami-agent-run -- --agent heartbeat
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
$ cabal run shikigami-agent-run -- --agent triage-note --from-activity fixtures/envelope.json
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
