---
id: 97
slug: track-durable-tasks-and-authoritative-assignment-checkpoints-without-rei
title: "Track durable tasks and authoritative assignment checkpoints without Rei"
kind: exec-plan
created_at: 2026-10-28T20:12:06Z
intention: "intention_01m62265gjex4a0k54gsbwx4gs"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-28T20:12:06Z
---

# Track durable tasks and authoritative assignment checkpoints without Rei


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Follow `agents/skills/exec-plan/FRICTION.md` for implementation friction and distill durable decisions into `docs/adr/` before completion.


## Purpose / Big Picture


Deliver [IR-13](../improvement-requests/support-optional-major-task-tracking.md): a user or authorized agent can create a durable task, inspect its goal, completion criteria, assignments, evidence and next action, and continue it in another run or conversation without Rei or memory search. A successful worker run records evidence; only explicit acceptance of the integrated result completes the larger task. Concurrent updates either commit in order or return a visible conflict, and retries after a crash return the original receipt.

This plan selects Shikigami's own PostgreSQL-backed task owner and supplies the production objective/checkpoint and coordination-association providers already required by continuing workers. It is an independently owned prerequisite of [MasterPlan 14](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md), not another child of that master plan. It must not wait for plan 84 to finish, because plan 84 is waiting for this provider. IR-11 still owns repository workspaces and process fencing; plans 85–87 still own adaptive decisions, integrated repository qualification and recurring mandates.

The observable demonstration is an authenticated task created with Rei disabled, updated through a durable agent tool, read by a later run and a conversation, and inspected through the CLI/API with its original evidence and actor/run attribution. A second demonstration integrates real continuing-session results into the same task store and survives a lost acknowledgement and a stale concurrent update.


## Progress


- [ ] Milestone 1: authoritative task state, assignment checkpoints and immutable operation receipts pass real PostgreSQL concurrency and crash-window tests.
- [ ] Milestone 2: authenticated task commands, bounded inspection and trusted run/conversation associations work through the API and CLI with task-scoped authorization.
- [ ] Milestone 3: production checkpoint, ownership and retained coordination-scope providers pass continuing-session integration and explicit conflict-recovery tests.
- [ ] Milestone 4: dedicated durable Skill and Flow task capabilities, including independently admitted conversation turns, retain operation identity and authority across replay.
- [ ] Milestone 5: the no-Rei continuity demonstration, integrated-completion checks, compatibility gates and documentation establish the delivered IR-13 boundary.

Planning baseline: `7d38de14ac1013347259da1f4b559c5399ac8571`, inspected on 2026-10-28. No implementation or implementation-test results are claimed here.


## Surprises & Discoveries


(None yet.)


## Decision Log


2026-10-28: Keep authoritative task state in Shikigami, using its existing checked domain-command and transactional projection pattern. Memory is supplementary context and Rei is an optional external reference. A separate service would add another deployment and distributed commit boundary without satisfying a requirement unavailable in the existing store.

2026-10-28: Distinguish a task's access owner and overall completion from the owner of each assignment. Existing `ObjectiveVersion.owner` is compared with the worker session's owner, so worker-facing objective references must resolve a specific assignment within the task. One task-wide worker identity cannot serve multiple workers correctly.

2026-10-28: Expose task mutations through one closed command service, a dedicated native durable tool and a replay-safe Flow capability. Keep general capability overlays observation-only. Use runtime-owned operation keys, retained immutable requests and store receipts; tool names and model-supplied identities confer no authority.

2026-10-28: Include HTTP/CLI access, later-run and conversation continuity, explicit completion, and the real IR-13 side of worker integration. Preserve the existing workspace-provider boundary and fail closed for workspace transfers without IR-11. Do not make delivery of IR-13 depend on future adaptive orchestration, recurrence, offline replication, automatic Rei mirroring or an A2A protocol mapping. An optional Rei intention link satisfies the first integration slice.

2026-10-28: Definitive checkpoint conflicts require a retained non-commit result and explicit reconciliation. A transport timeout is not a conflict. Never silently replace a pending intent with a newly fetched version, because its original operation might already have committed.


## Outcomes & Retrospective


(To be filled during implementation.)


## Context and Orientation


A task is a goal spanning executions. An assignment is a versioned piece of that goal, with dependencies and a designated agent owner. A checkpoint is the authoritative current task/assignment view, including accepted evidence and pending work. A revision is a monotonically increasing integer used to detect intervening changes. An owner epoch increments on handoff so former owners cannot write using old authority. An operation key identifies one immutable command across retries; its fingerprint is a versioned digest of its complete semantic request. A receipt records the committed result of that command. These are different from a Keiro workflow journal, which records the steps of one execution, and from a Kioku memory session, which supplies recalled context.

