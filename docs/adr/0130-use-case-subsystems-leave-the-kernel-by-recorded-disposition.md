# 0130. Use-case subsystems leave the kernel by recorded disposition

Date: 2026-11-16

Status: accepted


## Context

[ADR-129](0129-the-kernel-owns-primitives-and-use-cases-ship-as-declarations-or-packs.md)
says `shikigami-core` owns primitives and a use case ships as a declaration or a flow pack.
When it was written, the core still held four use-case subsystems compiled into the
kernel's `AgentRun` workflow: the active-work watchdog, unrequested-work proposals
(`Initiative`), architecture-practice reviews (`PracticeReview`) and a set of teaching
flows. It also declared a `Deterministic` behavior arm the runner always refused. Each use
case had widened `FlowEffects`, the `AgentRunDeps` record and the flow runner, and had put
its labels and `patch` gates in `domain/shikigami/agent-run.keiro`.

Several subsystems looked like use cases and were not. Deciding each one by hand at move
time would have let the next reviewer re-argue it, so plan 131 classified every candidate
first, traced through imports, the domain specification, migrations, workers, server verbs
and docs, and then moved them largest and least coupled first.


## Decision

Every subsystem that could be a use case has a recorded disposition. A use case leaves the
kernel for a pack under `packs/`; a primitive stays and is listed `kernel` in
`kernel.namespaces` of `tools/style/module-ownership.json`; a declared feature the runtime
never executes is retired.

| Subsystem | Disposition | Where it is now |
| --- | --- | --- |
| `Deterministic` behavior arm | Retired | deleted from `Agent.Decl`, `schema/Agent.dhall`, the runner and the catalog ([ADR-1](0001-declare-only-what-the-runtime-executes.md)) |
| `objective-example`, `shikumi-decision-example`, `shikumi-judgment-example`, `delegation-proof`, `at-risk-customer` and their programs | Pack | `packs/flow-pack-examples` |
| `PracticeReview*`, `opentelemetry-practice-review`, `architecture-practice-router` | Pack | `packs/flow-pack-practice-review` |
| `Initiative/*`, `propose-work`, its assessment program and the `proposals` verbs | Pack | `packs/flow-pack-initiative` |
| `Watchdog/*`, `watchdog-sweep`, `Observe`, the drift program and the `watchdog` verbs | Pack | `packs/flow-pack-watchdog` |
| Adaptive-delivery coordinator (`Coordination.{Workflow,Runtime,Capability,Commands,Direct,Decision,DecisionAuthority}`, `Flow.AdaptiveDelivery`, `Program.Decision.Adaptive`) | Kernel | adaptive coordination ([ADR-111](0111-adaptive-delivery-carries-native-admission-and-reference-only-seeds.md)) |
| `Coordination.{Proposal,Validate,Sql,Wake,Checkpoint,Observation,Types,Identity}` | Kernel | objective organization ([ADR-108](0108-adaptive-decisions-commit-with-authoritative-checkpoints.md)) |
| `Router/*`, `Flow.Routing` | Kernel | governed delegation ([ADR-28](0028-a-router-catalog-is-a-bounded-snapshot-of-declared-authority.md), [ADR-29](0029-model-routing-output-is-a-proposal-until-validated-against-journaled-authority.md)) |
| `Mandate*`, `RecurringObjective`, `RecurringCheckpointCycle` | Kernel | recurring objective authority ([ADR-121](0121-recurring-mandates-retain-authority-checkpoint-receipts-and-generation-owned-wakes.md)) |

The verdicts that look surprising are the kernel ones, and each has a test of its own
reason:

* **Router is kernel.** `Router.Catalog` and `Router.SelectionLimit` implement the
  delegation allow-list that `Agent.Decl`, `Agent.Delegate` and `Flow.Decision` use for
  every delegating agent. Only the `architecture-practice-router` flow and its closed route
  label were use-case code; the route site is now an open, checked value and the flow went
  with practice review.
* **Mandates are kernel.** A recurring mandate is the authority under which any objective is
  supervised over time: it owns checkpoint receipts and generation-owned wakes for
  objectives the kernel owns. No use case calls it that another could not.
* **The adaptive coordinator is kernel** (user decision, 2026-11-15). It is how an objective
  is organized, it reaches about 55 kernel modules and no Kikan service, and its tables are
  read by the kernel objective store. The `CoordinatorImportsBinding` rule of the
  `kernel boundary` group keeps it that way: no coordinator module may import a Kikan
  binding (`Shikigami.Sink.{KawaClient, KizashiClient, Danwa, KanmonClient, ReiAction}`,
  `Shikigami.Integration.Danwa`, `Shikigami.Authority.KikanEn*` or
  `Shikigami.DanwaConversation`).

