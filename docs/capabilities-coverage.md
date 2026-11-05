# Capability coverage census

This census was checked on 2026-10-29 against the Cabal manifests, public module
exports, executable entry points, administrative parser, implementation, tests,
and current user/operations documentation. It maps **seven packages, 226 exposed
modules, twelve executables, and fourteen repository-owned administrative command
families** to the capability catalog or an explicit supporting-surface exclusion.

This is a coverage audit of the current consumer surface, not a declaration that
every function is a separate capability or that all runtime behavior was tested.
The listed tests were inspected as evidence; they were not rerun for this
documentation change. Private implementation and generated modules support the
mapped provisions and are not independently importable consumer interfaces.

## Package boundary

| Package | Exposed modules | Executables |
| --- | ---: | ---: |
| [shikigami-agent](../shikigami-agent/shikigami-agent.cabal) | 6 | 3 |
| [shikigami-api](../shikigami-api/shikigami-api.cabal) | 7 | 1 |
| [shikigami-client](../shikigami-client/shikigami-client.cabal) | 2 | 1 |
| [shikigami-core](../shikigami-core/shikigami-core.cabal) | 162 | 0 |
| [shikigami-migrations](../shikigami-migrations/shikigami-migrations.cabal) | 2 | 1 |
| [shikigami-server](../shikigami-server/shikigami-server.cabal) | 30 | 2 |
| [shikigami-workers](../shikigami-workers/shikigami-workers.cabal) | 17 | 4 |

The migration count includes its public `test-support` sublibrary. Counts come
from `exposed-modules` and `executable` declarations, not all source files.

## Public module families

Families below partition all exposed modules. Where prefixes overlap, the
most specific row owns that family. A count includes only modules assigned
to that row. Capability links describe the provision; modules sharing one
mechanism remain grouped under that provision.

