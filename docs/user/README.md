---
type: "Navigation"
title: "Shikigami — User Guide"
description: "Find the right guide for declaring, running, and operating Shikigami agents."
docId: "DOC-1"
timestamp: "2026-11-06T18:18:06Z"
tags: ["navigation", "agents"]
generated:
  by: process:shikigami-user-docs-okf-migration
  at: 2026-09-07T14:41:30Z
---

# Shikigami — User Guide

Shikigami runs agents declared in Dhall. For a routine task in your own checkout,
start with a Skill. For a repository change, declare a Claude Code or Codex
worker. A [playbook](playbooks.md) can combine those changes with commands,
human approvals and work across several repositories. Use a [Flow pack](flows.md#flow-packs)
when the procedure needs a Haskell implementation.

## Your first local run

After [setting up the database](getting-started.md), run these commands from the
Shikigami checkout inside the dev shell. Edit the generated `SKILL.md` to
describe the report you want before running the second command.

```sh
cabal run shikigami-local -- new repo-digest
cabal run shikigami-local -- run repo-digest "summarize this checkout"
cabal run shikigami-local -- runs
```

The local operator confirms the declaration for the selected repository.
The run records its decisions and writes its result to a local report. The scaffold requests `workspace.read`. To produce a real summary, configure a
[model provider](local-operator.md#one-command-one-confirmation). The
[routine-agent guide](routine-agents.md) covers tool declarations and local scheduling. To try the loader and a deterministic behavior before setting
up PostgreSQL, use [Getting Started](getting-started.md).

## Choose a guide

| I want to… | Start here |
| --- | --- |
| Write a declaration or understand its defaults | [Writing agents](writing-agents.md), [behaviors](behaviors.md), [triggers](triggers.md), [outputs](outputs.md) |
| Let an agent use my checkout or commands | [Local operator](local-operator.md), [declared CLI and MCP tools](declared-tools.md), [authoring Skills](skills.md) |
| Automate a multi-repository procedure | [Playbooks](playbooks.md) and the [modernization campaign](../../agents/campaigns/keiro-modernization/keiro-modernization.dhall) |
| Extend an executable with compiled behavior | [Flow packs](flows.md#flow-packs), [typed decisions](typed-decisions.md), [package architecture](../architecture/packages.md) |
| Run a Kikan integration | [Kikan outputs and grants](sinks.md), [stream detectors](detectors.md), [living-loop walkthrough](living-loop.md) |
| Operate or inspect runs | [CLI reference](cli.md), [HTTP API](http-api.md), [configuration](../operations/configuration.md), [memory and sessions](memory.md) |
| Track longer work | [Objectives](objectives.md), [external trackers](objective-trackers.md), [adaptive delivery](adaptive-delivery.md) |
| Use the organizational packs | [Practice reviews](architecture-practice-reviews.md), [watchdog](watchdog.md), [unrequested work](unrequested-work.md) |

## Which executable runs my declaration?

Stock commands supply the kernel behaviors. `shikigami-local run` selects the
local-operator tier and defaults to a Markdown report. The Kikan distribution
adds service adapters and organizational Flows. Its worker can deliver a Kawa
digest for the same declaration. A declaration that explicitly requests a
Kikan output or Flow needs an executable composed with its pack. Use
`shikigami flows` or `kikan-shikigami flows` to inspect the composition.

Durable coding-agent launches and declared CLI/MCP tools currently require
local-operator authority. The deployed Kikan binding also needs a new action
to authorize coding-agent launches. The [portability example](outputs.md#one-declaration-two-compositions)
shows the common subset, and the [invariant audit](../architecture/kernel-invariants.md)
records what was checked under each composition.

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
policy. Configured durable workers have authoritative objective/checkpoint providers
and governed mutable workspaces with process fencing. Continuing sessions retain
follow-ups and recover governed handoffs. See [durable objectives](objectives.md),
[workspace operations](../operations/workspaces.md) and
[finite adaptive delivery](adaptive-delivery.md).

The native adaptive repository and recovery fixture passes; its actual-model trial
still requires production authorization and approved live limits. Recurring supervision requires an explicit [mandate](../operations/recurring-objectives.md). The independently scheduled [watchdog](watchdog.md) provides
advisory observation, and [unrequested work](unrequested-work.md) requires its own
observer allowance and acceptance or standing policy.
