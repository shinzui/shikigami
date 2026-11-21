---
type: "Guide"
title: "Writing Agents"
description: "Declare agent identity, behavior, triggers, outputs, tools, memory policy, and routing in Dhall."
docId: "DOC-3"
tags: ["agents", "dhall"]
generated:
  by: process:shikigami-user-docs-okf-migration
  at: 2026-09-07T14:41:30Z
---

# Writing Agents

An agent is a value in the typed Dhall schema at [`schema/Agent.dhall`](../../schema/Agent.dhall).
A manifest produces one `Agent.Type` record. Only `name` and `behavior` are
required. Record completion (`A.Agent::{ … }`) supplies the defaults. This
example assumes the file lives directly under `agents/`.

```dhall
let A = ../schema/Agent.dhall
in  A.Agent::{
    , name = "summary"
    , behavior = A.Behavior.ShikumiProgram
        { task = "noop-summary", preferEnrichment = False, grounding = None Text }
    }
```

The declaration can run on demand. Its result goes to the destination chosen by
the composition. For a short Skill or coding-agent declaration, the
[routine prelude](../../schema/Routine.dhall) supplies helpers.

## The schema at a glance

| Field | Type | Meaning | Default |
| --- | --- | --- | --- |
| `name` | `Text` | Human label; also resolves `agents/<name>.dhall` for the CLI | — (required) |
| `description` | `Text` | Free-text summary | `""` |
| `trigger` | `Trigger` | When the agent fires — see **[Triggers](./triggers.md)** | `Manual` |
| `behavior` | `Behavior` | What the agent does — see **[Behaviors](./behaviors.md)** | — (required) |
| `outputs` | `List Output` | Registered kinds and their JSON configurations. [Outputs](outputs.md) describes composition defaults. | `[]` |
| `tools` | `List Tool` | [Declared CLI commands or MCP tools](declared-tools.md) | `[]` |
| `delegates` | `List Text` | Exact allow-list of child agents this declaration may launch | `[]` |
| `delegationBudget` | `Optional Natural` | Optional root-run-wide child budget | platform default |
| `sanctionedProfile` | `Optional ProfileRequirement` | Execution profile the run must resolve and satisfy | `None` |
| `capabilityOverlays` | `List Text` | Additive model-tool capabilities requested by this agent | `[]` |
| `execution` | `Optional Execution` | Default and permitted immutable whole-assignment model aliases | `None` |
| `harness` | `Optional Harness.Type` | Narrow operator Skill policy ceilings and restrictions | `None` |
| `decisionModels` | `List Text` | Operator model aliases this agent permits typed Flow decisions to use | `[]` |
| `identity` | `Optional Identity` | Principal reference for directory admission. Required when requesting local tools or overlays | `None` |
| `memory` | `MemoryPolicy` | Recall scope, recall bound, and automatic recording policy | agent scope, 10 results, record on success |
| `enabled` | `Bool` | Whether long-running worker roles load the agent | `True` |
| `expertise` | `List Expertise` | Routing metadata describing a specialist's knowledge | `[]` |
| `routing` | `Optional RouterPolicy` | Bounded semantic-selection policy over `delegates` | `None` |

To migrate a declaration with a `sinks` field, replace that field with `outputs`.
For Kikan service destinations, import the [binding helpers](../../packs/kikan-shikigami-binding/dhall/Outputs.dhall).
For example, `K.kawaDigest { subjectType = "heartbeat", verb = "heartbeat.tick" }`
produces one output entry. The [Kikan outputs reference](sinks.md) covers the five
kinds and the authority required to deliver each.

## Identity

Local runs authorize the declaration for a repository and retain a name-keyed compatibility identity. Declare an `identity` when requesting tools or capability overlays. For a Kikan deployment using a directory, name the agent’s stable Meibo principal:

```dhall
, identity = Some { principal = "agent_01h000000000000000heartbeat" }
```

