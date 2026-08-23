---
id: 23
slug: agent-lifecycle-control-with-meibo-principals
title: "Agent lifecycle control with meibo principals"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1typzbe9dtqnk49t6d5q5w"
master_plan: "docs/masterplans/4-identity-and-trust-grants-outbound-auth-and-agent-lifecycle-control.md"
---

# Agent lifecycle control with Meibo principals

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami loads declared agents from Dhall manifests and runs them from schedules, activity
records, and integration events. The manifests now have loud load reporting, an explicit
`enabled` flag, and an optional `identity.principal`, but all long-running roles still load
their declarations only at startup. An operator cannot pause one deployed agent everywhere
without editing configuration and restarting processes. Sink delivery and Kioku session
attribution still use the declaration name rather than a verified directory principal.

This plan implements the repository's `IR-1` improvement request in
`docs/improvement-requests/consult-meibo-agent-lifecycle.md`. After implementation, the
explicitly configured local directory view is refreshed while processes run. A Meibo agent
principal with lifecycle `paused` or `deactivated` cannot produce a new trigger job, start a
queued job, enqueue a sink intent, or publish an already-enqueued intent. Every trigger or
queue-drain refusal is durably recorded, every sink refusal is represented by a durable sink
result or delivery receipt, and reactivation resumes new work without a process restart.

The same directory join makes the operator's agent inventory show declaration state beside
principal id and lifecycle, makes `agents sync` persist load state and reconcile the nullable
principal id on existing sink grants, and makes newly opened Kioku sessions store the
principal id in `StartSessionData.agentId`. This plan deliberately leaves memory scope,
`RunJob` identity, grant primary keys, and outbound actor fields name-keyed; the follow-on
`docs/plans/54-key-durable-agent-state-by-meibo-principal.md` owns that broader re-keying.

Meibo's C14 contract is documented at `mori://shinzui/meibo/docs/initial-spec`: a principal
has a stable kind-prefixed id, a unique handle, and lifecycle `active | paused |
deactivated`; `paused` is the portfolio-wide agent kill switch. No trigger or sink hot path
may call the Meibo service. This plan therefore installs a cached `DirectoryHandle` and a
file-backed source whose internal contract a future live client can implement. The file is a
development and test source, not a second system of record.

The HTTP API, live Meibo client authentication, Meibo event consumption, kikan-en action
checks, cost/model capture, and the plan-54 durable identity migration remain out of scope.


## Progress

- [x] (2026-08-23T00:20:46Z) Refreshed this plan against commit
  `8f0bf5ec5bc1a44e30419f6e2e60565e8f639fe6`: corrected six-package ownership, current
  transaction boundaries, current sink-delivery semantics, Settei keys, pg-migrate layout,
  workflow-versioning requirements, and the Meibo source status.
- [x] (2026-08-23T00:20:46Z) Prerequisites verified: plans 20, 21, 30, 33, 36, and 47 have
  landed; plan 38's pg-migrate component, manifest, CLI, and test support have landed. Plans
  37 and 38 retain only their shared migration-CLI Settei cleanup, which does not block adding
  a forward migration here.
- [x] (2026-08-23T00:38:15Z) Milestone 1: implemented `Shikigami.Directory`, the typed
  conditional Settei directory selection, fail-closed configured cold start, atomic
  last-known-valid refresh, operator documentation, and focused tests. Evidence:
  `nix develop -c cabal build lib:shikigami-core test:shikigami-core-test`, 12 principal
  directory tests, and 49 configuration/provider tests passed.
- [x] (2026-08-23T00:49:00Z) Milestone 2: appended the pg-migrate change for
  `shikigami.agent_load_state` and `shikigami.run_skips`, implemented complete-view and
  idempotent skip persistence, added the loader's before-refusal hook, and wired that hook
  through the combined worker, standalone scheduler, and both consumers. Evidence: four pure
  migration tests, two real-Postgres migration smoke tests, three real-Postgres directory
  store tests, and all 11 loader tests passed; the core and workers libraries build.
- [x] (2026-08-23T01:07:54Z) Milestone 3: enforced lifecycle at schedule, Kafka trigger,
  and run-job drain boundaries; supervised a cadence-aware refresh loop in every configured
  worker role; and proved transactional skip auditing. Evidence: `shikigami-core` and all
  worker executables build, and all 78 `shikigami-workers` tests pass, including real-Postgres
  schedule, inbox, and drain lifecycle cases.
