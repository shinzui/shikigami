---
id: 131
slug: shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems
title: "Shrink shikigami-core to the kernel by moving or retiring use-case subsystems"
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
      at: 2026-11-15T14:01:55Z
      mode: "other"
      note: "Drafted plan body under MasterPlan 22"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-15T14:15:42Z
      mode: "discuss"
      note: "Applied user decisions of 2026-11-15 (repos, in-place placement, disposable databases, stalled-intention)"
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
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-15T15:08:44Z
      mode: "update"
      note: "M1 precedes the first freeze; later milestones leave frozen declaration surfaces alone (user decision 2026-11-15)"
---

# Shrink shikigami-core to the kernel by moving or retiring use-case subsystems

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

`shikigami-core` is meant to be a small durable kernel: agent runs, objectives, approvals,
authority, resource roots, memory, workspaces and worker sessions. Today it also contains
four use-case subsystems, each compiled into the kernel's agent-run workflow: the active-work
watchdog, unrequested-work proposals (`Initiative`), architecture-practice reviews
(`PracticeReview`), and a set of example flows. Adaptive delivery looked like a fifth; the
user decided on 2026-11-15 that its coordinator is a kernel primitive and stays. It also declares a
`Deterministic` behavior arm that the runner has always refused. Each use case widened the
kernel's flow effect row and the agent-run dependency record, and added special cases to the
kernel's flow runner and triggers. The next use case would follow the same path.

After this plan, those use cases ship as out-of-core flow packs. A flow pack is a Haskell
library package outside `shikigami-core` that contributes flows, typed-decision programs,
trigger hooks and CLI verbs at executable composition. MasterPlan 22's EP-5
(`docs/plans/130-move-the-extension-boundary-out-of-shikigami-core-with-flow-packs-and-an-architecture-fitness-check.md`)
owns the whole pack API. This plan consumes it and adds fields to EP-5's one `FlowPack` type;
it never defines a pack type of its own. The stock `shikigami-*` executables compose no pack.
This plan creates the distribution package `kikan-shikigami`, whose worker, scheduler, stream
consumer, server and admin executables compose the kernel with the packs. **Every currently
supported feature keeps working** when run from that distribution. The watchdog
still sweeps active work on its schedule, proposals still reach an operator for approval,
practice reviews still route to a specialist, and, from the kernel itself, adaptive delivery
still coordinates an objective and recurring mandates still supervise objectives. The only thing deleted is the
`Deterministic` arm, which never ran.

You can see it working three ways: the measured core shrinks by roughly 13,000 of its
78,094 lines and the kernel namespace list gets shorter; `shikigami-core` imports no
`Watchdog`, `Initiative` or `PracticeReview` module; and each moved feature runs for real on
this Mac through the same operator verbs as before (`watchdog inspect`, `proposals inspect`,
`objectives inspect`), now served by the distribution's admin executable `kikan-shikigami`.


## Progress

- [ ] M1: Classification confirmed against the code and recorded in this plan, baseline
  measured, pre-release facts rechecked, and the `Deterministic` arm deleted from
  `shikigami-core`, `schema/Agent.dhall`, the server, tests, manifests and docs. A real Skill
  run on a checkout under `/Users/shinzui/Keikaku/bokuno/` still succeeds. This milestone is
  a prerequisite of EP-11's first freeze, the declaration baseline, because it is the last
  change this plan makes to `schema/Agent.dhall` and the `AgentDecl` codec.
- [ ] M2: Flow decision, routing and slot vocabularies are open, checked values rather than
  closed kernel enumerations. The example flows run from `flow-pack-examples`. The
  `kikan-shikigami` distribution exists, and its worker runs `objective-example`, which
  creates a real objective in the local database.
- [ ] M3: `PracticeReview` and the `architecture-practice-router` flow run from
  `flow-pack-practice-review`. A real review trigger for a local repository produces the
  same outcome as before the move.
- [ ] M4: `Initiative` runs from `flow-pack-initiative` through a kernel stream-intake
  hook. A real transcript excerpt produces an approval request, and accepting it creates an
  objective.
- [ ] M5: `Watchdog` runs from `flow-pack-watchdog` through a kernel schedule-allowance
  hook. A scheduled sweep observes a real local run and `kikan-shikigami watchdog inspect` shows it.
- [ ] M6: The adaptive-delivery coordinator is confirmed as a kernel primitive and stays in
  `shikigami-core`. Its disposition is recorded, an import check shows it has no Kikan
  service dependency, and a real objective on a local repository receives an adaptive
  decision from a stock executable.
- [ ] M7: Kernel namespace list closed, the core specification holds no use-case label,
  dispositions recorded in ADRs and architecture docs, before/after size reported. All packs
  composed in the `kikan-shikigami` distribution, plus a kernel mandate cycle, run on this Mac
  in one session.


## Surprises & Discoveries

- Observation: The use cases are woven into the kernel's own workflow and flow runner, not
  just registered beside it. `domain/shikigami/agent-run.keiro` declares watchdog,
  initiative, practice-review, routing and adaptive-delivery step labels in the `AgentRun`
  body. `Shikigami.Flow.FlowEffects` carries 18 capabilities, 8 of them use-case specific.
  `Shikigami.Agent.Workflow.runFlowBehavior` builds every use-case interpreter for every
  flow, and it compares `flow.name == watchdogFlowName` in three places.
  Evidence: `shikigami-core/src/Shikigami/Agent/Workflow.hs` lines 1117–1230. The
  `AgentRunDeps` fields `initiatives`, `observe` and `practiceReview` serve only these flows.
- Observation: Only `Shikigami.Flow`, `Shikigami.App.Config` and `Shikigami.Agent.Workflow`
  import a use-case namespace from the kernel side; the other edges are in the workers
  (stream consumer, scheduler, sampler), the server CLI and `shikigami-agent`. Each move is
  mechanical once the kernel offers hooks.
- Observation: `Router` is not a use case. `Router.Catalog` and `Router.SelectionLimit`
  are imported by the kernel's `Agent.Decl`, `Agent.Delegate` and `Flow.Decision`, and they
  implement the delegation allow-list from ADR-28 and ADR-29. Only the
  `architecture-practice-router` flow and the closed `RouteLabel = ArchitecturePractice` are
  use-case code.
- Observation: Adaptive delivery is split across the boundary. `Objective.Store` itself
  admits adaptive organization proposals (`ApplyAdaptiveDecision`, using
  `Coordination.Proposal`, `Validate`, `Sql` and `Wake`), as ADR-108 requires. `Mandate` and
  `Watchdog` also use `Coordination.Wake` and `Coordination.Observation`. The first draft
  treated the coordinator workflow and its capability as pack material; the user's decision
  of 2026-11-15 keeps them in the kernel with the rest (see the Decision Log).
- Observation: The live practice-review reader fails closed until
  `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5` exists. A real run today
  ends `unresolved` with a `content-plane-unavailable` problem (`docs/user/architecture-practice-reviews.md`).
  "Runs the same after the move" therefore means that same outcome.
- Observation: The reproducible namespace count is 63, and the line count is 78,094. The
  count is distinct first module segments under `shikigami-core/src/Shikigami` and includes
  generated-only roots. MasterPlan 22 was corrected to these figures on 2026-11-15 (its first
  draft said 57 and 78,219).
- Observation: The three large subsystems do not import each other, so the packs need no
  pack-to-pack dependency. Checked with `grep` over the `import` lines on 2026-11-15:
  no module under `Initiative` or `PracticeReview` imports `Shikigami.Watchdog`, and no module
  under `Watchdog` imports `Shikigami.Initiative` or `Shikigami.PracticeReview`.
