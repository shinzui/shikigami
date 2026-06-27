---
id: 8
slug: conversational-agent-loop-bound-to-danwa
title: "Conversational agent loop bound to danwa"
kind: exec-plan
created_at: 2026-06-27T16:23:56Z
intention: "intention_01kw4y6ktdebtscmdds2ydv24e"
---

# Conversational agent loop bound to danwa

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today a `shinzui/shikigami` agent is a batch job. A trigger fires, the agent runs its
behavior once, writes its result to some sinks, and the run ends. There is no way for a
human to *talk to* an agent — to post a message, get a reply, post a follow-up that the
agent answers *with the earlier exchange in mind*, and keep going. The conversation
**storage** already exists: `shinzui/kioku` durably records multi-turn turn history
(`kioku_turns`, `Kioku.Session.recordTurn`/`getTurns`, and an `Interactive` session
vertex). What is missing is the **runtime loop** that drives a live, stateful,
back-and-forth dialogue and binds it to `shinzui/danwa`, the conversation substrate where
humans and agents actually post messages.

After this change, a person can open (or be in) a danwa conversation thread, address a
message to an agent (for example by `@`-mentioning it or having it assigned to the
thread), and get a real reply posted back into that same thread by the agent. They can
then post a *second* message in the thread; the agent answers again, and its second
answer is informed by the first exchange because the whole dialogue is one durable kioku
session. Crucially, **between** the human's turns the agent's run does not sit burning
resources and it does not die: it **parks** — it durably suspends and waits — then
**resumes** when the next human message arrives. This is the same durable suspend/resume
machinery used by approvals (the "keystone" re-platforming described below).

You can see it working at the end of this plan by posting two human messages into one
danwa thread and observing, with plain SQL and HTTP, three things at once: (1) two agent
replies appear in the danwa thread, (2) four turns are recorded in `kioku_turns` for one
session (a `user` turn and an `assistant` turn per human message), and (3) the agent's
workflow record shows it suspended after the first reply and resumed on the second
message rather than running two independent jobs.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **M0 — Danwa binding spike.** Added
      `shikigami-cli/src/Shikigami/Cli/Commands/DanwaSpike.hs`, wired the
      `danwa-spike` subcommand through `shikigami-cli/src/Shikigami/Cli.hs`, added
      `danwa-api`/`danwa-client` to `shikigami-cli/shikigami-cli.cabal`, pinned danwa
      packages in `cabal.project`, and verified with
      `nix develop --command cabal build shikigami-cli`.
      Completed: 2026-06-27T18:58:25Z.
      Original scope: Add a throwaway CLI subcommand (or test) that uses
      `Danwa.Client` to start a conversation, join an `Agent` participant, post a human
      message, and post an agent reply; observe the rows in `danwa.danwa_messages`. Proves
      the danwa API end to end before any loop work.
- [x] **M1 — Real `DanwaConversation` sink.** Replaced `runDanwaStub` in
      `shikigami-core/src/Shikigami/Sink/Danwa.hs` with a handler that posts the behavior
      output into a danwa thread via `Danwa.Client.postMessage`/`replyToMessage`; added
      `DanwaConfig` and `DanwaTarget`, threaded danwa config through `WorkerEnv`,
      `AgentRunDeps`, `SinkIntent`, and `SinkContext`; changed the `DanwaConversation {}`
      arm of `Shikigami.Sink.runSink` from `Stubbed` to `Delivered`/`Failed`; added WAI
      stub-backed tests for targeted replies and fresh-thread fallback.
      Validated with `nix develop --command cabal build all` and
      `nix develop --command cabal test shikigami-core-test`.
      Completed: 2026-06-27T19:06:10Z.
- [x] **M2 — Conversational trigger (addressed message → run/resume).** Added
      `shikigami-core/src/Shikigami/Trigger/Danwa.hs` with `AddressedMessage`,
      `DanwaBridgeConfig`, `detectAddressed`, `runDanwaBridgeOnce`, and `runDanwaBridge`;
      added `enqueueAddressedRunWithKey` so the bridge can set
      `idempotencyKey = agentName <> ":" <> messageId`; added a `danwa-bridge` CLI command
      that polls danwa read-model mentions and enqueues addressed run jobs; persisted
      bridge idempotency in `shikigami_danwa_bridge_seen`.
      Validated with `nix develop --command cabal build all` and
      `nix develop --command cabal test shikigami-core-test`.
      Completed: 2026-06-27T19:13:25Z.
      Original scope: A new module
      `Shikigami.Trigger.Danwa` that detects a danwa message addressed to a declared agent
      and either starts a new conversation run or resumes the parked one, by enqueuing onto
      `shikigami_run_jobs` (`Shikigami.Trigger.Enqueue.enqueueAddressedRun`). Carry
      `conversationId`, `messageId`, `author`, and `content` in the run payload.
- [x] **M3 slice — Addressed message jobs run as conversation turns.** Added
      `shikigami-core/src/Shikigami/Agent/Conversation.hs` with `ConversationEnv`,
      `ConversationTurnResult`, and `runConversationTurn`; `Shikigami.Worker.handleRunJob`
      now detects an `AddressedMessage` trigger payload, resolves the declared agent,
      ensures/reuses one running kioku session whose `subjectRef` is the danwa
      `conversationId`, records `user` and `assistant` turns, runs the behavior, and replies
      to the triggering danwa message via the M1 `postReply` client.
      Validated with `nix develop --command cabal build all` and
      `nix develop --command cabal test shikigami-core-test`.
      Completed: 2026-06-27T19:18:36Z.
- [x] **M3 remaining — Durable park/resume loop.** Promoted the conversation turn runner
      into a long-lived `shikigami.danwa-conversation` keiro workflow keyed by
      `danwa-conversation:<conversationId>`; added `Shikigami.Agent.Workflow.Input` for the
      generic `awaitInput`/`deliverInput` surface; made each conversation workflow park on
      `next-message:<n>` awakeables after enqueueing the assistant reply into the sink
      outbox; wired the worker resume registry to include conversation workflows; and made
      the danwa bridge call a delivery callback before enqueueing a new start job.
      Validated with `nix develop --command cabal test shikigami-core-test` (28 tests,
      including the two-turn conversation workflow test and bridge delivery-before-enqueue
      test) and `nix develop --command cabal build all`.
      Completed: 2026-06-27T22:22:24Z.
- [x] **M3 hardening — co-transactional assistant turn and reply outbox.** Replaced the
      separate `record-assistant:<messageId>` workflow step plus `danwa-reply:<messageId>`
      outbox step with one `record-assistant-and-reply:<messageId>` workflow step. The step
      now uses `Keiro.Command.runCommandWithSqlEvents` against `Kioku.Session.EventStream`
      so the `RecordTurn` append, `sessionInlineProjection`, `l1TimerScheduleProjection`,
      and `Keiro.Outbox.enqueueOutboxTx` all run in the command append transaction. The
      sink intent preparation remains shared with the normal agent-run outbox path via
      `Shikigami.Agent.Workflow.prepareSinkIntent`. A replay after the command transaction
      commits but before the workflow step journals sees the existing assistant turn and
      returns the same deterministic `outbox:` handle without enqueueing a duplicate row.
      Validated with `nix fmt`, `nix develop --command cabal test shikigami-core-test` (28
      tests), and `nix develop --command cabal build all`.
      Completed: 2026-06-27T23:06:00Z.
- [ ] **M4 — End-to-end acceptance.** Post two human messages; show two danwa replies, four
      `kioku_turns` rows for one session, and a workflow journal proving the park-between-turns.
