# 117. Watchdog staleness is measured against its own sweep marks

Date: 2026-11-06

Status: Accepted

## Context

Owner timestamps are incomplete and use different clocks. Messages, checkpoints,
accepted operations and attempts instead retain revisions and cursors. A durable
watchdog must repeat classification after a journal restart without reading a new
clock or silently changing the evidence that originally produced a notice.

## Decision

A subject's canonical activity digest is compared with the watchdog's retained
prior digest. The first observation records first-seen and last-change times; an
accepted mark change advances last-change time. Quiet time is the journaled page
observation time minus that retained last-change time. Owner updated_at values are
hints only. Findings report first-seen, last-change and observation instants and
coverage/relationship limits, so they do not claim knowledge before observation.

Terminal owner facts, incomplete evidence, changed marks, live waits, persistent
uncertainty, independent coordinator silence and ordinary stuck work have explicit
ordered rules. Incomplete evidence holds episodes. Expiry does not prove an
external effect failed. Material summaries omit elapsed time, sweep identity and
evidence revisions; only a material summary change produces another notice in the
same episode. Liveness and drift close episodes only in their own detector family.

Frozen priors accompany classified outcomes. Liveness persistence refuses a stale
prior or an observation older than a retained later observation. A principal/scope
claim serializes sweeps, and retained page receipts recover the original notices
before any retry coalesces episodes again. Opening and closing retain database
instants on their first committed operations. Scope changes start separate coverage.

A finished population traversal does not prove missing subjects ended. Bounded
exact owner reads must confirm termination or deletion before closing unseen
episodes. Idle, corrupt or unavailable owners remain unknown. Pass receipts retain
those outcomes and advance an accepted pass boundary once.

## Alternatives rejected

Owner timestamps omit important progress and can change without accepted work.
Per-subject Kiroku event times would add owner-specific event scans and still need
stable replay inputs. A heartbeat column on sessions would change the owners and
measure polling rather than accepted work. Recomputing a page on retry loses its
original notices after the first commit changes episode state. Lease expiry alone
would permit overlapping writers whose journals still retain live work.

## Consequences

A newly observed quiet subject needs a full configured window before a finding.
Incomplete evidence can delay a finding or closure but cannot establish absence.
Observation and classification add no owner heartbeat or intervention authority.
The ledger's database locks belong only to watchdog persistence; owner observation
reads retain their lock-free contract.

See [ADR 0116](0116-watchdog-observation-preserves-completeness-and-detector-boundaries.md),
[ExecPlan 110](../plans/110-classify-stuck-work-deterministically-and-coalesce-findings-into-episodes.md)
and [MasterPlan 19](../masterplans/19-supervise-active-work-with-an-independent-watchdog-agent.md).
