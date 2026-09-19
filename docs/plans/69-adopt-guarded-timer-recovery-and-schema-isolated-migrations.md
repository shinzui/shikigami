---
id: 69
slug: adopt-guarded-timer-recovery-and-schema-isolated-migrations
title: "Adopt guarded timer recovery and schema-isolated migrations"
kind: exec-plan
created_at: 2026-09-18T16:22:03Z
intention: intention_01m2trbg5ze1dt6dfz50mxg4bq
master_plan: "docs/masterplans/12-adopt-keiro-0-17-and-applicable-runtime-haskell-and-postgresql-patterns.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-18T16:22:03Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-19T00:06:28Z
      mode: "implement"
      note: "Added guarded timer recovery, real upgrade, and schema-isolation evidence"
---

# Adopt guarded timer recovery and schema-isolated migrations

This ExecPlan is a living document governed by agents/skills/exec-plan/PLANS.md. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Update durable decisions in docs/adr/ when implementation changes them.


## Purpose / Big Picture


Make the database upgrade from Keiro 0.15 to 0.17 repeatable and safe for existing work, and ensure Shikigami's timer loop respects guarded resume ownership. Migrations must act on their intended schemas even in a host with a hostile search_path. Operators receive a concrete stop/migrate/start procedure and an explicit rollback boundary.


## Progress


- [x] (2026-09-19T00:06:28Z) Added the finite serving timer-pass boundary and public-API guarded recovery test.
- [x] (2026-09-19T00:06:28Z) Added a real exact-byte Keiro 0.15-to-0.17 upgrade fixture with durable seeded data.
- [x] (2026-09-19T00:06:28Z) Added the schema-isolation gate and corrected new-migration scaffolding.
- [x] (2026-09-19T00:06:28Z) Wrote the coordinated writer rollout and rollback procedure.
- [x] (2026-09-19T00:06:28Z) Closed all EP-4 runtime, Kiroku, migration, and PostgreSQL rows.
- [x] (2026-09-19T00:14:28Z) Proved migration 0032 ignores a colliding hostile schema and preserves the host connection path.
- [ ] Run the final clean all-Hackage qualification after EP-1 clears.


## Surprises & Discoveries


2026-09-18: The selected Keiro implementation already calls
`recoverExpiredTimerResumes` exactly once in the preamble shared by bounded timer
drains. Adding a second application sweep would duplicate locking and accounting.

2026-09-18: Authoritative 0.15 and 0.17 Keiro migration tarballs differ only by
0032 and its manifest line. Kioku 0.5.2 and 0.7 migration directories are
byte-identical, so the upgrade fixture can construct the actual old component from
the exact first 31 released payloads without vendoring duplicate SQL.

2026-09-18: One immutable application migration predates schema isolation and
mutates `search_path`. Rewriting it would falsify applied checksums. The gate names
that exact exception, scans vendored PGMQ separately, and rejects the pattern in all
new application SQL.


## Decision Log


2026-09-18: Preserve all applied migration bytes by default. Adopt timer claim recovery at the application's actual shared dispatcher; do not assume using a library helper automatically runs a complete maintenance pass. Foreground resume remains disabled unless application-specific authorization and execution ownership are implemented.

2026-09-18: Roll out migration 0032 stop-the-world across timer/workflow writers.
Old writers do not honor opaque claim tokens; rollback first disables resume and
recovers expired claims with the new dispatcher, never SQL token clearing.


## Outcomes & Retrospective


Implementation is complete against the selected release sources. The worker test
proves guarded claim recovery and fencing through the serving pass. The migration
smoke upgrades real 0.15 ledger bytes, preserves a queued job, workflow, dead timer,
rich evidence and every prior checksum, ignores a hostile-schema collision, preserves
the host path, then performs a no-op second apply. The SQL
gate and rollout procedure are executable repository artifacts. Evidence is in
`docs/evidence/keiro-0.17/ep4-coverage.md`; final completion waits on EP-1's public
Hackage solve.


## Context and Orientation


Hard prerequisite: docs/plans/66-resolve-and-adopt-the-released-keiro-0-17-dependency-cohort.md supplies supported Keiro and Kioku packages. shikigami-migrations/src/Shikigami/Migrations.hs composes Kiroku, Keiro, Kioku and Shikigami components using pg-migrate. A migration component is an ordered set of SQL files whose identities and checksums are retained in a shared ledger. verifyShikigamiMigrations is a read-only startup check; only the dedicated executable applies the plan. The test-support sublibrary creates one migrated template and an isolated clone per test.

