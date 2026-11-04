---
id: 121
slug: host-workspace-operations-on-the-machine-with-local-deadlines-and-retained-receipts
title: "Host workspace operations on the machine with local deadlines and retained receipts"
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

# Host workspace operations on the machine with local deadlines and retained receipts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Today every governed workspace operation runs on the host that also runs the central Shikigami runtime. The file, Git and process adapters in `shikigami-workers` read and write the central PostgreSQL stores in the same function that touches the filesystem or starts a systemd unit, so none of them can run on a machine that has no database credential. After this plan, the physical half of each operation (copy a repository at an approved commit, read or replace a contained file, write Git objects and a commit, start and settle a supervised validation command, stop a whole cgroup) is one module, `Shikigami.Workspace.Physical`, that takes explicit inputs and returns receipts and touches no database. The existing supervisor and worker-side adapters call it and keep their PostgreSQL bookkeeping, so the single-host deployment behaves exactly as before. A new module, `Shikigami.Machine.Host`, runs inside the `shikigami-machine` daemon on an enrolled machine, executes only commands the machine's local policy has admitted, enforces each command's absolute deadline and cancellation without any central connection, writes every receipt to the daemon's ledger before sending it, and resends every unacknowledged receipt whenever a new session opens. The daemon also declares what it can safely run: a Linux machine with systemd, writable cgroup v2 and a process policy declares the qualified containment profile; any other machine declares itself unqualified and refuses process commands while still hosting edits and commits.

You can see it working in a disposable Apple container: `bash tests/workspace/run-apple.sh --machine` starts the daemon with a local policy over a fixture repository, drives it through the protocol from an in-process fake gateway, and prints named passing cases for provisioning at the approved commit, read, replace, a contained validation command, a commit with exact tree and commit identities, a daemon killed between process completion and receipt send that reconnects with exactly one receipt and no second launch, a cancelled command whose detached descendant is proven stopped, a command whose deadline passes while disconnected and settles locally, a planted uncommitted file that never appears in the private copy or in any outbound frame, and a policy without process tools that refuses `LaunchProcess` while completing an edit and a commit. This plan is EP-3 of [MasterPlan 21](../masterplans/21-execute-governed-work-through-enrolled-machine-daemons.md). It requires [plan 120](120-enforce-local-machine-policy-over-typed-bound-commands-with-a-retained-ledger.md) (and through it [plan 119](119-enroll-machines-and-hold-outbound-daemon-sessions-with-revocable-identities.md)) to be Complete. The central relay in [plan 122](122-place-assignments-on-machines-and-relay-durable-commands-with-absence-and-partition-fencing.md) is not a prerequisite: this plan proves itself with its own driver.


## Progress

- [ ] Milestone 1: `Shikigami.Workspace.Physical` exists in `shikigami-workers`, the supervisor, file, Git and integration adapters perform their IO through it while keeping their PostgreSQL stores, and the worker suite plus `bash tests/workspace/run-apple.sh --prototype`, `--git` and `--workspace-gates` pass with unchanged case counts.
- [ ] Milestone 2: `Shikigami.Machine.Host` executes admitted `Provision`, `ReadFile`, `ListFiles`, `ReplaceFile`, `GitStatus`, `GitDiff` and `GitCommit` commands in a Linux guest, every receipt is in the ledger before it is sent, the outbound content contract holds against captured frames, and the new `--machine` fixture mode passes its edit and commit cases.
- [ ] Milestone 3: `LaunchProcess`, `ObserveProcess` and `CancelProcess` run under the local absolute deadline with whole-cgroup settlement, a daemon restart between completion and send yields one receipt and no second launch, unacknowledged receipts are resent on reconnection, an unqualified platform refuses process commands, and the planted uncommitted file is absent from the private copy and from every outbound frame.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: `Shikigami.Workspace.Physical` is the single IO seam. The supervisor, the file and Git adapters, the integration adapter and the daemon host all perform filesystem, Git and systemd IO only through it; no second copy of a physical step is written for the daemon.
  Rationale: The daemon may hold no database credential, so the existing adapters cannot run on a machine. Extracting the steps they already perform, instead of rewriting them, keeps one qualified implementation of contained replacement, Git object writing and whole-cgroup settlement, and lets the plan 96 native matrix prove the refactor did not change behavior.
  Date: 2026-11-04

- Decision: A receipt is written to the daemon ledger with fsync and atomic rename before it is sent, and every unacknowledged receipt is resent on each new session until the gateway acknowledges it.
  Rationale: [ADR 0060](../adr/0060-safe-recovery-spends-new-attempts-and-retains-independent-receipts.md) makes a lost acknowledgement unknown until the retained receipt settles it. A receipt that exists only in memory would be lost by a daemon restart and would turn an unknown outcome into a missing one; a receipt sent before it is retained could be acknowledged centrally and then forgotten locally.
  Date: 2026-11-04

