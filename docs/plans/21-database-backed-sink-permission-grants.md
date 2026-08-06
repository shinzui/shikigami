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

- [x] Prerequisites: plans 36/37 complete; plan 38's schema-authoring path complete and proven
      (its remaining Settei work does not gate schema authoring — see plan 38's 2026-08-05
      Portfolio Reconciliation). Confirmed 2026-08-06.
- [x] Milestone 1: `shikigami.sink_grants` pg-migrate change added to the manifest, applied,
      verified, and seeded with the five current defaults. Done 2026-08-06 —
      `shikigami-migrations/sql-migrations/2026-08-06-04-02-23-sink-grants.sql`, nine seed rows,
      41/41 `already_applied` on re-run, `migrate-status` `issues=0`, and
      `shikigami-migrations-smoke` green (it applies the whole plan to a fresh ephemeral
      database, so the change is proved from empty as well as incrementally).
- [x] Milestone 2: `GrantSource` introduced; all four gate call sites read it; the worker boots
      `DbGrants` over the store pool; existing tests pass with the static source. Done
      2026-08-06 — `cabal build all --enable-tests` and `cabal test all` green (157 core + 64
      across the other suites), and no `checkGrant` call remains without a source.
- [x] Milestone 3: `shikigami grants list|grant|revoke` implemented in `shikigami-server` and
      manually verified against the dev database. Done 2026-08-06 — transcript in Outcomes.
      Note the command takes configuration the same way its siblings do, so the plan's
      `--config config/operator-dev.yaml` is optional rather than required; the dev shell
      already supplies `database.connection_string`.
- [x] Milestone 4: real-Postgres tests for the DB gate, seed data, paging, and
      revocation-between-enqueue-and-publish. Done 2026-08-06 — `Shikigami.GrantStoreSpec`
      (11 cases) plus one case in `Shikigami.AgentWorkflowSpec`; `cabal test all` green with
      169 core tests, up from 157.


## Surprises & Discoveries

**The authoring command in this plan does not exist.** Milestone 1 and Concrete Steps say
`cabal run shikigami-migrate -- new sink-grants`. The `shikigami-migrate` executable exposes the
`pg-migrate-cli` verbs (`plan`, `list`, `check`, `status`, `verify`, `up`, `repair`), but
scaffolding a new migration in this repository is a `Justfile` recipe:

```bash
nix develop -c just new-migration sink-grants
```

Note it takes a **positional** argument; `just new-migration name=sink-grants` fails the recipe's
own slug validation. The recipe writes the timestamped file and appends it to
`shikigami-migrations/sql-migrations/manifest` in one step, so there is no separate "add its
identity to the manifest" action to perform.

**`GrantSource` cannot live in `Shikigami.Sink.Permission`.** The plan's Interfaces section puts
it there, but `checkGrant`'s database arm needs `Shikigami.Sink.GrantStore`, and `GrantStore`
needs `SinkKind` and `sinkKindText` from `Permission` — a module cycle GHC rejects. Resolved by
splitting on the IO boundary instead: `Permission` keeps the pure vocabulary (`SinkKind`,
`AgentIdentity`, `Denied`, `sinkKindText`, `defaultGrantTable`, `checkGrantStatic`) and knows
nothing about a database; `GrantStore` owns `GrantSource`, `checkGrant`, and all SQL. That is a
better layering than the plan described — the pure decision stays callable without a pool — and
it is recorded as a decision below.

**Re-exporting the whole store from `Shikigami.Sink` does not compile.** `GrantRow` and
`GrantCursor` both have an `agentName` field, which is ambiguous against `AgentIdentity`'s in
every module importing `Shikigami.Sink`. Only `GrantSource(..)` and `checkGrant` are
re-exported; the row and paging types are imported directly by the CLI and tests.

**`SinkEnv` had to lose its `Eq`/`Show` instances.** `Shikigami.Flow.Capability.SinkEnv` derived
both, and `GrantSource` carries a `Hasql.Pool.Pool`, which has neither. Nothing in the tree used
those instances (checked), so they were dropped rather than hand-written around the new field.