With `directory.mode=file`, this id is authoritative: it must resolve to an `agent_…` record
in the cached Meibo projection, and that record must be `active` before the agent can create
new trigger, drain, or sink effects. A present but unknown id never falls back to the name.
When `identity` is absent, the declaration's `name` joins by case-normalized Meibo handle for
compatibility. `shikigami agents list` shows the join and lifecycle; `shikigami agents sync`
persists load state and fills or verifies the same principal id on existing sink grants.

Explicit `directory.mode=disabled` admits work under a name-derived compatibility
identity, rather than treating a declared id as verified. The operator inventory labels the
lifecycle `DISABLED` rather than implying `active`. Admitted durable jobs record a
verified principal or an explicit compatibility identity. Sessions, memory scopes,
and workflow identity use that recorded identity, so verified agents retain
continuity across renames. `shikigami agents sync --alias LEGACY_NAME=agent_...` associates
legacy name-scoped memory with a verified principal without rewriting old rows;
see the [operator CLI](../operations/operator-cli.md).

## Decision model aliases

A Flow using typed decisions declares a finite alias allow-list:

```dhall
, decisionModels = [ "triage", "investigate" ]
```

These names refer to the operator's `behavior.decisionModels` catalog. They do
not contain model IDs or credentials and cannot grant a model absent from that
catalog. The Flow's declared slots and any sanctioned profile further restrict
selection. Empty defaults preserve manifests that do not use decisions. See
[Typed decisions in Flows](typed-decisions.md) for a runnable example.

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

The schema keeps three concerns independent, but execution also requires a supported
behavior and any necessary grants and action authorization:

```text
behavior  ×  trigger  ×  outputs
( what )     ( when )    ( produces )
```

- A **registered program** on a **stream** trigger raising a **signal** → a detector.
- A **shikumi program** on a **schedule** writing a **kawa digest** → a recurring summarizer.
- A **skill** on a public **event** trigger opening a **danwa conversation** → an addressed responder.
- A **skill** on an external conversation activity using **ChannelEgress** → a guarded reply through Kanmon.

A `Flow` needs durable execution; `shikigami-run-behavior` supports only
registered programs and Skills. See [Behaviors](./behaviors.md).

## A worked example

```dhall
let A = ../schema/Agent.dhall

let K = ../packs/kikan-shikigami-binding/dhall/Outputs.dhall
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
    , outputs =
        [ K.kizashiSignal K.KizashiSignal::
            { source = "shinzui/shikigami"
            , signalType = K.SignalType.TaskCandidate
            , priority = K.Priority.Normal
            , importance = 45
            , recipientFrom = K.RecipientFrom.SubjectOwner
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
- A **detector** is an agent on a stream trigger (see **[Detectors](./detectors.md)**).
  Directory loading is not recursive; a new Flow ships in a [flow pack](./flows.md#flow-packs).
- `agents/skills/<name>/SKILL.md` — skill behaviors referenced by `Skill { path = … }` (see
  **[Skills](./skills.md)**).

## Validate as you go

Every manifest should round-trip through `validate` before you wire it into the worker:

```bash
$ cabal run kikan-shikigami:exe:kikan-shikigami -- validate agents/triage-note.dhall
```

A typed Dhall error points at the exact field that doesn't conform — the schema is your
spec. To see what a behavior actually produces without a database, use `run-behavior` (see
**[Getting Started](./getting-started.md)**).

## Assignment execution and harness policy

`execution = Some { defaultAlias = "worker", permittedAliases = [ "worker" ] }`
selects aliases from the operator's `behavior.decisionModels` catalog for a whole
assignment. Admission intersects declaration permissions, delegation restrictions,
operator entries and any sanctioned profile. The accepted binding retains exact
provider/model/options and catalog revision; changing defaults does not retarget
pending work. A missing retained binding refuses rather than falling back.
`decisionModels` remains the separate allow-list for typed Flow decision slots.

The optional `harness` record narrows model turns, output repair, safe recovery,
context, permission lifetime and summary ceilings, and adds denied/human tools.
See [execution policies](../operations/durable-execution.md) for a complete Dhall
example, ranges and output requirements. Neither field grants tools or external
authority. [CoordinatingSkill](behaviors.md#coordinatingskill--admitted-worker-control)
additionally requires a trusted admitted coordination scope.
