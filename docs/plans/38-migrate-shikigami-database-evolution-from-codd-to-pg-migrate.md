---
id: 38
slug: migrate-shikigami-database-evolution-from-codd-to-pg-migrate
title: "Migrate Shikigami database evolution from Codd to pg-migrate"
kind: exec-plan
created_at: 2026-07-22T20:55:26Z
master_plan: "docs/masterplans/3-correctness-and-delivery-semantics-stop-dropping-and-duplicating-work.md"
---

# Migrate Shikigami database evolution from Codd to pg-migrate

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami currently embeds timestamped Codd migrations and composes only part of its
runtime schema contract. After this change `shikigami-migrations` owns one pg-migrate
component, embeds an ordered manifest, composes the complete Kiroku, Keiro, Kioku, PGMQ,
and Shikigami plan, and exposes the fleet migration CLI and public ephemeral-database test
support.

An operator can inspect, verify, apply, and repair the same embedded plan that production
uses. An existing Codd-managed database is cut over by importing durable history into the
pg-migrate ledger without replaying DDL. Running `up` twice is visibly idempotent.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: inventory Codd files, ledgers, framework components, and exact payload mappings; create the Shikigami manifest and component.
- [ ] M2: compose and test one complete Kiroku → Keiro → Kioku → PGMQ → Shikigami migration plan and standard CLI.
- [ ] M3: implement and prove the one-time Codd history import on an existing-data database clone; strict verification passes before new SQL runs.
- [ ] M4: replace test support, Justfile, deployment, and child-plan instructions; remove Codd dependencies and variables.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Import Codd history ledger-only; never replay already-applied DDL.
  Rationale: Existing databases may contain production data and schema state. Re-executing historical actions is unsafe and does not prove equivalence.
  Date: 2026-07-22
- Decision: Shikigami owns one component and the application executable owns one complete plan.
  Rationale: Library components declare their migrations and dependencies; only the deployed application knows the total runtime composition order.
  Date: 2026-07-22
- Decision: All future migrations are append-only, numbered manifest entries.
  Rationale: Stable component/name/checksum identities make history verifiable and prevent timestamp-order or filesystem-discovery drift.
  Date: 2026-07-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

`shikigami-migrations/shikigami-migrations.cabal` currently depends on `codd`,
`codd-extras`, and `file-embed`. SQL files live under
`shikigami-migrations/sql-migrations/`; `Shikigami.Migrations` embeds them and the
`shikigami-migrate` executable runs Codd. The public `test-support` library provisions
databases with `codd-extras:ephemeral`. Plans 19, 21, and 23 currently instruct authors to
run `just new-migration` and create more timestamped Codd files; plan 31 deploys the
`CODD_*` environment surface. Those instructions are superseded by this plan.

A pg-migrate component is a named ordered set of immutable migrations. A manifest is a
checked-in ordered filename list whose exact SQL bytes are embedded at compile time. A
migration plan is a validated dependency-ordered non-empty list of components. The ledger
stores component-local names, positions, checksums, kind, and transaction mode. History
import writes evidence into that ledger without executing target migrations.

Before implementation, run `mori registry show shinzui/pg-migrate --full`, inspect the
public source and docs at the returned path, and verify the coherent released package
cohort on Hackage and upstream tags before selecting bounds. Use only public facades under
`Database.PostgreSQL.Migrate`; do not import `Internal` modules.


## Plan of Work

Milestone 1 inventories history before changing the runner. Record every file under
`shikigami-migrations/sql-migrations`, its Codd filename, applied checksum evidence if
available, owned schema objects, and whether the target native payload is byte-identical or
only state-equivalent. Locate the current Kiroku, Keiro, Kioku, and PGMQ migration components with
Mori and read their public composition APIs. Create
`shikigami-migrations/migrations/manifest` plus numbered append-only SQL files and
`Shikigami.Migrations.Component` using `embedMigrationManifest` and
`migrationComponentFromEmbeddedSql`. The component name is stable (`shikigami`) and
declares its actual component dependencies.

Use `SamePayload` only where reviewed bytes and legacy evidence prove identity. If a
legitimate old workflow cannot prove a checksum, add a read-only validator and use
`EquivalentState`; do not upgrade weak evidence. The manifest and every SQL file are
`extra-source-files`. The embedding module enables the released recompile plugin so a SQL
change forces rebuild and validation.

