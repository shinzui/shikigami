# 0087. Agent values retain checked meaning and separate compatibility scopes

Date: 2026-10-31

Status: accepted

## Context

AgentName and DelegationDepth already named domain concepts, but exported their
constructors. Declarations, delegation targets and routing catalogs still stored
names as Text. Expertise keys and routing ceilings lost their validated meaning
between declaration checking and model proposal validation. The unbound initial
conversation seed used an empty AgentName, although ingress rejected that value.

A compiled public-client probe also reproduced a compatibility attribution
collision: both `a:b` and `a.b` rendered as `shikigami.agent.a.b`. Both names are
valid. The sanitizer additionally left whitespace intact, although Kioku's
principal reference rejects whitespace and reserved tuple characters. Directory
compatibility must preserve distinct admitted names without claiming verified
Meibo authority.

## Decision

AgentName is private and nonempty, preserving exact spelling, Unicode and
whitespace. JSON, Dhall and HTTP ingress use its checked factory. Static vocabulary
can use a structurally nonempty character list. Declarations, catalogs, delegation,
routing choices, scheduling, lifecycle admission and run acceptance retain the
nominal value; external encoders render it explicitly.

ExpertiseKey is private and nonblank after the existing trim/case-fold comparison.
It stores the original spelling. Duplicate detection alone normalizes keys;
ordinary routing membership remains exact. SelectionLimit is private, 1..16, and
remains in RouterPolicy through declaration and decision validation. JSON and
Dhall reject invalid scalar values before constructing a declaration. Collection
and cross-field checks still accumulate their semantic errors.

DelegationDepth is private and nonnegative within the native integer range.
Checked successor refuses overflow. The existing exclusive four-level child
policy remains a separate governance rule. None of these scalars expose Generic,
Num, Integral or IsString construction.

ConversationSeed represents its initially unbound name with Maybe AgentName.
Its explicit codec retains the complete initial empty-string wire value and the
complete carried-name wire value. Only the exact unbound initial state accepts
an empty decoded name. ConversationStart and queued work remain strict.

CompatibilityIdentity and CompatibilityAgent retain AgentName. Their attribution
and scope text is `shikigami.agent.v2.` followed by the UUIDv5 URL-namespace
commitment of the versioned exact-name digest under
`shikigami.compatibility-principal/2`. The UUID rendering satisfies Kioku's
principal syntax for every admitted name. This is a deterministic technical scope
and attribution coordinate, not an allocated entity or a TypeID-v7 principal.
Verified identities retain the exact directory-issued principal and all existing
lifecycle and grant checks. Compatibility grant lookup remains name-keyed.

## Alternatives rejected

Restricting valid agent names would discard admitted input without fixing the
ambiguous sanitizer. Keeping a private wrapper only at decoding would still lose
the unit inside domain decisions. An unchecked literal instance or Generic
instance would reopen the constructor boundary. Treating the initial empty seed
as an ingress name would weaken every use of AgentName. Random scope allocation
would destroy deterministic same-build restore and require a new allocation owner.

## Consequences

The v2 compatibility namespace intentionally changes self-asserted memory/session
scopes, attribution and derived sink identities under ADR-27's confirmed unused
first-release baseline. No old-sanitizer fallback or populated cross-build replay
is promised. ADR-33's verified-principal authority and explicit legacy-name alias
product remain; this change does not copy or rewrite Kioku history.

Valid name, expertise, ceiling and depth wire values retain their existing shapes.
Workflow step labels and order remain unchanged. Scalar refactoring preserves
valid journal codecs; the deliberate compatibility-namespace meaning change is
part of the reviewed first-release reset. Subsequent deployed changes follow the
ordinary workflow versioning rules. Retain the before probe and qualify separate
stored scopes, same-build recovery, complete conversation seeds and private
construction boundaries before accepting this candidate.

## References

[ADR-33](0033-recorded-agent-principals-key-durable-state.md),
[ADR-27](0027-the-first-release-establishes-one-clean-durable-baseline.md),
[ADR-86](0086-versioned-structured-coordinates-identify-delegated-and-http-runs.md),
[workflow versioning](../workflow-versioning.md),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
[the retained probe](../evidence/keiro-0.22/agent-values-before-probe.json),
and [the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids).
Kioku's principal validator belongs to `mori://shinzui/kioku`, at
`kioku-api/src/Kioku/Api/Access/Internal.hs`; its artifact-level source URI is pending.
