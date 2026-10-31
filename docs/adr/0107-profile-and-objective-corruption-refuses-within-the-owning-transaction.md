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

Cleanup-plan inspection and bounded workspace listing follow the same boundary:
raw JSON is decoded in the owning transaction, missing cleanup rows remain
`Right Nothing`, and malformed retained values return `WorkspaceBindingConflict`
and condemn the transaction. Inspection reuses the existing preparation rules
for binding digest, Unix user range and filesystem target spelling; it does not
invent stronger target syntax. Completion reads the retained plan before changing
its completion bit. The maintenance IO adapter maps the domain refusal to
`CleanupRefused` before filesystem deletion or public listing publication, while
SQL failures retain `CleanupUnavailable`. Historical plans without ownership
retain their exact encoding. The remaining workspace stores are reviewed separately below.

Directory skip and sink delivery readers now retain parsed row results as
`Either Text value` until their owning transaction checks them. A malformed
member refuses the whole skip list. Both pool and composable transaction readers
return a fixed owner-specific corruption diagnostic and condemn the transaction;
genuine SQL failures keep their existing store diagnostics. Existing public
`Either Text` APIs and stored representations remain unchanged. The indexed
skip lookup constrains every parsed field (agent, drain stage and run key) by
already checked query parameters; it shares the same row checker without
inventing validation for free-form refusal details or invalid principal claims.

A corrupt delivery status cannot become missing delivery truth or authorize a
new transport call. The existing publisher handles the read refusal before
updating the receipt or sending, and repair recovers the original delivered
receipt with its downstream ID. This boundary covers status decoding; remaining
receipt scalar and identity distinctions stay explicit audit violations.

The HTTP acceptance ledger follows the same rule for checked agent/request/run
keys and its closed `RunDisposition`. It validates all fetched pagination rows,
including the extra row used only to decide whether another page exists, before
constructing cursors or trimming the page. Reconciliation rereads retained
acceptance within its transaction before observing DLQ evidence. Corruption
cannot commit a queue observation or a replacement acceptance; SQL failures keep
the existing unavailable result. The disposition renderer preserves the exact
`accepted` and `dead_lettered` SQL and HTTP spellings.

Workspace binding, control, effect receipt, registered-file and transfer reads
also return owning refusals and condemn their transaction. Binding reads reuse
the allocator's existing path/request predicate, check the allocated identity
column against JSON, and check the immutable origin locator. Transfer reads
reuse existing intent/fence invariants. Registered-file reads keep the row visible
through left joins and validate the stored operation, fingerprint, binding,
prepared receipt and any completed receipt before independent recovery.
Missing related rows or a corrupt fingerprint cannot masquerade as an
unregistered operation. Recovery adapters keep the original effect unresolved.

Same-owner follow-up and successor discovery derive exact workspace locators
from the session's relational assignment coordinates, then use the binding and
transfer owners to inspect those rows. Discovery must not depend on fields
inside the JSON it is meant to validate: a corrupt assignment locator could
otherwise make retained work disappear and authorize a fresh allocation. The
existing origin formula and provider addresses are unchanged, and no new entity
identity or migration is introduced. Current-owner lookup likewise decodes
retained admissions before filtering their owner/epoch, so unreadable admission
cannot authorize cleanup fallback. Typed failures propagate through cleanup,
provisioning, file/Git providers, transfer and process supervision.

Cleanup eligibility and successor/follow-up settlement now compose typed
execution, message, result, session, effect and process reads before deciding
whether work is terminal. An unknown or malformed receipt cannot become zero
pending work, and a denormalized settlement Boolean must agree with the complete
validated receipt. The original absent-pending-receipts compatibility rule stays
in the execution codec. Prior assignments are located by relational coordinates;
corrupt message/result/execution fields cannot disappear behind JSON joins.

Three discoveries lack independent relational attribution: workspace storage
roots, session execution roots and child workflow mappings. These readers decode
the metadata before filtering, keeping bounded accumulators (twenty workspace
bindings, two child matches, or one terminal flag). The query can scan all
remaining rows, and unreadable attribution can conservatively refuse an otherwise
unrelated root or child lookup. This trades availability and scan cost for refusing
unsafe absence; it is not a performance qualification. A future independently
maintained relational index would require its own migration and consistency
acceptance. Existing addresses, identities and table layouts are unchanged.

These checks qualify the named read boundaries, not the remaining scalar audit.

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

Cleanup controls additionally persist a real terminal plan through interrupted
filesystem cleanup, then corrupt its JSON shape or an existing admitted invariant.
Inspection, preparation, completion and maintenance refuse; an ignored inspection
refusal rolls back an earlier control change. Scratch remains present until the
original plan is restored and resumed. A valid listing member beside a corrupt
binding proves whole-page refusal, rollback and recovery; absence and a renamed
table distinguish missing metadata from SQL failure.

Directory controls additionally mutate the agent name, run key and stage of a
complete public skip beside a valid sibling. Whole-list refusal rolls back both
earlier and later tentative writes even when ignored; repair recovers both
members. An invalid external principal claim remains reportable under the
existing refusal contract. Sink controls publish a real delivery, corrupt its
status, prove rollback and no additional HTTP send, then repair the exact receipt
and recover the send guard. Missing rows and renamed tables distinguish absence
from SQL failure in both owners.

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
