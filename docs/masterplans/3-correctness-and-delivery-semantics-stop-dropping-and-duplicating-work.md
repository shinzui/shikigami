---
id: 3
slug: correctness-and-delivery-semantics-stop-dropping-and-duplicating-work
title: "Correctness and Delivery Semantics: Stop Dropping and Duplicating Work"
kind: master-plan
created_at: 2026-07-08T20:13:36Z
intention: "intention_01kx1tykwvek587vr2gwtcf81j"
---

# Correctness and Delivery Semantics: Stop Dropping and Duplicating Work

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Shikigami is a declared-agent runtime: agents are declared in Dhall manifests, triggers (cron schedules via keiro durable timers, the `activity.v1` Kafka stream via the keiro idempotent inbox, and addressed integration events) all converge on one pgmq queue named `shikigami_run_jobs`, a shibuya `QueueProcessor` drains that queue into keiro durable workflows with journaled steps, and sink deliveries go out asynchronously through a keiro transactional outbox. Each of those hand-offs currently has a correctness hole that either drops work (an event that never becomes a run, a run whose failure is silently archived, a sink that is never actually delivered) or duplicates it (a redelivered long run executing concurrently with itself, a scheduler replaying a day of missed cron ticks, a retried sink double-posting to a downstream service).

After this initiative, every hand-off is honest. A behavior failure caused by a flaky LLM or HTTP call is genuinely re-executed on retry instead of being replayed from the journal three times and archived. A run that takes longer than 30 seconds — that is, any real LLM call — is no longer redelivered mid-flight into a concurrent duplicate execution. A Kafka event whose processing hits a transient Postgres outage is retried instead of being permanently skipped by an unconditional offset commit; and once the inbox accepts an event, the corresponding run job is enqueued in the same database transaction, so a crash cannot strand an event in the "processed but never enqueued" state. A run record that says a sink was "Delivered" actually means the downstream HTTP call succeeded, not merely that a row was inserted into the outbox; retried sink publishes no longer duplicate kizashi signals or orphan danwa conversations. Routing of run jobs is decided by the job's declared trigger kind, the scheduler applies an explicit catch-up policy after downtime instead of firing every missed minute, and failures that today vanish (kioku session/memory write errors, unloadable agent manifests, unparseable crons) are loud.

In scope: completing the pg-migrate transition so every new correctness table is part of
one complete component plan; retry/timeout/heartbeat semantics of the run-job worker;
atomicity of the Kafka consumer path; truthfulness of sink outcomes and client-side
idempotency toward kawa, kizashi, and danwa; and explicit routing, scheduler catch-up,
and loud failure reporting.

Foundation status (2026-07-31). Plans 36, 37, and 47 are Complete, so this initiative's
cross-MasterPlan prerequisites are satisfied and its file map has moved. The six-package
split landed: the run-job handler is `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs`,
the Kafka consumers are `shikigami-workers/src/Shikigami/Trigger/Consumer.hs`, the outbox
publisher loop is `shikigami-workers/src/Shikigami/Flow/SinkOutbox/Publisher.hs`, and
enqueue remains `shikigami-core/src/Shikigami/Trigger/Enqueue.hs`. Nothing lives under
`shikigami-cli` any more. Every process except `shikigami-migrate` resolves settings through
Settei's `AppConfig`. The July 2026 cohort is in place, and it removed codd from the
repository entirely; the 2026-08-05 decision to cancel the codd-ledger import shrank F1
again, down to one configuration change (see the Decomposition Strategy and the F1 notes in
Surprises & Discoveries). Any child plan text still naming
`shikigami-cli/...` or `shikigami-core/src/Shikigami/Worker.hs` is stale and must be read
against this map.

Explicitly excluded: structured logging/metrics infrastructure (docs/plans/28), health/liveness and loop supervision (docs/plans/29), the operator CLI for inspecting runs and dead letters (docs/plans/30), per-agent lifecycle state recorded against meibo principals (docs/plans/23, MasterPlan 4 — this initiative only stops the silence around manifest load failures), consolidation of the duplicated sink-intent machinery (docs/plans/27, MasterPlan 5 — this initiative fixes the semantics of that machinery in place), and upstream API changes to kizashi or danwa to add server-side idempotency keys (documented as follow-ups inside EP-3; this initiative delivers client-side mitigations only).


## Decomposition Strategy

