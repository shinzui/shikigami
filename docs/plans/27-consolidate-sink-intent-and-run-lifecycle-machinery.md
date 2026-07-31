---
id: 27
slug: consolidate-sink-intent-and-run-lifecycle-machinery
title: "Consolidate sink-intent and run-lifecycle machinery"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tytnwe53rdd4es99ztv1p"
master_plan: "docs/masterplans/5-durable-evolution-versioning-and-replay-safety-for-long-lived-workflows.md"
---

# Consolidate sink-intent and run-lifecycle machinery

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Two pieces of shikigami exist as duplicated copies today, and duplication here is not a
style nit — it is a correctness time bomb for durable workflows. The "sink intent" — the
serialized record of an agent's intent to emit a signal, written to a transactional outbox
and later published — is defined byte-identically in TWO modules: the flow path
(`shikigami-core/src/Shikigami/Flow/SinkOutbox.hs`) and the agent-run path
(`shikigami-core/src/Shikigami/Agent/Workflow.hs`). Both produce integration events that the
SINGLE publisher decodes (`publishSinkIntent`), so if the two copies ever drift — a field
added to one, a JSON encoding tweaked in the other — the publisher fails to decode intents
from the diverged copy, marks them `PublishFailed`, and dead-letters real agent signals.
Separately, the agent run lifecycle (open session → recall → run behavior → record learning
→ complete/fail) exists twice: the durable workflow version
(`shikigami-core/src/Shikigami/Agent/Workflow.hs`) and a non-durable version
(`runAgentWithMemory`, `shikigami-core/src/Shikigami/Agent/Run.hs`) used only by the
`agent-run` demo CLI, with subtly different failure-path semantics. And the keiki lifecycle
transducer for the at-risk flow is a parallel artifact that nothing checks the flow against.

After this plan, the sink-intent wire contract has exactly one generated definition from
plan 39's checked Keiro DSL, re-exported behind the hand-owned `Shikigami.Sink.Intent` vertical with
a golden round-trip test that fails if the wire format ever changes, so the two producers
and the one consumer can never silently disagree. The `agent-run` CLI drives the same
durable lifecycle as the worker (or shares the exact same lifecycle functions), so there is
one definition of what an agent run does and one failure-path behavior. The at-risk flow is
checked against its keiki lifecycle transducer by a conformance test (or the transducer is
explicitly documented as illustrative). None of this changes any journaled step name or any
byte of the sink wire format — it is behavior-preserving consolidation, verified by tests.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: encode the existing sink-intent contract in `domain/shikigami.keiro`, regenerate its
      structural type/codec, consolidate hand-owned prepare/enqueue/id behavior in
      `Shikigami.Sink.Intent`, delete both former copies, and add golden wire tests.
- [ ] M2: Unify the run lifecycle — `agent-run` CLI drives the durable workflow (or shares
      lifecycle functions); retire `runAgentWithMemory`'s divergent copy.
- [ ] M3: keiki lifecycle conformance test for the at-risk flow (or documented as
      illustrative).
- [ ] M4: Record the plan-19 reconciliation step and the sharedScope note for plan 34;
      full suite green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Consolidation must leave plan 39's checked Keiro topology and generated
  scaffold diff unchanged except for intentional owner/module wiring.
  Rationale: code motion must not silently rename durable steps, patches, timers, or
  awakeables.
  Date: 2026-07-22

- Decision: Plan 39's generated module owns the `SinkIntent` structural wire type and codec;
  a hand-owned `Shikigami.Sink.Intent` module under the existing `Shikigami.Sink.*` namespace
  re-exports it and owns preparation, deterministic identity, enqueue, and publish behavior.
  Re-export the names the two call sites need so
  their import surface barely changes.
  Rationale: the machinery is sink-domain, not flow- or agent-workflow-specific; both
  current homes are accidental, and a third hand-written structural definition would violate
  the generated-code firewall. Keeping the exported names (`enqueueSinkIntentStep`,
  `prepareSinkIntent`, `preparedSinkResult`, `enqueuePreparedSinkIntentTx`,
  `publishSinkIntent`, `PreparedSinkIntent`, `SinkIntent`) stable minimizes the diff.
  Date: 2026-07-08
