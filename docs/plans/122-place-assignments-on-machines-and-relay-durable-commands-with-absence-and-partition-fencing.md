---
id: 122
slug: place-assignments-on-machines-and-relay-durable-commands-with-absence-and-partition-fencing
title: "Place assignments on machines and relay durable commands with absence and partition fencing"
kind: exec-plan
created_at: 2026-11-04T19:26:00Z
intention: "intention_01m6m0b6zxebfv3yatcy7fvbgk"
master_plan: "docs/masterplans/21-execute-governed-work-through-enrolled-machine-daemons.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-11-04T19:26:00Z
---

# Place assignments on machines and relay durable commands with absence and partition fencing

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Today every governed workspace operation runs on the host that runs the durable worker. The worker's edit, Git and process adapters write their reservations and receipts into PostgreSQL and perform the physical effect locally, or hand the process launch to `shikigami-workspace-supervisor` over a Unix socket on the same host. Nothing can place an assignment on another machine, and nothing describes what happens when the machine running an effect is unreachable.

After this plan, an operator's workspace grant can name a machine. When an assignment for that grant is admitted, the central runtime selects that machine explicitly, requires it to be enrolled and, before installing any process tool, requires it to have declared a qualified Linux containment profile. The same durable adapters that run locally today get remote counterparts: they reserve exactly as before in PostgreSQL, then write one bound command row and wait for the machine's receipt. The gateway delivers queued commands to the connected daemon, settles each receipt once through the owning workspace store and the execution owner's independent late-receipt path, and acknowledges it. A machine that is disconnected leaves its commands queued and the execution unresolved; no state ever becomes failed because time passed. A revoked machine refuses new commands and retries while its unresolved commands stay inspectable. A transfer away from a machine that cannot be reached starts the successor in a new workspace at an explicit approved base, freezes the old workspace, records a pending fence, and delivers that fence to the old machine before anything else when it returns, so its stale commands are refused and its late results settle only the old attempt's accounting.

You can see it working in the PostgreSQL suite: `cabal test shikigami-core-postgres-test --test-options='-p MachineRelay -j1'` runs a remote edit through an in-process fake daemon, shows the execution settle once through `recordIndependentToolReceipt`, redelivers the same dispatch and shows it converge on the same command row, disconnects the fake daemon and shows the command `Queued` and the execution `Unresolved`, restarts the central publication loop and shows the receipt published once, and revokes the machine and shows the retry refused with `MachineRevoked`. The final milestone repeats the partition cases against the real daemon in a Linux guest. This plan is EP-4 of [MasterPlan 21](../masterplans/21-execute-governed-work-through-enrolled-machine-daemons.md).


## Progress

- [ ] Milestone 1: `Placement` and `RepositorySource` exist in `Shikigami.Workspace.Settings`, `Shikigami.Workspace.Types` and `Shikigami.Workspace.Instructions`; old binding, grant and snapshot JSON decodes unchanged; machine selection at admission refuses a machine that is not enrolled, not listed for the repository, or unqualified for a process adapter; `just keiro-gate` passes with no workflow body change.
- [ ] Milestone 2: The command and fence tables exist, `Shikigami.Machine.Store` relays commands, the remote edit adapter and gateway settlement pass the relay check against an in-process fake daemon (settle once, redelivery converges, disconnected stays `Queued` and `Unresolved`, central restart republishes once, revoked refuses), and the MasterPlan's relay gate is checked off.
- [ ] Milestone 3: Remote process, Git and same-machine integration adapters exist; a transfer during a partition allocates the successor on an explicit base, freezes the old binding, records a pending fence that the real daemon applies before any other exchange on reconnection, and the old epoch's late receipt settles accounting only. The native `--machine-relay` mode passes in a Linux guest.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The daemon is thin and the central runtime keeps all durable bookkeeping. Every reservation, epoch, receipt row and attempt stays in PostgreSQL; the machine returns receipts that the central runtime records.
  Rationale: IR-20 requires that the daemon hold no central credential. Reusing the existing stores and the existing independent late-receipt path keeps one owner of epochs and attempts and reuses the recovery contract in [ADR 0060](../adr/0060-safe-recovery-spends-new-attempts-and-retains-independent-receipts.md).
  Date: 2026-11-04

- Decision: Absence is the durable state `Queued` on the command and `Unresolved` with a pending receipt on the execution. A timeout is never a failure; only a receipt or a refusal from the machine moves a command to a terminal state.
  Rationale: The request states that a timeout alone never counts as failure and that a lost acknowledgement stays unknown until the machine's retained receipt settles it. The execution owner already models dispatched uncertainty with a retained cursor and reservation ([ADR 0054](../adr/0054-execution-attempts-own-dispatch-fences-and-generation-wakes.md)).
  Date: 2026-11-04

