# 0080. Opaque checked values do not expose generic construction

Date: 2026-10-30

Status: accepted

## Context

Hiding a constructor does not enforce a smart-constructor boundary when the type
also exposes Generic. Aeson's public genericParseJSON can construct its generic
representation without using the owning FromJSON instance or parser.
Generic serialization similarly bypasses a secret wrapper's deliberate absence
of ToJSON.

On the source parent 651de68, the public port and revision constructors rejected
0 and "branch" while the generic parser returned Right 0 and Right "branch".
A real selected-compiler client also accepted generic bypasses for all thirteen
opaque values listed below. Its credential probes were type-only: no actual
credential was read or printed.

## Decision

Remove Generic from these opaque values:

- AgentPrincipal: directory-issued principal admission.
- Port and App.Config.ByteLimit: checked listener and body-size bounds.
- SecretText, InspectionCredential and BearerToken: explicit credential construction
  and disclosure boundaries.
- FullCommit, Repository.Revision and RelativePath: pinned commit and safe content
  address admission.
- CapabilityId and CapabilityRevision: checked capability address/version syntax.
- ResolvedCapabilitySet: canonical capability ordering at construction.
- ValidatedRouteDecision: catalog/context validation is the authority mint.

Keep their owning public constructors, parsers, explicit renderers and deliberate
codecs. Keep Generic on ordinary records that need it. This is an abstraction
rule for checked/opaque values, not a ban on generic record access or codecs.
Do not add an unsafe instance or public constructor to restore compilation.

Opaque values also must not export a real record selector for their private
representation: a client can use that selector in a record update. ExecutionId,
WorkerSessionId and AssignmentId use private positional representations. Their
existing `.value` reads are supplied by read-only HasField instances; no record
update or Generic construction is available. This preserves the mapped total
identity codecs and the checked assignment decoder without exposing a setter.
Compiler clients enable record-field disambiguation and check the actual update
expression. An ambiguous selector error does not demonstrate opacity.

## Alternatives rejected

Trusting callers to select the safe parser leaves the invariant unenforced.
A hand-written FromJSON instance does not stop a caller from selecting
Aeson's generic parser explicitly. Omitting Show/ToJSON on a secret is also
insufficient if generic conversion still reveals its Text representation.
Removing Generic from unrelated outer records adds no protection and would
unnecessarily discard their record interfaces.

## Consequences

Invalid underlying values cannot be reconstructed through these public generic
APIs. Credential wrappers retain greppable explicit lowering at their existing
library boundaries. Public codec behavior and valid wire bytes remain unchanged;
no DSL declaration, binding conversion, journal step or identity derivation changes.

A positive compiler control checks all thirteen public factories/adapters before
thirteen negative clients require each generic parse/render bypass to fail for
its missing Generic instance. Existing public constructor/codec and authentication
cases remain runtime controls. This decision does not certify every scalar or
identity authority in the wider census; those reviews remain explicit work.

Plan 108 applies the same rule to the one-off agent's `WorkspaceScope`. Its
canonical absolute Git root is established by `resolveWorkspaceScope`, so the
record constructor and `Generic` must not admit arbitrary paths. `workspaceRoot`
renders the resolved path at the native filesystem boundary. The 15 existing
discovery/containment/tool-bound tests pass, and a positive public compiler client
precedes constructor, coercion, record-update and Generic refusal probes in
`tests/types/workspace-scope.py`. Filesystem/symlink rechecks still run because
the filesystem can change after scope resolution. No entity ID or second root
wrapper is introduced, and no serialized workflow representation changes.

Nominal capture of a foreign or operator claim preserves its existing spelling
until the established owner validates it. A private nominal carrier does not
justify adding a universal UUID/digest grammar or moving validation to a different
boundary. `CronExpressionClaim` feeds the existing checked `CronSchedule` parser
and preserves strict/lenient scheduler diagnostics. Activity envelopes also carry
synthetic trigger references under their original run keys, so typing them must
not allocate replacement activity IDs. Capability leases distinguish native
workflow references from process-local one-off run references explicitly.

Composite workspace process images, rules, policies, profiles and identity ranges
follow the same construction rule. Their explicit `Input` records retain the
existing fields for configuration and fixture editing; `mkProcessImage`,
`mkCommandRule`, `mkProcessPolicy`, `mkProcessProfile` and `mkIdentityRange` apply
the original predicates before returning private positional newtypes. Strict JSON
decoders use these factories, while read-only `HasField` instances preserve field
reads. The integration `Request` likewise admits its existing bounded, distinct
artifact collection through `mkRequest`. Input records are proposals, not admitted
policies or requests. Re-admission preserves the previous scalar JSON and policy
identity formulas without introducing another validation framework.

## References

[ADR-74](0074-domain-state-revisions-keep-their-scope-at-application-boundaries.md),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
[the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids),
and [Aeson's public generic conversion APIs](mori://haskell/aeson/packages/aeson).
