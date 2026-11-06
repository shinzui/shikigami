---
id: 111
slug: assess-drift-with-a-registered-typed-decision-over-bounded-evidence
title: "Assess drift with a registered typed decision over bounded evidence"
kind: exec-plan
created_at: 2026-11-04T15:58:26Z
intention: "intention_01m6kkgpehed8r75hazq4y7qqj"
master_plan: "docs/masterplans/19-supervise-active-work-with-an-independent-watchdog-agent.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-11-04T15:58:26Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-06T04:40:28Z
      mode: "update"
      note: "Reconciled proposed APIs, ownership and acceptance with current source review."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T14:59:30Z
      mode: "implement"
      note: "Implement bounded typed drift proposal, input-bound validation and root-accounted replay qualification."
---

# Assess drift with a registered typed decision over bounded evidence

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

A worker that keeps producing accepted operations is not stuck, but it may be working on the wrong thing. Deciding that requires judgment, so the request asks for a registered typed decision: a Shikumi program with a typed input, a typed validated output, a pinned model, journaled slots that replay without a second provider call, and accounting against a resource root. After this plan the program `shikigami.watchdog-drift` exists in the compiled decision catalog, a Flow can invoke it at a `Drift` slot with `decide driftStep alias input`, and its answer is a `DriftAssessment` that names each input subject exactly once, places it in one of three closed categories, cites only evidence references that were in the input, and cannot change the subject or invent a reference. A cadence rule selects which progressing subjects are due so that one bounded decision runs per sweep at most, and a small table remembers when each subject was last assessed.

You can see it working in `cabal test shikigami-core-postgres-test --test-options='-p WatchdogDrift'`: a test Flow with the `Drift` slot runs against the stub provider scripted to answer "outside scope" for a fixture worker whose operation tool names contradict the objective's goal, a drift detection with evidence references is recorded, a replay after a crash makes no second provider call, and an answer that names a different subject or an unknown reference is refused and produces no detection. This plan is EP-3 of [MasterPlan 19](../masterplans/19-supervise-active-work-with-an-independent-watchdog-agent.md). It requires plan 109 (`docs/plans/109-observe-active-work-through-bounded-lock-free-reads-under-a-watchdog-grant.md`) to be Complete for the vocabulary and the body-free objective metadata. Plan 110's ledger is a soft dependency: once it exists, drift detections are recorded through it; until then this plan proves its decision with an in-memory assessment fixture.


## Progress

- [x] (2026-11-06) Milestone 1: The `Drift` decision label, the `shikigami.watchdog-drift` program with its input and output types, root-accounting classification and validators are registered, and the unit group proves subject substitution, invented evidence and missing subjects are refused.
- [ ] Milestone 2: A test Flow invokes the slot against the stub provider through the real journaled decision path, replay after a crash makes no second call, and provider calls are accounted against a fixture root.
- [ ] Milestone 3: Cadence selection, the `watchdog_drift_checks` table and the conversion of assessments into `Drift` detections exist, with the settings fields and the authoring guide updated.


M1 acceptance 2026-11-06: all eight drift-program unit groups and the full core
unit suite pass (774 tests). Conventions pass. Compiler controls refuse direct,
Generic, decoded and representation-coerced DriftAssessment construction and
unchecked Rationale construction. The registered descriptor golden is
`sha256:d8d47c490849c498c7b251378221af9eeb47a89b204fde64d60f563aa4ae0705`.
M2's real journal/accounting harness and M3's cadence/settings remain.


## Surprises & Discoveries

EP-1 and EP-2 are Complete at `39c0a7e1`. The registered program API validates
outputs without invocation input, so its result remains an untrusted proposal.
The raw proposal uses canonical subject-key strings and per-subject evidence
indexes; the pure input-bound validator resolves exact references and mints the
assessment. This requires no orphan Shikumi schema instances for owner types.
The fixed catalog subject maximum is 16; a lower configured bound is retained in
the typed input. Drift persistence has an owner-local refusal type, preserving
the soft dependency on EP-2. `dueForDrift` receives liveness-eligible candidates
from EP-4, which owns that classification decision.

Adding the uninvoked Drift label under `Flow/Decision.hs` preserves all existing
labels, result types and branches under workflow-versioning rules 4 and 7. The
production caller, patch and declaration remain EP-4 work. Harness-only callers
use their own undeclared test workflow.


