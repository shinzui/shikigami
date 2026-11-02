# 0070. Objective receipts and integrated acceptance share one command owner

Date: 2026-10-30

Status: accepted

## Context

Objectives span executions and have several future adapters: worker providers,
HTTP and CLI commands, model tools and Flow effects. Each adapter needs the same
membership, revision, retry and completion rules. Worker results are useful
progress, but successful child execution alone does not prove that an integrated
artifact meets an objective's criteria or user journey.

## Decision

`Shikigami.Objective.Capability` authenticates trusted adapter context and obtains
fresh exact action authority for recorded agents. Its access value is private to
`shikigami-core` and has no JSON decoder. Verified API callers, recorded agents
and configured local operators remain distinct identities. Development HTTP
authentication being disabled never constructs a verified objective caller.
Objective tracking defaults to disabled for fresh work; agent creation defaults to denied. Disabling tracking retains authenticated inspection and accepted-receipt recovery under current membership and exact action authority. Fresh creation and mutations still refuse, and current worker versions are unavailable for admitting new work.

`Shikigami.Objective.Store` is the single conditional persistence owner. It checks
current membership and command permission under the objective row lock before
receipt lookup. Public edits and ownership transfers require exact objective
revision equality. Internal checkpoints use [ADR 0067](0067-objective-checkpoints-use-assignment-scoped-preconditions.md).
A fingerprint includes the actor, operation, objective, command and expected
versions. An accepted retry returns the original receipt before checking stale
versions or contacting an evidence owner again. Payload reuse conflicts.

A locked inspection transaction retains definitive negative command outcomes.
It changes no objective state and appends no lifecycle event. A positive
inspection is repeated under the row lock inside Keiro's checked lifecycle append
and live projection transaction. Current state, assignment rows, protected
payload, association or source cursor, and immutable receipt commit together.
A race restarts inspection; transport failure remains unavailable or uncertain.
External verification and exact-action calls run outside database locks.

The generated catalog describes the tables as preserved, live-only targets.
Public lifecycle metadata contains identities, revisions and a command
fingerprint; protected state cannot be reconstructed from it. Receipts, evidence
and origin links have no workflow-journal lifetime dependency and are retained
indefinitely until a separately designed retention policy exists. Assignment
reference keys index the existing worker `ObjectiveRef` with provider ID
`shikigami-objective-v1` without changing its codec. Finite assignments may omit
resource roots and sessions; the worker version projection refuses until an
admitted root and cutoff exist. Withdrawn assignment identities are retained and cannot be reused.

The authenticated `/objectives` vertical and the configured local-operator CLI
adapt this same owner. Their versioned public envelopes cannot decode internal
provider commands or caller authority. Creation disposition comes from the
transaction's allocated identity, so concurrent replays return the same receipt
with only its publisher reporting creation. Lists filter current membership
before applying bounded pages. Inspection pages safe goal, criterion, assignment
and evidence-reference metadata, excluding instructions and result bodies.
History validates protected payload commitments and physical receipt keys,
then exposes accepted revisions and their recorded actors without command bodies.
The HTTP vertical refuses disabled tracking; internal accepted-work readers remain
available for recovery as described above. Wire and CLI documents cap at 1 MiB.

Completion requires a proposal naming the exact objective, instruction and
criteria revisions, integrated artifacts, checks and limitations, followed by an
explicit approving owner or completer command. Every check must match retained
evidence for the current objective instructions, criteria and assignment
meaning. Assignment instruction/dependency revisions and owner epochs prevent
reverted text or an ownership round trip from reviving old evidence. Dependencies
must be done, and unresolved effects must be reconciled by their owning adapter.

Fresh acceptance also checks the live retained owners of linked roots, creating
executions/turns, associated runs and bound turns, including rootless finite
work. It repeats this check under the commit boundary. Pending receipts and
unresolved execution phases abort without a definitive negative receipt; the
same acceptance key can succeed after actual settlement. Accepted positive
receipts still recover before these fresh-source checks.

Native objective command recovery can independently acknowledge a superseded
attempt only from the immutable positive command receipt, the exact original
renderer, accepted continuation and retained dispatch owner/generation. Its
frozen tool binding declares no provider invoice cost. Mutable inspection has
no command receipt and cannot settle its original attempt using a later read.
Logical execution success alone proves neither original receipt settlement nor
absence of external effects.

Ordinary worker result receipts are authenticated against the retained worker
result and payload inside the SQL boundary and stored as `ResultObserved` (or a
failed disposition). They cannot substitute for automatic check evidence. An
automatic check requires a trusted verifier-owned result interpretation naming
the criterion and, where required, a verified journey. A human-verifiable
criterion requires an explicit attestation by an owner or completer. The model
supplies references and statements, never authoritative pass/fail flags.