- Decision: Make the `agent-run` CLI call the durable workflow against the database, rather
  than keeping a parallel non-durable lifecycle.
  Rationale: the two lifecycles have "subtly different failure-path semantics" (the CLI copy
  fails the session on behavior error and returns `Left`; the durable copy journals a
  `fail-session` step and returns `Left` inside a `Completed` outcome) — exactly the kind of
  silent divergence this plan removes. One lifecycle is easier to reason about than a shared
  helper that both call, and the CLI is a demo tool, so the durable path's extra journaling
  is acceptable. If driving the full worker workflow from the CLI proves too heavy, the
  fallback is to extract the shared lifecycle steps (open/recall/record/complete) into
  functions both call; record which path was taken.
  Date: 2026-07-08
- Decision: Deliver the keiki conformance check as a test asserting the flow's emitted
  state transitions are a subset of the transducer's accepted language, using keiki's input
  acceptor; if that proves impractical, document the transducer as illustrative in the flow
  module header instead.
  Rationale: keiki exposes `inputAcceptor`/`accepts`
  (`/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Acceptor.hs`) over a transducer's command
  language, so the at-risk lifecycle's command sequence (classify → acknowledge/deadline)
  can be checked for acceptance; the flow's branches
  (`shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs:41-60`) map onto those commands. A
  real check is better than a comment, but the fallback keeps the plan unblocked if the
  mapping is lossy.
  Date: 2026-07-08
- Decision: Do not remove or repurpose `sharedScope`; only note it.
  Rationale: `sharedScope` (`shikigami-core/src/Shikigami/Memory/Scope.hs:21-22`) is dead
  code, but whether shikigami should have cross-agent shared memory is a product decision
  owned by `docs/plans/34-memory-lifecycle-distillation-retention-and-shared-scope.md`
  (MasterPlan 7). Deleting it here would preempt that plan.
  Date: 2026-07-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to `/Users/shinzui/Keikaku/bokuno/shikigami` unless noted; keiki (the
pure symbolic-register transducer library) is at `/Users/shinzui/Keikaku/bokuno/keiki`
(locate with `mori registry show keiki --full`). This plan soft-depends on plan 24
(`docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md`): consolidation
must preserve journaled step names and the sink wire format byte-for-byte, and plan 24's
`docs/workflow-versioning.md` (with its step-name inventory) is the standard this
plan's diff is reviewed against. Plan 24 need not be merged first, but the discipline
document is the acceptance yardstick.

The duplicated sink intent, verified. `SinkIntent` is declared identically in two places:
`shikigami-core/src/Shikigami/Flow/SinkOutbox.hs:33-43` and
`shikigami-core/src/Shikigami/Agent/Workflow.hs:96-106` — the same seven fields (`agent`,
`runId`, `ordinal`, `occurredAt`, `danwaTarget`, `sink`, `output`), the same
`deriving (Eq, Show, Generic)` + `anyclass (ToJSON, FromJSON)`. Both modules also duplicate
`PreparedSinkIntent`, `prepareSinkIntent`, `preparedSinkResult`,
`enqueuePreparedSinkIntentTx`, `sinkIntentEvent`, and `deterministicOutboxIdForMessage`
(`SinkOutbox.hs:45-159` vs `Agent/Workflow.hs:108-559`), plus `enqueueSinkIntentStep`
(`SinkOutbox.hs:50-81` vs `Agent/Workflow.hs:442-473`). The flow copy's
`enqueueSinkIntentStep` is called by the flow Sink capability
(`shikigami-core/src/Shikigami/Flow/Capability.hs:39,124`); the agent-run copy is called by
the conversation reply path (`shikigami-core/src/Shikigami/Agent/Conversation.hs` via
`AgentWorkflow.prepareSinkIntent`, lines 399-414) and the agent-run sink dispatch
(`Agent/Workflow.hs:enqueueSinkIntents`, lines 386-440, a bulk variant). The SINGLE
consumer is `publishSinkIntent` (`Agent/Workflow.hs:561-583`): it decodes the outbox event
with `decodeJsonIntegrationEvent` and, on failure, returns
`PublishFailed (Text.pack (show err))` (line 565) — which the outbox publisher
(`shikigami-core/src/Shikigami/Worker.hs:103-112`) turns into a dead-letter. The integration
event is stamped with `eventType = "shikigami.sink.dispatch-requested"`, `schemaVersion = 1`
(`SinkOutbox.hs:131-152`, identical in `Agent/Workflow.hs:523-544`). The two copies are
equal today; nothing enforces that they stay equal.