The repository is a Cabal multi-package Haskell service. `shikigami-core` owns domain behavior, durable workflows and storage. `shikigami-api` owns HTTP contracts, `shikigami-client` their client, `shikigami-server` HTTP handlers and operator commands, `shikigami-workers` runtime composition, and `shikigami-migrations/sql-migrations/manifest` append-only migration ordering. Register new Haskell modules and tests in each package's Cabal file and test entry point. Generated code under `Generated/` comes from `domain/shikigami.keiro-workspace`; never edit it by hand.

`shikigami-core/src/Shikigami/WorkerSession/Checkpoint.hs` defines `ObjectiveVersion`, `CheckpointIntent`, `CheckpointReceipt` and `CheckpointProvider`. `CheckpointProvider.current` returns an assignment's revision, criteria revision, owner, epoch, active flag, resource root and cutoff. `shikigami-core/src/Shikigami/WorkerSession/Workflow.hs` checks all of these before admitting new work. A resource root is the existing shared execution-budget record; task state references it rather than copying counters.

`shikigami-core/src/Shikigami/WorkerSession/Integration.hs` retains an intent for at most 100 contiguous session events, calls the checkpoint provider, and advances the local cursor only after a matching receipt. `shikigami-core/src/Shikigami/WorkerSession/Transfer.hs` defines the workspace fence and ownership contracts. `shikigami-core/src/Shikigami/WorkerSession/Handoff.hs` retains settled fence evidence before asking the objective owner to transfer. `shikigami-core/src/Shikigami/WorkerSession/Store.hs` currently retains a conflicted checkpoint intent with no explicit supersession command. That fact must be addressed by milestone 3; otherwise a legitimate optimistic conflict can permanently block progress or handoff.

`shikigami-core/src/Shikigami/WorkerSession/Capability.hs` owns closed worker commands and `CoordinationAuthority.admit/reacquire`. The retained scope carries the accepted parent run, identity, memory session, resource root, delegation context, allowed worker slots and limits. `shikigami-core/src/Shikigami/WorkerSession/Tools.hs` demonstrates a native tool whose preparation receives the accepted `OperationContext`; description cannot execute it. `shikigami-core/src/Shikigami/Flow/Workers.hs` demonstrates the corresponding journaled Flow interpreter. Production currently has no task-backed authority source: `shikigami-workers/src/Shikigami/Workers/Config.hs` sets coordination to `Nothing`, and `shikigami-server/src/Shikigami/Server/Command/Workers.hs` constructs unavailable checkpoint/ownership providers.

Use the checked aggregate and protected payload pattern in `domain/shikigami-worker-session.keiro`, `shikigami-core/src/Shikigami/WorkerSession/Store.hs` and `shikigami-core/src/Shikigami/WorkerSession/Catalog.hs`. Domain events and application rows commit together. A live-only projection means protected payload tables cannot be reconstructed from public lifecycle metadata; it must refuse destructive rebuilds rather than invent missing payloads. `shikigami-core/src/Shikigami/Runtime.hs` registers the common catalog at startup.

`shikigami-api/src/Shikigami/Caller/Api.hs` and `shikigami-server/src/Shikigami/Caller/Verifier.hs` supply `ApiCaller`. Its identifier comes from the configured verifier, not request JSON. The current verifier represents one configured caller, not an issuer-backed multi-user directory. Task access control must still support distinct caller identities and test them with a verifier fixture. Anonymous API access must not gain task access by default. `shikigami-core/src/Shikigami/AgentRun/Ledger.hs` commits run acceptance and queue send together; task-run association must join that acceptance boundary. `shikigami-core/src/Shikigami/Agent/RunJob.hs` owns the versioned application input envelope.

Relevant ADRs were discovered by scanning `docs/adr/` filenames and headings. The bundle is not profile-governed in the current Mori manifest; preserve its existing Markdown convention. [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md) requires replay-safe effects and stable write identities, while [ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) forbids treating a lease or mutation descriptor as duplicate protection. [ADR 0033](../adr/0033-recorded-agent-principals-key-durable-state.md) keys durable agent authority by recorded principal, not mutable display name. [ADR 0047](../adr/0047-public-api-authentication-is-a-verifier-at-the-vertical-mount.md) separates authentication from resource authorization.

[ADR 0051](../adr/0051-resource-roots-own-conservative-reservations-and-actual-attempts.md) keeps budgets and cutoffs with the resource owner. [ADR 0057](../adr/0057-skill-parents-admit-frozen-assignments-and-await-execution-children.md) freezes native tool bindings and accepted operation context; [ADR 0058](../adr/0058-conversation-acceptance-and-wakes-retain-their-generation.md) gives conversation turns their own admission and generation. [ADR 0061](../adr/0061-continuing-sessions-own-ordered-assignments-and-retained-receipts.md), [ADR 0062](../adr/0062-session-generations-await-governed-children-and-retain-checkpoint-intents.md), [ADR 0063](../adr/0063-handoffs-establish-epochs-only-after-fences-and-versioned-owner-receipts.md) and [ADR 0066](../adr/0066-worker-commands-require-retained-scopes-and-fresh-exact-authority.md) establish mailbox ownership, retained intents, fenced transfer, and fresh exact action authorization. This plan supplies their missing task provider without replacing those owners.