- Observation: The adaptive coordinator reaches far more of the kernel than any moved
  subsystem. Its seven modules and `Flow/AdaptiveDelivery` import about 55 kernel modules
  across `Execution`, `WorkerSession`, `Objective`, `Behavior`, `Attestation`, `Agent`,
  `Decision`, `Capability` and `Workspace`; the watchdog imports about 38 and initiative about
  28. It imports no Kikan service module: a `grep` over the `import` lines of
  `Coordination/*.hs`, `Flow/AdaptiveDelivery.hs` and `Program/Decision/Adaptive.hs` on
  2026-11-15 found no Kawa, Kizashi, Rei, Danwa, Kanmon, Meibo, Shomei or Kikan-En import,
  and no `Shikigami.Sink` or `Shikigami.Action` import. This is the evidence for keeping it
  in the kernel.


## Decision Log

- Decision: No subsystem is re-expressed as a playbook in this plan. All movable use cases
  become flow packs.
  Rationale: Every candidate needs something EP-4's step kinds (`CodingAgent`, `Skill`,
  `Tool`, `Approval`, `Playbook`, `ForEach`, `Reflect`) cannot express: typed decisions
  over registered programs, bounded observation ledgers, or a checkpoint-reactive workflow
  family. Converting them would change behavior and risk losing features. The decoupling
  also turns EP-4 into a non-dependency. The Interfaces section records what EP-4 would
  need in order to absorb them later.
  Date: 2026-11-15
- Decision: `Mandate`, `MandateLifecycle`, `MandateLookup`, `RecurringObjective` and
  `RecurringCheckpointCycle` stay in the kernel unchanged.
  Rationale: A mandate gives an objective finite, expiring recurring authority bound to an
  objective lock, a retained resource root and a checkpoint watermark (ADR-121). It
  composes only kernel owners, and a scheduled playbook would need exactly this primitive.
  Collapsing it into the `Schedule` trigger would drop the objective-bound authority and the
  checkpoint receipts, which would lose a supported feature.
  Date: 2026-11-15
- Decision (superseded on 2026-11-15 by the MasterPlan 22 review entry below): Journal labels
  stay declared where the journal lives. Flows that run inside `AgentRun` keep their existing
  labels and patch ids in `domain/shikigami/agent-run.keiro`. Only hand-written code moves.
  Rationale: The labels belong to `AgentRun`'s durable contract no matter which package
  runs them. Keeping them avoids a `WorkflowBodyChanged` reset and keeps `just keiro-gate`
  covering them.
  Date: 2026-11-15
