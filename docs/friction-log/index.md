---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [Baseline build references absent Kikan action packages](1-baseline-build-references-absent-kikan-action-packages.md) - The Cabal project requires co-developed Kikan packages absent from the registered checkout, blocking core compilation.
- [Default PostgreSQL test parallelism exhausts fixture connections](2-default-postgresql-test-parallelism-exhausts-fixture-connections.md) - The core PostgreSQL suite inherits all CPU capabilities and starts enough isolated test pools to exceed the ephemeral server client ceiling.
- [Legacy Cabal package mirror rejects a required source archive](3-legacy-cabal-package-mirror-rejects-a-required-source-archive.md) - The full package test build encounters a 403 on the configured HTTP Hackage mirror and needs an authoritative archive cache fill.