- Decision: Provisioning reads only the Git object store at the approved commit named by the local policy. It never reads the source repository's working tree or index, and the working-tree grant in this delivery has the single value `WorkingTreeRefused`.
  Rationale: IR-20 acceptance 9 requires that a person's uncommitted file is neither read nor sent without an explicit grant. Materializing the private copy from objects reachable from the approved commit makes that true by construction rather than by filtering.
  Date: 2026-11-04

- Decision: A platform without a qualified containment profile still hosts provisioning, edits and Git operations but refuses `LaunchProcess`, `ObserveProcess` and `CancelProcess` with `UnqualifiedContainment`. There is no weaker process backend.
  Rationale: The request forbids silent fallback to weaker isolation. Git commits run the trusted Git helper with controlled arguments against a private object store, not repository-controlled code, so they do not need a containment profile.
  Date: 2026-11-04


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a Cabal multi-package Haskell service. `shikigami-core` owns domain types and PostgreSQL stores; `shikigami-workers` owns long-running processes and every adapter that touches a filesystem, a Git repository or systemd, because core is forbidden from linking process adapters (`docs/architecture/packages.md`). Module names express concepts; `Shikigami.Workspace.*` is the governed workspace concept and `Shikigami.Machine.*` (introduced by plan 119) is the enrolled-machine concept. `tools/style/module-ownership.json` lists both roots; `just haskell-conventions` fails on a module outside a listed root.

A *workspace* is one isolated, provider-owned copy of a repository in which one assignment's work happens. Its durable description is `WorkspaceBinding` in `shikigami-core/src/Shikigami/Workspace/Types.hs`: an allocated `WorkspaceId`, the `WorkspaceRequest` (run, assignment, root, principal, owner, epoch), the `WorkspaceRef` locator, the repository identity, the approved base commit, the policy revision, the storage root and the repository source. The *private repository copy* is the on-disk shape of a workspace, created by `Shikigami.Workspace.Allocation` (`workspaceFiles`, `workspaceMetadata`, `workspaceScratch` name its three directories under the storage root) and `Shikigami.Workspace.Provision` (`provisionWorkspaceProfile`, `provisionRoots`, `nativeProvisionBackend`): the mutable files mounted into validation services, a metadata directory holding receipts and the lock file, and a scratch directory, with the Git directory kept outside the mutable files. The *object store* is the `.git/objects` content of a repository: every blob, tree and commit reachable from a commit identity. Reading objects reachable from an approved commit never touches files a person has edited but not committed.

A *containment profile* is the set of systemd unit properties under which a validation command runs: an immutable `RootDirectory`, a private network and PID namespace, an empty capability bounding set, a syscall filter and a bounded `RuntimeMaxSec`. `Shikigami.Workspace.Systemd` (`shikigami-workers/src/Shikigami/Workspace/Systemd.hs`) renders them (`systemdProperties`, `systemdProfileIdentity`, `systemdPropertiesIdentity`), starts the command and its collector (`startProcess`, `startCollector`), observes the collector (`collectorActive`), stops the unit (`stopProcess`) and reads the host boot identity (`systemdBootIdentity`). A *cgroup* is the kernel control group that holds a unit's main process and every descendant; a command is settled only when the whole cgroup is empty, never when its main process has exited ([ADR 0063](../adr/0063-handoffs-establish-epochs-only-after-fences-and-versioned-owner-receipts.md)). The *collector* is the separate `shikigami-workspace-collector` executable (`shikigami-workers/app/workspace-collector/Main.hs`, C source `shikigami-workers/cbits/workspace-collector.c`) that drains the command's output into bounded private files and writes a `CollectorFact` (unit, fingerprint, boot and invocation identities, exit code, termination, byte counts, truncation, descendant settlement, output completeness); `Shikigami.Workspace.Collector` reads it (`readCollectorReceipt`, `readCollectorIdentity`, `collectorFailed`). The absolute deadline is enforced by the `shikigami-workspace-deadline` guard (`shikigami-workers/cbits/workspace-deadline.c`, packaged by `nix/workspace-deadline.nix`), which `Systemd.processArguments` places in front of the command with the record's `deadline` in nanoseconds, together with `RuntimeMaxSec` on the unit. Apple containers step the guest clock every thirty seconds (FRIC-24); the guard expires correctly under that step, and the fixtures keep clock-change protection enabled.

