# 0011. Defaulted agent fields preserve workflow-journal codec compatibility

Date: 2026-08-19

Status: accepted


## Context

An agent manifest is Dhall source at authoring time, but its decoded `AgentDecl`
also crosses a durable boundary. The agent workflow journals the declaration as
the result of its `lookup-agent` step. Those journals outlive the binary that
wrote them and are decoded again during replay.

Adding `identity`, `memory`, and `enabled` to the Dhall schema is source
compatible because record completion supplies defaults. A generic Haskell JSON
codec would nevertheless emit the new fields into every newly journaled
declaration and require them when reading old step values. Dhall compatibility
alone therefore does not protect the durable workflow contract.

The new memory record policy also changes the body of existing `record` and
`fail-session` steps. Historical declarations can carry only the old behavior:
agent-scoped recall limited to ten results, record on success, and enabled.


## Decision

**Every additive, defaulted `AgentDecl` field must preserve the previous JSON
shape when it has its compatibility default, and its decoder must restore that
default when the key is absent.**

For this schema evolution:

* `identity = Nothing`, the default memory policy, and `enabled = True` are
  omitted from JSON.
* Missing `identity`, `memory`, and `enabled` keys decode to those same values.
* Non-default declarations encode the complete value that affects execution.
* `RecallLimit` validates the Dhall `Natural` into the inclusive range 1–1000
  before exposing a total `Int` conversion for the Kioku query boundary.
* The existing `record` step remains present when policy is `Never` and journals
  `Nothing`; it is not removed or renamed.
* Failure recording under `Always` happens inside the existing `fail-session`
  step. No journaled step name, order, or result type changes.

No Keiro workflow patch is introduced for these branches. A replayed historical
declaration decodes to `OnSuccess`, so it follows the same step bodies and
results that existed when the journal was written. `Never` and `Always` can
occur only in declarations decoded after this schema exists.


## Alternatives rejected

**Rely only on Dhall defaults.** Dhall defaults protect manifest source, not the
JSON values already stored in Keiro journals.

**Derive the JSON codec generically after adding fields.** This would make
default declarations acquire new durable keys and make historical declarations
depend on generic missing-field behavior that does not express the compatibility
contract.

**Remove the `record` step for `Never`.** Changing the step sequence would make
the policy look simple in fresh runs but would violate the workflow's durable
shape and complicate replay.

**Add a patch solely because a step body now contains a policy branch.** A patch
is needed when old journals must choose the old shape. Here the old decoded
value deterministically chooses the old behavior, and the step sequence and
wire values remain unchanged.


## Consequences

Existing manifests remain unchanged, old workflow journals remain decodable,
and newly written declarations with default policy retain the old encoded bytes.
New policy values are durable and inspectable only when an author explicitly
selects them.

Future additions to `AgentDecl` must review both compatibility surfaces: Dhall
record completion and the workflow-journal JSON codec. A field default is not
complete until the old JSON shape and missing-key decode are tested.

The policy branch inside a journaled step remains subject to
[`docs/workflow-versioning.md`](../workflow-versioning.md). A future change that
cannot route historical values through identical behavior must declare and gate
a patch instead of extending this exception by analogy.


## References

* [`docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md`](../plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md)
  — implementation and behavioral proofs.
* [`schema/Agent.dhall`](../../schema/Agent.dhall) — declaration defaults.
* [`Shikigami.Agent.Decl`](../../shikigami-core/src/Shikigami/Agent/Decl.hs) —
  bounded type and compatibility codec.
* [`docs/workflow-versioning.md`](../workflow-versioning.md) — durable workflow
  evolution rules.
* `mori://shinzui/haskell-jitsurei/docs/core-record-patterns` — direct, strict
  record-field conventions used by the Haskell mirror.