[Plan 84](84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md) has implemented consumer mechanics but remains incomplete pending IR-11 and IR-13. [Plan 85](85-adapt-durable-delivery-through-validated-coordinator-decisions.md) requires versioned graph, instructions and integrated-acceptance evidence. [Plan 87](87-supervise-recurring-objectives-from-current-durable-checkpoints.md) requires current-state reads and mandate references; neither its scheduler nor its mandate lifecycle belongs here. This plan can establish and test provider contracts now without starting those dependent plans.


## Plan of Work


### Milestone 1 — Persist authoritative tasks and conditional commands


Create `shikigami-core/src/Shikigami/Task/Types.hs`, `Task/Command.hs`, `Task/Store.hs`, `Task/Catalog.hs` and `Task/Acceptance.hs`. Add `domain/shikigami-task.keiro` to the workspace, generate the lifecycle/read-model modules, and add a migration through `just new-migration task-checkpoints`. Use schema-qualified `shikigami` tables for current task state, assignment records, command receipts, protected payloads, associations, retained scopes and checkpoint source cursors. Register their projection group in the shared generated catalog. Preserve receipts and protected records independently of terminal workflow garbage collection.

A task has a stable `TaskId`, access owner, explicit member roles, title, goal/instructions, `revision`, `instructionsRevision`, `criteriaRevision`, structured completion criteria, status, bounded decisions/assumptions/next actions, and optional external references. Statuses are `Open`, `Blocked`, `Completed` and `Cancelled`; blocking is reversible, and completion/cancellation stop fresh progress admission. Administrative access changes and reconciliation of already accepted effects remain possible without reopening a terminal task. Do not infer completion from run status. A single-task aggregate serializes graph and accepted-progress changes; retain historical evidence rather than rewriting it when an assignment changes.

A `TaskAssignmentId` is distinct from a continuing session's per-message `AssignmentId`. It identifies a logical work item and stores instruction revision, dependencies, designated agent principal, owner epoch, state and references to its worker session and accepted result revisions. The task graph must reject duplicate identities, dangling dependencies and cycles. A result reference includes the producing run/execution/session, immutable result or payload digest, artifact identity and acceptance disposition. Narrative notes are not acceptance evidence. Unresolved operations reference their owning execution/session records and remain visible until reconciled by that owner.

Use an access-principal sum distinguishing verified API caller, recorded agent identity and trusted local operator. Never turn an arbitrary principal-shaped string into authority. Owner and explicit coordinator roles may manage assignments and propose acceptance; worker members may record progress only on assignments they own; read-only members may inspect only permitted task data. Only owners or explicitly granted completers can accept completion. Grant/revoke operations are versioned owner commands. An agent may create a task only when operator policy grants task creation; creating it cannot grant access to existing tasks. Preserve the existing explicit development identity mode without promoting it to verified authority.

All writes pass one command executor. Check task membership/role and its revision inside the same transaction as the write, so concurrent revocation cannot race an authorized mutation. Obtain any external exact-action decision immediately before that boundary, without holding a database lock across its network call. Authenticate and authorize the caller first; then look up an existing operation receipt before optimistic revision validation. The deduplication key includes task and operation identity; the fingerprint includes actor, command tag, semantic payload, expected revisions and owner epoch. An identical accepted retry returns the original receipt even after later progress; changed payload under the same key conflicts. New writes lock/check the task revision, validate the whole transition, append the checked lifecycle event, write protected data/current rows and store the receipt in one transaction. On conflict return a typed result, with no partial progress or evidence writes. Persist definitive provider non-commit outcomes needed by milestone 3 so a conflicted operation cannot later become accepted. Connection loss produces uncertainty, not a manufactured negative receipt. Creation has a uniqueness key scoped to authenticated creator and operation, so retry cannot create a second task.

Define `TaskAcceptance` here as the task/instruction/criteria revisions, exact integrated artifact references, per-criterion check evidence, user-journey evidence where required, recorded limitations, proposer and approving authority. Automatic checks must refer to retained verifier/run results, not a model-authored Boolean. A human-verifiable criterion requires an explicit authorized attestation. Completion rejects stale criteria, unmet required dependencies, unresolved relevant operations, missing/failing checks and mere child success. Store acceptance and terminal status atomically. Plan 85's future `IntegratedAcceptance` adapts to this owner contract rather than becoming another completion store.

Add `shikigami-core/test/Shikigami/TaskSpec.hs` and `shikigami-core/test-postgres/Shikigami/TaskStoreSpec.hs`. Before broadening the UI, prove one real session result can be persisted as task progress and projected into the existing `ObjectiveVersion` shape. Test two writers at one revision, identical retries after progress advances, conflicting key reuse, rollback after evidence insertion and a process loss after commit but before acknowledgement. Milestone acceptance is one surviving update and receipt, unchanged accepted evidence, a visible losing conflict, and task data still readable after a fresh database connection.


