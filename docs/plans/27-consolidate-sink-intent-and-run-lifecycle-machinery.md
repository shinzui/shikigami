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

After this plan, the sink-intent wire contract has exactly one hand-owned definition in
`Shikigami.Sink.Intent`, with a golden round-trip test that fails if the wire format ever changes,
so the two producers
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

- [x] (2026-08-23T18:08:27Z) M1: consolidated the two `SinkIntent` copies into one hand-owned `Shikigami.Sink.Intent`
      module, together with prepare/enqueue/id behavior, delete both former copies, and keep
      `WireCompatSpec`'s byte-identity fixtures green. **Revised 2026-08-19: this is a Haskell
      consolidation, not a regeneration** — the specification cannot own the type's codec until a
      declared node consumes it. `cabal build all`, the three SinkIntent tests, all 20
      FlowLifecycle tests, all 44 AgentWorkflow tests, and `just keiro-gate HEAD` pass; the
      scaffold is unchanged and `rg "data SinkIntent" shikigami-core/src` returns one hit.
- [x] (2026-08-23T18:17:36Z) M2: Unified the run lifecycle — `agent-run` now synthesizes a
      distinct `RunJob`, constructs `AgentRunDeps`, and drives `runAgentRunWorkflow`; the
      divergent `runAgentWithMemory` and `runAgentWithMemoryUsing` copies are deleted.
      All 29 `shikigami-agent` tests pass, `rg "runAgentWithMemory"` returns no hits, and two
      isolated CLI runs recalled zero then one prior memory while recording a learning each time.
- [x] (2026-08-23T18:20:23Z) M3: Added a Keiki input-acceptor conformance test for the
      at-risk flow's three modelled branch sequences plus an invalid-order rejection, and
      documented the branch-to-command mapping beside the flow body. All 21 FlowLifecycle
      tests pass.
- [ ] M4: Record the plan-19 reconciliation step and the sharedScope note for plan 34;
      full suite green.
- [x] (2026-08-23T17:53:54Z) Implementation preflight: verified plans 19, 36, 39, and
      47 complete; verified plan 28's trace context is present in both sink-intent
      copies; `nix develop -c cabal build all` and `nix develop -c cabal test all -j1`
      passed on the untouched implementation (460 core tests, 81 worker tests, and all
      other repository and Keiro conformance suites green).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The record-pattern instruction path in `AGENTS.md` has moved from
  `core/record-patterns.md` to `patterns/core/record-patterns.md`. Mori's
  `mori registry docs shinzui/haskell-jitsurei` reported the current canonical
  document as `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`; the
  moved document was read before editing Haskell records.
- Plans 19 and 28 have materially expanded both duplicated sink paths since this
  plan was drafted: each copy now carries `principalId`, `resolvedRecipient`, a
  pending delivery receipt, and `IntegrationEvent.traceContext`. Evidence:
  `rg -n "principalId|resolvedRecipient|traceContext|deliveryReceipt"` over
  `Shikigami.Agent.Workflow` and `Shikigami.Flow.SinkOutbox` finds the same
  fields and preparation behavior in both copies. The consolidation must move
  these settled semantics together rather than reproduce the older seven-field
  sketch in this plan.
- The new golden is a real wire-compatibility tripwire: a scratch codec edit that renamed
  `runId` to `run_id` made only the pinned-byte assertion fail, showing the exact old and new
  payloads. Restoring `omitNothingFields` with the original field names made all three focused
  SinkIntent tests pass again. The scratch edit was not committed.
- The existing development database could not accept current migrations because its recorded
  checksum for `kioku/0011-kioku-memory-space-partition` differs from the current dependency.
  CLI acceptance therefore used a fresh `shikigami_plan27_cli` database, ran the current complete
  migration set, executed twice successfully, and then removed that isolated database. The stale
  existing database was not changed.
- The concrete at-risk flow also has a `Declined` acknowledgement branch, while the illustrative
  Keiki transducer has no decline command or state. The source mapping now states that boundary;
  this plan tests the three sequences the transducer actually claims rather than silently implying
  coverage of the unmodelled branch. Expanding the lifecycle alphabet would be a modelling change,
  not consolidation.


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
  **Half superseded 2026-08-19 — there is no generated module, and there will not be one until a
  declared node consumes the type.** Plan 39 landed and found that an unconsumed `mapped
  structural` declaration generates a shape, a binding skeleton, projections, and conformance
  assertions but *no codec*, so declaring `SinkIntent` would certify a JSON policy nothing
  executes. The `Shikigami.Sink.Intent` half of this decision stands and is now the whole of it:
  that module owns a single hand-written `SinkIntent` with its existing `genericToJSON`
  `omitNothingFields` encoding. See the reconciliation section at the end of this plan.
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