| Package | Module or family under `Shikigami.` | Modules | Catalog mapping |
| --- | --- | ---: | --- |
| shikigami-agent | `Agent.Capability` | 2 | [CAP-12](capabilities/revision-pinned-tool-overlays.md) |
| shikigami-agent | `Agent.Command` | 1 | [CAP-17](capabilities/worker-operations-and-telemetry.md) |
| shikigami-agent | `Agent.Command.AgentRun` | 1 | [CAP-4](capabilities/durable-agent-flows.md), [CAP-5](capabilities/agent-memory-and-sessions.md) |
| shikigami-agent | `Agent.Command.Launch` | 1 | [CAP-18](capabilities/foreground-agent-launches.md) |
| shikigami-agent | `Agent.Command.RunBehavior` | 1 | [CAP-3](capabilities/program-and-skill-execution.md) |
| shikigami-api | `Api` | 3 | [CAP-16](capabilities/http-health-contract.md) |
| shikigami-api | `Agent.Api` | 1 | [CAP-22](capabilities/declared-agent-http-catalog.md) |
| shikigami-api | `AgentRun.Api` | 1 | [CAP-24](capabilities/idempotent-http-agent-runs.md), [CAP-25](capabilities/http-agent-run-lifecycle.md) |
| shikigami-api | `Caller.Api` | 1 | [CAP-23](capabilities/http-caller-authentication.md) |
| shikigami-api | `Health` | 1 | [CAP-16](capabilities/http-health-contract.md) |
| shikigami-client | `Client` | 2 | [CAP-16](capabilities/http-health-contract.md), [CAP-22](capabilities/declared-agent-http-catalog.md), [CAP-23](capabilities/http-caller-authentication.md), [CAP-24](capabilities/idempotent-http-agent-runs.md), [CAP-25](capabilities/http-agent-run-lifecycle.md) |
| shikigami-core | `Action` | 2 | [CAP-7](capabilities/exact-action-authorization.md) |
| shikigami-core | `Activity` | 1 | [CAP-2](capabilities/durable-trigger-intake.md) |
| shikigami-core | `Agent.Approval` | 3 | [CAP-10](capabilities/durable-human-approval.md) |
| shikigami-core | `Agent.Conversation` | 2 | [CAP-11](capabilities/addressed-conversations.md) |
| shikigami-core | `Agent.Catalog` | 1 | [CAP-22](capabilities/declared-agent-http-catalog.md) |
| shikigami-core | `Agent.Decl` | 1 | [CAP-1](capabilities/typed-agent-declarations.md) |
| shikigami-core | `Agent.Delegate` | 3 | [CAP-8](capabilities/governed-routing-and-delegation.md) |
| shikigami-core | `Agent.Loader` | 1 | [CAP-1](capabilities/typed-agent-declarations.md) |
| shikigami-core | `Agent.Name` | 1 | [CAP-1](capabilities/typed-agent-declarations.md) |
| shikigami-core | `Agent.Principal` | 1 | [CAP-6](capabilities/principal-lifecycle-and-continuity.md) |
| shikigami-core | `Agent.Run` | 1 | [CAP-5](capabilities/agent-memory-and-sessions.md) |
| shikigami-core | `Agent.Run.Key` | 1 | [CAP-4](capabilities/durable-agent-flows.md) |
| shikigami-core | `Agent.RunFailure` | 1 | [CAP-4](capabilities/durable-agent-flows.md) |
| shikigami-core | `Agent.RunJob` | 1 | [CAP-2](capabilities/durable-trigger-intake.md) |
| shikigami-core | `Agent.Skill` | 1 | [CAP-3](capabilities/program-and-skill-execution.md) |
| shikigami-core | `Agent.Workflow` | 3 | [CAP-4](capabilities/durable-agent-flows.md) |
| shikigami-core | `AgentRun.Ledger` | 1 | [CAP-24](capabilities/idempotent-http-agent-runs.md), [CAP-25](capabilities/http-agent-run-lifecycle.md) |
| shikigami-core | `AgentRun.Status` | 1 | [CAP-25](capabilities/http-agent-run-lifecycle.md) |
| shikigami-core | `App` | 4 | [CAP-17](capabilities/worker-operations-and-telemetry.md) |
| shikigami-core | `Attestation` | 7 | [CAP-14](capabilities/run-evidence-and-compliance.md) |
| shikigami-core | `Attestation.CallFacts` | 1 | [CAP-21](capabilities/typed-flow-decisions.md), [CAP-14](capabilities/run-evidence-and-compliance.md) |
| shikigami-core | `Attestation.Profile` | 1 | [CAP-13](capabilities/sanctioned-execution-profiles.md) |
| shikigami-core | `Attestation.Resolve` | 1 | [CAP-13](capabilities/sanctioned-execution-profiles.md) |
| shikigami-core | `Behavior` | 7 | [CAP-3](capabilities/program-and-skill-execution.md) |
| shikigami-core | `Behavior.Provider.Call` | 1 | [CAP-21](capabilities/typed-flow-decisions.md), [CAP-13](capabilities/sanctioned-execution-profiles.md) |
| shikigami-core | `Capability` | 4 | [CAP-12](capabilities/revision-pinned-tool-overlays.md) |
| shikigami-core | `Core` | 1 | Support only: placeholder/version or common name/prelude helpers. |
| shikigami-core | `Decision` | 4 | [CAP-21](capabilities/typed-flow-decisions.md) |
| shikigami-core | `Directory` | 2 | [CAP-6](capabilities/principal-lifecycle-and-continuity.md) |
| shikigami-core | `Flow` | 4 | [CAP-4](capabilities/durable-agent-flows.md) |
| shikigami-core | `Flow.Acknowledgement` | 1 | [CAP-10](capabilities/durable-human-approval.md) |
| shikigami-core | `Flow.Capability` | 1 | [CAP-4](capabilities/durable-agent-flows.md), [CAP-5](capabilities/agent-memory-and-sessions.md), [CAP-9](capabilities/authorized-sink-outbox.md) |
| shikigami-core | `Flow.Decision` | 1 | [CAP-21](capabilities/typed-flow-decisions.md) |
| shikigami-core | `Flow.Delegate` | 1 | [CAP-8](capabilities/governed-routing-and-delegation.md) |
| shikigami-core | `Flow.OpenTelemetryPracticeReview` | 1 | [CAP-15](capabilities/advisory-practice-review.md) |
| shikigami-core | `Flow.Routing` | 1 | [CAP-8](capabilities/governed-routing-and-delegation.md) |
| shikigami-core | `Generated.Conformance` | 1 | [CAP-4](capabilities/durable-agent-flows.md), [CAP-14](capabilities/run-evidence-and-compliance.md) |
| shikigami-core | `Health` | 1 | [CAP-16](capabilities/http-health-contract.md) |
| shikigami-core | `Id` | 1 | Support only: placeholder/version or common name/prelude helpers. |
| shikigami-core | `Integration` | 1 | [CAP-11](capabilities/addressed-conversations.md) |
| shikigami-core | `Log` | 2 | [CAP-17](capabilities/worker-operations-and-telemetry.md) |
| shikigami-core | `Memory` | 3 | [CAP-5](capabilities/agent-memory-and-sessions.md) |
| shikigami-core | `PracticeReview` | 6 | [CAP-15](capabilities/advisory-practice-review.md) |
| shikigami-core | `Prelude` | 1 | Support only: placeholder/version or common name/prelude helpers. |
| shikigami-core | `Program` | 1 | [CAP-3](capabilities/program-and-skill-execution.md) |
| shikigami-core | `Program.Decision` | 2 | [CAP-21](capabilities/typed-flow-decisions.md) |
| shikigami-core | `Program.DecisionRunner` | 1 | [CAP-21](capabilities/typed-flow-decisions.md) |
| shikigami-core | `Repository` | 1 | [CAP-15](capabilities/advisory-practice-review.md) |
| shikigami-core | `Router` | 3 | [CAP-8](capabilities/governed-routing-and-delegation.md) |
| shikigami-core | `RunEvidence` | 2 | [CAP-14](capabilities/run-evidence-and-compliance.md) |
| shikigami-core | `RunJobs` | 1 | [CAP-2](capabilities/durable-trigger-intake.md) |
| shikigami-core | `Runtime` | 1 | [CAP-3](capabilities/program-and-skill-execution.md), [CAP-7](capabilities/exact-action-authorization.md), [CAP-13](capabilities/sanctioned-execution-profiles.md), [CAP-17](capabilities/worker-operations-and-telemetry.md) |
| shikigami-core | `Sink` | 17 | [CAP-9](capabilities/authorized-sink-outbox.md) |
| shikigami-core | `Sink.Authorization` | 1 | [CAP-7](capabilities/exact-action-authorization.md), [CAP-9](capabilities/authorized-sink-outbox.md) |
| shikigami-core | `Store.DelegationBudget` | 1 | [CAP-8](capabilities/governed-routing-and-delegation.md) |
| shikigami-core | `Telemetry` | 2 | [CAP-17](capabilities/worker-operations-and-telemetry.md) |
| shikigami-core | `Trigger` | 3 | [CAP-2](capabilities/durable-trigger-intake.md) |
| shikigami-core | `Workflow` | 2 | [CAP-4](capabilities/durable-agent-flows.md) |
| shikigami-migrations | `Migrations` | 2 | [CAP-19](capabilities/database-migrations-and-bootstrap.md) |
| shikigami-server | `Agent.Handler` | 1 | [CAP-22](capabilities/declared-agent-http-catalog.md) |
| shikigami-server | `AgentRun.Handler` | 1 | [CAP-24](capabilities/idempotent-http-agent-runs.md), [CAP-25](capabilities/http-agent-run-lifecycle.md) |
| shikigami-server | `Caller.Verifier` | 1 | [CAP-23](capabilities/http-caller-authentication.md) |
| shikigami-server | `Health` | 1 | [CAP-16](capabilities/http-health-contract.md) |
| shikigami-server | `Server` | 6 | [CAP-16](capabilities/http-health-contract.md), [CAP-17](capabilities/worker-operations-and-telemetry.md) |
| shikigami-server | `Server.Command` | 1 | [CAP-17](capabilities/worker-operations-and-telemetry.md) |
| shikigami-server | `Server.Command.Agents` | 1 | [CAP-6](capabilities/principal-lifecycle-and-continuity.md) |
| shikigami-server | `Server.Command.DanwaSpike` | 1 | [CAP-20](capabilities/local-integration-fixtures.md) |
| shikigami-server | `Server.Command.EnqueueRun` | 1 | [CAP-2](capabilities/durable-trigger-intake.md) |
| shikigami-server | `Server.Command.Grants` | 1 | [CAP-9](capabilities/authorized-sink-outbox.md) |
| shikigami-server | `Server.Command.Ops` | 1 | [CAP-17](capabilities/worker-operations-and-telemetry.md) |
| shikigami-server | `Server.Command.PublishFixture` | 1 | [CAP-20](capabilities/local-integration-fixtures.md) |
| shikigami-server | `Server.Command.RenderLifecycle` | 1 | [CAP-4](capabilities/durable-agent-flows.md) |
| shikigami-server | `Server.Command.ResolveApproval` | 1 | [CAP-10](capabilities/durable-human-approval.md) |
| shikigami-server | `Server.Command.Runs` | 1 | [CAP-17](capabilities/worker-operations-and-telemetry.md) |
| shikigami-server | `Server.Command.StubKanmon` | 1 | [CAP-20](capabilities/local-integration-fixtures.md) |
| shikigami-server | `Server.Command.StubKawa` | 1 | [CAP-20](capabilities/local-integration-fixtures.md) |
| shikigami-server | `Server.Command.Validate` | 1 | [CAP-1](capabilities/typed-agent-declarations.md) |
| shikigami-server | `Sink` | 3 | [CAP-20](capabilities/local-integration-fixtures.md) |
| shikigami-server | `Trigger` | 1 | [CAP-20](capabilities/local-integration-fixtures.md) |
| shikigami-workers | `Agent.RunJob` | 1 | [CAP-2](capabilities/durable-trigger-intake.md), [CAP-17](capabilities/worker-operations-and-telemetry.md) |
| shikigami-workers | `Agent.Workflow` | 1 | [CAP-4](capabilities/durable-agent-flows.md), [CAP-17](capabilities/worker-operations-and-telemetry.md) |
| shikigami-workers | `Flow` | 1 | [CAP-9](capabilities/authorized-sink-outbox.md) |
| shikigami-workers | `Health` | 1 | [CAP-16](capabilities/http-health-contract.md) |
| shikigami-workers | `Telemetry` | 2 | [CAP-17](capabilities/worker-operations-and-telemetry.md) |
| shikigami-workers | `Trigger` | 3 | [CAP-2](capabilities/durable-trigger-intake.md) |
| shikigami-workers | `Workers` | 8 | [CAP-17](capabilities/worker-operations-and-telemetry.md) |
| shikigami-core | `Store.ExecutionResources` | 1 | [CAP-26](capabilities/root-resource-accounting.md) |
| shikigami-core | `Store.ExecutionSelection` | 1 | [CAP-27](capabilities/assignment-execution-selection.md) |
| shikigami-core | `Execution` | 21 | [CAP-26](capabilities/root-resource-accounting.md), [CAP-27](capabilities/assignment-execution-selection.md), [CAP-28](capabilities/recoverable-skill-execution.md) |
| shikigami-core | `ExecutionDriver` | 2 | [CAP-28](capabilities/recoverable-skill-execution.md) |
| shikigami-core | `WorkerSession` | 12 | [CAP-29](capabilities/continuing-worker-primitives.md) |
| shikigami-core | `Workspace` | 1 | [CAP-30](capabilities/repository-catalog-admission.md) |
| shikigami-core | `Flow.Workers` | 1 | [CAP-29](capabilities/continuing-worker-primitives.md) |
| shikigami-server | `Server.Command.Resources` | 1 | [CAP-26](capabilities/root-resource-accounting.md) |
| shikigami-server | `Server.Command.Executions` | 1 | [CAP-28](capabilities/recoverable-skill-execution.md) |
| shikigami-server | `Server.Command.Workers` | 1 | [CAP-29](capabilities/continuing-worker-primitives.md) |