### Milestone 2 — Expose governed inspection and trusted associations


Add `shikigami-api/src/Shikigami/Task/Api.hs`, `shikigami-server/src/Shikigami/Task/Handler.hs`, and `shikigami-server/src/Shikigami/Server/Command/Tasks.hs`. Extend `shikigami-api/src/Shikigami/Api.hs`, `shikigami-server/src/Shikigami/Server/App.hs`, `shikigami-client/src/Shikigami/Client.hs`, CLI parsing in `shikigami-server/src/Shikigami/Server/Command.hs`, and OpenAPI generation/tests. Mount the task vertical under the existing authenticated boundary. The API offers `POST /tasks`, `GET /tasks`, `GET /tasks/:taskId`, `GET /tasks/:taskId/history`, and `POST /tasks/:taskId/commands`; command bodies use the closed versioned sum, explicit operation key and expected revision. Return 201 for creation, 200 for identical replay/read/accepted command, 409 for stale version or key mismatch, 413 for oversize payloads, and 503 for store unavailability. Missing and inaccessible task reads both return 404; authenticated users lacking a permitted operation receive a bounded 403. Apply authorization to list/history/payload reads as well as writes.

Provide `shikigami tasks create --operation-key KEY --file FILE --json`, `tasks inspect TASK --json`, `tasks history TASK --after CURSOR --limit N --json`, and `tasks command TASK --operation-key KEY --expected-revision N --file FILE --json`. These call the same command service. A local operator is a separately recorded trusted administrative identity loaded from configuration; CLI flags cannot impersonate an API caller or recorded agent. Agent operations also use the existing exact `InvokeCapabilityTool` action authorizer, binding task/scope revision and the full command digest, in addition to task membership and current principal lifecycle. Operator/API access follows task membership or explicit operator administration policy, never an agent identity supplied in the request.

Default pages to 20 and cap at 100. Bound command payloads to 1 MiB and model replies to 16 KiB; large evidence is stored behind protected references and read with explicit pagination. Use stable revision/cursor ordering, not timestamps alone. Public metadata must not include instructions, tokens, hidden model context or unrestricted result bodies. Missing or unknown codec versions fail explicitly.

Create `shikigami-core/src/Shikigami/Task/Association.hs`. Add an optional typed task/assignment reference to fresh public run requests and the application-owned run envelope. Keep old decoders and absent-task behavior, and include the association in new request fingerprints so an idempotency key cannot be replayed against another task. Do not reinterpret arbitrary old trigger JSON as trusted task metadata. Update `shikigami-core/src/Shikigami/AgentRun/Ledger.hs`, `shikigami-server/src/Shikigami/AgentRun/Handler.hs`, `shikigami-api/src/Shikigami/AgentRun/Api.hs` and `shikigami-core/src/Shikigami/Agent/RunJob.hs` so permitted association, run acceptance and queue send commit together, using the owning store transaction interfaces. No second queue or post-enqueue best-effort attachment.

For conversations, an authorized `BindConversation` task command links an existing conversation and recorded participant agent to the task. Resolve the conversation through its owning index, reject unrelated participants, and retain binding revisions. A turn snapshots its association only at its own new admission; rebinding affects later turns, never accepted work. Run/session/conversation identities are links to task state, not replacement task IDs. Protected task lookup and command execution recheck current membership even when a historical association exists.

The closed command sum contains `ReviseInstructions`, `ReviseCriteria`, `SetAssignments`, `RecordProgress`, `RecordEvidence`, `SetNextAction`, `SetBlocked`, `ProposeCompletion`, `AcceptCompletion`, `CancelTask`, `GrantMember`, `RevokeMember`, `BindConversation` and `LinkExternal`. Creation is its own endpoint. Provider-only checkpoint ingestion and ownership transfer are internal commands, unavailable as arbitrary HTTP/model tags. Public command envelopes carry `format: 1`, `operationKey`, `expectedRevision` and `command`; the command discriminant is `tag`. Native tool adapters inject the operation key and trusted actor rather than accepting them in tool JSON. `SetAssignments` validates and commits the entire proposed bounded graph; it cannot change an active session owner without the handoff protocol. Write exact JSON examples and schema tests together with these types.

Add server contract tests with two distinct authenticated callers, revoked agents, an anonymous caller, and a forged task reference in trigger text. Verify authorized users can create, inspect, revise and submit associated runs; unauthorized reads reveal no protected task content and unauthorized associations enqueue nothing. An old unassociated request still follows its original fingerprint and queue-codec path. This is the acceptance boundary for milestone 2.


### Milestone 3 — Supply the real checkpoint and scope providers