**`grants` is a subcommand group, not three top-level commands.** The plan says "register
`grants list|grant|revoke` in the server-owned dispatcher" without saying which shape. A nested
`subparser` was chosen so the C11 surface stays one entry in `shikigami --help` rather than three
scattered ones. This changed `Shikigami.Server.CommandSpec`'s "the six administrative commands
are present" assertion to seven.

**The scaffold's default header is wrong for this migration.** `just new-migration` seeds every
new file with `SET search_path TO kiroku, pg_catalog;` and a comment about kizashi read-model
tables. That is right for a table the runtime reads unqualified, and wrong here: `sink_grants`
lives in its own `shikigami` schema and every statement is schema-qualified. The header was
replaced rather than kept.


## Decision Log

- Decision: Key grants by `agent_name` text now, with a nullable `principal_id` column reserved for the verified meibo principal id.
  Rationale: `AgentIdentity` today is just the agent-name `Text` copied from the `RunJob` payload (`shikigami-core/src/Shikigami/Sink/Permission.hs:35`) — it is spoofable and unverified. Verifying identity is plan 23's scope; adding the column now means plan 23 can re-key grants by populating a column instead of migrating the table shape. See `docs/initial-spec.md:947-948` (Open Question 6: the grant table is eventually keyed by the verified `sub`).
  Date: 2026-07-08

- Decision: The gate runs twice per sink (once when the sink intent is enqueued to the outbox, once when the outbox publisher delivers it). Keep both: the enqueue-time check is authoritative (it decides the journaled `SinkResult` and whether an outbox row exists at all), and the publish-time check revalidates. A revocation landing between the two skips delivery.
  Rationale: The enqueue-time check happens inside the durable workflow and its result is journaled (replayed runs must not re-decide). The publish-time check is nearly free once grants are in the database and closes the window where an operator revokes a grant while intents are still queued. The journaled `SinkResult` for such a sink will still read `Delivered "outbox:…"` (the enqueue-time verdict); the late denial is visible as the `[sink] skipped (denied)` stderr line from `shikigami-core/src/Shikigami/Sink.hs:45` and the outbox row completes without delivering. Making the journal reflect late denials is out of scope (it would require rewriting journaled step results).
  Date: 2026-07-08

- Decision: On a database error during a grant lookup, the gate fails closed (the sink is denied with the error in the reason text).
  Rationale: C11 is a trust boundary; delivering to an external service when we cannot prove a grant exists is the failure mode the gate exists to prevent. Plan 23 likewise fails closed until its first valid lifecycle snapshot, then serves the last-known valid snapshot during refresh outages.
  Date: 2026-07-08

- Decision: Model the injectable seam as a small sum type `GrantSource = StaticGrants (Map Text (Set SinkKind)) | DbGrants Pool` with `checkGrant :: GrantSource -> AgentIdentity -> SinkKind -> IO (Either Denied ())`, rather than threading a bare function value.
  Rationale: There are four gate call sites (see Context) plus several construction sites for the dependency records; a named sum keeps construction at process boot obvious, keeps the pure decision logic (`checkGrantStatic`) available for unit tests exactly as the current stub is, and is trivially replaceable later. The existing tests in `shikigami-core/test/Main.hs` (the "denied: skipped and recorded" cases) keep working by injecting `StaticGrants defaultGrantTable`.
  Date: 2026-07-08

- Decision: Put `GrantSource` and `checkGrant` in `Shikigami.Sink.GrantStore`, not in
  `Shikigami.Sink.Permission` as the Interfaces section says.
  Rationale: a module cycle, and a better boundary. `Permission` is now pure vocabulary with no
  database dependency at all, so `checkGrantStatic` remains a plain function tests call without
  a pool; `GrantStore` owns every effectful thing. `Shikigami.Sink` re-exports `GrantSource` and
  `checkGrant` so the four gate call sites need one import and nothing downstream changed.
  Date: 2026-08-06

