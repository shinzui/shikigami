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

Before plan 47, Shikigami embedded timestamped Codd migrations and composed only part of its
runtime schema contract. The delivered `shikigami-migrations` package owns one pg-migrate
component, embeds an ordered manifest, composes the complete Kiroku, Keiro, Kioku, PGMQ,
and Shikigami schema as four components (PGMQ is vendored inside Shikigami's component), and
exposes the fleet migration CLI and public ephemeral-database test support.

An operator can inspect, verify, apply, and repair the same embedded plan that production
uses. Running `up` twice is visibly idempotent.

**Scope change, 2026-08-05: the Codd history import is cancelled.** Nobody is running
shikigami yet, so there is no database whose history must be preserved. Every database this
repository creates — developer, CI, and any future deployment — starts from an empty ledger
and receives the whole plan by a fresh `up`. Codd support is removed outright rather than
migrated away from. What that leaves of this plan is recorded in Progress below; the
reasoning is in the Decision Log.

**Closure, 2026-08-26:** ADR 0032 accepts `shikigami-migrate`'s dedicated
application-owned `DATABASE_URL` boundary. The former Settei-unification remainder is
cancelled as unnecessary architecture, and this plan is complete.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: the Shikigami manifest and component exist —
      `shikigami-migrations/sql-migrations/manifest` and `Shikigami.Migrations`. Delivered by
      `docs/plans/47-upgrade-shikigami-to-the-coherent-july-2026-dependency-cohort.md`, not
      here. The Codd-file/ledger inventory half is void with M3.
- [x] M2: one complete Kiroku → Keiro → Kioku → Shikigami plan, including PGMQ in the
      Shikigami component, is composed and applied by
      the `shikigami-migrate` executable, and covered by
      `shikigami-migrations-test` (pure composition) and `shikigami-migrations-smoke`
      (ephemeral database, fresh apply, idempotent second `up`). `shikigami-migrations:test-support`
      is published and consumed by the core and workers suites. Delivered by plan 47.
      Verified 2026-08-05: 40 migrations apply from empty, a second `up` reports 40
      `already_applied`, and `migrate-status` reports `issues=0`.
- [x] ~~M3: the one-time Codd history import.~~ **Cancelled 2026-08-05** — no database needs
      it. See the Decision Log.
- [x] M4 (part): Codd is removed from the repository. No package depends on it, no SQL file
      carries a `-- codd:` directive, and no comment, `Justfile` recipe, or build-config note
      describes a Codd path. Done 2026-08-05.
- [x] (2026-08-26) M4 reconciliation: the proposed Settei unification is cancelled.
      [ADR 0032](../adr/0032-the-migration-cli-keeps-a-dedicated-configuration-boundary.md)
      accepts the dedicated `DATABASE_URL` boundary because pg-migrate leaves connection
      ownership with the embedding application and sharing `AppConfig` would create a
      package cycle or a configuration-only package.
- [x] (2026-08-26) M4 reconciliation: `just migrate` and `just migrate-status` deliberately
      pass `DATABASE_URL` to that one administrative process. No `--config` migration file
      is required or planned.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Reconciliation (2026-08-26): the assumed need for Settei unification was premise rot.
  Mori's current pg-migrate Quickstart shows the embedding application reading
  `DATABASE_URL`; `pg-migrate-cli` owns parsing, dispatch, reports, and rendering but
  deliberately does not own application connection configuration. The current wrapper is
  therefore the supported library boundary, not a temporary pre-migration adapter.

- Reconciliation (2026-08-26): breaking the Cabal cycle had three costs and no behavioral
  benefit: move configuration into a new lower-level package, duplicate a one-key Settei
  declaration, or remove production-shaped migration test support from core. ADR 0032
  rejects all three while bounding the raw read to one connection value.


## Decision Log

Record every decision made while working on the plan.

- Decision: Keep `shikigami-migrate` on the dedicated pg-migrate `DATABASE_URL` boundary
  and cancel the Settei-unification/package-restructure remainder.
  Rationale: pg-migrate explicitly assigns connection configuration to the embedding
  application, the executable consumes no other Shikigami application settings, and sharing
  `AppConfig` would create a package cycle. A new package or duplicate declaration would
  make the architecture larger without changing operator behavior. See ADR 0032.
  Date: 2026-08-26

- Decision: Cancel the Codd history import and remove Codd support outright.
  Rationale: the import exists to protect data in a database that crossed over from Codd.
  Shikigami has no users and no such database — the only one that existed was the developer
  cluster in `db/`, which was recreated from empty on 2026-08-05. Carrying an import path,
  the `pg-migrate-import-codd` dependency, and the constraints it imposed (do not rename or
  reformat any applied SQL file, because those bytes are import evidence) would be paying a
  migration cost for a migration nobody needs to make. Removing it also frees the SQL files:
  their `-- codd: in-txn` headers were inert under pg-migrate, which takes transaction mode
  from the Haskell component, and they are now gone.
  Consequence: if shikigami is ever pointed at a Codd-managed database, the answer is to
  recreate it, not to import it. That is acceptable precisely while there is nothing to lose,
  and this decision should be revisited the moment a database holds data anyone wants.
  Date: 2026-08-05

- Superseded decision (2026-07-22): Import Codd history ledger-only; never replay
  already-applied DDL. Rationale at the time: existing databases may contain production data
  and schema state. Superseded by the cancellation above — there are no such databases.
- Decision: Shikigami owns one component and the application executable owns one complete plan.
  Rationale: Library components declare their migrations and dependencies; only the deployed application knows the total runtime composition order.
  Date: 2026-07-22
- Decision: All future migrations are append-only, numbered manifest entries.
  Rationale: Stable component/name/checksum identities make history verifiable and prevent timestamp-order or filesystem-discovery drift.
  Date: 2026-07-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Complete as of 2026-08-26. Plan 47 delivered the pg-migrate component, exact-byte manifest,
complete four-component application plan (including PGMQ in the Shikigami component),
reusable CLI, and public test support. The
2026-08-05 decision cancelled history import and removed Codd because no database required a
transition. Fresh apply, idempotent second `up`, and status verification were proven against
40 migrations.

The only later remainder was configuration uniformity. ADR 0032 closes it as a deliberate
boundary: `shikigami-migrate` owns application composition around
`mori://shinzui/pg-migrate/packages/pg-migrate-cli` and reads `DATABASE_URL`; every other
Shikigami-owned application setting remains in plan 37's `AppConfig`. There is no schema,
runtime, packaging, or migration work left. Plans 31 and 46 may consume this plan as
complete.


## Context and Orientation

Historical starting point: `shikigami-migrations` depended on Codd, embedded timestamped
files, and provisioned tests through `codd-extras:ephemeral`. That state is gone. The current
package depends on `pg-migrate`, `pg-migrate-embed`, and `pg-migrate-cli`; the manifest is
`shikigami-migrations/sql-migrations/manifest`; `Shikigami.Migrations` composes the full
plan; and the public `test-support` sublibrary applies the same plan to ephemeral databases.
`shikigami-migrate` mounts pg-migrate commands and reads the application-owned
`DATABASE_URL` accepted by ADR 0032.

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
dependency order—Kiroku, Keiro, Kioku, then Shikigami with its vendored PGMQ schema—and validate the plan before opening a
connection. Update `shikigami-migrations/app/Main.hs` to mount the reusable pg-migrate CLI
commands `plan`, `list`, `check`, `status`, `verify`, `up`, `repair`, and `new`. Database
connection configuration comes from the dedicated `DATABASE_URL` boundary. `plan`, `list`, and local `check` work
without a live database. Production runs always apply the complete plan, never a selected
subset.

Add a migration-package test suite for manifest rules, component/plan construction,
filename and slug validation, exact embedded bytes, an idempotent second `up`, and strict
verification. Publish `shikigami-migrations:test-support` using
`pg-migrate-test-support`; its `withShikigamiMigratedDatabase` provisions an isolated
database and installs the same complete plan used by production. Core, server, and worker
tests consume this sublibrary; no production library does.

Milestone 3 is cancelled; see the Decision Log. A database that cannot be recreated is the
only thing that would bring it back.

Milestone 4 is complete. Codd is gone from the repository, and ADR 0032 accepts the remaining
operator shape: `shikigami-migrate` resolves `DATABASE_URL` itself because the embedding
application owns connection configuration and importing plan 37's `AppConfig` would create
the `shikigami-core` ↔ `shikigami-migrations` package cycle. `just migrate` and
`just migrate-status` keep exporting that variable to the one process. There is no
`config/migrations-dev.yaml` and no package restructure to implement.

Authoring stays as it is: add a numbered entry to
`shikigami-migrations/sql-migrations/manifest` with its SQL file. Note that the durable
migration identity is `<component>/<filename without extension>` and pg-migrate fingerprints
each migration's exact bytes, so an applied file can be neither renamed nor edited — a
correction is a new entry. `just new-migration` scaffolds this.

Plans 19, 21, 23, and 31 were already rewritten on 2026-07-22 to add pg-migrate manifest
entries, plan-aware tests, and an explicit deployment job; their remaining Codd mentions are
guardrails and revision history, not instructions.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`:

```bash
nix develop
cabal build shikigami-migrations
cabal test shikigami-migrations
cabal run shikigami-migrate -- plan
cabal run shikigami-migrate -- list
```

Against a database supplied through the dedicated migration boundary:

```bash
DATABASE_URL="$PG_CONNECTION_STRING" cabal run shikigami-migrate -- status
DATABASE_URL="$PG_CONNECTION_STRING" cabal run shikigami-migrate -- up
DATABASE_URL="$PG_CONNECTION_STRING" cabal run shikigami-migrate -- verify
DATABASE_URL="$PG_CONNECTION_STRING" cabal run shikigami-migrate -- up
```

The second `up` reports every migration as already applied. Finish with:

```bash
cabal test all
rg -n 'codd|CODD_' shikigami-migrations Justfile process-compose.yaml docs/plans docs/operations
```

That search must come back empty for `shikigami-migrations`, `Justfile`,
`process-compose.yaml`, and `docs/operations`. Matches under `docs/plans` and
`docs/masterplans` are the historical record of completed work and are expected.


## Validation and Acceptance

Acceptance requires pure plan construction, manifest checks, and all database tests to pass.
A fresh database receives every framework and service schema through one executable, and a
second `up` makes no changes. Plans 19, 21, and 23 name pg-migrate files, manifests, and test
support rather than Codd scaffolding.

All of the schema and CLI behavior above was verified on 2026-08-05 and is recorded in
Progress. The 2026-08-26 reconciliation accepts the remaining configuration shape under ADR
0032; no acceptance item remains open.


## Idempotence and Recovery

Manifest checking and plan construction are read-only. `up` is idempotent for applied
transactional migrations. There is no history import to recover from. Never edit the ledger manually; recover an
ambiguous nontransactional migration only through a reviewed `repair` request with evidence.
While shikigami has no users, the sanctioned recovery from any ledger confusion is to drop
and recreate the database — which is exactly what was done on 2026-08-05 when the developer
cluster was found carrying both a `codd.sql_migrations` and a `pgmigrate.migrations` ledger.


## Portfolio Reconciliation (2026-07-30)

This plan follows plans 36, 37, and 47. Plan 47 owns the coherent package pins and ports
migration-component imports to pg-migrate 1.1.0.0; this plan owns the historical Codd-ledger import,
complete application manifest, operational cutover, and rollback proof. The two plans' migration
changes must be integration-tested together, but Codd is removed only here.


## Portfolio Reconciliation (2026-08-05)

Plan 47 turned out to deliver M1 and M2 in full, and the 2026-08-05 cancellation removes M3.
This plan is therefore no longer a migration at all: it is one configuration change, the
Settei unification of `shikigami-migrate`.

That matters to the portfolio because
`docs/architecture/implementation-order.md` records this plan as the widest unblocker, gating
plans 19, 21, 23, 31, 35, and 51. Those plans depend on it for *a working pg-migrate authoring
path* — a manifest to add an entry to, and public test support to write a plan-aware test
against. Both exist and are proven today. **The schema-authoring gate is therefore released:
19, 21, 23, 35, and 51 may add migrations now.** What still genuinely waits on this plan is
only work that needs the migration executable to read its configuration through Settei, which
in practice is plan 31's deployment job.


## Portfolio Reconciliation (2026-08-26)

The configuration-only remainder is cancelled under ADR 0032. The current wrapper follows
pg-migrate's documented ownership split, and changing it would require a package split or a
duplicate Settei declaration without changing the schema or command behavior. This plan is
Complete. Plan 31 supplies `DATABASE_URL` to the migration job; plan 46 uses the existing
manifest and test-support surface and has no dependency on how that one value is parsed.


## Interfaces and Dependencies

Use the released coherent `pg-migrate`, `pg-migrate-embed`, `pg-migrate-cli`, and test-only
`pg-migrate-test-support` packages. `pg-migrate-import-codd` is **not** used — see the
Decision Log. The owned modules are `Shikigami.Migrations` and
`Shikigami.Migrations.TestSupport`; the separate `Shikigami.Migrations.Component` and
`Shikigami.Migrations.Plan` modules this plan once specified were never created, because plan
47 implemented the component and the plan in one module. The former schema-authoring gates
on plans 19, 21, and 23 are satisfied. Plan 31 consumes the completed migration boundary by
supplying `DATABASE_URL`; it does not wait for another configuration change. The migration
package depends on no Shikigami sibling production package.


Revision note (2026-08-05): Cancelled Milestone 3, the Codd history import, because nobody is
using shikigami and no database needs its history preserved; Codd support was removed from the
repository outright instead. Marked M1 and M2 complete — plan 47 delivered them — and recorded
that this plan's only remaining implementation work is the Settei unification of
`shikigami-migrate`. Added a Portfolio Reconciliation noting that the schema-authoring gate on
plans 19, 21, 23, 35, and 51 is released, and corrected the module names, which never matched
what was built.

Revision note (2026-07-22): Created from the portfolio conformance review to replace the
active Codd plan with the fleet pg-migrate component, plan, CLI, transition, and test model.

Revision note (2026-08-26): Accepted the dedicated pg-migrate `DATABASE_URL` boundary under
ADR 0032, cancelled the configuration-only package restructure, and marked M4 and the plan
complete. Replaced the stale `--config config/migrations-dev.yaml` examples with the actual
operator contract and released plans 31 and 46 from the former bookkeeping gate.