- [x] (2026-08-23T01:24:31Z) Milestone 4: enforced lifecycle before sink grant checks at
  enqueue and publish, carried an optional resolved principal through both compatible sink
  intent codecs, recorded publish-time refusals as terminal non-send receipts, and attributed
  new agent-run and conversation sessions to the principal without changing their name-keyed
  scopes or journal step shapes. Evidence: all 387 `shikigami-core` tests pass, including
  enqueue-after-pause, pause-after-enqueue, principal session attribution, and wire
  compatibility cases.
- [ ] Milestone 5: extend `shikigami agents list`, add `agents sync`, reconcile grant
  principal ids, update operator/configuration documentation, and capture the pause/resume
  demonstration.
- [ ] Final: `nix develop -c cabal test all`, `nix develop -c just keiro-gate`, and the
  manual acceptance transcript are green; durable decisions are distilled into `docs/adr/`.


## Surprises & Discoveries

- Mori currently reports `shinzui/meibo` with zero packages, but its registered checkout now
  contains `meibo-api`, `meibo-client`, `meibo-core`, `meibo-server`, and
  `meibo-migrations`. The checkout has no release tags, and the latest local commit observed
  during refresh was `f6b6d19fd09f305b11e2fb7210df8e2342a4d7ab` from 2026-08-08. Plan
  54 already owns pinning the unreleased client. Evidence: `mori registry show
  shinzui/meibo --full`, `git -C <registered-meibo-checkout> tag --list`, and the source
  inventory under `mori://shinzui/meibo/repos/meibo`. (2026-08-22)

- Meibo's current `PrincipalView` wire format is snake_case and includes more than the three
  fields Shikigami needs. The file stub should use `principal_id`, `handle`, and `lifecycle`
  and ignore additional fields, while the internal `DirectorySource` returns Shikigami's own
  small `PrincipalRecord`. This avoids pretending a bare array is identical to Meibo's
  paginated HTTP response. (2026-08-22)

- Activity and integration-event jobs are no longer enqueued by the `onHit` callbacks. They
  are enqueued inside `runInboxTransaction` in
  `shikigami-workers/src/Shikigami/Trigger/Consumer.hs`; `onHit` only logs after commit.
  Lifecycle decisions and `run_skips` inserts must therefore be prepared before that
  transaction and committed inside it, or the Kafka offset could advance without the skip
  audit. (2026-08-22)

- `loadAgentsLoud` exits inside the loader when strict mode sees any failure. A caller cannot
  persist the returned report after that exit. Milestone 2 must add a before-refusal hook (or
  an equivalent loader API with the same single traversal) so a strict deployment records
  every failure before refusing startup. (2026-08-22)

- The sink-intent implementation is still intentionally duplicated between
  `Shikigami.Agent.Workflow` and `Shikigami.Flow.SinkOutbox`; plan 27 has not consolidated it.
  Both copies must carry the optional principal id and retain byte-identical codecs, as
  enforced by `Shikigami.WireCompatSpec`. (2026-08-22)

- The mounted pg-migrate `new` command no longer accepts the positional spelling retained in
  the earlier concrete transcript. It requires `--manifest` and `--description`, and this
  timestamp-style manifest also needs an explicit `--name`; the implementation used the
  mounted CLI's help and authoring contract. (2026-08-22)

- Worker liveness previously had only fixed, constructor-wide stale thresholds. A directory
  refresh interval is operator-configured up to one day, so a fixed `DirectoryLoop` threshold
  would either fail healthy slow-cadence processes or take a day to notice a default-cadence
  wedge. `Heartbeats` now stores per-registration thresholds; existing loops retain their
  defaults and configured directory loops use three missed refresh periods with a ten-second
  floor. (2026-08-22)

- `just keiro-gate` runs `git diff --exit-code -- shikigami-core/src` after scaffolding, so it
  cannot certify an uncommitted workflow-source milestone even when every generated file is
  unchanged. Its semantic checks and scaffolding were clean before the Milestone 4 commit;
  the full gate must be rerun against that commit so the source-tree freshness comparison has
  a committed baseline. (2026-08-22)


## Decision Log

- Decision: Keep this plan file-source-first even though a Meibo client now exists.
  Rationale: the client is unreleased and untagged, while plan 54 explicitly owns selecting
  and pinning it. The lifecycle architecture needs the cached-view and source seam regardless
  of transport, and implementing that seam now keeps this plan independently releasable.
  Date: 2026-08-22

