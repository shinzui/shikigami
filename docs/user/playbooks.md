---
type: "Guide"
title: "Playbooks"
description: "Declare a multi-step, multi-repository procedure in Dhall, check it, and run it durably with coding agents, declared tools and approvals."
docId: "DOC-25"
tags: ["playbook", "coding-agent", "approval", "local-operator"]
generated:
  by: claude-code/claude-opus-5-5
  at: 2026-11-15T23:40:00Z
---

# Playbooks

A playbook is a procedure written in Dhall: coding-agent steps, declared-tool steps and
approvals, repeated for each item of a list and composed from smaller playbooks. It runs as
one durable agent run under the `local-operator` tier ([local operator](local-operator.md)):
a restarted run continues where it stopped and never repeats a step that finished.

## A bundle

A bundle names its main playbook and holds its siblings (`schema/Playbook.dhall`):

```dhall
let P = ../../schema/Playbook.dhall

in  { main = "two-repo-review"
    , playbooks =
      [ { name = "two-repo-review"
        , steps =
          [ P.Step.ForEach
              { id = "each-repository"
              , items = P.Items.FromPayload "repositories"
              , item = "repository"
              , playbook = "review-one"
              }
          ]
        }
      , { name = "review-one"
        , steps =
          [ P.Step.CodingAgent
              { id = "improve"
              , prompt = "This worktree is {{repository}}. Fix one instance of: {{run.focus}}."
              , workspace = "{{repository}}"
              , deadlineMinutes = 20
              , skills = [] : List Text
              }
          , P.approval "continue" "Continue after reviewing the change in {{repository}}?"
          ]
        }
      ]
    }
    : P.Bundle
```

The steps are:

