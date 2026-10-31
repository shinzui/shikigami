# 0103. Model aliases remain checked through permission and selection

Date: 2026-10-31

Status: accepted

## Context

Decision catalog lookup used a public ModelAlias constructor, while agent
permissions, whole-run requests, inherited delegation and worker-session receipts
flattened the same lookup concept to Text. Empty names could enter decoded
snapshots and constructor/Generic access bypassed admission. Different primitive
representations also encouraged wrapping and unwrapping inside permission logic.

## Decision

Decision.ModelAlias owns one private nominal, nonempty exact-text lookup name.
It exposes checked parsing, a total NonEmpty factory, a renderer and checked
JSON/Dhall decoding. It has no Generic, IsString or representation-coercion escape.
Decision.Contract re-exports that public API. The independent concept module
keeps agent declarations from depending on the larger decision contract graph.

Use that type through decision slots/descriptors, operator model configuration,
agent decision permissions, whole-run policies/requests/contexts/selections,
RunJob, delegation, worker coordinator permissions and retained MessageReceipt.
Permission intersection, narrowing, equality and immutable binding lookup operate
on the nominal values. Project text for evidence/diagnostics and existing
owner-specific boundary checks.

An alias is an operator/declaration lookup name, not an allocated entity or the
vendor's model identifier. Keep exact case, whitespace, Unicode and admitted
bytes. Do not mint a TypeID or invent a universal length/character policy. Model
configuration retains its 128-character word syntax; selection retains its
64-entry, distinct, 256-character key checks; scoped session admission retains
its nonempty, 128-entry, 256-character key checks. A valid lookup name supplies no
provider credential, profile, model-selection or delegation authority.

## Alternatives rejected

Sealing ModelAlias while leaving permission lists as Text preserves the largest
primitive substitution paths. Wrapping only at lookup repeatedly reconstructs a
meaning already captured at ingress. An IsString or Generic instance recreates
unchecked construction. Trimming, case folding or globally copying configuration
syntax would silently change exact alias semantics in other owners.

## Consequences

Valid JSON strings, descriptor digests, static flow aliases, process-default
names, permission arrays and producer coordinates retain their encodings and
meaning. Empty aliases now refuse at JSON/Dhall admission, including complete
retained selection/job/context decoding. This tighter first-release admission
has no fallback reader under ADR-27. Native workflow labels/order/effects remain;
a neutral declaration diff does not make formerly invalid opaque values valid.

Private fixture factories use checked parsing. Compiler clients check retained
field types and reject constructor/coercion/literal/Generic/name substitution.
Actual decision/HTTP model selection, profile restrictions, inherited permission
narrowing and whole-run versus decision authority remain their existing owners.
Other descriptor versions/digests, decision scalars and the complete census still
require their own review; this decision does not exempt them as metadata.

## References

- `mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids`
- `mori://dhall-lang/dhall-haskell` public
  `dhall-haskell/dhall/src/Dhall/Marshal/Decode.hs` (checked Decoder extraction;
  source-file artifact URI pending).
- [ADR-27](0027-the-first-release-establishes-one-clean-durable-baseline.md)
- [ADR-43](0043-decision-provider-wrappers-own-actual-attempt-boundaries.md)
- [Plan107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md)
