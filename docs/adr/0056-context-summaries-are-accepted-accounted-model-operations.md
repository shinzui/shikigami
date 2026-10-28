# 0056. Context summaries are accepted, accounted model operations

Date: 2026-10-28

Status: accepted

## Context

Context selection can omit complete history groups to fit a pinned byte ceiling.
An optional model-assisted summary must survive a crash and explain which source
it summarized. Treating it as an unrecorded preprocessing callback could spend
unbounded allowance or sample different context after restart.

## Decision

Only a snapshot whose policy enables summaries may admit one. The driver admits
a `ModelSummary` operation through the same operation, queue, actual-attempt and
accounting boundaries as ordinary model work. Its output ceiling is explicit and
the existing model-turn ceiling includes it. A summary request has no tools.

Protected model inputs carry optional versioned provenance: the previous regular
model-input reference, an accepted summary reference, or the digest of the source
being summarized. The extension is omitted when absent, preserving historical
format-1 bytes and readers. A summary reference names its operation, accepted
outcome and source digest. Restart reuses the accepted summary for that exact
source; it never resamples it as a replay convenience.

The summary request preserves the initial user anchor and original system prompt.
It includes complete omitted groups and a factual-summary instruction. If those
required source groups do not fit, admission refuses explicitly. Signed or opaque
continuations remain mandatory in the ordinary context and are not replaced by
summary prose. A successful nonempty plain-text summary enters the following
context as labeled data. Its source is retained separately. It grants no tools,
model settings, root resources or permissions. A summary that requests tools or
returns an invalid result fails visibly instead of dispatching tools or entering
an unbounded summary-repair loop.

## Alternatives rejected

An unrecorded summary would make restart nondeterministic. Giving it a separate
allowance would let compaction reset model budgets. Silently trimming its required
source would claim coverage it did not receive. Replacing raw history with its
prose would discard the evidence needed to reproduce the context decision.

## Consequences

Summaries remain disabled by default. Enabling them spends ordinary model turns
and actual attempts; a near-exhausted execution may have no allowance for another
answer after summarization. Protected provenance grows only by references and
digests, while accepted raw payloads retain their existing lifecycle. Agent and
operator configuration and parent workflow adoption remain in plan 83.

## References

- [Plan 83](../plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md)
- [ADR 0053](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md)
- [ADR 0055](0055-execution-drivers-rotate-around-accepted-work.md)
