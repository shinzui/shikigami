---
id: 19
slug: sink-delivery-truth-and-downstream-idempotency
title: "Sink delivery truth and downstream idempotency"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tykwvek587vr2gwtcf81j"
master_plan: "docs/masterplans/3-correctness-and-delivery-semantics-stop-dropping-and-duplicating-work.md"
---

# Sink delivery truth and downstream idempotency

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

When a shikigami run finishes, its outputs are delivered to "sinks" — downstream services: kawa (activity ingest), kizashi (signals), danwa (conversations). Today the run's journal records every sink as `Delivered` at the moment a row is written to the transactional outbox, before any HTTP happens; if the async publisher later exhausts its ten attempts and dead-letters the message, nothing anywhere reconciles the lie. Meanwhile, retried publishes duplicate downstream effects: kizashi has no idempotency key so every retry that reaches it creates another signal, and the danwa "fresh conversation" path (start → join → post) orphans a conversation when the post fails and then creates a second conversation on retry. Finally, all of a run's sink messages share one outbox ordering key, so one failing sink blocks the others for up to ten attempts.

After this plan, the journal says `Enqueued` (the truth) at enqueue time; actual publish outcomes are recorded in a queryable `shikigami.sink_deliveries` table (including the downstream id — signal id, activity id, message id); retried publishes are guarded so a delivery that already succeeded is never re-sent; the danwa path remembers the conversation it started and reuses it on retry; and each sink of a run gets its own ordering key so failures are isolated. You can see it working in the new test module `Shikigami.SinkDeliverySpec`, whose stub downstream servers count requests across simulated retries.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: `Enqueued` constructor in `SinkOutcome`; all three enqueue sites journal `Enqueued`; `sinkResultDetail` and tests updated; `logSinkResult` implemented; publisher summary logged.
- [ ] Milestone 2: `sink_deliveries` migration; `publishSinkIntent` records outcomes and skips already-delivered messages.
- [ ] Milestone 2: tests — receipt row recorded with downstream id; second publish of a delivered message does not re-POST.
- [ ] Milestone 3: danwa fresh-conversation retry reuses the recorded conversation id.
- [ ] Milestone 3: test — post-failure retry does not start a second conversation.
- [ ] Milestone 4: per-sink outbox keys (`runId:ordinal`) on the dispatch-sinks path; conversation replies keep per-run key.
- [ ] Milestone 4: test — sink 0 failing does not block sink 1 within one publish pass.
- [ ] Register `Shikigami.SinkDeliverySpec` in `shikigami-core.cabal` and `shikigami-core/test/Main.hs`; `cabal build all` and `cabal test all` green under `nix develop`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Planning research (2026-07-08): neither kizashi nor danwa accepts any client-supplied id or idempotency key. kizashi's `CreateSignalReq` (kizashi repo, `kizashi-api/src/Kizashi/Api/Signal.hs:102-117`) has no dedupe field and its handler mints a fresh `SignalId` per call (`kizashi-core/src/Kizashi/Signal/Http.hs:205-222`); danwa's `StartConversationRequest`/`PostMessageRequest` (danwa repo, `danwa-api/src/Danwa/Conversation/Api.hs:139-148`, `danwa-api/src/Danwa/Message/Api.hs:42-47`) mint server-side TypeIDs, and danwa has no lookup-by-external-key (conversations are listable by status only). Downstream idempotency in this plan is therefore entirely client-side; upstream API additions are recorded as follow-ups in the Decision Log.


## Decision Log

Record every decision made while working on the plan.

