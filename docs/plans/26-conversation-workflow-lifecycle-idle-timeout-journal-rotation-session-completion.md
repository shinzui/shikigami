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

**This plan was refreshed on 2026-08-19 against the delivered tree.** Six plans it depended on
have landed since it was written (24, 36, 37, 39, 47, 53, and most of 17), the dependency cohort
moved twice, and the file it edits was rewritten twice. The refresh changed the *design* in two
places, not just the citations — see the Revision Note of 2026-08-19 and the Decision Log entries
of the same date. Everything below reflects the refreshed design.


## Purpose / Big Picture

A danwa conversation (a chat thread between a human and a shikigami agent) runs as ONE durable
keiro workflow that lives for the entire conversation: it processes a turn, then loops back to
await the next message, forever. Read
`shikigami-core/src/Shikigami/Agent/Conversation.hs:149-184` and you can see the whole shape in
thirty lines — `conversationWorkflow` journals `ingest-start`, resolves the agent declaration,
processes the first turn, then `loop` awaits `next-message:1`, processes it, awaits
`next-message:2`, and so on with no exit.

That design has four defects that compound over a conversation's lifetime.

The workflow never ends — there is no idle timeout — so its kioku session stays
`status = "running"` indefinitely and the workflow instance is immortal. Its journal grows
without bound: six journaled steps plus one awakeable allocation per turn, appended forever to a
single stream, so replay and hydration get slower with every message and never recover. Resolving
which kioku session a conversation belongs to is an O(number of the agent's sessions) linear scan
(`Conversation.hs:332-346`). And a message that arrives while the workflow is mid-turn finds no
pending awakeable, so `deliverConversationInput` returns `False`, `runConversationTurn` treats
that as "brand new conversation" and starts a `ConversationStart` turn, and the worker's retry
path is what eventually gets the message delivered — the routine case (a busy conversation) runs
down an error path.

There is a fifth defect that only became visible after
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md` landed, and it is
now this plan's headline. `domain/shikigami-conversation.keiro` can declare only three of this
workflow's labels — `ingest-start`, `lookup-agent`, `resolve-session`. Every other label it
writes carries a suffix computed at run time (`record-user:<messageId>`,
`run-behavior-v2:<messageId>`, `record-assistant-and-reply:<messageId>`,
`turn-result:<messageId>`, `danwa-reply:<messageId>`, `next-message:<ordinal>`), and a keiro-dsl
workflow label is a compile-time wire word matching `[A-Za-z0-9][A-Za-z0-9_-]*`. So `just
keiro-gate` — the check that refuses a change which would strand a durable identity — is blind to
almost the whole conversation journal. The specification's own comment block says so and points
here.

After this plan, five things are true and demonstrable.

A conversation workflow **ends cleanly when it has been idle past a configured timeout**. The
durable idle timer fires, signals the same awakeable the next human message would have signalled,
the workflow completes its kioku session (`status = "completed"`) and returns. A later message in
the same thread starts a fresh conversation *epoch* that reuses the same kioku session lineage
through `previousSessionId`.

The journal is **bounded by construction rather than by a tuning constant**. Each turn is one
journal generation: the body processes exactly one message, then rotates onto a fresh generation
with `continueAsNew`, carrying a small seed. Per-generation replay cost is a fixed handful of
steps no matter how long the conversation runs.

Because a generation holds exactly one turn, **every label becomes static** — `record-user`,
`run-behavior`, `record-assistant-and-reply`, `turn-result`, `danwa-reply`, `next-message` — with
no computed suffix and no colon. That makes the whole conversation body **declarable** in
`domain/shikigami-conversation.keiro`, which puts it under `just keiro-gate` for the first time.
This is the change that discharges plan 39's largest undeclarable-label family.

Session resolution is **a keyed lookup by conversation id**, not a scan.

And a message arriving mid-turn is **delivered smoothly**: the ingress path always finds a live
promise because the next turn's awakeable is allocated before the current turn's behavior runs,
and a message that still arrives inside the allocation window is redelivered rather than
misinterpreted as a first turn.

The observable proof is a test transcript (see Concrete Steps) plus a `just keiro-gate` run that
reports the conversation workflow's full body — not three steps of it.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-19) Prerequisite audit. Plans 24, 36, 37, 39, 47, and 53 have landed; plan 17 has
      landed through Milestone 4. The cohort is keiro / keiro-core / keiro-dsl / keiro-migrations
      / keiro-pgmq `0.13.0.0`, kioku `0.4.1.0`, shibuya-core `0.9.0.0`, verified against
      `cabal.project` and `docs/dependency-cohort.md`.
- [x] (2026-08-19) Citation audit of this plan against the working tree, per the standing
      requirement in `docs/architecture/implementation-order.md` ("Citation rot: 19 open plans").
      Every `shikigami-core/src/Shikigami/Worker.hs` and `shikigami-cli/...` pointer was wrong;
      every `Conversation.hs` line number was wrong; every `keiro/src/...` line number predated
      keiro 0.13. All are corrected below.
- [x] (2026-08-19) Design refreshed: one turn per generation (which makes every label static and
      the body declarable) and one awakeable with two signalers (which makes the idle race a
      single declared `await`). Recorded in the Decision Log.
- [ ] **M0 (gate, still open): kioku IR-2.** `Kioku.Session` at `0.4.1.0` exports `getById`,
      `getRecentInNamespace`, `getByScope`, `getByFocus`, `getByStartedRange`, `getChain`,
      `getDelegationChildren`, `getAwaitingByCorrelationKey`, `getTurns` — and no subjectRef
      query. `mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2` is still `status:
      proposed`. M1 has a shikigami-side fallback and is not blocked; see M1.
- [ ] M1: indexed session resolution — `getBySubjectRef` if kioku ships it, otherwise the
      documented shikigami-side fallback; decoy-session test proves resolution is keyed.
- [ ] M1: generation-aware ingress and result loading — `deliverConversationInputFromApp`
      (`Conversation.hs:264-272`) and `loadConversationResult` (`Conversation.hs:290-295`) stop
      passing a literal `0` to `loadStepIndex`; `Shikigami.Agent.Workflow.Input.deliverInputTo`
      gets the same fix.
- [ ] M2: one-turn-per-generation restructure — `ConversationSeed`, `restoreSeed` at the top of
      the body, `continueAsNew` as the final body item, every label static, `ContinuedAsNew`
      handled as success rather than as an error (`Conversation.hs:137`).
- [ ] M2: the declared body — `domain/shikigami-conversation.keiro` gains the full step/await/
      continueAsNew inventory; `just keiro-scaffold` regenerated; the hand-owned conformance
      expectations accepted; `just keiro-gate <merge-base>` green and its `keiro-diff`
      classification recorded in Surprises & Discoveries.
- [ ] M3: idle timeout — `ConversationWake` sum, the conversation timeout timer (generation- and
      turn-pinned, modelled on `approvalTimeoutTimerId`), the fire action registered in the
      worker's timer routing, kioku session completion through
      `Shikigami.Memory.Access`, and the workflow returning `Completed`.
- [ ] M3: new epoch after timeout — `resolveSession` finds the completed session and
      `startSession` passes its id as `previousSessionId` (`Conversation.hs:364` passes `Nothing`
      today).
- [ ] M4: racing-message smoothing — next-turn awakeable allocated before the behavior runs;
      undelivered-but-live messages redelivered instead of restarting the conversation; the
      worker's `RetryDefault` demoted to a genuine-failure fallback.
- [ ] M5: tests — extend the `Conversation` group in
      `shikigami-core/test/Shikigami/AgentWorkflowSpec.hs:536-614` with idle-timeout, new-epoch,
      rotation, and racing cases; update the two existing cases for the label change; `cabal test
      all` green.
- [ ] M5: `docs/workflow-versioning.md` updated — its "What Shikigami journals today" table and
      its "Undeclarable label families" section both name the conversation families, and both are
      wrong once this plan lands.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **(2026-08-19, refresh) keiro-dsl language 5 can declare rotation, awaits, and sleeps — the
  plan-39 reconciliation section written 2026-08-19 understated what is declarable.** The
  workflow grammar is documented at
  `/Users/shinzui/Keikaku/bokuno/keiro/docs/user/typed-spec-toolchain.md:1706-1747` and admits
  `step`, `await <label> -> Type`, `sleep <label> after <inputField>`, `child`,
  `patch id { ... }`, and `continueAsNew SeedType`. Two constraints shape this plan's design:
  labels must be unique across steps, awaits, sleeps, children and nested patches within one
  body, and `continueAsNew` may appear only as the final top-level body item, never inside a
  patch. The uniqueness rule is the whole reason the per-message suffixes exist, and rotating
  once per turn removes the need for them.

- **(2026-08-19, refresh) the approval deadline timer is already generation-pinned, which
  discharges most of the 2026-07-22 stale-timer decision.** `approvalTimeoutTimerId`
  (`shikigami-core/src/Shikigami/Agent/Approval.hs:182-188`) derives a v5 UUID from
  `("shikigami", "approval-timeout", workflowName, workflowId, generation, stepName)`, and
  `armApprovalDeadline` (`Approval.hs:159-180`) reads the generation from
  `currentRunGeneration` before building it. A timer armed in generation *g* cannot be confused
  with one armed in *g+1*, and `scheduleTimerOnceTx` makes re-arming on replay a no-op. The idle
  timer copies this exactly, so "cancel or version every superseded timer" reduces to "derive the
  timer id the way approvals already do" plus one staleness check in the fire action.

- **(2026-08-19, refresh) keiro 0.13 documents a rotation race that this plan must handle and
  the 2026-07-08 draft did not know about.** `Keiro.Workflow`'s module header
  (`/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Workflow.hs:63-110`) states three
  obligations for any custom wake source, and the second is that `appendJournalEntry` resolves
  the current generation and then appends in a *separate* transaction, so a `continueAsNew`
  committing in between strands the completion on the closed generation. The repair is obligation
  three: the arming action re-runs on every resume, so an arm that reads its durable row and
  re-appends an already-resolved result heals a stranded delivery. This matters much more under
  one-turn-per-generation than it would have under a 20-turn cadence, because rotations become
  routine rather than rare.

- **(2026-08-19, refresh) `docs/architecture/shikigami-domain-inventory.md`'s conversation label
  table is already stale.** It was written 2026-08-19 before plan 17 landed, so it lists
  `run-behavior:<messageId>` but not `run-behavior-v2:<messageId>`
  (`Conversation.hs:201`), and its `Agent/Conversation.hs:NNN` line numbers all predate the
  retry-semantics edit. That table is the census `docs/workflow-versioning.md:441-457` points at,
  so both documents need the same correction when M2 lands. Not a blocker; recorded so the
  implementer does not trust those line numbers.

- (Everything above was found while refreshing the plan, not while implementing it. Add
  implementation findings below this line.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Complete the kioku session on idle timeout and end the workflow, rather than
  leaving both open.
  Rationale: an unbounded set of `status = "running"` sessions — `resolveSession`
  (`shikigami-core/src/Shikigami/Agent/Conversation.hs:332-346`) only ever reuses running
  sessions and nothing ever closes one — is both a resource leak and a correctness hazard for the
  session-reuse scan; a completed session with a stable `subjectRef` gives the next epoch a
  lineage to continue via kioku's `previousSessionId`.
  Date: 2026-07-08

- Decision: Each idle timer carries a durable turn/generation token and is cancelled when
  supported; the fire action and workflow both reject stale tokens.
  Rationale: simply re-arming leaves old timers able to terminate a later active turn,
  especially across continue-as-new generation changes.
  Date: 2026-07-22
  Amended 2026-08-19: the mechanism is now specific rather than aspirational, because approvals
  already do it. Derive the timer id from `(workflowName, workflowId, generation, label)` exactly
  as `approvalTimeoutTimerId` does (`Approval.hs:182-188`) and arm it with
  `scheduleTimerOnceTx`, which is first-arm-wins and therefore idempotent across replays. Under
  one-turn-per-generation the generation *is* the turn token, so there is no second counter to
  keep in step. Explicit cancellation is not required: a superseded timer's id belongs to a closed
  generation, its fire action finds no pending awakeable for that generation, and it settles
  without effect. Keep the staleness check in the fire action anyway — it is three lines and it is
  what makes the claim testable.

- Decision: Rotate the journal with `continueAsNew` on a turn-count cadence (default 20
  turns), guarded by a `patch` id.
  Rationale: `continueAsNew` is keiro's bounded-journal mechanism for unbounded workflows; the
  conversation loop is the canonical unbounded workflow. The restructuring changes step ordering
  in a workflow with live in-flight instances (parked conversations), so per
  `docs/workflow-versioning.md` it must ship behind a patch so existing parked conversations keep
  their old loop shape.
  Date: 2026-07-08
  Amended 2026-08-10: there are no live parked conversations — shikigami has no users — so the
  patch guard protects nothing that exists today. Ship it anyway, and prove it with a constructed
  instance.
  **Superseded 2026-08-19 on both counts. See the two entries immediately below.**

- Decision: **Rotate once per turn, not every N turns, and make every conversation label
  static.**
  Rationale: this is the refresh's central design change, and it is worth stating why a cadence
  constant was the wrong shape. The per-message suffixes exist for exactly one reason — a keiro
  journal matches records to steps by label, so two turns in one generation must not write
  `record-user` twice. Rotating after every turn removes that constraint at the root: a
  generation holds one turn, so `record-user`, `run-behavior`, `record-assistant-and-reply`,
  `turn-result`, `danwa-reply`, and `next-message` are each written at most once and need no
  suffix. Three things fall out. The journal is bounded by construction rather than by a constant
  someone has to choose and defend, so `rotateEvery` disappears from `ConversationEnv`. Every
  label becomes a compile-time wire word, so the body becomes declarable in
  `domain/shikigami-conversation.keiro` and `just keiro-gate` starts covering it — which is the
  largest single reduction of plan 39's undeclarable surface available anywhere in the
  repository. And the "which generation is live" question that M1's ingress fix has to answer
  gets exercised on every turn instead of once every twenty, so a bug in it fails loudly in the
  first test rather than in production.
  Cost, stated honestly: one rotation per turn writes a seed and marks the generation terminal.
  A conversation turn already writes six journal events, opens a database transaction per step,
  and makes a model call; a rotation is not the expensive part of it.
  Idempotency, which the suffixes were *not* actually providing: replay identity for a redelivered
  message comes from kioku's turn ids, not from the journal label. `recordTurnOnce`
  (`Conversation.hs:381-388`) keys on `danwa:user:<messageId>` and
  `recordAssistantTurnAndEnqueueReply` (`Conversation.hs:400-401`) keys on
  `danwa:assistant:<messageId>`; both return the existing turn when it is already recorded. Those
  keys are unchanged by this plan. The seed additionally carries the last processed message id so
  the body can recognise a redelivery before doing any work.
  Date: 2026-08-19

- Decision: **Do not carry an old, non-rotating branch behind a patch. Declare and ship the new
  shape only.**
  Rationale: `docs/architecture/implementation-order.md` ("Compatibility work that v1 does not
  owe") records that in-flight workflow survival across a deploy is not a v1 acceptance criterion
  for plans 24, 25, and 26, because nothing consumes shikigami yet. The 2026-08-10 amendment kept
  the guard anyway on the grounds that this plan was "the main proof that plan 24's mechanism
  works". That reason has expired: plan 24 shipped its own constructed-instance proof on
  2026-08-19 (commit `82e8315`, "test(workflow): prove a parked instance survives a deploy"), and
  plan 17 shipped a second live consumer, `shikigami-behavior-retry-v1`, declared in both
  workflow specifications. The mechanism is built and twice proven; this plan does not owe a third
  proof.
  There is also a structural reason. A patch guard here would have to hold the *old* loop shape,
  and the old loop shape is precisely the undeclarable one — per-message labels with colons. So
  the guarded branch could not be declared, `just keiro-gate` could not see it, and the plan would
  be adding an undeclarable branch in the same change that removes undeclarable labels. Deleting
  the old loop is both simpler and more honest.
  What replaces the guard as safety: `just keiro-diff` classifies the body change and refuses a
  `BREAKING` finding, and the M2 acceptance records that classification verbatim.
  Date: 2026-08-19

- Decision: **The idle race is one awakeable with two signalers, not two awakeables.**
  Rationale: the 2026-07-08 draft said "await a sum of {next message, idle fired}", which keiro
  cannot express directly — `awaitStep` suspends on one step name. The pattern that does work is
  already in the tree: `awaitApproval` (`shikigami-core/src/Shikigami/Agent/Approval.hs:101-115`)
  allocates one awakeable, arms a timer whose fire action signals *that same awakeable* with
  `TimedOut` (`approvalTimeoutFireAction`, `Approval.hs:125-142`), and awaits once. Whichever
  signaler arrives first wins; the second is a no-op because `signalAwakeable` returns `False` on
  an already-completed awakeable. So the conversation awaits one label, `next-message`, whose
  payload is a sum: `NextMessage AddressedMessage | IdleTimedOut`. One awakeable, one declared
  `await`, one suspension point, and a shape the specification can hold.
  Alternative considered and rejected: `sleepNamed`
  (`/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Workflow/Sleep.hs`) suspends the whole
  workflow until its timer fires and cannot be woken early by a message, so it is the wrong
  primitive for a timeout that must lose a race. Also considered: `setWorkflowWakeAfterTx`
  (`Keiro.Workflow`), which makes a suspended instance discoverable at a deadline — that is the
  mechanism keiro's own sleep uses for rediscovery, but on its own it would require the workflow
  body to sample the clock to decide whether the deadline passed, which is a replay hazard. The
  timer-signals-the-awakeable pattern journals the decision instead of recomputing it.
  Date: 2026-08-19

- Decision: Add a subjectRef-indexed session read model to kioku rather than a
  shikigami-side lookup table.
  Rationale: kioku owns session read models (`kioku-core/src/Kioku/Session/ReadModel.hs`) and
  already indexes by namespace, scope, focus, started-range, chain, delegation children, and
  awaiting correlation key; a subjectRef query is a small additive read model that belongs there
  and avoids a second source of truth in shikigami. The conversation id is already stored as
  `subjectRef` on the session (`Conversation.hs:363`).
  Date: 2026-07-08
  Amended 2026-08-19: this is now a *request*, not an assumption. It is
  `mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2`
  (`add-indexed-session-and-bounded-memory-read-models`), still `status: proposed` as of
  2026-08-19, and `Kioku.Session`'s export list at `0.4.1.0` confirms no such query exists. M1
  therefore ships whichever is available when it is implemented, and records which. The fallback
  is *not* a second source of truth: it is `Session.getChain` plus a shikigami-owned
  `shikigami.conversation_sessions (conversation_id primary key, session_id, updated_at)` index
  table written in the same transaction as `startSession`, which is a cache of a fact kioku
  already owns. Prefer the kioku query; the fallback exists so M1 is not blocked on an upstream
  release.

- Decision: Reference plan 17 for the PER-TURN behavior timeout; this plan owns only the IDLE
  (between-turns) timeout.
  Rationale: plan 17 owns behavior retry/timeout for all behaviors; duplicating a
  behavior-timeout mechanism here would create the divergence plan 27 exists to remove. The idle
  timeout is a conversation-lifecycle concern with no analog elsewhere, so it is in scope.
  Date: 2026-07-08
  Amended 2026-08-19: plan 17 has landed. The per-turn timeout is real and already threaded:
  `ConversationEnv.runTimeout` (`Conversation.hs:73`) is passed to `runBehaviorAttempt`
  (`Conversation.hs:204`) under the `shikigami-behavior-retry-v1` patch, and its value comes from
  Settei's `worker.run_timeout_seconds`. This plan adds `idleTimeout` beside it and must not
  touch the retry path.

- Decision: **Session writes go through `Shikigami.Memory.Access`, and this plan adds no new
  deprecated kioku call site.**
  Rationale: kioku 0.4 made memory spaces and principals mandatory. Every session write now has a
  `*WithContext` form taking a `MemoryAccessContext`, and the unsuffixed `Session.complete` this
  plan needs is a deprecated compatibility wrapper confined to `legacyMemorySpaceId`
  (`/Users/shinzui/Keikaku/bokuno/kioku/kioku-core/src/Kioku/Session.hs:12-15,30-37`).
  `docs/architecture/implementation-order.md` records that shikigami answers both questions in
  exactly one module, `shikigami-core/src/Shikigami/Memory/Access.hs`, and instructs plans that
  record memory-scoped facts to treat that module as the seam. Clearing the *existing* ~24
  deprecation warnings is plan 54's job
  (`docs/plans/54-key-durable-agent-state-by-meibo-principal.md`); adding a twenty-fifth is this
  plan's to avoid. So the idle-timeout completion calls `completeWithContext` with the context
  `Shikigami.Memory.Access` supplies, even though the surrounding code still calls the wrappers.
  Date: 2026-08-19


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

All shikigami paths are repository-relative to `/Users/shinzui/Keikaku/bokuno/shikigami`. Where a
dependency's source is quoted, the absolute path of the local checkout is given so the reader can
open it; the canonical references are `mori://shinzui/keiro` and `mori://shinzui/kioku`.

### Terms used throughout

An **epoch** is one workflow instance, spanning from a conversation's first message (or the first
message after an idle timeout) until the next idle timeout. A conversation may span several
epochs, each a distinct workflow instance, chained through kioku session lineage.

