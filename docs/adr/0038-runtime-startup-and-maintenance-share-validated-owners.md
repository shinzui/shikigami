# 0038. Runtime startup and maintenance share validated owners

Date: 2026-09-07

Status: accepted

## Context

Plan 65 adopts the released runtime contracts. A process can otherwise open a pool
against an incomplete migration ledger, omit one workflow family from resumption,
or offer recovery operations that cannot reconstruct encode-only evidence. Long-lived
terminal workflow journals also require an explicit retention decision.

## Decision

Every serving runtime checks the complete migration plan through the read-only
`Shikigami.Migrations.verifyShikigamiMigrations` boundary before telemetry and resource
acquisition. Pending, unknown, failed or changed ledger entries refuse startup. Only
the migration executable applies or repairs the plan. Agent, server and worker packages
may depend on the migration library for this check; core remains independent and the
migration package does not import core. This extends the legal package arrows documented
by plan 36 without changing ADR 0032's dedicated migration configuration boundary.

Construct process telemetry before the store. Extend upstream connection defaults with
bounded pool observations and the released Kiroku-to-Keiro event bridge. Register the
validated RunEvidence catalog before listeners or workflow intake. Its live handler
captures rich command evidence in the same transaction as lifecycle append; queries
and operator catalog operations use the same generated authority.

The shared core registry contains agent runs, approval children and conversations.
The worker binary owns bounded resumption because the embedded server ResumeHook's
`[Store, Error StoreError, IOE]` row cannot interpret the resource-aware Kioku workflows.
`--resume-passes N --resume-limit N` previews the budget; adding `--force` executes it.
A bounded drain stops on zero `advanced`, even if `discovered` is nonzero, and reports
every released summary field. Continuous execution uses the upstream worker and its
thread-safe failure hook; that hook does not expose successful per-pass summaries.
Keep concurrency at one until pool headroom is measured.

One timer dispatcher routes both Keiro sleeps and application timers, with a 100-row
pass bound. Terminal workflow GC runs hourly, at most 100 instances per pass, after
90 days. This is the workflow idempotency window: older redelivery needs operator
review. Keiro excludes live workflows and completed children of live parents. GC does
not own application evidence streams, rich projection rows, sink receipts or remote
deduplication keys; those survive this policy.

Catalog operations preserve live-only payload targets. Their non-destructive pass may
inspect/reconcile existing catalog state; it cannot recover missing rich evidence.
Lifecycle replay audit remains useful and read-only. No rich-payload replay adapter,
destructive reset, resource-effect cast or private mutation is supplied.

## Alternatives rejected

Applying migrations in every replica would mix deployment mutation with startup and
race schema ownership. A core-to-migrations dependency would weaken the domain package
boundary. Separate registries or competing timer routing algorithms would let runtime
and operations disagree about owners. Repeating a drain on candidate count would spin
on paced or blocked work. Unlimited journal retention would leave maintenance implicit;
a shorter horizon would unnecessarily narrow ordinary retry and investigation windows.

## Consequences

Runtime roles link the migration library and refuse incompatible databases early.
Operators have a finite, explicit resume command and a documented retention horizon.
Application evidence retention remains separate. A crash before the first committed
journal entry has no discoverable workflow instance: queue redelivery owns that
retry. Failed-workflow resurrection applies once ingestion has committed; the
recovery fixture pins that distinction. Future changes to the horizon must
consider delayed queue redelivery and operator recovery, not just storage usage.

## References

- [Plan 65](../plans/65-migrate-shikigami-to-the-keiro-0-15-cohort-and-the-idiomatic-v2-record-model.md)
- [ADR 0010](0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md)
- [ADR 0032](0032-the-migration-cli-keeps-a-dedicated-configuration-boundary.md)
- [ADR 0037](0037-adopt-the-released-keiro-contracts-before-v1.md)
- `mori://shinzui/pg-migrate/packages/pg-migrate`
- `mori://shinzui/keiro/packages/keiro`

## Keiro 0.17 amendment — 2026-09-18

The shared 100-row timer pass now has an explicit finite application boundary for
integration and operator testing. Keiro 0.17 performs guarded-claim recovery once
in that pass before ordinary claims; Shikigami does not add a competing recovery
sweep. Expired foreground claims return directly to Dead with reason, payload and
attempt history intact, and opaque replacement tokens fence stale completion.

Migration 0032 requires a coordinated writer cutover because old timer writers do
not honor claim tokens. `docs/operations/keiro-0.17-rollout.md` therefore stops all
old workflow/timer writers before the complete migration plan, starts only upgraded
writers, and keeps foreground Dead-timer resume disabled until an application-owned
authorization and execution boundary exists. Rollback must first expire and recover
guarded claims; operators never clear tokens or reset attempts with SQL.

Application migrations are schema-qualified and checked by
`tools/check-migration-schema-isolation.sh`. The checker reports the one exact
checksum-immutable historical `SET search_path` file and separately scans the
vendored PGMQ snapshot; new migration scaffolds never emit session path mutation.

## First-release schema ownership — 2026-10-30

MasterPlan 16 replaces Shikigami's vendored PGMQ baseline with the released
`pgmq-migration` component from `mori://shinzui/pgmq-hs/packages/pgmq-migration`.
The application component depends on both Kioku and PGMQ. Production composition
and the shared database fixture use these same five component owners; framework
SQL remains in its producing package. The unused detector suppression table moves to the application-owned
`shikigami.fired` relation; no runtime consumer references the old name. Every
application object is explicitly qualified without changing the session search path.

This is an unused-service first-release ledger reset under ADR-27, not an upgrade
recipe for a populated old ledger. The superseded vendored SQL and historical
0.15 upgrade fixture are retired. Startup still verifies read-only and refuses
pending, drifted, unknown or missing history. Plan 92 records native acceptance: ten PostgreSQL smoke tests and five
composition tests pass, including the required upstream migration identities.


## Current runtime ownership — 2026-10-30

Plan94 replaces per-action Kioku store acquisition in Shikigami workflows with
`Shikigami.App`, a service interpreter over the released resource row plus
Reader RunCommandOptions. Production environments bind their acquired store through
public runKirokuStoreWith; standalone actions may acquire one. Every application
aggregate writer receives process tracer/metrics through default-based options.
No workflow step, seed or wire identity changes. Startup forces validation of all
four aggregates and registers the shared catalog before intake; production
statements now have a thirty-second timeout.

Kafka and PGMQ Shibuya handles are bracketed with masked ownership transfer and
joined cleanup. Infrastructure/finalizer failure reaches process supervision;
Kafka configuration/authentication/fatal errors do not reconnect forever. The
PGMQ worker uses StopAllOnFailure, client polling, batch1/inbox1 and an initial
visibility horizon of two configured attempt windows plus60seconds. Active work
renews its shorter lease; queued work after a crash may wait the initial horizon.
Queue liveness follows attempt timeout plus30seconds. Idle paused processors are
healthy, while paused admitted work retains the last-progress deadline.

The current common registry has five families: agent run, approval, conversation,
execution driver and continuing worker. Worker-owned bounded resumption remains
necessary because the embedded operations row cannot interpret the resource-aware
workflows; no cast or private API widens it. Inspection provider/collector wiring
is separately qualified by plan106 and must not allocate another worker runtime.

The acquired-handle interpreter is supplied by
`mori://shinzui/kiroku/packages/kiroku-store`; the base effect row remains supplied
by `mori://shinzui/kioku/packages/kioku-core`. Application code composes their
released public interpreters and keeps ownership in the process root.
