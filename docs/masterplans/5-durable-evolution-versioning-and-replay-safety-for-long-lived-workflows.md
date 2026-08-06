---
id: 5
slug: durable-evolution-versioning-and-replay-safety-for-long-lived-workflows
title: "Durable Evolution: Versioning and Replay Safety for Long-Lived Workflows"
kind: master-plan
created_at: 2026-07-08T20:13:36Z
intention: "intention_01kx1tytnwe53rdd4es99ztv1p"
---

# Durable Evolution: Versioning and Replay Safety for Long-Lived Workflows

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Shikigami runs agents as durable keiro workflows: every meaningful step of an agent run is
journaled to Postgres under a step name, and a crashed or suspended run resumes by replaying
the journal instead of re-running side effects. That foundation (laid by
`docs/plans/7-agent-runs-as-durable-keiro-workflows.md`) works for a workflow whose code
never changes while instances are in flight. It does not survive its own evolution. Today
there is no versioning anywhere in shikigami: `FlowDef` has no version field
(`shikigami-core/src/Shikigami/Flow.hs:41-45`), the agent-run workflow name is a bare
constant (`shikigami-core/src/Shikigami/Agent/Workflow/Name.hs:9`), the flow `emitSignal`
capability derives journal step names from a per-run in-memory counter that shifts across
deploys (`shikigami-core/src/Shikigami/Flow/Capability.hs:116-127`), and the flow memory
capability bypasses the journal entirely (`Flow/Capability.hs:88-114`), so a replayed flow
re-runs memory writes and re-reads memory nondeterministically. Meanwhile the danwa
conversation workflow is an infinite loop whose journal grows forever and whose kioku
session never completes (`shikigami-core/src/Shikigami/Agent/Conversation.hs:139-148`), and
the sink-intent and run-lifecycle machinery exists in duplicated copies that can silently
drift apart (`shikigami-core/src/Shikigami/Flow/SinkOutbox.hs` vs
`shikigami-core/src/Shikigami/Agent/Workflow.hs`, and
`shikigami-core/src/Shikigami/Agent/Run.hs:55-132` vs the durable lifecycle).

keiro already provides the missing primitives — `patch` for branching in-flight instances
away from fresh ones, and `continueAsNew` for rotating an unbounded journal onto a fresh
generation (`keiro/src/Keiro/Workflow.hs`, in the keiro checkout at
`/Users/shinzui/Keikaku/bokuno/keiro`) — and shikigami calls neither.

After this initiative, an operator can redeploy shikigami while agent runs, flows, and danwa
conversations are suspended mid-flight, and those instances resume correctly under the new
code. Before implementation, a checked `domain/shikigami.keiro` specification inventories
workflow names, stable steps, patches, timers, awakeables, and continue-as-new boundaries;
CI rejects drift between that specification and the harness/scaffold. In-flight
instances take the old code path where the shape changed (guarded by keiro
`patch`), fresh instances take the new path, and no journaled step is ever silently replayed
into the wrong position. Flows can remember and recall memory without duplicating writes on
replay. A danwa conversation ends on idle timeout (completing its kioku session), rotates
its journal every N turns so replay stays fast forever, and delivers racing messages without
treating the routine case as an error. Finally, the sink-intent encoding and the run
lifecycle each live in exactly one module, with a wire-format regression test, so the
duplication that would defeat all of the above is removed.

In scope: a written versioning discipline for workflow step evolution, adoption of keiro
`patch`/`continueAsNew` and run-options plumbing, replay-stable step names for the flow
Sink and Memory capabilities, journaled and idempotent flow memory operations, conversation
lifecycle management (idle timeout, journal rotation, indexed session resolution, race
smoothing), and consolidation of the duplicated SinkIntent/run-lifecycle code with
conformance and wire-format tests. Out of scope: behavior retry semantics and per-turn
behavior timeouts (owned by `docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md`
under MasterPlan 3), sink delivery truth and downstream idempotency (owned by
`docs/plans/19-sink-delivery-truth-and-downstream-idempotency.md` under MasterPlan 3,
with a documented integration point below), memory distillation/retention and the fate of
the unused `sharedScope` (owned by
`docs/plans/34-memory-lifecycle-distillation-retention-and-shared-scope.md` under
MasterPlan 7), and any multi-version plugin/registration system for flows beyond a minimal
registry module with load-time validation.


## Decomposition Strategy

The initiative decomposes into a checked-DSL foundation plus four functional concerns,
each independently deliverable and verifiable:

