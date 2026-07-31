---
id: 15
slug: inject-recalled-memory-and-trigger-payload-into-behavior-context
title: "Inject recalled memory and trigger payload into behavior context"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tygnxenvarsw91bjsy19r"
master_plan: "docs/masterplans/2-production-reality-de-stub-the-runtime-behavior-and-integration-path.md"
---

# Inject recalled memory and trigger payload into behavior context

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

shikigami's headline promise is that an agent "accumulates knowledge across runs
instead of starting blank each time." The plumbing half-exists: every run durably
recalls the agent's prior learnings from kioku memory before the behavior executes.
But the recalled memories never reach the behavior — the workflow's `recall` step
stores them only in the run's *result* record
(`shikigami-core/src/Shikigami/Agent/Workflow.hs:175` and `197-205`), while the
behavior itself receives only the declaration and the trigger payload
(`shikigami-core/src/Shikigami/Behavior/Run.hs:53-66`). Worse, the `ShikumiProgram`
behavior arm discards even the trigger payload — it parses an empty argument map and
ignores the payload parameter (`Behavior/Run.hs:70-74`). The recall query itself is
generic boilerplate, identical for every run of an agent
(`shikigami-core/src/Shikigami/Agent/Run.hs:221-223`), and the one example Flow that
*does* recall memories throws them away (`classifyRisk activity _prior input`,
`shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs:62-63`).

After this plan, both executable behavior arms receive the recalled memories and the
trigger payload: the Skill arm's LLM context contains a "Prior learnings" section and
the payload (payload was already present); the ShikumiProgram arm receives the payload
and prior learnings through handan's argument map; the recall query is built from the
agent's description and the actual trigger payload text so retrieval is about *this*
event; and the at-risk-customer example Flow demonstrably changes its verdict when a
relevant prior learning exists. Observably: run an agent twice on related payloads and
the second run's model context (capturable in tests, visible in the OTel trace)
contains what the first run learned.


## Progress

- [ ] Milestone 1: `BehaviorInput` record; `runBehavior` takes it; both arms consume
      payload + recalled memories; all four call sites updated; capture-seam tests for
      skill context and program args.
- [ ] Milestone 2: payload-aware `recallQuery`; callers updated; unit test.
- [ ] Milestone 3: `classifyRisk` uses `prior`; flow-level test showing a
      verdict changed by a recalled memory; workflow-level round-trip test (record →
      re-run → behavior sees the learning).


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Introduce an explicit `BehaviorInput { payload, recalled }` record and
  change `runBehavior`'s signature, rather than smuggling recalled memories into the
  payload `Value`.
  Rationale: the conversation path already smuggles turn history into the payload
  (`behaviorPayload`, `shikigami-core/src/Shikigami/Agent/Conversation.hs:254-263`) and
  it works, but it makes the payload's shape trigger-dependent and untyped; a typed
  input record keeps "what the trigger said" and "what the agent remembers" distinct
  for each arm to render appropriately, and the compiler finds every call site.
  Date: 2026-07-08
- Decision: Replay safety comes for free — pass the `recall` step's journaled result
  into `run-behavior`; do not re-fetch memories inside the behavior.
  Rationale: `prior` is the recorded output of the journaled `recall` step
  (`Agent/Workflow.hs:175`), so on crash-replay the behavior re-receives the identical
  list; re-fetching inside `run-behavior` would make the step body nondeterministic
  across a crash (memory content changes between attempts). Step names and order are
  untouched, honoring the flow-versioning discipline of
  `docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md`.
  Date: 2026-07-08
- Decision: The program arm passes context through handan's existing
  `ArgMap = Map Text Text` (keys `payload` and `prior`, JSON-encoded) instead of
  changing handan's `Task` contract.
  Rationale: `taskParse :: ArgMap -> Either Text i` is handan's stable parse seam
  (`/Users/shinzui/Keikaku/bokuno/handan/src/Handan/Task.hs:53,66-71`, verify path via
  `mori registry show handan --full`); every existing task ignores unknown keys, so the
  change is non-breaking for tasks that don't care, and a task that wants the payload
  simply reads the `payload` key. Changing handan itself is out of this repo's scope.
  Date: 2026-07-08
