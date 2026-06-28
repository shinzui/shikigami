# Shikigami — User Guide

**Shikigami** (式神 — a summoned spirit-servant bound to its master's will) is a runtime
in which an autonomous system agent is *declared*, not coded. You write a short, typed
Dhall file that says:

> Run **this behavior**, when **this trigger** fires, and send the result to **these sinks**.

…and a thin worker runs it forever — on a schedule, in response to events flowing through
the activity stream, or when addressed by a public integration event. There is no bespoke service to build and
deploy: an agent is a declaration.

```text
behavior  = what the agent does     (a deterministic rule, a typed shikumi program, or a Skill)
trigger   = when it does it         (a schedule, an activity.v1 stream pattern, or a public addressed event)
sinks     = what it produces        (a kawa digest, a kizashi signal, a rei action, a danwa conversation)
identity  = under whose authority   (each sink is gated by a permission grant)
```

Instead of asking *"which service do I build to automate this coordination?"*, the question
becomes *"which behavior runs, on which trigger, producing which sinks — and is this agent
permitted each sink?"*

## A first agent

```dhall
-- agents/heartbeat.dhall
let A = ../schema/Agent.dhall
in  A.Agent::{
    , name = "heartbeat"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "noop-summary", preferEnrichment = False
          , grounding = None Text, enabledBy = None Text }
    , trigger = A.Trigger.Schedule { cron = "* * * * *" }
    , sinks = [ A.Sink.KawaDigest { subjectType = "heartbeat", verb = "heartbeat.tick" } ]
    }
```

```bash
$ cabal run shikigami -- validate agents/heartbeat.dhall
AgentDecl {name = "heartbeat", ...}
OK: 1 agent parsed.
```

## How to read these docs

Start with **[Getting Started](./getting-started.md)**, then read the four pieces of an
agent declaration in order:

| Guide | What it covers |
| --- | --- |
| **[Getting Started](./getting-started.md)** | Prerequisites, building, the database, your first validate + run |
| **[Writing Agents](./writing-agents.md)** | The Dhall schema: `name`, `description`, and how the four parts fit together |
| **[Triggers](./triggers.md)** | The three trigger classes — Schedule, Stream, Event — and the feedback guard |
| **[Behaviors](./behaviors.md)** | The behavior union — Deterministic, ShikumiProgram, Skill |
| **[Skills](./skills.md)** | Authoring a `SKILL.md` skill behavior |
| **[Sinks](./sinks.md)** | The producer sink set and the permission gate |
| **[Memory & Sessions](./memory.md)** | How an agent recalls prior learnings and records new ones across runs |
| **[Detectors](./detectors.md)** | Building the intelligence layer as declared agents |
| **[The Living Loop](./living-loop.md)** | Running the worker end to end; closing the loop with `stub-kawa` |
| **[CLI Reference](./cli.md)** | Every `shikigami` subcommand |

## Mental model in one picture

```text
Agent declarations (agents/*.dhall, schema/Agent.dhall)
  │  loaded + validated by the Dhall loader
  ▼
Trigger fires  ──  Schedule (cron) │ Stream (activity.v1 match) │ Event (public integration event)
  ▼
Behavior runs  ──  Deterministic rule │ shikumi program (handan) │ Skill (baikai)
  ▼
Sinks dispatch ──  KawaDigest │ KizashiSignal │ ReiAction │ DanwaConversation   (each permission-gated)
  ▼
Session recorded (kioku) ── prior learnings recalled before, new learning recorded after
  ▼
A KawaDigest reappears on activity.v1 → a *second* agent fires on it → the living loop closes.
```

Danwa addressed conversations use the Event path: Danwa publishes
`danwa.message-addressed-to-agent` on `danwa.message-addressed.v1`, Shikigami consumes that
public topic with `consume-events`, and replies through Danwa's HTTP API. Shikigami does not
read Danwa's database or private event store.

> **Status note.** Several downstream services (`kawa`, `shomei`, `kanmon`, `danwa`) are
> proven against **stubs and fixtures** in this runtime; their live wiring is owned by their
> own plans. Where a guide says "stub," the contract shape is real and the stub swaps for the
> live client with no schema change. The full design is frozen in
> [`docs/initial-spec.md`](../initial-spec.md).
