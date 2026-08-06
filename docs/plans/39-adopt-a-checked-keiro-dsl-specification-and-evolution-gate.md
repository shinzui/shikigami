---
id: 39
slug: adopt-a-checked-keiro-dsl-specification-and-evolution-gate
title: "Adopt a checked Keiro DSL specification and evolution gate"
kind: exec-plan
created_at: 2026-07-22T20:55:26Z
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

A developer can run `keiro-dsl check`, regenerate deterministically, execute the generated
domain harness, and run `keiro-dsl diff --since` to see whether a proposed workflow or
contract change is compatible.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M0 (prerequisite): `docs/plans/53-upgrade-shikigami-to-the-keiro-0-11-and-keiki-0-9-cohort.md`
      has landed, so the specification is authored against keiro-dsl 0.11 language 4 rather
      than migrated onto it afterwards.
- [ ] M1: inventory current aggregates, workflows, timers/process managers, queues, integrations, inbox/outbox contracts, routers, and read models; encode their stable identities in `domain/shikigami.keiro`.
- [ ] M2: run the checked scaffold into `shikigami-core/src`, reconcile generated modules with hand-owned holes, and enforce the generated-code firewall.
- [ ] M3: add domain, DSL conformance, integration-contract, and evolution-diff tests to CI.
      On keiro-dsl 0.11 this is concrete: `keiro-dsl check --min-language 4 --deny-warnings
      --report-out <path>` as the gate, plus `keiro-dsl diff --since <ref>` for compatibility
      classification. See Context for the full 0.11 surface.
- [ ] M4: make plans 24–27 and 35 consume the specification and require the evolution gate for every persisted contract or workflow-shape change.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Author the specification against keiro-dsl 0.11 language 4, after plan 53.
  Rationale: keiro-dsl 0.11 changes the generated Haskell naming edition (compound module paths
  move, for example `Service_oncall` → `ServiceOncall`), renames every scaffold sidecar file,
  and releases a language 4 whose acceptance differs from earlier languages. Adopting on the
  pinned 0.4 cohort and upgrading afterwards would mean a scaffold-wide rename plus a language
  migration on a specification that had just been hand-authored — the same do-it-twice cost this
  plan exists to spare plans 24–27 and 50–51.
  Date: 2026-08-05

- Decision: Adopt Keiro DSL now rather than documenting a hand-written exception.
  Rationale: Shikigami has several node families, queue and integration contracts, and long-lived workflow evolution; it satisfies every fleet adoption trigger.
  Date: 2026-07-22
- Decision: Adopt incrementally without renaming persisted identifiers.
  Rationale: The checked specification must describe the deployed contract first. Moving code or generating modules must not change stream, workflow, timer, queue, event, or step identities.
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
`Trigger/Scheduler.hs`, `Trigger/Consumer.hs`, and `Flow/*`. Work arrives through the
`shikigami_run_jobs` PGMQ queue and Kafka integration consumers. Sink intents use Keiro's
outbox, incoming integration events use the inbox, and conversations/approvals use timers
and awakeables. There is no `domain/shikigami.keiro` and no DSL check, scaffold, harness,
or evolution-diff target.

The Keiro DSL is a build-time parser, checker, scaffolder, harness generator, and evolution
differ. It is not a runtime interpreter. The specification owns stable identities,
cross-node references, transport/disposition policy, and evolution relationships. Generated
modules own structural types, codecs, stream definitions, projections, and harness facts.
Hand-owned holes own Keiki decisions, projections, transport configuration, and application
behavior.

Use Mori to locate `shinzui/keiro` and read the current `keiro-dsl` CLI and source before
implementation. Verify any selected released bounds with the authoritative package registry
and upstream tags. Add `keiro-dsl` as a development/tool component from the same immutable
Keiro cohort as the runtime packages (or the corresponding coherent Hackage release); do not
run an unrelated checkout version against the committed specification.

**Target keiro-dsl 0.11** (published on Hackage; verified 2026-08-05). What it gives this plan,
none of which existed when this plan was written:

- A released **language 4**, with `check --min-language 4` enforcing that floor so a
  contributor cannot silently author against an older, more permissive language.
- `--deny-warnings` and repeatable/comma-separated `--deny CODE`, which make selected warnings
  CI-failing *without changing their severity* — the mechanism Milestone 3's gate needs.
- `check --report-out`, writing the append-only `keiro-dsl/check-report/1` schema through
  `Keiro.Dsl.CheckReport`, so CI has a machine-readable record rather than parsed stderr.
- Resolution of every internally decidable process, router, projection, publisher, queue, pgmq
  source-key, read-model, and timer-ID surface, which is most of what Milestone 1 must encode.
- Field aliases: a direct aggregate or integration-contract field may declare independent
  `haskell <selector>` and `as "<wire-key>"` names. Records use the selector, codecs and goldens
  use the wire key. This is what lets the specification describe today's persisted wire shapes
  without renaming a Haskell field, or vice versa.
- One checked UpperCamelCase/lowerCamelCase naming edition for generated Haskell. A spec
  authored fresh on 0.11 never needs `scaffold --apply-name-migrations`; that command exists to
  move trees generated by older DSL versions.

The identities the specification must describe, which exist in the tree today as string
literals and **must not change** (renaming one strands every parked workflow):

- Workflow names `shikigami.agent-run` (`Shikigami/Agent/Workflow/Name.hs`) and
  `shikigami.danwa-conversation` (`Shikigami/Agent/Conversation.hs:92`).
