# Shikigami domain inventory

This census was refreshed on 2026-09-07 for [plan 65](../plans/65-migrate-shikigami-to-the-keiro-0-15-cohort-and-the-idiomatic-v2-record-model.md), starting at revision `65b8a1b44faa540fef163d5de33ee1c79eea7de4`.
It describes executed ownership and explicitly identifies pending adoption. A declaration
counts only when its generated contract is used by production code (ADR 0001).
The workspace currently contains four Language 5 members: agent-run, approval,
conversation, and RunEvidence. Later plan milestones add queue and catalog contracts.

## Workflows and identities

Paths in this section are relative to `shikigami-core/src/`.

| Surface | Declaration and execution owner | Observable proof / remaining work |
|---|---|---|
| `shikigami.agent-run` | `domain/shikigami-agent-run.keiro`; `Shikigami/Agent/Workflow.hs`; generated AgentRun runtime | Job idempotency key identifies the run. WorkflowVersioningSpec, ApprovalWorkflowSpec, BehaviorRetrySpec and memory/router replay suites exercise it. Plan 65 retires unused historical patch branches after verifying the pre-v1 exception. |
| `shikigami.approval` | `domain/shikigami-approval.keiro`; `Shikigami/Agent/Approval/Workflow.hs`; generated Approval runtime | ApprovalWorkflowSpec covers a durable child with `ingest-approval`, `notify`, and `decision`. Publication and resolution use the allocated opaque AwakeableId, distinct from the review-request key. |
| `shikigami.danwa-conversation` | `domain/shikigami-conversation.keiro`; `Shikigami/Agent/Conversation.hs`; generated DanwaConversation runtime | Conversation tests cover restoreSeed, one turn per continueAsNew generation, timeout and wake tokens. Historical nonrotating/per-message-label branches remain pending retirement. |
| Delegated runs | `Shikigami/Agent/Delegate.hs` and `Shikigami/Agent/Delegation/` | Deterministic UUIDv5 child identities and reservation ledger are technical deduplication identities. Preserve their derivation; do not relabel them TypeID-v7. |
| Workflow options | `Shikigami/Workflow/Versioning.hs` | One options constructor derives active patches from generated declarations. Preserve it even with an empty patch set; retain synthetic old/new workflow tests. |
| Flow capabilities | `Shikigami/Flow/Capability.hs`, `Shikigami/Flow/Routing.hs`, `Shikigami/Flow/AtRiskCustomer.hs` | Journaled memory, routing decisions, approvals and sink labels execute within agent-run. The model-driven router is a Flow capability, not a Keiro process/router node. |

The worker registry in `shikigami-workers/src/Shikigami/Agent/Workflow/Resume.hs`
composes the agent-run registry (including approval children) with conversations.
Its old comment saying two families is stale. Plan 65 must prove all three registrations,
bounded termination on zero durable advances, restart/resume, and rotation token invalidation.
Generated workflow facts inventory static declared steps; `docs/workflow-versioning.md`
still inventories historical computed labels until their reviewed removal.

`Shikigami/Flow/Lifecycle/AtRiskCustomer.hs` is a diagram-only Keiki transducer
with no emitted events. Its durable execution state belongs to the workflow journal.
It does not become an aggregate merely because RunEvidence is now an aggregate.

## Evidence lifecycle and queries

`domain/shikigami-run-evidence.keiro` owns the RunEvidence aggregate, generated
RunEvidenceId, commands, events, transducer, codecs and behavior obligations.
`Shikigami.RunEvidence.BehaviorHoles` supplies executable state/command witnesses.
`shikigami-core/src/Shikigami/Attestation/EvidenceStore.hs` executes
`runCommandWithSqlEvents` and persists `shikigami.run_evidence` and
`shikigami.run_evidence_calls` in the same transaction callback. These are real
application-owned query targets, disproving the former no-aggregate/no-read-model census.
`RunEvidenceSpec` covers the lifecycle and persistence boundary.

Plan 65 assigns the generated catalog and guarded query/write integration to the
RunEvidence vertical. Both SQL tables belong to one dependency group. Its reset policy
must preserve and reconcile data and its delivery capability must be live-only:
lifecycle events do not contain Baikai's rich encode-only evidence. No destructive
replay, stream repair, or fabricated evidence decoder can recover those payloads.
Acceptance must force SQL failure and catalog fencing and observe atomic rollback.
`shikigami-server/src/Shikigami/Server/Command/Runs.hs` owns operator evidence queries;
`Server/Command/Ops.hs` must expose honest lifecycle audit/catalog hooks using the same
validated catalog. Current raw SQL queries and empty hooks remain pending adoption.
No external SQL reader has been identified in the repository.

Kioku owns shared session streams, memory projections and session timer projections.
Conversation session commands use Kioku's stream and inline projections. The service
migration boundary reconciles Kioku read models through its public API. Shikigami must
not redeclare that upstream aggregate or those targets as its own.

## Run-job queue

`shikigami-core/src/Shikigami/Agent/RunJob.hs` owns the current RunJob domain value
and bare JSON codec. `Trigger/Enqueue.hs` is the producer boundary for
`shikigami_run_jobs`; `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs` decodes
and dispatches it. Producers include CLI, schedule, Kafka inbox, delegation and conversation
routing. The complete payload includes routing, trigger data, occurrence time, idempotency,
parentage, depth, lineage and delegation budget, not just the three workflow input facts.
`WireCompatSpec` currently proves the bare payload and compatibility defaults.

