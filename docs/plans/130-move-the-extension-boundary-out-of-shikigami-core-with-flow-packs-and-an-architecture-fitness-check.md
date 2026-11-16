---
id: 130
slug: move-the-extension-boundary-out-of-shikigami-core-with-flow-packs-and-an-architecture-fitness-check
title: "Move the extension boundary out of shikigami-core with flow packs and an architecture fitness check"
kind: exec-plan
created_at: 2026-11-15T13:43:17Z
intention: "intention_01m7fq4tf3ejrt0tjxvsy8ejdt"
master_plan: "docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-15T13:43:17Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-15T14:02:26Z
      mode: "other"
      note: "Drafted plan body under MasterPlan 22"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-15T14:50:10Z
      mode: "update"
      note: "MasterPlan 22 review: single pack API owner, two SDK components, distribution, pack-owned labels, drain rule"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-15T15:01:14Z
      mode: "update"
      note: "Adaptive-delivery coordinator stays in the kernel (user decision 2026-11-15)"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-16T03:48:14Z
      mode: "implement"
      note: "M1: kernel fitness check, kernel policy in module-ownership.json, ADR 0129"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-16T04:42:50Z
      mode: "implement"
      note: "M2: pack API, flow-sdk and pack-sdk, watchdog representative check, flow-pack-examples and examples-distribution, IR-61"
---

# Move the extension boundary out of shikigami-core with flow packs and an architecture fitness check

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Today the only way to add a Haskell flow (a durable, multi-step agent behavior) or a Shikumi
program to Shikigami is to edit `shikigami-core`. You add a module under
`shikigami-core/src/Shikigami/Flow/`, list it in `shikigami-core/shikigami-core.cabal`, and
append it to the list `Shikigami.Flow.flowRegistry`. So every use case ends up inside the core.
This plan moves that extension point out of the core. It is EP-5 of
[MasterPlan 22](../masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md).

After this plan, an operator can write a *flow pack*. A flow pack is an ordinary Cabal library
package that depends only on two small public SDK components of `shikigami-core`:
`shikigami-core:flow-sdk`, which is everything a flow body may import, and
`shikigami-core:pack-sdk`, which adds what a pack's interpreter needs. The pack contributes
flows and programs. A separate *distribution* package composes packs into executables with a
few lines of `main`, and those executables run declared agents with the pack's flows. No edit
to `shikigami-core` is needed. Packs and distributions can live in this repository under
`packs/` or in a different repository. A fitness check in the core test suite fails the build
if someone adds a new use-case namespace to `shikigami-core`, and its failure message points
at the pack and declaration route.

This plan is the single owner of the pack API. MasterPlan 22's review on 2026-11-15 found that
this plan and EP-6 had each defined the pack type, with different fields, names and dependency
rules. The whole shape is defined here once, including pack-owned interpreters, and it is
proven against the most demanding consumer (the watchdog flow) before any subsystem moves.
Later plans extend this plan's type and never define a parallel one.

You can see it working three ways. First, on this Mac,
`cabal run shikigami-examples-agent-run -- --agent packs/flow-pack-examples/agents/at-risk-customer-flow.dhall --payload ...`
runs the at-risk-customer teaching flow, which now lives in `packs/flow-pack-examples`. The
executable belongs to the distribution package `packs/examples-distribution`. The stock
`shikigami-agent-run` refuses that agent and names the flows it actually has. Second, a
pack in a separate local repository records HEAD observations of the operator's real checkouts
under `/Users/shinzui/Keikaku/bokuno/`. It does this with no change to this repository. Third,
adding `shikigami-core/src/Shikigami/Campaign/Plan.hs` makes `cabal test shikigami-core-test`
fail with a message naming the pack and playbook routes. Deleting the file makes the test pass
again.


## Progress

- [x] M1 (2026-11-16). Kernel fitness check. `tools/style/module-ownership.json` gains a closed `kernel`
  section that classifies every top-level `shikigami-core` namespace as `kernel`, `flow-pack`
  or `kikan-binding` and freezes the modules of non-kernel namespaces. `PackageArchitectureSpec` fails
  on the planted `Shikigami.Campaign` namespace and passes after its removal. The new ADR is
  written.
  - Evidence: 72 namespaces (68 kernel; Initiative, PracticeReview and Watchdog `flow-pack`;
    DanwaConversation `kikan-binding`) and 57 frozen modules. `just kernel-fitness` runs the six
    `kernel boundary` tests in `shikigami-core/test/Shikigami/KernelBoundarySpec.hs`. With
    `shikigami-core/src/Shikigami/Campaign/Plan.hs` planted it exits 1 and prints
    "shikigami-core/src/Shikigami/Campaign/Plan.hs: Shikigami.Campaign is not a kernel
    namespace." followed by the declaration and pack routes; after removing the file it exits 0.
    The empty `Id` and `Store` directories are gone. ADR
    [0129](../adr/0129-the-kernel-owns-primitives-and-use-cases-ship-as-declarations-or-packs.md)
    is written and amends ADR-75 and ADR-13.
- [x] M2 (2026-11-16). The pack API, both SDK components and the first in-repository pack.
  Flows (a body plus a pack-owned interpreter), decision programs and ShikumiProgram tasks are
  composed at executable start. The representative check ran before the shape was fixed and
  changed it. `packs/flow-pack-examples` owns at-risk-customer, and the frozen list shrank by
  its two modules. The keiro improvement request is filed.
  - Evidence, commits `653056eb` (composable registry), `6989b827` (SDK components) and
    `627e8a2a` (the pack). `shikigami-examples flows` prints
    `examples  at-risk-customer  default-model=required  slots=-` after ten `builtin` lines,
    and the stock `shikigami flows` has no `at-risk` line.
  - Real run on this Mac, low path. The payload was the body of the most recent issue of
    `shinzui/keiro` (2,019 bytes, no risk word). `shikigami-examples-agent-run` logged
    `flow.registry.composed` with packs `builtin` (ten flows) and `examples`
    (`at-risk-customer`), then
    `{"agent":"at-risk-customer","event":"flow.selected","flow":"at-risk-customer","pack":"examples",...}`,
    and printed `output: {"level":"low","rationale":"no high-risk signal detected",...}` with
    exit 0. The stock `shikigami-agent-run` printed
    `agent-run: unknown flow at-risk-customer; registered flows: run-declared-tool, watchdog-sweep, ...`
    before opening a session.
  - Planting `import Effectful (IOE)` in
    `packs/flow-pack-examples/bodies/FlowPack/Examples/Body/AtRiskCustomer.hs` fails with
    "Could not load module ‘Effectful’. It is a member of the hidden package"; removing it
    builds.
  - Suites at `627e8a2a`: shikigami-core-test 963, shikigami-core-postgres-test 688,
    shikigami-agent-test 42, shikigami-server-test 114, shikigami-core-diagrams-test 2,
    flow-pack-examples-test 13, keiro-shikigami-conformance. `just kernel-fitness` passes
    7 tests, now over two real packages under `packs/`. `nix eval` of
    `.#packages.aarch64-darwin.shikigami-worker.drvPath` succeeds with
    `nix/qualification/cohort.json` unchanged.
  - `just keiro-gate HEAD~1` reports one finding, `WorkflowBodyChanged` for AgentRun (see
    Surprises), and `just keiro-diff HEAD` is clean.
  - Filed `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-61` (keiro commit
    `136879d1`).
- [x] M3 (2026-11-16). A pack in a separate repository with no Shikigami change. The local
  repository `/Users/shinzui/Keikaku/bokuno/shikigami-operator-packs` (intended URI
  `mori://shinzui/shikigami-operator-packs`; not registered, not pushed) holds
  `flow-pack-repository-ledger` and `operator-distribution`, builds against this checkout
  through `just sync-cohort`, and ran the flow over real checkouts.
  - Evidence, commit `b5a9f31` of that repository, built against this repository at
    `7256c709`. `flow-pack-repository-ledger-test` passes 7 tests, including the golden labels
    `ledger-compare`, `recall-ledger-prior` and `remember-ledger-observed` read from a real
    journal.
  - Four runs of `operator-agent-run --agent agents/repository-ledger.dhall`, each logging
    `"flow":"repository-ledger","pack":"ledger"`: keiro printed
    `"movement":"FirstObservation"` with `"previousHead":null`; shikigami printed
    `"movement":"FirstObservation"`; the second and third keiro runs printed
    `"movement":"Unchanged"` with `previousHead` equal to keiro's HEAD
    `15d9ac3ac74048db92cb34730a77efbd883a4649`. A fifth run through `just observe ../keiro`
    printed `Unchanged` again.
  - `git status --short` in this repository printed nothing after the runs.


## Surprises & Discoveries

- Observation: Flow step labels are declared in the core's keiro-dsl specification, so a pack
  cannot add a label to the reviewed durable step list without editing this repository.
  Evidence: `domain/shikigami/agent-run.keiro` declares `step classify -> RiskVerdict`
  (at-risk-customer), `objectives-example-*` and `decision-prepare-triage` inside the
  `AgentRun` body. `docs/workflow-versioning.md` says "a new label on a registered flow is now a
  specification edit, a regeneration, and a gate run". See the Decision Log.
- Observation: The frozen Nix closure assumes exactly seven `shikigami-*` packages.
  Evidence: `tools/qualification/export-cohort.py` roots the closure at package names starting
  with `shikigami-` and raises "expected all seven local Shikigami packages".
  `nix/qualification-package.nix` asserts `builtins.length applicationPackages == 7`.
