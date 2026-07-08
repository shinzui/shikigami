---
id: 34
slug: memory-lifecycle-distillation-retention-and-shared-scope
title: "Memory lifecycle: distillation, retention, and shared scope"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tyzqcerzv4ysbktgr9sw9"
master_plan: "docs/masterplans/7-platform-feature-completion-egress-schema-memory-lifecycle-delegation.md"
---

# Memory lifecycle: distillation, retention, and shared scope

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami records memory but never *manages* it. Every write is hard-coded to priority 100,
MediumConfidence, type MemoryPattern, and supersedes Nothing
(shikigami-core/src/Shikigami/Agent/Run.hs:100-112, Agent/Workflow.hs:590-603,
Flow/Capability.hs:98-110). kioku ships a full lifecycle — supersede, archive, and a
multi-level distillation pipeline (L1 extract → L2 scene → L3 persona) driven by timers — and
shikigami invokes none of it. Worse, the L1 distillation timer is *scheduled* on every
conversation turn (the `l1TimerScheduleProjection` is applied at
shikigami-core/src/Shikigami/Agent/Conversation.hs:377) but **never fired**: the worker's
timer loop only handles schedule and approval timers
(shikigami-core/src/Shikigami/Trigger/Scheduler.hs:105-109), and kioku's
`runKiokuTimerWorkerLoop`/`fireL1Timer` (kioku-core/src/Kioku/Distill/Timer/Worker.hs) are
never imported. So conversation memory accumulates raw turns that are never distilled into
consolidated learnings. Separately, the non-vector recall fallback returns *all* active
memories in scope (Agent/Run.hs:214-219), which degrades linearly as memory grows, and the
`sharedScope` global scope (Shikigami/Memory/Scope.hs:17-22) is dead code.

After this plan: (1) the worker runs a fifth loop that fires kioku's distillation timers, so a
conversation's turns actually distill into consolidated memories on schedule; (2) the recall
fallback is bounded and recency-ordered, so recall cost does not grow without limit; (3) a
periodic maintenance task archives old MemoryPattern rows via kioku's `archive`, so the active
memory set stays bounded; and (4) `memory.scope = Shared` (the field defined by
docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md) becomes real —
an agent declaring it records into and recalls from the cross-agent global scope. The
observable proof is a real-Postgres test: seed a conversation, advance the clock past the L1
timer, run the distill loop once, and see a consolidated memory appear; seed N old memories,
run the maintenance task, and see them archived; declare two agents `Shared` and see one
recall what the other recorded.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: add the kioku distill-timer loop as the worker's fifth concurrent loop (env-gated), building a `DistillRuntime`; L1 timers scheduled on conversation turns now fire.
- [ ] M1: real-Postgres test — a conversation turn schedules an L1 timer; after advancing the clock and running the loop once, a consolidated memory exists.
- [ ] M2: bound the recall fallback — `recallActiveByScope` takes a limit and orders by recency (newest first).
- [ ] M3: a periodic maintenance task archives active MemoryPattern rows older than a threshold via kioku `archive`; run it inside the distill/maintenance loop.
- [ ] M3: real-Postgres test — seeded old memories are archived (status flips to archived) and no longer recalled; recent ones survive.
- [ ] M4: implement `memory.scope = Shared` — record and recall against `sharedScope` when the agent declares it; keep `AgentScope` as today.
- [ ] M4: real-Postgres test — agent B with `scope = Shared` recalls a memory agent A recorded under `Shared`.
- [ ] Docs: update docs/user/memory.md with distillation, retention, and shared scope.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- (Authoring-time) kioku's distiller is fully self-wired: `newDistillRuntime`
  (kioku-core/src/Kioku/Distill/Runtime.hs:60-74) calls `ClaudeApi.register` and pins
  `Models.anthropic_claude_haiku_4_5`, so this plan has **no code dependency** on
  docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md — only an operational one (an
  `ANTHROPIC_API_KEY` when the loop runs live). Because `DistillRuntime` is a record of plain
  `IO`-returning functions, tests substitute a fake runtime with no network (recorded in the
  Decision Log).