- Decision: Keep transport dispatch in `Shikigami.Agent.Workflow`, where `AgentRunDeps` owns
  sink client configuration, but move the integration-event decoder and all intent preparation,
  identity, receipt, and enqueue behavior to `Shikigami.Sink.Intent`. The bulk enqueue helper
  accepts the already-resolved agent/job values instead of importing workflow-private `RunJob`
  helpers.
  Rationale: this removes both structural and behavioral duplication without introducing an
  import cycle or moving process-level HTTP configuration into the sink contract module. The
  journaled `dispatch-sinks` label, message ids, ordering keys, delivery receipts, trace context,
  and publisher behavior remain unchanged.
  Date: 2026-08-23

- Decision: Take M2's preferred full-workflow path. The CLI builds the same durable dependencies
  as the worker, with a disabled principal directory for its historical one-off semantics and a
  local observation-only workspace capability runtime authorized in `Durable` mode. Empty overlay
  declarations still avoid workspace discovery.
  Rationale: session failure, profile resolution, capability resolution, memory recording, and
  workflow outcomes now have one implementation. The one-off package remains light because its
  new direct `keiro` edge adds no Kafka, queue-adapter, worker-loop, or telemetry-export package.
  Date: 2026-08-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

M1 removed 560 lines of duplicated sink contract and enqueue machinery while preserving the
deployed JSON bytes, event identity, journal labels, deterministic ids, trace context, recipient
resolution, and delivery receipts. The shared module is hand-owned deliberately: Keiro's checked
workspace still declares only contracts whose generated artifacts the runtime executes. A
scratch `runId` wire rename proved the new golden detects field-policy drift.

M2 removed the second session orchestrator rather than factoring smaller lifecycle helpers. The
CLI now creates a fresh workflow identity for each invocation and reports every terminal or
nonterminal `WorkflowOutcome`. Its existing human report is unchanged on success, including
across-run recall; an isolated two-run check observed the second run recall the first learning.

M3 made the useful portion of the illustrative Keiki lifecycle executable as a specification:
low risk, acknowledged high risk, and timed-out high risk are accepted, while acknowledgement
before classification is rejected. The nearby mapping note keeps the correspondence—and its
explicit decline limitation—visible when the flow changes.


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

Milestone 1 — one sink intent contract and module. Keep the sink outbox undeclared, as required by
ADR 0001: the current HTTP publisher is not a generated Keiro contract publisher, so a generated
shape would not describe the codec the runtime executes. Create the hand-owned
`shikigami-core/src/Shikigami/Sink/Intent.hs` vertical by moving the single `SinkIntent` definition
and all shared behavior there:
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
- Delete the former hand-written `SinkIntent` definition and moved helpers from
  `shikigami-core/src/Shikigami/Agent/Workflow.hs`; import the type through
  `Shikigami.Sink.Intent`; re-export from `Agent/Workflow.hs` if downstream modules import
  those names from there today (`Conversation.hs` imports `AgentWorkflow.prepareSinkIntent`
  etc. — either repoint those imports to `Shikigami.Sink.Intent` or keep the re-export; the
  re-export is the smaller diff).
- Register the hand-owned module in `shikigami-core/shikigami-core.cabal`; remove
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
  that makes future drift impossible to land silently. The unchanged generated domain harness
  and DSL evolution diff remain part of the workflow-topology acceptance gate.

Acceptance: `cabal build all` succeeds; `rg "data SinkIntent" shikigami-core/src` finds
exactly one hand-written definition in `Shikigami.Sink.Intent`; deterministic scaffold and
domain-harness checks pass; the FlowLifecycleSpec sink tests
(`FlowLifecycleSpec.hs:83-97`) and AgentWorkflowSpec outbox assertions still pass unchanged
(same outbox message ids, same delivered details); the new golden test passes.