- Observation: Supplying the registry at composition moves the list, not the coupling.
  `FlowEffects` in `shikigami-core/src/Shikigami/Flow.hs` is a closed row of 18 effects, 8 of
  them use-case specific (`AdaptiveDelivery`, `Initiative`, `Observe`, `ExecutionContext` and
  four `PracticeReview*` effects). `FlowDef.run` is quantified over that fixed row, so a pack
  cannot add a capability of its own. `runFlowBehavior` in
  `shikigami-core/src/Shikigami/Agent/Workflow.hs` (lines 1117 to 1230) hand-stacks every
  interpreter for every flow, evaluates the `shikigami-watchdog-v1`, `shikigami-initiative-v1`
  and `shikigami-initiative-admission-v1` patches, and tests
  `flow.name == WatchdogFlow.watchdogFlowName` in three places. This is why a pack flow must
  carry its own interpreter (see the Decision Log). EP-6 removes the use-case effects and
  branches as each subsystem moves; this plan adds the shape that lets them leave.
- Observation: Neither existing architecture check can see a pack, so the kernel fitness check
  is a new check, not an extension.
  Evidence: `declaredProjectPackages` in `shikigami-core/test/Shikigami/PackageArchitectureSpec.hs`
  keeps only `cabal.project` lines that start with `shikigami-`, so the "exactly seven
  packages" test ignores `packs/...`. `tools/style/module_ownership.py` checks that the root of
  every `Shikigami.<Root>` module is one of the 56 `domainRoots`; it is repository-wide, per
  root, and does not know which package a module is in or whether a root is a use case.
- Observation: `shikigami-core` has no library API boundary today. Its Cabal file exposes 357
  modules. The two SDK components are the first reviewed surface.


- Observation (M2, the representative check): the watchdog body compiles against the pack
  shape, and the check changed the shape in three ways.
  Evidence: a throwaway `packs/flow-pack-probe` (not merged) held the watchdog body verbatim in
  a `bodies` sublibrary and the `Observe` effect with its interpreter in the main library. The
  body was typed `(FlowEffects es, Observe :> es) => Value -> Eff es Value`, with Cabal
  `mixins` restricting `bodies` to `flow-sdk` plus a named module list, so no `IOE` or `Store`
  was in scope; planting `import Effectful (IOE)` failed with "member of the hidden package".
  Its unit test ran the body over a recording interpreter that returned one fixed, empty
  observation page and printed
  `the watchdog body performed ["probe-grant","probe-open","probe-observe","probe-record","probe-close"]`.
  - What the shape could not express, now fixed. (1) `runObserve` needs `Error StoreError`
    for a journaled read, so `PackFlow.run` grants it. (2) The sweep origin needs the native
    workflow name, so `FlowRunContext` carries `workflowName`. (3) The kernel chose the
    advisory decision interpreter and the optional drift slot by testing the flow's name;
    `FlowDef.decisionMode` (`StrictDecisions` or `AdvisoryDecisions`) now carries both.
  - What the watchdog gets by name today and how a pack obtains it. The sweep-failure hook:
    the pack's `run` wraps the body in `try` and calls its own hook, which the probe did. The
    sweep origin and `driftEnabled`: built from `FlowRunContext` (`workflowName`, `runId`,
    `occurredAt`, `identity` through `resolvedIdentity`, `agent.decisionModels`,
    `executionRoot`). Two by-name branches remain in `runFlowDefinition` for EP-6: the
    inventory is emptied when `Observe` is unavailable, and `onSweepFailed`. The
    `shikigami-watchdog-v1` patch gate is also still evaluated by the kernel; a pack that keeps
    it must call `patch` itself, which `flow-sdk` does not export yet.
  - Kernel modules the probe imported beyond the SDK, the first candidates for EP-6. Body:
    `Shikigami.Decision.Contract`, `Shikigami.Decision.ModelAlias`,
    `Shikigami.Flow.Capability` (`emitSignals`), `Shikigami.Flow.Decision` (`Decision`,
    `DecisionLabel`, `decide`, `decisionSlot`, `decisionStep`),
    `Shikigami.Objective.Observation`, `Shikigami.Program.DecisionRunner` (`DecisionAbort`),
    `Shikigami.Sink.Types`, and `Effectful.Exception` (`try`, `throwIO`). Interpreter:
    `Shikigami.Agent.Principal` (`resolvedIdentity`), `Shikigami.Agent.Decl`,
    `Shikigami.Objective.Observation` and `Hasql.Transaction`. Modules that move with the
    subsystem: `Shikigami.Watchdog.{Classify, Delivery, Drift, Grant, Ledger, Observation,
    Store, Types}` and `Shikigami.Program.Decision.Drift`.
- Observation (M2): `just keiro-gate` reports the recorded removal as one finding, and five
  labels left, not one.
  Evidence: the AgentRun declaration also carried at-risk-customer's `recall-risk-history`,
  `remember-acknowledged`, `remember-declined` and `remember-escalated`. With `classify` they
  are the five removals behind
  `BREAKING: AgentRun workflow-body AgentRun: workflow body labels, kinds, result types, or order changed without a new patch guard; wrap a cross-cutting change in patch, or rename the replay label for one changed step [WorkflowBodyChanged]`
  with `vector: private-history-read=breaking old-binary-read-new-events=breaking snapshot-hydration=advisory rollout=stop-the-world`
  and `replay-neutral: stored-data replay is unchanged by this diff`. It is accepted under
  ADR-27. The hand-owned `KeiroConformance.Expectations` body list lost the same five labels.
- Observation (M2): a pack cannot list the labels its body journals without PostgreSQL.
  Evidence: `Keiro.Workflow` 0.22.0.0 exports the `Workflow` effect without constructors, and
  `runWorkflow` and `runWorkflowWith` need `Store`. The pack's test runs each branch under
  `runWorkflowWith` on a fresh database and reads the step index; the kernel capabilities are
  recording interpreters, for which `Shikigami.Flow.Capability` and
  `Shikigami.Flow.Acknowledgement` now export their effect constructors. IR-61 asks keiro for
  a store-free interpreter.
- Observation (M2): `shikigami-agent-run` already had `--payload` and already printed the
  behavior output, so M2 added only the composition, the pre-session refusal and
  `flow.selected`. The line is `output: <json>`, with a colon.
- Observation (M3): the development shell acts on the directory it is entered from, so the
  plan's commands for the external repository needed two changes (FRIC-82).
  Evidence: `nix develop /Users/shinzui/Keikaku/bokuno/shikigami --command ...` run from the
  other repository ran `initdb` into its `./db`, linked `.pre-commit-config.yaml`, installed
  Shikigami's commit hooks into its `.git/hooks`, and reset `PGHOST` and
  `PG_CONNECTION_STRING` to that empty directory. The `export PG_CONNECTION_STRING=...` of
  Concrete Steps is therefore overridden, and the first run failed with
  `connection to server on socket ".../shikigami-operator-packs/db/.s.PGSQL.5432" failed`.
  The working form sets both inside the shell:
  `nix develop ... --command env PGHOST=<shikigami>/db PG_CONNECTION_STRING=... cabal run ...`.
  The external repository's `just observe` and `just test` do that, its `.gitignore` covers
  the two created paths, and its README says to remove the installed hooks, which look for
  Shikigami's `flake.nix` and fail there.
- Observation (M3): a pack test that uses the database fixture must link the threaded
  runtime.
  Evidence: without `-threaded` the suite died before printing, with
  `registerDelay: requires -threaded`. The in-repository pack already had the option.
- Observation (M2): the qualification fixture `fixtures/qualification/agents/at-risk-customer.dhall`
  named the moved flow. A stock worker loading that directory would refuse to start, so the
  agent moved to `packs/flow-pack-examples/agents/qualification-at-risk-customer.dhall`. Its
  directory entry stays. The durable approval scenario of plan 79 needs a worker composed
  with the pack before it can be qualified again; EP-6 creates the first such distribution.
- Observation: Ten namespaces were added to the core after this plan was drafted, all by
  MasterPlan 22's kernel work: Authority, CodingAgent, CodingAgentStep, DeclaredTool,
  DeclaredToolStep, Output, Playbook, Process, Record and Trust. They are classified `kernel`.
  The plan's list also named an `Action` root, which no longer exists (the action vocabulary is
  `Shikigami.Authority`, ADR 0123), so the Kikan-En authorizer modules frozen here are
  `Shikigami.Authority.KikanEn{,.Config,.Settings}`.
  Evidence: `ls shikigami-core/src/Shikigami` on 2026-11-16.
- Observation: Two Kikan modules are mixed and cannot be frozen whole: `Shikigami.Directory`
  holds the Meibo directory source and `Shikigami.Sink.Authorization` builds the Kikan-En
  authorizer. EP-10 must split them; ADR 0129 records it.

## Decision Log

- Decision: Recheck of the pre-release facts before M2 touched `Shikigami.Agent.Workflow`,
  `Shikigami.Flow` and `domain/` (base `1a7dfe16`). `git tag --list` is empty.
  `docs/workflow-versioning.md` still carries "Current first-release baseline exception", and
  MasterPlan 22 records no "exception ended". The development database holds non-terminal
  runs: three suspended `shikigami.agent-run` instances (among them the parked campaign run
  `c4341273-0d66-516c-a51b-b840d26be160`), two running coding-agent children and one running
  approval. The drain rule's wording is not met, and M2 proceeded.
  Rationale: none of those runs is an at-risk-customer run, and
  `select count(*) from keiro.keiro_workflow_steps where step_name = 'classify'` is 0, so no
  journal can meet the removed labels. There is no local cancel for a parked run (FRIC-80),
  and the campaign run is not to be resumed. The commits before the pack move change no step
  shape. The user should confirm that the three parked runs are abandoned before EP-11's
  baseline gate.
  Date: 2026-11-16
- Decision: `BehaviorEnv.tasks` is a lookup function, `Text -> Maybe ProgramTask`, set with
  `withProgramTasks`, and `decisionServices` and `flowDeclarationErrors` live in
  `Shikigami.Flow.Pack`. The plan sketched `tasks :: FlowRegistry` and a `decisionServices` in
  `Shikigami.Flow.Decision`.
  Rationale: `Shikigami.Flow.Pack` imports `Shikigami.Flow`, which reaches
  `Shikigami.Behavior.Run` through `Shikigami.Flow.Routing`, so the registry type cannot appear
  in `BehaviorEnv` or `Flow.Decision` without a module cycle. The stub and provider
  constructors answer from the builtin tasks; production composition replaces the lookup.
  Date: 2026-11-16
