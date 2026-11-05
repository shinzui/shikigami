# 114. Standing policies are revocable durable grants, and admission funds an independent coordinator run

Date: 2026-11-04

Status: Accepted

## Context

[IR-21](../improvement-requests/propose-unrequested-work-from-observed-activity.md)
makes human acceptance the default for unrequested work and allows exactly one way
past it. That exception must be explicit, bounded and revocable, must stop new work the
moment an operator revokes it, and must not leak into any authority the work would not
otherwise hold. Admitted work also needs an envelope far larger than the one evaluation
that noticed it.

## Decision

A standing policy is a durable row installed only by the configured local operator. No
agent declaration, Skill or observed text can create one. Installing never updates a
row: a changed policy is a new policy and a revocation of the old one, so every admission
receipt stays pinned to the exact digest it ran under. A policy that could never admit
is refused at install, including one whose per-objective envelope could not pay for a
model attempt.

`reserveAdmission` is the authority. It locks the policy row, re-reads revocation and
expiry against the current instant, checks the requested repository and action class
against the row rather than a journaled copy, and takes one admission from the window
and one whole per-objective envelope from the totals. The Flow's own view of which
policies cover a run is only a list of ones to try. Totals are conservative arithmetic
over the policy's own rows, excluding `ActiveWork`, which is a gauge each root bounds for
itself. A reservation stays consumed even when its admission later fails.

Admission funds and staffs an independent coordinator run with its own resource root
rather than a delegated child. The proposer creates the objective under its existing
default-deny creation grant, enrolls a root for the coordinator run's derived workflow id
with the per-objective envelope, grants the coordinator its role, sets the single
`deliver` assignment, and registers the run's association with the objective owner in the
same transaction that enqueues it. Each step is journaled and idempotent under its own
key.

A policy grants no workspace, sink or tool authority. The coordinator's declared identity,
workspace grants, sink grants and action authorization are unchanged, and the objective's
template is the same one a person would have approved: it stops at a reviewable artifact
and forbids publication. A covering policy also narrows what the assessment is offered, so
a model can only choose what that policy could admit.

An exhausted window or total, or a policy gone at the fresh read, is a recorded refusal in
the journal and the proposal falls back to a person. Before an objective exists a failed
admission also falls back. After one exists, the partial objective stays visible and the
proposal is refused, because a second objective for the same subject would be worse.

## Alternatives

Policy in process configuration was rejected because revocation would need a restart and
admissions could not pin a digest. A journaled policy snapshot was rejected because
revocation must stop new admission immediately. A delegated child was rejected because
descendants cannot enroll roots and would inherit an envelope sized for one evaluation.
Reading actual usage for totals was rejected because it couples a policy to settlement and
to unknown usage.

## Consequences

Revocation is immediate for new admissions only: admitted work continues under its own
objective, root and coordinator controls, and stopping it is a separate act. Totals are
promises rather than measurements, so an underspending objective still consumes its whole
envelope, and an operator reclaims capacity by installing a new policy. Because a covering
policy narrows the model's choices, work outside it is refused by the validator instead of
being offered to a person.
