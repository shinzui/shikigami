# Triggers — *when* an agent fires

A trigger is one of three classes. They cover the whole space of "when should this agent
run": on a clock, when the world changes, or when something addresses the agent directly.

```dhall
let Trigger =
      < Schedule : { cron : Text }
      | Stream   : { match : StreamMatch }
      | Event    : { eventType : Text }
      >
```

| Class | Constructor | Fires when… | Reaches the agent via… |
| --- | --- | --- | --- |
| **Schedule** | `Trigger.Schedule` | the clock matches a cron expression | a due-time job on the worker queue |
| **Stream** | `Trigger.Stream` | a matching `activity.v1` envelope is published | the Kafka stream consumer |
| **Event** | `Trigger.Event` | a public integration event or direct command addresses the agent | the integration-event consumer or run queue |

## Schedule — the clock

```dhall
trigger = A.Trigger.Schedule { cron = "* * * * *" }   -- every minute
```

A standard five-field cron expression. The worker enqueues a due-time job and runs the agent
when it fires. Use this for recurring work — a digest every morning, a heartbeat every
minute, a weekly rollup.

## Stream — observe `activity.v1`

```dhall
trigger =
  A.Trigger.Stream
    { match =
        { verb        = Some "ticket.received"   -- match this verb (optional)
        , source      = None Text                -- match this source (optional)
        , subjectType = Some "ticket"            -- match this subject type (optional)
        , verbs       = [] : List Text           -- OR match any verb in this list (empty = any)
        }
    }
```

The Stream trigger binds the **one** `activity.v1` topic — the unified river of everything
that happens in the system — and fires the agent for each envelope that matches its
predicate. It never binds raw per-service topics.

### How matching works

`StreamMatch` is an **AND of the predicates that are present**:

- `verb`, `source`, `subjectType` — each `Optional Text`. A `Some "x"` predicate must equal
  the envelope's field; a `None Text` predicate is ignored.
- `verbs` — a `List Text` for matching **any** of several verbs (the multi-verb case). An
  empty list matches any verb. This is how a detector watches both
  `["intention.declared", "action.recorded"]` on one subject.

An envelope matches when **all present predicates** hold. Examples:

| `match` | Fires on |
| --- | --- |
| `{ verb = Some "x", subjectType = None, source = None, verbs = [] }` | every `x` activity, any subject |
| `{ subjectType = Some "ticket", verb = None, source = None, verbs = [] }` | every activity about a `ticket` |
| `{ verbs = ["a","b"], subjectType = Some "intention", … }` | `a` or `b` activities about an `intention` |

### The feedback guard

By default the stream consumer **excludes activities produced by agents**
(`actor.kind = "agent"`). This prevents feedback loops: an agent's own digest reappearing on
the stream does not re-trigger detectors that watch human activity.

To intentionally match agent-produced activities (a "meta-detector" that watches other
agents), pass `--include-agent-actors` to the stream consumer:

```bash
$ cabal run shikigami -- consume-stream --agents agents --include-agent-actors
```

See **[The Living Loop](./living-loop.md)** for how a digest *does* legitimately trigger a
second agent.

## Event — addressed delivery

```dhall
trigger = A.Trigger.Event { eventType = "ticket.escalated" }
```

An Event-triggered agent runs when it is **addressed directly**. This is the path for public
integration events and commands that already know their recipient. Event triggers bypass
`activity.v1`; they match the integration event's `eventType` or are enqueued directly as a
run job.

Consume a public integration-event topic with `consume-events`:

```bash
$ cabal run shikigami -- consume-events \
    --agents agents \
    --broker 127.0.0.1:9092 \
    --topic danwa.message-addressed.v1
```

For Danwa conversations, declare:

```dhall
trigger = A.Trigger.Event { eventType = "danwa.message-addressed-to-agent" }
```

Danwa publishes that public event type to `danwa.message-addressed.v1` when integration
events are enabled. Shikigami consumes the topic and uses Danwa's HTTP API for replies. It
must not read Danwa's database, private event store, read models, or outbox tables.

Enqueue an addressed run by hand with `enqueue-run`:

```bash
$ cabal run shikigami -- enqueue-run my-agent --payload '{"ticketId":"T-42"}'
```

The worker drains the queue and runs the named agent with that payload. Manual enqueueing is
useful for local smoke tests and command-style integrations that do not use a broker.

## Choosing a trigger

| If the agent should run… | Use |
| --- | --- |
| on a fixed cadence | `Schedule` |
| whenever something happens in the system | `Stream` |
| only when explicitly invoked / addressed | `Event` |
