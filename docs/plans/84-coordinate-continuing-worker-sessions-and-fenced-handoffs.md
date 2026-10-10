---
id: 84
slug: coordinate-continuing-worker-sessions-and-fenced-handoffs
title: "Coordinate continuing worker sessions and fenced handoffs"
kind: exec-plan
created_at: 2026-10-10T23:32:15Z
master_plan: "docs/masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md"
intention: "intention_01m4m2pjz6es9v9aqq5jq9c4ee"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-10T23:32:15Z
---

# Coordinate continuing worker sessions and fenced handoffs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


A coordinator can send a second assignment to the same worker, recover accepted messages and results after restart, and transfer ownership without permitting simultaneous writers. Fulfill [IR-15](../improvement-requests/support-continuing-worker-sessions.md) and the continuing-message integration of IR-14. Hard child dependencies are `docs/plans/81-enforce-root-resource-reservations-across-durable-work.md`, `docs/plans/82-pin-governed-execution-settings-for-agent-assignments.md` and `docs/plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md`. External IR-13 current objective/assignment references are required for production checkpoint integration; IR-11 is required for the real repository-handoff acceptance. Those facilities are not implemented by this child.


## Progress


Implementation has not started. Seed unchecked milestone entries when implementation begins.


## Surprises & Discoveries


None recorded during implementation.


## Decision Log


2026-10-10: Keep continuing worker sessions distinct from Kioku session history and Danwa lifecycle. Queue follow-ups at assignment boundaries; interrupt and ownership transfer are explicit reconciling operations. External workspace/checkpoint completion remains visible rather than being bundled into this plan.


## Outcomes & Retrospective


To be filled during implementation. Do not claim request completion until every acceptance case below, including stated external integration gates, has evidence.


## Context and Orientation


`shikigami-core/src/Shikigami/Agent/Delegate.hs` supplies governed one-shot spawning and cancellation. `Flow/Delegate.hs` exposes it without Store/IO in Flow bodies. `Agent/Conversation.hs` supplies rotation and epoch precedents, while `Agent/Conversation/SessionIndex.hs` is only a Kioku association cache. An idle continuing worker is not a completed Danwa conversation or a relevance-ranked memory result. Give it a new authoritative session identity linked to principal, parent coordinator, objective, assignment revision, run and memory session, with a stable root resource id across all of them.

[ADR 0018](../adr/0018-a-workflow-that-ends-is-re-keyed-by-epoch.md) requires a new epoch for a genuinely terminated workflow; [ADR 0023](../adr/0023-delegation-is-governed-at-the-child-spawn-boundary.md) preserves admission before spawn. [ADR 0033](../adr/0033-recorded-agent-principals-key-durable-state.md) keys continuity by recorded principal, not a mutable name. [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md) keeps Flow bodies free of direct external IO.

The repository is a Cabal multi-package Haskell service. `shikigami-core` owns domain behavior and store adapters; `shikigami-workers` owns queue, resume and timer processes; `shikigami-server` owns operator commands. `shikigami-migrations/sql-migrations/manifest` owns append-only SQL ordering. `shikigami-core/test-postgres/Main.hs` registers tests using `Shikigami.Migrations.TestSupport.withShikigamiMigratedSuite`, which supplies isolated disposable PostgreSQL databases. Register new modules and tests in the owning Cabal file and test entry point; generated files under `Generated/` are regenerated, never hand-edited.


## Plan of Work


### Milestone 1: Accept ordered messages and retain authoritative results

Create `shikigami-core/src/Shikigami/WorkerSession/Types.hs`, `WorkerSession/Store.hs` and a checked session lifecycle declaration. Store `WorkerSessionId`, objective/assignment references, admitted principal/parent/root, owner epoch, current state, message sequence and result/event cursor. Commands take stable operation id, immutable payload fingerprint and expected session/assignment revision. Under a session lock, atomically accept a message, assign its sequence and record its acknowledgement state. Identical replay returns the same acceptance; conflicting reuse or stale revision refuses visibly.

