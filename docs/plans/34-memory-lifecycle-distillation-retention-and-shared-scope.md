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

- [ ] Prerequisites: plans 36 and 37 have established the six-package service boundary and a single validated Settei configuration value; plan 33 has established bounded memory policy types.
- [ ] M1: add the kioku distill-timer loop as the worker's fifth supervised concurrent loop, configured through Settei and building a `DistillRuntime`; L1 timers scheduled on conversation turns now fire.
- [ ] M1: real-Postgres test — a conversation turn schedules an L1 timer; after advancing the clock and running the loop once, a consolidated memory exists.
- [ ] M2: bound the recall fallback at the database boundary — a server-side read model accepts `RecallLimit`, orders newest-first, and returns no more than the requested rows.
- [ ] M3: a periodic maintenance task archives active MemoryPattern rows older than a threshold via kioku `archive`; scan candidates in bounded, deterministic keyset batches inside the distill/maintenance loop.
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
  docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md. Its live credential is
  nevertheless resolved through plan 37's Settei-owned secret/reference boundary rather than
  read ad hoc in this module. Because `DistillRuntime` is a record of plain
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
- (Review-time) kioku's existing list-shaped read models are not sufficient for an operational
  bound: fetching all rows and applying `take` or grouping in Haskell still permits database,
  transfer, and heap cost to grow without limit. M2 and M3 therefore add or consume SQL read
  models whose `ORDER BY`, `LIMIT`, and keyset cursor are enforced by Postgres.


## Decision Log

Record every decision made while working on the plan.

- Decision: Add the distill worker as a fifth supervised concurrent loop in `runWorker`
  (shikigami-core/src/Shikigami/Worker.hs:70), enabled by the validated Settei configuration
  value from plan 37 and building the `DistillRuntime` once at worker start.
  Rationale: `runWorker` already fans out four loops via nested `concurrently_`
  (Worker.hs:70); adding a fifth is the minimal structural change. A typed disabled setting
  keeps CI and key-less local runs working, while an enabled setting is validated before any
  loop starts. An unexpected loop exit fails the worker process so its process supervisor can
  restart the complete service; it must not silently leave a partially healthy worker alive.
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

- Decision: Enforce recall and retention bounds in Postgres. Recall uses a newest-first query
  with a validated `RecallLimit`; retention uses a stable `(created_at, memory_id)` keyset
  cursor and a validated batch size, archiving one bounded batch at a time. Do not call an
  unbounded list API and then `take`, sort, or group the result in Haskell.
  Rationale: an application-side bound limits only the returned list after the database and
  process have already paid the unbounded cost. SQL ordering, limits, and keyset pagination
  make the memory and query-cost claim true under a large active-memory set.
  Date: 2026-07-22

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
on kioku-cli's `runTimerLoop`, but consume plan 37's already-decoded configuration rather
than reading the environment in the loop:

```haskell
runDistillWorker :: WorkerEnv -> IO ()
runDistillWorker env =
  case distillation (config env) of
    Disabled -> pure ()
    Enabled settings ->
      bracket (newDistillRuntime settings) closeDistillRuntime $ \runtime ->
        runDistillationAndMaintenance env settings runtime
```

Thread it into the fan-out at Worker.hs:70 (add a fifth `concurrently_` level, or lift the
list to `Async.mapConcurrently_ ($ env) [runQueueWorker, runResumeWorker, runOutboxPublisher,
runTimerWorker, runDistillWorker]` for readability). Import `newDistillRuntime`,
`runKiokuTimerWorkerLoop`, and `scopedScanCandidates` from kioku. The exact constructor and
cleanup function must follow the released kioku API found through Mori; the sketch above
expresses lifecycle ownership, not an API to guess. `WorkerConfig` contains strict,
unprefixed fields such as `distillation`, `pollInterval`, and `maintenanceInterval`, with
bounded duration/count newtypes validated by Settei. Do not add `lookupEnv` or accept a raw
API key in this module. If the enabled loop returns unexpectedly, propagate the failure out
of `runWorker`; the process supervisor owns restarts. Because `fireKiokuTimer` ignores timers
whose process-manager name it does not own, the new loop and shikigami's existing
schedule/approval timer loop coexist without
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

