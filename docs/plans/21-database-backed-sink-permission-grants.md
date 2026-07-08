---
id: 21
slug: database-backed-sink-permission-grants
title: "Database-backed sink permission grants"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1typzbe9dtqnk49t6d5q5w"
master_plan: "docs/masterplans/4-identity-and-trust-grants-outbound-auth-and-agent-lifecycle-control.md"
---

# Database-backed sink permission grants

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami is a runtime that executes declared agents: each agent is a Dhall manifest (in `agents/`) naming a trigger (when to run), a behavior (what to compute), and one or more sinks (where to deliver the output — a kawa digest, a kizashi signal, a rei action, or a danwa conversation message). The architecture contract C11 (see `docs/initial-spec.md`, "Permission gate (C11)", lines 645-657) requires every sink dispatch to pass an explicit per-agent-per-sink permission check, so that a misbehaving or compromised agent cannot write to services it was never trusted with.

Today that permission gate is a five-entry allow-list compiled into the binary: `defaultGrantTable` in `shikigami-core/src/Shikigami/Sink/Permission.hs` (lines 53-61). Granting a new agent a sink — or revoking one — means editing Haskell source and recompiling every deployed process. The proof agents under `agents/proof/` (for example `digest-watcher`) are not in the list at all, so their sinks are silently denied on every run.

After this plan, grants live in a Postgres table (`shikigami.sink_grants`), managed at runtime with a new CLI surface:

```bash
shikigami grants list
shikigami grants grant digest-watcher KawaDigest --by nadeem
shikigami grants revoke heartbeat KizashiSignal --by nadeem
```

A grant or revocation takes effect on the next sink dispatch with no rebuild and no process restart. The current five compiled-in defaults are migrated as seed rows, so existing behavior is unchanged on upgrade. Denied sinks are still recorded and never crash a run, exactly as today. The table carries a nullable `principal_id` column so that when agent identity becomes a verified meibo principal (delivered by `docs/plans/23-agent-lifecycle-control-with-meibo-principals.md`), grants can be re-keyed without a schema change.


## Progress

- [ ] Milestone 1: `shikigami.sink_grants` migration written, applied, and seeded with the five current defaults.
- [ ] Milestone 2: `GrantSource` introduced; all four gate call sites read it; worker boots a DB-backed source; existing tests pass with the static source.
- [ ] Milestone 3: `shikigami grants list|grant|revoke` CLI implemented and manually verified.
- [ ] Milestone 4: real-Postgres tests for the DB gate, seed data, and revocation-between-enqueue-and-publish; full `cabal test all` green.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Key grants by `agent_name` text now, with a nullable `principal_id` column reserved for the verified meibo principal id.
  Rationale: `AgentIdentity` today is just the agent-name `Text` copied from the `RunJob` payload (`shikigami-core/src/Shikigami/Sink/Permission.hs:35`) — it is spoofable and unverified. Verifying identity is plan 23's scope; adding the column now means plan 23 can re-key grants by populating a column instead of migrating the table shape. See `docs/initial-spec.md:947-948` (Open Question 6: the grant table is eventually keyed by the verified `sub`).
  Date: 2026-07-08

- Decision: The gate runs twice per sink (once when the sink intent is enqueued to the outbox, once when the outbox publisher delivers it). Keep both: the enqueue-time check is authoritative (it decides the journaled `SinkResult` and whether an outbox row exists at all), and the publish-time check revalidates. A revocation landing between the two skips delivery.
  Rationale: The enqueue-time check happens inside the durable workflow and its result is journaled (replayed runs must not re-decide). The publish-time check is nearly free once grants are in the database and closes the window where an operator revokes a grant while intents are still queued. The journaled `SinkResult` for such a sink will still read `Delivered "outbox:…"` (the enqueue-time verdict); the late denial is visible as the `[sink] skipped (denied)` stderr line from `shikigami-core/src/Shikigami/Sink.hs:45` and the outbox row completes without delivering. Making the journal reflect late denials is out of scope (it would require rewriting journaled step results).
  Date: 2026-07-08

- Decision: On a database error during a grant lookup, the gate fails closed (the sink is denied with the error in the reason text).
  Rationale: C11 is a trust boundary; delivering to an external service when we cannot prove a grant exists is the failure mode the gate exists to prevent. Contrast with the meibo lifecycle gate (plan 23), which fails open per the improvement request — lifecycle is an operational kill switch, not a trust boundary.
  Date: 2026-07-08

