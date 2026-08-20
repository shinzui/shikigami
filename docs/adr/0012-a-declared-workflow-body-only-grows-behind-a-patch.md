# 0012. A declared workflow body only grows behind a patch guard

Date: 2026-08-19

Status: accepted


## Context

`domain/shikigami-agent-run.keiro` and `domain/shikigami-conversation.keiro`
declare each durable workflow's `body`: the inventory of journal labels every
path through that workflow can write. `just keiro-gate` classifies a change to
that inventory across six compatibility surfaces and refuses a `BREAKING`
finding.

There is a rule about how that inventory may change that nobody had written
down, and the natural assumption is wrong. `docs/workflow-versioning.md` said, of
adding a step, that "a new step with a new name is always safe: no existing
journal holds that name, so every in-flight instance simply runs it on its next
replay ... these two cover most changes and need no ceremony." That is true of
Keiro at run time and false of `keiro-dsl diff`, which is the thing that decides
whether the change ships.

`Keiro.Dsl.Diff.classifyWorkflowBody` compares the normalised old and new bodies
and admits exactly two additive escapes — a change wholly contained in a *new*
`patch` block, or a terminal `continueAsNew` append:

```haskell
safeAdditions =
  (not (null newPatchIds) || isJust appendedSeed)
    && comparableNewBody == oldBody
```

Everything else is `WorkflowBodyChanged`, breaking on `private-history-read` and
`old-binary-read-new-events`, with a stop-the-world rollout constraint. A pure
append is not special-cased; keiro-dsl's own suite pins that, in a test named
"classifies workflow relabeling and appends as WorkflowBodyChanged". There is no
waiver: `diff`'s only policy flag is `--gate SURFACE`, which *adds* failures.

The rule is structural and deliberately conservative. It does not consult the
differ's own replay verdict, which reported `replay-neutral: stored-data replay
is unchanged by this diff` about the very change it called breaking.

`docs/plans/25-replay-safe-flow-memory-capabilities.md` is the evidence that this
is worth writing down. It researched the runtime semantics correctly, concluded
in its Decision Log that "no `patch` guard is needed ... the change is purely
additive step insertion", made passing `just keiro-gate` an acceptance criterion,
and only discovered at the gate that the two requirements were incompatible. Both
steps previously added to the agent-run body had in fact been patch-guarded —
`resolve-profile` inside `shikigami-resolve-profile-v1`, `run-behavior-v2` inside
`shikigami-behavior-retry-v1` — so the practice was already unanimous and only
the reasoning was missing.


## Decision

**Adding, removing, or reordering a label in a declared workflow body requires a
new `patch` block containing the whole change, and the runtime must honour that
guard with a real branch.**

Concretely:

* The new labels go inside one `patch <id> { ... }` block. The block must contain
  the entire change and nothing else — `stripNewPatches` removes it wholesale
  before comparing, so any edit outside it re-breaks the comparison.
* The block must be contiguous, which sometimes means the labels cannot sit where
  they would read best. That is acceptable: a workflow body is ordered for
  reading, not for control flow, because replay matches journal records by label.
* The runtime reads the guard and branches on it. The `False` branch carries the
  genuine pre-change behavior, so an instance already in flight keeps the shape
  its journal was written under. A guard the runtime ignores would be a
  declaration nobody honours, which
  [ADR-0001](0001-declare-only-what-the-runtime-executes.md) forbids.
* The guard is read once per interpreted run rather than per operation, so every
  operation of one instance agrees which scheme it is on.
* Retiring the guard follows [ADR-0004](0004-one-options-value-and-a-checked-patch-set.md):
  delete the `False` branch and the specification id in the same commit, once no
  pre-change instance can resume.

A step name the specification *cannot* hold — anything carrying a colon or a
runtime-computed suffix, such as `emit-signal:<label>` — is genuinely free,
because there is no declared body for the differ to compare. That is the only
case where "additive needs no ceremony" still holds, and it is a reason to prefer
declarable hyphenated labels rather than an argument for colons.


## Alternatives rejected

**Leave the labels undeclared.** The gate then passes trivially and the runtime
stays clean — no patch id, no legacy branch. This is what the `emit-signal`
family does, and it was seriously considered for the flow memory labels. It was
rejected because the declaration is the durable half of the value: an undeclared
label is stable only by convention, and `just keiro-diff` cannot see a change to
it. Trading a permanent gate for a temporary branch is the wrong way round.

**Declare the patch and let the runtime ignore it.** Cheapest possible fix and
strictly dishonest. The specification would assert a guard that guards nothing,
a future contributor would read the declaration rather than the code, and
ADR-0001 exists precisely to refuse this.

**Ask keiro-dsl for a waiver.** There is none, and asking for one would be
arguing that this service knows better than the differ about a class of change
the differ is conservative about on purpose.


## Consequences

Growing a declared workflow costs a patch id, a regeneration, a hand-edit to
`KeiroConformance.Expectations`, and a runtime branch — every time, not once.
Budget for it when planning work that adds journal labels. The pressure this
creates is healthy: it makes "does this really need a new journaled step?" a
question with a price attached.

Each guard leaves behind a `False` branch reproducing the behavior the change
was meant to remove. That code is not dead and must not be deleted casually; it
is what keeps pre-change instances coherent. It is also not permanent — see
ADR-0004's retirement rule. Shikigami has no users today, so every such
population is currently empty, which makes retirement cheap and makes it easy to
forget that the branches exist. `docs/workflow-versioning.md` lists them.

Journals gain one `patch:<id>` record per guard, and assertions comparing exact
step-name sets must filter them. `AgentWorkflowSpec.loadLifecycleStepKeys` and
`FlowLifecycleSpec.flowStepKeys` both do.

`docs/workflow-versioning.md` rule 2 is corrected to state this, since it was the
document that produced the wrong expectation.


## References

* `docs/workflow-versioning.md` — rule 2, the corrected version, and the journal
  label inventory.
* [ADR-0001](0001-declare-only-what-the-runtime-executes.md) — why a declared
  guard obliges a real branch.
* [ADR-0004](0004-one-options-value-and-a-checked-patch-set.md) — where patch ids
  come from, and how to retire one.
* `docs/plans/25-replay-safe-flow-memory-capabilities.md` — the plan that hit
  this, with the failing and passing gate transcripts.
* `mori://shinzui/keiro-runtime-patterns/docs/keiro-evolution-and-rollout` — the
  fleet's gate ladder: "each gate answers a question the earlier ones cannot, so
  none of them substitutes for another."
