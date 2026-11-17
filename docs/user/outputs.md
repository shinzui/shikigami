---
type: "Guide"
title: "Where a run's result goes"
description: "Declare a run's outputs, rely on the composition's default (a local report under the local operator), require an approval before delivery, and resolve it from the local inbox."
docId: "DOC-23"
tags: ["outputs", "approval", "local-operator", "triggers"]
generated:
  by: claude-code/claude-opus-5-5
  at: 2026-11-15T21:50:00Z
---

# Where a run's result goes

A declaration can say where its result goes with `outputs`, a list of registered output kinds
and their JSON configuration. A declaration that lists none receives the composition's
default output; under the `local-operator` tier that is a Markdown report. The choice is
journaled when the run delivers, so a run keeps its destination across a restart. The
smallest declaration needs no trigger and no outputs:

```dhall
let A = ../schema/Agent.dhall

in  A.Agent::{
    , name = "plain-note"
    , behavior = A.Behavior.Skill { path = "agents/skills/plain-note" }
    }
```

Its trigger defaults to `Manual`: it runs only when you ask, with `shikigami-agent-run` or
`shikigami enqueue-run`, and the scheduler and consumers skip it.

## Outputs

`local.report` writes `<state_dir>/reports/<agent>/<run-id>-<n>.md` (or `.json`), privately
(mode 0600) and at most 1 MiB. Name it explicitly with the helper:

```dhall
let Local = ../schema/outputs/Local.dhall

in  A.Agent::{ …, outputs = [ Local.report Local.Format.Json ] }
```

A declaration naming a kind this composition does not register is refused before the run,
with the kinds that are registered. Every delivery is decided as `emit_output` by the run's
authority and appears in `shikigami-local ledger`; the local operator's authority allows
`local.*` outputs, which only write on your machine. Each delivered output also appends an
`output.delivered` record entry naming the exact action that was allowed.

`kawa.digest` publishes the result to the Kawa doorway as one activity envelope, with the
configuration `{"subjectKind": …, "verb": …}`. A `shikigami-worker` registers it, and gives it
to a declaration with no outputs when `outputs.default` is `kawa.digest` (the default is `none`:
the result stays in the journal). The other Kikan sinks (`sinks`) keep their own path until
they move to output adapters.

## One declaration, two compositions

A declaration that names only kernel vocabulary runs unchanged under the stock local-operator
composition and under a Kikan composition. `agents/proof/portable-note.dhall` is that check: it
has a principal, a Skill and nothing else, so it reports to `local.report` in the first and to
`kawa.digest` in the second. `shikigami record check --run <id>` reads each run's record and
reports which kernel invariants it shows broken. A capability overlay is not kernel vocabulary:
`workspace.read` exists only in the light commands, and a worker refuses a declaration that asks
for it.

## Approving before delivery

`approval.require_outputs` lists output kinds whose delivery waits for you:

```bash
shikigami-agent-run --set trust.tier=local-operator --set approval.require_outputs=local.report \
  --agent agents/plain-note.dhall --payload '{"topic":"durable execution journals"}'
```

The run stops at the ask and prints what to do:

```text
Run 41854ae1-… waits for approval:
  shikigami-local approvals resolve review_9f4f…    # Deliver the local.report output of agent plain-note?
then: shikigami-agent-run --agent <the same declaration> --resume 41854ae1-…
```

Under the local operator the ask is a file in `<state_dir>/approvals/` (mode 0600), the only
place that holds its token. `shikigami-local approvals pending` lists open asks;
`shikigami-local approvals resolve <REVIEW-ID>` approves (add `--reject REASON` to reject),
then `--resume` delivers the output, or skips it when rejected.