- Decision: Rename the enqueue-time journal outcome to a new additive constructor `Enqueued !Text` rather than repurposing `Delivered`, and never re-journal the final outcome into the workflow (delivery truth lives in `shikigami.sink_deliveries` plus keiro's own `keiro.keiro_outbox.status`).
  Rationale: The workflow completes before the async publisher runs; writing publish outcomes back into a completed workflow's journal would fight keiro's model. Additive constructor keeps already-journaled `Delivered` values decodable (aeson's derived sum encoding), respecting the additive-only discipline of docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md.
  Date: 2026-07-08

- Decision: Record delivery receipts in a new shikigami-owned table written by the publish transport (`publishSinkIntent`), and use the same table as a send-guard (skip dispatch when a receipt with status `delivered` exists for the outbox message).
  Rationale: keiro's outbox has no publish-outcome callbacks (verified: keiro `src/Keiro/Outbox.hs` — observation is via returned summaries and row status only), and its `keiro.keiro_outbox.status` cannot carry the downstream id we need for reconciliation. The transport is the one place that knows the real outcome. The guard turns "keiro retries the whole transport call" into at-most-once dispatch per outbox message except for a crash in the narrow window between downstream success and receipt commit — an explicitly documented at-least-once floor that no client-side scheme can beat without server-side idempotency keys.
  Date: 2026-07-08

- Decision: Per-sink outbox ordering keys `runId <> ":" <> ordinal` on the `dispatch-sinks` fan-out; the conversation-reply path keeps `key = runId` (the kioku session id).
  Rationale: A run's sinks are independent destinations — under keiro's `PerKeyHeadOfLine` policy (verified default, keiro `src/Keiro/Outbox/Types.hs:221-230`) a shared key makes sink 0's failure block sink 1 for up to `maxAttempts = 10` publishes with `ConstantBackoff 2`. Danwa replies within one conversation, by contrast, genuinely require order, which the shared per-conversation key provides.
  Date: 2026-07-08

- Decision: Fix the danwa orphan-conversation bug client-side by recording the started conversation id as a sub-receipt keyed by the outbox message, and reusing it on retry — not by restructuring into multiple outbox messages.
  Rationale: danwa offers no deterministic ids and no external-key lookup (see Surprises & Discoveries), so the client must remember. Splitting start/join/post into separate outbox messages would need cross-message data flow (the conversation id) that keiro's outbox does not model.
  Date: 2026-07-08

- Decision: Follow-ups filed, out of scope here: add an idempotency key to kizashi's create-signal API (field on `CreateSignalReq`, dedupe lookup in `handleCreateH`, unique index) and an external-key/start-idempotency story to danwa. Until then the receipt guard reduces but cannot eliminate duplicates (crash-window floor).
  Rationale: Server-side changes belong to those services' own plans; this plan must not block on them.
  Date: 2026-07-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

A "sink" is a declared delivery target on an agent (`Sink` in `shikigami-api/src/Shikigami/Api/Agent.hs`): `KawaDigest` posts an activity envelope to kawa's ingest doorway, `KizashiSignal` posts a signal, `DanwaConversation` posts into a danwa conversation. Sinks are dispatched asynchronously through keiro's transactional outbox: the agent workflow (`shikigami-core/src/Shikigami/Agent/Workflow.hs`) journals a `dispatch-sinks` step whose body atomically appends the journal entry and inserts outbox rows in one Postgres transaction (`enqueueSinkIntents`, Workflow.hs:386-440); a publisher loop in the worker (`runOutboxPublisher`, `shikigami-core/src/Shikigami/Worker.hs:103-112`) repeatedly calls keiro's `publishClaimedOutbox` with the transport function `publishSinkIntent` (Workflow.hs:561-583), which decodes the outbox row back into a `SinkIntent` and performs the actual HTTP dispatch via `Shikigami.Sink.dispatch` (`shikigami-core/src/Shikigami/Sink.hs:39-47`). Dispatch returns a `SinkResult { kind, outcome }` with `SinkOutcome = Delivered !Text | Stubbed | DeniedOutcome !Text | Failed !Text` (`shikigami-core/src/Shikigami/Sink/Types.hs:42-48`) — `Delivered`'s payload is the downstream id (kizashi signal id, kawa activity id, danwa message id).

The verified problems:

Enqueue-time "Delivered". `buildSinkIntent` journals `SinkResult kind (Delivered ("outbox:" <> messageId))` (Workflow.hs:440) before any HTTP; the same pattern exists in `prepareSinkIntent` (Workflow.hs:492, used by the conversation-reply path via `enqueueSinkIntentStep`) and in `shikigami-core/src/Shikigami/Flow/SinkOutbox.hs:100` (the flow-DSL sink capability). keiro's publisher gives each message `maxAttempts = 10` with `ConstantBackoff 2` and `PerKeyHeadOfLine` ordering (`defaultPublishOptions`, keiro `src/Keiro/Outbox/Types.hs:221-230`, wired at Worker.hs:108); on exhaustion the row goes to terminal status `dead` in the `keiro.keiro_outbox` table (status column values `pending|publishing|sent|failed|dead`; dead rows are kept for inspection, keiro `src/Keiro/Outbox/Schema.hs`) — and nothing shikigami-side notices. `publishSinkIntent` itself discards the downstream id: it collapses `outcome result` to `PublishSucceeded`/`PublishFailed` (Workflow.hs:581-583). `logSinkResult` is a literal no-op (Workflow.hs:629-630), and the publisher loop discards the returned `OutboxPublishSummary` (`Right _summary -> pure ()`, Worker.hs:111) which carries `claimed/published/retried/dead` counts.

Shared ordering key. `sinkIntentEvent` sets `key = Just runId` (Workflow.hs:530) for every sink of a run; with `PerKeyHeadOfLine`, sink 0 failing blocks sink 1 until sink 0 succeeds or dies.

Downstream idempotency. kawa is safe: the doorway dedupes on `(source, source_event_id)` and shikigami sends a deterministic `source_event_id` (`mkSourceEventId` in Sink/Types.hs, `projectIngest` in `shikigami-core/src/Shikigami/Sink/KawaClient.hs:72-83`). kizashi is not: `CreateSignalReq` (mirrored at `shikigami-core/src/Shikigami/Sink/Wire.hs:56-67`) has no idempotency field, and the real kizashi handler mints a fresh signal id per POST — every retried publish that reaches kizashi creates a duplicate signal. danwa is doubly unsafe: a retried targeted reply double-posts (`postReply`, `shikigami-core/src/Shikigami/Sink/Danwa.hs:33-57`), and the untargeted path `postToFreshConversation` (Danwa.hs:59-92) runs start → join → post; a failure at post leaves an orphaned conversation, and the retry starts a fresh one.

Consumers of `Delivered` you must not break: `Shikigami.Agent.Conversation.sinkResultDetail` (`shikigami-core/src/Shikigami/Agent/Conversation.hs:446-448`) extracts the `Delivered` detail as the reply's message id (tests assert an `outbox:` prefix, `shikigami-core/test/Shikigami/AgentWorkflowSpec.hs:198-199`), and `Shikigami/Sink.hs:55-65` constructs real `Delivered` values from actual HTTP responses (those remain correct — they happen after HTTP).

Infrastructure facts: shikigami's migrations are embedded SQL files under `shikigami-migrations/sql-migrations/` applied by codd; `just new-migration <slug>` scaffolds a correctly-timestamped file, and `withShikigamiMigratedDatabase` (test support) applies them in tests, so a new table is immediately test-visible. The `shikigami` Postgres schema already exists (see `2026-06-24-12-00-00-shikigami-fired.sql`). `AgentRunDeps.appEnv` gives `publishSinkIntent` access to the kiroku store pool (`Kioku.App.AppEnv { store, … }`, pool via `Kiroku.Store.Connection.pool`).


## Plan of Work

Milestone 1 — tell the truth in the journal and the logs. Scope: `Sink/Types.hs`, `Agent/Workflow.hs`, `Flow/SinkOutbox.hs`, `Agent/Conversation.hs`, `Worker.hs`, existing tests. At the end, no code path claims `Delivered` before HTTP, and publisher dead-letters are visible in the worker log.

Add `Enqueued !Text` to `SinkOutcome` in `shikigami-core/src/Shikigami/Sink/Types.hs` (keep `Delivered` — it remains the post-HTTP truth; the derived aeson instances make the addition backward-compatible for already-journaled values). Switch the three enqueue sites to `Enqueued ("outbox:" <> messageId)`: Workflow.hs:440, Workflow.hs:492, Flow/SinkOutbox.hs:100. Update `sinkResultDetail` (Conversation.hs:446-448) to match `Enqueued detail` as well as `Delivered detail` (order: `Enqueued` first; `Delivered` kept for old journaled turns replaying). Update the AgentWorkflowSpec assertions that check the `outbox:` prefix — they read `replyMessageId`, which now flows from `Enqueued`. Implement `logSinkResult` (Workflow.hs:629-630) through plan 28's `Shikigami.Log`, naming agent, run idempotency key, sink kind, and outcome. In `runOutboxPublisher` (Worker.hs:103-112), stop discarding the summary: emit structured `published`/`retried`/`dead` fields when any is non-zero and a dead-letter event with the `haltedOn` id if present.

Milestone 2 — durable delivery receipts and the send-guard. Scope: new migration, new module `shikigami-core/src/Shikigami/Sink/Delivery.hs`, `Agent/Workflow.hs` (`publishSinkIntent`). At the end, every publish attempt's real outcome is queryable, and re-publishing an already-delivered message is a no-op.

Scaffold the migration (`just new-migration sink-deliveries`) with:

```sql
CREATE TABLE shikigami.sink_deliveries (
  receipt_key text PRIMARY KEY,      -- outbox message id, or "<message-id>#<substep>" for sub-receipts
  outbox_message_id text NOT NULL,
  run_id text NOT NULL,
  agent text NOT NULL,
  ordinal int NOT NULL,
  sink_kind text NOT NULL,
  status text NOT NULL,              -- 'delivered' | 'failed' | 'conversation-started'
  detail text,                       -- downstream id on success; error text on failure
  updated_at timestamptz NOT NULL
);
CREATE INDEX sink_deliveries_run_idx ON shikigami.sink_deliveries (run_id);
```

Create `Shikigami.Sink.Delivery` with hasql statements and pool-level helpers: `recordDelivery :: Pool -> DeliveryReceipt -> IO (Either UsageError ())` (upsert on `receipt_key`), `lookupDelivery :: Pool -> Text -> IO (Either UsageError (Maybe DeliveryReceipt))`, and a plain record `DeliveryReceipt` mirroring the columns. Rework `publishSinkIntent` (Workflow.hs:561-583): it already receives `AgentRunDeps`, so take the pool from `appEnv`. Before dispatching, `lookupDelivery` by the outbox message id; if a `delivered` receipt exists, log a `skip: already delivered` line and return `PublishSucceeded` without HTTP. After dispatch, record the receipt: `Delivered detail` → status `delivered` with the downstream id; `Failed err` → status `failed` with the error (and return `PublishFailed err` so keiro retries); `DeniedOutcome`/`Stubbed` → status `delivered` with a marker detail (they are terminal non-sends). A receipt-write failure after a successful send must not fail the publish (that would guarantee a duplicate on retry): log it loudly and return `PublishSucceeded` — this is the documented at-least-once floor.

Milestone 3 — danwa retry safety. Scope: `Sink/Types.hs` (`SinkContext`), `Sink.hs`, `Sink/Danwa.hs`, `Agent/Workflow.hs`. At the end, a retried untargeted danwa sink reuses the conversation it already started.

Thread a guard capability into dispatch without giving the sink modules a pool dependency: add to `SinkContext` (Sink/Types.hs) a field `deliveryGuard :: !(Maybe DeliveryGuard)` where

```haskell
data DeliveryGuard = DeliveryGuard
  { lookupReceipt :: !(Text -> IO (Maybe Text)),   -- substep key -> recorded detail
    recordReceipt :: !(Text -> Text -> IO ())      -- substep key -> detail
  }
```

(define `DeliveryGuard` in `Shikigami.Sink.Types`; `publishSinkIntent` constructs it from `Shikigami.Sink.Delivery` closed over the pool and the outbox message id, using sub-receipt keys `<message-id>#conv`). In `postToFreshConversation` (Danwa.hs:59-92): consult `lookupReceipt "conv"` first — on `Just cid`, skip start+join and post into `cid` (reusing the `postReply`-style call with no parent); otherwise run start and join, then `recordReceipt "conv" cid` before the post. A post failure now leaves a recorded conversation; the retry reuses it instead of orphaning it and starting another. Existing callers that construct `SinkContext` (test `Main.hs`, `publishSinkIntent`) set the new field (`Nothing` where no pool exists — behavior then matches today, which the stub-based unit tests in `test/Main.hs` rely on).

Milestone 4 — per-sink ordering keys. Scope: `Agent/Workflow.hs`. At the end, one run's sinks fail independently.

Give `sinkIntentEvent` (Workflow.hs:523-544) an explicit ordering-key parameter instead of hardcoding `key = Just runId`. The `dispatch-sinks` path (`buildSinkIntent`, Workflow.hs:420-440) passes `runId <> ":" <> Text.pack (show ordinal)`; `prepareSinkIntent` (the conversation-reply path, Workflow.hs:475-514) passes `runIdText` unchanged — danwa replies in one conversation keep head-of-line order. `Flow/SinkOutbox.hs` mirrors whichever of the two semantics it implements (it is a per-step reply-style enqueue; keep the per-run key there and note it). This changes only the `key` field of newly-written outbox rows — no journaled step values change.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikigami` inside `nix develop`.

```bash
just new-migration sink-deliveries
# edit the generated shikigami-migrations/sql-migrations/<ts>-sink-deliveries.sql per Plan of Work
nix develop -c cabal build all
```

Edit per Plan of Work in milestone order; `cabal build all` after each. Create `shikigami-core/test/Shikigami/SinkDeliverySpec.hs` exporting `tests :: TestTree`; add `Shikigami.SinkDeliverySpec` to `other-modules` of `test-suite shikigami-core-test` in `shikigami-core/shikigami-core.cabal`; register it in `shikigami-core/test/Main.hs`. The stub-server pattern to copy is `stubKizashiApp`/`stubDanwaApp` in `shikigami-core/test/Main.hs` (warp `testWithApplication` + an `IORef` request log).

```bash
nix develop -c cabal test shikigami-core-test --test-show-details=streaming
```

Expected transcript excerpt:

```text
SinkDelivery
  workflow journals Enqueued (not Delivered) at enqueue time:        OK
  publish records a delivered receipt with the downstream id:        OK
  re-publish of a delivered message does not re-POST kizashi:        OK
  danwa post-failure retry reuses the started conversation:          OK
  failing sink 0 does not block sink 1 in one publish pass:          OK
```

Then the full suite (AgentWorkflowSpec's outbox and conversation assertions are affected by Milestone 1):

```bash
nix develop -c cabal test all
```


## Validation and Acceptance

All tests live in `shikigami-core/test/Shikigami/SinkDeliverySpec.hs`, run against a real Postgres via `withShikigamiMigratedDatabase` (which now also creates `shikigami.sink_deliveries`), with warp stubs standing in for kizashi/danwa/kawa.

Journal truth (fails before): run `runAgentRunWorkflow` for an agent with one `KawaDigest` sink (copy `decl`/`job` from AgentWorkflowSpec). Load the journaled `dispatch-sinks` value (`loadStepIndex` as in AgentWorkflowSpec.hs:216) or decode the step's stored JSON, and assert the outcome is `Enqueued` with an `outbox:` detail — today it decodes as `Delivered`, so this assertion fails before the change.

Receipt recording (fails before): enqueue a sink intent (run the workflow), then drive one publish pass — call `Keiro.Outbox.publishClaimedOutbox (publishSinkIntent deps) defaultPublishOptions Nothing` under `runAppIO appEnv` with the kizashi stub URL in `deps`. Assert the stub received exactly one POST, the summary says `published = 1`, and `lookupDelivery` returns a `delivered` receipt whose detail is the stub's signal id (`"sig_stub"`).

Send-guard (fails before): after the pass above, manually reset the outbox row to `pending` (or simpler: call `publishSinkIntent deps row` directly a second time with the same `OutboxRow`). Assert it returns `PublishSucceeded` and the stub's request count is still 1 — before this plan the count reaches 2, which is exactly the kizashi duplicate-signal bug.

Danwa conversation reuse (fails before): a danwa stub whose post-message endpoint fails the first call with HTTP 500 and succeeds afterwards, while counting `POST /conversations` calls. First `publishSinkIntent` for an untargeted `DanwaConversation` intent → `PublishFailed`, start-count 1, and a `conversation-started` sub-receipt exists. Second call → `PublishSucceeded`, start-count still 1, and the message was posted into the first conversation id. Before the change, start-count reaches 2 (orphaned conversation).

Head-of-line isolation (fails before): a run with two sinks whose transport fails for ordinal 0 (stub returns 500 for the first sink's route) and succeeds for ordinal 1. One `publishClaimedOutbox` pass must yield `published = 1, retried = 1` — before Milestone 4 the shared key yields `published = 0` for the second sink in that pass (blocked behind the failed head).

Operationally: run the worker and force a sink target down; the worker log now shows `retried=N` lines and, after ten failures, a `dead=1` error line naming the message — and `SELECT status, detail FROM shikigami.sink_deliveries WHERE run_id = …` tells you exactly what each sink of a run actually did.


## Idempotence and Recovery

The migration is additive (new table) and applied idempotently by codd; re-running `just migrate` is safe. All receipt writes are upserts keyed by `receipt_key`, so replays converge. The send-guard makes re-running the publisher safe by construction; the residual duplicate window (crash after downstream success, before receipt commit) is documented and bounded to one duplicate per crash. Rolling back the code but keeping the table is harmless (the table just stops being written); rolling back the migration requires dropping the table only after the code rollback. Milestone 4's key change affects only new outbox rows; in-flight rows with the old per-run key drain under the old ordering — no backfill needed.


## Interfaces and Dependencies

Libraries and why: keiro (`Keiro.Outbox` — `publishClaimedOutbox`, `defaultPublishOptions` (`maxAttempts = 10`, `ConstantBackoff 2`, `orderingPolicy = PerKeyHeadOfLine`, verified in keiro `src/Keiro/Outbox/Types.hs:221-230`), `OutboxRow (..)`, `PublishOutcome (..)`, `OutboxPublishSummary (..)`, `lookupOutbox`/`listOutbox` for inspection; outbox state in table `keiro.keiro_outbox`, status ∈ `pending|publishing|sent|failed|dead`), hasql/hasql-pool (the receipts table statements), warp/wai (test stubs, already test dependencies), aeson (backward-compatible constructor addition).

Signatures that must exist at the end (full module paths):

```haskell
-- shikigami-core/src/Shikigami/Sink/Types.hs
data Shikigami.Sink.Types.SinkOutcome
  = Delivered !Text | Enqueued !Text | Stubbed | DeniedOutcome !Text | Failed !Text
data Shikigami.Sink.Types.DeliveryGuard = DeliveryGuard
  { lookupReceipt :: !(Text -> IO (Maybe Text)),
    recordReceipt :: !(Text -> Text -> IO ()) }
-- SinkContext gains: deliveryGuard :: !(Maybe DeliveryGuard)

-- shikigami-core/src/Shikigami/Sink/Delivery.hs (new)
data Shikigami.Sink.Delivery.DeliveryReceipt = DeliveryReceipt
  { receiptKey, outboxMessageId, runId, agent :: !Text, ordinal :: !Int,
    sinkKind, status :: !Text, detail :: !(Maybe Text), updatedAt :: !UTCTime }
Shikigami.Sink.Delivery.recordDelivery :: Pool -> DeliveryReceipt -> IO (Either UsageError ())
Shikigami.Sink.Delivery.lookupDelivery :: Pool -> Text -> IO (Either UsageError (Maybe DeliveryReceipt))

-- shikigami-core/src/Shikigami/Agent/Workflow.hs
-- publishSinkIntent keeps its signature (AgentRunDeps -> OutboxRow -> Eff es PublishOutcome)
-- but now consults/records receipts; sinkIntentEvent gains an ordering-key parameter.
```

Constraints from sibling plans (record in code comments where relevant): journaled step names never change and `SinkOutcome`'s encoding change is additive-only (docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md); docs/plans/27-consolidate-sink-intent-and-run-lifecycle-machinery.md (MasterPlan 5) plans to consolidate `enqueueSinkIntents`/`enqueueSinkIntentStep`/`Flow/SinkOutbox.hs` — this plan should land first, and that consolidation must preserve the `Enqueued` semantics, the receipt guard, and the per-sink keys introduced here (this is a declared cross-MasterPlan integration point in docs/masterplans/3).

Hard cross-MasterPlan predecessor: plan 28 Milestone 1 supplies `Shikigami.Log`, which
this plan imports for delivery and publisher events. Preferred predecessor: plan 16 first
makes every handler produce truthful success/failure outcomes. Plan 27 lands after this
plan and preserves these semantics.


## Revision Notes

- 2026-07-22: Made plan 28 Milestone 1 a hard prerequisite, kept plan 16 as a preferred
  predecessor, and changed `logSinkResult`/publisher summaries to use the structured
  logger. The sink sequence is now plan 16 plus plan 28 M1 → plan 19 → plan 27.
