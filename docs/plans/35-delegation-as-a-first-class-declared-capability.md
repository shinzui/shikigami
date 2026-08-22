---
id: 35
slug: delegation-as-a-first-class-declared-capability
title: "Delegation as a first-class declared capability"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tyzqcerzv4ysbktgr9sw9"
master_plan: "docs/masterplans/7-platform-feature-completion-egress-schema-memory-lifecycle-delegation.md"
---

# Delegation as a first-class declared capability

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami has a working multi-agent delegation *mechanism* but exposes it as a demo, not a
capability. An agent run can spawn a child agent-run workflow, wait for it, and read its
output — the machinery in shikigami-core/src/Shikigami/Agent/Delegate.hs (deterministic
UUIDv5 child workflow ids, `spawnChild`, a pre-journaled child "ingest-job") works and is
tested (shikigami-core/test/Shikigami/AgentWorkflowSpec.hs delegation cases;
DelegateContextSpec's depth-4 bound). But the *only* way to reach it is a hardcoded special
case: `runBehaviorStep` matches `task == researchSupervisorTaskName` and calls
`runResearchSupervisor` (shikigami-core/src/Shikigami/Agent/Workflow.hs:287-288, :344-372),
which delegates to two stub children that return fixed strings
(shikigami-core/src/Shikigami/Program/Registry.hs:101-113). There is no way to *declare* that
an agent may delegate, no way for a Flow behavior to delegate, no cycle detection (only a
depth-4 bound; A→B→A→B is allowed), no budget, and no way to collect partial results or cancel
siblings on failure.

After this plan, delegation is declared and governed. An agent lists whom it may delegate to:

```dhall
, delegates = [ "web-researcher", "code-researcher" ]
, delegationBudget = Some 8
```

A Flow can delegate through a capability (`delegate`/`awaitDelegated`/`awaitAllDelegated`
effects), and every delegation is checked against the allow-list, rejected if it would form a
cycle (an agent already in the ancestor chain), and denied once the run's child-run budget is
exhausted. The budget is a single durable root-run budget, consumed atomically and
idempotently by every child anywhere in the tree; sibling branches cannot each inherit and
spend the same remainder. A supervisor can collect per-child results as `Either` values and cancel its
siblings when one fails. The hardcoded research-supervisor special case is gone, re-expressed
on the general mechanism. The observable proof is a set of real-Postgres workflow tests: a
declared supervisor delegates to allow-listed children and synthesizes their outputs; an
undeclared target is refused; a cycle is refused; an over-budget delegation is refused; and a
failing child triggers sibling cancellation with a collected partial result.

This plan hard-depends on the platform foundations. Plan 33
(docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md) establishes
the additive field-with-default pattern used when `delegates`/`delegationBudget` are added
to the same `Agent` record (MasterPlan 7, IP-1). Plan 24
(docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md) establishes the
versioning discipline, patch plumbing, and step inventory required before changing the
durable agent-run workflow (MasterPlan 5, IP-3).
Plan 36 fixes package ownership, plan 37 provides the validated platform default, plan 38
owns the budget-ledger migration, and plan 39 requires the changed workflow topology and
step contract to pass the checked Keiro DSL evolution gate before runtime code is merged.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-22T22:24:21Z) Pre-implementation refresh: plans 24, 33, 36, and 39
      are complete; plans 37 and 38 have delivered the configuration declaration and
      pg-migrate component this plan needs, while their unrelated migration-CLI remainder stays
      open. The delivered tree uses `Shikigami.Agent.Decl` and
      `Shikigami.Agent.RunJob` in `shikigami-core`, Keiro is pinned and published at
      0.14.0.0, the checked workflow already declares `child delegate`, and the five existing
      delegation tests pass.
- [x] (2026-08-22T22:33:26Z) M1: added `delegates : List Text` and
      `delegationBudget : Optional Natural` to `schema/Agent.dhall` with additive defaults,
      validated budgets into the bounded `DelegationBudget`, configured the platform default
      as 16, and made the existing research-supervisor proof manifest declare its two children
      and budget 8. Both that manifest and unchanged heartbeat validate; declaration,
      wire-compatibility, and configuration tests pass.
- [x] (2026-08-22T22:33:26Z) M1: introduced the shared `ingestJobStepName`
      constant and used it in both `Workflow.hs` and `Delegate.hs`; the durable text remains
      byte-identical as `ingest-job`.
- [ ] M2: add `lineage : [Text]` and `delegationBudgetId : Maybe DelegationBudgetId` to `RunJob`; initialize one durable root budget and propagate its identity across every descendant.
- [ ] M2: atomically and idempotently reserve one global budget slot per deterministic child workflow id; add ancestor-cycle and exhausted-budget rejection.
- [ ] M3: a `Delegate` Flow capability (`delegate`, `awaitDelegated`, `awaitAllDelegated`) added to `FlowEffects`; allow-list enforced at the capability boundary.
- [ ] M4: `awaitAllDelegated :: [Delegated a] -> Eff es [Either Text a]` and sibling cancellation via keiro `cancelChild`; a failure-policy field or awaitAll variant.
- [ ] M5: re-express `runResearchSupervisor` on the general mechanism (allow-list + budget + awaitAll); delete the `task == researchSupervisorTaskName` special case.
- [ ] Tests: allow-list refusal, cycle refusal, budget refusal, partial-collection + sibling cancel — all under `withShikigamiMigratedDatabase`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- (Authoring-time) `parentRunWorkflowId` is already carried through `RunJob` and
  `DelegateCtx` but never read for cycle detection: `runResearchSupervisor` builds a
  `DelegateCtx` with it (Workflow.hs:349-356) and `delegate` threads it into the child
  `RunJob` (Delegate.hs:59-61), yet `checkDepth` only compares depth
  (Delegate/Context.hs:39-51). Cycle detection needs an *ancestor chain*, not a single parent
  id — hence M2 adds a `lineage` list rather than reusing the single field.
