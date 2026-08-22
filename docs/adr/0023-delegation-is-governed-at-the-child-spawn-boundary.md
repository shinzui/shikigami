# 0023. Delegation is governed at the child-spawn boundary

Date: 2026-08-22

Status: accepted


## Context

Shikigami's original delegation proof was selected by the literal
`research-supervisor` task name. It could spawn two fixed children, but an agent
declaration could not say whether delegation was allowed, a Flow could not use
the mechanism, and descendants shared neither a cycle check nor a global fan-out
limit.

A copied “remaining budget” does not bound a tree: two siblings can inherit the
same remainder and each spend it. Durable replay adds another constraint. A
child must keep the same identity across a retry, and retrying the same spawn
must not spend a second slot. Source-order ordinals are not stable identities
when calls are inserted or reordered.

Keiro 0.14 exposes idempotent `spawnChild`, `awaitChild`, and `cancelChild`, but
its child-registration transaction is private. Shikigami cannot atomically
combine a budget write with public child registration without copying SQL for
Keiro-owned tables.


## Decision

**Every child creation passes through one governed delegation boundary.**

An `AgentDecl` carries an explicit target allow-list and an optional bounded
delegation budget. `Shikigami.Agent.Delegate.delegate` checks that declaration,
the complete ancestor-name lineage, and the depth limit before creating a
child. Both declaration-driven supervisors and the Flow `Delegate` capability
call this same function; policy is not duplicated in either caller.

The budget is one durable ledger for the complete root-run tree. Every child
carries its root `DelegationBudgetId`. Before spawn, Shikigami reserves a slot
under the deterministic child workflow id while locking the ledger row. The
reservation key makes replay idempotent, and the row lock prevents concurrent
siblings from overspending.

Child workflow ids derive from the parent workflow id, target agent, and a
caller-supplied stable delegation key. The generic supervisor derives
`delegate-<index>` keys from the `delegates` list stored in the journaled agent
declaration; Flow authors name their call sites directly.

Reservation commits before Keiro's public `spawnChild`. A crash in that window
can leave a reserved slot without a registered child, but replay observes the
same reservation and repairs the same child. This ordering chooses the safe
failure direction: an unbudgeted child cannot start. Shikigami does not import
private Keiro modules or mutate Keiro-owned tables.


## Alternatives rejected

**Keep a task-name-specific supervisor.** This leaves delegation as a demo,
cannot govern Flow callers, and makes every new supervisor another workflow
branch.

**Copy a decremented budget into each child.** Sibling branches can spend the
same remainder independently, so the root limit is not real under concurrency.

**Use a fresh ordinal as child identity.** Inserting or reordering a delegation
call shifts later ordinals and moves durable children on replay.

**Copy Keiro's private registration SQL to make one cross-library transaction.**
That couples Shikigami to framework-owned schema and bypasses the public child
semantics. Reserve-first convergence preserves ownership and fails safely.

**Enforce policy only in the Flow interpreter.** Imperative supervisors could
bypass it. The shared spawn boundary is the only location every caller must
cross.


## Consequences

Existing declarations decode with an empty allow-list and therefore cannot
delegate accidentally. A non-Flow declaration with a non-empty `delegates` list
uses the generic supervisor; a Flow declaration retains control of its own
delegation calls through the capability interpreter.

Operators can inspect `shikigami.delegation_budgets` and
`shikigami.delegation_reservations` for root-wide consumption. A reservation
may remain ahead of child registration until its parent resumes; cleanup must
never reclaim it merely because registration is temporarily absent, because a
replay may still repair that child.

Callers must provide stable keys. Reusing one key for the same target is replay;
using distinct keys spends distinct slots. The result type of a delegated child
is the actual durable `Either AgentRunFailure AgentRunResult`, shared between
the workflow and delegation modules.

The checked agent-run body already declared `child delegate`, and the routing
change is driven by the `AgentDecl` value captured in `lookup-agent`. Old
journals decode with an empty allow-list and cannot enter the new branch, so no
new patch id or workflow label is required. `just keiro-gate` classifies the
change as replay-neutral.


## References

* `docs/plans/35-delegation-as-a-first-class-declared-capability.md` — implementation plan and
  acceptance evidence.
* [ADR-0012](0012-a-declared-workflow-body-only-grows-behind-a-patch.md) — the workflow-shape
  rule this change does not trigger.
* [ADR-0013](0013-flows-reach-the-world-only-through-capabilities.md) — why Flow receives a
  delegation effect rather than direct store and workflow access.
* `docs/workflow-versioning.md` — stable identity and durable workflow compatibility rules.
* `mori://shinzui/keiro` — the released public child-workflow API consumed here.
