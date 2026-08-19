---
id: 39
slug: adopt-a-checked-keiro-dsl-specification-and-evolution-gate
title: "Adopt a checked Keiro DSL specification and evolution gate"
kind: exec-plan
created_at: 2026-07-22T20:55:26Z
intention: "intention_01kx1tytnwe53rdd4es99ztv1p"
master_plan: "docs/masterplans/5-durable-evolution-versioning-and-replay-safety-for-long-lived-workflows.md"
---

# Adopt a checked Keiro DSL specification and evolution gate

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami already has durable workflows, timers, PGMQ work, Kafka integration, inbox and
outbox boundaries, and expected schema evolution, but those cross-node contracts exist only
in hand-written modules and prose. After this change `domain/shikigami.keiro` is the
checked source of truth for mechanically verifiable identities and relationships, generated
modules are protected by the Keiro firewall, and CI rejects incompatible evolution before
deployment.

A developer can run `keiro-dsl check --min-language 5`, regenerate deterministically, run the
generated conformance package with a single `cabal test` target, and run `keiro-dsl diff --since`
to see whether a proposed workflow or contract change is compatible.

**This plan targets `keiro-dsl 0.13.0.0` and authors onto Language 5.** Both statements changed
on 2026-08-18 and both reverse earlier instructions in this file; see Context and the Decision
Log. Shikigami's cohort already sits at `keiro 0.13.0.0` (delivered by plan 53), but the
repository does not depend on `keiro-dsl` at all yet — adding that dependency is this plan's own
first act.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-18) M0 (prerequisite): `docs/plans/53-upgrade-shikigami-to-the-keiro-0-11-and-keiki-0-9-cohort.md`
      has landed. It delivered a **larger** cohort than its title says — `keiro`/`keiro-core`/
      `keiro-migrations` at `0.13.0.0`, not 0.11 — so the specification is authored against
      keiro-dsl **0.13** language **5**, not against 0.11 language 4. This plan's earlier 0.11 /
      language-4 instructions are superseded throughout; see the Revision Note of 2026-08-18.
- [ ] M0: add `keiro-dsl ==0.13.0.0` to `cabal.project`'s constraints block and record the row in
      `docs/dependency-cohort.md`. **The repository has no `keiro-dsl` dependency today** — plan 53
      deliberately did not add one, because nothing consumed it. `cabal run keiro-dsl -- --help`
      must report the 0.13 command surface (`new`, `parse`, `pretty`, `check`, `inspect`,
      `behavior-obligations`, `scaffold`, `diff`) before Milestone 1 starts.
- [ ] M1: inventory current aggregates, workflows, timers/process managers, queues, integrations, inbox/outbox contracts, routers, and read models; encode their stable identities in `domain/shikigami.keiro`.
- [ ] M1: the source's first non-comment line is exactly `language keiro-dsl 5`. Language 4 is a
      published *compatibility-only* contract at 0.13 and shikigami has no Language-4 source to
      preserve, so authoring at 4 would deliberately adopt a compatibility contract for a
      greenfield specification. See Context.
- [ ] M1: for each identity transcribed, an explicit keep-or-rename call recorded — this is the
      last window in which any of them is free to change. See Context.
- [ ] M1: decide and record whether `shikigami_run_jobs` is described as a scaffolded `workqueue`
      node. Under Language 5 that imposes Keiro's schema-version-1 `{v,t,data}` envelope on the
      payload, which today is a bare `RunJob` JSON body. See Context.
- [ ] M2: run the checked scaffold into `shikigami-core/src`, reconcile generated modules with hand-owned holes, and enforce the generated-code firewall.
- [ ] M2: fill the create-once behavior evidence. `keiro-dsl behavior-obligations
      domain/shikigami.keiro --format=text` enumerates every live transition, rejection cell, and
      replay-only transition that `BehaviorHoles` must witness; a `Pending` row is a conformance
      failure, not a default.
- [ ] M3: add the CI gates. On keiro-dsl 0.13 this is concrete: `keiro-dsl check
      domain/shikigami.keiro --min-language 5` with an explicit `--deny CODE` list, plus
      `--report-out <path>` for a machine-readable record and `--coverage-report <path>
      --fail-on-opaque` for the mapped-boundary gate; and `keiro-dsl diff domain/shikigami.keiro
      --since <ref> --explain --report-out <path>` for compatibility classification. See Context
      for the full 0.13 surface.
- [ ] M3: the chosen `--deny` code list recorded in the Decision Log, so the next `keiro-dsl`
      bump knows which failure mode to expect. At 0.13 a code `check` cannot emit is an
      immediate CLI error rather than a silent no-op, so a stale list fails loudly.
- [ ] M3: scaffold with `--runtime-package shikigami-core` so keiro-dsl generates the runnable
      conformance package, and add its stable glob to `cabal.project`. This **replaces** the
      hand-written domain-harness executable earlier drafts of this plan called for; the driver
      and its test stanza are now generated. See Plan of Work.
- [ ] M4: make plans 24–27, 35, 50, and 51 consume the specification and require the evolution gate for every persisted contract or workflow-shape change.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**Language 4 cannot describe `shikigami_run_jobs` at all** (found 2026-08-18 while re-baselining
onto 0.13, before implementation began). A Language-4 `workqueue` payload closes its type
vocabulary to `text`, `int`, and `bool`, and every payload field is required. `RunJob`
(`shikigami-core/src/Shikigami/Agent/RunJob.hs:19-28`) has a `UTCTime`, a four-constructor
`TriggerKind`, an opaque `Data.Aeson.Value`, and four `Maybe` fields. Language 5's colon form
— `field -> "wire_key" : TypeExpr`, lowered through the checked mapped graph — is the first
released spelling that can express it. This is a concrete reason to author at 5 that is
independent of 5 being the default, and it is recorded here because the earlier draft of this
plan asserted the opposite version choice on reasoning that no longer holds.

