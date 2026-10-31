# Shikigami domain inventory

This census was refreshed on 2026-10-30 under
[MasterPlan 16](../masterplans/16-upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds.md)
and [plan 93](../plans/93-adopt-guarded-catalog-commands-and-qualify-current-dsl-consumer-contracts.md).
A declaration counts only when production executes its generated contract (ADR-1).
The workspace has ten explicit Language 6 members: agent-run, approval,
conversation, execution-driver, execution, RunEvidence, run-jobs, worker-session,
continuing-worker and objective. Four aggregates own catalogs and query models.
Keiro/DSL 0.22 is released; Language 6 remains the opt-in candidate language.

## Workflows and identities

Paths in this section are relative to `shikigami-core/src/`.

| Surface | Declaration and execution owner | Observable proof |
|---|---|---|
| `shikigami.agent-run` | `domain/shikigami/agent-run.keiro`; `Shikigami/Agent/Workflow.hs`; generated AgentRun runtime | Job idempotency key identifies the run. WorkflowVersioningSpec, ApprovalWorkflowSpec, BehaviorRetrySpec and memory/router replay suites exercise it. Current leaf Skills await execution children directly; no obsolete patch branch remains. |
| `shikigami.approval` | `domain/shikigami/approval.keiro`; `Shikigami/Agent/Approval/Workflow.hs`; generated Approval runtime | ApprovalWorkflowSpec covers a durable child with `ingest-approval`, `notify`, and `decision`. Publication and resolution use the allocated opaque AwakeableId, distinct from the review-request key. |
| `shikigami.danwa-conversation` | `domain/shikigami/conversation.keiro`; `Shikigami/Agent/Conversation.hs`; generated DanwaConversation runtime | Conversation tests cover restoreSeed, one turn per continueAsNew generation, timeout and wake tokens. The baseline uses only the rotating workflow and static labels. |
| Delegated runs | `Shikigami/Agent/Delegate.hs` and `Shikigami/Agent/Delegate/Context.hs` | Deterministic UUIDv5 child identities and reservation ledger are technical deduplication identities. Preserve their derivation; do not relabel them TypeID-v7. |
| `shikigami.execution` | `domain/shikigami/execution-driver.keiro`; `Shikigami/Execution/Driver.hs`; generated ExecutionDriver runtime | Transcript and selection workflow tests cover bounded generations, accepted-reference queue repair, protected replay, Approval, cancellation and parent completion after provider retirement. |
| `shikigami.worker-session` | `domain/shikigami/continuing-worker.keiro`; `Shikigami/WorkerSession/Workflow.hs`; generated ContinuingWorker runtime | Session suites cover one assignment per generation, durable idle wakes, original governed child mappings, missing-input repair and retained result acknowledgement after handoff. |
| Workflow options | `Shikigami/Workflow/Versioning.hs` | One options constructor derives active patches from generated declarations. Preserve it even with an empty patch set; retain synthetic old/new workflow tests. |
| Flow capabilities | `Shikigami/Flow/Capability.hs`, `Shikigami/Flow/Routing.hs`, `Shikigami/Flow/AtRiskCustomer.hs` | Journaled memory, routing decisions, approvals and sink labels execute within agent-run. The model-driven router is a Flow capability, not a Keiro process/router node. |

RunJob retains `AgentName`, `RunKey`, `DelegationDepth`, parent `SessionId` and
`WorkflowId` values through orchestration. Its generated transport adapter renders
scalars explicitly and validates them on decode. Conversation seeds keep AgentName;
delegation context carries nominal lineage and depth. Evidence uses generated
RunEvidenceId, RunKey and distinct nonnegative duration/concurrency types. Existing
attestation versions, digests and locators keep their owning nominal types.

The queue's `TriggerKind` and `RunRouteKind` fields use total structural enum
bindings to the existing consumer types. Generated codecs admit exactly their
finite spellings, and generated conformance covers every constructor and owner/key
law. Hand-written string adapters are removed. `AgentName`, `RunKey` and
`DelegationDepth` remain refined application values; their rejecting parsers are
not total isomorphisms over Text/Int. Upstream `SessionId`/`WorkflowId` are opaque
identities. Queue decoding still reaches these real parsers before execution.

The concept-owned `Execution.Bindings` and `WorkerSession.Bindings` modules supply
nominal Text bindings to
`ExecutionId` and `WorkerSessionId`. They preserve their runtime-owned UUIDv5
technical coordinates and empty initial sentinel. They are not TypeID-v7 domains.

Execution transcript revisions and expected command revisions retain the separate
`execution` StateRevision scope, including PreparedTool. The transcript cursor,
retained operation positions and operation-id derivation retain
`execution-operation`; they cannot substitute for resource-root policy revisions.
Native generated command and SQL codecs render numbers explicitly. Exact positive
state/operation codecs, invalid-position rejection and unchanged deterministic ID
input bytes are covered by ExecutionPositionSpec. This scalar refactor changes no
workflow step or declared DSL body; counters and other scalar findings retain
their separate open census in plan 107.

