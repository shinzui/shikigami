# 0045. Flow policy pins pending decisions and retains completed result codecs

Date: 2026-10-25

Status: accepted

## Context

Triage can commit before investigation has prepared. A deployment in that gap
must not silently change the second decision's model or local derivation.
Conversely a completed outcome must remain readable after its executable and
credentials are removed. Existing Routing and PracticeReview still use the
process default, while the new example uses only explicitly selected models.

## Decision

The typed Decision capability journals the complete finite policy for every
compiled slot before any invocation. Preparation commits the selected immutable
program, effective parameter/derivation identity, model binding and input.
Result execution resolves only that prepared contract. Historical model bindings
may be retained separately from active aliases, granting no additional authority
to new runs. Missing pending state or binding yields a bounded refusal before
provider dispatch; process defaults never substitute.

The result journal stores a versioned full validated value. Historical pure
codecs live independently of executable registrations and domain validators.
Replay decodes the committed value without re-entering the executable, changing
its confidence or re-deriving its branch. Unknown historical versions fail
explicitly. Deployment compatibility therefore includes codec retention even
when a program is no longer dispatchable.

`FlowDef.requiresDefaultModel` declares whether a Flow needs the ambient model.
Decision-only examples bypass its unused default-model admission. Routing,
PracticeReview and all prior flows retain that check. Every actual selected
decision call still receives final tuple/profile and evidence preflight.

Closed decision labels map to literal checked preparation/result names. Slots
are one-use per generation. The actual `shikigami-flow-decisions-v1` patch call
guards the declared segment. Its false branch preserves the old interpreter;
a new decision Flow encountered under an old snapshot refuses the unavailable
capability without a policy lookup. Unbounded future loops require rotation.

The Flow retains branch authority. Investigation routes are proposals, decoded
strictly and validated against the journaled catalog and declaration before
governed child creation. Ordinary sink enqueue remains in the existing durable
lifecycle. Provider output cannot create new effect authority.

## Alternatives rejected

Pinning a model only when the second slot starts would adopt deployment drift.
Using the current program reference on replay would reinterpret old local state.
Keeping executables forever just to decode outcomes couples read compatibility
to active execution authority. Removing ambient model checks globally would
weaken existing router and review protection. Treating a call as exactly once
would hide the provider/action-to-journal crash window.

## Consequences and evidence

Workers and one-off durable runs share decision-service construction. Operators
must retain exact pending bindings/state or accept a bounded refusal, and retain
codecs for historical completed journals. Roll forward across patch introduction.

The PostgreSQL acceptance suite drives actual Handan/Shikumi and migrated workflow
journals. It proves two model IDs and three internal attempts, completed replay
with removed executables and credentials, original pending version retention,
missing-state refusal, local derivation with identical provider requests,
terminal persistence failure, lost-append repeat accounting, old patch isolation,
profile/default checks, route authority, and child/sink deduplication. Confidence
is retained result data and never substitutes for call-compliance evidence.

## References

- [ADR 0041](0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md)
- [ADR 0042](0042-decision-admission-intersects-operator-agent-and-pinned-profile-authority.md)
- [ADR 0043](0043-decision-provider-wrappers-own-actual-attempt-boundaries.md)
- [ADR 0044](0044-decision-attempts-persist-expectations-and-consumer-owned-compliance-facts.md)
- [Plan 76](../plans/76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md)
- [Authoring guide](../shikumi-flow-decisions.md)
