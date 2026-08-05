---
id: 23
slug: agent-lifecycle-control-with-meibo-principals
title: "Agent lifecycle control with meibo principals"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1typzbe9dtqnk49t6d5q5w"
master_plan: "docs/masterplans/4-identity-and-trust-grants-outbound-auth-and-agent-lifecycle-control.md"
---

# Agent lifecycle control with meibo principals

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan implements the accepted improvement request `docs/improvement-requests/consult-meibo-agent-lifecycle.md` (read it first; its scope decisions govern this plan). Meibo (名簿) is the platform's organizational directory (kikan contract C14): every agent is a first-class principal with an `agent_…` id, a handle, and a lifecycle of `active | paused | deactivated` — and for agents, `paused` is the portfolio-wide kill switch.

Today shikigami has none of that. There is no way to stop a deployed agent short of deleting its Dhall file and restarting every consumer process. An unparseable manifest is silently skipped at load (`loadAgents` keeps only the `Right` results — `shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs:45-49`, duplicated at `Scheduler.hs:77-80` and `ConsumeStream.hs:90-94`; `agents/broken.dhall` demonstrates the silent drop). Runs are attributed to a free-text agent name, not a principal.

After this plan, an operator can pause an agent in the directory and, within one cache refresh, every trigger fire and every sink dispatch for that agent is skipped with a durably recorded, attributable outcome — no process restarts, no file deletions; reactivating resumes it. Manifest load failures become visible, queryable state instead of silence. Kioku sessions carry the agent's `agent_…` principal id so run history joins the directory without string matching. Because meibo itself is not yet consumable (verified 2026-07-08: `mori registry show meibo --full` registers `shinzui/meibo` at `/Users/shinzui/Keikaku/bokuno/meibo-project/meibo`, but the repo contains only `docs/`, `agents/`, and mori metadata — zero Haskell packages, no service, no `meibo.v1` topic), the directory is consumed through a cached view fed by a local stub source (a JSON file), exactly the stub-first pattern this repo used for kawa (`stub-kawa`); the real meibo lookup replaces the source function later without touching any call site.

Explicitly out of scope, per the improvement request: the shikigami HTTP API, the kikan-en `checkAction` swap, and cost/model capture on sessions.


## Progress

- [ ] Milestone 1: `Shikigami.Directory` module — types, cached view, file stub source, refresher; unit tests.
- [ ] Prerequisites: plans 36/37/38, 30, and 33 complete.
- [ ] Milestone 2: pg-migrate changes for `shikigami.agent_load_state` and `shikigami.run_skips`; persist plan 20's canonical load report.
- [ ] Milestone 3: lifecycle kill switch at all trigger-fire and sink-dispatch points; fail closed before the first valid snapshot, then serve last-known valid on refresh failure; real-Postgres tests.
- [ ] Milestone 4: principal join — sessions record principal ids; extend plan 30's `shikigami agents list` and add `sync` to reconcile declared↔principal orphans and backfill `sink_grants.principal_id`.
- [ ] Final: end-to-end pause/resume demonstration transcript captured; `cabal test all` green.


## Surprises & Discoveries

- Meibo is registered in mori but has no consumable packages yet (0 packages; the repo at `/Users/shinzui/Keikaku/bokuno/meibo-project/meibo` holds only docs and agent manifests). The improvement request anticipated this ("the seam can be built earlier behind a config/stub"); this plan is therefore stub-first by design, not by accident.
  Evidence: `mori registry show meibo --full` → "Packages (0): (none)"; `ls /Users/shinzui/Keikaku/bokuno/meibo-project/meibo` → `agents docs mina.kdl mori mori.dhall`. (2026-07-08)


## Decision Log

