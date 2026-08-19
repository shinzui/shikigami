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
in hand-written modules and prose. After this change the `domain/shikigami.keiro-workspace`
manifest and its members are the checked source of truth for mechanically verifiable identities
and relationships, generated modules are protected by the Keiro firewall, and CI rejects
incompatible evolution before deployment.

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
- [x] (2026-08-19) M0: added `keiro-dsl ==0.13.0.0` to `cabal.project`'s constraints block **and**
      `extra-packages: keiro-dsl` above it (a constraint alone does not make `cabal run keiro-dsl`
      resolve — see the Decision Log entry of 2026-08-19), and recorded the row plus the
      `extra-packages` rationale in `docs/dependency-cohort.md`. `cabal run keiro-dsl -- --help`
      reports the full 0.13 command surface: `parse`, `pretty`, `check`, `inspect`,
      `behavior-obligations`, `scaffold`, `diff`, `new`.
- [x] (2026-08-19) M1: inventoried every node family from source. The census is
      `docs/architecture/shikigami-domain-inventory.md`, and it is mostly negative: shikigami has
      **no aggregate, no read model, no projection, no router, and no process manager** of its
      own. It has two durable workflows, one PGMQ queue, a Kafka inbox, and a Keiro outbox. See
      Surprises.
- [x] (2026-08-19) M1: authored `domain/shikigami.keiro-workspace` with two members —
      `shikigami-agent-run.keiro` and `shikigami-conversation.keiro` — derived from that
      inventory. The manifest carries `service shikigami`, `runtime-package shikigami-core`, and
      `layout collocated`. It deliberately does **not** carry `module Shikigami`: `context
      shikigami` already supplies that prefix, and adding the clause emits
      `Shikigami.Shikigami.*`. See Surprises.
- [x] (2026-08-19) M1: `SinkIntent` **cannot** be given an owning member at keiro-dsl 0.13, and
      the tool says so. An unconsumed `mapped structural` declaration generates a shape, a
      binding, projections, and conformance — but no wire codec — so declaring it would certify a
      JSON policy nothing executes. Recorded in the Decision Log and handed to plan 27, whose own
      premise this corrects.
- [x] (2026-08-19) M1: both members' first non-comment line is exactly `language keiro-dsl 5`;
      `inspect --format=json` reports both `"sourceForm": "declared"`, effective version 5,
      `"languageSupport": "stable"`.
- [x] (2026-08-19) M1: keep-or-rename call recorded for every identity, in the inventory's
      final section. **Every name was kept**, so every existing golden stays byte-identical.