The duplicated run lifecycle, verified. The durable version lives in
`shikigami-core/src/Shikigami/Agent/Workflow.hs`: `runResolvedAgent` (lines 164-205) journals
`open-session` (`openSession`, 248-275), `recall` (line 175), `run-behavior`,
`dispatch-sinks`, `record` (`recordLearning`, 585-605), `complete` (`completeSession`,
607-618), and on behavior error `fail-session` (`failSession`, 374-384). The non-durable
version is `runAgentWithMemory` (`shikigami-core/src/Shikigami/Agent/Run.hs:55-132`): it
opens a session, recalls prior learnings, runs the behavior, and on `Left` fails the session
and returns `Left`, on `Right` records the learning and completes. Same shape, but: it is
plain IO with no journaling (no crash resume), and its metadata and error handling are
hand-written in parallel (e.g. it always returns `Left` on behavior failure, whereas the
durable path returns `Right`-wrapped-`Left` inside a `Completed` outcome and journals the
failure). Its ONLY caller is the demo CLI `agent-run`
(`shikigami-cli/src/Shikigami/Cli/Commands/AgentRun.hs:14,54`). `runAgentWithMemory` also
duplicates the hardcoded memory metadata (`Run.hs:99-112`) that
`recordLearning`/`Agent/Workflow.hs:590-603` hardcodes.

The keiki lifecycle transducer, verified. `shikigami-core/src/Shikigami/Flow/Lifecycle/AtRiskCustomer.hs`
builds `atRiskCustomerLifecycle`, a `SymTransducer` with states
`Observed | SettledLow | AwaitingAck | Acknowledged | Escalated` and commands
`ClassifyLowRisk | ClassifyHighRisk | Acknowledge | DeadlineExpired` (lines 28-70). It is
used only to render a Mermaid diagram and produce validation warnings
(`Flow.hs:50-55`, surfaced by the `render-lifecycle` CLI and the FlowLifecycleSpec diagram
tests, `FlowLifecycleSpec.hs:52-61`). Nothing checks that the actual flow
(`shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs`) only makes transitions the
transducer permits: the flow classifies (low → return; high → emit + await ack), and on ack
resolves, on decline declines, on timeout escalates (lines 41-60) — a command sequence that
SHOULD be a subset of the transducer's language, but nothing asserts it. keiki's
`Keiki.Acceptor` (`/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Acceptor.hs:34-45`) exposes
`inputAcceptor :: SymTransducer ... -> Acceptor ...` and
`accepts :: Acceptor s a -> [a] -> Bool`, which answer exactly "is this command sequence in
the transducer's input language?".

`sharedScope` (`shikigami-core/src/Shikigami/Memory/Scope.hs:17-22`) is exported but has no
non-test caller (`rg sharedScope` finds only its definition and export); it is dead code.


## Plan of Work

Milestone 1 — one sink intent contract and module. First update
`domain/shikigami.keiro` with the exact deployed event type, schema version, fields, JSON
names, and outbox relationship, run `check`/`diff`, and regenerate through plan 39. The
generated module owns `SinkIntent` and its codec; do not edit it. Create the hand-owned
`shikigami-core/src/Shikigami/Sink/Intent.hs` vertical by moving the shared behavior there:
`PreparedSinkIntent`, `prepareSinkIntent`, `preparedSinkResult`,
`enqueuePreparedSinkIntentTx`, `enqueueSinkIntentStep`, `sinkIntentEvent`,
`deterministicOutboxIdForMessage`, and the bulk `enqueueSinkIntents` and the
`sinkMessageId`/`deterministicOutboxId` helpers currently in `Agent/Workflow.hs:386-559`.
Also move `publishSinkIntent`'s decode half — the `SinkIntent`-from-event decoding — but
keep `publishSinkIntent` itself where its `AgentRunDeps` dependency lives, or move the whole
function and pass the sink configs explicitly; choose the smaller diff and record it. Then:

- Delete `shikigami-core/src/Shikigami/Flow/SinkOutbox.hs` entirely and change its importer
  `shikigami-core/src/Shikigami/Flow/Capability.hs:39` to
  `import Shikigami.Sink.Intent (enqueueSinkIntentStep)`.
- Delete both hand-written `SinkIntent` definitions and the moved helpers from
  `shikigami-core/src/Shikigami/Agent/Workflow.hs`; import the type from the generated module
  through
  `Shikigami.Sink.Intent`; re-export from `Agent/Workflow.hs` if downstream modules import
  those names from there today (`Conversation.hs` imports `AgentWorkflow.prepareSinkIntent`
  etc. — either repoint those imports to `Shikigami.Sink.Intent` or keep the re-export; the
  re-export is the smaller diff).