- Decision: A transfer away from a disconnected machine allocates a new workspace for the successor at an explicit approved base and records a pending fence. The old workspace is frozen; its queued commands are superseded; the fence is delivered in the `Welcome` frame and must be acknowledged before any command or receipt is exchanged.
  Rationale: [ADR 0063](../adr/0063-handoffs-establish-epochs-only-after-fences-and-versioned-owner-receipts.md) forbids a successor writing the same resource before the former writer is fenced and settled. A partition makes that proof unobtainable. A new workspace is a different resource, so the successor needs no fence proof from the absent machine, and the request itself says a move uses fenced handoff and an explicit base.
  Date: 2026-11-04

- Decision: Receipts settle through a generalization of the supervisor's `publishProcessReceipt`, never through a new execution write path.
  Rationale: That function already performs the routing, attempt, fingerprint and phase checks that make a late receipt safe to accept, and already calls `recordIndependentToolReceipt`, `markExpiredExecutionAttemptUncertain` and `publishExecutionWake`. A second path would duplicate those checks and eventually disagree with them.
  Date: 2026-11-04

- Decision: The remote adapter's wait releases the runtime capacity permit through the existing executor finalizer while the root's usage stays held as unknown.
  Rationale: [ADR 0109](../adr/0109-runtime-capacity-admission-shares-accepted-attempt-fences.md) says long external execution holds no capacity transaction and that a trusted local finalizer may release the exact permit after local dispatch has unwound without settling unknown root usage. A machine absent for hours must not hold a deployment-wide execution slot, and it must not free its root's budget either.
  Date: 2026-11-04


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a Cabal multi-package Haskell service. `shikigami-core` owns domain behavior and PostgreSQL store adapters, `shikigami-workers` owns long-running loops and the concrete workspace adapters, `shikigami-server` owns operator commands and the HTTP server, and `shikigami-migrations` owns append-only SQL migrations plus the `test-support` sublibrary that gives each test an isolated migrated database. `docs/architecture/packages.md` describes the rules; `tools/style/module-ownership.json` lists every concept root and `just haskell-conventions` fails on an unlisted one. The `Machine` root is added by plan 119, which this plan requires to be Complete.

A *workspace* is a provider-owned private copy of a repository at an approved commit, identified by a `WorkspaceBinding` (`shikigami-core/src/Shikigami/Workspace/Types.hs`) that carries an allocated `WorkspaceId`, the `WorkspaceRequest` (run, optional session and assignment, root, principal, owner, owner epoch), a `WorkspaceRef` locator, `repository`, `base`, `policyRevision`, `storageRoot` and `source`. An *owner epoch* is `StateRevision "worker-owner"`, the monotonically increasing number that identifies which owner may write; a *fence* is proof that an earlier epoch's writes and processes cannot continue. The *admission snapshot* is `WorkspaceAdmission` (`shikigami-core/src/Shikigami/Workspace/Instructions.hs`) frozen into the protected `ExecutionSnapshot.workspace` field (`shikigami-core/src/Shikigami/Execution/Transcript.hs`) at admission by `admitSkillExecutionWithAdmissions` in `shikigami-core/src/Shikigami/Execution/Start.hs`; it fixes the workspace, binding digest, run, assignment, root, owner, epoch, instruction bundle and `filePolicy` for the life of the execution.

*Placement* is new in this plan: where a workspace's physical files live. Today it is always the worker's host. A *machine* is a host enrolled through plan 119, identified by a `MachineId` and named by a `MachineName`, running the *daemon* `shikigami-machine`, which connects outbound to the *gateway* role `shikigami-machine-gateway` and executes typed operations. The *relay* is the central path that turns a tool dispatch into a bound command row, delivers it to the daemon over the session, and settles the daemon's receipt. A *receipt* is the machine's retained record of an operation's outcome (`FileReceipt`, `ProcessReceipt`, Git outcome or `FenceOutcome`); a *late receipt* is one that arrives after the central runtime has stopped waiting for it. An *uncertain attempt* is an actual dispatch whose effect may or may not have happened; the execution owner keeps its reservation and cursor and marks the operation `Unresolved`. A *capacity permit* is the deployment-wide execution admission ticket from `Shikigami.Execution.Capacity`. A *partition* is a period during which the machine cannot reach the gateway.