Create `shikigami-core/src/Shikigami/Task/Checkpoint.hs`, `Task/Ownership.hs`, and `Task/Coordination.hs`. Use provider id `shikigami-task-v1`; encode the stable task and `TaskAssignmentId` together in its opaque reference key. Existing `ObjectiveRef` codecs stay intact. `current` returns the task revision, the addressed assignment revision, task criteria revision, assignment owner/epoch, admitted resource root and the effective current cutoff. Resolve resource/mandate authority through its owner and fail closed if unavailable or inactive. An ordinary finite task needs no worker session or root; it becomes a coordination slot only after explicit admission binds the already accepted execution root. Retain root references; never reset budget by minting a replacement during reattachment.

Implement `CheckpointProvider.commit` using the task command transaction. Validate the retained session binding, parent actor, assignment mapping, epoch, root, complete expected version and the contiguous source event range. Verify submitted events against the session owner's retained receipts; an event body from tool JSON is not trusted evidence. Deduplicate `(sessionId, cursor)` ingestion as well as operation keys. Atomically retain result/evidence references, decisions and next actions and advance the task-side source cursor. Treat worker results as reported progress pending acceptance. Return `CheckpointAccepted` only with the exact fingerprint and advancing revision expected by `matchesReceipt`. Return the same receipt before version checks on accepted retry, including when the local consumed cursor has not yet advanced.

Implement `OwnershipProvider.transfer` with the same receipt rules. Require a fence proof validated against the trusted configured workspace provider and retained handoff record; string equality alone does not establish that a workspace stopped writing. Atomically change only the addressed assignment's owner/epoch, preserve evidence and increment task/assignment revisions. Scope all protected provider callbacks to authenticated internal authority; `current` has no actor argument, so it must not become a public unchecked read, and the actor carried in an intent must be checked against retained session authority. A provider callback is not an authorization grant.

Add explicit checkpoint-conflict reconciliation in `shikigami-core/src/Shikigami/WorkerSession/Integration.hs`, `WorkerSession/Store.hs`, `WorkerSession/Capability.hs` and the session domain declaration. The task owner must first retain a definitive rejected/non-committed outcome for the original operation. A new parent-authorized reconciliation command validates that proof, records supersession, and clears/replaces the pending intent without advancing the consumed cursor. It then prepares a new operation against freshly read authoritative state. Keep the original intent and rejection for audit. If the old result is accepted or unknown, recover its receipt or continue waiting; never supersede it. A changed owner/criteria requires explicit revalidation of the retained events, not automatic acceptance under new meaning. Extend the closed worker tool/CLI command surface and compatibility readers for this transition.

Implement `CoordinationAuthority` from accepted task/run associations, recorded delegation context, model permissions and operator-bounded worker slots. Persist each admitted scope by fingerprint and retain it as long as any run/session references it. `reacquire` returns that exact scope, while each fresh action checks current task authority and versions. Replacing instructions, rotating a coordinator or compacting model context cannot replace the scope's root, reset limits, widen permissions or silently select another principal. New assignment admission after a task revision change must read current versions and obtain a fresh explicit decision. A pending old operation keeps its original request.

Wire the real providers through `shikigami-workers/src/Shikigami/Workers/Config.hs`, shared runtime/catalog construction and `shikigami-server/src/Shikigami/Server/Command/Workers.hs`. Expose an explicit operator task-tracking enablement setting in `shikigami-core/src/Shikigami/App/Config.hs` and its loader. Missing provider/authority refuses relevant work; ordinary unassociated runs still work. Do not fabricate a workspace provider when IR-11 is absent.

Add `shikigami-core/test-postgres/Shikigami/TaskCheckpointSpec.hs` using real session and task stores. Start two workers with separate task assignments, retain one result, commit its checkpoint and drop the acknowledgement. Restart integration and prove one task revision/evidence update and one eventual cursor advance. Race an owner or criteria change with another checkpoint, prove visible conflict and successful explicit reconciliation without losing accepted results. Recreate the provider host and recover a retained coordination scope. Ownership tests use a trusted deterministic fence fixture only to qualify the task-side contract and receipt recovery; they do not claim real workspace fencing. Milestone 3 delivers the IR-13 provider gate, while plan 84's IR-11 gate remains open until its actual provider is qualified.


### Milestone 4 — Make task capabilities durable for agents and conversations


Create `shikigami-core/src/Shikigami/Task/Capability.hs`, `Task/Tools.hs`, and `shikigami-core/src/Shikigami/Flow/Tasks.hs`. The native tool is a closed `tasks` command surface for authorized create, inspect, assignment progress, evidence, next-action and completion proposals. Authority fields and operation keys are absent from model arguments. The tool binding includes its immutable contract revision and retained task scope fingerprint. Preparation receives the accepted `OperationContext.operationId`; description invokes no command. The backend remains an idempotent local effect with no provider invoice, as in the existing worker tool. No generic overlay mutation policy changes.