- Register the hand-owned and generated modules per plan 39's firewall in
  `shikigami-core/shikigami-core.cabal`; remove
  `Shikigami.Flow.SinkOutbox` from the module list.
- Add the golden test `shikigami-core/test/Shikigami/SinkIntentSpec.hs` (register in
  `test/Main.hs`): construct a representative `SinkIntent` for each `Sink` constructor
  (KizashiSignal, KawaDigest, DanwaConversation, and any ReiAction variant), encode it to
  the integration event via `sinkIntentEvent`, decode it back with
  `decodeJsonIntegrationEvent`, and assert equality (`decode . encode == id`). Additionally
  pin the ON-THE-WIRE JSON: encode one canonical `SinkIntent` to `Aeson.encode` and compare
  against a checked-in expected `ByteString` (a golden string in the test), so a field
  rename or reordering is caught even if it round-trips. Assert the event's `eventType` is
  `"shikigami.sink.dispatch-requested"` and `schemaVersion` is `1`. This is the tripwire
  that makes future drift impossible to land silently. The generated domain harness and DSL
  evolution diff are part of the same acceptance gate.

Acceptance: `cabal build all` succeeds; `rg "data SinkIntent" shikigami-core/src` finds
exactly one generated definition and no hand-written definition; deterministic scaffold and
domain-harness checks pass; the FlowLifecycleSpec sink tests
(`FlowLifecycleSpec.hs:83-97`) and AgentWorkflowSpec outbox assertions still pass unchanged
(same outbox message ids, same delivered details) — proving the wire format and
deterministic ids are byte-for-byte preserved; the new golden test passes.

Milestone 2 — one run lifecycle. Retire the divergent copy. Preferred path: change
the `agent-run` command component assigned to `shikigami-workers` by plan 36 so the non-activity branch (currently line 54 in the legacy module,
`runAgentWithMemory appEnv behEnv decl Aeson.Null`) instead constructs an `AgentRunDeps`
(as the worker does, `shikigami-core/src/Shikigami/Worker.hs:194-206`) and calls
`AgentWorkflow.runAgentRunWorkflow deps job` with a synthesized `RunJob` (idempotency key
derived from the agent name plus a fresh id so repeated CLI runs are distinct workflows),
then renders the `AgentRunResult` from the `Completed` outcome the same way the CLI renders
it today (recalled priors, recorded learning). This makes the demo CLI exercise the real
durable path. Delete `runAgentWithMemory` from `shikigami-core/src/Shikigami/Agent/Run.hs`
and its export (lines 13, 55-132), keeping the still-used helpers there
(`behaviorKindText`, `recallPriorLearnings`, `recallQuery`, `renderLearning`,
`recordActivityAsMemory`, `renderMemoryRecord` — all imported elsewhere). If wiring the full
`AgentRunDeps` into the CLI (sink configs, approval env) proves disproportionate for a demo
command, take the fallback: extract the four lifecycle actions the two share into small
functions in `Agent/Run.hs` (e.g. `openRunSession`, `recordRunLearning`, `completeRunSession`,
`failRunSession`) and have BOTH `runAgentRunWorkflow`'s steps and a slimmed
`runAgentWithMemory` call them, so there is one definition of each lifecycle action even if
two orchestrators remain. Record which path was taken in the Decision Log and Surprises.
Acceptance: `agent-run` CLI still prints an across-run report (recalled priors grow across
repeated invocations); `rg "runAgentWithMemory" shikigami` returns no hits (preferred path)
or only shared-helper call sites (fallback); behavior on a failing behavior is now the
single durable semantics.

Milestone 3 — keiki conformance. Add
`shikigami-core/test/Shikigami/FlowLifecycleSpec.hs` cases (the transducer lives in the
module this spec already imports) that build the at-risk lifecycle's input acceptor
(`Keiki.Acceptor.inputAcceptor atRiskCustomerLifecycle`) and assert each command sequence a
flow branch produces is accepted: `[ClassifyLowRisk]` (low-risk return),
`[ClassifyHighRisk, Acknowledge]` (acknowledged), `[ClassifyHighRisk, DeadlineExpired]`
(escalated), and assert a NON-sequence is rejected (e.g. `[Acknowledge]` from `Observed`).
Then add a mapping note: a short comment in
`shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs` stating which flow branch corresponds
to which transducer command, so the correspondence is documented at the source. If the flow
cannot be mechanically mapped to commands (the flow does not currently name its transitions),
fall back to documenting the transducer as illustrative in the
`Flow/Lifecycle/AtRiskCustomer.hs` module header and skip the acceptance test — but attempt
the real check first. Acceptance: the conformance test passes (or the illustrative
documentation is in place with a Decision Log note explaining why the mechanical check was
not feasible).

