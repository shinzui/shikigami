# Behaviors — *what* an agent does

A behavior is the work an agent performs when its trigger fires. It is a **union** of three
arms — not everything needs a typed program or a model call:

```dhall
let Behavior =
      < Deterministic :
          { rule : Text, params : List { mapKey : Text, mapValue : Text } }
      | ShikumiProgram :
          { task : Text, preferEnrichment : Bool
          , grounding : Optional Text, enabledBy : Optional Text }
      | Skill : { path : Text }
      >
```

| Arm | Runs via | Needs a model key? | Use for |
| --- | --- | --- | --- |
| **Deterministic** | a named rule, in-process | No | cheap, rule-based decisions (thresholds, staleness, counting) |
| **ShikumiProgram** | `shinzui/handan` + `shinzui/shikumi` | Only when the program calls a model | typed, structured, evaluable pipelines |
| **Skill** | `shinzui/baikai` | Only when the skill calls a model | "follow these instructions, maybe call these tools" |

Whatever the arm, its output is a JSON value handed to the agent's **sinks** identically — the
downstream wiring (sinks, sessions, memory) is shared across all three.

## Deterministic — a named rule

```dhall
behavior =
  A.Behavior.Deterministic
    { rule = "stalled-intention"
    , params = toMap { staleAfterDays = "7" }
    }
```

The cheapest arm: a named rule evaluated in-process with no model and no credentials. `rule`
names the logic; `params` is a string→string map of configuration (here, the staleness
threshold in days). This is the workhorse for detectors whose condition is a clear rule —
"declared but no action for N days," "count exceeded threshold," "field missing."

Because it needs no key, the Deterministic path always runs in CI and on a fresh checkout.

## ShikumiProgram — the typed path

```dhall
behavior =
  A.Behavior.ShikumiProgram
    { task = "noop-summary"      -- a registered handan/shikumi task
    , preferEnrichment = False   -- prefer upstream enrichment facts when available
    , grounding = None Text      -- optional OKF knowledge grounding reference
    , enabledBy = None Text      -- optional env var that gates this behavior on
    }
```

Names a typed task in the program registry, run through `shinzui/handan` over a
`shinzui/shikumi` `Program`. This is the path for **structured, typed, evaluable** work —
schemas, validation, ensembles, an eval harness. Fields:

- `task` — the registered task name. The runtime ships a deterministic stub task,
  **`noop-summary`**, that returns a fixed JSON body with **no model call**, so the loop is
  provable without a provider configured. Real detectors register tasks that call a model.
- `preferEnrichment` — when `True`, prefer pre-computed enrichment facts on the activity
  payload (e.g. `payload.enrichment.sentiment`) and fall back to classifying raw text only if
  they are absent.
- `grounding` — an optional reference to OKF knowledge grounding (what concepts *mean*),
  kept deliberately distinct from a skill's instructions (how-to).
- `enabledBy` — an optional environment-variable name that must be set for the behavior to
  run. Lets an LLM-backed program ship **opt-in** (e.g. behind `TOMOSHIBI_ENABLE_LLM_DETECTORS`)
  so the default path stays credential-free and CI stays hermetic.

## Skill — the lightweight path

```dhall
behavior = A.Behavior.Skill { path = "agents/skills/triage-note" }
```

Points at a **skill directory** following the [Agent Skills specification](https://agentskills.io/specification):
a folder with a `SKILL.md` (YAML frontmatter + Markdown instructions), run directly through
`shinzui/baikai`. This is the lightweight path for the many agents that are "follow these
instructions, maybe call these tools" rather than a typed pipeline.

The runtime loads the skill's `SKILL.md`, builds a `baikai` context from its instructions,
maps its `allowed-tools` to tool definitions, and runs a completion (plus a tool-use loop if
the skill calls tools). A **stub provider** satisfies CI, so a skill-agent runs without a
model key — exactly as `noop-summary` does. See **[Skills](./skills.md)** for authoring one.

> **Sandbox note.** A skill's *instructions* and `allowed-tools` run. Executing a skill's
> `scripts/` (arbitrary executable code) needs a sandbox and is **not** run by this runtime —
> a deferred concern.

## Running without a key

All three arms are provable with deterministic stubs:

```bash
$ cabal run shikigami -- run-behavior --agent agents/heartbeat.dhall
{"summary":"..."}
```

`run-behavior` runs only the behavior (no DB, no sinks) and prints its JSON output — the
quickest way to iterate on what an agent produces.

## Choosing an arm

| If the work is… | Use |
| --- | --- |
| a clear rule over structured fields | `Deterministic` |
| a typed pipeline you want to evaluate/optimize | `ShikumiProgram` |
| natural-language instructions, optionally with tools | `Skill` |