- Decision: `FlowDef.lifecycle` stays a required `LifecycleDiagram`, not the `Maybe` of the
  plan's sketch, and `FlowDef` gains `decisionMode`.
  Rationale: every flow has a diagram today and `render-lifecycle` reads it; no consumer needs
  its absence. `decisionMode` comes from the representative check (see Surprises).
  Date: 2026-11-16
- Decision: The SDK names the sink capability `SinkCapability`, exports the effect vocabulary
  a pack capability needs (`Effect`, `Dispatch`, `DispatchOf`, `send`) and `Eff` and `(:>)`
  from `flow-sdk`, and `pack-sdk` also exports `liftIO`, `Error`, `StoreError` and
  `runTransactionNoRetry`. `Shikigami.Pack.Sdk` makes `Pack` a kernel namespace, added to
  `domainRoots` and `kernel.namespaces`.
  Rationale: the kernel's `Sink` effect and the `Sink` declaration a body constructs share a
  name across modules and cannot both be exported unqualified. A `bodies` sublibrary that
  depended on `effectful-core` to write a signature could import `IOE`, so the SDK re-exports
  what a body needs and the body depends on `flow-sdk` alone. The interpreter additions are
  what the probe's `Observe` interpreter imported.
  Date: 2026-11-16
- Decision: Every label of the moved body is renamed with the pack's prefix, not only
  `classify`: the memory keys (`examples-risk-history` and three more), the two sink keys and
  the acknowledgement step. The five declared steps leave `domain/shikigami/agent-run.keiro`.
  The golden inventory accepts a label that starts with `examples-` or with a kernel
  capability prefix (`recall-`, `remember-`, `emit-signal-`, `flow-`) followed by it.
  Rationale: the plan's rule is that every literal label of a pack flow starts with the pack's
  name, and ADR-1 forbids leaving four declared steps no runtime journals.
  Date: 2026-11-16
- Decision: The core's durable tests use `Shikigami.Fixture.AcknowledgementFlow` in
  `shikigami-core/test-postgres`, a copy of the old body under its old test-local labels,
  registered as flow `acknowledgement-fixture` in a `fixture` pack. `FlowLifecycleSpec` runs
  bodies through a test-local `SpikeFlow` record. The pure classification tests and the
  lifecycle tests moved into the pack's suite.
  Rationale: the tests exercise kernel machinery and may not depend on a pack. The agent name
  stays `at-risk-customer` because the seeded sink grant is keyed by it.
  Date: 2026-11-16
- Decision: `flow.selected` is logged from the workflow body, outside any step, so a resumed
  run logs it again.
  Rationale: the worker and the one-off command then share one line, and the line states
  which pack this process chose for this pass, which is true on a replay too.
  Date: 2026-11-16

- Decision: The fitness check is its own test module, `Shikigami.KernelBoundarySpec`, which
  reuses the `.cabal` parser that `PackageArchitectureSpec` now exports, instead of a group
  inside that module. Beyond the plan's violations it reports `UnreviewedKernelRoot` (the
  consistency assertion against `domainRoots` and the composition roots) and
  `PackWithoutTests`, and `EmptyNamespace` applies to every status so the closed map stays
  exact. The policy also records `sourceRoot`, and ADR 0129 takes the next free number (0123 is
  the kernel action vocabulary).
  Rationale: the rules are a pure function tested on synthetic inputs; a separate module keeps
  `PackageArchitectureSpec` about the seven packages.
  Date: 2026-11-16

- Decision: Stock role packages never depend on a pack. Each role library gains a
  `...With :: [FlowPack] -> ...` entry point. Only a *distribution* package composes packs: it
  holds executables and no library, and it may depend on role packages and packs. A pack
  package holds a library and tests and no executable. Packs are named `flow-pack-<name>` with
  modules under `FlowPack.<Name>`; no pack or distribution uses the `shikigami-` prefix.
  Rationale: This keeps the ADR-39 frozen source closure and its Nix outputs byte-identical, and
  keeps the "every executable links only its own package's library" rule of ADR-3 intact for
  the seven stock packages. Separating the distribution keeps a pack's dependency closure equal
  to the two SDK components, which the fitness check can then state as one rule. A pack in
  another repository composes exactly like an in-repository one. Packaging a distribution with
  Nix is a follow-up, not a gate. (Revised by the MasterPlan 22 review, 2026-11-15: the first
  draft let a pack ship its own executables.)
  Date: 2026-11-15
- Decision: The SDK is two public Cabal sublibraries. `shikigami-core:flow-sdk` re-exports
  `Shikigami.Flow.Sdk` and `Shikigami.Flow.Sdk.Program`: what a flow body and a pack value may
  import, with no `IOE` and no `Store`. `shikigami-core:pack-sdk` re-exports
  `Shikigami.Pack.Sdk`: what an interpreter needs (`IOE`, `Store`, the run read view
  `FlowRunContext`, logging) and, as later plans land, the kernel ports and the kernel modules a
  moved subsystem needs. A pack library may depend on these two and on no other Shikigami
  component. Each pack keeps its flow bodies in an internal `bodies` sublibrary that depends on
  `flow-sdk` alone.
  Rationale: GHC exposes only the modules of directly depended components, so the compiler
  enforces both the SDK and the body/interpreter split. The existing `shikigami-core:inspection`
  sublibrary is the precedent. `pack-sdk` is where 357 exposed modules become a reviewed API:
  whatever a pack needs from the kernel is added there deliberately, with a pinned export list.
  (Revised by the MasterPlan 22 review, 2026-11-15: the first draft had one component and gave
  packs no interpreter surface.)
  Date: 2026-11-15
- Decision: A pack flow is a body plus a pack-owned interpreter (`PackFlow`). The body is typed
  against the kernel capability row and the pack's own capabilities. The interpreter may use
  `IOE` and `Store`; the body may not. This plan amends ADR-13 to say so.
  Rationale: `FlowDef.run` is quantified over the fixed `FlowEffects` row, so a pack could only
  use capabilities already compiled into the core (see Surprises). The use-case capabilities
  (`Observe`, `Initiative`, the practice-review quartet) are journaled interpreters that need
  IO. ADR-13's guarantee, that a body cannot smuggle IO, is kept by the compiler through the
  `bodies` sublibrary; the reviewed interpreter is the only IO surface. EP-6's draft had this
  shape; it is defined here because it decides what the SDK exports.
  Date: 2026-11-15
- Decision: A `FlowPack` may contribute flows, decision programs, program tasks, extra workflow
  families, trigger hooks, output adapters, approval-channel adapters, admin CLI verbs and
  setting decoders. Each field lands with its first executed consumer. This plan lands flows,
  decision programs (with retained codecs) and tasks. EP-6 lands trigger hooks, admin verbs
  and setting decoders. EP-8 lands the two adapter fields. EP-10 lands workflow families, for
  the Danwa conversation family; EP-6 no longer needs that field, because the user decided on
  2026-11-15 that the adaptive-delivery coordinator stays in the kernel. A later plan
  extends `Shikigami.Flow.Pack.FlowPack` and records that in its own Decision Log.
  Rationale: ADR-1 forbids declaring a surface no runtime executes. Naming the full list here
  keeps one owner and one type while each field still arrives with a consumer.
  Date: 2026-11-15
- Decision: Before M2 is accepted, prove the pack flow shape against the watchdog: its flow
  body and its `Observe` capability compile and pass a unit test in a throwaway pack. The
  throwaway pack is not merged, and the watchdog does not move in this plan.
  Rationale: MasterPlan 22 names this representative check. The watchdog is the most demanding
  consumer (advisory decisions, a schedule allowance, a failure hook, eight labels). A shape
  proven only on at-risk-customer, whose body needs kernel capabilities alone, would be
  redesigned by EP-6.
  Date: 2026-11-15
- Decision: The kernel classification in `module-ownership.json` starts from MasterPlan 22's
  list, which EP-6 confirmed against imports, workflows, migrations and routes. `Router`,
  `Mandate*` and `RecurringObjective*` are kernel. `Coordination` is a kernel root with seven
  frozen coordinator modules. The statuses are `kernel`, `flow-pack` (EP-6 moves it) and
  `kikan-binding` (EP-10 moves it).
  Rationale: This plan's first draft listed `Router` as leaving and the mandate roots as
  undecided, which contradicted EP-6's traced result. Two classifications of one tree would
  drift.
  Date: 2026-11-15
- Decision: Move at-risk-customer into the first pack. It is the teaching example of
  `docs/user/flows.md`, and its body uses only SDK-level capabilities (`Workflow`, `Memory`,
  `Sink`, `Activity`, `Acknowledgement`). Its core durable tests are rewritten against a
  test-local fixture flow in `shikigami-core/test-postgres`, and its pure tests move into the
  pack.
  Rationale: The tests in `FlowLifecycleSpec` and `AgentWorkflowSpec` exercise kernel machinery
  (acknowledgement parks, deadlines, memory and sink journaling) and only use at-risk-customer as
  a vehicle. A core test may not depend on a pack.
  Date: 2026-11-15
