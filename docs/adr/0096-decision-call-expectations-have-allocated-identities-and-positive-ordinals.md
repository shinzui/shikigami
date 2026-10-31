# 0096. Decision call expectations have allocated identities and positive ordinals

Date: 2026-10-31

Status: accepted

## Context

ADR-43 places admission around each actual provider attempt; ADR-44 retains its
expectation in decision_attempts even when the enclosing result append is lost.
That application record has its own lifetime and identity. The private
AttemptToken previously held an untyped UUIDv4 string and Natural ordinal, while
outcomes and reports flattened those values to Text and Natural. Zero ordinals
could enter decoded reports, and the memory hooks did not verify a changed token
ordinal. Neither the token's private constructor nor its SQL primary key made
this an external identifier or a logical retry locator.

## Decision

DecisionCallId is a private, non-Generic KindID-v7 value with prefix
shikigami_decision_call. Allocate it outside the SQL transaction before admitting
an actual call. A later actual transport attempt gets a fresh identity, including
a retry after a lost enclosing result append. Do not deduplicate distinct remote
attempts through a logical-request allocation receipt.

The parser checks prefix, UUID version/variant and canonical encoding. It does
not check against the current clock when reading retained evidence. Exact string
JSON and explicit toEncoding retain the allocated identifier through the private
token, in-memory map, committed DecisionOutcome and StoredDecisionCall report.
Render Text explicitly at SQL and correlation boundaries. Syntax never confers
permission to finish an expectation; retained ownership and ordinal checks remain.

DecisionCallOrdinal is a distinct private positive signed-int64 value. It is
separate from selection's CallOrdinal and from observed call counts. The run-row
lock still assigns its value, and admission retains the independent 10,000-call
ceiling and configured resource limits. JSON decoding rejects zero, negative,
fractional and overflowing values. Provider evidence receives the explicit
Natural projection accepted by its API. Both durable and memory hooks refuse a
changed ordinal before updating terminal state.

Baikai continues to allocate its own independent provider evidence call ID.
Shikigami correlates the retained expectation to that evidence; it does not
rewrite provider call IDs or invent retry lineage. The contract is described by
`mori://shinzui/baikai/docs/model-call-evidence` and the existing application
adapter in Attestation.Evidence.

Malformed retained application call IDs fail through the evidence owner's data
refusal, before a report or another admission can treat them as valid calls.
No row is silently dropped and transport failures keep their separate meaning.

## Alternatives rejected

Keeping arbitrary Text in outcome/report records loses the entity boundary after
allocation. Reusing execution attempt IDs conflates separate ledgers. A numeric
instance would admit zero and unchecked arithmetic. Hashing an invocation into a
call ID would merge distinct attempts after retries. Replacing Baikai's evidence
ID would cross its producer authority.

## Consequences

The unused first-release baseline deliberately replaces former UUIDv4 call
strings with checked allocated IDs under ADR-27. No old-ID fallback is added.
The DSL labels, order, effects and result declaration names remain unchanged;
a neutral native diff cannot establish old opaque-payload compatibility.

Same-build replay, terminal convergence, unresolved expectations, run-wide
resource accounting and exact provider evidence remain separate acceptance
requirements. Program/model descriptor and the complete scalar census review
remain open in plan107.

## References

- [ADR-27](0027-the-first-release-establishes-one-clean-durable-baseline.md)
- [ADR-43](0043-decision-provider-wrappers-own-actual-attempt-boundaries.md)
- [ADR-44](0044-decision-attempts-persist-expectations-and-consumer-owned-compliance-facts.md)
- [Plan107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md)
