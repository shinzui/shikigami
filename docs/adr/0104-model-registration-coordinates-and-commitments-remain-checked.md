# 0104. Model registration coordinates and commitments remain checked

Date: 2026-10-31

Status: accepted

## Context

modelBinding already refused empty model versions and credential-binding
identities/versions, and computed a canonical digest over the complete
credential-free binding. ModelDescriptor flattened those checked meanings back
to Text. Complete JSON decoding therefore did not retain their admission rules,
and a model version, credential binding key and binding version were freely
interchangeable after capture.

## Decision

ModelRegistration is private with nominal scopes `model-version`,
`credential-binding-id` and `credential-binding-version`. Each parser rejects
empty text and retains exact admitted bytes. ModelDescriptor stores the three
scoped values. modelBinding remains the textual boundary and refines each once
before admitting the descriptor. No Generic, literal or representation-coercion
escape is supplied. Do not infer SemVer, trimming, a digest algorithm or a global
length limit for these supplied opaque coordinates.

These are authored immutable registration/credential lookup coordinates, not
allocated call entities or vendor model IDs. Exact alias/version binding
conflict checks, retained descriptor equality, credential availability and final
transport/profile checks remain required. A checked coordinate conveys no
execution or secret authority.

ModelDescriptorDigest is a separate private type with a concrete producer:
versionedDigest `shikigami.decision-model/1` over the existing complete alias,
version, provider tuple, native model, options and credential-binding coordinates.
Its checked reader enforces `sha256:` plus 64 lowercase hexadecimal digits.
The producer, domain, preimage and valid primitive JSON remain unchanged.
This digest domain is distinct from parameter and payload commitments. Syntax
validation does not replace computing and comparing the complete binding.

## Alternatives rejected

Reusing ProgramIdentity would conflate independent model and executable
registration concepts. Retaining Text after checking construction leaves JSON
admission and scope substitution open. Imposing hash/version syntax on supplied
labels invents a producer contract. Accepting any text as the computed digest
fails the actual canonical commitment encoding.

## Consequences

Complete descriptor decoding rejects empty coordinates and malformed computed
commitments. Positive codecs and the former raw-value preimage establish valid
wire/digest stability. Existing synthetic test descriptors adopt real computed
commitments instead of fake `sha256:model` labels; no production reader fallback
is added. First-release invalid opaque metadata refuses under ADR-27.

Workflow labels, order, effects, valid identity bytes and result declarations
remain unchanged; no patch is needed. Native declaration checks do not replace
behavioral binding/evidence/recovery checks. Provider tuple fields, other decision
scalars, decoder owners and the complete domain census remain separate open work.
No dependency bound or final Linux qualification changes here.

## References

- [ADR-97](0097-program-registration-values-retain-scoped-identity-and-parameter-contracts.md)
- [ADR-103](0103-model-aliases-remain-checked-through-permission-and-selection.md)
- `mori://shinzui/baikai`, project-relative `baikai/src/Baikai/Evidence.hs`
  (`commitmentDigest`; source-file artifact URI pending).
- `mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids`
- [Plan107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md)