- (Authoring-time) The child "ingest-job" step name is a brittle stringly contract: Delegate.hs
  pre-journals a step literally named `"ingest-job"` (Delegate.hs:66-70) that must match the
  first step `runResolvedAgent`/`agentRunWorkflow` reads back (Workflow.hs:135, the
  `StepName "ingest-job"`). A rename on either side silently breaks delegation with no
  compile error. M1 ties them to one shared constant.
- (Authoring-time) keiro's `cancelChild :: ChildHandle a -> Eff es Bool` exists
  (/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Workflow/Child.hs:272) and is unused in
  shikigami; `awaitDelegated` currently throws on a child failure (Delegate.hs:82-88), which
  is why a supervisor cannot collect partial results today.
- (Review-time) Propagating a decremented scalar to each child does not bound the whole tree:
  two siblings can each receive the same remainder and spend it independently, allowing total
  descendants to exceed the root declaration. The budget must therefore be shared, durable,
  atomic under concurrent siblings, and replay-idempotent.
- (Implementation refresh, 2026-08-22) Keiro 0.14 keeps `registerChildTx` private to
  `Keiro.Workflow.Child`; the public `spawnChild` opens its own transaction. Shikigami therefore
  cannot combine its budget reservation and Keiro's child registration in one transaction without
  importing an internal module or writing Keiro-owned tables. Reserving first under the same
  deterministic child id has the required safety direction: no child can spawn unbudgeted, and a
  crash before `spawnChild` retries the same reservation instead of spending twice.
- (Implementation refresh, 2026-08-22) The current child id still uses
  `freshOrdinal "delegate"`. `docs/workflow-versioning.md` now explicitly lists that identity as
  unstable when code inserts or reorders delegation calls. The general capability needs a
  caller-supplied stable key; preserving the ordinal API would formalise the exact hazard this plan
  owns.


## Decision Log

Record every decision made while working on the plan.

- Decision: The declaration surface is `delegates : List Text` (default `[]`) — an allow-list
  of agent names this agent may delegate to — plus `delegationBudget : Optional Natural`
  (default `None` = use the platform default) — the maximum number of child runs one run may
  spawn across its complete descendant tree. Both follow plan 33's additive
  field-with-default pattern.
  Rationale: an allow-list is the minimal declaration that makes "may this agent delegate, and
  to whom" answerable from the manifest; a name list (not a richer capability grant) matches
  how the runtime already resolves agents by name (`find ((== agentName job) . agentDeclName)`,
  Workflow.hs:135). A budget as `Optional Natural` keeps existing manifests unchanged while
  letting an operator cap a supervisor's fan-out; manifest decoding immediately validates it
  into `DelegationBudget` (0–1000) so an unbounded `Natural` or partial `Natural`-to-`Int`
  conversion never reaches runtime code. `None` uses plan 37's validated platform default
  (`16` initially, finite and within the same domain).
  Date: 2026-07-08

- Decision: Cycle detection uses an ancestor *chain* carried on `RunJob` as
  `lineage :: [Text]` (agent names from root to current), not the existing single
  `parentRunWorkflowId`. `delegate` rejects a target already in `currentLineage` with a new
  `DelegationCycleDetected` error; the child's `RunJob.lineage` is `currentLineage ++ [target]`.
  Rationale: A→B→A is a cycle even though B's immediate parent (A) differs from the *target*
  (A); only a full ancestor set catches it. Carrying names (not session ids) makes the check a
  cheap `elem` and keeps the wire payload small; the depth-4 bound stays as a second guard.
  Date: 2026-07-08

- Decision: Budget is a durable root-run ledger identified by `DelegationBudgetId`. `RunJob`
  carries only `delegationBudgetId :: Maybe DelegationBudgetId`; a root with `Nothing`
  creates or finds its deterministic ledger, and every child carries the same identifier.
  Before spawning a deterministic child workflow, `reserveDelegationSlot` atomically inserts
  a reservation keyed by `(budgetId, childWorkflowId)` and increments `consumed` only for a
  new reservation whose ledger is below `maximum`. Exhaustion yields
  `DelegationBudgetExhausted`; replay of the same child reservation succeeds without another
  increment.
  Rationale: a remaining scalar copied into sibling jobs is not a global tree bound. A
  database ledger serializes concurrent siblings, survives process restarts, and uses the
  already-deterministic child workflow id as its idempotency key. The migration is owned by
  plan 38 and the reservation plus child registration/pre-journaling must share one database
  transaction so neither an orphan reservation nor an unbudgeted child can commit.
  Date: 2026-07-22

- Decision: Update the checked Keiro DSL specification from plan 39 before changing the
  runtime. It records the delegation child edge, unchanged `"ingest-job"` journal name,
  cancellation paths, and durable budget-reservation boundary; the generated/evolution diff
  is a required CI gate.
  Rationale: delegation changes durable topology and replay-visible input. Reviewing the
  specification diff first makes compatibility choices explicit instead of discovering them
  after Haskell implementation.
  Date: 2026-07-22