- Decision: This plan soft-depends on plan 13 (`docs/plans/13-wire-a-real-model-
  provider-into-behavior-runs.md`) and rebases on it: plan 13 owns the `BehaviorEnv`
  shape and the `runSkillWith` `Options` parameter; this plan owns `BehaviorInput` and
  the context assembly.
  Rationale: both plans edit `Behavior/Run.hs` and `Behavior/Skill.hs`; sequencing
  avoids merge thrash. Everything here is testable against the stub provider via the
  `runSkillWith` capture seam — the injected context is asserted on the request side,
  so no key is needed — but the feature is only *meaningful* once a real model reads
  the context.
  Date: 2026-07-08
- Decision: Implement only after plan 36 establishes the six-package service architecture.
  Keep `BehaviorInput` in the API/domain package that owns behavior contracts and keep
  provider/session wiring in the application/infrastructure packages selected there. Records
  use strict, direct fields (`payload`, `recalled`) with `DuplicateRecordFields`; do not add
  type- or module-prefixed selectors.
  Rationale: this plan changes a cross-package behavior boundary. Landing it first would
  preserve the current package coupling and make the architecture migration harder.
  Date: 2026-07-22
- Decision: The Flow example's use of prior memory is a deliberately simple, auditable
  rule: a recalled learning that mentions this activity's subject id and the word
  "escalated" forces a high verdict.
  Rationale: the flow is the repository's teaching example; the rule must be
  deterministic and testable without a model, while still proving that memory changes
  behavior. The low-risk rationale string is left byte-identical so existing
  assertions (`AgentWorkflowSpec.hs:691-697`) keep passing on a fresh database.
  Date: 2026-07-08


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Repository: `/Users/shinzui/Keikaku/bokuno/shikigami`. An agent run is a durable keiro
workflow (`shikigami-core/src/Shikigami/Agent/Workflow.hs`, function
`runResolvedAgent`, lines 164-205) with journaled steps in this order: `ingest-job`,
`lookup-agent`, `open-session`, `recall`, `run-behavior` (or flow steps),
`dispatch-sinks` (plus `approval:*` when configured), `record`, `complete`. "Journaled"
means each step's result JSON is stored in Postgres; on crash the workflow replays
recorded results instead of re-running bodies.

The pieces this plan touches, precisely:

- **Recall**: step `recall` calls
  `recallPriorLearnings (appEnv deps) (agentScope name) (recallQuery decl focus)`
  (`Agent/Workflow.hs:175`). `recallPriorLearnings`
  (`shikigami-core/src/Shikigami/Agent/Run.hs:191-212`) does a kioku hybrid
  vector/text recall (max 10) with a scope fallback. `recallQuery`
  (`Agent/Run.hs:221-223`) is the boilerplate
  `unwords [agentName, focusTxt, "summary digest learning prior memory"]` — the same
  string every run, so retrieval cannot rank by relevance to the triggering event.
  Its result type is kioku's `MemoryRecord` (fields used here: `memoryId`,
  `memoryType`, `confidence`, `content`; see `renderMemoryRecord`,
  `Agent/Run.hs:187-189`).
- **The drop**: `prior` flows only into `AgentRunResult.recalledPrior`
  (`Agent/Workflow.hs:197-205`); `runBehaviorStep` (`Agent/Workflow.hs:277-289`) calls
  `runBehavior (behaviorEnv deps) decl triggerPayload` without it.
- **runBehavior** (`shikigami-core/src/Shikigami/Behavior/Run.hs:53-66`) dispatches on
  the behavior union: `ShikumiProgram` → `runProgramTask`, `Skill` → the baikai
  completion, `Flow`/`Deterministic` → handled elsewhere/unsupported.
