# 0105. Provider tuples retain nominal foreign coordinates

Date: 2026-10-31

Status: accepted

## Context

ProviderCall, signed-profile AllowedCall and ModelDescriptor compare the same
provider name, API code, endpoint class and exact vendor model ID. Those four
meanings were separate Text fields, allowing cross-field substitution inside
permission and evidence checks. They are foreign SDK/protocol coordinates,
distinct from configured ModelAlias and credential-registration coordinates.

## Decision

Behavior.Provider.Coordinate owns private ProviderCoordinate values with nominal
scopes `provider-name`, `provider-api`, `endpoint-class` and `provider-model-id`.
The scopes prevent substitution even through coerce. No Generic, IsString or
public constructor is supplied. Exact text capture is total: the current SDK
supports opaque/custom vocabulary, and this change invents no nonempty, syntax,
normalization or length constraint. JSON still accepts exactly textual values
and emits the original string, including an empty/custom value where the old
representation did. Capturing a coordinate confers no provider availability or
profile authority.

ProviderCall, AllowedCall and ModelDescriptor retain those scoped values. The
actual SDK model/options adapter captures them when forming the call tuple;
model registration copies the retained tuple. Dispatch/profile matching compares
nominal values without flattening them. The native terminal-evidence adapter
captures foreign evidence coordinates once before compliance comparisons. SDK
terminal checks, evidence projection and diagnostics explicitly render text at
their real foreign/output boundaries. Native Baikai records and ThinkingLevel
remain their original types.

The provider's model ID is an external lookup coordinate. It is neither a local
allocated entity nor the operator alias that may be repointed. Keep its exact
foreign representation in a nominal domain; do not mint a TypeID or borrow the
model-alias admission rule.

## Alternatives rejected

Flattening signed permissions and requested tuples to Text leaves substitution
inside the authority predicate. Reusing ModelAlias conflates mutable operator
lookup with the exact vendor model name. Enumerating only today's known APIs or
requiring universal name syntax would change the existing custom/opaque boundary.
Rewrapping native SDK structured evidence would duplicate its owning protocol.

## Consequences

Valid JSON, signed-profile canonical bytes, model commitments and exact tuple
semantics remain unchanged. The existing literal minimal-profile byte golden
and profile/model/HTTP/CLI controls qualify those boundaries independently of
round trips. Positive compiler clients precede scope/coercion/literal/Generic
and alias/registration substitution rejection. Foreign native facts remain
native; application comparisons retain nominal meanings.

No workflow step, producer identity, valid codec or effect order changes, so no
patch is required. Native declarations alone cannot qualify this behavior.
Profile identity/signing values, policy flags, remaining decision scalars,
decoder owners and the complete domain census remain separate open work. This
change does not qualify Linux containment or the final packaged runtime.

## References

- [Provider adapter](../../shikigami-core/src/Shikigami/Behavior/Provider/Call.hs)
- [Compliance adapter](../../shikigami-core/src/Shikigami/Attestation/Compliance.hs)
- [ADR-103](0103-model-aliases-remain-checked-through-permission-and-selection.md)
- [ADR-104](0104-model-registration-coordinates-and-commitments-remain-checked.md)
- `mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids`
- `mori://shinzui/baikai/docs/model-call-evidence`
- [Plan107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md)
