# 0024. A configured principal directory fails closed to its last valid snapshot

Date: 2026-08-22

Status: accepted


## Context

Meibo lifecycle is a fleet-wide control boundary. A paused or deactivated agent
must stop producing new runs and external effects across schedule, Kafka, queue,
workflow, and publisher processes without requiring all of those processes to
restart.

Consulting Meibo synchronously at each boundary would put a network request in
every hot path and turn a directory outage into unbounded latency. Caching adds
its own ambiguity: no snapshot at startup, a malformed replacement, and an
operator who explicitly disabled integration are three different states. If all
three mean “allow”, a configured kill switch silently disappears exactly when
its policy cannot be read. If all three mean “deny”, upgrading an unconfigured
deployment changes its behavior.

The snapshot is also a join boundary. A declared principal id is stable and
authoritative; the declaration name is only a compatibility handle. Falling
back from an unknown explicit id to a matching handle could bind a declaration
to a different principal after an operator typo or identity replacement.


## Decision

**A configured principal directory permits work only from a complete valid
snapshot, and a process serves its last valid snapshot until a newer complete
snapshot replaces it. Explicit disabled mode is a separate compatibility
state.**

Every process reads lifecycle through an in-memory `DirectoryHandle`. A source
builds and validates a complete candidate before one atomic publication. A
candidate with a read, decode, id-prefix, empty-handle, duplicate-id, or
duplicate-normalized-handle failure changes no visible record.

Configured cold start requires one valid snapshot. Without one, startup fails
and hot-path consultation returns unavailable rather than active. After the
first successful publication, a source failure is logged and the exact prior
snapshot remains authoritative. No schedule, Kafka, queue-drain, sink-enqueue,
or sink-publish boundary performs directory IO.

`DirectoryDisabled` deliberately preserves pre-directory execution. It permits
work, carries a declared principal id when one exists, and is rendered as
`DISABLED` in operator inventory so it cannot be mistaken for verified active
policy.

Lookup uses an explicit declaration principal id when present and never falls
back from that id to the handle. Only a declaration without an id may join by a
trimmed, case-normalized handle. Missing principals in configured mode fail
closed as unknown.

The refresh action is a supervised process loop. It heartbeats after every
attempt, including a failed fetch, because “the source is unavailable while the
loop retries” differs from “the loop stopped”. Source availability is not a
readiness dependency: eviction or restart cannot repair Meibo, and the cached
snapshot is intentionally sufficient to continue enforcing the last known
policy.


## Alternatives rejected

**Call Meibo at every side-effect boundary.** This couples correctness and
latency to a remote service and creates several independently implemented
network failure policies.

**Treat every source error as an empty or active directory.** A transient torn
file or outage would reactivate paused principals and erase the kill switch.

**Treat disabled configuration as an unavailable configured source.** That
would make adoption a breaking deployment change rather than an explicit
operator choice.

**Publish partially decoded records.** Readers could observe a mixture of old
and new policy, and the fate of a principal would depend on file order.

**Fall back to handle after an explicit id misses.** This hides identity errors
and can silently authorize the wrong principal.

**Make directory availability a readiness check.** Removing every worker from
service does not repair the directory and discards the last-known-valid policy
that the cache exists to serve.


## Consequences

File mode is fail-closed at startup and during any lookup absent from the last
valid snapshot. Operators must replace the JSON file atomically; a non-atomic
write is safe but produces a logged rejected refresh until the next cadence.

Pausing or deactivating a principal takes effect after the configured refresh
interval at every new side-effect boundary. Work already completed is not
rolled back. A sink intent admitted before the pause is checked again at publish
and becomes a terminal non-send receipt rather than an HTTP request.

Trigger and drain refusals are durable `run_skips` rows. Sink enqueue refusals
are journaled `SkippedLifecycle` outcomes, and publish refusals are terminal
delivery receipts. Those different evidence stores reflect the boundary that
owns each decision rather than introducing a second global audit authority.

A future live Meibo client may implement the same source interface. It must
retain complete-snapshot validation and atomic publication; transport changes
do not weaken this failure policy.


## References

* `docs/plans/23-agent-lifecycle-control-with-meibo-principals.md` — implementation
  plan and acceptance evidence.
* [ADR-0019](0019-a-loop-that-stops-stops-the-process.md) — refresh-loop
  supervision.
* [ADR-0020](0020-readiness-covers-only-what-restarting-can-fix.md) — why Meibo
  availability is not readiness.
* [ADR-0022](0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md)
  — terminal non-send receipt ownership.
* `mori://shinzui/meibo/docs/initial-spec` — principal and lifecycle contract.