- Decision: Model the injectable seam as a small sum type `GrantSource = StaticGrants (Map Text (Set SinkKind)) | DbGrants Pool` with `checkGrant :: GrantSource -> AgentIdentity -> SinkKind -> IO (Either Denied ())`, rather than threading a bare function value.
  Rationale: There are four gate call sites (see Context) plus several construction sites for the dependency records; a named sum keeps construction at process boot obvious, keeps the pure decision logic (`checkGrantStatic`) available for unit tests exactly as the current stub is, and is trivially replaceable later. The existing tests in `shikigami-core/test/Main.hs` (the "denied: skipped and recorded" cases) keep working by injecting `StaticGrants defaultGrantTable`.
  Date: 2026-07-08

- Decision: Seed the migration with exactly the five agents from `defaultGrantTable` and nothing more. Grant the proof agents (e.g. `digest-watcher`) at runtime via the new CLI.
  Rationale: The migration should be behavior-preserving; granting `digest-watcher` interactively is itself the demonstration that runtime grants work (see Validation).
  Date: 2026-07-08


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Repository layout: this is a Haskell cabal multi-package repo. `shikigami-core` holds the runtime library, `shikigami-cli` the `shikigami` executable (subcommand parser in `shikigami-cli/src/Shikigami/Cli.hs`, one module per subcommand under `shikigami-cli/src/Shikigami/Cli/Commands/`), `shikigami-migrations` the codd-managed SQL migrations plus a test-support sublibrary, and `shikigami-api` the shared wire types. All build and test commands run inside the nix dev shell: `nix develop` from the repo root, then `cabal build all` / `cabal test all`.

Terms. A "sink" is one delivery target declared on an agent (the `Sink` type in `shikigami-api`, variants `KawaDigest`, `KizashiSignal`, `ReiAction`, `DanwaConversation`). A "sink kind" is the coarse permission category for a sink — the `SinkKind` enum in `shikigami-core/src/Shikigami/Sink/Permission.hs:25-32` with five values: `SKawaDigest`, `SKizashiSignal`, `SReiAction`, `SDanwaConversation`, and `SChannelEgress` (line 30 — reserved for a future channel-egress sink; `docs/plans/32-channel-egress-sink-through-kanmon.md` will consume it, so the grant table must accept it from day one). `sinkKindText` (Permission.hs:43-49) renders the kinds as the exact strings `KawaDigest`, `KizashiSignal`, `ReiAction`, `DanwaConversation`, `ChannelEgress` — these strings become the `sink_kind` column values. A "grant" is the statement "agent X may use sink kind K".

The gate today. `checkGrant :: AgentIdentity -> SinkKind -> IO (Either Denied ())` (Permission.hs:65-71) is a pure `Map.lookup` into the compiled-in `defaultGrantTable` (Permission.hs:53-61), which grants: `heartbeat` → all four real kinds; `danwa-heartbeat` → `SDanwaConversation`; `triage-note` → `SKizashiSignal`+`SReiAction`; `stalled-intention` and `at-risk-customer` → `SKizashiSignal`. `AgentIdentity` (Permission.hs:35) is a newtype over the agent-name `Text` taken from the `RunJob` queue payload — nothing verifies it.

Where the gate is called — there are four call sites, in two phases:

1. Enqueue time (inside the durable keiro workflow, deciding whether a sink intent goes to the transactional outbox at all):
   - `buildSinkIntent` inside `enqueueSinkIntents`, `shikigami-core/src/Shikigami/Agent/Workflow.hs:423` (denial produces `SinkResult kind (DeniedOutcome reason)` with no outbox message, lines 424-425).
   - `prepareSinkIntent`, same file, line 493 (denial handling lines 494-498). Called by `Shikigami.Agent.Conversation.prepareConversationReplySinkIntent` (Conversation.hs:399).
   - A near-duplicate `prepareSinkIntent` in `shikigami-core/src/Shikigami/Flow/SinkOutbox.hs:101`, reached from the Flow behavior DSL via `enqueueSinkIntentStep` (SinkOutbox.hs:50-61, called from `Shikigami/Flow/Capability.hs:124`). (`docs/plans/27-consolidate-sink-intent-and-run-lifecycle-machinery.md` plans to merge these duplicates; do not merge them here, just thread the same source through both.)
