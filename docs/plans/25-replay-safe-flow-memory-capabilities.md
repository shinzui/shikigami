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

Shikigami flows (agent behaviors written in the Haskell Flow DSL) can `remember` a learning
into kioku's durable memory store and `recall` prior learnings. Flows run inside durable
keiro workflows, which may suspend (park waiting for a human acknowledgement) and later
replay their journaled steps. But the flow Memory capability's interpreter performs raw IO
instead of journaled workflow steps: every replay that passes a `remember` call mints a
fresh memory id and writes a duplicate memory row, and every replay re-executes `recall`
against the live store, so a flow that branches on what it recalled can take a different
branch on replay than it took originally — the exact nondeterminism durable workflows exist
to prevent. The non-flow agent-run path already does this correctly (its recall and record
are journaled steps with a crash-resume dedup test); the flow path silently is not.

After this plan, a flow's `remember` and `recall` are journaled keiro steps with stable,
caller-supplied labels: a replayed flow returns the recorded recall results without touching
the store, and a replayed remember is idempotent twice over (the step journal short-circuits
it, and even a crash inside the step window re-writes the SAME deterministic memory id,
which kioku treats as already-recorded). Flow authors also gain control over the memory
metadata that is currently hardcoded on every write (priority, confidence, memory type,
supersedes), and lose ambient `IOE`/`Store` access inside flows so the only way a flow can
touch the world is through replay-safe capabilities. A test that fails today — replaying a
completed flow duplicates its memory — passes after the change.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Add failing test: replaying an acknowledged at-risk flow duplicates its recorded
      memory (red).
- [ ] M2: Labeled Memory effect (`Recall`/`Remember` carry labels); `runMemory` journals
      both as keiro steps; deterministic memory ids; M1 test green.
- [ ] M2: Crash-window idempotency test (deterministic id makes a re-executed remember a
      no-op in kioku).
- [ ] M3: `Acknowledgement` capability added; `IOE` and `Store` removed from `FlowEffects`;
      `atRiskCustomerFlow` and specs compile against the narrowed constraint.
- [ ] M4: `RememberOptions` (priority/confidence/memoryType/supersedes/extra tags) and
      `rememberWith`; defaults preserve current values; docs updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Labeled memory steps are declared in plan 39's checked Keiro DSL and pass
  checker/scaffold/harness/generated-diff CI with the handwritten interpreter.
  Rationale: deterministic ids do not protect against declaration/code step-name drift.
  Date: 2026-07-22

- Decision: No `patch` guard is needed for journaling `remember`/`recall` as steps.
  Rationale: the old interpreter journaled NOTHING for memory operations, so the change is
  purely additive step insertion — an in-flight flow resumed under the new code finds no
  journal entry for `remember:<label>`, runs it fresh (which the old code would also have
  done, minus the journaling), and proceeds. Per `docs/workflow-versioning.md` (plan 24),
  additive new step names are deploy-safe without a patch. The residual behavior change on
  replayed-but-already-completed instances (they stop re-writing memories) is the bug fix
  itself.
  Date: 2026-07-08
- Decision: Deterministic memory ids are minted in shikigami by decorating a UUIDv5 (over
  workflow name, id, generation, and step label) into kioku's `MemoryId` KindID, using the
  `mmzk-typeid` package directly, rather than adding a constructor to `Kioku.Id`.
  Rationale: kioku's `Memory.record` is already idempotent by id
  (`kioku-core/src/Kioku/Memory.hs`, `record` returns `Right memoryId` when the id already
  exists), so no kioku change is required; `MemoryId` is a type alias for
  `KindID "kioku_memory"` (`kioku-api/src/Kioku/Id.hs:21`), and `mmzk-typeid` exposes
  `Data.KindID.V7.decorateKindID :: UUID -> KindID prefix` (used by kioku itself in
  `parseIdAnyPrefix`). The tradeoff — a v5 (name-based) UUID inside an id family that is
  normally UUIDv7 (time-ordered) — costs only time-sortability for these specific rows,
  which nothing in kioku depends on for correctness; record the tradeoff here.
  Date: 2026-07-08
