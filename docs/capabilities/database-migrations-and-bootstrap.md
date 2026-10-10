---
type: "Capability"
title: "Database migrations and bootstrap"
description: "Apply a dependency-ordered database plan, reconcile memory read models, and refuse incompatible migration history at runtime startup."
capabilityId: "CAP-19"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-migrations"]
interface: ["Shikigami.Migrations", "shikigami-migrate", "Shikigami.Migrations.TestSupport"]
tags: ["migrations", "database", "bootstrap"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:55:22Z"
evidence:
  - kind: module
    resource: "shikigami-migrations/src/Shikigami/Migrations.hs"
    proves: "Embedded migration composition, read-model reconciliation, and a read-only startup ledger check."
  - kind: test
    resource: "shikigami-migrations/test/Main.hs"
    proves: "All four components are present and ordered by dependency, with application SQL embedded."
  - kind: test
    resource: "shikigami-migrations/test/Migrate.hs"
    proves: "Fresh application, no-op reapplication, incompatible-ledger refusal, and isolated suite fixtures."
  - kind: module
    resource: "shikigami-migrations/app/Main.hs"
    proves: "The mounted migration command parser uses DATABASE_URL and reconciles read models only after successful up."
  - kind: module
    resource: "shikigami-migrations/test-support/Shikigami/Migrations/TestSupport.hs"
    proves: "A shared migrated suite template yields isolated database clones with callback-scoped cleanup."
---

# Database migrations and bootstrap

## Provides

The package embeds Shikigami SQL and composes it with the storage, workflow, and
memory dependencies' migration components in dependency order. The migration
binary exposes plan, list, check, status, verify, up, repair, and new commands
through the mounted migration CLI. A successful `up` also reconciles the memory
read-model registry. Runtime entry points use a read-only verification handshake
that refuses pending, changed, failed, or unknown migration history before
starting work.

The public `test-support` sublibrary creates a migrated template once per suite
and clones an isolated database for each example, releasing it after the callback.

## Adopt

Set `DATABASE_URL` for `shikigami-migrate`, then inspect the plan and apply `up`.
The repository's `just migrate` recipe supplies that dedicated configuration
boundary. Embedders can consume `shikigamiMigrationPlan` and
`verifyShikigamiMigrations`; tests can use the `test-support` sublibrary.

## Evidence

- [Migrations.hs](../../shikigami-migrations/src/Shikigami/Migrations.hs): migration composition and startup verification.
- [Main.hs](../../shikigami-migrations/test/Main.hs): pure component ordering and embedding assertions.
- [Migrate.hs](../../shikigami-migrations/test/Migrate.hs): real-database application, verification, and fixture isolation.
- [Migration executable](../../shikigami-migrations/app/Main.hs): command wiring and successful-up reconciliation.
- [TestSupport.hs](../../shikigami-migrations/test-support/Shikigami/Migrations/TestSupport.hs): suite and per-example fixture lifecycle.

## Limits

The migration binary reads `DATABASE_URL` directly; it does not use the shared
runtime configuration resolver. Runtime startup verifies but does not apply or
repair migrations. Applied migration names and SQL bytes are immutable; a
correction needs a new manifest entry. The fixture sublibrary is a test boundary
and must not supply production database resources. PostgreSQL is required, and
the migration runner itself is provided by
[the migration dependency](mori://shinzui/pg-migrate/packages/pg-migrate).