- Decision: Allow-list enforcement lives at the delegation call boundary, checked against the
  *delegating agent's* `delegates` list, and applies to both the imperative
  `runResearchSupervisor`-style path and the new Flow capability. A target not in the list is
  refused with `DelegationNotAllowed target`.
  Rationale: the check must see the delegating agent's declaration; both entry points have (or
  can be given) the `AgentDecl`, so a single `assertMayDelegate :: AgentDecl -> Text -> Either
  DelegationError ()` guard is shared. Enforcing in `delegate` itself (rather than only at the
  Flow boundary) means the imperative supervisor is governed too.
  Date: 2026-07-08

- Decision: Failure policy is a new `awaitAllDelegated :: [Delegated a] -> Eff es [Either Text
  a]` that awaits every child and returns per-child results without throwing, plus an explicit
  `cancelSiblingsOnFailure :: [Delegated a] -> Eff es [Either Text a]` variant that, on the
  first child failure, cancels the not-yet-completed siblings via keiro `cancelChild` and
  returns the collected partials. `awaitDelegated` (throw-on-failure) is kept for callers that
  want fail-fast.
  Rationale: the two real policies — "collect whatever succeeded" and "one fails, abandon the
  rest" — map to these two functions; keeping the throwing `awaitDelegated` avoids breaking the
  existing tests and the depth-4 semantics. `cancelChild` already exists and returns `Bool`
  (found/cancelled), so the variant is a fold over handles.
  Date: 2026-07-08

- Decision: One shared `ingestJobStepName :: StepName` constant (placed in
  `Shikigami.Agent.Workflow.Name` beside `agentRunWorkflowName`) replaces the two independent
  `"ingest-job"` string literals in Workflow.hs (the `runStep ... (StepName "ingest-job")` at
  Workflow.hs:134 area and `lookupTask` flow) and Delegate.hs:66-70.
  Rationale: a rename must not silently break the pre-journaled child step; a shared constant
  turns a runtime break into a compile-time one. Per the MasterPlan's IP-3 and Decision Log,
  the *value* stays `"ingest-job"` byte-for-byte so in-flight journals replay; only the
  Haskell reference is centralized.
  Date: 2026-07-08

- Decision: Removing the `researchSupervisor` special case, re-express it as a normal
  `ShikumiProgram`/supervisor behavior that reads its children from its own `delegates` list
  and uses `awaitAllDelegated`. The web/code stub children remain (they are useful fixtures)
  but are reached through the general path.
  Rationale: the special case (Workflow.hs:287-288) is exactly the anti-pattern this plan
  removes; keeping the stub children as allow-listed targets lets the existing delegation
  tests keep passing with minimal edits, proving the general mechanism subsumes the demo.
  Date: 2026-07-08

- Decision: Derive every child workflow id from the parent workflow id, target agent, and a
  caller-supplied stable delegation key; remove `freshOrdinal` from delegation identity.
  Rationale: a counter is stable only while source order is frozen. Flow callers can name a
  durable call site directly. The generic supervisor derives its keys from the `delegates` list
  stored in the journaled `lookup-agent` result, so a manifest edit cannot move an in-flight
  run's child identities.
  Date: 2026-08-22

- Decision: Reserve a budget slot before calling Keiro's public `spawnChild`, rather than
  duplicating Keiro's private child-registration SQL to manufacture a cross-library transaction.
  Rationale: the public API exposes no transactional spawn primitive at 0.14.0.0. Reservation and
  spawn share one deterministic child id; reserve-first prevents an unbudgeted child, and replay
  repairs the only crash window by observing the existing reservation before idempotently spawning
  the child. Keeping ownership boundaries is more durable than coupling to Keiro's tables.
  Date: 2026-08-22

- Decision: Add this plan's ledger migration to Shikigami's existing pg-migrate component.
  Rationale: plan 38 delivered the component, manifest, runner, and real-Postgres fixture; it did
  not pre-author tables for later plans. Schema ownership follows the code that defines the
  delegation budget rather than reopening plan 38.
  Date: 2026-08-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Shikigami (this repo) runs each agent as a durable keiro *workflow* — a function whose steps
are journaled so that if the process crashes, the workflow *resumes* from the journal rather
than restarting. The agent-run workflow is `agentRunWorkflow`
(shikigami-core/src/Shikigami/Agent/Workflow.hs:129-138); it runs steps named "ingest-job",
"lookup-agent", "open-session", "recall", "run-behavior", "dispatch-sinks", "record",
"complete" (each `runStep`/`step` call journals its result under a `StepName`). A "child
workflow" is another workflow spawned from a running one; keiro provides `spawnChild`,
`awaitChild`, and `cancelChild` (/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Workflow/Child.hs).