- Decision: Remove BOTH `IOE` and `Store` from the flow-facing `FlowEffects` constraint,
  and introduce an `Acknowledgement` capability to replace direct
  `awaitAcknowledgement` calls (which require `Store`/`IOE`).
  Rationale: the task is to make unjournaled effects unreachable from flow bodies.
  Feasibility was verified by reading `atRiskCustomerFlow`
  (`shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs:41-60`): it uses `currentActivity`
  (Activity), `recall`/`remember` (Memory), `step` with pure bodies (Workflow),
  `emitSignal` (Sink), and `awaitAcknowledgement` (the only direct `Store`+`IOE` consumer).
  Wrapping acknowledgement as a capability removes the last direct dependency; `Workflow`
  stays in `FlowEffects` so flows can still name pure checkpoints with `step`, but without
  `IOE` a step body cannot `liftIO`. Documentation-plus-lint was rejected as unenforced.
  Date: 2026-07-08
- Decision: Extend metadata on the FLOW capability only; leave the non-flow
  `recordLearning` (`shikigami-core/src/Shikigami/Agent/Workflow.hs:585-605`) hardcoded.
  Rationale: the duplicate non-flow lifecycle is plan 27's consolidation target; changing
  it here would widen this plan's blast radius and race plan 27's refactor.
  Date: 2026-07-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

All shikigami paths are relative to `/Users/shinzui/Keikaku/bokuno/shikigami`. kioku (the
agent memory/session library) lives at `/Users/shinzui/Keikaku/bokuno/kioku` (locate with
`mori registry show kioku --full`); keiro (the durable workflow engine) lives at
`/Users/shinzui/Keikaku/bokuno/keiro`, library sources under its `keiro/` subdirectory.
This plan hard-depends on plan 24
(`docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md`), which must be
complete first: it establishes the caller-supplied stable-label convention for capability
step names, the `docs/workflow-versioning.md` discipline this plan's step changes are
justified against, and it re-signatures the `Sink` effect in the same module this plan
edits.

Background a novice needs. A durable keiro workflow journals each
`step (StepName n) action` result to Postgres; on replay, a journaled name returns its
recorded result WITHOUT running the action (`keiro/src/Keiro/Workflow.hs`, module header
and the `Step` handler). Anything a workflow body does OUTSIDE a `step` runs again on every
replay — replays happen when a suspended workflow resumes, when a crashed run is retried,
and when an already-completed workflow is re-invoked with the same id (the body re-executes
with every step hitting the journal). Therefore any effect with an external footprint that
is not wrapped in a step is executed an unpredictable number of times.

The flow system: a `FlowDef` (`shikigami-core/src/Shikigami/Flow.hs:41-45`) carries
`run :: forall es. FlowEffects es => Value -> Eff es Value`, where today

```haskell
type FlowEffects es =
  (Workflow :> es, Store :> es, IOE :> es, Memory :> es, Sink :> es, Activity :> es)
```

(`Flow.hs:28`). `Memory`, `Sink`, and `Activity` are effectful dynamic effects defined in
`shikigami-core/src/Shikigami/Flow/Capability.hs`:

```haskell
data Memory :: Effect where
  Recall   :: MemoryQuery -> Memory m [MemoryRecord]
  Remember :: Value -> Memory m MemoryId
```

(lines 60-63). The interpreter `runMemory` (lines 88-114) is the defect: `Recall` is
`liftIO (recallPriorLearnings ...)` — a direct hybrid vector/scan query against kioku
(`shikigami-core/src/Shikigami/Agent/Run.hs:191-219`) — and `Remember` is a `liftIO` block
that calls `genMemoryId` (a RANDOM time-based id, `kioku-api/src/Kioku/Id.hs:25-26`),
`getCurrentTime`, and `MemoryStore.record` with hardcoded metadata: `priority = 100`,
`confidence = MediumConfidence`, `memoryType = MemoryPattern`, `supersedes = Nothing`
(lines 98-110). Neither operation touches the workflow journal. Consequences, concretely:

- Duplicate memories on replay. `atRiskCustomerFlow` calls `remember` AFTER its
  acknowledgement park (`shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs:50-60`), i.e.
  in a resumed run. Re-invoking the completed workflow (which is exactly what
  `runAgentRunWorkflow` does on a pgmq redelivery of the same idempotency key, and what the
  FlowLifecycleSpec harness does when called twice) re-executes `remember` with a fresh
  `genMemoryId`: a new row per replay. The existing test
  `shikigami-core/test/Shikigami/FlowLifecycleSpec.hs:80-82` (`memoryFlow`, defined at
  lines 178-187) passes only because it runs remember-then-recall once in a single run and
  never replays.
- Nondeterministic recall. A flow that branches on `recall` results re-queries the live
  store on each replay; memories recorded or superseded in the meantime change the result
  set, so the replayed control flow can diverge from the journaled steps taken earlier —
  after which step names no longer line up and replay integrity is gone.

