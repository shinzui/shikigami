# 0095. Logical operation keys retain their coordinate contract

Date: 2026-10-31

Status: accepted

## Context

OperationId is shared by execution position lookup, resource reservation
correlation, worker/Objective command receipts and workspace factual receipts.
Its public Text constructor and Generic instance admitted empty keys. Its name
alone does not establish an allocated entity or the ownership of its identity.

ADR-53 and the current execution writer establish the execution authority:
operationIdFor derives an exact versioned coordinate from the technical
ExecutionId and committed operation cursor, and acceptOperation checks that
coordinate under the execution lock. Workspace providers retain and match that
accepted operation and its fingerprint before effects. Actual dispatch attempts
are separate allocated entities under ADR-94.

Other call sites have concrete locator authorities: native child coordinates
identify delegation reservations; worker action/caller keys address immutable
receipts within a session; Objective caller keys address fingerprint-bound
receipts within the authorized objective. Handoff and checkpoint keys derive
from retained intents. These are logical retry/position locators. A SQL primary
key or a private hash prefix alone is not the justification for that exception.

## Decision

Keep OperationId as the existing nominal logical-key type and preserve all
admitted string bytes. Its constructor is private, its parser rejects empty
Text without trimming or rewriting it, and it has no Generic, literal or numeric
construction. String JSON and explicit toEncoding preserve the existing wire
representation. This is the natural/composite locator exception in
`mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids`;
it does not exempt accounting entities or future independent application
entities from allocated UUIDv7 identity.

Total factories accept a structural NonEmpty Char value or a nonempty prefix
plus suffix. Each current owner keeps its existing prefix and preimage recipe.
Execution/cursor, worker workflow/generation/label, model selection, native child,
checkpoint and handoff coordinates therefore retain their bytes. Factory
construction establishes nonemptiness; concrete write owners retain their
existing length, scope, fingerprint, revision and authority policies. Do not
invent a universal TypeID format or normalize opaque caller keys.

SQL, RPC, evidence, inspection and cryptographic preimage adapters unwrap
explicitly. Operator operation flags refine at parsing, before configuration or
instruction IO. Flows and durable workflow helpers use total owner-prefix
factories without changing valid step labels, order, effects or result bytes;
this representation-preserving change requires no patch.

The workspace transfer pending-reader captures invalid retained keys as data.
It refuses the entire pending set before any receipt publication, and its IO
owner returns an unresolved fence. A malformed unsettled operation cannot be
silently omitted or satisfy the settled predicate. The existing transaction and
fence authorities remain in place.

## Alternatives rejected

Allocating a new entity ID for every technical retry coordinate would separate
retries that must address the same accepted position or receipt. Treating
OperationId as an allocated entity merely because of its name confuses that
locator with the separately allocated actual attempt. Leaving Generic exposed
bypasses the parser. Dropping a malformed pending row could permit an incorrect
handoff; mapping it to a transport failure loses the owning domain disposition.

## Consequences

Existing nonempty key strings retain their exact wire and lookup meaning. Empty
values fail at construction/decoding. Replay still checks exact accepted
specifications, current authority, fingerprints and ownership, and never derives
permission from key syntax. Existing owner limits and scope checks remain.

The complete scalar/identity and remaining decoder-owner review in plan107 stays
open. This decision does not classify unrelated identifiers, turn every stored
row into a boundary DTO, or claim old opaque-payload compatibility for ADR-94's
separate first-release accounting-identity change.

## References

- [ADR-53](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md)
- [ADR-94](0094-accounting-entities-use-allocated-identities-and-root-origin-receipts.md)
- [Plan107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md)
- [Workflow versioning](../workflow-versioning.md)