- The queue `shikigami_run_jobs` (`Shikigami/Trigger/Enqueue.hs:29`).
- Thirteen journaled step names: `ingest-job`, `lookup-agent`, `open-session`, `recall`,
  `run-behavior`, `dispatch-sinks`, `record`, `complete`, `fail-session`, `await-ack`,
  `classify`, `ingest-start`, `resolve-session`.
- Derived timer identities (`Shikigami/Agent/Approval.hs:182-183`).

Note that `shikigami_run_jobs` is **not** scaffolded by keiro-dsl and keeps its own payload
codec, so Keiro's versioned `keiroJobCodec` queue envelope does not reach it. Encoding the queue's
identity in the specification must not silently adopt that envelope for in-flight messages. This plan starts after
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md` so
the scaffold target and test ownership are stable.


## Plan of Work

Milestone 1 creates an evidence-backed node inventory. Map every persisted name and wire
contract from source and tests before writing the specification: agent-run and conversation
workflow names; step and patch names; approval/conversation timers and awakeables; run-job
queue identity and retry/DLQ policy; Kafka intake envelopes and complete dispositions;
sink-intent integration events, outbox keys, and codecs; routers for run type and timer
kind; process managers; and any read model or projection. Record source locations and
golden values in `docs/architecture/shikigami-domain-inventory.md`.

Create `domain/shikigami.keiro` using the exact deployed names. Put mechanically checkable
cross-node contracts in the specification instead of retyping them in Haskell. Keep opaque
business decisions and environment-specific transport configuration in typed holes. Run
`keiro-dsl parse` and `check --emit`; acceptance is a checked normalized specification with
no renames or new behavior.

Milestone 2 scaffolds into `shikigami-core/src` using the collocated vertical layout chosen
by plan 36. Always run `check` before `scaffold`. Generated modules carry the generated
banner and may be overwritten; create-once holes remain hand-owned. Reconcile existing
modules by moving behavior into the corresponding `Holes`, `ReadModel`, integration, or
workflow module while retaining compatibility re-exports during the transition. Never edit
a generated file to match old code. Run the generated harness and firewall checks after
each slice. Delete stale paths only after reviewing whether each is generated or hand-owned.

Milestone 3 creates the test gates. Add a core domain harness executable that concatenates
all generated assertions and fails on any false result. Add a DSL conformance test that
checks the committed spec and deterministic generated output, an integration-contract test
for wire codecs and disposition completeness, and a CI command that runs
`keiro-dsl diff domain/shikigami.keiro --since <merge-base>` for persisted-contract
changes. A workflow or event evolution marked incompatible must fail before compilation or
deployment.

Milestone 4 updates downstream plan contracts. Plan 24's versioning discipline must require
the DSL evolution diff in addition to Keiro `patch`; plans 25 and 26 add memory and
conversation workflow structure through the spec; plan 27 consolidates only hand-owned
code around generated contracts; plan 35 declares delegation workflow/child relationships
and RunJob contract evolution in the spec. Each downstream plan names generated files as
generated and edits only the specification or hand-owned holes.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami` using the Keiro checkout found by Mori:

```bash
nix develop
cabal run keiro-dsl -- parse domain/shikigami.keiro
cabal run keiro-dsl -- check domain/shikigami.keiro --emit
cabal run keiro-dsl -- scaffold domain/shikigami.keiro \
  --out shikigami-core/src \
  --module-root Shikigami \
  --collocate
cabal test shikigami-core:shikigami-core-domain
cabal test all
```

Before a persisted-contract change:

```bash
cabal run keiro-dsl -- diff domain/shikigami.keiro --since HEAD^
```

The output must classify the change and exit non-zero for an incompatible evolution that
has not been resolved by an explicit supported strategy.


## Validation and Acceptance

Acceptance requires the checked specification, deterministic scaffold, generated domain
harness, and full suite to pass. A deliberate invalid cross-reference fails `check`. A
manual edit to a generated module fails deterministic-output or firewall validation. A
deliberate incompatible rename fails `diff --since`. Existing workflow, queue, timer,
integration-event, and outbox golden tests remain byte-identical during adoption.


## Idempotence and Recovery

Parsing, checking, diffing, and harness execution are read-only. Scaffolding is repeatable
for generated files and must skip hand-owned holes. Commit or stash work before reviewing
stale paths; never use forced overwrite until the target is positively identified as
disposable generated output. Adopt one vertical at a time with compatibility re-exports so
the suite stays green. Persisted identifiers are never renamed as cleanup.


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 36 and 47. Target Keiro 0.4.0.1 and include its
state-shape hash, structural/opaque declaration, codec comparison/golden, coverage, and opaque gates.
Generated queue codec envelopes require the drain/transitional-decoder policy from plan 47; do not
certify a schema that differs from the codec actually executed.


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

Both hard-depend on this plan for that reason: hand-authoring them and re-expressing them under the
specification afterward is the largest avoidable rework in that initiative. This plan does not need
to wait for either; it only needs to leave room for them in the M4 consumer list.


## Interfaces and Dependencies

Use the public `keiro-dsl` CLI and generated runtime APIs from the coherent Keiro cohort.
The Cabal project/build-tool setup must make `cabal run keiro-dsl` reproducible in CI and pin
it with the same Keiro release/ref rather than depending on a developer's `PATH`.
The owned source of truth is `domain/shikigami.keiro`; generated modules live beside
hand-owned concept holes under `shikigami-core/src/Shikigami/<Concept>`. This plan
hard-depends on `docs/plans/53-upgrade-shikigami-to-the-keiro-0-11-and-keiki-0-9-cohort.md`
and hard-precedes plans 24–27 and cross-MasterPlan plan 35. It does not replace Keiro runtime
`patch`/`continueAsNew`; it supplies the structural and evolution gate those runtime
mechanisms cannot infer from hand-written code.


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