- (Authoring-time) kioku already exposes exactly the pieces needed: `runKiokuTimerWorkerLoop`
  and `runKiokuTimerWorkerOnce` (Distill/Timer/Worker.hs:87-98,67-75) fire L1/L2/L3 timers;
  `scopedScanCandidates :: Int -> FindMergeCandidates es` (Distill/L1.hs) provides a
  no-vector candidate finder; `Kioku.Memory.archive` + `ArchiveMemoryData {memoryId,
  archivedAt}` (Memory.hs:81-92) archive a row; `getActiveRowsByType`
  (Memory.hs:177) lists active rows by type; `Kioku.Recall.getGlobal`/`getActiveByScope`
  (Recall.hs:512-535) read a scope, `ScopeGlobal` included. kioku's own worker CLI
  (kioku-cli Worker.hs:95-99) is the reference wiring to copy.


## Decision Log

Record every decision made while working on the plan.

- Decision: Add the distill worker as a fifth concurrent loop in `runWorker`
  (shikigami-core/src/Shikigami/Worker.hs:70), gated on an environment variable
  (`SHIKIGAMI_DISTILL=1`) and building the `DistillRuntime` once at worker start.
  Rationale: `runWorker` already fans out four loops via nested `concurrently_`
  (Worker.hs:70); adding a fifth is the minimal structural change. Env-gating keeps CI and
  key-less local runs working (the runtime registers a Claude provider that needs a key to
  *fire*, though building it does not), and mirrors kioku's own worker which degrades to
  "timer worker only" when vector columns are absent (kioku-cli Worker.hs:80-81).
  Date: 2026-07-08