A *receipt* is the retained fact about one operation's physical outcome. The three receipt shapes already exist in core: `FileReceipt` (`shikigami-core/src/Shikigami/Workspace/Provider.hs`: operation, attempt, generation, fingerprint, binding digest, instruction digest, path, target, expected and result content digests, `state :: ReceiptState` of `EditPrepared | EditApplied | EditRefused`), `ProcessReceipt` (`shikigami-core/src/Shikigami/Workspace/Process.hs`: operation, attempt, generation, fingerprint, binding digest, unit, boot and invocation identities, optional exit code, termination, bounded stdout and stderr, descendant settlement, output completeness) and `GitRecord` with its `GitCandidate` (`shikigami-core/src/Shikigami/Workspace/GitTypes.hs`: parent, tree, result commit and changed paths). A prepared file receipt is intent, not proof of publication ([ADR 0060](../adr/0060-safe-recovery-spends-new-attempts-and-retains-independent-receipts.md)); only an applied receipt proves the file was published. An *acknowledgement* is the gateway's `Ack` frame for one `MachineCommandId`, defined by plan 119's `Shikigami.Machine.Protocol`; until it arrives the receipt is the daemon's only evidence that the work happened. The *ledger* is plan 120's `Shikigami.Machine.Ledger` in `shikigami-workers`: fsynced, atomically renamed files under the daemon state directory holding the identity, the applied fences per `WorkspaceRef`, and per `MachineCommandId` the admitted envelope, the receipt and the acknowledgement marker, with `recordReceipt`, `recordAck`, `unacknowledgedReceipts` and `applyFence`.

The current adapters mix physical IO with store transactions. `Shikigami.Workspace.Supervisor` (`superviseProcess`, `reconcileProcess`, `lockedProcess`, `observe`, `stopControlled`, `publishProcessReceipt`) reserves and transitions `ProcessRecord` rows through `Shikigami.Workspace.ProcessStore` and calls the `SupervisorBackend` record (`bootIdentity`, `capture`, `launch`, `collectorActive`, `stop`, instantiated by `systemdSupervisorBackend`) for IO. `Shikigami.Workspace.FileProvider` (`fileAdapter`, `readFileFor`, `replaceFileFor`, `readPrivateReceipt`, `writePrivateReceipt`, `reconcileFileEffect`, `publishFileReceipt`) uses `Shikigami.Workspace.ContainedFile` (`withContainedFile`, `withWorkspaceLock`, `readContainedFile`, `listContainedFiles`, `replaceContainedFileOwned`, `provisionContainedRoot`; C source `shikigami-workers/cbits/workspace-files.c`) and `Shikigami.Workspace.Store` transactions in one function. `Shikigami.Workspace.GitProvider` (`gitAdapterFor`, `runGitToolFor`, `GitBackend` with `nativeGitBackend`) uses `Shikigami.Workspace.GitObjects` (`storeBlob`, `storeTree`, `storeCommit`, `publishCommit`, `verifyPublishedCommit`, `changedPaths`, `objectDiff`, `readHead`, `readCommit`, `readFlatTree`, `readBlob`), `Shikigami.Workspace.GitCapture.captureGitTree`, `Shikigami.Workspace.Git.runWorkspaceGit` and `Shikigami.Workspace.GitStore`. `Shikigami.Workspace.Integration.planIntegration` combines exact worker commits in a separately allocated workspace. `Shikigami.Workspace.Cleanup.cleanupWorkspace` removes a terminal workspace's owned directory. Every one of these keeps its store; this plan moves only the IO beneath them.

Plan 120 supplies the admitted command this plan executes. `AdmittedCommand` is a sealed value ([ADR 0081](../adr/0081-validated-results-use-private-seals-and-public-read-views.md)) minted only by `Shikigami.Machine.Policy.admitCommand`; its read view exposes the `CommandBinding` (machine, `WorkspaceRef`, binding digest, assignment, owner, epoch, `OperationId`, `AttemptId`, `ClaimOwner`, `StateRevision "execution-attempt"`), the `MachineOperation`, the envelope deadline and the local repository and process rule the policy resolved. The daemon's session handler (plan 120's `MachineSessionHandler` from plan 119's `Shikigami.Machine.Client`) calls an executor slot with each admitted command; this plan fills that slot. The closed `MachineOperation` and `MachineOutcome` sums and the `ReceiptEnvelope` are plan 119's; this plan adds no constructor and records any needed change in the MasterPlan's Integration Points first.

