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

- [x] (2026-08-21T15:10:14Z) Milestone 1 (startable half): additive `Enqueued` and
      `PermanentFailure` constructors in `SinkOutcome`; enqueue sites tell the truth;
      structured publisher summaries expose retries and dead letters; all 342 core tests pass.
- [x] (2026-08-22T20:50:43Z) Milestone 1 (formerly blocked half): consumed the released
      Keiro 0.14/Kioku 0.5 cohort; `PermanentFailure` now records a `dead` receipt and returns
      bounded Keiro `PublishRejected`, while worker summaries expose terminal `rejected` rows
      separately from exhausted `dead` rows.
- [x] (2026-08-21T15:10:14Z) Prerequisites: plans 36/37/38, plan 16, and plan 28 M1 complete. Plan 28 M1 landed
      2026-08-05 and plan 38's schema gate is released, so the repository-side prerequisites are
      met; only the Keiro gate above remains, and it constrains one half of one milestone.
- [x] (2026-08-21T15:41:33Z) Milestone 2: added the pg-migrate-managed
      `shikigami.sink_deliveries` ledger; enqueue records `pending` atomically with the
      journal/outbox; publication records attempting/delivered/failed/dead/unknown states,
      retains downstream ids, reconciles successful outbox commits, and skips only proven
      delivered messages.
- [x] (2026-08-21T15:41:33Z) Milestone 2 tests: a delivered receipt retains the downstream
      id, a second publish does not re-POST, and terminal reconciliation materializes an
      `unknown` receipt when delivery cannot be proved.
- [x] (2026-08-21T15:41:33Z) Milestone 3: the Danwa fresh-conversation path records and
      reuses its conversation-id sub-receipt across retries.
- [x] (2026-08-21T15:41:33Z) Milestone 3 test: a failed first message post followed by a
      retry starts one conversation and posts twice into that same conversation.
- [x] (2026-08-21T15:41:33Z) Milestone 4: dispatch fan-out uses per-sink ordering keys
      (`runId:ordinal`); prepared conversation replies and the Flow step path retain their
      shared per-run key.
- [x] (2026-08-21T15:41:33Z) Milestone 4 test: sink 0 retries while sink 1 publishes in the
      same Keiro pass (`retried = 1`, `published = 1`).
- [x] (2026-08-21T15:41:33Z) Registered `Shikigami.SinkDeliverySpec`; the full repository
      `cabal test all` run passed, the post-reconciliation focused run passed 348 core and
      74 worker tests, the migration manifest check passed, and `just keiro-gate` reported
      replay-neutral workflow storage with all conformance tests passing.
- [ ] (2026-08-22T20:50:43Z) Final release-integration validation in progress: Keiro DSL
      regeneration is provenance-only; focused tests, the 63-entry fresh migration plan,
      full repository tests, and the workflow gate remain to be recorded.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**The upstream gate cleared as a two-release cohort on 2026-08-22.** Keiro 0.14 implements
`mori://shinzui/keiro/plans/165-add-terminal-outbox-publication-rejection-outcomes` with
`PublishRejected PublishRejection`, terminal `rejected` rows, bounded audit fields, and a
separate publisher-summary count. Kioku 0.4.1 still capped Keiro below 0.14, so Shikigami could
not consume Keiro alone. The user released Kioku 0.5 with matching `^>=0.14.0.0` bounds, and
the exact six-package Keiro plus three-package Kioku cohort then solved without `allow-newer`
or source overrides. Upstream annotated tags and all nine Hackage package releases were
verified before the pins moved.

Keiro intentionally makes `PublishRejection` abstract. Shikigami therefore uses
`mkPublishRejection "sink.permanent-failure" (Just detail)` rather than constructing or
serializing the audit value itself. The stable code meets Keiro's lowercase 1–64 byte contract;
the smart constructor also keeps detail inside the 1–1024 UTF-8 byte contract. An invalid
detail fails visibly as retryable instead of fabricating or truncating audit data.

