---
id: 25
slug: replay-safe-flow-memory-capabilities
title: "Replay-safe flow memory capabilities"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tytnwe53rdd4es99ztv1p"
master_plan: "docs/masterplans/5-durable-evolution-versioning-and-replay-safety-for-long-lived-workflows.md"
---

# Replay-safe flow memory capabilities

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami flows — agent behaviors written in this repository's Haskell Flow DSL — can
`remember` a learning into kioku's durable memory store and `recall` prior learnings. A flow
runs inside a durable keiro workflow, which may suspend (park waiting for a human
acknowledgement) and later replay its journaled steps. But the flow `Memory` capability's
interpreter performs raw IO instead of journaled workflow steps. Every replay that passes a
`remember` call mints a fresh memory id and writes a duplicate memory row, and every replay
re-executes `recall` against the live store, so a flow that branches on what it recalled can
take a different branch on replay than it took originally — the exact nondeterminism durable
workflows exist to prevent. The non-flow agent-run path already does this correctly (its recall
and record are journaled steps with a crash-resume dedup test); the flow path silently is not.

After this plan, a flow's `remember` and `recall` are journaled keiro steps with stable,
caller-supplied labels. A replayed flow returns the recorded recall results without touching the
store, and a replayed remember is idempotent twice over: the step journal short-circuits it, and
even a crash inside the step window re-writes the *same* deterministic memory id, which kioku
answers as an idempotent success rather than a second row. Those labels are declared in the
checked keiro-dsl specification and gated by `just keiro-gate`, so they are the first flow-side
journal names this service can actually gate — unlike the `emit-signal:<label>` family, which is
stable but undeclarable. Flow authors also gain control over the memory metadata that is
currently hardcoded on every write (priority, confidence, memory type, supersedes), and lose
ambient `IOE`/`Store` access inside flow bodies so the only way a flow can touch the world is
through replay-safe capabilities. A test that fails today — replaying a completed flow
duplicates its memory — passes after the change.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-19) Prerequisites cleared. Plans 24, 36, 39, 47, and 53 have all landed; the
      cohort is keiro 0.13.0.0 / keiro-dsl 0.13.0.0 (language 5) / kioku 0.4.1.0. Verified
      against `cabal.project` and `docs/dependency-cohort.md`.
- [x] (2026-08-19) Plan reconciled against the delivered tree: see the Revision Note of
      2026-08-19 and the Surprises entries it points at. No runtime code written yet.
- [x] (2026-08-19) M1: Failing test added — "replaying a completed flow does not duplicate its
      memory" in `shikigami-core/test/Shikigami/FlowLifecycleSpec.hs`, with the
      `acknowledgedMemoryCount` / `isAcknowledgedNote` helpers it needs. Run red against the
      unmodified interpreter; transcript captured in Surprises & Discoveries. Not committed
      alone (this tasty suite has no expected-failure idiom); it lands with M2.
- [x] (2026-08-19) M2: Declared `recall-risk-history`, `remember-acknowledged`,
      `remember-declined`, and `remember-escalated` in `domain/shikigami-agent-run.keiro`,
      regenerated (`shikigami-core/src/Shikigami/AgentRun/Generated/WorkflowFacts.hs` and
      `shikigami-core/src/keiro-dsl-ledger.workspace.shikigami.txt`), and hand-accepted the
      `workflow/AgentRun/body` fact in
      `shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/src/KeiroConformance/Expectations.hs`.
- [x] (2026-08-19) M2: Labeled `Memory` effect — `Recall` carries a `Text` label, `Remember`
      carries a label and `RememberOptions`; `runMemory` journals both under
      `recall-<label>` / `remember-<label>` with constraint `(Workflow :> es, IOE :> es)`;
      `deterministicFlowMemoryId` and `recordFlowMemory` added; call sites in
      `Shikigami/Flow/AtRiskCustomer.hs` and the spec's `memoryFlow` labeled. M1 test green,
      and it now also asserts both labels are in the step index.
- [x] (2026-08-19) M2: Crash-window idempotency test green in both directions — "one
      deterministic id records idempotently and refuses a changed payload".
- [x] (2026-08-19) M2: `docs/workflow-versioning.md` updated — the journal inventory gains
      `recall-<label>` / `remember-<label>` marked `declared`, and the "Undeclarable label
      families" section records why memory labels are deliberately declarable.
- [x] (2026-08-19) M2: The four labels moved inside a new
      `patch shikigami-flow-memory-steps-v1` block, and `runMemory` now reads that guard once
      per interpreted run and branches. Forced by `keiro-dsl diff`, which classifies any
      unguarded change to a declared body as BREAKING; see Surprises & Discoveries and the
      Decision Log entry that supersedes the earlier "no patch guard is needed" decision.
- [x] (2026-08-19) M2: `just keiro-gate 860b680` green — `ADDITIVE: AgentRun workflow-patch
      shikigami-flow-memory-steps-v1`, `replay-neutral`, exit 0. `cabal test all` green (311
      tests in `shikigami-core-test`). Negative check performed and reverted: deleting
      `step remember-declined` from the specification makes `keiro-diff` fail BREAKING.
- [x] (2026-08-19) M3: `Acknowledgement` capability added in
      `shikigami-core/src/Shikigami/Flow/Acknowledgement.hs`; `IOE` and `Store` removed from
      `FlowEffects`; `FlowRuntime` is now the `runAcknowledgement` environment;
      `FlowRegistration` deleted and `flowRegistry :: [FlowDef]` is the single list with
      `registeredFlowNames` projecting from it; `lookupFlow` loses its `FlowRuntime`.
      Consumers updated: `runFlowBehavior`, `Shikigami.Server.Command.RenderLifecycle` (a
      consumer the plan did not name — it minted a session id and a throwaway approval env
      purely to render a diagram, and now does not), `FlowLifecycleSpec`, and
      `WorkflowVersioningSpec`. `sleepFlow` carries its own
      `(Workflow :> es, Store :> es, IOE :> es)` and its own runner. Guardrail verified by
      attempt and reverted: a flow body with `liftIO` fails with
      `Could not deduce 'IOE :> es' arising from a use of 'liftIO' from the context:
      FlowEffects es`.
- [ ] M4: `rememberWith` exported, metadata threaded into `RecordMemoryData`, supersession
      spec green; defaults preserve today's values; docs updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**kioku already performs this plan's central trick, and proves it is sound.**
`Kioku.Distill.L1` derives a deterministic memory id for every extracted atom
(`kioku-core/src/Kioku/Distill/L1.hs:603-605`):

```haskell
l1AtomMemoryId :: SessionId -> Text -> MemoryId
l1AtomMemoryId sid content =
  KindID.decorateKindID (l1Uuid5 (idText sid <> ":" <> content))
```

It is *not* exported (`Kioku.Distill.L1`'s export list is `FindMergeCandidates`, `L1Error`,
`L1Outcome`, `L1RunMode`, `L1Summary`, `distillSessionL1`, `recallCandidates`,
`scopedScanCandidates`), so shikigami must still mint its own — but the pattern is kioku's own,
not an invention, and shikigami already uses the same shape for outbox ids
(`deterministicOutboxIdForMessage`, `shikigami-core/src/Shikigami/Agent/Workflow.hs:749-754`).

**kioku's record idempotency is conditional, and the condition is load-bearing.**
`Kioku.Memory.recordIn` (`kioku-core/src/Kioku/Memory.hs:180-189`) looks the id up first and,
when a row already exists, returns `idempotentOr "record" recordMismatch row mid` — a success
only if *every semantic field* agrees. `memoryRecordFields`
(`kioku-core/src/Kioku/Memory.hs:452-464`) compares `agentId`, `sessionId`, namespace, scope
kind, scope ref, `memoryType`, `content`, `priority`, `confidence`, `tags`, and `supersedes`. A
disagreement is `MemoryConflict`, not success. So "deterministic id ⇒ idempotent" is only true
when the whole payload is a pure function of replay-stable inputs. What saves the design is that
call-time timestamps are deliberately excluded, and kioku says why
(`kioku-core/src/Kioku/Memory.hs:398-408`): "Call-time timestamps (`recordedAt`, `supersededAt`,
`archivedAt`) are deliberately *not* compared. The id is the identity: a second write against the
same id with the same semantic payload is a retry, and retries re-read the clock." That is
precisely the crash-window regime this plan needs, and kioku cites `recordAtom` — which passes
`recordedAt = now` under a deterministic id — as the proof.