Delegation today. `Shikigami.Agent.Delegate.delegate`
(shikigami-core/src/Shikigami/Agent/Delegate.hs:32-72) spawns a child agent-run workflow: it
computes a deterministic child `WorkflowId` (UUIDv5 of parent-id + child-agent + ordinal, so a
replay recomputes the same id), calls `spawnChild agentRunWorkflowName childWorkflowId ...`,
and **pre-journals the child's first step** — a `StepRecorded { stepName = "ingest-job",
result = toJSON childJob, ... }` — so the child resumes with its `RunJob` already ingested.
`awaitDelegated` (Delegate.hs:75-95) suspends until the child completes and decodes its
`behaviorOutput`, **throwing** `DelegatedChildFailed`/`DelegatedChildCancelled` on a bad
outcome. Depth is bounded by `checkDepth` (shikigami-core/src/Shikigami/Agent/Delegate/Context.hs:39-51),
which allows attempted depths 1-3 and rejects 4 (`maxDelegationDepth = 4`). The `DelegateCtx`
(Delegate/Context.hs:14-19) carries `delegateDepth`, `sessionId`, `parentSessionId`, and
`parentRunWorkflowId` — the last is threaded but never checked for cycles.

The only caller. `runBehaviorStep` (Workflow.hs:284-289) special-cases
`ShikumiProgram { task } | task == researchSupervisorTaskName` and calls
`runResearchSupervisor` (Workflow.hs:344-372), which builds a `DelegateCtx`, delegates to
`webResearcherTaskName` and `codeResearcherTaskName` (names in
shikigami-core/src/Shikigami/Program/Registry.hs:57-63), awaits them **sequentially**
(Workflow.hs:364-365), and synthesizes a fixed object. The two children are stub tasks
returning fixed strings (Program/Registry.hs:101-113). No other behavior can delegate; Flow
behaviors especially cannot — `FlowEffects` (shikigami-core/src/Shikigami/Flow.hs:28) is
`(Workflow, Store, IOE, Memory, Sink, Activity)` with no delegate effect.

The wire contract. `RunJob` (shikigami-api/src/Shikigami/Api/RunJob.hs:19-28) carries
`agentName, triggerKind, occurredAt, triggerPayload, idempotencyKey, parentSessionId,
parentRunWorkflowId, delegationDepth`. `openSession` (Workflow.hs:248-275) reads
`parentSessionId`/`delegationDepth` to record session lineage in kioku. `RunJob` is
client-safe (no hasql/effectful deps), so adding fields is a pure additive change consumed by
both the enqueuer and the worker.

keiro child API signatures (Keiro/Workflow/Child.hs): `spawnChild :: WorkflowName ->
WorkflowId -> Eff es a -> Eff es (ChildHandle a)`; `awaitChild :: ChildHandle a -> Eff es a`
(suspends); `cancelChild :: ChildHandle a -> Eff es Bool` (flips the child row to cancelled,
returns whether it was found). `WorkflowChildFailed`/`WorkflowChildCancelled` are the
exceptions `awaitChild` can raise, which `awaitDelegated` catches and remaps
(Delegate.hs:90-95).

"Cycle": a delegation graph edge from an agent back to one of its own ancestors (A delegates
to B which delegates back to A). "Budget": a maximum count of descendant runs one root run may
spawn. "Allow-list": the set of agent names a given agent is permitted to delegate to.


## Plan of Work

### Milestone 1 — The declaration surface and the shared step-name constant

Scope: an agent can declare its delegates and budget, and the brittle "ingest-job" string is
centralized. In schema/Agent.dhall extend the `Agent` record (following plan 33's pattern):
add `delegates : List Text` (default `[] : List Text`) and `delegationBudget : Optional
Natural` (default `None Natural`) to `Type` and `default`. Mirror on `AgentDecl`
(shikigami-api/src/Shikigami/Api/Agent.hs) with strict direct fields:
`delegates :: ![Text]`, `delegationBudget :: !(Maybe DelegationBudget)`. Add a total smart
constructor that accepts only `0..1000`; surface an actionable validation error for larger
Dhalls rather than converting an arbitrary `Natural` to `Int`. The Settei platform default
uses the same bounded type.

Add `ingestJobStepName :: StepName` to shikigami-core/src/Shikigami/Agent/Workflow/Name.hs
(value `StepName "ingest-job"` — byte-identical to today) and use it at both the workflow read
site (Workflow.hs, the `StepName "ingest-job"` in `agentRunWorkflow`) and the pre-journal
write site (Delegate.hs:66-70, replacing the literal). This is a code-only refactor; the wire
value is unchanged (MasterPlan IP-3).

Add a supervisor proof manifest `agents/proof/supervisor.dhall`:

```dhall
let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "research-supervisor"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "research-supervisor"
          , preferEnrichment = False
          , grounding = None Text
          , enabledBy = None Text
          }
    , trigger = A.Trigger.Event { eventType = "proof.delegate" }
    , delegates = [ "web-researcher", "code-researcher" ]
    , delegationBudget = Some 8
    }