- Decision: Use kioku's `runKiokuTimerWorkerLoop Nothing rt (scopedScanCandidates 5)
  defaultPollMicros`, i.e. the full L1+L2+L3 fallback firer with the no-vector candidate
  finder, not the L1-only variant.
  Rationale: `fireKiokuTimer` tries L1, then L2, then L3 (Distill/Timer/Worker.hs:57-65), so
  one loop drives the whole pipeline; `scopedScanCandidates` avoids requiring pgvector, which
  matches shikigami's existing degrade-gracefully recall (Agent/Run.hs:195-197 detects vector
  capability and falls back). If a deployment has vectors, `recallCandidates` can be swapped
  behind the same `FindMergeCandidates` type later with no loop change.
  Date: 2026-07-08

- Decision: Tests use a fake `DistillRuntime` whose `runExtract`/`runConsolidate` return fixed
  decisions, not `newDistillRuntime`.
  Rationale: `DistillRuntime` is a plain record of functions
  (kioku-core/src/Kioku/Distill/Runtime.hs:39-46), so a hermetic fake needs no API key and no
  network; the test asserts that firing the timer *invokes* the pipeline and writes a
  consolidated memory, which does not require a real LLM. The live path is exercised manually
  (Concrete Steps) with a key.
  Date: 2026-07-08

- Decision: Retention policy — a periodic maintenance pass (run from the same fifth loop,
  once per configurable interval) archives active `MemoryPattern` rows whose `createdAt` is
  older than a threshold (default 30 days) *beyond* a per-scope keep-count (default: keep the
  newest 200 per scope). It uses `Kioku.Memory.archive` with a fresh `archivedAt`. It never
  archives non-`MemoryPattern` types (distilled scenes/personas are kept) and never touches
  already-archived rows (kioku's `archive` is a no-op on non-active rows, Memory.hs:90-92).
  Rationale: age-only archival would delete a small but active memory set on a quiet agent;
  count-only would churn a busy one; the age-AND-keep-count combination bounds growth without
  losing a minimal working set. `MemoryPattern` is the only type shikigami writes today
  (Run.hs:104), so scoping to it protects distillation outputs.
  Date: 2026-07-08

- Decision: Keep `sharedScope` and give it semantics driven by `memory.scope`. When an agent
  declares `memory.scope = Shared`, its run records into and recalls from `sharedScope`
  (`ScopeGlobal (Namespace "shikigami")`); `AgentScope` keeps today's `agentScope name`
  behavior. Recall for a `Shared` agent reads the global scope only (not a union of agent +
  global) to keep the semantics and the query simple and predictable.
  Rationale: this is the MasterPlan's IP-4 integration — plan 33 defines the field, this plan
  implements it — and it turns dead code into the README's promised cross-agent memory. A
  scope *union* was considered and deferred: it doubles every recall query and muddies "where
  did this memory come from"; a single-scope selection is the honest minimal semantics, and a
  union can be added later behind the same selector.
  Date: 2026-07-08

- Decision: A memory-scope *selector* function
  `resolveMemoryScope :: AgentDecl -> MemoryScope` centralizes the `AgentScope`/`Shared`
  choice, replacing the direct `agentScope name` calls at the record and recall sites.
  Rationale: `agentScope (name decl)` appears at Run.hs:58, Run.hs:78 (via recall), Run.hs:105
  (record), Workflow.hs:175, Workflow.hs:267, Workflow.hs:595, and Flow/Capability.hs:92,105 —
  a single selector keeps the scope choice consistent across all of them and is the one place
  a future union semantics would live.
  Date: 2026-07-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Shikigami (this repo) records agent memory through kioku (a sibling library at
/Users/shinzui/Keikaku/bokuno/kioku, discoverable via `mori registry show kioku --full`).
"Memory" here is a kioku `MemoryRecord` — a durable, scoped, typed note an agent recalls on
later runs. A "scope" (`Kioku.Api.Scope.MemoryScope`) is either `ScopeEntity ns kind ref`
(shikigami uses `ScopeEntity (Namespace "shikigami") (ScopeKind "agent") <agentName>` via
`Shikigami.Memory.Scope.agentScope`) or `ScopeGlobal ns` (shikigami's
`Shikigami.Memory.Scope.sharedScope`, currently unused). A "memory type" distinguishes raw
patterns (`MemoryPattern`) from distilled artifacts (scenes, personas).

How shikigami writes and reads today. Three write sites all hard-code the same fields:
`runAgentWithMemory` step 4 (shikigami-core/src/Shikigami/Agent/Run.hs:97-112), the durable
workflow's `recordLearning` (shikigami-core/src/Shikigami/Agent/Workflow.hs:585-605), and the
Flow `remember` capability (shikigami-core/src/Shikigami/Flow/Capability.hs:93-114) — each
passes `priority = 100, confidence = MediumConfidence, memoryType = MemoryPattern, supersedes
= Nothing`. Reads go through `recallPriorLearnings`
(shikigami-core/src/Shikigami/Agent/Run.hs:191-212): it detects whether the Postgres install
has the pgvector extension (`RecallCapability.detectVectorCapability`), runs a kioku
`Recall.recall` with `maxResults = 10`, and if that returns nothing falls back to
`recallActiveByScope` (Run.hs:214-219), which calls `Kioku.Recall.getActiveByScope` and
returns *every* active memory in the scope, unordered and unbounded.

"Distillation" is kioku's process of turning many raw memories/turns into fewer consolidated
ones. It is timer-driven: recording a conversation turn applies
`Kioku.Distill.Timer.l1TimerScheduleProjection`, which schedules an L1 timer row (shikigami
does this at Conversation.hs:377). A "timer" is a keiro durable alarm; a worker loop polls for
due timers and *fires* them via a fallback function. Shikigami's worker
(shikigami-core/src/Shikigami/Worker.hs:114-123) runs `runWorkflowTimerWorker` with
`Scheduler.shikigamiTimerFallback`, which handles only schedule and approval timers
(shikigami-core/src/Shikigami/Trigger/Scheduler.hs:105-109) — so L1 timers sit due-but-unfired
forever. kioku provides the firer shikigami is missing:
`Kioku.Distill.Timer.Worker.runKiokuTimerWorkerLoop :: Maybe KeiroMetrics -> DistillRuntime ->
FindMergeCandidates es -> Int -> Eff es ()` (Distill/Timer/Worker.hs:87-98), whose
`fireKiokuTimer` dispatches L1/L2/L3 timers (skipping any timer whose process-manager name it
does not recognize, so it coexists safely with shikigami's own timers). A `DistillRuntime` is
built by `Kioku.Distill.Runtime.newDistillRuntime :: IO DistillRuntime` (it self-registers the
Claude provider and picks a model). A `FindMergeCandidates` is a candidate-lookup strategy;
`Kioku.Distill.L1.scopedScanCandidates :: Int -> FindMergeCandidates es` is the no-vector one.

kioku's lifecycle write APIs this plan uses:
`Kioku.Memory.archive :: ArchiveMemoryData -> Eff es (Either MemoryWriteError MemoryId)` with
`ArchiveMemoryData {memoryId :: MemoryId, archivedAt :: UTCTime}` (a no-op on a non-active
row), and `Kioku.Memory.getActiveRowsByType :: Namespace -> MemoryType -> Eff es (Either
ReadModelError [MemoryRow])` to enumerate candidates (a `MemoryRow` carries `createdAt`,
`scopeKind`, `scopeRef`, `status`, `memoryType`; Memory/ReadModel.hs:45-62). `Kioku.Recall`
reads: `getActiveByScope`, and `getGlobal :: Namespace -> Eff es (Either ReadModelError
[MemoryRecord])` which is exactly `getActiveByScope (ScopeGlobal ns)` (Recall.hs:530-535).

The worker loop structure this plan extends: `runWorker`
(shikigami-core/src/Shikigami/Worker.hs:67-70) runs four loops under nested `concurrently_`
(queue worker, resume worker, outbox publisher, timer worker). kioku's own CLI worker
(kioku-cli Worker.hs:93-99) is the exact reference for building `rt <- newDistillRuntime` and
running `runKiokuTimerWorkerLoop Nothing rt (scopedScanCandidates 5) defaultPollMicros` under
`runAppIO`.


## Plan of Work

### Milestone 1 — Fire the distillation timers

Scope: the worker actually runs kioku's distill timer loop, so scheduled L1 timers fire. In
shikigami-core/src/Shikigami/Worker.hs add a `runDistillWorker :: WorkerEnv -> IO ()` modeled
on kioku-cli's `runTimerLoop`:

```haskell
runDistillWorker :: WorkerEnv -> IO ()
runDistillWorker env = do
  enabled <- lookupEnv "SHIKIGAMI_DISTILL"
  case enabled of
    Just ('1':_) -> do
      hPutStrLn stderr "[shikigami.worker] starting kioku distillation timer worker"
      rt <- newDistillRuntime
      result <- runAppIO (appEnv env)
        (runKiokuTimerWorkerLoop Nothing rt (scopedScanCandidates 5) defaultDistillPollMicros)
      either (\e -> hPutStrLn stderr ("[shikigami.worker] distill worker store error: " <> show e)) pure result
    _ -> hPutStrLn stderr "[shikigami.worker] distillation disabled (set SHIKIGAMI_DISTILL=1 to enable)"