**The domain-harness executable this plan was going to hand-write is now generated.** keiro-dsl
0.12 added a runnable conformance *package* per service (`scaffold --runtime-package PACKAGE`),
with its own `.cabal`, `Main.hs`, machine-owned ledger, and a create-once
`KeiroConformance.Expectations` module. Milestone 3's original first bullet — "add a core domain
harness executable that concatenates all generated assertions and fails on any false result" —
would now be reimplementing a generated artifact by hand.


## Decision Log

Record every decision made while working on the plan.

- Decision (2026-08-18): **Author onto Language 5 and pin `check --min-language 5`.** This
  reverses the decision of 2026-08-10 below, which is retained for history and must not be
  followed.
  Rationale: three things changed. (1) keiro-dsl 0.12 published Language 5 as the *sole stable
  and default authoring contract*; the registry at
  `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs:242-249` now marks languages 1–4
  `CompatibilityOnly` and 5 `Stable`, and there is no candidate language 6. The 2026-08-10
  entry's premise — that 5 was a candidate "amended in place until publication" — expired.
  (2) Language 4 is not a neutral choice for a greenfield source: at 0.13 it is a compatibility
  contract, and keiro's own guidance is that existing Language-4 CI may keep `--min-language 4`
  while *new* services use `--min-language 5`. Shikigami has no Language-4 source to preserve.
  (3) The old entry's supporting argument — "shikigami has no projection catalog or rebuild
  group, so 5 buys nothing" — was true of catalogs and wrong overall: Language 5's mapped
  workqueue and read-model query surface is what makes `shikigami_run_jobs` describable, and its
  typed domain outcomes are what plan 51's run-evidence state machine needs.

- Decision (2026-08-18): **Keep the explicit `--deny CODE` list; do not switch to
  `--deny-warnings`, and record that this diverges from keiro's published CI recipe.**
  Rationale: the 2026-08-10 entry predicted that a blanket deny turns a `keiro-dsl` upgrade into a
  build failure on a code that did not exist when the gate was written. That prediction was
  borne out — 0.12 appended catalog cursor/source-ordering, delivery/freshness, typed-outcome,
  mapped queue/read-model, workspace-source-index, and behavior-source-anchor `DiagnosticCode`
  cases. What is new is that the explicit list is now *validated*: 0.13's `check` refuses a
  `--deny CODE` it can never emit (`keiro-dsl/app/Main.hs:221-283`), so a list that goes stale
  fails immediately and visibly rather than silently matching nothing. That removes the one real
  cost of the explicit list. keiro's own CI recipe recommends `--deny-warnings`; the divergence is
  deliberate and belongs in the CI file as a comment, not as tribal knowledge.

- Decision (2026-08-18): **Scaffold with `--runtime-package shikigami-core` and delete the
  hand-written-harness item from Milestone 3.**
  Rationale: keiro-dsl 0.12+ generates one runnable conformance package per service, including its
  Cabal stanza and driver, and prints the exact `cabal test` target. Hand-writing the equivalent
  would be maintaining a copy of a generated artifact, and the generated one additionally runs the
  context `StructuralConformance` checks under a `structural/` prefix and compares process, router,
  and workflow facts against the create-once `KeiroConformance.Expectations` module. The package
  name is explicit because a service named `shikigami` is implemented by a library named
  `shikigami-core`.

- Decision (2026-08-18): **One `domain/shikigami.keiro` source, not a `.keiro-workspace`.**
  Rationale: 0.13 supports splitting one service across several members via a
  `.keiro-workspace` manifest, and shikigami has enough verticals (agent, trigger, sink,
  integration, flow) to make that tempting. Start single-file anyway: workspace membership adds a
  manifest, per-member `language` preambles, a different ledger and cabal-fragment sidecar naming
  scheme, and a composed-refusal failure mode, for no benefit until the file is genuinely
  unwieldy. The migration single-file → workspace is supported and additive; the reverse is not
  the pressure to plan for. Revisit if the source passes the point where a reader cannot hold one
  vertical in view.

- Decision: Pin `check --min-language 4` and do not adopt candidate language 5.
  **Superseded 2026-08-18 — do not follow.** Retained because it records why the plan pointed at
  language 4 for eight days.
  Rationale (as written): language 5 is registered in keiro's `Unreleased` changelog as a
  candidate that is "amended in place until publication", so its contract can still change;
  keiro's changelog also states languages 1–4 keep their published parse and runtime meaning
  across that work, so a language-4 specification does not rot. Shikigami has no projection
  catalog or rebuild group to describe, which is what language 5 adds, so adopting it would
  couple `domain/shikigami.keiro` to an unpublished contract for no gain.
  Date: 2026-08-10

- Decision: Treat Milestone 1 as the last free window for renaming a durable identity, and spend
  it deliberately rather than transcribing names by reflex.
  Rationale: the original "must not change" framing rested on stranding parked workflows.
  Shikigami has no users, so there are none, and every one of these names is still free. After
  this plan lands, the same rename costs an evolution-diff refusal and a migration strategy — by
  design. Carrying forward a name known to be wrong on the strength of a compatibility argument
  with no subject would freeze a mistake behind a gate built to make it expensive. The default
  remains to keep the deployed name; the change is that a rename is now a decision to record
  rather than a prohibition.
  Date: 2026-08-10