Milestone 4 — cross-plan reconciliation and notes. Two documentation deliverables and a
verification. First, verify that plan 19's delivery semantics and plan 28's trace-context
fields are present before extracting the shared module. Move both into
`Shikigami.Sink.Intent`, and use the golden wire-format test from M1 as the shared tripwire.
Second, add a
note (a comment at `Shikigami.Memory.Scope.sharedScope` and a line in this plan) that
`sharedScope` is dead code whose removal-or-use is deferred to
`docs/plans/34-memory-lifecycle-distillation-retention-and-shared-scope.md` (MasterPlan 7)
— do not change it. Acceptance: the notes exist; `cabal test all` is green.


## Concrete Steps

All commands from `/Users/shinzui/Keikaku/bokuno/shikigami` inside `nix develop`.

```bash
nix develop
cabal build all
cabal test all           # capture the pre-change baseline
```

After M1, prove the wire format is unchanged by running the sink-touching specs plus the new
golden test:

```bash
cabal test shikigami-core-test --test-options='-p "SinkIntent"'
cabal test shikigami-core-test --test-options='-p "FlowLifecycle"'
cabal test shikigami-core-test --test-options='-p "AgentWorkflow"'
```

Confirm single definitions:

```bash
rg -n "data SinkIntent" shikigami-core/src        # expect exactly one hit
rg -n "runAgentWithMemory" shikigami              # after M2: no hits (preferred path)
```

Exercise the CLI after M2:

```bash
just create-database
cabal run shikigami-agent-run -- at-risk-customer   # prints an across-run report; run twice, priors grow
```

Finish:

```bash
cabal build all
cabal test all
```

Expected shape of the new golden test output:

```text
SinkIntent
  round-trips every sink constructor through the outbox event: OK
  canonical intent encodes to the pinned wire bytes:            OK
```


## Validation and Acceptance

Accepted when these behaviors hold:

1. Single sink-intent definition: `rg "data SinkIntent" shikigami-core/src` returns one
   generated hit; `shikigami-core/src/Shikigami/Flow/SinkOutbox.hs` no longer exists; both
   former call sites import through `Shikigami.Sink.Intent`; DSL check, deterministic scaffold,
   domain harness, and evolution diff pass.
2. Wire format preserved: the AgentWorkflowSpec outbox assertions
   (`AgentWorkflowSpec.hs:60-65,113-114,210-211`) and FlowLifecycleSpec sink assertions
   (`FlowLifecycleSpec.hs:83-97`) pass unchanged — same outbox message ids and delivered
   details — and the new golden test's pinned-bytes assertion passes. Deliberately changing
   a `SinkIntent` field name in a scratch edit makes the golden test fail (verify once, do
   not commit).
3. Single run lifecycle: the `agent-run` CLI drives the durable workflow (or shared
   lifecycle functions); `runAgentWithMemory`'s divergent copy is gone; behavior-failure
   semantics are the single durable version.
4. keiki conformance: the acceptor test passes (accepted command sequences accepted,
   invalid rejected), or the transducer is documented as illustrative with a rationale.
5. Notes: the plan-19 reconciliation and the sharedScope deferral are recorded.
6. `cabal test all` green.


## Idempotence and Recovery

All work is checked-spec/code motion plus tests; builds and tests repeat safely, and each DB-backed test
provisions its own migrated database. The M1 extraction is behavior-preserving by the checked
specification plus byte-level golden tests and is verified by the unchanged outbox
assertions, so there is no data-migration or deploy-ordering hazard: existing outbox rows
and journals decode identically because the codec bytes are unchanged. If M1 accidentally
alters the wire format (caught by the golden test or the spec outbox assertions), revert the
offending edit, correct the spec/schema mapping or hand-owned wiring, and regenerate; never
patch the generated file. M2 changes only a demo command's code path; rolling it back
restores the old non-durable behavior with no persistent effect. M3 and M4 are tests and
documentation, always safe to redo. Because this plan changes no journaled step names (it is
the plan whose acceptance criterion is that names and bytes are unchanged), it introduces no
`patch` and needs no versioning guard — it is the discipline's beneficiary, not a change the
discipline governs.


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 19, 24, 28, 39, and 47. Consolidate only after terminal
outbox semantics, trace context, and Keiro 0.4 wire fixtures have settled, so the code moves once.
The golden SinkIntent and workflow fixtures from plan 47 are mandatory acceptance evidence.


