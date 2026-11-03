# 0108. Adaptive decisions commit with authoritative checkpoints

Date: 2026-11-03

Status: accepted

## Context

An adaptive coordinator proposes changes to an objective's assignment graph and
then dispatches continuing-worker commands. A typed model answer establishes
syntax, not permission. A journal append can fail after the objective changes,
and an operator can revise instructions or revoke authority while a coordinator
is suspended. Recording acceptance in a separate transaction would permit a
manifest without its graph change, or dispatch without a retained decision.

## Decision

The objective command owner accepts a closed, versioned proposal by expected
checkpoint revision and stable operation key. It validates the entire proposal
under the objective transaction, including its pinned target/principal catalog,
hierarchy and dependency graphs, bindings, model permissions, evidence references
and authoritative root availability. The graph and protected executable manifest
commit with the objective receipt. The manifest records the exact input checkpoint
commitment, proposal, validator version, pinned policy, hierarchy and derived
operation keys before dispatch. Invalid proposals cannot reserve or dispatch work.

The checkpoint adapter recovers a committed decision by its original operation
key before consulting a live validator or policy callback. It checks current
objective access before revealing that protected record. Recovery never treats
changed payloads as retries. Uncommitted concurrent checkpoint changes conflict
and require another explicit proposal. Current objective definitions and fenced
owners remain authoritative; only hierarchy edges come from retained manifests.

Accepted manifests describe intents, not grants. Every later session or provider
command still requires its owning capability's current authority, stable logical
operation key, reservations and fences. Revocation can stop pending dispatch
without rewriting the historical accepted decision. Uncertain acknowledgements
must reconcile the original intent rather than create a replacement worker.

Integrated result evidence uses the objective owner's existing source verification
and acceptance rules. A coordinator can propose exact combined artifacts and
checks, but only the objective completion authority can accept them. Child exits
and model prose do not establish integrated acceptance.

## Alternatives rejected

A coordinator-owned mutable copy of assignment ownership or budget counters would
race the authoritative owners. A journal-only acceptance would not close the
crash window between checkpoint mutation and journal acknowledgement. Treating a
retained manifest as dispatch authority would bypass revocations and fences.

## Consequences

The application owns the additive `shikigami.adaptive_decisions` projection. It
retains protected manifests alongside objective receipts; terminal workflow GC is
not permission to delete records referenced by pending operations. Existing
objective commands and fixed supervisors retain their behavior. Adaptive Flow
execution and shared runtime capacity are separate acceptance gates in plan 85.

## References

- [Plan 85](../plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md)
- [ADR 0029](0029-model-routing-output-is-a-proposal-until-validated-against-journaled-authority.md)
- [ADR 0041](0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md)
- [ADR 0062](0062-session-generations-await-governed-children-and-retain-checkpoint-intents.md)

## Admission and retained-read qualification

Validator version 2 keeps permissions scoped to the assignment's named role,
including when another role shares its principal. Repeated ancestor roles are
hierarchy cycles, and transfer proposals must name a pinned workspace reference.
Version 1 manifests retain their decoder and their empty-workspace wire encoding;
a committed decision is never run through the newer validator.

The manifest projection is checked against its original objective receipt and
payload commitment before it supplies executable operations. Substitution or
corruption refuses without invoking live policy or dispatching replacement work.
Admission also consults the session owner for graph restructuring: a session can
exist before its first checkpoint publishes its reference into the objective.
An absent projected reference is not proof that the assignment is unfenced.
Metadata-only progress and exact evidence recording do not reserve fresh model
work; proposed execution checks its minimum model, tool and descendant costs
without copying or mutating the root's counters.
