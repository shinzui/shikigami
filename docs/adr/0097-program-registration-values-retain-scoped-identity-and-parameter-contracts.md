# 0097. Program registration values retain scoped identity and parameter contracts

Date: 2026-10-31

Status: accepted

## Context

ADR-41 binds a decision to an immutable program registration: program/version,
implementation, input/result schemas, validator, complete effective parameter
state and local derivation. The registry checks that complete binding and its
Haskell type witnesses. These are application-owned registration coordinates,
not metadata automatically supplied by Shikumi.

registerProgram already refused seven empty identity/version strings, but its
ProgramDescriptor flattened those checked values back to Text. Decoding a
retained descriptor did not preserve that admission rule. The parameter digest
had a concrete producer and encoding, while its format was an unrestricted
Natural whose reader separately required one.

## Decision

ProgramIdentity has a private constructor, a nominal scope and no Generic,
literal or numeric construction. The seven descriptor fields use distinct
scopes: program-id, program-version, implementation-digest, input-schema-version,
result-schema-version, validator-version and derivation-version. Parsing rejects
empty strings and preserves every admitted byte. Do not invent trimming, case
folding, SemVer syntax, universal length limits or a digest algorithm for the
operator-supplied opaque implementation identity.

The registration function remains the boundary receiving textual registration
metadata. It refines each field once before publishing the descriptor and typed
program reference. Registries, retained codecs, policy/preparation/outcome records
and evidence bindings retain those scoped values. A record's Generic instance
cannot create an invalid private field value. Public parsing establishes the
value invariant; it never establishes executable availability or permission.

The program/version pair is the authored lookup coordinate of an immutable code
registration, not a separately allocated business entity. Exact complete binding
and type-witness checks remain required. This concrete authority under ADR-41,
rather than a hash prefix or persistence alone, distinguishes these coordinates
from allocated actual-call identities in ADR-96.

ProgramParameterDigest is a separate private type. Its concrete producer is the
existing versionedDigest with domain shikigami.decision-parameters/1 over complete
effective parameter state. Baikai's commitmentDigest uses canonical JSON and
SHA-256, rendered as sha256: plus 64 lowercase hexadecimal digits; the checked
reader enforces that encoding. This rule does not extend to the opaque
implementation label. Parameter digest syntax alone does not prove the stored
state; registration still computes the commitment, and pending execution checks
the retained complete registration.

ProgramParameterFormat is a closed type containing ParametersV1. Its exact
numeric JSON is one; unsupported or fractional values refuse. All other identity
and digest JSON remain primitive strings with explicit toEncoding. Valid
registration fields, parameter preimage, keys and wire bytes retain their existing
meaning. Workflow labels, order, effects and result declarations are unchanged;
this representation-preserving change needs no patch.

## Alternatives rejected

Retaining primitive fields after validation permits invalid decoded descriptors
and cross-field substitution. Treating every implementation label as SHA-256
would invent a contract absent from its producer. Using parameter identity as
executable authority would omit opaque code and type witnesses. Allocating a new
UUID for each authored immutable registration lookup would lose its natural
program/version coordinate without supplying the missing complete binding checks.

## Consequences

Malformed retained metadata fails through its owning decoder. Valid opaque
registration values preserve exact Unicode/whitespace bytes admitted by the
existing nonempty rule. Parameter formats and computed digest encodings are
strict. Cross-scope and digest-domain substitutions fail at compilation.

The source-file artifact URI for Baikai's concrete digest implementation is
pending: the canonical project is `mori://shinzui/baikai`, with project-relative
path `baikai/src/Baikai/Evidence.hs` (digestOf and commitmentDigest). The selected
cohort is unchanged; this decision chooses no new dependency bounds.

Model aliases/descriptors, other decision coordinates and the complete domain
scalar/identity and decoder-owner review remain open in plan107. This decision
neither exempts whole persistence records nor certifies the final runtime profile.

## References

- [ADR-41](0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md)
- [ADR-45](0045-flow-policy-pins-pending-decisions-and-retains-completed-result-codecs.md)
- [ADR-96](0096-decision-call-expectations-have-allocated-identities-and-positive-ordinals.md)
- [Plan107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md)
- `mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids`
