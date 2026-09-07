---
type: "Guide"
title: "Writing Agents"
description: "Declare agent identity, behavior, triggers, sinks, memory policy, and routing in Dhall."
docId: "DOC-3"
tags: ["agents", "dhall"]
generated:
  by: process:shikigami-user-docs-okf-migration
  at: 2026-09-07T14:41:30Z
---

# Writing Agents

An agent is a value in the typed Dhall schema at [`schema/Agent.dhall`](../../schema/Agent.dhall).
Every manifest imports that schema and produces one `Agent` record. Its trigger, behavior,
and sinks describe execution; identity, memory policy, and enablement describe how that
execution is governed:

```dhall
let A = ../schema/Agent.dhall
in  A.Agent::{
    , name = "my-agent"                 -- a human label (required)
    , description = "what it does"       -- optional, defaults to ""
    , trigger  = A.Trigger.Schedule { cron = "* * * * *" }   -- WHEN it runs
    , behavior = A.Behavior.ShikumiProgram { … }             -- WHAT it does
    , sinks    = [ A.Sink.KawaDigest { … } ]                 -- WHAT it produces
    , identity = Some { principal = "principal_my_agent" }   -- WHO authorizes it
    , memory =
        { scope = A.MemoryScope.AgentScope
        , recallLimit = 25
        , recordPolicy = A.RecordPolicy.OnSuccess
        }
    , enabled = True
    }
```

`A.Agent::{ … }` uses Dhall's record-completion syntax: it merges your fields over the
schema's defaults, so you only write the fields you care about.

## The schema at a glance

```dhall
let Agent =
      { Type =
          { name : Text
          , description : Text
          , trigger : Trigger          -- one of three classes
          , behavior : Behavior         -- one of three arms
          , sinks : List Sink           -- zero or more producer outputs
          , delegates : List Text
          , delegationBudget : Optional Natural
          , sanctionedProfile : Optional ProfileRequirement.Type
          , capabilityOverlays : List Text
          , identity : Optional Identity
          , memory : MemoryPolicy
          , enabled : Bool
          , expertise : List Expertise
          , routing : Optional RouterPolicy
          }
      , default =
          { description = ""
          , sinks = [] : List Sink
          , delegates = [] : List Text
          , delegationBudget = None Natural
          , sanctionedProfile = None ProfileRequirement.Type
          , capabilityOverlays = [] : List Text
          , identity = None Identity
          , memory =
              { scope = MemoryScope.AgentScope
              , recallLimit = 10
              , recordPolicy = RecordPolicy.OnSuccess
              }
          , enabled = True
          , expertise = [] : List Expertise
          , routing = None RouterPolicy
          }
      }
```

| Field | Type | Meaning | Default |
| --- | --- | --- | --- |
| `name` | `Text` | Human label; also resolves `agents/<name>.dhall` for the CLI | — (required) |
| `description` | `Text` | Free-text summary | `""` |
| `trigger` | `Trigger` | When the agent fires — see **[Triggers](./triggers.md)** | — (required) |
| `behavior` | `Behavior` | What the agent does — see **[Behaviors](./behaviors.md)** | — (required) |
| `sinks` | `List Sink` | What the agent produces — see **[Sinks](./sinks.md)** | `[]` |
| `delegates` | `List Text` | Exact allow-list of child agents this declaration may launch | `[]` |
| `delegationBudget` | `Optional Natural` | Optional root-run-wide child budget | platform default |
| `sanctionedProfile` | `Optional ProfileRequirement` | Execution profile the run must resolve and satisfy | `None` |
| `capabilityOverlays` | `List Text` | Additive model-tool capabilities requested by this agent | `[]` |
| `identity` | `Optional Identity` | Stable meibo principal whose authority the agent will use | `None` |
| `memory` | `MemoryPolicy` | Recall scope, recall bound, and automatic recording policy | agent scope, 10 results, record on success |
| `enabled` | `Bool` | Whether long-running worker roles load the agent | `True` |
| `expertise` | `List Expertise` | Routing metadata describing a specialist's knowledge | `[]` |
| `routing` | `Optional RouterPolicy` | Bounded semantic-selection policy over `delegates` | `None` |