```

Thread it into the fan-out at Worker.hs:70 (add a fifth `concurrently_` level, or lift the
list to `Async.mapConcurrently_ ($ env) [runQueueWorker, runResumeWorker, runOutboxPublisher,
runTimerWorker, runDistillWorker]` for readability). Import `newDistillRuntime`,
`runKiokuTimerWorkerLoop`, and `scopedScanCandidates` from kioku; add `System.Environment
(lookupEnv)`. Because `fireKiokuTimer` ignores timers whose process-manager name it does not
own, the new loop and shikigami's existing schedule/approval timer loop coexist without
double-firing (verify: the L1 process-manager name is `"kioku-l1-extract"`,
Distill/Timer.hs:36-37; shikigami's are `"shikigami.scheduler"` and the approval names).

Acceptance: a `withShikigamiMigratedDatabase` test in
shikigami-core/test/Shikigami/ (new `MemoryLifecycleSpec.hs`, added to the suite's
`other-modules`) records a conversation turn for an agent (reusing the Conversation path, or
directly seeding a session + turn + calling `l1TimerScheduleProjection` machinery), advances a
clock past the timer's `fireAt`, runs `runKiokuTimerWorkerOnce Nothing fakeRt
(scopedScanCandidates 5) now`, and asserts a consolidated `MemoryPattern` memory now exists in
the scope that did not before. Use a fake `DistillRuntime` returning a fixed extraction.

### Milestone 2 — Bound and order the recall fallback

Scope: the non-vector fallback no longer returns everything. Change `recallActiveByScope`
(shikigami-core/src/Shikigami/Agent/Run.hs:214-219) to take a limit and order by recency:

```haskell
recallActiveByScope :: AppEnv -> Int -> MemoryScope -> IO [MemoryRecord]
recallActiveByScope appEnv limit scope' = do
  priorE <- runAppIO appEnv (Recall.getActiveByScope scope')
  pure $ case priorE of
    Right (Right ms) -> take (max 0 limit) (sortOn (Down . createdAt) ms)
    _ -> []
```

`MemoryRecord` has `createdAt :: UTCTime` (kioku-api Kioku/Api/Types.hs:111), so
`sortOn (Down . createdAt)` gives newest-first; `take limit` bounds it. Pass the limit down
from `recallPriorLearnings` (which, after plan 33, already receives a limit — if plan 33 has
not landed, add the `Int` parameter here and thread the literal 10 at the call sites, matching
plan 33's signature so the two plans converge). Add `Data.Ord (Down)` and `Data.List (sortOn)`
imports.

Acceptance: a test seeds 25 active memories with increasing timestamps in a scope on a
no-vector database (the test DB has no pgvector, so the fallback path is taken), calls
`recallPriorLearnings` with limit 10, and asserts exactly the 10 newest are returned in
newest-first order.

### Milestone 3 — Retention: archive old memories

Scope: a periodic maintenance pass bounds the active set. Add a module
shikigami-core/src/Shikigami/Memory/Maintenance.hs:

```haskell
data RetentionPolicy = RetentionPolicy
  { maxAge :: !NominalDiffTime   -- default 30 days
  , keepPerScope :: !Int         -- default 200 (newest kept regardless of age)
  }

archiveOldMemories ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  RetentionPolicy -> UTCTime -> Eff es Int   -- returns count archived
```

which reads active `MemoryPattern` rows via `Kioku.Memory.getActiveRowsByType (Namespace
"shikigami") MemoryPattern`, groups them by `(scopeKind, scopeRef)`, and within each scope
sorts newest-first, keeps the first `keepPerScope`, and among the remainder archives those
whose `createdAt` is older than `now - maxAge` by calling `Kioku.Memory.archive
(ArchiveMemoryData memId now)`. Drive it from the distill loop: instead of the bare
`runKiokuTimerWorkerLoop`, run a small loop that alternates a timer-worker pass and, once per
`maintenanceInterval` (default hourly), an `archiveOldMemories` pass; keep it in
`runDistillWorker` so retention shares the distill loop's env gate and `AppEnv`.

Acceptance: a `withShikigamiMigratedDatabase` test seeds, in one scope, 5 memories older than
`maxAge` beyond the keep-count and 3 recent ones, runs `archiveOldMemories` with a small
`keepPerScope`, asserts the 5 old ones have `status = "archived"` (via
`getActiveRowsByType`/`getActiveByScope` no longer returning them) and the recent ones remain
active and recallable.

### Milestone 4 — Shared scope semantics

Scope: `memory.scope = Shared` (defined by plan 33) works end to end. Add the selector to
shikigami-core/src/Shikigami/Memory/Scope.hs:

```haskell
resolveMemoryScope :: AgentDecl -> MemoryScope
resolveMemoryScope decl = case scope (memory decl) of
  AgentScope -> agentScope (name decl)
  Shared     -> sharedScope
```

(importing the `MemoryScopeDecl` constructors and `MemoryPolicy` accessor from
`Shikigami.Api.Agent`). Replace the direct `agentScope (name decl)` / `agentScope
(agentDeclName decl)` calls at every record and recall site with `resolveMemoryScope decl`:
Run.hs:58 (session scope), Run.hs:78 (recall), Run.hs:105 (record), Workflow.hs:175 (recall),
Workflow.hs:267 (session start), Workflow.hs:595 (record), Flow/Capability.hs:92 (recall),
Flow/Capability.hs:105 (record). The session's own scope should follow the agent's declared
scope too, so a `Shared` agent's session and memories co-locate.

If plan 33 (which defines the `memory` field and `MemoryScopeDecl`) has not yet landed, this
milestone is blocked on it — it is the plan's one hard input (MasterPlan: EP-3 soft-depends on
EP-2, but *this milestone specifically* needs the field). Milestones 1-3 do not.

Acceptance: a `withShikigamiMigratedDatabase` test declares agent A and agent B both with
`memory.scope = Shared`, runs A (recording a memory), then runs B and asserts B's
`recalledPrior` includes A's memory (impossible under `AgentScope`, where each agent's scope
is keyed by its own name). A control agent with `AgentScope` does not see it.

### Docs

Update docs/user/memory.md: describe the L1/L2/L3 distillation loop and its env gate, the
bounded recency recall, the retention policy and its defaults, and the `Shared` scope
(cross-referencing writing-agents.md's `memory` field from plan 33).


## Concrete Steps

All commands from the repo root inside `nix develop`; database tests need
`just create-database` once. The live distill loop needs `ANTHROPIC_API_KEY` set; the tests
do not (fake runtime).

Step 1 — baseline build and tests:

```bash
cabal build all
cabal test shikigami-core
```

Step 2 — after M1, run the worker with distillation enabled and observe the loop start:

```bash
SHIKIGAMI_DISTILL=1 ANTHROPIC_API_KEY=... cabal run shikigami -- worker --agents agents/proof 2>&1 | head
```

Expected line:

```text
[shikigami.worker] starting kioku distillation timer worker
```

Without `SHIKIGAMI_DISTILL=1`:

```text
[shikigami.worker] distillation disabled (set SHIKIGAMI_DISTILL=1 to enable)
```

Step 3 — after each milestone, the targeted DB test:

```bash
cabal test shikigami-core --test-options='--pattern MemoryLifecycle'
```

Expected: the M1 distill, M2 recall-bound, M3 archival, and M4 shared-scope cases pass. (The
`--pattern` filter matches the tasty test group name; adjust to the group you named.)

Step 4 — full regression:

```bash
cabal test all
```


## Validation and Acceptance

Acceptance is behavioral and database-observable:

1. Distillation fires: before, an L1 timer scheduled by a conversation turn stays due forever
   (the worker's fallback ignores it, Scheduler.hs:105-109). After, running the distill loop
   once past the timer's `fireAt` produces a consolidated memory. Test asserts the memory
   count in scope increases; the fake `DistillRuntime` proves the pipeline was invoked without
   a live model.
2. Recall bounded: before, the fallback returns every active memory in scope
   (Run.hs:214-219). After, with 25 seeded memories and limit 10, recall returns exactly the
   10 newest, newest-first.
3. Retention: before, nothing is ever archived — `Kioku.Memory.archive` is never called by
   shikigami (grep the tree). After, `archiveOldMemories` flips old MemoryPattern rows to
   `archived`; they stop appearing in `getActiveByScope`/recall while recent rows survive.
4. Shared scope: before, `sharedScope` is dead code and cross-agent recall is impossible.
   After, two `Shared` agents share a memory pool: B recalls what A recorded; an `AgentScope`
   control does not.

Exact commands: `cabal test shikigami-core` for M1/M2 unit-ish DB tests and `cabal test all`
for the whole suite; all four cases run under
`Shikigami.Migrations.TestSupport.withShikigamiMigratedDatabase` against real Postgres, which
the dev shell provides (`just create-database`). CI needs no API key because every test uses
the fake `DistillRuntime`.


## Idempotence and Recovery

Firing timers is idempotent by construction: kioku's timer worker marks a timer fired with a
deterministic marker event id (Distill/Timer/Worker.hs:113-114), so re-running the loop does
not re-fire a completed timer. `archive` is a no-op on an already-archived row
(Memory.hs:90-92), so re-running the maintenance pass never double-archives or errors.
`resolveMemoryScope` is a pure function; changing an agent's declared scope changes *future*
records/recalls only — memories already written under the old scope stay where they are (a
migration of existing memories is explicitly out of scope). The `SHIKIGAMI_DISTILL` gate means
the new loop is opt-in: a deployment without the flag (or without an API key) behaves exactly
as today. Rollback: unset the flag to disable distillation and maintenance; revert M2/M4 edits
to restore unbounded fallback and agent-only scope — no data migration is needed either way.


## Interfaces and Dependencies

Owned and defined by this plan:

- `Shikigami.Worker` — `runDistillWorker :: WorkerEnv -> IO ()` as the fifth concurrent loop;
  env-gated on `SHIKIGAMI_DISTILL`.
- `Shikigami.Agent.Run` — `recallActiveByScope :: AppEnv -> Int -> MemoryScope -> IO
  [MemoryRecord]` (bounded, recency-ordered); the limit threaded from `recallPriorLearnings`.
- `Shikigami.Memory.Maintenance` (new) — `RetentionPolicy {maxAge, keepPerScope}`,
  `archiveOldMemories :: RetentionPolicy -> UTCTime -> Eff es Int`.
- `Shikigami.Memory.Scope` — `resolveMemoryScope :: AgentDecl -> MemoryScope`; the direct
  `agentScope` call sites (Run.hs, Workflow.hs, Flow/Capability.hs) rewired through it.

Consumed from kioku (library, no changes — locate via `mori registry show kioku --full`):

- `Kioku.Distill.Runtime.newDistillRuntime :: IO DistillRuntime` (self-registers Claude +
  model); `DistillRuntime` is a record of `IO`-returning functions, so tests fake it.
- `Kioku.Distill.Timer.Worker.runKiokuTimerWorkerLoop :: Maybe KeiroMetrics -> DistillRuntime
  -> FindMergeCandidates es -> Int -> Eff es ()` and `...WorkerOnce` (single pass for tests).
- `Kioku.Distill.L1.scopedScanCandidates :: Int -> FindMergeCandidates es` (no-vector finder).
- `Kioku.Memory.archive :: ArchiveMemoryData -> Eff es (Either MemoryWriteError MemoryId)`
  with `ArchiveMemoryData {memoryId :: MemoryId, archivedAt :: UTCTime}`;
  `Kioku.Memory.getActiveRowsByType :: Namespace -> MemoryType -> Eff es (Either
  ReadModelError [MemoryRow])`.
- `Kioku.Recall.getActiveByScope` / `getGlobal`; `MemoryRecord {createdAt :: UTCTime, ...}`;
  `MemoryRow {createdAt, scopeKind, scopeRef, status, memoryType, ...}`.

Cross-plan dependencies:

- Hard input for M4 only: the `memory` field / `MemoryScopeDecl` from
  docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md (MasterPlan
  IP-4). M1-M3 are independent of it.
- No code dependency on docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md — only
  the operational `ANTHROPIC_API_KEY` for the *live* distill loop (Surprises).

Build/test toolchain: Nix dev shell; `cabal build all`; `cabal test all`;
`just create-database` + `withShikigamiMigratedDatabase` for the real-Postgres tests. The new
test module `Shikigami.MemoryLifecycleSpec` must be added to the
`shikigami-core-test` suite's `other-modules` in shikigami-core/shikigami-core.cabal:118-126.