```

Acceptance: `cabal run shikigami -- validate agents/proof/supervisor.dhall` decodes the two
new fields; `cabal run shikigami -- validate agents/heartbeat.dhall` is unchanged (defaults).

### Milestone 2 — Lineage, durable global budget, cycle and budget rejection

Scope: `RunJob` carries the ancestor chain and the identity of one root budget, and
`delegate` enforces both. Add to `RunJob` (shikigami-api/src/Shikigami/Api/RunJob.hs)
`lineage :: ![Text]` (root-to-current agent names; additive, old jobs decode as `[]`) and
`delegationBudgetId :: !(Maybe DelegationBudgetId)` (old/root jobs decode as `Nothing`). At
root workflow start, deterministically derive a budget id from the root workflow id, insert
the ledger with the agent or platform maximum using an idempotent insert, and carry that id
on every descendant `RunJob`.

Plan 38 adds schema-qualified tables for the ledger and its idempotent reservations. Use
strict direct Haskell fields such as `budgetId`, `rootWorkflowId`, `maximum`, `consumed`, and
`childWorkflowId`. The reservation operation locks/updates the ledger and records the child
workflow id in the same transaction that registers and pre-journals the child. A conflict on
an existing reservation is replay success; a new reservation at `consumed == maximum` is a
typed exhaustion result. Add transaction/concurrency tests at the store boundary.

Extend `DelegateCtx` (Delegate/Context.hs) with `lineage :: ![Text]` and
`delegationBudgetId :: !DelegationBudgetId`, and extend `checkDepth` (or add a sibling
`checkDelegation`) to also:

```haskell
data DelegationError
  = DelegationDepthExceeded !Int
  | DelegationMissingSessionId
  | DelegationCycleDetected !Text        -- target already an ancestor
  | DelegationBudgetExhausted            -- durable root ledger has no unreserved slot
  | DelegationNotAllowed !Text           -- target not in the delegating agent's `delegates`
  | ...existing child-outcome constructors...
```

In `delegate` (Delegate.hs:38-46), before spawning, reject when `childAgent \`elem\`
lineage ctx` (`DelegationCycleDetected`), compute the deterministic child workflow id, then
attempt the atomic reservation/child-registration transaction. Map an exhausted ledger to
`DelegationBudgetExhausted`. The allow-list check needs the *delegating* agent's declaration
— pass it in (see M3/M5; `delegate` gains an `AgentDecl` or a pre-checked allow-list
argument). Keep the depth check as an independent outer guard.

Acceptance: `withShikigamiMigratedDatabase` tests prove: (a) delegating to an agent already
in the lineage yields `DelegationCycleDetected`; (b) concurrent siblings and grandchildren
share one maximum and exactly that many distinct children can reserve slots; (c) replaying
the same deterministic child after a process restart does not consume again; (d) the next
distinct child yields `DelegationBudgetExhausted`; and (e) the existing depth test passes.

### Milestone 3 — The Flow delegate capability

Scope: Flow behaviors can delegate, governed by the allow-list. Add a `Delegate` effect in a
new module shikigami-core/src/Shikigami/Flow/Delegate.hs (mirroring the `Memory`/`Sink`
capabilities in Flow/Capability.hs):

```haskell
data Delegate :: Effect where
  Delegate    :: Text -> Value -> Delegate m (Delegated Value)
  AwaitOne    :: Delegated Value -> Delegate m Value            -- throws on failure (fail-fast)
  AwaitAll    :: [Delegated Value] -> Delegate m [Either Text Value]  -- collect partials
```

with `delegate'`/`awaitOne'`/`awaitAll'` wrappers, and a `runDelegate :: DelegateEnv -> Eff
(Delegate : es) a -> Eff es a` interpreter that (a) checks each target against the delegating
agent's `delegates` list (`assertMayDelegate`, refusing with a Flow-visible error), (b)
enforces cycle/budget via M2's guards, and (c) dispatches to `Shikigami.Agent.Delegate`.
`DelegateEnv` carries the delegating `AgentDecl`, the `DelegateCtx` (built from the run's
session, lineage, and durable budget id). Add `Delegate` to `FlowEffects`
(shikigami-core/src/Shikigami/Flow.hs:28) and provide `runDelegate` in the Flow runner
(`runFlowBehavior`, Workflow.hs:299-322) alongside `runActivity`/`runMemory`/`runSink`.

Acceptance: a small test flow that delegates to an allow-listed child returns its output; the
same flow delegating to a non-listed name fails with `DelegationNotAllowed`. (A fixture flow
can be added to the flow registry for the test, or the capability interpreter unit-tested with
a stubbed `Shikigami.Agent.Delegate`.)

### Milestone 4 — Partial collection and sibling cancellation

Scope: a supervisor can collect per-child results and cancel siblings on failure. In
Shikigami.Agent.Delegate add:

```haskell
awaitAllDelegated :: (Workflow :> es, Store :> es, IOE :> es, FromJSON a) => [Delegated a] -> Eff es [Either Text a]
cancelSiblingsOnFailure :: (Workflow :> es, Store :> es, IOE :> es, FromJSON a) => [Delegated a] -> Eff es [Either Text a]
```

`awaitAllDelegated` maps `awaitDelegated`-with-`try` over the handles, converting a
`DelegationError`/child failure into `Left <reason>` and a success into `Right a`, returning
all of them (never throwing). `cancelSiblingsOnFailure` awaits in order; on the first `Left`,
it calls keiro `cancelChild` on every not-yet-awaited sibling handle and returns the collected
list (successes plus the failure plus `Left "cancelled"` for the cancelled siblings). Expose
`cancelChild` on `Delegated` by storing the `ChildHandle` (already the case:
`Delegated a = Delegated (ChildHandle (Either Text AgentRunResult))`, Delegate.hs:29) — add a
`cancelDelegated :: Delegated a -> Eff es Bool` wrapping `cancelChild`.

Acceptance: a `withShikigamiMigratedDatabase` test spawns two children where one child agent
is wired to fail; `cancelSiblingsOnFailure` returns one `Right` (or `Left`) and the other as
cancelled, and the cancelled child's workflow row is `cancelled` (asserted via keiro's child
row lookup). `awaitAllDelegated` on the same set returns both results without throwing.