2. Publish time: `Shikigami.Sink.dispatch` (`shikigami-core/src/Shikigami/Sink.hs:39-47`) re-checks the grant (line 42) before routing to the per-sink handler; a denial logs `[sink] skipped (denied): …` to stderr (line 45) and returns `DeniedOutcome`. `dispatch` is invoked by the outbox publisher via `publishSinkIntent` (Workflow.hs:561-583), which maps any non-`Failed` outcome — including `DeniedOutcome` — to `PublishSucceeded` (lines 581-583), so a denied publish completes the outbox row without delivering. This denial-recording behavior must not change.

Migrations. Shikigami's own SQL lives in `shikigami-migrations/sql-migrations/` (currently two files: `2026-06-24-12-00-00-shikigami-fired.sql` and `2026-06-24-13-00-00-pgmq-schema.sql`); the rest of the schema arrives by composing the kioku migration set (which itself composes kiroku and keiro) — see `shikigami-migrations/src/Shikigami/Migrations.hs:29-33`. Migration files are embedded into the `shikigami-migrate` binary at compile time by a Template Haskell `embedDir` splice (Migrations.hs:46). Because GHC only tracks files that existed at the last compile, the `just migrate` recipe (Justfile lines 29-37) touches `shikigami-migrations/shikigami-migrations.cabal` first to force re-embedding — always create migrations with `just new-migration <slug>` and apply with `just migrate`, never by hand. The `just new-migration` template pins `SET search_path TO kiroku, pg_catalog;` because most shikigami tables live in the `kiroku` schema; this migration instead creates and uses a dedicated `shikigami` schema (replace the template's `search_path` line as shown below). The test-support helper `withShikigamiMigratedDatabase` (`shikigami-migrations/test-support/Shikigami/Migrations/TestSupport.hs:12-19`) already lists `shikigami` among the schemas it manages, so no test-support change is needed. Note that the application's connection pool (kiroku-store) sets `search_path` to `kiroku`, so all runtime SQL against the new table must schema-qualify it as `shikigami.sink_grants`.

Database access idiom. `shikigami-core` already depends on `hasql`, `hasql-pool`, and `hasql-transaction` (shikigami-core.cabal). The runtime obtains a `Hasql.Pool.Pool` from the kiroku store (`Kiroku.Store.Connection.withStore` … `pool st` — see `shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs:31-35` and `Shikigami.Trigger.Enqueue.enqueueRunJob` for the `Pool.use` pattern). CLI commands read the connection string from the `PG_CONNECTION_STRING` environment variable (Worker.hs:28).


## Plan of Work

The work is four milestones. Each is independently verifiable; 2 depends on 1 (the table must exist for the DB-backed source to read), 3 and 4 depend on 2.

### Milestone 1 — the grant table migration with seed data

Scope: create the `shikigami` schema and the `shikigami.sink_grants` table, seeded with rows equivalent to `defaultGrantTable`. At the end, `just migrate` applies cleanly to a fresh and to an existing database, and `psql` shows nine seed rows.

Run `just new-migration sink-grants` at the repo root; it prints the created file path (`shikigami-migrations/sql-migrations/<UTC timestamp>-sink-grants.sql`). Replace the generated body (keeping the `-- codd: in-txn` first line) with:

```sql
-- codd: in-txn

-- Migration: sink-grants
-- The C11 per-agent-per-sink grant table. One row per (agent, sink kind); a row
-- with granted = TRUE allows the sink, granted = FALSE records a revocation
-- (kept for audit), no row denies. principal_id is reserved for the verified
-- meibo principal id (plan 23) and is nullable until then.
CREATE SCHEMA IF NOT EXISTS shikigami;

CREATE TABLE IF NOT EXISTS shikigami.sink_grants (
  agent_name   TEXT        NOT NULL,
  principal_id TEXT        NULL,
  sink_kind    TEXT        NOT NULL
    CHECK (sink_kind IN ('KawaDigest','KizashiSignal','ReiAction','DanwaConversation','ChannelEgress')),
  granted      BOOLEAN     NOT NULL DEFAULT TRUE,
  granted_by   TEXT        NULL,
  granted_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_by   TEXT        NULL,
  revoked_at   TIMESTAMPTZ NULL,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (agent_name, sink_kind)
);

-- Seed: the five agents from the compiled-in defaultGrantTable
-- (shikigami-core/src/Shikigami/Sink/Permission.hs), behavior-preserving.
INSERT INTO shikigami.sink_grants (agent_name, sink_kind, granted_by) VALUES
  ('heartbeat',         'KawaDigest',        'seed:defaultGrantTable'),
  ('heartbeat',         'KizashiSignal',     'seed:defaultGrantTable'),
  ('heartbeat',         'ReiAction',         'seed:defaultGrantTable'),
  ('heartbeat',         'DanwaConversation', 'seed:defaultGrantTable'),
  ('danwa-heartbeat',   'DanwaConversation', 'seed:defaultGrantTable'),
  ('triage-note',       'KizashiSignal',     'seed:defaultGrantTable'),
  ('triage-note',       'ReiAction',         'seed:defaultGrantTable'),
  ('stalled-intention', 'KizashiSignal',     'seed:defaultGrantTable'),
  ('at-risk-customer',  'KizashiSignal',     'seed:defaultGrantTable')
ON CONFLICT (agent_name, sink_kind) DO NOTHING;
```