- Decision: Author the specification against keiro-dsl 0.11 language 4, after plan 53.
  **Version superseded 2026-08-18 (0.13, language 5); the "after plan 53" half stands and is
  discharged.**
  Rationale: keiro-dsl 0.11 changes the generated Haskell naming edition (compound module paths
  move, for example `Service_oncall` → `ServiceOncall`), renames every scaffold sidecar file,
  and releases a language 4 whose acceptance differs from earlier languages. Adopting on the
  pinned 0.4 cohort and upgrading afterwards would mean a scaffold-wide rename plus a language
  migration on a specification that had just been hand-authored — the same do-it-twice cost this
  plan exists to spare plans 24–27 and 50–51. That argument was correct and is the reason this
  plan waited; it applies unchanged to 0.13, which added two further language contracts and a
  second sidecar rename on top of 0.11's.
  Date: 2026-08-05

- Decision: Adopt Keiro DSL now rather than documenting a hand-written exception.
  Rationale: Shikigami has several node families, queue and integration contracts, and long-lived workflow evolution; it satisfies every fleet adoption trigger.
  Date: 2026-07-22
- Decision: Adopt incrementally without renaming persisted identifiers.
  Rationale: The checked specification must describe the deployed contract first. Moving code or generating modules must not change stream, workflow, timer, queue, event, or step identities.
  **Qualified 2026-08-10** by the keep-or-rename decision above: the default is still to keep
  every deployed name, but a rename is now a recordable decision rather than a prohibition.
  Date: 2026-07-22
- Decision: Generated modules are never edited; domain decisions remain in hand-owned holes.
  Rationale: Deterministic regeneration and the firewall are only meaningful when generated and hand-owned surfaces remain separate.
  Date: 2026-07-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Current durable behavior lives in `shikigami-core/src/Shikigami/Agent/Workflow.hs`,
`Agent/Conversation.hs`, `Agent/Approval.hs`, `Agent/Delegate.hs`,
`Trigger/Schedule.hs`, `Trigger/Stream.hs`, and `Flow/*`. Work arrives through the
`shikigami_run_jobs` PGMQ queue and Kafka integration consumers. Sink intents use Keiro's
outbox, incoming integration events use the inbox, and conversations/approvals use timers
and awakeables. There is no `domain/shikigami.keiro` and no DSL check, scaffold, harness,
or evolution-diff target — and, as of 2026-08-18, no `keiro-dsl` dependency either.

The Keiro DSL is a build-time parser, checker, scaffolder, harness generator, and evolution
differ. It is not a runtime interpreter. The specification owns stable identities,
cross-node references, transport/disposition policy, and evolution relationships. Generated
modules own structural types, codecs, stream definitions, projections, and harness facts.
Hand-owned holes own Keiki decisions, projections, transport configuration, and application
behavior.

Use Mori to locate `mori://shinzui/keiro` and read the current `keiro-dsl` CLI and source before
implementation; the language reference is at `docs/user/typed-spec-toolchain.md` in that
checkout. Verify any selected released bounds with the authoritative package registry and
upstream tags. Add `keiro-dsl` as a development/tool component from the same immutable Keiro
cohort as the runtime packages; do not run an unrelated checkout version against the committed
specification.

### Target keiro-dsl 0.13, not 0.11

`keiro-dsl 0.13.0.0` was released 2026-08-17 (tag `keiro-dsl-0.13.0.0`, verified 2026-08-18) and
is the tip: keiro's `Unreleased` changelog section is empty. `docs/dependency-cohort.md` already
pins `keiro`, `keiro-core`, and `keiro-migrations` at `0.13.0.0`, so `keiro-dsl` must join at the
same version — the runtime and the toolchain move in lockstep, and 0.13 declares
`keiro-core ^>=0.13.0.0`.

What 0.11 gave this plan and 0.13 still gives it:

- `check --min-language N`, enforcing a language floor so a contributor cannot silently author
  against an older, more permissive contract.
- `--deny-warnings` and repeatable/comma-separated `--deny CODE`, which make selected warnings
  CI-failing *without changing their severity*.
- `check --report-out`, writing the append-only `keiro-dsl/check-report/1` schema, so CI has a
  machine-readable record rather than parsed stderr.
- Resolution of every internally decidable process, router, projection, publisher, queue, pgmq
  source-key, read-model, and timer-ID surface, which is most of what Milestone 1 must encode.
- Field aliases: a direct aggregate or integration-contract field may declare independent
  `haskell <selector>` and `as "<wire-key>"` names, so the specification can describe today's
  persisted wire shapes without renaming a Haskell field, or vice versa.
- One checked UpperCamelCase/lowerCamelCase naming edition for generated Haskell. A spec authored
  fresh never needs `scaffold --apply-name-migrations`; that flag exists to move trees generated
  by older DSL versions and to rename pre-0.11 sidecars.

What 0.12 and 0.13 added on top, all of which this plan consumes:

- **Language 5 as the sole stable and default authoring contract** (see below).
- **A runnable conformance package per service.** `scaffold --runtime-package PACKAGE` emits
  `<out>/keiro-dsl-conformance.<context>/` containing a `.cabal`, `src/Main.hs`, a machine-owned
  `keiro-dsl-conformance-ledger.txt`, and a **create-once** `KeiroConformance.Expectations`
  module. The runner executes service structural checks once under `structural/`, then every
  aggregate and read-model self-check, then compares process, router, and workflow facts against
  `Expectations`. Later scaffolds never overwrite `Expectations`, including under
  `--force-generated-overwrite`; an added, removed, duplicate, or changed fact fails the target
  until a human reviews it. Add one stable glob to `cabal.project` and the CI command stops
  changing as nodes are added.
- **`behavior-obligations`**, a new subcommand (`--format=text|json`, schema
  `keiro-dsl/behavior-obligations/1`) that lists every live transition, reachable rejection cell,
  and replay-only transition the create-once `BehaviorHoles` module must witness, with exact
  file/line/column. Use text while authoring, JSON in CI.