**The plan's original step-name scheme contradicted its own constraint.** The earlier Milestone 2
specified `StepName ("recall:" <> label)`. A keiro-dsl workflow label is a compile-time wire word
matching `[A-Za-z0-9][A-Za-z0-9_-]*`, so a colon cannot be declared and `just keiro-diff` cannot
gate it (`docs/workflow-versioning.md:441-459`). Following that scheme would have created a sixth
undeclarable label family in the same change that plan 39 spent a milestone censusing the
existing five. Resolved by using a hyphen; see the Decision Log.

**`mmzk-typeid` and `uuid` are already direct dependencies.** `shikigami-core.cabal:129` and
`:140` list both, and `Data.KindID` is already imported by
`shikigami-core/src/Shikigami/Sink/KawaClient.hs:19`. The earlier plan's instruction to add
`mmzk-typeid >=0.7` and re-resolve is now a no-op.

**kioku's write surface moved out from under the interpreter.** kioku 0.4 partitioned everything
by memory space and principal. `Kioku.Memory.record` now carries
`{-# DEPRECATED record "Use recordWithContext..." #-}` (`kioku-core/src/Kioku/Memory.hs:167`) and
is confined to `legacyMemorySpaceId`. Moving to `recordWithContext` is not a mechanical swap:
`underContext` (`kioku-core/src/Kioku/Memory.hs:133-143`) rejects a write whose
`actorPrincipal` differs from the context's own with `MemoryActorMismatch`, and shikigami's only
minted context — `shikigamiReadContext` in
`shikigami-core/src/Shikigami/Memory/Access.hs` — carries the *service* principal `shikigami`,
while memory writes record the *agent* principal `shikigami.agent.<name>`. See the Decision Log
for why that swap stays out of this plan.

**The red run reproduces the defect exactly as predicted, on the replay and not before.**
Against the unmodified `runMemory`, `cabal test shikigami-core-test --test-options='-p "duplicate
its memory"'`:

```text
shikigami
  FlowLifecycle
    replaying a completed flow does not duplicate its memory: FAIL
      Exception: user error (MigratedDatabaseCallbackFailed (HUnitFailure (...
      srcLocStartLine = 201 ...) "replay does not record the note a second time
      expected: 1
       but got: 2"))

1 out of 1 tests failed (1.46s)
```

The intermediate assertion at line 196 — "the acknowledged branch records its note once" —
passed, so the second row is written by the third invocation (the pure replay of an already
completed workflow) and by nothing earlier. That isolates the fault to the un-journaled
`Remember` rather than to the park-and-resume, and it is why the resume in the middle of the
test is kept: without it the replay would not be replaying an acknowledged branch at all.

**`keiro-dsl diff` rejects ANY unguarded change to a declared workflow body, appends included.**
This is the plan's largest wrong assumption, and it only surfaced at the gate.
`classifyWorkflowBody` (`keiro-dsl/src/Keiro/Dsl/Diff.hs:2905-2954`) has exactly two additive
escapes — a change wholly contained in a *new* patch guard, or a terminal `continueAsNew` append
— and falls through to `WorkflowBodyChanged` otherwise:

```haskell
safeAdditions =
  (not (null newPatchIds) || isJust appendedSeed)
    && comparableNewBody == oldBody
```

keiro-dsl's own suite pins the append case (`keiro-dsl/test/Main.hs:7642-7647`):

```text
it "classifies workflow relabeling and appends as WorkflowBodyChanged" $ do
  ...
  appended <- diffFixtures "test/fixtures/workflow.keiro" "test/fixtures/workflow-stepadd.keiro"
  [ckCode k | Breaking k <- appended] `shouldContain` [WorkflowBodyChanged]
```

The first attempt — four bare `step` lines beside `classify` — produced:

```text
BREAKING: AgentRun workflow-body AgentRun: workflow body labels, kinds, result types, or
order changed without a new patch guard; wrap a cross-cutting change in patch, or rename
the replay label for one changed step [WorkflowBodyChanged]
    vector: private-history-read=breaking old-binary-read-new-events=breaking
            snapshot-hydration=advisory rollout=stop-the-world
```

There is no waiver: `keiro-dsl diff`'s only policy flag is `--gate SURFACE`, which *adds*
failures. Note the irony in the same output — the differ's own replay verdict was
`replay-neutral: stored-data replay is unchanged by this diff`, which agrees with the plan's
runtime reasoning. The body rule is structural and conservative on purpose, and it does not
consult that verdict.

After wrapping the four steps in one patch block, the same command reports:

```text
ADDITIVE: AgentRun workflow-patch shikigami-flow-memory-steps-v1: new patch guard contains
the entire body change, so in-flight generations retain their journaled branch
replay-neutral: stored-data replay is unchanged by this diff
```

**Both existing steps in this body arrived the same way, which the plan half-noticed.** The plan
named commit `c159d80` as "the exact procedure M2 follows" and correctly described it as adding
"a patch block plus `step run-behavior-v2`" — then concluded three sections later that no patch
was needed. `resolve-profile` is likewise inside `patch shikigami-resolve-profile-v1`. Every step
ever added to `domain/shikigami-agent-run.keiro` has been patch-guarded; there was no precedent
for the unguarded append the plan assumed.

**Activating the patch needs no hand-edit.** `shikigamiActivePatches`
(`shikigami-core/src/Shikigami/Workflow/Versioning.hs`) is the union of each workflow's generated
`declaredPatches`, and `keiro-scaffold` rewrote that set from the specification
(`shikigami-core/src/Shikigami/AgentRun/Generated/WorkflowRuntime.hs:43`). Declaring the block was
the whole activation.

**One flaky failure, unrelated to this work.** A full `cabal test all` run reported
`GrantStore > runtime grant and revoke > revoking something never granted reports that it changed
nothing: FAIL`. It passed in isolation and passed on a re-run of the whole
`shikigami-core-test` suite (311 tests). It touches the runtime grant store, not flow memory, and
nothing in this plan goes near it. Recorded so a future reader does not attribute it here.


## Decision Log

Record every decision made while working on the plan.

- Decision: Flow memory step names use a hyphen, not a colon: `recall-<label>` and
  `remember-<label>`, and every label reachable from a *registered* flow is declared in
  `domain/shikigami-agent-run.keiro`.
  Rationale: a keiro-dsl workflow label must match `[A-Za-z0-9][A-Za-z0-9_-]*`, so `recall:x`
  cannot be declared and therefore cannot be gated by `just keiro-diff`
  (`docs/workflow-versioning.md:441-459`). The colon scheme would have added a sixth
  undeclarable family. A hyphen is the same intent spelled legally — the same fix
  `docs/workflow-versioning.md:271-272` already applies to patch ids, where
  `shikigami.emit-signal-labels-v1` fails to parse and `shikigami-emit-signal-labels-v1` does
  not. The cost is real and accepted: adding a `remember "foo"` call to a registered flow now
  also means adding `step remember-foo` to the specification, regenerating, and passing the
  gate. That is the discipline `docs/adr/0001-declare-only-what-the-runtime-executes.md` chose.
  Date: 2026-08-19

- Decision: Test-only flows in `shikigami-core/test/Shikigami/FlowLifecycleSpec.hs` do not need
  declared labels.
  Rationale: the specification declares the `shikigami.agent-run` workflow. The spec harness runs
  its flows under `WorkflowName "shikigami.flow.spike"`
  (`shikigami-core/test/Shikigami/FlowLifecycleSpec.hs:280`), which no member declares, so
  labels reachable only from `memoryFlow` and friends are outside the gate. Only labels
  reachable from a flow in `flowRegistrations` (`shikigami-core/src/Shikigami/Flow.hs:81-88`) —
  today just `at-risk-customer` — must be declared.
  Date: 2026-08-19