First, plan 39 inventories the durable topology in `domain/shikigami.keiro`, checks and
scaffolds it, wires generated artifacts behind a firewall with typed implementation
holes, and adds a CI diff gate. It does not generate business logic.

Second, the versioning mechanism itself (EP-1, plan 24). Everything else in this MasterPlan
changes the journaled step structure of workflows that may have instances in flight, so the
discipline (what step changes are safe, when to use `patch`, when to use `continueAsNew`,
how to name steps) and the plumbing (threading `WorkflowRunOptions.activePatches` through
every `runWorkflow` call site and the resume worker) must exist first. Plan 24 also fixes
the one capability whose step naming is deploy-fragile today (`emitSignal` ordinals) because
that fix defines the caller-supplied-label convention the other plans reuse, and adds
load-time validation that a declared `Flow{name}` resolves in the flow registry.

Third, replay safety of flow memory (EP-2, plan 25). This is a self-contained correctness
hole — flow `remember`/`recall` are raw IO, not journaled steps — whose fix (journaled
steps with stable labels, deterministic memory ids) depends on plan 24's label convention
and discipline but on nothing else. It is separable from the conversation work because it
changes the `Memory` capability and its interpreter, not the conversation loop.

Fourth, the conversation workflow lifecycle (EP-3, plan 26). The danwa conversation is the
one workflow that actually lives long enough for journal growth and code evolution to hurt,
so it is the first consumer of `continueAsNew` and the discipline. It is a distinct
functional concern (conversation semantics: idle timeout, session completion, message
racing) that can be built and tested independently once plan 24's mechanism exists.

Fifth, consolidation (EP-4, plan 27). Duplicated SinkIntent machinery and run lifecycles
are how versioning discipline gets silently violated: a fix applied to one copy and not the
other changes wire format or step semantics for half the system. Consolidation is mostly
code motion that must preserve journaled step names and JSON wire format byte-for-byte, so
it soft-depends on plan 24's discipline document but does not need its mechanism.

Alternatives considered: a single monolithic plan was rejected because it would span four
distinct concerns and well over ten files with independent test surfaces. Folding the
memory-capability fix (25) into the versioning plan (24) was rejected because 24 is the
critical path for two other plans and should stay small; 25 has its own red/green test
story. Making consolidation (27) the first plan was rejected because its main risk —
accidentally changing step names or wire bytes — is exactly what plan 24's discipline
document and step-name inventory exist to police; landing the discipline first makes the
consolidation reviewable against it.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| F0 | Upgrade Shikigami to the keiro 0.11 and keiki 0.9 cohort | docs/plans/53-upgrade-shikigami-to-the-keiro-0-11-and-keiki-0-9-cohort.md | cross-MP: plans 36 ✅, 47 ✅ | None | Not Started (blocked: no published `kioku` admits keiro 0.11 / keiki 0.9; kioku is being updated) |
| F1 | Adopt a checked Keiro DSL specification and evolution gate | docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md | F0; cross-MP: plans 36 ✅, 47 ✅ | None | Not Started (author against keiro-dsl 0.11 language 4, so F0 first) |
| 1 | Flow versioning with keiro patch and continue-as-new | docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md | F1 | None | Not Started |
| 2 | Replay-safe flow memory capabilities | docs/plans/25-replay-safe-flow-memory-capabilities.md | F1, EP-1; cross-MP: plan 47 | None | Not Started |
| 3 | Conversation workflow lifecycle: idle timeout, journal rotation, session completion | docs/plans/26-conversation-workflow-lifecycle-idle-timeout-journal-rotation-session-completion.md | F1, EP-1; cross-MP: plan 47; upstream Kioku IR-2 | None | Not Started |
| 4 | Consolidate sink-intent and run-lifecycle machinery | docs/plans/27-consolidate-sink-intent-and-run-lifecycle-machinery.md | F1; cross-MP: plan 47 | EP-1; cross-MP: plan 19 (MasterPlan 3), plan 28 (MasterPlan 6) | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

F1 follows the package architecture in plan 36 and is the first durable-workflow gate.
Every EP must keep `domain/shikigami.keiro`, the generated scaffold, the typed holes,
and the handwritten harness in sync. EP-1 then delivers three artifacts the others
consume: the versioning discipline document (`docs/workflow-versioning.md`), the
`Shikigami.Workflow.Versioning` module (the process-wide `activePatches` set and the
`WorkflowRunOptions`/`WorkflowResumeOptions` values threaded into every workflow run and
the resume worker), and the caller-supplied-label convention for capability step names
(established by the `emitSignal` fix).