A note on why byte-for-byte preservation is still the acceptance here (added 2026-08-10).
Shikigami has no users, so there is no stored outbox row and no external consumer whose
compatibility is at stake — the usual reason for this criterion does not apply. It is still the
right criterion, for a different reason: this milestone's entire claim is that it is *code
motion*. Two definitions become one and nothing else changes. Byte-identical outbox ids and
delivered details are the only evidence that the consolidation did not quietly pick one copy's
behavior over the other's, which is exactly the failure a de-duplication of two independently
drifted definitions invites. So do not relax this to "equivalent" or update a golden to match new
output — if the bytes move, the two copies had drifted and that divergence needs a decision of
its own, recorded in the Decision Log, before consolidation proceeds. What *does* relax is the
consequence of a deliberate change: if a drift is found and the better shape is the other copy's,
this plan may adopt it and move the golden, in its own commit, with the reason written down. That
would not have been available while real consumers existed.

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
cabal run shikigami-agent-run -- --agent agents/detectors/at-risk-customer-flow.dhall
# Run the same command twice: the report's recalled-prior count grows.
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
   hand-owned hit; `shikigami-core/src/Shikigami/Flow/SinkOutbox.hs` no longer exists; both
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
workflow topology gate plus byte-level golden tests and is verified by the unchanged outbox
assertions, so there is no data-migration or deploy-ordering hazard: existing outbox rows
and journals decode identically because the codec bytes are unchanged. If M1 accidentally
alters the wire format (caught by the golden test or the spec outbox assertions), revert the
offending edit and correct the hand-owned wiring; never patch the generated workflow files. M2
changes only a demo command's code path; rolling it back
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
helpers retained in `Agent/Run.hs`). M2 adds `keiro` as a direct dependency of the lightweight
`shikigami-agent` package because its CLI handles a `WorkflowOutcome`; it was already in the
repository dependency cohort.

Signatures that must exist at the end (full paths):

