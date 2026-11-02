---
type: "Navigation"
title: "Shikigami — User Guide"
description: "Find the right guide for declaring, running, and operating Shikigami agents."
docId: "DOC-1"
timestamp: "2026-11-02T09:53:52Z"
tags: ["navigation", "agents"]
generated:
  by: process:shikigami-user-docs-okf-migration
  at: 2026-09-07T14:41:30Z
---

# Shikigami — User Guide

**Shikigami** (式神 — a summoned spirit-servant bound to its master's will) is a runtime
in which an autonomous system agent is *declared*, not coded. You write a short, typed
Dhall file that says:

> Run **this behavior**, when **this trigger** fires, and send the result to **these sinks**.

…and a thin worker runs it forever — on a schedule, in response to events flowing through
the activity stream, or when addressed by a public integration event. There is no bespoke service to build and
deploy: an agent is a declaration.

```text
behavior  = what the agent does     (a registered shikumi program, a Skill, or a durable Flow)
trigger   = when it does it         (a schedule, an activity.v1 stream pattern, or a public addressed event)
sinks     = what it produces        (a kawa digest, a kizashi signal, a rei action, a danwa conversation, channel egress)
identity  = under whose authority   (principal lifecycle, sink grants, and exact action authorization)
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
| **[Behaviors](./behaviors.md)** | The behavior union — Deterministic, ShikumiProgram, Skill, Flow |
| **[Flows](./flows.md)** | Durable lifecycle-backed behaviors that can park, resume, and render diagrams |
| **[Typed decisions in Flows](./typed-decisions.md)** | Model aliases, validated typed results, replay, and actual-attempt evidence |
| **[HTTP API — agents and runs](./http-api.md)** | Authentication, agent discovery, idempotent submission, status, and acceptance history |
| **[Architecture-practice reviews](./architecture-practice-reviews.md)** | Revision-pinned advisory review, resolution, attention, and recovery |
| **[Skills](./skills.md)** | Authoring a `SKILL.md` skill behavior |
| **[Sinks](./sinks.md)** | The producer sink set and the permission gate |
| **[Durable objectives](./objectives.md)** | Goals, authoritative progress, cross-run continuity and explicit integrated acceptance |
| **[Memory & Sessions](./memory.md)** | How an agent recalls prior learnings and records new ones across runs |
| **[Detectors](./detectors.md)** | Building the intelligence layer as declared agents |
| **[The Living Loop](./living-loop.md)** | Running the worker end to end; closing the loop with `stub-kawa` |
| **[CLI Reference](./cli.md)** | Every `shikigami` subcommand |
| **[Configuration](../operations/configuration.md)** | Every setting each binary accepts, where values come from, and the `--check-config` / `--explain-config` diagnostics |

## Mental model in one picture

```text
Agent declarations (agents/*.dhall, schema/Agent.dhall)
  │  loaded + validated by the Dhall loader
  ▼
Trigger fires  ──  Schedule (cron) │ Stream (activity.v1 match) │ Event (public integration event)
  ▼
Behavior runs  ──  Registered shikumi program (handan) │ Skill (baikai) │ Flow (keiro)
  ▼
Sinks dispatch ──  KawaDigest │ KizashiSignal │ ReiAction │ DanwaConversation │ ChannelEgress (permission-gated)
  ▼
Session recorded (kioku) ── prior learnings recalled before, new learning recorded after
  ▼
A KawaDigest reappears on activity.v1 → a *second* agent fires on it → the living loop closes.
```

Danwa addressed conversations use the Event path: Danwa publishes
`danwa.message-addressed-to-agent` on `danwa.message-addressed.v1`, Shikigami consumes that
public topic with `consume-events`, and replies through Danwa's HTTP API. Shikigami does not
read Danwa's database or private event store.

> **Status note.** The schema's `Deterministic` arm and some detector seed tasks
> are not executable yet; see [Behaviors](./behaviors.md) and [Detectors](./detectors.md).
> Protected external actions fail closed by default and need deployment authorization.
> Stubs and fixtures provide local contract proofs; the
> [initial spec](../initial-spec.md) records the original design, not current feature status.

## Maintaining this documentation

This directory is an OKF 0.2 bundle using the shared
[user-documentation profile](mori://shinzui/okf-profiles/profiles/user-documentation).
The generated `index.md` groups pages by reader intent; this page keeps the
curated reading order. Each page has a stable `DOC-N` handle. Preserve that handle
when renaming or revising a page, and allocate a new one for a new page.

After editing pages, update `log.md`, regenerate the index with
`just user-docs-index`, and run `just user-docs-validate`. The migration provenance
records the format conversion; it does not claim independent verification of the
existing runtime examples.

## Recovery and continuing work

New leaf Skills retain accepted model/tool work in a protected durable execution
child. See [execution policy and recovery](../operations/durable-execution.md),
[root accounting](../operations/execution-resources.md) and
[worker inspection/control](../operations/operator-cli.md). Manifest `execution`
selects an admitted whole-assignment model binding; `harness` narrows operator
policy. Continuing-worker primitives do not yet supply real objective/checkpoint
or mutable workspace providers. The [roadmap](../roadmap.md) tracks those gates.