## Executable entry points

| Executable | Package | Catalog mapping |
| --- | --- | --- |
| `shikigami-run-behavior` | shikigami-agent | [CAP-3](capabilities/program-and-skill-execution.md) |
| `shikigami-agent-launch` | shikigami-agent | [CAP-18](capabilities/foreground-agent-launches.md) |
| `shikigami-agent-run` | shikigami-agent | [CAP-4](capabilities/durable-agent-flows.md), [CAP-5](capabilities/agent-memory-and-sessions.md) |
| `shikigami-openapi` | shikigami-api | [CAP-16](capabilities/http-health-contract.md) |
| `shikigami-client` | shikigami-client | [CAP-16](capabilities/http-health-contract.md), [CAP-22](capabilities/declared-agent-http-catalog.md), [CAP-23](capabilities/http-caller-authentication.md), [CAP-24](capabilities/idempotent-http-agent-runs.md), [CAP-25](capabilities/http-agent-run-lifecycle.md) |
| `shikigami-migrate` | shikigami-migrations | [CAP-19](capabilities/database-migrations-and-bootstrap.md) |
| `shikigami-server` | shikigami-server | [CAP-16](capabilities/http-health-contract.md), [CAP-17](capabilities/worker-operations-and-telemetry.md), [CAP-22](capabilities/declared-agent-http-catalog.md), [CAP-23](capabilities/http-caller-authentication.md), [CAP-24](capabilities/idempotent-http-agent-runs.md), [CAP-25](capabilities/http-agent-run-lifecycle.md) |
| `shikigami` | shikigami-server | [CAP-1](capabilities/typed-agent-declarations.md), [CAP-2](capabilities/durable-trigger-intake.md), [CAP-4](capabilities/durable-agent-flows.md), [CAP-6](capabilities/principal-lifecycle-and-continuity.md), [CAP-9](capabilities/authorized-sink-outbox.md), [CAP-10](capabilities/durable-human-approval.md), [CAP-17](capabilities/worker-operations-and-telemetry.md), [CAP-20](capabilities/local-integration-fixtures.md) |
| `shikigami-worker` | shikigami-workers | [CAP-4](capabilities/durable-agent-flows.md), [CAP-9](capabilities/authorized-sink-outbox.md), [CAP-17](capabilities/worker-operations-and-telemetry.md) |
| `shikigami-scheduler` | shikigami-workers | [CAP-2](capabilities/durable-trigger-intake.md), [CAP-17](capabilities/worker-operations-and-telemetry.md) |
| `shikigami-consume-stream` | shikigami-workers | [CAP-2](capabilities/durable-trigger-intake.md), [CAP-17](capabilities/worker-operations-and-telemetry.md) |
| `shikigami-consume-events` | shikigami-workers | [CAP-2](capabilities/durable-trigger-intake.md), [CAP-11](capabilities/addressed-conversations.md), [CAP-17](capabilities/worker-operations-and-telemetry.md) |

