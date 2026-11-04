# 111. Adaptive delivery carries native admission and reference-only seeds

Date: 2026-11-03

Status: Accepted

## Context

A coordinator must survive a lost decision or command acknowledgement without
sampling another organization or creating another worker. Continuing workers
also need to admit local coordinators against real objective authority. Prompt
JSON cannot supply that association. Worker events require explicit checkpoint
integration, so watching objective writes alone misses the first worker result.

## Decision

The compiled `adaptive-delivery` Flow admits a new native child family behind
`shikigami-adaptive-delivery-v1`. The parent's journal pins its declaration,
transitive permitted catalog, decision policy, root, cutoff and positive limits.
Each child generation restores its seed first and uses static labels. Seeds carry
accepted decision/command identities, pending operation position, ready assignment
references, session scopes/cursors and evidence marks. They copy no mutable
resource counters. The original coordinator run owns delegation enrollment;
the technical child identity does not create a second budget.

`Coordination` owns the implemented proposal, validation, decision manifests,
checkpoint wakes and finite controller protocol. Existing objective, resource,
session and workspace owners retain their state and authority. `AdaptiveDelivery`
owns only this native family's generated runtime/facts. Both are concrete concept
roots in the closed module inventory under
[ADR 0075](0075-service-composition-has-a-closed-reviewed-module-budget.md),
not additions to the service composition allowance.

The child executes accepted typed programs through the shared executor. A whole
proposal commits before command dispatch. Recovery reads that manifest first;
current membership, source owner epoch, lifecycle and exact command authority can
still refuse fresh effects. Ready assignments obey organizational concurrency;
actual transport occupancy obeys shared database capacity. Existing scope
fingerprints are reacquired instead of inserted again. Temporary owner failures
throw before a step commits, preserving the same recoverable operation.

Native worker, objective and finite-cutoff notifications converge on one Boolean
awakeable hint. Historical session listeners retain their session-valued hint
and wire representation. Registration catches observation/publication races.
Only meaningful result events are integrated into the checkpoint before model
reflection; start notifications do not invalidate an admitted instruction by
premature projection. A checkpoint conflict requires explicit revalidation;
uncertain effects remain retained rather than being replaced.

The continuing-worker patch `shikigami-worker-objective-children-v1` verifies the
exact running native message and derived child under the objective lock, then
admits its separate objective association. Old child inputs retain the old
branch. Native worker transports recheck their message, owner epoch, membership
and root at actual call admission. Adaptive direct/decision transports recheck
their native parent admission and current coordinator assignment. Recorded menus
and historical results remain immutable.
Transport guards discover their native source using the accepted execution's
application environment before consulting optional objective/adaptive services.
Historical unassociated runs therefore retain their original branch without
requiring those services. A native associated source with missing services
refuses fresh work instead of falling back to that historical path.

Direct work uses an admitted pure Skill role under the coordinator principal;
it has its own accepted execution and no worker session. Roles requiring their
own overlays, delegates, routing or profiles use their declared worker path.
Transfers require an explicitly pinned workspace and the existing fence and
ownership providers; absent authority is refusal, never a simulated handoff.
Workspace references are discovered from a unique ready session binding at the
current root/owner/epoch and pinned in that decision's checkpoint. A transfer is
standalone and requires an idle, fully integrated session. Its retained operation
and scope reconcile across rotations; a finite recheck timer repairs pending
fences without another model call. This uses the existing administrative fence
and ownership control path, separate from accepted provider launch work.

Objective inspection reads current graph metadata, protected-receipt-validated
decision history, coarse observations and authoritative root usage under one
objective lock. It exposes no instruction or result bodies. Historical inspection
values decode with the new optional metadata absent. Model prose, a worker's
success and an artifact-free result cannot supply a passing combined check.
Only the objective owner accepts exact, current integrated evidence, after all
root transports, native mailboxes and pending source receipts settle.

## Consequences

Local coordinators use their own admitted descendant tools; the root does not
impersonate them. A later live catalog can narrow availability without expanding
the pinned universe. Long work suspends its parent and releases workflow leases.
A silent objective waits on owner publications or its finite cutoff rather than
spending model calls to poll. A completed child merely proposes acceptance; an
authorized completer remains responsible for the combined artifact and journey.

The alternative of deriving grants from trigger JSON would lose source ownership.
Rebuilding scopes or proposals after a crash would turn recovery into fresh work.
A second mutable assignment/resource graph would diverge from existing owners.
These alternatives are rejected. Repository artifact/live-trial qualification
remains Plan 86's responsibility.

## Producer and descendant qualification

New pinned scopes and session admissions carry the admitted declaration catalog.
The existing `lookup-agent` step reads it from the exact native child source;
local scope admission propagates that same catalog. Missing optional catalog
fields preserve historical wire bytes and lookup behavior. A later live local
role cannot add descendants to that retained universe. Fresh lifecycle/action
checks can still refuse a pinned role.

For these pinned admissions, the instruction's objective revision is an ordering
base while assignment revision, criteria revision, owner, epoch, active state and
root remain exact. Instruction/status edits invalidate assignment revisions as
specified in [ADR 0067](0067-objective-checkpoints-use-assignment-scoped-preconditions.md).
Sibling bookkeeping therefore does not strand accepted work. Historical session
admissions retain the stricter original objective equality check.

External producers previously wrote ingestion before a runner could establish
its patch snapshot (FRIC-53). `Workflow.Versioning` now prepares the active patch
set and original ingestion in one transaction under the public ingestion-step
lock. Existing ingestion or an existing patch snapshot wins, including an empty
old patch set. Native source admission composes that prepared transaction with
its authority check. No private framework tables are written directly. The
underlying primitive is supplied by `mori://shinzui/keiro` (project-relative
`keiro/src/Keiro/Workflow/Journal.hs`; artifact-level URI pending).