- [x] **Dependency tracking.** Confirmed plan 7 ("Agent runs as durable keiro workflows")
      has landed its workflow suspend/resume substrate and `awaitInput`; confirm the kioku
      `Awaiting` session state (kioku plan "Awaiting session state for durable
      park-and-resume") if used; confirm danwa can surface addressed-message events
      (see Interfaces & Dependencies for the fallback that needs no danwa change).
      Evidence: `Shikigami.Agent.Approval` already exposed generic `awaitInput` and
      `deliverInput`; this implementation moved them to
      `Shikigami.Agent.Workflow.Input`, preserved the approval wrapper behavior, and uses the
      existing keiro awakeable/outbox/resume worker APIs. The optional kioku `Awaiting`
      state was not used; sessions stay `Running`. Completed: 2026-06-27T22:22:24Z.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Plain `cabal build shikigami-cli` outside the Nix dev shell failed while relinking
  `shikigami-core` because the local shell could not find `librdkafka`; the documented
  `nix develop --command cabal build shikigami-cli` path succeeded. Evidence:

  ```text
  ld: library not found for -lrdkafka
  clang: error: linker command failed with exit code 1
  ```

- `Danwa.Conversation.Api.StartConversationRequest` has `startedBy`, `kind`, and
  `parentConversationId`; it has no durable `topic` field. Evidence from
  `/Users/shinzui/Keikaku/bokuno/danwa/danwa-api/src/Danwa/Conversation/Api.hs`:

  ```haskell
  data StartConversationRequest = StartConversationRequest
    { startedBy :: !Text,
      kind :: !Text,
      parentConversationId :: !(Maybe Text)
    }
  ```

- pgmq `sendMessage` does not deduplicate on `RunJob.idempotencyKey`; the bridge needs its
  own durable claim before enqueueing a detected danwa message. Evidence: reusing
  `enqueueRunJob` sends a message body to `shikigami_run_jobs`; the idempotency key is data
  inside the JSON payload, not a pgmq uniqueness constraint.

- Plan 7's exact generic input helpers had landed inside `Shikigami.Agent.Approval`, not in
  a standalone workflow module. The conversation workflow needed the same helper against a
  non-`shikigami.agent-run` workflow name, so the implementation extracted the generic
  helper to `Shikigami.Agent.Workflow.Input` and left `Shikigami.Agent.Approval` re-exporting
  the same names. Evidence: `nix develop --command cabal test shikigami-core-test` passed
  the existing approval tests plus the new conversation workflow tests.

- Kioku's public `Session.recordTurn` intentionally owns its transaction through
  `runCommandWithProjections`, but the lower-level pieces it uses are exported:
  `Kioku.Session.EventStream.sessionEventStream`/`sessionStream`,
  `Kioku.Session.Domain.RecordTurn`, `Kioku.Session.ReadModel.sessionInlineProjection`, and
  `Kioku.Distill.Timer.l1TimerScheduleProjection`. This allowed shikigami to add the reply
  outbox enqueue to the same command append transaction without changing kioku.


## Decision Log

Record every decision made while working on the plan.

- Decision: One kioku session per danwa conversation; the session stays in the `Running`
  vertex across all turns and is only `complete`d when the conversation closes.
  Rationale: `Kioku.Session.recordTurn` rejects turns unless the session row's `status` is
  `"running"` (it returns `SessionNotRunning` otherwise — see
  `kioku-core/src/Kioku/Session.hs` lines 107–118). The `Interactive` vertex is *terminal*
  in the kioku transducer (`kioku-core/src/Kioku/Session/Domain.hs`, `isTerminal` returns
  `True` for `Interactive`), so it cannot host an open multi-turn loop. Keeping the session
  `Running` and looping `recordTurn` is the supported path; `complete` ends it.
  Date: 2026-06-27

- Decision: The durable park between human turns lives in the **keiro workflow** (plan 7's
  substrate), not in a new kioku state. The kioku session merely stays `Running`.
  Rationale: The gap analysis (`kikan/docs/architecture/evolution/agent-infrastructure-gaps.md`,
  gap #3) places the loop in shikigami over keiro's long-lived-workflow primitive and
  treats turn storage as already-solved in kioku. A kioku `Awaiting` vertex is an *optional*
  enhancement for auditing *why* a session is parked; it is not required for the park
  itself.
  Date: 2026-06-27

- Decision: The conversational trigger keys the workflow by `conversationId`, so a second
  addressed message in the same thread *resumes the existing parked workflow* rather than
  starting a second independent run.
  Rationale: This is what makes it a conversation and not two batch jobs; it is the
  observable difference the acceptance test checks.
  Date: 2026-06-27

- Decision: "Addressed to the agent" is detected from danwa as either (a) an
  `EmbellishmentAdded` of kind `Mention` whose payload names the agent's `ParticipantId`,
  or (b) the agent being assigned to the conversation (`Danwa.Client.assignAgent`). The
  agent's danwa `ParticipantId` is configured per agent.
  Rationale: danwa models addressing via Mention embellishments and agent assignment; both
  resolve to "this message wants this agent."
  Date: 2026-06-27

- Decision: M2 ships with a **read-model polling bridge** over danwa's `danwa_messages` /
  `danwa_embellishments` tables as the default trigger source, with a danwa-emitted
  integration-event path documented as the preferred upgrade.
  Rationale: The polling bridge needs **no danwa code change**, so this plan is
  self-contained and can be validated immediately; emitting a first-class
  `MessageAddressedToAgent` integration event is danwa-side work tracked as a dependency.
  Date: 2026-06-27

- Decision: Pin `danwa-core`, `danwa-api`, and `danwa-client` in `cabal.project` as a
  source-repository-package from `https://github.com/shinzui/danwa.git` at commit
  `301bc1b381fb1baa253b9ba5fce5735e6d0a8ca9`, and depend on `danwa-api`/`danwa-client`
  from `shikigami-cli`.
  Rationale: M0 needs the real typed client and request/response DTOs to compile in this
  repository, and `git ls-remote` confirmed that commit is current `origin/master`.
  Date: 2026-06-27

- Decision: Implement shikigami's sink function as
  `runDanwa :: DanwaConfig -> AgentIdentity -> Maybe DanwaTarget -> Sink -> Value -> IO (Either Text Text)`
  instead of hiding the optional target outside the signature.
  Rationale: The target lives on `SinkContext`, and making it an explicit argument keeps
  the pure dispatcher-to-client handoff visible. It also lets M3's conversational workflow
  supply `DanwaTarget { dtConversationId, dtParentMessageId }` through the existing outbox
  `SinkIntent` payload.
  Date: 2026-06-27

- Decision: For an untargeted `DanwaConversation` sink, start a fresh danwa conversation
  with `kind = "thread"`, join the configured agent participant, and post the behavior
  output as the first message; do not try to persist `Sink.topic` into danwa.
  Rationale: danwa does not expose a topic field on `StartConversationRequest`. Targeted
  conversational replies carry the actual thread identity via `DanwaTarget`, so the topic
  remains only shikigami declaration metadata until danwa grows a first-class title/topic.
  Date: 2026-06-27

- Decision: Persist M2 bridge idempotency in a shikigami-owned table
  `shikigami_danwa_bridge_seen(idempotency_key text primary key, seen_at timestamptz)`,
  created idempotently when the bridge starts.
  Rationale: The bridge can safely rescan danwa read-model rows on every poll and still
  satisfy "same message id produces no second job"; `agentName:messageId` is claimed before
  enqueueing, so a repeated observation is skipped before pgmq send.
  Date: 2026-06-27

- Decision: Land M3 in two slices: first the concrete conversation-turn behavior in
  `Shikigami.Agent.Conversation`, then the durable `awaitInput` loop.
  Rationale: The first slice makes addressed danwa jobs observably different from batch
  jobs immediately: they reuse one kioku session per conversation, record human/assistant
  turns, and reply to the same danwa thread. The remaining slice is still required for the
  headline park-between-turns behavior because the current slice posts synchronously and
  returns after one turn.
  Date: 2026-06-27

- Decision: The bridge owns the "resume before enqueue" check through a callback on
  `DanwaBridgeConfig` instead of importing `Shikigami.Agent.Conversation` from
  `Shikigami.Trigger.Danwa`.
  Rationale: `Shikigami.Agent.Conversation` depends on `Shikigami.Trigger.Danwa` for the
  `AddressedMessage` type, so importing the conversation module back into the trigger module
  would create a cycle. The CLI supplies `deliverConversationInputFromApp`; tests can supply
  `const (pure False)` or `const (pure True)` to cover enqueue and resume paths.
  Date: 2026-06-27

- Decision: Conversation replies now record a deterministic `outbox:` handle in
  `ConversationTurnResult.replyMessageId` rather than a danwa `msg_…` id.
  Rationale: Once replies move to the plan 7 outbox, the workflow has durably requested the
  reply but the HTTP publisher has not necessarily run yet. The returned value is the stable
  outbox message id; the existing sink publisher later calls `Shikigami.Sink.Danwa.runDanwa`
  and obtains the real danwa message id.
  Date: 2026-06-27

- Decision: For conversation replies, use `Keiro.Command.runCommandWithSqlEvents` directly
  rather than `Kioku.Session.recordTurn`, and apply the same Kioku inline projections plus
  `Keiro.Outbox.enqueueOutboxTx` in that callback.
  Rationale: `Session.recordTurn` cannot accept an additional in-transaction side effect,
  while `runCommandWithSqlEvents` is the primitive Kioku's projection runner uses. This
  gives the plan's required atomicity for assistant-turn event append, turn read-model
  projection, timer projection, and reply outbox enqueue, while preserving Kioku's command
  transducer and event stream.
  Date: 2026-06-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- M0 delivered a working CLI spike surface named `danwa-spike`. The implementation has not
  been exercised against a live danwa server in this session, but it compiles against the
  real `Danwa.Client` API and is ready for the M0 runtime acceptance check once
  `danwa-server` is running.
- M1 made `DanwaConversation` a real delivered sink. The implementation posts targeted
  replies when `SinkContext` carries a `DanwaTarget`, starts a fresh danwa thread for
  untargeted one-shot runs, and is covered by `shikigami-core-test` WAI stub tests.
- M2 delivered the polling trigger bridge. It detects `mention` embellishments whose JSON
  payload names a configured agent participant, maps that participant to a declared agent,
  enqueues one addressed run job with the normalized message payload, and proves repeated
  observation is idempotent in `shikigami-core-test`.
- M3 has a working conversation-turn runner but not yet the durable parked loop. Addressed
  jobs now record turns into a kioku session keyed by the danwa conversation and reply under
  the human message; the next step is replacing the one-turn return with `awaitInput`
  suspension and `deliverInput` resume.
- M3 now has the durable parked loop. `Shikigami.Agent.Conversation` runs a
  `shikigami.danwa-conversation` workflow keyed by `danwa-conversation:<conversationId>`,
  records both human and assistant turns into one running kioku session, enqueues the
  assistant reply through the sink outbox, then parks on a `next-message:<n>` awakeable. The
  danwa bridge now tries to deliver an addressed message to an already-parked conversation
  workflow before enqueueing a new run job.
- M3 hardening is complete. Assistant-turn recording and reply outbox enqueue now commit in
  one SQL transaction using Keiro's command callback. The workflow journals one combined
  `record-assistant-and-reply:<messageId>` step for replay; the deterministic outbox handle
  keeps crash recovery idempotent if the command transaction commits before the workflow
  step journal does. The live danwa-server M4 acceptance remains open.


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it fully before editing.

### What shikigami is, in one paragraph

`shinzui/shikigami` (the repository at `/Users/shinzui/Keikaku/bokuno/shikigami`) is a
declared-agent runtime. An *agent* is a declaration written in Dhall (a typed
configuration language) describing four things: a **trigger** (when the agent runs), a
**behavior** (what work it does), and a list of **sinks** (where its output goes). The
declaration type is `AgentDecl` in
`shikigami-api/src/Shikigami/Api/Agent.hs`:

```haskell
data AgentDecl = AgentDecl
  { name :: !Text,
    description :: !Text,
    trigger :: !Trigger,
    behavior :: !Behavior,
    sinks :: ![Sink]
  }
```

`Trigger` is `Schedule {cron}` | `Stream {match}` | `Event {eventType}`. `Behavior` is
`Deterministic {..}` | `ShikumiProgram {..}` | `Skill {path}`. `Sink` is one of
`KawaDigest`, `KizashiSignal`, `ReiAction`, and `DanwaConversation {topic :: Text}` — the
last is the one this plan makes real.

### How a run happens today (the path you are extending)

1. A trigger fires and a **run job** is enqueued. The contract is
   `Shikigami.Api.RunJob` (`shikigami-api/src/Shikigami/Api/RunJob.hs`):

   ```haskell
   data TriggerKind = TriggeredBySchedule | TriggeredByStream | TriggeredByEvent
   data RunJob = RunJob
     { agentName :: !Text,
       triggerKind :: !TriggerKind,
       occurredAt :: !UTCTime,
       triggerPayload :: !Value,    -- arbitrary JSON the behavior receives
       idempotencyKey :: !Text
     }
   ```

   The producer side is `Shikigami.Trigger.Enqueue`
   (`shikigami-core/src/Shikigami/Trigger/Enqueue.hs`): `enqueueRunJob :: Pool -> RunJob ->
   IO (Either UsageError MessageId)` puts a job on the `shikigami_run_jobs` pgmq queue, and
   `enqueueAddressedRun :: Pool -> Text -> Value -> IO (Either UsageError MessageId)`
   enqueues an *addressed* (event-trigger) run for a named agent with a payload. (pgmq is a
   PostgreSQL-backed message queue.)

2. The **worker** drains the queue. `Shikigami.Worker`
   (`shikigami-core/src/Shikigami/Worker.hs`) builds a `shibuya` queue processor over pgmq
   and, per job, calls `handleRunJob` → `runOneAgent`. `runOneAgent` calls
   `runAgentWithMemory`, then dispatches each sink with `Shikigami.Sink.dispatch`, then maps
   the result to a `shibuya` `AckDecision` (`AckOk` | `AckRetry` | `AckDeadLetter`).

3. `runAgentWithMemory` (`shikigami-core/src/Shikigami/Agent/Run.hs`) is the
   "run-with-memory bracket": it opens a kioku `Session` (`Kioku.Session.start`), recalls
   prior learnings, calls `runBehavior`, records the output as a kioku memory, then
   `Kioku.Session.complete`s the session. **This runs to completion and cannot suspend.**
   That single fact is the gap this plan closes for the conversational case.

4. `runBehavior` (`shikigami-core/src/Shikigami/Behavior/Run.hs`) dispatches on the
   behavior union: `Skill` → `Shikigami.Behavior.Skill.runSkill` (a `baikai` LLM
   completion built from a `SKILL.md`), `ShikumiProgram` → a `handan` task. The output is a
   JSON `Value`.

5. Sinks. `Shikigami.Sink.dispatch` (`shikigami-core/src/Shikigami/Sink.hs`) permission-gates
   each sink then routes it. The `DanwaConversation` arm currently calls `runDanwaStub`
   (`shikigami-core/src/Shikigami/Sink/Danwa.hs`), which logs one line and no-ops, returning
   a `Stubbed` outcome. **This is the stub this plan replaces.**

### What kioku already gives you (storage is solved)

`shinzui/kioku` is at `/Users/shinzui/Keikaku/bokuno/kioku`; shikigami pins it in
`cabal.project`. The relevant modules:

- `kioku-core/src/Kioku/Session.hs` exposes `start`, `complete`, `failSession`,
  `recordInteractive`, **`recordTurn`**, `getById`, **`getTurns`**, `getByScope`, and more.
  `recordTurn :: (...) => RecordTurnData -> Eff es (Either SessionWriteError SessionId)`
  appends one durable turn and requires the session to be `Running` (else `SessionNotRunning`).
  `getTurns :: (...) => SessionId -> Eff es (Either ReadModelError [TurnRow])` reads them back.

- `kioku-core/src/Kioku/Session/Domain.hs` defines
  `data SessionVertex = NotCreated | Running | Completed | Failed | Interactive` and the
  turn payload:

  ```haskell
  data RecordTurnData = RecordTurnData
    { sessionId :: !SessionId,
      turnId :: !Text,
      turnIndex :: !Int,
      role :: !Text,            -- "user" | "assistant"
      content :: !Text,
      toolSummary :: !(Maybe Text),
      promptTokens :: !(Maybe Int),
      outputTokens :: !(Maybe Int),
      recordedAt :: !UTCTime
    }
  ```

  Turns are written via the `RecordTurn` command and projected to the `kioku_turns` read
  model. The conversation history is therefore already durable; this plan only adds the loop
  that *produces* the turns.

### What danwa is and the real API you will call (grounded in source)

`shinzui/danwa` is at `/Users/shinzui/Keikaku/bokuno/danwa` — an event-sourced
conversation substrate (PostgreSQL event store via keiki/kiroku, `shibuya` workers, servant
HTTP). Conversations, messages, and participants are first-class. The IDs are TypeID
strings: `conv_…` (`ConversationId`), `msg_…` (`MessageId`), `part_…` (`ParticipantId`).
Participants carry a kind: `data ParticipantType = Human | Agent | Team | Service |
Workflow` — an agent is a participant of kind `Agent`.

The typed client is `Danwa.Client` (`danwa-client/src/Danwa/Client.hs`); shikigami will
depend on the `danwa-client` package. The functions you need, with their real signatures:

```haskell
-- Run a servant ClientM against a base URL.
runDanwa :: ... -- (see Danwa.Client; wraps servant's runClientM)

-- Conversations
startConversation :: StartConversationRequest -> ClientM ConversationResponse
joinConversation  :: Text -> JoinConversationRequest -> ClientM NoContent   -- conversationId
assignAgent       :: ...   -- "Agent operations" group: bind an agent to a conversation

-- Messages (this is how the agent posts its reply)
postMessage    :: Text -> PostMessageRequest -> ClientM MessageResponse        -- conversationId
replyToMessage :: Text -> Text -> PostMessageRequest -> ClientM MessageResponse -- convId, parentMessageId
listMessages   :: ...
getMessage     :: ...

-- Embellishments (addressing: a Mention names the addressed participant)
addEmbellishment   :: Text -> AddEmbellishmentRequest -> ClientM EmbellishmentResponse
listEmbellishments :: ...
```

`PostMessageRequest` carries `{ author :: Text, content :: Text }` where `author` is the
agent's `part_…` id and `content` is the reply text; the response `MessageResponse` carries
`{ messageId, conversationId, author, content, postedAt }`. A message *addressed to* an
agent is, on the danwa side, a `MessagePosted` whose message also has an
`EmbellishmentAdded` of kind `Mention` naming the agent's `ParticipantId` (the
`EmbellishmentKind` enum includes `Mention`), or a conversation the agent was assigned to.

The danwa domain events live in `danwa-core/src/Danwa/Message/Generated/Domain.hs`
(`MessageEvent`, including `MessagePosted (MessagePostedData {messageId, conversationId,
author, parentMessageId, content, commandId})`) and
`danwa-core/src/Danwa/Embellishment/Generated/Domain.hs` (`EmbellishmentEvent`, including
`EmbellishmentAdded`). They are persisted to the `danwa.danwa_messages` and
`danwa.danwa_embellishments` read-model tables by the projection workers in `danwa-workers`.
**Important:** danwa currently publishes these events only *internally* (kiroku/shibuya
projections + a pgmq agent-summary queue); it does not emit a first-class external
"message addressed to an agent" event onto a stream shikigami consumes. That gap is handled
in Interfaces & Dependencies (the polling bridge needs no danwa change; the integration
event is the preferred upgrade).

### The keystone this plan depends on

This plan **requires** the shikigami repository plan titled **"Agent runs as durable keiro
workflows"** (`shikigami/docs/plans/7-agent-runs-as-durable-keiro-workflows.md`). That plan
re-platforms the behavior runner from "run to completion" onto a **keiro workflow** — a
durable, resumable unit of execution that can `suspend` (stop and persist its position) and
`resume` (continue from where it stopped) and exposes an **`awaitInput`** combinator (a
workflow step that suspends until an external input is delivered to it). This plan does not
re-derive that substrate; it consumes it. If plan 7 has not landed when you start, you must
implement (or stub against) its workflow surface first — see Interfaces & Dependencies for
the exact combinator contract this plan assumes.

This plan also relies on the kioku plan **"Awaiting session state for durable
park-and-resume"** *only if* you choose to mark the session as parked for auditing. The park
itself is the keiro workflow's job; the kioku `Awaiting` vertex is optional here.

### Build and run tooling (so you can actually run things)

shikigami builds with cabal and GHC 9.12.4 (see `cabal.project`). Work inside the Nix dev
shell (`nix develop`, or `direnv` auto-loads it). Postgres for development is started by
`process-compose up --no-server` (see `process-compose.yaml`), which runs `just
create-database` (Justfile target) to create and migrate the `shikigami` database. The
`PG_CONNECTION_STRING` env var points the worker at the database (see
`shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs`). Common commands: `cabal build all`,
`cabal test all`, and `cabal run shikigami -- <subcommand>` for the CLI (subcommands live
under `shikigami-cli/src/Shikigami/Cli/Commands/`, including `worker`, `enqueue-run`,
`consume-stream`, `run-behavior`). danwa builds the same way (GHC 9.12.4, `cabal build
all`, `process-compose up --no-server`, `just create-database`) at
`/Users/shinzui/Keikaku/bokuno/danwa`.


## Plan of Work

The work is five milestones. M0–M2 are independent of plan 7 and deliver the two-way danwa
binding and the trigger. M3 needs plan 7's workflow substrate and delivers the durable
loop. M4 is the end-to-end acceptance.

### Milestone M0 — Danwa binding spike (de-risk the external API)

**Scope.** Prove, in isolation, that shikigami can drive danwa's real HTTP API: start a
conversation, join an `Agent` participant, post a human message, and post an agent reply.
Nothing in the agent runtime changes yet.

**What exists at the end.** A throwaway CLI subcommand
`shikigami-cli/src/Shikigami/Cli/Commands/DanwaSpike.hs` (wired into
`shikigami-cli/src/Shikigami/Cli.hs`) named `danwa-spike` that takes a danwa base URL and a
human and agent `part_…` id, performs the four calls above using `Danwa.Client`, and prints
the resulting `msg_…` ids. Add `danwa-client` to `shikigami-cli`'s `build-depends`.

**Commands to run.** From `/Users/shinzui/Keikaku/bokuno/danwa`, in one terminal:
`process-compose up --no-server` then `cabal run danwa-server`. From
`/Users/shinzui/Keikaku/bokuno/shikigami`: `cabal run shikigami -- danwa-spike
--danwa-url http://localhost:PORT --human part_human1 --agent part_agent1`.

**Acceptance.** The command prints two `msg_…` ids (the human message and the agent reply),
and `psql -d danwa -c "select author, content from danwa.danwa_messages order by posted_at"`
shows both rows with the expected authors. This confirms the outbound half (posting) works
before you wire it into the sink and loop. Treat this milestone as **prototyping**: once
M1 lands, the spike may be deleted (note it in Progress).

### Milestone M1 — Make the `DanwaConversation` sink real

**Scope.** Replace the stub sink so an agent's behavior output is posted as a real message
into a danwa thread. This is the outbound half of the two-way binding.

**What exists at the end.** `runDanwaStub` is gone; in its place
`shikigami-core/src/Shikigami/Sink/Danwa.hs` exposes
`runDanwa :: DanwaConfig -> AgentIdentity -> Maybe DanwaTarget -> Sink -> Value -> IO (Either Text Text)`
that, for a `DanwaConversation` sink, resolves the target conversation from the
`Maybe DanwaTarget` supplied by `SinkContext` and posts the rendered output via
`Danwa.Client.postMessage` (or `replyToMessage` when a parent message id is present),
returning the new `msg_…` id on success.

**Edits.**

- `shikigami-core/src/Shikigami/Sink/Config.hs`: add
  `data DanwaConfig = DanwaConfig { danwaBaseUrl :: !Text, danwaAgentParticipant :: !Text }`
  (the agent's `part_…` id used as message `author`).
- `shikigami-core/src/Shikigami/Sink/Types.hs` (`SinkContext`): add `sinkCtxDanwa ::
  !DanwaConfig` and an optional `sinkCtxDanwaTarget :: !(Maybe DanwaTarget)` where
  `data DanwaTarget = DanwaTarget { dtConversationId :: !Text, dtParentMessageId :: !(Maybe Text) }`.
  For a plain (non-conversational) `DanwaConversation` sink with no target, fall back to
  starting a fresh conversation via `startConversation` keyed by the sink's `topic`.
- `shikigami-core/src/Shikigami/Sink.hs` (`runSink`): change the `DanwaConversation {}` arm
  from `Stubbed <$ runDanwaStub …` to call `runDanwa` and map `Right mid -> Delivered mid`,
  `Left e -> Failed e`.
- `shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs` and
  `shikigami-core/src/Shikigami/Worker.hs` (`WorkerEnv`): add a `workerDanwa :: DanwaConfig`
  field, populate it from a `--danwa-url`/agent-participant CLI flag, and pass it into every
  `SinkContext` built in `runOneAgent`.
- `shikigami-core`'s `.cabal`: add `danwa-client` to `build-depends`.

**Commands / acceptance.** `cabal build all`. Then run the worker against danwa and enqueue
a one-shot run for an agent whose sink is `DanwaConversation` with a target conversation;
observe a new row in `danwa.danwa_messages` authored by the agent participant. This proves
the sink delivers (not stubs): the worker log line for the sink reads `-> SDanwaConversation
-> Delivered msg_…` instead of `Stubbed`.

### Milestone M2 — Conversational trigger: addressed message → run or resume

**Scope.** Detect a danwa message *addressed to* a declared agent and turn it into a run
job. The same mechanism must *resume* an already-parked conversation workflow when the
message belongs to a thread that already has one (the keying is by `conversationId`).

**What exists at the end.** A new module
`shikigami-core/src/Shikigami/Trigger/Danwa.hs` with:

```haskell
-- A danwa message addressed to an agent, normalized for the runtime.
data AddressedMessage = AddressedMessage
  { amConversationId :: !Text,   -- conv_…
    amMessageId      :: !Text,   -- msg_…
    amAuthor         :: !Text,   -- part_…  (the human)
    amContent        :: !Text,
    amAgentParticipant :: !Text  -- part_…  (the addressed agent)
  } deriving stock (Eq, Show)

-- The trigger payload carried in RunJob.triggerPayload (JSON).
-- A worker decodes this to know which conversation/turn to run.
```

and a bridge entrypoint `runDanwaBridge :: DanwaBridgeConfig -> Pool -> [AgentDecl] -> IO
()` that, on each newly-observed addressed message, resolves the matching agent (by mapping
the addressed `part_…` to a declared agent — see config below) and calls
`Shikigami.Trigger.Enqueue.enqueueAddressedRun pool agentName (toJSON addressedMessage)`.
The `idempotencyKey` is `agentName <> ":" <> amMessageId` so a re-observed message never
double-fires.

**Default source — read-model polling bridge (no danwa change).** The bridge polls danwa's
read-model tables since a stored watermark: it selects from `danwa.danwa_messages` joined to
`danwa.danwa_embellishments` where `kind = 'mention'` and the embellishment payload's
`mentionedParticipantId` equals a configured agent participant id (and, separately,
considers conversations the agent was assigned to). Each new hit becomes an
`AddressedMessage`. The watermark (last `posted_at` / event position processed) is persisted
so restarts neither re-fire nor lose position.

**Preferred upgrade (danwa-side dependency).** If danwa publishes a first-class
`MessageAddressedToAgent` integration event (onto the `activity.v1` Kafka stream shikigami
already consumes via `Shikigami.Trigger.Consumer`, or onto a pgmq queue), the bridge becomes
a thin consumer of that event instead of a poller. This is noted as a danwa dependency; it
is **not** required for this plan to be demonstrable.

**Mapping addressed-participant → agent.** Add a small config that maps an agent's danwa
`part_…` id to its `AgentDecl.name`. Place it next to the existing per-sink configs (extend
`Shikigami.Sink.Config.DanwaConfig` or add a `DanwaBridgeConfig` carrying
`[(participantId, agentName)]` plus the danwa base URL / DB connection).

**Acceptance.** With the bridge running, post a message into a danwa thread that
`@`-mentions the agent participant. Observe a new row appear on the `shikigami_run_jobs`
pgmq queue (`select * from pgmq.q_shikigami_run_jobs`) whose payload contains the
`conversationId`, `messageId`, `author`, and `content`. Posting the *same* message id again
produces no second job (idempotency).

### Milestone M3 — The durable conversation workflow (depends on plan 7)

**Scope.** This is the core deliverable: a long-lived, durable workflow keyed to a danwa
`conversationId` that drives turn-by-turn dialogue and **parks** (suspends) between human
turns. It depends on plan 7's keiro workflow substrate and `awaitInput`.

**What exists at the end.** A new module `shikigami-core/src/Shikigami/Agent/Conversation.hs`
exporting:

```haskell
-- Run (start or resume) the conversation workflow for one danwa thread.
-- Keyed by conversationId so the same thread always maps to the same workflow.
runConversationTurn ::
  ConversationEnv ->            -- AppEnv (kioku store) + BehaviorEnv + DanwaConfig + workflow handle
  AgentDecl ->
  AddressedMessage ->           -- the human turn just observed
  IO (Either Text ConversationTurnResult)

data ConversationTurnResult = ConversationTurnResult
  { ctrSessionId   :: !SessionId,   -- the one kioku session for this thread
  , ctrUserTurnId  :: !Text,
  , ctrAsstTurnId  :: !Text,
  , ctrReplyMessageId :: !Text      -- the msg_… posted back to danwa
  }
```

**Behavior of one turn** (this is the loop body executed inside the keiro workflow):

1. **Resolve the session for the thread.** Look up the kioku session whose `subjectRef`
   equals the `conversationId` (via `Kioku.Session.getByScope (agentScope name)` filtered on
   `subjectRef`, where `agentScope` is `Shikigami.Memory.Scope.agentScope`). If none exists,
   `Kioku.Session.start` a new one with `focus = "conversation"`, `scope = agentScope name`,
   `subjectRef = Just conversationId`. The session is `Running` and stays `Running`.
2. **Record the human turn.** `Kioku.Session.recordTurn` with `role = "user"`, `content =
   amContent`, `turnIndex = <next index from getTurns>`, fresh `turnId`.
3. **Run the agentic turn.** Build the model context from the recalled prior turns
   (`Kioku.Session.getTurns`) plus this human message and run the behavior
   (`Shikigami.Behavior.Run.runBehavior` for the agent's `Skill`/`ShikumiProgram` arm, which
   may call tools). The output `Value` is rendered to reply text (reuse
   `Shikigami.Agent.Run.renderLearning`-style extraction of a `reply`/`summary` field).
4. **Record the assistant turn.** `recordTurn` with `role = "assistant"`, `content =
   replyText`, the next `turnIndex`, optional `toolSummary`/token counts.
5. **Post the reply to danwa.** The reply is a mid-run sink, so under the C3 decision (Option 3 —
   transactional outbox; see `docs/plans/7-agent-runs-as-durable-keiro-workflows.md`) it is
   **enqueued** into `kiroku.keiro_outbox` with a deterministic message id from the conversation
   workflow id and human message id, and plan 7's outbox publisher delivers it via
   `Shikigami.Sink.Danwa.runDanwa` to the `DanwaTarget
   { dtConversationId = amConversationId, dtParentMessageId = Just amMessageId }`, so the reply threads
   under the human message. The implementation as of 2026-06-27 records the assistant turn and then
   enqueues the outbox row in the immediately following durable workflow step; this is recoverable by
   workflow replay but is not yet a single database transaction with `Kioku.Session.recordTurn`. The
   remaining hardening item in Progress tracks making the assistant-turn write and outbox enqueue one
   transaction once kioku exposes a transaction hook or shikigami adds a lower-level wrapper. The M1
   `runDanwa` client is the publisher's HTTP backend rather than a synchronous call in the loop, so the
   workflow records an `outbox:…` handle and the real danwa `msg_…` arrives when the publisher runs.
6. **Park.** Call plan 7's `awaitInput` on the workflow's input channel — the workflow
   **suspends durably** here. It does not return to a fresh job; it is the same workflow
   instance resumed when the next `AddressedMessage` for this `conversationId` is delivered.
   The kioku session is **not** completed; it stays `Running`.

**How resume is delivered.** The M2 trigger, when it sees a message for a `conversationId`
that already has a parked workflow, **delivers the input** to that workflow's `awaitInput`
channel (resuming it) instead of starting a new one. Keying the workflow id by
`conversationId` (e.g. workflow id = `"danwa-conversation:" <> conversationId`) makes
"already has a workflow" a lookup. The worker's `handleRunJob` is extended: a run job whose
payload decodes as an `AddressedMessage` routes to `runConversationTurn` (start or resume)
rather than the one-shot `runAgentWithMemory`.

**Closing the conversation.** When a human posts a close/`resolve` (danwa
`resolveConversation`) or an explicit end marker, the workflow exits the await loop and calls
`Kioku.Session.complete`, moving the session to `Completed`. (Optional: if you adopt the
kioku `Awaiting` state, mark the session `Awaiting` at step 6 and back to `Running` on
resume for a precise audit trail.)

**Commands / acceptance.** `cabal build all`; `cabal test all`. Then the M4 end-to-end run.

### Milestone M4 — End-to-end acceptance (two human turns, park between)

**Scope.** Demonstrate the whole loop with two human messages and prove the park.

**What to do.** Bring up danwa (`cabal run danwa-server`) and shikigami's worker plus the
danwa bridge. Start a danwa conversation, assign/mention the agent, and post a first human
message. Wait for the reply. Then post a second human message in the same thread.

**What to observe** (all three simultaneously):

1. **Two danwa replies.** `select author, content, posted_at from danwa.danwa_messages where
   author = '<agent part_…>' order by posted_at` returns two agent rows.
2. **Four kioku turns, one session.** Find the session id (one row, `status = running`,
   `subject_ref = '<conv_…>'`) and run `select turn_index, role, left(content, 40) from
   kioku_turns where session_id = '<sid>' order by turn_index` — expect four rows:
   `user`, `assistant`, `user`, `assistant`.
3. **The park between turns.** The keiro workflow journal for workflow id
   `danwa-conversation:<conv_…>` shows a `suspend` after the first `assistant` turn/reply and
   a `resume` when the second message arrived — i.e. one workflow instance, not two jobs. The
   exact query/inspection command depends on plan 7's journal surface; cite it once plan 7
   lands. As a runtime-agnostic proxy, the worker logs show the same workflow id resuming
   rather than a second `runAgentWithMemory` bracket opening a second session.


## Concrete Steps

State the exact commands to run and where to run them (working directory). Update this
section as work proceeds; capture real transcripts in fenced blocks.

### Prerequisites (both repos)

```bash
# danwa: bring up Postgres + server (terminal A)
cd /Users/shinzui/Keikaku/bokuno/danwa
nix develop
process-compose up --no-server      # starts postgres on a unix socket, runs `just create-database`
cabal build all
cabal run danwa-server              # note the port it binds

# shikigami: bring up its Postgres + build (terminal B)
cd /Users/shinzui/Keikaku/bokuno/shikigami
nix develop
process-compose up --no-server      # starts postgres, runs `just create-database` (migrates)
cabal build all
```

### M0 — danwa spike

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
cabal run shikigami -- danwa-spike \
  --danwa-url http://localhost:PORT \
  --human part_human1 --agent part_agent1
# expected stdout (ids will differ):
#   started conversation conv_01h...
#   posted human message msg_01h...A
#   posted agent reply   msg_01h...B
psql -d danwa -c "select author, left(content,30) from danwa.danwa_messages order by posted_at;"
# expected: two rows, authors part_human1 then part_agent1
```

Implementation build transcript:

```text
$ nix develop --command cabal build shikigami-cli
Build profile: -w ghc-9.12.4 -O1
...
Building executable 'shikigami' for shikigami-cli-0.1.0.0...
[2 of 2] Linking .../x/shikigami/build/shikigami/shikigami [Library changed]
```

### M1 — real sink (verify Delivered)

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
cabal build all
# run the worker with danwa wired (flag names finalized during implementation):
export PG_CONNECTION_STRING="host=$PGHOST dbname=shikigami user=$(id -un)"
cabal run shikigami -- worker --agents ./fixtures/agents \
  --kawa-url http://localhost:8088 --kizashi-url http://localhost:8089 \
  --danwa-url http://localhost:PORT --danwa-agent part_agent1
# in another terminal enqueue a run whose agent has a DanwaConversation sink + target:
cabal run shikigami -- enqueue-run --agent <agentName> --payload '{"reply":"hello"}'
# expected worker log:
#   [shikigami.sink] agent=<agentName> sink=SDanwaConversation -> Delivered msg_01h...
```

Implementation validation transcript:

```text
$ nix develop --command cabal build all
Build profile: -w ghc-9.12.4 -O1
...
Building executable 'shikigami-migrate' for shikigami-migrations-0.1.0.0...

$ nix develop --command cabal test shikigami-core-test
shikigami
  Sink
    DanwaConversation
      targeted reply posts through danwa and returns Delivered msg id: OK
      untargeted sink starts a conversation before posting:            OK
...
All 20 tests passed
```

### M2 — trigger / bridge (verify a job appears, idempotently)

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
# run the danwa→shikigami bridge (poller) — flag names finalized during implementation:
cabal run shikigami -- danwa-bridge --agents ./fixtures/agents \
  --danwa-db "$DANWA_PG_CONNECTION_STRING" \
  --map part_agent1=<agentName>
# post a human message in danwa that mentions part_agent1 (via the spike or danwa UI/HTTP),
# then inspect the run queue:
psql -d shikigami -c "select message from pgmq.q_shikigami_run_jobs;"
# expected: one job whose payload has conversationId/messageId/author/content
# re-deliver the SAME message id -> still exactly one job (idempotency by agentName:messageId)
```

Implementation validation transcript:

```text
$ nix develop --command cabal test shikigami-core-test
shikigami
  Trigger
    DanwaBridge
      mention detection enqueues once for a repeated observation: OK
...
All 21 tests passed

$ nix develop --command cabal build all
Building executable 'shikigami' for shikigami-cli-0.1.0.0...
```

### M3/M4 — end-to-end

```bash
# With danwa-server, the shikigami worker (danwa-wired), and the danwa-bridge all running:
# 1) start a conversation + mention the agent + post HUMAN MESSAGE #1 (via spike or HTTP)
# 2) wait for the agent reply to appear in danwa
# 3) post HUMAN MESSAGE #2 in the same thread

# Observe two agent replies:
psql -d danwa -c "select left(content,40), posted_at from danwa.danwa_messages \
  where author='part_agent1' order by posted_at;"   # expect 2 rows

# Observe four turns in ONE kioku session:
psql -d shikigami -c "select id from kioku_sessions where subject_ref='<conv_…>';"   # one id
psql -d shikigami -c "select turn_index, role, left(content,40) from kioku_turns \
  where session_id='<sid>' order by turn_index;"     # expect user/assistant/user/assistant

# Observe the park-between-turns in the keiro workflow journal (command per plan 7).
```

Partial M3 validation transcript:

```text
$ nix develop --command cabal test shikigami-core-test
All 28 tests passed

$ nix develop --command cabal build all
Building executable 'shikigami' for shikigami-cli-0.1.0.0...
```


## Validation and Acceptance

Acceptance is observable behavior, not the presence of code. The plan is complete when, with
danwa-server, the shikigami worker, and the danwa bridge running, the following holds:

1. **Outbound reply (M1).** Enqueuing a run for an agent with a `DanwaConversation` sink
   produces a real message in `danwa.danwa_messages` authored by the agent participant, and
   the worker logs `Delivered msg_…` (not `Stubbed`). A unit test in `shikigami-core`'s test
   suite (`cabal test all`) exercises `Shikigami.Sink.Danwa.runDanwa` against a danwa test
   server (danwa exposes throwaway-database test support in `danwa-migrations:test-support`)
   and asserts a posted row.

2. **Trigger/idempotency (M2).** A danwa message that mentions a configured agent yields
   exactly one `shikigami_run_jobs` entry; re-observing the same `messageId` yields none.
   Covered by a test that runs the bridge's detection/enqueue path twice over the same
   message and asserts a single job (the `idempotencyKey = agentName:messageId`).

3. **The durable conversational loop (M3/M4) — the headline acceptance.** Post **two** human
   messages into one danwa thread that addresses the agent. Then assert all three at once:
   - **Two danwa replies** authored by the agent (`select … from danwa.danwa_messages`).
   - **Four kioku turns for one session** (`user/assistant/user/assistant` in `kioku_turns`
     for a single `session_id` whose `subject_ref` is the `conv_…`), proving the second turn
     saw the first because it is the same session.
   - **A park between the turns**: the workflow `danwa-conversation:<conv_…>` suspended after
     the first reply and resumed on the second message — one workflow instance, not two
     independent jobs. This is the difference between "conversation" and "two batch runs."

   This is best expressed as an integration test (gated behind the dev Postgres, like
   shikigami's other DB-backed tests) that drives two `AddressedMessage`s through
   `runConversationTurn` and asserts the four turns, two replies, and a single workflow id
   with a recorded suspend/resume.

A useful before/after: before this plan, two human messages to an agent produce **two
sessions** (each a `runAgentWithMemory` bracket that completes) and **zero** danwa replies
(the sink is stubbed). After, they produce **one** session with four turns and **two** real
replies, with a durable park in between.


## Idempotence and Recovery

The pieces are designed to be safe to repeat.

- **Trigger.** The bridge persists a watermark and uses `idempotencyKey =
  agentName <> ":" <> messageId`. Re-running the bridge, or re-observing a message, never
  produces a duplicate run job. This mirrors the existing stream consumer's keiro idempotent
  inbox (`Shikigami.Trigger.Consumer`) and `runJobFromEnvelope`'s `name:activityId` key.
- **Turn recording.** kioku turns carry a stable `turnId`; deriving `turnId` from the danwa
  `messageId` (for the user turn) and from the posted reply `messageId` (for the assistant
  turn) makes a re-driven turn a no-op append rather than a duplicate, and makes
  `turnIndex` recomputable from `getTurns`.
- **Reply posting.** danwa `PostMessage` mints a fresh `msg_…` per call, so naive retries
  could double-post. Guard by checking whether the assistant turn for this human `messageId`
  was already recorded in kioku before posting; if it was, skip the post (the reply already
  went out). Because the kioku turn is recorded *before* a retry would re-post, this gives
  at-most-one visible reply per human turn under retry.
- **Workflow.** The durable park is the keiro workflow's own journaled state (plan 7): a
  crash between turns resumes the workflow at the `awaitInput` point, not from scratch. The
  kioku session staying `Running` is the durable anchor that survives process restarts.
- **Sessions.** `Kioku.Session.start` is idempotent on an existing `sessionId` (it returns
  the id without re-emitting `SessionStarted` — see `kioku-core/src/Kioku/Session.hs` lines
  63–68), so resolving-or-starting the thread session is safe to repeat.

Rollback: M1–M2 are additive (a new sink path, a new trigger module, new config fields).
If the conversational workflow (M3) misbehaves, you can fall back to the one-shot path by
routing `AddressedMessage` jobs through `runAgentWithMemory` (a single turn, no park),
which still posts a reply via the M1 sink — losing only the multi-turn memory and the park.


## Interfaces and Dependencies

### New and changed shikigami modules (full paths and signatures)

- `shikigami-core/src/Shikigami/Sink/Config.hs` — add
  `data DanwaConfig = DanwaConfig { danwaBaseUrl :: !Text, danwaAgentParticipant :: !Text }`.
- `shikigami-core/src/Shikigami/Sink/Danwa.hs` — replace `runDanwaStub` with
  `runDanwa :: DanwaConfig -> AgentIdentity -> Maybe DanwaTarget -> Sink -> Value -> IO (Either Text Text)`
  and a helper `postReply :: DanwaConfig -> DanwaTarget -> Text -> IO (Either Text Text)`
  over `Danwa.Client.postMessage`/`replyToMessage`.
- `shikigami-core/src/Shikigami/Sink/Types.hs` — extend `SinkContext` with `sinkCtxDanwa ::
  !DanwaConfig` and `sinkCtxDanwaTarget :: !(Maybe DanwaTarget)`; add
  `data DanwaTarget = DanwaTarget { dtConversationId :: !Text, dtParentMessageId :: !(Maybe Text) }`.
- `shikigami-core/src/Shikigami/Sink.hs` — `runSink`'s `DanwaConversation {}` arm calls
  `runDanwa` and maps to `Delivered`/`Failed`.
- `shikigami-core/src/Shikigami/Trigger/Danwa.hs` (new) — `AddressedMessage`,
  `DanwaBridgeConfig`, `detectAddressed :: DanwaBridgeConfig -> Pool -> IO [AddressedMessage]`,
  `runDanwaBridgeOnce :: DanwaBridgeConfig -> Pool -> Pool -> [AgentDecl] -> IO [(AddressedMessage, Either UsageError MessageId)]`,
  and `runDanwaBridge :: DanwaBridgeConfig -> Pool -> Pool -> [AgentDecl] -> IO ()` (calls
  `Shikigami.Trigger.Enqueue.enqueueAddressedRunWithKey` after claiming
  `agentName:messageId` in `shikigami_danwa_bridge_seen`).
- `shikigami-core/src/Shikigami/Agent/Conversation.hs` (new) — `ConversationEnv`,
  `ConversationTurnResult`, and `runConversationTurn :: ConversationEnv -> AgentDecl ->
  AddressedMessage -> IO (Either Text ConversationTurnResult)` as specified in M3. This is the
  loop body executed inside the keiro workflow.
- `shikigami-core/src/Shikigami/Worker.hs` — extend `WorkerEnv` with `workerDanwa ::
  !DanwaConfig`; extend `handleRunJob` to route an `AddressedMessage`-shaped payload to the
  conversation workflow (start or resume) instead of `runOneAgent`.
- `shikigami-cli/src/Shikigami/Cli.hs` + new commands `DanwaSpike.hs`, `DanwaBridge.hs`, and
  `--danwa-url`/`--danwa-agent` flags on `Worker.hs`.

### kioku (dependency: storage, already present)

- `Kioku.Session` (`kioku-core/src/Kioku/Session.hs`): `start`, `recordTurn`, `getTurns`,
  `getById`, `getByScope`, `complete`. Used as-is.
- `Kioku.Session.Domain` (`kioku-core/src/Kioku/Session/Domain.hs`): `RecordTurnData`,
  `StartSessionData`, `CompleteSessionData`, `SessionVertex`. Used as-is.
- `Kioku.App` (`Kioku.App.AppEnv`, `runAppIO`) for running session effects, as in
  `Shikigami.Agent.Run`. `Shikigami.Memory.Scope.agentScope` for the session scope.
- **Optional dependency:** kioku plan "Awaiting session state for durable park-and-resume"
  — adds an `Awaiting` `SessionVertex` for auditing the park. Not required; the park lives in
  the keiro workflow.

### plan 7 (hard dependency: the workflow substrate)

This plan consumes the shikigami plan "Agent runs as durable keiro workflows"
(`shikigami/docs/plans/7-agent-runs-as-durable-keiro-workflows.md`). The contract it assumes:

- A durable workflow keyed by a stable id (here `"danwa-conversation:" <> conversationId`)
  that can `suspend` and `resume`, with per-step journaling that survives process restart.
- Plan 7's generic `awaitInput` combinator: a workflow step that **suspends** the workflow until an
  external input (the next `AddressedMessage`) is delivered to it, then **resumes** with that input.
  Plan 7 exposes it (see `docs/plans/7-agent-runs-as-durable-keiro-workflows.md`, Milestone 3) with the
  exact signature
  `awaitInput :: (Workflow :> es, Store :> es, IOE :> es, FromJSON a) => StepName -> Eff es a`
  — a `StepName` labels the suspension point within the run; the payload type `a` is the conversation's
  input (here the decoded `AddressedMessage`).
- Plan 7's `deliverInput`, used by the M2 trigger/bridge to resume a parked conversation, addressed by
  workflow id + step:
  `deliverInput :: (Store :> es, IOE :> es, ToJSON a) => WorkflowId -> StepName -> a -> Eff es Bool`
  (True = resumed an existing parked workflow; False = none parked, so the bridge starts a new one).
  This plan relies on plan 7 resolving audit item **C2** — exposing this *generic, `WorkflowId`-keyed*
  pair (not only the approval-shaped `awaitInput`) — so the danwa bridge can resume a conversation
  knowing only its `conversationId` (which is the run's `WorkflowId`), never an `AwakeableId`.

If plan 7 has not landed, implement these against keiro's workflow primitives first (the gap
analysis confirms keiro already provides workflow support, queues, timers, and event
streams), or temporarily stub `awaitInput`/`deliverInput` so M1–M2 can be validated while M3
waits.

### danwa (dependency: trigger source + reply sink)

- **Reply sink — available now.** `Danwa.Client` (`danwa-client/src/Danwa/Client.hs`):
  `postMessage :: Text -> PostMessageRequest -> ClientM MessageResponse`,
  `replyToMessage :: Text -> Text -> PostMessageRequest -> ClientM MessageResponse`,
  `startConversation`, `joinConversation`, `assignAgent`, `addEmbellishment`. Add
  `danwa-client` to `shikigami-core`/`shikigami-cli` `build-depends`. No danwa change needed
  for the outbound half.
- **Trigger source — default needs no danwa change.** The polling bridge reads danwa's
  read-model tables (`danwa.danwa_messages`, `danwa.danwa_embellishments` with `kind =
  'mention'`) to detect addressed messages. This keeps the plan self-contained.
- **Trigger source — preferred upgrade (danwa-side work, tracked as a dependency).** danwa
  emits a first-class addressed-message integration event (e.g. `MessageAddressedToAgent`)
  onto a stream shikigami can consume — either the `activity.v1` Kafka stream shikigami
  already consumes via `Shikigami.Trigger.Consumer` (`shikigami-core/src/Shikigami/Trigger/
  Consumer.hs`), or a dedicated pgmq queue. When that lands, the bridge swaps polling for a
  consumer. Domain events to project from live in
  `danwa-core/src/Danwa/Message/Generated/Domain.hs` (`MessagePosted`) and
  `danwa-core/src/Danwa/Embellishment/Generated/Domain.hs` (`EmbellishmentAdded`).

### Existing shikigami pieces reused

- `Shikigami.Api.RunJob` (`RunJob`, `TriggerKind`) — the run-job contract; addressed runs use
  `TriggeredByEvent`.
- `Shikigami.Trigger.Enqueue.enqueueAddressedRun :: Pool -> Text -> Value -> IO (Either
  UsageError MessageId)` — enqueue the addressed run.
- `Shikigami.Behavior.Run.runBehavior` — execute one agentic turn.
- `Shikigami.Sink.dispatch` / `SinkContext` — permission-gated sink dispatch (the danwa sink
  rides the same C11 permission seam as the other sinks).


## Revision Notes

- 2026-06-27 — **Cross-plan coherence pass (plans 7–11), C2 resolution.** Replaced the conceptual
  `awaitInput :: WorkflowChannel a -> Workflow a` / `deliverInput :: WorkflowId -> a -> IO Bool`
  placeholders with plan 7's exact, now-committed generic signatures
  (`awaitInput :: (… , FromJSON a) => StepName -> Eff es a` and
  `deliverInput :: (… , ToJSON a) => WorkflowId -> StepName -> a -> Eff es Bool`). The audit found this
  plan assumed a generic, `WorkflowId`-keyed input channel while plan 7 originally offered only an
  approval-shaped `awaitInput` resumed by `AwakeableId`; the user resolved C2 by having plan 7 expose the
  generic pair, which this plan now cites. No other change — the one-session-per-conversation model and
  the danwa bridge are unaffected.

- 2026-06-27 — **M3 implementation update.** Recorded the durable danwa conversation workflow
  implementation: generic workflow input extraction, `shikigami.danwa-conversation` workflow
  keying, outbox-backed replies, bridge delivery-before-enqueue behavior, and the focused
  test evidence proving two turns share one session and park between turns.
- 2026-06-27 (follow-up) — **C3 resolved as Option 3 (transactional outbox).** The per-turn danwa reply
  (a mid-run sink) is enqueued into `kiroku.keiro_outbox` and delivered by plan 7's outbox publisher via
  `runDanwa`, rather than posted synchronously in the loop. The current implementation enqueues the
  outbox row in the durable workflow step immediately after the assistant-turn record; a remaining M3
  hardening item tracks making those two writes a single database transaction. Reason: durable,
  decoupled reply delivery consistent with the canonical sink model chosen for kikan production.