The initiative has one database-evolution foundation and four independent hand-off
boundaries. F1 completes the move to the fleet pg-migrate component/manifest/application-
plan model before any child adds tables. Plan 47 already delivered the component, the
exact-byte manifest, the composed four-component application plan, the `pg-migrate-cli`
executable, and the pg-migrate test support, and removed codd from the repository. The
codd-ledger import was cancelled on 2026-08-05 — shikigami has no users and no database whose
history needs preserving — so F1's remaining work is only the package restructure that lets
`shikigami-migrate` resolve through the shared `AppConfig`. **The schema-authoring gate is
released:** the manifest, the composed plan, and the public test support all exist and are
proven, so a child may add a migration today.
The queue-to-workflow boundary (EP-1) is about
what "retry" means once a job is in a handler, including the adapter's zero-based
attempt and Shibuya's framework-owned acknowledgement. The stream-to-queue boundary
(EP-2) is about transactional atomicity between Kafka offsets, the keiro inbox table,
and pgmq. The workflow-to-downstream boundary (EP-3) is about truthful receipts and
retry behavior. The trigger surface (EP-4) owns explicit routing, scheduler catch-up,
and loud failures; configuration itself belongs to plan 37.

Alternatives considered. A single "fix all correctness bugs" ExecPlan was rejected: it would span more than ten files across four unrelated subsystems and exceed five milestones, and the four streams need no shared code to proceed. Splitting EP-4 into three micro-plans (routing, scheduler, loudness) was rejected because each is one to two milestones and they share the same review context (the trigger surface) and the same test modules. Merging EP-1 and EP-4 because both edit `Shikigami/Worker.hs` was rejected: the ack-classification concern (EP-1) and the routing concern (EP-4) touch adjacent but different functions, and the seam between them is narrow enough to manage as an integration point rather than a merge. Sequencing EP-3 behind the MasterPlan-5 consolidation (docs/plans/27) was rejected: the consolidation is refactoring and should preserve semantics, so the semantics should be fixed first (see Integration Points).

Each plan is independently verifiable: EP-1 by tests that fail a behavior transiently and observe re-execution instead of journal replay; EP-2 by tests that assert an inbox row and a pgmq message appear or vanish together; EP-3 by stub HTTP servers counting downstream requests across retried publishes; EP-4 by scheduler tests firing stale timers and loader tests over the checked-in `agents/broken.dhall`.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| F1 | Migrate Shikigami database evolution from Codd to pg-migrate | docs/plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md | cross-MP: plans 36 ✅, 37 ✅, 47 ✅ | None | Mostly Complete (M1, M2, M3 cancelled, M4 part; remaining: `shikigami-migrate` Settei unification. No longer gates schema authoring) |
| 1 | Behavior retry semantics, run timeouts, and visibility heartbeat | docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md | cross-MP: plans 36 ✅, 37 ✅, 47 ✅ | None | Not Started (startable) |
| 2 | Atomic stream consumption: offsets, inbox, and enqueue in one boundary | docs/plans/18-atomic-stream-consumption-offsets-inbox-and-enqueue-in-one-boundary.md | cross-MP: plans 36 ✅, 37 ✅, 47 ✅ | None | Not Started (startable) |
| 3 | Sink delivery truth and downstream idempotency | docs/plans/19-sink-delivery-truth-and-downstream-idempotency.md | cross-MP: plans 16 ✅, 47 ✅, 28 M1 ✅; upstream Keiro IR-3 ⏳ | None | Not Started (**M2–M4 startable** — F1's schema gate released and plan 28 M1 landed 2026-08-05. M1 still wants a released Keiro `PublishRejected`, which does not exist: `PublishOutcome` is `PublishSucceeded \| PublishFailed` at `keiro/src/Keiro/Outbox.hs:264-269`, verified 2026-08-05) |
| 4 | Explicit trigger routing, scheduler catch-up policy, and loud failures | docs/plans/20-explicit-trigger-routing-scheduler-catch-up-policy-and-loud-failures.md | EP-1, EP-2; cross-MP: plans 37 ✅, 47 ✅ | None | Not Started (blocked on EP-1, EP-2) |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).
✅ marks a dependency verified Complete as of 2026-07-31; ⏳ marks one still outstanding.

Child-plan staleness (2026-07-31). Every child ExecPlan's Context section was written before
plans 36/37/47 landed and still names pre-split paths — `shikigami-cli/src/Shikigami/Cli/...`
in plans 18 and 20, `shikigami-core/src/Shikigami/Worker.hs` in plans 17, 19, and 20 — and
plan 38 described codd as present in the tree (corrected 2026-08-05). The *defects* those plans describe were
re-verified against the current tree on 2026-07-31 and all still hold; only the file map and
F1's starting point moved. Each child must have its Context and Concrete Steps re-pointed at
the map in Vision & Scope before implementation begins.