- **Program arm ignores payload**: `runProgramTask rt task _payload` parses
  `Map.empty` (`Behavior/Run.hs:70-74`). handan's `Task` is existential:
  `taskParse :: ArgMap -> Either Text i` with `type ArgMap = Map Text Text`, then
  `taskRun :: Runtime -> i -> IO Envelope`. The in-repo registry
  (`shikigami-core/src/Shikigami/Program/Registry.hs`) has `noop-summary` (parse
  ignores args, returns fixed `noopBody`, lines 68-99) and two fixed-finding research
  stubs.
- **Skill arm**: `runSkillWith` (`shikigami-core/src/Shikigami/Behavior/Skill.hs:93-111`)
  builds the baikai `Context`: system prompt = the SKILL.md description, one user
  message = SKILL.md body + `"\n\nTrigger payload: "` + compact JSON of the payload
  (lines 104-110). No memory anywhere. Note `runSkillWith` takes the completion
  function as a parameter — that is the capture seam the tests use.
- **Call sites of `runBehavior`** (the complete set, verified by grep):
  `Agent/Workflow.hs:289` (worker path), `Agent/Run.hs:80` (`runAgentWithMemory`, the
  non-durable seam used by the `agent-run` CLI), `Agent/Conversation.hs:165`
  (conversation turns; it already embeds prior *turns* in the payload), and
  `shikigami-cli/src/Shikigami/Cli/Commands/RunBehavior.hs:34` (DB-less demo command).
- **Flow example**: `atRiskCustomerFlow`
  (`shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs:35-60`) recalls prior memories
  via the `Memory` capability effect and passes them to `classifyRisk`, which ignores
  them — its signature is `classifyRisk :: ActivityEnvelope -> [a] -> Value ->
  RiskVerdict` with `_prior` unused (lines 62-63). The flow's `Memory` interpreter
  reuses `recallPriorLearnings` (`shikigami-core/src/Shikigami/Flow/Capability.hs:88-92`).
- **Import-cycle warning**: `Behavior/Skill.hs` must not import
  `Shikigami.Agent.Run` (which imports `Behavior/Run.hs`, which imports
  `Behavior/Skill.hs`). Any memory-rendering helper the skill arm needs is written
  locally in `Behavior/Skill.hs` against kioku's `MemoryRecord` directly.

Coordination: plan 13 lands first and owns `BehaviorEnv`/`Options` in these same
files. If plan 13 is not yet merged when you start, implement against current `main`
and treat the `Options` parameter as absent — the `BehaviorInput` change is orthogonal.


## Plan of Work

### Milestone 1 — BehaviorInput threading into both arms

Scope: after this milestone, the skill arm's outgoing LLM request contains the recalled
memories and the program arm's task receives the payload and memories through its
`ArgMap` — proven by capture-seam tests, no database or key required.

Edit `shikigami-core/src/Shikigami/Behavior/Run.hs`:

- Add and export:

```haskell
data BehaviorInput = BehaviorInput
  { payload :: !Value,
    recalled :: ![MemoryRecord]
  }
```

  (import `Kioku.Api.Types (MemoryRecord)`; derive `Eq, Show, Generic, ToJSON,
  FromJSON` for symmetry with neighboring types).
- Change `runBehavior :: BehaviorEnv -> AgentDecl -> BehaviorInput -> IO (Either
  RunError Value)` and thread the record through.
- Rewrite `runProgramTask` to build a real `ArgMap`:

```haskell
programArgs :: BehaviorInput -> Map Text Text
programArgs input =
  Map.fromList
    [ ("payload", compactJson (payload input)),
      ("prior", compactJson (toJSON (fmap memoryContentText (recalled input))))
    ]
```

  where `compactJson` is the lazy-text encode already used in `Skill.hs:114-115` and
  `memoryContentText` projects `MemoryRecord.content`. Pass `programArgs input` to
  `taskParse` instead of `Map.empty`.

Edit `shikigami-core/src/Shikigami/Behavior/Skill.hs`: `runSkill`/`runSkillWith` take
`BehaviorInput` instead of the bare payload `Value`. The user message becomes: SKILL.md
body, then the `Trigger payload:` line (unchanged wording), then — only when `recalled`
is non-empty — a section:

```text
Prior learnings (most relevant first):
- <memoryId> [<memoryType>/<confidence>] <content>
- ...
```

rendered by a local helper (do not import `Shikigami.Agent.Run.renderMemoryRecord`;
see the cycle warning — duplicate the one-line format locally and note it in a
comment). Keeping the section absent when there are no memories keeps first-run
requests identical to today's.

Update the call sites:

- `Agent/Workflow.hs`: `runResolvedAgent` passes `prior` into `runBehaviorStep`
  (add a `[MemoryRecord]` parameter), which builds
  `BehaviorInput { payload = triggerPayload, recalled = prior }`. The `run-behavior`
  step *name* and result shape (`Either Text Value`) are unchanged.
- `Agent/Run.hs` (`runAgentWithMemory`, line 80): it already has `prior` in scope —
  pass it.
- `Agent/Conversation.hs:165`: pass `recalled = []` with a comment that conversation
  context travels as turns inside `behaviorPayload` (lines 254-263); unifying those is
  future work, not this plan.
- The `run-behavior` command component assigned to `shikigami-workers` by plan 36:
  `recalled = []` (the command is DB-less by design; keep its help text honest by appending
  "no memory" to its worker-package parser description).
- Update `Program/Registry.hs` `noopSummaryTask.taskParse` to read the `payload` key
  (`Right . fromMaybe Aeson.Null . fmap decodeOrString . Map.lookup "payload"` in
  spirit — parse the JSON text back to `Value`, falling back to `Null`), and extend
  `noopSummaryProgram` to echo its input under an `"input"` field of the fixed body.
  Any test asserting the old fixed body (`rg "noop-summary produced" shikigami-core/test
  shikigami-workers`) must be updated in the same commit.

Tests (new `shikigami-core/test/Shikigami/BehaviorInputSpec.hs`, registered in
`test/Main.hs`):

- Skill capture: call `runSkillWith` on `agents/skills/triage-note` with a fake
  completion function that stores the received `Context` in an `IORef`; input carries
  one synthetic `MemoryRecord` with a recognizable `content`; assert the single user
  message contains both the payload JSON and the memory content; assert the
  no-memories case contains no "Prior learnings" text.
- Program capture: a throwaway `Task` whose `taskParse` returns the `ArgMap` itself
  (encoded) and whose `taskRun` echoes it in the verdict; run through `runBehavior`
  and assert `payload`/`prior` keys arrived. (Register nothing globally — construct
  the `Task` locally and call `runProgramTask` via a small exported-for-tests wrapper,
  or test through `lookupTask "noop-summary"` and the new echo field.)

Acceptance: `cabal test all` green; the two capture tests fail on pre-change code (the
context lacks the memory; the ArgMap is empty) and pass after.

### Milestone 2 — A recall query about this event

Scope: retrieval quality. Change `recallQuery`
(`shikigami-core/src/Shikigami/Agent/Run.hs:221-223`) to:

```haskell
recallQuery :: AgentDecl -> Text -> Value -> Text
recallQuery AgentDecl {name = agentName', description = desc} focusTxt payload =
  Text.take 512 (Text.unwords (agentName' : focusTxt : desc : payloadTerms payload))
```

where `payloadTerms` extracts the string leaves of the payload's top level (and one
level down, mirroring the field-walking style of `textFields` in
`Flow/AtRiskCustomer.hs:182-187`), so a payload like
`{"text":"customer says cancel"}` yields a query about cancellation rather than the
constant `"... summary digest learning prior memory"` string. Cap at 512 characters —
the query feeds an embedding, not a prompt. Update the two callers
(`Agent/Workflow.hs:175`, `Agent/Run.hs:78`) to pass the trigger payload. The `recall`
step's journaled *result* shape is unchanged (still `[MemoryRecord]`); only the query
text differs, which is safe because the step body only executes on first run, never on
replay.

Test: pure unit case in `BehaviorInputSpec` asserting `recallQuery` contains payload
words and the description, and respects the cap.

### Milestone 3 — Memory that changes a decision (the Flow example)