- Decision: A pack flow's step and capability labels are owned by the pack, not declared in
  `domain/shikigami/agent-run.keiro`. Every literal label of a pack flow starts with the pack's
  name (for example `ledger-compare`, `examples-classify`, `watchdog-open`). When a flow leaves
  the core, its labels and its `patch` gates leave the core specification with it. The moved
  at-risk-customer flow renames `classify` to `examples-classify`, and `step classify` leaves
  the core declaration (ADR-1). The resulting `just keiro-diff` finding is accepted under the
  ADR-27 pre-release exception. Each pack ships a golden inventory of its labels in its own
  test suite.
  Rationale: Declaring a pack's labels in core would make every pack an edit to this repository,
  which defeats the MasterPlan's architectural acceptance test, and would leave every
  organizational use case in the kernel's durable contract at the baseline. No journal needs
  the old bytes or the patch gates before EP-11's baseline gate, because every run is drained
  first. The gap is that `keiro-diff` cannot see pack labels. The golden inventory makes a
  label change a reviewed diff in the meantime. The gap is recorded in the ADR and raised as an
  improvement request in `mori://shinzui/keiro` for declaring workflow fragments from separate
  packages. EP-6 follows the same rule for the flows it moves.
  Date: 2026-11-15
- Decision: `DecisionLabel` in `Shikigami.Flow.Decision` stays a closed sum in this plan. A pack
  can register decision programs and ShikumiProgram tasks, and a pack flow can use the existing
  kernel slot labels. A pack-defined slot label is deferred to EP-6.
  Rationale: No flow moved here makes a decision. ADR-1 says not to declare a surface no runtime
  executes. The change is small and known: carry a checked `DecisionSlotLabel` and a
  `DecisionAccounting` in `DecisionStep`, and derive the step names
  `decision-prepare-<label>` and `decision-result-<label>`, which are byte-identical for the six
  current labels.
  Date: 2026-11-15


## Outcomes & Retrospective

All three milestones are accepted (2026-11-16). The plan's purpose holds on this Mac:

- Adding a use-case namespace to `shikigami-core` fails `just kernel-fitness` with a message
  that names the declaration and pack routes (M1).
- A flow lives in a pack and runs from a distribution. `packs/flow-pack-examples` owns
  at-risk-customer, `shikigami-examples-agent-run` ran it on a real issue text, and the stock
  executables refuse its manifest before opening a session (M2).
- A pack and a distribution live in another repository. `shikigami-operator-packs` recorded
  HEAD observations of real checkouts with no change here (M3).

What the plan got right. Proving the shape on the watchdog first paid off before any
subsystem moved: the first-drafted `PackFlow.run` could not have hosted the `Observe`
interpreter, and the kernel knew the watchdog by name in three places. Two of those are now
declaration data or run context. Splitting bodies into a sublibrary makes ADR-13 a compiler
error instead of a review rule.

What differed from the plan.

- The registry could not be threaded as one value everywhere. `BehaviorEnv` carries a task
  lookup function, because the registry module depends on it (Decision Log).
- Five labels left the AgentRun declaration, not one, and every label of the moved body took
  the pack's prefix.
- The label inventory needs PostgreSQL, because keiro has no store-free interpreter of its
  workflow effect. IR-61 asks for one, together with pack-declared workflow fragments.
- The qualification fixture named the moved flow and moved with it.
- The external repository's commands set the database inside the shell (FRIC-82).

What remains for later plans.

- EP-6 moves the watchdog, the initiative and practice review. It inherits the probe's list
  of kernel modules for `pack-sdk`, the two by-name watchdog branches left in
  `runFlowDefinition`, the `shikigami-watchdog-v1` gate (which needs `patch` in `flow-sdk`),
  the eight use-case members of `FlowEffects`, and the open `DecisionLabel`.
- A worker composed with packs does not exist yet. Until EP-6 creates one, the durable
  approval scenario of plan 79 cannot be qualified, and pack flows run from the one-off
  command only.
- The development database holds three parked agent runs. They cannot meet the removed
  labels, but the user should confirm they are abandoned before EP-11's baseline gate.
- `shikigami-operator-packs` is unregistered and unpushed. Whether to keep it, register it
  with Mori and give it a development shell of its own is the user's call.


## Context and Orientation

Shikigami is a Haskell service that runs declared agents. An agent is a Dhall file (for example
`agents/heartbeat.dhall`) whose `behavior` field selects how the agent works. The `Flow` arm,
`Behavior.Flow { name = "at-risk-customer" }`, names a compiled Haskell function. That function
runs inside the durable `AgentRun` workflow of the keiro workflow engine. *Durable* means each
named `step` is journaled in PostgreSQL. After a crash the body is replayed, and journaled
steps are answered from the journal instead of running again.

The repository has seven Cabal packages, listed in `cabal.project` and described in
`docs/architecture/packages.md`. `shikigami-core` is the domain library. `shikigami-agent` holds
the light one-off commands (`shikigami-run-behavior`, `shikigami-agent-run`), and
`shikigami-workers` holds the background loops (`shikigami-worker` and others).
`shikigami-server` holds the HTTP server and the administrative `shikigami` command, which
includes `validate` and `render-lifecycle`. `shikigami-api`, `shikigami-client` and
`shikigami-migrations` complete the set.

Three compiled-in registries, and the consumers of the first, matter here:

- `Shikigami.Flow.flowRegistry :: [FlowDef]`, in `shikigami-core/src/Shikigami/Flow.hs`, lists
  ten flows. A `FlowDef` has the fields `name`, `lifecycle`, `decisionSlots`,
  `requiresDefaultModel` and `run :: forall es. FlowEffects es => Value -> Eff es Value`. The
  functions `lookupFlow`, `registeredFlowNames` and `flowDeclarationErrors` read the global list.
- `flowRegistry` is consumed in several places. `Shikigami.Agent.Workflow` calls
  `Flow.lookupFlow` in `usesDefaultModel`, `behaviorEnvForProfile` and `runFlowBehavior`. The
  worker's boot check `refuseUndeployableAgents`
  (`shikigami-workers/src/Shikigami/Workers/Command/Worker.hs`), `shikigami validate`
  (`shikigami-server/src/Shikigami/Server/Command/Validate.hs`) and `render-lifecycle`
  (`.../Command/RenderLifecycle.hs`) also read it.
- `Shikigami.Program.Decision.Registry` defines `decisionPrograms` and `decisionCodecs`, the
  typed decision programs. `Shikigami.Flow.Decision.defaultDecisionServices` uses them, and it is
  called by `shikigami-agent/src/Shikigami/Agent/Command/AgentRun.hs` and the worker.
- `Shikigami.Program.Registry.programRegistry :: [ProgramTask]` holds the tasks of the
  `ShikumiProgram` behavior (`noop-summary`, `web-researcher`, `code-researcher`).
  `Shikigami.Behavior.Run.runBehavior` reaches it through `lookupTask`.

The durable composition record is `AgentRunDeps` in `shikigami-core/src/Shikigami/Agent/Workflow.hs`.
It is built by `runDurableAgent` in `AgentRun.hs` (one-off) and by `agentRunDeps` in
`shikigami-workers/src/Shikigami/Workers/Config.hs`, from `WorkerEnv`.

`tools/style/module-ownership.json` is the closed module budget of ADR-75. It holds
`domainRoots`, the 56 concept namespaces of all packages, and `compositionModules`, the reviewed
wiring modules. `tools/style/module_ownership.py` checks it under `just haskell-conventions`.
The check is per namespace root and repository-wide: it does not know packages and does not
distinguish a kernel root from a use case. `shikigami-core/test/Shikigami/PackageArchitectureSpec.hs`
parses the `.cabal` files as text and enforces the legal arrows between the seven packages. Its
package list comes from `declaredProjectPackages`, which keeps only `cabal.project` lines
starting with `shikigami-`, so it cannot see a pack either. Today
`shikigami-core/src/Shikigami/` has 63 top-level namespaces (distinct first module segments,
generated-only roots included) and 78,094 lines.

Relevant ADRs:

- [ADR-3](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md): `shikigami-agent`
  links no Kafka, PGMQ or OTLP stack. Every executable links only its own package's library. A
  pack's composed agent-run must stay light, and stock executables must not grow pack edges.
- [ADR-13](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md): a flow body
  reaches the world only through replay-safe capabilities, and `FlowEffects` grants nothing else.
  This plan amends it: a pack's reviewed interpreter may use `IOE` and `Store`, and its flow
  body may not. The amendment is a dated note in ADR-13 that points at this plan's ADR.
- [ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) and
  `docs/workflow-versioning.md`: until the first release or deployment, unreleased workflow and
  declaration shapes may be replaced directly. The facts must be rechecked and recorded, and
  `just keiro-gate` must still run.
- [ADR-38](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md): each runtime
  validates its owners once at startup and refuses on failure. Registry composition follows
  this: it is checked once at boot and refuses on duplicates.
- [ADR-39](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md): runtime roles
  are built from one frozen Cabal solve exported to `nix/qualification/cohort.json`. This plan
  leaves that closure unchanged (see the Decision Log).
- [ADR-75](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md): the closed
  module budget. This plan amends it with the kernel section, which is a new check beside the
  root budget rather than an extension of it.
- [ADR-80](../adr/0080-opaque-checked-values-do-not-expose-generic-construction.md),
  [ADR-81](../adr/0081-validated-results-use-private-seals-and-public-read-views.md) and
  [ADR-97](../adr/0097-program-registration-values-retain-scoped-identity-and-parameter-contracts.md):
  checked newtypes with private constructors, sealed validated results with read views, and
  program registration identity. `FlowPackName` and `FlowRegistry` follow them.

The cross-repository standards are `mori://shinzui/keiro-runtime-patterns/docs/architecture-service-packages`,
`mori://shinzui/keiro-runtime-patterns/docs/architecture-cross-cutting-modules` and the record
guide `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`: record fields are unprefixed
under `DuplicateRecordFields`.

Terms used below:

- A *pack* is a Cabal library package that depends on `shikigami-core:flow-sdk` and
  `shikigami-core:pack-sdk` only and exports one `FlowPack` value.
- A *flow body* is the replay-safe function of a flow. A *pack-owned interpreter* is the
  reviewed code that gives the body's pack capabilities their journaled meaning.
