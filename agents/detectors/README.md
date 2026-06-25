# Detectors — the intelligence layer as declared agents

> **Re-pointed at the canonical schema (2026-06-24, EP-6 M1).** These seed detectors
> now import the runtime's canonical C5 schema at `../../schema/Agent.dhall` (EP-1)
> instead of the local placeholder `./schema.dhall` (now retired). The change was a
> mechanical rename — `Observe`→`Stream { match }`, `Program { program }`→
> `ShikumiProgram { task }`, `RaiseSignal`→`KizashiSignal`, singular `sink`→
> `sinks = [ … ]` — exactly as MasterPlan IP-2 promised; both files validate through
> `shikigami validate` unchanged.

A **detector** is a [declared agent](../) whose whole job is to *watch the unified
activity stream and raise a signal when a pattern matters*. The intelligence layer
is exactly a small **set of detectors declared as agents** on the shikigami
runtime — there is no separate "intelligence service" and no hardcoded registry
that later migrates. The detectors are the runtime's **first declarations from day
one** (contract C5: "detectors are the first declarations — no
hardcoded-then-migrate step").

This directory is the **detector catalog**: drop a `.dhall` file here and the
runtime loads it.

This work is authored by **EP-5**
(`kikan/docs/plans/12-the-intelligence-layer-continuous-observation-to-signals.md`).
The runtime that loads and runs these declarations is **EP-6** (the shikigami
runtime; its design lives in this repo's `docs/initial-spec.md`). The cross-cutting
contracts (C1–C12) live in `kikan/docs/architecture/evolution/contracts.md`.

## The catalog

| file | trigger | behavior | sink |
| --- | --- | --- | --- |
| [`stalled-intention.dhall`](./stalled-intention.dhall) | `activity.v1[subject.type=intention]` | deterministic rule (N days, no action) | `kizashi:Reminder` |
| [`at-risk-customer.dhall`](./at-risk-customer.dhall) | `activity.v1[subject.type=ticket]` | shikumi/handan program (LLM) `[opt-in]` | `kizashi:Alert` |

- **`stalled-intention`** — the cheap, deterministic case. "An `intention` was
  declared but has had no `action.recorded` for N days (default 7)." This is
  `shinzui/rei`'s `OnIntentionStalled` reactor pattern lifted out of rei's single
  bounded context and run portfolio-wide over the whole river, expressed as a
  declared agent rather than rei-internal code. It observes rei's agent work *as
  `activity.v1` activities* (rei publishes `rei.v1` integration events that `kawa`
  normalizes) — never by reading rei's database (C5, "Interaction with rei/Ren").
- **`at-risk-customer`** — the LLM-backed case. A judgment over unstructured
  ticket text; prefers EP-4's enrichment facts (`payload.enrichment.sentiment` /
  `…risks`, C7) and falls back to classifying `payload.text` with a `shinzui/shikumi`
  program run via `shinzui/handan`. Opt-in behind `TOMOSHIBI_ENABLE_LLM_DETECTORS`
  (default off) so the deterministic path needs no credentials and CI stays
  hermetic.

## The schema (C5)

Each detector is a value in the agent-definition schema —
`{ name, behavior, trigger, sink }` (contract **C5**):

- `name` — a human label.
- `trigger` — one of C3's three trigger classes. Detectors use the **Observe**
  class: an `activity.v1` stream pattern over `shinzui/kawa`'s published,
  **subject-keyed** integration-event topic, consumed via a `shinzui/keiro` inbox.
  This is the one contract topic — never the raw per-service topics, and never a
  direct `shinzui/kiroku` subscription against `kawa`'s store ("an interim
  prototype only, never a contract", C3).
- `behavior` — a **union** (C5): a **`Deterministic`** rule (cheap, no model), a
  **`Program`** (a typed `shikumi` Program run via `handan`, optionally OKF-grounded
  per C10), or a **`Skill`** (an Agent Skills directory run through `baikai`). Not
  everything needs a typed program.
- `sink` — one or more output actions. These detectors use only the
  **`RaiseSignal`** sink (a `shinzui/kizashi` signal, C4). The `RecordReiAction`
  sink (the rei bridge) is declared for future intention-driving detectors.

The canonical schema is **owned by the runtime (EP-6)**. Until it publishes its
concrete Dhall type, the declarations here annotate against the local seed
[`schema.dhall`](./schema.dhall); once the runtime publishes its schema, replace
the `let Schema = ./schema.dhall` import with an import of the runtime's schema and
the declarations re-run unchanged.

## Recipe — add a detector (no Haskell, no migration)

1. **Author** a new `<name>.dhall` in this directory, a value in the C5
   `{ name, behavior, trigger, sink }` schema. Copy
   [`stalled-intention.dhall`](./stalled-intention.dhall) (deterministic) or
   [`at-risk-customer.dhall`](./at-risk-customer.dhall) (LLM) as a starting point.
2. **Drop it** in `agents/detectors/`.
3. The runtime **loads it on next start** — `shikigami agents list --dir
   agents/detectors` shows it and `shikigami agents run <name>` evaluates it.

There is **no hardcoded registry to edit and no migration step**: a detector *is*
a declared agent.

## The signal sink (C4)

A detector's finding maps to a `kizashi` `CreateSignalReq`
(`kizashi-api/src/Kizashi/Api/Signal.hs`) exactly per `awareness.md`:

- `source` = `"shinzui/shikigami"` (this runtime's `mori` identity — required by
  C4's change rule).
- `actor` = the audit string `"<source>:<actor.id>"` of who *caused* the
  triggering activity (origin, **not** the recipient).
- `recipient` = the routing target the detector chooses (the subject owner for
  `stalled-intention`; the area owner for `at-risk-customer`), falling back to a
  configured default.
- `signalType` / `priority` / `importance` follow the awareness derivation table:
  a reminder/at-risk verb → `Reminder` / `Normal` / `40–69`; an LLM high-risk
  verdict → `Alert` / `High`–`Urgent` / `70–89`.
- `contextTags` **always** include `"activity://<activity_id>"` (the C4
  back-reference linking the awareness end to the memory end), plus the detector's
  extra tags (`verb:…`, `subject:…`).

## Per-subject sliding window

Because `activity.v1` is **subject-keyed** (C3), all activity about one subject is
delivered in order on one partition — so a per-subject window is consistent. The
runtime maintains, per detector evaluation:

- A `SubjectKey = (subject.type, subject.id)` index over recent activities.
- `recordActivity` appends an envelope under its `SubjectKey` and **trims** each
  subject's list to the most recent **N (default 50)** and a **time horizon
  (default 30 days)**.
- A detector reasons over *only that subject's* recent history (e.g.
  `stalled-intention` sees the latest `intention.declared` and any later
  `action.recorded` for that intention).

The window is in-memory in this slice; a `shinzui/kiroku`-backed durable rebuild is
forward work (recorded in EP-5's Decision Log, not built here). Cross-subject
ordering is not guaranteed; sort within a subject by `occurred_at` / `activity_id`.

## Suppression — `(detector, subject, window)` de-duplication

A still-true condition (e.g. a stalled intention) stays true on every evaluation;
without suppression a detector would raise a new signal on every tick and spam the
inbox. So before raising, the runtime checks a suppression table keyed on
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

Evaluation flow: compute the `Finding`; if `alreadyFired` (a `SELECT` on the
primary key) → **skip the POST**; else `raiseSignal` → on success `recordFired`
(an `INSERT … ON CONFLICT DO NOTHING` storing the returned `signal_id`). The
pre-check plus `ON CONFLICT DO NOTHING` makes a concurrent double-fire raise at
most one signal even under a redelivery/timer race — on top of the keiro inbox's
delivery-level dedup (C3).

The **window-key** defines "the same condition." For `stalled-intention` it is the
declaration's `occurred_at` truncated to the day, so the same staleness *episode*
dedups, but a *new* declaration (after the first was resolved) gets a new key and
may legitimately fire again.

## Where the detector LOGIC lives

The `.dhall` files here are **declarations**. The evaluation **logic** — the
deterministic stalled-intention rule, the `at-risk-customer` shikumi
signature (`Signature TicketInput RiskVerdict`, modeled on handan's
`SmokeInput`/`SmokeOutput` in `handan-core/src/Handan/Task.hs`) and its
`Handan.Task.decisionTask` wrapping, the per-subject windowing, and the suppression
gate — is preserved as DESIGN in the shikigami **initial-spec** ("Worked agents"
section) and summarized above. Any genuinely new shikumi/handan capability the
LLM detector needs is tracked as an improvement-request in EP-5's recast plan, not
authored here.