- Decision: Model `DirectoryView` with indexes by both principal id and normalized handle,
  reject duplicate ids or handles, and treat an explicit `identity.principal` as authoritative.
  Handle lookup is used only when the declaration has no principal field.
  Rationale: C14 makes the id canonical and the handle the compatibility join. Falling back
  from a present-but-unknown id to a handle could silently bind a declaration to the wrong
  principal, while a one-map design cannot perform both lookups unambiguously.
  Date: 2026-08-22

- Decision: Distinguish explicit `DirectoryDisabled` from a configured directory with no
  valid snapshot. Configured cold start fails closed; after one successful refresh, a refresh
  failure retains exactly the last valid snapshot and logs the failure.
  Rationale: disabled mode is an intentional compatibility choice. A source that has never
  supplied policy cannot safely imply `active`, while an outage must not erase already
  observed lifecycle state.
  Date: 2026-07-22; reaffirmed 2026-08-22

- Decision: A valid snapshot missing the authoritative id or compatibility handle denies as
  `UnknownPrincipal`. Paused, deactivated, unknown, and unavailable decisions all share the
  no-side-effect path but remain distinct values for logging and tests.
  Rationale: absence is not evidence that an agent is active, and distinct reasons are needed
  for repair.
  Date: 2026-07-22; refined 2026-08-22

- Decision: Record admission skips in `shikigami.run_skips` only at `trigger` and `drain`
  stages, with a non-null idempotency key and uniqueness on `(stage, idempotency_key)`.
  Record sink skips through `SinkOutcome = SkippedLifecycle Text` plus the existing delivery
  receipt path.
  Rationale: triggers and queue drains have no workflow session result to attach to. Sink
  enqueue already journals `SinkResult`, and publish already records terminal non-send
  receipts; duplicating those in `run_skips` would create two authorities for sink truth.
  Date: 2026-08-22

- Decision: Carry `principalId :: Maybe Text` in both copies of `SinkIntent`, omitted when
  absent and defaulted to `Nothing` when decoding old rows.
  Rationale: publish happens after the originating declaration may have changed or disappeared.
  Re-resolving only by agent name would discard an authoritative declared principal exactly at
  the second lifecycle gate. The optional compatible field preserves historical outbox rows.
  Date: 2026-08-22

- Decision: Do not allocate a Keiro patch id for this plan's workflow edits.
  Rationale: no journal step is added, removed, renamed, reordered, or decoded as a different
  type. Old `SinkResult` and `SinkIntent` bytes still decode, and the new lifecycle branch
  applies only when an existing side-effecting step has not yet been recorded. Applying the
  current kill switch to an in-flight run before its sink is the intended safety behavior; a
  patch's legacy branch would deliberately bypass it. `just keiro-gate` remains mandatory and
  must report no declared body change.
  Date: 2026-08-22

- Decision: Extend the loud loader with a persistence hook that runs after reporting and before
  strict refusal, rather than walking the directory a second time or weakening strict mode.
  Rationale: one report must feed logging, enabled selection, durable state, and operator
  inventory. Two traversals can observe different files and strict refusal before persistence
  recreates the invisible-failure problem this plan closes.
  Date: 2026-08-22

- Decision: Keep session memory scopes name-keyed while writing the resolved principal id to
  `StartSessionData.agentId` for both agent-run and conversation sessions.
  Rationale: `IR-1` requires directory attribution; plan 54 owns re-keying durable memory and
  lineage without orphaning history. Mixing half of plan 54 into this plan would make its
  reconciliation incomplete.
  Date: 2026-07-08; reaffirmed 2026-08-22

- Decision: Treat a committed Kafka lifecycle refusal as `Enqueued` at the broker disposition
  layer, while carrying an internal committed-result value that distinguishes a queued run
  from a skip for post-commit logging.
  Rationale: `Enqueued` is the pre-existing name for "the inbox handler's durable effect
  committed" and maps to `AckOk`; adding a second terminal broker disposition would not alter
  mechanics. The internal distinction prevents the enqueue callback from firing for skips and
  keeps offset acknowledgement after the inbox and `run_skips` row commit together.
  Date: 2026-08-22


## Outcomes & Retrospective

The 2026-08-22 refresh converted the July design into an implementation guide for the current
tree. It removed obsolete `shikigami-cli` and pre-pg-migrate paths, assigned code to
`shikigami-core`, `shikigami-workers`, `shikigami-server`, and
`shikigami-migrations`, incorporated transactional Kafka ingestion and terminal delivery
receipts, and separated this plan's attribution work from plan 54's durable re-keying.