- A *distribution* is a package of executables whose `main` passes packs to a role's `...With`
  entry point. MasterPlan 22 names two: the stock composition (the seven `shikigami-*`
  packages, which compose no pack) and the Kikan distribution `kikan-shikigami`, which EP-6
  creates and EP-10 (`docs/plans/135-move-the-kikan-service-bindings-out-of-shikigami-core-and-compose-a-kikan-distribution.md`)
  extends. This plan creates the small `examples-distribution`.
- The *builtin pack* is the set of flows, programs and tasks still compiled into the core. EP-6
  dissolves it.
- The *baseline gate* is EP-11
  (`docs/plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md`).
  The ADR-27 pre-release exception ends there, not at the first real run. Until then every run
  is drained to a terminal state before a workflow or declaration shape changes.


## Plan of Work

**M1: the kernel fitness check.** Add a `kernel` section to `tools/style/module-ownership.json`.
This is a new check. It sits beside the ADR-75 root budget, which cannot express it (see
Surprises). It is a closed map from every top-level namespace directory or file under
`shikigami-core/src/Shikigami/` to one of three statuses: `kernel`, `flow-pack` (EP-6 moves it
to a pack) or `kikan-binding` (EP-10 moves it to the Kikan binding package). The
`frozenModules` list then names every module that lives in a non-kernel namespace, or that is
a use-case or binding module inside a kernel namespace. The initial classification is
MasterPlan 22's, which EP-6 traced through imports, workflows, migrations and routes:

- **Kernel:** agent runs, execution, objectives, approvals, resources, memory, workspaces,
  capabilities, authority, worker sessions, the output and trigger mechanisms and
  composition. That is Action, Activity, AdaptiveDelivery (generated from the kernel-owned
  adaptive-delivery specification only), Agent, AgentRun, App, Approval, Attestation,
  Behavior, Capability, ContinuingWorker, Coordination, Decision, Delegation, Diagrams,
  Directory, Duration, Execution*, Flow, FormatVersion, Generated, Health, Inspection,
  Integration, Log, Mandate, MandateLifecycle, MandateLookup, Memory, Objective*, Prelude,
  Program, ProjectionCatalog, RecurringCheckpointCycle, RecurringObjective, Repository,
  Router, RunEvidence*, RunJobs, Runtime, RuntimePolicy, Sink, StateRevision, Telemetry,
  Trigger, WorkerSession*, Workflow and Workspace. `Router`, the mandate roots and the
  recurring-objective roots are coordination primitives that other features build on.
- **Flow pack:** Initiative, PracticeReview and Watchdog.
- **Kikan binding:** DanwaConversation.

Inside kernel roots, the frozen modules are:

- Flow-pack material:
  `Shikigami.Flow.{AtRiskCustomer, Lifecycle.AtRiskCustomer, Initiative, ObjectiveExample, Observe, OpenTelemetryPracticeReview, ShikumiDecisionExample, ShikumiJudgmentExample, Watchdog}`
  and `Shikigami.Program.Decision.{Drift, Examples, Initiative, JudgmentExample}`.
  The adaptive-delivery coordinator is kernel and is not frozen: all of
  `Shikigami.Coordination`, `Shikigami.Flow.AdaptiveDelivery` and
  `Shikigami.Program.Decision.Adaptive` stay, by the user's decision of 2026-11-15, because
  the coordinator has no Kikan service dependency.
  `Shikigami.Flow.Routing` stays kernel; only its `architecture-practice-router` flow is
  use-case code, and EP-6 moves that flow.
- Kikan-binding material: the per-service clients under `Shikigami.Sink`
  (`KawaClient`, `KizashiClient`, `Danwa`, `KanmonClient`, `ReiAction`), the Kikan-En
  authorizer construction in `Shikigami.Action.Authorization`, the Meibo directory source and
  the Rei adapter under `Shikigami.Objective.Tracker`. The implementer lists the exact module
  names from the tree. EP-10 confirms or corrects this group, as EP-6 does for the first.

The empty `Id` and `Store` directories are deleted. Freezing means only that no new module may
join a frozen group; nothing moves in M1.

```json
"kernel": {
  "package": "shikigami-core",
  "decision": "docs/adr/0129-the-kernel-owns-primitives-and-use-cases-ship-as-declarations-or-packs.md",
  "namespaces": { "Agent": "kernel", "Mandate": "kernel", "Watchdog": "flow-pack", "DanwaConversation": "kikan-binding" },
  "frozenModules": ["Shikigami.Flow.AtRiskCustomer", "Shikigami.Watchdog.Sweep", "Shikigami.Sink.KawaClient"],
  "sdkModules": {
    "flow-sdk": ["Shikigami.Flow.Sdk", "Shikigami.Flow.Sdk.Program"],
    "pack-sdk": ["Shikigami.Pack.Sdk"]
  }
}
```

The excerpt shows the shape only. The implementer generates the full lists from the tree once,
with `find shikigami-core/src/Shikigami -name '*.hs'`, and reviews each entry. In
`PackageArchitectureSpec.hs`, add a `kernel boundary` test group whose rules are a pure
function. That makes each rule testable on synthetic inputs as well as on the real tree:

```haskell
data NamespaceStatus = Kernel | LeavingToPack | LeavingToBinding
  deriving stock (Eq, Show)

data KernelPolicy = KernelPolicy
  { namespaces :: !(Map Text NamespaceStatus),
    frozenModules :: !(Set Text),
    sdkModules :: !(Map Text [Text]),        -- SDK component -> pinned re-export list
    decision :: !FilePath
  }

data PackagesKind = PackPackage | DistributionPackage   -- every package under packs/ is one

data KernelViolation
  = UnknownNamespace !Text !FilePath         -- a new top-level root in core
  | UnfrozenModule !Text !NamespaceStatus    -- a new module under a non-kernel root
  | StaleFrozenModule !Text                  -- listed but deleted: the list must shrink
  | EmptyNamespace !Text                     -- a non-kernel root with no modules left
  | StockDependsOnPack !Text !Text           -- (stanza of one of the seven, pack or distribution)
  | PackEscapesSdk !Text !Text               -- (pack library, forbidden Shikigami dependency)
  | BodyEscapesFlowSdk !Text !Text           -- (pack bodies sublibrary, anything but flow-sdk)
  | PackShipsExecutable !Text                -- a pack package with an executable stanza
  | PrefixedOutOfCorePackage !Text           -- a packs/ package named shikigami-*
  | SdkExportsDrifted !Text                  -- reexported-modules differ from the pinned list

kernelViolations :: KernelPolicy -> [FilePath] -> [KernelViolation]
renderKernelViolation :: KernelPolicy -> KernelViolation -> Text
```

`UnknownNamespace` renders the message that does the steering:

```text
shikigami-core/src/Shikigami/Campaign/Plan.hs: Shikigami.Campaign is not a kernel namespace.
  shikigami-core owns primitives only (docs/adr/0123-...).
  Ship a use case as a declaration under agents/ (a skill or a playbook), or as a flow pack
  under packs/ that depends only on shikigami-core:flow-sdk (docs/user/flows.md#flow-packs).
  A genuine new primitive needs an ADR and a "kernel" entry in tools/style/module-ownership.json.
```

The test walks the directory rather than the `exposed-modules` list, so a planted file fails
even before anyone lists it in the `.cabal` file. M1 already includes the pack rules, which are
vacuous until M2 creates `packs/`. The test finds packages by walking `packs/*/*.cabal`, not
through `declaredProjectPackages`, whose `shikigami-` filter must keep reporting exactly seven.
First, no stanza of the seven packages may depend on a package found under `packs/`. Second, a
pack's main library may depend on no Shikigami component except `shikigami-core:flow-sdk` and
`shikigami-core:pack-sdk`, and it obeys `forbiddenInLightPackages`. Third, a pack's `bodies`
sublibrary may depend on no Shikigami component except `shikigami-core:flow-sdk`; this is the
per-pack architecture test that keeps `IOE` and `Store` out of flow bodies. Fourth, a pack
package has no executable, and only a distribution package (executables, no library) may
depend on both a role package and a pack. Fifth, no package under `packs/` is named
`shikigami-*`. Sixth, every pack ships a test suite. Finally, add a consistency assertion: every `kernel` key is in `domainRoots`
or is a composition root, so the two lists cannot drift apart. Add a
`just kernel-fitness` recipe that runs the group.

Also in M1, write the ADR, `docs/adr/0129-the-kernel-owns-primitives-and-use-cases-ship-as-declarations-or-packs.md`.
Use the next unused number if another MasterPlan 22 child has taken 0123. It states that the
kernel owns primitives; that use cases ship as declarations or out-of-core packs; that a pack
depends only on `flow-sdk` and `pack-sdk`; that a pack flow is a body plus a pack-owned
interpreter and only the interpreter may use IO; that registries are composed by executables;
that stock roles compose only the builtin pack and only a distribution composes packs; and
that the kernel list is closed and only shrinks. It states that the ADR-3 and ADR-39
consequences are preserved, and it records the pack-label rule and the `keiro-diff` gap. It
amends ADR-75 (the kernel section is a new check beside the root budget) and ADR-13 (the
interpreter/body split), and adds a dated pointer to each. EP-6's first draft owned the ADR-13
amendment; MasterPlan 22 moved it here with the pack API.

**M2: the pack API, the two SDK components and the first pack.** In `shikigami-core`, add the
module `Shikigami.Flow.Pack`. It is a kernel module inside the kernel `Flow` root, and it is
the one definition of the pack API for MasterPlan 22.