Value rules every new type follows: [ADR 0080](../adr/0080-opaque-checked-values-do-not-expose-generic-construction.md) (private constructors and checked parsers, no `Generic` on opaque values), [ADR 0081](../adr/0081-validated-results-use-private-seals-and-public-read-views.md) (sealed results with public read views), [ADR 0085](../adr/0085-attempt-fencing-retains-its-owner-token-and-generation-scope.md) (the `ClaimOwner` token and `StateRevision "execution-attempt"` travel unchanged through every receipt), [ADR 0091](../adr/0091-operation-uncertainty-and-call-ordinals-retain-their-meanings.md) (closed sums instead of booleans), [ADR 0101](../adr/0101-process-intent-decoding-preserves-launch-and-receipt-uncertainty.md) (a corrupt retained record is a refusal, never absence or permission to launch again), [ADR 0102](../adr/0102-workspaces-have-allocated-identities-beside-stable-origin-locators.md) (the workspace identity is allocated centrally; the machine receives it in the binding and allocates nothing). The house record style is unprefixed strict fields under `DuplicateRecordFields` and `NoFieldSelectors` with explicit deriving strategies ([the record patterns](mori://shinzui/haskell-jitsurei/docs/core-record-patterns)); modules follow [the vertical-slice guide](mori://shinzui/keiro-runtime-patterns/docs/architecture-vertical-slice-modules) and [the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids). The containment backend is `mori://systemd/systemd` (project-relative `man/systemd.exec.xml`, `man/systemd.service.xml`, `man/systemd.kill.xml`; artifact-level URIs pending), as plan 96 recorded.

Qualification environment: `AGENTS.md` names Apple containers as the preferred Linux environment. `tests/workspace/run-apple.sh MODE` builds `shikigami-workspace-prototype` through Nix (falling back to the configured remote builder when Cabal stalls at two cores, FRIC-21), starts one disposable `--arch arm64` guest, copies the runtime and explicit fixture sources in, and runs `tests/workspace/run-linux.sh MODE RUNTIME` inside it; `run-linux.sh` refuses any host that is not a marked disposable root guest with systemd and cgroup v2. The fixture executable is `tests/workspace/prototype/Main.hs` with modules `Accepted`, `Adaptive`, `Continuing`, `Durable`, `FixtureIdentity` and `Qualification` registered in `tests/workspace/prototype/workspace-linux-fixture.cabal`; `tests/workspace/prototype-payload.c` is the fixture payload whose descendant calls `setsid` and ignores `SIGTERM`. Worker-suite modules are registered in `shikigami-workers/test/Main.hs` and in the `other-modules` list of the `shikigami-workers-test` stanza in `shikigami-workers/shikigami-workers.cabal`.


## Plan of Work

### Milestone 1: One physical seam under the existing adapters

Create `shikigami-workers/src/Shikigami/Workspace/Physical.hs` (new). It exposes the IO steps the adapters already perform, each over explicit inputs and returning a receipt or a refusal, with no `AppEnv`, pool, `Transaction` or authorizer argument. Its signatures:

```haskell
-- | Materialize the private copy of @repository@ at @base@ under the three
-- allocated directories. Reads only objects reachable from @base@ in the
-- source object store; the source working tree and index are never opened.
provisionPrivateCopy
  :: WorkspaceLocator "repository-source" -> WorkspaceCoordinate "git-object"
  -> FilePath -> IO (Either ProvisionError ProvisionMarker)

readContained :: FilePath -> WorkspaceCoordinate "relative-path" -> ReadBound -> IO (Either FileError (Maybe ByteString))
listContained :: FilePath -> ListBound -> IO (Either FileError [(WorkspaceCoordinate "relative-path", Bool)])

-- | Prepared receipt fsynced in @metadata@ before atomic publication into the
-- files directory; the applied receipt replaces it after publication.
replaceContained :: FilePath -> FilePath -> WorkspaceIdentity -> Replacement -> ReceiptCoordinates -> IO (Either FileError FileReceipt)

gitStatus :: FilePath -> ProcessProfile -> IO (Either WorkspaceError CapturedTree)
gitDiff :: FilePath -> WorkspaceCoordinate "git-object" -> WorkspaceCoordinate "git-object" -> DiffBound -> IO (Either WorkspaceError ByteString)
gitCommit :: FilePath -> GitCommitRequest -> GitAuthor -> UTCTime -> OperationId -> IO (Either WorkspaceError GitCandidate)

launchSupervised :: SystemdProfile -> WorkspaceDirectories -> ProcessRecord -> IO (Either SystemdError ())
observeSupervised :: FilePath -> ProcessRecord -> IO (Either CollectorError (Maybe ProcessReceipt))
cancelSupervised :: ProcessRecord -> IO (Either SystemdError ())

integrateExact :: FilePath -> Request -> [(WorkspaceBinding, GitRecord)] -> IO (Either WorkspaceError IntegrationPlan)
cleanupOwned :: FilePath -> WorkspaceBinding -> IO (Either FileError ())
```

`ReadBound`, `ListBound`, `DiffBound` and `ReceiptCoordinates` are new small checked types in the same module: the bounds are positive integers capped at the existing 1 MiB read ceiling from `readContainedFile`, and the coordinates carry the operation, attempt, generation, fingerprint, binding digest and instruction digest a `FileReceipt` needs. `WorkspaceDirectories` is the triple `Allocation.workspaceFiles`, `workspaceMetadata` and `workspaceScratch` compute. `provisionPrivateCopy` is built from the object-store steps of `Provision.provisionRoots` and `ContainedFile.provisionContainedRoot`, reading through `GitObjects.readCommit`, `readFlatTree` and `readBlob`; it refuses a `base` that is not a commit and refuses a source whose object store is missing. `replaceContained` is the prepared-then-applied sequence now inside `FileProvider.replaceFileFor` (`writePrivateReceipt`, `replaceContainedFileOwned` under `withWorkspaceLock`, then the applied receipt). `gitCommit` is the sequence inside `GitProvider.runGitToolFor` over `GitCapture.captureGitTree`, `GitObjects.storeTree`, `storeCommit` and `publishCommit`. `launchSupervised`, `observeSupervised` and `cancelSupervised` wrap `Systemd.startCollector` and `startProcess`, `Collector.readCollectorReceipt` with `Collector.collectorFailed`, and `Systemd.stopProcess`, and `observeSupervised` returns `Just` a receipt only when the collector fact records `DescendantsSettled`; a receipt with descendants remaining is not settlement.

Then refactor the four consumers to call `Physical` for IO and nothing else for IO: `Supervisor.lockedProcess`, `observe` and `stopControlled` call `launchSupervised`, `observeSupervised` and `cancelSupervised` through `SupervisorBackend` (whose five fields now point at `Physical` functions in `systemdSupervisorBackend`; test backends keep instrumenting the record); `FileProvider.readFileFor` and `replaceFileFor` call `readContained`, `listContained` and `replaceContained`; `GitProvider.runGitToolFor` and `nativeGitBackend` call `gitStatus`, `gitDiff` and `gitCommit`; `Integration.planIntegration` calls `integrateExact`; `Cleanup.cleanupWorkspace` calls `cleanupOwned`; `Provision.provisionWorkspaceProfile` calls `provisionPrivateCopy` for the copy step while keeping `reserveProcessProfileTx` and identity creation. Every store transaction, authorization call, fingerprint check and receipt publication path (`publishProcessReceipt`, `publishFileReceipt`, `reconcileFileEffect`) stays where it is. The milestone is accepted when `cabal test shikigami-workers-test` passes with every existing `Workspace*Spec` module unchanged except for import paths and backend construction, and when `bash tests/workspace/run-apple.sh --prototype`, `--git` and `--workspace-gates` print the same passing case counts as before the refactor (ten, thirteen and twenty-two).

### Milestone 2: The machine host executes admitted edits and Git operations

Create `shikigami-workers/src/Shikigami/Machine/Host.hs` (new):

```haskell
data HostRuntime = HostRuntime
  { policy :: !LocalPolicy
  , machine :: !MachineId
  , stateDirectory :: !(WorkspaceLocator "machine-state")
  , ledger :: !Ledger
  , containment :: !ContainmentProfile
  , clock :: !(IO UTCTime)
  , logger :: !Log.Logger
  }
  deriving stock (Generic)

-- | Execute one admitted command. Total: every branch returns a receipt
-- envelope whose outcome is a 'MachineOutcome', including 'Refused' and
-- 'Unresolved'; it never throws past this boundary.
executeAdmitted :: HostRuntime -> AdmittedCommand -> IO ReceiptEnvelope

-- | Send every ledger receipt without an acknowledgement marker, oldest first.
resendUnacknowledged :: HostRuntime -> (ReceiptEnvelope -> IO ()) -> IO ResendSummary

-- | Declared in the Hello frame. 'SystemdCgroupV2' only when the policy
-- declares a process policy and the host probe passes.
declareContainment :: LocalPolicy -> IO ContainmentProfile

data ResendSummary = ResendSummary {resent :: !Word, retained :: !Word}
  deriving stock (Eq, Show, Generic)
```

`executeAdmitted` derives the workspace directories from the policy's local repository entry and the binding's `WorkspaceRef` under the daemon state directory (the machine never receives a path from the central runtime), takes `ContainedFile.withWorkspaceLock` on the workspace metadata directory for the whole command so a fence or cleanup cannot interleave with a write, consults the ledger first and returns the retained receipt when the `MachineCommandId` already has one (a replayed command converges), then dispatches on the admitted operation: `Provision` calls `provisionPrivateCopy` with the policy's source locator and the binding's base; `ReadFile` and `ListFiles` call `readContained` and `listContained` under the policy's read prefixes; `ReplaceFile` calls `replaceContained` under the write prefixes and the policy's workspace identity; `GitStatus`, `GitDiff` and `GitCommit` call the Git steps; `Integrate` and `Cleanup` call `integrateExact` and `cleanupOwned`. `FenceOwner` and `AdmitWrite` are answered from the ledger's fence view (plan 120's `applyFence` and the epoch comparison) and never touch files. Each outcome is wrapped in a `ReceiptEnvelope` carrying the original `CommandBinding`, written with `Ledger.recordReceipt` (fsync, then atomic rename into `commands/<id>/receipt.json`) and only then returned to the session handler for sending. A physical refusal (`FileError`, `WorkspaceError`, `ProvisionError`) maps to `Refused` with the matching `MachineRefusal`; an IO exception or a missing collector fact maps to `Unresolved`, never to a fabricated success.

The outbound content contract is implemented here and documented in the module header: the only bytes that leave the machine are receipt coordinates (digests, identities, exit status, termination, descendant settlement), bounded read bytes of files under the policy's read prefixes, bounded diff bytes, exact tree and commit identities with changed paths, and the provisioning marker; the total of stdout and stderr prefixes stays within the 1 MiB `validView` ceiling in `shikigami-core/src/Shikigami/Workspace/Protocol.hs`. No absolute path, environment variable, policy source locator or working-tree content is ever placed in a frame. The daemon's log events (`machine.host.admitted`, `machine.host.receipt_retained`, `machine.host.receipt_sent`, `machine.host.resent`, `machine.host.refused`) carry the command identity, operation class and outcome constructor only.

Wire `executeAdmitted` into plan 120's session handler executor slot and `resendUnacknowledged` into the session-open callback in `shikigami-workers/app/machine/Main.hs`, after plan 119's `Welcome` processing and plan 120's fence application. Add `Shikigami.Workspace.Physical` and `Shikigami.Machine.Host` to the library `exposed-modules` in `shikigami-workers/shikigami-workers.cabal`. Add a worker-suite module `shikigami-workers/test/Shikigami/MachineHostSpec.hs` that runs `executeAdmitted` against a temporary fixture repository on the test host for the edit and Git branches (these need no systemd), checks ledger-before-send ordering by interposing a sender that records the ledger state at call time, checks replay convergence, and checks that a frame captured from the sender contains none of a planted marker string placed in the fixture source's working tree.

### Milestone 3: Supervised processes, local deadlines, restart and the unqualified platform

Fill the process branches. `LaunchProcess` builds a `ProcessRecord` from the admitted command's process rule (the policy's `ProcessPolicy.processPolicyCommand` already produces `ProcessCommand`), with `deadline` equal to the envelope deadline, `unit` from `processUnit`, and the binding digest and fingerprint from the admitted binding; it writes the record to the ledger under the command (`commands/<id>/process.json`), then calls `launchSupervised`, which places the deadline guard in front of the command and sets `RuntimeMaxSec` from the remaining seconds, exactly as `Systemd.processArguments` does today. A second `LaunchProcess` for the same command finds the record and does not launch again ([ADR 0101](../adr/0101-process-intent-decoding-preserves-launch-and-receipt-uncertainty.md): a retained launch record is the single launch grant). `ObserveProcess` calls `observeSupervised` and returns `ProcessObserved` with a `ProcessView` whose receipt is present only when the collector fact proves descendant settlement and output completeness; otherwise the view carries `ProcessRunning` or, when the collector has failed, `Unresolved`. `CancelProcess` calls `cancelSupervised`, which stops the unit with `KillMode=control-group` semantics, then observes until the collector reports `DescendantsSettled`, and returns the settled receipt; a cancellation whose cgroup is not yet empty returns a running view, not a settled one. The daemon's own watcher thread observes every launched record on a bounded interval while disconnected, so a command whose deadline passes settles into the ledger with `ProcessTimedOut` without any central frame; the next session resends it.