The sink-kind strings must match `sinkKindText` (Permission.hs:43-49) exactly. Apply with `just migrate` (idempotent; codd records applied files by name and skips them on re-run).

Acceptance: `psql -h "$PGHOST" -d "$PGDATABASE" -c "TABLE shikigami.sink_grants"` shows nine rows, all `granted = t`.

### Milestone 2 — `GrantSource` and rewiring the four gate sites

Scope: replace the global `checkGrant` with a source-parameterized one and thread a `GrantSource` from process boot to every gate site. At the end, `cabal build all` succeeds, `cabal test all` passes (tests inject the static source), and a worker booted against a migrated database consults the table.

In `shikigami-core/src/Shikigami/Sink/Permission.hs`:

- Keep `SinkKind`, `AgentIdentity`, `Denied`, `sinkKindText`, and `defaultGrantTable` unchanged.
- Add `data GrantSource = StaticGrants !(Map Text (Set SinkKind)) | DbGrants !Hasql.Pool.Pool` (import `Hasql.Pool` qualified; this adds no new cabal dependency — `hasql-pool` is already a `shikigami-core` dependency).
- Extract the current lookup body as the pure seam `checkGrantStatic :: Map Text (Set SinkKind) -> AgentIdentity -> SinkKind -> Either Denied ()` (the exact `Map.lookup`/`Set.member` logic from lines 66-71 today, minus the `pure`).
- Change `checkGrant` to `checkGrant :: GrantSource -> AgentIdentity -> SinkKind -> IO (Either Denied ())`. The `StaticGrants` arm is `pure . checkGrantStatic table`. The `DbGrants pool` arm runs the query below and maps: `Just True` → `Right ()`; `Just False` → `Left (Denied ("agent '" <> nm <> "' grant for " <> sinkKindText kind <> " is revoked"))`; `Nothing` → `Left (Denied ("agent '" <> nm <> "' has no grant for " <> sinkKindText kind))`; a `Pool.UsageError` → `Left (Denied ("grant lookup failed (denying): " <> …))` (fail closed, per the Decision Log).