- Decision: This plan keeps calling `Kioku.Memory.record`, the deprecated legacy-space wrapper,
  and does not move the flow write path to `recordWithContext`.
  Rationale: `underContext` (`kioku-core/src/Kioku/Memory.hs:133-143`) requires the payload's
  `actorPrincipal` to equal the context's `memoryContextRecordedActor`. Flow memories are
  attributed to the agent (`agentActor (name decl)` → `shikigami.agent.<name>`), and shikigami
  mints only a service-actor context today. Supplying per-agent write contexts is a separate
  change with its own attribution decision, and `shikigami-core/src/Shikigami/Memory/Access.hs`
  already names its owner: IR-9,
  `docs/improvement-requests/key-agent-continuity-by-meibo-principal.md`. Doing it here would
  widen this plan's blast radius and duplicate that decision. The deprecation warning is
  tolerated meanwhile; the build does not treat it as an error.
  Date: 2026-08-19

- Decision: The deterministic id hashes UTF-8 bytes (`Data.Text.Encoding.encodeUtf8`), not
  `fromEnum` over `Char`s.
  Rationale: `deterministicOutboxIdForMessage`
  (`shikigami-core/src/Shikigami/Agent/Workflow.hs:749-754`) uses
  `fmap (fromIntegral . fromEnum) . Text.unpack`, which truncates any code point above 255. Its
  inputs are ASCII by construction so it is safe there, but a memory id is derived from a
  workflow *name* and *id*, and nothing in the type system keeps those ASCII. kioku's `l1Uuid5`
  (`kioku-core/src/Kioku/Distill/L1.hs:596-598`) uses `BS.unpack . TE.encodeUtf8` and is
  unconditionally correct at identical cost. Diverging from the in-tree neighbour is deliberate;
  note it in the code so a later reader does not "fix" the inconsistency backwards.
  Date: 2026-08-19

- Decision: `RememberOptions` lands in M2 with its defaults, and M4 only exposes `rememberWith`
  and threads the fields through. Superseding the earlier plan's offer of two orderings.
  Rationale: PLANS.md forbids outsourcing a decision to the reader, and writing the interpreter
  twice is the worse of the two options — the second write would land after the M1/M2 tests are
  green, which is exactly when a silent metadata regression is cheapest to introduce.
  Date: 2026-08-19

- Decision: SUPERSEDED — "No `patch` guard is needed for journaling `remember`/`recall` as
  steps." The original entry is preserved below because its reasoning is still correct about
  the runtime; it was wrong about the gate.
  Original rationale: the old interpreter journaled NOTHING for memory operations, so the change
  is purely additive step insertion — an in-flight flow resumed under the new code finds no
  journal entry for `remember-<label>`, runs it fresh (which the old code would also have done,
  minus the journaling), and proceeds. Per `docs/workflow-versioning.md` (plan 24), additive new
  step names are deploy-safe without a patch. The residual behavior change on
  replayed-but-already-completed instances (they stop re-writing memories) is the bug fix
  itself. Contrast `shikigami-emit-signal-labels-v1`, which *did* need a patch because it
  **renamed** an existing family rather than adding one.
  Date: 2026-07-08 (re-affirmed 2026-08-19 against the delivered plan 24; superseded the same
  day at the gate)

