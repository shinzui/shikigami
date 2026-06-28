---
id: 11
slug: haskell-behavior-dsl-over-keiro-with-keiki-modeled-agent-state-machines
title: "Haskell behavior DSL over keiro with keiki-modeled agent state machines"
kind: exec-plan
created_at: 2026-06-27T16:39:29Z
intention: "intention_01kw4z4f9yew2sa0aawfy93rad"
---

# Haskell behavior DSL over keiro with keiki-modeled agent state machines

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today a `shinzui/shikigami` agent's *behavior* — the work it does when its trigger fires — is
authored in one of three shapes named by a string in a Dhall file: a `Deterministic` rule, a
`ShikumiProgram` (a typed program run through `shinzui/handan`), or a `Skill` (instructions run
through `shinzui/baikai`). All three run through one synchronous seam,
`Shikigami.Behavior.Run.runBehavior :: BehaviorEnv -> AgentDecl -> Value -> IO (Either RunError Value)`
(file `shikigami-core/src/Shikigami/Behavior/Run.hs`). That seam takes one JSON payload in and
returns one JSON value out, in plain `IO`, in a single pass. It is perfect for "read this ticket,
return a verdict" and structurally incapable of anything that must **wait**: a behavior cannot
classify a ticket, raise an alert, then *pause for up to fifteen minutes* for a human to acknowledge
it and *escalate if no one does*. A synchronous `IO Value` has nowhere to put the wait.

The runtime that *can* express waiting is `shinzui/keiro`, the event-sourcing and durable-workflow
engine shikigami already depends on (it is in `shikigami-core/shikigami-core.cabal` as `keiro` and
`keiro-core`). Keiro is an `effectful`-library runtime: its capabilities are `Eff es` computations
(durable workflows that journal each step and can suspend/resume, sagas, timers, child workflows).
**None of that is reachable from Dhall** — Dhall can name a thing and pass scalars; it cannot compose
effects. So the only way to give an agent author access to keiro's power is to let them write Haskell.

This plan introduces a small, hand-written **behavior DSL** — a thin Haskell capability layer — so a
complex agent behavior can be authored as a *durable keiro workflow* with safe, named combinators
(`recall`, `remember`, `emitSignal`, `awaitAcknowledgement`) instead of raw keiro plumbing. It adds a
fourth arm to the behavior union, `Flow { name : Text }`, that — exactly like `ShikumiProgram { task }`
names an entry in the in-Haskell program registry — names an entry in a new in-Haskell **flow
registry**. The Dhall file stays the declaration (identity, trigger, sinks); the complex part is
compiled-in Haskell, resolved by name.

Separately, this plan adopts `shinzui/keiki` — the typed symbolic-state-machine library keiro is built
on — to give each complex agent a **theoretically-backed lifecycle**: the agent's states and
transitions are written as a keiki `SymTransducer`, which keiki can (a) *validate* for well-formedness
(no hidden inputs, no nondeterministic transitions, no dead edges) and (b) *render to a Mermaid state
diagram*. The agent's lifecycle stops being implicit control flow buried in a function and becomes a
checked, drawable artifact.

After this change, someone with a fresh checkout in the nix dev shell can:

- Run a CLI command and get a **Mermaid state diagram** of an agent's lifecycle printed to stdout
  (and written into a Markdown doc), generated directly from the agent's keiki state machine — and run
  a test that **fails if that state machine is ill-formed** (a guard reads a field the events do not
  carry, two transitions overlap, or a state is unreachable).

- Declare an agent in Dhall whose `behavior` is `Flow { name = "at-risk-customer" }`, start the worker,
  feed it a high-risk support-ticket activity, and watch the agent **classify the ticket, raise a
  kizashi Alert, then park** — durably suspend, freeing the worker — waiting for an acknowledgement.

- Drive the two outcomes and see them differ: send an acknowledgement event within the window and the
  run **resumes, records that it was acknowledged, and completes**; send nothing and after the deadline
  the run **resumes on a timeout, raises an escalation signal, and completes**. Kill the worker while
  the run is parked and restart it — the run does not re-classify the ticket; it resumes from its
  journal exactly where it parked.

This is the proof slice. It reimplements the existing `agents/detectors/at-risk-customer.dhall`
detector — whose own documentation already specifies "high-risk verdict → Alert, shared inbox,
**escalate after timeout**" — as a durable flow, demonstrating the one capability the synchronous
`runBehavior` seam can never have.

This plan **depends on** and layers on top of `docs/plans/7-agent-runs-as-durable-keiro-workflows.md`
("Agent runs as durable keiro workflows"), the keystone that re-platforms a shikigami run onto a keiro
`Workflow` named `agentRunWorkflowName = WorkflowName "shikigami.agent-run"` (run with `WorkflowId` =
`RunJob.idempotencyKey`) and adds the `awaitApproval` suspend/resume combinator with its
`ApprovalRequest`/`ApprovalDecision`/`ApprovalEnv` types and the `resolveApproval` resume seam. Plan 11
does not re-build the durable-workflow substrate; it builds the *authoring surface* (the DSL, the
registry, the keiki lifecycle) on top of it. Two precise dependencies, established during the
cross-plan coherence review on 2026-06-27:

- A `Flow` behavior is **inlined into plan 7's `agentRunWorkflow`**, replacing the single opaque
  `step (StepName "run-behavior") …` that plan 7 uses for the other three arms. The flow's own `step`s
  and its `awaitAcknowledgement` therefore join the *same* journal and `WorkflowId` as the rest of the
  run, and are resumed by plan 7's existing `runWorkflowResumeWorker` (registered via plan 7's
  `agentRunRegistry`). This plan introduces **no new keiro workflow and no new keiro `WorkflowRegistry`**;
  its `flowRegistry`/`lookupFlow` is a shikigami-level lookup of which `Eff` body to splice in for a
  `Flow { name }` arm — not a keiro registry.
- `awaitAcknowledgement` is a thin wrapper over plan 7's `awaitApproval`, and its *deadline* (the
  "escalate after timeout") needs plan 7 **Milestone 4** specifically — the milestone that arms a keiro
  timer for the `awaitApproval` deadline and signals a `TimedOut` decision when it fires. Plan 11's M4
  therefore requires plan 7 M4, not merely plan 7 M2/M3.