shikigami-migrations/sql-migrations/2026-06-24-13-00-00-pgmq-schema.sql vendors a large PGMQ schema and functions. Upgrading Haskell PGMQ packages does not update this SQL. Its header still explains an old hasql-migration incompatibility; that is historical rationale, not proof the workaround remains needed. Existing functions include legacy grouped reads, but capability coverage for the newly selected clients must be verified. Do not equate the package version 0.6 with the PGMQ server version.

shikigami-workers/src/Shikigami/Trigger/Timer.hs calls drainWorkflowSleepTimers in a one-second loop with limit 100 and Scheduler.shikigamiTimerFallback. That is the serving path to inspect, not merely upstream runTimerWorker. Shikigami.Workflow.Versioning and Shikigami.Workflow.Registry own workflow options and the agent/approval/conversation inventory. Timer claims, queue visibility leases and workflow-resume leases are separate ownership mechanisms.

Keiro 0.16 introduced migration 0032 and opaque expiring tokens for foreground Dead-timer resume. Old writers do not honor the token exclusions, so additive columns do not make mixed writers safe. Normative sources are mori://shinzui/keiro-runtime-patterns/docs/keiro-dead-timer-resume, mori://shinzui/keiro-runtime-patterns/docs/keiro-runtime-assembly, mori://shinzui/keiro-runtime-patterns/docs/migrations-authoring and mori://shinzui/postgresql-jitsurei/docs/migrations-schema-qualify-migration-objects.

[ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md) requires read-only startup verification, shared resource-aware resumption, one timer dispatcher, bounded passes and 90-day terminal journal retention. [ADR 0010](../adr/0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md) protects rich evidence from destructive replay. [ADR 0027](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) is conditional; do not reuse the September 7 unused-state finding. docs/workflow-versioning.md governs any body or stored-result changes.


## Plan of Work


### Milestone 1 — Qualify the composed schema and server capabilities

Extend shikigami-migrations/test/Migrate.hs with both a genuinely fresh application and an old-to-new upgrade fixture. Build the old schema from the captured 0.15 package cohort in a disposable checkout/database, seed representative queued jobs, workflow instances, timers and rich evidence, close old connections, then apply the new full plan. Do not simulate an upgrade by deleting ledger rows from the new schema. Keep source checksums and original data for comparison. Apply the new plan twice and require no second-pass AppliedNow outcomes; pending or changed ledgers must still refuse serving startup without mutation.

Inventory every PGMQ SQL function/result column used by 0.6 clients, adapter 0.16 and the selected keiro-ops commands. Include nullable metrics fields and queue reconciliation, not just send/read. Record the server capabilities explicitly. Where missing, append a supported, schema-qualified upgrade migration to the application manifest or adopt the current upstream migration component through a documented ownership transition. Never install two components claiming the same historic objects or edit the vendored applied file. A FIFO server upgrade is required only if FIFO becomes a separately approved domain requirement.

Acceptance is successful fresh and real upgrade paths, preserved seeded rows and ledger identities, supported client operations, and repeatable verification.

### Milestone 2 — Enforce schema isolation and immutable history

Audit application SQL, nested function bodies, dynamic SQL, defaults, grants and cross-component references. Fully qualify non-temporary object names wherever PostgreSQL syntax allows. CREATE INDEX is a documented exception: qualify the parent table, then qualify the index in later operations. Prohibit migration-session SET search_path, SET LOCAL search_path, SET SCHEMA and set_config search-path mutation; distinguish a security-sensitive function-local SET clause from runner-session mutation.

Add tools/check-migration-schema-isolation.sh and a justfile recipe that checks newly authored/application-managed SQL while reporting historical/upstream exceptions with exact file and reason. It must not silently whitelist all vendored SQL. Add a composed-plan test that places colliding objects in an unrelated host schema, uses a distinctive path on one connection, runs the component between host components, and asserts intended object ownership and unchanged path. Exercise transactional mode and any actually supported nontransactional mode. The fixture may set a hostile path; migration SQL may not.

For historic defects, append corrections while preserving original bytes. If an immutable upstream migration cannot pass the hostile-path contract, record the exact upstream prerequisite and keep its applicable matrix row open; a post-hoc cleanup migration does not prove that earlier statements resolved safely. A history rewrite is possible only with newly verified unadopted-history evidence and an explicit plan/ADR decision, never as a shortcut.

### Milestone 3 — Make the serving timer loop honor claim recovery

The inspected upstream implementation already routes drainWorkflowSleepTimers through drainDueTimersWith and timerPassPreamble, which calls recoverExpiredTimerResumes once per pass. Confirm this against the selected release and preserve that path; do not add a redundant second recovery pass. Ensure the bounded operator drain reaches the same maintenance boundary. Use released APIs and never write claim columns directly. Keep ordinary sleep/schedule/approval dispatch unified. The current helper selects default timer options; review explicit attempt ceilings and stale-claim policy against the timer standard, using validated options and workflowSleepOrPmFire with the configurable drain if needed.