## Interfaces and Dependencies

Hard dependencies: plans 36 and 39. The checked DSL/harness is the topology tripwire;
plans 19 and 28 remain preferred semantic predecessors.

Dependencies: `keiro` (`Keiro.Outbox`, `Keiro.Integration.Event`,
`Keiro.Workflow` journal-append helpers — all already used by the code being moved),
`keiki` (`Keiki.Acceptor.{inputAcceptor, accepts}`, `Keiki.Core.SymTransducer` — keiki is
already a transitive dependency via the lifecycle module), `kioku` (unchanged session/memory
helpers retained in `Agent/Run.hs`). No new package dependencies.

Signatures that must exist at the end (full paths):

```haskell
-- plan-39 generated module, re-exported by Shikigami.Sink.Intent
data SinkIntent          -- agent, runId, ordinal, occurredAt, danwaTarget, sink, output

-- shikigami-core/src/Shikigami/Sink/Intent.hs (hand-owned behavior)
data PreparedSinkIntent
prepareSinkIntent        :: WorkflowId -> StepName -> Text -> Text -> Int
                         -> Maybe UTCTime -> Maybe DanwaTarget -> Sink -> Value -> UTCTime
                         -> IO PreparedSinkIntent
preparedSinkResult       :: PreparedSinkIntent -> SinkResult
enqueuePreparedSinkIntentTx :: PreparedSinkIntent -> Tx.Transaction ()
enqueueSinkIntentStep    :: (Workflow :> es, Store :> es, IOE :> es)
                         => StepName -> Text -> Text -> Int -> Maybe UTCTime
                         -> Maybe DanwaTarget -> Sink -> Value -> Eff es SinkResult
sinkIntentEvent          :: Text -> Text -> UTCTime -> SinkIntent -> IntegrationEvent
deterministicOutboxIdForMessage :: Text -> OutboxId

-- shikigami-core/src/Shikigami/Agent/Run.hs (runAgentWithMemory removed; helpers kept)
behaviorKindText, recallPriorLearnings, recallQuery, renderLearning,
recordActivityAsMemory, renderMemoryRecord   -- unchanged, still exported
```

Consumers to keep compiling: `shikigami-core/src/Shikigami/Flow/Capability.hs` (imports
`enqueueSinkIntentStep`), `shikigami-core/src/Shikigami/Agent/Conversation.hs` (imports
`prepareSinkIntent`, `preparedSinkResult`, `enqueuePreparedSinkIntentTx` — repoint or via
re-export), `shikigami-core/src/Shikigami/Worker.hs` (`publishSinkIntent` for the outbox
publisher), and the `agent-run` component in `shikigami-workers` (rewired in M2).

Integration Points (cross-plan):

- Plan 19 (`docs/plans/19-sink-delivery-truth-and-downstream-idempotency.md`, MasterPlan 3)
  changes SinkIntent SEMANTICS (delivery truth, downstream idempotency), and plan 28 adds
  trace context. This plan changes LOCATION. Both should land first; move their settled
  fields and behavior into `Shikigami.Sink.Intent` and use the M1 golden test as the wire
  tripwire. Implementing earlier is possible, but landing earlier creates avoidable code
  motion and a second reconciliation pass.
- Plan 26 (`docs/plans/26-conversation-workflow-lifecycle-...`, this MasterPlan) uses the
  conversation reply path that builds SinkIntents (`Conversation.hs:391-414`). Coordinate
  merge order so the reply path imports the single `Shikigami.Sink.Intent` module; no
  semantic conflict.
- Plan 34 (`docs/plans/34-memory-lifecycle-distillation-retention-and-shared-scope.md`,
  MasterPlan 7) owns the fate of `sharedScope`; this plan only notes it.


## Revision Notes

- 2026-07-22: Replaced the either-order rule with the preferred landing order plans
  19 and 28 → plan 27. Consolidation now moves the final delivery and trace semantics
  once instead of moving old code and rebasing it immediately.
- 2026-07-22: Added plan 39 as a hard predecessor and made topology/scaffold diff
  stability an explicit consolidation acceptance criterion.
- [ ] Prerequisites: plans 36 and 39 complete; plans 19 and 28 land before final consolidation.