```haskell
-- | A pack's checked name: lowercase ASCII words joined by '-', 1..64 bytes.
newtype FlowPackName = FlowPackName Text            -- constructor not exported (ADR-80)
  deriving stock (Eq, Ord, Show)

data FlowPackNameError = EmptyFlowPackName | MalformedFlowPackName !Text
  deriving stock (Eq, Show)

parseFlowPackName :: Text -> Either FlowPackNameError FlowPackName
flowPackNameText :: FlowPackName -> Text

data FlowPack = FlowPack
  { name :: !FlowPackName,
    flows :: ![PackFlow],
    decisionPrograms :: ![SomeProgram],
    retainedCodecs :: ![SomeResultCodec],   -- ADR-45: codecs outlive retired programs
    tasks :: ![ProgramTask]
    -- Later fields, each added by the plan that first executes it (ADR-1):
    --   triggers, adminVerbs, settings              (EP-6)
    --   outputs, approvalChannels                   (EP-8)
    --   workflows                                   (EP-10, the Danwa conversation family)
  }

-- | A flow's declaration data. This is today's FlowDef without its `run` field.
data FlowDef = FlowDef
  { name :: !(DeclarationCoordinate "flow"),
    lifecycle :: !(Maybe LifecycleDiagram),
    decisionSlots :: ![DecisionSlot],
    requiresDefaultModel :: !DefaultModelRequirement
  }

-- | A body plus the pack-owned interpreter that runs it. `run` is the only place a pack may
-- use IOE and Store. It is built as `\ctx -> interpretMine runtime ctx . body`, where `body`
-- lives in the pack's `bodies` sublibrary and is typed
-- `(FlowEffects es, MyCapability :> es) => Value -> Eff es Value`.
data PackFlow = PackFlow
  { definition :: !FlowDef,
    run :: !(forall es. (FlowEffects es, IOE :> es, Store :> es) => FlowRunContext -> Value -> Eff es Value)
  }

-- | A flow whose body needs only kernel capabilities, so it has no interpreter of its own.
kernelCapabilityFlow :: FlowDef -> (forall es. FlowEffects es => Value -> Eff es Value) -> PackFlow

-- | The read view the kernel builds once per run. A pack interpreter reads the run from here
-- and never reaches into RunJob or AgentRunDeps.
data FlowRunContext = FlowRunContext
  { agent :: !AgentDecl, identity :: !ResolvedAgentIdentity, session :: !SessionId,
    runId :: !WorkflowId, occurredAt :: !UTCTime, activity :: !Activity,
    executionRoot :: !(Maybe ExecutionRootId), directory :: !DirectoryHandle,
    declarations :: ![AgentDecl]
  }

-- | Sealed: names are unique across packs and the decision registries validated (ADR-81).
data FlowRegistry

data RegisteredFlow = RegisteredFlow
  { pack :: !FlowPackName,
    flow :: !PackFlow
  }

data FlowRegistryError
  = DuplicatePackName !FlowPackName
  | DuplicateFlowName !(DeclarationCoordinate "flow") !FlowPackName !FlowPackName
  | DuplicateTaskName !Text !FlowPackName !FlowPackName
  | DecisionProgramsRejected !DecisionFailure
  | ResultCodecsRejected !DecisionFailure
  deriving stock (Show)

composeFlowRegistry :: [FlowPack] -> Either (NonEmpty FlowRegistryError) FlowRegistry
registeredFlows :: FlowRegistry -> [RegisteredFlow]
lookupFlow :: FlowRegistry -> DeclarationCoordinate "flow" -> Maybe RegisteredFlow
lookupTask :: FlowRegistry -> Text -> Maybe ProgramTask
decisionProgramRegistry :: FlowRegistry -> ProgramRegistry
resultCodecRegistry :: FlowRegistry -> ResultCodecRegistry
flowDeclarationErrors :: FlowRegistry -> AgentDecl -> [Text]

-- | Compose at process start (ADR-38). It logs flow.registry.composed with each pack and its
-- flows, or logs flow.registry.rejected and exits non-zero.
composeFlowRegistryOrExit :: Log.Logger -> Text -> [FlowPack] -> IO FlowRegistry
```

`FlowEffects` keeps its 18 members in this plan; EP-6 removes the 8 use-case members as their
subsystems leave, after which it is the kernel capability row. `runFlowBehavior` builds the
`FlowRunContext`, installs the kernel interpreters and calls `PackFlow.run`; a pack's own
capabilities are discharged inside `run`, before the kernel stack, so the kernel never names
them. The builtin flows are wrapped with `kernelCapabilityFlow`, which keeps their step shapes
byte-identical.

**The representative check comes before the rest of M2.** On a scratch branch, create a
throwaway pack `packs/flow-pack-probe`. Copy the watchdog flow body
(`shikigami-core/src/Shikigami/Flow/Watchdog.hs`) into its `bodies` sublibrary and the
`Observe` capability with its interpreter (`shikigami-core/src/Shikigami/Flow/Observe.hs`) into
its main library. The body must compile against `(FlowEffects es, Observe :> es)` with no
`IOE` or `Store` in scope, and the `PackFlow.run` built from the interpreter must type-check.
One unit test runs the body over an `ObserveSeed` that returns a fixed observation page and
asserts the labels it journals. Record three things in Surprises & Discoveries: the kernel
modules the probe had to import (the first candidates for `pack-sdk`; EP-6 lists the expected
ones per subsystem), anything the shape could not express, and how the body obtains what
`runFlowBehavior` gives the watchdog by name today (the advisory decision interpreter and the
sweep-failure hook). If the shape cannot express the watchdog, change the shape now. Do not
merge the probe, and do not move the watchdog; EP-6 does that.

Move the current list out of `Shikigami.Flow` into a new module
`Shikigami.Flow.Builtin (builtinPack, builtinFlowRegistry)`, which is a frozen module. The
builtin pack carries the flows, the six decision programs and their codecs, and the three
ShikumiProgram tasks. `builtinFlowRegistry` composes `[builtinPack]` and errors at construction
on failure, the same pattern `decisionPrograms` uses today, so tests stay concise. In
`Shikigami.Flow`, keep `FlowDef`, `FlowEffects`, `FlowRuntime`, `LifecycleDiagram` and
`flowDecisionSlotsFor`, and delete the global `flowRegistry`, `lookupFlow` and
`registeredFlowNames`.

Thread the registry as data:

- Add a `flows :: !FlowRegistry` field to `AgentRunDeps`. Change the three `Flow.lookupFlow`
  sites in `Shikigami.Agent.Workflow` to `lookupFlow deps.flows`. This changes a workflow body
  under `Agent/`. The lookup is pure and sits outside any step, so no step shape changes. Still
  run the gate (see Concrete Steps).
- Replace `defaultDecisionServices` with
  `decisionServices :: FlowRegistry -> ModelCatalog -> DecisionServices`, and rename the
  test-only helper to `builtinDecisionServices`. This makes a production site that forgot to
  compose visible in review.
- Add a `tasks :: !FlowRegistry` field to `BehaviorEnv` in `Shikigami.Behavior.Run`, so
  `runBehavior` uses `lookupTask env.tasks`. `newBehaviorEnv*` defaults it to
  `builtinFlowRegistry`, and production composition sets it with `& #tasks .~ registry`.

Add the composition entry points, each prepending `builtinPack` to the packs it receives:

```haskell
-- shikigami-agent: Shikigami.Agent.Command
agentRunRoleInfoWith :: [FlowPack] -> RoleInfo
agentRunRoleInfo = agentRunRoleInfoWith []

-- shikigami-workers: Shikigami.Workers.Command (WorkerEnv gains flows :: !FlowRegistry)
workerRoleInfoWith :: [FlowPack] -> RoleInfo
workerRoleInfo = workerRoleInfoWith []

-- shikigami-server: Shikigami.Server.Command
runAdminWith :: [FlowPack] -> IO ()
runAdmin = runAdminWith []
```

`shikigami-agent-run` gains three changes:

- It accepts `--payload JSON|-` and `--stdin`, reusing `Shikigami.Agent.Payload.payloadArgument`.
  The value becomes `RunJob.triggerPayload`.
- It runs `flowDeclarationErrors` before running and refuses with the composed flow names.
- It logs `flow.selected` (fields `agent`, `flow`, `pack`) for a Flow behavior, and prints
  `output <json>` from `AgentRunResult.behaviorOutput`.

`validate`, `render-lifecycle` and the worker boot check read the composed registry. Add an
admin subcommand `shikigami flows` in a new composition module, `Shikigami.Server.Command.Flows`,
listed in `compositionModules`. It prints one line per flow with its pack, its default-model
requirement and its decision slot labels.

Add the two SDK components. A new `library flow-sdk` stanza with `visibility: public` in
`shikigami-core/shikigami-core.cabal` depends on `base` and `shikigami-core` and has
`reexported-modules: Shikigami.Flow.Sdk, Shikigami.Flow.Sdk.Program`. A new `library pack-sdk`
stanza, also public, has `reexported-modules: Shikigami.Pack.Sdk`. All three facades live in
the main library and have explicit export lists. `Shikigami.Flow.Sdk` is what a flow body and
a pack value may import. It re-exports the following, and nothing else:

- `FlowPack (..)`, `PackFlow (..)`, `kernelCapabilityFlow`, `FlowPackName`,
  `parseFlowPackName`, `FlowDef (..)`, `FlowEffects`, `LifecycleDiagram (..)` and
  `DefaultModelRequirement (..)`.
- `DeclarationCoordinate`, `declarationCoordinate` and `declarationCoordinateText`.
- The capability operations, without their interpreters: `Memory`, `MemoryQuery (..)`,
  `recall`, `remember`, `Sink`, `emitSignal`, `Activity`, `currentActivity`, `Acknowledgement`,
  `Ack (..)`, `awaitAck`, `Delegate`, `delegate` and `awaitOne`.
- The declaration vocabulary those operations take: `Agent.Sink (..)`, `Priority (..)`,
  `SignalType (..)`, `RecipientFrom (..)`, `ApprovalRequest (..)`, `ApprovalChannel (..)`,
  `ActivityEnvelope (..)`, `Subject (..)`, the activity coordinates and `parseSignalImportance`.
- From `Keiro.Workflow`: `Workflow`, `step` and `StepName (..)`.