Scope: the non-vector fallback no longer fetches everything. Change `recallActiveByScope`
(shikigami-core/src/Shikigami/Agent/Run.hs:214-219) to take plan 33's validated
`RecallLimit`, and add or use a kioku read-model operation whose SQL orders and limits the
result before it crosses the database boundary:

```haskell
recallActiveByScope :: AppEnv -> RecallLimit -> MemoryScope -> IO [MemoryRecord]
```

The backing query is schema-qualified, filters the exact active scope, and uses `ORDER BY
created_at DESC, memory_id DESC LIMIT $n`. If the current released kioku API lacks this
bounded read model, add it to kioku first (with its own tests and release), verify the
released version and bounds, then consume it here; do not emulate it with
`Recall.getActiveByScope`, `sortOn`, and `take`. Pass the already-bounded value down from
`recallPriorLearnings` so invalid or enormous counts are not representable internally.

Acceptance: a test seeds 25 active memories with increasing timestamps in a scope on a
no-vector database (the test DB has no pgvector, so the fallback path is taken), calls
`recallPriorLearnings` with limit 10, and asserts exactly the 10 newest are returned in
newest-first order.

### Milestone 3 — Retention: archive old memories

Scope: a periodic maintenance pass bounds the active set. Add a module
shikigami-core/src/Shikigami/Memory/Maintenance.hs:

```haskell
data RetentionPolicy = RetentionPolicy
  { maxAge :: !RetentionAge
  , keepPerScope :: !KeepCount
  , batchSize :: !MaintenanceBatchSize
  }

archiveOldMemories ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  RetentionPolicy -> UTCTime -> Eff es Int   -- returns count archived
```

The read model selects at most `batchSize` eligible active `MemoryPattern` rows using stable
keyset pagination and a schema-qualified SQL query. It applies the per-scope newest
`keepPerScope` rule in SQL (for example with `row_number()` partitioned by scope), filters by
the age cutoff, and orders by `(created_at, memory_id)` so every pass has a deterministic
cursor. `archiveOldMemories` archives the returned identifiers with
`Kioku.Memory.archive (ArchiveMemoryData {memoryId, archivedAt = now})`, then continues from
the last cursor until a short batch is returned. It never loads or groups the entire active
set in Haskell. If kioku does not expose this read model, contribute and release the bounded
operation there before consuming it from shikigami. Drive it from the distill loop: instead
of the bare
`runKiokuTimerWorkerLoop`, run a small loop that alternates a timer-worker pass and, once per
`maintenanceInterval` (default hourly), an `archiveOldMemories` pass; keep it in
`runDistillWorker` so retention shares the distillation setting and `AppEnv`.

Acceptance: a `withShikigamiMigratedDatabase` test seeds more than two maintenance batches
across several scopes, including timestamp ties, runs `archiveOldMemories` with a small
`keepPerScope`, and asserts every eligible old row is archived exactly once while recent and
per-scope protected rows remain active. Query-level tests prove no page exceeds `batchSize`
and cursors neither skip nor repeat tied rows.

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

Do not start implementation until plan 33 has landed: it defines the `memory` field,
`MemoryScopeDecl`, and validated recall policy consumed throughout this plan. Plans 36 and 37
must also have landed so worker ownership and configuration do not introduce a parallel
architecture.

Acceptance: a `withShikigamiMigratedDatabase` test declares agent A and agent B both with
`memory.scope = Shared`, runs A (recording a memory), then runs B and asserts B's
`recalledPrior` includes A's memory (impossible under `AgentScope`, where each agent's scope
is keyed by its own name). A control agent with `AgentScope` does not see it.

### Docs