A **generation** is a keiro journal generation within one epoch's workflow instance. After this
plan, one generation holds exactly one turn, and `continueAsNew` starts the next.

**Idle** means no new human message for the timeout window while the workflow is parked awaiting
the next message.

A **label** is the name a journaled step, await, sleep, or child is recorded under. keiro matches
replay by label, and keiro-dsl can declare a label only if it matches
`[A-Za-z0-9][A-Za-z0-9_-]*` — no colon, nothing computed at run time.

### What has landed since this plan was written

This plan was drafted 2026-07-08. Six of its dependencies have since shipped, and reading it
without knowing that will send you to files that no longer exist.

`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md` split the
repository into seven packages and **deleted `shikigami-cli` and
`shikigami-core/src/Shikigami/Worker.hs`**. The worker loops now live in `shikigami-workers`:
`Shikigami/Workers/Registry.hs` (`runWorkers`, `runQueueWorker`),
`Shikigami/Agent/Workflow/Resume.hs`, `Shikigami/Flow/SinkOutbox/Publisher.hs`,
`Shikigami/Trigger/Timer.hs`, and `Shikigami/Agent/RunJob/Worker.hs`. It also renamed the domain
modules: `Shikigami.Api.Agent` is now `Shikigami.Agent.Decl` and `Shikigami.Api.RunJob` is now
`Shikigami.Agent.RunJob`.

`docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md` replaced every
environment read with one resolved `Shikigami.App.Config.AppConfig`.

`docs/plans/47-...` and `docs/plans/53-...` moved the cohort to keiro `0.13.0.0` and kioku
`0.4.1.0`. **Every `keiro/src/...` line number in the 2026-07-08 draft predated 0.13 and has been
re-resolved.**

`docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md` delivered
`shikigami-core/src/Shikigami/Workflow/Versioning.hs` — `shikigamiActivePatches` (the union of
each generated workflow's `declaredPatches`), `shikigamiWorkflowRunOptions`, and
`shikigamiWorkflowResumeOptions` — plus `docs/workflow-versioning.md`. The conversation workflow
already runs through it (`Conversation.hs:255-259`). The durable rationale is
`docs/adr/0004-one-options-value-and-a-checked-patch-set.md`.

`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md` delivered the
checked specification (below) and `docs/adr/0001-declare-only-what-the-runtime-executes.md`,
whose rule binds this plan: **do not declare a shape the runtime does not execute.** A
specification that describes a codec or label nobody honours is worse than none, because the gate
then certifies a false claim.

`docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md` landed through
Milestone 4. It added the `shikigami-behavior-retry-v1` patch, the `run-behavior-v2:<messageId>`
label, attempt-scoped timeouts, and a typed `JobOutcome` for run jobs. **The conversation's
delivery failure path is no longer `AckRetry (RetryDelay 1s)`** — it is
`conversationJobOutcome` mapping `ConversationTransientFailure` to `RetryDefault`
(`shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs:247-255`).

`docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md` landed and
produced `docs/adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md`, which is
directly relevant: `AgentDecl` is journaled as the result of the `lookup-agent` step, so its codec
is a durable contract. This plan journals `ConversationSeed` under the same rules — if the seed
ever gains a field, it needs the same defaulted-codec treatment that ADR 0011 describes.

Still open and relevant: `docs/plans/25-replay-safe-flow-memory-capabilities.md` (labelled memory
steps), `docs/plans/27-consolidate-sink-intent-and-run-lifecycle-machinery.md` (which owns
`prepareConversationReplySinkIntent`), and `docs/plans/54-key-durable-agent-state-by-meibo-principal.md`
(which owns the kioku deprecation debt).

### The checked specification

The service input is `domain/shikigami.keiro-workspace`, a manifest naming `service shikigami`,
`runtime-package shikigami-core`, `layout collocated`, and three members:
`shikigami-agent-run.keiro`, `shikigami-conversation.keiro`, and `shikigami-run-evidence.keiro`.
Every file-taking `keiro-dsl` command takes the manifest and validates the composed service. The
manifest deliberately carries **no `module` clause** — `context shikigami` already supplies the
`Shikigami` prefix — so do not add one and do not pass `--module-root` or `--collocate`.

`domain/shikigami-conversation.keiro` today declares the workflow identity, its input and output
types, the id derivation, three steps, and one empty patch block:

```text
workflow DanwaConversation
  name "shikigami.danwa-conversation"
  in ConversationStart {
    agentName:Text
  }
  out ConversationTurnResult
  id from input via conversationWorkflowId
  body
    step ingest-start -> ConversationStart
    step lookup-agent -> AgentDecl
    step resolve-session -> SessionId
    patch shikigami-behavior-retry-v1 {
    }

operation RunDanwaConversation
  run DanwaConversation
    input ConversationStart
    outcome -> ConversationTurnResult
```

The patch block is empty because the labels it guards carry colons. Its comment says so.

The gate is `just keiro-gate <merge-base>` (`justfile:175-182`), which runs `keiro-check` (with
`--min-language 5`, `--deny-warnings`, `--explain-bindings`, `--fail-on-opaque`),
`keiro-inspect` (asserting every member declares its language at effective version 5),
`keiro-scaffold` followed by `git diff --exit-code`, `keiro-diff <ref>`, and `cabal test
keiro-shikigami-conformance`. Run it before merging any change to `domain/`, to the generated
layer under `shikigami-core/src/Shikigami/*/Generated/`, or to a durable identity. A `BREAKING`
finding exits non-zero and is a deployment gate, not an advisory.

The generated module this plan touches is
`shikigami-core/src/Shikigami/DanwaConversation/Generated/WorkflowRuntime.hs`. It is
`@generated`; do not edit it. It exports `workflowName`, `declaredPatches`,
`declaredPatchStepNames`, `withDeclaredPatches`, `awaitLabels` (currently `[]`), and
`allocateDeclaredAwait`, which wraps `awakeableNamed` behind a private `AwaitBinding` constructor
so a consumer can allocate only labels the source workflow declares. **After M2 the conversation's
await goes through `allocateDeclaredAwait`, not through a hand-built `StepName`.** The
hand-owned conformance expectations that must be updated in the same change are
`shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/src/KeiroConformance/Expectations.hs`.

Three surfaces are deliberately undeclared and stay that way: the `shikigami_run_jobs` queue
keeps its bare `RunJob` payload rather than acquiring keiro's `{v,t,data}` envelope; the Kafka
inbox and the Danwa contract stay hand-written because a generated contract codec writes a
discriminator into a body that has none; and the sink outbox stays hand-written because its
publisher calls HTTP sinks rather than publishing to Kafka. Declaring any of them is a wire change
needing its own commit, decision, and fixture. Shikigami has no aggregate, no read model, no
projection, no router, and no process manager of its own — the census with evidence is
`docs/architecture/shikigami-domain-inventory.md`.

### The conversation workflow as it stands

Verified against `shikigami-core/src/Shikigami/Agent/Conversation.hs` at commit `860b680`
(521 lines).

Identity: `conversationWorkflowName` (`:122-123`) is
`ConversationGenerated.workflowName`, i.e. the literal comes from the specification and a rename
has exactly one place to happen. `conversationWorkflowId` (`:125-127`) is
`WorkflowId ("danwa-conversation:" <> conversationId)`.

Body: `conversationWorkflow` (`:149-159`) journals `ingest-start`, resolves the agent declaration
under `lookup-agent`, processes the first turn, then calls `loop` (`:173-184`), which is
`awaitInput (next-message:N)` → `processTurn` → recurse with `N+1`. Nothing terminates it and
nothing rotates the journal.

`processTurn` (`:186-238`) journals, per turn: `resolve-session` (`:192`),
`record-user:<messageId>` (`:194`), then a patched behavior step — `run-behavior-v2:<messageId>`
(`:201`) when `patch shikigami-behavior-retry-v1` (`:198`, `:240-241`) reads `True`, else the
legacy `run-behavior:<messageId>` (`:212`) — then `record-assistant-and-reply:<messageId>`
(`:223`, name built at `:305-307`) and `turn-result:<messageId>` (`:238`, name built at
`:301-303`). That is six labels per turn plus the `awkid:next-message:N` allocation. The reply's
sink-intent id uses a seventh label, `danwa-reply:<messageId>` (`:309-311`, used at `:468`),
which is a sink-intent step name rather than a journaled step — the existing test asserts it is
*not* in the step index.

`ContinuedAsNew` is treated as an ERROR: `runConversationTurn` (`:129-143`) maps it to
`Left (ConversationTerminalFailure "conversation workflow continued as new unexpectedly")` at
`:137`. Adopting rotation requires changing this, and `conversationJobOutcome`
(`shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs:247-255`) maps a terminal failure to a
dead-letter, so leaving it would dead-letter every rotating turn.

Session resolution: `resolveSession` (`:332-342`) calls `Session.getByScope shikigamiMemorySpace
(agentScope (name decl))` — returning every session that agent has had — and linearly scans for
one whose `subjectRef` matches and whose `status` is `"running"`
(`isRunningConversationSession`, `:344-346`). Sessions are never completed, so that set only
grows. `startSession` (`:348-372`) passes `previousSessionId = Nothing` (`:364`).

Delivery: `deliverConversationInputFromApp` (`:264-272`) loads the step index at **generation 0**
(`:267`), finds pending `next-message:N` awakeable allocations (`pendingInputAids`, `:274-280`),
and signals the first that accepts (`signalFirst`, `:282-288`). If none is pending — the workflow
is mid-turn, between arming awakeables — delivery returns `False`. `loadConversationResult`
(`:290-295`) also reads generation 0 (`:292`). Both break after the first rotation, which moves
the live journal to generation ≥ 1. The same literal `0` appears in the shared helper
`Shikigami.Agent.Workflow.Input.deliverInputTo`, which agent runs use.

The busy path is the routine path: `runConversationTurn` (`:130-132`) delivers the message; if
delivered it runs the workflow with `Nothing` (resume), if not delivered — mid-turn *or* brand
new — it runs with a `ConversationStart` payload. `runConversationAgent`
(`shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs:110-159`) maps a transient conversation
failure to `RetryDefault`, so a message that could not be delivered because the conversation was
busy is re-driven by the queue's retry policy.

### The keiro primitives this plan uses

Verified against the pinned `keiro 0.13.0.0`, local checkout
`/Users/shinzui/Keikaku/bokuno/keiro`.

`Keiro.Workflow` exports `step`, `awaitStep`, `currentWorkflow`, `currentRunGeneration`,
`freshOrdinal`, `continueAsNew`, `restoreSeed`, and `patch` as the authoring surface, plus
`runWorkflowWith`, `loadStepIndex`, `currentGeneration`, `appendJournalEntry`,
`appendJournalEntryReturningId`, `cancelWorkflow`, `listWorkflowInstances`, and
`setWorkflowWakeAfterTx`/`clearWorkflowWakeAfterTx`
(`keiro/src/Keiro/Workflow.hs:117-165`).

`continueAsNew seed` snapshots `seed` onto generation *g+1*, marks generation *g* terminal, and
unwinds with outcome `ContinuedAsNew`. `restoreSeed def` reads the carried seed at the top of the
body and returns `def` on generation 0. `currentRunGeneration` gives the generation the body is
running in; `currentGeneration :: WorkflowName -> WorkflowId -> Eff es Int` answers the same
question for out-of-band callers such as `deliverConversationInput`, which run in `AppEffects`
and therefore already have `Store`.

The module header (`keiro/src/Keiro/Workflow.hs:63-110`) sets out four obligations for a custom
wake source, and the idle timer is one. Paraphrased, and all four apply here:

1. Keep a durable row keyed by the logical workflow, not by a generation. For a timer that is the
   `keiro_timers` row; it must outlive a rotation.
2. Deliver by appending under the awaited step name, and expect to lose a rotation race — an
   append may also be declined as `JournalRefusedTerminal` when the workflow has gone terminal,
   which is not an error.
3. Re-check the row from the arm and re-deliver. The arming action re-runs on every resume until
   the awaited result is journaled, so an arm that reads its durable row and re-appends an
   already-resolved result repairs a stranded delivery onto whatever generation is now current.
4. Every lifecycle transition of the durable row must leave the owning `keiro_workflows` instance
   row discoverable, in the same transaction. Delivering through `appendJournalEntry` satisfies
   this for free.

`Keiro.Workflow.Awakeable` exports `awakeableNamed`, `signalAwakeable`, `signalAwakeableFrom`,
and `cancelAwakeable`. `signalAwakeable` is idempotent and crash-safe: a double signal returns
`False` without changing the recorded value, and a signal of an already-completed awakeable
re-appends the journal entry from the stored payload to repair historical wedges. That property
is what makes one-awakeable-two-signalers safe.

`Keiro.Workflow.Sleep` provides `sleepNamed` and `runWorkflowTimerWorker`. `sleepNamed` is the
wrong primitive for an idle timeout (it suspends the whole workflow and cannot lose a race to a
message), but `runWorkflowTimerWorker` is exactly the loop that fires this plan's timer: it
recognises workflow-sleep rows by a payload discriminator and hands everything else to a
caller-supplied fallback action.

### The timer path, and where the idle timer plugs in

`shikigami-workers/src/Shikigami/Trigger/Timer.hs:32-41` is the loop. Each second it calls
`runWorkflowTimerWorker Nothing now (Scheduler.shikigamiTimerFallback (schedulerEnv env))`.
`shikigamiTimerFallback` (`shikigami-workers/src/Shikigami/Trigger/Scheduler.hs:105-109`) tries
the row as a schedule payload first and falls back to `Approval.approvalTimeoutFireAction`. That
is the routing point: the conversation idle-timeout fire action becomes a third arm, discriminated
the same way — by a `kind` field in the timer payload.

The approval implementation is the template. `awaitApproval`
(`shikigami-core/src/Shikigami/Agent/Approval.hs:101-115`) allocates the awakeable, journals a
notify step, arms the deadline, and awaits. `armApprovalDeadline` (`:159-180`) reads
`currentWorkflow` and `currentRunGeneration`, builds a `TimerRequest` whose `timerId` is
`approvalTimeoutTimerId` (`:182-188`) — a v5 UUID over
`("shikigami", "approval-timeout", workflowName, workflowId, generation, stepName)` — and inserts
it with `scheduleTimerOnceTx`, which is first-arm-wins so re-arming on replay is a no-op.
`approvalTimeoutFireAction` (`:125-142`) parses the payload, signals the awakeable with
`TimedOut`, looks the awakeable row up for its owning workflow, and appends the completion.

### The kioku facts

Verified against the pinned `kioku 0.4.1.0`, local checkout `/Users/shinzui/Keikaku/bokuno/kioku`.

`SessionRow` (`kioku-core/src/Kioku/Session/ReadModel.hs:53-76`) carries `memorySpaceId`,
`sessionId`, `agentId`, `focus`, `namespace`, `scopeKind`, `scopeRef`, **`subjectRef :: Maybe
Text`**, **`previousSessionId :: Maybe Text`**, `parentSessionId`, `delegationDepth`,
**`status :: Text`**, `startedAt`, `completedAt`, `modelUsed`, `summary`, `errorMessage`, and
four `awaiting*`/`resumeInput` fields.

The queries kioku exports are `SessionByIdQuery`, `SessionsByNamespaceQuery`,
`SessionsByScopeQuery`, `SessionsByFocusQuery`, `SessionsByStartedRangeQuery`,
`SessionChainQuery`, `SessionDelegationChildrenQuery`, `AwaitingSessionsByCorrelationKeyQuery`,
and `TurnsBySessionQuery` (`ReadModel.hs:6-27`). **There is no subjectRef query.** That is kioku
IR-2, still proposed.

Writes come in two forms. `startWithContext`, `completeWithContext`, `recordTurnWithContext` and
friends take a `MemoryAccessContext`; the unsuffixed `start`, `complete`, `recordTurn` are
deprecated wrappers confined to `legacyMemorySpaceId` (`Kioku/Session.hs:12-15,20-37`).
Shikigami answers the space-and-principal question in exactly one module,
`shikigami-core/src/Shikigami/Memory/Access.hs`, which exports `shikigamiMemorySpace`,
`agentActor`, and `shikigamiReadContext`.

The projection tables are `kioku.sessions`, `kioku.turns`, `kioku.memories`
(`kioku-core/src/Kioku/Database/Schema.hs:45-73`) — kioku migration `0012` relocated them out of
the `kiroku` schema, so any older document naming `kiroku.kioku_sessions` is stale.

### Relevant ADRs

- `docs/adr/0001-declare-only-what-the-runtime-executes.md` — the specification declares only what
  the runtime executes. Binding on M2: declare the labels the body actually writes, and no more.
- `docs/adr/0004-one-options-value-and-a-checked-patch-set.md` — every durable run goes through
  `shikigamiWorkflowRunOptions`, and the active patch set is the union of the generated
  per-workflow `declaredPatches`. Binding on any patch decision this plan makes.
- `docs/adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md` — a value
  journaled as a step result is a durable contract, and a generic JSON codec that emits new fields
  into new journals and requires them when reading old ones breaks replay. Binding on
  `ConversationSeed`'s codec.

No ADR covers conversation lifecycle, idle timeouts, or journal rotation. If M2's
one-turn-per-generation decision survives implementation, it is a durable architectural judgment
and should be promoted to a new ADR during the distillation pass.


## Plan of Work

### Milestone 1 — indexed session resolution and generation-aware ingress

This milestone is independently valuable and is a prerequisite for M2's rotation. At the end of
it, resolving a conversation's session is a keyed lookup rather than a scan, and no code in the
repository assumes a workflow's live journal is generation 0. Nothing rotates yet, so the
generation fix is provably a no-op on today's data — which is exactly why it can land first.

**The keyed lookup.** If kioku IR-2 has shipped by the time you implement this, add
`getBySubjectRef` alongside `getByScope` and use it. The shape follows the existing queries:
a `SessionsBySubjectRefQuery` in `kioku-core/src/Kioku/Session/ReadModel.hs` mirroring
`SessionsByScopeQuery`, filtering `subject_ref = $2` within the memory space, exported alongside
its read model; and `getBySubjectRef :: MemorySpaceId -> Text -> Eff es (Either ReadModelError
[SessionRow])` in `kioku-core/src/Kioku/Session.hs` mirroring `getByScope`. Note the leading
`MemorySpaceId` — kioku 0.4 gives every read one, and a `Namespace`-first signature (which is what
the 2026-07-08 draft of this plan wrote) will not compile.

If IR-2 has not shipped, take the fallback and record it in the Decision Log. Add a shikigami-owned
index table via `just new-migration conversation-session-index`:

```sql
CREATE TABLE IF NOT EXISTS shikigami.conversation_sessions (
  conversation_id text PRIMARY KEY,
  session_id      text NOT NULL,
  updated_at      timestamptz NOT NULL
);
```

Write it in the same transaction as `startSession`, so the index cannot diverge from the session
it points at, and treat kioku as the authority: resolve the id from the index, then read the row
with `Session.getById`. This is a cache of a fact kioku owns, not a second source of truth. Retire
it when IR-2 lands.

Either way, rewrite `resolveSession` (`Conversation.hs:332-342`) to select the conversation's own
most recent session, preferring a `running` one; M3 extends the same function to fall back to the
most recent `completed` session so the next epoch can chain from it.

**The generation fix.** `deliverConversationInputFromApp` (`Conversation.hs:264-272`) must resolve
the live generation before reading the step index:

```haskell
deliverConversationInputFromApp :: AppEnv -> AddressedMessage -> IO Bool
deliverConversationInputFromApp appEnv' msg = do
  result <- runAppIO appEnv' do
    let wid = conversationWorkflowId msg
    gen <- currentGeneration conversationWorkflowName wid
    stepIndex <- loadStepIndex conversationWorkflowName wid gen
    signalFirst msg (pendingInputAids stepIndex)
  pure (either (const False) id result)
```

`currentGeneration` needs `Store`, which `runAppIO` already provides. Apply the same change to
`loadConversationResult` (`:290-295`) and to the shared
`Shikigami.Agent.Workflow.Input.deliverInputTo`, whose literal `0` is the same latent bug on the
agent-run path.

**Acceptance.** The existing two Conversation tests still pass unchanged (nothing they assert
moves in this milestone). A new test creates a decoy running session for the same agent under a
different `subjectRef`, runs two turns of a real conversation, and asserts that exactly one running
session exists for that conversation id and that the decoy was never selected. A second new test
asserts `currentGeneration` is consulted: run a turn, assert the delivery path succeeds, then
assert `loadConversationResult` returns the turn result — both must hold at generation 0, which is
what proves the fix is behaviour-preserving before rotation exists.

### Milestone 2 — one turn per generation, and a declared body

This is the structural milestone and the one that produces the visible win. At the end of it, the
conversation workflow's journal is bounded, every label is static, and
`domain/shikigami-conversation.keiro` describes the whole body instead of three steps of it.

**Order matters: specification first, then runtime.** `just keiro-scaffold` regenerates
`shikigami-core/src/Shikigami/DanwaConversation/Generated/WorkflowRuntime.hs`, and the runtime
consumes what it generates (`allocateDeclaredAwait`, `declaredPatches`). Editing the Haskell first
means writing against a module that does not exist yet.

**The seed.** Add a small record beside `ConversationStart`:

```haskell
data ConversationSeed = ConversationSeed
  { agentName :: !Text,
    turnsSoFar :: !Int,
    lastMessageId :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
```

Give it a hand-written codec that defaults every field on read rather than deriving
`FromJSON` generically, for the reason `docs/adr/0011-...` sets out: this value crosses a durable
boundary, and a generic codec makes a future field addition a replay break. `turnsSoFar` is
carried for observability and for the tests' rotation assertions; `lastMessageId` lets the body
recognise a redelivery of the message it just finished.

**The body.** Restructure `conversationWorkflow` (`:149-159`) and delete `loop` (`:173-184`). The
new shape processes exactly one message and rotates:

```haskell
conversationWorkflow env mStart = do
  seed <- restoreSeed (ConversationSeed {agentName = "", turnsSoFar = 0, lastMessageId = Nothing})
  start <- step (StepName "ingest-start") (ingestStart seed mStart)
  decl <- resolveDeclStep env start
  result <- processTurn env decl (initialMessage start)
  case result of
    Left err -> pure (Left err)
    Right completed -> do
      wake <- awaitConversationWake env      -- the single declared await
      case wake of
        IdleTimedOut -> completeEpoch env decl completed   -- M3
        NextMessage next ->
          continueAsNew (nextSeed seed decl next)          -- final body item
```

`ingest-start` must now accept either an explicit `ConversationStart` (generation 0, a fresh
conversation) or a restored seed plus the message that woke the previous generation (generation
≥ 1). That is the one place the two entry paths meet, and it is worth a comment saying so.

`continueAsNew` unwinds the body, so it must be the last thing the body does — which is also the
DSL's constraint (`typed-spec-toolchain.md:1744-1747`). It may not appear inside a `patch` block.

**Every label loses its suffix.** `record-user`, `run-behavior-v2`, `record-assistant-and-reply`,
`turn-result`, `danwa-reply`, `next-message`. Delete `nextMessageStepName` (`:297-299`),
`turnResultStepName` (`:301-303`), `assistantReplyStepName` (`:305-307`), and the suffix argument
of `replySinkStepName` (`:309-311`). Note that `danwa-reply` is a *sink intent* step name, not a
journaled step — it participates in the sink-intent id, which the existing test asserts by
prefix (`outbox:danwa-conversation:conv_thread_1:danwa-reply:msg_human_1`). Removing the message
id from it changes that id, so either keep the message id in the sink-intent id explicitly or
update the assertion; decide, and record which.

**Handle the rotation outcome.** `runConversationTurn` (`:129-143`) currently maps `ContinuedAsNew`
to a terminal failure at `:137`, which under this design would dead-letter every turn. It becomes
the success path: the workflow rotated, the turn's work is journaled on the generation that just
closed, so load the result from that generation and return it. Because `loadConversationResult` is
now generation-aware (M1), it must be told *which* generation to read — the one that just
completed, not the one that just started. Read the result before the rotation is observed, or pass
the generation explicitly; the safest form is to capture the generation from
`currentRunGeneration` inside the body and journal it as part of `turn-result`.

**Declare the body.** Extend `domain/shikigami-conversation.keiro`:

```text
  body
    step ingest-start -> ConversationStart
    step lookup-agent -> AgentDecl
    step resolve-session -> SessionId
    step record-user -> RecordedTurn
    step run-behavior-v2 -> BehaviorOutput
    step record-assistant-and-reply -> AssistantTurnAndReply
    step turn-result -> ConversationTurnResult
    await next-message -> ConversationWake
    continueAsNew ConversationSeed
```

The `patch shikigami-behavior-retry-v1 { }` block is the open question in this milestone, and the
plan deliberately does not pretend to know the answer. Plan 17 left it empty because both of its
branches were undeclarable; once `run-behavior` and `run-behavior-v2` are static, they are not.
Try declaring the v2 step inside the patch block and the legacy step outside it, run
`just keiro-check`, and let the checker decide. Two outcomes are acceptable and both must be
recorded in the Decision Log with the checker's exact message:

- The two-branch shape validates. Take it; the patch is now covered by the gate.
- It does not. Leave the block empty, keep `run-behavior-v2` undeclared, and say so in the file's
  comment — the same honesty ADR 0001 requires. Do **not** declare only the v2 step and pretend
  the legacy branch does not exist, because it does.

A third option exists and needs an explicit decision rather than a drive-by: retire
`shikigami-behavior-retry-v1` and delete the legacy `run-behavior` branch entirely. It is
defensible (no instance has ever taken the legacy branch in production, because there is no
production) but it retires another plan's declared identity, so it belongs in this plan's Decision
Log with plan 17 named, or nowhere.

**Regenerate and gate.**

```bash
just keiro-scaffold
just keiro-gate <merge-base>
```

Update `shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/src/KeiroConformance/Expectations.hs`
in the same change — it is hand-owned and keiro-dsl will never rewrite it.

**Acceptance.** `just keiro-gate` is green and its `keiro-diff` classification is pasted into
Surprises & Discoveries. A test drives five turns of one conversation and asserts: generation 4
exists; each generation's step index holds at most one `turn-result`; all five turns are recorded
in one kioku session as `user/assistant` pairs at indices 0–9; and the `next-message` awakeable
allocation appears once per generation and not `next-message:1..5` in one.

### Milestone 3 — idle timeout, session completion, and the next epoch

At the end of this milestone a parked conversation ends by itself, its kioku session is closed,
and the next message opens a new epoch chained to the closed one.

**The wake type.** One awakeable, two signalers:

```haskell
data ConversationWake
  = NextMessage !AddressedMessage
  | IdleTimedOut
  deriving stock (Eq, Show, Generic)
```

Both the ingress path and the timer fire action signal the same `next-message` awakeable; whoever
gets there first wins, and `signalAwakeable` makes the loser a no-op.

**The timer.** Copy `armApprovalDeadline`/`approvalTimeoutTimerId`
(`shikigami-core/src/Shikigami/Agent/Approval.hs:159-188`) into a conversation-scoped analog. The
timer id is a v5 UUID over `("shikigami", "conversation-idle", workflowName, workflowId,
generation, "next-message")`; because one generation is one turn, the generation *is* the
staleness token. Arm it with `scheduleTimerOnceTx` immediately after allocating the awakeable, so
that re-entering the await on a resume re-arms idempotently — which is keiro's obligation 3 for a
custom wake source.

**The fire action.** Write `conversationIdleTimeoutFireAction :: (Store :> es, IOE :> es) =>
TimerRow -> Eff es (Maybe EventId)` mirroring `approvalTimeoutFireAction`
(`Approval.hs:125-142`): parse the payload's `kind` discriminator, return `Nothing` if it is not
ours, otherwise signal the awakeable with `IdleTimedOut` and append the completion under the
awaited step name. Register it as a third arm of `shikigamiTimerFallback`
(`shikigami-workers/src/Shikigami/Trigger/Scheduler.hs:105-109`), after the schedule payload and
beside the approval fallback, discriminated by `kind`. Do not add a second timer loop; a timer
table with two independent readers races, which is why `Shikigami/Trigger/Timer.hs`'s header says
there is one loop.

Handle keiro's obligation 2 explicitly: an append may be declined as `JournalRefusedTerminal`
because the workflow has already gone terminal. That is not an error — settle the timer row and
deliver nothing.

**Completing the epoch.** On `IdleTimedOut`, journal a terminal `idle-timeout` step (declare it in
the specification alongside the others), close the kioku session, and return `Completed`. Close it
through `Session.completeWithContext` with the context from `Shikigami.Memory.Access`, with a
summary such as `"conversation idle timeout"` — not through the deprecated `Session.complete`
wrapper, per the Decision Log entry of 2026-08-19.

**The configuration.** Add `idleTimeout :: !NominalDiffTime` to `ConversationEnv`
(`Conversation.hs:70-78`) beside `runTimeout`, and a Settei key for it following the pattern
`worker.run_timeout_seconds` and `approval.deadline_seconds` already establish in
`shikigami-core/src/Shikigami/App/Config.hs`. Default it to 30 minutes; the tests set it to
seconds.

**The next epoch.** A message arriving after an epoch ended is delivered to a terminated workflow,
so delivery fails and `runConversationTurn` runs a fresh `ConversationStart` — the existing code
path, unchanged. What changes is `resolveSession`: it now finds the *completed* session for that
conversation id and `startSession` (`:348-372`) passes its id as `previousSessionId` instead of
`Nothing` (`:364`), so kioku records the lineage and `Session.getChain` can walk it.

**Acceptance.** Run two turns; fire the due timer the way the existing suite fires approval timers;
assert the workflow outcome is `Completed`, `Session.getById` reports `status = "completed"`, and
`countPendingAwakeables` for that conversation returns 0. Then fire a *superseded* timer — one
armed in an earlier generation — and assert it produces no terminal step and leaves the live
conversation running. Then send a third message and assert a new running session exists whose
`previousSessionId` is the completed session's id, and that the conversation continues in it.

### Milestone 4 — racing-message smoothing

The residual failure is a message arriving in the window between finishing a turn and arming the
next await, or during turn processing. Two complementary changes.

**Keep a promise armed at all times.** Allocate the next await *before* running the current turn's
behavior rather than after the turn completes. The awakeable id is journaled under
`awkid:next-message`, so allocating early is replay-stable, and it shrinks the unarmed window from
"the whole turn" to "the moment between generation start and the allocation step". Under
one-turn-per-generation this reordering is cheap because the allocation is one of a handful of
steps in a short body.

**Buffer, do not bounce.** `deliverConversationInput` returning `False` currently forces the
`ConversationStart` path, which is right for a genuinely new conversation and wrong for a busy
one. Distinguish them: if the workflow instance exists and is not terminal — ask keiro, via
`Keiro.Workflow.listWorkflowInstances` with a `workflowName`/`afterKey` filter or by looking the
instance up directly — then the message belongs to a live conversation and should be redelivered
with a short delay rather than restarted. Return a distinct outcome from
`runConversationTurn` for that case so `runConversationAgent`
(`shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs:110-159`) can map it to `RetryDefault`
*as backpressure* and log it at info rather than error. Reserve error-level logs and dead-lettering
for actual store failures and genuinely permanent outcomes.

**Acceptance.** A test delivers a second message while the first turn's behavior is still running
(use a slow stub behavior, following the instrumentation the suite already uses for agent-run
hooks). Assert the second message is delivered to the same workflow, recorded as the next turn in
the same kioku session, that no new session was created, and that no error-level log line was
emitted for it.

### Milestone 5 — tests and documentation

Extend the `Conversation` test group in
`shikigami-core/test/Shikigami/AgentWorkflowSpec.hs:536-614`. The two existing cases must be
updated rather than left alone, because M2 changes what they assert:

- "parks and resumes a danwa conversation as one workflow session" asserts
  `Map.member "turn-result:msg_human_1"` and `"record-assistant-and-reply:msg_human_2"` in
  generation 0's step index, and `any (Text.isPrefixOf "awkid:next-message:1")`. After M2 the
  labels are static and the second turn lives in generation 1. Rewrite it to read both generations
  and assert one `turn-result` in each.
- "conversation permanent v2 failure completes as a replayable typed failure" asserts
  `run-behavior-v2:msg_permanent` is present and `run-behavior:msg_permanent` is absent. The
  labels become `run-behavior-v2` and `run-behavior`.

Then add: an idle-timeout case (M3), a stale-timer case (M3), a new-epoch-after-timeout case (M3),
a rotation case (M2, five turns), and a racing-message case (M4). Reuse the harness already there
— `ConversationEnv`, `runConversationTurn`, `firstAddressedMessage`/`secondAddressedMessage`, and
the approval-timer firing idiom.

Finally, correct the two documents this plan invalidates. `docs/workflow-versioning.md:441-457`
lists "every per-message conversation label" among the undeclarable families; after M2 that is
false and the section must say what changed and why. `docs/architecture/shikigami-domain-inventory.md`
holds the census those families point at; its conversation table (lines 105-123) needs the new
labels, and while you are in it, note that it never listed `run-behavior-v2:<messageId>` at all.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shikigami` inside the Nix dev shell. A bare
`cabal build all` outside it compiles and then fails at link with
`ld: library not found for -lrdkafka`.

```bash
nix develop
```

Start the in-repo Postgres cluster and apply the schema if it is not already running — the
conversation tests provision real databases:

```bash
just create-database
```

Baseline before touching anything, so a later failure is attributable:

```bash
cabal build all
cabal test shikigami-core-test --test-options='-p Conversation'
```

Milestone 1 may touch kioku; if it does, build everything so the change is picked up:

```bash
cabal build all
```

Milestone 2 changes the specification, so run the gate against the merge base before merging:

```bash
just keiro-scaffold
just keiro-gate origin/master
```

Expected from `keiro-inspect`: both members report `"sourceForm": "declared"` at effective
language version 5 with `"languageSupport": "stable"`. Expected from `keiro-diff`: a
classification for the conversation workflow body. Paste whatever it says into Surprises &
Discoveries — including a `BREAKING` finding, which is a gate, not an advisory, and must be
resolved before merge.

Iterate per milestone and finish with the full battery:

```bash
cabal test all
```

Expected final Conversation transcript shape:

```text
AgentWorkflow
  Conversation
    parks and resumes a danwa conversation as one workflow session:  OK
    conversation permanent v2 failure completes as a replayable typed failure: OK
    resolves its own session and ignores a decoy in the same scope:  OK
    rotates onto a fresh generation after every turn:                OK
    completes the kioku session on idle timeout:                     OK
    ignores a timer armed in a superseded generation:                OK
    opens a new epoch after idle timeout, chaining session lineage:   OK
    delivers a message arriving mid-turn to the same workflow:       OK
```

Every commit while working on this plan carries both trailers:

```text
ExecPlan: docs/plans/26-conversation-workflow-lifecycle-idle-timeout-journal-rotation-session-completion.md
Intention: intention_01kx1tytnwe53rdd4es99ztv1p
```


## Validation and Acceptance

Accepted when these behaviors are observable.

1. **Session resolution is keyed.** With a decoy running session for the same agent under a
   different `subjectRef`, conversation resolution selects only the conversation's own session,
   and the decoy is never returned.
2. **The journal is bounded.** After five turns of one conversation, generation 4 exists, and no
   single generation's step index holds more than one `turn-result`. All ten turns (five user,
   five assistant) are recorded in one kioku session.
3. **The body is declared.** `just keiro-gate origin/master` exits zero, and `keiro-check
   --explain-bindings` reports the conversation workflow's steps, its `next-message` await, and its
   `continueAsNew` seed type. `domain/shikigami-conversation.keiro` no longer carries a comment
   saying its labels are undeclarable, because they are not.
4. **Idle completion.** After firing the idle timer on a parked conversation, the workflow outcome
   is `Completed`, `Session.getById` reports `status = "completed"`, and `countPendingAwakeables`
   for that conversation returns 0.
5. **Stale timers are inert.** A timer armed in a superseded generation, fired after a newer
   message and after a rotation, leaves the active conversation and session running and produces
   no terminal step.
6. **New epoch.** A message after a timeout starts a fresh running session whose
   `previousSessionId` is the completed session id, and turns continue in the new session.
7. **Racing delivery.** A message delivered during turn processing is recorded as the next turn in
   the SAME session, with no new session created and no error-level worker log line.
8. **No regressions.** `cabal test all` is green, including `keiro-shikigami-conformance`, the
   `WorkflowVersioning` deploy simulation from plan 24, and the untouched agent-run tests.

Two things this plan explicitly does **not** owe, per
`docs/architecture/implementation-order.md`'s "Compatibility work that v1 does not owe": a proof
that an in-flight conversation survives this deploy, and byte-for-byte preservation of any wire
shape it changes. Nothing consumes shikigami. Build the mechanism; assert the shape you want.


## Idempotence and Recovery

All changes are code, specification, and tests; builds and tests repeat safely and each test
provisions its own migrated database. If M1 takes the fallback index table, its migration is
additive and `CREATE TABLE IF NOT EXISTS`, so re-running `just migrate` is a no-op.

The generation-aware ingress (M1) is a pure correctness fix — reading the current generation is
always correct, including when it is 0 — so it is safe to land and safe to keep whatever happens to
the rest of the plan.

M2 is the irreversible-looking step, and it is worth being precise about why it is not. It changes
persisted label names in a workflow with no live instances, so there is nothing to strand.
`just keiro-diff` classifies the change and refuses a `BREAKING` finding before merge, which is
the real safety net. If the restructure has to be abandoned mid-flight, revert the specification
and the generated layer together — they are regenerated from one source, so `just keiro-scaffold`
followed by `git diff --exit-code` will tell you whether they agree.

M3's timer routing is the one place where a partial landing could misbehave: a fire action
registered before the workflow can handle `IdleTimedOut` would signal an awakeable whose consumer
does not understand the payload. Land the wake type and the body's handling of it in the same
commit as the fire action, and keep the `kind` discriminator so an unrecognised row falls through
to the existing arms rather than being consumed. If the three-way routing in
`shikigamiTimerFallback` proves fragile, the fallback is to make the discrimination explicit with
a small sum type over the payload kinds rather than a chain of `Maybe`s — not to add a second
timer worker, which would race.


## Interfaces and Dependencies

**Hard dependencies, all landed:** plans 24, 36, 37, 39, 47, 53, and plan 17 through Milestone 4.
Verify with `git log --oneline` and against each plan's Progress section before starting.

**Open upstream gate:** kioku IR-2
(`mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2`) for `getBySubjectRef`. M1 has a
documented fallback and is not blocked.

**Libraries.** `keiro 0.13.0.0` — `Keiro.Workflow` (`step`, `patch`, `continueAsNew`,
`restoreSeed`, `currentRunGeneration`, `currentGeneration`, `loadStepIndex`,
`appendJournalEntryReturningId`, `listWorkflowInstances`), `Keiro.Workflow.Awakeable`
(`awakeableNamed`, `signalAwakeable`), `Keiro.Workflow.Sleep` (`runWorkflowTimerWorker`),
`Keiro.Timer` (`TimerId`, `TimerRequest`, `TimerRow`, `scheduleTimerOnceTx`). `kioku 0.4.1.0` —
`Kioku.Session` (`getById`, `getByScope`, `getChain`, `getTurns`, `startWithContext`,
`completeWithContext`, and `getBySubjectRef` if IR-2 lands), `Kioku.Session.ReadModel`
(`SessionRow`, `TurnRow`). Shikigami — `Shikigami.Workflow.Versioning`
(`shikigamiWorkflowRunOptions`), `Shikigami.Memory.Access` (`shikigamiMemorySpace`, `agentActor`,
`shikigamiReadContext`), and the generated
`Shikigami.DanwaConversation.Generated.WorkflowRuntime` (`workflowName`, `allocateDeclaredAwait`,
`declaredPatches`).

**Signatures that must exist at the end**, with full paths:

```haskell
-- kioku-core/src/Kioku/Session.hs (new, if IR-2 lands; note the leading MemorySpaceId)
getBySubjectRef ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId -> Text -> Eff es (Either ReadModelError [SessionRow])

-- kioku-core/src/Kioku/Session/ReadModel.hs (new, if IR-2 lands)
data SessionsBySubjectRefQuery = SessionsBySubjectRefQuery MemorySpaceId Text
sessionsBySubjectRefReadModel :: ReadModel SessionsBySubjectRefQuery [SessionRow]

-- shikigami-core/src/Shikigami/Agent/Conversation.hs (changed)
data ConversationSeed = ConversationSeed
  { agentName     :: !Text,
    turnsSoFar    :: !Int,
    lastMessageId :: !(Maybe Text)
  }                                             -- hand-written, field-defaulting codec

data ConversationWake
  = NextMessage !AddressedMessage
  | IdleTimedOut

data ConversationEnv = ConversationEnv
  { appEnv       :: !AppEnv,
    behaviorEnv  :: !BehaviorEnv,
    runTimeout   :: !NominalDiffTime,
    idleTimeout  :: !NominalDiffTime,           -- new; no rotateEvery, by design
    danwa        :: !DanwaConfig,
    agents       :: ![AgentDecl],
    grants       :: !GrantSource
  }

conversationIdleTimeoutFireAction ::
  (Store :> es, IOE :> es) => TimerRow -> Eff es (Maybe EventId)

-- shikigami-core/src/Shikigami/App/Config.hs (extended)
-- a stable Settei key for the idle window, beside worker.run_timeout_seconds
```

**Consumers to keep working.** `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs`
(`runConversationAgent` at `:110-159` and `conversationJobOutcome` at `:247-255` must stop treating
`ContinuedAsNew` as terminal and must gain the busy-conversation backpressure outcome);
`shikigami-workers/src/Shikigami/Trigger/Scheduler.hs:105-109` (timer routing);
`shikigami-workers/src/Shikigami/Agent/Workflow/Resume.hs:30-33` (the resume registry already
carries both workflow families through `shikigamiWorkflowResumeOptions`, and drives rotated
generations without change); and
`shikigami-server/src/Shikigami/Server/Command/DanwaSpike.hs` if it drives conversations.

**Cross-plan contracts.** `docs/plans/27-consolidate-sink-intent-and-run-lifecycle-machinery.md`
owns `prepareConversationReplySinkIntent` (`Conversation.hs:456-485`) and the `SinkIntent`
consolidation; if M2 changes the `danwa-reply` sink-intent id, coordinate with plan 27's
Integration Points so the reply path keeps using one shared module.
`docs/plans/25-replay-safe-flow-memory-capabilities.md` adds labelled memory steps to the same
specification workspace — both plans regenerate the same generated layer, so whichever lands
second re-runs `just keiro-scaffold` and re-accepts the conformance expectations.
`docs/plans/54-key-durable-agent-state-by-meibo-principal.md` owns moving the whole kioku write
path to `*WithContext`; this plan only refrains from adding to the debt.
`docs/plans/17-...` owns the per-turn behavior timeout and the `shikigami-behavior-retry-v1` patch;
this plan must not change either without naming plan 17 in its Decision Log.


## Revision Notes

- 2026-07-22: Added plan 39's checked topology gate and corrected idle timeout handling
  to cancel/version superseded timers and ignore stale completions across turns and
  continue-as-new generations.

- 2026-08-10: Amended the `continueAsNew` decision to record that shikigami has no users, so there
  are no live parked conversations for the patch guard to protect. Kept the guard and proposed
  proving it with a constructed instance.

- 2026-08-19: **Full refresh against the delivered tree.** Superseded by this note: the 2026-07-30
  "Portfolio Reconciliation" section and the 2026-08-19 "Reconciliation with the delivered plan
  39" section, both of which are folded into Context and Orientation above.

  *Why the refresh was needed.* Six dependencies landed between 2026-07-08 and now, and
  `docs/architecture/implementation-order.md` records a standing requirement to audit a plan's
  citations immediately before implementing it — 19 open plans cite `shikigami-cli` or
  `shikigami-core/src/Shikigami/Worker.hs`, both deleted by plan 36, and seven carry
  line-numbered keiro citations predating 0.13. This plan carried both faults. Every path and line
  number here has been re-resolved against commit `860b680` and against the pinned
  `keiro 0.13.0.0` / `kioku 0.4.1.0` checkouts.

  *What changed in the design, not just the citations.* Two things.

  First, **rotation cadence became one turn per generation**, replacing "every N turns, default
  20". The reason is that keiro-dsl language 5 can declare `await`, `sleep`, `patch`, and
  `continueAsNew` — which the 2026-08-19 plan-39 reconciliation section did not know — and its
  label-uniqueness rule is the only reason the per-message suffixes exist. One turn per generation
  removes the suffixes, which makes the entire conversation body declarable and puts it under
  `just keiro-gate` for the first time. That converts this plan from "bound a journal" into "bound
  a journal *and* discharge plan 39's largest undeclarable-label family", which is a strictly
  better trade for one extra rotation per turn.

  Second, **the idle race became one awakeable with two signalers**, replacing "await a sum of
  {next message, idle fired}". keiro's `awaitStep` suspends on one step name and cannot await a
  sum of two; the pattern that works is the one `awaitApproval` already uses, and it has the
  additional virtue of being a single declared `await` label.

  *What was dropped.* The patch guard around the loop restructure, and with it the constructed-
  instance proof the 2026-08-10 amendment asked for. `docs/architecture/implementation-order.md`
  records that in-flight survival is not v1 scope, plan 24 shipped its own proof on 2026-08-19
  (commit `82e8315`), and plan 17 shipped a second live patch consumer. The structural argument is
  stronger than the scheduling one: a guard here would have to hold the old, undeclarable loop
  shape, so the plan would be adding an ungated branch in the same change that removes ungated
  labels. `just keiro-diff`'s classification replaces it as the safety net. The `rotateEvery`
  knob was dropped with it.

  *What was corrected.* `Session.complete` → `completeWithContext` through
  `Shikigami.Memory.Access` (kioku 0.4 made spaces and principals mandatory and deprecated the
  wrappers). `getBySubjectRef`'s signature takes a `MemorySpaceId`, not a `Namespace`. The kioku
  tables are `kioku.sessions`/`kioku.turns`, not `kiroku.kioku_*`. The worker's delivery failure
  path is `RetryDefault` via a typed `JobOutcome`, not `AckRetry (RetryDelay 1s)`. The stale-timer
  decision now points at `approvalTimeoutTimerId`, which already solves it. And keiro 0.13's
  documented `continueAsNew`-versus-`appendJournalEntry` rotation race was added as an obligation
  the idle timer must satisfy — it matters far more under per-turn rotation than it would have
  under a 20-turn cadence.
