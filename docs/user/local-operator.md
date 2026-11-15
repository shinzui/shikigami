---
type: "Guide"
title: "Run agents on your own machine"
description: "Run a declared agent against your own repository under the local-operator trust tier, confirm its grant once, and read the action record."
docId: "DOC-21"
tags: ["local-operator", "trust", "authority", "record"]
generated:
  by: claude-code/claude-opus-5-5
  at: 2026-11-15T16:40:00Z
---

# Running agents on your own machine

Under the `local-operator` trust tier you are the authority. A declared agent runs against a
repository on your own machine, does only what you granted it, and leaves a record of every
grant and decision. No Kikan service is needed: only the local PostgreSQL that
`shikigami-agent-run` already uses and your model credential.
[ADR-124](../adr/0124-authority-is-selected-by-trust-tier-and-the-local-operator-grants-a-declaration-once.md)
records the design.

## One command, one confirmation

```bash
shikigami-agent-run --set trust.tier=local-operator \
  --set behavior.provider=openai --set behavior.model=gpt-5.4-mini \
  --agent agents/local-maintainer.dhall --workspace mori://shinzui/fsrs-hs \
  --payload '{"task":"Summarize what src/ implements and which module owns scheduling."}'
```

`--workspace` takes a checkout path or a Mori identity; without it the run uses the Git checkout
containing the current directory. The first time, the command shows what the declaration asks
for and asks once:

```text
local-operator: local-maintainer asks for
  repository   mori://shinzui/fsrs-hs (/Users/shinzui/Keikaku/bokuno/fsrs-hs)
  placement    separate worktree on a run branch
  capabilities workspace.read
  budget       30 model attempts, 120 tool attempts, 3000000 tokens, 60 minutes
Grant this declaration? [y/N] y
…
reply:
`src/` implements the FSRS spaced-repetition library. …
local-operator: repository mori://shinzui/fsrs-hs (/Users/shinzui/Keikaku/bokuno/fsrs-hs)
local-operator: record 17 approved, 0 refused — shikigami-local ledger --run 5c4414c8-…
```

The answer is stored against the digest of the declaration and the repository, so the next run
does not ask. Editing the declaration asks again. A run with no terminal (standard input or output
redirected, or `--no-confirm`) never asks; with no stored grant it refuses before calling the
model:

```text
agent-run: no stored grant for this declaration; run it once in a terminal to confirm it
```

Until local outputs exist (EP-8 M2 of MasterPlan 22), a declaration that lists a Kikan sink is
refused when it is resolved, before any model call:

```text
agent-run: the declaration lists outputs this composition cannot deliver: kizashi.signal
```

## What you granted, and what happened

```bash
shikigami-local approvals                 # the approvals file and every stored grant
shikigami-local revoke 7a43f1bf4d53       # delete a stored confirmation (8+ digest characters)
shikigami-local ledger --run <workflow-id> [--refusals] [--limit N] [--json]
```

The ledger is the action record: one `authority.granted` event per confirmation and one
`authority.decided` event per decision, refusals included, each with the run, the principal,
the action and who decided.

## The explicit approvals file

Instead of confirming in a terminal you may write the grant. An entry for an agent and a
repository replaces the confirmation for that pair, and it is the only place a `workspace.exec`
command rule is approved.

```dhall
-- ~/.config/shikigami/local-operator.dhall
let L = /path/to/shikigami/schema/LocalOperator.dhall

in  L.Approvals::{
    , repositories = [ L.Repository::{ identity = "mori://shinzui/fsrs-hs" } ]
    , agents =
      [ L.AgentApproval::{
        , agent = "local-maintainer"
        , repository = "mori://shinzui/fsrs-hs"
        , capabilities = [ "workspace.read" ]
        , budget = Some L.Budget::{ minutes = 30 }
        }
      ]
    }
```

A repository's `source` defaults to `mori path <identity>` and must be the top level of a Git
checkout. `placement` is `SeparateWorktree` (the default) or `InPlace`. A missing file is an
empty set of approvals.

## Settings

| Key | Default | Meaning |
|-----|---------|---------|
| `trust.tier` (`SHIKIGAMI_TRUST_TIER`) | `contained` | `local-operator`, `contained` or `multi-tenant`. |
| `trust.local_operator.approvals_file` | `$XDG_CONFIG_HOME/shikigami/local-operator.dhall` | The explicit approvals file. |
| `trust.local_operator.state_dir` | `$XDG_STATE_HOME/shikigami` | Stored grants (and, later, worktrees and locks). |

`shikigami-worker` refuses `local-operator`; use the two light commands.