## Decision Log

- Decision: One batched drift decision per sweep, over one objective and at most `driftSubjectsPerSweep` of its subjects, rather than one decision per subject.
  Rationale: A decision slot is static and one-use per generation (ADR 0045), and the watchdog sweep is one generation. A per-subject slot family would turn the limit into a declaration shape; a batch keeps the model call count at most one per sweep and the limit a configuration value.
  Date: 2026-11-04

- Decision: The output validator requires the assessed subject set to equal the input subject set and every cited reference to be a member of that subject's input references.
  Rationale: Acceptance 6 requires that instructions planted in worker output cannot alter a finding's subject or recipient. The input is built from structured facts, so the only channel from worker text into the decision is closed by construction, and the validator closes the output channel.
  Date: 2026-11-04


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a Cabal multi-package Haskell service; `shikigami-core` owns domain code, including the typed decision layer this plan extends. A *typed decision* ([IR-12](../improvement-requests/compose-shikumi-decisions-in-durable-flows.md), plans 73–76) is a registered Shikumi program invoked from a compiled Flow at a named slot. The pieces, all under `shikigami-core/src/Shikigami/`: `Program/Decision.hs` (`RegisteredProgram i o`, `registerProgram`, `registerJudgmentProgram`, `programRef`, `ProgramRegistry`, `ResultCodecRegistry`); `Program/Decision/Registry.hs` (`decisionPrograms` and `decisionCodecs`, the only place programs are registered; duplicate `(programId, version)` pairs are refused and retired programs keep their `retainedCodec`); `Program/Decision/Adaptive.hs` (the shape to copy: a `Predict (mkSignature ...) emptyParams` body, `jsonResultCodec`, bounded-text validators); `Decision/Contract.hs` (`ProgramDescriptor`, `DecisionSlot`, `PreparedDecision`, `DecisionOutcome`, `DecisionCallHooks`); `Flow/Decision.hs` (`DecisionLabel = Triage | Investigation | Judgment | Adaptive | Propose`, `decisionStep`, `decisionSlot`, `decide :: (Decision :> es, ...) => DecisionStep i o -> ModelAlias -> i -> Eff es o`, `refuseDecision`, `runDecision`, `slotLabel`, `decisionStepNames`); `Decision/ModelCatalog.hs` (`resolveModel`, `resolvePolicy`); `Decision/Evidence.hs` (the PostgreSQL call ledger: `decision_runs`, `decision_invocations`, `decision_attempts`); `Decision/Accounting.hs` (`accountedDecisionHooks`, which ties each provider call to the execution root per [ADR 0110](../adr/0110-accepted-typed-decisions-account-for-every-transport-call.md)); `Decision/StubProvider.hs` (`decisionStubProvider :: ApiProvider`, which answers by `modelId`). `Flow/ShikumiJudgmentExample.hs` is the minimal registered example and `agents/proof/shikumi-judgment-example.dhall` the declaration that lists its alias in `decisionModels`. `docs/shikumi-flow-decisions.md` is the authoring guide; research found it still naming a `shikigami-flow-decisions-v1` patch that no longer exists in `domain/` or the generated `declaredPatches`, so correct that sentence when you edit the guide.

How a decision is journaled and why replay never resamples: `decide` journals two Keiro steps named by `decisionStepNames` for the slot, `decision-prepare-<label>` committing the `PreparedDecision` (its identity covers workflow, generation, label, program, model, input and policy) and `decision-result-<label>` committing the whole `DecisionOutcome`; on replay a completed result step returns the stored value through the retained codec without entering the provider ([ADR 0041](../adr/0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md), [ADR 0045](../adr/0045-flow-policy-pins-pending-decisions-and-retains-completed-result-codecs.md)). The whole slot inventory is pinned once in the `decision-policy` step ([ADR 0042](../adr/0042-decision-admission-intersects-operator-agent-and-pinned-profile-authority.md)); an alias the agent does not declare or the operator catalog lacks is refused. Each provider call commits an expectation before dispatch and its terminal evidence after ([ADR 0043](../adr/0043-decision-provider-wrappers-own-actual-attempt-boundaries.md), [ADR 0044](../adr/0044-decision-attempts-persist-expectations-and-consumer-owned-compliance-facts.md)); a lost journal append makes a new attempt visible rather than hiding it. A slot is one-use per generation. Decision step names are declared in `domain/shikigami/agent-run.keiro`; adding the `Drift` label's two steps to the real agent-run body belongs to plan 112's patch, and this plan proves the label with a Flow run under the test harness, which [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md) notes runs under a workflow name no declared member owns and is therefore outside the evolution gate. `runDecisionAccepted` accepts only the `Adaptive` label (its error text is "accepted interpreter requires the adaptive slot"); the watchdog uses the ordinary `runDecision` path, so leave that guard alone.

