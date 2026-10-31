# 0094. Accounting entities use allocated identities and root origin receipts

Date: 2026-10-31

Status: accepted

## Context

ADR-51 gives resource roots, exclusive allocations and actual transport attempts
application-owned rows that survive terminal workflow collection. Their public
Text constructors and Generic instances admitted arbitrary strings. Root
admission derived a UUIDv5 from the native workflow coordinate; actual dispatch
producers minted UUIDv4 strings. Neither a private hash namespace nor retained
SQL rows establish an external or native-runtime identity authority.

The adopted rule is
`mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids`.
Native workflow coordinates still need retry deduplication, and resource
conservation, settlement and workspace fencing must survive the identity change.

## Decision

ExecutionRootId, AttemptId and AllocationId are private KindID-backed UUIDv7
values with full singular prefixes `shikigami_execution_root`,
`shikigami_execution_attempt` and `shikigami_execution_allocation`. Public
factories allocate in IO. Readers require the exact prefix, canonical encoding
and UUIDv7 version/variant, without comparing retained timestamps to the current
clock. No Generic, literal, numeric or enumeration construction is exposed.
SQL, evidence, RPC and cryptographic-preimage adapters render explicitly.

The two actual-attempt producers use the allocator. Existing dispatch and
settlement records retain AttemptId through recovery. Empty-attempt guards
become redundant and are removed; operation matching, positive generation and
all authority/fencing checks remain. Allocation APIs accept already allocated
AllocationIds and retain their existing exclusive-capacity and narrowing rules.
This decision does not classify or change logical OperationId coordinates; their
construction and owning-authority audit remains part of plan107.

Native-run enrollment separates the workflow coordinate from the resource
entity. Migration 0033 adds execution_root_origins, keyed by the opaque native
WorkflowId and binding resolved creator, agent and immutable admitted envelope.
The root ID is unique in that table. The origin is independent of the workflow
journal's lifetime. Descendants inherit the admitted root and cannot enroll a
replacement; a fresh unresolved creator is refused before allocation.

Origin receipt and root publish in one transaction. A candidate UUIDv7 is
allocated outside the retryable transaction. Receipt insertion happens before
root creation so a concurrent loser does not publish an unused root. A deferred
foreign key requires the selected root to exist at commit. Identical retries,
including retries without the first response, recover the winning root. Changed
binding or an unexpected supplied reference refuses and condemns the whole
transaction. A failure publishing the root rolls its origin back. No delivery
status or second workflow state machine is introduced.

Delegation's SQL reference restores the checked root type before domain
comparison, including a captured corruption result. The operator inspection
argument refines before configuration IO. Existing root-first lock ordering,
quota conservation, current-owner checks, irreversible cancellation, unknown
holds, settlement and root inheritance remain their own authorities. Identity
syntax never grants access or refunds capacity.

Test fixture selectors produce explicit synthetic, fixed-timestamp UUIDv7 test
data through checked parsers. These local test modules are not production
allocators. Real allocator uniqueness, domain/codec admission, origin races and
rollback are exercised independently.

## Alternatives rejected

Keeping root UUIDv5 or attempt UUIDv4 values because accounting is implemented
beside a workflow confuses application entities with the native coordinate.
Minting a fresh root on every retry resets identity and allowance. Creating the
root before arbitrating the origin can leave losing roots behind. Recording an
origin outside the root transaction can retain a dangling receipt after a
publication failure. Treating a parsed ID as an authorization proof would bypass
the existing operation/root/owner fences.

## Consequences

This intentionally changes the first-release identity domain in queued inputs,
retained execution/workspace records and operator arguments under ADR-27. There
is no old-string reader, UUIDv4 attempt fallback or derived-root factory. Native
helper-reference/aggregate replay neutrality does not establish compatibility
with those old opaque payloads. Subsequent deployments follow the ordinary
workflow and identifier evolution rules.

Origin receipts and their accounting roots require coordinated retention; native
workflow collection cannot remove them. Low-level accounting APIs retain their
existing explicit enrollment capability and accept allocated IDs; native-run
admission owns the origin receipt. This change does not activate resource
policies or process tools by default and does not qualify Linux containment.
The complete domain-value and other decoder-owner audit remains open.

## References

- [ADR-51](0051-resource-roots-own-conservative-reservations-and-actual-attempts.md)
- [ADR-52](0052-assignments-pin-whole-run-selection-and-account-every-provider-attempt.md)
- [ADR-27](0027-the-first-release-establishes-one-clean-durable-baseline.md)
- [Plan107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md)
- [Workflow versioning](../workflow-versioning.md)
