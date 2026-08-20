# 0013. A flow body reaches the world only through replay-safe capabilities

Date: 2026-08-19

Status: accepted


## Context

A Shikigami "flow" is a Haskell function describing an agent behavior that runs
inside the durable agent-run workflow — `Shikigami.Flow.AtRiskCustomer` is the
worked example. Because it runs inside a Keiro workflow, its body is re-executed
on every resume and on every re-invocation of an already-completed instance, with
journaled steps answered from the journal and everything else run again. An
effect with an external footprint that is not wrapped in a step therefore happens
an unpredictable number of times.

`FlowEffects`, the constraint every flow body is written against, used to include
`IOE` and `Store`:

```haskell
type FlowEffects es =
  (Workflow :> es, Store :> es, IOE :> es, Memory :> es, Sink :> es, Activity :> es)
```

So a flow could `liftIO` anything at all, and no reviewer could prove one had
not. This was not theoretical. The `Memory` capability's own interpreter did
exactly that: `recall` was a bare `liftIO` query against the live store and
`remember` a bare `liftIO` write under a freshly minted random id. Replaying a
completed flow wrote one duplicate memory row per replay, and a flow branching on
what it recalled could take a different branch than the one its journal recorded
— the precise nondeterminism durable workflows exist to prevent. The non-flow
agent-run path had journaled both operations correctly all along, with a
crash-resume dedup test; only the flow path had drifted.

`Store` and `IOE` were reachable for one honest reason: `awaitAcknowledgement`
needed them, because parking for a human allocates an awakeable and arms a
durable deadline timer.


## Decision

**Every way a flow body reaches the world is an effect with a replay-safe
interpreter, and `FlowEffects` grants nothing else.**

```haskell
type FlowEffects es =
  (Workflow :> es, Memory :> es, Sink :> es, Activity :> es, Acknowledgement :> es)
```

* `Memory` journals each `recall` and `remember` as a Keiro step named from a
  caller-supplied stable label, so a replay is answered from the journal.
* `Sink` journals each emission the same way.
* `Acknowledgement` wraps the approval machinery. It exists so that parking no
  longer requires the flow to hold `Store` and `IOE`; the interpreter holds them.
* `Activity` is pure data about the trigger.
* `Workflow` stays so a flow can still name a pure checkpoint with `step`.
  Without `IOE`, that step body cannot smuggle IO in.

Adding an effect to `FlowEffects` widens what *every* flow may do and is a
decision of this record's weight. Add a capability instead.

Two properties of the `Memory` capability are part of this contract because a
journaled step alone does not deliver them:

* **A `remember` payload must be a pure function of replay-stable inputs.** Keiro
  steps are at-least-once at the step boundary, so `remember` derives a
  deterministic memory id from the workflow identity, the journal generation, and
  the label; a crash inside the step window re-derives the same id and Kioku
  answers idempotently instead of writing a second row. But Kioku's idempotency
  is conditional — `recordIn` compares the whole semantic payload and returns
  `MemoryConflict` when it differs. A note built from a fresh clock read or a
  live query therefore turns a retry into a hard failure. Call-time timestamps
  are deliberately excluded from that comparison, which is what makes the scheme
  work at all.
* **`supersedes` records lineage; it does not retire anything.** It writes "this
  memory descends from that one" onto the new row. The older memory stays active
  and stays recallable. This is Kioku's model, not a shortcut: `Kioku.Distill.L1`
  records a winner carrying `supersedes` and then issues distinct merge commands
  for the targets it means to retire. A flow capability that silently performed
  two aggregate writes from one call would be a surprising API, so it does not.


## Alternatives rejected

**Document the rule and rely on review.** This is what was in force, and it
produced the duplicate-memory defect in the only registered flow the repository
has. A constraint the compiler does not check is a constraint that erodes.

**Keep `IOE` and journal the capabilities anyway.** Fixes the known bug and
leaves the hole open for the next flow author. The bug was not that someone wrote
bad code; it was that the type let them.

**Give `Acknowledgement` its environment through the flow body.** That is what
the code did before: `FlowRuntime` was threaded into each flow so its body could
close over the approval environment and deadline. It made `flowRegistry` a
function of deployment configuration, so `Shikigami.Server.Command.RenderLifecycle`
had to mint a session id and a throwaway approval environment purely to print a
diagram. Putting the environment in the interpreter removed that.


## Consequences

`flowRegistry` is a plain `[FlowDef]` and `lookupFlow` takes only a name, so
asking which flows exist no longer requires the machinery for running one.
`FlowRuntime` survives as the `runAcknowledgement` environment. `registeredFlowNames`
remains a projection of the same single list, preserving the invariant ADR-0004
notes.

Test spikes that genuinely need the wider row — `FlowLifecycleSpec.sleepFlow`
calls `sleepNamed`, which needs `Store` and `IOE` — carry their own local
constraint and their own runner instead of being `FlowDef`s. A *registered* flow
cannot do this, and if one needs suspension it needs a capability.

Memory labels are declared in `domain/shikigami-agent-run.keiro`, so adding a
labeled memory call to a registered flow is a specification change subject to
[ADR-0012](0012-a-declared-workflow-body-only-grows-behind-a-patch.md), not a
one-line edit. Flows in the test harness run under a workflow name no member
declares and are outside that gate.

The flow write path still calls Kioku's deprecated `Kioku.Memory.record`. Moving
to `recordWithContext` is blocked on per-agent write contexts: `underContext`
requires the payload's `actorPrincipal` to equal the context's own, flow memories
are attributed to `shikigami.agent.<name>`, and Shikigami mints only a
service-actor context. `Shikigami.Memory.Access` names IR-9 as the owner of that
change. The deprecation warning is tolerated meanwhile.


## References

* `shikigami-core/src/Shikigami/Flow.hs` — the constraint and its haddock.
* `shikigami-core/src/Shikigami/Flow/Capability.hs` — `Memory`, `Sink`, and the
  deterministic id.
* `shikigami-core/src/Shikigami/Flow/Acknowledgement.hs` — the capability that
  removed the last ambient effect.
* `docs/plans/25-replay-safe-flow-memory-capabilities.md` — the plan this record
  distils, including the failing-then-passing duplicate-memory transcript.
* [ADR-0012](0012-a-declared-workflow-body-only-grows-behind-a-patch.md) — what
  declaring a new memory label costs.
* `docs/improvement-requests/key-agent-continuity-by-meibo-principal.md` — IR-9,
  which owns the move off Kioku's deprecated write wrappers.