`Shikigami.Flow.Sdk.Program` re-exports `ProgramTask (..)`, `BehaviorInput (..)`,
`SomeProgram (..)`, `SomeResultCodec`, `registerProgram`, `retainedCodec` and `programRef`.
`Shikigami.Pack.Sdk` is what an interpreter may import in addition. In this plan it
re-exports `IOE`, `Store` and its transaction runner, `FlowRunContext (..)`, `interpret` and
`reinterpret` from effectful, and `Shikigami.Log`. It then grows by reviewed additions only:
EP-8 adds the kernel ports (`Shikigami.Authority`, `Shikigami.Record`, `Shikigami.Output`,
`Shikigami.Approval.Channel`, `Shikigami.Trigger`), and EP-6 adds the kernel modules each moved
subsystem needs, listed per milestone in its plan. An addition is either a name in the facade
or a whole kernel module appended to the stanza's `reexported-modules`; modules that packs
import qualified are re-exported whole. Both kinds are pinned in `sdkModules`. Nothing is added
for a consumer that does not exist yet.

Pin the module names of both components in `sdkModules`, and have `PackageArchitectureSpec`
check that each stanza's `reexported-modules` equals its list (`SdkExportsDrifted`). Also keep
a golden file of each facade's export list in `shikigami-core/test/golden/sdk/`, so adding a
name to the SDK is a reviewed diff. EP-11 reuses these two checks as the SDK's compatibility
check at the baseline gate.

Create `packs/flow-pack-examples/` and add it to `cabal.project` `packages:`. It contains the
following, and its Dhall manifest moves from `agents/detectors/` and imports
`../../../schema/Agent.dhall`:

```text
packs/flow-pack-examples/
  flow-pack-examples.cabal         library bodies (deps: base, aeson, text, kioku-api,
                                                   shikigami-core:flow-sdk)
                                   library (deps: + flow-pack-examples:bodies,
                                            shikigami-core:pack-sdk)
                                   test-suite flow-pack-examples-test
  bodies/FlowPack/Examples/Body/AtRiskCustomer.hs    (moved from Shikigami.Flow.AtRiskCustomer)
  src/FlowPack/Examples.hs         examplesPack :: FlowPack   (kernelCapabilityFlow)
  src/FlowPack/Examples/Lifecycle/AtRiskCustomer.hs  (moved keiki lifecycle; adds keiki deps)
  agents/at-risk-customer-flow.dhall
  test/Main.hs                     classifyRisk cases, lifecycle warnings, mermaid golden,
                                   composeFlowRegistry [builtinPack, examplesPack] succeeds,
                                   a duplicate pack name is refused, and the golden label
                                   inventory test/golden/labels.txt matches
packs/examples-distribution/
  examples-distribution.cabal      executable shikigami-examples-agent-run
                                     (deps: base, flow-pack-examples, shikigami-agent)
                                   executable shikigami-examples
                                     (deps: base, flow-pack-examples, shikigami-server)
  app/agent-run/Main.hs            main = runRole (agentRunRoleInfoWith [examplesPack])
  app/admin/Main.hs                main = runAdminWith [examplesPack]
```

The golden label inventory is the pack's stand-in for `keiro-diff`, which cannot yet see labels
declared outside the core specification. It lists every literal step and capability label the
pack's flows journal, one per line and sorted; here that is `examples-classify` and the
`recall-`, `remember-` and `emit-signal-` labels the body's capability calls build. The test
derives the list by running each flow over recording interpreters and compares it to the file,
and it also asserts that every label starts with the pack's name or with a kernel capability
prefix followed by the pack's name. Changing a label is then a reviewed diff in the pack. File
the improvement request in `mori://shinzui/keiro` for declaring workflow fragments from
separate packages, and cite its handle in the ADR once allocated.

The pack modules use the `FlowPack.*` namespace, not `Shikigami.*`. They are outside the core
and outside `module_ownership.py`'s concept roots. The move also makes these core changes:

- `shikigami-core.cabal` loses the two modules, and both leave `frozenModules`. That is the
  list shrinking.
- `Shikigami.Diagrams` drops the at-risk diagram. Regenerate the atlas with
  `just domain-diagrams`.
- `step classify -> RiskVerdict` leaves `domain/shikigami/agent-run.keiro`, and the moved body
  journals `examples-classify`.
- The core tests that used at-risk-customer as a vehicle (`FlowLifecycleSpec`,
  `AgentWorkflowSpec`, `BehaviorInputSpec` and the `shikigami-core-diagrams-test` golden) get a
  test-local acknowledgement fixture flow in `shikigami-core/test-postgres`. They pass it
  through a test registry, `composeFlowRegistry [builtinPack, fixturePack]`.
- The sink seed grant `at-risk-customer` in `Shikigami.Sink.Permission.defaultGrantTable` stays.
  It is migration seed data keyed by agent name, not code.

Update `docs/user/flows.md`: replace "register it in `Shikigami.Flow.flowRegistry`" with a
"Flow packs" section that walks through this pack. Update `docs/architecture/packages.md`: add a
"Flow packs" section with the legal arrows `pack bodies -> shikigami-core:flow-sdk`,
`pack -> shikigami-core:{flow-sdk, pack-sdk}` and `distribution -> packs and roles`, and say
that none of the seven may depend on a pack or a distribution. This revises the
document that plan 36 owns.

**M3: a pack in another repository.** Create the local Git repository
`/Users/shinzui/Keikaku/bokuno/shikigami-operator-packs`. Its intended Mori URI is
`mori://shinzui/shikigami-operator-packs`, and it is not pushed unless the user asks. It holds
two packages: the pack `flow-pack-repository-ledger`, whose library depends on
`shikigami-core:flow-sdk` and `shikigami-core:pack-sdk`, and the distribution
`operator-distribution`, whose executable `operator-agent-run` depends on the pack and
`shikigami-agent`. Its `cabal.project` is generated by `just sync-cohort`. The recipe writes a
`packages:` block, made of the two packages plus
`../shikigami/shikigami-core`, `../shikigami/shikigami-migrations` and
`../shikigami/shikigami-agent`. It then appends this repository's `cabal.project` with its
`packages:` and `optional-packages:` blocks removed, so the constraints, `index-state`, pinned
`source-repository-package` stanzas, flags and `allow-newer` are identical. Rerun it when the
cohort moves.

The flow uses only the SDK and makes no model call
(`requiresDefaultModel = DefaultModelOptional`):

```haskell
-- bodies/FlowPack/RepositoryLedger/Body.hs
data Observation = Observation { repository :: !Text, head :: !Text, branch :: !Text }
  deriving stock (Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

data LedgerResult = LedgerResult
  { observation :: !Observation, previousHead :: !(Maybe Text), movement :: !Movement }
data Movement = FirstObservation | Unchanged | Moved   -- a closed sum, not a Bool

repositoryLedger :: (Workflow :> es, Memory :> es) => Value -> Eff es Value
-- recall "ledger-prior" for this repository, step "ledger-compare" (pure), remember
-- "ledger-observed" with the Observation, return the LedgerResult as JSON. Every label
-- starts with the pack's name, "ledger", and the pack ships its golden label inventory.

-- src/FlowPack/RepositoryLedger.hs
ledgerPack :: FlowPack   -- name "ledger", one kernelCapabilityFlow "repository-ledger"
```

The agent manifest `agents/repository-ledger.dhall` imports
`../../shikigami/schema/Agent.dhall`.


## Concrete Steps

Run everything from `/Users/shinzui/Keikaku/bokuno/shikigami` inside `nix develop`, unless a
step says otherwise. For M1, after editing the JSON and the spec:

```bash
cabal test shikigami-core-test --test-options='-p "/kernel boundary/"'
mkdir -p shikigami-core/src/Shikigami/Campaign
printf 'module Shikigami.Campaign.Plan where\n' > shikigami-core/src/Shikigami/Campaign/Plan.hs
cabal test shikigami-core-test --test-options='-p "/kernel boundary/"'   # must fail
rm -r shikigami-core/src/Shikigami/Campaign
cabal test shikigami-core-test --test-options='-p "/kernel boundary/"'   # passes again
just haskell-conventions
```

The failing run prints the `UnknownNamespace` message from the Plan of Work. Repeat the check
once with `shikigami-core/src/Shikigami/Watchdog/Extra.hs` and expect `UnfrozenModule`, then
delete that file.

Before M2 touches `Shikigami.Agent.Workflow`, `Shikigami.Flow` or `domain/`, recheck the
pre-release facts and record them in the Decision Log with the date:

```bash
git tag --list                       # expect no output: nothing has been released
grep -n "first-release baseline exception" docs/workflow-versioning.md
grep -n "exception ended" docs/masterplans/22-*.md   # EP-11 records it there at the baseline gate
shikigami --config config.json runs --help            # use the listed verbs: no non-terminal AgentRun
base=$(git rev-parse HEAD)           # record this hash in the plan
```

MasterPlan 22 ends the exception at EP-11's baseline gate, not at the first real run. Until
then the rule is the drain rule: every run, including EP-7's campaign runs, is in a terminal
state before a workflow or declaration shape change lands. If a non-terminal run exists, let
it finish or have the operator abandon it, then proceed. If EP-11 has recorded the end of the
exception, stop: the `classify` removal then needs `patch` handling under
`docs/workflow-versioning.md`. After M2's edits, run the checks below. `just keiro-gate`
should report only the recorded removal of `classify` as BREAKING, and that finding is
accepted under ADR-27. Paste its diagnostic into Surprises & Discoveries.

```bash
just keiro-gate "$base"
cabal build all
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-core-diagrams-test \
  shikigami-agent-test shikigami-workers-test shikigami-server-test flow-pack-examples-test
just kernel-fitness
just domain-diagrams && git diff --stat docs/
just user-docs-validate
```

For the M2 real run on this Mac, start PostgreSQL in another terminal with `process-compose up`,
then:

