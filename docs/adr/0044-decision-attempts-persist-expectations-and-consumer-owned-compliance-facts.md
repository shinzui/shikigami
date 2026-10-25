# 0044. Decision attempts persist expectations and consumer-owned compliance facts

Date: 2026-10-25

Status: accepted

## Context

A provider can finish while the enclosing workflow result append is lost. An
in-memory collector cannot distinguish that call from a later retry after a
worker restart. Baikai's ModelCallEvidence has no supported decoder, and ordinary
agent runs do not carry the reviewed artifact binding required by sanctioned run
evidence.

## Decision

The additive decision ledger owns invocation bindings and actual-attempt records.
An invocation commits program, parameter and derivation identities, selected model,
policy reference and an input commitment. It omits input/prompt payloads. Reusing
an invocation identity with different binding bytes is refused.

A run-row database lock serializes admission across connections. Admission counts
prior expected calls, checks duration and configured resource limits, allocates an
ordinal and commits a fresh UUID expectation before returning a token. Unknown
usage and unresolved calls cannot reset constrained tokens or cost to zero. A
10,000-attempt hard limit bounds internal reports; detail queries use stable
ordinal cursors and pages of at most 200 calls.

Terminal writes atomically preserve the status, exact encode-only provider JSON
and versioned Shikigami CallComplianceFacts. Identical completions converge;
conflicting completions are refused. A terminal write fault leaves the expectation
unresolved. A new actual call after a lost workflow append receives a new ID and
retains every previous attempt.

Live typed evidence and reloaded facts feed one evaluator in
Shikigami.Attestation.Compliance. Facts preserve requested and observed identities,
translation quality, correlation, usage/cost uncertainty and exact rational cost.
Unsupported fact versions fail explicitly. The selected runtime does not provide
reliable node/retry lineage to the provider wrapper; the ledger records grouping
and order without inventing relationships. A constrained retry assessment with
unknown lineage remains an explicit uncertainty, never a clean compliance claim.

Ordinary runs expose an unsigned decision report with an optional policy
assessment. They acquire no reviewed-artifact binding. When a caller supplies a
real existing binding, facts-based finalization uses the same artifact, result,
child and lifecycle guards, and the existing validated EvidenceStore catalog
writes the original rich provider JSON in its atomic projection transaction.

## Alternatives rejected

Reconstructing typed provider records from JSON would invent an unsupported
upstream decoder. Assigning identities only at terminal capture would lose the
crash window before capture. Overwriting an earlier attempt on workflow retry
would erase actual spending. Treating missing cost as zero would permit a restart
to replenish a budget. Probability/confidence output cannot substitute for an
actual provider terminal.

## Consequences

Completed decisions still need their workflow outcome journals; this ledger does
not make remote execution exactly once. Unresolved records remain inspectable and
may require reconciliation. Report refresh is serialized and a new admission
invalidates a stored report snapshot. Raw evidence survives facts-only sanctioned
finalization without creating another lifecycle authority or changing existing
payload bytes.

## References

- [Plan 75](../plans/75-persist-decision-call-evidence-across-retries-and-restarts.md)
- [ADR 0010](0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md)
- [ADR 0041](0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md)
- [ADR 0043](0043-decision-provider-wrappers-own-actual-attempt-boundaries.md)