`declareContainment` returns `SystemdCgroupV2 <identity>` only when the policy declares `SystemdProcessPolicy`, `Systemd.systemdBootIdentity` succeeds, `Systemd.systemdPropertiesIdentity` renders, and the cgroup v2 filesystem is writable (the same checks `tests/workspace/probe-root-apple.sh` performs); otherwise `UnqualifiedPlatform`. Plan 119's `Hello` frame carries the result. When the profile is `UnqualifiedPlatform`, `executeAdmitted` answers every process operation with `Refused UnqualifiedContainment` before touching the ledger's process record, even if plan 120's admission let it through, so the two gates agree. Restart recovery: on start the host reads every `commands/<id>/process.json` without a receipt, observes the collector for each, writes any settled receipt, and resends; a record whose unit and collector evidence are both missing after a reboot stays `Unresolved` and is resent as such, never relaunched.

Extend the fixture. Add `tests/workspace/prototype/Machine.hs` (new) to `workspace-linux-fixture.cabal`'s `other-modules` and the `machine` dispatch arm in `tests/workspace/prototype/Main.hs`. The module runs a fake gateway in-process using plan 119's protocol types over a loopback WebSocket with a self-signed certificate (the daemon pins its fingerprint from the fixture's enrollment file), accepts the daemon's session, and drives the cases listed under Validation and Acceptance by sending `Command` frames and recording every received frame to `machine-frames.jsonl` under the fixture prefix. Add `--machine` to the accepted modes of `tests/workspace/run-apple.sh` and `tests/workspace/run-linux.sh`; in `run-linux.sh` the mode writes a local policy file naming the fixture repository's object store, a `NoProcessTools` variant of the policy, a systemd unit for `shikigami-machine`, and runs the fixture arm, then prints one line per case. Add `shikigami-machine` to `prototypeExecutables` in `nix/qualification-package.nix` so the runtime copied into the guest contains the daemon (plan 119 adds the executable; this plan adds it to the qualification closure if plan 119 has not).


## Concrete Steps

Run from the repository root. Build and run the worker suite focused on the modules this plan touches:

```bash
nix develop --no-write-lock-file -c cabal build shikigami-workers
nix develop --no-write-lock-file -c cabal test shikigami-workers-test --test-options='-p "Workspace|Machine"' --test-show-details=direct
```

Expected after Milestone 1: every `Workspace*Spec` group passes with its previous case count; after Milestone 2, `MachineHostSpec` adds its edit, Git, ordering, replay and outbound-content cases. A successful empty selection is not evidence; require a nonzero count.

Run the house checks after every milestone:

```bash
just haskell-conventions
just domain-value-types
just keiro-gate
```

`just keiro-gate` must report no workflow-body change; this plan edits no `Shikigami.Agent` or `Shikigami.Flow` module and declares no patch. Run the plan 96 native matrix in a disposable Apple container after Milestone 1 and again at the end:

```bash
bash tests/workspace/run-apple.sh --prototype
bash tests/workspace/run-apple.sh --git
bash tests/workspace/run-apple.sh --workspace-gates
```

Expected: the same named cases and the same counts (ten, thirteen, twenty-two) as before this plan; a changed count is a regression, not a new feature. Run the new mode after Milestones 2 and 3:

```bash
bash tests/workspace/run-apple.sh --machine
```

Expected transcript shape from the guest:

```text
machine-provision: PASS (private copy at approved base; working tree unread)
machine-edit: PASS (prepared receipt retained before publication; applied receipt sent once)
machine-commit: PASS (exact tree and commit identities; changed paths)
machine-process: PASS (contained validation; collector fact; descendants settled)
machine-restart: PASS (daemon killed after completion; one receipt; no second launch)
machine-cancel: PASS (detached SIGTERM-ignoring descendant; cgroup empty before settled)
machine-offline-deadline: PASS (deadline passed while disconnected; ProcessTimedOut retained; resent)
machine-working-tree: PASS (planted marker absent from private copy and from machine-frames.jsonl)
machine-unqualified: PASS (NoProcessTools policy; LaunchProcess refused UnqualifiedContainment; edit and commit completed)
Machine host qualification passed (9 cases).
```

The runner prints the private evidence directory on exit; `machine-frames.jsonl` and the ledger copy inside it are the retained evidence for the Validation section. If the Nix build stalls at two cores, use the configured remote builder for the Haskell controller as `AGENTS.md` permits (FRIC-21) and keep the Apple guest for runtime qualification.


## Validation and Acceptance

Milestone 1 is accepted when the worker suite and the three existing native modes pass unchanged. Specifically, `WorkspaceSupervisorSpec`, `WorkspaceFileProviderSpec`, `WorkspaceGitProviderSpec` and `WorkspaceProvisionSpec` pass without case changes, and the native runs show duplicate launch, worker restart, supervisor restart, cancellation, completion recovery, denials, capture loss, authority denial, Git upgrade, Git recovery and Git denial passing exactly as recorded in `docs/operations/workspaces.md`.

Milestone 2 is accepted when, in the guest, the fake gateway sends `Provision`, `ReadFile`, `ReplaceFile`, `GitStatus`, `GitDiff` and `GitCommit` commands bound to the fixture machine and observes: the private copy under the daemon state directory contains exactly the tree of the approved commit; the `ReplaceFile` receipt in the ledger has `state` `EditApplied` and its `result` digest matches the file bytes; the `GitCommit` outcome carries a tree identity equal to `git write-tree` over the private copy and a commit whose parent is the approved base; every receipt file exists in the ledger before the corresponding frame appears in `machine-frames.jsonl` (the fixture records the ledger directory listing when each frame arrives); re-sending the same `Command` frame yields a byte-identical `Receipt` frame and no second file write; and no frame contains the planted marker, an absolute path under the state directory, or any environment value. Bounds: a `ReadFile` request above the read ceiling is refused with `CeilingExceeded`, and the sum of stdout and stderr bytes in any `ProcessObserved` receipt is at most 1 MiB.

Milestone 3 is accepted when the process cases pass. `machine-process`: the fixture payload runs under the policy's systemd profile, the receipt carries the boot and invocation identities, `DescendantsSettled` and `OutputCollected`, and the payload's attempt to read a path outside its root fails. `machine-restart`: the daemon is killed with `SIGKILL` after the collector fact exists but before the receipt frame is sent; after restart and reconnection, `machine-frames.jsonl` contains exactly one `Receipt` for that command and `systemctl list-units` shows one unit for its fingerprint. `machine-cancel`: a `CancelProcess` arrives while the payload's `setsid` descendant ignores `SIGTERM`; the receipt reports `ProcessCancelled` and `DescendantsSettled`, and no process from the unit's cgroup survives. `machine-offline-deadline`: the fake gateway closes the socket after `LaunchProcess` is admitted; the command's deadline passes; the ledger gains a `ProcessTimedOut` receipt with no central frame; on reconnection `resendUnacknowledged` reports one resent receipt. `machine-working-tree`: the fixture writes `UNCOMMITTED-MARKER-<random>` into a file in the source repository's working tree before provisioning; the marker is absent from the private copy and from `machine-frames.jsonl`. `machine-unqualified`: with the `NoProcessTools` policy the `Hello` frame declares the profile `UnqualifiedPlatform`, `LaunchProcess` is `Refused UnqualifiedContainment`, and `ReplaceFile` and `GitCommit` still succeed. Observability: the daemon's stderr log contains the five event names with command identities and outcome constructors and contains neither command arguments nor output bytes; `shikigami-machine status --json` (plan 123) can later read the per-command state because every state is a ledger file.

Required acceptance is the nine named cases plus the unchanged existing matrices. Running the same cases on the optional `amd64` guest is additional evidence only (FRIC-22 records that the translated process payload fails there).


## Idempotence and Recovery

Every fixture mode creates its own disposable guest and removes it on exit; rerunning any mode is safe. `executeAdmitted` is idempotent per `MachineCommandId`: a retained receipt is returned without repeating the effect, a retained launch record is never launched again, and a prepared file receipt without an applied receipt is reconciled by reading the published file's digest, never by writing again. If a milestone fails midway in the guest, the runner's cleanup stops every unit it started and copies the evidence out; no host repository is touched because the daemon's policy names only the fixture object store copied into the guest. The refactor in Milestone 1 is additive first: introduce `Physical` beside the existing code, switch one adapter at a time, run the worker suite after each switch, and remove the duplicated IO only when its caller is gone. A corrupt ledger record refuses daemon start with a named event rather than being skipped; the operator inspects the state directory and either restores the file or removes the command directory after confirming centrally that the command was superseded.


## Interfaces and Dependencies

Prerequisites declared by the MasterPlan: plan 120 Complete, which supplies `Shikigami.Machine.Policy` (`LocalPolicy`, `admitCommand`, `AdmittedCommand` and its read view, `SystemdProcessPolicy | NoProcessTools`, `WorkingTreeRefused`) and `Shikigami.Machine.Ledger` (`recordReceipt`, `recordAck`, `unacknowledgedReceipts`, `applyFence`, `recoverLedger`), and through it plan 119's `Shikigami.Machine.Types` (`MachineId`, `MachineCommandId`, `ContainmentProfile`, `OperationClass`, `MachineRefusal`), `Shikigami.Machine.Protocol` (`CommandEnvelope`, `CommandBinding`, `MachineOperation`, `ReceiptEnvelope`, `MachineOutcome`, the `Hello`, `Receipt` and `Ack` frames), `Shikigami.Machine.Client` (`MachineSessionHandler`), `MachineDaemonSettings` and the `shikigami-machine` executable in `shikigami-workers/app/machine/Main.hs`. Nothing here waits on plan 122; plan 122's milestone 3 waits on this plan.

Modules this plan creates: `shikigami-workers/src/Shikigami/Workspace/Physical.hs`, `shikigami-workers/src/Shikigami/Machine/Host.hs`, `shikigami-workers/test/Shikigami/MachineHostSpec.hs`, `tests/workspace/prototype/Machine.hs`. Modules it edits: `Shikigami.Workspace.Supervisor`, `FileProvider`, `GitProvider`, `Integration`, `Cleanup`, `Provision` (IO moves beneath `Physical`), `shikigami-workers/app/machine/Main.hs` (executor and resend wiring), `shikigami-workers/shikigami-workers.cabal`, `shikigami-workers/test/Main.hs`, `tests/workspace/prototype/Main.hs`, `tests/workspace/prototype/workspace-linux-fixture.cabal`, `tests/workspace/run-apple.sh`, `tests/workspace/run-linux.sh`, `nix/qualification-package.nix`. Core types consumed unchanged: `WorkspaceBinding`, `WorkspaceRef`, `WorkspaceCoordinate`, `WorkspaceLocator`, `Replacement`, `FileReceipt`, `ProcessRecord`, `ProcessReceipt`, `ProcessView`, `GitRecord`, `GitCandidate`, `ProcessPolicy`, `ProcessProfile`, `ClaimOwner`, `StateRevision`. No new Hackage dependency is introduced by this plan; the WebSocket and TLS libraries the fixture's fake gateway uses are those plan 119 selected and verified through Mori. The systemd backend remains the one plan 96 selected; the fixture verifies effective containment rather than assuming a property is supported.
