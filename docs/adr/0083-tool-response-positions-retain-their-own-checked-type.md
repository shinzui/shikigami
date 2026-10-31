# 0083. Tool response positions retain their own checked type

Date: 2026-10-30

Status: accepted

## Context

ToolOperationInput.position, NextWork's tool index and OperationSpec.responsePosition
shared Int with unrelated cursors and indexes. The operation writer already
required positions within 0..255. Actual assistant validation separately limited
a request to at most 128 uniquely identified tool calls. Workspace routing readers
used the unrelated operation-cursor ceiling of 10000 for a tool position.

## Decision

Use private ToolPosition throughout retained tool inputs, continuations,
operation specifications and their execution/workspace consumers. Its constructor
and JSON decoder own the existing 0..255 scalar bound; there is no Num, Integral,
IsString, Enum or Generic instance. Increment returns Maybe at the upper bound.
Keep the existing 128-call and exact invocation/binding checks at the assistant
admission boundary, where the whole request is available.

Lower the position only when indexing the captured SDK list. Ephemeral local
indexes refine once before calling the shared validator. A concept-owned
continuation helper computes the same following tool or NeedModel for the
executor and independent file/Git/process providers. It introduces no replay read
or new dispatch authority.

Workspace routing readers retain their positive-follow-up check and reference
checks. They no longer compare a tool position with the operation-cursor ceiling:
the scalar constructor owns its actual range. This contracts structural acceptance
of invalid routing positions above 255; accepted provider routing already comes
from requests admitted with at most 128 calls. No historical reader is added under
the unused-service baseline.

## Alternatives rejected

Using execution-operation revisions for tool indexes mixes retained operation
order with a position inside one assistant response. Retaining Int permits
unchecked arithmetic and negative construction. Applying 10000 treats unrelated
units as the same bound. Clamping an invalid index could select a different call.

## Consequences

Valid retained JSON remains numeric, with complete input, continuation and
specification byte controls before invalid bounds. Compiler clients reject cursor
substitution, primitive arithmetic/coercion and generic construction. The two-call
continuation control precedes real replay/provider recovery fixtures. Native
identity derivation, DSL declarations, step labels/order and valid writer behavior
remain unchanged. The complete scalar/identity census and final packaged/runtime
qualification remain open.

## References

[ADR-74](0074-domain-state-revisions-keep-their-scope-at-application-boundaries.md),
[ADR-80](0080-opaque-checked-values-do-not-expose-generic-construction.md),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
and [the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids).