Contrast with the non-flow agent-run path, which is correct: recall is journaled as step
`"recall"` (`shikigami-core/src/Shikigami/Agent/Workflow.hs:175`) and the learning write is
journaled as step `"record"` (line 195 wrapping `recordLearning`, lines 585-605 — note it
hardcodes the same four metadata fields at 590-603). Crash-resume dedup for that path is
proven by the test "resumes after a crash between record and complete without duplicating
memory" (`shikigami-core/test/Shikigami/AgentWorkflowSpec.hs:115-159`), which asserts
exactly one memory row for the resumed session.

One residual window remains even for a journaled step: keiro steps are at-least-once at the
step boundary — crash after the action ran but before the journal append commits, and the
action reruns on resume. For remember, closing that window requires the memory write itself
to be idempotent, which kioku gives us if the id is deterministic: `Kioku.Memory.record`
first looks up the id and returns `Right memoryId` without writing when it already exists
(`kioku-core/src/Kioku/Memory.hs`, `record`). `MemoryId = KindID "kioku_memory"`
(`kioku-api/src/Kioku/Id.hs:21`, from the `mmzk-typeid` package), and a KindID can be
constructed from an arbitrary UUID via `Data.KindID.V7.decorateKindID`.

Kioku metadata vocabulary (for M4): `RecordMemoryData`
(`kioku-core/src/Kioku/Memory/Domain.hs:42-55`) carries `memoryType :: MemoryType`
(`MemoryFact | MemoryPattern | MemoryPreference | MemoryConstraint | MemoryInstruction`,
`kioku-api/src/Kioku/Api/Types.hs:20-26`), `priority :: Int`,
`confidence :: Confidence` (`HighConfidence | MediumConfidence | LowConfidence`,
`Api/Types.hs:52-56`), `tags :: Set Text`, and `supersedes :: Maybe MemoryId`; kioku also
exposes `supersede` and `archive` commands (`kioku-core/src/Kioku/Memory.hs:68-93`).

Finally, the acknowledgement machinery this plan wraps: `awaitAcknowledgement`
(`shikigami-core/src/Shikigami/Flow/Acknowledgement.hs:22-31`) has constraint
`(Workflow :> es, Store :> es, IOE :> es)` because it delegates to
`Shikigami.Agent.Approval.awaitApproval` (awakeable allocation plus a durable deadline
timer, `shikigami-core/src/Shikigami/Agent/Approval.hs:100-115`). It is the only reason a
flow body needs `Store`/`IOE` today.


## Plan of Work

Milestone 1 — make the defect visible (red test). In
`shikigami-core/test/Shikigami/FlowLifecycleSpec.hs`, add a test case "replaying a
completed flow does not duplicate its memory": using the existing `withAtRiskFlow` harness
(lines 263-278), run the at-risk flow with `highRiskPayload` to suspension, resolve the
acknowledgement (as the test at lines 98-116 does), resume to completion, then invoke
`runFlowInAppEnv` a second time with the same `WorkflowId` (a pure replay: outcome is
`Completed` with the same value). Then count memory rows: the flow's `MemoryEnv` in this
harness has `sessionId = Nothing` (`runFlowBody`, line 255), so count via
`Kioku.Memory.getActiveRowsByScope` for `agentScope "at-risk-customer"` (import
`Shikigami.Memory.Scope (agentScope)`), filtering rows whose content matches the
acknowledged-note summary (`"at-risk customer alert acknowledged"`). Assert exactly one.
Run it; observe TWO (the replay re-ran `remember`). Commit the failing test skipped or
guarded? No — tasty has no expected-failure idiom in this suite; commit it together with M2
in one change, but record the observed red output in Surprises & Discoveries first.
Acceptance: the test exists and demonstrably fails against the unmodified interpreter (keep
the failing-run transcript).

Milestone 2 — journal the Memory capability. Before editing runtime code, add every stable
`recall:<label>` and `remember:<label>` identity and its workflow relationship to
`domain/shikigami.keiro`; run plan 39's check, compatibility diff, scaffold, and generated
harness. Reference generated identity facts where the scaffold exposes them and keep the
effect/interpreter in hand-owned holes. Then edit
`shikigami-core/src/Shikigami/Flow/Capability.hs`:

1. Re-signature the effect with caller-supplied labels (same convention as plan 24's
   `emitSignal`): a label is a short stable `Text`, unique per call site within a flow,
   never derived from run-varying data.

   ```haskell
   data Memory :: Effect where
     Recall   :: Text -> MemoryQuery -> Memory m [MemoryRecord]
     Remember :: Text -> RememberOptions -> Value -> Memory m MemoryId

   recall   :: (Memory :> es) => Text -> MemoryQuery -> Eff es [MemoryRecord]
   remember :: (Memory :> es) => Text -> Value -> Eff es MemoryId   -- defaultRememberOptions
   ```

   (`RememberOptions` is introduced in M4; in M2 it can be introduced with only its
   defaults so the interpreter is written once. If you prefer strictly sequential
   milestones, land M2 with `Remember :: Text -> Value -> ...` and widen in M4.)

2. Give `runMemory` the constraint `(Workflow :> es, IOE :> es)` and journal both
   operations:

   ```haskell
   Recall label q ->
     step (StepName ("recall:" <> label))
          (liftIO (recallPriorLearnings appEnv (agentScope (name decl)) (query q)))
   Remember label opts value -> do
     (wfName, wfId) <- currentWorkflow
     gen <- currentRunGeneration
     let mid = deterministicFlowMemoryId wfName wfId gen label
     step (StepName ("remember:" <> label)) (liftIO (recordFlowMemory mid ...))
   ```

   `[MemoryRecord]` and `MemoryId` already have the `ToJSON`/`FromJSON` instances the
   `step` requires (the non-flow path journals both types today, `Agent/Workflow.hs:175`
   and `:195`). The recorded step value for remember is the `MemoryId`.

3. Add the deterministic id helper in the same module (new dependency `mmzk-typeid` in
   `shikigami-core/shikigami-core.cabal`, same package kioku uses):

   ```haskell
   deterministicFlowMemoryId :: WorkflowName -> WorkflowId -> Int -> Text -> MemoryId
   deterministicFlowMemoryId (WorkflowName wn) (WorkflowId wid) gen label =
     KindID.decorateKindID $
       UUID.V5.generateNamed UUID.V5.namespaceURL $
         fmap (fromIntegral . fromEnum) $
           Text.unpack (Text.intercalate ":" ["shikigami", "flow-memory", wn, wid, Text.pack (show gen), label])
   ```

   The generation component mirrors keiro's own journal-id namespacing
   (`keiro/src/Keiro/Workflow.hs:894-911`) so a post-rotation generation never collides
   with a prior one. `recordFlowMemory` keeps the existing `RecordMemoryData` construction
   (lines 96-110) but treats kioku's already-exists result as success — with the
   deterministic id, `Kioku.Memory.record` returning the same id means the crash-window
   re-execution found the prior write, which is precisely the idempotency we want.

4. Update call sites: `atRiskCustomerFlow` — `recall "risk-history" (riskQuery activity)`
   (line 43), `remember "acknowledged" ...` (line 52), `remember "declined" ...` (line 55),
   `remember "escalated" ...` (line 59); `FlowLifecycleSpec.memoryFlow` (lines 178-187) —
   `remember "note" ...`, `recall "note-back" ...`. Update
   `shikigami-core/src/Shikigami/Agent/Workflow.hs:runFlowBehavior` only if type inference
   requires (the interpreter stack there, lines 302-307, already runs under
   `Workflow :> es`).

5. Add the crash-window test: a small flow that remembers under label `"only"`; run it
   once; then simulate the lost-append window by calling the interpreter's underlying
   record function directly with the same deterministic id (or, more honestly, delete the
   `remember:only` row from the step index is not possible through public API — instead
   run a second workflow id pointing at the same deterministic-id inputs is wrong too;
   simplest honest version: call `recordFlowMemory` twice with the same computed id and
   assert one active row and a `Right` result both times). Also update the M1 test — it now
   passes — and add a step-index assertion: after the acknowledged at-risk run,
   `loadStepIndex` contains `remember:acknowledged` and `recall:risk-history`.

Acceptance: M1's test is green; the step index shows labeled memory steps; the whole suite
passes.

Milestone 3 — remove ambient IO from flows. In
`shikigami-core/src/Shikigami/Flow/Acknowledgement.hs` (or `Flow/Capability.hs`; prefer
keeping the Ack types where they live) add the capability:

```haskell
data Acknowledgement :: Effect where
  AwaitAcknowledgement :: StepName -> ApprovalRequest -> Acknowledgement m Ack

awaitAck :: (Acknowledgement :> es) => StepName -> ApprovalRequest -> Eff es Ack

runAcknowledgement ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  ApprovalEnv -> NominalDiffTime -> Eff (Acknowledgement : es) a -> Eff es a
```

