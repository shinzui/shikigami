# 0030. An approval request is a durable child workflow

Date: 2026-08-23

Status: accepted


## Context

Shikigami has one approval primitive but two callers. An ordinary agent run may require a human
before a declared sink is enqueued, and a Flow may explicitly wait for acknowledgement. Both use a
Keiro awakeable and deadline. The current sink path identifies repeated approvals with computed
labels such as `approval:KawaDigest:0`; the notifier derives another computed `:notify` label. These
values replay, but Keiro DSL labels are static wire words and cannot express a colon or a runtime
ordinal. The checked workflow contract therefore cannot inventory the approval family.

Changing labels in place would orphan an in-flight await. Keeping the computed family for fresh
runs would preserve the blind spot identified by ADR 0017. Rotating the whole agent run after each
approval would make a sink-local concern reshape every surrounding behavior, memory, delegation,
and outbox step.

Approval policy introduces a separate replay hazard. A worker can restart with a different
`approval.require`, channel, or deadline while an old agent run is incomplete. Re-reading process
configuration at the decision point could make one workflow skip a gate it previously required or
adopt a gate that did not exist when it began.

The human-facing identity also has two incompatible jobs. A review request needs a stable public
identifier that can remain in run evidence and later lookup. The completion token is an
authorization capability. Keiro deliberately makes an `AwakeableId` random and journals it, so
deriving it from public workflow coordinates would weaken that boundary.


## Decision

**Each fresh approval request runs as a dedicated `shikigami.approval` child workflow, while its
parent journals one run-local approval-policy snapshot before approval can affect execution.**

The child has one request and one generation, with the static application labels
`ingest-approval`, `notify`, and `decision`. Its deterministic workflow id is the stable
`ReviewRequestId`, derived with UUIDv5 from the parent workflow name, workflow id, generation, and a
stable purpose key. Sink purpose keys contain the canonical sink kind and declared ordinal; Flow
purpose keys prefix the call site's durable step name with `flow-`. Keiro's own reserved child steps
represent the repeated family in the parent, and the checked AgentRun specification declares that
family as one `child approval` node.

The parent shape change is guarded by the permanent patch id
`shikigami-approval-workflow-v1`. The false branch retains the direct awakeable and computed labels
for pre-change instances. The true branch first journals `resolve-approval-policy`, containing the
required sink-kind set, notification channel, and deadline, then uses that recorded value for the
rest of the run. The false branch and patch remain until the operational drain procedure in ADR
0004 proves they can be retired.

The review id and resolution token remain separate. `ReviewRequestId` is public, stable, and safe
to index. `AwakeableId` remains Keiro's opaque random, journaled, one-shot token. Notification
renders both. The administrative resolution command calls Shikigami's existing
`resolveApproval` function with the token; it does not derive a token from the review id or address
the parent by workflow key and label.

The child journals successful notification before it arms the deadline and awaits. A transient
notification failure throws before the notify result is recorded and uses Keiro's durable attempt
and backoff policy. A permanent notification failure becomes a typed child result and fails the
parent session without awaiting or enqueuing a sink. Remote notification is at-least-once: a crash
after remote acceptance but before local journal commit may post the same review id and token
again.

The Keiro DSL declares the child workflow and parent patch, but no signal operation for approval
resolution. A DSL signal is keyed through a declared workflow key and await label; the implemented
command is keyed by random `AwakeableId`. Declaring a different operation would violate ADR 0001.


## Alternatives rejected

**Keep computed approval labels outside the checked specification.** This preserves replay but
leaves every new approval invisible to the evolution gate, so a later rename or reordered ordinal
can silently strand or duplicate work.

**Replace the colon with a hyphen and retain the runtime suffix.** A different separator satisfies
the character grammar but does not make a runtime-computed family static or reviewable.

**Continue the parent as new around each approval.** Conversation rotation makes one unbounded
turn static by giving each turn a generation. An agent run may have Flow waits and several sinks;
rotating it around those requests would force unrelated behavior, memory, and dispatch state across
a new-generation input contract.

**Read approval configuration whenever a sink or Flow reaches a gate.** A deployment change would
alter an in-flight workflow's policy during replay. The journaled snapshot is the authority for that
run, as ADR 0007 already requires for mutable execution profiles.

**Use `ReviewRequestId` as the awakeable token.** A deterministic public identifier is suitable for
evidence lookup but not for a capability that authorizes a one-shot decision.

**Declare a workflow-keyed DSL signal and translate it to the awakeable internally.** No such
runtime mapping exists. It would create a second addressing contract and claim generated behavior
the operator command does not execute.


## Consequences

Fresh approval children are fully represented by the checked workflow inventory and can be added
to the existing resume registry. The parent keeps legacy code and labels during the patch window,
so the implementation and replay tests must maintain both branches until drain.

Configuration changes apply to new agent runs, not the middle of an existing run. Even an empty
sink-approval set is journaled on the true branch. Explicit Flow acknowledgements still notify a
human because they are semantic gates in the Flow, not ordinary sink-policy decisions.

The child relation, journal, awakeable, timer, retry attempts, and failure state stay in Keiro's
existing persistence. Shikigami adds no approval table. An approved sink still crosses the parent
journal boundary only by enqueueing its outbox intent, preserving ADR 0022.

Run evidence can retain the same `ReviewRequestId` text encoding while importing its owning type
from approval. The token does not enter attestation identity. A future HTTP resolution endpoint may
call the same `resolveApproval` function, but it must preserve opaque-token semantics unless a new
decision deliberately introduces a reviewed mapping.


## References

* [`docs/plans/14-approval-and-human-in-the-loop-end-to-end.md`](../plans/14-approval-and-human-in-the-loop-end-to-end.md)
  — implementation plan and acceptance proof.
* [`docs/workflow-versioning.md`](../workflow-versioning.md) — patch activation, deploy simulation,
  and retirement procedure.
* [ADR 0001](0001-declare-only-what-the-runtime-executes.md) — generated declarations must match the
  runtime that actually executes.
* [ADR 0004](0004-one-options-value-and-a-checked-patch-set.md) — patch activation and retirement.
* [ADR 0007](0007-a-resolved-profile-is-a-run-local-policy-snapshot.md) — journaled policy snapshot
  precedent.
* [ADR 0012](0012-a-declared-workflow-body-only-grows-behind-a-patch.md) — parent body evolution.
* [ADR 0017](0017-rotate-to-make-a-label-static-rather-than-computing-it.md) — static-label rule and
  the approval family that still needed structural resolution.
* [ADR 0021](0021-operator-verbs-wrap-the-owning-library.md) — operator command ownership.
* [ADR 0022](0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md) — approved sink
  enqueue boundary.
* [ADR 0026](0026-outbound-sink-credentials-stay-opaque-and-http-policy-lives-at-the-process-boundary.md)
  — authenticated notification clients and HTTP failure classes.
* `mori://shinzui/keiro/packages/keiro` — child workflow, awakeable, timer, patch, and resume
  contracts.


## Implementation evidence — 2026-09-07

Plan 65 removed shikigami-approval-workflow-v1 and its unused false branch under the verified ADR 0027 exception. Every current agent run journals its policy and uses the dedicated approval child. Public review identity remains distinct from the random journaled one-shot token. Restart and duplicate-resolution acceptance use the token actually rendered by the Danwa notifier.

See [Plan 65](../plans/65-migrate-shikigami-to-the-keiro-0-15-cohort-and-the-idiomatic-v2-record-model.md) and [ADR 0038](0038-runtime-startup-and-maintenance-share-validated-owners.md).
