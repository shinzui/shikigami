# Shikigami domain inventory

This census was refreshed on 2026-09-21 for
[plan 72](../plans/72-adopt-keiro-0-18-and-current-runtime-patterns.md), from the
plan 65 baseline at revision `65b8a1b44faa540fef163d5de33ee1c79eea7de4`.
It describes executed ownership and the reasons other surfaces remain hand-owned. A declaration
counts only when its generated contract is used by production code (ADR 0001).
The workspace currently contains five explicitly declared Language 6 members: agent-run, approval,
conversation, RunEvidence and run-jobs. The evidence member also declares its catalog and query model.
Keiro 0.18 is a released package family, while its language registry truthfully
labels Language 6 as the opt-in `Candidate CandidateLanguage` contract; Language 5
remains its stable published compatibility contract.

## Workflows and identities

Paths in this section are relative to `shikigami-core/src/`.

| Surface | Declaration and execution owner | Observable proof |
|---|---|---|
| `shikigami.agent-run` | `domain/shikigami-agent-run.keiro`; `Shikigami/Agent/Workflow.hs`; generated AgentRun runtime | Job idempotency key identifies the run. WorkflowVersioningSpec, ApprovalWorkflowSpec, BehaviorRetrySpec and memory/router replay suites exercise it. The reviewed pre-v1 reset retired all historical application patch branches. |
| `shikigami.approval` | `domain/shikigami-approval.keiro`; `Shikigami/Agent/Approval/Workflow.hs`; generated Approval runtime | ApprovalWorkflowSpec covers a durable child with `ingest-approval`, `notify`, and `decision`. Publication and resolution use the allocated opaque AwakeableId, distinct from the review-request key. |
| `shikigami.danwa-conversation` | `domain/shikigami-conversation.keiro`; `Shikigami/Agent/Conversation.hs`; generated DanwaConversation runtime | Conversation tests cover restoreSeed, one turn per continueAsNew generation, timeout and wake tokens. The baseline uses only the rotating workflow and static labels. |
| Delegated runs | `Shikigami/Agent/Delegate.hs` and `Shikigami/Agent/Delegate/Context.hs` | Deterministic UUIDv5 child identities and reservation ledger are technical deduplication identities. Preserve their derivation; do not relabel them TypeID-v7. |
| Workflow options | `Shikigami/Workflow/Versioning.hs` | One options constructor derives active patches from generated declarations. Preserve it even with an empty patch set; retain synthetic old/new workflow tests. |
| Flow capabilities | `Shikigami/Flow/Capability.hs`, `Shikigami/Flow/Routing.hs`, `Shikigami/Flow/AtRiskCustomer.hs` | Journaled memory, routing decisions, approvals and sink labels execute within agent-run. The model-driven router is a Flow capability, not a Keiro process/router node. |

RunJob retains `AgentName`, `RunKey`, `DelegationDepth`, parent `SessionId` and
`WorkflowId` values through orchestration. Its generated transport adapter renders
scalars explicitly and validates them on decode. Conversation seeds keep AgentName;
delegation context carries nominal lineage and depth. Evidence uses generated
RunEvidenceId, RunKey and distinct nonnegative duration/concurrency types. Existing
attestation versions, digests and locators keep their owning nominal types.

Language 6 nominal leaves are intentionally absent from the run-job declaration.
`AgentName`, `RunKey`, and `DelegationDepth` are refined values whose parsers reject
members of their underlying Text or integer representation, so they are not total
consumer nominal isomorphisms. `SessionId` and `WorkflowId` are upstream opaque
identities, and `RunKey` is a composite retry identity rather than a TypeID-v7 domain.
`TriggerKind` and `RunRouteKind` keep their established Aeson constructor spellings;
changing them to the DSL enum wire-word grammar would change durable queue bytes.
The generated queue decoder feeds the real `RunJob` decoder before execution, and
`WireCompatSpec` proves rejection of invalid refined IDs, depths, lineage, session and
workflow IDs, plus unknown enum strings. This is executable boundary validation rather
than an unchecked opaque root.

Keiro 0.18 adds checked mappings for bare containers, calendar days, text sets and
base16 bytes, plus UUIDv5-or-v7 identifier admission. None matches a current declared
Shikigami surface: the queue adapter already validates richer application values, and
the specification has no mapped consumer declaration. `RunEvidenceId` remains a
TypeID-v7 domain through `typeIdV7Domain`; deterministic UUIDv5 workflow and
deduplication identities are technical identities outside that declared domain. Their
admission and durable bytes are unchanged by the release upgrade.

`Shikigami.Workflow.Registry` in core composes agent runs, approval children and
conversations. The worker consumes this exact registry; the approval integration
case verifies all three names. Bounded resume stops on zero durable advances and
exports all summary fields. Generated facts describe the current static workflow
bodies; the synthetic versioning test preserves future patch-gate coverage.

`Shikigami/Flow/Lifecycle/AtRiskCustomer.hs` is a diagram-only Keiki transducer
with no emitted events. Its durable execution state belongs to the workflow journal.
It does not become an aggregate merely because RunEvidence is now an aggregate.

## Evidence lifecycle and queries

`domain/shikigami-run-evidence.keiro` owns the RunEvidence aggregate, generated
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

## Run-job queue

`shikigami-core/src/Shikigami/Agent/RunJob.hs` owns the complete journal input.
`domain/shikigami-run-jobs.keiro` owns the twelve-field generated `RunJobMessage`
envelope and queue policy. `Shikigami.RunJobs` adapts the nominal domain value to
that envelope and validates identity and route on decoding. `Trigger/Enqueue.hs`
uses it for direct and transactional producers; the worker uses the same generated
codec, queue provisioning and retry policy. CLI, schedule, Kafka inbox, delegation
and conversation routing all select an explicit route.

The reviewed unused pre-v1 reset removed bare queue decoding, missing-field defaults,
and inferred routing. `WireCompatSpec` pins a complete literal envelope and rejects
the former bare payload. Worker tests exercise actual enqueue and dispatch; scheduler
and inbox tests decode through the production facade. The Haskell worker registration
is the executable binding for this queue; Language 6 did not change its physical name,
envelope bytes, retry policy or `Unordered` delivery semantics.

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
The executed report in `docs/evidence/plan-65/behavior-conformance.json` has 56 filled
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