Milestone 1 established the reusable enforcement seam without adding a Meibo package:
configured processes require one valid file snapshot, later malformed candidates cannot
replace it, and disabled mode remains visibly distinct from an unavailable source. The Settei
schema and operator guide now expose the conditional file path and bounded refresh interval.

Milestone 2 made the loader report and lifecycle refusals durable. One transaction replaces
the complete observed state for a manifest directory, strict startup persists before refusal,
and `(stage, idempotency_key)` makes retried trigger/drain evidence safe.

Milestone 3 connected that policy to every ingress and drain composition root. Schedule
timers now remain retryable if skip auditing fails and advance only after either enqueue or
durable refusal. Kafka matches prepare lifecycle decisions before opening the inbox
transaction, then atomically enqueue or record the refusal; duplicate delivery repeats
neither effect. The PGMQ worker consults lifecycle before route selection, acknowledges a
durable refusal, and retries an audit failure. Directory refresh loops are supervised and
heartbeat after success or failure using the configured cadence.

Milestone 4 closes both sink race windows. A paused principal cannot create an outbox row, and
a principal paused after enqueue cannot cross the HTTP boundary; the latter becomes a dead,
terminal non-send receipt so publication will not retry. Compatible intent decoding keeps old
rows publishable, while new rows preserve the resolved principal for the second check. Newly
opened agent-run and conversation sessions now store that principal in Kioku while their
lookup scope remains declaration-name-keyed. Milestone 5 remains to expose inventory and
grant reconciliation to operators.


## Context and Orientation

Shikigami is a Cabal multi-package Haskell application. `shikigami-core` owns declarations,
directory domain values, durable workflows, sink intent construction, and database access
modules. `shikigami-workers` owns the queue, scheduler, Kafka subscription, resume, timer, and
outbox loops. `shikigami-server` owns the `shikigami` operator CLI.
`shikigami-migrations` owns the ordered pg-migrate manifest and the public ephemeral-Postgres
test support. Run every build and test inside the Nix development shell.

An agent declaration is `Shikigami.Agent.Decl.AgentDecl` in
`shikigami-core/src/Shikigami/Agent/Decl.hs`. Its `identity :: Maybe IdentityDecl` contains an
optional `principal :: Text`. `Shikigami.Agent.Loader.loadAgentsLoud` returns one
`AgentLoadReport` containing every `AgentLoaded` and `AgentLoadFailed` entry; all worker roles
already use it and then call `enabledAgentsFromReport`.

`Shikigami.App.Config.AppConfig` is the one typed Settei declaration. Add
`DirectorySettings = DirectoryDisabled | DirectoryFile {path, refreshInterval}` through a
conditional branch selected by `directory.mode`. The stable keys are
`directory.mode`, `directory.file.path`, and `directory.refresh_interval_seconds`; the
environment bindings are `SHIKIGAMI_DIRECTORY_MODE`, `SHIKIGAMI_DIRECTORY_FILE_PATH`, and
`SHIKIGAMI_DIRECTORY_REFRESH_INTERVAL_SECONDS`. Disabled is the default. File mode requires a
path and defaults the bounded positive refresh interval to five seconds.

Trigger admission has three owners. Schedule timers fire in
`shikigami-workers/src/Shikigami/Trigger/Scheduler.hs`; `scheduleFireAction` must gate before
`enqueueScheduledRun`, record a skip when denied, and still arm the next tick after a durable
skip. Activity and integration-event jobs are built transactionally in
`shikigami-workers/src/Shikigami/Trigger/Consumer.hs`; their prepared lifecycle decisions must
drive either `enqueueRunJobTx` or `recordRunSkipTx` inside the same inbox transaction. Decoded
PGMQ jobs enter `handleRunJob` in
`shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs`; it must record a `drain` skip and
return `Done` only after the insert commits, otherwise return `RetryDefault`.

Sink admission has two phases. Enqueue-time checks live in
`shikigami-core/src/Shikigami/Agent/Workflow.hs` and the duplicated
`shikigami-core/src/Shikigami/Flow/SinkOutbox.hs`. Publish-time checks live in
`shikigami-core/src/Shikigami/Sink.hs`, reached through `publishSinkIntent` in the workflow
module. The directory check occurs before the C11 grant check at each phase. A refusal produces
`SkippedLifecycle reason`, no outbox row at enqueue time, and a terminal non-send delivery
receipt at publish time.