Distinguish accepted, active, parked, idle, failed, cancelled and unresolved session/assignment states; an assignment can complete while its session becomes idle and retained. Ordinary follow-ups accepted during active work queue for the next assignment. An explicit interrupt is a separate request, observed at a safe boundary and reconciled before replacement work starts. Race final-result commit with a follow-up: the ordered mailbox makes both visible and neither mutates the instruction under which the finished result was produced. Store results and correlated durable events in the same transaction. Notification failure never removes result availability. Prove these cases in `WorkerSessionStoreSpec` before adding runtime behavior.

### Milestone 2: Drive sessions through recoverable assignments

Create `WorkerSession/Workflow.hs`. Find-or-create is scoped to admitted parent, target principal and stable logical worker key, not a global agent name. Start assignment runs through the existing governed delegation boundary with inherited root, narrowed authority, explicit execution selection and retained execution-history references. Assign each newly accepted assignment an immutable `AssignmentId` and persist its mapping to the child workflow/run identity before spawn. Derive the existing delegation key from that assignment id, not from the stable worker key alone: `delegatedWorkflowId` hashes parent workflow id, target and key but does not include generation. A follow-up therefore gets a distinct child/run under the same `WorkerSessionId`; replay of the same accepted message reuses its assignment and child mapping. Preserve this mapping across coordinator generations and parent epoch changes; a resume must not recompute a different child from its current parent. Use one bounded assignment/cycle per generation and authoritative store inspection on wake; never continuously poll or replace an idle worker because it is silent. A session may coordinate permitted descendants through the same boundary.

Consume events after a persisted cursor. Commit result integration identity and cursor advancement together with local progress; use IR-13's operation-key/versioned checkpoint command and a durable pending intent when the checkpoint owner is across a transaction boundary. Retry the same intent after a lost acknowledgement. Event delivery is at-least-once; integration is logically deduplicated. Persist bounded context selections from committed transcript/results, not copies of the entire parent history. Test a second assignment after restart that uses a retained finding from the first.

### Milestone 3: Fence and reconcile ownership transfer

Implement transfer as requested, reconciling, then established with a new owner epoch. Freeze new old-owner writes, retain accepted artifacts/workspace identity and pending operations, and query the effect/workspace owner for in-flight completion or uncertainty. A successor gets write authority only after the old writer is fenced and previously admitted effects are reconciled sufficiently to avoid conflicting writes. Timeout/lease expiry is not proof an external process ended. An unknown mutation holds transfer unresolved and inspectable.

Define a narrow workspace adapter requiring resource identity, owner epoch, operation id, conditional write admission and reconciliation result. IR-11 supplies the actual workspace implementation; use a deterministic adapter fixture to build the session state machine now, but retain real restart/late-write tests as a completion gate. Likewise consume IR-13's authoritative objective/assignment snapshot and conflict-aware progress operations rather than creating a competing task store. Complete the real integrations before claiming full IR-15 delivery.

### Milestone 4: Expose governed operations to Flows, Skills and operators

Create `shikigami-core/src/Shikigami/Flow/Workers.hs` and `WorkerSession/Capability.hs`. Expose find/create, send, inspect, await-events, interrupt/cancel and transfer as closed typed commands. Skill model tools and Flow interpreters call the same command admission; the durable harness records their operations. Add a dedicated admitted coordination surface with lifecycle/target/depth/cycle/resource checks, rather than removing the global observation-only restriction for arbitrary overlays. Route fresh protected-action authorization through the existing boundary. Do not make a declaration's text grant session control.

Add `workers inspect SESSION --json` plus explicit supported send/interrupt/transfer operator commands under `shikigami-server/src/Shikigami/Server/Command/`, with stable caller operation keys and bounded diagnostics. Register the workflow in `Workflow/Registry.hs`, and wire process dependencies in worker/server configuration. Preserve one-shot delegation, old supervisor semantics and existing conversation behavior. Follow [workflow versioning](../workflow-versioning.md) for every durable-body change. Keep old journal populations on real old branches behind newly declared patch ids; preserve result codecs. Add declarations to `domain/shikigami.keiro-workspace`, regenerate the runtime and conformance artifacts, and union new workflow patch sets in `shikigami-core/src/Shikigami/Workflow/Versioning.hs`. Long-lived workflows restore a seed first, use static labels within each generation, rotate with `continueAsNew`, and republish generation-owned wake references. Do not invoke the pre-v1 reset exception without separately proving all four documented empty-population conditions. Default this plan to compatible evolution.


