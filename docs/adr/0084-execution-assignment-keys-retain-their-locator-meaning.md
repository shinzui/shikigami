# 0084. Execution assignment keys retain their locator meaning

Date: 2026-10-30

Status: accepted

## Context

Whole-assignment selection, execution bindings, provider-call receipts and
workspace admissions shared Text with unrelated objective and worker assignment
identities. Production derives these keys from a workflow coordinate, or from a
workflow/message pair for a conversation. They locate the frozen selection and
its execution; no independently allocated assignment entity is created here.

## Decision

Use private AssignmentKey through selection resolution, persisted execution
bindings, receipts, inspection, workspace instruction loading and transfer checks.
Own the established nonempty/at-most-256-character rule in its constructor and
JSON decoder. Preserve exact text, including existing whitespace and Unicode
acceptance. Do not add Generic, Num or IsString construction.

Keep the existing versioned assignment and conversation digest derivations in
the concept owner and reexport them from SelectionRuntime. They remain total for
all workflow/message text, including empty initial coordinates. Execution-id
hashing consumes the same JSON string. Hasql encoders lower AssignmentKey at the
database boundary; domain callers retain it. Remove only scalar checks made
redundant by the private constructor. Whole-request authority, immutable pinned
selection, concurrency, accounting and workspace matching checks remain.

## Alternatives rejected

Using objective or worker assignment ids conflates separately governed
coordinates. Minting a random identity for this locator would change stable
execution lookup and deduplication. Leaving Text in domain records would permit
unchecked construction and substitution. Trimming or imposing a new grammar
would change the admitted domain independently of this nominal correction.

## Consequences

Complete selection, call-receipt and workspace-admission wire controls retain
primitive string bytes before invalid-bound tests. Derivation controls include
empty, Unicode and long input. Compiler clients reject objective/worker key
substitution, representation coercion and generic construction. This does not
classify every other identity or complete the scalar census.

## References

[ADR-52](0052-assignments-pin-whole-run-selection-and-account-every-provider-attempt.md),
[ADR-53](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
and [the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids).