Language 5 supports this service-owned queue. Plan 65 will add
`domain/shikigami-run-jobs.keiro`, use generated Queue/QueueCodec/QueuePolicy artifacts
at both ends, and replace the bare fixture with a complete literal `{v,t,data}` envelope.
The existing wire shape is preserved during edition migration, then intentionally reset
in a separate reviewed change. `InferredLegacyRoute` and bare fallback decoding have no
permanent exemption; every producer must choose its route explicitly before removal.
Acceptance is an actual generated-envelope enqueue/dequeue/run, not a codec-only test.

## External intake and sink delivery

| Boundary | Owner | Why it remains hand-owned; proof |
|---|---|---|
| Open Kafka agent matching | `shikigami-workers/src/Shikigami/Trigger/Consumer.hs` | Matching configured agents over ActivityEnvelope/open integration payloads is not a finite declared typed-event intake. Preserve inbox transaction dispositions and Kafka offset advancement only after durable disposition; consumer tests exercise failure/redelivery. |
| Danwa addressed message | `shikigami-core/src/Shikigami/Integration/Danwa.hs` | Upstream AddressedMessage is a bare object without the generated contract discriminator. Preserve upstream bytes and explicit decoding tests. |
| HTTP sink outbox | `shikigami-core/src/Shikigami/Sink/Intent.hs`, `Shikigami/Flow/SinkOutbox.hs`, `Shikigami/Agent/Workflow.hs`; worker `Shikigami/Flow/SinkOutbox/Publisher.hs` | HTTP dispatch is not a DSL Kafka publisher. One hand-owned SinkIntent replaced the former duplicate. Preserve deterministic intent IDs, delivery receipts and remote deduplication keys. SinkIntentSpec, SinkDeliverySpec and worker tests prove transient retry, permanent rejection and redelivery. |
| Sink grants | `shikigami-core/src/Shikigami/Sink/Permission.hs`, `Sink/GrantStore.hs` | Authorization policy tables are not an event-sourced aggregate or an unused generated enum. Permission/grant tests own the boundary. |

The outbox publisher already uses Keiro's claim-batch callback and exports rejected counts.
Plan 65 audits actual permanent/transient outcomes and terminal claim races before replacing
any already-correct behavior. A remote acceptance followed by journal failure must reuse the
same remote key; the journal alone cannot promise exactly-once HTTP delivery.

## Timers, startup, operations and tests

`shikigami-workers/src/Shikigami/Trigger/Timer.hs` owns the shared timer dispatcher,
with schedule, approval and conversation-timeout payload handlers. Schedule allocation lives
in `Trigger/Scheduler.hs`; approval allocation in core's approval vertical; conversation idle
allocation in the conversation vertical. These are custom timer rows, not a saga process.
RunEvidence's existence does not supply a process that dispatches their commands. Plan 65
adds bounded Keiro sleep draining within the owning dispatcher and proves wake/cancel/rotation
behavior without competing unfiltered consumers.

Workers.Config, worker command entry points, server startup and the one-off agent path own
resource acquisition and telemetry. Required proof covers migration handshake before listeners,
telemetry before store callbacks, validated streams/catalog, registry completeness, resume
summaries, quiescent waits and safe terminal retention. Existing wiring is retained when tests
prove it meets the released contract.

`shikigami-server/src/Shikigami/Server/Command/Ops.hs` currently leaves application hooks
empty. Its no-aggregate rationale is obsolete. Lifecycle audit and catalog hooks are applicable.
The released ResumeHook effect row lacks the resource-aware Kioku effects required here;
plan 65 must either supply an honest interpreter or expose bounded resume at the worker-owned
operational boundary and document the exact unsupported embedded type. Timer mutation stays
with its dispatcher. No cast or direct private SQL is an acceptable integration.

`shikigami-migrations:test-support` is the only database-test acquisition boundary.
It currently wraps pg-migrate's per-database fixture. Plan 65 replaces that implementation
with keiro-test-support's migrated suite/template and isolated per-example clones, preserving
the complete migration ledger and Kioku reconciliation. Core's domain/diagram checks will move
to database-independent drivers, with PostgreSQL tests in a separate suite. Server and worker
integration tests retain their package ownership. Cleanup on exceptions, distinct example
databases and a no-op second migration are mandatory acceptance.

## Evolution and conformance

Run `nix develop -c just keiro-check`, `just keiro-inspect`, and generated conformance
with the project-pinned tool. Check retains `--min-language 5`, `--deny-warnings`, binding
and coverage reports, and `--fail-on-opaque`. Behavior obligations are nonzero and must
execute; the former zero-obligation claim is obsolete. After committing reviewed generation,
ordinary scaffold must change no bytes. `just keiro-gate <baseline>` remains strict.

There are no local release tags or checked-in deployment pipeline; process-compose and
example config describe the development stack. Plan 65 records the owner's 2026-09-07
unused-service statement. Repository configuration alone cannot prove an empty remote
population: immediately before any workflow/wire reset, record all four pre-v1 facts in
that plan and preserve compatibility if contrary evidence appears.