Session attribution occurs in the existing `open-session` steps. Agent runs construct
`StartSessionData` in `Shikigami.Agent.Workflow.openSession`; conversations construct the same
value in `Shikigami.Agent.Conversation`. A fresh configured run has already passed the drain
gate, so lookup resolves the same authoritative principal and stores its id in `agentId`.
Explicit disabled mode falls back to the declaration's principal text and then its name.

The migration manifest is
`shikigami-migrations/sql-migrations/manifest`; every new schema change is a new immutable
entry. Tests use `Shikigami.Migrations.TestSupport.withShikigamiMigratedDatabase` rather than
inventing a database harness.

The local ADR corpus is plain Markdown, not an OKF bundle. Relevant accepted records are:

- [`docs/adr/0004-one-options-value-and-a-checked-patch-set.md`](../adr/0004-one-options-value-and-a-checked-patch-set.md)
  and [`docs/adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md`](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md),
  which require one checked patch set and a real patch branch for declared body-shape changes.
  This plan changes no declared body shape.
- [`docs/adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md`](../adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md),
  which supplies the compatible optional-field pattern used for the sink-intent principal id.
- [`docs/adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md`](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md),
  which requires the flow sink gate to remain in the capability interpreter rather than in a
  flow body.
- [`docs/adr/0019-a-loop-that-stops-stops-the-process.md`](../adr/0019-a-loop-that-stops-stops-the-process.md)
  and [`docs/adr/0020-readiness-covers-only-what-restarting-can-fix.md`](../adr/0020-readiness-covers-only-what-restarting-can-fix.md),
  which govern refresher supervision and distinguish a live retrying loop from dependency
  readiness.
- [`docs/adr/0021-operator-verbs-wrap-the-owning-library.md`](../adr/0021-operator-verbs-wrap-the-owning-library.md),
  which keeps `agents sync` as Shikigami-owned join logic rather than a duplicate Meibo CLI.
- [`docs/adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md`](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md),
  which makes the delivery receipt, not the workflow journal, authoritative after enqueue.

No accepted local ADR currently defines directory-cache failure semantics. Implementation must
distill that durable decision into a new ADR using the repository's sequential plain-Markdown
convention.


## Plan of Work

### Milestone 1 — Cached directory and configuration

