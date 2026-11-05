# 0041. Durable decisions bind program state and preserve committed outcomes

Date: 2026-10-21

Status: accepted

Updated: 2026-11-05 (Plan 124: local Shikumi execution adapter)


## Context

[MasterPlan 13](../masterplans/13-compose-shikumi-decisions-in-durable-flows.md)
implements typed Shikumi program invocation inside durable Flows through plans
73–76. Admission, actual-attempt governance and persistence, and the durable
capability now share the contracts below.

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
versioned validated result. Shikumi API adaptation stays inside the
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

Plans 73–76 implement these contracts on the selected dependencies. Current-API
fixtures prove parameter-state identity, pending-state retention/refusal and
committed-result reuse. Future upstream adoption needs qualified adapters and new
program/result versions, with retained codecs for supported historical runs.
It must preserve the distinction between deliberate evidence re-derivation and
workflow replay.


## Structured judgment extension (2026-11-03)

Registered programs explicitly declare generative or closed-set judgment
output. Missing capability fields decode as generative, whose historical JSON
remains unchanged. Judgment-only models enter only declared judgment slots;
they cannot become legacy text/tool model selections.

Raw Baikai structured answers are protected, bounded application snapshots,
separate from Shikumi's locally derived typed result and the transport receipt.
Effective decision settings, including defaults, join immutable program state.
Changing a threshold, cut or weight requires another registration; replay reads
the original committed result through its retained codec instead of deriving
again. Version-two outcomes correlate snapshots to actual acknowledged calls;
outcomes without snapshots retain the version-one envelope. New finite judge
steps are declared under `shikigami-structured-judgments-v1`.

Assistant replay adds scoped format two and user structured context adds format
three. Historical text formats retain their wire numbers and readers. Structured
content in the wrong message role refuses; a data-only assistant cannot succeed
as empty prose. Cache/replay preserves answer data without minting provider
evidence. A failed terminal acknowledgement cannot publish a successful answer.

Shikumi 0.5.1.0 implements owning request
`mori://shinzui/shikumi/okf/improvement-requests/concepts/IR-5`. The application
stream entry point reuses the complete runner's admission, invocation-local
registry and acknowledged terminal boundary, composing the public Shikumi
streaming interpreters. Atomic judgments return full structured snapshots and
the same typed local derivation, with status callbacks rather than partial prose.
No application router/parser bypass is introduced. See the
[consumer checkpoint](../evidence/baikai-execution/structured-judgments.md).

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

## Durable integration evidence

The PostgreSQL DecisionWorkflowSpec runs actual Shikumi in a durable
agent-run workflow. Versioned registrations with identical provider requests and
responses but different pure local derivation produce different fresh results.
An already committed original result retains every field, including confidence,
after the original executable and model bindings are removed. Between decisions,
the whole-Flow snapshot selects the original retained derivation; removing that
state refuses pending execution before dispatch. The result-codec registry alone
is sufficient to read committed outcomes. [ADR 0045](0045-flow-policy-pins-pending-decisions-and-retains-completed-result-codecs.md) records the workflow integration boundary.


## Preparation representation

Plan 108 retains the preparation commitment as `DecisionPreparationId` through
the preparation, outcome and actual-call report. It is the existing SHA-256
commitment under `shikigami.prepared-decision/1`, not a separately allocated
entity. Its factory and checked decoder share the canonical lowercase digest
shape; no Generic or constructor bypass is public. Actual remote attempts still
receive the independent allocated identities in ADR-96.

`DecisionSlotLabel` checks the existing ASCII label grammar at construction and
decoding, preserving arbitrary admitted labels rather than closing the domain
to the two current compiled slots. `DecisionGeneration` distinguishes a runtime
generation from attempt ordinals and resource counts. Keiro supplies an Int;
retained JSON preserves its existing unbounded nonnegative Natural domain,
including values above the host Int range. No new upper bound is inferred.

The preparation retains Keiro's native `WorkflowId`. That type has no upstream
JSON codec, so the preparation's narrow adapter preserves the historical string
representation and its compatibility coordinates. It also preserves the former
optional-policy decode behavior. There is no new journal-name restriction at
this adapter. The upstream authority is `mori://shinzui/keiro/packages/keiro`;
source symbols remain in the canonical project `mori://shinzui/keiro`, under
`keiro/src/Keiro/Workflow/Types.hs` and `keiro/src/Keiro/Workflow.hs`
(symbol-level URIs pending).

Valid policy/preparation/outcome JSON, preparation hash input, labels, step order
and provider effects retain their meaning and bytes. Corrupt slot labels and
unproducible commitment strings now fail during complete-envelope decoding.
This is validation of the existing admitted contracts, not an identity reset
under the unused first-release exception. Native workflow gate evidence and
actual replay/provider tests remain required alongside primitive codec checks.