- **`inspect --format=json`**, which reports declared language provenance, effective semantic
  contract, and `languageSupport`. This is the mechanical answer to "what contract is this source
  actually on", and belongs in the same CI job as `check`.
- **A context `BehaviorSourceMap` and `StructuralConformance` module.** Declaration-wide binding,
  fixture, opaque-boundary, coverage, and projection-witness checks moved out of per-aggregate
  harnesses into one context module, so an unrelated aggregate no longer acquires generated-byte
  churn from another aggregate's change. Behavior contracts resolve failure positions through the
  source map instead of embedding volatile line numbers, so moving source text rewrites one file.
- **`diff --gate SURFACE`, `--explain`, `--emit-goldens DIR`, `--replay-impact-out FILE`,
  `--coverage-report FILE`, `--fail-on-opaque-increase`.** `diff` classifies findings across six
  surfaces — `private-history-read`, `old-binary-read-new-events`, `snapshot-hydration`,
  `public-consumer`, `persisted-identity`, `consumer-build` — and gates all but
  `old-binary-read-new-events` by default. Mapped findings carry a `semantic impact` block naming
  the checked old/current typed consumers; declarative router changes carry a `coordination
  impact` block.
- **`check --coverage-report FILE` and `--fail-on-opaque`.** Coverage findings are ordinary
  diagnostics of the run: they obey `--deny-warnings`/`--deny CoverageOpaqueSurface`, appear in
  the check report as line-0 entries, and are accounted for by the report's `ok`.
- **`check --explain-bindings`**, listing the consumer-owned binding, fixture, and register-initial
  symbols that structural mapped types require.
- **A second sidecar rename.** Current names are `keiro-dsl-ledger.context.<context>.txt` (machine
  owned; commit it, never edit it), `keiro-dsl-cabal-fragment.context.<context>.txt` (human-facing
  text to paste into the consuming Cabal stanza), and `keiro-dsl-conformance-ledger.txt`. A
  greenfield source is written with the current names and needs no migration.
- **Scaffold reports `Unchanged` for a byte-identical generated module** rather than rewriting it,
  and separates *semantic impact* (checked dependency graph: which consumers change) from
  *generated-artifact impact* (which bytes actually changed).

### Author onto Language 5

At 0.13 the language registry (`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs:242-249`) marks
languages 1–4 `CompatibilityOnly` and language 5 `Stable`. There is no candidate language 6, and
keiro's `Unreleased` section is empty. Language 4 remains a published, immutable, byte-compatible
contract — existing Language-4 services may keep `--min-language 4` without a mechanical rewrite —
but it is a *compatibility* contract, not the authoring default. Keiro's own guidance is that new
services use `--min-language 5`. Shikigami has no Language-4 specification to preserve, so
authoring at 4 would be choosing a compatibility contract for a greenfield source and then owning
a migration later.

Beyond the default, Language 5 carries three things this portfolio needs:

- **Mapped queue and query surface.** A workqueue payload row may be `field -> "wire_key" :
  TypeExpr`, lowered through the checked mapped graph into structural field codecs or explicit
  opaque `ToJSON`/`FromJSON` boundaries. Language 4 closes queue payload types to `text`, `int`,
  and `bool` and makes every field required — which cannot describe `RunJob` at all. See Surprises.
- **Typed domain outcomes.** Aggregates may declare rejection and no-op result types and label
  each live transition accepted, rejected with a checked reason, or no-op with a checked reason;
  scaffolding dispatches on Keiki's exact selected edge. This is the shape
  `docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md` needs for its
  requested → profile-resolved → running → evidence-sealed → attested state machine.
- **Separated projection delivery and query freshness**, plus catalog contracts and
  `external-read`. Shikigami has no projection catalog today — its inline projections come from
  kioku (`Shikigami/Agent/Conversation.hs:393`), not from its own aggregates — so this is
  headroom rather than an immediate need. It is no longer a reason to avoid 5, because 5 is not
  the opt-in it was when this plan first weighed it.

### The CI gate, concretely

The gate is `check` with a floor, an explicit deny list, and two reports:

```bash
keiro-dsl check domain/shikigami.keiro \
  --min-language 5 \
  --deny <CODE>[,<CODE>...] \
  --report-out build/keiro-check-report.json \
  --coverage-report build/keiro-coverage.json \
  --fail-on-opaque
```

The warning codes `check` can emit at 0.13, from which Milestone 3's list is drawn — record the
chosen subset and the reason for each omission in the Decision Log:

| Class | Codes |
| --- | --- |
| Depend on operational history; deny once the fleet fact is established | `DeprecatedEventReplayHazard`, `EventRetirementInProgress`, `ReplayOnlyCommandStillLive` |
| Deliberate or currently accepted policy | `WqUnloggedDurability`, `ProcessBenignInversion`, `RouterBenignInversion`, `AmbiguousFollowsRejectedPolicy`, `PolicyDeadLetterUnused` |
| Accepted but inert declarations | `IntakeBindFlagUnenforced`, `RmInlineSubscriptionIgnored` |
| Internally decidable; future-language error candidates | `WireSchemaVersionMismatch`, `RmProjectionWithoutNode` |
| Structural coverage; requires `--coverage-report` in the same invocation | `CoverageOpaqueSurface` |

Two mechanical facts make the explicit list safe. A `--deny CODE` naming a code `check` cannot
emit — a cross-revision `diff` code, or a coverage code without `--coverage-report` — is an
immediate CLI error, so a stale list is loud. And `--fail-on-opaque` raises
`CoverageOpaqueGateExceeded` as an *error*, so denying that code can never match; pass the flag
instead.

The evolution gate is `diff`, whose default gate covers every surface except
`old-binary-read-new-events`:

```bash
keiro-dsl diff domain/shikigami.keiro --since <merge-base> --explain \
  --report-out build/keiro-diff.json \
  --replay-impact-out build/replay-impact.json
```

### The identities to describe, and the one window in which they are still free

The identities below exist in the tree today as string literals. The original framing of this
plan was that they must not change, because renaming one strands every parked workflow. That
reasoning is sound in general and does not apply yet: **shikigami has no users, so there is no
parked workflow and no deployed contract.** This is the last moment at which any of these names
is free to change, and this plan is precisely the moment to spend that freedom deliberately,
because the whole point of what follows is to freeze them behind a gate.

So the instruction for Milestone 1 is not "transcribe these verbatim" but "transcribe these,
and while transcribing, say out loud whether each name is the one you want to live with". A step
name that reads badly, a workflow name whose prefix is inconsistent, a queue name that will
collide with a sibling service — fix it here, in the same commit that encodes it, and record the
rename in the Decision Log. After this plan lands, the same rename costs an evolution-diff
refusal and a migration strategy, which is exactly the cost this plan is being built to impose.

Change nothing casually. The default is still to keep the deployed name, because a rename with
no reason is churn and because the inventory's value is that it matches the code. But do not
carry forward a name you know is wrong on the strength of a compatibility argument that has no
subject.

The identities (locations re-verified 2026-08-18):

- Workflow names `shikigami.agent-run` (`Shikigami/Agent/Workflow/Name.hs:9`) and
  `shikigami.danwa-conversation` (`Shikigami/Agent/Conversation.hs:96`).
- The queue `shikigami_run_jobs` (`Shikigami/Trigger/Enqueue.hs:29`).
- Thirteen journaled step names: `ingest-job`, `lookup-agent`, `open-session`, `recall`,
  `run-behavior`, `dispatch-sinks`, `record`, `complete`, `fail-session`, `await-ack`,
  `classify`, `ingest-start`, `resolve-session` — in `Agent/Workflow.hs:187-250,491`,
  `Agent/Conversation.hs:127-161`, and `Flow/AtRiskCustomer.hs:45,50`.
- Derived timer identities (`Shikigami/Agent/Approval.hs:182-184`).

Note that `shikigami_run_jobs` is **not** scaffolded by keiro-dsl today and keeps its own payload
codec: `enqueueRunJob` sends `MessageBody (toJSON job)` — a bare `RunJob` record
(`Shikigami/Trigger/Enqueue.hs:51-58`). Describing it as a Language 5 `workqueue` node would put
that payload inside Keiro's schema-version-1 `{v,t,data}` envelope, because a scaffolded queue
always carries one. That is not a problem of in-flight messages — there are none — but a silent
codec substitution is a behavior change smuggled in under a documentation change, and this plan's
acceptance is that adoption changes no behavior. So Milestone 1 must decide explicitly, with a
test, between two honest options:

1. **Adopt the envelope**, as a stated decision with its own commit and its own wire test, and
   accept that `RunJob`'s producer and consumer both move. Language 5 makes this describable:
   `triggerPayload` becomes an opaque `Json` boundary visible in `--coverage-report`,
   `triggerKind` a structural tagged union, and the four `Maybe` fields explicit optionals.
2. **Leave the queue out of the scaffolded surface** for now, describing only its identity
   elsewhere, and record that the specification does not yet cover the run-job wire shape.

What is not an option is describing the queue in the specification while the runtime keeps a
different codec — do not certify a schema that differs from the codec actually executed.