Resource vectors now retain private checked ResourceAmount values, indexed by
Dimension, through finite limits, reservations, usage and settlement. Numeric
wire values remain unchanged. Checked arithmetic and preflight accumulation
reject underflow/overflow before publication; an unrepresentable provider report
retains its unknown billing hold instead of becoming zero. ADR-76 and
[resource-amount acceptance](../evidence/keiro-0.22/resource-amount-results.txt)
cover the real HTTP and synthetic counter-boundary cases. This does not complete
the separate counter/policy/identity census.

Root and assignment attempt counts now retain distinct nominal scopes. Finite
call/retry/concurrency ceilings match their respective count scopes, while token
caps retain ResourceAmount. Signed-profile wire values refine once into these
operational limits with typed refusal before provider setup. Checked zero-count
decrements refuse before coupled settlement/reconciliation. The positive codec,
compiler and full recovery evidence is in [attempt-count acceptance](../evidence/keiro-0.22/attempt-count-results.txt)
and ADR-77. Other execution counters and policy values remain under review.

Objective is an application-owned entity: `ObjectiveId` now uses the generated
abstract TypeID-v7 domain with prefix `shikigami_objective`. Creation allocates a
UUIDv7 ID, while creator-scoped operation receipts retain deduplication authority.
Concurrent losing candidates roll back before recovering the committed receipt.
[ADR 73](../adr/0073-objective-identity-is-allocated-and-creation-receipts-own-deduplication.md)
and the retained strict breaking diff describe this first-release correction.
RunEvidence retains its separate generated TypeID-v7 domain.
All four current aggregate event streams explicitly use `snapshotPolicy = Never`
and no state codec, so this change does not claim cache fallback qualification
for a snapshot consumer that does not exist. Same-build event/journal replay,
protected-payload corruption and current producer/consumer fixtures remain gates.

`RunEvidenceId` retains the generated TypeID-v7 contract. UUIDv5 workflow and
retry identities stay technical identities outside that domain. The actual queue
already executes ordered scalar lists for lineage; its boundary tests preserve
order and reject invalid refined values. There is no date, text-set or unrestricted
byte consumer in a declared payload. Prefixed fixed-length digests are not the
unrestricted base16-byte policy. No current aggregate guard compares an enum field:
control phases are vertices, while the two structural enums are queue data. No
unused enum guard is invented. Mapped identity registers copy complete typed
command values; there is no scalar-to-mapped write or transition resetting them
to an initial value that would justify an unused write-lift.

`Shikigami.Workflow.Registry` in core composes all five families: agent runs,
approval children, conversations, execution drivers and continuing workers. The
worker consumes this exact registry; the approval integration case verifies all
five names. Bounded resume stops on zero durable advances and
exports all summary fields. Generated facts describe the current static workflow
bodies; the synthetic versioning test preserves future patch-gate coverage.

`Shikigami/Flow/Lifecycle/AtRiskCustomer.hs` is a diagram-only Keiki transducer
with no emitted events. Its durable execution state belongs to the workflow journal.
It does not become an aggregate merely because RunEvidence is now an aggregate.

## Evidence lifecycle and queries

`domain/shikigami/run-evidence.keiro` owns the RunEvidence aggregate, generated
RunEvidenceId, commands, events, transducer, codecs and behavior obligations.
`Shikigami.RunEvidence.BehaviorHoles` supplies executable state/command witnesses.
`shikigami-core/src/Shikigami/Attestation/EvidenceStore.hs` executes
`runCommandWithCatalogProjections` with a validated live handler capturing rich command
payloads. Lifecycle append and both SQL target writes share one transaction. The generated
`run_evidence_lookup` model guards queries through `Keiro.ReadModel.runQuery`.
`RunEvidenceSpec` proves SQL-failure rollback, typed rebuild fencing, fenced-query refusal,
restart convergence, and a generated lifecycle replay audit.

Both SQL targets share the generated `run_evidence_store` dependency group. Their reset
policy is `PreserveAndReconcile`; the owner is `LiveOnly` because lifecycle history lacks
rich evidence payloads. Catalog rebuild operations preserve existing rows and cannot
reconstruct missing payloads. There is no destructive reset or rich-evidence replay adapter.
`Shikigami.RunEvidence.Catalog` is the shared authority for writes, queries, registration
and the server's catalog/lifecycle-audit hooks. Runtime entry points register it before
serving requests. The static handler fails closed without captured command evidence.
No external SQL reader has been identified in the repository.

Kioku owns shared session streams, memory projections and session timer projections.
Conversation session commands use Kioku's stream and inline projections. The service
migration boundary reconciles Kioku read models through its public API. Shikigami must
not redeclare that upstream aggregate or those targets as its own.