* `CodingAgent` — a coding agent works in `workspace` (a `mori://` identity or a checkout
  path; empty means the run's repository) and its change is committed on the run branch.
  `skills` lists skill directories, relative to the bundle, attached to the agent.
* `Tool` — a declared CLI tool of the declaration, run as a durable step in the run's
  worktree ([declared tools](declared-tools.md)). Each argument is a template rendered into
  exactly one word, and a word that renders empty is left out, so an optional flag can be an
  item field; the declared patterns decide whether the call runs.
* `Probe` — a declared tool whose exit code is its answer (for example `mori status --json`,
  which exits 1 for a stale schema): any exit is recorded and quoted through
  `{{steps.ID.output}}` with the exit code, and the run continues.
* `Approval` — the run waits for you in the local approval inbox.
* `Reflect` — a read-only coding agent looks at the work in `workspace` and answers with up
  to three learnings and an optional suggestion for the bundle (see below).
* `ForEach` — run a sibling playbook once per item, binding the item to the variable named by
  `item`. Items run one at a time and come from a literal list (`Literal`), a string array of
  the run's payload (`FromPayload`), or an earlier step's JSON output (`FromStep`).
* `RunPlaybook` — run a sibling playbook once.

Text fields are templates: `{{run.NAME}}` reads a top-level string of the payload,
`{{NAME}}` a variable bound by an enclosing `ForEach`, `{{steps.ID.summary}}` and
`{{steps.ID.output}}` an earlier step of the same playbook (a tool's standard output or a
coding agent's final message, at most 128 KiB, observed like step-sourced items), and
`{{learnings}}` the learnings so far. The first step that does not succeed (a failed coding agent, a declared tool that does
not exit 0, a declined approval) ends the run.

## Fanning out over a step's output

`FromStep { step, at, key }` reads the JSON output of an earlier step of the same playbook: a
tool's standard output, or the last line of a coding agent's final message that is a JSON
object. `at` is a JSON pointer to an array (empty for the whole output). An array of strings
gives one item per string; an array of objects takes each item's key from its `key` field and
binds each string field `f` as `{{ITEM.f}}`. More than 200 items, duplicate keys and a value
that is not an array end the run.

```dhall
[ P.Step.Tool
    { id = "packages"
    , tool = "mori"
    , args = [ "registry", "show", "{{run.project}}", "--full", "--json" ]
    , deadlineMinutes = 1
    }
, P.Step.ForEach
    { id = "each-package"
    , items = P.Items.FromStep { step = "packages", at = "/packages", key = "name" }
    , item = "package"
    , playbook = "locate"
    }
]
```

Values from step output are observed: they may appear in prompts and as tool arguments, but a
`workspace` may never name one, so a repository always comes from the bundle or the payload.
`playbook validate` refuses a workspace that does.

## Learnings and suggestions

A run recalls the playbook's learnings from earlier runs when it starts, and each `Reflect`
step adds its own; later prompts quote them through `{{learnings}}` as observed evidence, not
instructions. The run keeps its new learnings for later runs when it ends, as one memory headed
`Learnings of playbook NAME` (the bundle's main playbook) and tagged `playbook` and `NAME`; the
next run recalls up to ten lines by that header. Learnings are shared by runs of the same
declaration, whichever repository they work in.

The run's output says why a stopped run stopped: `stoppedBy` is `environment` when the stopping
step could not be attempted on this machine (a helper that would not start, a Baikai ceiling
refusal, a prompt over the 64 KiB limit, a declared tool refused or unstartable) and `work`
otherwise. A run stopped by its environment records no learning of its own, so a setup failure is
not recalled by later runs as a lesson about the repository.

`agents/playbooks/build-repair.dhall` checks this end to end in a few minutes. Run it twice on a
small Cabal package whose build is broken: the first run repairs the build, reports failing
tests without stopping, waits for the close approval and reflects. The second run's
`fix-build` prompt then quotes the first run's learnings.

When a `Reflect` step suggests a change to the playbook, the run ends with one coding agent in
the Git repository that holds the bundle, on that run's branch. The change is kept only when it
touches nothing but the bundle file; the report names the commit and the
`shikigami-local playbook validate` check to run on the branch. Nothing changes the current run
or your checkout: you review the branch and merge it with Git, and later runs pin whatever the
file holds when they start.

Check a bundle before running it:

```bash
shikigami-local playbook validate agents/playbooks/two-repo-review.dhall
```

It prints the step tree, or refuses an unknown sibling, a cycle, a duplicate step id or a
template that names no parameter or item, naming the step that is wrong.

## The declaration

A `Playbook` behavior names the bundle (relative to the declaration) and the coding agent its
steps use:

```dhall
A.Agent::{
, name = "two-repo-review"
, behavior =
    A.Behavior.Playbook
      { bundle = "two-repo-review.dhall"
      , provider = A.CodingAgentProvider.ClaudeCode
      , access = A.WorkspaceAccess.EditWorkspace
      , model = None Text
      , effort = None A.CodingAgentEffort
      }
}
```

Declared tools for `Tool` steps go in the declaration's `tools`, as for any agent.

## Running one

```bash
shikigami-agent-run --set trust.tier=local-operator \
  --agent agents/playbooks/two-repo-review-agent.dhall --workspace mori://shinzui/fsrs-hs \
  --payload '{"repositories":["mori://shinzui/fsrs-hs","mori://shinzui/mina"],"focus":"an exported function without a Haddock comment"}'
```

You confirm the declaration for the run's repository; a step in another repository asks once
for that repository too, and the grant is kept. To confirm before the run, and to choose where
each repository is worked, run `shikigami-local grant <declaration> --in <repository>
--placement in-place|separate-worktree` once per repository in a terminal. The run can then start
with `--no-confirm`, or from a pane whose output is piped. The bundle is loaded, checked and pinned when
the run starts, so editing the file affects only later runs.

Before the first step the run checks this machine: the vendor CLI, `shikigami-agent-launch`,
`shikigami-local` and the Baikai ceiling. It refuses to start when one is missing and names the
fix; `shikigami-local doctor --agent <declaration> --workspace <repository>` runs the same checks
and also says whether the declaration is granted there.

When the run reaches an approval it stops and prints what to do:

```text
Run <WORKFLOW_ID> waits for approval:
  shikigami-local approvals resolve <REVIEW-ID>    # Continue after reviewing the change in mori://shinzui/fsrs-hs?
then: shikigami-agent-run --agent <the same declaration> --resume <WORKFLOW_ID>
```

The ask waits a day for you (`trust.local_operator.approval_deadline_seconds`).
`shikigami-local approvals pending` lists the waiting asks. After you answer, `--resume`
continues the run; steps that finished are read from its journal and not run again. The
report lists every step with its outcome, and `shikigami-local ledger --run <WORKFLOW_ID>`
shows each decision.
