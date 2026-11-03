---
type: "Reference"
title: "Behaviors — what an agent does"
description: "Compare deterministic, ShikumiProgram, Skill, CoordinatingSkill, and Flow behavior declarations."
docId: "DOC-5"
tags: ["behaviors"]
generated:
  by: process:shikigami-user-docs-okf-migration
  at: 2026-09-07T14:41:30Z
---

# Behaviors — *what* an agent does

A behavior is the work an agent performs when its trigger fires. Its declaration
has five arms:

```dhall
let Behavior =
      < Deterministic :
          { rule : Text, params : List { mapKey : Text, mapValue : Text } }
      | ShikumiProgram :
          { task : Text, preferEnrichment : Bool
          , grounding : Optional Text, enabledBy : Optional Text }
      | Skill : { path : Text }
      | CoordinatingSkill : { path : Text }
      | Flow : { name : Text }
      >
```

| Arm | Runs via | Needs a model key? | Use for |
| --- | --- | --- | --- |
| **Deterministic** | schema only; runner returns `UnsupportedBehavior` | — | reserved rule declaration |
| **ShikumiProgram** | `mori://shinzui/handan` + `mori://shinzui/shikumi` | Only when the program calls a model | typed, structured, evaluable pipelines |
| **Skill** | `mori://shinzui/baikai` | Only when the skill calls a model | "follow these instructions, maybe call these tools" |
| **CoordinatingSkill** | admitted durable execution | When the selected provider requires one | instructions controlling a bounded set of continuing workers |
| **Flow** | `mori://shinzui/keiro` durable workflow | Only if the flow body calls a model | lifecycle-backed work that can park, resume, and escalate |

Supported behaviors return JSON to the shared session, memory, and sink lifecycle.
Flows execute through the durable agent workflow, while the synchronous runner
supports registered programs and Skills.

## Deterministic — a named rule

```dhall
behavior =
  A.Behavior.Deterministic
    { rule = "stalled-intention"
    , params = toMap { staleAfterDays = "7" }
    }
```

The schema accepts this arm, but `Shikigami.Behavior.Run.runBehavior` returns
`UnsupportedBehavior "Deterministic"`. The worker uses that same runner for this
arm. A valid manifest therefore does not imply an executable rule. Implement
rule logic as a registered program or compiled Flow until this arm has a runner.

## ShikumiProgram — the typed path

```dhall
behavior =
  A.Behavior.ShikumiProgram
    { task = "noop-summary"      -- a registered handan/shikumi task
    , preferEnrichment = False   -- schema metadata; task must implement this
    , grounding = None Text      -- schema metadata; task must implement this
    , enabledBy = None Text      -- schema metadata; not an enforced gate
    }
```

Names a typed task in the program registry, run through `mori://shinzui/handan` over a
`mori://shinzui/shikumi` `Program`. This is the path for **structured, typed, evaluable** work —
schemas, validation, ensembles, an eval harness. Fields:

- `task` selects a compiled entry in `Shikigami.Program.Registry`. Its current
  entries are `noop-summary`, `web-researcher`, and `code-researcher`, all deterministic
  proof programs. The durable agent workflow additionally handles the
  `research-supervisor` delegation program; the synchronous runner cannot run it.
- `preferEnrichment`, `grounding`, and `enabledBy` are accepted declaration fields
  but are not consulted by the current dispatcher. In particular, `enabledBy`
  does not provide an environment-variable execution gate. Use `enabled = False`
  to exclude an agent from long-running loaders.

The runner supplies trigger payload and recalled memory through the task argument
map. New tasks must implement any enrichment or grounding behavior themselves.

## Skill — the lightweight path

```dhall
behavior = A.Behavior.Skill { path = "agents/skills/triage-note" }
```

Points at a **skill directory** following the [Agent Skills specification](https://agentskills.io/specification):
a folder with a `SKILL.md` (YAML frontmatter + Markdown instructions), run directly through
`mori://shinzui/baikai`. This is the lightweight path for the many agents that are "follow these
instructions, maybe call these tools" rather than a typed pipeline.

The runtime loads the skill's `SKILL.md`, builds a `baikai` context from its instructions,
and advertises the runtime-supplied tool registry. The current loader ignores
`allowed-tools`; it neither installs nor restricts tools. Overlay admission and
per-action authorization govern the tools supplied to a run. A completion can enter a bounded
tool-use loop when actual tools are available. A **stub provider** satisfies CI, so a skill-agent runs without a
model key — exactly as `noop-summary` does. See **[Skills](./skills.md)** for authoring one.

> **Sandbox note.** The skill's instructions run through the model; tools come from the runtime registry. Executing a skill's
> `scripts/` (arbitrary executable code) needs a sandbox and is **not** run by this runtime —
> a deferred concern.

## CoordinatingSkill — admitted worker control

```dhall
behavior = A.Behavior.CoordinatingSkill { path = "agents/skills/coordinator" }
```

This arm uses the durable Skill harness and requires an operator-admitted
coordination scope before any model call. The scope fixes the parent, root,
delegation limits, permitted models and finite worker slots. The dedicated
`workers` tool shares the governed command owner with Flows and operator commands.
Instructions and `delegates` request capabilities; they do not grant control.

An ordinary `Skill` with delegates continues to use the existing fixed supervisor.
`CoordinatingSkill` cannot run through `shikigami-run-behavior`, conversation
fallback, or a routed declaration. Objective-backed coordination requires
enabled tracking and retained admitted associations. Repository transfer also
requires the configured process-backed workspace supervisor; file-only settings
provide no process fence. See [worker operations](../operations/operator-cli.md)
for configuration, command semantics and provider requirements.

## Flow — the durable lifecycle path

```dhall
behavior = A.Behavior.Flow { name = "at-risk-customer" }
```

Names a compiled Haskell flow in the flow registry. A Flow runs inside the agent-run
workflow, so it can journal internal steps, emit replay-safe sink intents, park for an
acknowledgement, resume after an answer or deadline, and render its lifecycle as Mermaid.

Flows can also invoke typed Shikumi decisions with separately admitted model
aliases, journal full validated results, and retain every actual provider attempt.
The registered `shikumi-decision-example` Flow demonstrates triage followed by
investigation and optional governed specialist delegation. See
[Typed decisions in Flows](typed-decisions.md) for configuration and replay limits.

Use this path when the behavior is not just "compute one JSON value" but a durable process.
The `at-risk-customer` flow classifies a ticket, raises an alert for high risk, waits for
acknowledgement, and escalates on timeout. See **[Flows](./flows.md)**.

## Running without a key

The synchronous arms are provable with deterministic stubs:

```bash
$ cabal run shikigami-run-behavior -- --agent agents/heartbeat.dhall
{"summary":"..."}
```

`run-behavior` runs only the behavior (no DB, no sinks) and prints its JSON output — the
quickest way to iterate on what an agent produces.

## Choosing an arm

| If the work is… | Use |
| --- | --- |
| a clear rule over structured fields | a registered `ShikumiProgram` |
| a typed pipeline you want to evaluate/optimize | `ShikumiProgram` |
| natural-language instructions, optionally with tools | `Skill` |
| instructions controlling admitted continuing workers | `CoordinatingSkill` after provider qualification |
| a durable process that must wait or resume | `Flow` |
| typed decisions that branch into governed actions and survive restart | `Flow` with the `Decision` capability |