- [x] (2026-08-19) M1: `shikigami_run_jobs` is **not** described as a scaffolded `workqueue`
      (the plan's option 2). Evidence in the inventory: the generated codec is `keiroJobCodec`,
      the generated `Queue` module defines its own `RunJob`, and
      `shikigami-core/test/Shikigami/WireCompatSpec.hs:76-81` asserts as a live case that the
      payload is bare.
- [x] (2026-08-19) M2: scaffolded into `shikigami-core/src`. Five generated modules land —
      `Shikigami.{AgentRun,DanwaConversation}.Generated.{WorkflowFacts,WorkflowRuntime}` and the
      context-level `Shikigami.Generated.Conformance` — plus the generated conformance package.
      `firewall: OK (5 generated modules scanned, 0 forbidden operators)`. Reconciled by pointing
      `Shikigami.Agent.Workflow.Name.agentRunWorkflowName` and
      `Shikigami.Agent.Conversation.conversationWorkflowName` at the generated
      `WorkflowRuntime.workflowName`, so the specification is now the single source of both
      durable workflow names. There are no holes to fill: with no aggregate there is no
      `Holes`, `BehaviorHoles`, `ReadModel`, or binding module.
- [x] (2026-08-19) M2: excluded the generated layer from `treefmt`. fourmolu rewrote all four
      generated `.hs` files and `cabal-fmt` rewrote the generated conformance `.cabal`, which
      breaks both the firewall and determinism. See Surprises and the Decision Log.
- [x] (2026-08-19) M2: `behavior-obligations --format=text` reports `required: 0` — there is no
      aggregate, so there is no live transition, rejection cell, or replay-only transition to
      witness. Nothing is `Pending`.
- [x] (2026-08-19) M3: the gate is five `just` recipes — `keiro-check`, `keiro-inspect`,
      `keiro-scaffold`, `keiro-diff`, and `keiro-gate`, which runs all four plus `cabal test
      keiro-shikigami-conformance`. This repository has **no CI runner** (no `.github/workflows`,
      no pipeline file of any kind), so "a CI step" is realized as a named repository command
      plus in-suite tests; see the Decision Log.
- [x] (2026-08-19) M3: `--deny-warnings` stands. **No warning fires** — the specification is
      green under `--min-language 5 --deny-warnings --fail-on-opaque` with no `--deny CODE`
      fallback and nothing to justify. This is unsurprising given the census: every warning code
      in the Context table belongs to an aggregate, process, router, queue, intake, or read-model
      surface, and shikigami declares none of them.
- [x] (2026-08-19) M3: `keiro-inspect` asserts `sourceForm == "declared"`, effective version 5,
      and `languageSupport == "stable"` for every member, and fails the recipe otherwise.
      Verified against the real failure: deleting a member's preamble makes both `keiro-check`
      and `keiro-inspect` exit 1 with `WorkspaceLanguageVersionMismatch`.
- [x] (2026-08-19) M3: added `Shikigami.KeiroSpecificationSpec` to `shikigami-core-test`, six
      cases covering the failures the toolchain structurally cannot catch — a `.keiro` file in
      `domain/` that the manifest does not list, a generated module absent from
      `shikigami-core.cabal`, a `.cabal` entry with no file, and a lost `-- @generated` banner.
      Each was mutation-tested and fails on the mutation.
- [x] (2026-08-19) M3: proved the gate fails on every failure mode it claims: a lost preamble
      (`WorkspaceLanguageVersionMismatch`), a hand-edited generated module (scaffold refuses,
      "nothing was written"), a stale committed generated layer (`keiro-scaffold` exits 1), and
      an incompatible rename (`BREAKING ... [WorkflowStableNameChanged]`, `keiro-diff` exits 1).
- [x] (2026-08-19) M3: declared `runtime-package shikigami-core` in the manifest and added the
      stable glob `optional-packages: shikigami-core/src/keiro-dsl-conformance.workspace.*/*.cabal`
      to `cabal.project`. `cabal test keiro-shikigami-conformance` passes twelve workflow facts.
      The create-once `KeiroConformance.Expectations` module is reviewed and committed.
- [x] (2026-08-19) M4: repointed **31 stale `domain/shikigami.keiro` references** across nine
      plans and two MasterPlans onto `domain/shikigami.keiro-workspace`. Two of them were
      startability checks (`ls domain/shikigami.keiro` in plans 50 and 51) that would have told an
      implementer this plan was not done against a repository where it is.
- [x] (2026-08-19) M4: added a "Reconciliation with the delivered plan 39" section to plans 24,
      25, 26, 27, 35, 50, and 51, each carrying the shared corrections (workspace not one file, no
      `module` clause, no aggregate, the three deliberately undeclared surfaces, `just
      keiro-gate`, the wire-word label rule) plus what changes for that plan specifically.
- [x] (2026-08-19) M4: corrected plan 27's Decision Log **in place**. Its entry "Plan 39's
      generated module owns the `SinkIntent` structural wire type and codec" is marked half
      superseded, and its Milestone 1 now says "a Haskell consolidation, not a regeneration".
      Leaving that uncorrected would have sent an implementer looking for a generated module that
      does not exist.
- [x] (2026-08-19) M4: added reconciliation notes to plans 14 and 16, which this plan's inventory
      names as the owners of the undeclarable `approval:<kind>:<ordinal>`, `<label>:notify`, and
      `emit-signal:<ordinal>` label families. Plan 14 also inherits the `signal` operation this
      plan deliberately did not declare.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**This repository's formatter rewrites generated modules, which breaks the firewall and
determinism together** (found 2026-08-19, Milestone 2). `nix fmt` runs fourmolu over every
`.hs` file and cabal-fmt over every `.cabal`, including keiro-dsl output:

```text
$ nix fmt -- --fail-on-change --no-cache
ERRO file has changed path=shikigami-core/src/Shikigami/AgentRun/Generated/WorkflowFacts.hs
ERRO file has changed path=shikigami-core/src/Shikigami/DanwaConversation/Generated/WorkflowFacts.hs
ERRO file has changed path=shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/src/Main.hs
formatted 12 files (5 changed)
```

Both consequences are real. A formatter editing a `-- @generated` file is an edit, which the
firewall forbids; and once the committed bytes are formatter output, the next `scaffold` reports
`overwritten` rather than `unchanged`, so the committed bytes would alternate between generator
output and formatter output forever. This plan's Validation section requires the opposite. The
fix is a `treefmt.settings.global.excludes` list in `flake.module.nix`; after it,
`formatted 139 files (0 changed)` and a repeat scaffold reports every module `unchanged`.

**`keiro-dsl-migration-report.workspace.shikigami.txt` did appear, and its appearance is
benign.** This plan's Idempotence section says the file "should never appear" and that if it
does, "a standalone scaffold happened somewhere and must be understood before proceeding". The
real trigger is narrower: the workspace-adoption path runs whenever `--out` already contains
Haskell under the target namespace, which `shikigami-core/src` obviously does. It claimed
nothing and touched nothing:

```text
migration: adopting pre-workspace scaffold output into workspace shikigami
  legacy record: (none for this context)
  claimed: nothing was attributable to this workspace
  unclaimed: 51 file(s) this workspace does not own; left untouched:
```

The report is written once — a second scaffold does not re-run the migration path and leaves the
file byte-identical — so it is committed as the record of what the workspace did and did not
claim.

**Shikigami has no aggregate at all — not one, as this plan assumed** (found 2026-08-19 during
the Milestone 1 census). `Shikigami.Flow.Lifecycle.AtRiskCustomer` is a Keiki `SymTransducer`
whose output type is `()` and whose own module comment says "this transducer is not an event
source. It is a rendered specification of the at-risk-customer lifecycle: it produces the Mermaid
diagram and nothing else." The single `runCommandWithSqlEvents` call in the repository
(`shikigami-core/src/Shikigami/Agent/Conversation.hs:373`) runs against *kioku's*
`sessionEventStream`, and the inline projections beside it (`Conversation.hs:393`) are kioku's.
Zero aggregates means zero read models, zero projections, zero routers, and zero process
managers of shikigami's own — a `process` node requires a saga aggregate and a target aggregate,
which is why shikigami's two timer families cannot be declared either. This is the finding that
reshaped the member split; see the Decision Log.

**A workflow label cannot contain a colon, and most of shikigami's cannot be declared at all**
(found 2026-08-19). keiro-dsl parses a workflow label with the `wireWord` production —
`[A-Za-z0-9][A-Za-z0-9_-]*` (`keiro-dsl/src/Keiro/Dsl/Parser/Core.hs:282-286`):

```text
domain/probe.keiro:13:19:
   |
13 |     step await-ack:notify -> ParkedApproval
   |                   ^^
unexpected ":n"
expecting "->", '-', or '_'
```

Renaming would not rescue them, because the part after the colon is a runtime value: an approval
await is `approval:<SinkKind>:<ordinal>`, a conversation turn writes `record-user:<messageId>`
and four siblings, and the conversation loop awaits `next-message:<ordinal>`. Eleven agent-run
labels and three conversation labels are static and are declared; the rest are inventoried with
their owning downstream plan.

**`module Shikigami` in the manifest would double the module prefix.** This plan's Context
asserted that "`context shikigami` already supplies `Shikigami` as the default Haskell module
root; the `module` clause is stated anyway so placement is explicit rather than derived". It is
not idempotent — the clause is a *prefix*, applied on top of the context:

```text
$ keiro-dsl scaffold probe.keiro --out out          # with `module Shikigami`
  generated  Shikigami.Shikigami.AgentRun.Generated.WorkflowFacts

$ keiro-dsl scaffold probe.keiro --out out2         # without it
  generated  Shikigami.AgentRun.Generated.WorkflowFacts
```

The manifest therefore declares `service`, `runtime-package`, and `layout` only.

**An unconsumed `mapped structural` declaration owns no wire codec, and keiro says so.**
Declaring `mapped structural record SinkIntent` checks clean, but the tool reports it as
unconsumed and generates no codec:

```text
$ keiro-dsl check probe.keiro --explain-bindings --coverage-report cov.json
  queue-payloads: 0 mapped roots (0 structural, 0 opaque, 0 Json boundaries)
binding obligations for context shikigami
  Shikigami.Sink.Intent.Bindings (package shikigami-core)
    sinkIntentBinding :: StructuralBinding Shikigami.Sink.Intent.SinkIntent SinkIntentShape
      reason: binding — structural type SinkIntent (not currently used by an aggregate root)
```

The scaffold emits `Structural.Shape.SinkIntent`, `StructuralProjections`,
`StructuralConformance`, and a create-once binding hole — and no encoder or decoder. So the
declaration would state a JSON policy that nothing executes, which is precisely what the
Portfolio Reconciliation of 2026-07-30 forbids.

**`RunJob` has three optional fields, not four**, and at 0.13 a `workqueue` payload field cannot
be optional by presence at all. The parser accepts the `required` keyword and discards it:
"Every payload field is required: generated decoders use `o .:` for all of them. The keyword
stays accepted so existing sources still parse, but it selects nothing"
(`keiro-dsl/src/Keiro/Dsl/Parser/Queue.hs:100-102`). Optionality is expressible only in the
*type* — `Optional Text` — which is a different claim about the wire than `omitNothingFields`.
This does not change the queue decision, which rests on the envelope, but it does correct this
plan's Surprises entry of 2026-08-18.

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

- Decision (2026-08-19): **The gate is `just keiro-gate` plus in-suite tests, because this
  repository has no CI runner.** Rationale: there is no `.github/workflows`, no pipeline file,
  and no hosted job anywhere in the tree — the `justfile` is the repository's command surface and
  `treefmt` under git-hooks is its only automatic enforcement. Writing a workflow file for a CI
  system that does not exist would be a declaration with no effect, which the house standard
  tells us to delete rather than ship. So the gate is a named command a human and a future
  pipeline both run identically, and the parts of it that are cheap enough to run every time
  moved into `cabal test all`: `Shikigami.KeiroSpecificationSpec` covers the manifest/member/
  cabal/banner invariants, and the generated `keiro-shikigami-conformance` target covers the
  workflow facts. When a pipeline is added, it runs `just keiro-gate` and nothing here changes.

- Decision (2026-08-19): **Add `Shikigami.KeiroSpecificationSpec` rather than relying on the
  toolchain alone.** Rationale: three of its six cases cover failures `keiro-dsl` structurally
  cannot see. `check`, `inspect`, and `scaffold` all operate on the manifest's member set, so a
  `.keiro` file added to `domain/` and never listed is invisible to every one of them — it is
  simply not part of the service. Likewise a generated module that nobody pastes into
  `shikigami-core.cabal` sits in `src` uncompiled. The banner case duplicates a scaffold refusal,
  but only fires on the next scaffold, whereas the test fires on the next `cabal test`. Each case
  was mutation-tested: introducing the fault makes exactly that case fail, with a message naming
  the file.

- Decision (2026-08-19): **`--deny-warnings` with no `--deny CODE` fallback.** Rationale: the
  fallback is for a green specification that cannot pass the blanket gate, and this one passes.
  No warning fires, and the reason is structural rather than lucky: every emittable warning code
  in this plan's Context table belongs to an aggregate, process, router, queue, intake, or
  read-model surface, and the Milestone 1 census found that shikigami declares none of those. The
  gate will start earning its keep when plan 51 adds an aggregate.

- Decision (2026-08-19): **Exclude the generated keiro-dsl layer from `treefmt`, and only the
  generated layer.** Rationale: see Surprises — formatting generated bytes breaks the firewall
  and the determinism property this plan's Validation section demands. The excludes live in
  `flake.module.nix`, which is the repository's unmanaged extension point, because
  `nix/treefmt.nix` is seihou-managed and would lose the change on a template upgrade. The
  create-once `KeiroConformance.Expectations` module inside the generated conformance package is
  deliberately **not** excluded: keiro-dsl never overwrites it, it is application-owned code that
  a human edits to accept a conformance change, and it should be formatted like any other module.
  The alternative — letting the formatter win and dropping the determinism check — would have
  removed the one mechanical guarantee that a generated file on disk is what the current
  specification produces.

- Decision (2026-08-19): **Gitignore the Cabal fragment; commit both ledgers and the migration
  report.** Rationale: the fleet standard at
  `mori://shinzui/keiro-runtime-patterns/docs/architecture-spec-and-scaffolding` says of the
  fragment "Gitignore it" — it is an instruction to paste into the consuming stanza, and the
  build reads `shikigami-core.cabal`, not the fragment, so a committed copy is a second source of
  truth that can silently disagree. `keiro-dsl-ledger.workspace.shikigami.txt` and
  `keiro-dsl-conformance-ledger.txt` are machine-owned history the next scaffold reads to report
  stale paths, so they are committed unedited. The one-time migration report is committed as
  evidence of what the workspace adoption claimed.

- Decision (2026-08-19): **Point the two hand-written workflow-name constants at the generated
  `WorkflowRuntime.workflowName` rather than leaving the literals in Haskell.** Rationale: this
  is what makes the specification load-bearing instead of decorative. Before this change
  `WorkflowName "shikigami.agent-run"` existed in `Agent/Workflow/Name.hs` and again in
  `domain/shikigami-agent-run.keiro`, and nothing connected them; a rename in one would not
  reach the other and `keiro-dsl diff` would gate a change the runtime never saw. Now there is
  one literal, in the specification, and the diff gate is over the value the runtime actually
  uses. The strings are unchanged, so no golden moves.

- Decision (2026-08-19): **Two members — `shikigami-agent-run.keiro` and
  `shikigami-conversation.keiro` — and no shared member.**
  Rationale: the Milestone 1 census found zero aggregates, so none of the three house triggers
  for a workspace (`mori://shinzui/keiro-runtime-patterns/docs/keiro-service-workspaces`:
  complete aggregates needing separate review ownership, one-aggregate-per-file already, several
  same-context specs scaffolding into one tree) is met by today's tree. The workspace is kept
  anyway because this plan's decision of 2026-08-18b — author as a workspace from the first
  commit so the `WorkspaceAdoption` path is never run — still stands, the manifest is four
  lines, and the same standard explicitly blesses the shape ("To adopt one existing
  multi-aggregate file, create a one-member manifest and scaffold it"). The member *count* comes
  from the inventory: the six-member proposal in Context assumed an aggregate, a router, an
  intake, a publisher, and read models that do not exist, so five of its six members would have
  been empty. What remains is two complete durable workflows with genuinely different downstream
  editors — plans 24, 27, 35, and 50 edit agent-run; plans 25 and 26 edit conversation. There is
  no shared member because there is nothing shared to own: neither workflow declares an id, an
  enum, a rule, or a mapped type. Splitting further later is an advisory `OwnershipMoved` and a
  rescaffold, not wire evolution.

- Decision (2026-08-19): **Do not declare `module Shikigami` in the manifest.** Rationale: the
  clause is a prefix applied on top of the context, so `context shikigami` plus `module
  Shikigami` scaffolds `Shikigami.Shikigami.AgentRun.Generated.*`. Verified both ways; see
  Surprises. This reverses one sentence of this plan's Context, which claimed the clause was a
  redundant restatement of the context default.

- Decision (2026-08-19): **`shikigami_run_jobs` stays out of the scaffolded surface** — the
  plan's option 2. Rationale: all three costs of option 1 are load-bearing rather than
  theoretical. The generated codec is `keiroJobCodec runJobsPayloadCodec`, whose own generated
  comment warns against adopting it on a bare-payload queue; the generated `Queue` module defines
  its own `RunJob` record that would replace `Shikigami.Agent.RunJob.RunJob` on both the producer
  (`Trigger/Enqueue.hs:51-58`) and the consumer (`Agent/RunJob/Worker.hs:62`); and
  `WireCompatSpec.hs:76-81` asserts as a live case, against a captured literal, that "the payload
  is a bare run job, not a versioned envelope", with `docs/dependency-cohort.md` recording that
  fixture as permanent. Moving the queue is a wire change that needs its own commit, decision,
  and fixture, and plans 24 and 27 are where it belongs. The identity is recorded in
  `docs/architecture/shikigami-domain-inventory.md` instead.

- Decision (2026-08-19): **The specification does not own `SinkIntent`, and plan 27's premise is
  corrected rather than satisfied.** Rationale: this plan's Milestone 1 intended
  `WorkspaceDuplicateDeclaration` to mechanize the "must match ... exactly" comment at
  `Flow/SinkOutbox.hs:40,65`. That mechanism applies to DSL declarations, and at 0.13 a
  `SinkIntent` declaration cannot be one that the runtime executes: an unconsumed `mapped
  structural` type generates no codec, and keiro's own `--explain-bindings` output labels it "not
  currently used by an aggregate root" with zero roots on every coverage surface. Declaring it
  would state a wire policy nothing runs — the failure the Portfolio Reconciliation of
  2026-07-30 forbids — and would cost three mapped declarations (`SinkIntent`, `DanwaTarget`, and
  the four-constructor `Sink` union) plus three hand-owned binding modules to do it. The
  duplication stays guarded by `WireCompatSpec.hs:147-148` until
  `docs/plans/27-consolidate-sink-intent-and-run-lifecycle-machinery.md` merges the two records
  into one hand-owned module; Milestone 4 corrects plan 27's Decision Log entry, which currently
  says "Plan 39's generated module owns the `SinkIntent` structural wire type and codec".

- Decision (2026-08-19): **Declare `run` operations only, not `signal` operations.** Rationale:
  `runAgentRunWorkflow` and `runConversationWorkflow` are real, called entry points. The signal
  side is not: `Shikigami.Agent.Approval.resolveApproval` and
  `Shikigami.Agent.Workflow.Input.deliverInput` are exported but have no caller anywhere in the
  repository, `resolveApproval` is keyed by `AwakeableId` rather than by a workflow key (which is
  what a DSL `signal` declares), and the awaits an external signal would target
  (`approval:<kind>:<ordinal>`, `next-message:<n>`) are not declarable labels. The house standard
  is explicit that a declaration a reader expects to have an effect and which has none should be
  deleted rather than gated. `docs/plans/14-approval-and-human-in-the-loop-end-to-end.md` adds
  the entry point and the signal operation together.

- Decision (2026-08-19): **Declare the agent-run body as the full label inventory including its
  mutually exclusive branches.** Rationale: keiro's reference is explicit that "the body is
  ordered, but replay matches journal records by label", so the body is a label inventory rather
  than a control-flow program. `run-behavior` and the flow path's `classify`/`await-ack` are
  alternatives, and `fail-session` excludes `record`/`complete`; declaring all of them states
  every label the workflow may journal, which is exactly the set the evolution gate must guard.
  Declaring only the common prefix would leave four durable labels ungated. The exclusions are
  written into the member as comments so a reader does not mistake the order for a program.

- Decision (2026-08-19): **Keep every durable identity; no renames.** Rationale: Milestone 1 was
  the last free window and it was spent deliberately — the keep-or-rename call for each name is
  in the final section of `docs/architecture/shikigami-domain-inventory.md`. Two names were
  argued about and still kept: `classify` and `await-ack` are at-risk-flow labels journaled into
  the general agent-run workflow, which a rename would not fix (moving them out of the shared
  workflow would, and that is a modelling change for whichever plan gives the flow its own
  aggregate); and `record`/`complete` are generic, but they are the deployed names and the
  workspace now turns a future collision into a `check` failure. Because nothing was renamed,
  every existing golden stays byte-identical, which is the evidence that adoption changed no
  behavior.

- Decision (2026-08-19): **Declare `keiro-dsl` with `extra-packages:` in `cabal.project`, not
  only with a `constraints:` row.**
  Rationale: the plan's Milestone 0 said to "add `keiro-dsl ==0.13.0.0` to `cabal.project`'s
  constraints block" and then to run `cabal run keiro-dsl -- --help`. A `constraints:` row alone
  cannot do that. Constraints only bound versions the solver may pick for packages the project
  already depends on; `keiro-dsl` is a build-time toolchain that no shikigami component links
  against, so nothing would pull it in and `cabal run keiro-dsl` would fail with an unknown
  target. `extra-packages: keiro-dsl` is Cabal's supported spelling for exactly this case — it
  tells the solver to treat a package from the Hackage index as if it were a local project
  package, so its executable becomes a `cabal run`/`cabal build` target. The constraints row is
  kept as well, so the version is pinned in the same block as the rest of the cohort and a drift
  between `docs/dependency-cohort.md` and the solver stays a one-line diff. This keeps the plan's
  actual requirement — "`cabal run keiro-dsl` is reproducible in CI and does not depend on a
  developer's `PATH` or on the Keiro checkout" (Concrete Steps) — and satisfies it more directly
  than the house pattern at `mori://shinzui/keiro-runtime-patterns/docs/architecture-spec-and-scaffolding`,
  which observes that danwa runs the CLI out of a keiro checkout "because the executable is not
  installed globally". Verified: `cabal build keiro-dsl` resolves `keiro-dsl-0.13.0.0` against the
  already-pinned `keiro-core-0.13.0.0` and `keiki-0.9.0.0` with no `allow-newer`.

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

- Decision (2026-08-18, revised same day): **Gate CI with `--deny-warnings`, keeping an explicit
  `--deny CODE` list as a documented fallback.** This replaces an earlier same-day decision to
  prefer the explicit list, and supersedes the 2026-08-10 entry that first proposed it.
  Rationale: the fleet standard at
  `mori://shinzui/keiro-runtime-patterns/docs/keiro-dsl-adoption` is explicit — "`--deny-warnings`
  exits non-zero when any warning-severity diagnostic fires. Prefer it," with `--deny CODE` named
  as "the selective fallback when one idiomatic spelling warns by design," typically the router
  and process benign-inversion spellings. The earlier reasoning was that a `keiro-dsl` upgrade
  could then fail the build on a code that did not exist when the gate was written; that is
  factually right — 0.12 did append a batch of `DiagnosticCode` cases — but it is an argument
  *for* the blanket gate, not against it. A new warning on a tool upgrade is a real finding about
  this specification, and the whole reason `--deny-warnings` exists is that "until 0.11 nothing
  stopped a repository from accumulating them". Choosing the selective list up front would be
  pre-committing to ignore findings that have not been written yet. Take the fallback only when a
  green specification genuinely cannot pass `--deny-warnings`, and record which warning forced it.

- Decision (2026-08-18): **Scaffold with `--runtime-package shikigami-core` and delete the
  hand-written-harness item from Milestone 3.**
  Rationale: keiro-dsl 0.12+ generates one runnable conformance package per service, including its
  Cabal stanza and driver, and prints the exact `cabal test` target. Hand-writing the equivalent
  would be maintaining a copy of a generated artifact, and the generated one additionally runs the
  context `StructuralConformance` checks under a `structural/` prefix and compares process, router,
  and workflow facts against the create-once `KeiroConformance.Expectations` module. The package
  name is explicit because a service named `shikigami` is implemented by a library named
  `shikigami-core`.

- Decision (2026-08-18, revised same day): **Split the specification across
  `.keiro-workspace` members from the start.** This replaces an earlier same-day decision to
  begin with a single `domain/shikigami.keiro`; that decision is withdrawn, and its reasoning is
  recorded below as wrong rather than merely superseded, because the mistake is instructive.
  Rationale: the withdrawn entry weighed "one file is simpler" against "splitting later is
  supported", and both halves were weak. Splitting later is *not* free — adopting a workspace
  over attributable standalone history runs keiro's `WorkspaceAdoption` path, which writes a
  one-time `keiro-dsl-migration-report.workspace.<service>.txt` for human review and a
  `superseded-by:` marker into scaffold history. More importantly, the entry treated member
  boundaries as a filing convention when they are a **checked ownership mechanism**: a workspace
  gives every shared declaration and every node exactly one owning member, enforced by
  `WorkspaceDuplicateDeclaration` and `WorkspaceDuplicateNodeName`, with an `OwnershipIndex`
  attributing each node to its member. Shikigami has a live instance of exactly the failure that
  mechanism prevents — `Shikigami.Flow.SinkOutbox` carries a hand-maintained copy of
  `Agent/Workflow.hs`'s `SinkIntent` whose only guard is a comment reading "must match ...
  exactly" (`Flow/SinkOutbox.hs:40,65`). Mechanizing that is this plan's whole purpose, and the
  single-file choice would have thrown the mechanism away. Finally, Milestone 4 hands this
  specification to seven downstream plans (24, 25, 26, 27, 35, 50, 51) that edit it
  concurrently; one file gives them one merge surface and no ownership boundary, while members
  align with plan ownership almost exactly. The costs named in the withdrawn entry are real and
  small: an eight-line manifest, one `language` line per member, workspace-keyed sidecar names,
  and a composed-refusal mode that still writes a check report (with `"language": null`).

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
and awakeables. There is no `domain/` specification at all and no DSL check, scaffold, harness,
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

### Split the specification into workspace members

The specification is a **workspace**, not a single file: a `domain/shikigami.keiro-workspace`
manifest plus one `.keiro` member per review boundary. Author it that way from the first commit,
so the workspace never has to be adopted over standalone history later.

The manifest is short, and it — not the CLI, and not the members — is the authority on placement:

```text
service shikigami
runtime-package shikigami-core
module Shikigami
layout collocated
spec shikigami-agent-run.keiro
spec shikigami-conversation.keiro
spec shikigami-flow.keiro
spec shikigami-integration.keiro
spec shikigami-shared.keiro
spec shikigami-sink.keiro
```

(Alphabetical, matching the canonical path order composition uses anyway. The member list is the
*starting proposal* argued below, not a settled split — Milestone 1 derives it from the
inventory.)

Mechanics that follow from that, and that Milestone 1 must respect:

- Every member is a **complete, independently parseable source** beginning with `language
  keiro-dsl 5` and declaring the same `context`. The manifest itself has no language preamble.
- Every member must select the **same effective language version**. Composition compares versions
  *before* merging the graph and refuses a disagreement with `WorkspaceLanguageVersionMismatch`,
  so a language move is one change across the whole workspace, never a per-member migration.
- `module` and `layout` are **workspace authority**: a member clause must be absent or exactly
  equal. Declare them once in the manifest and stop passing `--module-root`/`--collocate`.
- `runtime-package` belongs in the manifest too; `scaffold --runtime-package` exists to override
  it, not to supply it.
- `spec` paths are manifest-relative `.keiro` paths with no absolute or `..` segments, no nested
  manifests, no duplicates, and no case-fold collisions. Membership is a **set**, canonically
  sorted by normalized path, so reordering `spec` lines changes neither meaning nor generated
  bytes — keep them alphabetical and never argue about order in review.
- `context shikigami` already supplies `Shikigami` as the default Haskell module root; the
  `module` clause is stated anyway so placement is explicit rather than derived.
- Every file-taking command accepts the manifest and validates the **composed** service before
  acting, so `check`, `diff`, `scaffold`, `inspect`, and `behavior-obligations` all take
  `domain/shikigami.keiro-workspace`. `inspect` lists every member in canonical path order.
- Member count does **not** change conformance-package count. One service gets one package.

**The reason to split is ownership, not file size.** A workspace gives every shared declaration
and every node exactly one owning member, enforced by `WorkspaceDuplicateDeclaration` ("a shared
declaration has exactly one owning member; identical duplicates do not merge") and
`WorkspaceDuplicateNodeName`, with an `OwnershipIndex` attributing each node to the member that
owns it. Shikigami already has the failure this prevents: `Shikigami.Flow.SinkOutbox` keeps a
hand-maintained copy of `Agent/Workflow.hs`'s `SinkIntent`, guarded by nothing but a comment
reading "The flow path's copy" and "Must match ... exactly" (`Flow/SinkOutbox.hs:40,65`). One
owning member turns that comment into a checked error. A single-file specification would have
had no such mechanism to offer.

The second reason is concurrent editing. Milestone 4 hands this specification to seven downstream
plans that each add to it — a single file gives them one merge surface and no boundary of
responsibility.

**The house criterion is the review boundary, and the unit is the aggregate.** Per
`mori://shinzui/keiro-runtime-patterns/docs/keiro-service-workspaces`: keep a small, densely
connected service in one file, and use a workspace when complete aggregates need separate review
ownership, the repository already keeps one aggregate per file, or several same-context specs
would otherwise scaffold into the same output tree. Two hard rules follow — **an aggregate is
never split across members**, and shared IDs, enums, rules, and mapped declarations have exactly
one owning member in a clearly named shared file.

Shikigami satisfies the criterion, though it is worth being precise about how, because the
obvious reading overstates it. Shikigami has **one** aggregate today — the at-risk-customer
lifecycle (`Flow/Lifecycle/AtRiskCustomer.hs`) — so the aggregate-per-file trigger is thin right
now. What carries the decision is the other half: `docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md`
adds a second aggregate under a different MasterPlan with different reviewers, and Milestone 4
hands this specification to seven plans (24, 25, 26, 27, 35, 50, 51) that edit it concurrently.
Those are separate review boundaries by any reading.

**Derive the split from the Milestone 1 inventory, and do not over-split up front.** Splitting
later is cheap and explicitly supported: moving a declaration or aggregate between members emits
the advisory `OwnershipMoved` and requires a whole-workspace rescaffold — it is *not* wire
evolution and creates no new identity. So the failure mode to avoid is inventing thin members for
symmetry, not under-splitting. The starting proposal below is grounded in the current tree and in
the plans that will edit each member; collapse any member the inventory shows to be thin, and
record the final split in the Decision Log.

| Member | Owns | Downstream editors |
| --- | --- | --- |
| `shikigami-shared.keiro` | IDs, enums, rules, and mapped declarations more than one member needs — agent name, session ref, run/workflow ids, trigger kind, sink kind | — |
| `shikigami-agent-run.keiro` | The `shikigami.agent-run` workflow, its journaled steps, and the `shikigami_run_jobs` queue that feeds it | 24, 27, 50 |
| `shikigami-conversation.keiro` | The `shikigami.danwa-conversation` workflow, its steps, and the approval/idle timers and awakeables | 25, 26 |
| `shikigami-sink.keiro` | Sink intents and the outbox contract/emit/publisher nodes — **the owner of `SinkIntent`** | 19, 27 |
| `shikigami-integration.keiro` | Kafka intake, inbox dedupe and disposition policy, the Danwa integration contract | 18, 20 |
| `shikigami-flow.keiro` | The at-risk-customer aggregate, whole and unsplit (`classify`, `await-ack`) | 25 |

Delegation is deliberately **not** a member of its own in this proposal: its topology is child
workflows of `shikigami.agent-run` and fields on the run contract, so it belongs with the
agent-run member unless Milestone 1's inventory shows otherwise. Plan 51's run-evidence aggregate
gets its own member when it lands — a new aggregate is a new review boundary, which is exactly the
criterion above.

Two further mechanics to respect: **never scaffold same-context members independently** — each
invocation would see a partial graph and overwrite context-keyed history — and golden payloads are
**aggregate-keyed**, so consolidate them under one workspace root and never let an ownership move
relocate an aggregate's historical fixtures.

### The CI gate, concretely

The gate is `check` with a language floor, a blanket warning denial, and two reports:

```bash
keiro-dsl check domain/shikigami.keiro-workspace \
  --min-language 5 \
  --deny-warnings \
  --report-out build/keiro-check-report.json \
  --coverage-report build/keiro-coverage.json \
  --fail-on-opaque
```

`--min-language 5` fails any member whose *effective* version is below 5, with the stable code
`LanguageVersionBelowMinimum`. Raise the floor in the same change that adopts the version, never
afterwards.

The warning codes `check` can emit at 0.13 are below. Under `--deny-warnings` this is not a list
to choose from — it is the inventory of what the gate catches, and every row is a finding to fix
or to justify in the specification. It matters only if a green specification cannot pass the
blanket gate, in which case one of these fired by design and the `--deny CODE` fallback names
everything except it:

| Class | Codes |
| --- | --- |
| Depend on operational history; deny once the fleet fact is established | `DeprecatedEventReplayHazard`, `EventRetirementInProgress`, `ReplayOnlyCommandStillLive` |
| Deliberate or currently accepted policy | `WqUnloggedDurability`, `ProcessBenignInversion`, `RouterBenignInversion`, `AmbiguousFollowsRejectedPolicy`, `PolicyDeadLetterUnused` |
| Accepted but inert declarations | `IntakeBindFlagUnenforced`, `RmInlineSubscriptionIgnored` |
| Internally decidable; future-language error candidates | `WireSchemaVersionMismatch`, `RmProjectionWithoutNode` |
| Structural coverage; requires `--coverage-report` in the same invocation | `CoverageOpaqueSurface` |

Two mechanical facts make the fallback safe if it is ever needed. A `--deny CODE` naming a code
`check` cannot emit — a cross-revision `diff` code, or a coverage code without `--coverage-report`
— is an immediate CLI error, so a stale list is loud rather than silently matching nothing. And
`--fail-on-opaque` raises `CoverageOpaqueGateExceeded` as an *error*, so denying that code can
never match; pass the flag instead.

Two rows deserve attention rather than denial. The **inert-declaration** warnings
(`IntakeBindFlagUnenforced`, `RmInlineSubscriptionIgnored`) each name a declaration a reader would
reasonably expect to have an effect and which has none — delete it, or replace it with the surface
that does the work, rather than gating it. Separately, `check` and `scaffold` write a **stderr
contract notice** for any source whose effective contract is not stable; authoring at language 5
removes that notice rather than adding one. The notice is not a diagnostic, so automation must
branch on `DiagnosticCode` — which derives `Ord`, `Enum`, and `Bounded` at 0.13, so the full set
can be enumerated rather than hardcoded — never on rendered text.

The evolution gate is `diff`, whose default gate covers every surface except
`old-binary-read-new-events`. It reconstructs the old manifest *and* its old member set from Git,
emitting one compatibility stream, one coverage report, and one replay-impact verdict for the
whole service; a shared-declaration change is classified at every use site, citing both the owning
member and the consuming member. Two workspace-specific advisories to expect and act on:
`OwnershipMoved` when a declaration or aggregate changes member, and `WorkspaceAuthorityChanged`
when `service`, `context`, `module`, or `layout` changes. Neither is wire evolution; both require
a whole-workspace rescaffold.

```bash
keiro-dsl diff domain/shikigami.keiro-workspace --since <merge-base> --explain \
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

Once the inventory exists, derive the member split from it and author
`domain/shikigami.keiro-workspace` plus its members, each beginning with `language keiro-dsl 5`
and declaring the same `context`. Use the exact deployed names except where a rename is recorded.
Put mechanically checkable cross-node contracts in the specification instead of retyping them in
Haskell; in particular, give `SinkIntent` one owning member and delete
`Shikigami.Flow.SinkOutbox`'s hand-maintained copy, whose only current guard is a comment. Keep
opaque business decisions and environment-specific transport configuration in typed holes. Run
`keiro-dsl parse`, then `check --emit --explain-bindings`, then `inspect --format=json` to
confirm every member reports `languageSupport: "stable"` at language 5 in canonical path order.
Acceptance is a checked composed specification with no unrecorded renames and no new behavior.

Milestone 2 scaffolds into `shikigami-core/src` using the collocated vertical layout chosen
by plan 36. Always run `check` before `scaffold`. `module Shikigami` and `layout collocated` live
in the manifest, which is workspace authority over both — do not pass `--module-root` or
`--collocate` on the command line, and do not repeat the clauses in members, where they must be
absent or exactly equal. Generated modules carry the
generated banner and may be overwritten; create-once holes remain hand-owned. Reconcile existing
modules by moving behavior into the corresponding `Holes`, `BehaviorHoles`, `ReadModel`,
integration, or workflow module while retaining compatibility re-exports during the transition.
Never edit a generated file to match old code. Paste the emitted
`keiro-dsl-cabal-fragment.workspace.shikigami.txt` blocks into `shikigami-core.cabal` and commit
`keiro-dsl-ledger.workspace.shikigami.txt` unedited. Adopt one member at a time: a workspace
composes on every command, so an unfinished member is a composed-refusal for the whole service —
add members in dependency order, starting with `shikigami-shared.keiro`. Run
`behavior-obligations --format=text` and
fill every live, rejection, and replay witness with a real history, command, expected event, or
expected rejection — a `Pending` row fails the conformance target and must not be left as a
default. Run the generated conformance target and firewall checks after each slice. Delete stale
paths only after reviewing whether each is generated or hand-owned; scaffold reports stale paths
and never deletes them.

Milestone 3 creates the test gates. The manifest's `runtime-package shikigami-core` makes
keiro-dsl generate the runnable conformance package at
`shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/`; add its stable glob to
`cabal.project` (`optional-packages:
shikigami-core/src/keiro-dsl-conformance.workspace.*/*.cabal`) and make `cabal test
keiro-shikigami-conformance` a CI step — the exact target name is printed by the scaffold run.
The glob is stable across member and node changes, which is the point of naming the package after
the service rather than a context.
Review and commit the create-once `KeiroConformance.Expectations` module; a later fact change
fails the target until a human accepts it. Add the `check` gate with `--min-language 5`, the
explicit `--deny` list, `--report-out`, and `--coverage-report --fail-on-opaque`. Add an
integration-contract test for wire codecs and disposition completeness that the generated
harness does not already cover. Add a CI command running `keiro-dsl diff
domain/shikigami.keiro-workspace --since <merge-base> --explain --report-out <path>` for
persisted-contract changes. A workflow or
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
cabal run keiro-dsl -- parse domain/shikigami.keiro-workspace
cabal run keiro-dsl -- check domain/shikigami.keiro-workspace --emit --explain-bindings
cabal run keiro-dsl -- inspect domain/shikigami.keiro-workspace --format=json
cabal run keiro-dsl -- behavior-obligations domain/shikigami.keiro-workspace --format=text
cabal run keiro-dsl -- scaffold domain/shikigami.keiro-workspace \
  --out shikigami-core/src \
  --goldens shikigami-core/test/golden-payloads
cabal test all
```

`--module-root`, `--collocate`, and `--runtime-package` are deliberately absent: the manifest
declares `module`, `layout`, and `runtime-package`, and those CLI flags exist to override a
manifest, not to supply one. Passing them here would move committed placement facts into a
command someone will eventually forget.

The scaffold run prints the exact generated conformance `cabal test` target; use that, not a
hand-written harness stanza.

The CI gate:

```bash
cabal run -v0 keiro-dsl -- check domain/shikigami.keiro-workspace \
  --min-language 5 \
  --deny-warnings \
  --report-out build/keiro-check-report.json \
  --coverage-report build/keiro-coverage.json \
  --fail-on-opaque
cabal run -v0 keiro-dsl -- inspect domain/shikigami.keiro-workspace --format=json
```

The `inspect` call is part of the gate, not a convenience: assert that every member reports
`sourceForm: "declared"` at effective version 5. A member that loses its preamble silently falls
back to legacy version 1, and composition would then fail with `WorkspaceLanguageVersionMismatch`
rather than naming the real cause.

If a green specification cannot pass `--deny-warnings`, one warning fired by design — process or
router benign inversion are the usual reasons. Only then fall back to an explicit `--deny CODE`
list naming every code except that one, and record in the Decision Log which warning forced it
and why the spelling is correct.

Before a persisted-contract change:

```bash
cabal run keiro-dsl -- diff domain/shikigami.keiro-workspace --since HEAD^ --explain \
  --report-out build/keiro-diff.json \
  --replay-impact-out build/replay-impact.json
```

The output must classify the change across the six compatibility surfaces and exit non-zero for
an incompatible evolution under the default gate set that has not been resolved by an explicit
supported strategy. `diff` reconstructs the old workspace — manifest and every member — from Git,
so run it from inside the repository containing the source, because `--since` uses `git show`.


## Validation and Acceptance

Acceptance requires the checked composed workspace at language 5, a deterministic scaffold, a
green generated conformance package, and the full suite passing. A deliberate invalid
cross-reference fails `check`, including one that crosses members, and is reported at the
original member path, line, and column. A declaration duplicated across two members fails
`WorkspaceDuplicateDeclaration` even when the two copies are identical — which is the acceptance
test for retiring `Flow/SinkOutbox`'s `SinkIntent` copy, and should be exercised deliberately
once. A member whose preamble disagrees with its siblings fails composition with
`WorkspaceLanguageVersionMismatch` *before* the graph merges, so that is the failure to expect
from a stray preamble, not `LanguageVersionBelowMinimum`. A manual edit to a
generated module fails deterministic-output or firewall validation. A deliberate incompatible
rename fails `diff --since`. A `Pending` behavior witness fails the generated conformance target.
A newly introduced opaque boundary on a private persisted root fails `--fail-on-opaque`.

Determinism is testable directly: scaffolding an unchanged specification twice must report every
generated module `unchanged` and skip `KeiroConformance.Expectations` as `already present`. A
second run that rewrites bytes is a defect to investigate, not noise. Membership order is
testable the same way — reordering the manifest's `spec` lines must produce byte-identical
generated output, because membership is a set sorted by normalized path.

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
behavior witnesses, and `KeiroConformance.Expectations`. A workspace composes on every command,
so a half-written member fails the whole service rather than silently scaffolding a subset —
that is the safe direction, but it means members are added in dependency order and each addition
is its own green commit. Commit or stash work before reviewing
stale paths; scaffold reports stale paths and never deletes them, so review each against version
control or a fresh disposable scaffold before removing it. Never use `--force-generated-overwrite`
until the target is positively identified as disposable generated output; it bypasses only the
missing-banner protection and cannot overwrite create-once hand code or authorize a name
migration. `--apply-name-migrations` should never be needed by a specification authored fresh at
0.13; if scaffold demands it, something older is present and must be understood before the flag is
passed. Likewise `keiro-dsl-migration-report.workspace.shikigami.txt` should never appear: it is
written when a workspace adopts attributable standalone history, and authoring as a workspace from
the first commit means there is none. If it appears, a standalone scaffold happened somewhere and
must be understood before proceeding. Adopt one vertical at a time with compatibility re-exports
so the suite stays green. Persisted identifiers are never renamed as cleanup — only as a recorded
Milestone 1 decision.


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

The owned source of truth is the `domain/shikigami.keiro-workspace` manifest and its `.keiro`
members; generated modules live beside hand-owned concept holes under
`shikigami-core/src/Shikigami/<Concept>`, and the generated conformance package under
`shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/` is reached by a stable
`optional-packages` glob in `cabal.project`. Commit the machine-owned
`keiro-dsl-ledger.workspace.shikigami.txt` and `keiro-dsl-conformance-ledger.txt`; never edit
them.

This plan hard-depends on `docs/plans/53-upgrade-shikigami-to-the-keiro-0-11-and-keiki-0-9-cohort.md`
(complete) and on `docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`
(complete), and hard-precedes plans 24–27, 50, 51, and cross-MasterPlan plan 35. It does not
replace Keiro runtime `patch`/`continueAsNew`; it supplies the structural and evolution gate those
runtime mechanisms cannot infer from hand-written code.

Upstream reference material comes from two repositories, and they answer different questions.

For the **grammar and the CLI**, `mori://shinzui/keiro`: the language reference at
`docs/user/typed-spec-toolchain.md`, the adoption argument at
`docs/guides/choosing-keiro-dsl.md`, and the boundary between generated and hand-written services
at `docs/guides/dsl-guarantees-and-hand-written-services.md`.

For **how this fleet uses it** — which is where this plan's workspace, CI, and layout choices come
from — `mori://shinzui/keiro-runtime-patterns`. These are house standards, not suggestions;
diverge from one only with a Decision Log entry saying why:

- `mori://shinzui/keiro-runtime-patterns/docs/keiro-service-workspaces` — the member split, the
  aggregate-never-split rule, single-owner shared declarations, workspace-keyed history, and the
  `OwnershipMoved`/`WorkspaceAuthorityChanged` diff classes.
- `mori://shinzui/keiro-runtime-patterns/docs/keiro-dsl-adoption` — the adoption rule, the eight
  runtime hole kinds, the firewall and its single exemption, and the `--deny-warnings` CI standard.
- `mori://shinzui/keiro-runtime-patterns/docs/keiro-language-versions` — the version registry, what
  4 and 5 each add, `WorkspaceLanguageVersionMismatch`, and the six-step version-adoption sequence.
- `mori://shinzui/keiro-runtime-patterns/docs/architecture-spec-and-scaffolding` — spec placement
  at the repository root and the check/scaffold/format/test loop.
- `mori://shinzui/keiro-runtime-patterns/docs/architecture-vertical-slice-modules` — the
  one-namespace-per-concept rule that plan 36's collocated layout implements.
- `mori://shinzui/keiro-runtime-patterns/docs/keiro-dsl-semantic-locality` — establishing the
  generated baseline once and reading semantic impact separately from changed bytes.
- `mori://shinzui/keiro-runtime-patterns/docs/keiro-behavior-conformance` — filling the create-once
  behavior witnesses Milestone 2 owns.
- `mori://shinzui/keiro-runtime-patterns/docs/keiro-evolution-and-rollout` — the operator
  obligation behind each advisory `diff` finding.
- `mori://shinzui/keiro-runtime-patterns/docs/keiro-mapped-consumer-surfaces` — required reading
  before describing `shikigami_run_jobs` as a mapped Language 5 workqueue payload, because a green
  aggregate harness is *not* evidence that an old queued payload is compatible.


Revision note (2026-08-18b): Split the specification into a `.keiro-workspace`, and reversed two
decisions taken earlier the same day after reading the fleet patterns at
`mori://shinzui/keiro-runtime-patterns`. Both reversals are recorded in the Decision Log with the
withdrawn reasoning kept, because in both cases the earlier argument was not merely superseded by
new information — it was wrong on the evidence already available.

**The specification is now a workspace, not a single file.** The withdrawn decision weighed "one
file is simpler" against "splitting later is supported" and got both halves wrong. Splitting later
runs keiro's `WorkspaceAdoption` path with a one-time migration report and a `superseded-by:`
marker, and — far more important — member boundaries are not a filing convention but a *checked
ownership mechanism*: `WorkspaceDuplicateDeclaration` refuses even textually identical duplicates.
Shikigami has a live instance of exactly what that prevents, in `Flow/SinkOutbox.hs`'s
hand-maintained copy of `SinkIntent` guarded by a comment reading "must match ... exactly".
Mechanizing that is this plan's purpose. The member split, the manifest, the composition rules,
and the workspace-keyed sidecars are written through Context, Plan of Work, Concrete Steps,
Validation, Idempotence, and Interfaces.

The house patterns then corrected the split itself. The first draft organized members by vertical;
`mori://shinzui/keiro-runtime-patterns/docs/keiro-service-workspaces` makes the criterion the
*review boundary* with the *aggregate* as the unit, and forbids splitting an aggregate across
members. That is now stated honestly: shikigami has one aggregate today, so what carries the
decision is plan 51's second aggregate plus seven concurrently editing downstream plans — not an
aggregate-per-file situation that does not yet exist. The delegation member was dropped into
agent-run for the same reason, and the plan now warns against inventing thin members, noting that
a later split is an advisory `OwnershipMoved` requiring a rescaffold rather than wire evolution.

**CI now gates with `--deny-warnings`, not an explicit `--deny CODE` list.** The withdrawn
decision — inherited from 2026-08-10 — argued that a blanket denial turns a `keiro-dsl` upgrade
into a build failure on a code that did not exist when the gate was written. That is factually
true and is an argument *for* the blanket gate: a new warning is a real finding about this
specification, and pre-committing to a fixed list is pre-committing to ignore findings not yet
written. The fleet standard says "prefer it", with `--deny CODE` as the fallback for a spelling
that warns by design. The warning-code table is retained, reframed as the inventory of what the
gate catches rather than a menu.

Smaller corrections from the same reading: member language versions are compared *before* graph
composition and disagree with `WorkspaceLanguageVersionMismatch` (not `--min-language`), which
Validation had wrong; `--min-language` failures carry `LanguageVersionBelowMinimum`; `inspect
--format=json` is now a CI assertion that every member is `declared`; `diff` gains the
`OwnershipMoved` and `WorkspaceAuthorityChanged` advisories; members must never be scaffolded
independently; goldens are aggregate-keyed and must not follow an ownership move; and automation
branches on `DiagnosticCode`, never on the stderr contract notice or other rendered text. The
Interfaces section now cites the nine relevant patterns by `mori://` URI and states that they are
house standards a divergence must be justified against.

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
