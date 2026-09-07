---
type: "Guide"
title: "Skills — authoring a SKILL.md behavior"
description: "Author and validate a skill directory for a Shikigami Skill behavior."
docId: "DOC-8"
tags: ["skills", "behaviors"]
generated:
  by: process:shikigami-user-docs-okf-migration
  at: 2026-09-07T14:41:30Z
---

# Skills — authoring a `SKILL.md` behavior

A **skill** is the lightweight behavior arm: a directory of instructions (and optional tools)
the runtime drives through `shinzui/baikai`, instead of a typed program. It follows the open
[Agent Skills specification](https://agentskills.io/specification), so skills are *reused, not
invented* — the same format the portfolio already uses.

An agent points at a skill by directory path:

```dhall
behavior = A.Behavior.Skill { path = "agents/skills/triage-note" }
```

## Anatomy of a skill directory

```text
agents/skills/triage-note/
  SKILL.md         -- REQUIRED: YAML frontmatter + Markdown instructions
  scripts/         -- optional executable code (NOT run by this runtime — see below)
  references/      -- optional docs loaded on demand
  assets/          -- optional templates / data
```

At minimum a skill is a folder with a `SKILL.md`. The folder name **must** match the skill's
`name` frontmatter field.

## The `SKILL.md` file

```markdown
---
name: triage-note
description: Read a support ticket and draft a one-line triage note for the owner.
---

# Triage Note

Read the ticket text in the trigger payload and produce a concise triage note.
```

### Frontmatter fields

| Field | Required | Notes |
| --- | --- | --- |
| `name` | ✅ | 1–64 chars, lowercase alphanumeric + hyphens, no leading/trailing/consecutive hyphens; **must match the directory name** |
| `description` | ✅ | 1–1024 chars; says *what* the skill does **and** *when* to use it; keyword-rich |
| `license` | | optional |
| `compatibility` | | optional, ≤500 chars; environment requirements |
| `metadata` | | optional string→string map |
| `allowed-tools` | | optional, space-separated pre-approved tools, e.g. `Bash(git:*) Read` (experimental) |

### The body

Markdown with no format restrictions. Keep it under ~500 lines / <5000 tokens and push detail
into `references/`. **Progressive disclosure** governs loading: the metadata (~100 tokens) is
known up front, the full body loads on activation, and `scripts/`/`references/`/`assets/` load
only as needed.

## How the runtime runs a skill

When a skill-agent fires, the runtime:

1. Loads `SKILL.md` from the declared directory.
2. Builds a `baikai` context whose system prompt / messages carry the skill's instructions
   (plus any `references/`/`assets/` pulled in as the run needs them).
3. Maps the skill's `allowed-tools` to `baikai` tool definitions.
4. Runs a completion. If the model requests tools, it runs a **tool-use loop** — dispatch the
   calls, fold the results back, complete again — until the model stops requesting tools.
5. Hands the final completion to the agent's sinks, exactly as a program's output.

A **stub `baikai` provider** satisfies CI, so a skill-agent runs **without a model key**.

> **Sandbox note.** A skill's *instructions* and `allowed-tools` run. Executing a skill's
> `scripts/` (arbitrary executable code) needs a sandbox and is a **deferred** concern — this
> runtime does not execute `scripts/`.

## Instructions vs. grounding

A skill's *instructions* (the how-to in `SKILL.md`) are deliberately **distinct from OKF
grounding** (the *knowledge* an agent loads to understand what things mean). Don't put concept
definitions in a skill body; that is grounding, configured separately on the
`ShikumiProgram` behavior's `grounding` field. The three input axes for any agent are:
**behavior** (program or skill) × **grounding** (knowledge) × the **trigger/sink** wiring.

## Validate a skill

`validate` checks a skill-agent's directory and `SKILL.md` frontmatter (a required `name`
matching the directory, and a required `description`):

```bash
$ cabal run shikigami -- validate agents/triage-note.dhall
AgentDecl {name = "triage-note", behavior = Skill {path = "agents/skills/triage-note"}, ...}
OK: 1 agent parsed (skill agents/skills/triage-note valid).
```
