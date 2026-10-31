# 0085. Attempt fencing retains its owner token and generation scope

Date: 2026-10-31

Status: accepted

## Context

Accepted execution attempts fence dispatch and publication with their immutable
reference, lease-owner token and monotonically increasing claim generation.
Attempt generations shared Integer with unrelated epochs; owner tokens shared
Text with application principals and workspace owners. The fence travels through
independent file, Git and process factual owners and the private supervisor RPC.
Keiro workflow generations in protected awakeable publications are a separate,
library-owned coordinate.

## Decision

Retain StateRevision "execution-attempt" throughout attempt state/claims,
dispatch contexts, file/Git/process registrations and receipts, supervisor requests
and process views. Initial undispatched state remains zero; claim advancement uses
the checked type's increment. Active-phase positivity and the private RPC's int64
ceiling remain joint admission checks. Keiro awakeable/workflow generations retain
the actual native Int contract.

Use private ClaimOwner for the executor's lease-owner nonce. Its constructor and
JSON decoder enforce the established 1..256-character rule without normalization.
There is no Generic, Num or IsString construction. The executor continues to mint
a UUIDv4 nonce and renders it through the type's fixed-width UUID adapter. This
is a technical claim-request token, with no independently addressable entity or
lifecycle; it is not an allocated domain entity or a TypeID-v7 claim. Neither this
token nor a caller-created claim grants IO: the store still matches the exact
persisted reference, owner, generation and lifecycle before dispatch/publication.

Domain callers retain the token and generation. JSON, fingerprint and action-hash
inputs keep the same strings/numbers. Remove only redundant scalar checks; retain
lease expiry, stale-owner refusal, fresh authority, current workspace fencing,
conditional dispatch-start, receipt matching and atomic accounting/publication.
Missing retained owners return AttemptClaimLost directly instead of fabricating
an empty owner whose subsequent match would return the same refusal.

## Alternatives rejected

Using worker-owner epochs or native workflow generations conflates separate
fences. Primitive arithmetic permits negative construction and scope substitution.
Using AgentPrincipal for the lease token confuses application identity with a
single dispatch claim. Clamping generations or supplying a fallback owner changes
the fence. Lease expiry still cannot prove that an external mutation stopped.

## Consequences

Complete claim and active-attempt wire controls accompany the existing real
expiry, replacement, late-receipt, restart and independent-publication fixtures.
Compiler boundaries distinguish native workflow generations, worker-owner epochs,
attempt generations, principals and claim tokens. This does not complete the
remaining scalar/identity census or final packaged/runtime qualification.

## References

[ADR-54](0054-execution-attempts-own-dispatch-fences-and-generation-wakes.md),
[ADR-74](0074-domain-state-revisions-keep-their-scope-at-application-boundaries.md),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
and [the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids).
The existing UUIDv4 generator and fixed-width UUID renderer are public contracts
of [uuid](mori://haskell-hvr/uuid/packages/uuid).
