# 0041. Durable decisions bind program state and preserve committed outcomes

Date: 2026-10-21

Status: accepted


## Context

[MasterPlan 13](../masterplans/13-compose-shikumi-decisions-in-durable-flows.md)
plans typed Shikumi program invocation inside durable Flows. Its admission contracts are implemented by plan 73. This decision also specifies
the runner and workflow contracts the remaining children must implement; it does
not claim the durable capability is complete.

`mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs`
plans probability-bearing outputs, local decision settings, Jev support and
calibration. A threshold, cut or weight can change a derived answer without
changing the provider request. Shikumi intentionally permits cache/trace replay
under new settings to produce a new answer. A committed workflow outcome must
retain its original meaning across deployments instead.

Today's program parameters already contain instruction overrides and
demonstrations. Structural shape omits their values and opaque functions. Neither
a shape fingerprint nor a provider request/cache key identifies a complete
executable decision.


## Decision

Shikigami owns the Flow-facing static-slot/model-alias/typed-input interface and
versioned validated result. Shikumi and Handan API adaptation stays inside the
program registry and runner. This isolates dependency changes; it does not
promise that upstream APIs never change. [Shikumi MP-12](mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs) is a coordination
dependency, with Jev, probability-backed types and calibration outside MP-13's
initial acceptance criteria.

Immutable program descriptors bind code, schemas, validators, a versioned digest
of complete effective parameter state, and local derivation semantics. State
includes each node's parameters and effective defaults; future thresholds, cuts
and weights join that identity when supported. Opaque executable behavior remains
covered by implementation identity. Changed state or derivation requires a new
immutable registration, even for an identical provider request.

The complete finite policy snapshot pins those identities for every slot before
the first invocation. The corresponding executable and state are retained in the
immutable registration. Pending execution uses that exact state or fails before
dispatch; current settings cannot substitute for missing pinned state. Attempt
records carry identities rather than prompt/demonstration payloads.

A committed outcome is read through its retained versioned durable-result codec
before consulting executable registrations. Preserve the full validated result,
including any probability/confidence data. Its stored JSON need not match the
model-facing response schema. Replay never re-runs validation under new domain
policy or recomputes a derived answer with new settings. Unknown codec versions
fail explicitly rather than causing a new provider call.

Judgment probabilities are result data, distinct from provider-attempt and
compliance evidence. They cannot close an unresolved expected call, establish
served-model identity or satisfy terminal accounting.


## Alternatives rejected

Waiting for all of [Shikumi MP-12](mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs) would delay a generative typed-program use case
that current APIs can support. Coupling the Flow API to Jev or a probability type
would make optional backend work a prerequisite for durable composition.

Using only program shape or request identity would miss changes to local meaning.
Re-deriving an old result from saved probabilities would let deployment settings
change an already committed branch. Flattening a rich result to a label would
discard the validated explanation of that branch. Treating probability data as
execution evidence would conflate model judgment with transport accounting.


## Consequences

Plans 73–76 can proceed on current dependencies. They must prove parameter-state
identity, pending-state retention/refusal and committed-result reuse using
current-API fixtures. Future upstream adoption needs qualified adapters and new
program/result versions, with retained codecs for supported historical runs.
It must preserve the distinction between deliberate evidence re-derivation and
workflow replay. Implementation evidence belongs here when those tests pass.


## References

- [MasterPlan 13](../masterplans/13-compose-shikumi-decisions-in-durable-flows.md)
- [ADR 0007](0007-a-resolved-profile-is-a-run-local-policy-snapshot.md)
- [ADR 0010](0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md)
- [ADR 0015](0015-a-kioku-write-answers-on-two-layers-and-a-journaled-step-keeps-its-bytes.md)
- `mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs`

## Registration implementation

Plan 73 computes parameter commitments from ordered effective node instructions,
serializable `Params` demonstrations, and explicit local derivation state. It
retains that state with the executable. Signature-level typed demonstrations are
refused at registration: the selected upstream existential `Predict` constraints
do not supply a JSON encoder for them. Authors put demonstrations in `Params`,
which provides a complete serializable representation. Opaque `Embed` behavior
and closures remain covered by the explicit implementation identity.

The executable and result-codec registries are separate. Retiring an executable
does not require retiring its pure result codec, and decoding through that codec
does not rerun a current domain validator. Contract tests preserve a result's
confidence field with an empty executable registry and reject changed state under
a reused immutable registration key.