Milestone 2 creates `Shikigami.Migrations.Plan`. Compose the exact native components in
dependency order—Kiroku, Keiro, Kioku, PGMQ, then Shikigami—and validate the plan before opening a
connection. Update `shikigami-migrations/app/Main.hs` to mount the reusable pg-migrate CLI
commands `plan`, `list`, `check`, `status`, `verify`, `up`, `repair`, and `new`. Database
configuration comes from plan 37's Settei surface. `plan`, `list`, and local `check` work
without a live database. Production runs always apply the complete plan, never a selected
subset.

Add a migration-package test suite for manifest rules, component/plan construction,
filename and slug validation, exact embedded bytes, an idempotent second `up`, and strict
verification. Publish `shikigami-migrations:test-support` using
`pg-migrate-test-support`; its `withShikigamiMigratedDatabase` provisions an isolated
database and installs the same complete plan used by production. Core, server, and worker
tests consume this sublibrary; no production library does.

Milestone 3 implements the cutover. Use the public Codd history importer to map each legacy
filename to its native component/migration identity and evidence. On a restored clone of a
Codd-managed database containing representative rows, quiesce writers, import history,
run strict `verify`, then apply only genuinely pending native migrations. Assert that the
import does not execute target SQL and that row counts and important data checksums remain
unchanged. Record the exact runbook and JSON reports. Do not improvise the import directly
against a live database; production execution requires a backup and tested restore.

Milestone 4 updates `Justfile`, process-compose, NixOS packaging, and
`docs/operations/migrations.md`. `just migrate` invokes `shikigami-migrate --config
config/migrations-dev.yaml up`; authoring
uses `shikigami-migrate new <description>` and updates the manifest. Remove Codd packages,
`CODD_*` variables, re-embedding touches, and filesystem directory discovery. Rewrite
plans 19, 21, and 23 to add pg-migrate manifest entries and plan-aware tests. Rewrite plan
31 to deploy an explicit `plan`/`status`/`verify`/`up`/`verify` job.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`:

```bash
nix develop
cabal build shikigami-migrations
cabal test shikigami-migrations
cabal run shikigami-migrate -- plan
cabal run shikigami-migrate -- list
```

Against an ephemeral database supplied through plan 37's configuration:

```bash
cabal run shikigami-migrate -- --config config/migrations-dev.yaml status
cabal run shikigami-migrate -- --config config/migrations-dev.yaml up
cabal run shikigami-migrate -- --config config/migrations-dev.yaml verify
cabal run shikigami-migrate -- --config config/migrations-dev.yaml up
```

The second `up` reports every migration as already applied. Finish with:

```bash
cabal test all
rg -n 'codd|CODD_' shikigami-migrations Justfile process-compose.yaml docs/plans docs/operations
```

The final search may mention the historical import runbook, but no active runtime or
authoring instruction uses Codd.


## Validation and Acceptance

Acceptance requires pure plan construction, manifest checks, and all database tests to pass.
A fresh database receives every framework and service schema through one executable. A
clone with legacy Codd history imports without replaying SQL, verifies as an applied prefix,
and preserves representative data. A second `up` makes no changes. Plans 19, 21, and 23
name pg-migrate files, manifests, and test support rather than Codd scaffolding.


## Idempotence and Recovery

Manifest checking and plan construction are read-only. `up` is idempotent for applied
transactional migrations. History import is one-time and forward-only; rehearse it on a
restored clone and retain its audit report. Back up and verify restore before production,
quiesce legacy writers, and never edit either ledger manually. Recover an ambiguous
nontransactional migration only through a reviewed `repair` request with evidence.


## Interfaces and Dependencies

Use the released coherent `pg-migrate`, `pg-migrate-embed`, `pg-migrate-cli`,
`pg-migrate-import-codd`, and test-only `pg-migrate-test-support` packages. Owned modules
are `Shikigami.Migrations.Component`, `Shikigami.Migrations.Plan`, and
`Shikigami.Migrations.TestSupport`. This plan hard-precedes the new database migrations in
plans 19, 21, and 23 and the deployment work in plan 31. The migration package depends on
no Shikigami sibling production package.


Revision note (2026-07-22): Created from the portfolio conformance review to replace the
active Codd plan with the fleet pg-migrate component, plan, CLI, transition, and test model.
