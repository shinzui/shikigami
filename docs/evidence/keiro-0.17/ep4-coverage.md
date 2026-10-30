# EP-4 timer and migration evidence

Keiro 0.17's `drainWorkflowSleepTimers` routes through `drainDueTimers`, whose
once-per-pass preamble calls `recoverExpiredTimerResumes`. Shikigami keeps that one
maintenance boundary and exposes its finite 100-row serving pass for integration
testing. `TimerRecoverySpec` uses only public timer APIs and a one-second lease. It
proves direct recovery to Dead with reason, payload, and attempts intact; refusal
of ID-only cancel/dead-letter/complete; and stale-token fencing after replacement.

The migration smoke constructs an actual Keiro 0.15 component from the first 31
exact migration payloads exported by Keiro 0.17. The authoritative 0.15 and 0.17
Hackage tarballs differ in that directory only by `0032.sql` and its manifest line;
Kioku migrations 0.5.2 and 0.7 are byte-identical. The test seeds a PGMQ job,
suspended workflow, dead timer, and rich run evidence, upgrades the same database,
requires exactly one new migration, checks `keiro/0032`, preserves every prior
checksum and seeded row, and requires a no-op second pass.

Before applying 0032, the same migration connection creates a colliding
`hostile.keiro_timers` relation and puts `hostile` first on its session path. The
upgrade proves that only `keiro.keiro_timers` receives the new claim columns and
that the host's path remains byte-for-byte unchanged.

`tools/check-migration-schema-isolation.sh` rejects application migration-session
`search_path`/`SET SCHEMA` mutation and common unqualified persistent-object
references. It scans the vendored PGMQ snapshot separately. The exact historical
`0001-shikigami-fired.sql` exception is reported because applied
pg-migrate bytes are checksum-immutable; every later application migration is
schema-qualified. `just new-migration` now generates a qualified-object reminder
instead of a `SET search_path` statement.

The complete operator cutover and rollback boundary is in
`docs/operations/keiro-0.17-rollout.md`.
The selected PGMQ server/client operations, including nullable metrics and the
explicit FIFO exclusion, are recorded in `pgmq-capabilities.md`.