## Objective ownership

`domain/shikigami/objective.keiro` owns ObjectiveLifecycle and its current catalog.
`Objective/Store.hs` commits lifecycle append and protected objective state,
assignment, payload, receipt, origin, association, scope and cursor targets together.
The preserve/live-only boundary does not reconstruct private evidence from events.
Objective authority, atomicity, workflow and contract suites qualify the owner;
tracker/product integrations remain with their owning MasterPlans 17 and 18.

## Continuing session ownership

`domain/shikigami/worker-session.keiro` owns WorkerSessionLifecycle. The live
catalog writer commits lifecycle events, protected payload references, ordered
messages, results, event cursors and immutable command receipts together across
six application targets. Its preserve-and-reconcile policy cannot reconstruct
private payloads from lifecycle history. Session retention is independent of
workflow GC. Scope counts include retained sessions and cannot reset capacity
with a replacement root.

`WorkerSession/Capability.hs` is the shared closed command owner for
`Flow/Workers.hs`, dedicated admitted Skill tools and operator control. The
current baseline resolves the coordination policy directly for Flows and Skills;
there is no obsolete coordination patch branch.
`CoordinatingSkill` selects durable admitted coordination explicitly; fixed
supervisors retain their prior behavior. Model-supplied roots, grants and
operation coordinates are refused. New messages narrow original delegation
permissions. The public resume registration uses the original session input and
is repairable by command retry.

Checkpoint and workspace contracts are consumer interfaces. Production defaults
to unavailable providers until the separately owned IR-13 and IR-11 integrations
qualify. Deterministic handoff and checkpoint tests do not establish real late
process fencing or authoritative task updates. See ADRs 0061–0063 and
[ADR 0066](../adr/0066-worker-commands-require-retained-scopes-and-fresh-exact-authority.md).

## Run-job queue

`shikigami-core/src/Shikigami/Agent/RunJob.hs` owns the complete journal input.
`domain/shikigami/run-jobs.keiro` owns the twelve-field generated `RunJobMessage`
envelope and queue policy. One complete version-1 application codec carries
current resource enrollment, selection, permissions and accepted-operation routes.
Historical upcasters and journal omission defaults are removed under ADR-27.
`Shikigami.RunJobs` binds the current domain value to the generated envelope;
`Trigger/Enqueue.hs` and the worker share the codec, provisioning and retry policy.
CLI, schedule, Kafka inbox, delegation and conversation routes remain explicit.

`WireCompatSpec` pins the complete current envelope, rejects superseded wrappers
and versions, requires authority keys in current journal values, and checks that
input resembling metadata remains ordinary input. Worker tests use actual enqueue
and dispatch. The physical queue name, retry policy and Unordered delivery remain
the production declaration's values.

## External intake and sink delivery

| Boundary | Owner | Why it remains hand-owned; proof |
|---|---|---|
| Open Kafka agent matching | `shikigami-workers/src/Shikigami/Trigger/Consumer.hs` | Matching configured agents over ActivityEnvelope/open integration payloads is not a finite declared typed-event intake. Preserve inbox transaction dispositions and Kafka offset advancement only after durable disposition; consumer tests exercise failure/redelivery. |
| Danwa addressed message | `shikigami-core/src/Shikigami/Integration/Danwa.hs` | Upstream AddressedMessage is a bare object without the generated contract discriminator. Preserve upstream bytes and explicit decoding tests. |
| HTTP sink outbox | `shikigami-core/src/Shikigami/Sink/Intent.hs`, `Shikigami/Flow/SinkOutbox.hs`, `Shikigami/Agent/Workflow.hs`; worker `Shikigami/Flow/SinkOutbox/Publisher.hs` | HTTP dispatch is not a DSL Kafka publisher. One hand-owned SinkIntent replaced the former duplicate. Preserve deterministic intent IDs, delivery receipts and remote deduplication keys. SinkIntentSpec, SinkDeliverySpec and worker tests prove transient retry, permanent rejection and redelivery. |
| Sink grants | `shikigami-core/src/Shikigami/Sink/Permission.hs`, `Sink/GrantStore.hs` | Authorization policy tables are not an event-sourced aggregate or an unused generated enum. Permission/grant tests own the boundary. |

The outbox publisher already uses Keiro's claim-batch callback and exports rejected counts.
The receipt-gap test injects a failed delivered-receipt commit after remote acceptance,
then redelivers through the real publisher. Two HTTP requests carry one remote key and
converge on one downstream activity and one delivered receipt. Permanent refusal is terminal
and transient failures remain retryable; journals alone cannot promise exactly-once HTTP.

## Timers, startup, operations and tests