Testing conventions for decisions are in `shikigami-core/test-postgres/Shikigami/DecisionWorkflowSpec.hs`: a `binding alias version exact` helper builds a `modelBinding` over `stubModel & #modelId .~ exact`; `scriptedProvider` replaces `decisionStubProvider`'s `complete` and `stream`; `services & #providers .~ [handler]` swaps the provider; `crashAt` installs `Agent.defaultAgentRunHooks & #afterStepBody` to crash after a named step; and the cases "completed decisions replay with removed executables, bindings and changed responses" and "a lost result append retains both actual investigation attempts" are the restart precedents to mirror. Plan 109's vocabulary supplies `Subject`, `EvidenceRef`, `DetectionKind` (`Drift` already exists in it), `WatchdogLimit`, `Duration "watchdog-drift"` and the `ObjectiveObservation` fields that are safe to put in a prompt: goal text, criteria metadata, assignment states, accepted operation specifications (operation kind, tool name, target coordinate) and artifact references. [ADR 0070](../adr/0070-objective-receipts-and-integrated-acceptance-share-one-command-owner.md) draws that line: instructions and result bodies are protected; goal, criteria and reference metadata are not. Plan 109 supplies shared `DriftCategory` and the observation vocabulary. Plan 110 owns `Observed`, `Outcome`, `Detection` and `EvidenceSummary`; EP-4 owns conversion from this plan's validated assessments to those ledger values. EP-3 must compile and pass without EP-2. Value rules: [ADR 0080](../adr/0080-opaque-checked-values-do-not-expose-generic-construction.md) and [ADR 0081](../adr/0081-validated-results-use-private-seals-and-public-read-views.md). Migrations follow the procedure in plan 110's Context (`just new-migration`, the lock line, the expected schema regeneration, `just migration-schema-isolation`). FRIC-15 records that authorization tests once shared a process-global model provider key; the decision tests avoid that by swapping the provider per test.


## Plan of Work

### Milestone 1: The label, the program and its validators

In `shikigami-core/src/Shikigami/Flow/Decision.hs` add the constructor `Drift` to `DecisionLabel`, with `slotLabel Drift` rendering `drift` and `decisionStepNames Drift` yielding `decision-prepare-drift` and `decision-result-drift`. Set `decisionAccounting Drift = RootAccountedCall`, following the existing `Propose` arm. This is required: a root on `DecisionEnv` alone does not charge an unaccounted label. Extend every exhaustive label match and preserve all existing labels.

Create `shikigami-core/src/Shikigami/Program/Decision/Drift.hs`:

```haskell
data CriterionSummary = CriterionSummary
  { key :: !CriterionKey
  , description :: !Text
  , kind :: !CriterionKind
  }
  deriving stock (Eq, Show, Generic)

data OperationSummary = OperationSummary
  { position :: !(StateRevision "execution-operation")
  , kind :: !OperationKindSummary
  }
  deriving stock (Eq, Show, Generic)

data DriftSubjectInput = DriftSubjectInput
  { subject :: !Subject
  , assignment :: !(Maybe ObjectiveAssignmentId)
  , operations :: ![OperationSummary]
  , artifacts :: ![EvidenceRef]
  , evidence :: !(NonEmpty EvidenceRef)
  }
  deriving stock (Eq, Show, Generic)

data DriftInput = DriftInput
  { objective :: !ObjectiveId
  , revision :: !(StateRevision "objective")
  , goal :: !Text
  , criteria :: ![CriterionSummary]
  , subjects :: !(NonEmpty DriftSubjectInput)
  }
  deriving stock (Eq, Show, Generic)

-- DriftCategory is imported from EP-1 watchdog vocabulary.

data DriftSubjectAssessment = DriftSubjectAssessment
  { subject :: !Subject
  , category :: !DriftCategory
  , rationale :: !Rationale
  , evidence :: ![EvidenceRef]
  }
  deriving stock (Eq, Show, Generic)

newtype DriftAssessment = DriftAssessment (NonEmpty DriftSubjectAssessment)
  deriving stock (Eq, Show)

driftProgram :: RegisteredProgram DriftInput DriftProposal

validateDriftAssessment :: DriftInput -> DriftProposal -> Either DecisionFailure DriftAssessment
```