Run associations are admitted in the HTTP ledger's transaction, with the queue
send and acceptance row. The application input envelope carries a typed objective
and assignment selector separately from arbitrary trigger JSON. Omitted selectors
retain their original journal, queue and fingerprint bytes; associated request
fingerprints use a separate UUIDv5 namespace and include both selectors and input.
A lock on the acceptance coordinate orders duplicate requests before checking the
retained winner. Current objective coordination permission is checked under the
objective lock before returning an associated receipt, including a conflict.
Fresh acceptance additionally checks the assigned agent's current membership and
ownership. Receipt recovery retains the accepted selector after assignment changes
and cannot downgrade to the unassociated entry point. Development-mode anonymous
HTTP access cannot admit an association. Worker provider qualification remains a separate acceptance gate in plan 99.

Conversation binding resolves the Shikigami-owned index and verifies the session
through Kioku's owning read-model query, including memory space, namespace,
conversation subject and a recorded objective member's agent identity. Publication
retains immutable binding history and one current binding per conversation and
participant. The binding receipt supplies its objective revision.

Turn admission retains the runtime run/turn coordinates, recorded participant,
source session and the binding visible at admission, including an explicit absent
binding. Retrying admission returns that snapshot after checking current objective
membership; it never acquires a later binding or requires the mutable memory index
to remain available. Source validation and snapshot persistence share a transaction.
Publication and fresh admission use the same binding-coordinate lock, with the
objective locked first, so a concurrent rebind either orders with admission or
produces a visible conflict before writing. The snapshot and its technical ObjectiveTurnAdmission event commit together in
their own live-only, preserved projection group. The original objective writer
and query retain their target sets and lifecycle identities;
workflow wiring and frozen tool scopes remain plan 101's responsibility.

Provider checkpoints retain bounded latest reported-result references per objective
assignment; immutable command payloads and receipts retain each earlier observation.
The backward-compatible objective codec omits this collection when empty and reads
old snapshots as empty. Reported artifacts have no criterion or pass/fail assertion;
providers never invent a criterion mapping from arbitrary worker output. Explicit
criterion evidence and completion keep their existing owner and verifier rules.
Checkpoint publication may attach the first retained session only after validating
its root, assignment, owner and parent against the admitted slot. It allocates no root.

Fresh creation by a recorded agent requires a verified origin whose operation matches
its creation key. Accepted creation receipts are recovered before applying new source
checks or creation-policy checks, while current membership and exact action authority
remain required. Origin lookup checks the physical objective and operation keys, the
receipt fingerprint and the original command receipt before returning authority for
continuation. Private runtime proofs have no wire decoder. Plan 101 still owns the
frozen scope's permitted operation set and the durable invocation boundary.

## Alternatives rejected

Independent adapter executors would drift on retry ordering and revocation races.
Last-writer-wins would hide stale work. Re-evaluating an accepted retry against
current versions or a temporarily unavailable evidence owner would lose immutable
recovery. Rebuilding protected payloads from lifecycle fingerprints would invent
missing data. Treating a successful child as an integrated verifier would allow
completion without checking the requested result.

## Consequences

Plans 99–101 install adapters that call this command owner and supply trusted
source and origin validation. Worker checkpoint, ownership and retained-scope
providers are installed in worker/operator composition. The authenticated HTTP
vertical, local operator CLI, protected native model tool and typed Flow effect
share its receipts and permission rules. Workspace-dependent transfer still needs
the real workspace fence; deterministic fence fixtures qualify only the objective
side. Fresh coordinator scope admission checks the recorded agent behavior;
ordinary associated Skills consume their own assignment without coordinator
grants. Retained coordinator scopes recover before source journal recontact.

Plan 102's serving fixture uses explicit authorized review of actual retained
worker outputs for human-verifiable combined-artifact and journey criteria. The
trusted automatic verifier callback contract is qualified separately; the general
serving hosts do not install an automatic producer. No model-authored passing
flag or worker success can replace either form of criterion evidence.

Treefmt excludes machine-owned Keiro output; hand-owned
modules remain formatted and the scaffold gate checks exact generated bytes.

The PostgreSQL suite exercises public conflicts, sibling checkpoint commits,
revocation, source authenticity, rollback and process exit before acknowledgement.
Acceptance tests distinguish retained observations, verifier-backed checks,
authorized attestations, stale instructions and unresolved effects. The real
worker-session store supplies checkpoint intents and result receipts in those
tests; no alternate checkpoint codec is introduced.

## References

- [Plan 98](../plans/98-persist-authoritative-objectives-and-conditional-commands.md)
- [Plan 102](../plans/102-qualify-no-rei-objective-continuity-and-close-ir-13.md)
- [Objective operations](../operations/objective-tracking.md)
- [MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md)
- [ADR 0067](0067-objective-checkpoints-use-assignment-scoped-preconditions.md)
- [ADR 0068](0068-objective-creation-has-authority-before-association.md)