Plan 11 is a sibling of plans 8 (danwa conversational loop), 9 (delegation), and 10
(timers/resume/tracing), which also build on plan 7. Plan 8 likewise needs to "open up" the opaque
`run-behavior` step (it routes to a separate long-lived conversation workflow keyed by
`conversationId`); plan 11's single-run flow instead inlines into the one agent-run workflow because a
flow suspends within a single run rather than across many.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **M1 (spike) — keiki agent lifecycle as a verified, drawable state machine.** Completed
      2026-06-28. Added `Shikigami.Flow.Lifecycle.AtRiskCustomer` with a keiki `SymTransducer`,
      Mermaid rendering, and validation warnings; added `Shikigami.FlowLifecycleSpec`; verified with
      `nix develop -c cabal build shikigami-core` and `nix develop -c cabal test shikigami-core` (all
      36 tests passed). This delivered the at-risk-customer lifecycle as a keiki `SymTransducer`,
      rendered it to Mermaid with `Keiki.Render.Mermaid.toMermaidWith`, and asserted well-formedness
      with keiki's validator. No database or keiro runtime is involved; it is pure functions plus a
      `tasty` test, which de-risks the keiki adoption.
- [ ] **M2 (spike) — the behavior DSL skeleton: a `Flow` effect row and a flow registry.** Define the
      capability constraints a flow runs under, a `FlowDef` registry mirroring
      `Shikigami.Program.Registry`, and run a trivial durable flow through keiro's `runWorkflow` in an
      isolated harness (independent of the worker). Confirms the effect stack assembles and a flow can
      `step`/suspend.
