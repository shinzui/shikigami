---
id: 26
slug: conversation-workflow-lifecycle-idle-timeout-journal-rotation-session-completion
title: "Conversation workflow lifecycle: idle timeout, journal rotation, session completion"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tytnwe53rdd4es99ztv1p"
master_plan: "docs/masterplans/5-durable-evolution-versioning-and-replay-safety-for-long-lived-workflows.md"
---

# Conversation workflow lifecycle: idle timeout, journal rotation, session completion

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A danwa conversation (a chat thread between a human and a shikigami agent) runs as ONE
durable keiro workflow that lives for the entire conversation: it processes a turn, then
loops back to await the next message, forever. That design has four defects that compound
over a conversation's lifetime. The workflow never ends — there is no idle timeout — so its
kioku session stays `status = "running"` indefinitely and the workflow instance is
immortal. Its journal grows without bound: roughly five journaled steps plus one awakeable
per turn, appended forever to a single stream, so replay and hydration get slower with every
message and never recover. Resolving which kioku session a conversation belongs to is an
O(scope) linear scan of every session the agent has ever had. And a message that arrives
while the workflow is mid-turn is reported as "not delivered" and only recovered by a
worker retry loop that treats the routine case (a busy conversation) as an error path.

After this plan, a conversation workflow ends cleanly when it has been idle past a
configured timeout — the durable idle timer fires, the workflow completes its kioku session
(`status = "completed"`) and terminates — and a later message in the same thread starts a
fresh conversation epoch that reuses the same kioku session lineage. The journal is bounded:
every N turns the workflow rotates onto a fresh generation via keiro's `continueAsNew`,
carrying only the small state it needs (turn count, agent name), so per-generation replay
cost is capped no matter how long the conversation runs. Session resolution is a keyed
lookup by conversation id, not a scan. And a message arriving mid-turn is delivered smoothly
— the workflow keeps its next-message awakeable armed so the ingress path always has a live
promise to signal — so the worker's retry loop stops being the primary delivery mechanism.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Indexed session resolution (kioku `getBySubjectRef`); generation-aware input
      delivery and result loading (stop hard-coding generation 0).
- [ ] M2: Idle-timeout durable timer per turn; on fire, complete the kioku session and end
      the workflow; a subsequent message opens a new epoch reusing the session lineage.
- [ ] M3: Journal rotation via `continueAsNew` every N turns behind a patch guard;
      `restoreSeed` at the top of the body; `ContinuedAsNew` handled as success.
- [ ] M4: Racing-message smoothing (next-message awakeable pre-armed; delivery no longer an
      error path); worker AckRetry demoted to a genuine-failure fallback.
- [ ] M5: Extend `AgentWorkflowSpec` Conversation tests for timeout, rotation, and racing;
      suite green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Complete the kioku session on idle timeout and end the workflow, rather than
  leaving both open.
  Rationale: an unbounded set of `status = "running"` sessions
  (`shikigami-core/src/Shikigami/Agent/Conversation.hs:281-287` only ever reuses running
  sessions and never closes them) is both a resource leak and a correctness hazard for the
  session-reuse scan; a completed session with a stable subjectRef gives the next epoch a
  lineage to continue via kioku's `previousSessionId`.
  Date: 2026-07-08
- Decision: Rotate the journal with `continueAsNew` on a turn-count cadence (default 20
  turns), guarded by a `patch` id.
  Rationale: `continueAsNew` is keiro's bounded-journal mechanism for unbounded workflows
  (`keiro/src/Keiro/Workflow.hs:243-257`); the conversation loop is the canonical unbounded
  workflow. The restructuring changes step ordering in a workflow with live in-flight
  instances (parked conversations), so per `docs/workflow-versioning.md` (plan 24) it must
  ship behind a patch so existing parked conversations keep their old loop shape.
  Date: 2026-07-08
- Decision: Add a subjectRef-indexed session read model to kioku rather than a
  shikigami-side lookup table.
  Rationale: kioku owns session read models (`kioku-core/src/Kioku/Session/ReadModel.hs`)
  and already indexes by scope; a subjectRef query is a small additive read model that
  belongs there and avoids a second source of truth in shikigami. The conversation id is
  already stored as `subjectRef` on the session (`Conversation.hs:302`).
  Date: 2026-07-08