whose interpreter delegates to the existing `awaitAcknowledgement`. Then narrow
`shikigami-core/src/Shikigami/Flow.hs:28` to

```haskell
type FlowEffects es =
  (Workflow :> es, Memory :> es, Sink :> es, Activity :> es, Acknowledgement :> es)
```

and update: `atRiskCustomerFlow`'s signature and its `awaitAcknowledgement approval ...`
call (the `ApprovalEnv` and deadline move from flow arguments into `runAcknowledgement`'s
environment, so `atRiskCustomerFlow` loses its first two parameters and
`flowRegistry`/`runFlowBehavior` apply `runAcknowledgement (approval runtime)
(acknowledgementDeadline runtime)` in the interpreter stack —
`shikigami-core/src/Shikigami/Agent/Workflow.hs:302-307` and the FlowLifecycleSpec harness
`runFlowBody` lines 246-261). The `Workflow` constraint stays so flows keep pure named
`step`s (e.g. `classify`, `AtRiskCustomer.hs:44`); without `IOE`, `liftIO` in a flow body
no longer typechecks — that is the guardrail. The FlowLifecycleSpec `sleepFlow`
(lines 202-206) uses `sleepNamed`, which requires `Store`+`IOE`; rewrite that spec flow to
run against the interpreter stack's full row (it is a harness-level spike, not a registry
flow — give it its own local constraint instead of `FlowEffects`). Acceptance: a flow body
containing `liftIO (putStrLn "x")` fails to compile (verify by attempt, do not commit);
suite green.

Milestone 4 — metadata options. In `Flow/Capability.hs`:

```haskell
data RememberOptions = RememberOptions
  { priority   :: !Int,
    confidence :: !Confidence,
    memoryType :: !MemoryType,
    supersedes :: !(Maybe MemoryId),
    extraTags  :: !(Set Text)
  }

defaultRememberOptions :: RememberOptions   -- 100 / MediumConfidence / MemoryPattern / Nothing / empty

rememberWith :: (Memory :> es) => Text -> RememberOptions -> Value -> Eff es MemoryId
```