The existing dispatch path: `Shikigami.Execution.Executor` dispatches a tool with a `DispatchContext` (`shikigami-core/src/Shikigami/Execution/Runner.hs`: `operation :: OperationContext`, `attemptId`, `owner :: ClaimOwner`, `generation :: StateRevision "execution-attempt"`) to a `DurableAdapter` (`shikigami-core/src/Shikigami/Capability/Provider.hs`: `descriptor`, `contracts :: [DurableToolContract]`, `prepare :: ExecutionSnapshot -> DispatchContext -> ExecutionCoordinate "tool-name" -> IO (Either ExecutionError SomeTool)`). The local adapters are `workspaceEditAdapter`, `supervisedWorkspaceEditAdapter` and `transferredWorkspaceEditAdapter` in `shikigami-workers/src/Shikigami/Workspace/FileProvider.hs` (over a `FileRuntime` of `appEnv`, `authorizer`, `lifecycle`, `replayAuthority`, `admitTarget`), `workspaceGitAdapter` and `transferredWorkspaceGitAdapter` in `GitProvider.hs`, `workspaceIntegrationAdapter` in `Integration.hs`, and `workspaceExecAdapter` and `transferredWorkspaceExecAdapter` in `ProcessProvider.hs`. The process adapter is the model for a remote adapter: it builds a `SupervisorRequest` from the dispatch context, calls the supervisor over the socket, polls `RpcObserve` until the view is terminal, and on timeout or any transport failure throws, which keeps the executor's uncertain-effect reservation. `shikigami-workers/src/Shikigami/Workspace/ConfiguredHost.hs` composes these adapters from `WorkspaceSettings` (`shikigami-core/src/Shikigami/Workspace/Settings.hs`: `storageRoot`, `repositories :: [WorkspaceRepository]`, `grants :: [WorkspaceGrant]`, optional `process`) through `configuredWorkspaceHostFor`, whose inner `resolve agent identity` finds the single matching `WorkspaceGrant` and resolves the repository, and whose `select` refuses when a process block is configured but systemd is unavailable.

Receipt recovery today: the supervisor's `publishProcessReceipt` (`shikigami-workers/src/Shikigami/Workspace/Supervisor.hs`) reads the registered process, requires a terminal record, checks the routing's identity, root, operation kind, tool name, scope digest, recovery class and fingerprint against the execution owner's retained operation, reads the actual attempt and checks owner and generation, then by attempt phase either waits for expiry, calls `Execution.markExpiredExecutionAttemptUncertain`, or calls `Execution.recordIndependentToolReceipt` followed by `reconcileExecutionControlAttempt` and `publishExecutionWake`. `publishFileReceipt` (`FileProvider.hs`) and `publishGitReceipt` (`GitProvider.hs`) do the same for file and Git effects. `Shikigami.Workspace.Service.serveSupervisor` races the RPC loop against a `recover` loop that pages the three stores and republishes every quarter second. The transfer provider `workspaceTransferProvider` (`shikigami-workers/src/Shikigami/Workspace/Transfer.hs`) implements `WorkspaceProvider.reconcile` through `TransferStore.inspectTransferTx`, `beginTransferTx`, `pendingWorkspaceOperationsTx` and `retainFenceTx`, and `admitWrite` through `checkSessionWriteTx`; `Store.freezeWorkspaceTx` freezes a binding's control row.

Plan 119 supplies the types this plan consumes: `Shikigami.Machine.Types` (`MachineId`, `MachineName`, `MachineStatus`, `ContainmentProfile`, `ConnectionState`, `OperationClass`, `MachineRefusal`, `MachineCommandId`), `Shikigami.Machine.Protocol` (`CommandEnvelope`, `CommandBinding`, `MachineOperation`, `ReceiptEnvelope`, `MachineOutcome`, and the frames `Welcome`, `Command`, `Receipt`, `Ack`, `Fence`, `FenceApplied`), `Shikigami.Machine.Store` (the registry with `inspectMachineTx`), and `Shikigami.Machine.Gateway` in workers with its per-session `MachineSessionHandler`. This plan does not redefine any of them; where it needs a new store function or frame field, it adds to those modules additively and records the change in the MasterPlan.