Put the SQL in a new module `shikigami-core/src/Shikigami/Sink/GrantStore.hs` (add it to the library's `exposed-modules` in `shikigami-core/shikigami-core.cabal`) so the CLI can reuse it:

```haskell
module Shikigami.Sink.GrantStore
  ( GrantRow (..),
    lookupGrant,   -- Pool -> Text -> SinkKind -> IO (Either Text (Maybe Bool))
    listGrants,    -- Pool -> IO (Either Text [GrantRow])
    upsertGrant,   -- Pool -> Text -> SinkKind -> Maybe Text -> IO (Either Text ())
    revokeGrant,   -- Pool -> Text -> SinkKind -> Maybe Text -> IO (Either Text ())
  )
where
```

`lookupGrant` executes `SELECT granted FROM shikigami.sink_grants WHERE agent_name = $1 AND sink_kind = $2` via `Hasql.Pool.use pool (Hasql.Session.statement …)` with `Hasql.Statement.Statement` and the `rowMaybe` decoder (mirror the statement style used elsewhere in the repo; the table name must stay schema-qualified because the pool's `search_path` is `kiroku`). `upsertGrant` is `INSERT … (agent_name, sink_kind, granted, granted_by, granted_at, updated_at) VALUES ($1,$2,TRUE,$3,now(),now()) ON CONFLICT (agent_name, sink_kind) DO UPDATE SET granted = TRUE, granted_by = EXCLUDED.granted_by, granted_at = now(), revoked_by = NULL, revoked_at = NULL, updated_at = now()`. `revokeGrant` is `UPDATE shikigami.sink_grants SET granted = FALSE, revoked_by = $3, revoked_at = now(), updated_at = now() WHERE agent_name = $1 AND sink_kind = $2` (revoking a non-existent grant is a no-op that the CLI reports). `GrantRow` carries agent name, principal id (Maybe), sink kind text, granted flag, and the audit columns for `listGrants` (ordered by agent_name, sink_kind).

Thread the source. Compilation errors after the signature change enumerate every site; concretely:

- `Shikigami.Sink.Types.SinkContext` gains a field `grants :: !GrantSource` (SinkContext is never serialized, so a non-JSON field is fine). `Shikigami.Sink.dispatch` (Sink.hs:42) becomes `checkGrant (grants ctx) (identity ctx) kind`.
- `Shikigami.Agent.Workflow.AgentRunDeps` gains `grants :: !GrantSource`. `buildSinkIntent` (Workflow.hs:420-440) and `prepareSinkIntent` (Workflow.hs:475-514) take the source as an argument (enqueueSinkIntents and enqueueSinkIntentStep pass it down; `enqueueSinkIntentStep`'s exported signature gains a leading `GrantSource` parameter). `publishSinkIntent` (Workflow.hs:561-583) puts `grants = grants deps` into the `SinkContext` it builds.
- `Shikigami.Flow.SinkOutbox.prepareSinkIntent` (SinkOutbox.hs:83-…) and `enqueueSinkIntentStep` (SinkOutbox.hs:50-61) gain the same parameter; `Shikigami.Flow.Capability.SinkEnv` gains a `grants :: !GrantSource` field and `runSink` passes it through (Capability.hs:124). The `SinkEnv` construction in `runFlowBehavior` (Workflow.hs:316-322) forwards `grants deps`.
- `Shikigami.Agent.Conversation`: `prepareConversationReplySinkIntent` (Conversation.hs:392-…) gains the parameter; `ConversationEnv` gains a `grants` field; construction sites are `Shikigami.Worker` (Worker.hs:90-97 and 148-155) and any CLI command that builds one (grep `ConversationEnv {`).
- Boot: `Shikigami.Worker.WorkerEnv` gains `grants :: !GrantSource`; `agentRunDeps` (Worker.hs:194-206) forwards it. `Shikigami.Cli.Commands.Worker.runWorkerCmd` builds `DbGrants (StoreConnection.pool st)` inside the `withStore` block (Worker.hs:31-42). Do the same in every other `AgentRunDeps`/`WorkerEnv` construction site (grep `AgentRunDeps {` — at least `Shikigami/Cli/Commands/AgentRun.hs` and the test helpers).
- Tests: `testDeps` in `shikigami-core/test/Shikigami/AgentWorkflowSpec.hs` and `ctxFor` in `shikigami-core/test/Main.hs` inject `StaticGrants defaultGrantTable`, preserving the existing "heartbeat allowed / intruder denied" assertions unchanged.

Acceptance: `cabal build all` and `cabal test all` pass; `grep -rn "checkGrant" shikigami-core/src` shows no remaining call that does not pass a `GrantSource`.

### Milestone 3 — the `grants` CLI

Scope: a new `shikigami grants` subcommand group. At the end, list/grant/revoke work against the dev database.

Add `shikigami-cli/src/Shikigami/Cli/Commands/Grants.hs` with `runGrantsList :: IO ()`, `runGrantsGrant :: Text -> Text -> Maybe Text -> IO ()`, `runGrantsRevoke :: Text -> Text -> Maybe Text -> IO ()`. Each reads `PG_CONNECTION_STRING` via `getEnv` (the Worker.hs:28 idiom), opens a store with `Kiroku.Store.Connection.withStore (defaultConnectionSettings connStr)`, and calls the corresponding `Shikigami.Sink.GrantStore` function with `pool st`. Parse the sink-kind argument by matching the five `sinkKindText` strings (reject anything else with the valid list in the error). `list` prints one line per row: agent name, sink kind, `granted`/`revoked`, principal id if present, and the audit trail (`granted_by`/`granted_at` or `revoked_by`/`revoked_at`).

Wire it into `shikigami-cli/src/Shikigami/Cli.hs`: extend the `Command` sum with `GrantsList | GrantsGrant Text Text (Maybe Text) | GrantsRevoke Text Text (Maybe Text)`, and add a `command "grants" (info (subparser …))` group with `list`, `grant AGENT SINK_KIND [--by WHO]`, and `revoke AGENT SINK_KIND [--by WHO]` following the existing parser style.

Acceptance: the transcript under Validation and Acceptance.

### Milestone 4 — real-Postgres tests

Scope: prove the DB gate beyond compilation. Add `shikigami-core/test/Shikigami/GrantStoreSpec.hs` (register its `tests :: TestTree` in `shikigami-core/test/Main.hs`'s `testGroup "shikigami"` list and in the test-suite's `other-modules`). Using `withShikigamiMigratedDatabase` + `withStore` (the exact pattern at AgentWorkflowSpec.hs:51-56), assert:

1. Seed data: `checkGrant (DbGrants pool) (AgentIdentity "heartbeat") SKawaDigest` is `Right ()`; `… (AgentIdentity "intruder") SKawaDigest` is `Left (Denied …)`; `… (AgentIdentity "danwa-heartbeat") SKizashiSignal` is `Left (Denied …)` (granted one kind, asking another).
2. Runtime grant: after `upsertGrant pool "digest-watcher" SKawaDigest (Just "test")`, the same check flips to `Right ()`; after `revokeGrant …`, it flips back to `Left`, and `listGrants` shows the row with `granted = False` and a `revoked_at`.
3. Revocation between enqueue and publish: run a full agent workflow via `runAgentRunWorkflow` with `grants = DbGrants pool` for an agent whose sink is granted (reuse AgentWorkflowSpec's `testDeps`/`job` fixtures, adapted); assert one outbox row exists (`Keiro.Outbox.listOutbox` as at AgentWorkflowSpec.hs:60); then `revokeGrant` and drive the publisher (`publishClaimedOutbox (AgentWorkflow.publishSinkIntent deps) …` as `Shikigami.Worker.runOutboxPublisher` does, Worker.hs:103-112) against a stub sink server (the `testWithApplication` + `stubKizashiApp` pattern in test/Main.hs); assert the stub received zero requests and the publish outcome succeeded (row completed, nothing delivered).

Acceptance: `cabal test all` green; the new group visible in the tasty output.


## Concrete Steps

All commands from the repo root `/Users/shinzui/Keikaku/bokuno/shikigami`, inside `nix develop`. The dev Postgres comes from `process-compose` (`process-compose.yaml` starts postgres and runs `just create-database`); with it running, `PGHOST`/`PGDATABASE` are set by the dev shell.

```bash
nix develop
just new-migration sink-grants
# edit shikigami-migrations/sql-migrations/<ts>-sink-grants.sql per Milestone 1
just migrate
psql -h "$PGHOST" -d "$PGDATABASE" -c "SELECT agent_name, sink_kind, granted FROM shikigami.sink_grants ORDER BY 1,2"
```

Expected tail of the psql output:

```text
    agent_name     |     sink_kind     | granted
-------------------+-------------------+---------
 at-risk-customer  | KizashiSignal     | t
 danwa-heartbeat   | DanwaConversation | t
 heartbeat         | DanwaConversation | t
 heartbeat         | KawaDigest        | t
 heartbeat         | KizashiSignal     | t
 heartbeat         | ReiAction         | t
 stalled-intention | KizashiSignal     | t
 triage-note       | KizashiSignal     | t
 triage-note       | ReiAction         | t
(9 rows)
```

Then implement Milestones 2-4 and iterate with:

```bash
cabal build all
cabal test all
```

CLI smoke test (requires `PG_CONNECTION_STRING`, e.g. `export PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)"`):

```bash
cabal run shikigami -- grants list
cabal run shikigami -- grants grant digest-watcher KawaDigest --by nadeem
cabal run shikigami -- grants revoke digest-watcher KawaDigest --by nadeem
```


## Validation and Acceptance

Beyond the milestone acceptances above, the end-to-end demonstration is: a sink permission changes at runtime with no rebuild.

1. Terminal A: `cabal run shikigami -- stub-kawa --port 8088`.
2. Terminal B: start the worker: `cabal run shikigami -- worker --agents agents/proof --kawa-url http://localhost:8088 --kizashi-url http://localhost:1 --danwa-url http://localhost:1 --danwa-agent part_test` (env: `PG_CONNECTION_STRING` as above).
3. Terminal C: enqueue a run for the proof agent: `cabal run shikigami -- enqueue-run digest-watcher --payload '{}'` (adjust to the proof agent's expected payload; any agent with a `KawaDigest` sink works). Because `digest-watcher` has no grant row, the worker logs a denial (the `DeniedOutcome` reason contains `has no grant for KawaDigest`) and stub-kawa logs nothing.
4. `cabal run shikigami -- grants grant digest-watcher KawaDigest --by nadeem`, enqueue again: stub-kawa now logs `[stub-kawa] accepted source=shinzui/shikigami …` — the grant took effect without touching the worker process.
5. `grants revoke`, enqueue again: back to a recorded denial.

Automated acceptance: `cabal test all` passes, including the new `GrantStoreSpec` group (seed rows honored, grant/revoke round-trip, revocation between enqueue and publish delivers nothing). The pre-existing dispatch tests in `shikigami-core/test/Main.hs` ("denied: skipped and recorded, no POST" etc.) still pass unchanged apart from injecting `StaticGrants defaultGrantTable` — proving the pure seam survived.


## Idempotence and Recovery

The migration is idempotent DDL (`IF NOT EXISTS`, `ON CONFLICT DO NOTHING` seeds) and codd skips already-applied files, so `just migrate` can be re-run freely. Never edit an applied migration file (codd keys by filename); to change the schema later, add a new migration. `upsertGrant`/`revokeGrant` are idempotent upserts/updates; repeating a CLI command converges to the same row state. If Milestone 2 is merged before Milestone 1's migration is applied to a given database, every grant lookup fails closed (all sinks denied with `grant lookup failed`) — safe but loud; apply `just migrate` first in any environment. Rollback of the whole feature is reverting the Haskell changes; the table can remain (it is additive and unreferenced by anything else).


## Interfaces and Dependencies

No new external dependencies: `hasql`, `hasql-pool`, `hasql-transaction`, `containers`, and `optparse-applicative` are already depended on by the relevant packages. New/changed interfaces that must exist at the end:

```haskell
-- shikigami-core : Shikigami.Sink.Permission
data GrantSource = StaticGrants !(Map Text (Set SinkKind)) | DbGrants !Hasql.Pool.Pool
checkGrantStatic :: Map Text (Set SinkKind) -> AgentIdentity -> SinkKind -> Either Denied ()
checkGrant :: GrantSource -> AgentIdentity -> SinkKind -> IO (Either Denied ())
defaultGrantTable :: Map Text (Set SinkKind)   -- unchanged; now seed/test data only

-- shikigami-core : Shikigami.Sink.GrantStore (new module)
data GrantRow = GrantRow
  { agentName :: !Text, principalId :: !(Maybe Text), sinkKind :: !Text,
    granted :: !Bool, grantedBy :: !(Maybe Text), grantedAt :: !UTCTime,
    revokedBy :: !(Maybe Text), revokedAt :: !(Maybe UTCTime) }
lookupGrant :: Hasql.Pool.Pool -> Text -> SinkKind -> IO (Either Text (Maybe Bool))
listGrants  :: Hasql.Pool.Pool -> IO (Either Text [GrantRow])
upsertGrant :: Hasql.Pool.Pool -> Text -> SinkKind -> Maybe Text -> IO (Either Text ())
revokeGrant :: Hasql.Pool.Pool -> Text -> SinkKind -> Maybe Text -> IO (Either Text ())

-- shikigami-core : Shikigami.Sink.Types
data SinkContext = SinkContext { …existing fields…, grants :: !GrantSource }

-- shikigami-core : Shikigami.Agent.Workflow
data AgentRunDeps = AgentRunDeps { …existing fields…, grants :: !GrantSource }

-- shikigami-core : Shikigami.Flow.Capability
data SinkEnv = SinkEnv { …existing fields…, grants :: !GrantSource }
```

Database artifact: table `shikigami.sink_grants` as in Milestone 1 (primary key `(agent_name, sink_kind)`, nullable `principal_id` reserved for `docs/plans/23-agent-lifecycle-control-with-meibo-principals.md`, `sink_kind` CHECK-constrained to the five `sinkKindText` strings including `ChannelEgress` for `docs/plans/32-channel-egress-sink-through-kanmon.md`). CLI artifact: `shikigami grants list|grant|revoke` in `shikigami-cli/src/Shikigami/Cli.hs` + `Shikigami/Cli/Commands/Grants.hs`.