This plan starts after
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md` (complete)
so the scaffold target and test ownership are stable.


## Plan of Work

Milestone 0 adds the toolchain. Pin `keiro-dsl ==0.13.0.0` in `cabal.project`'s constraints
block alongside the existing `keiro ==0.13.0.0` rows, add the row to
`docs/dependency-cohort.md`, and confirm `cabal run keiro-dsl -- --help` reports the 0.13 command
surface. This is genuinely new work: plan 53 moved the runtime cohort to 0.13 but deliberately did
not add `keiro-dsl`, because nothing consumed it.

Milestone 1 creates an evidence-backed node inventory. Map every persisted name and wire
contract from source and tests before writing the specification: agent-run and conversation
workflow names; step and patch names; approval/conversation timers and awakeables; run-job
queue identity and retry/DLQ policy; Kafka intake envelopes and complete dispositions;
sink-intent integration events, outbox keys, and codecs; routers for run type and timer
kind; process managers; and any read model or projection. Record source locations and
golden values in `docs/architecture/shikigami-domain-inventory.md`.

Create `domain/shikigami.keiro` beginning with `language keiro-dsl 5`, using the exact deployed
names except where a rename is recorded. Put mechanically checkable cross-node contracts in the
specification instead of retyping them in Haskell. Keep opaque business decisions and
environment-specific transport configuration in typed holes. Run `keiro-dsl parse`, then `check
--emit --explain-bindings`, then `inspect --format=json` to confirm the source reports
`languageSupport: "stable"` at language 5. Acceptance is a checked normalized specification with
no unrecorded renames and no new behavior.

Milestone 2 scaffolds into `shikigami-core/src` using the collocated vertical layout chosen
by plan 36. Always run `check` before `scaffold`. Prefer declaring `module` and `layout
collocated` in the source over passing `--module-root`/`--collocate` on every invocation, so
placement is a committed fact rather than a flag someone forgets. Generated modules carry the
generated banner and may be overwritten; create-once holes remain hand-owned. Reconcile existing
modules by moving behavior into the corresponding `Holes`, `BehaviorHoles`, `ReadModel`,
integration, or workflow module while retaining compatibility re-exports during the transition.
Never edit a generated file to match old code. Paste the emitted
`keiro-dsl-cabal-fragment.context.<context>.txt` blocks into `shikigami-core.cabal` and commit
`keiro-dsl-ledger.context.<context>.txt` unedited. Run `behavior-obligations --format=text` and
fill every live, rejection, and replay witness with a real history, command, expected event, or
expected rejection — a `Pending` row fails the conformance target and must not be left as a
default. Run the generated conformance target and firewall checks after each slice. Delete stale
paths only after reviewing whether each is generated or hand-owned; scaffold reports stale paths
and never deletes them.

Milestone 3 creates the test gates. Scaffold with `--runtime-package shikigami-core` so keiro-dsl
generates the runnable conformance package, add its stable glob to `cabal.project`
(`optional-packages: shikigami-core/src/keiro-dsl-conformance.*/*.cabal`), and make `cabal test
keiro-shikigami-conformance` a CI step — the exact target name is printed by the scaffold run.
Review and commit the create-once `KeiroConformance.Expectations` module; a later fact change
fails the target until a human accepts it. Add the `check` gate with `--min-language 5`, the
explicit `--deny` list, `--report-out`, and `--coverage-report --fail-on-opaque`. Add an
integration-contract test for wire codecs and disposition completeness that the generated
harness does not already cover. Add a CI command running `keiro-dsl diff domain/shikigami.keiro
--since <merge-base> --explain --report-out <path>` for persisted-contract changes. A workflow or
event evolution marked incompatible under the default gate set must fail before compilation or
deployment.

Milestone 4 updates downstream plan contracts. Plan 24's versioning discipline must require
the DSL evolution diff in addition to Keiro `patch`; plans 25 and 26 add memory and
conversation workflow structure through the spec; plan 27 consolidates only hand-owned
code around generated contracts; plan 35 declares delegation workflow/child relationships
and RunJob contract evolution in the spec; plans 50 and 51 declare their journaled step and
their run-evidence state machine (see the Portfolio Reconciliation of 2026-08-05). Each
downstream plan names generated files as generated and edits only the specification or
hand-owned holes.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`. `keiro-dsl` is a pinned Hackage dependency
of this project once Milestone 0 lands, so `cabal run keiro-dsl` is reproducible in CI and does
not depend on a developer's `PATH` or on the Keiro checkout.

```bash
nix develop
cabal run keiro-dsl -- --help
cabal run keiro-dsl -- parse domain/shikigami.keiro
cabal run keiro-dsl -- check domain/shikigami.keiro --emit --explain-bindings
cabal run keiro-dsl -- inspect domain/shikigami.keiro --format=json
cabal run keiro-dsl -- behavior-obligations domain/shikigami.keiro --format=text
cabal run keiro-dsl -- scaffold domain/shikigami.keiro \
  --out shikigami-core/src \
  --module-root Shikigami \
  --collocate \
  --runtime-package shikigami-core \
  --goldens shikigami-core/test/golden-payloads
cabal test all
```

The scaffold run prints the exact generated conformance `cabal test` target; use that, not a
hand-written harness stanza.

The CI gate:

```bash
cabal run -v0 keiro-dsl -- check domain/shikigami.keiro \
  --min-language 5 \
  --deny DeprecatedEventReplayHazard,EventRetirementInProgress,ReplayOnlyCommandStillLive,WireSchemaVersionMismatch,RmProjectionWithoutNode \
  --report-out build/keiro-check-report.json \
  --coverage-report build/keiro-coverage.json \
  --fail-on-opaque
```

That `--deny` list is the **starting proposal**, not a decided contract: Milestone 3 must confirm
each code against the specification actually written and record the chosen list and every
omission in the Decision Log. Codes describing deliberate policy (`WqUnloggedDurability`,
`ProcessBenignInversion`, `RouterBenignInversion`, `AmbiguousFollowsRejectedPolicy`,
`PolicyDeadLetterUnused`) and inert declarations (`IntakeBindFlagUnenforced`,
`RmInlineSubscriptionIgnored`) are omitted above because shikigami may legitimately want the
policy they describe; deny them only after confirming it does not.

Before a persisted-contract change:

```bash
cabal run keiro-dsl -- diff domain/shikigami.keiro --since HEAD^ --explain \
  --report-out build/keiro-diff.json \
  --replay-impact-out build/replay-impact.json
```

The output must classify the change across the six compatibility surfaces and exit non-zero for
an incompatible evolution under the default gate set that has not been resolved by an explicit
supported strategy. Run `diff` from inside the Git repository containing the source, because
`--since` uses `git show`.


## Validation and Acceptance

Acceptance requires the checked specification at language 5, a deterministic scaffold, a green
generated conformance package, and the full suite passing. A deliberate invalid cross-reference
fails `check`. A source authored below language 5 fails `--min-language 5`. A manual edit to a
generated module fails deterministic-output or firewall validation. A deliberate incompatible
rename fails `diff --since`. A `Pending` behavior witness fails the generated conformance target.
A newly introduced opaque boundary on a private persisted root fails `--fail-on-opaque`.

Determinism is testable directly: scaffolding an unchanged specification twice must report every
generated module `unchanged` and skip `KeiroConformance.Expectations` as `already present`. A
second run that rewrites bytes is a defect to investigate, not noise.

Existing workflow, queue, timer, integration-event, and outbox golden tests remain
byte-identical during adoption — with two deliberate exceptions, each of which must be its own
commit with its own Decision Log entry and its own test:

1. Where Milestone 1 chose to change an identity while it was still free (see "The identities to
   describe, and the one window in which they are still free").
2. Where Milestone 1 chose to adopt Keiro's `{v,t,data}` queue envelope for `shikigami_run_jobs`
   (see the same section).

Byte-identity is the default and the evidence that adoption changed no behavior; a golden that
moves for any reason not written down in the Decision Log is a failure.


## Idempotence and Recovery

Parsing, checking, inspecting, listing behavior obligations, diffing, and harness execution are
read-only. Scaffolding is repeatable for generated files and must skip create-once holes,
behavior witnesses, and `KeiroConformance.Expectations`. Commit or stash work before reviewing
stale paths; scaffold reports stale paths and never deletes them, so review each against version
control or a fresh disposable scaffold before removing it. Never use `--force-generated-overwrite`
until the target is positively identified as disposable generated output; it bypasses only the
missing-banner protection and cannot overwrite create-once hand code or authorize a name
migration. `--apply-name-migrations` should never be needed by a specification authored fresh at
0.13; if scaffold demands it, something older is present and must be understood before the flag is
passed. Adopt one vertical at a time with compatibility re-exports so the suite stays green.
Persisted identifiers are never renamed as cleanup — only as a recorded Milestone 1 decision.


## Portfolio Reconciliation (2026-07-30, superseded 2026-08-10, version re-superseded 2026-08-18)

This plan hard-depends on plans 36 and 47. It originally said "Target Keiro 0.4.0.1" and required
the drain/transitional-decoder policy from plan 47 for generated queue codec envelopes. **Both
clauses are dead and must not be followed.**

The version target is now keiro and keiro-dsl **`0.13.0.0`**, not the `0.11.0.0` the 2026-08-10
revision of this section named. `docs/plans/53-upgrade-shikigami-to-the-keiro-0-11-and-keiki-0-9-cohort.md`
— this plan's Milestone 0 prerequisite, now complete — delivered 0.13 despite its title. Authoring
against any earlier release is the exact do-it-twice cost the Decision Log entry of 2026-08-05
exists to prevent.

The drain and transitional-decoder policy is likewise moot: it existed to move in-flight messages
encoded under an old codec, and shikigami has no in-flight messages. What survives from the
original clause is its underlying rule, which is still binding and has nothing to do with
compatibility — **do not certify a schema that differs from the codec actually executed.** A
specification that describes a codec the runtime does not run is worse than no specification,
because the gate then attests to something false. That rule is what forces the explicit
`shikigami_run_jobs` envelope decision in Milestone 1.

What also survives unchanged: include Keiro's state-shape hash, structural/opaque declaration,
codec comparison and golden, coverage, and opaque gates, at their 0.13 surface. Codec comparison
is now `scaffold --codec-comparison MAPPED-NAME --comparison-out FILE`, which emits a
non-production comparison module for one structural mapped type; the old codec must be supplied
explicitly by a consumer-owned test, because the tool does not discover one at runtime.


## Portfolio Reconciliation (2026-08-05)

Milestone 4 gains two more consumers. Alongside plans 24–27 and 35, the specification and the
evolution gate must also cover MasterPlan 10's durable contracts
(`docs/masterplans/10-sanctioned-execution-attestation-for-agent-runs.md`):

- `docs/plans/50-fail-closed-profile-resolution-and-run-pinning.md` adds a journaled workflow step,
  `StepName "resolve-profile"`, returning `Maybe SanctionedExecutionProfileRef` — a new persisted
  value inside the agent-run workflow, placed before `open-session`.
- `docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md` adds a durable state machine —
  requested, profile-resolved, running, evidence-sealed, attested, plus non-conforming, incomplete,
  and failed — whose transitions and stored shape are exactly what this gate exists to certify.
  **Language 5's typed domain outcomes are the spelling for it** (accepted / rejected-with-reason /
  no-op-with-reason per live transition, dispatched on Keiki's exact selected edge), which is one
  more reason this plan authors at 5 rather than 4.

Both hard-depend on this plan for that reason: hand-authoring them and re-expressing them under the
specification afterward is the largest avoidable rework in that initiative. This plan does not need
to wait for either; it only needs to leave room for them in the M4 consumer list.


## Interfaces and Dependencies

Use the public `keiro-dsl` CLI and generated runtime APIs from the coherent Keiro cohort:
`keiro-dsl ==0.13.0.0`, matching the `keiro`/`keiro-core`/`keiro-migrations ==0.13.0.0` already
pinned in `cabal.project`. `keiro-dsl 0.13.0.0` requires `keiro-core ^>=0.13.0.0` and
`kiroku-store >=0.8 && <0.9`, both of which the current cohort satisfies. The Cabal
project/build-tool setup must make `cabal run keiro-dsl` reproducible in CI and pin it with the
same Keiro release/ref rather than depending on a developer's `PATH`.

The owned source of truth is `domain/shikigami.keiro`; generated modules live beside hand-owned
concept holes under `shikigami-core/src/Shikigami/<Concept>`, and the generated conformance
package under `shikigami-core/src/keiro-dsl-conformance.<context>/` is reached by a stable
`optional-packages` glob in `cabal.project`. Commit the machine-owned
`keiro-dsl-ledger.context.<context>.txt` and `keiro-dsl-conformance-ledger.txt`; never edit them.

This plan hard-depends on `docs/plans/53-upgrade-shikigami-to-the-keiro-0-11-and-keiki-0-9-cohort.md`
(complete) and on `docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`
(complete), and hard-precedes plans 24–27, 50, 51, and cross-MasterPlan plan 35. It does not
replace Keiro runtime `patch`/`continueAsNew`; it supplies the structural and evolution gate those
runtime mechanisms cannot infer from hand-written code.

Upstream reference material, all in `mori://shinzui/keiro`: the language reference at
`docs/user/typed-spec-toolchain.md`, the adoption argument at
`docs/guides/choosing-keiro-dsl.md`, and the boundary between generated and hand-written services
at `docs/guides/dsl-guarantees-and-hand-written-services.md`.


Revision note (2026-08-18): Re-baselined from keiro-dsl 0.11 / language 4 onto **keiro-dsl 0.13 /
language 5**, and corrected two instructions that had become false.

The version was wrong in a way that mattered. Plan 53 landed on 2026-08-17–18 against a *larger*
cohort than its own title describes — `keiro 0.13.0.0`, not 0.11 — so every "target 0.11"
statement here pointed at a release the repository had already passed. `docs/dependency-cohort.md`
and `cabal.project` both say 0.13, and keiro-dsl moves in lockstep with keiro-core.

The language choice was reversed outright. The Decision Log entry of 2026-08-10 pinned
`--min-language 4` and excluded language 5 on the grounds that 5 was a candidate keiro "amends in
place until publication". keiro-dsl 0.12 published it: the registry now marks languages 1–4
`CompatibilityOnly` and 5 `Stable`, and there is no candidate 6. The old entry is retained,
marked superseded, and replaced. Two supporting arguments are new rather than merely inverted —
Language 4 physically cannot describe `shikigami_run_jobs` (its queue payload vocabulary is
`text`/`int`/`bool` with every field required, and `RunJob` has a `UTCTime`, an enum, an opaque
`Value`, and four `Maybe`s), and Language 5's typed domain outcomes are the spelling plan 51's
run-evidence state machine needs.

Milestone 3 lost a deliverable and gained a stronger one. It called for hand-writing a domain
harness executable that concatenates generated assertions; keiro-dsl 0.12 generates a complete
runnable conformance *package* per service under `scaffold --runtime-package`, including its
Cabal stanza, driver, ledger, and a create-once `KeiroConformance.Expectations` module that turns
any changed process/router/workflow fact into a reviewed decision. Hand-writing it now would be
maintaining a copy of a generated artifact.

The `--deny` versus `--deny-warnings` question was re-grounded rather than re-argued. The
2026-08-10 prediction that a blanket deny turns a tool upgrade into a build failure was borne out
— 0.12 appended a large set of new diagnostic codes — and 0.13 removed the explicit list's one
real cost by refusing a `--deny CODE` that `check` can never emit. The list of emittable warning
codes is now tabulated in Context with a starting proposal in Concrete Steps, and the divergence
from keiro's published `--deny-warnings` recipe is recorded as deliberate.

Also folded in: the 0.12/0.13 CLI surface this plan now consumes (`inspect`,
`behavior-obligations`, `check --coverage-report`/`--fail-on-opaque`/`--explain-bindings`,
`diff --gate`/`--explain`/`--emit-goldens`/`--replay-impact-out`, the second sidecar rename, the
context `StructuralConformance` and `BehaviorSourceMap` modules); a new Milestone 0 item for
adding the `keiro-dsl` dependency, which the repository still does not have; a recorded decision
to stay on a single `.keiro` source rather than a `.keiro-workspace` manifest; a sharpened
`shikigami_run_jobs` envelope decision with two named honest options and evidence from
`Trigger/Enqueue.hs:51-58`; re-verified line numbers for every durable identity
(`Conversation.hs:92` → `:96`, and `Trigger/Scheduler.hs`/`Consumer.hs` → the actual
`Trigger/Schedule.hs`/`Stream.hs`); a determinism check in Validation; and the MasterPlan's
`intention` inherited into this plan's frontmatter.

Revision note (2026-08-10): Four changes, and one correction of a contradiction the plan was
carrying.

The contradiction: the Portfolio Reconciliation of 2026-07-30 still said "Target Keiro 0.4.0.1"
while the Decision Log and Context said 0.11. Both could not be followed, and the stale one was
the version an implementer reads first. That section is now marked superseded, states which of
its clauses are dead and which survive, and keeps the one rule from it that never depended on a
version — do not certify a schema that differs from the codec actually executed.

Language 5 is now explicitly out of scope, with the reasoning in Context and the Decision Log:
it is a candidate that keiro amends in place until publication, shikigami has nothing it
describes, and languages 1–4 keep their meaning across the language-5 work. Related, Milestone 3's
gate moved from a blanket `--deny-warnings` to an explicit `--deny CODE` list, because keiro 0.12
appends new diagnostic codes and a blanket deny turns a tool upgrade into a build failure on a
code that did not exist when the gate was written. **(The language-5 half of this note was
reversed on 2026-08-18; the `--deny` half stands.)**

The durable-identity section was reframed. Its "must not change" instruction rested on stranding
parked workflows, and shikigami has no users, so there are none and every identity is still
free. Milestone 1 now asks for an explicit keep-or-rename call on each name, on the argument that
this is the last moment the choice is free and this plan exists to make it expensive afterwards.
The default is still to keep the deployed name, and Validation still demands byte-identical
goldens except where a rename is recorded in the Decision Log in its own commit.

Finally, the queue-envelope caution was re-grounded. It previously warned about in-flight
messages, which do not exist; the real reason to keep `shikigami_run_jobs` on its own payload
codec is that a silent codec substitution is a behavior change disguised as a documentation
change, and this plan's acceptance is that adoption changes no behavior.

Revision note (2026-08-05): Re-pointed at keiro-dsl 0.11. Added plan 53 as a hard prerequisite
so the specification is authored against language 4 rather than migrated onto it; recorded the
0.11 surface this plan consumes (`--min-language`, `--deny-warnings`/`--deny`, `--report-out`,
field aliases, resolved process/router/projection/queue/timer identities, the single naming
edition); made Milestone 3's CI gate concrete; and wrote down the durable identities the
specification must describe without changing, plus the constraint that `shikigami_run_jobs` is
not scaffolded and keeps its own payload codec.

Revision note (2026-07-22): Created from the portfolio conformance review because
Shikigami's workflows, queues, integrations, and expected evolution make Keiro DSL adoption
mandatory rather than optional.