Create `shikigami-core/src/Shikigami/Directory.hs` and expose it from
`shikigami-core/shikigami-core.cabal`. Define strict, unprefixed record fields following
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`. A file snapshot is a JSON array
whose objects contain `principal_id`, `handle`, and `lifecycle`; additional Meibo fields are
ignored. Validate that ids begin with `agent_`, handles are non-empty, and ids and
case-normalized handles are unique before publishing a snapshot.

`DirectoryHandle` distinguishes disabled from configured state. A configured handle begins
without a snapshot. `refreshDirectory` atomically replaces state only on a fully valid source
result; on failure it retains the previous valid view and returns the error. Reads never block
on file or network IO. `startDirectory` performs the mandatory initial refresh and returns
`Left` on configured cold-start failure; its refresher action logs later failures and continues
serving the last valid view.

Extend `Shikigami.App.Config`, its exact-key tests, environment binding tests, and
`docs/operations/configuration.md`. Unit tests in a new
`shikigami-core/test/Shikigami/DirectorySpec.hs` prove disabled allow, configured cold-start
unavailable, active allow, paused/deactivated skip, authoritative-id lookup, compatibility
handle lookup, unknown principal, duplicate rejection, atomic refresh, and last-known-valid
behavior.

Acceptance for this milestone is:

```bash
nix develop -c cabal test shikigami-core --test-options='-p /directory/'
```

The selected tests pass and no database is required.


### Milestone 2 — Durable load state and admission skips

Generate one new migration with `shikigami-migrate new
agent-load-state-and-run-skips`, edit only the generated SQL, and append it to the manifest.
Create `shikigami.agent_load_state` with one row per manifest path and
`shikigami.run_skips` with one idempotent row per trigger/drain refusal. Use `observed_at`, not
the obsolete plan's ambiguous `loaded_at`, because failed entries were never loaded.

Add `shikigami-core/src/Shikigami/Directory/Store.hs` with IO and transaction entry points.
`recordLoadStates` performs one transaction that upserts the complete report and removes stale
paths from the same configured manifest directory. `recordRunSkipTx` is used inside Kafka inbox
transactions; `recordRunSkip` wraps it for scheduler and PGMQ boundaries. All statements are
schema-qualified because the shared pool's search path is `kiroku`.

Extend `loadAgentsLoud` with a callback that receives the one completed report after logging
and before strict refusal. The worker, standalone scheduler, stream consumer, and event
consumer open their store, record the report through that hook, and only then select enabled
agents or refuse strict startup. A persistence error is fatal; it must not turn a failed
manifest into another invisible state.

Add pure migration inventory tests and real-Postgres store tests. The database proof queries
both tables and verifies repeat writes are idempotent.

Acceptance for this milestone is:

```bash
nix develop -c cabal test shikigami-migrations
nix develop -c cabal test shikigami-core --test-options='-p /directory store/'
```


### Milestone 3 — Trigger and drain kill switch

Thread `DirectoryHandle` from every worker composition root into `WorkerEnv`, `SchedulerEnv`,
and the consumer functions. A scheduler environment also carries the declaration principal id
for each scheduled name. Start one refresher loop only when file mode is configured; register
it as `DirectoryLoop`, include it in `superviseLoops`, and heartbeat it after each refresh
attempt. Disabled mode has no refresher loop. Standalone scheduler and consumer roles use the
same supervision rule as the combined worker.

At a schedule fire, consult the cached directory before enqueue. On any deny, insert a
`RunSkip` with stage `trigger`, detail `schedule`, and the same deterministic idempotency key
the run would have used. Only after the insert commits, arm the next tick and return the fired
event id. A failed audit insert leaves the timer retryable.

For activity and integration-event records, match declarations and consult their cached
lifecycle before `runInboxTransaction`. Pass prepared allow/deny values into the handler. The
handler enqueues allowed jobs and inserts denied skips in the same inbox transaction; the
post-commit callbacks log only committed results. An inbox duplicate performs neither action a
second time.

At PGMQ drain, find the declaration and consult before choosing agent-run versus conversation
workflow. A deny inserts stage `drain`, detail equal to the declared route, and the job's
idempotency key. Successful insert returns `Done`; transient persistence failure returns
`RetryDefault`; no Kioku session is opened on the denied path.

Extend `SchedulerSpec`, `StreamInboxSpec`, `Agent.RunJob.WorkerSpec`, health-loop tests, and
supervision tests. Use the migrated ephemeral database to prove no queue/session side effect
and one skip row.


### Milestone 4 — Sink gates and principal session attribution

Add `directory :: DirectoryHandle` along the existing grant path:
`WorkerEnv` to `AgentRunDeps`, `ConversationEnv`, `Flow.Capability.SinkEnv`, and
`Sink.Types.SinkContext`. Add `principalId :: Maybe Text` compatibly to both `SinkIntent`
copies and update `WireCompatSpec`.

At both enqueue-time implementations, consult directory before `checkGrant`. A deny produces
`SinkResult kind (SkippedLifecycle reason)` and creates neither outbox row nor pending delivery
receipt. At publish time, `Shikigami.Sink.dispatch` consults before the second grant check and
performs no HTTP call on deny. `publishTracked` records `SkippedLifecycle` as a terminal
non-send receipt and returns `PublishSucceeded`, so Keiro publishes the outbox row rather than
retrying a deliberate kill-switch refusal.

Resolve session attribution from the same directory handle in the existing `open-session`
actions for agent runs and conversations. Configured fresh runs use the resolved
`PrincipalRecord.principalId`; disabled mode uses declared principal text when present and the
name otherwise. Do not change memory scope or other Kioku identity fields.

These files are durable workflow bodies, so follow `docs/workflow-versioning.md` exactly. Do
not add a patch or edit `domain/*.keiro`; instead prove the declared body and generated files
are unchanged with `just keiro-gate`. Add compatibility tests for old `SinkIntent` and
`SinkResult` JSON, and behavior tests for paused enqueue, pause-between-enqueue-and-publish,
no downstream request, terminal receipt, and principal-valued agent-run/conversation session
rows.


### Milestone 5 — Operator reconciliation and end-to-end proof

Extend `Shikigami.Server.Command.Agents` rather than creating a second command owner. `agents
list [--json]` loads one directory snapshot and renders the union of manifest entries and agent
principals. Loaded declarations show principal id and lifecycle; declarations without a join
show `NO PRINCIPAL`; directory principals without a successfully loaded declaration show `NO
MANIFEST`; failed manifests retain their full Dhall diagnostic below the table.

Add `agents sync [--json]`. It requires the configured database, records the load report, and
backfills `shikigami.sink_grants.principal_id` for every unambiguous declaration/principal
join. It may fill a null or confirm the same id; it refuses and reports an already-populated
different id rather than overwriting identity. Missing declarations or principals are reported
as reconciliation issues, not invented or deleted.

Update `docs/operations/operator-cli.md` and configuration documentation. Run the complete
suite and the manual file-edit demonstration, then write the observed transcript into Outcomes
& Retrospective. Review the plan's decisions and discoveries and create or update local ADRs
for the cache and failure-semantics decisions that must outlive this task.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shikigami`.

Establish and repeatedly re-run the build gates:

```bash
nix develop -c cabal build all
nix develop -c cabal test all
nix develop -c just keiro-gate
```

Create the migration through the owning CLI:

```bash
DATABASE_URL=postgresql:///unused nix develop -c cabal run shikigami-migrate -- \
  new \
  --manifest shikigami-migrations/sql-migrations/manifest \
  --name 2026-08-23-00-41-28-agent-load-state-and-run-skips \
  --description 'Persist agent load state and lifecycle admission skips'
# Edit only the generated SQL; the authoring command appends its basename to the manifest.
nix develop -c cabal test shikigami-migrations
nix develop -c cabal test shikigami-migrations:shikigami-migrations-smoke
```

For manual testing, write a source outside the repository so it cannot become production
configuration accidentally:

```bash
tmp_directory_file="$(mktemp "${TMPDIR:-/tmp}/shikigami-directory.XXXXXX.json")"
printf '%s\n' '[{"principal_id":"agent_01h000000000000000heartbeat","handle":"heartbeat","lifecycle":"active"}]' >"$tmp_directory_file"
```

Run the combined worker with file mode and a five-second refresh, using the normal development
database settings:

```bash
SHIKIGAMI_DIRECTORY_MODE=file \
SHIKIGAMI_DIRECTORY_FILE_PATH="$tmp_directory_file" \
SHIKIGAMI_DIRECTORY_REFRESH_INTERVAL_SECONDS=5 \
nix develop -c cabal run shikigami-worker
```

Change `active` to `paused` in the file atomically by writing a sibling and renaming it. Within
five seconds, schedule, stream, event, drain, and sink logs for that agent report committed
skips. Change it back to `active`; new work resumes without restarting the process.

Inspect the durable evidence and reconciliation:

```bash
psql "$PG_CONNECTION_STRING" -c 'TABLE shikigami.agent_load_state'
psql "$PG_CONNECTION_STRING" -c 'SELECT agent_name, stage, detail, reason, idempotency_key FROM shikigami.run_skips ORDER BY occurred_at DESC LIMIT 10'
nix develop -c cabal run shikigami -- agents list
nix develop -c cabal run shikigami -- agents sync
```


## Validation and Acceptance

Acceptance is behavioral, not just compilation:

- Explicit disabled mode preserves the pre-plan runtime behavior and labels the operator
  inventory accordingly.
- File mode refuses startup before readiness when its first snapshot is missing, malformed,
  contains a non-agent id, or contains duplicate ids/handles.
- After one valid snapshot, a source failure keeps precisely that snapshot in service, logs
  refresh failure, and does not convert any denied principal to allowed.
- Paused and deactivated agents produce no schedule, stream, event, or drain work. Each
  committed refusal has one idempotent `run_skips` row. A schedule continues ticking while
  paused and resumes after reactivation.
- Pausing after sink enqueue but before publication sends no downstream request. The outbox
  row reaches a terminal published state only after the lifecycle non-send receipt commits.
- Failed manifests, including `agents/broken.dhall`, remain loudly logged and are now present
  in `shikigami.agent_load_state`; strict mode records them before refusing startup.
- Newly opened agent-run and conversation Kioku sessions carry the joined `agent_...` id in
  `agent_id`; memory scopes remain name-keyed for plan 54.
- `agents list` shows declared-only, principal-only, joined, disabled, and failed states;
  `agents sync` is idempotent and refuses a conflicting existing grant principal id.
- Old journaled `SinkResult` values and old outbox `SinkIntent` rows decode unchanged.
- `nix develop -c cabal test all` and `nix develop -c just keiro-gate` pass. The Keiro gate
  reports no undeclared or breaking workflow body change.


## Idempotence and Recovery

The migration is forward-only and immutable after application. Re-running the complete
pg-migrate plan reports the new entry as already applied. Corrections use a later migration,
never edits to accepted SQL.

Directory refresh publishes a complete valid snapshot atomically. A partial or malformed file
never mutates the current view. Operators should replace the source file by rename rather than
editing in place; even a torn read is only a logged failed refresh and leaves the last valid
view intact.

`recordLoadStates` upserts by manifest path and reconciles stale paths in one transaction.
`recordRunSkip` is replay-safe because all implemented trigger and drain sites have stable
idempotency keys. A write failure never becomes an allow: timer/consumer/queue ownership stays
retryable until the durable audit commits.

Sink enqueue refusal is journaled atomically with the absence of an outbox row. Publish refusal
is terminal only after the delivery receipt records the non-send. A process crash between
decision and commit retries safely through the existing journal, outbox, and receipt keys.

`agents sync` only fills null grant principal ids or verifies an equal id. A mismatch is a
reported error and leaves the row untouched. The command can be re-run after repairing either
the directory file or the declaration.


## Interfaces and Dependencies

No new package dependency is required. This plan uses `aeson`, `containers`, `hasql`,
`hasql-pool`, `hasql-transaction`, `settei`, and `time`, which are already dependencies of the
owning packages. It does not add an unreleased Meibo package.

The target public surface is:

```haskell
-- shikigami-core/src/Shikigami/Directory.hs
data Lifecycle = Active | Paused | Deactivated

data PrincipalRecord = PrincipalRecord
  { principalId :: !Text
  , handle :: !Text
  , lifecycle :: !Lifecycle
  }

data DirectorySettings
  = DirectoryDisabled
  | DirectoryFile
      { path :: !FilePath
      , refreshInterval :: !NominalDiffTime
      }

data DirectoryView
type DirectorySource = IO (Either Text DirectoryView)
data DirectoryHandle

data LifecycleDecision
  = AllowRun !(Maybe PrincipalRecord)
  | SkipRun !PrincipalRecord !Text
  | UnknownPrincipal !Text
  | DirectoryUnavailable !Text

data DirectoryRuntime = DirectoryRuntime
  { handle :: !DirectoryHandle
  , refresher :: !(Maybe (IO ()))
  }

fileDirectorySource :: FilePath -> DirectorySource
newDirectoryHandle :: DirectorySource -> IO DirectoryHandle
disabledDirectoryHandle :: DirectoryHandle
refreshDirectory :: DirectoryHandle -> IO (Either Text ())
startDirectory :: Log.Logger -> DirectorySettings -> IO (Either Text DirectoryRuntime)
consultLifecycle :: DirectoryHandle -> Maybe Text -> Text -> IO LifecycleDecision
lookupPrincipal :: DirectoryHandle -> Maybe Text -> Text -> IO (Maybe PrincipalRecord)
directoryPrincipals :: DirectoryHandle -> IO [PrincipalRecord]

-- shikigami-core/src/Shikigami/Directory/Store.hs
data SkipStage = TriggerStage | DrainStage

data RunSkip = RunSkip
  { agentName :: !Text
  , principalId :: !(Maybe Text)
  , stage :: !SkipStage
  , detail :: !Text
  , reason :: !Text
  , idempotencyKey :: !Text
  }

recordLoadStates :: Hasql.Pool.Pool -> FilePath -> AgentLoadReport -> IO (Either Text ())
recordRunSkip :: Hasql.Pool.Pool -> RunSkip -> IO (Either Text ())
recordRunSkipTx :: RunSkip -> Hasql.Transaction.Transaction ()

-- shikigami-core/src/Shikigami/Sink/Types.hs
data SinkOutcome
  = Delivered !Text
  | Enqueued !Text
  | Stubbed
  | DeniedOutcome !Text
  | SkippedLifecycle !Text
  | Failed !Text
  | PermanentFailure !Text
```

Every record follows the repository rule: direct unprefixed field names, strict fields,
`DuplicateRecordFields`, explicit deriving strategies, and Generic Lens at manipulation sites.


## Revision Notes

- 2026-08-22: Refreshed the complete plan before implementation. The revision replaces
  obsolete pre-six-package and pre-pg-migrate paths, acknowledges the now-present but
  unreleased Meibo client while preserving plan 54's ownership of that dependency, moves Kafka
  gating into the actual inbox transaction, incorporates delivery receipts and workflow
  versioning, narrows `run_skips` to admission boundaries, and expands operator/session
  acceptance to the current agent-run and conversation implementations.
