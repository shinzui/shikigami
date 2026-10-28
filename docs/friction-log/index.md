---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [Baseline build references absent Kikan action packages](1-baseline-build-references-absent-kikan-action-packages.md) - The Cabal project requires co-developed Kikan packages absent from the registered checkout, blocking core compilation.
- [Default PostgreSQL test parallelism exhausts fixture connections](2-default-postgresql-test-parallelism-exhausts-fixture-connections.md) - The core PostgreSQL suite inherits all CPU capabilities and starts enough isolated test pools to exceed the ephemeral server client ceiling.
- [Legacy Cabal package mirror rejects a required source archive](3-legacy-cabal-package-mirror-rejects-a-required-source-archive.md) - The full package test build encounters a 403 on the configured HTTP Hackage mirror and needs an authoritative archive cache fill.
- [Default Cabal project points at missing Kikan packages](4-default-cabal-project-points-at-missing-kikan-packages.md) - The checked-in Cabal project cannot resolve its local Kikan package paths in this workspace.
- [Parallel PostgreSQL suite exhausts ephemeral connection capacity](5-parallel-postgresql-suite-exhausts-ephemeral-connection-capacity.md) - The full core PostgreSQL test suite hits the ephemeral database connection limit with default concurrency.
- [Keiro scaffold drift check includes hand-owned core edits](6-keiro-scaffold-drift-check-includes-hand-owned-core-edits.md) - The keiro-scaffold recipe checks all core source changes rather than only generated files.
- [Automatic PGMQ exhaustion bypasses the domain disposition hook](7-automatic-pgmq-exhaustion-bypasses-the-domain-disposition-hook.md) - Keiro dead-letters exhausted messages before the domain handler and exposes no terminal callback to persist an HTTP receipt.
- [Resource-ledger baseline needs isolated Kikan sources](8-resource-ledger-baseline-needs-isolated-kikan-sources.md) - The default Cabal project still names two absent local Kikan packages and requires the existing isolated validation project.
- [Queue payload additions have no optional compatibility policy](9-queue-payload-additions-have-no-optional-compatibility-policy.md) - The queue generator requires every new field and rejects omission defaults, so resource metadata needs a versioned application codec.

