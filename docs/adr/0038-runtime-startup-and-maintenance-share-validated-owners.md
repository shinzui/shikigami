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