- Decision: Seed the migration with exactly the five agents from `defaultGrantTable` and nothing more. Grant the proof agents (e.g. `digest-watcher`) at runtime via the new CLI.
  Rationale: The migration should be behavior-preserving; granting `digest-watcher` interactively is itself the demonstration that runtime grants work (see Validation).
  Date: 2026-07-08


## Outcomes & Retrospective

### Complete 2026-08-06

The C11 gate reads `shikigami.sink_grants`. A grant or revocation takes effect on the running
worker's next dispatch, with no rebuild and no restart, which is the whole point of the plan.

The end-to-end demonstration, against the dev database:

```text
$ shikigami grants list | grep digest-watcher
(no row — denied)
$ shikigami grants grant digest-watcher KawaDigest --by nadeem
granted digest-watcher KawaDigest
$ shikigami grants list --limit 200 | grep digest-watcher
granted  digest-watcher  KawaDigest  by=nadeem at=2026-08-06T04:25:51.668404Z
$ shikigami grants revoke digest-watcher KawaDigest --by nadeem
revoked digest-watcher KawaDigest
$ shikigami grants list --limit 200 | grep digest-watcher
revoked  digest-watcher  KawaDigest  by=nadeem at=2026-08-06T04:25:51.775325Z
```

Tests: `cabal test all` green — 169 in `shikigami-core-test` (up from 157), plus 21 workers,
20 server, 15 api, 3 client, 3+2 migrations.

**The test worth naming** is `a revocation between enqueue and publish delivers nothing`, which
proves the two-phase gate the Decision Log argued for: the run enqueues an outbox row while the
grant holds, the grant is revoked, the publisher runs, and the kawa stub receives nothing. It was
checked for vacuity — removing the revocation and asserting the stub receives **one** delivery
also passes, so the zero-delivery assertion is measuring the revocation and not an inert fixture.