Update docs/user/memory.md: describe the L1/L2/L3 distillation loop and its typed Settei
setting, the server-side bounded recency recall, the retention policy and its defaults, and the `Shared` scope
(cross-referencing writing-agents.md's `memory` field from plan 33).


## Concrete Steps

All commands from the repo root inside `nix develop`; database tests need
`just create-database` once. The live distill loop needs the plan 37 Settei source for its
credential reference; the tests do not (fake runtime). Never place a raw credential on a
command line or in expected output.

Step 1 — baseline build and tests:

```bash
cabal build all
cabal test shikigami-core
```

Step 2 — after M1, supply a non-secret test configuration with distillation enabled and
observe the loop start. Use plan 37's documented configuration entry point; the schematic
command is:

```bash
cabal run shikigami-worker -- --config config/worker-memory-lifecycle-proof.yaml
```

Expected line:

```text
[shikigami.worker] starting kioku distillation timer worker
```

With distillation disabled in the same Settei configuration:

```text
[shikigami.worker] distillation disabled
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
   (Run.hs:214-219). After, seed far more rows than the limit and prove from the read-model
   query result that Postgres returns exactly the 10 newest, newest-first. A regression test
   must fail if the implementation fetches an unbounded list and truncates it in Haskell.
3. Retention: before, nothing is ever archived — `Kioku.Memory.archive` is never called by
   shikigami. After, `archiveOldMemories` processes a data set larger than two batches,
   flips every eligible old MemoryPattern row to `archived`, and leaves recent/protected rows
   active. Batch-size and tied-cursor assertions prove bounded, complete traversal.
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
migration of existing memories is explicitly out of scope). The typed distillation setting
means the new loop is opt-in: a deployment with `Disabled` behaves exactly as today, while an
invalid enabled configuration fails before workers start. Rollback: set it to `Disabled` to
stop distillation and maintenance; revert M2/M4 edits
to restore unbounded fallback and agent-only scope — no data migration is needed either way.


## Interfaces and Dependencies

Owned and defined by this plan:

- `Shikigami.Worker` — `runDistillWorker :: WorkerEnv -> IO ()` as the fifth supervised
  concurrent loop; configured by plan 37's typed Settei value.
- `Shikigami.Agent.Run` — `recallActiveByScope :: AppEnv -> RecallLimit -> MemoryScope -> IO
  [MemoryRecord]` (bounded, recency-ordered); the limit threaded from `recallPriorLearnings`.
- `Shikigami.Memory.Maintenance` (new) — strict direct fields on
  `RetentionPolicy {maxAge, keepPerScope, batchSize}`,
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
  plus a released bounded retention-candidate read model with SQL ordering, limit, and keyset
  cursor. The existing unbounded `getActiveRowsByType` is not acceptable for the worker.
- A released bounded recall-by-scope read model; the existing unbounded
  `Kioku.Recall.getActiveByScope` / `getGlobal` is context only and must not back M2.
  `MemoryRecord {createdAt :: UTCTime, ...}`;
  `MemoryRow {createdAt, scopeKind, scopeRef, status, memoryType, ...}`.

Cross-plan dependencies:

- HARD depends on the `memory` field / `MemoryScopeDecl` and bounded `RecallLimit` from
  docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md (MasterPlan
  IP-4).
- HARD depends on docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md
  for worker/application ownership and record conventions.
- HARD depends on docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md for
  the single decoded worker configuration and credential-reference boundary.
- No code dependency on docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md; live
  distillation still needs the provider credential resolved through plan 37 (Surprises).

Build/test toolchain: Nix dev shell; `cabal build all`; `cabal test all`;
`just create-database` + `withShikigamiMigratedDatabase` for the real-Postgres tests. The new
test module `Shikigami.MemoryLifecycleSpec` must be added to the
`shikigami-core-test` suite's `other-modules` in shikigami-core/shikigami-core.cabal:118-126.


## Revision Notes

- 2026-07-22: Reworked configuration, supervision, recall, and retention to follow the
  Settei/service patterns and operational API guidance. Bounds now apply in SQL rather than
  after unbounded reads, and maintenance uses deterministic keyset batches.
