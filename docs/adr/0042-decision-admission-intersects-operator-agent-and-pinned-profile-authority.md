# 0042. Decision admission intersects operator, agent and pinned profile authority

Date: 2026-10-25

Status: accepted

## Context

A compiled Flow may choose between several models. The process default response
model cannot express that authority, and a provider/model string from input must
not create it. Pending workflow decisions also need an exact descriptor to
resolve after configuration changes. MasterPlan 14's whole-run execution
selection consumes the same operator catalog while retaining its own permissions.

## Decision

`Shikigami.Decision.ModelCatalog` owns the finite operator alias catalog. Each
public descriptor binds its immutable version, complete model/options digest,
provider/API/endpoint/model/thinking tuple, and opaque credential binding identity
and authority version. Credential values remain process-local and are excluded
from descriptors. Rotation of a secret under unchanged authority need not change
the descriptor; changing endpoint semantics or options does.

Decision admission intersects that catalog with the journaled agent's explicit
`decisionModels` and optional resolved profile. The complete slot policy narrows
profile-forbidden selections and refuses a slot with no remaining models. Unknown
operator aliases fail rather than disappearing silently. Whole-run permission
must be declared separately by its owning capability; decision permission does
not grant whole-run permission.

`Shikigami.Behavior.Provider.Call` owns the shared pure tuple projection and
profile predicate. The existing response builder re-exports them and preserves
its environment constraint behavior. Decisions and future whole-run selection
must use that same predicate. HTTP option compatibility remains in
`Shikigami.Behavior.Compatibility`.

A Flow declares a finite slot inventory. Pure admission rejects duplicate labels,
unknown program contracts and undeclared aliases before constructing a runtime.
Existing flows have an empty inventory. Missing `decisionModels` in historical
agent JSON restores the empty list; encoding that default omits the new key.

## Alternatives rejected

Selecting a model from arbitrary payload strings would let data expand authority.
Using mutable aliases as durable identity would reinterpret pending decisions.
Duplicating the profile predicate would allow admission and transport checks to
drift. Granting decision and whole-run authority through one permission would
silently widen the effect of an existing declaration.

## Consequences

Settei configuration under `behavior.decisionModels` resolves exact generated
HTTP catalog models and the finite test stubs, with separate provider credentials.
Raw candidates for that nested setting are redacted so a mistakenly embedded
credential cannot leak through failed configuration diagnostics. The public
catalog descriptors remain serializable and inspectable.

The admission layer introduces no provider call or workflow step. The runner and
durable interpreter must still check the pinned descriptor at their boundaries;
passing admission alone is not a claim that a provider call occurred.

## References

- [Plan 73](../plans/73-define-typed-decision-programs-and-authorized-model-catalogs.md)
- [ADR 0007](0007-a-resolved-profile-is-a-run-local-policy-snapshot.md)
- [ADR 0011](0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md)
- [ADR 0041](0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md)