Add shikigami-workers/test/Shikigami/TimerRecoverySpec.hs and register it in test/Main.hs and the Cabal suite. Through public APIs, prove an expired guarded claim returns directly to Dead with reason, payload and attempt count intact; ordinary dispatch and ID-only cancellation cannot steal a claim; a replaced token fences stale completion; and scheduled ordinary timers still fire once per durable identity. Recovery must run even when ordinary stale-claim requeue is disabled. Use controllable lease-expiry fixtures or bounded polling, not long fixed sleeps.

Do not expose a new unrestricted foreground resume command. If an applicable application resume flow is selected, first decode the original payload, check fresh authorization/session availability, bound total attempts, renew the claim, and refuse success after lost ownership. Otherwise document why generic resume is unavailable while still supporting safe recovery of guarded rows.

### Milestone 4 — Publish the coordinated rollout and runtime audit

Create docs/operations/keiro-0.17-rollout.md with exact executable/config commands discovered from the pinned help output. Inventory every timer writer: worker, workflow hosts including server/one-off agents, embedded operations and any selected Kioku host. Stop/drain all old writers, apply the complete plan including 0032, deploy all upgraded writers, then enable only authorized foreground resume. Rollback first disables resume and drains/recovers guarded claims before an older writer starts. Never clear tokens or reset attempt history with SQL.

Review runtime assembly, connection defaults/observations, validated catalog registration, resumption budgets, maintenance bounds, Kiroku transactions/subscriptions/checkpoint inventory/retention and migration standards. Preserve LiveOnly/Preserve evidence and the existing journal-retention window; introduce retention leases only for real replay operations that need them. Close applicable gaps and record reasons for exclusions in the matrix. Update ADR 0038 or a new local ADR with the durable rollout and recovery decisions.


## Concrete Steps


Run from /Users/shinzui/Keikaku/bokuno/shikigami. Tests use disposable databases and PostgreSQL executables from nix develop:

```bash
cabal test shikigami-migrations-test shikigami-migrations-smoke --test-show-details=direct
cabal test shikigami-workers-test shikigami-core-postgres-test --test-show-details=direct
cabal run shikigami-migrate -- --help
cabal run shikigami -- ops --help
```

After adding the source check:

```bash
bash tools/check-migration-schema-isolation.sh
```

Do not run just migrate against the default local database during plan qualification. The smoke fixture must invoke runMigrationPlan and verifyShikigamiMigrations on its own isolated connection. Expected results are no leaked path, no object in the hostile schema, preserved baseline rows, a no-op second apply, and timer recovery without background execution of parked work.


## Validation and Acceptance


Both fresh and real 0.15-to-0.17 upgrade tests pass. Migration 0032 is applied once, checksums remain truthful, serving startup refuses incompatible ledgers, and selected PGMQ client APIs work against the installed SQL. Hostile search-path tests verify actual function bodies and object ownership, not only a lint. Guarded timer ownership is tested through the serving dispatcher and operator boundary. The rollout document names every writer and rollback precondition. Every applicable runtime/Kiroku/migration/PostgreSQL row is closed or explicitly blocks completion; an unresolved upstream migration defect is not compliant.


## Idempotence and Recovery


Repeated migration application is safe only through the full composed ledger. No applied file is edited, renamed or removed. Retain isolated baseline schema/data artifacts and rerun a failed experiment on a new database. SQL repair uses additive migrations and the supported library operations. Before actual deployment, take and verify a recoverable backup under the deployment procedure; source rollback alone cannot undo migration history or true workflow patch journals. No live deployment is performed by this planning task.


## Interfaces and Dependencies


Hard dependency: docs/plans/66-resolve-and-adopt-the-released-keiro-0-17-dependency-cohort.md. This plan owns migration composition, SQL, test fixtures, Timer.hs and database/timer operator hooks. It integrates with docs/plans/68-qualify-keiro-0-17-queue-inbox-and-delivery-semantics.md for PGMQ capabilities and docs/plans/71-qualify-the-keiro-0-17-rollout-and-close-pattern-coverage.md for rehearsal. Keep verifyShikigamiMigrations :: Text -> IO () read-only. Core must not depend on migrations. Use mori://shinzui/keiro/packages/keiro-migrations and mori://shinzui/keiro/packages/keiro-test-support, including withFreshResourceStorePrepared only when privileged preparation before application-store acquisition is actually needed.
