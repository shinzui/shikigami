# 0093. Review entities are allocated behind durable request receipts

Date: 2026-10-31

Status: accepted

## Context

Practice reviews and their adjudications survive producing workflows. ADR-31
requires cross-workflow convergence, immutable candidate recording before
retirement, and cleanup of competing candidates. Those requirements establish
stable request coordinates; they do not make application ReviewId and
ResolutionId values native runtime coordinates. Their previous UUIDv5 factories
derived entity names instead of allocating them. The checked UUIDv7 domain also
requires the owner to insert its identity before decoding a model proposal.

The adopted identity guide is
`mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids`.
ADR-27 permits a deliberate unused first-release contract reset while retaining
real authority, privacy and same-build recovery.

## Decision

The practice-review memory owner allocates private UUIDv7 KindID values with
prefixes `shikigami_practice_review` and
`shikigami_practice_review_resolution`. Readers require the exact prefix,
canonical encoding and UUIDv7 variant/version. Parsing establishes no ownership
and imposes no current-clock condition on retained identities. Constructors,
representation coercion and Generic construction are unavailable to consumers.

Application migration 0032 adds immutable allocation receipts. Review receipts
are scoped by the resolved creator and structured target-repository, caller-key,
practice and specialist coordinates. They bind the full normalized trigger,
practice, specialist and creator. A conflicting binding refuses; concurrent and
lost-response retries recover the committed winner. References have a checked
journal codec and private positional representation. Before recording a verdict,
the owner rechecks its current creator, retained receipt, identifier and verdict
metadata. A deserialized reference is a claim, not an authority grant.

The Flow reserves its review identity in the declared
`practice-review-reserve-identity` step before recall, evidence or evaluation.
It replaces the proposal's reviewId before decoding the verdict and supplies the
same allocated ID for an incomplete-evidence verdict. Models cannot allocate
application identities.

Ingress authorizes an ID-free PracticeReviewResolutionRequest. Its strict codec
refuses a caller-selected resolutionId. The existing authorizer still checks the
opaque submission evidence before queue publication. Submission Show is redacted
and there is no serialization instance. The schema-2 envelope receipt binds the
full canonical request, verified subject, authority kind, source and time through
a versioned structured commitment. This binding checksum does not authenticate
its source; the configured ingress authorizer remains that authority.

After finding the provisional review, the memory owner checks the review creator
and reserves a ResolutionId under the review/caller-key pair. Its receipt binds
the complete canonical command. Changed commands refuse before recording a
candidate. The journaled resolution result carries the allocated complete
resolution and MemoryId so history uses the owner's identifier. Transport/store
failures remain exceptions; they cannot become permanent journaled refusals.

Kioku MemoryIds remain technical UUIDv5 mappings from the allocated entity IDs.
The existing record-before-retire, cross-workflow replay and loser cleanup
protocol remains authoritative. Receipts add no delivery status or second
workflow state machine. This supersedes ADR-31's entity-ID derivation and
no-application-table statements, while preserving its memory transition decision.

## Alternatives rejected

Keeping entity UUIDv5 values because the memory locator is deterministic confuses
application allocation with technical addressing. Random allocation inside a
journal step alone loses cross-workflow and lost-response convergence. Reserving
a resolution at unauthenticated ingress permits a refused request to preempt its
logical key. Accepting a proposal's entity ID delegates allocation to a model.
Reusing one memory row for provisional and resolved content still conflicts with
immutable Kioku aggregates.

## Consequences

Review and resolution payloads intentionally change before first release. There
is no legacy ID factory or permissive reader. Native declaration findings must
be retained under ADR-27 and the new committed baseline must pass the ordinary
strict gate. Aggregate replay-impact neutrality cannot establish compatibility
of the changed workflow result or identity contract.

Allocation receipts outlive workflow garbage collection. Operational retention
must preserve them with their review data. A receipt and Kioku recording use
separate transactions: interrupted allocation is recovered from the receipt;
interrupted memory publication is recovered by the existing idempotent candidate
and retirement protocol. No developer database is cleared by this change.

## References

- [ADR-31](0031-practice-review-adjudication-is-a-logical-memory-transition.md)
- [ADR-27](0027-the-first-release-establishes-one-clean-durable-baseline.md)
- [Plan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md)
- [Workflow versioning](../workflow-versioning.md)