Scope: prove memory affects behavior end to end. Edit
`shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs`:

- `classifyRisk :: ActivityEnvelope -> [MemoryRecord] -> Value -> RiskVerdict`
  (concrete type instead of `[a]`; import `Kioku.Api.Types (MemoryRecord (..))`).
- New rule, checked alongside the existing text/enrichment rules: if any recalled
  `content` contains the activity's `subjectId` and the word `"escalated"`, the
  verdict is high with
  `rationale = "prior escalation on this subject: customer relationship at risk"`.
  The existing low rationale (`"no high-risk signal detected"`) stays byte-identical.

Tests:

- Pure: `classifyRisk` with a fabricated escalated-memory forces high; without it, the
  existing low case is unchanged.
- Workflow round-trip (extend `AgentWorkflowSpec` "runs Flow behavior through the
  agent workflow", lines 160-175, with a sibling case): using the migrated test
  database, first record a memory under `agentScope "at-risk-customer"` whose content
  is `"<ticketId> escalated after acknowledgement timeout"` (use `Kioku.Memory.record`
  directly, as `recordLearning` does at `Agent/Workflow.hs:585-605`), then run a
  low-text `flowJob` for the same subject and assert the verdict is high — memory, not
  payload, flipped it. Note the recall path works without a vector extension because
  `recallPriorLearnings` falls back to `getActiveByScope` (`Agent/Run.hs:209-212`), so
  the test is deterministic in CI.

Acceptance: both tests green; the pre-existing low-risk workflow case still passes
unchanged (fresh database ⇒ no memories ⇒ same verdict).


## Concrete Steps

All from `/Users/shinzui/Keikaku/bokuno/shikigami` in `nix develop`. After each
milestone:

```bash
cabal build all
cabal test all
```

Milestone 1 files: `shikigami-core/src/Shikigami/Behavior/Run.hs`,
`shikigami-core/src/Shikigami/Behavior/Skill.hs`,
`shikigami-core/src/Shikigami/Agent/Workflow.hs`,
`shikigami-core/src/Shikigami/Agent/Run.hs`,
`shikigami-core/src/Shikigami/Agent/Conversation.hs`,
`shikigami-core/src/Shikigami/Program/Registry.hs`,
the `run-behavior` command component in `shikigami-workers`, new test
`shikigami-core/test/Shikigami/BehaviorInputSpec.hs` (+ `test/Main.hs`,
`shikigami-core.cabal`). Use `cabal build all` as the call-site finder after changing
the `runBehavior` signature — the four sites listed in Context are the expected
breakage set.

Milestone 2 files: `shikigami-core/src/Shikigami/Agent/Run.hs`,
`shikigami-core/src/Shikigami/Agent/Workflow.hs`, test additions.

Milestone 3 files: `shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs`, test
additions in `shikigami-core/test/Shikigami/AgentWorkflowSpec.hs` (and
`FlowLifecycleSpec.hs` if it asserts `classifyRisk` — check with
`grep -rn classifyRisk shikigami-core/test`).

Demo transcript to verify by hand (stub provider; shows the program arm now seeing its
payload):

```bash
cabal run shikigami-run-behavior -- --agent agents/heartbeat.dhall \
  --payload '{"source":"demo"}'
```

```text
{"summary":"noop-summary produced a fixed digest","verb":"heartbeat.tick","input":{"source":"demo"}}
```

(Before this plan the `"input"` field is absent no matter what payload is passed —
that is the observable de-stubbing of the program arm.)


## Validation and Acceptance

Acceptance is behavioral at three levels:

1. Request-side proof (no key): `BehaviorInputSpec`'s skill-capture test shows the
   exact LLM request user-message containing both the trigger payload JSON and the
   recalled memory content; the program-capture test shows the `ArgMap` carrying
   `payload` and `prior`. Both fail before the change.
2. Durable round-trip: the Milestone 3 workflow test records a learning, runs the flow
   agent on an otherwise-low payload, and the verdict flips to high with the
   prior-escalation rationale — recalled memory observably changed a decision through
   the full open-session → recall → behavior → record pipeline.
3. Manual: the `run-behavior` transcript above, plus (once plan 13's real provider is
   available and a key is set) running a skill agent twice — second run's reply
   references the first run's recorded learning, and the OTel trace of the baikai call
   (the worker's trace sink, `Cli/Commands/Worker.hs:30`) shows the "Prior learnings"
   section in the outbound context.

Regression guard: `cabal test all` — especially the crash/replay cases in
`AgentWorkflowSpec` (lines 67-159), which prove the step names and replay semantics
were not disturbed.


## Idempotence and Recovery

All edits are compile-checked signature changes plus additive rendering; re-running
tests is always safe. The one replay-sensitive point is deliberate: `run-behavior`
consumes the journaled `recall` output, so resumed runs see the same memories as the
original attempt (asserted implicitly by the existing crash-resume tests, which now
route `prior` through the new parameter). The Milestone 3 test writes memories only
into the per-test ephemeral database provisioned by
`Shikigami.Migrations.TestSupport.withShikigamiMigratedDatabase` — nothing persists.
If a signature change leaves a call site behind, the build fails loudly; there is no
partial-runtime failure mode. Rollback is `git checkout` of the touched files.


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plan 47 and soft-depends on plan 13. Use the released Kioku
connection/resource API and Baikai 0.4 request/context construction. The tests remain request-side
and hermetic, so implementation may proceed before live provider credentials exist.


## Interfaces and Dependencies

New/changed interfaces (repository-relative module paths):

```haskell
-- shikigami-core/src/Shikigami/Behavior/Run.hs
data BehaviorInput = BehaviorInput
  { payload :: !Data.Aeson.Value,
    recalled :: ![Kioku.Api.Types.MemoryRecord]
  }
runBehavior :: BehaviorEnv -> Shikigami.Api.Agent.AgentDecl -> BehaviorInput -> IO (Either RunError Data.Aeson.Value)

-- shikigami-core/src/Shikigami/Behavior/Skill.hs (Options parameter present iff plan 13 landed)
runSkillWith ::
  Baikai.Model.Model ->
  SkillDir ->
  BehaviorInput ->
  (Baikai.Model.Model -> Baikai.Context.Context -> Baikai.Options.Options -> IO Baikai.Response.Response) ->
  IO (Either RunError Data.Aeson.Value)

-- shikigami-core/src/Shikigami/Agent/Run.hs
recallQuery :: Shikigami.Api.Agent.AgentDecl -> Data.Text.Text -> Data.Aeson.Value -> Data.Text.Text

-- shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs
classifyRisk :: Shikigami.Api.Activity.ActivityEnvelope -> [Kioku.Api.Types.MemoryRecord] -> Data.Aeson.Value -> RiskVerdict
```

Consumed, verified interfaces:

```haskell
Handan.Task.Task { taskParse :: ArgMap -> Either Text i, taskRun :: Runtime -> i -> IO Envelope, ... }
Handan.Task.ArgMap  -- type ArgMap = Map Text Text (handan Task.hs:53)
Kioku.Api.Types.MemoryRecord (memoryId, memoryType, confidence, content)
Shikigami.Agent.Run.recallPriorLearnings :: AppEnv -> MemoryScope -> Text -> IO [MemoryRecord]  -- Agent/Run.hs:191
Kioku.Memory.record / Kioku.Memory.Domain.RecordMemoryData (..)   -- test-side memory seeding
```

Dependency notes: no new packages (`kioku-api` already provides `MemoryRecord` to
`shikigami-core`). Soft dependency on plan 13 (ordering only, see Decision Log).
HARD dependency on
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`; place
the interfaces in the packages it assigns rather than extending the legacy monolith.
Constraint from the parent MasterPlan: existing journaled step names
(`recall`, `run-behavior`, and the rest) must not be renamed or reordered; this plan
complies — only step *bodies* and pure functions change.


## Revision Notes

- 2026-07-22: Added the six-package architecture prerequisite and made the direct strict
  record-field convention explicit for the new behavior boundary.