EP-2 hard-depends on F1 and EP-1. It converts flow `remember`/`recall` into journaled keiro steps,
which changes the journaled step structure of a workflow type (`shikigami.agent-run` running
a Flow behavior) that can have suspended instances in flight across a deploy. It needs
EP-1's discipline to reason about that change (purely additive steps need no patch guard),
EP-1's label convention for its `remember:<label>` / `recall:<label>` step names, and EP-1's
patch plumbing available in case implementation reveals a non-additive edge. It also edits
the same module (`shikigami-core/src/Shikigami/Flow/Capability.hs`) whose `Sink` effect
EP-1 re-signatures; serializing them avoids conflicting capability API changes.

EP-3 hard-depends on F1 and EP-1. Journal rotation via `continueAsNew` requires EP-1's run-options
plumbing (the rotation outcome must be handled by callers that today treat `ContinuedAsNew`
as an error, `shikigami-core/src/Shikigami/Agent/Conversation.hs:105`), and restructuring
the turn loop changes step ordering in the longest-lived workflow in the system, which must
be shipped behind EP-1's patch discipline so in-flight conversations survive the deploy.

EP-4 hard-depends on F1 and soft-depends on EP-1: consolidation must preserve journaled step names and the
SinkIntent wire format byte-for-byte, and EP-1's discipline document is the standard the
consolidation diff is reviewed against. EP-4 can start any time (its work is code motion
plus tests) but should land after the discipline exists and after cross-MasterPlan plans
19 and 28 have settled delivery semantics and trace context. EP-2 and EP-3 can proceed in
parallel with each other once EP-1 is complete; EP-4 can proceed in parallel with EP-2 and
EP-3 as long as merge order into `shikigami-core/src/Shikigami/Agent/Workflow.hs` and
`shikigami-core/src/Shikigami/Flow/Capability.hs` is coordinated (see Integration Points).

Cross-MasterPlan edges: plan 19 (MasterPlan 3) changes SinkIntent semantics, plan 28
(MasterPlan 6) adds trace context, and EP-4 moves the SinkIntent code. Preferred landing
order is plans 19 and 28 before EP-4 so the final machinery moves once. Plans 15, 17, and 23 (MasterPlans 2, 3, 4)
all touch `shikigami-core/src/Shikigami/Agent/Workflow.hs`; once EP-1 lands, every change to
journaled step structure in that file must follow `docs/workflow-versioning.md`. Plan 35
(MasterPlan 7) now hard-depends on EP-1 before changing the durable delegation path. This is
the MasterPlan-5 slice of the canonical MP-2 through MP-7 waves in MasterPlan 2.


## Integration Points

Checked durable topology (`domain/shikigami.keiro`): plan 39 owns the authoritative
inventory, checker/scaffolder invocation, generated-artifact firewall, typed holes,
harness, and CI diff gate. Plans 24–27 update the DSL and its stable identifiers in the
same change as any handwritten workflow change. Generated code may call typed holes;
it may not own provider selection, authorization, database transactions, or other
business decisions.

Flow capability effect signatures (`shikigami-core/src/Shikigami/Flow/Capability.hs`):
EP-1 changes the `Sink` effect (`EmitSignal` gains a caller-supplied stable label) and EP-2
changes the `Memory` effect (`Recall`/`Remember` gain labels and options and become
journaled). EP-1 defines the label convention (a short, stable, human-chosen `Text` that
becomes the step-name suffix, e.g. `emit-signal:alert`); EP-2 must reuse exactly that
convention (`remember:<label>`, `recall:<label>`). Both plans update the same flow author
call sites (`shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs`); land EP-1 first, then
EP-2 extends.

Versioning plumbing (`shikigami-core/src/Shikigami/Workflow/Versioning.hs`, new in EP-1):
EP-1 defines `shikigamiActivePatches :: Set PatchId`, `shikigamiWorkflowRunOptions`, and
`shikigamiWorkflowResumeOptions`, and rewires `runAgentRunWorkflow`
(`Agent/Workflow.hs:140-153`), `runConversationWorkflow` (`Agent/Conversation.hs:186-200`),
and the worker's resume loop (`shikigami-core/src/Shikigami/Worker.hs:86-101`) through
them. EP-2 and EP-3 add patch ids to that set if and when they need a guarded branch;
they never call `runWorkflow` with default options directly.