## Dependency Graph

F1 follows plans 36, 37, and 47 — all Complete. It no longer gates new Shikigami migrations:
the manifest, composed plan, and test support exist, so a child may add one today. EP-1, EP-2,
and F1's remainder are all startable now. EP-3's repository-side gates also cleared on
2026-08-05 — plan 28 Milestone 1 landed `Shikigami.Log` and `Shikigami.Log.Correlation`, and
F1's schema gate is released — but its Milestone 1 still wants a released Keiro
`PublishRejected` that upstream has not shipped, so EP-3 starts at M2 or waits. EP-4 hard-depends on EP-1 and EP-2 so it consumes the final ack taxonomy
and `ensureRunQueue`/transactional enqueue seam instead of shipping conditional duplicate
implementations. Three additional coordination edges exist.

EP-1 precedes EP-4. Both edit the run-job handler, now `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs` after plan 36: EP-1 defines the typed outcome-to-`AckDecision` classification, and EP-4 routes its malformed-payload errors through that taxonomy. That module's haddock already names plan 17 as the owner of retry ceilings, lease durations, and the failure taxonomy, and plan 36 deliberately preserved today's behavior unchanged — so EP-1 edits a handler that was left in a known state for it.

EP-2 precedes EP-4 on `shikigami-core/src/Shikigami/Trigger/Enqueue.hs`. EP-2 adds
`enqueueRunJobTx` and `ensureRunQueue`; EP-4 hardens the IO-level helpers by consuming
those artifacts and never conditionally invents them.

EP-3 has cross-MasterPlan integration edges with plan 27 (consolidation) and plans 22/32
(typed HTTP classification). EP-3 lands before plan 32 and defines `Enqueued`,
`PermanentFailure`, per-sink outbox keys, delivery receipts, and the Keiro-owned terminal
publish outcome; plan 27 must preserve them. All journaled-value changes in EP-1/EP-3 also
respect plan 24's additive-only versioning discipline.

EP-3 hard-depends on plan 28 Milestone 1, which defines `Shikigami.Log`, and preferably
follows plan 16, which makes each sink handler truthful. EP-3 then records delivery semantics
using the final sink outcomes and structured logger; plan 27 lands afterward and consolidates
the settled semantics. The sink chain is plan 16 plus plan 28 M1 → EP-3 → plan 27.

EP-1, EP-2, EP-3, and F1's remainder can all proceed in parallel as of 2026-08-05; EP-4
starts after EP-1 and EP-2. This is the MasterPlan-3 slice of the
canonical MP-2 through MP-7 waves recorded in MasterPlan 2.


## Integration Points

Worker handler and ack classification — `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs`
(placement assigned by plan 36, now landed). Involved: EP-1, EP-4. EP-1 keeps shibuya's
`QueueProcessor` as the sole acknowledgement owner, carries its lease for heartbeat, consumes
the adapter's first delivery as attempt 0, and derives retry delay with the shared
`mkRetryPolicy` vocabulary. EP-4 consumes that taxonomy and routes from an explicit
`triggerKind` discriminator; payload decodability is never used as the route selector.

Two facts about that module were fixed by earlier work and both plans consume them rather
than re-deriving them. First, the handler already emits Shibuya's `AckDecision` with typed
`DeadLetterReason`s (`InvalidPayload`, `PoisonPill`), so EP-1's Milestone 2 is about making
the mapping a pure attempt-aware function — every `AckRetry` today is a hard-coded
`RetryDelay 1s` — not about introducing the vocabulary. Second, `Shikigami.Behavior.Error`
already carries `ProviderFailed !Bool !Text`, whose `Bool` is baikai's own `isRetryable`,
threaded from `Shikigami.Behavior.Skill`; plan 47 recorded that EP-1 owns what the worker
does with that flag. EP-1's transient/permanent taxonomy must consume it rather than
reclassify provider failures by string matching.

