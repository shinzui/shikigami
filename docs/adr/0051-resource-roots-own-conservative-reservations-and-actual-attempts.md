# 0051. Resource roots own conservative reservations and actual attempts

Date: 2026-10-27

Status: accepted

## Context

The lifetime descendant ledger prevents sibling delegation from overspending a
shared count. It does not bound concurrent work, actual transport retries, tokens
or cost, and cannot represent an uncertain transport outcome. Copying a remaining
allowance into each new assignment would let reorganized workers regain capacity.

The checked queue generator requires every structural payload field. Its public
versioned codec API supports application upcasters, while the existing
`triggerPayload` field is application-owned JSON. Old queue messages and workflow
journals must keep their original input and unenrolled behavior.

## Decision

An explicitly enrolled resource root owns the immutable admitted envelope and an
absolute cutoff. Missing dimension policy denies spending; unbounded capacity
requires an explicit operator choice. Quantities fit nonnegative signed 64-bit
units. Cost uses integer millionths of one USD.

Logical operation ids and actual attempt ids are distinct. Replaying an identical
request returns its receipt without authorizing another dispatch. A new actual
transport attempt reserves fresh active capacity and its matching attempt counter.
Finite token and cost budgets require reserved, enforced request ceilings. The
dispatcher owns applying those ceilings to the real request; the ledger alone
cannot prove a transport's compliance.

Every mutation locks the root first. The root stores bounded aggregate state;
operations, attempts and exclusive finite allocations live in separate rows.
Allocation capacity is held in its parent and cannot be widened or reduced below
spent or held work. Nested allocations retain one root, and ancestor cutoffs still
apply. Known completion releases active work, retains attempt counters and records
measured usage. Unknown completion holds capacity until explicit reconciliation.
Neither lease expiry nor cancellation is a refund. Overage remains a fact and
stops subsequent admission. Result recording remains possible after cancellation,
cutoff and policy revision changes. Transaction-level hooks allow the execution
owner to commit an accepted outcome and its resource settlement together.

Enrolled delegation reserves both the resource ledger and historical descendant
ceiling in one transaction before spawn. The old budget binds to its resource
root. Replacing or stripping that reference is refused. Public Keiro child
registration follows the committed reservation; replay repairs the same child.

Root enrollment is explicit at the new-run admission boundary. Descendants cannot
seed a missing envelope. Historical journal values default the optional root to
`Nothing`; the new validation step is behind
`shikigami-execution-resources-v1`. The shared workflow options already union the
generated patch declarations.

The application queue codec writes version 2, wrapping its opaque input with the
optional root reference while preserving all generated structural fields. The
version 1 upcaster wraps its input with an absent root unconditionally, so a
historical input that resembles version 2 metadata is never reinterpreted.
Generated queue files remain generator-owned. Future execution settings extend
this application-owned input contract, preserving its earlier decoders.

## Alternatives rejected

Independent counters per assignment break conservation across retries and
handoffs. Releasing uncertain attempts on timeout asserts that the external work
stopped without evidence. Floating-point currency loses exact comparisons. A new
required generated queue field rejects retained jobs; a second queue would add a
competing intake path. Encoding root metadata without an envelope version would
reinterpret some historical user inputs.

## Consequences

Workers must understand queue version 2 before producers write it. Stop old
workflow writers before enrolling roots, since old binaries do not enforce the
new ledger. After new journals exist, roll forward. Application reservations,
deduplication and uncertain attempts survive terminal workflow garbage collection.
The ledger and inspection command establish accounting, not model/tool replay or
adaptive scheduling; those consumers retain their separate acceptance gates.

## References

- [Plan 81](../plans/81-enforce-root-resource-reservations-across-durable-work.md)
- [ADR 0023](0023-delegation-is-governed-at-the-child-spawn-boundary.md)
- [Workflow versioning](../workflow-versioning.md)
- `mori://shinzui/keiro/packages/keiro-core` — public versioned codec/upcaster API.