### Milestone 5 — Retire the special case

Scope: the general mechanism subsumes the demo. Rewrite `runResearchSupervisor`
(Workflow.hs:344-372) to read its child agent names from the supervisor decl's `delegates`
list, build the `DelegateCtx` with `lineage`/`delegationBudgetId` from the `RunJob`, delegate to each
(through the allow-list guard), and collect via `awaitAllDelegated`, synthesizing the same
output shape. Delete the `task == researchSupervisorTaskName` guard in `runBehaviorStep`
(Workflow.hs:287-288); route supervisor behavior through a general "supervisor program" arm
that is chosen by the presence of a non-empty `delegates` list (or keep a named
`research-supervisor` task in the registry that now uses the general path — either way, no
hardcoded task-name branch remains in `runBehaviorStep`). Keep the web/code stub tasks in the
registry as allow-listed fixtures.

Acceptance: the existing AgentWorkflowSpec delegation tests pass with the special case
removed; `grep researchSupervisorTaskName shikigami-core/src` shows no remaining special-case
branch in `runBehaviorStep`.


## Concrete Steps

All commands from the repo root inside `nix develop`; DB tests need `just create-database`.

Step 1 — baseline:

```bash
cabal build all
cabal test shikigami-core
```

Step 2 — after M1:

```bash
cabal run shikigami -- validate agents/proof/supervisor.dhall
cabal run shikigami -- validate agents/heartbeat.dhall
```

Expected: the supervisor record prints with `delegates = ["web-researcher","code-researcher"]`
and `delegationBudget = Just 8`; heartbeat prints unchanged (defaults `delegates = []`,
`delegationBudget = Nothing`).

Step 3 — after each of M2-M5, run the delegation tests:

```bash
cabal test shikigami-core --test-options='--pattern Delegat'
```

Expected: allow-list, cycle, budget, and partial-collection/cancel cases pass, plus the
pre-existing depth and supervisor cases.

Step 4 — confirm the special case is gone and the suite is green:

```bash
grep -n researchSupervisorTaskName shikigami-core/src/Shikigami/Agent/Workflow.hs
cabal test all
```

Expected: no `task == researchSupervisorTaskName` guard remains in `runBehaviorStep`
(the name may still exist as a registry task name); full suite green.


## Validation and Acceptance

Acceptance is behavioral, contrasted against today:

1. Declared delegation: a `research-supervisor` with `delegates = ["web-researcher",
   "code-researcher"]` delegates to exactly those, synthesizes their outputs, and completes.
   Before: only the hardcoded task name could delegate.
2. Allow-list refusal: the same supervisor attempting to delegate to `"intruder"` (not in its
   list) is refused with `DelegationNotAllowed "intruder"`; the run does not spawn that child.
   Before: no allow-list existed.
3. Cycle refusal: an agent whose `lineage` already contains the target is refused with
   `DelegationCycleDetected`; A→B→A cannot form. Before: only depth-4 bounded it, so A→B→A→B
   was allowed.
4. Global budget refusal: with `delegationBudget = Some 3`, concurrently attempt children
   from multiple sibling branches. Exactly three distinct child workflow ids reserve and
   spawn across the whole root tree; all later distinct attempts receive
   `DelegationBudgetExhausted`. Replaying any reserved child, including after reconstructing
   the workflow runtime, succeeds without incrementing `consumed`. Before: no budget existed.
