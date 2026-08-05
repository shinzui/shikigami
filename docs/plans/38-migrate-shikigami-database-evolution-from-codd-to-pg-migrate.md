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
uses. Running `up` twice is visibly idempotent.

**Scope change, 2026-08-05: the Codd history import is cancelled.** Nobody is running
shikigami yet, so there is no database whose history must be preserved. Every database this
repository creates — developer, CI, and any future deployment — starts from an empty ledger
and receives the whole plan by a fresh `up`. Codd support is removed outright rather than
migrated away from. What that leaves of this plan is recorded in Progress below; the
reasoning is in the Decision Log.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: the Shikigami manifest and component exist —
      `shikigami-migrations/sql-migrations/manifest` and `Shikigami.Migrations`. Delivered by
      `docs/plans/47-upgrade-shikigami-to-the-coherent-july-2026-dependency-cohort.md`, not
      here. The Codd-file/ledger inventory half is void with M3.
- [x] M2: one complete Kiroku → Keiro → Kioku → PGMQ → Shikigami plan is composed, applied by
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
- [ ] M4 (remaining): unify `shikigami-migrate` on plan 37's Settei surface. It still resolves
      `DATABASE_URL` itself, blocked by the Cabal package cycle described in plan 37 and
      reassigned here. This is now the only implementation work this plan has left.
- [ ] M4 (remaining): `just migrate` still invokes the executable with a `DATABASE_URL`
      environment variable rather than `--config`; it follows the Settei item above.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

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

Milestone 3 is cancelled; see the Decision Log. A database that cannot be recreated is the
only thing that would bring it back.

Milestone 4 is what remains. Codd itself is already gone from the repository — no package
depends on it, and no file describes a Codd path. Two things are still open, and both are
about configuration rather than schema:

`shikigami-migrate` resolves `DATABASE_URL` itself instead of taking plan 37's Settei
surface, because `shikigami-migrations` cannot depend on `shikigami-core` (which owns
`AppConfig`) without the two becoming mutually dependent and the solver rejecting the
project. Breaking that cycle — most likely by moving the configuration types into a package
both can depend on — is this plan's remaining implementation work, reassigned here from plan
37. Once it lands, `just migrate` invokes `shikigami-migrate --config
config/migrations-dev.yaml up` rather than exporting an environment variable, and
`docs/operations/configuration.md` loses its exception.

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

That search must come back empty for `shikigami-migrations`, `Justfile`,
`process-compose.yaml`, and `docs/operations`. Matches under `docs/plans` and
`docs/masterplans` are the historical record of completed work and are expected.


## Validation and Acceptance

Acceptance requires pure plan construction, manifest checks, and all database tests to pass.
A fresh database receives every framework and service schema through one executable, and a
second `up` makes no changes. Plans 19, 21, and 23 name pg-migrate files, manifests, and test
support rather than Codd scaffolding.

All of the above was verified on 2026-08-05 and is recorded in Progress. What remains
unaccepted is the Settei unification only.


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


## Interfaces and Dependencies

Use the released coherent `pg-migrate`, `pg-migrate-embed`, `pg-migrate-cli`, and test-only
`pg-migrate-test-support` packages. `pg-migrate-import-codd` is **not** used — see the
Decision Log. The owned modules are `Shikigami.Migrations` and
`Shikigami.Migrations.TestSupport`; the separate `Shikigami.Migrations.Component` and
`Shikigami.Migrations.Plan` modules this plan once specified were never created, because plan
47 implemented the component and the plan in one module. This plan hard-precedes the new database migrations in
plans 19, 21, and 23 and the deployment work in plan 31. The migration package depends on
no Shikigami sibling production package.


Revision note (2026-08-05): Cancelled Milestone 3, the Codd history import, because nobody is
using shikigami and no database needs its history preserved; Codd support was removed from the
repository outright instead. Marked M1 and M2 complete — plan 47 delivered them — and recorded
that this plan's only remaining implementation work is the Settei unification of
`shikigami-migrate`. Added a Portfolio Reconciliation noting that the schema-authoring gate on
plans 19, 21, 23, 35, and 51 is released, and corrected the module names, which never matched
what was built.

Revision note (2026-07-22): Created from the portfolio conformance review to replace the
active Codd plan with the fleet pg-migrate component, plan, CLI, transition, and test model.