A move is complete only when the kernel no longer names the use case: its namespace leaves
`kernel.namespaces` and `kernel.frozenModules`, its capability leaves `FlowEffects`, its
seed leaves `AgentRunDeps`, the runner loses every by-name branch, and its labels and
`patch` blocks leave `domain/shikigami/agent-run.keiro`, which now holds only the kernel's
two patch blocks, `shikigami-adaptive-delivery-v1` and `shikigami-objective-tracking-v1`.
The moved labels were renamed to start with the pack's name and are pinned by each pack's
`test/golden/labels.txt`. Removing the patch blocks used the pre-release exception of
[ADR-27](0027-the-first-release-establishes-one-clean-durable-baseline.md), after draining
every run that could replay them.

To move these four subsystems the kernel grew the hooks a pack contributes through its one
`FlowPack` value: `settings` (a pack-owned configuration key), `triggers` (a stream-intake
hook and a schedule-allowance hook, after which the kernel enrolls the root), `adminVerbs`,
`gauges` and the `shikigami.pack.events` counter. The final `pack-sdk` re-exports, grouped
by why an interpreter needs them:

| Group | Modules | Why |
| --- | --- | --- |
| The pack API | `Shikigami.Pack.Sdk` | The facade: `FlowPack`, `PackFlow`, `FlowRunContext`, settings, hooks, verbs, gauges and counters. |
| Process and directory | `Shikigami.App`, `Shikigami.Directory` | An admin verb runs in `AppEffects`, and interpreters resolve principals against the directory snapshot. |
| Memory | `Shikigami.Memory.Access`, `Shikigami.Memory.Scope` | Practice review writes and adjudicates review memory. |
| Output | `Shikigami.Sink`, `Shikigami.Sink.Delivery`, `Shikigami.Sink.Intent` | Practice review reserves attention and writes its own intents in its transaction. |
| Triggers | `Shikigami.Trigger.Enqueue`, `Shikigami.Trigger.RequestKey`, `Shikigami.Trigger.Schedule` | Stream and schedule hooks enqueue jobs and key their requests. |
| Objectives and resources | `Shikigami.Objective.{Association, Reference, Store}`, `Shikigami.Execution.ResourcesStore`, `Shikigami.Agent.Run.Key` | Initiative funds and launches a coordinator's run for an admitted objective. |
| Read surfaces for observation | `Shikigami.Approval.Observation`, `Shikigami.Agent.Approval.Workflow`, `Shikigami.ExecutionDriver.Generated.WorkflowRuntime`, `Shikigami.Agent.Workflow.Name`, `Shikigami.Workspace.Types` | The watchdog reads other owners' state without their locks. |
| Declarations | `Shikigami.Agent.Loader` | `watchdog inspect --agents DIR` loads a directory the operator names. |

Six of these are kernel internals exported whole because moved code needed them:
`Execution.ResourcesStore`, `Objective.Association`, `Objective.Store`,
`ExecutionDriver.Generated.WorkflowRuntime`, `Agent.Approval.Workflow` and `Agent.Loader`.
They are named for narrowing before the kernel freeze (plan 136, M3); "fund and launch a
coordinator's run" is the candidate kernel operation for the first three.


## Alternatives rejected

**Move the adaptive coordinator with the use cases.** It was in the first draft. It would
have needed a `workflows` field on `FlowPack` and a `pack-sdk` export of most of the
objective and execution internals, for a component every objective uses.

**Keep the moved flows compiled into the core and only hide them from the stock
executables.** The coupling that mattered was in `FlowEffects`, `AgentRunDeps`, the runner
and the core specification, not in the registry list.

**Keep `Deterministic` as a placeholder.** The runner refused every declaration that used
it, so a valid manifest could name behavior no build could run.


## Consequences

The stock executables, and the Nix role packages built from them in `flake.module.nix`, no
longer offer the moved use cases. `shikigami-worker` refuses to boot on a manifest naming a
moved flow, the stock `shikigami` has no `proposals` or `watchdog` verb, and every stock
executable refuses `initiatives`, `watchdog` and `practice_review.attention_recipients` as
unknown configuration keys. They run from the `packs/kikan-shikigami` distribution
(`kikan-shikigami-worker`, `kikan-shikigami-scheduler`, `kikan-shikigami-consume-stream`,
`kikan-shikigami` and `kikan-shikigami-agent-run`), which has no Nix role package yet.

A pack's tables stay in the one ordered migration chain; `docs/architecture/packages.md`
records which pack reads and writes each. The watchdog pack's test suite compiles 21 kernel
spec modules from `shikigami-core/test` and `test-postgres` until a public
`shikigami-core:test-support` library exists, so renaming those modules breaks it.

The decisions of the moved subsystems' own ADRs still hold; only where their code lives
changed. Those ADRs carry a note saying so.


## References

* [docs/plans/131-shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems.md](../plans/131-shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems.md)
  — the classification, the moves and their real-run evidence.
* [docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md](../masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md)
  — the initiative.
* `shikigami-core/test/Shikigami/KernelBoundarySpec.hs` — the fitness check, including
  `CoordinatorImportsBinding`.
