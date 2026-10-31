# 0100. Git intent decoding preserves unresolved publication and origin

Date: 2026-10-31

Status: accepted

## Context

GitStore retains the original accepted claim and the one conditional publication
transition. A lost acknowledgement can leave GitPublishRequested after HEAD has
changed. Factual recovery must retain that intent and its common effect barrier;
it cannot allocate a replacement or infer completion from a prepared candidate.

The JSON readers still used SQL refinement. Their shared receipt column permits
SQL NULL for other effect kinds, but every Git reservation writes its complete
record. A missing Git receipt is therefore malformed metadata, not absent intent.
The joined recovery reader also owns restoring the immutable workspace origin.
GitRecord's numeric format could be decoded at an unsupported version even
though its producer/validity checks required one.

## Decision

GitStore captures optional owned rows as typed Either values. Malformed JSON,
unexpected SQL NULL and an unreadable joined workspace binding return
WorkspaceBindingConflict inside the transaction and condemn coupled tentative
writes. The row remains present and unsettled. Real SQL/connection failures keep
the outer StoreError. No parser/source text is carried in the refusal.

Both direct intent and registered-origin inspectors return an explicit owning
Either around optional absence. Reservation, preparation, publication grant and
factual transitions propagate that refusal. The provider unwraps a data refusal
as FileEffectUnresolved before choosing a directory, creating a replacement,
publishing a receipt or granting another publication. Storage failures retain
its existing FileEffectUnavailable path.

GitRecordFormat is a closed type containing GitRecordV1, with exact numeric-one
JSON and toEncoding. Unsupported and fractional versions fail decoding. The
producer uses that constructor and the redundant numeric validity check is
removed. Valid record bytes, fingerprint preimages, original claim identity,
conditional updates and phase transitions are unchanged. A supported format is
shape, not Git authority; complete record/origin/candidate/claim checks remain.

The actual lost-ack fixture retains GitPublishRequested. Decode refusal leaves
that uncertainty in place: it does not invent GitUnresolved, GitApplied or a
receipt acknowledgement. Factual observation of valid retained metadata remains
possible after owner freeze without granting another command launch.

## Alternatives rejected

Treating an invalid receipt as Nothing allows a fresh reservation. Mapping it to
availability encourages retries without identifying the retained-data refusal.
Returning Left without condemnation can commit an earlier freeze or receipt.
Keeping a nullable SQL decoder outside the owning refusal loses the distinction
between no row and a present Git row with no intent. Treating format one as
numeric application state admits unsupported records through Generic decoding.

## Consequences

PostgreSQL controls establish valid reservations before injecting malformed JSON,
SQL NULL, an unsupported format or an invalid registered origin. The pending
barrier remains; no factual/publication transition succeeds. A tentative freeze
is observed inside the transaction and rolls back on the bad read. The accepted
Git fixture loses acknowledgement after one real local HEAD publication, then
refuses reconciliation/receipt publication on corrupt intent without another
publication or HEAD change. An independent SQL-failure control remains unavailable.

This qualifies metadata/recovery behavior in the existing macOS fixtures. It does
not enable configured process tools or qualify native Linux Git containment and
handoff. Other workspace stores and the complete scalar/identity census remain
open in plan107. Valid workflow labels/order/effects/codecs are unchanged; no
patch is required for these representation-preserving values and invalid-data
refusals. First-release Haskell callers adopt the typed inspectors/format.

## References

- [ADR-53](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md)
- [ADR-90](0090-execution-and-session-json-corruption-is-a-transactional-domain-refusal.md)
- [ADR-98](0098-resource-row-decoding-refuses-corruption-inside-the-transaction.md)
- [ADR-99](0099-assignment-call-readers-preserve-corruption-and-transaction-ownership.md)
- [Plan107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md)
