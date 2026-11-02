# 0066. Worker commands require retained scopes and fresh exact authority

Date: 2026-10-28

Status: accepted

## Context

Continuing workers need one control boundary for Flows, durable Skill tools and
operators. Agent text cannot grant control over a parent objective or another
worker. A resumed tool must also retain its original root, delegation context
and target scope after model context compaction or parent rotation.

## Decision

A trusted association source derives a coordination scope from accepted run or
session records. It binds the parent identity, memory session, resource root,
model permissions, delegation lineage/budget, finite worker slots and objective
references. It retains that scope by fingerprint while durable references use
it. Reacquisition validates the pinned run and fingerprint; it never substitutes
current instructions, another root or a newly generated scope. A declaration
requests capabilities but supplies no grant. Production installs objective-backed scope, checkpoint and ownership adapters. Disabled tracking yields no fresh scope, and missing workspace fencing remains unavailable.

One closed command owner serves Flow, Skill and operator callers. Every command
checks current lifecycle, scope membership and fresh exact C13 authorization.
The existing capability-tool action carries a scope-bound revision and a
command digest covering its trusted operation key and complete input. Inputs
cannot supply actors, roots, scope grants or model-selected operation keys.
New messages check current objective/assignment/criteria references; accepted
retries return the original receipt before consulting changed current versions.
Target identity and the existing delegation boundary still govern child spawn.
New assignments retain the intersection of the current scope's model aliases
and the original delegation permissions. Parent rotation cannot widen the
frozen depth, lineage or delegation budget. Accepted retries keep their original
permission receipt even when current providers are unavailable.

The dedicated native tool pins the scope fingerprint in its immutable binding.
Only preparation receives accepted harness operation coordinates; describing a
menu cannot execute it. This local command/control surface is idempotent and has
no invoice charge. A future provider that adds billed work requires a different
binding contract. Arbitrary mutation overlays remain observation-only. Flow
commands journal bounded replies under static caller labels; domain intents
can supply retained operation keys across technical parent epochs.

Find/create reuses matching retained sessions across parent rotations without
replacing their original context or limits. Scope admission counts all retained
sessions under an application advisory lock, enforces a bounded count, and
rejects a replacement root for the same parent scope. An expression index owns
that lookup. Public inspection pages at most 20 assignments and references;
protected result reads include bodies only within a 16 KiB bound. Neither public
inspection nor ordinary command replies expose wake tokens or admission bodies.

Flow event waits register at most 32 live generation-owned listeners. Accepted
events and their wake completions share the checked transaction. An already
present journal value must match the session identity; the upstream append API
does not assert that equality. Wrong-generation and collected wakes never
redirect to a successor. A retained session continues to accept facts and final
cursor acknowledgements after workflow GC. Logical closure records a retained
event, so a coordinator can observe it without polling.

Agent runs declare the real patch `shikigami-worker-coordination-v1`. Old Flow
journals retain the disabled interpreter without a policy lookup; new Flows
journal a bounded scope reference or refusal. Old Skills keep their original
menu admission branch. Existing accepted execution bindings are unchanged.
All five workflow families share the serving registry. Operators bootstrap a
protected admission read only after lifecycle and exact C13 checks against its
public binding; they then use the same command owner. Unsupported real-provider
operations refuse rather than fabricate objective or fencing state.

`CoordinatingSkill` explicitly selects the admitted durable coordinator path.
It requires a worker binding before any model call. Ordinary `Skill` declarations
with delegates retain their fixed-supervisor behavior. Ephemeral behavior and
conversation fallback cannot execute `CoordinatingSkill` without this admission.
Successful find/send commands idempotently register the original session input
through Keiro's public transactional journal API. Retrying an accepted command
repairs a crash between mailbox acceptance and driver registration without
resetting a generation or creating a new child.

Session replay also repairs a child registered before its input was journaled
through the original governed mapping. An accepted result is read before any
current-owner execution lookup, so a result committed just before a handoff can
still finish its parent journal acknowledgement. Known pre-spawn delegation
refusals produce one bounded retained failure; infrastructure uncertainty is not
converted into a successful or cancelled effect. These repairs retain existing
parent labels and result codecs.