`remember label = rememberWith label defaultRememberOptions`. The interpreter threads the
options into `RecordMemoryData` (replacing the constants at lines 98-110; `extraTags` union
the existing `["flow", focus]` tags). Add a spec: a flow records with
`rememberWith "constraint" opts` where opts set `MemoryConstraint`, priority 10,
`HighConfidence`, and supersedes the id returned by an earlier `remember` in the same flow;
assert via `Kioku.Memory.getMemoryRowById`/`getActiveRowsByScope` that the metadata landed
and the superseded row is no longer active (kioku's supersession lives in the record
command's `supersedes` field, `Memory/Domain.hs:52`). Acceptance: spec green; defaults
unchanged for existing call sites (assert one pre-existing flow memory still records
priority 100 / medium / pattern).


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shikigami` inside `nix develop`.

```bash
nix develop
cabal build all
cabal test shikigami-core-test
```

Iterate on the flow specs only:

```bash
cabal test shikigami-core-test --test-options='-p FlowLifecycle'
```

For M1, capture the red run; expected failure shape:

```text
FlowLifecycle
  replaying a completed flow does not duplicate its memory: FAIL
    expected exactly one acknowledged memory row, got 2
```

After M2 the same command reports `OK`. After each milestone run the full battery:

```bash
cabal build all
cabal test all
```

When adding the `mmzk-typeid` dependency, edit
`shikigami-core/shikigami-core.cabal` (`build-depends: mmzk-typeid >=0.7`) and re-run
`cabal build all`; the package is already in the project's package set (kioku-api depends
on it), so no freeze/index changes are expected.


## Validation and Acceptance

Accepted when the following behaviors are observable:

1. Dedup on replay: run the at-risk flow to acknowledged completion, re-invoke the same
   workflow id, and `Kioku.Memory.getActiveRowsByScope (agentScope "at-risk-customer")`
   shows exactly one "acknowledged" memory row. Exact command:
   `cabal test shikigami-core-test --test-options='-p "duplicate its memory"'` → OK.
   Reverting the `runMemory` change makes it fail with a count of 2.
2. Journaled recall: after any flow run that recalls, `loadStepIndex` for the workflow
   contains `recall:<label>` and a second invocation returns identical recall results even
   after new memories are inserted between runs (test inserts a decoy memory via
   `Kioku.Memory.record` between run one and the replay and asserts the replayed flow
   output is unchanged).
3. Crash-window idempotency: recording twice with the same deterministic id yields one
   active row and success both times.
4. Guardrail: `FlowEffects` no longer includes `IOE` or `Store`
   (`shikigami-core/src/Shikigami/Flow.hs:28`), and a scratch flow body with `liftIO`
   fails to compile.
5. Metadata: the M4 spec observes priority/confidence/type/supersedes as sent; existing
   flows still record priority 100, MediumConfidence, MemoryPattern, no supersedes.
6. `cabal test all` green, including plan 24's WorkflowVersioning spec and the untouched
   AgentWorkflowSpec dedup test (`AgentWorkflowSpec.hs:115-159`).


## Idempotence and Recovery

All steps are code-and-test changes; builds and tests can be repeated freely, and every
test provisions its own migrated database via `withShikigamiMigratedDatabase`. The runtime
change is deploy-safe without sequencing: journaling memory operations adds new step names
only (see Decision Log), and deterministic ids only narrow behavior (fewer rows written).
Rolling back the deploy restores the old duplicating behavior but corrupts nothing: step
entries named `remember:<label>`/`recall:<label>` in journals written by the new code are
simply never read by the old interpreter (orphaned journal entries are inert in keiro). The
`mmzk-typeid` dependency addition is safely re-runnable. If M3's constraint narrowing turns
out to break an out-of-tree flow author, the recovery is to re-add the constraint alias
`FlowEffectsIO` temporarily rather than reverting the interpreter work; record any such
retreat in the Decision Log.


## Interfaces and Dependencies

Hard dependencies: plans 36, 39, and 24. Generated artifacts stay behind plan 39's
firewall; the handwritten memory interpreter fills typed holes.

Dependencies: `keiro` (`Keiro.Workflow`: `step`, `StepName`, `currentWorkflow`,
`currentRunGeneration`), `kioku` (`Kioku.Memory.record/getMemoryRowById/getActiveRowsByScope`,
`Kioku.Memory.Domain.RecordMemoryData`, `Kioku.Api.Types.{MemoryType, Confidence}`,
`Kioku.Id.{MemoryId, idText}`), `mmzk-typeid` (NEW direct dependency of `shikigami-core`;
`Data.KindID.V7.decorateKindID`), `uuid` (`Data.UUID.V5.generateNamed`, already a
transitive pattern used in `Agent/Workflow.hs:30`). Plan 24's
`Shikigami.Workflow.Versioning` module governs run options; this plan adds no patch id.

Signatures that must exist at the end (full module paths):

```haskell
-- shikigami-core/src/Shikigami/Flow/Capability.hs
recall        :: (Memory :> es) => Text -> MemoryQuery -> Eff es [MemoryRecord]
remember      :: (Memory :> es) => Text -> Value -> Eff es MemoryId
rememberWith  :: (Memory :> es) => Text -> RememberOptions -> Value -> Eff es MemoryId
data RememberOptions   -- priority, confidence, memoryType, supersedes, extraTags
defaultRememberOptions :: RememberOptions
runMemory :: (Workflow :> es, IOE :> es) => MemoryEnv -> Eff (Memory : es) a -> Eff es a
deterministicFlowMemoryId :: WorkflowName -> WorkflowId -> Int -> Text -> MemoryId

-- shikigami-core/src/Shikigami/Flow/Acknowledgement.hs
awaitAck :: (Acknowledgement :> es) => StepName -> ApprovalRequest -> Eff es Ack
runAcknowledgement :: (Workflow :> es, Store :> es, IOE :> es)
                   => ApprovalEnv -> NominalDiffTime
                   -> Eff (Acknowledgement : es) a -> Eff es a

-- shikigami-core/src/Shikigami/Flow.hs
type FlowEffects es =
  (Workflow :> es, Memory :> es, Sink :> es, Activity :> es, Acknowledgement :> es)
```

Consumers to keep compiling: `shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs`,
`shikigami-core/src/Shikigami/Agent/Workflow.hs` (`runFlowBehavior` interpreter stack),
`shikigami-core/test/Shikigami/FlowLifecycleSpec.hs`, and plan 27's future
`Shikigami.Sink.Intent` (unaffected, but shares `Flow/Capability.hs` imports).


## Revision Notes

- 2026-07-22: Added the checked Keiro DSL as a hard prerequisite and made labeled memory
  steps part of the specification/scaffold/harness/diff acceptance gate.
- [ ] Prerequisites: plans 36, 39, and 24 complete; update `domain/shikigami.keiro` for every new labeled durable step.
