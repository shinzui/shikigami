# 0081. Validated results use private seals and public read views

Date: 2026-10-30

Status: accepted

## Context

ValidatedRouterDeclaration and ValidatedPinnedDiff exported their constructors.
A caller could label a record validated without running its validator. Merely
hiding a record constructor while exporting its selectors is insufficient:
a selected GHC 9.12.4 experiment compiled a client that updated a private-ctor
nonnegative counter to -1 through its exported record field.

A follow-up scan also found Generic on private DecisionFailure and
InstructionBundle, bypassing the bounded diagnostic and bundle identity validator.
Run/call correlation wrappers exposed unnecessary generic construction alongside
their deliberate technical-coordinate factories and retained wire codecs.

## Decision

Seal validated router declarations and pinned diffs in private newtypes without
Generic or context-free FromJSON. The owning validators alone construct them.
Public RouterDeclarationView and PinnedDiffView records expose readable facts;
projecting or updating a view does not produce another validated result. Ordinary
read views retain Generic for the established record patterns. Callers that need
a different accepted value run validation again.

Remove Generic from DecisionFailure, InstructionBundle and the two correlation
wrappers. Keep DecisionFailure's bounded factory and tuple codec. Keep the
correlation factories, rendering and retained wire representation; this change
does not assert that decoding an opaque correlation string verifies its original
run/step derivation.

InstructionBundle now has an explicit object codec with the same repository,
base, files and digest fields. Its reader still reconstructs through
mkInstructionBundle and requires matching files/digest, preserving scope, body,
ordering, source and aggregate-byte checks. It continues to ignore unknown fields
as the prior default generic parser did. Exact complete-bundle byte controls
precede existing tamper refusals.

The two Flow edits only project the same previously validated policy through a
read view. Under workflow-versioning rules 4 and 7, no patch or generation reset
is needed: no step name, call order, journal result type, wire value or meaning
changes. The validated wrappers were never journal result codecs. Preserve the
existing same-build routing/decision replay fixtures and native strict diff.

## Alternatives rejected

Public constructors permit validation to be skipped. Private constructors plus
public record selectors permit unchecked record updates. Keeping Generic on a
private checked result reopens generic construction. Making view records act as
authority tokens would discard the separation. A read view preserves ordinary
record access without granting construction of an accepted result.

## Consequences

Consumers read accepted facts through explicit projections. They cannot mint the
two validated values through a constructor, representation coercion, Generic or
unchecked JSON decoding. Positive compiler controls exercise the public validators
and the Generic read views before negative clients check those boundaries.
Existing validation, exact codec, semantic routing, evidence acquisition and
workflow replay cases retain their actual owners. The complete scalar/identity
census and exact-candidate final qualification remain open.

## References

[ADR-80](0080-opaque-checked-values-do-not-expose-generic-construction.md),
[workflow versioning](../workflow-versioning.md),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
and [the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids).