Run-job enqueue module — `shikigami-core/src/Shikigami/Trigger/Enqueue.hs`, with the Kafka
consumers at `shikigami-workers/src/Shikigami/Trigger/Consumer.hs` and the `consume-stream`
/ `consume-events` entry points under `shikigami-workers/app/`. Involved: EP-2,
EP-4. The queue payload is a bare `toJSON job` on both sides: plan 47 verified that
`shikigami_run_jobs` is not scaffolded by `keiro-dsl`, so Keiro 0.4's versioned
`keiroJobCodec` envelope does not reach it and neither EP-2 nor EP-4 needs a drain gate or
transitional decoder. Plan 39 inherits that as a live constraint. EP-2 defines `enqueueRunJobTx :: RunJob -> Tx.Transaction MessageId` with no
queue creation inside the transaction and a startup `ensureRunQueue`. Every inbox
record reaches one explicit terminal disposition: enqueued, duplicate, permanent
dead-letter, or transient failure with no offset commit. Kafka processing keeps
durable dead-letter/halt behavior and uses shibuya's serial/framework-owned commit
boundary rather than a parallel acknowledgement loop. EP-4 consumes that seam.

Database evolution — the `pg-migrate` component, exact-byte manifest, complete application
plan, CLI, and test-support contract now exist in the tree (`shikigami-migrations`, delivered
by plan 47). Plan 38 owns what remains: unifying the `shikigami-migrate` operator surface.
The codd-ledger import it also owned was cancelled on 2026-08-05. EP-3 adds delivery receipts
only by appending a file to `shikigami-migrations/sql-migrations/manifest` (via
`just new-migration`, which is already pg-migrate-shaped); plans 21 and 23 do the same for
their tables. Note that a migration's durable identity is `<component>/<filename without
extension>` and pg-migrate fingerprints its exact bytes, so an applied file can be neither
renamed nor edited — corrections are new entries.

One non-obvious obligation comes with that component. Applying the plan is only half the
job: `Shikigami.Migrations.reconcileShikigamiReadModels` must run after a successful `up`,
because Kioku 0.2 stopped registering read models on first query and `registerReadModel`
only inserts. Any child of this MasterPlan that introduces a Kioku read model — EP-3's
delivery receipts are the candidate — must confirm the reconciliation covers it, or every
projection query for it fails `ReadModelUnregistered` in production while passing in a
freshly-created test database.

Journaled sink outcome values—`SinkOutcome` and the values journaled by `dispatch-sinks` and
per-reply steps. Involved: EP-3 here; plans 22/32 for typed HTTP failures; plans 24/27 in
MasterPlan 5. EP-3 owns additive `Enqueued` and `PermanentFailure` constructors, per-sink
keys, and the released Keiro `PublishRejected` terminal mapping; old `Delivered`/`Failed`
values remain decodable. `Stubbed` survives in `Shikigami.Sink.Types` as a decodable
constructor that plan 16 stopped producing; EP-3 must keep it decodable and must not start
producing it again. Journaled step names are never renamed and value evolution stays
backward-compatible. Plan 27 preserves these final semantics.

Plan 16 added two hard constraints on how EP-3 may extend the outboxed record.
`SinkIntent` is defined **twice** — in `Shikigami.Agent.Workflow` and in
`Shikigami.Flow.SinkOutbox` — because the flow module cannot import the workflow module
without a package cycle, while `publishSinkIntent` decodes rows enqueued by both using the
workflow's copy. A field added to one and not the other is silently dropped in transit.
`Shikigami.WireCompatSpec` now asserts the two encoders produce identical bytes, so EP-3's
per-sink keys and receipt correlation must be added to both copies or the build fails.
Second, additive fields on a journaled or outboxed record are encoded with
`omitNothingFields`, so a record that resolved nothing stays byte-identical to one written
before the field existed and the pinned pre-upgrade fixture in `WireCompatSpec` is never
rewritten. EP-3 follows the same discipline. Consolidating the duplication remains plan 27's.

Workflow result encoding — `agentRunWorkflow`'s return type `Either Text AgentRunResult` (journaled by keiro as the workflow completion value). Involved: EP-1. Decision recorded here so no plan trips over it: EP-1 does not change this type. Transient failures are expressed by throwing (never journaled), so a journaled `Left` comes to mean "permanent failure" without any encoding change to already-completed workflows.

Agent loading boundary. EP-4 owns `AgentLoadReport`, the single directory traversal, and
loud/strict failure behavior. Plan 30 renders that report in `agents list`; plan 33 adds
enabled-agent selection; plan 23 persists the report and annotates the existing command with
lifecycle state. EP-4 must not implement persistence, enabled filtering, or operator output.

Plan 36 Milestone 4 already collapsed the four private copies of "list the directory, load
every `*.dhall`, drop the ones that fail" into one function in
`shikigami-core/src/Shikigami/Agent/Loader.hs`. EP-4's Context still describes four
call sites in `shikigami-cli`; there is now exactly one function to change, and
`loadAgent :: FilePath -> IO (Either LoadError AgentDecl)` beside it already returns the
error the directory walk discarded.

**Correction, 2026-08-20 (EP-4 landed).** This paragraph used to say strict mode must expect
**two** failing fixtures under `agents/`. That is wrong, and following it would have made the
strict-mode test assert a failure that never happens. `loadAgentsReport` does `listDirectory`
and keeps top-level names ending in `.dhall`; the traversal is **not recursive**, so
`agents/detectors/schema.dhall` is never opened. There is exactly one expected failure,
`agents/broken.dhall`, and the delivered `AgentLoaderSpec` asserts `"failed":1`. The retired
tombstone remains a record *type* rather than a manifest, and remains out of reach.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-1: Milestone 1 — transient/permanent behavior failure taxonomy; transient failures throw instead of journaling
- [x] F1: Milestones 1, 2, and most of 4 — pg-migrate component, exact-byte manifest, complete four-component plan, `pg-migrate-cli` executable, pg-migrate test support, codd removed from the repository (delivered by plan 47, 2026-07-31)
- [x] F1: Milestone 3 — **cancelled 2026-08-05.** No database needs its codd history preserved; codd support was removed outright instead
- [ ] F1: Milestone 4 remainder — `shikigami-migrate` resolves `DATABASE_URL` through the shared `AppConfig` instead of reading it directly; the `shikigami-core` ↔ `shikigami-migrations` package cycle is broken
- [ ] EP-1: Milestone 2 — zero-based adapter attempts, shared retry policy, framework-owned ack classification, and a real dead-letter queue
- [ ] EP-1: Milestone 3 — visibility heartbeat via the shibuya lease during long-running handlers
- [ ] EP-1: Milestone 4 — explicit wall-clock run timeout and configurable approval deadline
- [ ] EP-2: Milestone 1 — transactional enqueue: inbox transaction and pgmq send commit atomically
- [ ] EP-2: Milestone 2 — offset commit only after an explicit terminal inbox disposition; transient/store errors do not commit
- [ ] EP-2: Milestone 3 — supervised serial Kafka loop with reconnect backoff and durable dead-letter/halt poison policy
- [ ] EP-3: Milestone 1 — additive Enqueued/PermanentFailure outcomes and released Keiro PublishRejected; logSinkResult implemented
- [ ] EP-3: Milestone 2 — pg-migrate-managed sink delivery receipts table; publish outcomes and reconciliation state recorded and queryable
- [ ] EP-3: Milestone 3 — retry-safe dispatch: kizashi send-guard and danwa conversation reuse
- [ ] EP-3: Milestone 4 — per-sink outbox keys; head-of-line isolation between a run's sinks
- [ ] EP-4: Milestone 1 — routing on an explicit RunJob trigger discriminator with typed failure for mismatched/undecodable payloads
- [ ] EP-4: Milestone 2 — scheduler catch-up policy (skip-missed/coalesce default) and timer-kind dispatch fix
- [ ] EP-4: Milestone 3 — critical kioku errors propagate to retry/failure; best-effort writes are explicitly classified and logged
- [ ] EP-4: Milestone 4 — loud agent/cron loading with strict mode; enqueue-path hardening (keys, queue creation, epoch fallback, UUIDv5 bytes)


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Planning research (2026-07-08): keiro has no per-step retry policy or step options at all — the framework's documented contract (keiro `Keiro/Workflow.hs` module haddock and the `Step` handler, which journals only after the step body returns) is that transient failures should be thrown so the step re-runs on the next execution. This turned EP-1's design from "add a retry policy" into "stop journaling transient failures", which is a smaller and more idiomatic change.
- Dependency-cohort review (2026-07-30): Shibuya 0.8 exposes
  `lease :: Maybe (Lease es)` on the public `Message es msg` a handler receives, while
  shibuya-pgmq-adapter 0.12 converts PGMQ's one-based `read_count` to a zero-based
  `Envelope.attempt`. EP-1 keeps the lease and consumes the attempt without another
  normalization.
- Planning research (2026-07-08): neither kizashi's create-signal endpoint nor danwa's start/join/post endpoints accept any client-supplied id or idempotency key, and danwa has no lookup-by-external-key. EP-3's downstream idempotency is therefore necessarily client-side (a delivery-receipt guard in shikigami's own database), with upstream API changes recorded as follow-ups.
- Fleet conformance audit (2026-07-22): `pg-migrate` already supplies the component,
  manifest, complete application-plan, Codd ledger importer, CLI, and test support this
  initiative needs. Continuing to author Codd migrations would create a second schema
  authority and make delivery-receipt rollout unverifiable.
- Foundation landing (2026-07-31): **F1's scope shrank because plan 47 could not leave codd
  in place.** Plan 47 intended to keep the codd pins until plan 38 replaced them, but
  `kiokuMigrations` in Kioku 0.2 is a pg-migrate `MigrationComponent` rather than a list of
  codd `AddedSqlMigration`s, so there was no codd-shaped set left to append shikigami's
  migrations to. `shikigami-migrations`, its executable, and its `test-support` sublibrary
  all moved to pg-migrate in one step and codd left the repository. Verified in the tree on
  2026-07-31: `shikigami-migrations.cabal` depends on `pg-migrate`, `pg-migrate-embed`, and
  `pg-migrate-cli`; `sql-migrations/manifest` exists with both SQL files; the operator
  contract is `DATABASE_URL` and `cabal run shikigami-migrate -- up`. The migration filenames
  and their `-- codd: in-txn` headers were preserved verbatim as payload evidence for F1's
  ledger import. **Void as of 2026-08-05:** the import is cancelled and the headers are
  removed. They were inert anyway — pg-migrate takes transaction mode from the Haskell
  component, not from a SQL comment. The filenames stay, but for a different reason: an
  applied migration's durable identity is its filename, so renaming one breaks any database
  that ran it.
- Foundation landing (2026-07-31): **F1 also inherits a package-cycle problem that plan 37
  discovered and could not fix.** `shikigami-core`'s test suite depends on
  `shikigami-migrations`' public `test-support` sublibrary, so adding `shikigami-core` to
  `shikigami-migrate`'s `build-depends` makes the two packages mutually dependent, and Cabal
  detects cycles at package rather than component granularity:

  ```text
  [_33] rejecting: shikigami-core:*test (cyclic dependencies; conflict set:
        shikigami-core, shikigami-migrations)
  ```

  `shikigami-migrate` therefore reads `DATABASE_URL` with `lookupEnv` directly, documented at
  its call site. This is the one remaining exception to plan 37's "Settei is the sole
  process-configuration mechanism" rule, and F1 is the plan positioned to restructure the
  package boundary while it works there.
- Foundation landing (2026-07-31): **applying the migration plan is not sufficient on its
  own.** Kioku 0.2 stopped registering read models on first query and `registerReadModel`
  only inserts, so a host applying a composed plan directly must reconcile keiro's
  `keiro_read_models` registry itself or every projection query fails `ReadModelUnregistered`.
  `Shikigami.Migrations.reconcileShikigamiReadModels` now runs after a successful `up` and in
  the test database. Any plan here that adds a Kioku read model — EP-3's delivery receipts —
  inherits this as a live production concern, not an upgrade artifact.
- Foundation landing (2026-07-31): **EP-1's retry taxonomy has a concrete upstream input it
  did not have at planning time.** Baikai 0.4 reports provider failure in-band, and
  `runSkillWith` previously read only the assistant text — so an error-shaped response became
  a successful reply of `""`, recorded as a learning and followed by sink dispatch. Plan 47
  translated that into `Shikigami.Behavior.Error.ProviderFailed !Bool !Text`, carrying
  baikai's own `isRetryable`. EP-1 consumes that flag rather than inventing a classifier;
  plan 13 owns which provider runs.
- Foundation landing (2026-07-31): **EP-4's loader premise improved and its fixture premise
  got harder.** Plan 36 M4 collapsed four identical private copies of the silent-skip loader
  into one `Shikigami.Agent.Loader.loadAgentsIn`, so EP-4 now has a single edit site rather
  than four. But plan 16 found that `agents/detectors/schema.dhall` also fails validation and
  always did — it is a retired tombstone and a record type, not a manifest — so EP-4's strict
  mode has two expected failures under `agents/`, not one.
- Runtime-pattern audit (revised 2026-07-30): PGMQ `read_count` is one-based, but the
  released adapter's handler-facing `Envelope.attempt` is zero-based. Shibuya owns
  acknowledgement/commit. Retry and inbox plans consume those facts rather than layering
  another normalization or a second ack loop over the framework.


## Decision Log

- Decision: Cancel F1's codd-ledger import (plan 38 Milestone 3) and remove codd support
  outright, rather than carrying an import path for a migration nobody needs to make.
  Rationale: the import exists to protect data in a database that crossed over from codd.
  Shikigami has no users, and the only such database — the developer cluster in `db/` — was
  found on 2026-08-05 carrying both a `codd.sql_migrations` and a `pgmigrate.migrations`
  ledger, which made `just migrate` fail on objects codd had already created. It was dropped
  and recreated from empty in seconds. Keeping the import would have meant keeping the
  `pg-migrate-import-codd` dependency and, more expensively, the constraint that no applied
  SQL file may be renamed or reformatted because its bytes are import evidence.
  Consequence: if shikigami is ever pointed at a codd-managed database, the answer is to
  recreate it, not import it. Revisit this the moment a database holds data anyone wants.
  Date: 2026-08-05

- Decision: F1 no longer gates schema authoring for EP-3, plans 21, 23, 35, or 51.
  Rationale: what those plans need from F1 is a working pg-migrate authoring path — a manifest
  to append to and public test support to write a plan-aware test against. Both exist and were
  proven on 2026-08-05 (40 migrations apply from empty, a second `up` is a no-op,
  `migrate-status` reports `issues=0`). F1's remainder is the migration executable's
  *configuration* surface, which no schema author touches. Holding five plans behind it would
  be sequencing on a shared plan number rather than on a real dependency.
  Date: 2026-08-05

- Superseded decision (2026-07-31): Keep F1 (plan 38) in the registry with reduced scope rather than cancelling it as
  superseded by plan 47.
  Rationale: plan 47 delivered the component, manifest, plan, CLI, and test support, but the
  two parts that need their own rollback and deployment proof remain undone — the codd ledger
  import for an already-deployed database, and the package restructure that unifies the
  migration executable's operator surface. Cancelling F1 would drop both, and EP-3's receipts
  table still needs a foundation plan that has been proved against real data.
  Partly superseded 2026-08-05: the ledger import is cancelled, so only the package
  restructure justifies keeping F1 open, and EP-3 no longer waits on it.
  Date: 2026-07-31

- Decision: Treat the child ExecPlans' file paths as stale documentation to be re-pointed at
  implementation time, not as evidence that their defects were fixed.
  Rationale: plans 36/37/47 moved modules and packages without changing behavior — the run-job
  handler's own haddock records that it "preserves today's behavior unchanged" and names plan
  17 as the owner of the retry taxonomy. Every defect this MasterPlan targets was re-verified
  against the current tree on 2026-07-31 and still holds. Rewriting the children now, before
  anyone implements them, would spend effort on context that each implementer must re-derive
  from the working tree anyway; recording the map in one place is enough.
  Date: 2026-07-31

- Decision: Make plan 47 a hard foundation and track Keiro IR-3 as the only upstream gate
  on terminal outbox rejection.
  Rationale: Shibuya/PGMQ attempt, handler, and migration APIs change in the released cohort,
  while terminal rejection must remain Keiro-owned rather than a raw-table workaround.
  Date: 2026-07-30


Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Decompose into one database foundation plus four ExecPlans along hand-off
  boundaries, registered as F1=plan 38 and EP-1 through EP-4=plans 17–20.
  Rationale: Each boundary has a distinct failure mode, distinct files, and an independently observable fix; one mega-plan would exceed the ExecPlan size guidance and none of the streams share code artifacts that would force merging.
  Date: 2026-07-08

- Decision: EP-4 hard-depends on EP-1 and EP-2; it consumes EP-1's ack taxonomy and
  EP-2's `ensureRunQueue`/transactional enqueue seam.
  Rationale: the earlier soft/integration treatment required conditional duplicate
  implementations in EP-4. Serializing EP-4 behind EP-1/EP-2 removes that ambiguity;
  EP-3 remains independent of them and follows plan 28 Milestone 1.
  Date: 2026-07-22
- Decision: Retry math uses the adapter's zero-based `Envelope.attempt` and the shared
  `mkRetryPolicy`; Shibuya remains the sole acknowledgement owner.
  Rationale: the adapter already converts PGMQ `read_count`; preserving adapter/framework
  ownership prevents double normalization, duplicate acknowledgements, and process-specific
  retry dialects.
  Date: 2026-07-30
- Decision: Every new Shikigami table is delivered through plan 38's pg-migrate
  component and complete application plan; the Codd transition imports history only.
  Rationale: one schema authority makes fresh installs, upgrades, verification, tests,
  and rollback evidence agree on the exact migration prefix.
  Date: 2026-07-22

- Decision: EP-1 keeps `agentRunWorkflow`'s result type `Either Text AgentRunResult` unchanged and expresses transience by throwing; a journaled `Left` becomes "permanent" by construction.
  Rationale: keiro journals the workflow completion value; changing the type would change the JSON encoding of already-journaled completions and violate the additive-only versioning discipline that docs/plans/24 establishes.
  Date: 2026-07-08

- Decision: EP-3 lands before (or its semantics are treated as the frozen specification by) the docs/plans/27 sink-machinery consolidation in MasterPlan 5.
  Rationale: Refactoring should preserve semantics; therefore semantics must be corrected first. Consolidating first would bake the enqueue-time "Delivered" lie into the consolidated module and force a second pass.
  Date: 2026-07-08

- Decision: EP-4 stops the silence around agent-manifest and cron load failures (logging, counts, strict mode) but does not persist per-agent load state; that persistence belongs to docs/plans/23 in MasterPlan 4.
  Rationale: Load-state persistence requires the meibo principal model that MasterPlan 4 introduces; duplicating a throwaway mechanism here would create migration debt.
  Date: 2026-07-08
- Decision: EP-4 owns the canonical `AgentLoadReport`; plans 30 and 33 consume it for
  inspection and enabled selection, then plan 23 adds durable lifecycle state.
  Rationale: a single report preserves failures and prevents four plans from walking the
  same directory with subtly different semantics.
  Date: 2026-07-22
- Decision: Order the sink path as plan 16 plus plan 28 M1 → EP-3 → plan 27.
  Rationale: handlers become honest first, delivery accounting and logging then settle,
  and consolidation finally moves the stable semantics and trace context once.
  Date: 2026-07-22
- Decision: Make plan 28 Milestone 1 a hard predecessor of EP-3.
  Rationale: EP-3 now emits delivery and publisher events through the concrete
  `Shikigami.Log` API rather than adding temporary stderr logging that a later plan must
  replace.
  Date: 2026-07-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)


## Revision Notes

- 2026-08-05: Cancelled F1's Milestone 3 (the codd-ledger import) after the decision that
  shikigami has no users and no database whose history needs preserving; codd was removed from
  the repository outright. F1 is now Mostly Complete with one configuration change left, and it
  no longer gates schema authoring. EP-3 (plan 19) moves to startable: plan 28 Milestone 1
  landed the same day, and F1's schema gate is released — only its terminal-delivery milestone
  still waits on Keiro IR-3. Voided the inherited constraint that applied SQL files keep their
  `-- codd: in-txn` headers, which were inert under pg-migrate; recorded the real reason their
  filenames must not change (durable migration identity).

- 2026-07-31: Reconciled the MasterPlan against six plans that landed since it was last
  revised (36, 37, 47, 13, 15, 16). Every cross-MasterPlan hard dependency of F1, EP-1, and
  EP-2 is now Complete, so all three are startable; EP-3 remains gated on F1 and plan 28 M1
  (no `Shikigami/Log.hs` exists yet) and on Keiro IR-3; EP-4 remains gated on EP-1 and EP-2.
  Reduced F1's scope to the codd ledger import and the `shikigami-migrate` config/package
  restructure, since plan 47 delivered the component, manifest, plan, CLI, and test support
  and removed codd from the tree. Recorded the post-split file map and flagged the children's
  stale `shikigami-cli` / `Shikigami/Worker.hs` paths. Added four inherited constraints:
  `reconcileShikigamiReadModels` after every `up`, the duplicated `SinkIntent` plus the
  `omitNothingFields` discipline and byte-pinned `WireCompatSpec` for EP-3, the existing
  `ProviderFailed`/`isRetryable` input for EP-1, and the single `loadAgentsIn` call site plus
  the second expected fixture failure for EP-4. All child-plan defects re-verified as still
  present in the current tree.

- 2026-07-30: Added plan 47 to every child, corrected Shibuya/PGMQ attempt zero semantics,
  and linked the terminal-rejection milestone to Keiro IR-3.

- 2026-07-22: Converted EP-4's worker/enqueue prerequisites and EP-3's structured-logger
  prerequisite to hard dependencies, assigned canonical loader ownership to EP-4, and
  added the cross-MasterPlan sink landing chain. This aligns MasterPlan 3 with the MP-2
  through MP-7 execution waves.
- 2026-07-22: Added plan 38 as the database foundation; aligned retries, queue attempts,
  acknowledgements, inbox dispositions, Kafka poison behavior, and receipt migrations
  with the verified runtime and pg-migrate patterns.