- Decision: Labels leave the core specification with their flow (MasterPlan 22 review). When a
  flow moves to a pack, its step labels and its `patch` gates are deleted from
  `domain/shikigami/agent-run.keiro` and from `runFlowBehavior`. The pack owns the labels,
  every one starts with the pack's name, and the pack's test suite holds a golden inventory of
  them (EP-5's rule). Decision and route sites a pack supplies also start with the pack's
  name, so byte-identity with today's `decision-prepare-drift` style labels is not kept. The
  `adaptive-delivery.keiro` workflow family stays in the service specification, because
  MasterPlan 22 classifies that specification as kernel. Each removal produces a
  `WorkflowBodyChanged` finding that is recorded and accepted under the ADR-27 exception.
  Rationale: Keeping the labels would leave every organizational use case in the kernel's
  durable contract at EP-11's baseline, and a future pack label would still be a core change.
  No journal needs the old bytes or the patch gates, because MasterPlan 22 ends the exception
  at the baseline gate and every run is drained before a shape change. `keiro-diff` cannot see
  pack labels yet; the golden inventory makes a label change a reviewed diff until the keiro
  improvement request EP-5 files is answered.
  Date: 2026-11-15
- Decision: SQL migrations stay in `shikigami-migrations`. `docs/architecture/packages.md`
  records which pack owns which table.
  Rationale: Migrations form one ordered, locked chain (`migrations.lock`) for one schema.
  The fitness check governs Haskell namespaces. The pre-release exception never authorizes
  database deletion (`docs/workflow-versioning.md`).
  Date: 2026-11-15
- Decision: A pack flow's interpreter may use `IOE` and `Store`. Its body may not. EP-5
  defines this shape (`PackFlow`) and writes the ADR-13 amendment; this plan uses it.
  Rationale: The use-case capabilities (`Observe`, `Initiative`, the practice-review
  quartet) are journaled interpreters that need IO. Today they sit in the kernel's runner.
  The guarantee that a body cannot smuggle IO is kept by the compiler: each pack keeps its
  bodies in a `bodies` sublibrary that depends on `shikigami-core:flow-sdk` alone. This plan's
  first draft defined the shape itself; MasterPlan 22's review moved it to EP-5 so the pack API
  has one owner.
  Date: 2026-11-15
- Decision: This plan defines no pack type. It adds three fields to EP-5's
  `Shikigami.Flow.Pack.FlowPack`, each in the milestone that first executes it: `settings`
  (M3), and `adminVerbs` and `triggers` (M4; the schedule hook inside `triggers` in M5). A
  `workflows` field for extra durable families is not added, because its only consumer was
  the adaptive coordinator, which stays in the kernel (ADR-1). The `PackName`, `PackFlow`, `FlowRunContext`, `ComposedPacks` and
  `composePacks` definitions of the first draft are removed in favour of EP-5's
  `FlowPackName`, `PackFlow`, `FlowRunContext`, `FlowRegistry` and `composeFlowRegistry`.
  Rationale: MasterPlan 22's review found the pack type defined twice with different names,
  fields and dependency rules. ADR-1 still requires each field to land with a consumer.
  Date: 2026-11-15
- Decision: Packs are `packs/flow-pack-<name>` with modules under `FlowPack.<Name>`, and each
  depends only on `shikigami-core:flow-sdk` and `shikigami-core:pack-sdk`. What a subsystem
  needs from the kernel is added to `pack-sdk` in the milestone that moves it, from the lists
  in Plan of Work.
  Rationale: EP-5 forbids the `shikigami-` prefix outside the seven stock packages (ADR-39)
  and forbids a pack depending on the whole core. The first draft named the packages
  `shikigami-pack-*` and let each depend on `shikigami-core`. Exporting through `pack-sdk`
  deliberately is how the core's 357 exposed modules become a reviewed API.
  Date: 2026-11-15
- Decision: The stock `shikigami-workers`, `shikigami-server` and `shikigami-agent` compose no
  pack. M2 creates the distribution package `packs/kikan-shikigami`, which holds executables
  only: `kikan-shikigami-worker`, `kikan-shikigami-scheduler`,
  `kikan-shikigami-consume-stream`, `kikan-shikigami-server` and the admin CLI
  `kikan-shikigami`, each a few lines over the roles' `...With` entry points. All real-run
  acceptance in M2 to M7 uses these executables. EP-10
  (`docs/plans/135-move-the-kikan-service-bindings-out-of-shikigami-core-and-compose-a-kikan-distribution.md`)
  later adds the Kikan binding to the same distribution.
  Rationale: The first draft composed the packs into the stock workers and server, which
  breaks EP-5's rule and the ADR-39 frozen closure. The consequence is deliberate and must be
  documented: after each move, the stock executables and the stock Nix roles built from them
  no longer offer that use case. A deployment that wants the watchdog, proposals or practice
  review runs the distribution. Adaptive delivery stays in the stock executables. Nix packaging of the distribution is
  excluded by MasterPlan 22, so on this Mac the distribution runs from `cabal`.
  Date: 2026-11-15
- Decision: M1 must be accepted before EP-11's first freeze, and after that freeze no later
  milestone of this plan changes a frozen declaration surface.
  Rationale: The user decided on 2026-11-15 to "freeze in two steps". EP-11
  (`docs/plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md`)
  first freezes the declaration baseline: `schema/Agent.dhall`, the `AgentDecl` journal
  codec, the playbook format, the operator files and the stock local-work commands. M1
  removes the `Deterministic` arm and the `ShikumiProgram.enabledBy` field, which change
  both the schema and the codec, so it is a named prerequisite of that freeze. M2 to M7
  change the durable wire (labels, patch gates), the pack SDK and the admin CLI, which
  freeze second, and they stay free to do so under the drain rule. Checked against this
  plan: opening the decision and route vocabularies in M2 changes `FlowDef` and step
  labels, not the shape of `AgentDecl` (`decisionModels` and `routing` keep their types).
  The declarations under `agents/proof/` that name a moved flow load only under the
  distribution after their move, so EP-11 keeps them in the second freeze's corpus.
  Date: 2026-11-15
- Decision: The adaptive-delivery coordinator stays in the kernel, whole: `Coordination/*`,
  `Flow/AdaptiveDelivery`, `Program/Decision/Adaptive`, the `AdaptiveDelivery` capability in
  `FlowEffects`, the `shikigami.adaptive-delivery` family with its labels and patch block, and
  the `adaptive` decision site. No `flow-pack-adaptive-delivery` is created, and M6 becomes a
  confirmation milestone.
  Rationale: The user decided on 2026-11-15: "the adaptive delivery coordinator should remain
  in the kernel if it's not dependent on kikan services." The import check recorded in
  Surprises & Discoveries shows it is not. It also needs about 55 kernel modules, most of
  them execution, worker-session and objective internals, so moving it would export the
  kernel's internals instead of an API. It joins `Router` and `Mandate` as a coordination
  primitive.
  Date: 2026-11-15
- Decision: The pre-release exception ends at EP-11's baseline gate
  (`docs/plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md`),
  not at EP-7's first campaign run. Before each milestone's shape change lands, every run is
  drained to a terminal state. This plan must be Complete before EP-11.
  Rationale: The user decided this on 2026-11-15 (MasterPlan 22 Decision Log). It removes the
  first draft's fallback of byte-identical moves and a fail-closed `Deterministic` decoder.
  Date: 2026-11-15
- Decision: `agents/detectors/stalled-intention.dhall` is deleted with the `Deterministic`
  arm.
  Rationale: It is the arm's only real manifest, it has never executed, and it cannot load
  once the arm is gone. Writing a working stalled-intention detector would be new scope.
  The user approved the deletion on 2026-11-15.
  Date: 2026-11-15
- Decision: Delete the five unused items in M1: the `shikigami.fired` table, the
  `ShikumiProgram.enabledBy` field, `agents/detectors/schema.dhall`,
  `agents/detectors/at-risk-customer.dhall` and the `shikigami danwa-spike` command.
  Rationale: The user approved them on 2026-11-15. None is read, executed or needed: the
  table has no reader, the field is never consumed, the schema file is a tombstone, the
  declaration names an unregistered task, and the real Danwa sink replaced the spike.
  Date: 2026-11-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The repository is a Cabal project. Its packages are `shikigami-core` (domain and durable
workflows), `shikigami-workers` (the `shikigami-worker`, `shikigami-scheduler` and
`shikigami-consume-stream` executables), `shikigami-server` (the `shikigami` admin CLI and
HTTP server), `shikigami-agent` (light one-off runs, ADR-3), `shikigami-migrations`,
`shikigami-api` and `shikigami-client`. Durable workflows use keiro. Their checked
specification is `domain/shikigami.keiro-workspace`, which lists the `.keiro` files under
`domain/shikigami/` and generates code under `shikigami-core/src/Shikigami/*/Generated/`.
`just keiro-gate` checks that the hand-written runtime matches the specification and that
no change breaks stored journals. A workflow body is the ordered list of journaled steps;
each step has a label, and a journal replays by matching labels. A patch id (for example
`shikigami-watchdog-v1`) guards steps added after instances may already exist.

A Flow is a compiled Haskell workflow body that an agent selects with
`Behavior.Flow { name }` in its Dhall declaration. Today `Shikigami.Flow.flowRegistry`
(`shikigami-core/src/Shikigami/Flow.hs`) lists ten flows. A flow body may reach the world
only through capabilities, which are effectful effects listed in `Shikigami.Flow.FlowEffects`.
Each capability has a replay-safe interpreter that journals its results as steps.
`Shikigami.Agent.Workflow.runFlowBehavior` runs a flow inside the `AgentRun` workflow
(`shikigami.agent-run`) and composes every interpreter. A typed decision is a model call
validated against a registered program (`Shikigami.Program.Decision.Registry`). Each call
site has a label in the closed `Shikigami.Flow.Decision.DecisionLabel = Triage |
Investigation | Judgment | Adaptive | Propose | Drift`, which produces step labels such as
`decision-prepare-drift`.

EP-5 supplies the boundary this plan consumes:

- `Shikigami.Flow.Pack` with `FlowPack`, `FlowPackName`, `PackFlow` (a `FlowDef` plus
  `run :: forall es. (FlowEffects es, IOE :> es, Store :> es) => FlowRunContext -> Value -> Eff es Value`),
  `kernelCapabilityFlow`, `FlowRunContext`, the sealed `FlowRegistry` and
  `composeFlowRegistry`. A pack body is typed against `FlowEffects` plus the pack's own
  capabilities and lives in the pack's `bodies` sublibrary, which may depend only on
  `shikigami-core:flow-sdk`; the interpreter in the pack's main library may also use
  `shikigami-core:pack-sdk`.
- The role entry points `agentRunRoleInfoWith`, `workerRoleInfoWith` and `runAdminWith`, and
  the rule that only a distribution package (executables, no library) composes packs.
- `packs/flow-pack-examples`, which already owns at-risk-customer, and
  `packs/examples-distribution`.
- The fitness check: the `kernel` section of `tools/style/module-ownership.json`, with the
  keys `namespaces` (each top-level root mapped to `kernel`, `flow-pack` or `kikan-binding`),
  `frozenModules` and `sdkModules`, and the `kernel boundary` group in
  `shikigami-core/test/Shikigami/PackageArchitectureSpec.hs` (`just kernel-fitness`). A new
  use-case namespace in `shikigami-core` fails the build, and a `frozenModules` entry whose
  file is gone fails it too, so the lists must shrink as code moves.
- The label rule: pack labels are pack-prefixed, leave the core specification with their
  flow, and are pinned by a golden inventory in the pack's tests.

When this plan says "the kernel list", it means `kernel.namespaces` and
`kernel.frozenModules`. This plan removes entries from both as subsystems leave. The
`kikan-binding` entries are EP-10's to remove.

The confirmed classification follows. It was traced through imports, the domain
specification, migrations, workers, server verbs and docs. Line counts are
hand-written plus generated lines measured on 2026-11-15.

| Subsystem (core paths) | Lines | Disposition | Target |
| --- | --- | --- | --- |
| `Deterministic` arm in `Agent/Decl.hs`, `Behavior/Run.hs`, `Capability/Catalog.hs`, `Agent/Run.hs` | ~20 | Retire | deleted |
| `ObjectiveExample`, `ShikumiDecisionExample`, `ShikumiJudgmentExample`, `delegation-proof` in `Flow/`; `Program/Decision/Examples`, `JudgmentExample` (`AtRiskCustomer` moved in EP-5) | ~830 | Pack | `flow-pack-examples` |
| `PracticeReview*`, `Flow/OpenTelemetryPracticeReview`, `architecture-practice-router` flow | ~4,860 | Pack | `flow-pack-practice-review` |
| `Initiative/*`, `Flow/Initiative`, `Program/Decision/Initiative` | ~3,590 | Pack | `flow-pack-initiative` |
| `Watchdog/*`, `Flow/Watchdog`, `Flow/Observe`, `Program/Decision/Drift` | ~3,380 | Pack | `flow-pack-watchdog` |
| `Coordination/{Workflow,Runtime,Capability,Commands,Direct,Decision,DecisionAuthority}`, `Flow/AdaptiveDelivery`, `Program/Decision/Adaptive` | ~1,090 | Re-evaluated: Kernel | adaptive coordination (user decision 2026-11-15; ADR-111) |
| `Coordination/{Proposal,Validate,Sql,Wake,Checkpoint,Observation,Types,Identity}` | ~990 | Kernel | objective organization (ADR-108) |
| `Router/*`, `Flow/Routing` (with an open route site) | ~990 | Kernel | governed delegation (ADR-28, ADR-29) |
| `Mandate*`, `RecurringObjective`, `RecurringCheckpointCycle` | ~1,950 | Re-evaluated: Kernel | recurring objective authority (ADR-121) |
| Agent runs, `Execution*`, `Objective*`, `Approval`, `Memory`, `Workspace`, `Capability`, `WorkerSession*`, `Sink`, `Trigger`, `Decision`, `Program` core | rest | Kernel | unchanged |

The generated `Shikigami.AdaptiveDelivery.Generated.*` modules (86 lines) stay in core with
the coordinator that uses them, and EP-5's list marks the `AdaptiveDelivery` and
`Coordination` roots `kernel`. MasterPlan 22
classifies the Kikan service clients under `Shikigami.Sink`, the Kikan-En authorizer, the
Meibo directory source, `DanwaConversation` and `Objective.Tracker`'s Rei adapter as Kikan
bindings. EP-10 moves them; they are outside this plan. Evidence collection under
`Attestation` is kernel.

Pack-owned tables, which stay in `shikigami-migrations/sql-migrations/`, are
practice review `0012` and `0032`, initiative `0043` and `0044`, and watchdog
`0045`–`0048`. The adaptive tables `0038`, `0041` and `0042` are read by the kernel
objective store and stay kernel-owned. Plan of Work names the worker, server and settings
modules that wire each use case today.

Relevant ADRs. [ADR-1](../adr/0001-declare-only-what-the-runtime-executes.md): declare
only what the runtime executes (why `Deterministic` goes).
[ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) with
`docs/workflow-versioning.md` ("The one pre-v1 baseline exception"): unreleased shapes may
be replaced after rechecking four facts.
[ADR-12](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md): body growth
needs a patch. [ADR-13](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md):
flow bodies reach the world only through capabilities.
[ADR-3](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md): `shikigami-agent`
stays light. [ADR-75](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md):
the closed module budget EP-5 extends. Router:
[ADR-28](../adr/0028-a-router-catalog-is-a-bounded-snapshot-of-declared-authority.md),
[ADR-29](../adr/0029-model-routing-output-is-a-proposal-until-validated-against-journaled-authority.md).
Practice review: [ADR-31](../adr/0031-practice-review-adjudication-is-a-logical-memory-transition.md),
[ADR-35](../adr/0035-practice-review-attention-reserves-semantics-not-delivery-state.md).
Adaptive delivery: [ADR-108](../adr/0108-adaptive-decisions-commit-with-authoritative-checkpoints.md),
[ADR-111](../adr/0111-adaptive-delivery-carries-native-admission-and-reference-only-seeds.md).
Initiative: [ADR-113](../adr/0113-unrequested-proposals-park-on-the-approval-child-keyed-by-observer-and-subject.md),
[ADR-114](../adr/0114-standing-policies-are-revocable-durable-grants-and-admission-funds-an-independent-coordinator-run.md),
[ADR-115](../adr/0115-evaluation-spend-is-a-root-enrolled-at-the-trigger-and-accounted-slots-refuse-without-one.md).
Watchdog: ADR-116 to ADR-120, chiefly
[ADR-118](../adr/0118-the-watchdog-is-an-advisory-flow-agent-without-intervention-authority.md)
and [ADR-119](../adr/0119-the-schedule-trigger-enrolls-an-operator-owned-watchdog-envelope-per-tick.md).
Mandates: [ADR-121](../adr/0121-recurring-mandates-retain-authority-checkpoint-receipts-and-generation-owned-wakes.md).
Their decisions stay true after the move; only where the code lives changes.

**Work this plan supersedes or redirects (the plans themselves are not edited).**
MasterPlans 19 (watchdog) and 20 (unrequested work) are Complete. Their outputs move
unchanged into packs. Open practice-review hardening Plans 60–63 target code that moves. If that work
is resumed, it applies to the pack, and its Linux qualification is not a gate here. The
remaining qualification milestone of Plan 86 (adaptive delivery) targets code that stays in
the kernel and is unaffected.
Plan 87 (recurring objectives) stays in the kernel. MasterPlan 21 stays deferred.


## Approved removals of unused items

Research found the following items, which look dead. The user approved deleting all of them
on 2026-11-15 (Decision Log), and they are deleted in M1 with the `Deterministic` arm.

- The `shikigami.fired` detector suppression table in
  `shikigami-migrations/sql-migrations/0001-shikigami-fired.sql`. No Haskell module reads or
  writes it. `agents/detectors/README.md` calls it "not an active runtime feature".
- The `ShikumiProgram.enabledBy` field in `Shikigami.Agent.Decl` and `schema/Agent.dhall`.
  It is decoded but never consumed.
- `agents/detectors/schema.dhall`, a retired tombstone that evaluates to text.
- `agents/detectors/at-risk-customer.dhall`. It names a classifier task that is not
  registered, so it always ends in `UnknownTask`. Its sibling `at-risk-customer-flow.dhall`
  works and moves to the examples pack.
- The `shikigami danwa-spike` command (`Server/Command/DanwaSpike.hs`). It is described as
  proving the outbound Danwa client "before the real sink is wired"; the real sink now
  exists.


## Plan of Work

The order follows the rule "largest, least-coupled first", after two enabling steps. M1 is
independent of EP-5 and removes a fixture that later tests would otherwise carry. M2 opens
the kernel's closed vocabularies and moves the examples, which use only kernel
capabilities. That proves the pack path with no new kernel hooks. M3 through M5 move the
three large subsystems in descending size and ascending coupling. Practice review needs
pack interpreters only; initiative adds a stream hook; the watchdog adds a schedule hook,
advisory decisions and a sampler. M6 confirms that the adaptive coordinator stays in the
kernel, and M7 closes out.
After every milestone the full tree builds and `cabal test all` passes.

Each milestone that changes code under `shikigami-core/src/Shikigami/Agent/` or `Flow/`
starts with the pre-release recheck and drain in Concrete Steps and ends with
`just keiro-gate`. A move deletes the moved flow's labels and `patch` gates from
`domain/shikigami/agent-run.keiro` and from `runFlowBehavior` (Decision Log), so the gate
reports a `WorkflowBodyChanged` finding for `shikigami.agent-run` naming exactly those
labels. Record the finding verbatim in Surprises & Discoveries. A finding that names any
other label means a kernel step shape changed by accident: stop and fix it.

Every pack follows EP-5's layout: `packs/flow-pack-<name>/` with a `bodies` sublibrary
(`bodies/FlowPack/<Name>/Body/...`, depending only on `shikigami-core:flow-sdk`), a main
library (`src/FlowPack/<Name>/...`, also depending on `shikigami-core:pack-sdk`), a test
suite, and `test/golden/labels.txt`, the pack's label inventory. Each milestone lists the
kernel modules its subsystem imports today. Those are the candidate `pack-sdk` exports. Add
only the ones the moved code still needs after the move, pin them in `kernel.sdkModules`, and
record the final list in the Decision Log. A module on a list that looks like kernel
internals (a store, a generated runtime) is a prompt to ask whether the pack should call a
narrower kernel function instead; prefer adding that function to exporting the internals.

**M1 — Confirm, measure, retire `Deterministic`.** Copy the classification above into the
Decision Log as confirmed, or amended if the tree has changed since drafting. Record the
baseline measurements. Delete the `Deterministic` constructor from
`Shikigami.Agent.Decl.Behavior` and the `< Deterministic … >` alternative from
`schema/Agent.dhall`. Delete its cases in `Behavior/Run.hs`, `Capability/Catalog.hs`,
`Agent/Run.hs` and `shikigami-server/src/Shikigami/Agent/Handler.hs`, and remove the
EP-6 comment in `Behavior/Error.hs`. `UnsupportedBehavior` stays, because the one-off runner
still uses it for `Flow` and `CoordinatingSkill`. About a dozen test modules (in `shikigami-core/test`, `test-postgres` and
`shikigami-workers/test`) use
`Deterministic {}` as a "some non-Skill behavior" fixture. Replace it with
`Flow {name = declarationCoordinate "test-flow"}`, which has the same non-Skill semantics
for overlays, delegation and catalogs, and delete the assertions that only checked the
refusal. Delete `agents/detectors/stalled-intention.dhall` and its README row. Also delete the five
approved unused items listed under "Approved removals of unused items": the
`shikigami.fired` table, through a new migration that drops it, since migration 0001 is
not edited; the `ShikumiProgram.enabledBy` field; `agents/detectors/schema.dhall`;
`agents/detectors/at-risk-customer.dhall`; and the `shikigami danwa-spike` command with its
docs. Remove the
`Deterministic` section and table row from `docs/user/behaviors.md`. `AgentDecl` JSON is
journaled by `AgentRun`'s `lookup-agent` step, so this is a codec change under the
pre-release exception. Run the recheck and keiro-gate, and record any finding. Acceptance:
`rg -n 'Deterministic \{|Behavior\.Deterministic|< Deterministic' --glob '!docs/plans/**' --glob '!docs/masterplans/**'`
prints nothing. Every remaining manifest passes `shikigami validate`. A real run as in
Validation succeeds.

**M2 — Open vocabularies; examples pack.** Replace three closed kernel enumerations that
name use cases with checked, pack-supplied coordinates. Kernel-owned sites keep their label
bytes. Sketch, in `shikigami-core`:

```haskell
-- Shikigami.Flow.Decision: replaces data DecisionLabel = Triage | ... | Drift
type DecisionSite = DeclarationCoordinate "decision-site"  -- existing checked coordinate parser
data DecisionStep = DecisionStep
  { site :: !DecisionSite              -- "watchdog-drift" -> decision-prepare-watchdog-drift / decision-result-watchdog-drift
  , accounting :: !DecisionAccounting  -- existing closed sum: UnaccountedCall | RootAccountedCall
  , program :: !ProgramRef
  }

-- Shikigami.Flow.Routing: replaces data RouteLabel = ArchitecturePractice
type RouteSite = DeclarationCoordinate "route-site"  -- route-catalog-<site>, route-decision-<site>

-- Shikigami.Flow: FlowDef loses its name-based special cases
data DecisionMode = DecisionsRequired | DecisionsAdvisory
data SlotPolicy = AllSlotsRequired | SlotsDisabledWithoutAlias !ModelAlias
-- FlowDef gains:  decisionMode :: !DecisionMode, slotPolicy :: !SlotPolicy
```

`runFlowBehavior` and `flowDecisionSlotsFor` then branch on `decisionMode` and `slotPolicy`
instead of `flow.name == watchdogFlowName`. The decision program registry becomes the
kernel's programs plus each pack's `decisionPrograms`, validated once at composition. A site
a pack supplies starts with the pack's name (`examples-triage`, `watchdog-drift`,
`practice-review-architecture-practice`), so its labels are pack-prefixed; the old label bytes
are not kept.