SinkIntent wire format and outbox identity: today defined twice, identically —
`shikigami-core/src/Shikigami/Flow/SinkOutbox.hs:33-159` and
`shikigami-core/src/Shikigami/Agent/Workflow.hs:96-106,442-583`. EP-4 owns extracting the
single module `Shikigami.Sink.Intent` and the golden wire-format test. EP-1 (emitSignal
labels) and EP-3 (conversation replies) both produce SinkIntents through this machinery but
do not change its encoding; plan 19 changes its semantics and plan 28 adds trace context.
Both land before EP-4; the golden fixture test is the drift tripwire while the settled
fields and behavior move into the shared module.

Journaled step-name inventory: EP-1's discipline document includes the inventory of every
step name shikigami journals today (agent-run lifecycle steps, conversation per-turn steps,
approval/acknowledgement steps, capability steps). EP-2, EP-3, and EP-4 must update that
inventory when they add or restructure steps, and EP-4 must show its consolidation leaves
the inventory unchanged.

Conversation ingress and workflow identity (`shikigami-core/src/Shikigami/Agent/Conversation.hs`
and `shikigami-core/src/Shikigami/Worker.hs:143-162`): owned by EP-3. EP-1 only notes the
existing `ContinuedAsNew` pattern-match sites (`Worker.hs:192`, `Conversation.hs:105`);
EP-3 changes their behavior. Every idle timer is versioned or explicitly cancelled
when a new turn arrives, and stale timer completions are ignored by generation/token;
otherwise an old timer can terminate an active conversation after journal rotation.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-1 M1: Versioning discipline document `docs/workflow-versioning.md` written, with step-name inventory and AGENTS.md pointer.
- [ ] EP-1 M2: `Shikigami.Workflow.Versioning` module; all workflow entry points and the resume worker run through shared `WorkflowRunOptions` with `activePatches`.
- [ ] EP-1 M3: `emitSignal` takes caller-supplied stable labels; in-flight ordinal scheme preserved behind `patch`.
- [ ] EP-1 M4: Load-time flow registry validation (validate CLI and worker boot reject unknown `Flow{name}`).
- [ ] EP-1 M5: Deploy-simulation test green: workflow started under old shape resumes under new shape with the patch guard.
- [ ] EP-2 M1: Failing test demonstrating duplicated flow memory on replay (red).
- [ ] EP-2 M2: `remember`/`recall` journaled as labeled keiro steps with deterministic memory ids; red test green.
- [ ] EP-2 M3: `IOE`/`Store` removed from flow-facing `FlowEffects`; `Acknowledgement` capability added.
- [ ] EP-2 M4: `rememberWith` metadata options (priority, confidence, memoryType, supersedes) delivered.
- [ ] EP-3 M1: Session-first ingress with indexed session resolution (kioku subjectRef query) and epoch-capable workflow identity.
- [ ] EP-3 M2: versioned/cancelled idle-timeout timer ends only the intended idle generation and completes the kioku session.
- [ ] EP-3 M3: Journal rotation via `continueAsNew` every N turns; generation-aware delivery and result loading.
- [ ] EP-3 M4: Racing-message smoothing (pre-armed next-message awakeable; busy-path is not an error).
- [ ] EP-4 M1: `Shikigami.Sink.Intent` shared module extracted; both former copies deleted; golden wire-format round-trip test.
- [ ] EP-4 M2: `agent-run` CLI drives the durable workflow; `runAgentWithMemory` retired.
- [ ] EP-4 M3: keiki lifecycle conformance test (flow branches accepted by the transducer).
- [ ] EP-4 M4: Cross-plan reconciliation with plans 19 and 28 documented and verified; sharedScope disposition noted for plan 34.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Discovered during MasterPlan authoring (2026-07-08): conversation input delivery and
  result loading hard-code journal generation 0
  (`shikigami-core/src/Shikigami/Agent/Conversation.hs:208` and `:233` pass `0` to
  `loadStepIndex`), so adopting `continueAsNew` without fixing them would silently break
  message delivery after the first rotation. Folded into EP-3's scope as a required fix.
- Discovered during MasterPlan authoring (2026-07-08): kioku has no subjectRef-indexed
  session query (`kioku-core/src/Kioku/Session.hs` exports only `getByScope` and friends;
  `SessionsByScopeQuery` filters scope fields only), so EP-3's indexed session resolution
  requires a small kioku-side read-model addition rather than a shikigami-only change.
- Fleet conformance audit (2026-07-22): the Keiro DSL checker/scaffolder can make the
  durable topology reviewable before code changes, but only if generated artifacts stay
  behind a firewall and CI compares them with the checked-in specification.
