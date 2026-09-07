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
the runtime drives through `mori://shinzui/baikai`, instead of a typed program. It follows the open
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
  references/      -- optional supporting docs (not automatically loaded)
  assets/          -- optional templates / data
```

At minimum a skill is a folder with a `SKILL.md`. For portable skill authoring,
match the folder name to the `name` field. Shikigami's current loader only requires
the presence of `name` and `description`; it does not enforce the full specification.

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

| Field | Current Shikigami handling |
| --- | --- |
| `name` | Required flat frontmatter key; length, spelling, and directory-name match are not validated. |
| `description` | Required flat frontmatter key; supplied as the system prompt. |
| `license`, `compatibility`, `metadata` | Not interpreted. |
| `allowed-tools` | Ignored by the current parser; does not restrict or grant tools. |

The loader splits flat `key: value` lines rather than parsing full YAML. Use plain
single-line values for the required fields. Nested metadata and YAML multiline
scalars are not supported by this loader.

### The body

The Markdown body supplies the model instructions. Supporting files may be useful
when authoring a skill, but this runtime does not automatically read `references/`
or `assets/` on demand. Any file access needs an installed and authorized tool.

## How the runtime runs a skill

When a skill-agent fires, the runtime:

1. Loads `SKILL.md` from the declared directory.
2. Builds a `baikai` context whose system prompt / messages carry the skill's instructions
   and the trigger payload and recalled memories.
3. Advertises the tools in the runtime-supplied registry. Agent capability
   admission and per-action authorization govern overlay tools; the skill's
   ignored `allowed-tools` field is not an enforcement boundary.
4. Runs a completion. If the model requests tools, it runs a **tool-use loop** — dispatch the
   calls, fold the results back, complete again — bounded by the runtime
   turn limit (eight by default).
5. Hands the final completion to the agent's sinks, exactly as a program's output.

The default **stub provider** needs no model key. Setting `behavior.provider=anthropic`
and supplying its credential enables real model calls. Tool-using Skills additionally
need installed tools and action authorization. The one-off workspace limitation is
documented in the [CLI reference](./cli.md).

> **Sandbox note.** Instructions are supplied to the model; tools come from the runtime registry. Executing a skill's
> `scripts/` (arbitrary executable code) needs a sandbox and is a **deferred** concern — this
> runtime does not execute `scripts/`.

## Instructions vs. grounding

A skill's *instructions* (the how-to in `SKILL.md`) are deliberately **distinct from OKF
grounding** (the *knowledge* an agent loads to understand what things mean). Don't put concept
definitions in a skill body when they belong in reusable knowledge. The schema has
a `ShikumiProgram.grounding` field, but the current dispatcher does not resolve it. The three input axes for any agent are:
**behavior** (program or skill) × **grounding** (knowledge) × the **trigger/sink** wiring.

## Validate a skill

`validate` checks that the skill-agent's `SKILL.md` can be loaded and contains
`name` and `description` fields. It does not validate name/directory matching or
the full Agent Skills specification:

```bash
$ cabal run shikigami -- validate agents/triage-note.dhall
AgentDecl {name = "triage-note", behavior = Skill {path = "agents/skills/triage-note"}, ...}
OK: 1 agent parsed (skill agents/skills/triage-note valid).
```
