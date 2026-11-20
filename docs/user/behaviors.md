---
type: "Reference"
title: "Behaviors — what an agent does"
description: "Compare deterministic, ShikumiProgram, Skill, CoordinatingSkill, CodingAgent, and Flow behavior declarations."
docId: "DOC-5"
timestamp: "2026-11-15T12:00:00Z"
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
      < ShikumiProgram :
          { task : Text, preferEnrichment : Bool, grounding : Optional Text }
      | Skill : { path : Text }
      | CoordinatingSkill : { path : Text }
      | Flow : { name : Text }
      | CodingAgent :
          { provider : CodingAgentProvider, prompt : Text
          , access : WorkspaceAccess, model : Optional Text
          , effort : Optional CodingAgentEffort
          , deadlineMinutes : Natural, skills : List Text }
      >
```

| Arm | Runs via | Needs a model key? | Use for |
| --- | --- | --- | --- |
| **ShikumiProgram** | `mori://shinzui/shikumi` | Only when the program calls a model | typed, structured, evaluable pipelines |
| **Skill** | `mori://shinzui/baikai` | Only when the skill calls a model | "follow these instructions, maybe call these tools" |
| **CoordinatingSkill** | admitted durable execution | When the selected provider requires one | instructions controlling a bounded set of continuing workers |
| **Flow** | `mori://shinzui/keiro` durable workflow | Only if the flow body calls a model | lifecycle-backed work that can park, resume, and escalate |
| **CodingAgent** | Claude Code or Codex through `mori://shinzui/baikai`, as a durable child workflow | The vendor CLI's own login | "change this repository and commit the result", under the local-operator tier |

Supported behaviors return JSON to the shared session, memory, and sink lifecycle.
Flows execute through the durable agent workflow, while the synchronous runner
supports registered programs and Skills.

## ShikumiProgram — the typed path

```dhall
behavior =
  A.Behavior.ShikumiProgram
    { task = "noop-summary"      -- a registered Shikumi task
    , preferEnrichment = False   -- schema metadata; task must implement this
    , grounding = None Text      -- schema metadata; task must implement this
    }
```

Names a typed task in the program registry, run by Shikigami's local execution adapter over a
`mori://shinzui/shikumi` `Program`. This is the path for **structured, typed, evaluable** work —
schemas, validation, ensembles, an eval harness. Fields:

- `task` selects a compiled entry in `Shikigami.Program.Registry`. Its current
  entries are `noop-summary`, `web-researcher`, and `code-researcher`, all deterministic
  proof programs. The durable agent workflow additionally handles the
  `research-supervisor` delegation program; the synchronous runner cannot run it.
- `preferEnrichment` and `grounding` are accepted declaration fields but are not
  consulted by the current dispatcher. Use `enabled = False` to exclude an agent
  from long-running loaders.

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

## CodingAgent — a vendor coding agent as a durable step

```dhall
behavior = A.Behavior.CodingAgent
  { provider = A.CodingAgentProvider.ClaudeCode
  , prompt = "Find one exported function in src/ without a Haddock comment and add an accurate one."
  , access = A.WorkspaceAccess.EditWorkspace
  , model = None Text
  , effort = None A.CodingAgentEffort
  , deadlineMinutes = 20
  , skills = [] : List Text
  }
```

A `CodingAgent` behavior runs Claude Code (`ClaudeCode`) or Codex (`Codex`) on the run's
repository through Baikai's unattended agent command. It works in the run's own worktree
and branch, and when it completes Shikigami commits its changes there with the trailers
`Shikigami-Run` and `Shikigami-Agent`. The step is a durable child workflow: its launch,
its attempt and its settlement are journaled, so `shikigami runs show <id>` prints the
outcome, the commit, the changed files and the evidence summary.

* `access` is Baikai's capability: `ReadOnly`, `EditWorkspace` (edit inside the
  worktree) or `FullAccess`.
* `model` is a vendor model id; `None` means the vendor default. `effort` is one of
  `EffortLow`, `EffortMedium`, `EffortHigh`, `EffortXHigh` or `EffortMax`; `None` leaves
  it to the vendor.
* `deadlineMinutes` (1–720) is enforced by Baikai, which ends the agent and reports
  `timed_out`. The prompt is at most 256 KiB.
* `skills` lists skill directories next to the declaration. Each is copied for the
  attempt, and its `SKILL.md` is given to the agent with the prompt.

The outcome is one of `completed` (with the exit code, commit and changes), `failed`
(the launch was refused or did not run), `timed_out` (partial changes are left
uncommitted) or `uncertain`. A run ends `uncertain` when the launcher was lost without a
result after a restart; Shikigami never launches a second agent on the same worktree, so
an operator inspects the worktree and the attempt directory instead. If the command running
the step is interrupted, `shikigami-agent-run --resume <WORKFLOW_ID>` continues it and
reattaches to the agent if it is still running.

Coding agents run only under the `local-operator` trust tier, as the operator's own
`claude` or `codex` would ([local operator](local-operator.md)). The first run asks to
confirm the declaration, naming the provider and its workspace access; every launch is
recorded as a `launch_coding_agent` decision in `shikigami record list`. Under the
`contained` and `multi-tenant` tiers the step is refused before any process starts.

```bash
shikigami-agent-run --set trust.tier=local-operator \
  --agent agents/coding-agent-example.dhall --workspace mori://shinzui/mina
```

`run-behavior` does not run a `CodingAgent`; it needs a durable agent run.

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

Other registered Flows include [finite adaptive delivery](adaptive-delivery.md),
[unrequested-work proposals](unrequested-work.md), and the
[active-work watchdog](watchdog.md). Each requires its own configured admission,
identity and allowance; naming a Flow does not grant those prerequisites.

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
| a change to a repository made by Claude Code or Codex | `CodingAgent` under `local-operator` |
| a durable process that must wait or resume | `Flow` |
| typed decisions that branch into governed actions and survive restart | `Flow` with the `Decision` capability |
