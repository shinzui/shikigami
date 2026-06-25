# Writing Agents

An agent is a value in the typed Dhall schema at [`schema/Agent.dhall`](../../schema/Agent.dhall).
Every manifest imports that schema and produces one `Agent` record with four meaningful
parts:

```dhall
let A = ../schema/Agent.dhall
in  A.Agent::{
    , name = "my-agent"                 -- a human label (required)
    , description = "what it does"       -- optional, defaults to ""
    , trigger  = A.Trigger.Schedule { cron = "* * * * *" }   -- WHEN it runs
    , behavior = A.Behavior.ShikumiProgram { … }             -- WHAT it does
    , sinks    = [ A.Sink.KawaDigest { … } ]                 -- WHAT it produces
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
          }
      , default = { description = "", sinks = [] : List Sink }
      }
```

| Field | Type | Meaning | Default |
| --- | --- | --- | --- |
| `name` | `Text` | Human label; also resolves `agents/<name>.dhall` for the CLI | — (required) |
| `description` | `Text` | Free-text summary | `""` |
| `trigger` | `Trigger` | When the agent fires — see **[Triggers](./triggers.md)** | — (required) |
| `behavior` | `Behavior` | What the agent does — see **[Behaviors](./behaviors.md)** | — (required) |
| `sinks` | `List Sink` | What the agent produces — see **[Sinks](./sinks.md)** | `[]` |

Because `sinks` defaults to `[]`, an agent with no sinks is legal — it runs its behavior and
records a session, producing nothing outward. That's useful for a behavior whose only job is
to learn (record memory) for later runs.

## The three axes

The schema deliberately keeps three concerns independent. Any combination is valid:

```text
behavior  ×  trigger  ×  sinks
( what )     ( when )    ( produces )
```

- A **deterministic rule** on a **stream** trigger raising a **signal** → a cheap detector.
- A **shikumi program** on a **schedule** writing a **kawa digest** → a recurring summarizer.
- A **skill** on an **event** trigger opening a **danwa conversation** → an addressed responder.

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

```console
$ cabal run shikigami -- validate agents/triage-note.dhall
```

A typed Dhall error points at the exact field that doesn't conform — the schema is your
spec. To see what a behavior actually produces without a database, use `run-behavior` (see
**[Getting Started](./getting-started.md)**).