The Flow effect exposes typed reads and commands under caller-supplied static labels. Its interpreter journals bounded replies and derives operation identity from workflow ID, generation and label, or consumes a retained domain operation reference for cross-generation work. It does not grant `IOE` or raw store access to Flow bodies. Read results are journaled within one decision; a later decision/generation rereads current authoritative task state before new work. Historical checkpoint snapshots cannot overwrite new instructions or owner state. Completion requires the explicit completer grant and milestone 1 evidence validation even when the tool is present.

Extend `shikigami-core/src/Shikigami/Agent/Workflow.hs`, `shikigami-core/src/Shikigami/Agent/Conversation.hs`, `shikigami-core/src/Shikigami/Flow.hs` and runtime dependency construction. Admit task tools for eligible durable Skills and task-aware Flows only when the trusted association/operator policy permits them. A conversation uses its own recorded turn identity, task association and accepted operation coordinates, never a borrowed agent-run journal. Keep existing atomic assistant/reply ownership. Unsupported legacy coarse behavior and database-free one-off paths refuse requested task mutation clearly; they do not fall back to an unsafe tool loop. The user can still use the authenticated task API from a client without running a local agent.

Follow [docs/workflow-versioning.md](../workflow-versioning.md). Declare real new guards `shikigami-task-tracking-v1` for agent runs and `shikigami-conversation-task-tracking-v1` for conversations in the owning domain members, retaining complete old branches and codecs. Use a new policy-resolution step only behind the new branch; old runs must not consult task policy or suddenly acquire tools. Freeze each accepted execution's bindings and scope before dispatch. Register concrete task Flow labels in the checked specification. Regenerate artifacts and union patch sets through `shikigami-core/src/Shikigami/Workflow/Versioning.hs`. If unbounded task iteration is introduced, restore a seed first and rotate with `continueAsNew`; no dynamic label counters. This plan does not use the pre-v1 reset exception.

Add `shikigami-core/test-postgres/Shikigami/TaskWorkflowSpec.hs` and deployment cases in the existing workflow-versioning suite. With a scripted model transport and real execution/task stores, crash after a task command commits but before its tool result is recorded; resume and verify the same operation, receipt, evidence and task revision. Revoke task membership between admission and dispatch and verify no new write. Start a later run and a later conversation turn and verify they read current progress without memory recall. Replay old-shape agent/conversation journals and verify their original behavior. Completion of this milestone means the actual model-tool and Flow paths work, not merely a direct call to the store.


### Milestone 5 — Qualify continuity, document ownership and close IR-13


Add a reproducible no-Rei fixture under `fixtures/qualification/tasks/` and an isolated runner `tests/task-tracking/run.sh`. It must provision only disposable test resources, select scripted model responses and authenticated task callers, and use the serving API/workers with the real task/session stores. Make the fixture create a two-assignment finite task, run authorized progress, restart, continue from a second run and conversation, and produce an inspectable final checkpoint. Include the checkpoint lost-ack and stale-conflict scenario from milestone 3, preserving the accepted result after a transfer of assignment ownership. The fence fixture remains explicitly labeled; task acceptance requires no real repository writes.

For completion, report both workers successful while one integrated criterion fails: the task must remain open. Then record a passing verifier result for the exact combined artifact and current criteria, submit explicit authorized acceptance and observe one `Completed` transition. An older completion command must not close a task whose criteria changed. Unknown child/tool operations must still block acceptance. Repeating acceptance returns its original receipt. Cancellation stops new work but preserves late facts and unresolved operations without claiming that external effects stopped.

Write `docs/operations/task-tracking.md` and `docs/user/tasks.md`, describing configuration, commands, role boundaries, operation-key retry rules, conflict reconciliation, protected evidence, retention and the distinction between task/assignment, run, memory session, conversation, Rei intention and A2A Task. Persist optional typed external links only; automatic mirroring is outside this slice and failure of Rei must never change task state. Update `docs/user/README.md`, `docs/operations/operator-cli.md`, the domain inventory, IR-13, UC-1, roadmap, and MasterPlan 14/plan 84 prerequisite wording to link this provider and its actual evidence. Do not mark IR-11 or plans 84–87 complete from this plan's fixture results. Keep the IR proposed/planned until implementation acceptance is met, then record its delivered scope precisely.

Maintain OKF profile metadata, timestamps, indexes and logs for changed profiled documentation using the repository's existing commands. Add or update ADRs for task ownership, receipt/authorization ordering, assignment mapping, explicit conflict resolution and integrated completion. Record friction triage and acceptance evidence in this plan. Milestone 5 is complete when the isolated runner, relevant package suites and ordinary durable compatibility gates pass, and a fresh reader can reproduce continuity with no Rei endpoint configured.


## Concrete Steps


Run commands from the repository root, `/Users/shinzui/Keikaku/bokuno/shikigami`. Enter the development environment if needed:

```bash
nix develop --no-write-lock-file
```

Capture `git rev-parse HEAD` as the implementation baseline before edits. Use that exact revision for the final compatibility gate; the creation baseline above is only valid if implementation starts there. Confirm the normal project builds first:

```bash
cabal build all
```

The working session used for plans 83–84 also has `.dev/mp13.cabal.project` and `.dev/mp14-clean-dist`, with isolated dependency paths. They are local conveniences, not portable prerequisites. If the checked-in project cannot resolve its existing co-developed dependencies, locate their owners with Mori, follow `docs/dependency-cohort.md`, and reconstruct a local project using the same selected revisions. Do not copy another machine's absolute paths into committed configuration or change package bounds to bypass a failure. If using the existing local project, apply it consistently to builds/tests and the Cabal invocations inside the gate. For the HTTP runner, set `SHIKIGAMI_CABAL_PROJECT=.dev/mp13.cabal.project`, which `tests/hurl/run.sh` already supports; make the new task runner honor the same setting. The gate recipes currently invoke plain `cabal`, so their actual invocations must use the selected project as well rather than accidentally validating a different dependency graph. Record the chosen project in acceptance evidence.

```bash
cabal build --project-file=.dev/mp13.cabal.project --builddir=.dev/mp14-clean-dist all
cabal test --project-file=.dev/mp13.cabal.project --builddir=.dev/mp14-clean-dist shikigami-core-test shikigami-core-postgres-test shikigami-server-test shikigami-workers-test shikigami-agent-test --test-show-details=direct --test-options='--num-threads=1'
```

Create the additive migration and regenerate after domain edits:

```bash
just new-migration task-checkpoints
cabal run -v0 keiro-dsl -- scaffold domain/shikigami.keiro-workspace --out shikigami-core/src
just migration-schema-isolation
```

The migration command prints the created timestamped path and appends it to the manifest. The schema check must exit zero. Do not run `just new-migration` twice for the same change. The PostgreSQL test suite applies migrations to disposable databases through `shikigami-core/test-postgres/Main.hs`; no production connection is needed.

After registering the new test groups, run focused checks during implementation and the affected complete suites at the final boundary:

```bash
cabal test shikigami-core-test shikigami-core-postgres-test --test-show-details=direct --test-options='--num-threads=1'
cabal test shikigami-server-test shikigami-workers-test shikigami-agent-test --test-show-details=direct --test-options='--num-threads=1'
just hurl
bash tests/task-tracking/run.sh
```

All commands must exit zero. The new fixture runner must print task ID, final revision, original/replayed receipt IDs and the final status without protected payloads. It must report the unauthorized cases refused, stale cases conflicted, the failed integrated acceptance still open and the final explicit acceptance completed. The runner and task CLI commands are deliverables of this plan, not commands available at creation time. Add a smoke invocation to the runner using:

```bash
cabal run shikigami -- tasks create --operation-key ir13-demo-create --file fixtures/qualification/tasks/create.json --json
cabal run shikigami -- tasks inspect TASK_ID_FROM_CREATE --json
```

The fixture must document its isolated configuration and replace the placeholder with the returned ID. Keep the same create key across retries so creation returns the same task. Its command/evidence JSON examples must match the final public schema, and its real API path must also exercise the CLI's shared command owner.

At a coherent implementation commit, run the ordinary gate against the saved pre-change revision:

```bash
just keiro-gate IMPLEMENTATION_BASELINE
just improvement-requests-validate
just use-cases-validate
just user-docs-validate
git diff --check
```

`keiro-scaffold` inside the gate compares `shikigami-core/src` against the committed candidate, so commit the intended source/generated changes before using that check as final evidence. Every implementation commit includes `ExecPlan: docs/plans/97-track-durable-tasks-and-authoritative-assignment-checkpoints-without-rei.md` and the frontmatter's `Intention:` value, and follows Conventional Commits. Keep working on the current branch. Gate reports must contain no unexplained breaking findings; do not weaken the gate or hide a declared step to make it pass.


## Validation and Acceptance


Milestone 1 proves the persistence guarantee at its actual transaction boundary: task state, evidence, lifecycle event and receipt either all commit or none do. Two concurrent writers from one revision yield one accepted transition and one conflict. Creation retry and mutation retry return the original IDs after reconnect. Wrong-key payload reuse, graph cycles, stale owner epochs and invalid completion all leave state unchanged.

Milestone 2 proves governed use through supported entry points. Caller A can inspect its task; caller B and an ungranted agent cannot read, list, mutate or attach it. Revocation affects fresh operations and protected reads. Replay receipt lookup never bypasses authentication or current permission to see that receipt. Existing anonymous/unassociated run functionality remains intact while task access remains denied by default. CLI and HTTP commands return the same domain outcomes and pagination is bounded.

