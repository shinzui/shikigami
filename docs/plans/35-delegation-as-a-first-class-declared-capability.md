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
exhausted. A supervisor can collect per-child results as `Either` values and cancel its
siblings when one fails. The hardcoded research-supervisor special case is gone, re-expressed
on the general mechanism. The observable proof is a set of real-Postgres workflow tests: a
declared supervisor delegates to allow-listed children and synthesizes their outputs; an
undeclared target is refused; a cycle is refused; an over-budget delegation is refused; and a
failing child triggers sibling cancellation with a collected partial result.

This plan hard-depends on
docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md: it adds the
`delegates`/`delegationBudget` fields to the same `Agent` record and must follow the additive
field-with-default pattern that plan 33 establishes (MasterPlan
docs/masterplans/7-platform-feature-completion-egress-schema-memory-lifecycle-delegation.md,
IP-1).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: add `delegates : List Text` and `delegationBudget : Optional Natural` to schema/Agent.dhall (defaults `[]` / `None`) and mirror on `AgentDecl`; a `noopSummary`-behavior supervisor manifest validates.
- [ ] M1: introduce the shared `ingestJobStepName` constant and use it in both Workflow.hs and Delegate.hs (retire the two independent `"ingest-job"` literals).
- [ ] M2: add `lineage : [Text]` and `childBudgetRemaining : Maybe Int` to `RunJob`; propagate and decrement across `delegate`.
- [ ] M2: ancestor-cycle rejection (reject a target already in the lineage) and budget rejection in `delegate`/`checkDepth`; new `DelegationError` constructors.
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


## Decision Log

Record every decision made while working on the plan.

- Decision: The declaration surface is `delegates : List Text` (default `[]`) — an allow-list
  of agent names this agent may delegate to — plus `delegationBudget : Optional Natural`
  (default `None` = use the platform default) — the maximum number of child runs one run may
  spawn (transitively decremented and propagated). Both follow plan 33's additive
  field-with-default pattern.
  Rationale: an allow-list is the minimal declaration that makes "may this agent delegate, and
  to whom" answerable from the manifest; a name list (not a richer capability grant) matches
  how the runtime already resolves agents by name (`find ((== agentName job) . agentDeclName)`,
  Workflow.hs:135). A budget as `Optional Natural` keeps existing manifests unchanged while
  letting an operator cap a supervisor's fan-out; `None` defers to a code default
  (`defaultDelegationBudget = 16`, generous but finite).
  Date: 2026-07-08

- Decision: Cycle detection uses an ancestor *chain* carried on `RunJob` as
  `lineage :: [Text]` (agent names from root to current), not the existing single
  `parentRunWorkflowId`. `delegate` rejects a target already in `currentLineage` with a new
  `DelegationCycleDetected` error; the child's `RunJob.lineage` is `currentLineage ++ [target]`.
  Rationale: A→B→A is a cycle even though B's immediate parent (A) differs from the *target*
  (A); only a full ancestor set catches it. Carrying names (not session ids) makes the check a
  cheap `elem` and keeps the wire payload small; the depth-4 bound stays as a second guard.
  Date: 2026-07-08

- Decision: Budget is carried as `childBudgetRemaining :: Maybe Int` on `RunJob`, decremented
  once per spawned child and propagated to the child as `remaining - 1`. A run whose remaining
  budget is `Just 0` refuses to delegate (`DelegationBudgetExhausted`). The root run seeds it
  from its own `delegationBudget` (or the default).
  Rationale: a per-run decrement-and-propagate is the standard way to bound a delegation tree
  without a shared counter (which durable replay would corrupt); `Maybe` lets an unset budget
  mean "seed from the declaration at the root", set thereafter.
  Date: 2026-07-08

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
(shikigami-api/src/Shikigami/Api/Agent.hs): `delegates :: ![Text]`, `delegationBudget ::
!(Maybe Natural)`.

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

### Milestone 2 — Lineage, budget, cycle and budget rejection

Scope: `RunJob` carries the ancestor chain and remaining budget, and `delegate` enforces both.
Add to `RunJob` (shikigami-api/src/Shikigami/Api/RunJob.hs): `lineage :: ![Text]` (root-to-current
agent names; additive — decode old jobs as `[]`) and `childBudgetRemaining :: !(Maybe Int)`.
Update every `RunJob` construction site to set them: the enqueuer(s) seed `lineage =
[agentName]` and `childBudgetRemaining = Nothing` (the root fills the budget from its decl at
run start); `delegate` (Delegate.hs) sets the child's `lineage = currentLineage ++ [childAgent]`
and `childBudgetRemaining = Just (remaining - 1)`.