- Decision: Reference plan 17 (MasterPlan 3) for the PER-TURN behavior timeout; this plan
  owns only the IDLE (between-turns) timeout.
  Rationale: plan 17 owns behavior retry/timeout for all behaviors
  (`docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md`);
  duplicating a behavior-timeout mechanism here would create the divergence plan 27 exists
  to remove. The idle timeout is a conversation-lifecycle concern with no analog elsewhere,
  so it is in scope.
  Date: 2026-07-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

All shikigami paths are relative to `/Users/shinzui/Keikaku/bokuno/shikigami`; kioku is at
`/Users/shinzui/Keikaku/bokuno/kioku`, keiro at `/Users/shinzui/Keikaku/bokuno/keiro`
(library under its `keiro/` subdirectory). This plan hard-depends on plan 24
(`docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md`): it needs the
`Shikigami.Workflow.Versioning` run-options plumbing (so `continueAsNew`'s
`ContinuedAsNew` outcome is handled and `patch` decisions are recorded), and the
`docs/workflow-versioning.md` discipline (this plan restructures the longest-lived workflow
in the system and must do so behind a patch guard).

The conversation workflow today, verified in
`shikigami-core/src/Shikigami/Agent/Conversation.hs`:

- Identity: one workflow per conversation, `WorkflowName "shikigami.danwa-conversation"`
  (lines 90-91), `WorkflowId ("danwa-conversation:" <> conversationId)` (lines 93-95).
- Body: `conversationWorkflow` (lines 117-125) journals `ingest-start`, resolves the agent
  declaration (`lookup-agent`), processes the first turn, then enters `loop` (lines
  139-148): `awaitInput (next-message:N)` → `processTurn` → recurse with `N+1`, an infinite
  await/process cycle. `processTurn` (lines 150-184) journals per turn: `resolve-session`,
  `record-user:<messageId>`, `run-behavior:<messageId>`,
  `record-assistant-and-reply:<messageId>`, `turn-result:<messageId>` — five steps — plus
  the `next-message:N` awakeable allocation each loop. Nothing ever terminates the loop and
  nothing rotates the journal.
- `ContinuedAsNew` is treated as an ERROR: `runConversationTurn` maps it to
  `Left "conversation workflow continued as new unexpectedly"` (line 105). Adopting
  rotation requires changing this.