```bash
just migrate
cabal run shikigami-examples -- flows
payload=$(gh issue list -R shinzui/keiro --state all --limit 1 --json body \
  | jq -c '{text: .[0].body}')
cabal run shikigami-examples-agent-run -- \
  --agent packs/flow-pack-examples/agents/at-risk-customer-flow.dhall --payload "$payload"
cabal run shikigami-agent-run -- \
  --agent packs/flow-pack-examples/agents/at-risk-customer-flow.dhall --payload "$payload"
```

Expected output, shortened:

```text
examples  at-risk-customer             default-model=required  slots=-
builtin   watchdog-sweep               default-model=optional  slots=drift
{"event":"flow.registry.composed","packs":[{"name":"builtin","flows":9},{"name":"examples","flows":["at-risk-customer"]}]}
{"event":"flow.selected","agent":"at-risk-customer","flow":"at-risk-customer","pack":"examples"}
agent "at-risk-customer" run run_01k...
output {"level":"low","rationale":"no high-risk signal detected","ticketId":"..."}
agent-run: unknown flow at-risk-customer; registered flows: watchdog-sweep, propose-work, ...
```

The issue text can contain "cancel" or "churn". Then the verdict is high, the run prints
"Agent run accepted; a durable wake is pending.", and the alert goes to the outbox. That is also
valid evidence. Record which path ran.

For M3, run from the new repository:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami-operator-packs
git init
just sync-cohort
nix develop /Users/shinzui/Keikaku/bokuno/shikigami --command cabal build operator-distribution:exe:operator-agent-run
export PG_CONNECTION_STRING="postgresql://$(jq -rn --arg x /Users/shinzui/Keikaku/bokuno/shikigami/db '$x|@uri')/shikigami"
for repo in keiro shikigami keiro keiro; do
  path=/Users/shinzui/Keikaku/bokuno/$repo
  payload=$(jq -nc --arg r "$path" --arg h "$(git -C "$path" rev-parse HEAD)" \
    --arg b "$(git -C "$path" branch --show-current)" '{repository:$r, head:$h, branch:$b}')
  nix develop /Users/shinzui/Keikaku/bokuno/shikigami --command \
    cabal run operator-distribution:exe:operator-agent-run -- --agent agents/repository-ledger.dhall --payload "$payload"
done
git -C /Users/shinzui/Keikaku/bokuno/shikigami status --short   # expect no output
```

The `export` is required because the development shell sets `PGHOST` to `$PWD/db`. Expect
`"movement":"FirstObservation"` for the first keiro and shikigami runs and
`"movement":"Unchanged"` with `previousHead` equal to the current HEAD for the later keiro runs.
A commit in keiro between runs yields `"Moved"`.


## Validation and Acceptance

Acceptance is behavioral, and it is on this Mac:

- **M1.** The `kernel boundary` group passes on the real tree. It fails with the
  `UnknownNamespace` message when `Shikigami/Campaign/Plan.hs` exists, and with `UnfrozenModule`
  for a new file under `Shikigami/Watchdog/`. It passes again after the files are removed.
  Synthetic-input unit tests show that each `KernelViolation` constructor is produced by its
  rule, so a rule cannot pass vacuously; that covers the pack and distribution rules before any
  pack exists. The "exactly seven packages" test still passes unchanged.
- **M2.** The representative check is recorded first: the probe pack's watchdog body compiled
  against `(FlowEffects es, Observe :> es)` without `IOE` or `Store`, its unit test passed, and
  the imports it needed are listed in Surprises & Discoveries. Planting
  `import Effectful (IOE)` in `packs/flow-pack-examples/bodies/` makes the build fail, and
  removing it makes it pass. `shikigami-examples flows` lists `at-risk-customer` under pack `examples`, and the
  stock `shikigami flows` does not list it. The composed agent-run completes, or durably parks,
  the flow on a real issue text, and logs `flow.selected` with `pack=examples`. The stock
  agent-run refuses the same manifest before opening a session.
  `shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs` no longer exists, and both modules are
  gone from `frozenModules`. `just keiro-gate` and all listed test suites pass, including the
  pack's golden label inventory and the SDK export goldens.
  `nix build .#shikigami-worker` still evaluates against an unchanged
  `nix/qualification/cohort.json`. That is a no-regression check, not a new gate.
- **M3.** The separate repository builds and runs `repository-ledger` over real checkouts with
  the expected `movement` values, and this repository's `git status` stays clean. That is the
  MasterPlan's "no change to `shikigami-core`" test, at pack scale.

Proposals that are not required: a Nix package for a distribution, a worker executable
composed with packs (EP-6 creates the `kikan-shikigami` distribution when it moves the first
flow that needs a worker), and opening `DecisionLabel` (EP-6). No milestone adds a Linux or
Apple-container qualification gate.


## Idempotence and Recovery

M1's JSON and spec edits are additive. The planted files are removed by the same steps, so
rerunning them is safe. The M2 move is a set of ordinary commits. If a test suite cannot be made
to pass, revert the move commit: the composable registry commit stands on its own, because the
builtin pack keeps every flow. Make it the first M2 commit. `just sync-cohort` overwrites
`cabal.project` in the external repository and is safe to rerun. The ledger flow's `remember`
uses the Memory capability's deterministic memory id, so a retried run does not duplicate rows.
A second deliberate run does add an observation, as intended. Nothing in this plan deletes
database state. If `keiro-gate` reports a BREAKING finding other than `classify`, stop and
record it. It means a step shape changed unintentionally.


## Interfaces and Dependencies

This plan has no hard prerequisites. It may run in parallel with EP-1 to EP-4. EP-1
(`docs/plans/126-...`) also adds a field to `AgentRunDeps`, `WorkerEnv` and the agent-run
composition: its tier-selected composition record. The plans land serially, and whichever lands
second rebases onto the other. Neither edits the other's field.

Interfaces other plans depend on:

- `Shikigami.Flow.Pack`: `FlowPack`, `PackFlow`, `kernelCapabilityFlow`, `FlowRunContext`,
  `FlowPackName`, `parseFlowPackName`, `FlowRegistry`, `composeFlowRegistry` and `lookupFlow`.
  This is the only definition of these types. A later plan adds a field to `FlowPack` and
  records it; it does not define `PackName`, `ComposedPacks` or another pack record.
- `shikigami-core:flow-sdk` (`Shikigami.Flow.Sdk`, `Shikigami.Flow.Sdk.Program`) and
  `shikigami-core:pack-sdk` (`Shikigami.Pack.Sdk`), with pinned export lists.
- The package rules: packs are `packs/flow-pack-<name>` with modules under `FlowPack.<Name>`
  and a `bodies` sublibrary; distributions hold executables only; nothing out of core is named
  `shikigami-*`; pack labels are pack-prefixed with a golden inventory.
- `Shikigami.Flow.Builtin.builtinPack`, the frozen remainder EP-6 dissolves.
- `agentRunRoleInfoWith`, `workerRoleInfoWith` and `runAdminWith`.
- The `kernel` section of `tools/style/module-ownership.json` and the `kernel boundary` group in
  `shikigami-core/test/Shikigami/PackageArchitectureSpec.hs`.

How later plans consume them:

- EP-6 (`docs/plans/131-shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems.md`)
  moves subsystems into packs. It deletes their `frozenModules` entries and their
  `kernel.namespaces` keys, and the stale-entry rule forces those deletions. It adds the
  `triggers`, `adminVerbs` and `settings` fields to `FlowPack` (EP-10 adds `workflows`), adds the kernel
  modules its subsystems need to `pack-sdk`, shrinks `FlowEffects`, opens `DecisionLabel`, and
  creates the `kikan-shikigami` distribution.
- EP-8 (`docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md`)
  adds the `outputs` and `approvalChannels` fields to `FlowPack` and exports its ports through
  `pack-sdk`.
- EP-10 (`docs/plans/135-move-the-kikan-service-bindings-out-of-shikigami-core-and-compose-a-kikan-distribution.md`)
  moves the `kikan-binding` modules out, composes the binding like a pack, and extends the
  `kikan-shikigami` distribution.
- EP-11 (`docs/plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md`)
  reuses the pinned SDK export lists as the SDK's compatibility check and ends the pre-release
  exception.
- EP-4's playbook interpreter is kernel code. If it is a `FlowDef`, it is registered in a
  kernel pack in core, not in `builtinPack`.
- EP-7 cites a passing `just kernel-fitness` in its architectural acceptance.

Libraries whose choice matters:

- Cabal public sublibraries and `reexported-modules`, which enforce the SDK.
- keiro `Keiro.Workflow`, re-exported for `step`.
- keiki, used by the moved lifecycle module.
- `optparse-applicative`, for the new `--payload` and `flows` options.

Revision note (2026-11-15): the initial body was drafted under MasterPlan 22.

Revision note (2026-11-15, MasterPlan 22 review): this plan became the single owner of the pack
API. It now defines pack-owned interpreters, a second SDK component, the pack and distribution
package rules, the watchdog representative check and the pack label rule; adopts the
MasterPlan's classification; and replaces the first-deployment check with the drain rule.

Revision note (2026-11-15, user decision): the adaptive-delivery coordinator is kernel and
is no longer frozen as flow-pack material; the `workflows` pack field now lands with EP-10.

Revision note (2026-11-16, M2 implementation): M2 is complete. The representative check
added `Error StoreError` to `PackFlow.run`, `workflowName` to `FlowRunContext` and
`FlowDef.decisionMode`. Five labels left the AgentRun declaration instead of one, the
qualification fixture agent moved with the flow, and the pack's label inventory is derived
from a real keiro journal. IR-61 is filed with keiro.

Revision note (2026-11-16, M3 implementation): M3 is complete and the plan is done. The
external repository's commands set the database inside the development shell (FRIC-82), and
Outcomes & Retrospective is filled.