The five sink variants are `KawaDigest`, `KizashiSignal`, `ReiAction`,
`DanwaConversation`, and `ChannelEgress`. `ChannelEgress` sends an external conversation
action through Kanmon; see [Sinks](./sinks.md#channelegress--act-through-kanmon) for its
destination precedence and grant requirements.

Because `sinks` defaults to `[]`, an agent with no sinks is legal — it runs its behavior and
records a session, producing nothing outward. That's useful for a behavior whose only job is
to learn (record memory) for later runs.

## Identity

Declare an identity when the agent already has a stable principal in meibo:

```dhall
, identity = Some { principal = "agent_01h000000000000000heartbeat" }
```

With `directory.mode=file`, this id is authoritative: it must resolve to an `agent_…` record
in the cached Meibo projection, and that record must be `active` before the agent can create
new trigger, drain, or sink effects. A present but unknown id never falls back to the name.
When `identity` is absent, the declaration's `name` joins by case-normalized Meibo handle for
compatibility. `shikigami agents list` shows the join and lifecycle; `shikigami agents sync`
persists load state and fills or verifies the same principal id on existing sink grants.

Explicit `directory.mode=disabled` preserves compatibility: the declared id is carried for
session attribution but is not directory-verified, and the operator inventory labels the
lifecycle `DISABLED` rather than implying `active`. The broader migration of name-keyed durable
state remains in [plan 54](../plans/54-key-durable-agent-state-by-meibo-principal.md).

## Memory policy

The default preserves the behavior of manifests written before memory policy was declared:

```dhall
, memory =
    { scope = A.MemoryScope.AgentScope
    , recallLimit = 10
    , recordPolicy = A.RecordPolicy.OnSuccess
    }
```

`recallLimit` is enforced on vector recall and its scope-only fallback. It must be between 1
and 1000 inclusive; invalid values fail declaration loading before they can become an `Int`
or a database query bound. `recordPolicy` controls automatic run memories:

- `OnSuccess` records the behavior output only after a successful run.
- `Never` records no automatic run memory, while the successful session still completes.
- `Always` behaves like `OnSuccess` on success and records a `failure`-tagged memory before a
  failed session closes.

An explicit `remember` operation inside a Flow is intentional and is not suppressed by
`recordPolicy`. `AgentScope` is the currently enforced scope. `Shared` is accepted and
inspectable so manifests can adopt the coordinated schema, but its shared-recall semantics
belong to [plan 34](../plans/34-memory-lifecycle-distillation-retention-and-shared-scope.md)
and are not active yet.

## Enable or park an agent

Set `enabled = False` to keep a manifest on disk while excluding it from workers,
schedulers, and stream/event consumers. Each loader prints a stderr line naming the skipped
agent and manifest. Single-agent commands still load disabled declarations deliberately, so
you can validate or hand-run a parked agent; `validate` calls out its disabled state.

## Specialist expertise and router policy

`expertise` describes what a specialist knows. It is metadata for candidate selection; it does
not grant tools, sinks, or permission to launch the specialist:

```dhall
, expertise =
    [ { key = "opentelemetry"
      , description = "OpenTelemetry signals, propagation, and SDK architecture"
      , aliases = [ "otel", "telemetry" ]
      , evidenceHints = [ "traceparent", "service.name" ]
      }
    ]
```

Keys are trimmed and case-folded for uniqueness. Empty keys and duplicates such as
`OpenTelemetry` plus `opentelemetry` are declaration errors.

A router opts in with `routing`, but its candidates still come only from the existing
`delegates` allow-list:

```dhall
, delegates = [ "opentelemetry-practice-reviewer", "code-researcher" ]
, routing =
    Some
      { maxSelections = 2
      , minimumConfidence = A.RouterConfidence.RoutingMedium
      , onNoMatch = A.NoMatchPolicy.ReturnNoMatch
      , onAmbiguous = A.AmbiguousPolicy.ReturnAmbiguous
      }
```

`maxSelections` must be between 1 and 16 inclusive and cannot exceed the number of distinct
delegates. A routing policy with no delegates and duplicate delegate names are rejected.
`minimumConfidence` is a semantic threshold, while `onNoMatch` and `onAmbiguous` make the two
non-selection outcomes explicit. None of these values authorizes a child by itself: durable
delegation still enforces the allow-list, lineage, depth, and root-run budget at the spawn
boundary.

The checked-in architecture-practice router and OpenTelemetry specialist are a complete example of
this split. The router owns candidate selection and delegation; the specialist owns pinned
evidence, review memory, Kawa history, and conditional attention. See
[Architecture-practice reviews](./architecture-practice-reviews.md) for its trigger and operator
contract.

## The three axes

The schema deliberately keeps three concerns independent. Any combination is valid:

```text
behavior  ×  trigger  ×  sinks
( what )     ( when )    ( produces )
```

- A **deterministic rule** on a **stream** trigger raising a **signal** → a cheap detector.
- A **shikumi program** on a **schedule** writing a **kawa digest** → a recurring summarizer.
- A **skill** on a public **event** trigger opening a **danwa conversation** → an addressed responder.
- A **skill** on an external conversation activity using **ChannelEgress** → a guarded reply through Kanmon.

You mix and match freely; the runtime dispatches on each part independently.

## A worked example

```dhall
-- agents/triage-note.dhall — a skill-agent that watches the stream and raises a signal
let A = ../schema/Agent.dhall
in  A.Agent::{
    , name = "triage-note"
    , behavior = A.Behavior.Skill { path = "agents/skills/triage-note" }
    , trigger =
        A.Trigger.Stream
          { match =
              { verb = Some "ticket.received"
              , source = None Text
              , subjectType = Some "ticket"
              , verbs = [] : List Text
              }
          }
    , sinks =
        [ A.Sink.KizashiSignal
            { source = "shinzui/shikigami"
            , signalType = A.SignalType.TaskCandidate
            , priority = A.Priority.Normal
            , importance = 45
            , recipientFrom = A.RecipientFrom.SubjectOwner
            , defaultRecipient = Some "person:nadeem"
            , intentTemplate = "triage this ticket"
            , extraContextTags = [ "verb:ticket.received", "subject:ticket" ]
            }
        ]
    }
```

This says: *when a `ticket.received` activity about a `ticket` subject arrives on the stream*
(trigger), *follow the `triage-note` skill's instructions* (behavior), *and raise a
`TaskCandidate` kizashi signal to the subject's owner* (sink).

## Where agents live

- `agents/*.dhall` — top-level declared agents the worker loads from its `--agents`
  directory.
- `agents/detectors/*.dhall` — the intelligence-layer **detectors** (see
  **[Detectors](./detectors.md)**). Drop a file in and it is loaded; there is no registry to
  edit and no migration step.
- `agents/skills/<name>/SKILL.md` — skill behaviors referenced by `Skill { path = … }` (see
  **[Skills](./skills.md)**).

## Validate as you go

Every manifest should round-trip through `validate` before you wire it into the worker:

```bash
$ cabal run shikigami -- validate agents/triage-note.dhall
```

A typed Dhall error points at the exact field that doesn't conform — the schema is your
spec. To see what a behavior actually produces without a database, use `run-behavior` (see
**[Getting Started](./getting-started.md)**).