Milestone 3 is the early and continuing integration proof: actual worker result/event producers feed the actual task provider. A dropped task acknowledgement followed by a local cursor-commit failure converges without duplicate progress. Stale updates cannot erase accepted results or restore an old owner. Explicit rejected-intent reconciliation unblocks progress, while unknown outcomes keep their original intent. Different workers on the same task resolve different assignment owners and never share writable scope accidentally. Retained coordination scopes survive process restart and parent rotation without resetting root limits. Fixture fence results qualify only the task owner's transfer protocol.

Milestone 4 proves end-to-end replay through real durable execution and conversation admission. Disable memory recall in the fixture; a second run and conversation still obtain the exact current task revision and evidence. Crash after tool commit and retry the accepted operation. Restore a historical journal under new code and prove no added task policy call on its old branch. Inject unavailable task authority and verify refusal before model/tool dispatch where admission requires it. An accepted execution retains its original tool binding while fresh commands still respect revocation and version changes.

Milestone 5 proves the user's outcome: with no Rei configuration, the task outlives runs and process restarts, preserves authorship/evidence and completes only after explicit current integrated acceptance. The real task provider closes the IR-13 prerequisite; it does not claim an IR-11 late-writer test, an adaptive coordinator or recurring scheduler that this repository has not yet delivered. Record actual passing counts and fixture output only after running them.


## Idempotence and Recovery


Migrations are additive, schema-qualified and manifest-ordered. Never edit or rename an applied migration. Retain task data, command outcomes, task-side event cursors, protected evidence, associations and scope fingerprints beyond workflow journal collection. Initially retain them indefinitely; deletion/compaction needs a separately designed policy that preserves live and deduplication references. Do not rebuild live-only tables from incomplete event metadata.

On lost acknowledgement, retry the original command bytes and key. Accepted receipts precede revision checks; task access checks still precede disclosure. A known stale conflict is resolved by a new explicit command against reread state. A pending checkpoint is superseded only after a retained definitive non-commit proof; a timeout never supplies that proof. An accepted ownership transfer with a missing local acknowledgement must finish the original handoff using its saved receipt and fence, not allocate a replacement session or root.

Task revision serialization may make simultaneous workers conflict even when editing different assignments. That is an intentional first-slice correctness tradeoff. Preserve the failed proposal, read the current task and explicitly revalidate/reissue it; do not implement last-writer-wins or hidden retry that drops evidence. Any future finer-grained concurrency must preserve atomic graph/completion validation.

Roll forward after introducing new workflow patches or durable enum values. Disable new task admissions if necessary while retaining readers and reconciliation for accepted operations. Disabling a task feature must not select an older unsafe mutation path or drop task associations. Database backup/restore must include the task tables and their underlying event streams together. The fixture runner owns and cleans up only resources it created.


## Interfaces and Dependencies


`Shikigami.Task.Types` owns `TaskId`, `TaskAssignmentId`, access principals, versioned snapshots, commands, receipts and evidence references. `Shikigami.Task.Store` owns conditional persistence; `Shikigami.Task.Capability` owns authenticated command admission; API, CLI, Flow and model tools are adapters over that owner. Expose typed create/read/execute/read-receipt operations and typed errors for missing, denied, conflict, invalid evidence, unavailable and unresolved outcomes. Actor/run attribution is supplied by trusted adapter context, never copied from model content.

`Shikigami.Task.Association` owns task links to accepted runs and conversations. `Shikigami.Task.Coordination` supplies the existing `CoordinationAuthority` contract. `Shikigami.Task.Checkpoint` and `Shikigami.Task.Ownership` implement the existing worker consumer records. Keep the existing fingerprints and receipt matchers; any expanded durable protocol gets an explicit new version and retained old reader. Task completion belongs to `Shikigami.Task.Acceptance`; plan 85's coordinator validates proposals and submits evidence to it.

Use existing dependencies and selected cohort, with no version upgrade proposed here. Mori discovery located the public projection API in `mori://shinzui/keiro`, project-relative `keiro/src/Keiro/Projection.hs` (artifact-level URI pending): `runCommandWithCatalogProjections` commits inline projection handlers in the command append transaction and returns typed catalog/fence failures. The checked-in worker-session adapter is the concrete local usage to follow. Other owned dependencies remain `mori://shinzui/kiroku/packages/kiroku-store`, `mori://shinzui/kioku/packages/kioku-core`, and `mori://shinzui/kikan-en` for the existing exact capability action contract. Locate any additional dependency API through Mori and read its source before using it. Verify authoritative registry releases and upstream tags before changing bounds or pins; local registry metadata can lag.

There is no new required Rei service, workspace implementation, A2A identity mapping or offline store. Task IDs may link to a Rei intention, ExecPlan or external protocol task, but their independent lifecycles remain explicit. Session/mandate/root authorities retain their mutable state; task checkpoints hold references and resolve current facts at admission. This plan's completion is sufficient for the task side of MasterPlan 14's integration gates, not proof that all its separately owned dependencies are complete.