- Session resolution: `resolveSession` (lines 273-287) calls `Session.getByScope` for the
  agent's scope — returning EVERY session the agent has had — and linearly scans for one
  whose `subjectRef == conversationId` and `status == "running"`
  (`isRunningConversationSession`, lines 285-287). O(number of the agent's sessions).
  Sessions are never completed, so this set only grows.
- Delivery: `deliverConversationInput` (lines 202-213) loads the step index at GENERATION 0
  (`loadStepIndex conversationWorkflowName (conversationWorkflowId msg) 0`, line 208), finds
  pending `next-message:N` awakeable allocations (`pendingInputAids`, lines 215-221), and
  signals the first that accepts (`signalFirst`, lines 223-229). If NONE is pending (the
  workflow is mid-turn, between arming awakeables), delivery returns `False`.
  `loadConversationResult` also reads generation 0 (line 233). Both break after the first
  `continueAsNew` rotation, which moves the live journal to generation ≥ 1
  (`workflowGenerationStreamName`, `keiro/src/Keiro/Workflow/Types.hs:162-167`).
- The busy path is the routine path. In `runConversationTurn` (lines 97-111): deliver the
  message; if delivered, run the workflow with `Nothing` (resume); if NOT delivered (mid-turn
  or brand-new conversation), run it with a `ConversationStart` payload (first turn). The
  worker (`shikigami-core/src/Shikigami/Worker.hs:143-162`) maps a failed conversation turn
  to `AckRetry (RetryDelay 1s)` (lines 158-161), so a message that could not be delivered
  because the conversation was mid-turn is re-driven a second later — the error path IS the
  routine recovery for concurrent messages.

keiro primitives this plan uses (verified in `keiro/src/Keiro/Workflow.hs` and `.../Types.hs`):

- `continueAsNew seed` snapshots `seed` onto generation g+1, marks generation g terminal
  (`WorkflowContinuedAsNew`), and unwinds with outcome `ContinuedAsNew`
  (`Workflow.hs:243-257`, `rotateGeneration` at `Workflow.hs:801-826`). The resume worker
  rediscovers and drives the rotated generation forward
  (`Types.hs:340-352`; keiro test "rediscovers and resumes a rotated workflow").
- `restoreSeed def` reads the carried seed at the top of the body (returns `def` on
  generation 0) (`Workflow.hs:267-268`).
- `currentRunGeneration` gives the running generation (`Workflow.hs:231-232`); the ingress
  and result-loading paths must resolve the CURRENT generation rather than assume 0. keiro
  exposes `Keiro.Workflow.currentGeneration :: WorkflowName -> WorkflowId -> Int` (see the
  re-export list, `Workflow.hs:104-107`, and its use in `Workflow.hs:758`) for out-of-band
  callers like `deliverConversationInput`.
- Durable idle timer: keiro's `sleepNamed :: StepName -> NominalDiffTime -> Eff es ()`
  (`keiro/src/Keiro/Workflow/Sleep.hs`) arms a Postgres-backed timer and SUSPENDS; the timer
  worker (already running in shikigami, `Worker.hs:114-123`) fires it. But `sleepNamed`
  suspends the ENTIRE workflow, which is not what an idle timeout needs (the workflow must
  ALSO be resumable by a message). The right primitive is the same one approvals use: arm a
  deadline timer that, when it fires, signals a distinct awakeable, and have the turn loop
  await BOTH the next-message awakeable and the idle-timeout awakeable — whichever the wake
  source resolves first wins (this is exactly the approval-vs-deadline race the agent-run
  path already runs, `shikigami-core/src/Shikigami/Agent/Approval.hs:107-115` arms a timer
  alongside an awakeable and awaits the awakeable, and the timer's fire action signals that
  same awakeable with `TimedOut`, `Approval.hs:124-142`).

kioku session facts (verified): `SessionRow` carries `subjectRef :: Maybe Text` and
`status :: Text` (`kioku-core/src/Kioku/Session/ReadModel.hs:40-63`).
`Session.complete :: CompleteSessionData -> Eff es (...)`
(`kioku-core/src/Kioku/Session.hs:80-91`) closes a session (the agent-run path calls it,
`shikigami-core/src/Shikigami/Agent/Workflow.hs:607-618`). `StartSessionData` has a
`previousSessionId :: Maybe SessionId` field for lineage
(`Conversation.hs:296-306` passes `Nothing` today). The only scope/subject query kioku
exports today is `getByScope` (`Kioku/Session.hs:179-188`) backed by `SessionsByScopeQuery`
(`ReadModel.hs:82`); there is no subjectRef-indexed query — M1 adds one.

Term definitions: an "epoch" is one workflow instance spanning from a conversation's first
message (or the message after an idle timeout) until the next idle timeout; a conversation
may span several epochs, each a distinct workflow instance, chained through kioku session
lineage. A "generation" is a keiro journal generation within one epoch's workflow instance,
rotated by `continueAsNew`. "Idle" means no new human message for the timeout window while
the workflow is parked awaiting the next message.


## Plan of Work

Milestone 1 — indexed session resolution and generation-aware ingress. This milestone is
independently valuable (it removes the O(scope) scan and the generation-0 assumption) and
is a prerequisite for M3's rotation.

In kioku, add a subjectRef-indexed read model. In
`kioku-core/src/Kioku/Session/ReadModel.hs` add `data SessionsBySubjectRefQuery =
SessionsBySubjectRefQuery Text Text` (namespace, subjectRef) with a
`sessionsBySubjectRefReadModel` and a `selectSessionsBySubjectRefStmt` mirroring
`selectSessionsByScopeStmt` (lines 367-383) but filtering `subject_ref = $2` within the
namespace; export it. In `kioku-core/src/Kioku/Session.hs` add
`getBySubjectRef :: Namespace -> Text -> Eff es (Either ReadModelError [SessionRow])`
mirroring `getByScope` (lines 179-188). (If adding a kioku read model is undesirable for
scheduling reasons, the fallback stated in the MasterPlan is a shikigami-side lookup table
keyed by conversation id; prefer the kioku query and record the choice.)

In `shikigami-core/src/Shikigami/Agent/Conversation.hs`, rewrite `resolveSession`
(lines 273-287) to call `getBySubjectRef shikigamiNamespace conversationId` and select the
most recent running session, or (M2's lineage) the most recent completed session to chain
from, else start a new one. Fix the generation assumption: `deliverConversationInputFromApp`
(lines 205-213) must resolve the current generation —
`gen <- currentGeneration conversationWorkflowName (conversationWorkflowId msg)` — and pass
`gen` (not `0`) to `loadStepIndex` (line 208); likewise `loadConversationResult` (lines
231-236). `currentGeneration` runs in `AppEffects` (it needs `Store`), which
`deliverConversationInputFromApp` already provides via `runAppIO`. Acceptance: an existing
conversation test still passes; a new assertion confirms session resolution issues a
subjectRef query (observable indirectly: after two turns there is exactly one running
session for the conversation and resolution does not enumerate unrelated agent sessions —
create a decoy session for the same agent/different subjectRef and assert it is not
selected).

Milestone 2 — idle timeout and session completion. Add an idle-timeout awakeable alongside
the next-message awakeable in the loop. Model it on approvals: define a timeout payload and
a fire action (a conversation-scoped analog of `approvalTimeoutFireAction`,
`Approval.hs:124-142`) that signals the idle awakeable, and register that fire action in the
worker's timer loop (today `Worker.hs:119` fires only
`Scheduler.shikigamiTimerFallback`; the timer worker takes one fire action, so route by the
timer payload's `kind` discriminator as approvals do — or run a combined fire action). In
the loop (`loop`/`processTurn` restructure), after processing a turn, arm the idle timer for
the configured window and await a sum of {next message, idle fired}: on next-message,
process the turn and re-arm; on idle-fired, journal a terminal step (`idle-timeout`),
complete the kioku session (`Session.complete` with a summary like "conversation idle
timeout"), and RETURN from the workflow body (outcome `Completed`). Add the idle window to
`ConversationEnv` (a `NominalDiffTime`, default e.g. 30 minutes) so tests can set it to
seconds. The awaited sum can be expressed with two awakeables and whichever resolves first
(mirroring the approval-vs-deadline pattern, `Approval.hs:107-115`); the awakeable await is
already the loop's suspension point (`awaitInput`, `Agent/Workflow/Input.hs:18-24`).

For a message that arrives AFTER an epoch ended: `runConversationTurn` delivers to the
(now completed) workflow, delivery fails (no pending awakeable — the workflow terminated),
so it runs a fresh `ConversationStart`. The new epoch's `resolveSession` (M1) finds the
completed session, and `startSession` (`Conversation.hs:289-306`) passes its id as
`previousSessionId` so kioku records the lineage. Acceptance test: run two turns, fire the
idle timer (as `fireDueApprovalTimer` does, `AgentWorkflowSpec.hs:554-558`), assert the
workflow completed and `Session.getById` shows `status = "completed"`; then run a third
message and assert a NEW running session whose `previousSessionId` is the completed one, and
the conversation continues.

Milestone 3 — journal rotation. Restructure the loop to carry a turn counter as workflow
state and rotate every N turns. At the top of the body call
`restoreSeed ConversationSeed{agentName, turnsSoFar}` (a small `ToJSON`/`FromJSON` record).
In the loop, after processing turn number `k`, if `k mod rotateEvery == 0` call
`continueAsNew ConversationSeed{agentName, turnsSoFar = k}` (which unwinds; the next
run/resume restores the seed and continues awaiting the next message). Because this changes
the step ordering of an in-flight workflow type, guard the NEW loop shape behind
`patch (PatchId "shikigami.conversation-rotation-v1")` (added to
`Shikigami.Workflow.Versioning.shikigamiActivePatches`): on `False` (a conversation parked
under the old code), keep the old non-rotating loop; on `True`, use the rotating loop. Handle
the outcome: `runConversationTurn` (line 105) must treat `ContinuedAsNew` NOT as an error
but as "the workflow rotated and the resume worker will carry it" — return the turn result
loaded from the journal (via `loadConversationResult`, now generation-aware from M1) rather
than `Left`. Verify the worker's resume loop (already running,
`Worker.hs:86-101`, through plan 24's `runWorkflowResumeWorkerWith`) drives the rotated
generation. Acceptance: drive `rotateEvery = 2` conversations for, say, 5 turns; assert the
journal rotated (generation ≥ 1 exists via `workflowGenerationStreamName` reads, mirroring
keiro's rotation test at `keiro/test/Main.hs:4622` onward), each generation's step count is
bounded, and all five turns recorded their user/assistant turns in the one kioku session.

Milestone 4 — racing-message smoothing. The residual failure is a message arriving in the
window between finishing a turn and re-arming the next-message awakeable, or during turn
processing. Two complementary changes. First, keep a next-message awakeable armed at all
times: allocate the NEXT turn's awakeable BEFORE running the current turn's behavior, so
there is always a live promise for the ingress path to signal (the awakeable id is
journaled under `awkid:next-message:N`, so allocating early is replay-stable). Second, since
`awakeableNamed` allocation is deterministic per step name, a message that still finds no
pending awakeable (truly concurrent with allocation) should be BUFFERED rather than bounced:
`deliverConversationInput` returning `False` currently forces the `ConversationStart` path;
instead, when the workflow instance exists and is unfinished, enqueue the message for
redelivery with a short delay WITHOUT treating it as a first-turn start (the worker's
`AckRetry` remains, but only as a genuine backpressure fallback, not the primary path). Demote
the worker log line (`Worker.hs:159-160`) from an error to an info/debug for the
delivered-late case, and reserve `AckRetry`/error semantics for actual store failures.
Acceptance: a test that delivers a second message while the first turn's behavior is still
running (use `AgentRunHooks`-style instrumentation or a slow stub behavior) shows the second
message is delivered to the same workflow and recorded as turn index 2, with no spurious new
session and no error-level log.

Milestone 5 — tests. Extend the `Conversation` test group in
`shikigami-core/test/Shikigami/AgentWorkflowSpec.hs:176-228` (which already exercises
park/resume across two turns) with: an idle-timeout case (M2), a rotation case (M3), a
new-epoch-after-timeout case (M2), and a racing-message case (M4). Reuse the harness there
(`ConversationEnv`, `runConversationTurn`, `firstAddressedMessage`/`secondAddressedMessage`
at lines 611-637, `fireDueApprovalTimer` idiom). Acceptance: all Conversation tests pass,
including the pre-existing two-turn park/resume test (updated only where the loop
restructure changes journaled step names — additive changes should leave the existing
`turn-result:*` and `record-assistant-and-reply:*` assertions intact).


## Concrete Steps

All commands from `/Users/shinzui/Keikaku/bokuno/shikigami` inside `nix develop`.

```bash
nix develop
cabal build all
cabal test shikigami-core-test --test-options='-p Conversation'
```

M1 touches kioku; build the whole project so the kioku change is picked up:

```bash
cabal build all
```

Iterate per milestone and finish with the full battery:

```bash
cabal test all
```

Expected final Conversation transcript shape:

```text
AgentWorkflow
  Conversation
    parks and resumes a danwa conversation as one workflow session: OK
    completes the kioku session on idle timeout:                    OK
    opens a new epoch after idle timeout, chaining session lineage:  OK
    rotates the journal every N turns and keeps replaying:           OK
    delivers a message arriving mid-turn to the same workflow:       OK
```


## Validation and Acceptance

Accepted when these behaviors are observable:

1. Session resolution is keyed: with a decoy running session for the same agent under a
   different subjectRef, conversation resolution selects only the conversation's own
   session; no linear scan selects the decoy.
2. Idle completion: after firing the idle timer on a parked conversation,
   `Session.getById` reports `status = "completed"` and the workflow outcome is `Completed`;
   `countPendingAwakeables` for that conversation returns 0.
3. New epoch: a message after timeout starts a fresh running session whose
   `previousSessionId` is the completed session id; turns continue in the new session.
4. Bounded journal: with `rotateEvery = 2`, after 5 turns at least one rotation occurred
   (generation ≥ 1 stream exists) and no single generation's journal exceeds the
   per-generation bound (assert each generation's event count `<= rotateEvery * stepsPerTurn
   + constant`, following keiro's rotation-test assertion style,
   `keiro/test/Main.hs:5200-5223`).
5. Racing delivery: a message delivered during turn processing is recorded as the next turn
   in the SAME session with no new session created and no error-level worker log.
6. No regressions: `cabal test all` green, including plan 24's WorkflowVersioning spec and
   the untouched agent-run tests.


## Idempotence and Recovery

All changes are code-and-test; builds/tests repeat safely and each test provisions its own
migrated database. The runtime changes are deploy-safe under plan 24's discipline: M3's loop
restructure is behind `patch (PatchId "shikigami.conversation-rotation-v1")`, so a
conversation parked under the old code resumes on the old (non-rotating) branch and is never
left incoherent; a fresh conversation records the patch set and rotates. Keep that patch id
in `shikigamiActivePatches` until all pre-rotation conversation instances have ended (idle
timeouts guarantee they eventually do), then remove it in the same change that deletes the
old branch (per `docs/workflow-versioning.md`). The generation-aware ingress (M1) is a pure
correctness fix (reading the current generation is always correct, including generation 0),
safe to deploy independently. The kioku read-model addition (M1) is additive; rolling it
back requires reverting `resolveSession` to the scan. If the idle-timer fire-action routing
in the worker proves fragile, fall back to a dedicated timer worker pass for conversation
timeouts (a second `runWorkflowTimerWorker` with the conversation fire action) rather than a
combined action, and record it in the Decision Log.


## Interfaces and Dependencies

Dependencies: `keiro` (`Keiro.Workflow`: `continueAsNew`, `restoreSeed`,
`currentRunGeneration`, `currentGeneration`, `patch`; `Keiro.Workflow.Sleep`/timer wiring
for the idle timer; `Keiro.Workflow.Awakeable`), `kioku`
(`Kioku.Session.{getBySubjectRef (new), complete, start}`,
`Kioku.Session.ReadModel.{SessionsBySubjectRefQuery (new), SessionRow}`), and plan 24's
`Shikigami.Workflow.Versioning` (run/resume options and the shared active-patch set).

Signatures that must exist at the end (full paths):

```haskell
-- kioku-core/src/Kioku/Session.hs (new)
getBySubjectRef :: (IOE :> es, Store :> es)
                => Namespace -> Text -> Eff es (Either ReadModelError [SessionRow])

-- kioku-core/src/Kioku/Session/ReadModel.hs (new)
data SessionsBySubjectRefQuery = SessionsBySubjectRefQuery Text Text
sessionsBySubjectRefReadModel :: ReadModel SessionsBySubjectRefQuery [SessionRow]

-- shikigami-core/src/Shikigami/Agent/Conversation.hs (changed)
data ConversationSeed = ConversationSeed { agentName :: !Text, turnsSoFar :: !Int }  -- ToJSON/FromJSON
data ConversationEnv = ConversationEnv { ..., idleTimeout :: !NominalDiffTime, rotateEvery :: !Int }
resolveSession :: ConversationEnv -> AgentDecl -> Text -> IO (Either Text SessionId)  -- now keyed
conversationIdleTimeoutFireAction :: (Store :> es, IOE :> es) => TimerRow -> Eff es (Maybe EventId)

-- shikigami-core/src/Shikigami/Workflow/Versioning.hs (extended by this plan)
-- shikigamiActivePatches gains PatchId "shikigami.conversation-rotation-v1"
```

Consumers to keep working: `shikigami-core/src/Shikigami/Worker.hs`
(`runConversationAgent` at lines 143-162 and the timer worker at lines 114-123 route the new
idle fire action; the resume loop already carries rotated generations via plan 24's
`runWorkflowResumeWorkerWith`), and the CLI danwa spike if it drives conversations
(`shikigami-cli/src/Shikigami/Cli/Commands/DanwaSpike.hs`). Cross-plan: plan 27 consolidates
the SinkIntent machinery the conversation reply uses (`prepareConversationReplySinkIntent`,
`Conversation.hs:391-414`); coordinate merge order per plan 27's Integration Points so the
reply path keeps using the single shared module.