`OperationSpec` is a record, not an operation sum. Its `OperationKind` is `ModelTurn | ToolOperation | ModelSummary | ModelRepair | TypedDecision`; it also exposes a tool name, recovery class, policy/scope digests and optional response position. Use these exact metadata fields. There is no repository path, command or child target in that record: remove `target` and the proposed `TargetCoordinate` from this first input schema. Never parse protected tool arguments or result bodies to manufacture one. The fixture uses an out-of-scope tool name or existing artifact reference. Missing evidence produces no drift finding. `Rationale` is a private bounded text (at most 512 characters, no control characters) with a checked parser, following the `decisionFailure` detail bound. The input validator refuses more than `driftSubjectsPerSweep` subjects (use a fixed catalog maximum and include the configured lower bound in the validated input; do not vary a registered descriptor by deployment settings), more than 32 operations per subject, an empty evidence list, or goal text above 4 KiB. The output validator refuses an assessment with duplicate subjects or whose subject set is not exactly the input subject set, an assessment citing a reference that is not in that subject's `artifacts` or `evidence`, an adverse category with no supporting reference, or a rationale that fails its parser. Treat goal and criteria prose as untrusted data too; add an injection test there as well as in excluded bodies. Register the program with `registerProgram` (the output is structured, not a bare closed-set judgment), program id `shikigami.watchdog-drift`, version `1`, a signature instructing the model to compare each subject's operations and artifacts with the goal and criteria and to cite only the given references, `jsonResultCodec`, and add it to both lists in `Program/Decision/Registry.hs`. Create `shikigami-core/test/Shikigami/DriftProgramSpec.hs` with cases for each refusal, a round trip of the input and result codecs, and a golden digest of the program descriptor so an unintended parameter change is visible.

### Milestone 2: The slot in a Flow, replay and accounting

