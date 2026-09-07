---
type: "Guide"
title: "Detectors — the intelligence layer as declared agents"
description: "Create detector agents using the shipped catalog and suppression rules."
docId: "DOC-11"
tags: ["detectors", "agents"]
generated:
  by: process:shikigami-user-docs-okf-migration
  at: 2026-09-07T14:41:30Z
---

# Detectors — the intelligence layer as declared agents

A **detector** is just a [declared agent](./writing-agents.md) whose whole job is to *watch
the unified activity stream and raise a signal when a pattern matters*. The "intelligence
layer" of the platform is exactly a small **set of detectors declared as agents** on the
shikigami runtime — there is no separate intelligence service and no hardcoded registry that
later migrates. Detectors are the runtime's first declarations.

They live in [`agents/detectors/`](../../agents/detectors/). Drop a `.dhall` file there and the
runtime loads it — **no Haskell, no migration, no registry to edit.**

## The shipped catalog

| File | Trigger | Behavior | Sink |
| --- | --- | --- | --- |
| [`stalled-intention.dhall`](../../agents/detectors/stalled-intention.dhall) | `activity.v1` where `subject.type = intention` | `Deterministic` rule (N days, no action) | `KizashiSignal` (Reminder) |
| [`at-risk-customer.dhall`](../../agents/detectors/at-risk-customer.dhall) | `activity.v1` where `subject.type = ticket` | `ShikumiProgram` (LLM, opt-in) | `KizashiSignal` (Alert) |

- **`stalled-intention`** — the cheap, deterministic case: "an `intention` was declared but
  has had no `action.recorded` for N days (default 7)." It is `rei`'s `OnIntentionStalled`
  reactor lifted out of rei's bounded context and run portfolio-wide over the whole river — as
  a declared agent, not rei-internal code. It observes rei's work *as `activity.v1`
  activities*, never by reading rei's database.
- **`at-risk-customer`** — the LLM-backed case: a judgment over unstructured ticket text. It
  prefers upstream enrichment facts (`payload.enrichment.*`) and falls back to classifying
  `payload.text` with a shikumi program via handan. It is **opt-in** behind an environment
  variable (default off), so the deterministic path needs no credentials and CI stays
  hermetic.

## Anatomy of a detector

A detector uses the same three axes as any agent — it's a recognizable *shape*, not a special
type:

- **Trigger** — the **Stream** class: an `activity.v1` pattern. Because the stream is
  **subject-keyed**, all activity about one subject arrives in order on one partition, so a
  detector can reason over a consistent per-subject window.
- **Behavior** — `Deterministic` (a rule, no model), `ShikumiProgram` (a typed judgment),
  or `Skill`. Not everything needs a model.
- **Sink** — typically `KizashiSignal` (raise awareness). A detector concerning a specific
  intention can instead use the `ReiAction` bridge.

See [`stalled-intention.dhall`](../../agents/detectors/stalled-intention.dhall) for a fully
commented example.

## Suppression — don't spam the inbox

A still-true condition (a stalled intention stays stalled) would raise a new signal on every
evaluation. Before raising, the runtime checks a suppression table keyed on
`(detector, subject, window-key)`:

```sql
CREATE TABLE IF NOT EXISTS shikigami_fired (
  detector     TEXT        NOT NULL,
  subject_type TEXT        NOT NULL,
  subject_id   TEXT        NOT NULL,
  window_key   TEXT        NOT NULL,
  signal_id    TEXT        NOT NULL,
  fired_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (detector, subject_type, subject_id, window_key)
);
```

The flow: compute the finding; if it already fired for this window-key → **skip the signal**;
otherwise raise it and record the firing (`INSERT … ON CONFLICT DO NOTHING`). The **window-key**
defines "the same condition" — for `stalled-intention` it's the declaration's `occurred_at`
truncated to the day, so the same staleness *episode* dedups, but a *new* declaration (after
the first resolved) gets a new key and may legitimately fire again. This sits on top of the
keiro inbox's delivery-level dedup.

## Add a detector (recipe)

1. **Author** `<name>.dhall` in `agents/detectors/`, a value in the C5
   `{ name, behavior, trigger, sinks }` schema. Copy `stalled-intention.dhall` (deterministic)
   or `at-risk-customer.dhall` (LLM) as a starting point.
2. **Validate** it: `cabal run shikigami -- validate agents/detectors/<name>.dhall`.
3. **Point the stream consumer at the directory** so the runtime loads and matches it:
   `cabal run shikigami-consume-stream -- --agents agents/detectors`.

There is no hardcoded registry and no migration step: a detector *is* a declared agent.

> See the in-tree [`agents/detectors/README.md`](../../agents/detectors/README.md) for the
> deeper design notes (per-subject windowing, the signal-field derivation table, the rei
> boundary). Note that file predates the final CLI and references an `agents` subcommand that
> does not exist — use `validate` / `consume-stream` / `worker` as shown here and in the
> **[CLI Reference](./cli.md)**.
