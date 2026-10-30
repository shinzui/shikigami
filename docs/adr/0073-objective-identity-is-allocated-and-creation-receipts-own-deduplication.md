# 0073. Objective identity is allocated and creation receipts own deduplication

Date: 2026-10-30

Status: accepted

## Context

An objective is an entity owned by Shikigami. The initial implementation used a
creator/operation digest as its entity ID. That confused the creation operation's
deduplication locator with the identity of the created entity. The current domain
standard requires an allocated, prefix-bearing TypeID for a service-owned entity.
The service is unused and ADR-27 permits establishing a clean first-release baseline.

## Decision

Declare `ObjectiveId` in the workspace as a generated TypeID-v7 domain with prefix
`shikigami_objective`. Reuse the generated abstract type in the hand-owned objective
model. Its checked parser and JSON decoder own canonical prefix, UUID version and
variant admission; no application wrapper or public unchecked text constructor exists.
Creation allocates a fresh UUIDv7 TypeID. Database adapters render the type explicitly
and refine stored locators before returning them to the domain.

Preserve ADR-68's creator-scoped operation receipt as the deduplication authority.
The origin lock, objective state, immutable payload, lifecycle append and receipt
commit atomically. Concurrent candidates may allocate different IDs, but a losing
candidate rolls back before receipt recovery. A repeated operation returns the
original committed ID and receipt; it never derives a new entity from the locator.
A changed request under the same operation remains a conflict. Denial and origin
verification continue to precede persistence.

This is a deliberate first-release identity and event-field change. Retain the
strict breaking diff and qualify fresh histories and same-build replay. Do not
add an arbitrary-text decoder or promise access to an old populated deployment.
The protected objective JSON ID also becomes a checked JSON string. No developer
database is reset. Future deployed changes require normal evolution rules.

## Consequences

Objective lifecycle fold identity changes. Existing `snapshotPolicy = Never`
continues to apply; there is no state-codec cache to invalidate. UUIDv5 workflow
and retry coordinates owned by execution and worker-session runtimes retain their
separate technical derivation and nominal types. User-authored objective assignment
keys remain nominal locators within an objective; they do not become independently
allocated entities.

## References

[ADR 27](0027-the-first-release-establishes-one-clean-durable-baseline.md),
[ADR 68](0068-objective-creation-has-authority-before-association.md),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md), and
[the domain standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids).