`shikigami-workers/src/Shikigami/Trigger/Timer.hs` owns the shared timer dispatcher,
with schedule, approval and conversation-timeout payload handlers. Schedule allocation lives
in `Trigger/Scheduler.hs`; approval allocation in core's approval vertical; conversation idle
allocation in the conversation vertical. These are custom timer rows, not a saga process.
RunEvidence does not supply a process that dispatches their commands. The owning
dispatcher drains up to 100 Keiro sleep or custom timers per pass. Scheduler and
conversation tests prove wake-up, cancellation, rearming and rotation behavior.
`TimerRecoverySpec` drives the finite serving pass and proves expired guarded claims
return directly to Dead, retain payload/reason/attempts, reject ID-only mutation, and
fence stale completion tokens.

Runtime entry points first verify the complete migration ledger read-only, then
construct telemetry, acquire the store and register validated streams/catalogs before
serving requests. Store callbacks use bounded log fields and the released Keiro
metrics bridge. Missing, pending and changed migrations refuse startup without repair.

The server mounts generated lifecycle audit and validated catalog operations. Its
catalog preview has no destructive reset. The embedded ResumeHook's exact
`[Store, Error StoreError, IOE]` row lacks Kioku's resource/tracing effects, so
resumption stays in the worker binary: `--resume-passes N --resume-limit N` previews,
and `--force` advances through the same runtime registry. Timer mutation stays with
its dispatcher. No cast or private production SQL substitutes for these owners.

Terminal workflow GC runs hourly in batches of 100 after 90 days. Live approvals
and completed children of live parents remain protected. Application evidence and
sink receipts have independent ownership and retention. See
[ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md).

`shikigami-migrations:test-support` is the only database-test acquisition boundary.
It uses the released migrated-suite template with isolated per-example clones and
Kioku reconciliation. Core's domain and diagram drivers require no PostgreSQL;
its PostgreSQL suite is separate. Server and worker integration tests retain their
package ownership. Smoke tests prove shared template identity, isolated data,
exception cleanup, no-op reapplication and startup ledger refusal.

## Evolution and conformance

Run `nix develop --command just keiro-check`, `just keiro-inspect`, and generated conformance
with the project-pinned tool. Check requires `--min-language 6`, `--deny-warnings`, binding
and coverage reports, and `--fail-on-opaque`. Behavior obligations are nonzero and must
execute; the former zero-obligation claim is obsolete. After committing reviewed generation,
ordinary scaffold must change no bytes. `just keiro-gate <baseline>` remains strict.
The historical plan-65 report in `docs/evidence/plan-65/behavior-conformance.json` had 56 filled
obligations, 50 verified and six unverified, with every failure/coverage-gap set empty.
The six command/register identity-equality guards have passing witnesses but are not
proved total by the released DSL. The core facade additionally requires every generated
total-guard requirement to appear in the verified set; it never relabels the others.

There are no local release tags or checked-in deployment pipeline; process-compose and
example config describe the development stack. Plan 65 records the owner's 2026-09-07
unused-service statement. Repository configuration alone cannot prove an empty remote
population: immediately before any workflow/wire reset, record all four pre-v1 facts in
that plan and preserve compatibility if contrary evidence appears.


## Assembled scenario acceptance

AgentWorkflowSpec connects the generated queue job to the real workflow, Danwa
approval notification, recreated behavior runtime, opaque-token resolution,
approval-child resumption, HTTP sink publication and receipt guard. Redelivered
jobs and tokens retain one intent and one remote effect. The scenario caller
explicitly supplies review metadata to the real evidence persistence owner under
the same workflow correlation ID; ordinary runs do not invent review bindings.
Conversation qualification reads the tokens actually published in successive
generation journals: an old token is refused and the live token accepts input.

## Current module-placement fold audit

Plan 107 moved nominal bindings from the former DomainBindings bucket into their
concepts and regenerated the dependent ring with the pinned producer. Conversion
bodies, binding versions, fixtures, initial values and canonical type names are
unchanged. Native strict analysis nevertheless reports affected replay and fold
changes for ExecutionLifecycle (`dcb54c2c08dc93a15d777f0516cb3bbd` to
`275db6f9a12b2d5d58c8add044ce074d`) and WorkerSessionLifecycle
(`b6c71cca77fae715bdf11f112f991d69` to `837966c8889d6f3acec8c67a761887c9`).
ObjectiveLifecycle stays `f36259bde91df3202d0d3fd6ddf14188` and RunEvidence stays
`f3498d651a5f18786ed1bb41eb3d4977`.
The [native findings](../evidence/keiro-0.22/module-placement-diff.json),
[replay report](../evidence/keiro-0.22/module-placement-replay.json) and
[acceptance](../evidence/keiro-0.22/module-placement-results.txt) retain this distinction.
All four remain Never without a state codec. This is a first-release baseline
change; it does not qualify an old populated deployment or invent a cache consumer.
