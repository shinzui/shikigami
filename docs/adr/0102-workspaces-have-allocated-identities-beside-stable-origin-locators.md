# 0102. Workspaces have allocated identities beside stable origin locators

Date: 2026-10-31

Status: accepted

## Context

ADR-63 keeps an immutable workspace allocation through same-owner follow-ups,
owner transfer and terminal cleanup. The provider/resource address is derived
from its original run or assignment. It is a technical origin locator; deriving
that address does not allocate an identity for the longer-lived workspace entity.

## Decision

WorkspaceBinding retains a private WorkspaceId backed by UUIDv7 with prefix
`shikigami_workspace`. Checked text and UUID capture reject another prefix,
version, variant or noncanonical encoding. JSON encodes the canonical string.
The type exposes no constructor, Generic or coercion escape.

The PostgreSQL 18 allocator calls `pg_catalog.uuidv7()` within the existing
reservation transaction. The logical-origin insert, unique workspace identity
and protected binding form one receipt. Concurrent reservations and retries
return the committed winner, comparing the full immutable request/repository/
storage binding with its retained identity. A refused reservation condemns the
transaction. An aborted candidate never becomes the retained workspace.

The provider/resource derivation and filesystem addresses retain their exact
bytes. They remain locators beside the allocated identity. Transfer changes
owner admission, not the original allocation or its identity. Cleanup retains
its existing receipt lifetime. Identity supplies no action or transfer authority.

## Alternatives rejected

Renaming the deterministic address as an entity ID leaves its allocation
semantics unchanged. Allocating a new identity for every follow-up or handoff
splits one retained workspace into several entities. Generating another ID after
a lost response loses convergence. Replacing the physical address would move
existing directory and provider coordination without solving the identity receipt.

## Consequences

Fresh schema provisioning adds a unique `workspace_id` and requires it to match
the protected binding. This first-release migration does not backfill populated
bindings or delete a developer database. The new field intentionally changes
binding JSON and binding digests under ADR-27. Old opaque metadata/markers are
not compatible; unchanged native workflow declarations do not prove otherwise.
There is no old-identity inference or fallback reader.

Real database tests cover concurrent/lost-response reservation, rollback,
immutable binding conflicts and distinct origins. Exact action proofs bind the
allocated identity. Existing follow-up and transfer fixtures retain the complete
binding. These checks do not qualify Linux containment or independent service
restart; those remain final qualification work.

## References

- [ADR-27](0027-the-first-release-establishes-one-clean-durable-baseline.md)
- [ADR-63](0063-handoffs-establish-epochs-only-after-fences-and-versioned-owner-receipts.md)
- [PostgreSQL 18 UUID functions](https://www.postgresql.org/docs/18/functions-uuid.html)
- `mori://MMZK1526/mmzk-typeid` public `mmzk-typeid/src/Data/KindID/V7.hs`
  (`decorateKindID`, `checkKindID`; source-file artifact URI pending).
- [Plan107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md)
