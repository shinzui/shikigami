---
id: 6
slug: end-to-end-living-loop-proof-and-detector-conformance
title: "End-to-End Living-Loop Proof and Detector Conformance"
kind: exec-plan
created_at: 2026-06-24T23:41:29Z
intention: "intention_01kvy04813ehbv9aghj3tn4zjx"
master_plan: "docs/masterplans/1-shikigami-declared-agent-runtime-bootstrap.md"
---

# End-to-End Living-Loop Proof and Detector Conformance

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami (式神 — "a summoned spirit-servant bound to its master's will") is a small Haskell runtime
in which an autonomous system agent is *declared*, not coded: you write a short typed Dhall file that
says "run **this behavior**, when **this trigger** fires, send the result to **these sinks**," and a
thin worker runs it forever. By the time this plan starts, the whole runtime has already been built
by the five preceding ExecPlans of this MasterPlan (`docs/masterplans/1-shikigami-declared-agent-runtime-bootstrap.md`):
the four-package project and the canonical agent schema (`docs/plans/1-scaffold-agent-schema-loader-and-validate-cli.md`),
the behavior runner with kioku memory (`docs/plans/2-behavior-runner-and-kioku-session-and-memory-integration.md`),
the sink dispatcher with the kawa stub (`docs/plans/3-sink-dispatcher-permission-gate-and-kawa-stub.md`),
the trigger evaluators and the `activity.v1` stream consumer (`docs/plans/4-trigger-evaluators-and-the-activity-v1-stream-consumer.md`),
and the supervised worker that orchestrates them all (`docs/plans/5-the-supervised-worker-and-run-orchestration.md`).

This plan delivers the **conformance and de-risking proof** — the moment where the assembled runtime
is driven end to end and shown to actually work, not merely to compile. After this plan, someone with
a fresh checkout in the nix dev shell can:

- Run `shikigami validate agents/detectors/stalled-intention.dhall` (and `at-risk-customer.dhall`)
  and see the two **seed detector declarations** parse cleanly — proving the runtime's canonical
  schema (`schema/Agent.dhall`) can express the intelligence layer's detectors as declared agents
  (this is contract **C5**'s named acceptance test: *"re-express the intelligence layer's detectors as
  declared agents"*). Today those two files import a local placeholder schema
  (`agents/detectors/schema.dhall`); this plan re-points them at the real `schema/Agent.dhall`.

- Run a single proof harness (a `tasty` test executable plus a small set of CLI invocations against
  a local Postgres + Redpanda broker) and watch **the living loop close**: a declared agent loads
  from Dhall, fires on all three trigger classes (a cron schedule, a matching `activity.v1` stream
  envelope, and an addressed inbox delivery), runs its behavior through *both* arms of the behavior
  union (a deterministic `noop-summary` shikumi program *and* a `triage-note` skill driven by a stub
  baikai provider), dispatches its sinks (a `KawaDigest` to the kawa stub, a `KizashiSignal` to a
  kizashi stub), records the run as a **kioku session** and the output as a **kioku memory** — and
  then the kawa stub **re-publishes** the produced digest envelope onto the fixture `activity.v1`
  topic, where a **second declared agent fires on it**. The system feeds itself.

- See three guard rails proven: the **feedback guard** (an envelope whose `actor.kind` is `"agent"`
  fires nothing, so agents do not loop on their own output), the **permission proof** (a revoked
  grant causes the sink to be skipped, logged, and recorded as a denial while the run still
  completes), and the **memory proof** (a second run of the same agent recalls the first run's
  learning from kioku rather than starting blank).

- See shikigami's maturity recorded as a `shinzui/mori` capability record (its project lifecycle
  advances from `Experimental`/spec to `Active`), and see the three cross-project improvement-requests
  (IR-1 mori `Agent` action, IR-2 shomei scoped tokens, IR-3 kanmon egress) **filed** against their
  owning repos as design artifacts (named, not implemented).

The user-visible payoff is the manifesto's promise made concrete: routine coordination that used to
need a department of status meetings now runs itself as a handful of declared agents, and you can
*watch it run*.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1 — Confirm EP-1's canonical `schema/Agent.dhall` exists and can express both seed detectors
      (a deterministic-rule behavior, an `activity.v1` observe trigger with `subjectType`/`verbs`, and
      a kizashi-signal sink with recipient routing). If a field is missing, record the gap and amend
      EP-1's deliverable (per IP-2) rather than redesigning here.
- [ ] M1 — Re-point `agents/detectors/stalled-intention.dhall` from `let Schema = ./schema.dhall` to
      an import of `../../schema/Agent.dhall`; adapt singular `sink` to `sinks = [ … ]`; align
      `Observe`→`Stream`, `Deterministic`→canonical behavior variant, `RaiseSignal`→`KizashiSignal`.
- [ ] M1 — Re-point `agents/detectors/at-risk-customer.dhall` the same way (its behavior uses the
      program arm).
- [ ] M1 — Delete or retire the placeholder `agents/detectors/schema.dhall` and update
      `agents/detectors/README.md` to say the re-point happened.
- [ ] M1 — `shikigami validate agents/detectors/stalled-intention.dhall` prints the parsed declaration
      and exits 0; same for `at-risk-customer.dhall`. Both load through `Shikigami.Agent.Loader`
      unchanged.
- [ ] M2 — Author the `triage-note` skill directory (`agents/skills/triage-note/SKILL.md`) and the
      proof agents under `agents/proof/` (`noop-heartbeat.dhall`, `triage-note.dhall`,
      `digest-watcher.dhall`, `addressed-echo.dhall`).
- [ ] M2 — Author the fixture envelopes under `proof/fixtures/` (a `ticket.received` human envelope,
      an `actor.kind="agent"` envelope for the feedback guard).
- [ ] M2 — Write the proof harness `shikigami-cli/test/Proof/LivingLoopSpec.hs` (or
      `shikigami-core/test/...`) and wire it into the test suite; it brings up Postgres + Redpanda via
      `process-compose.yaml`, runs the worker, and asserts each leg of the loop.
- [ ] M2 — Prove trigger class 1a (schedule): the cron agent fires and records a kioku session.
- [ ] M2 — Prove trigger class 1b (stream): a fixture `activity.v1` envelope matches and fires.
- [ ] M2 — Prove trigger class 2/3 (addressed): an inbox delivery fires.
- [ ] M2 — Prove behavior arm 1 (shikumi `noop-summary`) and arm 2 (`triage-note` skill via stub
      baikai provider) both run.
- [ ] M2 — Prove both sinks dispatch: `KawaDigest` reaches the kawa stub; `KizashiSignal` reaches the
      kizashi stub.
- [ ] M2 — Prove the kioku session row and the kioku memory row are recorded.
- [ ] M2 — Prove the living loop: the kawa stub re-publishes the digest onto `activity.v1` and a
      second agent fires.
