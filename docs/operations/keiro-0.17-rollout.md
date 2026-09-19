# Keiro 0.17 rollout

This procedure upgrades Shikigami from the Keiro 0.15/Kioku 0.5.2 cohort to
Keiro 0.17/Kioku 0.7. Migration `keiro/0032` adds opaque guarded-resume tokens
to durable timers. Old writers do not honor those tokens, so the database change
requires a coordinated writer cutover.

## Before the maintenance window

Build and test the exact release revision without `cabal.project.local` or sibling
package overrides. Take a recoverable database backup and verify that it can be
restored. Record the current migration state:

```bash
DATABASE_URL="$DATABASE_URL" shikigami-migrate verify
DATABASE_URL="$DATABASE_URL" shikigami-migrate status
```

Inventory every process that can execute a workflow or mutate timers. In this
repository those are `shikigami-worker` (agent, approval and conversation bodies,
bounded resume, and the shared timer dispatcher), `shikigami-scheduler` (schedule
allocation and timer draining), and one-off `shikigami-agent` execution. Stop them
all. Stop administrative mutations through `shikigami timer`, `shikigami wf`, and
`shikigami pgmq` during the cutover. API processes that only enqueue work may stay
up only if the deployment can prove they do not execute a workflow body; the safe
default is to stop every old Shikigami binary.

Wait for in-flight old processes to exit. Do not enable foreground Dead-timer
resume: Shikigami 0.17 exposes no application-authorized foreground-resume command,
so it remains disabled by construction.

## Migrate and start

Apply the complete four-component plan once. Selective component execution is not
supported:

```bash
DATABASE_URL="$DATABASE_URL" shikigami-migrate plan
DATABASE_URL="$DATABASE_URL" shikigami-migrate up
DATABASE_URL="$DATABASE_URL" shikigami-migrate verify
DATABASE_URL="$DATABASE_URL" shikigami-migrate status
```

The plan applies Kiroku, Keiro, Kioku, and Shikigami in dependency order, then
reconciles Kioku read-model identities. Verify that `keiro/0032` is applied and
that a second `up` reports no `AppliedNow` work.

Deploy only binaries built from the new cohort. Start one worker set first. Preview
bounded workflow resumption before allowing it to advance:

```bash
shikigami-worker --config /path/to/config.yaml --resume-passes 1 --resume-limit 100
shikigami-worker --config /path/to/config.yaml --resume-passes 1 --resume-limit 100 --force
```

The long-running worker uses the same registry and bounds after startup. Bring up
the remaining new workers, scheduler, server, and consumers only after migration
verification passes. Inspect timers and queues with the released operator tree:

```bash
shikigami --database-url "$DATABASE_URL" --json timer stuck
shikigami --database-url "$DATABASE_URL" --json pgmq dlq read --queue shikigami_run_jobs --limit 100
```

Use `--force` only after reviewing the corresponding preview. DLQ inspection hides
rows temporarily; archive inspected IDs before retention and let guarded purge
refuse while hidden rows remain.

## Rollback boundary

Source rollback cannot undo migration history or a workflow branch written by the
new binary. Prefer a forward fix after migration 0032 or any Language 6 generated
identity reaches durable state.

If an emergency rollback to an old writer is still required, first stop every new
writer and keep foreground resume disabled. Let guarded claims expire and run one
new-version timer pass so they return directly to Dead; the finite pass is the same
maintenance boundary exercised by `TimerRecoverySpec`. Confirm no timer has a live
`resume_claim_token` through supported inspection or a reviewed read-only database
query. Only then may an old writer start. Never clear tokens, reset attempts, delete
ledger rows, or edit applied SQL.

Restore from the verified backup if rollback requires removing migration 0032 or
other applied schema history. Queue messages, workflow journals, sink receipts, and
rich evidence must be reconciled with the backup point before traffic resumes.
