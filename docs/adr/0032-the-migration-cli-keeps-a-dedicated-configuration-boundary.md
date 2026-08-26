# 0032. The migration CLI keeps a dedicated configuration boundary

Date: 2026-08-26

Status: accepted


## Context

Plan 37 established one Settei `AppConfig` for Shikigami-owned application and service
settings. The HTTP server, workers, consumers, scheduler, one-off commands, and operator
commands consume that declaration. `shikigami-migrate` is the sole administrative executable
outside it: the executable reads `DATABASE_URL` and mounts the parser, dispatcher, reports, and
renderers supplied by `pg-migrate-cli`.

Making the migration executable import `Shikigami.App.Config` creates a package cycle.
`shikigami-core`'s test suite depends on the public
`shikigami-migrations:test-support` sublibrary so core behavior can run against the production
migration plan. Adding the reverse production dependency makes Cabal reject the project at
package granularity. The migration executable consumes no other Shikigami application setting,
so breaking that cycle would be structural work solely to move one connection string between
two parsers.

This boundary also matches the contract of
`mori://shinzui/pg-migrate/packages/pg-migrate-cli`: the reusable package owns migration command
parsing and execution, while the embedding application owns its plan, database connection,
streams, logging, and process exit. The minimal application in
`mori://shinzui/pg-migrate/docs/quickstart` reads `DATABASE_URL` before constructing the CLI
environment. Shikigami's wrapper follows that pattern and adds only the application-owned
read-model reconciliation after a successful `up`.


## Decision

**`shikigami-migrate` remains a dedicated pg-migrate administrative boundary and reads
`DATABASE_URL` directly.** The `DATABASE_URL` value exported to that one process by `just
migrate`, `just migrate-status`, or deployment packaging is its supported configuration
contract. It is not duplicated into Settei, and the migration package does not gain a dependency
on `shikigami-core` merely to share configuration mechanics.

**Settei remains the sole configuration mechanism for Shikigami-owned application and service
settings.** This exception is deliberately narrow: it covers only the connection value needed to
construct pg-migrate's application-owned CLI environment. A future migration setting that is
also consumed by another Shikigami process belongs in `AppConfig`. If the migration executable
grows multiple Shikigami-owned settings, this decision must be revisited before adding more raw
environment reads.

**The migration wrapper continues to mount the owning library's command surface.** It may add
only application composition that no dependency can own, currently the complete Shikigami plan
and post-`up` read-model reconciliation. This applies ADR 0021's operator-boundary rule to schema
administration: wrap the supported library API; do not reproduce its command or ledger behavior
locally.


## Alternatives rejected

**Make `shikigami-migrations` depend on `shikigami-core`.** Rejected because the reverse test
dependency already exists and Cabal rejects the resulting package cycle.

**Move all configuration types into a new lower-level package.** Rejected because no reusable
domain boundary has appeared. A new package whose only consumer-visible benefit is sharing one
connection string would increase the permanent package graph to remove an explicit, documented
one-variable adapter.

**Duplicate a migration-only Settei declaration.** Rejected because two declarations for the
same database value would undermine plan 37's actual guarantee: one authoritative Shikigami
application schema with one precedence and diagnostic policy. It would provide the appearance of
uniformity while preserving separate configuration code.

**Replace the environment value with `--config config/migrations.yaml`.** Rejected because it
does not remove the separate parser or package boundary; it only adds a service-specific file
format around the same single value. Process-local `DATABASE_URL` is the conventional and
documented pg-migrate embedding contract.


## Consequences

Plans 37 and 38 are complete without a package restructure. Plan 31 should deploy the migration
job with `DATABASE_URL`; it should not wait for a Settei unification or invent a migration config
file. `just migrate` and `just migrate-status` remain correct as written.

The cost is explicit asymmetry. `shikigami-migrate` does not expose the five Settei diagnostics,
and its connection value has a separate environment spelling. That asymmetry is bounded to a
single-purpose administrative process, documented in the configuration guide and at the call
site, and protected from accidental growth by this record.


## References

* [`docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md`](../plans/37-adopt-settei-configuration-across-shikigami-binaries.md)
  — shared application configuration and the package-cycle discovery.
* [`docs/plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md`](../plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md)
  — pg-migrate delivery and closure of the former configuration remainder.
* [ADR 0021](0021-operator-verbs-wrap-the-owning-library.md) — operator commands mount the
  supported API of the state-owning library.
* `mori://shinzui/pg-migrate/packages/pg-migrate-cli` — reusable migration command boundary.
* `mori://shinzui/pg-migrate/docs/quickstart` — application-owned connection configuration.