## Administrative command families

These are the eleven entries in `adminSubcommands`. Nested verbs share
their owning provision: `agents list/sync`, `grants list/grant/revoke`, and
`runs show`. The mounted runtime administration tree is covered by CAP-17;
its commands belong to
[the upstream operations package](mori://shinzui/keiro/packages/keiro-ops).

| `shikigami` command | Catalog mapping |
| --- | --- |
| `validate` | [CAP-1](capabilities/typed-agent-declarations.md) |
| `render-lifecycle` | [CAP-4](capabilities/durable-agent-flows.md) |
| `enqueue-run` | [CAP-2](capabilities/durable-trigger-intake.md) |
| `resolve-approval` | [CAP-10](capabilities/durable-human-approval.md) |
| `publish-fixture` | [CAP-20](capabilities/local-integration-fixtures.md) |
| `stub-kawa` | [CAP-20](capabilities/local-integration-fixtures.md) |
| `stub-kanmon` | [CAP-20](capabilities/local-integration-fixtures.md) |
| `danwa-spike` | [CAP-20](capabilities/local-integration-fixtures.md) |
| `grants` | [CAP-9](capabilities/authorized-sink-outbox.md) |
| `agents` | [CAP-6](capabilities/principal-lifecycle-and-continuity.md) |
| `runs` | [CAP-17](capabilities/worker-operations-and-telemetry.md), [CAP-25](capabilities/http-agent-run-lifecycle.md) |

| `resources` | [CAP-26](capabilities/root-resource-accounting.md) |
| `executions` | [CAP-28](capabilities/recoverable-skill-execution.md) |
| `workers` | [CAP-29](capabilities/continuing-worker-primitives.md) |

## Exclusions and bounds

- `Shikigami.Core` is a version placeholder; `Prelude` and `Id.Name` are supporting utilities. They are exported, but do not warrant independent provision records.
- Generated workflow facts, queue codecs, projection ownership, and conformance reports support CAP-2, CAP-4, and CAP-14. They are not additional business capabilities.
- The at-risk-customer, delegation-proof, and architecture-review router flows are registered implementations/examples within CAP-4, CAP-8, and CAP-15. Proof researchers are fixed-output programs within CAP-3.
- Schema-only deterministic execution, shared memory recall, mutable repository workspaces, live Kubernetes diagnostics, cross-runtime A2A, and signed/served attestations remain unavailable. Their declarations or plans are not provision records.
- The production practice-review content reader remains unavailable. CAP-15 claims its implemented orchestration and unresolved path, with complete-evidence branches evidenced only through fixtures.
- Foreground and named-job launches belong to CAP-18; they do not imply working background CLI response providers.
- Build recipes, dependency qualification tooling, plans, schemas, migrations, and tests are supporting artifacts unless exposed through an independently usable provision such as CAP-19 or CAP-20.

The initial eighteen-record pass missed migration/bootstrap and integration
fixture tooling. This audit adds CAP-19 and CAP-20 and expands existing records
for direct enqueue, client/worker health, Skill validation, configuration
diagnostics, joined run inspection, and request logs. It also corrects the
evidence query interface to the exposed evidence-store API.

## Keeping the census current

When changing a Cabal public module list, binary, command family, behavior registry,
or declaration arm, reconcile the surface with this table and its owning record.
Inspect the implementation and evidence before widening the claim. Profile, link,
and graph validation check consistency; they do not automatically discover omitted
features or prove the semantics of a claim.

## October 25 additions

The 2026-10-25 refresh adds CAP-21 through CAP-25 and twenty exposed modules: typed
decision programs, model admission, attempt evidence, Flow composition, HTTP catalog,
authentication, atomic acceptance, and derived run lifecycle. The twelve binaries
and eleven administrative command families are unchanged; the typed client now
also exposes `agents list/show` and `runs request/show/list/wait`. HTTP discovery and
run routes are implemented and no longer appear in the unavailable-surface list.

## October 29 additions

CAP-26 through CAP-30 cover accounting, assignment selection, recoverable Skill
execution, continuing-worker primitives and pure repository admission. Counts
above now reflect all current Cabal public modules and fourteen command families.
Plan 84 remains partial; the repository catalog does not deliver mutable workspaces.
Objective persistence/API/CLI and full adaptive/recurring coordination remain planned.

## November 4 additions

CAP-31 covers unrequested work: the `Shikigami.Initiative.*` modules (`Types`, `Settings`,
`Source`, `Prefilter`, `Intake`, `Ledger`, `Policy`, `Inspection`, `Notice`, `Template`),
`Shikigami.Flow.Initiative`, `Shikigami.Program.Decision.Initiative`, and the `proposals`
command family in `Shikigami.Server.Command.Proposals`. The counts at the top of this census
were last computed on October 29 and do not include these.