- Decision: The four memory labels are declared inside a new
  `patch shikigami-flow-memory-steps-v1` block, and `runMemory` reads that guard once per
  interpreted flow run and branches on it.
  Rationale: this plan asked for three things that cannot all hold — declare the labels, add no
  patch, and pass `just keiro-gate`. `keiro-dsl diff` classifies *any* change to a declared
  workflow body as BREAKING unless the whole change sits inside a new patch guard, appends
  included, and offers no waiver (`--gate` only adds failures). See Surprises & Discoveries for
  the code and the differ's own test. Any two of the three requirements are satisfiable; the
  choice was between dropping the declaration (memory labels join the ungated
  `emit-signal:<label>` family, abandoning this plan's "first gateable flow-side labels" goal)
  and adding the guard. The guard won: it is what both existing steps in this body did, and the
  declaration is the durable half of the plan's value.
  ADR-0001 (`docs/adr/0001-declare-only-what-the-runtime-executes.md`) then makes the runtime
  branch mandatory rather than optional — a declared guard that guards nothing is precisely the
  specification-describes-something-nobody-honours failure that ADR forbids. So the `False`
  branch is the genuine pre-change behavior: an un-journaled recall and a `genMemoryId` write.
  The cost is real and accepted: the code this plan exists to delete survives behind a guard,
  exactly as `runSink`'s ordinal branch does, and is deletable on the same terms once no
  pre-change flow can resume. Shikigami has no users, so that population is empty today.
  The block sits after `await-ack` rather than beside `classify` because a patch block must
  contain the entire change contiguously and the body is ordered for reading, not control flow.
  Decided with the user, 2026-08-19.
  Date: 2026-08-19

- Decision: Deterministic memory ids are minted in shikigami by decorating a UUIDv5 (over
  workflow name, id, generation, and step label) into kioku's `MemoryId` KindID, using the
  `mmzk-typeid` package directly, rather than adding a constructor to `Kioku.Id`.
  Rationale: `Kioku.Memory.record` is already idempotent by id under a matching payload
  (`kioku-core/src/Kioku/Memory.hs:180-189`), so no kioku change is required; `MemoryId` is a
  type alias for `KindID "kioku_memory"` (`kioku-api/src/Kioku/Id.hs:21`), and `mmzk-typeid`
  exposes `Data.KindID.V7.decorateKindID :: UUID -> KindID prefix` (used by kioku itself in
  `parseIdLenient`, `kioku-api/src/Kioku/Id.hs:64`, and in `l1AtomMemoryId`). The tradeoff — a
  v5 (name-based) UUID inside an id family that is normally UUIDv7 (time-ordered) — costs only
  time-sortability for these specific rows, which nothing in kioku depends on for correctness.
  kioku accepted the identical tradeoff for L1 atoms.
  Date: 2026-07-08 (evidence refreshed 2026-08-19)

- Decision: Remove BOTH `IOE` and `Store` from the flow-facing `FlowEffects` constraint, and
  introduce an `Acknowledgement` capability to replace direct `awaitAcknowledgement` calls
  (which require `Store`/`IOE`).
  Rationale: the task is to make unjournaled effects unreachable from flow bodies. Feasibility
  re-verified 2026-08-19 by reading `atRiskCustomerFlow`
  (`shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs:36-61`): it uses `currentActivity`
  (Activity), `recall`/`remember` (Memory), `step` with a pure body (Workflow), `emitSignal`
  (Sink), and `awaitAcknowledgement` (the only direct `Store`+`IOE` consumer). Wrapping
  acknowledgement as a capability removes the last direct dependency; `Workflow` stays in
  `FlowEffects` so flows can still name pure checkpoints with `step`, but without `IOE` a step
  body cannot `liftIO`. Documentation-plus-lint was rejected as unenforced.
  Date: 2026-07-08 (re-verified 2026-08-19)

- Decision: Extend metadata on the FLOW capability only; leave the non-flow `recordLearning`
  (`shikigami-core/src/Shikigami/Agent/Workflow.hs:784-806`) hardcoded.
  Rationale: the duplicate non-flow lifecycle is plan 27's consolidation target; changing it here
  would widen this plan's blast radius and race plan 27's refactor. Plan 27 is still open.
  Date: 2026-07-08 (re-checked 2026-08-19)

- Decision: Labeled memory steps must pass plan 39's gate — `just keiro-gate` — with the
  handwritten interpreter, rather than being justified by determinism alone.
  Rationale: deterministic ids do not protect against declaration/code step-name drift. The gate
  is `keiro-check`, `keiro-inspect`, `keiro-scaffold` + `git diff --exit-code`, `keiro-diff`, and
  `cabal test keiro-shikigami-conformance` (`justfile:175-182`).
  Date: 2026-07-22 (gate name corrected 2026-08-19)


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

All shikigami paths are relative to `/Users/shinzui/Keikaku/bokuno/shikigami`. kioku (the agent
memory and session library) lives at `/Users/shinzui/Keikaku/bokuno/kioku` (locate it with
`mori registry show kioku --full`); keiro (the durable workflow engine) lives at
`/Users/shinzui/Keikaku/bokuno/keiro`, library sources under its `keiro/` subdirectory. The
cohort this plan is written against is pinned in `cabal.project`: keiro, keiro-core, keiro-dsl,
keiro-migrations, and keiro-pgmq at `0.13.0.0`, kioku-api/-core/-migrations at `0.4.1.0`, keiki
at `0.9.0.0`. `docs/dependency-cohort.md` records the upstream tags.

Every plan this one depended on has landed:
`docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md` (the stable-label
convention, `docs/workflow-versioning.md`, and the one-options-value rule),
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md` (the checked
specification and `just keiro-gate`),
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`, and the
dependency upgrades `47` and `53`. Nothing here is blocked.

Two ADRs matter and are summarized where they bear on the work rather than left as links.
`docs/adr/0001-declare-only-what-the-runtime-executes.md` holds that the specification declares a
surface only when the generated artifact is the one the runtime actually executes — a
specification that describes something nobody honours makes the gate certify a lie. That is why
this plan declares *step labels* (which the runtime does write) and declares no schema for the
memory payload (which the runtime does not generate).
`docs/adr/0004-one-options-value-and-a-checked-patch-set.md` holds that patch activation flows
from the checked specification through `Shikigami.Workflow.Versioning` into a single
`WorkflowRunOptions`, and that no call site may build a second one. This plan adds no patch id,
so it adds nothing to that set — but it must not regress it either, which is why the specs run
through `shikigamiWorkflowRunOptions`.

### What a durable workflow does to an effect

A durable keiro workflow journals each `step (StepName n) action` result to Postgres; on replay,
a journaled name returns its recorded result WITHOUT running the action
(`keiro/src/Keiro/Workflow.hs:282`, and the module header's replay rules). Anything a workflow
body does OUTSIDE a `step` runs again on every replay. Replays happen when a suspended workflow
resumes, when a crashed run is retried, and when an already-completed workflow is re-invoked with
the same id — the body re-executes with every step hitting the journal. Therefore any effect with
an external footprint that is not wrapped in a step is executed an unpredictable number of times.

### The flow system as it exists today

A `FlowDef` (`shikigami-core/src/Shikigami/Flow.hs:44-48`) carries
`run :: forall es. FlowEffects es => Value -> Eff es Value`, where today
(`shikigami-core/src/Shikigami/Flow.hs:31`):

```haskell
type FlowEffects es = (Workflow :> es, Store :> es, IOE :> es, Memory :> es, Sink :> es, Activity :> es)
```

`Memory`, `Sink`, and `Activity` are effectful dynamic effects defined in
`shikigami-core/src/Shikigami/Flow/Capability.hs`. `Memory` is the defect
(`Capability.hs:70-72`):

```haskell
data Memory :: Effect where
  Recall :: MemoryQuery -> Memory m [MemoryRecord]
  Remember :: Value -> Memory m MemoryId
```

Its interpreter `runMemory` (`Capability.hs:108-152`) has constraint `(IOE :> es)` only. `Recall`
is `liftIO (recallPriorLearnings ...)` — a hybrid vector-plus-scan query against kioku
(`shikigami-core/src/Shikigami/Agent/Run.hs:208-238`) — and `Remember` is a `liftIO` block that
calls `genMemoryId` (a random, time-ordered id, `kioku-api/src/Kioku/Id.hs:25-26`),
`getCurrentTime`, and `MemoryStore.record` with hardcoded metadata: `memoryType = MemoryPattern`
(`Capability.hs:126`), `priority = 100` (`:128`), `confidence = MediumConfidence` (`:129`),
`tags = Set.fromList ["flow", focus]` (`:130`), `supersedes = Nothing` (`:131`). Neither
operation touches the workflow journal.

`Sink` is what the same module looks like *after* plan 24, and is the template to copy.
`EmitSignal` carries a caller-supplied `Text` label (`Capability.hs:77`, helper at `:102-103`),
`runSink` has constraint `(Workflow :> es, Store :> es, IOE :> es)` (`Capability.hs:164`), and it
journals each emission under a step name derived from that label. Read `emitSignal`'s haddock
(`Capability.hs:92-101`) for the exact meaning of "label": short, lowercase, unique among one
flow's emissions, and never derived from data that varies between a run and its replays.

Concretely, two things go wrong today:

- **Duplicate memories on replay.** `atRiskCustomerFlow` calls `remember` AFTER its
  acknowledgement park (`shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs:50-61`), i.e. in a
  resumed run. Re-invoking the completed workflow — which is what `runAgentRunWorkflow` does on a
  pgmq redelivery of the same idempotency key, and what the `FlowLifecycleSpec` harness does when
  called twice — re-executes `remember` with a fresh `genMemoryId`: a new row per replay. The
  existing test at `shikigami-core/test/Shikigami/FlowLifecycleSpec.hs:107-109` (`memoryFlow`,
  defined at `:205-215`) passes only because it runs remember-then-recall once in a single run
  and never replays.
- **Nondeterministic recall.** A flow that branches on `recall` results re-queries the live store
  on each replay; memories recorded or superseded in the meantime change the result set, so the
  replayed control flow can diverge from the journaled steps taken earlier — after which step
  names no longer line up and replay integrity is gone. `atRiskCustomerFlow` branches on exactly
  this: `classifyRisk` raises an otherwise-low verdict to `high` when a recalled memory mentions a
  prior escalation on the same subject (`AtRiskCustomer.hs:85`, `:99-102`).

Contrast the non-flow agent-run path, which is correct: recall is journaled as step `"recall"`
(`shikigami-core/src/Shikigami/Agent/Workflow.hs:304`) and the learning write as step `"record"`
(`:344`, wrapping `recordLearning` at `:784-806` — which hardcodes the same metadata at
`:795-803`). Crash-resume dedup for that path is proven by the test "resumes after a crash between
record and complete without duplicating memory" in
`shikigami-core/test/Shikigami/AgentWorkflowSpec.hs:368`, which asserts exactly one memory row for
the resumed session.

### Why a journaled step is not enough by itself

keiro steps are at-least-once at the step boundary: crash after the action ran but before the
journal append commits, and the action reruns on resume. Closing that window for `remember`
requires the memory write itself to be idempotent, which kioku gives us if the id is
deterministic — with one condition that the earlier draft of this plan did not state.

`Kioku.Memory.record` delegates to `recordIn` (`kioku-core/src/Kioku/Memory.hs:176-189`), which
looks the id up first and, when a row exists, returns success *only if the whole semantic payload
matches*. `memoryRecordFields` (`:452-464`) compares `agentId`, `sessionId`, namespace, scope
kind, scope ref, `memoryType`, `content`, `priority`, `confidence`, `tags`, and `supersedes`; a
mismatch yields `MemoryConflict` naming the offending field. Call-time timestamps are
deliberately excluded, and kioku's haddock (`:398-408`) explains that this is exactly so a
deterministic-id retry that re-reads the clock still succeeds. So the rule this plan must honour
is: **the arguments to `remember` must be a pure function of replay-stable inputs.** In practice
that is already true — a flow builds its note from a journaled verdict and a journaled
acknowledgement — but it is a contract, and M2's crash-window test pins both halves of it.

`MemoryId` is `KindID "kioku_memory"` (`kioku-api/src/Kioku/Id.hs:21`, from the `mmzk-typeid`
package), and a KindID can be built from an arbitrary UUID with
`Data.KindID.V7.decorateKindID`. kioku does this itself in `parseIdLenient`
(`kioku-api/src/Kioku/Id.hs:64`) and in `l1AtomMemoryId`
(`kioku-core/src/Kioku/Distill/L1.hs:603-605`). Both `mmzk-typeid` and `uuid` are already direct
dependencies of `shikigami-core` (`shikigami-core.cabal:129`, `:140`).

### The checked specification, and what a label may be

`domain/shikigami.keiro-workspace` is the service input: a manifest naming `service shikigami`,
`runtime-package shikigami-core`, and `layout collocated`, plus two members —
`domain/shikigami-agent-run.keiro` and `domain/shikigami-conversation.keiro`. Every file-taking
`keiro-dsl` command takes the manifest and validates the composed service. The manifest declares
no `module` clause on purpose: `context shikigami` already supplies the `Shikigami` prefix, and
adding `module Shikigami` would scaffold `Shikigami.Shikigami.*`.

The gate is `just keiro-gate <since-ref>` (`justfile:175-182`). It runs `keiro-check` (with
`--min-language 5`, `--deny-warnings`, `--explain-bindings`, and `--fail-on-opaque`),
`keiro-inspect` (asserting every member declares its language at effective version 5),
`keiro-scaffold` (regenerate, then `git diff --exit-code`), `keiro-diff <ref>` (the six-surface
evolution classification), and `cabal test keiro-shikigami-conformance`. A `BREAKING` finding
exits non-zero and is a deployment gate, not an advisory.

**A workflow label is a wire word.** keiro-dsl parses a `step`, `await`, `sleep`, or `child` label
with `[A-Za-z0-9][A-Za-z0-9_-]*`. A label containing a colon, or a suffix computed at run time,
cannot be declared at all. That is why shikigami's `approval:<SinkKind>:<ordinal>`,
`<label>:notify`, `emit-signal:<label>`, and every per-message conversation label sit outside the
specification (`docs/workflow-versioning.md:441-459`, census in
`docs/architecture/shikigami-domain-inventory.md`). This plan's labels are chosen to be inside it.

`domain/shikigami-agent-run.keiro`'s `body` is the label inventory to extend. It holds
`ingest-job`, `lookup-agent`, a `patch shikigami-resolve-profile-v1` block containing
`resolve-profile`, `open-session`, `recall`, `run-behavior`, a
`patch shikigami-behavior-retry-v1` block containing `run-behavior-v2`, `classify`, the await
`await-ack`, an empty `patch shikigami-emit-signal-labels-v1` block, `dispatch-sinks`,
`fail-session`, `record`, `complete`, and the `delegate` child. The body is ordered for reading,
not for control flow: replay matches journal records by label, so alternatives and
mutually-exclusive branches all appear as siblings.

Note that `classify` and `await-ack` — written by flow code in
`shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs:45` and `:50` — are already declared there.
Flow steps journal into the agent-run workflow's own journal, because `runFlowBehavior`
(`shikigami-core/src/Shikigami/Agent/Workflow.hs:473-492`) interprets the flow inline rather than
inside an enclosing `step`. So the memory labels this plan adds belong in the same body.

**There is no `BehaviorHoles` module to fill and no behavior obligation to witness:**
`keiro-dsl behavior-obligations` reports `required: 0` because shikigami has no aggregate. Plan
39's census (`docs/architecture/shikigami-domain-inventory.md`) found shikigami has no aggregate,
no read model, no projection, no router, and no process manager — only two durable workflows and
their `run` operations. Three further surfaces are deliberately undeclared and the reasoning is
binding here too: do not certify a schema that differs from the codec actually executed.

### A worked precedent in the history

Plan 17 (behavior retry semantics) landed as commit `c159d80`, "feat(workflows): retry transient
behavior attempts", and its diff is the exact procedure M2 follows. It added a patch block plus
`step run-behavior-v2 -> BehaviorOutput` to `domain/shikigami-agent-run.keiro`, regenerated —
which rewrote `shikigami-core/src/Shikigami/AgentRun/Generated/WorkflowFacts.hs`,
`.../Generated/WorkflowRuntime.hs`, and
`shikigami-core/src/keiro-dsl-ledger.workspace.shikigami.txt` — and accepted the resulting change
to the application-owned
`shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/src/KeiroConformance/Expectations.hs`.
Read it before starting M2:

```bash
git show c159d80 -- domain/ shikigami-core/src/Shikigami/AgentRun/Generated/
```

### The acknowledgement machinery this plan wraps

`awaitAcknowledgement` (`shikigami-core/src/Shikigami/Flow/Acknowledgement.hs:22-30`) has
constraint `(Workflow :> es, Store :> es, IOE :> es)` because it delegates to
`Shikigami.Agent.Approval.awaitApproval` (awakeable allocation plus a durable deadline timer). It
is the only reason a flow body needs `Store`/`IOE` today.

Since the plan was first written, `Shikigami.Flow` grew a `FlowRuntime` record
(`Flow.hs:33-36`, holding `approval :: ApprovalEnv` and
`acknowledgementDeadline :: NominalDiffTime`) and an unexported `FlowRegistration`
(`Flow.hs:60-79`) whose `build :: FlowRuntime -> (forall es. FlowEffects es => Value -> Eff es Value)`
closes each flow body over that runtime. `flowRegistry`, `lookupFlow`, and the `FlowDef` they
produce therefore all take a `FlowRuntime` today, while `registeredFlowNames` and
`flowDeclarationErrors` do not. M3 changes that shape, so read `Flow.hs:60-127` before starting
it.


## Plan of Work

### Milestone 1 — make the defect visible

Nothing changes in runtime code. At the end of this milestone a test exists that fails, and its
failure is the bug this plan removes.

In `shikigami-core/test/Shikigami/FlowLifecycleSpec.hs`, add a test case "replaying a completed
flow does not duplicate its memory". Model it on the existing "registered at-risk-customer flow
replays parked alert without duplicating outbox" case (`:155-176`), which is its structural twin
for the sink side: it already runs the flow, replays it, and asserts a count did not grow. Use the
`withAtRiskFlow` harness (`:302`): run the at-risk flow with `highRiskPayload` (`:394`) to
suspension, resolve the acknowledgement the way the case at `:125-143` does, resume to completion,
then invoke `runFlowInAppEnv` (`:256`) a second time with the same `WorkflowId` — a pure replay,
whose outcome is `Completed` with the same value.

Then count memory rows. This harness's `MemoryEnv` has `sessionId = Nothing`
(`runFlowBody`, `:284`), so count by scope rather than by session:

```haskell
rows <- runAppIO appEnv (Memory.getActiveRowsByScope shikigamiMemorySpace (agentScope "at-risk-customer"))
```

`getActiveRowsByScope` takes the memory space first since kioku 0.4
(`kioku-core/src/Kioku/Memory.hs:519-523`) and returns
`Either ReadModelError [MemoryRow]`; `MemoryRow` is defined at
`kioku-core/src/Kioku/Memory/ReadModel.hs:54-72` and carries `content`, `status`, `priority`,
`confidence`, `memoryType`, `tags`, and `supersedes` as plain fields. Import
`shikigamiMemorySpace` from `Shikigami.Memory.Access` and `agentScope` from
`Shikigami.Memory.Scope`. Filter to rows whose `content` mentions the acknowledged-note summary
`"at-risk customer alert acknowledged"` (`AtRiskCustomer.hs:164`) and assert exactly one.

Run it and observe two. Paste the failing transcript into Surprises & Discoveries before touching
the interpreter — the red output is the evidence that this plan fixed something real, and once
M2 lands it cannot be regenerated without reverting.

There is no expected-failure idiom in this tasty suite, so do not commit the test alone on a red
build. Commit it together with M2's interpreter change, having recorded the red run first.

Acceptance: the test exists, and running it against the unmodified interpreter fails with a count
of two.

### Milestone 2 — journal the Memory capability

Do the specification first, because the gate is cheaper to satisfy before the Haskell exists than
after.

**Step one: declare the labels.** Add four steps to `domain/shikigami-agent-run.keiro`'s `body`,
beside the `classify` and `await-ack` labels the same flow already owns:

```text
    # Shikigami.Flow.Capability.runMemory journals a flow's recall and remember
    # calls under the caller's stable label. Unlike the emit-signal family, these
    # names are hyphenated wire words, so they are declarable and this gate
    # governs them. Adding a labeled memory call to a registered flow means
    # adding its label here.
    step recall-risk-history -> RecalledLearnings
    step remember-acknowledged -> RecordedLearning
    step remember-declined -> RecordedLearning
    step remember-escalated -> RecordedLearning
```

Reuse the existing result type names `RecalledLearnings` and `RecordedLearning` rather than
minting new ones: `keiro-check` runs with `--fail-on-opaque`, which raises
`CoverageOpaqueGateExceeded` when a *new* opaque boundary appears on a persisted root, and these
steps carry the same shapes the declared `recall` and `record` steps already do.

Then regenerate and accept:

```bash
just keiro-check
just keiro-scaffold
```

`keiro-scaffold` rewrites `shikigami-core/src/Shikigami/AgentRun/Generated/WorkflowFacts.hs`,
`.../WorkflowRuntime.hs`, and `shikigami-core/src/keiro-dsl-ledger.workspace.shikigami.txt`, then
fails `git diff --exit-code` until you commit the regeneration — that failure is the instruction,
not an error. The `body` fact in the application-owned
`shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/src/KeiroConformance/Expectations.hs`
must then be edited by hand to match; that file's header says so ("This module is
application-owned; review and edit it to accept conformance changes").

**Step two: re-signature the effect.** In `shikigami-core/src/Shikigami/Flow/Capability.hs`, give
both constructors a caller-supplied label, and give `Remember` its options record now so the
interpreter is written exactly once:

```haskell
data Memory :: Effect where
  Recall   :: Text -> MemoryQuery -> Memory m [MemoryRecord]
  Remember :: Text -> RememberOptions -> Value -> Memory m MemoryId

recall :: (Memory :> es) => Text -> MemoryQuery -> Eff es [MemoryRecord]
recall label query' = send (Recall label query')

remember :: (Memory :> es) => Text -> Value -> Eff es MemoryId
remember label value = send (Remember label defaultRememberOptions value)
```

`RememberOptions` and `defaultRememberOptions` are introduced here with today's constants;
`rememberWith` is exported in M4. Give `recall` and `remember` a haddock that says what a label
is, in the same terms `emitSignal`'s does (`Capability.hs:92-101`), and add the one rule
`emitSignal` does not have: the label is also a declared wire word, so it must match
`[A-Za-z0-9][A-Za-z0-9_-]*` and must appear in `domain/shikigami-agent-run.keiro` when the flow
is registered.

**Step three: journal both operations.** Widen `runMemory`'s constraint to
`(Workflow :> es, IOE :> es)` and wrap each branch in a `step`:

```haskell
Recall label MemoryQuery {query} ->
  step (StepName ("recall-" <> label))
       (liftIO (recallPriorLearnings appEnv (agentScope (name decl)) query))
Remember label opts value -> do
  (wfName, wfId) <- currentWorkflow
  generation <- currentRunGeneration
  let mid = deterministicFlowMemoryId wfName wfId generation label
  step (StepName ("remember-" <> label)) (liftIO (recordFlowMemory mid opts value))
```

`[MemoryRecord]` and `MemoryId` already carry the `ToJSON`/`FromJSON` instances `step` requires
(`keiro/src/Keiro/Workflow.hs:282`); the non-flow path journals both types today
(`Agent/Workflow.hs:304` and `:344`). The recorded step value for remember is the `MemoryId`.

Note the ordering: `currentWorkflow` and `currentRunGeneration` are read *outside* the step. They
are replay-stable by construction — `currentRunGeneration`'s own haddock
(`keiro/src/Keiro/Workflow.hs:300-304`) says wake sources include the generation in their durable
identities so that a generation opened by `continueAsNew` never collides with prior-generation
rows — so reading them outside a step costs nothing and keeps the step body a single IO action.

**Step four: the deterministic id.** Add to the same module:

```haskell
-- | The memory id a labeled 'Remember' always maps to.
--
-- Keyed on the workflow identity, the journal generation, and the caller's
-- label, so a crash between the record landing and the journal append commits
-- re-derives the SAME id; kioku answers the second write idempotently rather
-- than writing a second row. The generation is included for the reason
-- 'currentRunGeneration' names: a journal rotated by 'continueAsNew' must not
-- collide with the generation before it.
--
-- Hashes UTF-8 bytes rather than 'fromEnum' over Chars. This deliberately
-- diverges from 'deterministicOutboxIdForMessage' in Shikigami.Agent.Workflow,
-- whose inputs are ASCII by construction; a workflow name is not.
deterministicFlowMemoryId :: WorkflowName -> WorkflowId -> Int -> Text -> MemoryId
deterministicFlowMemoryId (WorkflowName wfName) (WorkflowId wfId) generation label =
  KindID.decorateKindID $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      ByteString.unpack $
        Text.Encoding.encodeUtf8 $
          Text.intercalate ":" ["shikigami:flow-memory", wfName, wfId, Text.pack (show generation), label]
```

`recordFlowMemory` keeps the existing `RecordMemoryData` construction (`Capability.hs:117-133`)
but takes the id and the options instead of calling `genMemoryId`, and treats kioku's
already-exists answer as success. With a deterministic id, `Kioku.Memory.record` returning the
same id means the re-execution found the prior write — precisely the idempotency we want. A
`MemoryConflict` must NOT be swallowed: it means the payload changed between attempts, which is a
real bug in the flow (a note built from unjournaled data), and it should surface as the write
failure it is.

**Step five: update call sites.** In
`shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs`: `recall "risk-history" (riskQuery activity)`
(`:44`), `remember "acknowledged" ...` (`:53`), `remember "declined" ...` (`:56`),
`remember "escalated" ...` (`:60`). In `shikigami-core/test/Shikigami/FlowLifecycleSpec.hs`,
`memoryFlow` (`:205-215`) becomes `remember "note" ...` and `recall "note-back" ...`. The
interpreter stack in `runFlowBehavior` (`Agent/Workflow.hs:486-489`) already runs under
`Workflow :> es`, and so does the spec harness's `body` (`FlowLifecycleSpec.hs:296-299`), so
neither should need editing beyond what type inference demands.

**Step six: the crash-window test.** The honest test does not try to fake a lost journal append —
there is no public API for that. It exercises the property the deterministic id buys, in both
directions. Call the interpreter's `recordFlowMemory` twice with the same computed id and the
same payload; assert `Right` both times and exactly one active row for the scope. Then call it a
third time with the same id and *different* content; assert the result is
`Left (MemoryConflict ...)`. The second half is what documents the contract from the Context
section — that a `remember` payload must be a pure function of replay-stable inputs — as
executable behavior rather than a comment.

**Step seven: pin the journal.** Extend M1's test to assert the step index. After the acknowledged
at-risk run, `Keiro.Workflow.loadStepIndex` for that workflow id contains `remember-acknowledged`
and `recall-risk-history`. `shikigami-core/test/Shikigami/AgentWorkflowSpec.hs:910` already has a
`loadLifecycleStepKeys` helper that filters reserved keiro markers and the patch-set step name;
follow its shape.

**Step eight: the documentation table.** `docs/workflow-versioning.md`'s "What Shikigami journals
today" inventory (its "flow capabilities" block, around `:403-408`) gains `recall-<label>` and
`remember-<label>` with their file citations, and the "Undeclarable label families" section
(`:441-459`) gains a sentence recording that memory labels are deliberately *declarable* — the
contrast with `emit-signal:<label>` is the point, and a later reader choosing a separator for a
new capability should find the reasoning already written down. That document's own rule says a
change to the inventory table is a change to a persisted compatibility identifier.

Acceptance: `just keiro-gate <merge-base>` green; M1's test green; the step index shows the
labeled memory steps; the crash-window test green in both directions; `cabal test all` green.

### Milestone 3 — remove ambient IO from flow bodies

At the end of this milestone a flow body containing `liftIO (putStrLn "x")` does not compile.

Add the capability. Keep it in `shikigami-core/src/Shikigami/Flow/Acknowledgement.hs`, where the
`Ack` type already lives:

```haskell
data Acknowledgement :: Effect where
  AwaitAcknowledgement :: StepName -> ApprovalRequest -> Acknowledgement m Ack

awaitAck :: (Acknowledgement :> es) => StepName -> ApprovalRequest -> Eff es Ack

runAcknowledgement ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  ApprovalEnv -> NominalDiffTime -> Eff (Acknowledgement : es) a -> Eff es a
```

The interpreter delegates to the existing `awaitAcknowledgement`
(`Acknowledgement.hs:22-30`), which keeps the approval env and the deadline out of the flow body.
Then narrow `shikigami-core/src/Shikigami/Flow.hs:31` to:

```haskell
type FlowEffects es =
  (Workflow :> es, Memory :> es, Sink :> es, Activity :> es, Acknowledgement :> es)
```

This has a consequence the earlier draft of this plan predates. `FlowRuntime` exists today only so
a flow body can close over the approval environment and the deadline (`Flow.hs:33-36`,
`FlowRegistration.build` at `:77`). Once acknowledgement is a capability, the body closes over
nothing: `FlowRegistration.build` becomes a plain `Value -> Eff es Value`, `FlowDef` no longer
needs constructing per-runtime, and `flowRegistry`/`lookupFlow` (`Flow.hs:90-106`) lose their
`FlowRuntime` parameter. `FlowRuntime` survives as the record that configures
`runAcknowledgement`. Make that simplification rather than threading a now-unused parameter — a
parameter kept only to avoid touching call sites is the drift this plan is cleaning up. Preserve
the invariant the module's haddock protects (`Flow.hs:68-73`): `flowRegistry` and
`registeredFlowNames` must stay two projections of one list.

Update the consumers: `runFlowBehavior` (`Agent/Workflow.hs:473-500`) applies
`runAcknowledgement (approval deps sid) (fromMaybe (secondsToNominalDiffTime 900) (deadline deps))`
in its interpreter stack instead of building a `FlowRuntime` for `lookupFlow`; the
`FlowLifecycleSpec` harness `runFlowBody` (`:266-297`) does the same; and the registry-lookup
tests at `:65-89` drop the `FlowRuntime` they currently construct.
`Shikigami.Server.Command.Validate` and worker boot use `registeredFlowNames`, which never took a
`FlowRuntime`, so they are unaffected.

One spec flow needs care. `sleepFlow` (`FlowLifecycleSpec.hs:229-233`) calls `sleepNamed`, which
requires `Store` and `IOE`. It is a harness-level spike proving keiro suspension, not a registry
flow, so give it its own local constraint — `(Workflow :> es, Store :> es, IOE :> es)` — instead
of `FlowEffects`, and leave `runFlowWorkflow` interpreting it over the full row.

Acceptance: a scratch flow body with `liftIO (putStrLn "x")` fails to compile — verify by
attempting it and reading the error, then discard the scratch edit rather than committing it —
and `cabal test all` is green.

### Milestone 4 — metadata options

At the end of this milestone a flow can say what kind of memory it is writing, and can supersede
one of its own earlier memories.

In `shikigami-core/src/Shikigami/Flow/Capability.hs`, export the record introduced in M2 and add
the widened helper:

```haskell
data RememberOptions = RememberOptions
  { priority   :: !Int,
    confidence :: !Confidence,
    memoryType :: !MemoryType,
    supersedes :: !(Maybe MemoryId),
    extraTags  :: !(Set Text)
  }

defaultRememberOptions :: RememberOptions
-- priority 100, MediumConfidence, MemoryPattern, no supersession, no extra tags

rememberWith :: (Memory :> es) => Text -> RememberOptions -> Value -> Eff es MemoryId
rememberWith label opts value = send (Remember label opts value)
```

`remember label = rememberWith label defaultRememberOptions`. The interpreter threads the options
into `RecordMemoryData`, replacing the constants at `Capability.hs:126-131`; `extraTags` unions
with the existing `["flow", focus]` tags rather than replacing them, so a flow cannot accidentally
un-tag its own memories out of the queries that find them.

The kioku vocabulary these fields come from: `RecordMemoryData`
(`kioku-core/src/Kioku/Memory/Domain.hs:54-69`) carries `memoryType :: MemoryType`
(`MemoryFact | MemoryPattern | MemoryPreference | MemoryConstraint | MemoryInstruction`,
`kioku-api/src/Kioku/Api/Types.hs`), `priority :: Int`, `confidence :: Confidence`
(`HighConfidence | MediumConfidence | LowConfidence`), `tags :: Set Text`, and
`supersedes :: Maybe MemoryId`.

Add a spec: a flow records under `remember "first" ...`, then under
`rememberWith "constraint" opts` where `opts` sets `MemoryConstraint`, priority 10,
`HighConfidence`, and `supersedes` the id the first call returned. Assert via
`Kioku.Memory.getMemoryRowById shikigamiMemorySpace` (`kioku-core/src/Kioku/Memory.hs:499-505`)
that the metadata landed on the new row, and via `getActiveRowsByScope` that the superseded row is
no longer active. Note that the second `remember` receives the first's `MemoryId` — which is
itself a journaled step result, so the supersession target is replay-stable and the deterministic
id of the superseding row does not change on replay. Say so in the test's comment; it is the
non-obvious part.

If `remember "constraint"` names a registered flow, its label must also be declared in
`domain/shikigami-agent-run.keiro`. Keep this spec's flow in the test harness (workflow
`shikigami.flow.spike`), which is outside the specification, so M4 needs no second gate pass.

Acceptance: the new spec is green; existing call sites are unchanged in behavior — assert that a
pre-existing flow memory still records priority 100, `MediumConfidence`, and `MemoryPattern`.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shikigami` inside `nix develop`. The test
suites provision their own migrated database, but they need the in-repo Postgres cluster running.

```bash
nix develop
cabal build all
cabal test shikigami-core-test
```

Iterate on the flow specs only:

```bash
cabal test shikigami-core-test --test-options='-p FlowLifecycle'
```

For M1, capture the red run. The expected failure shape:

```text
FlowLifecycle
  replaying a completed flow does not duplicate its memory: FAIL
    expected exactly one acknowledged memory row, got 2
```

After M2 the same command reports `OK`.

The specification gate, run from the repository root because `keiro-diff` reconstructs the old
manifest with `git show`:

```bash
just keiro-check
just keiro-inspect
just keiro-scaffold
just keiro-gate origin/master
```

`keiro-scaffold` fails with `the committed generated layer is out of date; commit the
regeneration` until the regenerated files are staged — that is the expected first result after
editing `domain/`, not a problem to debug. `keiro-diff` classifies the change across six
compatibility surfaces; adding a step label to a body should classify as compatible, and a
`BREAKING` finding means a label was moved rather than added.

After each milestone run the full battery:

```bash
cabal build all
cabal test all
```

No dependency edits are expected. `mmzk-typeid` and `uuid` are already in
`shikigami-core.cabal`'s `build-depends` (`:129`, `:140`); the earlier version of this plan told
you to add `mmzk-typeid >=0.7`, and that instruction is void.


## Validation and Acceptance

Accepted when the following behaviors are observable.

1. **Dedup on replay.** Run the at-risk flow to acknowledged completion, re-invoke the same
   workflow id, and `Kioku.Memory.getActiveRowsByScope shikigamiMemorySpace (agentScope
   "at-risk-customer")` shows exactly one "acknowledged" memory row. Exact command:
   `cabal test shikigami-core-test --test-options='-p "duplicate its memory"'` → OK. Reverting
   the `runMemory` change makes it fail with a count of two.
2. **Journaled recall.** After any flow run that recalls, `Keiro.Workflow.loadStepIndex` for that
   workflow contains `recall-<label>`, and a second invocation returns identical recall results
   even after new memories are inserted between runs. The test inserts a decoy memory via
   `Kioku.Memory.record` between run one and the replay, and asserts the replayed flow output is
   unchanged.
3. **Crash-window idempotency, both directions.** Recording twice with the same deterministic id
   and the same payload yields one active row and `Right` both times; recording a third time with
   the same id and different content yields `Left (MemoryConflict ...)`.
4. **The labels are gated, not merely stable.** `just keiro-gate origin/master` exits zero with
   the four new labels present in `domain/shikigami-agent-run.keiro`, the regenerated layer
   committed, and `cabal test keiro-shikigami-conformance` green. Deleting one label from the
   specification while leaving the Haskell in place makes the gate fail — verify this once, by
   attempt, and revert.
5. **Guardrail.** `FlowEffects` (`shikigami-core/src/Shikigami/Flow.hs:31`) no longer includes
   `IOE` or `Store`, and a scratch flow body with `liftIO` fails to compile.
6. **Metadata.** The M4 spec observes priority, confidence, type, and supersedes as sent, and the
   superseded row leaves the active set; existing flows still record priority 100,
   `MediumConfidence`, `MemoryPattern`, and no supersession.
7. **Nothing else moved.** `cabal test all` green, including plan 24's
   `Shikigami.WorkflowVersioningSpec` deploy-simulation tests and the untouched
   `AgentWorkflowSpec` crash-resume dedup test.


## Idempotence and Recovery

All steps are code, specification, and test changes; builds and tests can be repeated freely, and
every test provisions its own migrated database via `withShikigamiMigratedDatabase`
(`shikigami-migrations/test-support/Shikigami/Migrations/TestSupport.hs`).
`just keiro-scaffold` is deterministic by design — that determinism is what makes the committed
generated layer trustworthy — so re-running it is a no-op once the regeneration is committed.

The runtime change is deploy-safe without sequencing. Journaling memory operations adds new step
names only (see the Decision Log), and deterministic ids only narrow behavior: fewer rows written,
never different ones. Rolling back the deploy restores the old duplicating behavior but corrupts
nothing — step entries named `remember-<label>`/`recall-<label>` in journals written by the new
code are simply never read by the old interpreter, and orphaned journal entries are inert in
keiro. Rolling back the *specification* without rolling back the code is the one unsafe
combination, because the gate would then be certifying a body that no longer matches; roll both
or neither.

Shikigami has no users, so no in-flight flow will meet this step insertion in production. That
does not remove the obligation to prove additivity — the claim is about journal structure, and a
constructed instance proves it as well as a real one would. If you want that proof beyond M1's
replay test, follow the pattern in `shikigami-core/test/Shikigami/WorkflowVersioningSpec.hs`:
start a flow under old-shape code, suspend it, swap in new-shape code, and assert the resumed
instance completes.

If M3's constraint narrowing turns out to break an out-of-tree flow author, the recovery is to
re-add a constraint alias `FlowEffectsIO` temporarily rather than reverting the interpreter work;
record any such retreat in the Decision Log.


## Interfaces and Dependencies

Hard dependencies, all delivered:
`docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md`,
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`,
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md`, and the cohort
upgrades `47` and `53`. Generated artifacts stay behind plan 39's firewall; the handwritten memory
interpreter is hand-owned code that the specification names but does not generate.

Coordination, not dependency: plan 27
(`docs/plans/27-consolidate-sink-intent-and-run-lifecycle-machinery.md`) owns consolidating the
duplicate non-flow lifecycle, including `recordLearning`'s hardcoded metadata, and is still open.
This plan deliberately does not touch it. Plan 17
(`docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md`) landed as
`c159d80` and touched the same specification member and the same runtime module; rebase onto it
rather than beside it.

Library surfaces this plan uses:

- `keiro` (`mori://shinzui/keiro`) — `Keiro.Workflow`: `step`
  (`keiro/src/Keiro/Workflow.hs:282`), `StepName`, `currentWorkflow` (`:297`),
  `currentRunGeneration` (`:303`), `loadStepIndex`, `WorkflowName`, `WorkflowId`.
- `kioku` (`mori://shinzui/kioku`) — `Kioku.Memory.record` (deprecated wrapper,
  `kioku-core/src/Kioku/Memory.hs:170`), `getMemoryRowById` (`:499`), `getActiveRowsByScope`
  (`:519`); `Kioku.Memory.Domain.RecordMemoryData` (`Kioku/Memory/Domain.hs:54`);
  `Kioku.Memory.ReadModel.MemoryRow` (`:54`); `Kioku.Api.Types.{MemoryType, Confidence,
  MemoryRecord}`; `Kioku.Id.{MemoryId, idText}`.
- `mmzk-typeid` — `Data.KindID.V7.decorateKindID`. Already a direct dependency.
- `uuid` — `Data.UUID.V5.generateNamed`. Already a direct dependency.
- `Shikigami.Workflow.Versioning` — governs run options. This plan adds no patch id, so
  `shikigamiActivePatches` does not change.

Signatures that must exist at the end, with full module paths:

```haskell
-- shikigami-core/src/Shikigami/Flow/Capability.hs
recall                    :: (Memory :> es) => Text -> MemoryQuery -> Eff es [MemoryRecord]
remember                  :: (Memory :> es) => Text -> Value -> Eff es MemoryId
rememberWith              :: (Memory :> es) => Text -> RememberOptions -> Value -> Eff es MemoryId
data RememberOptions       -- priority, confidence, memoryType, supersedes, extraTags
defaultRememberOptions    :: RememberOptions
runMemory                 :: (Workflow :> es, IOE :> es) => MemoryEnv -> Eff (Memory : es) a -> Eff es a
deterministicFlowMemoryId :: WorkflowName -> WorkflowId -> Int -> Text -> MemoryId

-- shikigami-core/src/Shikigami/Flow/Acknowledgement.hs
awaitAck           :: (Acknowledgement :> es) => StepName -> ApprovalRequest -> Eff es Ack
runAcknowledgement :: (Workflow :> es, Store :> es, IOE :> es)
                   => ApprovalEnv -> NominalDiffTime
                   -> Eff (Acknowledgement : es) a -> Eff es a

-- shikigami-core/src/Shikigami/Flow.hs
type FlowEffects es =
  (Workflow :> es, Memory :> es, Sink :> es, Activity :> es, Acknowledgement :> es)

flowRegistry :: [FlowDef]          -- loses its FlowRuntime parameter in M3
lookupFlow   :: Text -> Maybe FlowDef
```

Declared identities that must exist at the end, in `domain/shikigami-agent-run.keiro`'s
`workflow AgentRun` body: `recall-risk-history`, `remember-acknowledged`, `remember-declined`,
`remember-escalated`.

Consumers to keep compiling: `shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs`,
`shikigami-core/src/Shikigami/Agent/Workflow.hs` (`runFlowBehavior`'s interpreter stack),
`shikigami-core/test/Shikigami/FlowLifecycleSpec.hs`, and
`shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/src/KeiroConformance/Expectations.hs`
(hand-edited to accept the new body fact).


## Revision Notes

- 2026-07-22: Added the checked Keiro DSL as a hard prerequisite and made labeled memory steps
  part of the specification, scaffold, harness, and diff acceptance gate.

- 2026-08-10: Scope note — shikigami has no users, so no in-flight flow will encounter this plan's
  step insertion in production. This changes nothing about the design: the additivity argument is
  a claim about journal structure, not about whether instances exist, and it still needs its test.
  The reference to plan 47's old-state fixtures stopped carrying a compatibility obligation at
  this point, since old state does not exist. Plan 39's topology gate still binds, because it is
  about the checked specification agreeing with the code.

- 2026-08-19: Reconciled the whole plan against the delivered tree, which had drifted from it in
  eight ways. (1) Every prerequisite has landed, and the cohort is keiro 0.13 / keiro-dsl 0.13
  language 5 / kioku 0.4.1, not the keiro 0.4 the stale "Portfolio Reconciliation" section named;
  that section is deleted and its live content folded into Context and Orientation and Interfaces
  and Dependencies. (2) The plan contradicted itself: Milestone 2 specified colon-separated step
  names that the plan's own plan-39 reconciliation section had already established cannot be
  declared. Resolved in favour of hyphens, which makes these the first flow-side journal labels
  this service can gate, and the four concrete labels are now named and specified for
  `domain/shikigami-agent-run.keiro`. (3) `mmzk-typeid` and `uuid` are already direct
  dependencies, so the cabal instruction was void and is now marked as such. (4) kioku 0.4
  deprecated `Kioku.Memory.record` in favour of `recordWithContext`, and moving to it is blocked
  on a per-agent write context that IR-9 owns — recorded as a scoped-out decision with the
  `underContext` actor-matching mechanism cited, rather than left as a silent stale API. (5) The
  crash-window idempotency claim was under-specified: kioku's `recordIn` is idempotent by id only
  when the whole semantic payload matches, and the plan now states that precondition, cites
  kioku's deliberate exclusion of `recordedAt` as the evidence that the design works, and turns
  both halves into a test. (6) kioku's own `l1AtomMemoryId` was found to be the same construction
  this plan proposes, which upgrades the deterministic-id decision from invention to precedent;
  the encoding was changed to UTF-8 bytes with the divergence from
  `deterministicOutboxIdForMessage` recorded. (7) `Shikigami.Flow` gained `FlowRuntime`,
  `FlowRegistration`, `flowDeclarationErrors`, and `registeredFlowNames` after this plan was
  written, so Milestone 3 now says what happens to them — `FlowRuntime` becomes the
  `runAcknowledgement` environment and the registry loses its parameter — instead of describing a
  module shape that no longer exists. (8) Every file:line citation was re-derived against the
  current tree, the milestone-ordering question the plan had left to the reader was decided, and
  three new obligations were added that the earlier draft omitted: updating
  `docs/workflow-versioning.md`'s journal inventory, hand-accepting the conformance expectation
  change, and running `just keiro-gate`. Progress, Surprises & Discoveries, Decision Log, Context
  and Orientation, Plan of Work, Concrete Steps, Validation and Acceptance, Idempotence and
  Recovery, and Interfaces and Dependencies were all rewritten to match; the two duplicate
  `## Revision Notes` headings were merged into this one.