Kioku 0.5 has an operational wrinkle unrelated to the terminal-outcome API: it corrects the
embedded bytes of migration 0011. Fresh test databases apply the corrected migration normally,
but a long-lived database that applied 0011 from Kioku 0.4.0 or 0.4.1 needs the upstream
one-time ledger re-baseline before its first 0.5 `up` or `verify`. No real database or ledger was
modified while implementing this plan. The new Keiro 0031 and Kioku 0013 entries bring the
dependency-composed migration plan to 55 and Shikigami's complete plan to 63.

The Kioku release guide also requires consumers to retire foreign tag decoders where possible.
A repository scan found no Shikigami parser or literal for Kioku's historical
`agent_memory_*`, `agent_session_*`, or `interactive_session_recorded` tags, so no decoder
change is required here.

The Keiro 0.14 build exposed three previously latent incomplete matches around Shikigami's
custom atomic journal/outbox transaction. `prepareJournalAppend` can return
`JournalRefusedTerminal`; the enqueue paths now turn that into an error and do not write an
outbox message or receipt. This adds no workflow step, label, branch, or stored shape.

- Planning research (2026-07-08): neither kizashi nor danwa accepts any client-supplied id or idempotency key. kizashi's `CreateSignalReq` (kizashi repo, `kizashi-api/src/Kizashi/Api/Signal.hs:102-117`) has no dedupe field and its handler mints a fresh `SignalId` per call (`kizashi-core/src/Kizashi/Signal/Http.hs:205-222`); danwa's `StartConversationRequest`/`PostMessageRequest` (danwa repo, `danwa-api/src/Danwa/Conversation/Api.hs:139-148`, `danwa-api/src/Danwa/Message/Api.hs:42-47`) mint server-side TypeIDs, and danwa has no lookup-by-external-key (conversations are listable by status only). Downstream idempotency in this plan is therefore entirely client-side; upstream API additions are recorded as follow-ups in the Decision Log.

- `AgentRunDeps.appEnv` no longer owns the Hasql pool described by the original plan. The
  worker environment owns it, so implementation adds an explicit optional `deliveryPool`
  seam: production always supplies the worker pool, while focused workflow tests that never
  publish may use `Nothing`.

- The current pg-migrate authoring interface is
  `new --manifest … --name … --description …`, and the service wrapper requires
  `DATABASE_URL` even for this author-only command. The generated exact-byte manifest is the
  migration authority; no separate lock file exists in this repository.

- The sink intent's `runId` is the Kioku session id, not the RunJob idempotency key. The
  ordering acceptance test exposed that stale assumption and now checks the actual invariant:
  both keys share one session prefix and end in distinct ordinals.

- `just keiro-gate` compares generated workflow scaffolding with the worktree, so unstaged
  production workflow edits appear as scaffold drift. Staging the implementation before the
  gate isolated the generated artifacts; the gate then reported that stored-data replay is
  unchanged and no patch declaration is required.


## Decision Log

Record every decision made while working on the plan.