Extend EP-5's `packs/flow-pack-examples` (modules under `FlowPack.Examples`), which already
owns at-risk-customer. Move the remaining example flows, their programs and their tests into
it, and delete `objectives-example-*` and the example decision labels from
`domain/shikigami/agent-run.keiro`. The example bodies need only kernel capabilities, so they
use `kernelCapabilityFlow`. They do need these added to `shikigami-core:flow-sdk`, because a
body imports them: the `Objectives`, `Decision` and `Delegate` capability operations
(`Shikigami.Flow.{Objectives, Decision, Delegate}`), the objective command vocabulary
(`Shikigami.Objective.{Command, Operation, Types}`), `Shikigami.Decision.Contract`,
`Shikigami.Program.Decision` and `Shikigami.Router.Decision`.

Create the distribution `packs/kikan-shikigami/` here, because `objective-example` is the
first moved flow that needs a worker:

```text
packs/kikan-shikigami/
  kikan-shikigami.cabal    executables only; depends on the packs and on shikigami-workers,
                           shikigami-server (and shikigami-agent for the agent-run role)
  app/worker/Main.hs           main = runRole (workerRoleInfoWith packs)
  app/scheduler/Main.hs        kikan-shikigami-scheduler      (added in M5)
  app/consume-stream/Main.hs   kikan-shikigami-consume-stream (added in M4)
  app/server/Main.hs           kikan-shikigami-server
  app/admin/Main.hs            main = runAdminWith packs        -- the `kikan-shikigami` CLI
  src-shared/Packs.hs          packs :: [FlowPack]  -- one list, shared by every executable
```