Relevant decisions: [ADR 0011](../adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md) (an added field decodes from an omitted key to its default and is omitted on encoding when default); [ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) (only exact registered durable adapters receive mutation authority; copying a descriptor grants nothing); [ADR 0027](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) (binding and snapshot codecs may change before v1 without backfill); [ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md) (fresh exact C13 authorization immediately before the protected effect, which for a remote command means immediately before the command row is written); [ADR 0054](../adr/0054-execution-attempts-own-dispatch-fences-and-generation-wakes.md) and [ADR 0055](../adr/0055-execution-drivers-rotate-around-accepted-work.md) (attempt claims, lease expiry that never proves an effect stopped, and late-receipt reconciliation after replay access is revoked); [ADR 0060](../adr/0060-safe-recovery-spends-new-attempts-and-retains-independent-receipts.md) (independent receipts settle only the original attempt's accounting); [ADR 0063](../adr/0063-handoffs-establish-epochs-only-after-fences-and-versioned-owner-receipts.md) (a successor may not write the same resource before the former writer is fenced); [ADR 0066](../adr/0066-worker-commands-require-retained-scopes-and-fresh-exact-authority.md) (core owns wire types; the server never depends on workers); [ADR 0085](../adr/0085-attempt-fencing-retains-its-owner-token-and-generation-scope.md) (`ClaimOwner` and `StateRevision "execution-attempt"` keep their scopes through every adapter); [ADR 0091](../adr/0091-operation-uncertainty-and-call-ordinals-retain-their-meanings.md) (closed sums rather than booleans for uncertainty); [ADR 0101](../adr/0101-process-intent-decoding-preserves-launch-and-receipt-uncertainty.md) (Either-typed rows; corruption refuses inside the transaction); [ADR 0102](../adr/0102-workspaces-have-allocated-identities-beside-stable-origin-locators.md) (the allocated `WorkspaceId` is distinct from the `WorkspaceRef` locator); [ADR 0109](../adr/0109-runtime-capacity-admission-shares-accepted-attempt-fences.md) (capacity permits and root holds are separate). Value rules follow [the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids), [the vertical-slice guide](mori://shinzui/keiro-runtime-patterns/docs/architecture-vertical-slice-modules) and [the record patterns](mori://shinzui/haskell-jitsurei/docs/core-record-patterns): private newtypes with checked parsers, closed sums, unprefixed strict record fields under `DuplicateRecordFields` and `NoFieldSelectors`, explicit deriving strategies.


## Plan of Work

### Milestone 1: Placement, repository source and selection

Scope: the central vocabulary for where a workspace lives, carried through settings, binding and admission snapshot, and the admission-time selection that refuses an unfit machine. At the end a grant can name a machine, old JSON still decodes, and selection refusals are observable in the worker suite. No command is relayed yet.

Add to `shikigami-core/src/Shikigami/Workspace/Settings.hs` (new types marked):

```haskell
-- new: where a grant's workspaces are provisioned
data Placement = LocalHost | OnMachine !MachineName
  deriving stock (Eq, Show)

-- JSON: "local" or {"machine": "<name>"}; an omitted key decodes to LocalHost
-- and LocalHost is omitted on encoding (ADR 0011).

-- new: replaces the type of WorkspaceRepository.source and WorkspaceBinding.source
data RepositorySource
  = HostPath !(WorkspaceLocator "repository-source")
  | OnMachines !(NonEmpty MachineName)
  deriving stock (Eq)

-- JSON: HostPath encodes as the existing bare string so every retained binding
-- decodes as HostPath; OnMachines encodes as {"machines": [..]}.

data WorkspaceGrant = WorkspaceGrant
  { agent :: !AgentName, principal :: !(DeclarationCoordinate "principal"),
    repository :: !RepositoryId, base :: !(Maybe (WorkspaceCoordinate "git-object")),
    placement :: !Placement }  -- new field
```

`validateWorkspaceSettings` gains the rules that a grant with `OnMachine m` requires its repository's source to be `OnMachines` containing `m`, a grant with `LocalHost` requires `HostPath`, and `OnMachines` names are distinct. `WorkspaceBinding` (`Types.hs`) gains `placement :: Placement` with the same omitted-key default and its `source` changes to `RepositorySource`; add a compatibility test that decodes a retained binding JSON fixture from before this change and asserts `LocalHost` and `HostPath`. `WorkspaceAdmission` (`Instructions.hs`) gains `placement :: Placement` the same way, so the protected snapshot pins where the execution's workspace lives; `Execution/Start.hs` needs no change because it stores the whole admission value.

Selection lives in `configuredWorkspaceHostFor` (`ConfiguredHost.hs`). After `resolve` finds the grant, a new `place :: WorkspaceGrant -> IO (Either Text Placement)` reads the machine row through `Shikigami.Machine.Store.inspectMachineTx` for `OnMachine`, and refuses with a bounded reason when the row is absent, when `status /= Enrolled`, or when the repository's source does not list the machine. The adapter set is then chosen per placement: `LocalHost` keeps today's lists exactly; `OnMachine` installs the remote adapters from Milestone 2, and installs the remote process adapter only when the machine row's `containment` is `SystemdCgroupV2`; an `UnqualifiedPlatform` machine receives edit and Git adapters and no process adapter, and the admission's `filePolicy` for that assignment is the supervised policy only when the process adapter is installed. The refusal strings join the existing `"workspace operator policy refused"` family; no machine name, path or key appears in a log line.

Run `just keiro-gate` and record in this plan that it passes without a new patch: tool dispatch and admission snapshots are not step shapes in any declared workflow body, and the snapshot field is additive under ADR 0011.

### Milestone 2: Command table, relay and settlement

Scope: the durable command row, the remote edit adapter, delivery over the gateway session, settlement through the owning store and the execution owner, acknowledgement, absence, revocation and central restart. At the end the MasterPlan's relay check passes against an in-process fake daemon.

Allocate the migration with `just new-migration machine-commands` and never hard-code its number. It creates two schema-qualified tables. `shikigami.machine_commands` holds `command_id text primary key`, `machine_id`, `workspace_key`, `assignment`, `owner`, `epoch bigint`, `operation_id`, `attempt_id`, `claim_owner`, `generation bigint`, `operation_class`, `envelope jsonb`, `state text`, `refusal jsonb null`, `receipt jsonb null`, `enqueued_at`, `delivered_at null`, `settled_at null`, `acknowledged_at null`, with `unique (operation_id, attempt_id)` so a redelivered dispatch converges on the same row, and a partial index on `(machine_id, enqueued_at) where state = 'queued'`. `shikigami.machine_fences` holds `machine_id`, `workspace_key`, `old_epoch`, `new_epoch`, `transfer_operation_id`, `recorded_at`, `applied_at null`, with `unique (workspace_key, old_epoch)` and a partial index on `machine_id where applied_at is null`. Run `just migration-schema-isolation` after adding it.

Extend `shikigami-core/src/Shikigami/Machine/Store.hs` with the command vocabulary and functions:

```haskell
-- new
data CommandState
  = Queued | Delivered | Settled | Refused !MachineRefusal | Unresolved | Superseded
  deriving stock (Eq, Show)

-- Allowed transitions, enforced as conditional updates on the current state:
--   Queued -> Delivered | Superseded | Refused (MachineRevoked at enqueue retry)
--   Delivered -> Settled | Refused | Unresolved | Superseded
--   Unresolved -> Settled | Refused          (a retained receipt arrives later)
--   Settled | Refused | Superseded are terminal; nothing moves on time alone.

enqueueCommandTx     :: CommandEnvelope -> Transaction (Either MachineError MachineCommandId)
deliverableCommandsTx :: MachineId -> CommandPage -> Transaction (Either MachineError [CommandEnvelope])
markDeliveredTx      :: MachineCommandId -> Transaction (Either MachineError ())
settleCommandTx      :: MachineCommandId -> ReceiptEnvelope -> Transaction (Either MachineError ())
refuseCommandTx      :: MachineCommandId -> MachineRefusal -> Transaction (Either MachineError ())
supersedeCommandsTx  :: WorkspaceRef -> StateRevision "worker-owner" -> Transaction (Either MachineError Int)
recordPendingFenceTx :: MachineId -> WorkspaceRef -> StateRevision "worker-owner" -> StateRevision "worker-owner" -> OperationId -> Transaction (Either MachineError ())
pendingFencesTx      :: MachineId -> Transaction (Either MachineError [PendingFence])
markFenceAppliedTx   :: MachineId -> WorkspaceRef -> StateRevision "worker-owner" -> Transaction (Either MachineError ())
inspectCommandTx     :: MachineCommandId -> Transaction (Either MachineError (Maybe CommandView))
```

`CommandPage` is a positive bounded page size (1 to 64) modelled on `Inspection.Settings.InspectionLimit`. `enqueueCommandTx` is idempotent on `(operationId, attemptId)`: a second call with an identical envelope returns the existing id; a different envelope for the same key refuses. Every reader decodes `envelope`, `receipt` and `refusal` through the protocol decoders and returns `Left` on corruption inside the transaction (ADR 0101), never `Nothing`. `enqueueCommandTx` and the retry path refuse with `MachineRevoked` when the machine row is `Revoked`.

Add `shikigami-core/src/Shikigami/Machine/Relay.hs`, the pure contract between adapter and gateway: `commandFor :: ExecutionSnapshot -> DispatchContext -> WorkspaceBinding -> MachineOperation -> UTCTime -> Either RelayRefusal CommandEnvelope` builds the envelope with its `CommandBinding` from the snapshot's admission (`workspace`, `bindingDigest`, `assignmentId`, `owner`, `epoch`), the binding's placement machine, and the dispatch context (`operationId`, `attemptId`, `owner` as `claimOwner`, `generation`), and the envelope `deadline` as the earlier of the root cutoff and now plus the operation's configured seconds; it refuses when the snapshot's placement is `LocalHost`. `settlementFor :: CommandEnvelope -> MachineOutcome -> Either RelayRefusal Settlement` maps an outcome to which owning store writer and which `Attempt.AttemptResult` apply, so the gateway contains no per-operation branching of its own.

Add `shikigami-workers/src/Shikigami/Workspace/RemoteProvider.hs` with `remoteWorkspaceEditAdapter :: RemoteRuntime -> DurableAdapter` (process and Git follow in Milestone 3). It mirrors `supervisedWorkspaceEditAdapter`'s descriptor, revision and `DurableToolContract`s exactly, so the same tool names and schemas appear to the model and ADR 0025's exact-adapter rule holds. Its prepared tool reserves the effect through the same `Store.reserveWorkspaceEffectTx` the local adapter uses, obtains fresh exact authorization through the same `workspaceFileAction`, calls `Relay.commandFor`, runs `enqueueCommandTx`, then waits up to the configured `RpcWaitSeconds` (1 to 3600, reusing the existing bound) for the row to reach `Settled` or `Refused`, polling `inspectCommandTx` every 250 milliseconds as the process adapter polls `RpcObserve`. `Settled` returns the receipt as the tool output; `Refused` returns a tool failure carrying only the `MachineRefusal` constructor name. On timeout it throws exactly as `ProcessProvider.hs` does so the executor retains the uncertain-effect reservation; the executor's existing finalizer then runs `releaseCapacity` for the permit while root usage stays held.

Extend `Shikigami.Machine.Gateway` (workers). On session open, after authentication, run `pendingFencesTx` and put every pending fence into the `Welcome` frame; the session then accepts only `FenceApplied` frames until each has been answered, and refuses any `Receipt` or heartbeat-only progress until then. Then start the delivery loop: every 250 milliseconds page `deliverableCommandsTx` for the session's machine, send each as a `Command` frame and `markDeliveredTx`. On a `Receipt` frame, run one transaction that records the receipt through the owning store (`Store.recordWorkspaceReceiptTx` for `FileReplaced`, `ProcessStore.recordProcessReceiptTx` for `ProcessObserved` with a settled view, `GitStore.recordGitAppliedTx` or `markGitUnresolvedTx` for Git outcomes, `TransferStore.retainFenceTx` for `Fenced (FencedAndSettled proof)`) and `settleCommandTx`, then call `publishMachineReceipt`, then send `Ack`. `publishMachineReceipt` (new, in `shikigami-workers/src/Shikigami/Machine/Settlement.hs`) is `publishProcessReceipt` generalized over the command's operation class: identical routing, retained-operation, attempt owner and generation, phase and fingerprint checks, then `Execution.recordIndependentToolReceipt`, `reconcileExecutionControlAttempt` and `publishExecutionWake`, or `markExpiredExecutionAttemptUncertain` when the attempt is still `DispatchStarted` and expired. A receipt whose binding does not match the command row is refused and the command is left `Delivered`. A machine's own `Refused` outcome runs `refuseCommandTx` and, for the execution, an `OperationDenied` outcome through the same publication path. Add a `recover` loop in the gateway modelled on `Service.serveSupervisor`'s: it pages `Settled` commands whose `acknowledged_at` is null and republishes them, so a central restart between settlement and wake publication completes once.

Write the relay check as the PostgreSQL case `MachineRelay.settlesOnce`: an in-process fake daemon implements plan 119's `MachineSessionHandler` over a loopback session, answers every `ReplaceFile` command with a `FileReplaced` receipt, and the test asserts one command row, one `recordIndependentToolReceipt` write, one execution outcome, and that a second dispatch of the same `(operationId, attemptId)` returns the same `MachineCommandId` and makes no second call to the fake. Add `MachineRelay.absence` (fake disconnected: row `Queued`, execution `Unresolved`, pending receipt count one, no failed state after the wait expires; reconnect: receipt settles once), `MachineRelay.centralRestart` (kill the publication loop between `settleCommandTx` and `publishExecutionWake`, restart it, assert one wake), and `MachineRelay.revoked` (revoke the machine; enqueue and retry return `MachineRevoked`; the earlier `Unresolved` row is still readable through `inspectCommandTx`).

### Milestone 3: Remote process and Git adapters, and partition transfer

Scope: the remaining remote adapters and the partition contract against the real daemon. This milestone starts only when plan 121 is Complete; the MasterPlan names it as EP-4's completion gate.

Add `remoteWorkspaceExecAdapter` and `remoteWorkspaceGitAdapter` to `RemoteProvider.hs`, mirroring `workspaceExecAdapter` and `workspaceGitAdapter`. The process adapter reserves through `ProcessStore.reserveAdmittedProcessTx` and sends `LaunchProcess`; its receipt is a settled `ProcessView` validated with `Protocol.validView` before `recordProcessReceiptTx`. The Git adapter reserves through `GitStore.reserveAdmittedGitTx` and sends `GitCommit`, `GitStatus` or `GitDiff`; status and diff are repeatable observations and commit is an idempotent mutation only once its receipt test passes, exactly as the local adapter is classified. Add `remoteWorkspaceIntegrationAdapter`, mirroring `workspaceIntegrationAdapter` in `Integration.hs`: it sends `Integrate` with the exact worker commits only when the integration workspace and every worker binding it names carry the same `OnMachine` placement, and refuses with a bounded reason before reserving anything when any binding lives elsewhere, because no artifact transport between machines exists in this delivery and the central host holds only commit identities, never the objects.

Extend `workspaceTransferProvider` (`Transfer.hs`). After `loadBinding`, branch on `binding.placement`. `LocalHost` is unchanged. `OnMachine m` with a `Connected` session sends `FenceOwner intent` as a command and settles the `Fenced` outcome through `retainFenceTx`; ADR 0063 applies unchanged. `OnMachine m` with a `Disconnected` or `NeverConnected` session requires an explicit base: `shikigami workers transfer` (`shikigami-server/src/Shikigami/Server/Command.hs`, the `transfer` parser) gains `--explicit-base <git-object>`, carried on `TransferWorker` as `Maybe (WorkspaceCoordinate "git-object")`, and the coordinator's typed transfer command gains the same optional field; without it the transfer returns `FenceUnresolved` and nothing changes. With it, one locked sequence runs: `Store.freezeWorkspaceTx` on the old binding, `recordPendingFenceTx` for the old machine, `supersedeCommandsTx` for the old workspace and epoch, and allocation of a new `WorkspaceBinding` through the existing reservation path with the successor's placement, the explicit base (which must be an admitted revision of the repository) and the new epoch. The transfer returns `FencedAndSettled` with a `FenceProof` whose `receipt` names the pending fence rather than a machine settlement, and `TransferStore` records that provenance so inspection distinguishes a machine-settled fence from a pending one. Late receipts from the old machine for the old epoch flow through `publishMachineReceipt`, which finds the retained attempt superseded or committed and records them through `recordIndependentToolReceipt` as accounting-only facts; they cannot change the assignment's outcome because the current binding and epoch differ.

Add `--machine-relay` to `tests/workspace/run-apple.sh` and `tests/workspace/run-linux.sh`. One guest hosts PostgreSQL, the gateway, a worker and the real daemon from plan 121 enrolled against the gateway on loopback. The fixture driver (a new module `MachineRelay.hs` in `tests/workspace/prototype/`) admits a placed assignment, dispatches an edit and a validation command, then inserts an `iptables` rule dropping the daemon's traffic to the gateway port while the command runs, asserts the execution is `Unresolved` and the command `Delivered` after the wait, removes the rule, and asserts one settlement. It then repeats with a transfer issued during the drop using `--explicit-base`, asserts the successor's new binding and frozen old binding, restores connectivity, and asserts the old daemon's `FenceApplied` precedes any later frame in the gateway's bounded diagnostics log and that a late receipt from the old epoch settles accounting only. Evidence is copied out like the other modes.


## Concrete Steps

Run from the repository root. Verify dependencies through Mori before changing any bound; this plan selects no new library.

```bash
just new-migration machine-commands
nix develop --no-write-lock-file -c cabal build shikigami-core shikigami-workers shikigami-server
nix develop --no-write-lock-file -c cabal test shikigami-core-test --test-options='-p Placement' --test-show-details=direct
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test --test-options='-p MachineRelay -j1' --test-show-details=direct
nix develop --no-write-lock-file -c cabal test shikigami-workers-test --test-options='-p MachineRelay' --test-show-details=direct
just haskell-conventions
just domain-value-types
just migration-schema-isolation
just keiro-gate
```

Expected shape of the PostgreSQL run after Milestone 2:

```text
MachineRelay
  settlesOnce:            OK
  redeliveryConverges:    OK
  absence:                OK
  centralRestart:         OK
  revoked:                OK
  unqualifiedProfile:     OK
All 6 tests passed
```

For Milestone 3, in a disposable Apple container:

```bash
bash tests/workspace/run-apple.sh --machine-relay
```

Expected: the runner prints named passing cases for `relay-edit`, `relay-sever`, `relay-reconnect`, `partition-transfer`, `pending-fence-first` and `late-receipt-accounting`, with a nonzero case count, and copies `relay-evidence.json` into the private evidence directory it names. A zero-case pass is not evidence. PostgreSQL suites have exhausted fixture connections under default parallelism before (friction entries FRIC-2, FRIC-5, FRIC-17 and FRIC-51 in `docs/friction-log/`); keep `-j1`.


## Validation and Acceptance

Milestone 1 is accepted when a `WorkspaceSettings` JSON with a grant `{"placement": {"machine": "laptop-a"}}` and a repository `{"source": {"machines": ["laptop-a"]}}` validates, the same grant with a `HostPath` repository refuses, a retained binding fixture without `placement` decodes to `LocalHost` with a `HostPath` source and re-encodes byte-identically, and the worker suite shows three bounded refusals at admission: machine row absent or `Revoked`, machine not listed in the repository's `OnMachines`, and a process-bearing assignment on an `UnqualifiedPlatform` machine, while the same assignment without process tools is admitted with edit and Git adapters only.

Milestone 2 is accepted when the six PostgreSQL cases above pass with the fake daemon, and additionally: the command row's envelope never contains file content beyond the `Replacement` the model supplied; `deliverableCommandsTx` never returns more than the configured page (default 16, maximum 64); a receipt larger than 1 MiB of bounded content is refused as malformed and leaves the command `Delivered`; the adapter's wait honors `RpcWaitSeconds` between 1 and 3600 and refuses configuration outside it; and after the wait expires the execution's `pendingReceipts` is one and its phase is `Unresolved`, never `Failed`. Observability: `inspectCommandTx` returns the state, class and timestamps of any command; a `countCommandsByStateTx` reader returns per-machine counts for the five live states; gateway log events are `machine.relay.delivered`, `machine.relay.settled`, `machine.relay.refused` and `machine.relay.fence_applied` with the machine name and the command id only, never the envelope, a path, or a key.

Milestone 3 is accepted when the native `--machine-relay` run passes every named case; when the partition transfer leaves the old binding frozen, the new binding at the explicit base on the successor's placement, exactly one pending fence row, and all old-epoch `Queued` commands `Superseded`; when the gateway's diagnostics show `FenceApplied` before the first `Receipt` of the reconnected session; and when the old epoch's late receipt produces an `recordIndependentToolReceipt` write and no change to the assignment's execution outcome. A transfer without `--explicit-base` against a disconnected machine must return `FenceUnresolved` and change nothing, which the driver asserts first.

Milestone 3 also requires the same-machine integration case: two worker commits in two workspaces placed on one machine integrate through `Integrate` into a third workspace on that machine with exact artifact identities, and an integration naming a worker binding placed elsewhere is refused before any reservation. Proposals for additional scope, not required here: a coordinator-side policy that chooses an explicit base automatically, and artifact transport that would let commits from different machines be integrated anywhere.


## Idempotence and Recovery

Every store write is a conditional transition on the current state, so repeating a step after a crash converges. `enqueueCommandTx` returns the existing id for an identical envelope under the same `(operationId, attemptId)`; a differing envelope refuses rather than overwriting. Delivery marks are idempotent: a command already `Delivered` is not re-sent within a session, and a new session re-delivers only `Queued` rows while the daemon re-sends its own unacknowledged receipts. Settlement runs the store write and `settleCommandTx` in one transaction; `publishMachineReceipt` is safe to repeat because `recordIndependentToolReceipt` converges on identical repeats and refuses conflicting ones (ADR 0060). The `recover` loop republishes any `Settled` command lacking `acknowledged_at`.

Never mutate a retained binding's `source` or `placement`; a transfer allocates a new binding. The migration is additive and applies to an empty command table; it does not touch retained workspace rows. If the partition transfer crashes after `freezeWorkspaceTx` and before the successor allocation commits, the next attempt with the same operation key finds the frozen control row and the pending fence and completes the allocation; the frozen workspace is never unfrozen by retry. A machine that never reconnects leaves its fence pending and its commands `Superseded` or `Unresolved` indefinitely; that is a valid inspectable state, and plan 123 surfaces it.


## Interfaces and Dependencies

Prerequisites declared by the MasterPlan: plan 119 Complete before Milestones 1 and 2 (it supplies `Shikigami.Machine.Types`, `Shikigami.Machine.Protocol`, `Shikigami.Machine.Store`'s registry functions and `Shikigami.Machine.Gateway`'s session); plan 121 Complete before Milestone 3 (the real daemon with local deadlines and retained receipts). Plan 120 is a soft dependency: its admission produces the real `MachineRefusal` values this plan records, but the vocabulary itself is plan 119's.

Owned here: `Shikigami.Machine.Relay` (core), the command and fence tables and their functions in `Shikigami.Machine.Store` (core, additive), `Shikigami.Workspace.RemoteProvider` and `Shikigami.Machine.Settlement` (workers), the `Placement` and `RepositorySource` types and fields in `Shikigami.Workspace.Settings`, `Shikigami.Workspace.Types` and `Shikigami.Workspace.Instructions` (core), the placement branch in `Shikigami.Workspace.ConfiguredHost` and `Shikigami.Workspace.Transfer` (workers), the `--explicit-base` flag on `shikigami workers transfer` (server), and the `--machine-relay` fixture mode. Consumed unchanged: `DurableAdapter`, `DurableToolContract` and `installDurableAdapters` (`Shikigami.Capability.Provider`); `DispatchContext` (`Shikigami.Execution.Runner`); `recordIndependentToolReceipt`, `markExpiredExecutionAttemptUncertain`, `reconcileExecutionControlAttempt`, `publishExecutionWake`, `inspectExecutionAttempt` and `releaseCapacity` (`Shikigami.Execution.Store`); the workspace, process, Git and transfer stores; `TransferIntent`, `FenceProof`, `FenceOutcome` and `WorkspaceProvider` (`Shikigami.WorkerSession.Transfer`). Plan 123 reads `inspectCommandTx`, `countCommandsByStateTx` and `pendingFencesTx` for its operator surface and metrics.

No new library is selected. `websockets`, `hasql`, `aeson` and `time` are already dependencies of both packages. Any bound change must first be verified through `mori registry show` and the authoritative Hackage release.
