# 120. Watchdog liveness is an operator-facing ledger verdict

Date: 2026-11-06

Status: Accepted

## Context

A watchdog that stops running cannot report its own absence. A newer unfinished
attempt must not conceal an older completion. Restarting healthy workers does
not repair a missed schedule and can disturb unrelated durable work.

## Decision

Expose the latest attempt separately from the latest completed sweep, scoped to
the configured principal and observation scope. Derive overdue status from the
actual declaration cron's next due instant after completion plus operator grace.
No completion and unavailable coverage remain distinct from a fresh, empty sweep.

The operator command can fail with exit 2 on a missing or overdue completion.
The worker's independent sampler reads completion age using the database clock.
It emits no gauge value before a completion and never substitutes zero for a
failed read. Old exported values retain their old timestamps. Runtime callbacks
use fixed tags and are at least once; retained ledger views provide exact audit
counts. Health probes keep [ADR 0020](0020-readiness-covers-only-what-restarting-can-fix.md)'s scope.

## Consequences

Monitoring can detect a missing watchdog without waiting for another sweep.
Operators must monitor sample timestamps and coverage as well as age. Changing
the configured principal or scope selects a separate inspection history. This
adds no intervention authority to the advisory Flow described in
[ADR 0118](0118-the-watchdog-is-an-advisory-flow-agent-without-intervention-authority.md).