If the scheduler, the stream consumer or the server has no `...With` entry point yet, add one
beside EP-5's three, following the same pattern (the stock entry point is `...With []`). The
stock `shikigami-workers`, `shikigami-server` and `shikigami-agent` gain no pack dependency;
EP-5's fitness check enforces that. Update `docs/architecture/packages.md` and
`docs/operations/` to say that the stock executables run kernel behaviors and declared agents
only, and that the organizational use cases run from the distribution.

Acceptance: `kikan-shikigami render-lifecycle agents/proof/shikumi-decision-example.dhall`
still renders, now from the pack, and the stock `shikigami render-lifecycle` refuses it with
the flows it has. The `objective-example` real run in Validation succeeds.

**M3 — Practice-review pack.** This is the first move that uses a pack-owned interpreter.
EP-5 defines the shape (`PackFlow` and `FlowRunContext` in `Shikigami.Flow.Pack`) and proved
it against the watchdog; this plan does not redefine it. If the practice-review interpreters
need something `FlowRunContext` lacks, add the field to EP-5's record and record that in the
Decision Log.

A pack writes its body against its own capabilities, in its `bodies` sublibrary. It builds
`PackFlow.run` as `\ctx -> interpretMine runtime ctx . body`, where `runtime` is closed over
when the pack value is built, for example `practiceReviewPack :: PracticeReviewRuntime ->
FlowPack`. The compiler keeps `IOE` and `Store` out of the bodies, because the `bodies`
sublibrary depends only on `shikigami-core:flow-sdk`.

This milestone adds one field to `FlowPack`, for the pack's setting:

```haskell
-- Shikigami.Flow.Pack (EP-5's module; field added here)
--   settings :: ![PackSetting]
data PackSetting = PackSetting
  { key :: !SettingKey                      -- e.g. practice_review.attention_recipients
  , validate :: Value -> Either Text ()     -- run at startup; a failure refuses boot (ADR-38)
  }
```

`composeFlowRegistry` refuses two packs that declare the same key. The pack decodes its own
typed value from the validated setting when it builds its runtime.