## Concrete Steps


Run from the repository root in the existing development environment; if native tools are unavailable, enter `nix develop` first. PostgreSQL tests own disposable databases and must not be pointed at production. Capture a baseline before implementation, then run the following after each applicable milestone:

```bash
MP14_BASE=$(git rev-parse HEAD)
cabal build all
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-workers-test shikigami-server-test --test-show-details=direct
just migration-schema-isolation
```

The build and tests must exit zero; tests report all cases passed. These are future implementation checks, not results of creating this plan. Add the named new test groups before using their success as evidence. If domain or workflow contracts change, scaffold with the checked workspace, stage/commit generated artifacts so the existing regeneration check compares the intended baseline, then run:

```bash
just keiro-gate "$MP14_BASE"
```

The gate must report no unexplained breaking change and generated conformance must pass. Record actual commands, baseline revision and bounded evidence in the living sections. Dependency source lookup starts with Mori; no new dependency bound is selected here. Before a later bound, pin or workaround change, verify the authoritative registry and upstream release tags as well as the Mori-located source.


## Validation and Acceptance


`WorkerSessionSpec` and PostgreSQL `WorkerSessionStoreSpec` prove two assignments on one session, duplicate follow-up and duplicate completion event across restart, an active-work follow-up plus one after result completion, and recovery of a result committed before its notification. Count one logical assignment and one result integration for every key, and prove two distinct child/run ids for two follow-ups under the same `WorkerSessionId`, including parent rotation/restart. A denied target, descendant cycle, absent authority or exhausted root causes zero protected callbacks. An idle session retains its work and context.

For transfer, hold an operation in flight, request transfer, and assert successor writes are refused; reconcile, establish a new epoch, then assert late old-owner writes are fenced. Run the test against the real IR-11 provider before closing IR-15 acceptance 4. Verify a stale IR-13 checkpoint update cannot restore an old owner. Resume after context compaction and redeliver a coordination tool; root usage, selection and accepted message identity remain. This closes IR-14 acceptance 8. Register tests in core/worker/server suites and record blocked prerequisite evidence explicitly if either external adapter is absent.


## Idempotence and Recovery


Use additive, schema-qualified migrations created through `just new-migration`; never edit an applied migration or upstream private tables. Re-running migrations and accepted commands must converge. Retain payloads and deduplication records referenced by live executions, idle sessions, pending handoffs or unresolved effects; terminal workflow GC is not permission to delete them. Roll forward after introducing a journal patch, because an older binary cannot serve its new branch. A storage or authority failure stops admission and preserves recorded work; retry with the same logical identities, not a newly minted root. At completion, distill durable storage/interface decisions into local ADRs under the contract in `agents/skills/exec-plan/ADR.md`.


## Interfaces and Dependencies


This plan owns session/mailbox/event types, session tables, owner epochs, `Flow.Workers`, coordination tool admission and operator session control. Logical signatures are `acceptMessage :: SessionRef -> OperationId -> ExpectedRevision -> Instruction -> ...`, `readEvents :: SessionRef -> Cursor -> Limit -> ...`, and `requestTransfer :: SessionRef -> OperationId -> ExpectedRevision -> NewOwner -> ...`; responses distinguish acceptance, conflict, denial and unresolved handoff. Define actual Haskell effect signatures at implementation without weakening these arguments.

IR-13, documented in `docs/improvement-requests/support-optional-major-task-tracking.md`, owns objective identity, current instructions, assignment revision/dependencies, accepted artifact/evidence references and conflict-aware checkpoints. IR-11, documented in `docs/improvement-requests/provide-governed-mutable-repository-workspaces.md`, owns real workspace fences and mutation recovery. These are external integration gates, not assumed modules. Plan 83 owns operation recovery and bounded execution; plan 81 owns resources; plan 82 owns selection. Plan 85 consumes events and proposals, while plan 87 consumes wake hints and current session state. No A2A, public HTTP control service or vendor terminal attachment is required.