Extend `DelegateCtx` (Delegate/Context.hs) with `lineage :: ![Text]` and `budgetRemaining ::
!(Maybe Int)`, and extend `checkDepth` (or add a sibling `checkDelegation`) to also:

```haskell
data DelegationError
  = DelegationDepthExceeded !Int
  | DelegationMissingSessionId
  | DelegationCycleDetected !Text        -- target already an ancestor
  | DelegationBudgetExhausted            -- remaining budget is Just 0
  | DelegationNotAllowed !Text           -- target not in the delegating agent's `delegates`
  | ...existing child-outcome constructors...
```

In `delegate` (Delegate.hs:38-46), before spawning: reject when `childAgent \`elem\` lineage
ctx` (`DelegationCycleDetected`), reject when `budgetRemaining ctx == Just 0`
(`DelegationBudgetExhausted`), then decrement. The allow-list check needs the *delegating*
agent's decl — pass it in (see M3/M5; `delegate` gains an `AgentDecl` or a pre-checked
allow-list argument, or the caller invokes a shared `assertMayDelegate` guard before
`delegate`). Keep the depth check as the outer guard.

Acceptance: `withShikigamiMigratedDatabase` tests: (a) delegating to `research-supervisor`
from a lineage containing it yields `DelegationCycleDetected`; (b) delegating with
`childBudgetRemaining = Just 0` yields `DelegationBudgetExhausted`; the existing depth test
still passes.

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
session/lineage/budget). Add `Delegate` to `FlowEffects`
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
list, build the `DelegateCtx` with `lineage`/`budget` from the `RunJob`, delegate to each
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
4. Budget refusal: with `delegationBudget = Some 1`, the first child spawns and a second
   delegation in the same run (or a grandchild past the propagated budget) is refused with
   `DelegationBudgetExhausted`. Before: no budget existed.
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

Delegation is already replay-safe: child workflow ids are deterministic UUIDv5s
(`delegatedWorkflowId`, Delegate.hs:97-107), so a parent replay recomputes the same child id
and `spawnChild` is idempotent on it; the pre-journaled child "ingest-job" step dedupes on
replay. The new fields are additive: `RunJob.lineage`/`childBudgetRemaining` decode as
`[]`/`Nothing` for jobs enqueued before this plan, and the schema fields default to
`[]`/`None`, so no migration and no manifest edits are needed. `cancelChild` returns `Bool`
(found or not) and is safe to call on an already-completed or already-cancelled child (it is a
no-op), so `cancelSiblingsOnFailure` is safe under partial completion and re-runs. The
step-name centralization keeps the wire value byte-identical, so in-flight journals from before
the refactor replay unchanged (MasterPlan IP-3). Rollback: reverting M5 restores the special
case; the additive fields can stay (unread fields are inert); reverting M2-M4 restores
throw-on-failure `awaitDelegated` with the depth-only guard.


## Interfaces and Dependencies

Owned and defined by this plan:

- `schema/Agent.dhall` — `delegates : List Text` (default `[]`), `delegationBudget : Optional
  Natural` (default `None`) on `Agent`.
- `Shikigami.Api.Agent` — `AgentDecl` gains `delegates :: ![Text]`, `delegationBudget ::
  !(Maybe Natural)`.
- `Shikigami.Api.RunJob` — `RunJob` gains `lineage :: ![Text]`, `childBudgetRemaining ::
  !(Maybe Int)`.
- `Shikigami.Agent.Workflow.Name` — `ingestJobStepName :: StepName` (value `"ingest-job"`).
- `Shikigami.Agent.Delegate.Context` — `DelegateCtx` gains `lineage`, `budgetRemaining`;
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
- Soft/cross-MP: any change to `agentRunWorkflow`'s journaled step names or order must respect
  docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md (MasterPlan 5,
  IP-3); this plan is additive-only and keeps existing step names byte-identical.

Build/test toolchain: Nix dev shell; `cabal build all`; `cabal test all`;
`cabal run shikigami -- validate <file>`; `just create-database` +
`withShikigamiMigratedDatabase` for the delegation workflow tests.
