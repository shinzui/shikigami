# 0046. The HTTP agent catalog joins boot-time declarations to the live directory

Date: 2026-10-25

Status: accepted

## Context

An HTTP caller needs to discover declared agents and predict lifecycle admission
without depending on workers having started. Workers persist manifest load state,
but that table describes a different process and can lag this deployment.

## Decision

The server loads all successfully decoded declarations, including disabled ones,
at boot. Each HTTP read joins them to the server's current lifecycle directory.
Failed manifests are counted and logged, rather than exposed as agents. A disabled
directory reports `unverified`; a configured directory without a matching principal
reports `unknown`. Only enabled agents with active or unverified lifecycle are
runnable. A configured directory without a valid snapshot returns an unavailable
problem. Later refresh failures retain the last valid snapshot.

The declaration catalog uses Relay keyset pagination in ascending agent-name order.
HTTP capture and schema instances stay in the API package; the catalog and lifecycle
classification stay in core. The server owns and cancels the directory refresher.

## Alternatives rejected

Reading worker-owned load state would couple catalog availability and freshness to
worker startup. Returning only enabled agents would hide the reason an addressed
run is refused. A plain list would make adding pagination a breaking change.

## Consequences

Manifest changes require a server restart. Lifecycle changes become visible after
the configured directory refresh. The catalog predicts lifecycle admission; workers
still re-admit work immediately before executing it. The HTTP inventory intentionally
contains declarations only; the operator inventory also shows failed manifests and
principals without declarations.

## References

[ExecPlan 88](../plans/88-serve-the-declared-agent-catalog-over-http.md),
[ADR 0020](0020-readiness-covers-only-what-restarting-can-fix.md), and
[ADR 0021](0021-operator-verbs-wrap-the-owning-library.md).