- [ ] M2 — Prove the feedback guard: an `actor.kind="agent"` envelope fires nothing.
- [ ] M2 — Prove the permission denial: a revoked grant skips the sink and records the denial.
- [ ] M2 — Prove memory persistence: a second run recalls run 1's learning.
- [ ] M3 — Author `mori.dhall` (shikigami's project manifest) with the capability record advanced to
      `Lifecycle.Active`, and `mori register` it.
- [ ] M3 — File IR-1 against `shinzui/mori` (cross-reference / shikigami-anchored note for the
      existing `add-agent-automation-action.md`).
- [ ] M3 — File IR-2 against `shinzui/shomei` (cross-reference / shikigami-anchored note for the
      existing `scoped-service-token-issuance.md`).
- [ ] M3 — File IR-3 against `shinzui/kanmon` (new `docs/improvement-requests/channel-egress-sink.md`).
- [ ] M3 — Record shikigami's own `mori/upstream-issues.dhall` entries pointing at the three filed IRs
      (the consumer-side mirror).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Treat the seed-detector re-point as a **mechanical rename, not a redesign**. The two
  files keep their identity (name, description, trigger predicates, behavior parameters, signal
  routing); only the import path and the surface syntax (`./schema.dhall` → `../../schema/Agent.dhall`,
  singular `sink` → `sinks = [ … ]`, `Observe`/`Deterministic`/`RaiseSignal` → the canonical variant
  names) change.
  Rationale: the MasterPlan's IP-2 explicitly assigns the canonical-schema design to EP-1 (built as a
  superset that the seeds' shapes fit into) and the re-point to EP-6. The seed `schema.dhall` header
  and `agents/detectors/README.md` both already say "replace this import with the runtime's schema and
  the declarations re-run unchanged." So EP-6's job is to *make that promise true*, not to invent a new
  schema. If a needed field turns out to be absent from EP-1's schema, the fix is to amend EP-1's
  deliverable (IP-2's named contract), not to fork the schema here.
  Date: 2026-06-24

- Decision: Build the living-loop proof as **one `tasty` test executable** that drives the real
  assembled worker against a real local Postgres + Redpanda (brought up by the project's existing
  `process-compose.yaml`), plus a handful of `shikigami` CLI invocations whose transcripts this plan
  pins. The proof asserts on **observable state** — kioku session rows, kioku memory rows, the kawa
  stub's request log, the kizashi stub's request log, the suppression table — not on internal Haskell
  values.
  Rationale: PLANS.md requires acceptance phrased as behavior a human can verify, and the spec's
  "Conformance & De-risking" section frames the proof as exactly this loop. A single end-to-end
  harness that uses the *real* runtime (not re-implemented stubs of it) is the only thing that proves
  the assembly works; per-component unit tests already live in EP-2/EP-3/EP-4/EP-5. The stubs that
  *are* used (kawa stub, kizashi stub, stub baikai provider, stub permission allow-list) are the ones
  the runtime itself ships per the spec, standing in for services not yet built.
  Date: 2026-06-24

- Decision: The three cross-project improvement-requests are **filed (named/authored as design
  artifacts), not implemented**. IR-1 (mori `Agent` action) and IR-2 (shomei scoped tokens) already
  exist as `docs/improvement-requests/*.md` in `shinzui/mori` and `shinzui/shomei` respectively, but
  they were authored by the *Kikan* platform initiative and cite Kikan plans. EP-6 files them "from
  shikigami's side" by (a) adding a shikigami-anchored cross-reference note to each existing artifact
  (or, if the maintainers prefer, a thin companion artifact) citing this repo's EP-6 and the contract
  numbers, and (b) recording the consumer-side mirror in shikigami's own `mori/upstream-issues.dhall`.
  IR-3 (kanmon channel egress) has no improvement-request artifact yet, so EP-6 authors a new
  `docs/improvement-requests/channel-egress-sink.md` in `shinzui/kanmon`. None of the three changes is
  *implemented* — no production code is written in mori, shomei, or kanmon.
  Rationale: the MasterPlan's "Cross-project improvement-requests" note and the spec's
  "Cross-Project Requirements" section both say these are authored into the owning repos *by other
  agents* and merely *named/listed* by the proof plan; the spec calls the changes "additive,
  net-new … authored elsewhere." EP-6's contribution is to ensure the requests exist and are traceable
  to shikigami's contracts (C5 for IR-1, C11 for IR-2, C12 for IR-3), not to land them.
  Date: 2026-06-24

- Decision: Record shikigami's maturity by writing `shinzui/shikigami`'s **`mori.dhall` project
  manifest** with `lifecycle = Schema.Lifecycle.Active` and registering it with `mori register`. The
  "capability record (spec → active)" the spec asks for *is* the project's mori lifecycle field plus
  its registration in the mori registry (there is no separate `mori capability` CLI subcommand;
  verified `mori capability --help` is invalid). The advance is from no-manifest/spec-only to a
  registered `Active` project once the build (EP-1..EP-5) lands and this proof passes.
  Rationale: the spec's C6 "capability map" is recorded *in mori*; the mori schema's `Lifecycle` enum
  is `< Active | Experimental | Deprecated | Archived >` and the project manifest carries it (verified
  against `shinzui/kioku`'s and `shinzui/kanmon`'s `mori.dhall`, which set
  `lifecycle = Schema.Lifecycle.Experimental`). Advancing shikigami's to `Active` is the registry's
  expression of "the runtime is built and proven."
  Date: 2026-06-24

- Decision: Use a dedicated proof-fixtures area (`agents/proof/*.dhall`, `agents/skills/triage-note/`,
  `proof/fixtures/*.json`) distinct from the real detector catalog (`agents/detectors/`).
  Rationale: the detectors are the *real* first declarations (their re-point is M1's conformance
  goal); the proof needs additional trivial agents (a heartbeat, a digest-watcher to close the loop,
  an addressed echo) and a skill that exist only to exercise every code path deterministically without
  a model key. Keeping them separate keeps the detector catalog honest and the proof reproducible.
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section describes the world this plan operates in as if you know nothing about it. Read it fully
before running anything.

**What shikigami is.** A runtime in which an autonomous agent is *declared* in a typed Dhall file as
four parts — `{ name, behavior, trigger, sinks }` — and a thin worker runs it. *Dhall* is a typed,
non-Turing-complete configuration language (think "JSON with types, functions, and imports"); the file
`schema/Agent.dhall` defines the agent type, and each agent manifest under `agents/` imports it. The
complete frozen design is in this repo at `docs/initial-spec.md` (read its sections "Example",
"High-Level Architecture", "Conformance & De-risking", and "Cross-Project Requirements"). Definitions
of the four parts:

- **behavior** = *what the agent does*. It is a union (a tagged choice) of two arms: a **shikumi
  Program** (a typed program run through the `shinzui/handan` library — the structured/typed path) or
  a **Skill** (a directory following the Agent Skills specification, whose `SKILL.md` instructions are
  driven through the `shinzui/baikai` LLM-completion library — the lightweight path). The proof uses a
  deterministic stub on each arm: a `noop-summary` shikumi program that returns a fixed JSON body with
  no model call, and the `triage-note` skill run through a **stub baikai provider** that returns a
  fixed completion. "Stub" here means a deterministic fake standing in for a real LLM, so the proof
  runs with no API key.
- **trigger** = *when it runs*. One of three classes (contract **C3**): a **Schedule** (a cron
  expression), a **Stream** match (a predicate over the unified `activity.v1` event stream), or an
  **Event** (an addressed delivery to the agent's inbox — an HTTP route or a shared queue message).
- **sinks** = *what it produces* (a list — agents are producers, not just reactors): a **KawaDigest**
  (writes a digest activity into the `shinzui/kawa` river), a **KizashiSignal** (raises an awareness
  signal in `shinzui/kizashi`), a **ReiAction** (hands off to `shinzui/rei`), a **DanwaConversation**
  (opens a conversation), and the channel-egress sink (acts on the outside world through
  `shinzui/kanmon`). This runtime *fully implements* KawaDigest and KizashiSignal (against stubs);
  the others are schema variants with stub handlers.
- **identity** = *under whose authority*. Each sink is gated by a permission grant (contract **C11**,
  `shinzui/shomei`). The proof uses a stub allow-list keyed by agent name; a *revoked* grant means the
  agent's name is removed from the allow-list for that sink kind.

**The activity envelope (contract C1).** Every activity on `activity.v1` is one nine-field record:
`activity_id` (a UUIDv7 string the publisher mints itself), `occurred_at` (an RFC3339 timestamp),
`source` (e.g. `"shinzui/shikigami"`), `actor` (`{ kind: "human"|"agent"|"service", id, session? }`),
`subject` (`{ type, id }`), `verb` (a past-tense dotted string like `"digest.produced"`), `payload`
(free-form JSON), `context_refs` (back-references), and `idempotency_key` (so re-delivery is a no-op).
**An agent's own output always carries `actor.kind: "agent"`** — that is precisely how the *feedback
guard* works: the stream matcher excludes `actor.kind="agent"` envelopes by default, so agents never
loop on memory they themselves produced.

**kioku (記憶, "memory").** Per the MasterPlan's headline change (its Decision Log and IP-3), the
spec's originally-planned bespoke `agent_runs` SQL table is **replaced by `shinzui/kioku`**, a
reusable event-sourced memory/session library consumed as a pinned dependency. kioku gives shikigami
a **Session** (an event-sourced record of one agent run: start / complete / fail, optional turns) and
a **Memory** (a durable, queryable learning), both scoped by a `MemoryScope`. shikigami maps each
agent run onto a kioku Session and each agent learning onto a kioku Memory scoped to that agent
(`ScopeEntity (Namespace "shikigami") (ScopeKind "agent") <agentName>`). kioku's read-model tables
live in the `kiroku` schema as `kioku_sessions`, `kioku_memories`, `kioku_turns`. This plan asserts on
those tables. **There is no `agent_runs` table.**

**What already exists when this plan starts.** By the dependency graph in the MasterPlan
(`docs/masterplans/1-shikigami-declared-agent-runtime-bootstrap.md`), EP-1 through EP-5 are Complete.
Concretely, the following are built and buildable in this repo:

- The four-package Haskell project (`shikigami-api`, `shikigami-core`, `shikigami-cli`,
  `shikigami-migrations`), scaffolded from the `shinzui/kizashi` template; `cabal build all` succeeds
  in the nix dev shell.
- `schema/Agent.dhall` — the canonical C5 schema (owned by EP-1; the superset reconciling the spec's
  illustrative shape and the seed detectors' shape).
- `shikigami-api` wire types (`Shikigami.Api.Agent`): `AgentDecl`, `Behavior`, `Trigger`,
  `StreamMatch`, `Sink`, and the nine-field `ActivityEnvelope` (`Shikigami.Api.Activity`).
- `Shikigami.Agent.Loader.loadAgent :: FilePath -> IO (Either LoadError AgentDecl)` and the
  `shikigami validate <file>` CLI.
- `Shikigami.Behavior.Run.runBehavior` (both arms) with the `noop-summary` stub program and the stub
  baikai provider; the kioku session/memory integration (`Shikigami.Memory.Scope` and the calls into
  `Kioku.Session`/`Kioku.Memory`/`Kioku.Recall`).
- `Shikigami.Sink.dispatch` (KawaDigest + KizashiSignal implemented against stubs; others stubbed),
  the C11 permission gate `Shikigami.Sink.Permission.checkGrant` (stub allow-list), and the
  `shikigami stub-kawa` server (with `--republish-topic`).
- `Shikigami.Trigger.Schedule.isDue`, `Shikigami.Trigger.Stream.matchesStream` /
  `subscribeActivityStream` (via `shinzui/kafka-effectful`, deduped through the keiro idempotent
  inbox, with the feedback guard), the addressed-event inbox, the fixture-topic plumbing, and the
  `shikigami publish-fixture <envelope.json>` CLI.
- The supervised worker (`shinzui/shibuya` `QueueProcessor` over `shinzui/pgmq-hs`), the suppression
  table `shikigami_fired`, and the `shikigami worker --agents <dir>` CLI.
- `shikigami-migrations` composing kioku's migrations plus `shikigami_fired`; `just create-database`
  lands the `kioku_*` tables + `shikigami_fired`.
- The dev substrate: `flake.nix` (GHC 9.12.4 + `GHC2024`), `process-compose.yaml` (Postgres + a
  Redpanda/Kafka broker for the fixture `activity.v1` topic), and the `Justfile`
  (`create-database`/`migrate`/`new-migration`).

> If any of the above is *not* present when you start (because a prior plan is incomplete), stop and
> finish that plan first — EP-6 hard-depends on EP-5, which hard-depends on EP-2/EP-3/EP-4, which
> hard-depend on EP-1. This plan does **not** re-implement the runtime; it drives it.

**What this plan changes.** Only conformance artifacts and proof artifacts: the two seed detector
`.dhall` files (re-pointed at the real schema), new proof agents and a skill, fixture envelopes, the
proof test harness, shikigami's `mori.dhall` (lifecycle → `Active`) and `mori/upstream-issues.dhall`,
and the three cross-project improvement-request artifacts (in the *other* repos — design only). It
does not modify the runtime's Haskell modules.

**The seed detectors as they stand today (the thing M1 re-points).** Both files currently begin with
`let Schema = ./schema.dhall` and use the placeholder schema's shape: a *singular* `sink`, a
`Behavior = < Deterministic | Program | Skill >` union, a `Trigger = < Observe | Schedule | Addressed >`
union, and a `Sink = < RaiseSignal | RecordReiAction >` union. The canonical `schema/Agent.dhall`
(EP-1) instead uses `sinks : List Sink`, `Behavior = < ShikumiProgram | Skill >` (the deterministic
case maps onto a shikumi program — a deterministic `noop`-style program — since the canonical behavior
union is the spec's two-arm shape), `Trigger = < Schedule | Stream | Event >`, and a producer
`Sink = < KawaDigest | KizashiSignal | ReiAction | DanwaConversation >`. The mechanical mapping M1
performs is therefore: `Observe { topic, subjectType, verbs }` → `Stream { match = { verb, source,
subjectType } }`; `Deterministic { rule, params }` → the canonical behavior arm EP-1 chose for a named
deterministic rule (confirm the exact variant name from EP-1's `schema/Agent.dhall`); `RaiseSignal { … }`
→ `KizashiSignal { signalType, priority }` (the richer awareness routing fields the seed carried —
`recipientFrom`, `importance`, `intentTemplate`, `extraContextTags` — are preserved if EP-1's schema
keeps them, or recorded as a gap to amend in EP-1 per IP-2 if it does not). The canonical `Stream`
match takes a single optional `verb`, while the seed `Observe` carried a *list* of `verbs`; reconcile
this with EP-1 (either the canonical `StreamMatch` already allows a verb list, or the detector splits
into one agent per verb, or — preferred per IP-2 — EP-1's schema is amended to carry `verbs : List
Text`). **Decide this against EP-1's actual `schema/Agent.dhall`, not against the illustrative spec.**


## Plan of Work

The work is three milestones, each independently verifiable. M1 is the conformance re-point (the
C5 acceptance test). M2 is the full living-loop proof harness. M3 records maturity and files the IRs.

### Milestone 1 — Detector conformance: re-point the seeds at the canonical schema

**Scope.** Turn the two seed detector declarations from files annotated against a local placeholder
schema into files that import the runtime's real `schema/Agent.dhall` and load through the runtime's
loader unchanged. This is contract **C5**'s named acceptance test ("re-express the intelligence
layer's detectors as declared agents") made literal: the detectors *are* declared agents on this
runtime once they import its schema and validate.

**What will exist at the end.** `agents/detectors/stalled-intention.dhall` and
`agents/detectors/at-risk-customer.dhall` import `../../schema/Agent.dhall`, use `sinks = [ … ]` (a
list), and use the canonical variant names; the placeholder `agents/detectors/schema.dhall` is removed
(or reduced to a re-export of the canonical schema for backward compatibility, decided below); and
`agents/detectors/README.md` is updated to state the re-point is done. `shikigami validate` succeeds
on both and prints the parsed `AgentDecl`.

**Steps, concretely.**

1. **Confirm the canonical schema's shape.** Open `schema/Agent.dhall` (EP-1's deliverable) and read
   its `Trigger`, `Behavior`, `Sink`, and `Agent` types. Confirm it can express: (a) an `activity.v1`
   observe trigger keyed by `subjectType` and a verb (or verb list); (b) a *deterministic named rule*
   behavior (the `stalled-intention` rule) and a *named shikumi program* behavior (the
   `at-risk-customer` program); (c) a kizashi-signal sink carrying at least `signalType` and
   `priority`, ideally the seed's richer routing (`recipientFrom`, `importance`, `intentTemplate`,
   `extraContextTags`). If any of these is missing, **do not** fork the schema: record the gap in the
   Decision Log and Surprises sections, amend EP-1's `schema/Agent.dhall` deliverable per IP-2
   (the MasterPlan assigns the superset design to EP-1 precisely so EP-6's re-point is mechanical),
   re-run EP-1's loader tests, then continue.

2. **Re-point `stalled-intention.dhall`.** Replace `let Schema = ./schema.dhall` with
   `let A = ../../schema/Agent.dhall`, change the trailing record from `Agent::{ … }` to the canonical
   completion form, map `trigger = Trigger.Observe { topic = "activity.v1", subjectType = Some
   "intention", verbs = [ "intention.declared", "action.recorded" ] }` to the canonical
   `trigger = A.Trigger.Stream { match = { verb = … , source = None Text, subjectType = Some
   "intention" } }` (per the verb-list reconciliation from step 1), map `behavior = Behavior.Deterministic
   { rule = "stalled-intention", params = toMap { staleAfterDays = "7" } }` to the canonical
   deterministic-behavior arm, and map the singular `sink = Sink.RaiseSignal { … }` to
   `sinks = [ A.Sink.KizashiSignal { signalType = … , priority = … } ]` (preserving the awareness
   routing fields the canonical schema retains). Keep `name`, `description`, and the inline comments.

3. **Re-point `at-risk-customer.dhall`** the same way, mapping its `Behavior.Program { program =
   "at-risk-customer", … }` to the canonical shikumi-program behavior arm and its `RaiseSignal` Alert
   sink to a `KizashiSignal` in the `sinks` list. Preserve the `enabledBy` opt-in semantics if the
   canonical schema models them; otherwise record as a gap (this detector's LLM path is opt-in behind
   a flag and stays off in CI, so the re-point must not require a model key to *validate*).

4. **Retire the placeholder schema.** Decide between (a) deleting `agents/detectors/schema.dhall`
   outright, or (b) replacing its body with `../../schema/Agent.dhall` as a one-line re-export so any
   stray importer keeps working. Prefer (a) for cleanliness unless `grep -rl 'detectors/schema.dhall'`
   over the repo finds other importers. Update `agents/detectors/README.md`'s "The schema (C5)" and
   "Recipe" sections to say the detectors now import `schema/Agent.dhall` directly.

5. **Validate.** Run `shikigami validate` on both detectors (commands and expected transcripts in
   Concrete Steps). Both must exit 0 and print the parsed `AgentDecl`.

**Acceptance.** `shikigami validate agents/detectors/stalled-intention.dhall` and
`agents/detectors/at-risk-customer.dhall` both exit 0 and print the parsed declaration; `git grep -n
'./schema.dhall' agents/detectors` returns nothing; the two detectors load through
`Shikigami.Agent.Loader.loadAgent` (asserted in the M2 harness, which loads the whole `agents/detectors`
directory).

### Milestone 2 — The living-loop proof harness

**Scope.** Build a single reproducible end-to-end proof that drives the *real* assembled worker and
asserts on observable state for every claim in the spec's "Conformance & De-risking" section: three
trigger classes, both behavior arms, both implemented sinks, the kioku session + memory record, the
living loop (kawa re-publish → second agent), the feedback guard, the permission denial, and memory
persistence across runs.

**What will exist at the end.** A `triage-note` skill directory; four trivial proof agents; two
fixture envelopes; and a `tasty` test module `Proof.LivingLoopSpec` (added to the existing test suite
of `shikigami-cli` or `shikigami-core`) that brings up the substrate, runs the worker, fires each
trigger, and asserts each leg. The proof passes with `cabal test` and produces a transcript a human
can compare.

**The proof agents (under `agents/proof/`).** Authored against `schema/Agent.dhall`:

- `noop-heartbeat.dhall` — `behavior = ShikumiProgram { task = "noop-summary" }`,
  `trigger = Schedule { cron = "* * * * *" }`,
  `sinks = [ KawaDigest { subjectType = "heartbeat", verb = "heartbeat.tick" } ]`. Proves trigger
  class 1a (schedule), behavior arm 1 (shikumi), and the KawaDigest sink. Its KawaDigest is what the
  kawa stub re-publishes to close the living loop.
- `triage-note.dhall` — `behavior = Skill { path = "agents/skills/triage-note" }`,
  `trigger = Stream { match = { verb = Some "ticket.received", source = None Text, subjectType = None
  Text } }`, `sinks = [ KizashiSignal { signalType = "TaskCandidate", priority = "Normal" } ]`. Proves
  trigger class 1b (stream), behavior arm 2 (skill via stub baikai), and the KizashiSignal sink. This
  is the exact agent the spec's "Example" section describes.
- `digest-watcher.dhall` — `behavior = ShikumiProgram { task = "noop-summary" }`,
  `trigger = Stream { match = { verb = Some "heartbeat.tick", source = Some "shinzui/shikigami",
  subjectType = None Text } }`, `sinks = [ KizashiSignal { signalType = "DigestItem", priority =
  "Low" } ]`. This is the **second agent** that fires when the kawa stub re-publishes
  `noop-heartbeat`'s KawaDigest — it closes the living loop and is also the natural place to prove
  memory persistence (run it twice; on the second run it recalls run 1's memory).
- `addressed-echo.dhall` — `behavior = ShikumiProgram { task = "noop-summary" }`,
  `trigger = Event { eventType = "echo" }`,
  `sinks = [ KizashiSignal { signalType = "Notification", priority = "Low" } ]`. Proves trigger class
  2/3 (addressed inbox delivery).

**The `triage-note` skill (`agents/skills/triage-note/SKILL.md`).** A minimal valid Agent-Skills
directory: YAML frontmatter with `name: triage-note` (must equal the directory name) and a keyword-rich
`description`, plus a short Markdown instruction body ("Read the ticket activity and write a one-line
triage note"). No `scripts/` (executable skill code is out of scope per the spec's sandbox note — only
instructions run). The stub baikai provider returns a deterministic completion for it, so no model key
is needed.

**The fixture envelopes (under `proof/fixtures/`).**

- `ticket-human.json` — a nine-field C1 envelope with `verb = "ticket.received"`, `subject = { type:
  "ticket", id: "T-1" }`, `actor = { kind: "human", id: "person:nadeem" }`, and a small `payload`.
  Triggers `triage-note`.
- `digest-agent.json` — a nine-field C1 envelope with `actor.kind = "agent"` (e.g. `verb =
  "heartbeat.tick"`, `source = "shinzui/shikigami"`). This is the **feedback-guard** fixture: when
  published, `digest-watcher` must *not* fire on it because the matcher excludes `actor.kind="agent"`
  by default.

**The harness (`Proof.LivingLoopSpec`).** A `tasty` test group. Its setup brings up Postgres +
Redpanda (use the project's `process-compose.yaml`; in CI, the test-support sublibrary
`Shikigami.Migrations.TestSupport.withShikigamiMigratedDatabase` already provisions an ephemeral
Postgres with the composed migrations — reuse it; the Kafka broker comes from `process-compose up`).
Each test fires a trigger and asserts on observable state. The legs, each a separate `testCase`:

1. **Load.** Load `agents/proof/` and `agents/detectors/` through `Shikigami.Agent.Loader.loadAgent`;
   assert all six agents parse (this re-asserts M1's detector conformance inside the harness).
2. **Schedule fires (class 1a).** Drive `noop-heartbeat` via the schedule path (advance the clock or
   enqueue its due-time job, whichever EP-4/EP-5 chose); assert a `kioku_sessions` row appears for
   `noop-heartbeat` with `status = completed`, and the kawa stub's request log has one
   `POST /v1/sources/.../events` with `verb = heartbeat.tick`, `actor.kind = agent`,
   `source = shinzui/shikigami`.
3. **Stream fires (class 1b) + skill arm.** `shikigami publish-fixture proof/fixtures/ticket-human.json`;
   assert `triage-note` fires, a `kioku_sessions` row appears, and the kizashi stub log has one
   `POST /v1/signals` with `signalType = TaskCandidate`.
4. **Addressed fires (class 2/3).** Deliver an `echo` event to the agent inbox (POST the
   `EventTrigger` route or enqueue the inbox job, per EP-4); assert `addressed-echo` fires and records
   a session.
5. **Both behavior arms ran.** Already covered by legs 2 (shikumi) and 3 (skill); assert both sessions
   carry the expected `summary`/output payload from `noop-summary` and the stub baikai completion.
6. **Both sinks dispatched.** Assert the kawa stub log (from leg 2) and the kizashi stub log (from
   leg 3) each have exactly the expected one request.
7. **kioku session + memory recorded.** For each fired agent, assert one `kioku_sessions` row
   (`status = completed`) and one `kioku_memories` row scoped to that agent
   (`namespace = shikigami`, `kind = agent`, entity = the agent name).
8. **Living loop closes.** Run the worker with the kawa stub in `--republish-topic activity.v1` mode.
   After leg 2's `noop-heartbeat` KawaDigest reaches the stub, the stub re-publishes it onto
   `activity.v1`; assert `digest-watcher` (whose Stream match is `verb = heartbeat.tick, source =
   shinzui/shikigami`) fires, producing a `DigestItem` signal at the kizashi stub and its own kioku
   session. This is the system feeding itself: an agent's output became a second agent's input.
9. **Feedback guard.** `shikigami publish-fixture proof/fixtures/digest-agent.json` (an
   `actor.kind="agent"` envelope). Assert that **no** new session row and **no** new signal appear for
   `digest-watcher` (or any agent) attributable to that envelope — the matcher excluded it. Contrast
   with leg 8, where the *same shape* of envelope fired the agent *because the stub re-publish path is
   the loop*; the guard test publishes an agent-actor envelope *directly* and shows it is dropped.
   (Reconcile the exact distinction with EP-4's feedback-guard implementation: the guard excludes
   `actor.kind="agent"` *by default*; the loop works because the digest-watcher opts in to observing
   agent output, OR because the re-publish path re-stamps the actor — confirm which against EP-4/EP-3
   and assert accordingly. Record the resolution in the Decision Log.)
10. **Permission denial.** Configure the stub permission allow-list (`Shikigami.Sink.Permission`) to
    *deny* `triage-note` the `KizashiSignal` sink (remove its name for `SKizashiSignal`). Re-fire
    `triage-note` via a fresh `ticket-human.json`; assert the kizashi stub log gains **no** new
    request, the worker log records a denial, the session still completes (`status = completed`, not
    `failed`), and the denial is recorded (in the session's turns/metadata per EP-2/EP-3's denial
    record). The run is not crashed by the denial — it is skipped.
11. **Memory persists across runs.** Fire `digest-watcher` twice (two re-published heartbeat digests,
    or two direct stream deliveries of a matching non-agent envelope). On the second run, assert that
    `Kioku.Recall.getActiveByScope` for `digest-watcher`'s scope returns run 1's memory *before* run 2
    records its own — i.e. run 2 sees run 1's learning. Concretely: assert `kioku_memories` has ≥ 1 row
    scoped to `digest-watcher` after run 1, and that run 2's behavior input (or its session's recalled
    context) contains that prior memory. This proves the kioku integration gives agents memory across
    runs (the capability the original spec lacked).

**Acceptance.** `cabal test` (or the specific test selector) runs `Proof.LivingLoopSpec` green, and
the transcript shows each leg's assertion passing. The eleven legs together are the spec's
"agent-loop proof," "living-loop proof," "feedback-guard proof," "permission proof," and "memory
proof," and they exercise the C5 acceptance test's machinery (a Stream trigger + a shikumi/handan
program or skill + a KizashiSignal sink — exactly the detector shape).

### Milestone 3 — Record maturity and file the cross-project IRs

**Scope.** Record shikigami's maturity as a `shinzui/mori` capability record and file the three
cross-project improvement-requests against their owning repos — as design artifacts, not
implementations.

**What will exist at the end.** A `mori.dhall` at the repo root with
`lifecycle = Schema.Lifecycle.Active`, registered with `mori register`; a `mori/upstream-issues.dhall`
with three entries pointing at the filed IRs; a shikigami-anchored cross-reference on
`shinzui/mori`'s `docs/improvement-requests/add-agent-automation-action.md` (IR-1) and
`shinzui/shomei`'s `docs/improvement-requests/scoped-service-token-issuance.md` (IR-2); and a new
`shinzui/kanmon` `docs/improvement-requests/channel-egress-sink.md` (IR-3). No production code in
mori, shomei, or kanmon.

**Steps, concretely.**

1. **Author `mori.dhall` (the capability record).** Model it on `shinzui/kioku`'s and
   `shinzui/kanmon`'s `mori.dhall` (both verified present): pin the `Schema` import to the mori-schema
   commit those use, set `project.name = "shikigami"`, `namespace = "shinzui"`,
   `type = Schema.PackageType.Application` (it ships the `shikigami` executable),
   `language = Schema.Language.Haskell`, **`lifecycle = Schema.Lifecycle.Active`** (the spec → active
   advance), a `description`, `domains = [ "AgentRuntime", "Automation" ]`, `owners = [ "shinzui" ]`,
   the `repos` entry, a `docs` entry for `docs/initial-spec.md`, and the `dependencies` list (kioku,
   the kikan stack, handan/shikumi/baikai/kafka-effectful/dhall, per the `cabal.project` pin-set).
   Run `mori register` from the repo root and verify with `mori registry show shinzui/shikigami --full`
   that it appears with lifecycle Active.

   > Note: there is no `mori capability` CLI subcommand (verified: `mori capability --help` is
   > invalid). The "capability record" the spec asks for *is* the project's mori manifest + its
   > registration, with the `Lifecycle` enum (`< Active | Experimental | Deprecated | Archived >`)
   > carrying the maturity. Advancing to `Active` is the registry's expression of "built and proven."

2. **File IR-1 against `shinzui/mori`.** The artifact `docs/improvement-requests/add-agent-automation-action.md`
   **already exists** in `shinzui/mori` (authored by the Kikan initiative; it specifies the additive
   `ReactionAction` `Agent` constructor + `AgentAction` record + `executeAgent` dispatch arm, citing
   C5). EP-6's job is to *file it from shikigami's side*: add a short "Filed by" / cross-reference note
   at the top (or bottom) of that artifact naming `shinzui/shikigami` `docs/plans/6-…` (this plan) and
   `docs/masterplans/1-…` as the consuming runtime, and confirming shikigami's side of the seam is the
   `EventTrigger` inbox (`POST /v1/agents/{name}/runs` or the shared pgmq agent-run queue) proven in
   M2 leg 4. Do **not** implement the mori change. If the maintainers' convention prefers a separate
   artifact over editing the existing one, author a thin companion
   `docs/improvement-requests/shikigami-agent-action-consumer.md` instead, cross-referencing the
   original. Cite contract **C5**.

3. **File IR-2 against `shinzui/shomei`.** The artifact
   `docs/improvement-requests/scoped-service-token-issuance.md` **already exists** in `shinzui/shomei`
   (Kikan-authored; it specifies the additive `issueServiceToken` path over the existing
   `signAccessToken`/`buildClaims` seam, coarse scopes `kawa:ingest`/`signal:raise`/`channel:egress`,
   citing C11). File it from shikigami's side the same way as IR-1: a cross-reference note naming this
   plan as the consuming runtime, confirming shikigami's side is the `checkGrant` seam
   (`Shikigami.Sink.Permission`, stubbed in this initiative, swapped for the real lookup by EP-10) and
   the local grant table keyed by the verified `sub`. Do **not** implement the shomei change. Cite
   contract **C11**.

4. **File IR-3 against `shinzui/kanmon`.** No improvement-request artifact exists yet for the channel
   egress (`shinzui/kanmon` owns it via its own spec/plans). Author a **new**
   `docs/improvement-requests/channel-egress-sink.md` in `shinzui/kanmon`, matching the shape of the
   existing mori/shomei artifacts (Status: proposed; Origin: this plan; Owner of the build:
   `shinzui/kanmon`; Size: additive). State the request: shikigami's channel-egress sink (the outbound
   half of contract **C12**) calls kanmon's egress API
   (`POST /channels/{channelId}/actions/{action}`, verified in kanmon's `docs/initial-spec.md`),
   per-destination authorized by `shomei`; kanmon holds the provider credentials and is the only thing
   that calls a provider; shikigami never holds provider credentials nor names an arbitrary
   destination. Acceptance: a shikigami agent with a channel-egress sink, given a valid shomei token
   and a per-destination grant, results in exactly one authorized egress call at kanmon. Do **not**
   implement the kanmon change. Cite contract **C12**.

5. **Record the consumer-side mirror in shikigami.** Author `mori/upstream-issues.dhall` (the mori
   `upstream-issues` extension — the convention for tracking gaps in dependencies a project consumes).
   Add three entries keyed `mori-agent-automation-action` (dependency `shinzui/mori`),
   `shomei-scoped-service-tokens` (dependency `shinzui/shomei`), and `kanmon-channel-egress`
   (dependency `shinzui/kanmon`), each with `status = Active` (we are affected; no local workaround
   beyond the stub), `upstreamUrl`/`workaroundPath` pointing at the filed IR artifacts and shikigami's
   stub seam, and a `revisitTrigger` ("when the IR lands upstream"). Run `mori register` and verify
   with `mori upstream-issues list`.

**Acceptance.** `mori registry show shinzui/shikigami --full` shows lifecycle `Active`;
`mori upstream-issues list` shows the three entries; the three IR artifacts exist in mori/shomei/kanmon
with shikigami-anchored cross-references and cite C5/C11/C12 respectively; no production code changed
in those three repos (verify with `git -C <repo> status` showing only the doc artifact).


## Concrete Steps

All commands run from the repo root `/Users/shinzui/Keikaku/bokuno/shikigami` inside the nix dev shell
(enter it with `nix develop` or via `direnv allow` if `.envrc` is set up), unless a different working
directory is stated. The `shikigami` executable is invoked as `cabal run shikigami --` during
development; once installed it is just `shikigami`.

### M1 — re-point and validate the seed detectors

After editing the two detector files (per Plan of Work M1), validate them:

```bash
cabal run shikigami -- validate agents/detectors/stalled-intention.dhall
```

Expected transcript (field set depends on EP-1's canonical `AgentDecl`; the shape is what matters):

```text
AgentDecl
  { name = "stalled-intention"
  , behavior = ShikumiProgram { task = "stalled-intention" }
  , trigger = StreamTrigger { match = StreamMatch { verb = Just "intention.declared", source = Nothing, subjectType = Just "intention" } }
  , sinks = [ KizashiSignal { signalType = "Reminder", priority = "Normal" } ]
  }
OK: 1 agent parsed.
```

```bash
cabal run shikigami -- validate agents/detectors/at-risk-customer.dhall
```

Expected:

```text
AgentDecl
  { name = "at-risk-customer"
  , behavior = ShikumiProgram { task = "at-risk-customer" }
  , trigger = StreamTrigger { match = StreamMatch { verb = Just "ticket.received", source = Nothing, subjectType = Just "ticket" } }
  , sinks = [ KizashiSignal { signalType = "Alert", priority = "High" } ]
  }
OK: 1 agent parsed.
```

Confirm no detector still imports the placeholder schema:

```bash
git grep -n 'schema.dhall' agents/detectors/
```

Expected: only the schema file itself if you kept a re-export; **no** matches in
`stalled-intention.dhall` or `at-risk-customer.dhall`. If you deleted the placeholder, expect no
matches at all.

A malformed file must still fail loudly (regression check for the loader, not a change):

```bash
echo 'let A = ../../schema/Agent.dhall in A.Agent::{ name = 42 }' > /tmp/bad.dhall
cabal run shikigami -- validate /tmp/bad.dhall ; echo "exit=$?"
```

Expected: a typed error mentioning the type mismatch and `exit=1` (non-zero).

### M2 — bring up the substrate and run the proof

Bring up Postgres + the Redpanda broker (the fixture `activity.v1` topic) and land the schema:

```bash
process-compose up -D            # starts postgres + redpanda from process-compose.yaml
just create-database             # composes kiroku + keiro + kioku migrations + shikigami_fired
```

Expected (abbreviated): `process-compose` reports `postgres` and `redpanda` as `Running`; `just
create-database` prints the applied migration names and ends with the `kioku_sessions`,
`kioku_memories`, `kioku_turns`, and `shikigami_fired` tables created. Verify:

```bash
psql "$SHIKIGAMI_DATABASE_URL" -c '\dt kiroku.*' -c '\dt public.shikigami_fired'
```

Expected: rows listing `kiroku.kioku_sessions`, `kiroku.kioku_memories`, `kiroku.kioku_turns`, and
`public.shikigami_fired`.

Run the proof test (the exact selector depends on where `Proof.LivingLoopSpec` is wired; show both):

```bash
cabal test shikigami-cli --test-options='--pattern "Living loop"'
# or, if hosted in core:
cabal test shikigami-core --test-options='--pattern "Living loop"'
```

Expected transcript (one line per leg):

```text
Living loop
  M2.1 all six agents load and parse:           OK
  M2.2 schedule fires + KawaDigest at kawa stub: OK
  M2.3 stream fires + skill arm + KizashiSignal: OK
  M2.4 addressed inbox delivery fires:           OK
  M2.5 both behavior arms ran:                   OK
  M2.6 both sinks dispatched exactly once:       OK
  M2.7 kioku session + memory recorded:          OK
  M2.8 living loop: kawa re-publish -> 2nd agent: OK
  M2.9 feedback guard: agent-actor fires nothing: OK
  M2.10 permission denial: sink skipped+recorded: OK
  M2.11 memory persists across runs:             OK

All 11 tests passed (… s)
```

The interactive CLI variant (for a human to watch the loop, complementing the test) — run the worker
with the kawa stub re-publishing, then publish a fixture and observe:

```bash
# terminal 1: the kawa stub, re-publishing received digests onto activity.v1
cabal run shikigami -- stub-kawa --port 8088 --republish-topic activity.v1 --broker localhost:9092

# terminal 2: the worker over the proof agents
cabal run shikigami -- worker --agents agents/proof --kawa-url http://localhost:8088 \
  --topic activity.v1 --broker localhost:9092

# terminal 3: kick the loop by publishing a ticket, then watch the heartbeat close the loop
cabal run shikigami -- publish-fixture proof/fixtures/ticket-human.json
```

Expected in terminal 2 (abbreviated log):

```text
[worker] loaded 4 agents from agents/proof
[fire] triage-note (stream verb=ticket.received) -> session sess_… started
[behavior] skill agents/skills/triage-note via stub-baikai -> ok
[sink] KizashiSignal TaskCandidate -> kizashi stub 201
[memory] recorded memory for scope shikigami/agent/triage-note
[fire] noop-heartbeat (schedule * * * * *) -> session sess_… started
[sink] KawaDigest heartbeat.tick -> kawa stub 200 (activity_id=…)
[loop] kawa stub re-published heartbeat.tick onto activity.v1
[fire] digest-watcher (stream verb=heartbeat.tick source=shinzui/shikigami) -> session sess_… started
[sink] KizashiSignal DigestItem -> kizashi stub 201
```

Show the feedback guard dropping an agent-actor envelope:

```bash
cabal run shikigami -- publish-fixture proof/fixtures/digest-agent.json
```

Expected in terminal 2: a single line such as `[guard] dropped activity … actor.kind=agent (feedback
guard)` and **no** `[fire]` line for it.

Assert on the recorded state directly (what the test does, runnable by hand):

```bash
psql "$SHIKIGAMI_DATABASE_URL" -c \
  "select agent_name, status from kiroku.kioku_sessions order by started_at;"
psql "$SHIKIGAMI_DATABASE_URL" -c \
  "select scope_namespace, scope_kind, scope_entity from kiroku.kioku_memories;"
```

Expected: session rows for `triage-note`, `noop-heartbeat`, and `digest-watcher` with
`status = completed`; memory rows scoped `shikigami` / `agent` / each agent name. (Column names are
kioku's; confirm them against kioku's read-model schema and adjust the SELECT accordingly.)

### M3 — record maturity and file the IRs

Author and register the capability record:

```bash
# after writing mori.dhall at the repo root
mori register
mori registry show shinzui/shikigami --full | grep -i 'lifecycle\|Active'
```

Expected: `mori register` reports the project stored; `mori registry show` displays the project with
lifecycle `Active`.

Author `mori/upstream-issues.dhall`, then:

```bash
mori register
mori upstream-issues list
```

Expected: three entries listed — `mori-agent-automation-action` (shinzui/mori),
`shomei-scoped-service-tokens` (shinzui/shomei), `kanmon-channel-egress` (shinzui/kanmon), all status
Active.

File the three IR artifacts in the owning repos (locate each path with `mori registry show <name>
--full`; verified during planning):

```text
shinzui/mori:    /Users/shinzui/Keikaku/bokuno/mori-project/mori/docs/improvement-requests/add-agent-automation-action.md   (exists; add shikigami cross-ref)
shinzui/shomei:  /Users/shinzui/Keikaku/bokuno/shomei/docs/improvement-requests/scoped-service-token-issuance.md            (exists; add shikigami cross-ref)
shinzui/kanmon:  /Users/shinzui/Keikaku/bokuno/kanmon/docs/improvement-requests/channel-egress-sink.md                      (new; author it)
```

Confirm no production code changed in those repos (only doc artifacts):

```bash
git -C /Users/shinzui/Keikaku/bokuno/mori-project/mori status --short
git -C /Users/shinzui/Keikaku/bokuno/shomei status --short
git -C /Users/shinzui/Keikaku/bokuno/kanmon status --short
```

Expected: each shows only the one `docs/improvement-requests/*.md` file modified or added — no `.hs`,
`.cabal`, or schema files.


## Validation and Acceptance

The plan is accepted when all three milestones' acceptance criteria hold, observed as behavior:

**C5 acceptance test — "re-express the intelligence layer's detectors as declared agents" (M1).**
The two seed detectors import the runtime's canonical `schema/Agent.dhall`, validate via
`shikigami validate` (exit 0, parsed declaration printed), and load through the runtime's loader in
the M2 harness (leg M2.1). This is the literal C5 acceptance the spec names: the detectors *are*
declared agents on this runtime. Evidence: the two `validate` transcripts above and a green M2.1.

**The agent-loop proof (M2 legs 2–7).** A Dhall agent loads; a trigger fires on all three classes
(schedule M2.2, stream M2.3, addressed M2.4); the behavior runs on both arms (shikumi in M2.2/M2.5,
skill in M2.3/M2.5); both implemented sinks dispatch (KawaDigest M2.2/M2.6, KizashiSignal M2.3/M2.6);
and the run is recorded as a kioku session and the output as a kioku memory (M2.7). Evidence: green
test legs plus the `kioku_sessions`/`kioku_memories` SELECTs.

**The living-loop proof (M2 leg 8).** The kawa stub re-publishes a KawaDigest envelope onto the
fixture `activity.v1` topic and a second agent (`digest-watcher`) fires on it. Evidence: green M2.8
and the `[loop]` + second `[fire]` lines in the worker log.

**The feedback-guard proof (M2 leg 9).** An envelope with `actor.kind = "agent"` fires nothing.
Evidence: green M2.9 and the `[guard] dropped` line with no `[fire]`.

**The permission proof (M2 leg 10).** A revoked grant causes the sink to be skipped and recorded as a
denial while the run still completes. Evidence: green M2.10 — no new kizashi request, a recorded
denial, and a `completed` (not `failed`) session.

**The memory proof (M2 leg 11).** A second run of the same agent recalls the first run's learning.
Evidence: green M2.11 — `Kioku.Recall.getActiveByScope` returns run 1's memory before run 2 records
its own.

**Maturity + IRs (M3).** `mori registry show shinzui/shikigami --full` shows lifecycle `Active`;
`mori upstream-issues list` shows three entries; the three IR artifacts exist with shikigami-anchored
cross-references citing C5 / C11 / C12; and `git status` in mori/shomei/kanmon shows only doc
artifacts changed (no implementation).

The whole proof is effective beyond compilation: it drives the *real* assembled worker against a real
Postgres + Redpanda and asserts on durable rows and HTTP request logs, not on internal values.


## Idempotence and Recovery

**M1 (re-point) is idempotent.** Editing the two `.dhall` files and re-running `shikigami validate` is
safe to repeat; the files are declarative. If a re-point is wrong, `git checkout
agents/detectors/<file>.dhall` restores the seed and you can re-do the mapping. Deleting the
placeholder `schema.dhall` is recoverable from git. If `validate` reveals the canonical schema cannot
express a detector, do **not** edit the detector to fit a wrong schema — amend EP-1's
`schema/Agent.dhall` (per IP-2), recorded as a Surprise + Decision.

**M2 (the proof) is idempotent across runs once the suppression and idempotency keys are honored.**
The kawa stub enforces idempotency on `(source, source_event_id)`; the keiro inbox dedupes by
delivery; the `shikigami_fired` suppression table dedupes `(detector, subject, window)`. So re-running
a fixture publish does not double-fire. For a *clean* re-run that asserts on counts (e.g. "exactly one
signal"), reset state first: `process-compose down && process-compose up -D && just create-database`
gives a fresh database and broker; the `tasty` harness should use a fresh ephemeral database per run
via `withShikigamiMigratedDatabase`, so the in-test assertions are naturally isolated. If a test leg
hangs (e.g. the broker is not up), tear down with `process-compose down` and re-bring-up before
retrying. Each proof agent, skill, and fixture file is additive under `agents/proof/`,
`agents/skills/triage-note/`, and `proof/fixtures/` — none touches the runtime modules, so the proof
artifacts can be deleted and regenerated without affecting the runtime build.

**M3 (maturity + IRs) is idempotent.** `mori register` is upsert-style (re-registering the same
`mori.dhall` is safe); re-running it after an edit updates the record. The IR artifacts are plain
markdown; re-authoring or re-editing them is safe and recoverable from git. If you register a wrong
lifecycle, fix `mori.dhall` and `mori register` again. Filing an IR is reversible by `git checkout` in
the owning repo. **Never run a `mori` write command that mutates another repo's source; the IR step
writes only documentation.**


## Interfaces and Dependencies

This plan *drives* the runtime built by EP-1..EP-5; it adds no new runtime modules. The interfaces it
relies on (all already existing per Context and Orientation) and the artifacts it produces:

**Runtime interfaces consumed (built by prior plans; full module paths).**

- `Shikigami.Agent.Loader.loadAgent :: FilePath -> IO (Either LoadError AgentDecl)` (EP-1) — loads
  each proof agent and re-pointed detector.
- `Shikigami.Api.Agent.{AgentDecl, Behavior, Trigger, StreamMatch, Sink}` and
  `Shikigami.Api.Activity.ActivityEnvelope` (the nine-field C1 shape) (EP-1) — the wire types the
  fixtures and proof agents conform to.
- `Shikigami.Behavior.Run.runBehavior :: BehaviorEnv -> AgentDecl -> Value -> IO (Either RunError
  Value)` (EP-2), the program registry including the `noop-summary` `Task` (EP-2's
  `Shikigami.Program.Registry`), and the stub baikai provider (EP-2) — the two behavior arms.
- `Shikigami.Sink.dispatch :: SinkContext -> Sink -> Value -> IO SinkResult` and
  `Shikigami.Sink.Permission.checkGrant :: AgentIdentity -> SinkKind -> IO (Either Denied ())` (EP-3)
  — the sink dispatch and the C11 permission gate (revoked-grant proof manipulates the stub
  allow-list). `Shikigami.Sink.KawaClient.postEnvelope` and the `shikigami stub-kawa` server with
  `--republish-topic` (EP-3) — the KawaDigest sink and the living-loop re-publish.
- `Shikigami.Trigger.Schedule.isDue`, `Shikigami.Trigger.Stream.{matchesStream, subscribeActivityStream}`
  (EP-4), the addressed-event inbox, and the `shikigami publish-fixture` / fixture-topic plumbing
  (EP-4) — the three trigger classes and the feedback guard (`matchesStream` excludes
  `actor.kind="agent"` by default).
- The supervised worker (`Shibuya.App.runApp` `QueueProcessor` over `shinzui/pgmq-hs`) and the
  `shikigami worker --agents <dir>` CLI (EP-5) — the assembled loop the proof drives.
- kioku's public API (consumed via EP-2's integration; import only top-level modules + `kioku-api`
  types, never `Kioku.*.Domain.*` internals): `Kioku.Session.{start, complete, failSession,
  recordTurn}`, `Kioku.Memory.record`, `Kioku.Recall.getActiveByScope`, `Kioku.App.{runAppIO, AppEnv,
  noopTracer}`, `Kioku.Api.Scope`, `Kioku.Api.Types`, `Kioku.Id`. The proof asserts on the read-model
  tables `kiroku.kioku_sessions`, `kiroku.kioku_memories`, `kiroku.kioku_turns`.
- `Shikigami.Migrations.TestSupport.withShikigamiMigratedDatabase :: (Text -> IO a) -> IO a` (EP-1) —
  the harness's per-test ephemeral database with the composed migrations.

**Substrate / external libraries (used as libraries, unchanged).** `shinzui/handan`
(`Handan.Runtime`) and `shinzui/shikumi` (the `noop-summary` program), `shinzui/baikai`
(`Baikai.completeRequest` via the stub provider), `shinzui/kafka-effectful` (the `activity.v1`
consumer/publisher), `shinzui/keiro` (the idempotent inbox), `shinzui/shibuya` (the worker),
`shinzui/pgmq-hs` (the queue), `shinzui/kizashi` (the `POST /v1/signals` shape the kizashi stub
mirrors), `tasty` + `hedgehog` (the test harness), and `shinzui/ephemeral-pg` + `codd` (the test
database). Locate any on-disk path with `mori registry show <name> --full`. Coding conventions per
IP-9 (`haskell-jitsurei`, browse with `mori registry docs haskell-jitsurei`) apply to the harness's
Haskell.

**Artifacts produced by this plan (full paths).**

- Re-pointed detectors: `agents/detectors/stalled-intention.dhall`,
  `agents/detectors/at-risk-customer.dhall`; retired `agents/detectors/schema.dhall`; updated
  `agents/detectors/README.md`.
- Proof agents: `agents/proof/noop-heartbeat.dhall`, `agents/proof/triage-note.dhall`,
  `agents/proof/digest-watcher.dhall`, `agents/proof/addressed-echo.dhall`.
- Skill: `agents/skills/triage-note/SKILL.md`.
- Fixtures: `proof/fixtures/ticket-human.json`, `proof/fixtures/digest-agent.json`.
- Proof harness: `shikigami-cli/test/Proof/LivingLoopSpec.hs` (or `shikigami-core/test/...`), wired
  into the existing `tasty` suite.
- Capability record: `mori.dhall` (lifecycle `Active`) and `mori/upstream-issues.dhall`.
- Cross-project IR artifacts (in the owning repos, design only — no code):
  `shinzui/mori` `docs/improvement-requests/add-agent-automation-action.md` (shikigami cross-ref, IR-1,
  cites C5); `shinzui/shomei` `docs/improvement-requests/scoped-service-token-issuance.md` (shikigami
  cross-ref, IR-2, cites C11); `shinzui/kanmon` `docs/improvement-requests/channel-egress-sink.md`
  (new, IR-3, cites C12).

**Dependencies on other plans (by repository path).** This plan hard-depends on
`docs/plans/5-the-supervised-worker-and-run-orchestration.md` (and transitively on
`docs/plans/2-…`, `docs/plans/3-…`, `docs/plans/4-…`, `docs/plans/1-…`). It consumes IP-2 (EP-1's
canonical `schema/Agent.dhall`, re-pointing the seeds at it) and honors IP-9 (coding conventions). It
files the cross-project improvement-requests named in the MasterPlan's Integration Points (IR-1, IR-2,
IR-3). It does not modify the kioku repository.