- Decision: The directory stub source is a local JSON file selected by plan 37's typed
  `DirectorySettings`, polled into an in-memory cached view, rather than a stub HTTP server.
  Rationale: The consult must be a cache read on the hot path (IR requirement 1: "no hot path blocks on meibo synchronously"), so the runtime needs the cached-view machinery regardless of transport; a file source exercises that machinery with the least ceremony and is trivially editable mid-test (pause = edit the file). The real meibo swap replaces only the `DirectorySource` function (fetch from meibo's read API or fold the `meibo.v1` topic) behind the same `DirectoryHandle`.
  Date: 2026-07-08

- Decision: Fail closed until the first valid configured directory snapshot. After one
  successful load, a refresh error keeps serving the last-known valid view. A deliberately
  disabled directory source is a separate explicit Settei mode, not indistinguishable
  from a failed/never-loaded source.
  Rationale: "last-known" requires a known snapshot; allowing before one exists can run
  an agent whose paused/deactivated policy has never been observed.
  Date: 2026-07-22

- Decision: A configured valid snapshot that does not contain the declared principal or
  compatibility handle also denies execution (`UnknownPrincipal`); only the explicit
  `DirectoryDisabled` Settei mode bypasses lifecycle enforcement.
  Rationale: Absence is not evidence of an active principal. Treating an unknown entry as
  active would recreate the cold-start fail-open hole after every successful refresh.
  Date: 2026-07-22

- Decision: Record trigger-level skips in a new `shikigami.run_skips` table; record sink-level skips through the existing `SinkOutcome` channel by adding a `SkippedLifecycle !Text` constructor (`shikigami-core/src/Shikigami/Sink/Types.hs:42-48`).
  Rationale: A trigger-level skip happens before any run, workflow, or kioku session exists, so there is nothing to attach it to — hence a table (the IR asks for an "attributable skipped outcome"; agent name + principal id + trigger kind + reason + timestamp is exactly that, and a fleet page can query it). A sink-level skip happens where `DeniedOutcome` already flows (journaled `SinkResult`s at `Shikigami/Agent/Workflow.hs:424-425`, publish-time log at `Shikigami/Sink.hs:45`), so reusing that channel keeps recording uniform; a distinct constructor (not `DeniedOutcome` with a special reason) keeps permission denials and lifecycle skips distinguishable in journals and logs. Adding a constructor is JSON-backward-compatible: old journaled rows decode unchanged, and new rows only appear after this code ships.
  Date: 2026-07-08

- Decision: Sessions record the principal id by writing it into `StartSessionData.agentId`. A declared `identity.principal` from plan 33 is authoritative; when absent, directory lookup by declared name remains the compatibility fallback. The kioku memory scope (`agentScope`, keyed by declared name) is unchanged.
  Rationale: `kioku_sessions.agent_id` is `text` (kioku-migrations `2026-06-24-00-00-00-kioku-base.sql:37`) and `StartSessionData.agentId :: Text` (`/Users/shinzui/Keikaku/bokuno/kioku/kioku-core/src/Kioku/Session/Domain.hs:43-53`), so no cross-repo change is needed — the IR's acceptance ("a run's kioku session carries the agent principal id") is met by writing the right value. Alternative rejected: adding a dedicated `principal_id` column to kioku sessions — a cross-repo schema change the IR does not require. Memory scoping stays name-keyed because scopes are a recall namespace, not an identity claim, and re-keying them would orphan existing memories.
  Date: 2026-07-08

- Decision: Hard-depend on plan 33's `identity.principal` field and plan 30's `agents`
  command group; consume plan 20's `AgentLoadReport` for durable load state.
  Rationale: plan 20 owns traversal/reporting, plan 30 owns CLI presentation, plan 33 owns
  declared identity, and this plan owns persistence plus lifecycle semantics. This removes
  the former "whichever lands first" loader rule and the temporary name-only identity path.
  Date: 2026-07-22

- Decision: Soft-depend on plan 21 for principal keying of grants: `shikigami.sink_grants.principal_id` (the nullable column plan 21 creates) is backfilled by this plan's `shikigami agents sync`, not by a schema change here. If plan 21 has not landed when Milestone 4 starts, skip the backfill step and record it in Progress as remaining.
  Date: 2026-07-08


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The current repository begins with legacy `shikigami-core`, `shikigami-cli`,
`shikigami-migrations`, and `shikigami-api` packages. Plans 36 and 38 run first and replace
that ownership/migration model with the six-package service architecture and pg-migrate
component, manifest, complete application plan, CLI, and test support. This plan places every
new module in those assigned packages and uses the public pg-migrate test support; it adds a
numbered manifest entry rather than extending an existing migration. Everything builds inside
`nix develop` with `cabal build all` / `cabal test all`.

Terms. A "principal" is a directory entry: an `agent_…` id plus a handle (the human name, which equals the Dhall `name` field for shikigami agents) plus a lifecycle. "Lifecycle" is one of `active`, `paused`, `deactivated`; paused/deactivated agents must neither fire nor deliver. A "trigger fire" is the moment shikigami decides to enqueue a run job for an agent; a "sink dispatch" is the moment a run's output is sent to an external service. The "directory view" is an in-memory snapshot mapping handle → principal record, refreshed in the background — never queried synchronously on the hot path.

Where triggers fire (each needs the kill switch before enqueue):

- Schedule: `Shikigami.Trigger.Scheduler.scheduleFireAction` (`shikigami-core/src/Shikigami/Trigger/Scheduler.hs:92-103`) calls `enqueueScheduledRun` when a keiro timer fires; it runs inside the worker's timer loop (`Shikigami.Worker.runTimerWorker`, `Shikigami/Worker.hs:114-123`) and the standalone `shikigami scheduler` command.
- Stream: the `consume-stream` command's `onHit` (`shikigami-cli/src/Shikigami/Cli/Commands/ConsumeStream.hs:45-53`) calls `enqueueRunJob` for each matched envelope.
- Event: the `consume-events` command's `onHit` (`ConsumeStream.hs:75-86`) calls `enqueueAddressedRunWithKey`.
- Defense in depth at drain time: `Shikigami.Worker.handleRunJob` (`Shikigami/Worker.hs:132-141`) decodes each queued `RunJob` and runs the agent — a job enqueued just before a pause, or by an external producer, should also be skipped here.

Where sinks dispatch (each already hosts the C11 permission gate; the lifecycle check sits beside it): enqueue-time in `Shikigami.Agent.Workflow.buildSinkIntent` (Workflow.hs:420-440) and `prepareSinkIntent` (Workflow.hs:475-514), the duplicate `Shikigami.Flow.SinkOutbox.prepareSinkIntent` (SinkOutbox.hs:83-121), and publish-time in `Shikigami.Sink.dispatch` (Sink.hs:39-47). Plan 21 (`docs/plans/21-database-backed-sink-permission-grants.md`) threads a `GrantSource` through the containing records (`AgentRunDeps` at Workflow.hs:79-89, `SinkContext` at `Shikigami/Sink/Types.hs:29-38`, `SinkEnv` at `Shikigami/Flow/Capability.hs`, `WorkerEnv` at Worker.hs:55-63); this plan threads a `DirectoryHandle` along the identical path, so if 21 has landed, follow its field placements exactly.

Manifest loading: `Shikigami.Agent.Loader.loadAgent :: FilePath -> IO (Either LoadError AgentDecl)` (`shikigami-core/src/Shikigami/Agent/Loader.hs:22-27`) is sound — the silent drop is in the three identical CLI helpers named above, each `pure [a | Right a <- loaded]`. `agents/broken.dhall` (a manifest with a deliberate `behaviour` typo) is the standing demonstration: today `shikigami worker --agents agents` reports one fewer agent than there are `.dhall` files and says nothing about which or why.

Session attribution: `Shikigami.Agent.Workflow.openSession` (Workflow.hs:248-275) starts a kioku session with `agentId = agentDeclName decl` — the free-text name.


## Plan of Work

### Milestone 1 — the directory view

Scope: a directory module in the package assigned by plan 36 providing fail-closed
cold start and last-known-valid refresh behavior, with a file-backed stub source and
Settei configuration from plan 37.

Types and functions (see Interfaces and Dependencies for full signatures): `Lifecycle`
(`Active | Paused | Deactivated`), `PrincipalRecord {principalId, handle, lifecycle}`,
`DirectoryView` (a `Map Text PrincipalRecord` keyed by handle, plus the load timestamp),
`DirectorySource` (an `IO (Either Text DirectoryView)`), `fileDirectorySource :: FilePath ->
DirectorySource` (decode the JSON stub file), and `DirectoryHandle` (an `IORef` state that
distinguishes no valid snapshot from last-known valid). `refreshDirectory` swaps on `Right`;
on `Left`, it retains a prior valid view but remains unavailable when no prior view exists.
`startDirectoryRefresher :: DirectoryHandle -> RefreshInterval -> IO ()` is a supervised
loop using a bounded Settei duration; an unexpected exit fails its process. Consults are:

```haskell
data LifecycleDecision
  = AllowRun !(Maybe PrincipalRecord)   -- active in a valid snapshot, or explicitly disabled mode
  | SkipRun !PrincipalRecord !Text      -- paused/deactivated, with the reason text
  | UnknownPrincipal !Text              -- absent from an otherwise valid configured snapshot
  | DirectoryUnavailable !Text          -- configured source has no valid snapshot

consultLifecycle :: DirectoryHandle -> Maybe Text -> Text -> IO LifecycleDecision
lookupPrincipal  :: DirectoryHandle -> Maybe Text -> Text -> IO (Maybe PrincipalRecord)
```

The `Maybe Text` is `identity.principal` from plan 33 and is looked up first; the final
`Text` is the declared agent name used as the compatibility fallback.

The stub file format mirrors the C14 principal shape so real meibo data drops in unchanged:

```json
[
  {"principalId": "agent_01h0000000000000000000heartbeat", "handle": "heartbeat", "lifecycle": "active"},
  {"principalId": "agent_01h000000000000000digestwatcher", "handle": "digest-watcher", "lifecycle": "paused"}
]
```

An explicit `DirectoryDisabled` Settei mode preserves compatibility when directory
integration is intentionally off. Configured-but-never-loaded returns
`DirectoryUnavailable` and startup/readiness fails closed. Tests distinguish disabled,
cold-start failure, valid active/paused, and refresh failure after a good snapshot.

Acceptance: `cabal test all` green with the new group.

### Milestone 2 — recorded load state and the skips table

Scope: two small tables and persistence of plan 20's canonical load report. At the end,
`agents/broken.dhall` produces a visible failed-load row and a loud stderr line instead of
a silent skip.

Run `cabal run shikigami-migrate -- new agent-load-state-and-run-skips`, edit the
generated pg-migrate change, and update/verify the exact component manifest and complete
application plan:

```sql

-- Migration: agent-load-state-and-run-skips (improvement request: consult-meibo-agent-lifecycle)
CREATE SCHEMA IF NOT EXISTS shikigami;

-- One row per manifest file per loader pass: loaded | failed(reason).
CREATE TABLE IF NOT EXISTS shikigami.agent_load_state (
  manifest_path TEXT        NOT NULL PRIMARY KEY,
  agent_name    TEXT        NULL,              -- NULL when the manifest failed to parse
  status        TEXT        NOT NULL CHECK (status IN ('loaded','failed')),
  error         TEXT        NULL,
  loaded_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One row per skipped trigger fire (the lifecycle kill switch).
CREATE TABLE IF NOT EXISTS shikigami.run_skips (
  skip_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  agent_name   TEXT        NOT NULL,
  principal_id TEXT        NULL,
  stage        TEXT        NOT NULL CHECK (stage IN ('trigger','sink','drain')),
  detail       TEXT        NOT NULL,   -- trigger kind or sink kind
  reason       TEXT        NOT NULL,   -- e.g. 'lifecycle paused'
  idempotency_key TEXT     NULL,
  occurred_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (stage, idempotency_key)
);
CREATE INDEX IF NOT EXISTS shikigami.run_skips_agent_idx
  ON shikigami.run_skips (agent_name, occurred_at);
```

(Plan 38's manifest/application plan defines exact order; manifest position governs, not
filename timestamps.)

Load-state persistence: consume the `AgentLoadReport` returned by plan 20's
`loadAgentsLoud`. Add `Shikigami.Directory.LoadStateStore` (or a section of
`Shikigami.Directory`) with `recordLoadStates :: Hasql.Pool.Pool -> AgentLoadReport -> IO
(Either Text ())` (upsert per manifest path, schema-qualified
`shikigami.agent_load_state`) and
`recordRunSkip :: Hasql.Pool.Pool -> RunSkip -> IO (Either StoreError ())`. Insert skips with
`ON CONFLICT (stage, idempotency_key) DO NOTHING`; PostgreSQL still permits multiple rows
where the key is `NULL`. A failed durable skip write is not swallowed before queue
acknowledgement.
At the existing CLI call sites, add only `recordLoadStates` after loading; retain plan 20's
logging, summary, and strict-mode behavior and plan 33's enabled selection.

Acceptance: `just migrate` applies; `cabal run shikigami-worker -- --config
yaml:config/worker-lifecycle-dev.yaml` prints the loud failure line for `broken.dhall`;
`psql … -c "TABLE shikigami.agent_load_state"` shows a `failed` row for
`agents/broken.dhall` with the Dhall error, and `loaded` rows for the others.

### Milestone 3 — the fail-closed/last-known lifecycle kill switch

Scope: consult the cached view before every trigger fire and sink dispatch; record skips;
fail closed when a configured source has no valid snapshot and use last-known valid only
after a successful refresh. Editing the stub file pauses and resumes an agent live.

Threading: add `directory :: !DirectoryHandle` to `SchedulerEnv`
(`Shikigami/Trigger/Scheduler.hs:36-39`), `WorkerEnv` (Worker.hs:55-63), `AgentRunDeps`
(Workflow.hs:79-89), `SinkContext` (Types.hs:29-38), and `SinkEnv` (Capability.hs)—the same
placements plan 21 uses for `GrantSource`. Also pass the pool where skips must be recorded
(SchedulerEnv already has one; the consumer commands have `pool st`). Plan 37's Settei
adapter decodes `DirectoryDisabled | DirectoryFile {path, refreshInterval}` once at each
composition root. Configured commands perform an initial refresh before becoming ready and
run the refresher under their supervised loop group. `DirectoryDisabled` alone constructs a
bypass handle; a missing, malformed, or unreachable configured source is not converted to
disabled mode.

Check sites, in order:

1. `scheduleFireAction` (Scheduler.hs:92-103): before `enqueueScheduledRun`, `consultLifecycle`; on `SkipRun`, `recordRunSkip` (stage `trigger`, detail `schedule`) and — important — still `armNextRun` for the following tick and still return the fired event id, so the schedule keeps ticking while paused and resumes cleanly on unpause.
2. The two consumer `onHit`s (ConsumeStream.hs:45-53, 75-86): on `SkipRun`, log `[stream] SKIP agent=… (lifecycle paused)` and `recordRunSkip` (stage `trigger`, detail `stream`/`event`) instead of enqueueing.
3. `handleRunJob` (Worker.hs:132-141): after decoding the `RunJob`, on a lifecycle denial
   record stage `drain` with the job idempotency key and return `AckOk` only after that insert
   commits. A transient store failure returns the retry disposition from plans 17/18; the
   durable skip's uniqueness key makes replay safe. A successfully recorded paused job is
   consumed rather than retried, so pausing drains stale queued work without a retry loop.
4. Sink enqueue-time — `buildSinkIntent` (Workflow.hs:420-440), `prepareSinkIntent` (Workflow.hs:475-514), and `Flow.SinkOutbox.prepareSinkIntent` (SinkOutbox.hs:83-121): consult beside `checkGrant`; on skip produce `SinkResult kind (SkippedLifecycle reason)` with no outbox message (mirror of the denied arm at Workflow.hs:424-425).
5. Sink publish-time — `Shikigami.Sink.dispatch` (Sink.hs:39-47): consult beside the grant check; on skip log `[sink] skipped (lifecycle): …` and return `SkippedLifecycle` (like `DeniedOutcome`, `publishSinkIntent` at Workflow.hs:581-583 must treat it as non-`Failed`, completing the outbox row without delivering — extend that `case` accordingly).

Add the `SkippedLifecycle !Text` constructor to `SinkOutcome` (Types.hs:42-48) and satisfy every `case` the compiler flags.

Tests (new `LifecycleGateSpec` in the package assigned by plan 36, registered in its test
suite, using plan 38's real-Postgres support): (a) a workflow run with a paused principal
produces `SkippedLifecycle` sink results and zero outbox rows; (b) `handleRunJob` with a
paused agent returns `AckOk`, records a skip, and opens no session; (c) configured/no-snapshot
returns `DirectoryUnavailable` and neither enqueues nor dispatches, while explicit
`DirectoryDisabled` preserves compatibility; (d) a valid snapshot missing the principal
returns `UnknownPrincipal`; and (e) dispatch against a paused principal sends no request.

Acceptance: tests green; the manual pause/resume transcript under Validation works.

### Milestone 4 — principal join, session attribution, and reconciliation

Scope: runs are attributed to principal ids and the declared↔directory join is visible both ways.

Session attribution: in `openSession` (Workflow.hs:248-275), call `lookupPrincipal
(directory deps) (principal <$> identity decl) (name decl)` and set `agentId` to the
resolved principal id. A configured lifecycle mode cannot reach session creation for an
unknown principal; explicit disabled mode may fall back to the declared principal value and
then the agent name for compatibility.

Reconciliation surface: extend plan 30's `Shikigami.Operator.Agents.Command` in
`shikigami-server` and its server-owned parser:

- Extend plan 30's `shikigami agents list --config PATH`: consume the same Settei directory
  settings, load the directory view once, add principal id/lifecycle columns, and print
  directory principals with no manifest as `NO MANIFEST`. Add `agents sync` beside the
  existing `list` parser.
- `shikigami agents sync --config PATH`: additionally `recordLoadStates` and, when plan 21's
  table exists, backfill the schema-qualified `shikigami.sink_grants.principal_id` for each
  resolved principal. If that soft dependency is absent, print a notice and skip.

Tests: extend `LifecycleGateSpec` — after a run with a directory that maps the agent, the kioku session row's `agent_id` equals the principal id (query `kioku_sessions` via `Kioku.Session` as AgentWorkflowSpec does); after `sync` against a database with plan 21's seed rows, the matching `sink_grants` rows carry the principal id.

Acceptance: `shikigami agents list` output matches the format above against `agents/` plus a stub file; session rows carry `agent_…` ids.


## Concrete Steps

All from `/Users/shinzui/Keikaku/bokuno/shikigami` inside `nix develop`; database and
directory settings come from the process-compose Settei source.

```bash
nix develop
cabal run shikigami-migrate -- new agent-load-state-and-run-skips
# edit the generated file per Milestone 2
just migrate
cabal build all
cabal test all
```

Create a stub directory file for manual testing:

```bash
cat > /tmp/meibo-stub.json <<'EOF'
[
  {"principalId": "agent_01hb000000000000000heartbeat", "handle": "heartbeat", "lifecycle": "active"}
]
EOF
```

Pause/resume demonstration: use plan 37's documented Settei sources to configure the worker
with `agents` as its manifest directory and `DirectoryFile {path =
"/tmp/meibo-stub.json", refreshInterval = 5 seconds}` (plus the normal dependency settings).
The `heartbeat` schedule fires normally. Edit the file, changing `"lifecycle": "active"` to
`"lifecycle": "paused"`; within one refresh interval the worker logs skips instead of runs:

```text
[scheduler] SKIP agent=heartbeat (lifecycle paused)
```

and `psql … -c "SELECT agent_name, stage, detail, reason FROM shikigami.run_skips ORDER BY occurred_at DESC LIMIT 3"` shows the recorded rows. Edit back to `active`; firing resumes — no restart happened at any point.

Load-state demonstration:

```bash
cabal run shikigami -- agents list --config config/operator-dev.yaml
```

Expected shape (exact principal ids per your stub file):

```text
heartbeat         loaded   agent_01hb000000000000000heartbeat  active
danwa-heartbeat   loaded   NO PRINCIPAL
broken            FAILED   (agents/broken.dhall: …dhall type error…)
```


## Validation and Acceptance

Acceptance is observable: pausing stops fires/dispatch after refresh with durable skips;
reactivating resumes. Failed manifests are queryable, sessions carry principal ids, and
the operator join is exact. A configured directory that fails before its first snapshot
prevents worker readiness/execution; after a good snapshot, deleting the stub keeps
serving precisely that last-known view. `DirectorySpec`, `LifecycleGateSpec`, and the
full test suite prove disabled, cold-start failure, and post-snapshot outage separately.


## Idempotence and Recovery

Plan 38's pg-migrate manifest/application plan owns replay and verification; re-running its
`up`/`verify` path never reapplies an accepted change. `recordLoadStates` upserts by manifest
path. `recordRunSkip` must use the trigger/job idempotency key when one exists so a replay does
not create duplicate skip rows; at call sites without such an identity, appending an
observational skip is acceptable and documented. A persistence failure must not turn a deny
into an allow: retain the lifecycle decision, emit a bounded critical error, and fail the
owning loop/process if the durable audit is required for acknowledgement.

Plan 37 distinguishes explicit `DirectoryDisabled` from a configured source that has not
loaded. A configured cold-start failure and an unknown principal remain fail closed; refresh
failure after a good snapshot keeps the last-known valid view. Pausing is reversible by
editing lifecycle back to active. Queued jobs for a paused agent are consumed-and-recorded
(`AckOk`), so unpausing does not replay a stale backlog.


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 30, 33, 36-38, and 47. It is not blocked on a Meibo
client release: the file-backed `DirectorySource` and `DirectoryHandle` are the accepted first
slice and keep a live-client adapter replaceable. Use released Kioku resource/session APIs from the
plan-47 cohort; a future live Meibo source must preserve the same fail-closed/last-known-valid
contract.


## Interfaces and Dependencies

Hard dependencies: plans 36, 37, 38, 30, and 33. Plan 20 supplies the load report.
Lifecycle settings come through Settei and database changes through pg-migrate.

No new external dependencies: `aeson`, `containers`, `hasql`, `hasql-pool`, `directory`, `filepath`, and `optparse-applicative` are already dependencies of the packages touched. Meibo is deliberately not depended on (see Surprises & Discoveries); the swap point is `DirectorySource` only. Interfaces that must exist at the end (full module paths):

```haskell
-- shikigami-core : Shikigami.Directory (new)
data Lifecycle = Active | Paused | Deactivated          -- FromJSON: "active" | "paused" | "deactivated"
data PrincipalRecord = PrincipalRecord
  { principalId :: !Text, handle :: !Text, lifecycle :: !Lifecycle }
data DirectoryView                                       -- Map Text PrincipalRecord + loadedAt
type DirectorySource = IO (Either Text DirectoryView)
fileDirectorySource :: FilePath -> DirectorySource
data DirectoryHandle
newDirectoryHandle :: DirectorySource -> IO DirectoryHandle
disabledDirectoryHandle :: IO DirectoryHandle
refreshDirectory :: DirectoryHandle -> IO ()
startDirectoryRefresher :: DirectoryHandle -> RefreshInterval -> IO ()
data LifecycleDecision
  = AllowRun !(Maybe PrincipalRecord)
  | SkipRun !PrincipalRecord !Text
  | UnknownPrincipal !Text
  | DirectoryUnavailable !Text
consultLifecycle :: DirectoryHandle -> Maybe Text -> Text -> IO LifecycleDecision
lookupPrincipal :: DirectoryHandle -> Maybe Text -> Text -> IO (Maybe PrincipalRecord)
data RunSkip = RunSkip
  { agentName :: !Text, principalId :: !(Maybe Text),
    stage :: !Text, detail :: !Text, reason :: !Text,
    idempotencyKey :: !(Maybe Text) }
recordRunSkip :: Hasql.Pool.Pool -> RunSkip -> IO (Either StoreError ())
recordLoadStates :: Hasql.Pool.Pool -> AgentLoadReport -> IO (Either Text ())

-- shikigami-core : Shikigami.Sink.Types
data SinkOutcome = Delivered !Text | Stubbed | DeniedOutcome !Text
                 | SkippedLifecycle !Text | Failed !Text

-- field additions (same placement as plan 21's GrantSource threading):
-- Shikigami.Trigger.Scheduler.SchedulerEnv, Shikigami.Worker.WorkerEnv,
-- Shikigami.Agent.Workflow.AgentRunDeps, Shikigami.Sink.Types.SinkContext,
-- Shikigami.Flow.Capability.SinkEnv  each gain: directory :: !DirectoryHandle
```

Database artifacts: `shikigami.agent_load_state` and `shikigami.run_skips` (Milestone 2).
CLI artifacts: lifecycle columns and `sync` added to plan 30's `agents` command group; all
long-running commands consume plan 37's shared `DirectorySettings`. Hard dependencies: plan
30 owns that command group and plan 33 defines `identity.principal`. Plan 20's
`AgentLoadReport` is the shared loader contract. Soft dependency: plan 21 provides the
nullable `sink_grants.principal_id` backfill target. The improvement request remains the
scope authority.


## Revision Notes

- 2026-07-08: Cross-plan consistency pass after initial authoring — added the touchpoint with `docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md`. The 2026-07-22 revision supersedes the original either-order assumption.
- 2026-07-22: Made plans 30 and 33 hard predecessors, switched load-state persistence to
  plan 20's `AgentLoadReport`, and changed `agents list` from a new command to an extension
  of plan 30's command. Declared identity is available from the start, with name fallback
  only for manifests that omit the optional field.
- 2026-07-22: Added plans 36–38, replaced Codd/direct flags with pg-migrate and Settei,
  and corrected lifecycle availability to fail closed before the first valid snapshot
  with last-known-valid fallback only after successful synchronization.
