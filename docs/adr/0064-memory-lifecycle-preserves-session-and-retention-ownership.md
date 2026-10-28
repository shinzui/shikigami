# 0064. Memory lifecycle preserves session and retention ownership

Date: 2026-10-28

Status: accepted design; implementation pending in plan 34

## Context

Agent declarations already contain a Shared memory choice, but runtime memory is
principal-scoped. Implementing sharing by changing all session scopes would also
change conversation lookup and publish private distillation. Retention based only
on MemoryPattern would include provisional practice-review facts. Alias recall
currently truncates unbounded scope reads, and a new generic timer poller would
compete with the existing application dispatcher.

## Decision

Pin a versioned memory-policy snapshot for new workflow branches: memory space,
recorded principal, learning target, recall limit and automatic record policy.
Authorize IO freshly; the snapshot is policy data, not an authorization grant.
Old workflow branches retain their old principal-only behavior. The new boundary
is guarded by `shikigami-memory-lifecycle-v1`; its policy step is `memory-policy-v1`.
One-off execution resolves the same policy once.

Sessions, transcripts and L1/L2/L3 distillation remain principal-scoped. Shared
selects the exact global bucket for automatic agent-run learnings and explicit
Flow memory, without publishing conversational history or its distilled results.
Shared recall does not union private memory. Automatic recordPolicy controls
automatic result learning; it does not suppress explicit Flow writes or the
conversation transcript protocol. Sharing preserves the admitted writer and never
grants cross-space access.

Recency fallback uses owner-provided, contextful SQL bounds and a deterministic
timestamp/id merge across principal and accepted alias scopes. Support at most
64 aliases; detect the 65th with a bounded query and fail explicitly without
partial recall. Keep a top-N metadata heap, retrieve content only for selected
ids, and propagate failed/denied reads distinctly from successful empty reads.
Successful relevance search retains its ranking semantics.

Only newly written automatic run learnings carrying the reserved
`shikigami.retention.run-learning.v1` tag are managed by default retention. The
runtime alone may supply the reserved prefix. Unmarked history, explicit Flow
writes, review memories, conversations and distilled artifacts remain outside
this collector. Keep the newest 200 eligible records per physical scope and
archive only older-than-30-day eligible rows beyond that set. Accepted aliases
retain separate physical keep sets; the shared bucket has one keep set.

Retention is independently enabled and supervised. It has a Shikigami-owned
checkpoint, fixed sweep cutoff, chronological cursor and finite per-pass row/time
budgets. Kioku owns candidate-query semantics and contextful archive commands. The archive
owner atomically rechecks eligibility and the keep set; a caller-side pre-read
cannot establish that condition under concurrent mutation.
Checkpoint replay is at-least-once: archive facts remain idempotent through the
owner API. Repeatedly failing candidates are parked visibly with bounded failure
storage. There is no inferred historical ownership or automatic legacy backfill.

Kioku timers use the existing shared claimed-row dispatcher and Kioku's public
fire/outcome APIs. With live distillation enabled, drain one timer per pass and
bound its AI callback to 30 seconds; the normal disabled-AI fast path retains the
100-row ceiling. This is a deliberate initial throughput tradeoff. Report backlog
age and keep heartbeat thresholds consistent with the callback budget. Retention
does not poll the generic timer table. Enabled distillation also requires bounded
source and candidate reads; a bounded number of timers alone is insufficient.

## Alternatives rejected

Moving sessions into the global bucket conflates sharing with conversation
identity. Publishing distilled transcripts automatically would broaden the meaning
of Shared without an explicit publication operation. Retaining every MemoryPattern
would take ownership of review facts. An eligibility marker on all memory writes
would recreate that same mistake under another name.

Dropping aliases at the limit would silently lose history; explicit refusal makes
the capacity boundary actionable. Client-side truncation and a second generic timer
poller would retain the original resource and ownership defects.

## Consequences

The first retention delivery manages newly opted-in automatic learning, not all
historical memory. Old history can still grow and needs a separately authorized
migration if operators want it collected. Shared agents intentionally do not get
private conversation distillation through generic Shared recall. Distillation
backlog throughput starts conservatively; further concurrency or claim scheduling
requires measured owner-supported changes.

The plan contains exact fixture, failure, cursor and upstream delivery contracts.
This decision selects the design; it does not certify missing released APIs or
claim implementation acceptance.

## References

- [Plan 34](../plans/34-memory-lifecycle-distillation-retention-and-shared-scope.md)
- [ADR 0033](0033-recorded-agent-principals-key-durable-state.md)
- [ADR 0031](0031-practice-review-adjudication-is-a-logical-memory-transition.md)
- [ADR 0038](0038-runtime-startup-and-maintenance-share-validated-owners.md)
- [Workflow versioning](../workflow-versioning.md)
- `mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2`