5. Partial collection + cancellation: `awaitAllDelegated` returns per-child `Either` without
   throwing; `cancelSiblingsOnFailure` cancels not-yet-completed siblings on the first failure
   (the cancelled child's workflow row is `cancelled`). Before: `awaitDelegated` threw on any
   child failure and the supervisor awaited sequentially with no cancellation.
6. Flow delegation: a Flow behavior delegates through the `Delegate` capability, governed by
   the same allow-list/cycle/budget guards. Before: `FlowEffects` had no delegate effect.

Exact commands: `cabal test shikigami-core --test-options='--pattern Delegat'` for the
targeted cases and `cabal test all` for the full regression; every workflow-level case runs
under `Shikigami.Migrations.TestSupport.withShikigamiMigratedDatabase` (real Postgres, via
`just create-database`).


## Idempotence and Recovery

Delegation child identity is already replay-safe: child workflow ids are deterministic UUIDv5s
(`delegatedWorkflowId`, Delegate.hs:97-107), so a parent replay recomputes the same child id
and `spawnChild` is idempotent on it; the pre-journaled child "ingest-job" step dedupes on
replay. The durable reservation uses that same child id as its uniqueness key, so replays do
not spend another slot. Ledger creation is idempotent by deterministic root id; the
reservation and child registration/pre-journal commit together. The new fields are additive:
`RunJob.lineage`/`delegationBudgetId` decode as `[]`/`Nothing` for jobs enqueued before this
plan; a resumed root with `Nothing` initializes or finds the deterministic ledger before it
can delegate. Schema fields default to `[]`/`None`, so manifests need no edits. Plan 38's
forward migration creates the ledger and reservation tables; rollback leaves them inert.
`cancelChild` returns `Bool`
(found or not) and is safe to call on an already-completed or already-cancelled child (it is a
no-op), so `cancelSiblingsOnFailure` is safe under partial completion and re-runs. The
step-name centralization keeps the wire value byte-identical, so in-flight journals from before
the refactor replay unchanged (MasterPlan IP-3). Rollback: reverting M5 restores the special
case; the additive fields can stay (unread fields are inert); reverting M2-M4 restores
throw-on-failure `awaitDelegated` with the depth-only guard.


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 24, 33, 36-39, and 47. It must use Keiro 0.4 checked
workflow/state declarations, plan 38's pg-migrate ledger, and plan 47's replay/queue compatibility
fixtures. Router execution in plan 42 extends this mechanism rather than defining another
budget/lineage path.


## Portfolio Reconciliation (2026-08-05)

The run-job lineage fields this plan makes declarative are now **read by an audit path that must not
lose a child**. `docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md` uses
`parentSessionId`, `parentRunWorkflowId`, and `delegationDepth` on `RunJob`
(`shikigami-core/src/Shikigami/Agent/RunJob.hs`), together with the `TriggeredByDelegation` trigger
kind, to find a run's children — and a parent's evidence cannot seal while any relevant child is
non-terminal. A delegated child that becomes invisible to that traversal makes the attestation
*incomplete*, which the consuming gate rejects, so it is a correctness failure rather than a missing
nicety.

Preserve those three fields and that trigger kind when formalising delegation, or, if the declarative
form supersedes them, update plan 51's traversal in the same change rather than leaving it reading
fields that no longer carry the whole truth. Also note that the closure must include tool-mediated
and retried calls made *inside* a child, not only the child's root call.


## Interfaces and Dependencies

Owned and defined by this plan:

- `schema/Agent.dhall` — `delegates : List Text` (default `[]`), `delegationBudget : Optional
  Natural` (default `None`) on `Agent`.
- `Shikigami.Api.Agent` — `DelegationBudget` is a bounded 0–1000 domain value;
  `AgentDecl` gains `delegates :: ![Text]`, `delegationBudget :: !(Maybe DelegationBudget)`.
- `Shikigami.Api.RunJob` — `RunJob` gains `lineage :: ![Text]`,
  `delegationBudgetId :: !(Maybe DelegationBudgetId)`.
- `Shikigami.Agent.Workflow.Name` — `ingestJobStepName :: StepName` (value `"ingest-job"`).
- `Shikigami.Agent.Delegate.Context` — `DelegateCtx` gains `lineage`,
  `delegationBudgetId`;
  `DelegationError` gains `DelegationCycleDetected`, `DelegationBudgetExhausted`,
  `DelegationNotAllowed`; `assertMayDelegate :: AgentDecl -> Text -> Either DelegationError ()`.
- `Shikigami.Agent.Delegate` — cycle/budget/allow-list enforcement in `delegate`;
  `awaitAllDelegated :: [Delegated a] -> Eff es [Either Text a]`;
  `cancelSiblingsOnFailure :: [Delegated a] -> Eff es [Either Text a]`;
  `cancelDelegated :: Delegated a -> Eff es Bool`.
- `Shikigami.Flow.Delegate` (new) — the `Delegate` effect and `runDelegate` interpreter;
  `Shikigami.Flow.FlowEffects` gains `Delegate :> es`.
- `Shikigami.Agent.Workflow` — `runResearchSupervisor` rewritten on the general mechanism; the
  `task == researchSupervisorTaskName` special case in `runBehaviorStep` removed; `runDelegate`
  wired into `runFlowBehavior`.
- `Shikigami.Store.DelegationBudget` (name may follow plan 36's exact package layout) —
  deterministic ledger initialization and atomic
  `reserveDelegationSlot :: DelegationBudgetId -> WorkflowId -> ... -> ReservationResult`.
- Plan 38 migration — schema-qualified delegation-budget and reservation tables, unique
  child-workflow reservation key, maximum/consumed checks, and indexes used by the atomic
  reservation statement.

Consumed (no changes):

- keiro `Keiro.Workflow.Child` — `spawnChild`, `awaitChild`,
  `cancelChild :: ChildHandle a -> Eff es Bool` (locate via
  `mori registry show keiro --full`; source
  /Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Workflow/Child.hs:272).

Cross-plan dependencies:

- HARD depends on docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md
  (MasterPlan EP-2): the `delegates`/`delegationBudget` fields must follow plan 33's additive
  field-with-default pattern in the same `Agent` record (MasterPlan IP-1). Do not add these
  fields before plan 33's pattern is merged.
- HARD depends on docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md
  (MasterPlan 5, IP-3). This plan changes the durable agent-run workflow and consumes
  plan 24's versioning discipline, active-patch plumbing, and step-name inventory. Existing
  step names remain byte-identical, and any new steps or guarded behavior are recorded in
  that inventory.
- HARD depends on docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md
  for package ownership and direct strict record-field conventions.
- HARD depends on docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md for
  the validated default `DelegationBudget`; no workflow module reads environment variables.
- HARD depends on docs/plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md
  for the durable ledger/reservation migration and test database manifest.
- HARD depends on docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md;
  update the checked specification and accept its compatibility diff before runtime changes.

Build/test toolchain: Nix dev shell; `cabal build all`; `cabal test all`;
`cabal run shikigami -- validate <file>`; `just create-database` +
`withShikigamiMigratedDatabase` for the delegation workflow tests.


## Revision Notes

- 2026-08-22: Refreshed the plan against the seven-package tree and the released Keiro 0.14.0.0
  source. Corrected module ownership to `shikigami-core`, assigned the new SQL to this plan on top
  of plan 38's delivered migration component, replaced ordinal child identity with a stable key,
  and changed the impossible cross-library transaction into reserve-first replay convergence.

- 2026-08-05: Added a Portfolio Reconciliation note recording that the run-job lineage fields
  (`parentSessionId`, `parentRunWorkflowId`, `delegationDepth`, `TriggeredByDelegation`) are now read by
  MasterPlan 10's complete-call-accounting closure, where a delegated child that becomes invisible makes
  an attestation incomplete. Preserve them, or update plan 51's traversal in the same change. No
  milestone scope changed.

- 2026-07-22: Promoted plan 24 from a soft coordination note to a hard dependency.
  Delegation now begins only after the workflow-versioning discipline and patch plumbing
  exist, matching the MP-2 through MP-7 execution order.
- 2026-07-22: Replaced per-child remaining-budget propagation with a durable, atomic,
  replay-idempotent root budget. Added bounded numeric validation, pg-migrate ownership,
  Settei defaults, package boundaries, and the checked Keiro DSL evolution gate.


## Reconciliation with the delivered plan 39 (2026-08-19)

`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md` has landed, and
three of its assumptions turned out to be wrong. Anything this plan says that contradicts the
following is superseded.

**The specification is a workspace, not one file.** The service input is
`domain/shikigami.keiro-workspace`, a manifest naming `service shikigami`,
`runtime-package shikigami-core`, and `layout collocated`, plus two members —
`domain/shikigami-agent-run.keiro` and `domain/shikigami-conversation.keiro`. Every file-taking
`keiro-dsl` command takes the manifest and validates the composed service. Every reference to
`domain/shikigami.keiro` in this plan has been repointed; a startability check that looks for the
old path would fail against a repository where plan 39 *is* done.

The manifest declares **no `module` clause**: `context shikigami` already supplies the
`Shikigami` prefix, and adding `module Shikigami` scaffolds `Shikigami.Shikigami.*`. Do not add
one, and do not pass `--module-root` or `--collocate`.

**Shikigami has no aggregate, no read model, no projection, no router, and no process manager.**
Plan 39's Milestone 1 census, with evidence in
`docs/architecture/shikigami-domain-inventory.md`, found that the only Keiro command runner in the
repository targets *kioku's* session stream, and that
`Shikigami.Flow.Lifecycle.AtRiskCustomer` is a Keiki transducer that renders a Mermaid diagram
rather than an event source. The declared surface today is exactly two durable workflows and
their `run` operations.

**Three surfaces are deliberately undeclared, and the reason is binding on this plan too:** do not
certify a schema that differs from the codec actually executed. The `shikigami_run_jobs` queue
keeps its bare `RunJob` payload rather than acquiring Keiro's `{v,t,data}` envelope; the Kafka
inbox and the Danwa contract stay hand-written because a generated contract codec writes a
discriminator into a body that has none; and the sink outbox stays hand-written because its
publisher calls HTTP sinks rather than publishing to Kafka. Declaring any of them is a wire change
that needs its own commit, its own decision, and its own fixture.

**The gate is `just keiro-gate`.** It runs `keiro-check` (with `--min-language 5`,
`--deny-warnings`, and `--fail-on-opaque`), `keiro-inspect` (asserting every member declares its
language at effective version 5), `keiro-scaffold` (regenerate, then `git diff --exit-code`),
`keiro-diff <ref>` (the six-surface evolution classification), and `cabal test
keiro-shikigami-conformance`. Run it before merging any change to `domain/`, to the generated
layer under `shikigami-core/src/Shikigami/*/Generated/`, or to a durable identity. A `BREAKING`
finding exits non-zero and is a deployment gate, not an advisory.

**A workflow label is a wire word.** keiro-dsl parses a `step`, `await`, `sleep`, or `child` label
with `[A-Za-z0-9][A-Za-z0-9_-]*`. A label containing a colon or a value computed at run time
cannot be declared at all. Shikigami's `approval:<SinkKind>:<ordinal>`, `<label>:notify`,
`emit-signal:<ordinal>`, and every per-message conversation label are therefore outside the
specification until the plan that owns them makes them static.

### What changes for this plan

Delegation is already partly declared. `domain/shikigami-agent-run.keiro` carries
`child delegate id input via delegatedWorkflowId -> AgentRunResult`, which records that
`shikigami.agent-run` spawns children of itself, and the generated conformance target asserts
`"child:delegate"` in `AgentRun.body`. The `via` name is descriptive: the real derivation
(`Shikigami/Agent/Delegate.hs:96-105`) is a UUIDv5 over
`["shikigami", "delegate", parentWorkflowId, childAgent, ordinal]` and takes the parent workflow
id, not the workflow input, which is what keiro-dsl's `child ... id input via ...` spelling
implies. Making the declaration and the derivation agree is this plan's, not plan 39's.

The `RunJob` contract evolution this plan touches is **not** declared. `shikigami_run_jobs` keeps
its bare payload deliberately, so adding a delegation field to
`Shikigami.Agent.RunJob.RunJob` is not gated by `keiro-dsl diff` today — it is gated only by
`shikigami-core/test/Shikigami/WireCompatSpec.hs`. If this plan wants the mechanical gate, it must
first move the queue onto the declared `workqueue` surface, which is the codec change described
above.
