# 0068. Objective creation has authority before association

Date: 2026-10-29

Status: accepted; persistence, runtime-origin proofs and frozen durable adapters implemented and qualified

## Context

Shikigami's declared agents can initiate useful work under granted authority. Requiring
an existing objective association before offering objective creation would force manual
setup and prevent an otherwise authorized agent from establishing its first objective.
Conversely, a creation tool cannot grant access to arbitrary existing objectives or
change an accepted execution's frozen tools after dispatch.

## Decision

Creation uses explicit default-deny operator policy keyed by recorded principal. A
durable Skill, Flow or conversation turn may retain a creation scope without an existing
objective, assignment or worker session. The scope binds its recorded principal,
execution/turn identity (or Flow workflow/generation), policy revision and allowed operations on objectives created
within that scope. Description does not execute creation. Fresh creation checks current
policy, lifecycle and exact action authority using the accepted operation identity.

One creator-scoped operation key identifies creation across retries. The objective owner
atomically persists the new objective, creator membership, immutable receipt and trusted
creation-origin link. Runtime adapters validate that origin against owning execution or
turn records, or retained workflow/generation/static-label coordinates for a Flow; model arguments cannot supply actor or operation authority. The origin
links work created during an existing execution without rewriting its accepted request,
association snapshot or fingerprint.

The frozen creation scope permits subsequent actions only on receipt-backed objectives
created within it and only within its original operation set. Each action also rechecks
current membership and exact authority. The returned objective ID is a selector, not a
grant. Creation does not add tools, widen scope, admit worker slots or allocate a new
resource root. Later runs use ordinary association-at-acceptance; later conversation
turns use explicit authorized binding. An existing conversation is never rebound merely
because one participant created an objective.

Plan 98 owns persistence, shared enablement, operator identity and creation policy;
plan 99 owns runtime-origin validation and lookup; plan 101 owns frozen scope admission
and durable adapters. This lets plan 100 consume shared configuration without waiting
for worker-provider wiring. Accepted bindings and old journal branches remain governed
by ADRs 0057 and 0058.

The protected execution snapshot retains an optional objective scope alongside its
frozen tool bindings. Absence is omitted on write and defaults on read, preserving
old snapshots. A new scope binds the recorded principal, run, memory session,
original root and execution assignment or conversation turn, plus the creation
policy commitment and permitted operations. Existing execution recovery precedes
scope loading, so configuration changes cannot replace an accepted grant. The
snapshot owner retains it independently of parent journal collection. A Flow
retains the equivalent admission in its own guarded journal. Both owning workflow
guards have real old branches; native pre-objective journals qualify those branches
with objective runtime access poisoned. The retained scope also includes the
original cutoff so retries derive identical assignment-command bytes without
consulting a changed resource owner before receipt recovery.

The model tool does not accept actors, resource roots or new operation keys.
Planning a creator's own assignment derives its owner and any resource cutoff
from the admitted scope and resource owner. Membership administration stays with
the authenticated API or trusted typed caller; every model command still passes
the single owner's current role and exact-action checks.

Unavailable or unresolved command outcomes remain retryable at the adapter boundary.
They are not journaled as definitive negative tool replies: the owner may already
have committed, and the model must not be prompted to manufacture a second create.
Accepted recovery retains its original operation, scope and menu; current lifecycle,
membership and exact action authority still apply. A tool-contract/schema revision
must retain the accepted revision's implementation rather than mutate its binding
in place.

## Alternatives rejected

Requiring an API-created objective prevents autonomous first creation. Trusting a model
supplied objective ID bypasses authority. Replacing the accepted tool binding after
creation changes the meaning of replay. Rewriting the original run request would break
its acceptance identity. Automatically binding a conversation would change other
participants' future work without explicit authorization.

## Consequences

Creation and access to existing objectives have distinct authority checks within one
command owner. Recovery tests must start with no objective, lose the creation
acknowledgement, recover exactly one receipt and origin, and continue through the same
frozen binding. Denied creation and unrelated objective selectors must fail. Later-run
and conversation continuity must work with memory recall disabled. Plan 98 now qualifies creator-scoped persistence, origin/receipt atomicity, default-deny creation and recovery after process exit. Plan 99 also qualifies opaque runtime-origin proofs and receipt-backed continuation lookup against accepted execution operations, already admitted conversation turns and native Flow workflow/generation/static-label coordinates. Flow operation commitments include the workflow name because workflow IDs are scoped by name. Conversation proofs check the addressed message against the execution assignment, rather than accepting another turn in the same session. A later operation may find the original creation receipt within the same scope; current membership and exact action authority are still required. Plan 101 qualifies frozen scope admission, real Skill/Flow/conversation invocation, creation and evidence acknowledgement loss, unrelated-selector refusal, current membership revocation and later-run/conversation continuity. Its native gate reports additive guards and neutral replay. Plan 102 retains serving-process restart qualification, integrated completion and IR-13 closure.

## References

- [Project vision](../../README.md)
- [Adaptive autonomous delivery](../use-cases/adaptive-autonomous-delivery.md)
- [MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md)
- [Plan 101](../plans/101-make-objective-capabilities-durable-for-agents-and-conversations.md)
- [ADR 0057](0057-skill-parents-admit-frozen-assignments-and-await-execution-children.md)
- [ADR 0058](0058-conversation-acceptance-and-wakes-retain-their-generation.md)