Create `shikigami-core/test-postgres/Shikigami/WatchdogDriftSpec.hs`. Define a harness-only Flow (not registered in `flowRegistry`, like the test spikes ADR 0013 describes) whose `decisionSlots` is `[decisionSlot driftStep [alias]]` with `driftStep = decisionStep Drift (programRef driftProgram)` and whose body builds a `DriftInput` from a fixture `ObjectiveObservation` and `ExecutionObservation` (plan 109's fixtures) and calls `decide driftStep alias input`. Script the stub provider to return an `OutsideScope` assessment citing one of the input references for a fixture execution whose operation tool names contradict the objective's goal. Cases: the Flow returns the assessment and the decision ledger holds one invocation and one attempt; a crash after the result journal append followed by resume yields the same assessment with the provider invocation count still one (count calls in the scripted provider); a scripted answer naming a subject not in the input, or citing a reference not in the input, makes `decide` fail with a `DecisionFailure` and no assessment; an alias absent from the agent's `decisionModels` is refused at `decision-policy` before any call. Accounting: enroll a fixture root with `Shikigami.Execution.Admission.enrollRootRun` on the harness run (the `ExecutionResourcesSpec` fixtures show how), run the Flow through ordinary `runDecision` with `decisionAccounting Drift = RootAccountedCall`, and assert through `ResourcesStore.inspectRoot` that the root's model-attempt counter advanced by one and that an envelope with `ModelAttempts` limited to zero refuses the call before dispatch. Verify the actual dispatch through `rootAccountedDecisionHooks` in `Flow/Decision.hs`, including refusal without a root before preparation or provider IO. The Flow-level root check is additional convenience, not the accounting boundary.

### Milestone 3: Cadence, the checks table and detections

Allocate the next migration with `just new-migration watchdog-drift-checks`; do not reserve 0044 (other initiatives may already own it):

```sql
-- Last drift assessment per subject. Metadata only.
CREATE TABLE IF NOT EXISTS shikigami.watchdog_drift_checks (
  subject_key text PRIMARY KEY,
  objective_id uuid NOT NULL,
  checked_at timestamptz NOT NULL,
  mark_digest text NOT NULL,
  category text NOT NULL,
  sweep_id uuid NOT NULL
);
```

Create `shikigami-core/src/Shikigami/Watchdog/Drift.hs`:

```haskell
data DriftCadence = DriftCadence
  { interval :: !(Duration "watchdog-drift")
  , subjectsPerSweep :: !(WatchdogLimit "drift-subjects")
  }
  deriving stock (Eq, Show, Generic)

data DriftCheck = DriftCheck
  { subject :: !Subject
  , objective :: !ObjectiveId
  , checkedAt :: !UTCTime
  , mark :: !MarkDigest
  , category :: !DriftCategory
  }
  deriving stock (Eq, Show, Generic)

-- | The one objective and its due subjects for this sweep, or nothing. Due means
-- progressing and never checked, or with an elapsed minimum interval;
-- a changed mark does not bypass that interval. Oldest due objective wins.
dueForDrift :: DriftCadence -> UTCTime -> Map SubjectKey DriftCheck -> [SubjectObservation] -> Maybe (ObjectiveId, NonEmpty SubjectObservation)

buildDriftInput :: WatchdogLimit "drift-subjects" -> ObjectiveObservation -> NonEmpty SubjectObservation -> Either Text DriftInput

-- | Turns an assessment into ledger outcomes: 'WithinScope' is 'Clear', the others
-- are 'Detected' with kind 'Drift' and the category in the evidence summary.
-- EP-4 implements the ledger adapter after both prerequisite children complete.
-- EP-3 returns validated DriftCheck values and assessments only.

readDriftChecks :: NonEmpty SubjectKey -> Transaction (Either WatchdogError (Map SubjectKey DriftCheck))
recordDriftChecks :: SweepId -> UTCTime -> NonEmpty DriftCheck -> Transaction (Either WatchdogError ())
```

Add `driftIntervalSeconds` and `driftSubjectsPerSweep` to `WatchdogSettings` (plan 109's record in `shikigami-core/src/Shikigami/App/Config.hs`) and its loader, defaulting to disabled when absent so that a deployment without a drift alias runs stuck detection only. Use EP-1's shared `DriftCategory`; EP-2 includes `driftCategory :: Maybe DriftCategory` from its initial schema in `EvidenceSummary` so a category change is a material change and a return to `WithinScope` closes the episode. Extend `WatchdogDriftSpec`: `dueForDrift` picks nothing when every check is fresh and the marks are unchanged, requires the configured interval to have elapsed even when the mark changed, picks the objective with the oldest check otherwise, and never returns more than the limit; `driftOutcomes` records a `Detected Drift` outcome through plan 110's family-scoped `recordSweepPage` in the EP-4 integration fixture and the resulting finding's evidence equals the assessment's citations; a later `WithinScope` assessment closes the episode. Update `docs/shikumi-flow-decisions.md` with a section on the drift program as the first program whose output is a structured per-subject assessment with an evidence-subset validator, and correct the stale patch sentence.


## Concrete Steps

Run from the repository root; enter `nix develop` if native tools are unavailable.

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
EP3_BASE=$(git rev-parse HEAD)
cabal build shikigami-core
```

After milestone 1:

```bash
just haskell-conventions
cabal test shikigami-core-test --test-show-details=direct --test-options='-p "Drift|Decision"'
```

Expected: the existing decision groups still pass (the registry now has one more program) and `DriftProgramSpec` passes.

After milestone 2:

```bash
cabal test shikigami-core-postgres-test --test-show-details=direct --test-options='-p "WatchdogDrift|DecisionWorkflow" --num-threads 1'
```

Expected: `WatchdogDriftSpec` passes, including the case whose name states that replay makes no second provider call, and the existing `DecisionWorkflowSpec` is unchanged.

After milestone 3:

```bash
just new-migration watchdog-drift-checks
sha256sum shikigami-migrations/sql-migrations/NNNN-watchdog-drift-checks.sql
# append the lock line, then:
just migration-schema-isolation
SHIKIGAMI_REGENERATE_EXPECTED_SCHEMA=1 cabal test shikigami-migrations-smoke
# Rebuild and verify the embedded expected snapshot after regeneration.
cabal test shikigami-migrations-smoke --test-show-details=direct
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-workers-test shikigami-server-test --test-show-details=direct
```

Commit at milestone boundaries with the trailers:

```text
feat(watchdog): assess drift with a registered typed decision

MasterPlan: docs/masterplans/19-supervise-active-work-with-an-independent-watchdog-agent.md
ExecPlan: docs/plans/111-assess-drift-with-a-registered-typed-decision-over-bounded-evidence.md
Intention: intention_01m6kkgpehed8r75hazq4y7qqj
```


## Validation and Acceptance

The request's acceptance 4, with the deterministic provider: a fixture worker that continues to produce accepted operations whose targets lie outside the objective's goal is assessed `OutsideScope`, a `Drift` detection with the cited evidence references is recorded, and no objective row, assignment, checkpoint or receipt changes (assert the objective's revision and the `objective_receipts` count before and after). Acceptance 8, the decision half: a crash after the result step and a resume produce the same assessment with exactly one provider call recorded in `decision_attempts`. Acceptance 6, the decision half: an answer that names a different subject or cites an unknown reference is refused and produces no detection. Required acceptance is the unit and PostgreSQL groups named above plus the full suites exiting zero. Measuring the quality of real model answers is a proposal for plan 113's optional live trial, not acceptance here.


## Idempotence and Recovery

Registering a program is a pure catalog change; the retained codec must stay even if the program is later retired (ADR 0045). The migration is additive. `recordDriftChecks` upserts by subject key and is safe to repeat. If a provider call's terminal write is lost, the ledger shows an unresolved expectation and the next sweep's `dueForDrift` sees a stale check and may try again under its own new attempt; that is the documented behavior of the decision ledger, not something this plan changes. Rolling back the code leaves the program's journaled outcomes decodable through the retained codec.


## Interfaces and Dependencies

This plan owns the `Drift` constructor of `Shikigami.Flow.Decision.DecisionLabel` and its step names, `Shikigami.Program.Decision.Drift` (`DriftInput`, `DriftSubjectInput`, `OperationSummary`, `CriterionSummary`, `DriftSubjectAssessment`, `DriftAssessment`, `Rationale`, `driftProgram`), the registry entries, `Shikigami.Watchdog.Drift` (`DriftCadence`, `DriftCheck`, `dueForDrift`, `buildDriftInput`, `readDriftChecks`, `recordDriftChecks`), migration `NNNN-watchdog-drift-checks`, the settings fields `driftIntervalSeconds` and `driftSubjectsPerSweep`; EP-2 owns its own `EvidenceSummary` field. Plan 112 declares `decision-prepare-drift` and `decision-result-drift` in the agent-run patch, lists the slot in the `watchdog-sweep` `FlowDef`, lists the alias in `agents/proof/watchdog.dhall`, and refuses the slot when the run has no root. It consumes plan 109 unchanged and must be Complete before plan 112 starts. It does not add a Flow to `flowRegistry`, change `runDecisionAccepted`, or declare any step in `domain/`.

Revision 2026-11-05: aligned operation metadata and per-label accounting with current APIs; moved ledger conversion to EP-4 to preserve the soft dependency; distinguished committed-result replay from an uncommitted provider attempt. Test a lost result append separately: recovery may call again, but every call must remain accounted and uncertainty must not be refunded.

The current `Program.Decision.registerProgram` result validator has type `o -> Either Text o`; it cannot compare an output to the invocation input. Register a structurally validated, codec-safe `DriftProposal`, then call pure `validateDriftAssessment input proposal` immediately after `decide` to mint the opaque `DriftAssessment`. This check enforces exact subject cardinality, no duplicates, per-subject evidence membership and nonempty adverse evidence. EP-4 accepts only that seal for conversion to findings. A replay decodes the retained proposal and deterministically revalidates it against the journaled input. Do not claim that the existing registry API provides input-dependent validation, and do not construct a fresh registered program for each sweep. Add tests at this actual proposal-to-assessment boundary.

The reviewed coordination constraints are recorded in [ADR 0116](../adr/0116-watchdog-observation-preserves-completeness-and-detector-boundaries.md); operator-owned spend follows [ADR 0115](../adr/0115-evaluation-spend-is-a-root-enrolled-at-the-trigger-and-accounted-slots-refuse-without-one.md).