Plan 99 supplies the objective-backed source. `Agent/CoordinationSource.hs` reads
accepted native run steps through Keiro's owner API, checking run identity, recorded
agent declaration, memory session, root and permission bounds. The first admission
also checks the immutable run/objective association, current coordinator authority,
allowed worker declarations and identities, membership and operator-bounded slots.
The retained scope, its indexed run pointer, original root/cutoff attachments and
command receipt publish in the objective owner's checked transaction. It never
allocates a root. Its parent coordinate binds objective and principal, preserving
session reuse without silently rotating the principal.

Scope publication also enrolls one delegation ledger with the original resource
root in that transaction. Descendants keep their inherited ledger; otherwise a
stable objective/principal commitment selects it. The ledger records the actual
first native run as origin. Reacquisition and coordinator rotation never reseed
its limit or consumption. Root accounting and the shared ledger both bound every
child reservation, and replaying an accepted reservation consumes neither again.
Publication failure rolls back ledger creation as well as assignment attachments.

Reacquisition reads the exact fingerprinted body under current membership and
coordination permission. It does not consult the source journal, replacement
configuration or a newly generated root. Accepted scopes therefore survive source
workflow GC and worker restarts. Each fresh child/message still checks the current
objective assignment, owner/epoch, root, cutoff, target identity and exact action.
Runtime callback factories select the parent recorded in the retained session;
submitted intent actors cannot select another authenticated host.

Disabling tracking refuses new scope admission, current versions for fresh worker
work and new mutations. Authenticated readers, retained scopes and matching accepted
receipts remain available under current permission. Recovery never selects an older
unassociated path or allocates replacement capacity. Worker and operator composition
share these adapters; the operator's existing-session bootstrap cannot create another
slot. Workspace transfer remains unavailable without its independently configured,
qualified fence provider. A deterministic fence fixture qualifies only the objective
side of the handoff contract.

## Alternatives rejected

Global mutation overlays would widen unrelated tools. Model-supplied operation
keys or roots would make retries manufacture new authority and capacity.
Resolving a current scope on replay would reinterpret accepted work. Polling idle
workers would spend effort without evidence. Treating journal deduplication as
payload equality would falsely accept a conflicting wake. Collecting session
facts with terminal workflow journals would erase continuity.

## Consequences

Plan 99 qualifies retention, current mandate checks and exact action authority against the real IR-13 owner. Workspace providers must qualify fences,
late processes and conditional writes under IR-11. The remaining deterministic workspace fixtures exercise consumer mechanics and do not satisfy the real workspace/joint handoff gate. Plan 84
cannot be Complete until the real integrations pass; dependent plans keep their
whole-child start gates. Roll forward across the new session events/phase.

The expanded Flow interpreter reproduced a native GHC 9.12.4 GC crash in a
fresh build. `Shikigami.Agent.Workflow` uses a module-local `-O0` workaround;
execution workers, tools and other modules retain normal optimization. Narrower
worker/wrapper and strictness exclusions did not survive the complete capability
population. Keep forced collection at suspension/resume in the deployment
regression and requalify before removing the workaround. The compiler pin is
unchanged. Scheduling throughput needs measurement under plan 85's capacity
qualification. Investigation and qualification evidence are recorded in
[FRIC-13](../friction-log/13-expanded-flow-registry-crashes-during-garbage-collection-under-ghc-worker-wrapper.md).

## References

- [Plan 84](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md)
- [ADR 0061](0061-continuing-sessions-own-ordered-assignments-and-retained-receipts.md)
- [ADR 0062](0062-session-generations-await-governed-children-and-retain-checkpoint-intents.md)
- [ADR 0063](0063-handoffs-establish-epochs-only-after-fences-and-versioned-owner-receipts.md)
- [Workflow versioning](../workflow-versioning.md)
- `mori://shinzui/kikan-en`, project-relative
  `kikan-en-contract/src/Kikan/En/Action.hs` (artifact-level URI pending), owns the
  released capability-tool action and exact proof verification contract.


The event listener retains native Keiro WorkflowName and WorkflowId through
generation lookup, awakeable ownership checks and journal notification. Its JSON
codec keeps the existing text representation, including historical spellings;
this nominal change adds no new identifier grammar or authority. The owner still
checks the exact token, workflow coordinates and generation before mutation.