- Runtime-pattern audit (2026-07-22): an idle timeout that is merely re-armed leaves a
  stale completion able to end a later active turn. Plan 26 now requires cancellation or
  generation/version validation, including across continue-as-new.


## Decision Log

- Decision: Put plan 47 before the checked Keiro DSL and every durable workflow change, and
  gate subject-reference session resolution on Kioku IR-2.
  Rationale: Keiro 0.4 changes state-shape and queue codec contracts, while indexed session
  lookup belongs in Kioku rather than an unbounded Shikigami scan.
  Date: 2026-07-30


Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Add plan 39 as the checked-DSL foundation; plan 24 remains the versioning
  mechanism foundation. Plans 24–27 hard-depend on the DSL gate, 25/26 hard-depend on
  24, and 27 soft-depends on 24.
  Rationale: 25 and 26 both change journaled step structure of workflow types with
  in-flight instances and need the patch discipline and stable-label mechanism 24 creates;
  27 is code motion whose safety criterion (byte-for-byte step names and wire format) is
  defined by 24's discipline document but whose code does not require 24's artifacts.
  Date: 2026-07-08
- Decision: Fix the `emitSignal` ordinal fragility in plan 24 (the mechanism plan) rather
  than in plan 25 (the capability plan).
  Rationale: the fix defines the caller-supplied stable-label convention and is the worked
  example of a `patch`-guarded cross-cutting change; plan 25 reuses both.
  Date: 2026-07-08
- Decision: Keep the flow registry a hardcoded in-code list; deliver only load-time
  validation (validate CLI + worker boot) in this MasterPlan.
  Rationale: shikigami has exactly one registered flow today
  (`shikigami-core/src/Shikigami/Flow.hs:57-64`); a plugin/registration system has no
  second consumer yet, while unknown-flow-at-run-time
  (`shikigami-core/src/Shikigami/Agent/Workflow.hs:299-301`) is a real, cheap-to-close
  failure mode.
  Date: 2026-07-08
- Decision: Defer the per-turn behavior timeout for conversations to plan 17 (MasterPlan 3)
  and only reference it from EP-3.
  Rationale: plan 17 owns behavior retry/timeout semantics for all behaviors; duplicating a
  timeout mechanism for the conversation path would create the same class of divergence
  EP-4 exists to remove.
  Date: 2026-07-08
- Decision: Leave `sharedScope` (`shikigami-core/src/Shikigami/Memory/Scope.hs:21-22`)
  untouched; EP-4 records it as dead code and defers the remove-or-use decision to
  `docs/plans/34-memory-lifecycle-distillation-retention-and-shared-scope.md` (MasterPlan 7).
  Rationale: whether cross-agent shared memory exists is a memory-lifecycle product
  decision, not a consolidation concern.
  Date: 2026-07-08
- Decision: Plan 27 lands after plans 19 and 28, and plan 35 hard-depends on plan 24.
  Rationale: consolidation should move final delivery/trace semantics once, while
  delegation must change a durable workflow only after patch plumbing and the step-name
  inventory exist.
  Date: 2026-07-22
- Decision: Every durable-topology change updates `domain/shikigami.keiro` and passes
  checker, scaffold, harness, and generated-diff gates before merge.
  Rationale: stable workflow identifiers are an externally persisted compatibility
  surface; review must compare declared intent with executable wiring.
  Date: 2026-07-22
- Decision: Conversation idle timers are cancelled or generation-versioned, and stale
  completions are harmless across normal turns and continue-as-new.
  Rationale: re-arming alone is insufficient in a durable journal and can terminate a
  newly active conversation.
  Date: 2026-07-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)


## Revision Notes

- 2026-07-30: Added plan 47, current Keiro 0.4 compatibility gates, and Kioku IR-2 for the
  indexed conversation-session milestone.

- 2026-07-22: Ordered plan 27 after plans 19 and 28 and made plan 24 an explicit
  prerequisite of MasterPlan 7's delegation work. This aligns the durable-evolution
  initiative with the canonical MP-2 through MP-7 execution waves.
- 2026-07-22: Added plan 39 as the checked Keiro DSL foundation, made all durable plans
  consume its evolution gate, and corrected plan 26's idle timeout to require stale-
  timer cancellation or generation validation.
- [ ] F1 M1–M4: durable topology inventory, checked Keiro DSL, scaffold/harness, and CI
      drift gate from plan 39 are complete.
