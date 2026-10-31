# 0107. Profile and objective corruption refuses within the owning transaction

Date: 2026-10-31

Status: accepted

## Context

The remaining decoder audit found two owners still using SQL decoder refinement
for retained JSON. Invalid workspace process profiles became store failures.
Objective snapshots and receipts did likewise, while checkpoint decoding could
turn corrupt retained intent into absence. An inner join from a worker result to
its protected payload could omit the result entirely when its JSON reference was
unreadable. Treating these conditions as normal rejection could retain a negative
command receipt that prevents recovery after the metadata is repaired.

## Decision

Process-profile reads return `Either WorkspaceError (Maybe ...)`. Missing rows
remain `Right Nothing`; invalid JSON or invalid existing profile invariants return
`WorkspaceBindingConflict` and condemn the transaction. Worker cleanup handles
this refusal explicitly before selecting a fallback Unix identity. A retry cannot
allocate another identity in place of unreadable retained metadata.

Objective SQL statements keep typed `Either () value` row results. The owner
decodes those results within its transaction, condemns corruption and uses its
existing abort mechanism to return `ObjectiveConflict`. It validates retained
snapshots against the existing snapshot validator. SQL failures continue to return
`ObjectiveUnavailable`. Corruption cannot be recorded as a definitive negative
command outcome.

Worker-result lookup uses a left join so a present result with an unreadable or
missing protected payload stays visible to the decoder. Both its receipt and the
complete assignment-result envelope must decode before source validation. A
missing result remains distinct from a result whose referenced payload is absent.
The retained result's keys and payload digest, assignment and disposition must
agree before assessing caller evidence. Even a type-correct changed source body
is corruption rather than a definitive rejection of a retryable command.
Checkpoint JSON decodes directly into its owned type rather than passing through
an optional JSON-to-domain conversion.

The process-policy version is a closed `ProcessPolicyFormat`, with only
`ProcessPolicyV1`. Its codec preserves the admitted numeric JSON value `1` and
rejects unsupported formats at decoding. It is separate from Git-record and
process-routing formats. This changes neither valid policy commitments nor
workflow steps or identities; other policy scalars remain under audit.

## Alternatives rejected

Mapping every database failure to corruption hides outages. Refining owned JSON
in Hasql loses the owner refusal. An uncondemned `Left` permits earlier writes to
commit if ignored. An inner join can conceal a corrupt retained effect reference.
Persisting a negative receipt for unreadable checkpoint/result metadata makes
repair unable to recover the original command.

## Consequences

Six real PostgreSQL profile controls cover valid concurrent allocation, absence,
SQL failure, malformed JSON, invalid Unix identities and unsupported formats. A
deliberately ignored refusal rolls back an earlier workspace freeze while keeping
the unresolved effect and reserved identity. Objective controls cover corrupt
snapshots, command and creation receipts, checkpoint intent and result joins,
preserving native event/receipt counts and allowing recovery after repair.
Existing Objective-store and worker profile/provisioning/transfer groups pass.
Complete policy/profile codecs preserve old bytes and the policy commitment.

These results qualify the selected macOS metadata boundaries. They do not certify
the remaining stores, the exhaustive scalar classification, native Linux process
containment, or a populated cross-build migration. The complete audit remains
open in [plan 108](../plans/108-complete-the-remaining-domain-scalar-identity-and-decoder-audit.md).

## References

[ADR-90](0090-execution-and-session-json-corruption-is-a-transactional-domain-refusal.md),
[ADR-98](0098-resource-row-decoding-refuses-corruption-inside-the-transaction.md),
[the current acceptance record](../evidence/plan-108/acceptance.md),
[process-profile controls](../../shikigami-core/test-postgres/Shikigami/WorkspaceProcessProfileStoreSpec.hs),
and [Objective-store controls](../../shikigami-core/test-postgres/Shikigami/ObjectiveStoreSpec.hs).