**What changed from the plan.** Three structural deviations, each recorded in Surprises &
Discoveries and the Decision Log: `GrantSource`/`checkGrant` live in `Shikigami.Sink.GrantStore`
rather than `Permission` (the plan's placement is a module cycle); only those two names are
re-exported from `Shikigami.Sink` (the row types' `agentName` field collides with
`AgentIdentity`'s); and `grants` is a subcommand group rather than three top-level commands.
`SinkEnv` also lost unused `Eq`/`Show` instances it could no longer derive.

**What this plan did not do.** The journaled `SinkResult` for a late-denied sink still reads
`Delivered "outbox:…"` — the enqueue-time verdict — as the Decision Log said it would. Making
the journal reflect late denials would mean rewriting journaled step results, which is out of
scope here and belongs with the delivery-truth work in
`docs/plans/19-sink-delivery-truth-and-downstream-idempotency.md`.

**Lesson.** The plan's Interfaces section specified module placement that could not compile.
That is not a criticism of the plan so much as a note for the next one: a plan can name a
signature confidently, but where a type lives is constrained by the import graph, and the graph
is only visible from inside the build.


## Context and Orientation

Repository layout: this is a Haskell cabal multi-package repo. `shikigami-core` holds the runtime library, `shikigami-cli` the `shikigami` executable (subcommand parser in `shikigami-cli/src/Shikigami/Cli.hs`, one module per subcommand under `shikigami-cli/src/Shikigami/Cli/Commands/`), `shikigami-migrations` the pg-migrate SQL migrations plus a test-support sublibrary, and `shikigami-api` the shared wire types. All build and test commands run inside the nix dev shell: `nix develop` from the repo root, then `cabal build all` / `cabal test all`.

Terms. A "sink" is one delivery target declared on an agent (the `Sink` type in `shikigami-api`, variants `KawaDigest`, `KizashiSignal`, `ReiAction`, `DanwaConversation`). A "sink kind" is the coarse permission category for a sink — the `SinkKind` enum in `shikigami-core/src/Shikigami/Sink/Permission.hs:25-32` with five values: `SKawaDigest`, `SKizashiSignal`, `SReiAction`, `SDanwaConversation`, and `SChannelEgress` (line 30 — reserved for a future channel-egress sink; `docs/plans/32-channel-egress-sink-through-kanmon.md` will consume it, so the grant table must accept it from day one). `sinkKindText` (Permission.hs:43-49) renders the kinds as the exact strings `KawaDigest`, `KizashiSignal`, `ReiAction`, `DanwaConversation`, `ChannelEgress` — these strings become the `sink_kind` column values. A "grant" is the statement "agent X may use sink kind K".

The gate today. `checkGrant :: AgentIdentity -> SinkKind -> IO (Either Denied ())` (Permission.hs:65-71) is a pure `Map.lookup` into the compiled-in `defaultGrantTable` (Permission.hs:53-61), which grants: `heartbeat` → all four real kinds; `danwa-heartbeat` → `SDanwaConversation`; `triage-note` → `SKizashiSignal`+`SReiAction`; `stalled-intention` and `at-risk-customer` → `SKizashiSignal`. `AgentIdentity` (Permission.hs:35) is a newtype over the agent-name `Text` taken from the `RunJob` queue payload — nothing verifies it.

Where the gate is called — there are four call sites, in two phases:

1. Enqueue time (inside the durable keiro workflow, deciding whether a sink intent goes to the transactional outbox at all):
   - `buildSinkIntent` inside `enqueueSinkIntents`, `shikigami-core/src/Shikigami/Agent/Workflow.hs:423` (denial produces `SinkResult kind (DeniedOutcome reason)` with no outbox message, lines 424-425).
   - `prepareSinkIntent`, same file, line 493 (denial handling lines 494-498). Called by `Shikigami.Agent.Conversation.prepareConversationReplySinkIntent` (Conversation.hs:399).
   - A near-duplicate `prepareSinkIntent` in `shikigami-core/src/Shikigami/Flow/SinkOutbox.hs:101`, reached from the Flow behavior DSL via `enqueueSinkIntentStep` (SinkOutbox.hs:50-61, called from `Shikigami/Flow/Capability.hs:124`). (`docs/plans/27-consolidate-sink-intent-and-run-lifecycle-machinery.md` plans to merge these duplicates; do not merge them here, just thread the same source through both.)
2. Publish time: `Shikigami.Sink.dispatch` (`shikigami-core/src/Shikigami/Sink.hs:39-47`) re-checks the grant (line 42) before routing to the per-sink handler; a denial logs `[sink] skipped (denied): …` to stderr (line 45) and returns `DeniedOutcome`. `dispatch` is invoked by the outbox publisher via `publishSinkIntent` (Workflow.hs:561-583), which maps any non-`Failed` outcome — including `DeniedOutcome` — to `PublishSucceeded` (lines 581-583), so a denied publish completes the outbox row without delivering. This denial-recording behavior must not change.

Migrations. Shikigami's pg-migrate component, exact-byte manifest, complete application
plan, CLI, and public test support all exist today (delivered by plan 47; plan 38 records
them). This plan contributes one forward-only grant change through that interface — a new
numbered entry in `shikigami-migrations/sql-migrations/manifest` with its SQL file — and does
not stand up a second runner. Runtime SQL remains schema-qualified
as `shikigami.sink_grants`.

Database access follows plan 36's package ownership. Runtime and CLI composition roots
receive validated database settings through plan 37's Settei config; command modules do
not call `getEnv`/`lookupEnv`.


## Plan of Work

The work is four milestones. Each is independently verifiable; 2 depends on 1 (the table must exist for the DB-backed source to read), 3 and 4 depend on 2.

### Milestone 1 — the grant table migration with seed data

Scope: create the `shikigami` schema and the `shikigami.sink_grants` table, seeded with rows equivalent to `defaultGrantTable`. At the end, `just migrate` applies cleanly to a fresh and to an existing database, and `psql` shows nine seed rows.

Run `cabal run shikigami-migrate -- new sink-grants`, edit the generated pg-migrate
change, and add its exact identity/checksum to the component manifest and complete plan:

```sql

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

The sink-kind strings must match `sinkKindText` exactly. Apply and verify with the
plan-38 `shikigami-migrate plan|up|verify` workflow.

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
    listGrants,    -- Pool -> GrantPageRequest -> IO (Either Text GrantPage)
    upsertGrant,   -- Pool -> Text -> SinkKind -> Maybe Text -> IO (Either Text ())
    revokeGrant,   -- Pool -> Text -> SinkKind -> Maybe Text -> IO (Either Text ())
  )
where
```

`lookupGrant` executes `SELECT granted FROM shikigami.sink_grants WHERE agent_name = $1 AND sink_kind = $2` via `Hasql.Pool.use pool (Hasql.Session.statement …)` with `Hasql.Statement.Statement` and the `rowMaybe` decoder (mirror the statement style used elsewhere in the repo; the table name must stay schema-qualified because the pool's `search_path` is `kiroku`). `upsertGrant` is `INSERT … (agent_name, sink_kind, granted, granted_by, granted_at, updated_at) VALUES ($1,$2,TRUE,$3,now(),now()) ON CONFLICT (agent_name, sink_kind) DO UPDATE SET granted = TRUE, granted_by = EXCLUDED.granted_by, granted_at = now(), revoked_by = NULL, revoked_at = NULL, updated_at = now()`. `revokeGrant` is `UPDATE shikigami.sink_grants SET granted = FALSE, revoked_by = $3, revoked_at = now(), updated_at = now() WHERE agent_name = $1 AND sink_kind = $2` (revoking a non-existent grant is a no-op that the CLI reports). `GrantRow` carries agent name, principal id (Maybe), sink kind text, granted flag, and the audit columns. `listGrants` is server-side keyset pagination ordered by `(agent_name, sink_kind)`, accepts a validated `PageSize` from 1 through 200 plus an optional opaque cursor, fetches `size + 1`, and returns at most `size` rows plus the next cursor. It never loads the complete table.

Thread the source. Compilation errors after the signature change enumerate every site; concretely:

- `Shikigami.Sink.Types.SinkContext` gains a field `grants :: !GrantSource` (SinkContext is never serialized, so a non-JSON field is fine). `Shikigami.Sink.dispatch` (Sink.hs:42) becomes `checkGrant (grants ctx) (identity ctx) kind`.
- `Shikigami.Agent.Workflow.AgentRunDeps` gains `grants :: !GrantSource`. `buildSinkIntent` (Workflow.hs:420-440) and `prepareSinkIntent` (Workflow.hs:475-514) take the source as an argument (enqueueSinkIntents and enqueueSinkIntentStep pass it down; `enqueueSinkIntentStep`'s exported signature gains a leading `GrantSource` parameter). `publishSinkIntent` (Workflow.hs:561-583) puts `grants = grants deps` into the `SinkContext` it builds.
- `Shikigami.Flow.SinkOutbox.prepareSinkIntent` (SinkOutbox.hs:83-…) and `enqueueSinkIntentStep` (SinkOutbox.hs:50-61) gain the same parameter; `Shikigami.Flow.Capability.SinkEnv` gains a `grants :: !GrantSource` field and `runSink` passes it through (Capability.hs:124). The `SinkEnv` construction in `runFlowBehavior` (Workflow.hs:316-322) forwards `grants deps`.
- `Shikigami.Agent.Conversation`: `prepareConversationReplySinkIntent` (Conversation.hs:392-…) gains the parameter; `ConversationEnv` gains a `grants` field; construction sites are `Shikigami.Worker` (Worker.hs:90-97 and 148-155) and any CLI command that builds one (grep `ConversationEnv {`).
- Boot: `Shikigami.Worker.WorkerEnv` gains `grants :: !GrantSource`; `agentRunDeps`
  forwards it. The worker and agent-run composition components in `shikigami-workers` build
  `DbGrants (StoreConnection.pool st)` inside the shared store bracket. Do the same in every
  other `AgentRunDeps`/`WorkerEnv` construction site (`rg 'AgentRunDeps\s*\{'` plus the test helpers).
- Tests: `testDeps` in `shikigami-core/test/Shikigami/AgentWorkflowSpec.hs` and `ctxFor` in `shikigami-core/test/Main.hs` inject `StaticGrants defaultGrantTable`, preserving the existing "heartbeat allowed / intruder denied" assertions unchanged.

Acceptance: `cabal build all` and `cabal test all` pass; `grep -rn "checkGrant" shikigami-core/src` shows no remaining call that does not pass a `GrantSource`.

### Milestone 3 — the `grants` CLI

Scope: a new `shikigami grants` subcommand group. At the end, list/grant/revoke work against the dev database.

Add the grants command as a direct administrative executable component in
`shikigami-server`, as assigned by plan 36. It receives
validated database settings from plan 37's Settei composition root and calls the grant
store through the existing pool; no command reads the environment directly. Parse the
sink-kind argument against the five canonical strings and print the audit trail.

Register `grants list|grant|revoke` in the server-owned dispatcher. `grants list` accepts
`--limit` and `--after`, validates before opening the pool, prints the next opaque cursor, and
never exposes raw cursor internals as positional database fields.

Acceptance: the transcript under Validation and Acceptance.

### Milestone 4 — real-Postgres tests

Scope: prove the DB gate beyond compilation. Add `shikigami-core/test/Shikigami/GrantStoreSpec.hs` (register its `tests :: TestTree` in `shikigami-core/test/Main.hs`'s `testGroup "shikigami"` list and in the test-suite's `other-modules`). Using `withShikigamiMigratedDatabase` + `withStore` (the exact pattern at AgentWorkflowSpec.hs:51-56), assert:

1. Seed data: `checkGrant (DbGrants pool) (AgentIdentity "heartbeat") SKawaDigest` is `Right ()`; `… (AgentIdentity "intruder") SKawaDigest` is `Left (Denied …)`; `… (AgentIdentity "danwa-heartbeat") SKizashiSignal` is `Left (Denied …)` (granted one kind, asking another).
2. Runtime grant: after `upsertGrant pool "digest-watcher" SKawaDigest (Just "test")`, the same check flips to `Right ()`; after `revokeGrant …`, it flips back to `Left`, and a bounded `listGrants` page shows the row with `granted = False` and a `revoked_at`. Seed more than one page and prove traversal has no gaps or duplicates.
3. Revocation between enqueue and publish: run a full agent workflow via `runAgentRunWorkflow` with `grants = DbGrants pool` for an agent whose sink is granted (reuse AgentWorkflowSpec's `testDeps`/`job` fixtures, adapted); assert one outbox row exists (`Keiro.Outbox.listOutbox` as at AgentWorkflowSpec.hs:60); then `revokeGrant` and drive the publisher (`publishClaimedOutbox (AgentWorkflow.publishSinkIntent deps) …` as `Shikigami.Worker.runOutboxPublisher` does, Worker.hs:103-112) against a stub sink server (the `testWithApplication` + `stubKizashiApp` pattern in test/Main.hs); assert the stub received zero requests and the publish outcome succeeded (row completed, nothing delivered).

Acceptance: `cabal test all` green; the new group visible in the tasty output.


## Concrete Steps

All commands from the repo root `/Users/shinzui/Keikaku/bokuno/shikigami`, inside `nix develop`. The dev Postgres comes from `process-compose` (`process-compose.yaml` starts postgres and runs `just create-database`); with it running, `PGHOST`/`PGDATABASE` are set by the dev shell.

```bash
nix develop
cabal run shikigami-migrate -- new sink-grants
# edit the pg-migrate change and update/verify the manifest and complete plan
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

CLI smoke test (uses the same checked Settei source as the server-owned administrative
dispatcher; the file supplies `database.connection_string`):

```bash
cabal run shikigami -- grants list --config config/operator-dev.yaml
cabal run shikigami -- grants grant digest-watcher KawaDigest --by nadeem --config config/operator-dev.yaml
cabal run shikigami -- grants revoke digest-watcher KawaDigest --by nadeem --config config/operator-dev.yaml
```


## Validation and Acceptance

Beyond the milestone acceptances above, the end-to-end demonstration is: a sink permission changes at runtime with no rebuild.

1. Terminal A: `cabal run shikigami -- stub-kawa --config config/stub-kawa-dev.yaml`.
2. Terminal B: start `cabal run shikigami-worker -- --config config/worker-grants-dev.yaml`. The checked file supplies `database.connection_string`, `agents.directory`, the Kawa stub URL through `sinks.kawa.base_url`, and any deliberately unreachable unused sink URLs.
3. Terminal C: enqueue a run for the proof agent through the server-owned command: `cabal run shikigami -- enqueue-run digest-watcher --payload '{}' --config config/operator-dev.yaml` (adjust to the proof agent's expected payload; any agent with a `KawaDigest` sink works). Because `digest-watcher` has no grant row, the worker logs a denial (the `DeniedOutcome` reason contains `has no grant for KawaDigest`) and stub-kawa logs nothing.
4. Run `cabal run shikigami -- grants grant digest-watcher KawaDigest --by nadeem --config config/operator-dev.yaml`, enqueue again: stub-kawa now logs `[stub-kawa] accepted source=shinzui/shikigami …` — the grant took effect without touching the worker process.
5. `grants revoke`, enqueue again: back to a recorded denial.

Automated acceptance: `cabal test all` passes, including the new `GrantStoreSpec` group (seed rows honored, grant/revoke round-trip, revocation between enqueue and publish delivers nothing). The pre-existing dispatch tests in `shikigami-core/test/Main.hs` ("denied: skipped and recorded, no POST" etc.) still pass unchanged apart from injecting `StaticGrants defaultGrantTable` — proving the pure seam survived.


## Idempotence and Recovery

The change is forward-only and plan 38 verifies the applied manifest prefix/checksum.
Never edit an applied change; add a new manifest entry. Seed writes and grant commands
are idempotent. Deployments run the pg-migrate verification/startup gate before new code;
without the table, grant lookups fail closed and loudly.


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 36-38 and 47. Add its schema through the canonical
pg-migrate component/application plan and resolve operational settings through Settei. The
nullable principal seam remains intentionally compatible with the later lifecycle join.


## Interfaces and Dependencies

Hard dependencies: plans 36, 37, and 38. The schema is managed only by pg-migrate and
the CLI receives database configuration through Settei.

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
data GrantCursor = GrantCursor {agentName :: !Text, sinkKind :: !Text}
newtype PageSize = PageSize Word16 -- private constructor; smart decoder accepts 1..200
data GrantPageRequest = GrantPageRequest {size :: !PageSize, after :: !(Maybe GrantCursor)}
data GrantPage = GrantPage {items :: ![GrantRow], next :: !(Maybe GrantCursor)}
listGrants  :: Hasql.Pool.Pool -> GrantPageRequest -> IO (Either Text GrantPage)
upsertGrant :: Hasql.Pool.Pool -> Text -> SinkKind -> Maybe Text -> IO (Either Text ())
revokeGrant :: Hasql.Pool.Pool -> Text -> SinkKind -> Maybe Text -> IO (Either Text ())

-- shikigami-core : Shikigami.Sink.Types
data SinkContext = SinkContext { …existing fields…, grants :: !GrantSource }

-- shikigami-core : Shikigami.Agent.Workflow
data AgentRunDeps = AgentRunDeps { …existing fields…, grants :: !GrantSource }

-- shikigami-core : Shikigami.Flow.Capability
data SinkEnv = SinkEnv { …existing fields…, grants :: !GrantSource }
```

Database artifact: table `shikigami.sink_grants` as in Milestone 1 (primary key `(agent_name, sink_kind)`, nullable `principal_id` reserved for `docs/plans/23-agent-lifecycle-control-with-meibo-principals.md`, `sink_kind` CHECK-constrained to the five `sinkKindText` strings including `ChannelEgress` for `docs/plans/32-channel-egress-sink-through-kanmon.md`). Command artifact: `shikigami grants list|grant|revoke` in the grants vertical of `shikigami-server`.


## Revision Notes

- 2026-07-22: Rebased package/config ownership on plans 36/37 and replaced every Codd
  authoring/deployment instruction with plan 38's pg-migrate component, manifest,
  complete plan, CLI, verification, and test-support workflow.