Candidate `pack-sdk` exports, from the subsystem's imports today: `Shikigami.Agent.{Decl,
DeclarationValue, Name, Principal, RunJob}`, `Shikigami.Activity`, `Shikigami.App`,
`Shikigami.Behavior.{Compatibility, Run}`, `Shikigami.Decision.Contract`,
`Shikigami.Directory`, `Shikigami.FormatVersion`, `Shikigami.Memory.{Access, Scope}`,
`Shikigami.Repository`, `Shikigami.Sink` with `Shikigami.Sink.{Coordinate, Delivery, Intent,
Types}`, and `Shikigami.Trigger.{Enqueue, RequestKey}`. If EP-8
(`docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md`)
has landed, the attention delivery uses its output port from `pack-sdk` instead of the
`Shikigami.Sink.*` modules.

Move `PracticeReview*`, `Flow/OpenTelemetryPracticeReview` and the
`architecture-practice-router` flow, which now names
`declarationCoordinate "practice-review-architecture-practice"` as its route site. Move their
tests from `shikigami-core/test` and `test-postgres` as well. Delete the nine
`practice-review-*` labels and the `route-*-architecture-practice` labels from
`domain/shikigami/agent-run.keiro`, and list them in the pack's golden inventory. Remove
`ExecutionContext` and the four
`PracticeReview*` capabilities from `FlowEffects`, and remove `practiceReview` from
`AgentRunDeps` (its seed is built in `shikigami-workers/src/Shikigami/Workers/Config.hs`). Interpreters must evaluate in the same order as before. The
`practice_review.attention_recipients` setting keeps its key and env binding. Its decoder
moves to the pack, and the kernel config loader accepts the composed packs' `settings`: same
key, same validation failure at startup. The stock executables compose no pack, so they do
not offer the flow and reject the setting key as unknown; the `kikan-shikigami` executables
offer both. Remove `PracticeReview` from `kernel.namespaces` and its modules from
`kernel.frozenModules`.

**M4 — Initiative pack.** This milestone adds two fields to EP-5's `FlowPack`:
`triggers :: !TriggerHooks` (`emptyTriggerHooks` for packs without one) and
`adminVerbs :: ![AdminVerb]`, where an `AdminVerb` is a named `optparse-applicative` command
that `runAdminWith` mounts beside the kernel's verbs and refuses on a duplicate name. Add the
stream-intake hook to the kernel and move the prefilter/ledger call out of
`shikigami-workers/src/Shikigami/Trigger/Consumer.hs` into the pack:

```haskell
-- Shikigami.Trigger.Hook (kernel)
data TriggerHooks = TriggerHooks { stream :: !(Maybe StreamHook), schedule :: !(Maybe ScheduleHook) }
newtype StreamHook = StreamHook (StreamCandidate -> IO StreamDisposition)
data StreamCandidate = StreamCandidate { envelope :: !ActivityEnvelope, agent :: !AgentDecl, receivedAt :: !UTCTime }
data StreamDisposition = StreamAdmit | StreamSkip !StreamSkipRecord  -- record carries reason text for metrics/logs
```

The consumer consults the hook of the pack that owns the matched agent's flow. Move
`Initiative/*`, `Flow/Initiative`, `Program/Decision/Initiative` and the
`proposals` verbs (`Server/Command/Proposals.hs` becomes `FlowPack.Initiative.Command`,
contributed through `adminVerbs`, so `kikan-shikigami proposals …` works and the stock
`shikigami` no longer has the verb). Add `kikan-shikigami-consume-stream` to the
distribution. Also move the `initiatives` setting, and change
`Telemetry.Metrics.recordInitiativeCandidate` into a generic `recordStreamDisposition`
labelled by pack name. Remove `Initiative` from `FlowEffects`, `initiatives` from
`AgentRunDeps`, and `Initiative` from the kernel list. Delete the `shikigami-initiative-v1`
and `shikigami-initiative-admission-v1` patch blocks, with their `initiative-*`,
`objectives-initiative-*` and `emit-signal-initiative-admitted` labels, from
`domain/shikigami/agent-run.keiro`, and delete the two `Workflow.patch` evaluations from
`runFlowBehavior`. The pack's golden inventory lists the labels.

Candidate `pack-sdk` exports: `Shikigami.Activity` and `Shikigami.Activity.Coordinate`,
`Shikigami.Agent.{Approval, Decl, DeclarationValue, Name, Principal, Run.Key, RunJob}`,
`Shikigami.Decision.Contract`, `Shikigami.Directory`, `Shikigami.Duration`,
`Shikigami.Execution.{Coordinate, Identity, Quantity, Resources, ResourcesStore}`,
`Shikigami.Objective.{Association, Command, Keys, Operation, Reference, Store, Types}`,
`Shikigami.Repository`, `Shikigami.StateRevision`, `Shikigami.Trigger.Enqueue` and the new
`Shikigami.Trigger.Hook`.

**M5 — Watchdog pack.** Today `shikigami-workers/src/Shikigami/Trigger/Scheduler.hs` calls
`Watchdog.Admission.watchdogAllowance` and `enrollScheduledWatchdogTx`. Generalize ADR-119's schedule enrollment. The transaction that
recovers a root at the native workflow origin and binds it to the run job is generic
resource-root code. It moves into the kernel as `enrollScheduledRootTx`. The pack supplies
only the allowance check:

```haskell
-- Shikigami.Trigger.Hook (kernel)
newtype ScheduleHook = ScheduleHook (ScheduledCandidate -> Either ScheduleRefusal (Maybe ScheduledAllowance))
data ScheduledAllowance = ScheduledAllowance
  { principal :: !PrincipalId, flow :: !(DeclarationCoordinate "flow")
  , limits :: !EnvelopeLimits, lifetime :: !(Duration "allowance") }
enrollScheduledRootTx :: ExecutionRootId -> ScheduledAllowance -> UTCTime -> RunJob -> Transaction (Either ScheduleRefusal RunJob)
```

Move `Watchdog/*`, `Flow/Watchdog`, `Flow/Observe`, `Program/Decision/Drift`, the
`watchdog` verbs (through `adminVerbs`), the sweep-age gauge from `Telemetry/Sampler.hs` and
the `watchdog` setting. Add `kikan-shikigami-scheduler` to the distribution. The watchdog
`FlowDef` declares `decisionMode = DecisionsAdvisory` and
`slotPolicy = SlotsDisabledWithoutAlias watchdog-drift`. Its pack `run` calls the
sweep-failure hook on exception and then rethrows. Start from the findings EP-5's
representative check recorded for this flow. Remove `Observe` from `FlowEffects`, `observe`
from `AgentRunDeps`, and `Watchdog` from the kernel list. Delete the `shikigami-watchdog-v1`
patch block, with its `watchdog-*` and `emit-signals-watchdog-deliver` labels, from
`domain/shikigami/agent-run.keiro`, and delete the patch evaluation and the three
`watchdogFlowName` tests from `runFlowBehavior`.

Candidate `pack-sdk` exports: `Shikigami.Agent.{Approval, Approval.Workflow, Decl,
DeclarationValue, Name, Principal, RunJob, Workflow.Name}`, `Shikigami.Approval.Observation`,
`Shikigami.Coordination.Observation`, `Shikigami.Decision.{Contract, ModelAlias}`,
`Shikigami.Duration`, `Shikigami.Execution.{Attempt, Coordinate, Identity, Observation,
Progress, Quantity, Resources, ResourcesStore, RootObservation, Transcript}`,
`Shikigami.ExecutionDriver.Generated.WorkflowRuntime`, `Shikigami.Objective.{Observation,
Types}`, `Shikigami.Program.{Decision, DecisionRunner}`, `Shikigami.Sink.{Types, Validate}`,
`Shikigami.StateRevision`, `Shikigami.Trigger.Schedule`, `Shikigami.WorkerSession.{Observation,
Types}` and `Shikigami.Workspace.{Process, ProcessObservation, Types}`. The watchdog reads
other owners' state; the `*.Observation` modules are the intended read surface, and
`ExecutionDriver.Generated.WorkflowRuntime` is the one to replace with a narrower kernel
function.

**M6 — Confirm the adaptive coordinator as a kernel primitive.** Nothing moves. The
coordinator (`Coordination/*`, `Flow/AdaptiveDelivery`, `Program/Decision/Adaptive`), the
`AdaptiveDelivery` capability in `FlowEffects`, the `shikigami.adaptive-delivery` family
declared in `domain/shikigami/adaptive-delivery.keiro`, the `shikigami-adaptive-delivery-v1`
patch block and its labels in `domain/shikigami/agent-run.keiro`, and the generated
`Shikigami.AdaptiveDelivery.Generated.*` modules all stay in `shikigami-core`. The keiro
conformance package under `shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/`
keeps checking them as it does today and needs no pack dependency. The decision site stays
the unprefixed kernel coordinate `adaptive` (labels `decision-prepare-adaptive` and
`decision-result-adaptive`, unchanged), while every pack-supplied site carries its pack's
name. This milestone does three things:

1. Record the disposition: make sure the `kernel` section of
   `tools/style/module-ownership.json` lists `Coordination` and `AdaptiveDelivery` as
   `kernel` and that none of the modules above is in `frozenModules`. If EP-5 listed any of
   them as leaving, correct the list here.
2. Prove the reason still holds. Add a rule to the `kernel boundary` group, or a case to
   it, asserting that no module under `Shikigami.Coordination`, `Shikigami.Flow.AdaptiveDelivery`
   or `Shikigami.Program.Decision.Adaptive` imports a Kikan binding module. Until EP-10 moves
   the bindings, name them explicitly (`Shikigami.Sink.KawaClient`, `KizashiClient`, `Danwa`,
   `KanmonClient`, `ReiAction`, `Shikigami.Action.Authorization`'s Kikan constructor module and
   `Shikigami.DanwaConversation`); after EP-10 the dependency rule on the binding package
   covers it. The check must fail on a planted import and pass without it.
3. Run adaptive delivery for real from a stock executable (see Validation).

No `pack-sdk` export is added for the coordinator, and the `FlowPack` type gains no
`workflows` field. Because the coordinator stays, the kernel modules it uses stay internal.
EP-11 decides which of them remain exposed.

**M7 — Close out.** Run the measurement and record before and after values in Outcomes.
Update `docs/architecture/packages.md` with the packs, their tables and their composition.
Update `docs/architecture/domain-atlas.md`. Update `docs/capabilities/index.md` and the
capability pages `active-work-watchdog.md`, `unrequested-work-proposals.md`,
`advisory-practice-review.md` and `durable-agent-flows.md` to state their owning pack. In
`docs/user/flows.md`, a new flow is now added in a pack, not in `flowRegistry`. EP-5 owns
the ADR-13 amendment; add only a Consequences note on code ownership to ADR-28, ADR-118,
ADR-119 and ADR-111. Write one new ADR, "Use-case subsystems leave the kernel by recorded
disposition", that records the classification table, the Mandate and Router "kernel"
verdicts, the `Deterministic` retirement, the final `pack-sdk` export list with the reason
for each group, and the consequence that the stock executables and Nix roles no longer offer
the moved use cases. Confirm that `domain/shikigami/agent-run.keiro` holds no `watchdog-`,
`initiative-`, `practice-review-` or example label and no patch block for a moved flow, which
is what EP-11's baseline gate requires of the core specification. If keiro has meanwhile
shipped workflow fragments declared from separate packages, move each pack's golden inventory
to such a declaration under the same recheck and gate. Then run the combined real session
described in Validation.


## Concrete Steps

Run everything from `/Users/shinzui/Keikaku/bokuno/shikigami` inside the dev shell.

Measure the core (before M1, and again at M7):

```bash
cd shikigami-core/src
find Shikigami -name '*.hs' | wc -l
find Shikigami -name '*.hs' -print0 | xargs -0 cat | wc -l
find Shikigami -name '*.hs' | awk -F/ '{n=$2; sub(/\.hs$/,"",n); print n}' | sort -u | wc -l
grep -rlE 'import Shikigami\.(Watchdog|Initiative|PracticeReview)' Shikigami | wc -l
```

```text
437
78094
63
38
```

The earlier estimate at M7 was about 64,000 lines and 60 namespaces. It assumed the
hand-written adaptive coordinator (about 1,090 lines) would leave, which it no longer does, so
expect roughly 65,000 lines; the namespace count is still 60, because `Watchdog`,
`Initiative` and `PracticeReview` are gone and the `Coordination` and `AdaptiveDelivery` roots
stay. Treat both as estimates and record the measured values. The last count should be 0.

Pre-release recheck and drain. Run it immediately before M1, M2, M3, M4, M5 and M6 land, and
record the result in the Decision Log:

```bash
git tag --list                                   # expect empty: no release
grep -n "exception ended" docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md
shikigami --config config.json runs --help       # use the listed verbs to confirm no non-terminal AgentRun
```

Record the facts: no external wire consumers, no release, and no non-terminal run in the
local database. MasterPlan 22 ends the exception at EP-11's baseline gate, and EP-11 depends
on this plan being Complete, so the `grep` should find no such entry. If it does, stop and
raise it with the MasterPlan: this plan's label and codec changes assume the exception. Until
the gate, the rule is the drain rule. EP-7's campaign may be running pilot runs on this
machine; let every non-terminal run reach a terminal state, or have the operator abandon it,
before landing a milestone. A terminal run journaled before the change may become unreadable
by `runs show`; its durable results are the commits and receipts it left in the target
repositories.

Build and gate after each milestone:

```bash
cabal build all
cabal test all
just haskell-conventions
just keiro-gate
```

The expected gate result for M2 to M5 is one `WorkflowBodyChanged` finding for
`shikigami.agent-run` that names only the labels and patch ids the milestone deleted. M6
changes no workflow body, so its gate must report no finding. Record
it verbatim. For M1, record whatever the codec change reports. Also run `just kernel-fitness`
and each pack's test suite, which checks its golden label inventory.

Run the local stack for real-use checks in a second terminal:

```bash
process-compose up            # PostgreSQL; runs `just create-database`
```


## Validation and Acceptance

"No supported feature lost" is the overriding acceptance criterion. Every milestone ends
with the feature it moved running for real on this Mac, through the same operator verbs as
before, against the local PostgreSQL started by `process-compose up` and the operator's own
repositories. From M2 on, every run of a moved use case uses the `kikan-shikigami`
distribution's executables, built with `cabal build kikan-shikigami` and run with
`cabal run kikan-shikigami:exe:<name> --`: `kikan-shikigami-worker`,
`kikan-shikigami-scheduler`, `kikan-shikigami-consume-stream`, `kikan-shikigami-server` and
the admin CLI `kikan-shikigami`. After each move, also confirm the other half: the stock
`shikigami` and `shikigami-worker` no longer list the moved flow, verb or setting. The real
runs assume EP-1's `LocalOperator` tier
(`docs/plans/126-run-declared-agents-on-the-operator-s-own-machine-through-a-local-operator-trust-tier.md`),
which lands earlier on the critical path. If it has not landed, use the existing worker
configuration and note that in Outcomes. Fixture tests still move with their code and must
pass, but they are not substitutes for these runs.

For M1, rerun EP-1's real Skill run on a checkout under `/Users/shinzui/Keikaku/bokuno/`,
such as `keiro`, and observe the same successful completion. Also, every manifest under
`agents/` and `agents/proof/` passes `shikigami validate <file>`.

For M2, start `kikan-shikigami-worker --agents agents/proof` and enqueue the
`objective-example` flow. Then `kikan-shikigami --config config.json objectives inspect <id>
--json` shows the objective it created, planned and progressed. The worker's startup log
carries EP-5's `flow.registry.composed` event naming the composed packs and their flows. It
is the operator's evidence of composition. The stock `shikigami-worker --agents agents/proof`
refuses to boot on the same directory, naming `objective-example` as an unknown flow.

For M3, send a version-1 `target-change` trigger (format in
`docs/user/architecture-practice-reviews.md`) to `architecture-practice-router`. Name a
real local repository and its real head revision. Observe the same outcome as a run on the
pre-move build: today that is the specialist's `unresolved` verdict with a recorded
`content-plane-unavailable` problem. A local-checkout content reader for `LocalOperator`
would let the review read real evidence. That is a proposed scope addition, not required.

For M4, publish one `activity.v1` envelope with source `external/transcripts`, containing
an excerpt of a real meeting note, to the stream consumed by
`agents/proof/proposer.dhall` (see `docs/operations/unrequested-work.md`). Observe the
approval request text "Unrequested proposal from agent proposer …". Approve it with
`kikan-shikigami resolve-approval TOKEN --approve`. Then `kikan-shikigami proposals inspect
--json` and `kikan-shikigami objectives inspect` show the accepted proposal and its new
objective. `shikigami proposals --help` on the stock CLI reports an unknown command.

For M5, with the watchdog schedule and allowance configured (`docs/operations/watchdog.md`)
and a real objective active from M2 or M4, wait one tick. Then
`kikan-shikigami --config config.json watchdog inspect --agents agents --json` shows a completed
sweep whose coverage includes that objective, and
`watchdog inspect --fail-when-overdue` exits 0.

For M6, create an objective with one delivery assignment for a real local repository, as
in `docs/user/adaptive-delivery.md`, and run `agents/proof/adaptive-delivery.dhall` against
it with the stock `shikigami-worker`, which composes no pack. `shikigami objectives inspect
<id> --json` shows an accepted adaptive decision and the dispatched assignment, the same
outcome as before this plan. The planted-import check from M6 step 2 fails and then passes,
and `just keiro-gate` reports no body change.

For M7, run all packs in one `kikan-shikigami-worker` session together with a kernel
mandate, created with `kikan-shikigami mandates create … --file mandate.json` on the M4
objective as in `docs/operations/recurring-objectives.md`. `kikan-shikigami mandates inspect
<name> --json` shows a completed cycle, and the M2–M6 observations hold in the same session.
Mandates are kernel, so the stock `shikigami mandates inspect` shows the same cycle. The
before/after measurement is recorded, `kernel.namespaces` no longer contains `Watchdog`,
`Initiative` or `PracticeReview`, `just kernel-fitness` passes, every pack's golden label
inventory passes, and
`grep -nE 'watchdog-|initiative-|practice-review-|objectives-example-' domain/shikigami/agent-run.keiro`
prints nothing. No milestone adds a Linux or Apple-container qualification gate.


## Idempotence and Recovery

Each milestone is one or a few commits that build and pass on their own. A failed move is
reverted with `git revert` of that milestone's commits, and no data migration is involved.
Tables never move, so a database migrated at any point stays valid for every build. The
measurement, recheck and gate commands are read-only and can be repeated. Moves use
`git mv` so history follows the files. Each move deliberately changes the `AgentRun` body
(the moved labels and patch gates leave it), so the expected `keiro-gate` finding names only
those. If it names a kernel label, a kernel step was reordered or renamed by accident: fix
that instead of accepting the finding. Because the body changes, a run journaled by the old
build does not replay on the new one. Drain every run to a terminal state before switching
the local workers to a build that moves a pack, and never revert across a move while a run
started on the newer build is still in flight. If a pack's golden label inventory fails, the
diff is the list of renamed labels; update the file only when the rename was intended.


## Interfaces and Dependencies

Freeze ordering: EP-11's first freeze (the declaration baseline) requires this plan's M1 and
nothing else from it, and may land while M2 to M7 are in progress. After it, a later
milestone that would change `schema/Agent.dhall`, the `AgentDecl` journal codec, the playbook
format, the operator files or a stock local-work command (`shikigami-agent-run`,
`shikigami-local`, `shikigami-tools`, `shikigami playbook`) stops and raises it with the
MasterPlan. Step labels, patch gates, the pack SDK and the admin CLI stay changeable under
the drain rule until EP-11's second freeze, which requires this whole plan Complete.

Hard prerequisite: EP-5
(`docs/plans/130-move-the-extension-boundary-out-of-shikigami-core-with-flow-packs-and-an-architecture-fitness-check.md`)
must be Complete. Its pack API (`Shikigami.Flow.Pack` with `PackFlow` and `FlowRunContext`),
both SDK components, the `...With` entry points, `packs/flow-pack-examples`, the label rule
and the `kernel` section of `tools/style/module-ownership.json` with its test group in
`shikigami-core/test/Shikigami/PackageArchitectureSpec.hs` must exist before M2. M1 can
start at once. EP-4 (`docs/plans/129-…`) is a soft dependency that this plan does not need
(see the Decision Log). For EP-4 to absorb a pack later, its format would need a
typed-decision step over a registered program, a step that runs a named declared agent as a
governed child and returns its result (which would cover `delegation-proof`), and a
scheduled playbook trigger. The real runs depend on EP-1's `LocalOperator` tier in
practice.

Interfaces this plan introduces in `shikigami-core`, as sketched in Plan of Work: three
fields on EP-5's `Shikigami.Flow.Pack.FlowPack` (`settings` with `PackSetting`, `adminVerbs`
with `AdminVerb` and `triggers`); `Shikigami.Trigger.Hook` (`TriggerHooks`,
`StreamHook`, `StreamDisposition`, `ScheduleHook`, `ScheduledAllowance`,
`enrollScheduledRootTx`); the checked `DecisionSite` and `RouteSite` coordinates with
`DecisionMode` and `SlotPolicy` on `FlowDef`; and the reviewed additions to
`shikigami-core:flow-sdk` and `shikigami-core:pack-sdk` listed per milestone. This plan
defines no pack type. Where EP-5 defines a type, extend it and record that in the Decision
Log; do not add a parallel one.
`FlowEffects` shrinks from 18 capabilities to 11: `Workflow`, `Memory`, `Sink`, `Activity`,
`Acknowledgement`, `Delegate`, `Workers`, `AdaptiveDelivery`, `Objectives`, `Routing` and
`Decision`. `AdaptiveDelivery` stays because its coordinator is kernel.
`AgentRunDeps` loses `initiatives`, `observe` and `practiceReview`. The new types follow the
nominal and sealed-value patterns already used by `DeclarationCoordinate` and
`ValidatedRouterDeclaration`, use unprefixed strict fields (AGENTS.md), and use closed sums
instead of booleans or name comparisons.

Packages created under `packs/`: `flow-pack-practice-review`, `flow-pack-initiative` and
`flow-pack-watchdog`, plus the distribution
`kikan-shikigami`; EP-5's `flow-pack-examples` is extended. Each pack depends only on
`shikigami-core:flow-sdk` and `shikigami-core:pack-sdk`. Only `kikan-shikigami` (and EP-5's
`examples-distribution`) composes packs; `shikigami-workers`, `shikigami-server` and
`shikigami-agent` depend on none, so the stock executables and the ADR-39 Nix roles built
from them stop offering the moved use cases. Nix packaging of the distribution is excluded
by MasterPlan 22.

Later consumers. EP-10
(`docs/plans/135-move-the-kikan-service-bindings-out-of-shikigami-core-and-compose-a-kikan-distribution.md`)
moves the Kikan service bindings out of the core and adds its binding package to
`kikan-shikigami`. EP-8
(`docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md`)
replaces the closed `Sink` with an output port; a pack that delivers signals (practice review,
initiative, watchdog) uses that port once it exists. EP-11
(`docs/plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md`)
requires this plan Complete and freezes the SDK export lists this plan grew.

Dependencies whose APIs matter are keiro (`Keiro.Workflow`
`step`, `patch` and `WorkflowRegistry`) and effectful (`interpret`). Locate their sources
with `mori registry show shinzui/keiro --full`, not from memory.

Revision note (2026-11-15, MasterPlan 22 review): this plan now consumes EP-5's single pack
API instead of defining its own. Packs were renamed `flow-pack-*` and depend only on the two
SDK components, with the kernel modules each needs listed per milestone. The stock
executables compose no pack and the `kikan-shikigami` distribution was added. Moved labels
and patch gates now leave the core specification, and the drain rule with EP-11's baseline
gate replaced the first-deployment fallback.

Revision note (2026-11-15, user decision): the adaptive-delivery coordinator stays in the
kernel because it has no Kikan service dependency. M6 became a confirmation milestone, no
`flow-pack-adaptive-delivery` is created, and the `workflows` pack field was dropped.