```haskell
-- shikigami-core/src/Shikigami/Sink/Intent.hs (hand-owned wire contract and behavior)
data SinkIntent          -- agent, principalId, runId, ordinal, occurredAt,
                         -- danwaTarget, resolvedRecipient, sink, output
data PreparedSinkIntent
prepareSinkIntent        :: DirectoryHandle -> GrantSource -> Maybe Text
                         -> WorkflowId -> StepName -> Text -> Text -> Int
                         -> Maybe UTCTime -> Maybe DanwaTarget -> Maybe Text
                         -> Sink -> Value -> UTCTime
                         -> IO PreparedSinkIntent
preparedSinkResult       :: PreparedSinkIntent -> SinkResult
enqueuePreparedSinkIntentTx :: PreparedSinkIntent -> Tx.Transaction ()
enqueueSinkIntentStep    :: (Workflow :> es, Store :> es, IOE :> es)
                         => DirectoryHandle -> GrantSource -> Maybe Text
                         -> StepName -> Text -> Text -> Int -> Maybe UTCTime
                         -> Maybe DanwaTarget -> Maybe Text -> Sink -> Value
                         -> Eff es SinkResult
sinkIntentEvent          :: Text -> Text -> UTCTime -> Maybe TraceContext
                         -> SinkIntent -> IntegrationEvent
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


## Revision Notes

- 2026-08-10: Re-grounded Milestone 1's byte-for-byte acceptance now that shikigami has no users.

  The criterion is unchanged; its justification is different, and the difference matters because
  the old justification is void. Preserving outbox message ids and delivered details byte for byte
  was inherited from a compatibility argument — stored rows and downstream consumers — and neither
  exists. It survives because this milestone's whole claim is that it is code motion: two
  independently maintained `SinkIntent` definitions become one and nothing else changes.
  Byte-identity is the only evidence that consolidation did not silently adopt one copy's behavior
  over the other's, which is the characteristic failure of de-duplicating two definitions that may
  have drifted.

  One thing genuinely does relax. If the two copies have drifted and the better shape is the one
  being retired, this plan may now adopt it and move the golden — in its own commit, with the
  reason in the Decision Log. That option did not exist while real consumers did. What remains
  forbidden is updating a golden to match new output without establishing why it moved.


## Reconciliation with the delivered plan 39 (2026-08-19)

`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md` has landed, and
three of its assumptions turned out to be wrong. Anything this plan says that contradicts the
following is superseded.

**The specification is a workspace, not one file.** The service input is
`domain/shikigami.keiro-workspace`, a manifest naming `service shikigami`,
`runtime-package shikigami-core`, and `layout collocated`, plus two members —
`domain/shikigami-agent-run.keiro` and `domain/shikigami-conversation.keiro`. Every file-taking
`keiro-dsl` command takes the manifest and validates the composed service. Every reference to
`domain/shikigami.keiro` in this plan has been repointed; a startability check that looks for the
old path would fail against a repository where plan 39 *is* done.

The manifest declares **no `module` clause**: `context shikigami` already supplies the
`Shikigami` prefix, and adding `module Shikigami` scaffolds `Shikigami.Shikigami.*`. Do not add
one, and do not pass `--module-root` or `--collocate`.

**Shikigami has no aggregate, no read model, no projection, no router, and no process manager.**
Plan 39's Milestone 1 census, with evidence in
`docs/architecture/shikigami-domain-inventory.md`, found that the only Keiro command runner in the
repository targets *kioku's* session stream, and that
`Shikigami.Flow.Lifecycle.AtRiskCustomer` is a Keiki transducer that renders a Mermaid diagram
rather than an event source. The declared surface today is exactly two durable workflows and
their `run` operations.

**Three surfaces are deliberately undeclared, and the reason is binding on this plan too:** do not
certify a schema that differs from the codec actually executed. The `shikigami_run_jobs` queue
keeps its bare `RunJob` payload rather than acquiring Keiro's `{v,t,data}` envelope; the Kafka
inbox and the Danwa contract stay hand-written because a generated contract codec writes a
discriminator into a body that has none; and the sink outbox stays hand-written because its
publisher calls HTTP sinks rather than publishing to Kafka. Declaring any of them is a wire change
that needs its own commit, its own decision, and its own fixture.

**The gate is `just keiro-gate`.** It runs `keiro-check` (with `--min-language 5`,
`--deny-warnings`, and `--fail-on-opaque`), `keiro-inspect` (asserting every member declares its
language at effective version 5), `keiro-scaffold` (regenerate, then `git diff --exit-code`),
`keiro-diff <ref>` (the six-surface evolution classification), and `cabal test
keiro-shikigami-conformance`. Run it before merging any change to `domain/`, to the generated
layer under `shikigami-core/src/Shikigami/*/Generated/`, or to a durable identity. A `BREAKING`
finding exits non-zero and is a deployment gate, not an advisory.

**A workflow label is a wire word.** keiro-dsl parses a `step`, `await`, `sleep`, or `child` label
with `[A-Za-z0-9][A-Za-z0-9_-]*`. A label containing a colon or a value computed at run time
cannot be declared at all. Shikigami's `approval:<SinkKind>:<ordinal>`, `<label>:notify`,
`emit-signal:<ordinal>`, and every per-message conversation label are therefore outside the
specification until the plan that owns them makes them static.

### What changes for this plan — including one premise that is now wrong

**This plan's Decision Log entry "Plan 39's generated module owns the `SinkIntent` structural wire
type and codec" is superseded and must not be followed.** Plan 39 tried to give `SinkIntent` an
owning workspace member and found it cannot, at keiro-dsl 0.13, without certifying a codec nothing
executes.

The evidence is the tool's own. A `mapped structural record SinkIntent` checks clean, but no
declared node consumes it — shikigami has no aggregate, no declared queue payload, and no read
model — so `check --explain-bindings` reports the obligation as "structural type SinkIntent (not
currently used by an aggregate root)" and the coverage report lists zero mapped roots on every
surface. The scaffold then emits a shape module, a create-once binding skeleton, projections, and
conformance assertions, and **no encoder or decoder**. The declaration would state a JSON policy
that the outbox does not use, and it would cost three mapped declarations (`SinkIntent`,
`DanwaTarget`, and the four-constructor `Sink` union) plus three hand-owned binding modules to say
it.

So Milestone 1 of this plan is a **Haskell consolidation, not a regeneration**. Merge
`Shikigami.Agent.Workflow`'s `SinkIntent` (`Agent/Workflow.hs:125-138`) and
`Shikigami.Flow.SinkOutbox`'s copy (`Flow/SinkOutbox.hs:49-58`) into one hand-owned
`Shikigami.Sink.Intent` module — the module cycle that forced the duplication disappears once the
record lives in a leaf — keep `genericToJSON` with `omitNothingFields` so not one byte moves, and
keep `WireCompatSpec` as the guard. The generated modules named in this plan for that purpose do
not exist and will not until a declared node consumes the type; the sink outbox becomes a declared
`emit`/`publisher` only when it publishes to a contract topic rather than calling HTTP sinks.

What survives unchanged: consolidation must not move a golden, and the generated layer is
regenerated rather than edited.