- [ ] **M3 — the capability combinators.** Implement `recall`, `remember`, `emitSignal`,
      `currentActivity`, and `awaitAcknowledgement` (the last wrapping plan 7's `awaitApproval`) as thin
      smart constructors over keiro + shikigami effects.
- [ ] **M4 — the at-risk-customer vertical slice.** Compose the combinators into `atRiskCustomerFlow`,
      register it, and prove both branches (acknowledged-in-time and timed-out-then-escalated) plus
      crash-resume against a live Postgres.
- [ ] **M5 — wiring and docs.** Add the `Flow { name : Text }` arm to `schema/Agent.dhall` and
      `Shikigami.Api.Agent`; route it through the loader and worker; add a `render-lifecycle` CLI
      subcommand; write `docs/user/flows.md`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The real keiro app uses keiro raw — no thick framework wrapper.** Reading the worked-example app
  `shinzui/keiro-runtime-jitsurei` (`services/hospital-capacity` and `services/incident-command`) shows
  durable workflows written as plain `Eff es` functions calling `step`/`awakeableNamed` directly under
  explicit `(Workflow :> es, Store :> es, IOE :> es)` constraints, aggregates as hand-written
  `EventStream` records, and the *only* abstraction layer being smart constructors that inject telemetry
  into options records (e.g. `HospitalCapacity/Store.hs` `workflowOptionsWithTelemetry`). Evidence shaped
  this plan's "thin capability layer, not a newtype monad" decision: we expose keiro's effects directly
  and only add shikigami's own capabilities (`Memory`, `Sink`, `Activity`) plus a handful of named
  combinators.
- **keiki already gives the lifecycle diagram + verification for free.** `Keiki.Render.Mermaid` exposes
  `toMermaidWith :: MermaidOptions -> SymTransducer ... -> Text` and `defaultMermaidOptions`; keiki's
  validator reports `HiddenInput` / `NondeterministicPair` / `PossiblyDeadEdge` per offending edge. The
  jitsurei app's `services/hospital-capacity/src/HospitalCapacity/Domain/Diagrams.hs` is a complete
  worked precedent (`toMermaidWith annotatedMermaidOptions reservationTransducer`, plus a
  `writeKeikiDiagrams` that splices the diagrams into Markdown via `Keiki.Render.Markdown`). So "model the
  agent as a verified state machine that renders to a diagram" is adoption, not invention.
- **The escalate-after-timeout shape is a blessed keiro cookbook.** `keiro-runtime-docs`'
  `cookbook/timeout-saga.mdx` and the incident-command escalation process manager
  (`05-escalation-process-manager-and-timers.mdx`) document the canonical "schedule a deterministic-id
  timer in the append transaction, fire a *total* compensating command on deadline" pattern. Plan 7's
  `awaitApproval` (suspend + arm a deadline timer + resume on answer-or-timeout) is the in-workflow
  expression of the same idea, which is why this plan reuses it rather than standing up a process manager.
- **Validation must run inside the nix development shell on this machine.** A plain
  `cabal build shikigami-core` compiled the new lifecycle module but failed at link time because the
  ambient shell could not find `librdkafka`; the same build through `nix develop` succeeded. Evidence:

```text
ld: library not found for -lrdkafka
clang: error: linker command failed with exit code 1
```


## Decision Log

Record every decision made while working on the plan.

- Decision: Build the complex-behavior authoring layer as a **new plan (11) layered on plan 7**, not by
  folding it into plan 7 and not as a standalone plan that ignores plan 7.
  Rationale: Plan 7 is the durable-workflow *substrate* keystone that plans 8/9/10 all depend on landing;
  keeping it lean protects those dependents. The DSL/keiki/diagram work is a distinct *authoring surface*
  concern that sits cleanly on top, the same way 8/9/10 layer thin capabilities on 7. Chosen by the user
  on 2026-06-27.
  Date: 2026-06-27

- Decision: The DSL is a **thin capability layer of constrained `Eff es` functions and smart
  constructors**, not a new `AgentM` newtype monad that hides keiro.
  Rationale: The production keiro app (`keiro-runtime-jitsurei`) uses keiro's effects directly with
  explicit constraints and adds only light smart constructors; a bespoke monad would obscure keiro's own
  combinators (`step`, `awakeableNamed`, `spawnChild`) that plans 8/9 also rely on, and would fight the
  ecosystem. We expose keiro effects plus shikigami's `Memory`/`Sink`/`Activity` effects and a few named
  helpers.
  Date: 2026-06-27

- Decision: Agent lifecycles are **hand-written keiki transducers**, not code-generated from a spec.
  Rationale: The user judged hand-written significantly better and the kotei `keiro-dsl` codegen approach
  a poor fit; jitsurei confirms hand-written transducers (via keiki's `Builder`) are the idiomatic,
  ergonomic path and compose with keiki's validator and Mermaid renderer without a generator.
  Date: 2026-06-27

- Decision: Complex flows are **named from Dhall and resolved in an in-Haskell registry** (`Flow { name }`
  → `lookupFlow`), exactly mirroring the existing `ShikumiProgram { task }` → `Shikigami.Program.Registry.lookupTask`.
  Rationale: This is the seam that already exists in the codebase for "declarative file names typed Haskell
  artifact." It keeps simple agents fully declarative and serializable while complex agents are compiled-in
  code; it requires no new architecture, only a second registry.
  Date: 2026-06-27

- Decision: For the proof slice, the keiki transducer is the agent's **verified lifecycle specification
  and diagram source**, and its vertex/event names are reused as the workflow's journaled `StepName`s; it
  is **not** (yet) promoted to a runtime keiro `EventStream` aggregate.
  Rationale: The user's stated goals are theoretical backing + Mermaid generation, both satisfied by the
  transducer-as-spec. Making the agent's own state event-sourced (queryable durable aggregate state) is a
  larger, separable capability; we record it as a follow-on rather than entangle the proof slice with it.
  Date: 2026-06-27

- Decision (coherence review, 2026-06-27, audit item **C3** = Option 3): A flow's sinks (`emitSignal`)
  are dispatched via plan 7's **transactional outbox** — the `Sink` interpreter runs the permission gate
  then `enqueueOutboxTx`s into `kiroku.keiro_outbox` in the journal transaction (deterministic
  `message_id`), and plan 7's outbox publisher delivers asynchronously. M4 asserts on outbox rows and
  delivery, not synchronous POSTs.
  Rationale: Flows emit sinks mid-run (Alert before the wait, escalation after a timeout resume), so a
  synchronous in-step POST risks at-least-once double-POST and couples the 15-minute wait to endpoint
  health, and after-`Completed` dispatch is impossible. The outbox gives durable, decoupled,
  exactly-once-enqueued delivery — the production model chosen for kikan. Decided by the user 2026-06-27.
  Date: 2026-06-27

- Decision (coherence review, 2026-06-27): A `Flow` behavior is **inlined into plan 7's
  `agentRunWorkflow`** (replacing the opaque `run-behavior` step) and shares its `WorkflowId`, journal,
  and resume worker; `flowRegistry`/`lookupFlow` is a **shikigami behavior lookup, not a keiro
  `WorkflowRegistry`**; and `awaitAcknowledgement` is aligned to plan 7's real `awaitApproval` signature
  (`ApprovalEnv -> StepName -> ApprovalRequest -> Maybe NominalDiffTime -> Eff es ApprovalDecision`),
  mapping `Approved/Rejected/TimedOut` to `Acknowledged/Declined/TimedOut`.
  Rationale: The cross-plan audit of plans 7–11 found plan 11 had drifted from plan 7's actual API — it
  implied a second registry, an over-simplified `awaitAcknowledgement` signature, and an unstated
  dependency on plan 7 Milestone 4 (the deadline timer). Pinning to plan 7's names keeps the five plans
  coherent and makes plan 11 implementable directly against plan 7's artifacts.
  Date: 2026-06-27

- Decision: `awaitAcknowledgement` is implemented as a **thin wrapper over plan 7's `awaitApproval`**
  rather than a fresh process-manager + timer.
  Rationale: Plan 7 already delivers in-workflow suspend + deadline-timer-race + resume; the timeout-saga
  process-manager pattern is the right tool when the coordinator is *outside* the run, but the agent run
  *is* the workflow here, so the in-workflow primitive is the correct and smaller expression. If plan 7 has
  not landed when M3 begins, M3 implements `awaitAcknowledgement` directly against keiro
  `awakeableNamed` + `sleepNamed` and the plan 7 keystone later subsumes it (recorded as a risk in
  Idempotence and Recovery).
  Date: 2026-06-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- 2026-06-28 — M1 is complete. The at-risk-customer lifecycle now exists as a checked keiki state
  machine in `shikigami-core/src/Shikigami/Flow/Lifecycle/AtRiskCustomer.hs`. The lifecycle uses the
  states `Observed`, `SettledLow`, `AwaitingAck`, `Acknowledged`, and `Escalated`; validates with no
  keiki warnings; and renders to Mermaid. This proves the plan's keiki adoption slice before any flow
  runtime or database wiring begins. Remaining work starts at M2: define the flow effect row and
  registry and prove a trivial durable flow can complete or suspend under keiro.


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it fully before editing.

**Shikigami** is a small Haskell runtime in which an autonomous agent is *declared*, not coded. An
agent declaration is a typed Dhall file naming a `trigger` (when to run), a `behavior` (what to do),
and `sinks` (where to send the result). The canonical schema is `schema/Agent.dhall`; the Haskell
mirror it decodes into is `shikigami-core/src/../Shikigami/Api/Agent.hs` (module `Shikigami.Api.Agent`,
record `AgentDecl { name, description, trigger, behavior, sinks }`). The repository is a Cabal
multi-package project: `shikigami-core` (library: loader, behavior runner, sinks, triggers, worker),
`shikigami-cli` (the `shikigami` executable, optparse-applicative), `shikigami-api` (shared wire types
including `Shikigami.Api.Agent`), and `shikigami-migrations`. The nix dev shell is entered with
`direnv allow` / `nix develop`; builds run with `cabal build all` from the repo root
`/Users/shinzui/Keikaku/bokuno/shikigami`.

**The behavior union today.** `Shikigami.Api.Agent.Behavior` has three arms:

```haskell
data Behavior
  = Deterministic {rule :: !Text, params :: !(Map Text Text)}
  | ShikumiProgram {task :: !Text, preferEnrichment :: !Bool, grounding :: !(Maybe Text), enabledBy :: !(Maybe Text)}
  | Skill {path :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)
```

`ShikumiProgram { task }` is the precedent this plan generalizes: the `task` string does not contain
the program; it *names* one. `Shikigami.Program.Registry` (file
`shikigami-core/src/Shikigami/Program/Registry.hs`) holds `programRegistry :: [Task]` and
`lookupTask :: Text -> Maybe Task`; the runner finds the named `Task` and runs it through a `handan`
`Runtime`. We will add a fourth arm, `Flow { name :: Text }`, and a parallel
`Shikigami.Flow.Registry` with `flowRegistry :: [FlowDef]` and `lookupFlow :: Text -> Maybe FlowDef`.

**The behavior seam today is synchronous IO.**
`Shikigami.Behavior.Run.runBehavior :: BehaviorEnv -> AgentDecl -> Value -> IO (Either RunError Value)`
runs a behavior to completion in one pass and returns a JSON value. `Shikigami.Agent.Run.runAgentWithMemory`
(file `shikigami-core/src/Shikigami/Agent/Run.hs`) wraps it with the kioku session/memory lifecycle:
it opens a `Kioku` session (`Kioku.Session.start` via `Kioku.App.runAppIO appEnv`), recalls prior
learnings (`recallPriorLearnings`), calls `runBehavior`, records the output as a durable `Kioku`
memory, and completes (or fails) the session. **All of this is `IO`, not `Eff es`.** A `Flow` behavior
cannot be hosted by `runBehavior` because a flow may suspend; it needs a different runner that lives in
keiro's `Eff` stack. That runner is provided by plan 7 (`runWorkflow`-based); this plan adds the
`Flow` arm and its registry and routes the worker to plan 7's runner for that arm.

**keiro — the durable-workflow runtime (dependency).** Keiro is an `effectful` runtime. The
capabilities a flow uses:

- `Keiro.Workflow` exposes a custom effect `Workflow :> es` and primitives:
  `step :: StepName -> Eff es a -> Eff es a` (run an action once and *journal* its JSON result; on
  replay the recorded result is returned and the action is **not** re-run — identity is the `StepName`,
  not source position), `awaitStep`/`sleepNamed`/`awakeableNamed`/`spawnChild` (all suspend the run),
  and `runWorkflow :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)`
  where `WorkflowOutcome a = Completed a | Suspended | Cancelled | Failed | ContinuedAsNew`.
- `Keiro.Workflow.Sleep.sleepNamed :: StepName -> Int -> Eff es ()` arms a durable timer and suspends.
- `Keiro.Workflow.Awakeable.awakeableNamed :: StepName -> Eff es (AwakeableId, Eff es a)` returns an
  id (handed to an external caller) and an action that, when awaited, suspends until
  `signalAwakeable` resolves it.
- `Store :> es` is keiro's event-store effect (the journal lives here).
- A **resume worker** (`Keiro.Workflow.Resume`, used by plan 7/10) re-invokes `runWorkflow` for
  suspended runs when a timer fires or an awakeable is signalled; every still-in-flight workflow name —
  including children — must be present in its registry.

A "durable workflow" is a program whose named steps are recorded to Postgres so that after a crash it
resumes at the first unfinished step instead of repeating completed ones, and which can *suspend* (park
its position and wake later). "At-least-once until journaled" is keiro's contract: a `step`'s action is
safe to re-run until its result commits, so step actions must be idempotent with respect to the outside
world (pass deterministic ids, dedupe at the destination).

**keiki — the symbolic state-machine library (new dependency for this plan).** Keiro's aggregates are
keiki `SymTransducer`s: typed finite-state machines with guarded transitions over a register file. We
adopt keiki only for the *agent lifecycle* here. The relevant modules:

- `Keiki.Builder` — the do-notation builder for transducers: `B.buildTransducer initialState initialRegs isTerminal $ do { B.from State $ do { B.onCmd ctor $ \d -> B.do { B.requireGuard ...; B.slot @"x" =: ...; B.emit wireEvent fields; B.goto NextState } } }`. The jitsurei file
  `keiro-runtime-jitsurei/services/hospital-capacity/src/HospitalCapacity/Reservation/Transducer.hs`
  is a full worked example.
- `Keiki.Render.Mermaid` — `toMermaidWith :: MermaidOptions -> SymTransducer ... -> Text` and
  `defaultMermaidOptions`. Renders the transducer to a Mermaid `stateDiagram`.
- `Keiki.Render.Validate` — Mermaid-output validators; keiki core additionally provides
  `validateTransducer` returning structured warnings (`HiddenInput`, `NondeterministicPair`,
  `PossiblyDeadEdge`) that an empty-list assertion in a test turns into a build-time guarantee.

"Theoretically-backed lifecycle" means: the agent's states and transitions are a typed transducer
whose well-formedness keiki can check and whose shape keiki can draw, rather than ad-hoc `if`/`case`
control flow.

**The at-risk-customer detector (the thing we reimplement).** `agents/detectors/at-risk-customer.dhall`
declares an LLM-backed detector: trigger is an `activity.v1` stream match on support tickets; behavior
is a `ShikumiProgram` (`task = "at-risk-customer"`) that prefers EP-4 enrichment facts and otherwise
classifies `payload.text`; sink is a kizashi `Alert` on a high-risk verdict. Its header comment already
specifies the behavior this plan delivers: "high-risk verdict → Alert, Shared inbox, **escalate after
timeout**." Today that escalation cannot exist because the behavior is a synchronous program. The proof
slice turns this detector into a `Flow` that classifies, alerts, waits for acknowledgement, and
escalates on timeout.

**Plan 7 (the substrate this builds on).** `docs/plans/7-agent-runs-as-durable-keiro-workflows.md`
re-platforms a shikigami run onto a keiro `Workflow` and adds `awaitApproval`, a combinator that
"suspends the run, optionally arms a deadline timer, records that the run is waiting; when a human
answers the run resumes where it parked, or if the deadline passes first, resumes with a 'timed out'
decision." Plan 11's `awaitAcknowledgement` is a domain-named wrapper over `awaitApproval`.


## Plan of Work

The work is five milestones. M1 and M2 are independent spikes that de-risk the two new dependencies
(keiki, and the keiro flow stack) in isolation, with no database and no worker. M3 builds the combinator
layer. M4 is the end-to-end proof slice against a live database. M5 wires the new arm into the Dhall
schema, loader, worker, and CLI, and documents it. Each milestone is independently verifiable.

Throughout, work additively: new modules under a new `Shikigami.Flow.*` namespace inside the existing
`shikigami-core` package, plus a new `keiki` dependency. Do not modify `runBehavior`'s existing three
arms; the `Flow` arm is dispatched on a separate path.

### Milestone 1 (spike): keiki agent lifecycle as a verified, drawable state machine

Scope: prove that an agent lifecycle can be written as a keiki transducer, validated, and rendered to
Mermaid — with zero runtime dependencies. At the end there is a new module
`shikigami-core/src/Shikigami/Flow/Lifecycle/AtRiskCustomer.hs` exporting a `SymTransducer` for the
at-risk-customer lifecycle and a `Text` Mermaid rendering of it, plus a `tasty` test asserting the
transducer is well-formed (empty warning list) and that the Mermaid output contains the expected states.

The lifecycle to model (states): `Observed` (a ticket activity arrived) → on classify: `SettledLow`
(verdict not high; terminal) or `AwaitingAck` (high verdict, alert raised); `AwaitingAck` → on
acknowledgement: `Acknowledged` (terminal); `AwaitingAck` → on deadline: `Escalated` (terminal).
Terminal states: `SettledLow`, `Acknowledged`, `Escalated`.

Work: add `keiki` to `shikigami-core.cabal` `build-depends`. Create the module using `Keiki.Builder`
(mirror the structure of jitsurei's `Reservation/Transducer.hs`). Render with
`Keiki.Render.Mermaid.toMermaidWith defaultMermaidOptions`. Add a test in
`shikigami-core/test/Main.hs` (or a new `tasty` test module wired into the existing test-suite stanza)
that asserts `validateTransducer defaultValidationOptions atRiskCustomerLifecycle == []` and that the
Mermaid text mentions `AwaitingAck` and `Escalated`.

Commands: `cabal build shikigami-core` then `cabal test shikigami-core`. Acceptance: the test passes;
deliberately introducing a bad edge (a guard reading a field the emitted event omits) makes the
validation assertion fail with a `HiddenInput` warning naming the edge — demonstrating the check is
real. (Revert the deliberate break before committing.)

### Milestone 2 (spike): the behavior DSL skeleton — a `Flow` effect row and a flow registry

Scope: define the capability surface a flow runs under and prove a trivial durable flow runs through
keiro's `runWorkflow` in an isolated harness, independent of the shikigami worker. At the end there is a
new module `Shikigami.Flow` defining the flow effect constraints and the `FlowDef`/registry types, plus
a spike test that runs a two-step flow to `Completed` and a one-await flow to `Suspended`.

Define the capability alias and registry in `shikigami-core/src/Shikigami/Flow.hs`:

```haskell
-- | The capabilities a Flow behavior may use. Keiro's own effects are exposed
-- directly (Workflow, Store); shikigami adds its domain capabilities later (M3).
type FlowEffects es = (Workflow :> es, Store :> es, IOE :> es)

-- | A registered complex behavior. 'flowLifecycle' is the keiki transducer (for the
-- diagram + validation); 'flowRun' is the durable behavior body, named from Dhall.
data FlowDef = FlowDef
  { flowName      :: !Text
  , flowLifecycle :: !LifecycleDiagram          -- a wrapper carrying the transducer's Mermaid + validation
  , flowRun       :: forall es. FlowEffects es => Value -> Eff es Value
  }

flowRegistry :: [FlowDef]
lookupFlow   :: Text -> Maybe FlowDef
```

(`forall es.` in the field needs `RankNTypes`, already common in this codebase; `LifecycleDiagram`
is a small record holding the rendered Mermaid `Text` and a validation thunk so the registry can be
inspected without importing keiki everywhere.) Add a spike test that builds a tiny in-memory/Postgres
keiro `Store` (use keiro's test harness, e.g. `Keiro.Test.Postgres.withFreshStore` as jitsurei's tests
do) and runs `runWorkflow "spike" wid (do { _ <- step (StepName "a") (pure 1); step (StepName "b") (pure 2) })`,
asserting `Completed 2`; and a second flow that calls `sleepNamed (StepName "wait") 300` and asserts
`Suspended`.

Commands: `cabal build shikigami-core`; `cabal test shikigami-core`. Acceptance: the two-step flow
returns `Completed`, the sleeping flow returns `Suspended`. This proves the effect stack assembles and a
flow can journal and park before any shikigami wiring exists.

### Milestone 3: the capability combinators

Scope: add shikigami's own capabilities to the flow row and implement the named combinators authors use
instead of raw keiro. At the end `FlowEffects` includes `Memory`, `Sink`, and `Activity`, and the
combinators compile and have unit coverage.

Add three shikigami effects (small `effectful` effects, each interpreted to the existing IO machinery):

- `Memory` — `recall :: Memory :> es => MemoryQuery -> Eff es [MemoryRecord]` and
  `remember :: Memory :> es => Value -> Eff es MemoryId`, interpreted by reusing
  `Shikigami.Agent.Run`'s existing `recallPriorLearnings` / kioku `Memory.record` calls (which run via
  `Kioku.App.runAppIO`). The interpreter closes over the `AppEnv` and the agent scope.
- `Sink` — `emitSignal :: Sink :> es => KizashiSignalSpec -> Eff es ()` (and siblings for the other sink
  kinds as needed). Per the C3 decision (Option 3, transactional outbox — plan 7's Decision Log), the
  interpreter runs the existing permission gate and then **enqueues a sink-intent row** into
  `kiroku.keiro_outbox` via plan 7's `dispatch-sinks` seam (keiro `enqueueOutboxTx`, deterministic
  `message_id` from `(WorkflowId, sinkIndex)`) — it does **not** POST synchronously. Plan 7's outbox
  publisher delivers it at-least-once. Reuse the existing `Shikigami.Sink.*` clients as the publisher's
  HTTP backend; do not reimplement the sink path. Because a flow emits sinks *mid-run* (the Alert before
  the wait, the escalation after a timeout resume), the enqueue happens at those points inside the
  workflow, which is exactly why sinks must be inside the workflow (and why the outbox, not a synchronous
  POST, gives durable delivery without coupling the wait to endpoint health).
- `Activity` — `currentActivity :: Activity :> es => Eff es ActivityEnvelope`, supplying the triggering
  envelope to the flow.

Then the wait combinator. It must fit plan 7's `awaitApproval` exactly, whose real signature is
`awaitApproval :: (Workflow :> es, Store :> es, IOE :> es) => ApprovalEnv -> StepName -> ApprovalRequest -> Maybe NominalDiffTime -> Eff es ApprovalDecision`
with `data ApprovalDecision = Approved !Value | Rejected !Text | TimedOut`. `awaitAcknowledgement` builds
the `ApprovalRequest` (the acknowledgement prompt + context), passes the deadline as `Just`, and maps the
three `ApprovalDecision` cases onto a domain `Ack`:

```haskell
-- | Park the run until an acknowledgement arrives or the deadline elapses.
-- Thin wrapper over plan 7's awaitApproval; the deadline path requires plan 7 Milestone 4
-- (the timer that arms the awaitApproval deadline and signals TimedOut on fire).
data Ack = Acknowledged !Value | Declined !Text | TimedOut
awaitAcknowledgement ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  ApprovalEnv -> StepName -> ApprovalRequest -> NominalDiffTime -> Eff es Ack
awaitAcknowledgement env name req deadline =
  toAck <$> awaitApproval env name req (Just deadline)
  where
    toAck = \case { Approved v -> Acknowledged v; Rejected r -> Declined r; TimedOut -> TimedOut }
```

`ApprovalEnv` is threaded from the run (it carries the channel hooks plan 7 stubs: `postAsk` over
kizashi/danwa, `recordPark` over kioku); the flow obtains it the same way plan 7's worked example does.
If plan 7 has not landed when M3 begins, implement `awaitAcknowledgement` directly against keiro
`awakeableNamed` (for the acknowledgement) raced with `sleepNamed` (for the deadline), keeping this exact
author-facing signature so M4/M5 are unaffected, and record the fallback in the Decision Log when taken.

Commands: `cabal build shikigami-core`; `cabal test shikigami-core` (add interpreter unit tests:
`recall` returns seeded memories; `emitSignal` invokes the sink dispatcher / respects a denied
permission). Acceptance: combinators typecheck under `FlowEffects` and their interpreters pass unit
tests reusing the existing kioku and sink code paths.

### Milestone 4: the at-risk-customer vertical slice

Scope: compose the combinators into the real flow, register it, and prove both outcome branches plus
crash-resume end to end against a live Postgres. At the end `atRiskCustomerFlow` exists, is in
`flowRegistry`, and a proof harness demonstrates classify → alert → park → (ack | timeout→escalate),
with resume across a simulated crash.

The flow body (in `shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs`):

```haskell
atRiskCustomerFlow :: FlowEffects es => Value -> Eff es Value
atRiskCustomerFlow payload = do
  env     <- currentActivity
  prior   <- recall (riskQuery env)
  verdict <- step (StepName "classify") (classifyRisk env prior)   -- runs the existing typed program; journaled
  if not (isHigh verdict)
    then pure (toJSON verdict)                                      -- -> SettledLow
    else do
      emitSignal (alertFor verdict env)                            -- raise the kizashi Alert  -> AwaitingAck
      ack <- awaitAcknowledgement approvalEnv (StepName "await-ack") (ackRequest verdict env) (15 * 60)
      case ack of                                                  -- park up to 15 minutes
        Acknowledged who -> do _ <- remember (acknowledgedNote verdict who); pure (resolvedValue who)
        Declined why     -> do _ <- remember (declinedNote verdict why); pure (declinedValue why)
        TimedOut         -> do emitSignal (escalationFor verdict env); _ <- remember (escalatedNote verdict); pure escalatedValue
```

`classifyRisk` wraps the existing at-risk-customer typed program (the `ShikumiProgram` path) so the
classification logic is reused, not rewritten — the flow adds only the durable wait/escalate around it.
The journaled `StepName`s (`classify`, `await-ack`) and the lifecycle states from M1 share one
vocabulary so the Mermaid diagram and the live run describe the same machine.

Build the proof as a `tasty` test plus, optionally, CLI invocations, following the precedent of
`docs/plans/6-end-to-end-living-loop-proof-and-detector-conformance.md`'s harness (Postgres via the
project's `process-compose`/`db` setup; keiro store via its migrations). Three scenarios:

1. **Acknowledged in time:** feed a high-risk ticket activity; assert the run reaches `Suspended` after
   the alert; assert exactly one Alert **outbox row** was enqueued in `kiroku.keiro_outbox` (deterministic
   `message_id`, status pending) and the outbox publisher delivered it (a kizashi Alert POST); signal the
   acknowledgement awakeable; assert the run resumes to `Completed` with the resolved value and **no**
   escalation row was ever enqueued.
2. **Timed out → escalated:** feed the same activity; advance the deadline timer (fire it via the timer
   worker the way jitsurei's tests do); assert the run resumes to `Completed` with the escalated value and
   a **second (escalation) outbox row** was enqueued and delivered. (Sink delivery is asynchronous via the
   outbox publisher, so assert on the outbox row first, then on delivery — not a single synchronous POST.)
3. **Crash-resume:** between the alert and the resume, discard the in-process workflow state and
   re-invoke `runWorkflow` from the journal; assert `classify` is **not** re-run (the journaled verdict
   is reused) and the run still completes correctly.

Commands: start the local stack (`process-compose up` / the repo's `Justfile` db target), run the proof
test (`cabal test shikigami-core --test-options=...` or a dedicated test-suite). Acceptance: all three
scenarios pass; the worker log shows one suspend and one resume per parked run, not two independent runs.

### Milestone 5: wiring and docs

Scope: make the new arm usable from a Dhall declaration and from the CLI, and document it. At the end an
agent file can say `behavior = Behavior.Flow { name = "at-risk-customer" }`, the worker runs it, and a
CLI subcommand prints the agent's lifecycle diagram.

Work:

- Add `| Flow : { name : Text }` to the `Behavior` union in `schema/Agent.dhall` and the mirrored
  `Flow {name :: !Text}` constructor to `Shikigami.Api.Agent.Behavior` (keep `FromDhall`/`ToJSON`/`FromJSON`
  deriving). Update `agents/detectors/at-risk-customer.dhall` (or add a sibling
  `agents/detectors/at-risk-customer-flow.dhall`) to use the new arm.
- In the worker/agent-run dispatch (`Shikigami.Agent.Run` / the worker command), route `Flow { name }`
  to plan 7's workflow runner using `lookupFlow name`'s `flowRun`, instead of the synchronous
  `runBehavior` path used by the other three arms. The other arms are unchanged.
- Add a `shikigami render-lifecycle <agent.dhall>` CLI subcommand (in `shikigami-cli`) that loads the
  agent, looks up its flow, and prints `flowLifecycle`'s Mermaid `Text` to stdout; optionally
  `--write <file.md>` splices it into a Markdown doc via `Keiki.Render.Markdown` (mirror jitsurei's
  `writeKeikiDiagrams`).
- Write `docs/user/flows.md` explaining: when to reach for a `Flow` vs the simpler arms, the capability
  combinators, the suspend/resume/escalate model, and how the keiki lifecycle gives verification + a
  diagram. Cross-link from `docs/user/behaviors.md` and `docs/user/README.md`.

Commands: `cabal build all`; `shikigami validate agents/detectors/at-risk-customer-flow.dhall`;
`shikigami render-lifecycle agents/detectors/at-risk-customer-flow.dhall`. Acceptance: the validate
command prints the parsed declaration with the `Flow` arm; the render command prints a Mermaid
`stateDiagram` showing `Observed → AwaitingAck → {Acknowledged, Escalated}`; starting the worker and
feeding a high-risk ticket runs the flow (the M4 behavior) end to end.


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/shikigami` inside the nix dev
shell (`direnv allow` once, or `nix develop`).

Confirm the starting point and the substrate dependency:

```bash
# The new dependencies and the plan-7 substrate this plan builds on.
mori registry show keiki --full | head -20
sed -n '/build-depends/,/^$/p' shikigami-core/shikigami-core.cabal | grep -E 'keiro|keiki' || echo 'keiki not yet a dependency (M1 adds it)'
test -f docs/plans/7-agent-runs-as-durable-keiro-workflows.md && echo 'plan 7 present (substrate)'
```

M1 — build and test the lifecycle spike:

```bash
cabal build shikigami-core
cabal test shikigami-core
# Expected: the lifecycle test passes; toMermaidWith output includes "AwaitingAck" and "Escalated".
```

Actual M1 validation on 2026-06-28 was run through the nix development shell because the ambient shell
was missing `librdkafka`:

```bash
nix develop -c cabal build shikigami-core
nix develop -c cabal test shikigami-core
```

The relevant test output was:

```text
FlowLifecycle
  at-risk customer lifecycle is well-formed:              OK
  at-risk customer lifecycle renders the expected states: OK

All 36 tests passed (3.14s)
Test suite shikigami-core-test: PASS
```

M2 — the flow skeleton and durable-run spike:

```bash
cabal build shikigami-core
cabal test shikigami-core
# Expected: two-step flow -> Completed 2; sleeping flow -> Suspended.
```

M3/M4 — combinators and the end-to-end proof (needs the local stack):

```bash
# Start Postgres (and any broker) the repo's way; see Justfile / process-compose.yaml.
just db-up 2>/dev/null || process-compose up -D
cabal test shikigami-core   # includes the three at-risk-customer scenarios
```

M5 — wiring and diagram CLI:

```bash
cabal build all
cabal run shikigami -- validate agents/detectors/at-risk-customer-flow.dhall
cabal run shikigami -- render-lifecycle agents/detectors/at-risk-customer-flow.dhall
# Expected: a Mermaid stateDiagram printed to stdout.
```

(Exact expected transcripts are filled in as each milestone is implemented; this section must be updated
with the real output captured during M1–M5.)


## Validation and Acceptance

Acceptance is phrased as observable behavior, not code shape.

1. **The lifecycle is a checked, drawable artifact (M1, M5).** `cabal test shikigami-core` passes a test
   that fails if the at-risk-customer transducer is ill-formed; `shikigami render-lifecycle <agent>.dhall`
   prints a Mermaid `stateDiagram` whose states are `Observed`, `SettledLow`, `AwaitingAck`,
   `Acknowledged`, `Escalated` with the transitions described in M1. Pasting the output into any Mermaid
   viewer renders the agent's lifecycle.

2. **A flow can park and resume (M2, M4).** Feeding a high-risk ticket to the registered
   `at-risk-customer` flow produces a run that reaches keiro `Suspended` after raising the Alert (the
   worker is free), then resumes to `Completed` when acknowledged. With no acknowledgement, after the
   15-minute deadline the run resumes and dispatches a second, escalation signal, then completes. These
   are two distinct, observable outcomes from the same input, neither expressible by the synchronous
   `runBehavior` seam.

3. **Resume is durable, not a thread block (M4).** Killing the worker (or discarding in-process state)
   while a run is parked and re-invoking the workflow runner resumes from the journal: the `classify`
   step is not re-run (no second classification, no duplicate memory), proven by asserting the journaled
   verdict is reused and exactly one Alert was dispatched.

4. **Simple agents are unaffected (M5).** The existing three behavior arms still run through
   `runBehavior` unchanged; an agent without a `Flow` arm behaves exactly as before
   (`cabal test shikigami-core` for the pre-existing suites stays green).

A reviewer can reproduce all four from a fresh checkout by following Concrete Steps.


## Idempotence and Recovery

All additions are additive: a new `keiki` dependency, new modules under `Shikigami.Flow.*`, a new
registry, and one new `Behavior` arm. Re-running any build/test step is safe. The `Flow` arm is
dispatched on a separate code path, so the change cannot regress the existing three arms.

Keiro's durability contract requires care in two places, both handled by construction: (a) the
`classify` step must be safe to run "at least once until journaled" — it is, because it is a pure
classification over the activity payload with no external write; (b) the escalation must be **total** —
a late timeout arriving after an acknowledgement already completed the run must be a benign no-op, which
the workflow journal guarantees (a `Completed` run does not resume). Timer and awakeable ids must be
deterministic (derived from the agent name + activity id) so re-arming on resume is idempotent; follow
the jitsurei precedent (`namedUuid`-style v5 ids).

Risk: **plan 7 may not have landed when M3 begins.** Mitigation is in the Decision Log — implement
`awaitAcknowledgement` directly against keiro `sleepNamed` + `awakeableNamed`, and when plan 7 lands,
re-point it at `awaitApproval`. The flow's author-facing signature (`awaitAcknowledgement`) does not
change, so M4/M5 are unaffected by which implementation backs it. If the local Postgres stack is
unavailable, M1 and M2's pure/spike tests still run and de-risk the design; only M4's live scenarios
require the database.


## Interfaces and Dependencies

New dependency: `keiki` (add to `shikigami-core/shikigami-core.cabal` `build-depends`). Existing
dependencies relied on: `keiro`, `keiro-core` (already present), `kioku` (already used by
`Shikigami.Agent.Run`), `effectful`, `aeson`, `text`, `time`.

Keiki modules used (paths are the library's exposed modules, confirmed via its `keiki.cabal`):

- `Keiki.Builder` — `buildTransducer`, `from`, `onCmd`, `requireGuard`, `slot`, `emit`, `goto`.
- `Keiki.Render.Mermaid` — `toMermaidWith :: MermaidOptions -> SymTransducer ... -> Text`,
  `defaultMermaidOptions`, `MermaidOptions(..)`.
- `Keiki.Render.Validate` (and keiki core `validateTransducer` / `defaultValidationOptions`) — returns
  `[]` for a well-formed transducer or warnings (`HiddenInput`, `NondeterministicPair`,
  `PossiblyDeadEdge`).
- `Keiki.Render.Markdown` — `replaceMarkdownDiagramBlock` (M5 `--write`).

Keiro modules used:

- `Keiro.Workflow` — `Workflow`, `step`, `StepName(..)`, `runWorkflow`, `WorkflowOutcome(..)`,
  `WorkflowName`, `WorkflowId`.
- `Keiro.Workflow.Sleep` — `sleepNamed`. `Keiro.Workflow.Awakeable` — `awakeableNamed`,
  `signalAwakeable`. `Keiro.Workflow.Resume` — the registry the resume worker consumes (plan 7/10 own
  the worker; this plan registers its flow names there).
- `Store` (keiro's event-store effect) and its test harness (`Keiro.Test.Postgres.withFreshStore`) for
  the spike/proof tests.

Plan 7 artifacts consumed (must exist before M4/M5; names are plan 7's, verbatim): the workflow
`agentRunWorkflow :: AgentRunDeps -> Maybe RunJob -> Eff (Workflow : AppEffects) (Either Text AgentRunResult)`
and its constant `agentRunWorkflowName = WorkflowName "shikigami.agent-run"`; the registry
`agentRunRegistry :: AgentRunDeps -> WorkflowRegistry AppEffects` and the resume worker
`runWorkflowResumeWorker` it is registered with; and the approval combinator
`awaitApproval :: (Workflow :> es, Store :> es, IOE :> es) => ApprovalEnv -> StepName -> ApprovalRequest -> Maybe NominalDiffTime -> Eff es ApprovalDecision`
with `ApprovalDecision = Approved !Value | Rejected !Text | TimedOut`, `ApprovalRequest`, `ApprovalEnv`,
and the deadline-arming timer from plan 7 Milestone 4. `AppEffects` is plan 7's row
`[Store, Error StoreError, Tracing, IOE]`; `FlowEffects` adds shikigami's `Memory`/`Sink`/`Activity`
effects to that row, so a flow body typechecks inside `agentRunWorkflow`'s `Eff (Workflow : AppEffects)`.
The `Flow` arm is spliced in **in place of** plan 7's `step (StepName "run-behavior") …`, sharing that
workflow's `WorkflowId`, journal, and resume worker; this plan adds no keiro `WorkflowRegistry` entry.

Types/functions that must exist at the end of each milestone:

- End of M1: `Shikigami.Flow.Lifecycle.AtRiskCustomer.atRiskCustomerLifecycle :: SymTransducer ...` and
  `atRiskCustomerMermaid :: Text`; a passing well-formedness test.
- End of M2: `Shikigami.Flow.FlowEffects` (constraint synonym), `FlowDef`, `flowRegistry :: [FlowDef]`,
  `lookupFlow :: Text -> Maybe FlowDef`; a passing durable-run spike (`Completed`/`Suspended`).
- End of M3: effects `Memory`, `Sink`, `Activity` with interpreters reusing the existing kioku/sink/IO
  code; combinators `recall`, `remember`, `emitSignal`, `currentActivity`, and
  `awaitAcknowledgement :: (Workflow :> es, Store :> es, IOE :> es) => ApprovalEnv -> StepName -> ApprovalRequest -> NominalDiffTime -> Eff es Ack`
  (a thin map over plan 7's `awaitApproval`).
- End of M4: `atRiskCustomerFlow :: FlowEffects es => Value -> Eff es Value`, registered in
  `flowRegistry`; three passing end-to-end scenarios.
- End of M5: `Behavior` gains `Flow {name :: !Text}` (Dhall + Haskell); worker dispatch routes the arm
  via `lookupFlow`; `shikigami render-lifecycle` subcommand; `docs/user/flows.md`.


## Revision Notes

- 2026-06-27 — **Cross-plan coherence pass (plans 7–11).** After authoring this plan, a normalized
  design-contract was extracted from each of plans 7, 8, 9, 10 and compared against this one. The audit
  found this plan had drifted from plan 7's actual API in four ways, now corrected throughout (Purpose,
  Context, Plan of Work M3/M4, Decision Log, Interfaces): (1) a `Flow` is now stated to inline into plan
  7's `agentRunWorkflow` in place of the opaque `run-behavior` step, sharing its `WorkflowId`/journal/
  resume worker, so this plan adds **no** keiro workflow or `WorkflowRegistry`; (2) `flowRegistry` is
  clarified as a shikigami behavior lookup, not a keiro registry; (3) `awaitAcknowledgement` is aligned to
  plan 7's real `awaitApproval` signature and `ApprovalDecision` mapping; (4) the deadline ("escalate
  after timeout") is now explicitly a dependency on plan 7 **Milestone 4**. Reason: keep the five
  concurrently-written plans mutually consistent and make this one implementable directly against plan 7's
  named artifacts.
- 2026-06-27 (follow-up) — **C3 resolved as Option 3 (transactional outbox).** The `Sink` effect's
  `emitSignal` now enqueues into `kiroku.keiro_outbox` via plan 7's `dispatch-sinks` seam rather than
  POSTing synchronously, and M4's two outcome scenarios assert on outbox rows + asynchronous delivery.
  Reason: flows emit sinks mid-run, so durable, decoupled, exactly-once-enqueued delivery (the kikan
  production model) is required; a synchronous POST cannot give it without coupling the wait to endpoint
  health.