- Decision: Rename the enqueue-time journal outcome to a new additive constructor `Enqueued !Text` rather than repurposing `Delivered`, and never re-journal the final outcome into the workflow (delivery truth lives in `shikigami.sink_deliveries` plus keiro's own `keiro.keiro_outbox.status`).
  Rationale: The workflow completes before the async publisher runs; writing publish outcomes back into a completed workflow's journal would fight keiro's model. Additive constructor keeps already-journaled `Delivered` values decodable (aeson's derived sum encoding), respecting the additive-only discipline of docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md.
  Date: 2026-07-08

- Decision: Record delivery receipts in a new shikigami-owned table written by the publish transport (`publishSinkIntent`), and use the same table as a send-guard (skip dispatch when a receipt with status `delivered` exists for the outbox message).
  Rationale: keiro's outbox has no publish-outcome callbacks (verified: keiro `src/Keiro/Outbox.hs` — observation is via returned summaries and row status only), and its `keiro.keiro_outbox.status` cannot carry the downstream id we need for reconciliation. The transport is the one place that knows the real outcome. The guard turns "keiro retries the whole transport call" into at-most-once dispatch per outbox message except for a crash in the narrow window between downstream success and receipt commit — an explicitly documented at-least-once floor that no client-side scheme can beat without server-side idempotency keys.
  Date: 2026-07-08
- Decision: Receipt state distinguishes `pending`, `attempting`, `delivered`, `failed`,
  `dead`, and `unknown`; a reconciliation pass compares terminal keiro outbox rows with
  receipts and materializes `unknown` when downstream success cannot be proven.
  Rationale: treating every non-error return or missing receipt as delivered recreates
  the same truthfulness bug. `unknown` preserves the irreducible crash window without
  lying and gives operators a repair target.
  Date: 2026-07-22

- Decision: Preserve permanent versus transient transport failures. `Failed` remains the
  backward-compatible transient constructor; `PermanentFailure` is additive. Map transient
  failures to Keiro `PublishFailed` and permanent failures to a public terminal
  `PublishRejected` outcome owned by Keiro, which marks the row dead without another send.
  Rationale: Returning success for a rejected request would make the outbox lie, while
  directly updating Keiro tables would violate framework ownership. If the selected released
  Keiro cohort lacks `PublishRejected`, add it upstream with state/summary/ordering tests,
  release the coherent cohort, verify registry/tags, and then update Shikigami's bound.
  Date: 2026-07-22

- Decision: Per-sink outbox ordering keys `runId <> ":" <> ordinal` on the `dispatch-sinks` fan-out; the conversation-reply path keeps `key = runId` (the kioku session id).
  Rationale: A run's sinks are independent destinations — under keiro's `PerKeyHeadOfLine` policy (verified default, keiro `src/Keiro/Outbox/Types.hs:221-230`) a shared key makes sink 0's failure block sink 1 for up to `maxAttempts = 10` publishes with `ConstantBackoff 2`. Danwa replies within one conversation, by contrast, genuinely require order, which the shared per-conversation key provides.
  Date: 2026-07-08

- Decision: Fix the danwa orphan-conversation bug client-side by recording the started conversation id as a sub-receipt keyed by the outbox message, and reusing it on retry — not by restructuring into multiple outbox messages.
  Rationale: danwa offers no deterministic ids and no external-key lookup (see Surprises & Discoveries), so the client must remember. Splitting start/join/post into separate outbox messages would need cross-message data flow (the conversation id) that keiro's outbox does not model.
  Date: 2026-07-08

- Decision: Follow-ups filed, out of scope here: add an idempotency key to kizashi's create-signal API (field on `CreateSignalReq`, dedupe lookup in `handleCreateH`, unique index) and an external-key/start-idempotency story to danwa. Until then the receipt guard reduces but cannot eliminate duplicates (crash-window floor).
  Rationale: Server-side changes belong to those services' own plans; this plan must not block on them.
  Date: 2026-07-08

- Decision: Proceed with Milestones 2-4 while the user owns Keiro plan 165 in parallel. Until a
  released cohort exposes `PublishRejected`, retain `PermanentFailure` as an additive domain
  outcome but translate it to retryable `PublishFailed` at the Keiro boundary.
  Rationale: The receipt ledger, Danwa sub-receipt guard, and per-sink ordering keys have no
  dependency on Keiro's terminal outcome. This preserves truthful failure semantics without
  modifying the user's Keiro checkout or inventing a temporary framework behavior.
  Date: 2026-08-21

- Decision: Insert the initial `pending` receipt in the same transaction as the journal append
  and outbox insert, for every Shikigami enqueue path.
  Rationale: An asynchronous ledger created after enqueue could itself be missing after a crash,
  recreating the truth gap this plan removes. One transaction establishes the delivery intent
  before the publisher can claim it.
  Date: 2026-08-21

- Decision: Add `deliveryPool :: Maybe Pool` as a narrow publisher dependency; worker
  construction always supplies `Just envPool`, and only focused non-publisher tests use
  `Nothing`.
  Rationale: The current `AppEnv` does not expose the pool. Making the seam optional avoids
  coupling workflow-only fixtures to a live receipt store without weakening production tracking.
  Date: 2026-08-21

- Decision: Reconcile only rows whose callback returned `PublishSucceeded`, and only after
  `publishClaimedOutbox` successfully commits. Capture those batch outcomes at the worker
  boundary, then use the public Shikigami receipt API to materialize `unknown` when no terminal
  receipt exists.
  Rationale: This follows Keiro's transaction boundary without querying or mutating its schema,
  avoids unbounded scans, and does not label retryable failures as terminal uncertainty.
  Date: 2026-08-21

- Decision: Do not add a workflow patch for this implementation.
  Rationale: The workflow step names and stored step shapes remain replay-compatible; the
  additive `SinkOutcome` change already preserves old values, and `just keiro-gate` classified
  the final diff as replay-neutral.
  Date: 2026-08-21

- Decision: Upgrade the complete dependency boundary to Keiro 0.14 and Kioku 0.5 in lockstep,
  with exact project constraints and no `allow-newer` or source override.
  Rationale: Kioku 0.4.1 correctly capped Keiro at 0.13. Kioku 0.5 is the released consumer
  bound that makes Keiro 0.14 coherent, and both upstream migration guides require the two
  releases to be treated together.
  Date: 2026-08-22

- Decision: Encode every `PermanentFailure` as a Keiro rejection with stable code
  `sink.permanent-failure` and the transport error as validated detail; return
  `PublishRejected` only after the Shikigami `dead` receipt commits.
  Rationale: Keiro owns terminal outbox truth while Shikigami owns delivery-receipt truth. A
  terminal result on only one side would reintroduce the split-brain state this plan removes.
  Invalid audit detail or a failed receipt write remains retryable and visible instead of being
  silently truncated or terminally acknowledged.
  Date: 2026-08-22

- Decision: Handle `JournalRefusedTerminal` as an enqueue error without a workflow patch.
  Rationale: Refusal means the workflow has already reached a terminal marker, so writing a new
  sink outbox message would violate the journal boundary. Making an existing transaction
  outcome match total changes no declared step or stored value and is replay-neutral.
  Date: 2026-08-22


## Outcomes & Retrospective

As of 2026-08-22, all planned work is implemented. The journal stops at `Enqueued`;
the new receipt ledger becomes the queryable delivery truth and stores downstream ids; proven
delivery suppresses another send; Danwa retries reuse their recorded conversation; and fan-out
sinks no longer share a head-of-line key. Reconciliation explicitly records the irreducible
acknowledgement/receipt crash window as `unknown` after Keiro commits a successful publication.

The released Keiro 0.14/Kioku 0.5 cohort closes the former upstream gap. A
`PermanentFailure` now commits a `dead` Shikigami receipt and yields Keiro
`PublishRejected`, so the outbox records `rejected` after one callback instead of retrying a
known permanent result. Worker summaries keep that result distinct from rows that became
`dead` only after exhausting transient attempts. Plan 22 remains responsible for classifying
concrete HTTP statuses into `PermanentFailure`; this plan owns and now completes the durable
boundary that consumes that outcome.


## Context and Orientation

A "sink" is a declared delivery target on an agent (`Sink` in `shikigami-api/src/Shikigami/Api/Agent.hs`): `KawaDigest` posts an activity envelope to kawa's ingest doorway, `KizashiSignal` posts a signal, `DanwaConversation` posts into a danwa conversation. Sinks are dispatched asynchronously through keiro's transactional outbox: the agent workflow (`shikigami-core/src/Shikigami/Agent/Workflow.hs`) journals a `dispatch-sinks` step whose body atomically appends the journal entry and inserts outbox rows in one Postgres transaction (`enqueueSinkIntents`, Workflow.hs:386-440); a publisher loop in the worker (`runOutboxPublisher`, `shikigami-core/src/Shikigami/Worker.hs:103-112`) repeatedly calls keiro's `publishClaimedOutbox` with the transport function `publishSinkIntent` (Workflow.hs:561-583), which decodes the outbox row back into a `SinkIntent` and performs the actual HTTP dispatch via `Shikigami.Sink.dispatch` (`shikigami-core/src/Shikigami/Sink.hs:39-47`). Dispatch returns a `SinkResult { kind, outcome }` with `SinkOutcome = Delivered !Text | Stubbed | DeniedOutcome !Text | Failed !Text` (`shikigami-core/src/Shikigami/Sink/Types.hs:42-48`) — `Delivered`'s payload is the downstream id (kizashi signal id, kawa activity id, danwa message id).

The verified problems:

Enqueue-time "Delivered". `buildSinkIntent` journals `SinkResult kind (Delivered ("outbox:" <> messageId))` (Workflow.hs:440) before any HTTP; the same pattern exists in `prepareSinkIntent` (Workflow.hs:492, used by the conversation-reply path via `enqueueSinkIntentStep`) and in `shikigami-core/src/Shikigami/Flow/SinkOutbox.hs:100` (the flow-DSL sink capability). keiro's publisher gives each message `maxAttempts = 10` with `ConstantBackoff 2` and `PerKeyHeadOfLine` ordering (`defaultPublishOptions`, keiro `src/Keiro/Outbox/Types.hs:221-230`, wired at Worker.hs:108); on exhaustion the row goes to terminal status `dead` in the `keiro.keiro_outbox` table (status column values `pending|publishing|sent|failed|dead`; dead rows are kept for inspection, keiro `src/Keiro/Outbox/Schema.hs`) — and nothing shikigami-side notices. `publishSinkIntent` itself discards the downstream id: it collapses `outcome result` to `PublishSucceeded`/`PublishFailed` (Workflow.hs:581-583). `logSinkResult` is a literal no-op (Workflow.hs:629-630), and the publisher loop discards the returned `OutboxPublishSummary` (`Right _summary -> pure ()`, Worker.hs:111) which carries `claimed/published/retried/dead` counts.

Shared ordering key. `sinkIntentEvent` sets `key = Just runId` (Workflow.hs:530) for every sink of a run; with `PerKeyHeadOfLine`, sink 0 failing blocks sink 1 until sink 0 succeeds or dies.

Downstream idempotency. kawa is safe: the doorway dedupes on `(source, source_event_id)` and shikigami sends a deterministic `source_event_id` (`mkSourceEventId` in Sink/Types.hs, `projectIngest` in `shikigami-core/src/Shikigami/Sink/KawaClient.hs:72-83`). kizashi is not: `CreateSignalReq` (mirrored at `shikigami-core/src/Shikigami/Sink/Wire.hs:56-67`) has no idempotency field, and the real kizashi handler mints a fresh signal id per POST — every retried publish that reaches kizashi creates a duplicate signal. danwa is doubly unsafe: a retried targeted reply double-posts (`postReply`, `shikigami-core/src/Shikigami/Sink/Danwa.hs:33-57`), and the untargeted path `postToFreshConversation` (Danwa.hs:59-92) runs start → join → post; a failure at post leaves an orphaned conversation, and the retry starts a fresh one.

Consumers of `Delivered` you must not break: `Shikigami.Agent.Conversation.sinkResultDetail` (`shikigami-core/src/Shikigami/Agent/Conversation.hs:446-448`) extracts the `Delivered` detail as the reply's message id (tests assert an `outbox:` prefix, `shikigami-core/test/Shikigami/AgentWorkflowSpec.hs:198-199`), and `Shikigami/Sink.hs:55-65` constructs real `Delivered` values from actual HTTP responses (those remain correct — they happen after HTTP).

Infrastructure facts: one pg-migrate component, exact-byte manifest, complete application
plan, CLI, and public test support already exist (see plan 38). This plan adds its receipt
change only through that component. The worker's `AgentRunDeps.deliveryPool` gives
`publishSinkIntent` access to the same Hasql pool in production.


## Plan of Work

Milestone 1 — tell the truth in the journal and the logs. Scope: `Sink/Types.hs`, `Agent/Workflow.hs`, `Flow/SinkOutbox.hs`, `Agent/Conversation.hs`, `Worker.hs`, existing tests. At the end, no code path claims `Delivered` before HTTP, and publisher dead-letters are visible in the worker log.

Add `Enqueued !Text` and `PermanentFailure !Text` to `SinkOutcome` in
`Shikigami.Sink.Types` (keep `Delivered` and `Failed`; additive derived encodings preserve old
journals). Switch the three enqueue sites to `Enqueued`. Update all exhaustive matches and
tests. Obtain the coherent released Keiro cohort with
`PublishRejected PublishRejection`; construct the abstract rejection through
`mkPublishRejection`, and do not emulate it with raw SQL or `PublishSucceeded`. Implement
`logSinkResult` through plan 28's logger and emit publisher summary/dead-letter events.

Milestone 2 — durable delivery receipts, reconciliation, and the send-guard. Scope: a
plan-38 pg-migrate change, a delivery store module, and `publishSinkIntent`. At the end,
every publish attempt has an explicit state, and only a proven `delivered` receipt
suppresses a repeat send.

Create the pg-migrate change with `shikigami-migrate new --manifest … --name sink-deliveries
--description …`, add it to the
exact manifest/application plan, and define:

```sql
CREATE TABLE shikigami.sink_deliveries (
  receipt_key text PRIMARY KEY,      -- outbox message id, or "<message-id>#<substep>" for sub-receipts
  outbox_message_id text NOT NULL,
  run_id text NOT NULL,
  agent text NOT NULL,
  ordinal int NOT NULL,
  sink_kind text NOT NULL,
  status text NOT NULL CHECK
    (status IN ('pending','attempting','delivered','failed','dead','unknown','conversation-started')),
  detail text,                       -- downstream id on success; error text on failure
  updated_at timestamptz NOT NULL
);
CREATE INDEX shikigami.sink_deliveries_run_idx ON shikigami.sink_deliveries (run_id);
```

Create `Shikigami.Sink.Delivery` with schema-qualified hasql statements and pool-level
helpers, plus a plain `DeliveryReceipt` mirroring the columns. Rework `publishSinkIntent`:
write `attempting` before dispatch; a proven `delivered` receipt returns
`PublishSucceeded` without HTTP. Map `Delivered` to receipt `delivered` and
`PublishSucceeded`; transient `Failed` to receipt `failed` and `PublishFailed`; additive
`PermanentFailure` to receipt `dead` and Keiro `PublishRejected`; and
`DeniedOutcome`/`Stubbed` to a terminal non-send receipt plus `PublishSucceeded`. A
receipt-write failure after downstream success cannot safely trigger another send: record a
critical `unknown` reconciliation item/event and return success, preserving the documented
irreducible crash-window floor rather than guaranteeing a duplicate.

Milestone 3 — danwa retry safety. Scope: `Sink/Types.hs` (`SinkContext`), `Sink.hs`, `Sink/Danwa.hs`, `Agent/Workflow.hs`. At the end, a retried untargeted danwa sink reuses the conversation it already started.

Thread a guard capability into dispatch without giving the sink modules a pool dependency: add to `SinkContext` (Sink/Types.hs) a direct field `receipts :: !(Maybe DeliveryGuard)` where

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
cabal run shikigami-migrate -- new sink-deliveries
# edit the generated pg-migrate change, then update/verify the exact manifest and application plan
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
  terminal reconciliation materializes an unknown receipt:           OK
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

Permanent rejection: a stub 401/403/404 response maps through plan 22's typed HTTP error to
`PermanentFailure`, records receipt `dead`, and yields Keiro `PublishRejected`; the outbox row
becomes dead after one request. A 429/500/network failure maps to `Failed`/`PublishFailed` and
remains retryable. This test also runs in the upstream Keiro cohort for summary and ordering
semantics.

Send-guard (fails before): after the pass above, manually reset the outbox row to `pending` (or simpler: call `publishSinkIntent deps row` directly a second time with the same `OutboxRow`). Assert it returns `PublishSucceeded` and the stub's request count is still 1 — before this plan the count reaches 2, which is exactly the kizashi duplicate-signal bug.

Danwa conversation reuse (fails before): a danwa stub whose post-message endpoint fails the first call with HTTP 500 and succeeds afterwards, while counting `POST /conversations` calls. First `publishSinkIntent` for an untargeted `DanwaConversation` intent → `PublishFailed`, start-count 1, and a `conversation-started` sub-receipt exists. Second call → `PublishSucceeded`, start-count still 1, and the message was posted into the first conversation id. Before the change, start-count reaches 2 (orphaned conversation).

Head-of-line isolation (fails before): a run with two sinks whose transport fails for ordinal 0 (stub returns 500 for the first sink's route) and succeeds for ordinal 1. One `publishClaimedOutbox` pass must yield `published = 1, retried = 1` — before Milestone 4 the shared key yields `published = 0` for the second sink in that pass (blocked behind the failed head).

Operationally: run the worker and force a sink target down; the worker log now shows `retried=N` lines and, after ten failures, a `dead=1` error line naming the message — and `SELECT status, detail FROM shikigami.sink_deliveries WHERE run_id = …` tells you exactly what each sink of a run actually did.


## Idempotence and Recovery

The migration is additive and applied/verified through plan 38's pg-migrate CLI and
complete application plan. All receipt writes are upserts keyed by `receipt_key`, so
replays converge. The reconciliation pass is idempotent and never promotes `unknown` to
`delivered` without downstream evidence. The send-guard makes re-running the publisher
safe only for proven delivered receipts; unknown outcomes remain visible for operator
repair. Rolling back code while retaining the table is harmless.


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 16, 28 M1, 38, and 47. The former terminal-delivery block is
cleared: `mori://shinzui/keiro/plans/165-add-terminal-outbox-publication-rejection-outcomes`
shipped in Keiro 0.14, and Kioku 0.5 supplies the coherent consumer bound. Shikigami consumes
the public rejection API without raw table mutation, false success, or an unbounded retry.


## Interfaces and Dependencies

Hard dependencies: plans 36, 37, 38, and plan 28 Milestone 1; preferred predecessor:
plan 16. Schema work uses `pg-migrate`/`pg-migrate-test-support`.

Libraries and why: keiro (`Keiro.Outbox` — `publishClaimedOutbox`, `defaultPublishOptions` (`maxAttempts = 10`, `ConstantBackoff 2`, `orderingPolicy = PerKeyHeadOfLine`, verified in keiro `src/Keiro/Outbox/Types.hs:221-230`), `OutboxRow (..)`, `PublishOutcome (..)`, `PublishRejection`, `mkPublishRejection`, `OutboxPublishSummary (..)`, `lookupOutbox`/`listOutbox` for inspection; outbox state in table `keiro.keiro_outbox`, status ∈ `pending|publishing|sent|failed|dead|rejected`), hasql/hasql-pool (the receipts table statements), warp/wai (test stubs, already test dependencies), aeson (backward-compatible constructor addition).

Signatures that must exist at the end (full module paths):

```haskell
-- shikigami-core/src/Shikigami/Sink/Types.hs
data Shikigami.Sink.Types.SinkOutcome
  = Delivered !Text | Enqueued !Text | Stubbed | DeniedOutcome !Text
  | Failed !Text | PermanentFailure !Text
data Shikigami.Sink.Types.DeliveryGuard = DeliveryGuard
  { lookupReceipt :: !(Text -> IO (Maybe Text)),
    recordReceipt :: !(Text -> Text -> IO ()) }
-- SinkContext gains: receipts :: !(Maybe DeliveryGuard)

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
The selected coherent released cohort is Keiro 0.14 plus Kioku 0.5. It exposes terminal
`PublishRejected PublishRejection`; its Hackage releases and authoritative upstream tags were
verified after inspecting both projects through Mori.


## Revision Notes

- 2026-07-22: Made plan 28 Milestone 1 a hard prerequisite, kept plan 16 as a preferred
  predecessor, and changed `logSinkResult`/publisher summaries to use the structured
  logger. The sink sequence is now plan 16 plus plan 28 M1 → plan 19 → plan 27.
- 2026-07-22: Moved receipt schema evolution to plan 38's pg-migrate component and
  added explicit terminal/unknown receipt states plus a reconciliation acceptance path.
- 2026-07-22: Added an additive permanent-failure path backed by Keiro-owned
  `PublishRejected`, so stable 4xx failures dead-letter once without raw table mutation or
  repeated HTTP calls.
- 2026-08-10: Split Milestone 1 into a startable half and an upstream-blocked half, and recorded
  the evidence for the block so it is not re-derived.

  Milestone 1 bundled two independent things: shikigami's own additive `SinkOutcome` constructors
  and honest enqueue sites, which need nothing external, and consumption of a released Keiro
  `PublishRejected` terminal outcome, which does not exist. Bundling them made the whole milestone
  look blocked when only part of it is.

  The block was re-verified rather than inherited. `PublishOutcome` in
  `keiro/src/Keiro/Outbox.hs:266-271` is still `PublishSucceeded | PublishFailed` in the
  `keiro-0.11.0.0` tree; keiro's `Unreleased` section, which describes a substantial 0.12, does not
  mention `PublishRejected`; and keiro's implementing plan
  `mori://shinzui/keiro/plans/165-add-terminal-outbox-publication-rejection-outcomes` has none of
  its four milestones done. So neither the keiro 0.11 upgrade nor the pending 0.12 will deliver it.

  Surprises & Discoveries also records the workaround that must not be taken: inventing a local
  terminal-rejection notion inside `publishSinkIntent`. The upstream request exists precisely
  because the outbox rather than its caller has to know a publication is terminally rejected, so a
  local approximation would be deleted when the real outcome lands.

  The prerequisites line was updated to reflect that plan 28 M1 landed on 2026-08-05 and plan 38's
  schema gate is released, so every repository-side prerequisite is now met.

- 2026-08-21: Recorded completion of Milestone 1's Shikigami-owned half and the parallel ownership
  boundary for Keiro plan 165. The released 0.13 cohort still lacks `PublishRejected`, so the
  blocked half remains open while Milestones 2-4 proceed independently.

- 2026-08-21: Implemented Milestones 2-4, including atomic pending receipts, publisher state
  transitions and reconciliation, the proven-delivery guard, Danwa conversation sub-receipts,
  and per-sink ordering keys. Added ADR 0022 and six database-backed acceptance tests. Validation
  passed the exact migration manifest check, workflow replay/conformance gate, focused core and
  worker suites, and the full test suite. The plan remains open only for consumption of the
  released Keiro Plan 165 cohort.

- 2026-08-22: Consumed the released Keiro 0.14/Kioku 0.5 cohort and completed the formerly
  blocked half of Milestone 1. Permanent sink failures now use Keiro's bounded terminal
  rejection contract after the Shikigami dead receipt commits; worker summaries distinguish
  rejected rows from exhausted dead rows. Recorded Kioku's migration-0011 ledger remediation,
  the 63-entry complete fresh migration plan, and total handling of terminal journal refusal.
