---
id: 120
slug: enforce-local-machine-policy-over-typed-bound-commands-with-a-retained-ledger
title: "Enforce local machine policy over typed bound commands with a retained ledger"
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

# Enforce local machine policy over typed bound commands with a retained ledger

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

A *machine* is a computer someone owns (a laptop, a build box) that has been enrolled with the central Shikigami runtime. The *daemon* is the one process on that machine, `shikigami-machine`, that connects outbound to the central gateway and executes workspace operations the central runtime asks for. Plan 119 gives the daemon an identity and a session but lets it execute nothing. Plan 121 gives it the physical operations. This plan sits between them and answers the question the request treats as central: when a command arrives over the session, who decides whether the machine will run it?

After this plan the answer is the machine's operator, through a *local policy* file the daemon reads at start. The policy names the repositories the machine hosts and where their Git object stores live, the agent principals the machine accepts, the *operation classes* it allows (provisioning, reading, editing, running a validation process, Git, integration, ownership transfer, cleanup), the process containment it has qualified, and the resource ceilings it imposes. Every incoming command is admitted by one total pure function that checks the command's binding (the machine it names, the workspace, the owner epoch, the operation and attempt identities) and the policy, and refuses with a typed reason or returns a sealed `AdmittedCommand` that is the only thing the executor will ever accept. Nothing in a command can widen the policy: the effective permission is the intersection of what the central runtime asked for and what the local policy allows. The daemon also keeps a *ledger* on disk: the fences it has applied (the owner epochs below which a workspace refuses writes), the commands it has admitted, the receipts it has produced and whether the central runtime has acknowledged them. The ledger survives a daemon restart, refuses to start on a corrupt record, and lets a command that arrives twice converge on its first outcome.

You can see it working without a network. `nix develop --no-write-lock-file -c cabal test shikigami-core-test --test-options='-p MachinePolicy'` loads a policy that allows edits but not processes, admits an edit command bound to this machine, refuses the same command rebound to another machine, refuses a process launch as `OutsidePolicy ProcessClass`, and refuses a write whose epoch is below an applied fence as `StaleEpoch`. `shikigami-machine check-policy --policy <file> --json` validates an operator's policy file offline and prints its revision digest. This plan is EP-2 of [MasterPlan 21](../masterplans/21-execute-governed-work-through-enrolled-machine-daemons.md). It requires plan 119 to be Complete and is itself the prerequisite of plan 121.


## Progress

- [ ] Milestone 1: `Shikigami.Machine.Policy` exists in `shikigami-core` with the `LocalPolicy` record, its strict decoder and validator, `policyRevision`, the fixture policy `shikigami-core/test/fixtures/machine-policy.json`, and the compiler probe; `cabal test shikigami-core-test --test-options='-p MachinePolicy'`, `just haskell-conventions` and `just domain-value-types --match Machine` pass.
- [ ] Milestone 2: `admitCommand` is total over every `MachineOperation` constructor, returns the sealed `AdmittedCommand`, and the enumerated admission cases (wrong machine, unknown repository, class outside policy, unqualified containment, stale epoch, each ceiling, passed deadline, intersection monotonicity) pass in the core suite.
- [ ] Milestone 3: `Shikigami.Machine.Ledger` and `Shikigami.Machine.Handler` exist in `shikigami-workers`, `shikigami-machine check-policy` works offline, and the worker suite proves recovery after a kill between envelope and receipt, refusal to start on a corrupt record, fence application before and after a command, duplicate-command convergence and acknowledgement pruning through plan 119's handler record with no network.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The intersection rule is one total pure function, `admitCommand`, evaluated on the machine over the validated policy, the daemon's own identity, the applied-fence view and the command envelope; the central runtime's grant is an input to be checked, never an authority that bypasses the check.
  Rationale: The request names the machine as the enforcement point and requires a forged or widened command to be refused there. A pure function over explicit inputs is total, property-checkable with no runtime, and cannot be influenced by a compromised central process.
  Date: 2026-11-04

- Decision: The sealed `AdmittedCommand` is the only input the executor (plan 121) accepts; it has a private constructor, no `Generic`, no JSON decoder and a public read view.
  Rationale: [ADR 0081](../adr/0081-validated-results-use-private-seals-and-public-read-views.md) keeps a seal with its validator. If the executor accepted a raw envelope, a code path could run an operation that admission never saw.
  Date: 2026-11-04

- Decision: The ledger is a directory of fsynced, atomically renamed files, not a local database.
  Rationale: No SQLite binding is registered in Mori, and the contained file adapter already proves the fsync-then-rename practice for prepared receipts (`shikigami-workers/cbits/workspace-files.c` and `workspace-collector.c`). The ledger's cardinality is bounded by retention until acknowledgement, so directory scanning on start is bounded.
  Date: 2026-11-04

- Decision: `WorkingTreeRefused` is the only value of `workingTree` in this delivery; the decoder accepts no other spelling.
  Rationale: IR-20 requires that a person's uncommitted files are never read or sent without a separate explicit grant and excludes that grant from the first delivery. Declaring the field now fixes the shape so a later grant is additive rather than a reinterpretation.
  Date: 2026-11-04


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a Cabal multi-package Haskell service. `shikigami-core` owns domain behavior and pure contracts, `shikigami-workers` owns long-running processes and every adapter that touches the filesystem or processes, `shikigami-server` owns operator commands, and `shikigami-migrations` owns SQL. Module names express concepts; `tools/style/module-ownership.json` lists every allowed concept root and `just haskell-conventions` fails on a module outside one. Plan 119 adds the root `Machine`; this plan adds modules under it and changes no policy file. [ADR 0075](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md) is the rule behind that list.

Terms used in this plan. A *workspace* is a private copy of a repository that one assignment edits; it is addressed by `WorkspaceRef {provider, resource}` in `shikigami-core/src/Shikigami/Workspace/Reference.hs`, two opaque coordinates derived from the assignment. An *owner epoch* is a `StateRevision "worker-owner"` that increases each time ownership of a workspace is transferred; a write under an epoch lower than the current one is a write by a former owner. A *fence* is the applied fact that a workspace refuses every command below a given epoch; the daemon learns fences from the central runtime through plan 119's `Fence` frame and must apply them before anything else when it reconnects. An *envelope* is one command as it travels: plan 119's `CommandEnvelope {commandId, binding, operation, deadline, issuedAt}` whose `CommandBinding` carries `machine :: MachineId`, `workspace :: WorkspaceRef`, `bindingDigest`, `assignment :: AssignmentKey`, `owner :: AgentIdentity`, `epoch :: StateRevision "worker-owner"`, `operationId`, `attemptId`, `claimOwner :: ClaimOwner` and `generation :: StateRevision "execution-attempt"`. The `MachineOperation` is a closed sum (`Provision`, `ReadFile`, `ListFiles`, `ReplaceFile`, `LaunchProcess`, `ObserveProcess`, `CancelProcess`, `GitStatus`, `GitDiff`, `GitCommit`, `Integrate`, `FenceOwner`, `AdmitWrite`, `Cleanup`) and `operationClass :: MachineOperation -> OperationClass` maps each to one of the closed `OperationClass` constructors (`ProvisionClass | ReadClass | EditClass | ProcessClass | GitClass | IntegrationClass | OwnershipClass | CleanupClass`). `MachineRefusal` is the closed sum `OutsidePolicy !OperationClass | WrongMachine | StaleEpoch | UnknownRepository | UnqualifiedContainment | CeilingExceeded !CeilingKind | MalformedCommand | MachineRevoked`. All of these are defined by plan 119 in `shikigami-core/src/Shikigami/Machine/Types.hs` and `Protocol.hs`; this plan does not widen them, and the MasterPlan's Integration Points say that widening `MachineRefusal` needs plan 122's agreement because every refusal maps to a central command state.

What exists today that this plan reuses. `shikigami-core/src/Shikigami/Workspace/Settings.hs` is the central operator configuration: `WorkspaceSettings` with `repositories`, `grants` and an optional `process` block, a strict Aeson decoder (`strictOptions` sets `rejectUnknownFields = True`), a validator `validateWorkspaceSettings` that bounds counts and checks paths, `pathAdmitted :: [WorkspaceCoordinate "path-prefix"] -> WorkspaceCoordinate "relative-path" -> Bool`, and `workspacePolicyIdentity`, which renders a versioned digest through `versionedDigest` from `shikigami-core/src/Shikigami/Decision/Contract.hs`. The local policy mirrors that style. `shikigami-core/src/Shikigami/Workspace/ProcessPolicy.hs` owns the reviewed process rules: `ProcessPolicy` (constructed only by `mkProcessPolicy` from `ProcessPolicyInput`, with `rules :: [CommandRule]`, read and write prefixes, and an image), `IdentityRange` (the unprivileged Unix identity range reserved for workspace services), `processPolicyCommand :: ProcessPolicy -> WorkspaceCoordinate "process-profile" -> WorkspaceCoordinate "process-rule" -> Maybe ProcessCommand`, and `processFileAllowed`. `shikigami-core/src/Shikigami/Workspace/Value.hs` owns the scoped coordinate newtypes `WorkspaceCoordinate (scope :: Symbol)` and `WorkspaceLocator (scope :: Symbol)` (both `type role nominal`), and the checked positive newtypes `ProcessSeconds` (1 to 3600) and `ProcessOutputBytes` (1 to 1048576) with `parseProcessSeconds` and `parseProcessOutputBytes`. `shikigami-core/src/Shikigami/Repository.hs` owns `RepositoryId`; `shikigami-core/src/Shikigami/Agent/Name.hs` owns `AgentName`; `shikigami-core/src/Shikigami/Agent/DeclarationValue.hs` owns `DeclarationCoordinate "principal"`. The fsync-then-rename practice the ledger copies is in `shikigami-workers/cbits/workspace-files.c` (the replacement path fsyncs the file, renames it into place, then fsyncs the staging and parent directories) and `shikigami-workers/cbits/workspace-collector.c` (`atomic_fact` writes a temporary name, fsyncs, renames, fsyncs the directory); `shikigami-workers/src/Shikigami/Workspace/FileProvider.hs` writes a prepared receipt before publication and treats the prepared receipt as intent rather than proof.

Decisions that bind this plan. [ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md): the central runtime still obtains fresh exact Kikan-En authorization before it binds and sends a command; local policy is a second, independent gate on the machine and never a replacement. [ADR 0063](../adr/0063-handoffs-establish-epochs-only-after-fences-and-versioned-owner-receipts.md): an owner epoch is checked at the actual effect boundary, and checking once before an uncontrolled process starts is insufficient; on the machine that boundary is `admitCommand` immediately before execution plus the fence view it reads. [ADR 0066](../adr/0066-worker-commands-require-retained-scopes-and-fresh-exact-authority.md): core owns wire types and bounded framing, workers own process-touching adapters, and the server never depends on workers; the policy module is therefore pure core and the ledger is workers. [ADR 0080](../adr/0080-opaque-checked-values-do-not-expose-generic-construction.md) and [ADR 0081](../adr/0081-validated-results-use-private-seals-and-public-read-views.md): opaque values have private constructors and checked parsers, and a validated result is sealed with a public read view. [ADR 0085](../adr/0085-attempt-fencing-retains-its-owner-token-and-generation-scope.md): the `ClaimOwner` token and the `StateRevision "execution-attempt"` generation keep their scopes across every boundary, including the wire; admission compares them, never converts them. [ADR 0091](../adr/0091-operation-uncertainty-and-call-ordinals-retain-their-meanings.md): closed sums, not booleans. [ADR 0101](../adr/0101-process-intent-decoding-preserves-launch-and-receipt-uncertainty.md): a retained record that cannot be decoded is a refusal, never absence; the ledger refuses to start rather than forgetting a receipt. The cross-repository standards are [the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids), [the vertical-slice guide](mori://shinzui/keiro-runtime-patterns/docs/architecture-vertical-slice-modules), [the Settei service standard](mori://shinzui/keiro-runtime-patterns/docs/config-settei-service-standard), [the test layout](mori://shinzui/keiro-runtime-patterns/docs/architecture-test-layout) and [the record patterns](mori://shinzui/haskell-jitsurei/docs/core-record-patterns): unprefixed strict fields under `DuplicateRecordFields` and `NoFieldSelectors`, `OverloadedRecordDot` reads, explicit deriving strategies.

Tests. `shikigami-core/test/Main.hs` registers unit groups (the workspace specs are `WorkspaceCatalogSpec`, `WorkspaceInstructionsSpec`, `WorkspaceProcessPolicySpec`, `WorkspaceAdapterSpec` and `WorkspaceActionProofSpec`, each a `tests :: TestTree`); `shikigami-workers/test/Main.hs` registers the worker groups; both use tasty and tasty-hunit only, and neither package depends on QuickCheck or hedgehog, so property-style claims are enumerated cases. Every new spec module is listed in the suite's `other-modules`. Fixtures live under `shikigami-core/test/fixtures/`. `tests/types/opaque-values.py` (run by `just domain-value-types`) compiles small client modules against the core library to prove that opaque values cannot be constructed generically; a new control is added there with `--match Machine` selecting it.


## Plan of Work

### Milestone 1: The local policy and its revision

Create `shikigami-core/src/Shikigami/Machine/Policy.hs` (new). It imports plan 119's `Shikigami.Machine.Types` and the existing workspace value, process policy and settings modules, and defines the policy an operator writes:

```haskell
data LocalPolicy = LocalPolicy
  { machine :: !MachineName
  , repositories :: ![LocalRepository]
  , principals :: ![AllowedPrincipal]
  , classes :: !(Set OperationClass)
  , containment :: !ContainmentDeclaration
  , ceilings :: !Ceilings
  , workingTree :: !WorkingTreeAccess
  }
  deriving stock (Eq, Generic)

data LocalRepository = LocalRepository
  { identity :: !RepositoryId
  , objectStore :: !(WorkspaceLocator "repository-source")
  , bases :: !AllowedBases
  , readPaths :: ![WorkspaceCoordinate "path-prefix"]
  , writePaths :: ![WorkspaceCoordinate "path-prefix"]
  }
  deriving stock (Eq, Generic)

data AllowedBases = AnyApprovedBase | OnlyBases !(NonEmpty (WorkspaceCoordinate "git-object"))
  deriving stock (Eq, Show)

data AllowedPrincipal = AllowedPrincipal
  { agent :: !AgentName, principal :: !(DeclarationCoordinate "principal") }
  deriving stock (Eq, Generic)

data ContainmentDeclaration = SystemdProcessPolicy !ProcessPolicy !IdentityRange | NoProcessTools
  deriving stock (Eq)

data Ceilings = Ceilings
  { concurrentCommands :: !ConcurrentCommands   -- new, 1..64
  , processSeconds :: !ProcessSeconds           -- existing, 1..3600
  , outputBytes :: !ProcessOutputBytes          -- existing, 1..1048576
  , diskBytes :: !DiskBytes                     -- new, 1 MiB..1 TiB
  }
  deriving stock (Eq, Generic)

data WorkingTreeAccess = WorkingTreeRefused
  deriving stock (Eq, Show)

newtype PolicyRevision = PolicyRevision (WorkspaceCoordinate "machine-policy")
```

`ConcurrentCommands` and `DiskBytes` are new checked newtypes in the style of `ProcessSeconds`: private constructor, `parseConcurrentCommands :: Int -> Either Text ConcurrentCommands`, a number accessor, numeric JSON, no `Generic`, `Num` or `IsString`. `PolicyRevision` is plan 119's `WorkspaceCoordinate "machine-policy"` as the MasterPlan names it; if plan 119 ships it as a type alias rather than a newtype, use the alias and do not add a second type.

The decoder is `Aeson.genericParseJSON strictOptions` followed by `validateLocalPolicy :: LocalPolicy -> Either Text ()` inside `parseJSON`, exactly as `WorkspaceSettings` does, so an unknown key, a duplicate repository identity, an empty `classes` set, an empty `repositories` or `principals` list, more than 64 repositories, more than 32 principals, more than 64 prefixes per repository, a prefix that is absolute or contains `..` or a NUL byte, an `objectStore` locator that is not an absolute normalized path of at most 4096 bytes, a `SystemdProcessPolicy` whose `ProcessPolicy` fails `validProcessPolicy` or whose `IdentityRange` fails `validIdentityRange`, or `ProcessClass` present in `classes` while `containment` is `NoProcessTools`, all fail to parse. `workingTree` decodes only the string `"refused"`. `ContainmentDeclaration` decodes from `{"kind": "systemd", "policy": ..., "identities": ...}` or `{"kind": "none"}` and nothing else. The whole file is read with a 256 KiB bound before decoding.

`policyRevision :: LocalPolicy -> PolicyRevision` is `versionedDigest "shikigami.machine-policy/1"` over a canonical object whose keys are sorted and whose repositories, principals, classes and prefixes are sorted, so two operators who write the same policy in a different order get the same revision. The revision is what the daemon reports in plan 119's `Hello` frame and what `shikigami machines inspect` shows centrally; the object-store path is excluded from the digest input, so a machine can move its repositories on disk without appearing to change policy.

Write the fixture `shikigami-core/test/fixtures/machine-policy.json` (new):

```json
{
  "machine": "laptop-a",
  "repositories": [
    {
      "identity": "mori://fixture/repo",
      "objectStore": "/var/lib/shikigami-machine/repos/fixture-repo.git",
      "bases": "any-approved",
      "readPaths": [""],
      "writePaths": ["src", "cabal.project"]
    }
  ],
  "principals": [{"agent": "upgrade-agent", "principal": "meibo:fixture/upgrade"}],
  "classes": ["provision", "read", "edit", "git"],
  "containment": {"kind": "none"},
  "ceilings": {"concurrentCommands": 2, "processSeconds": 600, "outputBytes": 262144, "diskBytes": 2147483648},
  "workingTree": "refused"
}
```

Add `shikigami-core/test/Shikigami/MachinePolicySpec.hs` (new) with a `tests :: TestTree` group named `MachinePolicy`, register it in `shikigami-core/test/Main.hs` and the suite's `other-modules`, and add a control to `tests/types/opaque-values.py` that attempts `coerce` and `Generic.to` construction of `ConcurrentCommands`, `DiskBytes` and (from Milestone 2) `AdmittedCommand` and expects compilation failure.

### Milestone 2: Admission as a total pure function

In the same module add the fence view and the admission function:

```haskell
-- | Applied fences: the highest epoch fenced per workspace. A command whose
-- epoch is not strictly greater is a former owner's command.
newtype FenceView = FenceView (Map WorkspaceRef (StateRevision "worker-owner"))

admitCommand
  :: LocalPolicy -> MachineId -> FenceView -> UTCTime -> CommandEnvelope
  -> Either MachineRefusal AdmittedCommand

-- Sealed: no Generic, no FromJSON, constructor not exported.
data AdmittedCommand = AdmittedCommand
  { envelope :: !CommandEnvelope
  , repository :: !LocalRepository
  , admittedClass :: !OperationClass
  , processRule :: !(Maybe (ProcessCommand, ProcessPolicy, IdentityRange))
  , admittedAt :: !UTCTime
  }

data AdmittedView = AdmittedView
  { commandId :: !MachineCommandId, workspace :: !WorkspaceRef
  , operationClass :: !OperationClass, epoch :: !(StateRevision "worker-owner")
  , deadline :: !UTCTime, repository :: !RepositoryId }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

admittedView :: AdmittedCommand -> AdmittedView
```

The refusal precedence is fixed and documented in the module header so plan 122 can rely on it: first `WrongMachine` when `envelope.binding.machine` is not the daemon's `MachineId`; then `MalformedCommand` when the envelope's deadline is not after `now`, when `issuedAt` is after the deadline, when the generation is not above `initialRevision`, or when any coordinate fails the bounded-text checks that `Shikigami.Workspace.Process.bounded` and `digestText` already express; then `UnknownRepository` when no `LocalRepository` matches `envelope.binding.repository`, or when the matching entry's `bases` is `OnlyBases` and does not contain `envelope.binding.base` (plan 119's `CommandBinding` carries `repository :: RepositoryId` and `base :: WorkspaceCoordinate "git-object"` for exactly this check, so every operation, not only `Provision`, is checked against the hosted repositories); then `OutsidePolicy class` when `operationClass envelope.operation` is not in `policy.classes`, or when the operation is a `ReadFile` or `ListFiles` whose path is not admitted by `readPaths`, or a `ReplaceFile` whose path is not admitted by `writePaths` (both through `pathAdmitted`), or a `Provision` whose base is outside `OnlyBases`; then `UnqualifiedContainment` when the operation is `LaunchProcess`, `ObserveProcess` or `CancelProcess` and `containment` is `NoProcessTools`, or when `LaunchProcess` names a rule that `processPolicyCommand` does not resolve; then `StaleEpoch` when the fence view holds an epoch for the workspace and the envelope's epoch is not strictly greater; then `CeilingExceeded kind` when the launch's requested seconds exceed `processSeconds`, its output bound exceeds `outputBytes`, or the caller-supplied occupancy count (the handler passes the number of commands currently admitted but unsettled, so the function stays pure) is already at `concurrentCommands`. `MachineRevoked` is never returned by this function; revocation is a session fact plan 119 handles at hello. The function is total: every `MachineOperation` constructor has a branch, there is no wildcard pattern, and `-Wincomplete-patterns` is already an error in this repository.

Monotonicity is the property the request cares about and the tests enumerate it: for a fixed envelope, removing a class from `classes`, removing a repository, narrowing `writePaths`, switching `containment` to `NoProcessTools` or lowering a ceiling never turns a refusal into an admission; and no field of the envelope can turn `OutsidePolicy` into an admission, including a `CommandBinding` that names a different principal or a wider claimed grant, because the function never reads any central grant at all.

### Milestone 3: The ledger and the handler

Create `shikigami-workers/src/Shikigami/Machine/Ledger.hs` (new). The ledger is a directory, `MachineDaemonSettings.stateDirectory` from plan 119, mode `0700`, with this layout:

```text
<stateDirectory>/
  identity/            owned by plan 119: private key, machine id, gateway pin
  policy-revision      the revision the daemon last loaded (for status)
  fences/<fence-key>   JSON {workspace, epoch, appliedAt}; fence-key is
                       versionedDigest "shikigami.machine-fence-key/1" (toJSON workspace)
  commands/<commandId>/
    envelope.json      the admitted envelope and admittedView
    receipt.json       the ReceiptEnvelope once produced
    ack                empty marker once the central runtime acknowledged
```

```haskell
data Ledger  -- opaque handle: root path, in-memory FenceView, pending map

openLedger :: FilePath -> IO (Either LedgerError Ledger)       -- creates layout, takes a flock
recoverLedger :: FilePath -> IO (Either LedgerError LedgerState) -- scans, decodes, refuses corruption
recordAdmitted :: Ledger -> AdmittedCommand -> IO (Either LedgerError Convergence)
recordReceipt :: Ledger -> ReceiptEnvelope -> IO (Either LedgerError ())
recordAck :: Ledger -> MachineCommandId -> IO (Either LedgerError ())
applyFence :: Ledger -> WorkspaceRef -> StateRevision "worker-owner" -> IO (Either LedgerError ())
fenceView :: Ledger -> IO FenceView
unacknowledgedReceipts :: Ledger -> IO [ReceiptEnvelope]
occupancy :: Ledger -> IO Int                                    -- admitted, no receipt yet

data Convergence = FreshlyAdmitted | AlreadyPending | AlreadySettled !ReceiptEnvelope
data LedgerError = LedgerCorrupt !FilePath | LedgerUnavailable | LedgerBusy | LedgerFull
```

Every write creates `<name>.tmp-<nonce>` in the target directory, writes, `fsync`s the file, renames over the final name, then `fsync`s the directory, mirroring `atomic_fact` in `shikigami-workers/cbits/workspace-collector.c`; use `System.Posix` from the `unix` package the workers library already depends on. `applyFence` only ever raises the retained epoch; a lower epoch is a no-op that returns `Right ()`. `recordAck` writes the marker and then removes the command directory in a second step, so a crash between the two leaves an acknowledged command that the next recovery prunes rather than resends. `recoverLedger` decodes every `fences/*` and `commands/*/envelope.json` and `receipt.json`; a file that fails to decode, a command directory without an envelope, or a receipt whose `commandId` does not match its directory is `LedgerCorrupt path`, and the daemon exits with that path in its log and nothing else. Bounds: at most 4096 command directories (`LedgerFull` refuses new admissions, which the handler reports as `CeilingExceeded`), at most 65536 fence files, each JSON file at most 1 MiB.

Create `shikigami-workers/src/Shikigami/Machine/Handler.hs` (new). It builds plan 119's `MachineSessionHandler` record:

```haskell
data Executor = Executor { execute :: AdmittedCommand -> IO () }  -- plan 121 supplies the real one

machineHandler :: LocalPolicy -> MachineId -> Ledger -> Executor -> (ReceiptEnvelope -> IO ()) -> MachineSessionHandler
```

`onCommand envelope` reads `fenceView` and `occupancy`, calls `admitCommand` with the current time, and on `Left refusal` immediately sends a `ReceiptEnvelope` whose outcome is `Refused refusal` without touching the ledger (a refusal is not a retained effect). On `Right admitted` it calls `recordAdmitted`; `FreshlyAdmitted` hands the sealed value to the executor; `AlreadyPending` sends nothing (the earlier receipt will arrive); `AlreadySettled receipt` resends that receipt. `onFence workspace epoch` calls `applyFence` and replies `FenceApplied`; the handler applies fences strictly before processing any command frame from the same session, which plan 119's client guarantees by delivering the `Welcome` fence list first. `onAck commandId` calls `recordAck`. On every new session the handler sends `unacknowledgedReceipts` before accepting new commands. The stub executor this plan wires in `shikigami-workers/app/machine/Main.hs` records nothing and produces no receipt, so an admitted command stays `AlreadyPending` until plan 121 replaces the stub; the plan 119 daemon therefore still executes nothing after this plan.

Add the subcommand `shikigami-machine check-policy --policy <path> [--json]` to the daemon's parser in `shikigami-workers/src/Shikigami/Workers/Command.hs` beside plan 119's `enroll` and `run`. It reads and decodes the file, prints `{"machine": ..., "revision": ..., "classes": [...], "repositories": <count>}` or the decoder's refusal, exits nonzero on refusal, and never opens a socket. Logs from the handler carry only `machine.command.refused` with `refusal.kind` and `operation.class`, `machine.command.admitted` with `operation.class`, `machine.fence.applied` with the epoch number, and `machine.ledger.corrupt` with the path; never a policy path, key bytes, command payload or file content.


## Concrete Steps

Run from the repository root. Plan 119 must be Complete; confirm its modules exist before starting:

```bash
ls shikigami-core/src/Shikigami/Machine/Types.hs shikigami-core/src/Shikigami/Machine/Protocol.hs
grep -n "MachineSessionHandler" shikigami-workers/src/Shikigami/Machine/Client.hs
```

Milestone 1 and 2 loop:

```bash
nix develop --no-write-lock-file -c cabal build shikigami-core
nix develop --no-write-lock-file -c cabal test shikigami-core-test --test-options='-p MachinePolicy' --test-show-details=direct
just haskell-conventions
just domain-value-types --match Machine
```

Expected: the `MachinePolicy` group reports a nonzero case count, every case passes, and the conventions and value-type checks exit zero. A successful empty selection is not evidence.

Milestone 3 loop:

```bash
nix develop --no-write-lock-file -c cabal build shikigami-workers
nix develop --no-write-lock-file -c cabal test shikigami-workers-test --test-options='-p MachineLedger' --test-show-details=direct
nix develop --no-write-lock-file -c cabal run shikigami-machine -- check-policy --policy shikigami-core/test/fixtures/machine-policy.json --json
```

Expected for the last command:

```text
{"machine":"laptop-a","revision":"<64 hex characters>","classes":["edit","git","provision","read"],"repositories":1}
```

Final candidate:

```bash
nix develop --no-write-lock-file -c cabal test all --test-options=-j2 --test-show-details=direct </dev/null
just keiro-gate
git diff --check
```

This plan changes no declared workflow body, so `just keiro-gate` is a confirmation, not a patch gate. Every implementation commit carries `MasterPlan: docs/masterplans/21-execute-governed-work-through-enrolled-machine-daemons.md`, `ExecPlan: docs/plans/120-enforce-local-machine-policy-over-typed-bound-commands-with-a-retained-ledger.md` and `Intention: intention_01m6m0b6zxebfv3yatcy7fvbgk`.


## Validation and Acceptance

Policy decoding. The fixture decodes and its revision is stable across two decodes and across a reordering of `classes` and `writePaths`. Each of these fails to decode with a bounded reason: an unknown top-level or nested key; two repositories with the same identity; an empty `classes`; `"classes": ["process"]` with `"containment": {"kind": "none"}`; a `writePaths` entry of `/etc`, `../x` or a string containing a NUL byte; an `objectStore` of `relative/path` or `/`; a file over 256 KiB; and `"workingTree": "allowed"`. A policy with `"kind": "systemd"` requires a `ProcessPolicy` that `validProcessPolicy` accepts.

Admission. Build one envelope per `MachineOperation` constructor bound to the fixture machine and repository at epoch 3 with a deadline one hour ahead. Against the fixture policy, `Provision`, `ReadFile` under any path, `ReplaceFile` under `src/`, `GitStatus`, `GitDiff` and `GitCommit` are admitted and `admittedView` reports the right class; `ReplaceFile` under `docs/` is `OutsidePolicy EditClass`; `LaunchProcess`, `ObserveProcess` and `CancelProcess` are `OutsidePolicy ProcessClass`; `Integrate`, `FenceOwner`, `AdmitWrite` and `Cleanup` are `OutsidePolicy` of their classes until the test adds those classes, after which they are admitted. Rebinding the admitted edit to another `MachineId` is `WrongMachine` even when every other field is valid. Naming a repository the policy does not host is `UnknownRepository`. With a policy whose containment is systemd and whose classes include `process`, `LaunchProcess` with a rule the policy names is admitted and with an unnamed rule is `UnqualifiedContainment`. With a fence view holding epoch 3 for the workspace, the epoch-3 edit is `StaleEpoch` and the same edit at epoch 4 is admitted. Requesting 601 seconds against `processSeconds` 600 is `CeilingExceeded`, as is an occupancy equal to `concurrentCommands`. A deadline equal to or before `now` is `MalformedCommand`. For every admitted case, removing the operation's class from the policy, removing the repository, narrowing `writePaths` to `[]`, or lowering the relevant ceiling yields a refusal, and no admitted case exists whose envelope differs from a refused one only in the binding's `owner` or `claimOwner` fields. The compiler probe shows `AdmittedCommand` cannot be built by `coerce`, record syntax or `Generic`.

Ledger and handler. In a temporary directory: `openLedger`, admit and record a command, kill the process (simulated by closing the handle without `recordReceipt`), `recoverLedger` reports it pending and `unacknowledgedReceipts` is empty; record a receipt, recover, and the receipt is listed for resend; `recordAck`, recover, and the command is gone. Truncating `receipt.json` to half its bytes makes `recoverLedger` return `LedgerCorrupt` naming that path and the daemon's `run` exits nonzero with log event `machine.ledger.corrupt`. `applyFence` at epoch 5 then 4 leaves 5; an envelope at epoch 5 is `StaleEpoch` and at 6 admitted. Sending the same `CommandEnvelope` twice through `onCommand` calls the executor once; sending it after a receipt exists resends that receipt and calls the executor zero times. A `Fence` frame delivered before a command frame makes that command `StaleEpoch`; delivered after admission it does not retract the admission (the running effect belongs to plan 121's deadline), and the next command at the old epoch is refused. All of this runs through plan 119's `MachineSessionHandler` record with in-memory channels and no socket.

Bounds and observability. A 4097th pending command is refused as `CeilingExceeded`; a 1 MiB plus one byte `envelope.json` is `LedgerCorrupt`. Refusals are typed values, so the handler's test counts them by kind, and the log assertions check that no log line contains the fixture's object-store path, the policy file path, the identity key bytes or the replacement content.


## Idempotence and Recovery

Policy loading is a pure read; reloading the same file yields the same revision. `recordAdmitted` for a known `commandId` returns the retained state and writes nothing. `applyFence` never lowers an epoch. `recordAck` is safe to repeat; a repeated acknowledgement for a pruned command returns `Right ()`. Every ledger write is a temporary file renamed into place, so a crash leaves either the old or the new file, never a partial one; a leftover `*.tmp-*` file is removed on recovery without being decoded. A corrupt record stops the daemon with the offending path; the operator inspects and removes or restores that file by hand, and the daemon never deletes a record it cannot read. Tests use temporary directories only and never touch an operator's state directory.


## Interfaces and Dependencies

New in `shikigami-core`: `Shikigami.Machine.Policy` exporting `LocalPolicy (..)`, `LocalRepository (..)`, `AllowedBases (..)`, `AllowedPrincipal (..)`, `ContainmentDeclaration (..)`, `Ceilings (..)`, `WorkingTreeAccess (..)`, `ConcurrentCommands`, `parseConcurrentCommands`, `concurrentCommandsNumber`, `DiskBytes`, `parseDiskBytes`, `diskBytesNumber`, `PolicyRevision`, `policyRevision`, `validateLocalPolicy`, `FenceView (..)`, `admitCommand`, `AdmittedCommand` (abstract), `AdmittedView (..)`, `admittedView`, `admittedEnvelope :: AdmittedCommand -> CommandEnvelope` and `admittedProcess :: AdmittedCommand -> Maybe (ProcessCommand, ProcessPolicy, IdentityRange)` for plan 121's executor. New in `shikigami-workers`: `Shikigami.Machine.Ledger` and `Shikigami.Machine.Handler` as sketched, and the `check-policy` subcommand. Both cabal files list the new modules and spec modules; no new dependency is added (aeson, containers, text, time, unix and filepath are already present).

Consumed from plan 119 (`docs/plans/119-enroll-machines-and-hold-outbound-daemon-sessions-with-revocable-identities.md`, which must be Complete): `Shikigami.Machine.Types` (`MachineId`, `MachineName`, `MachineCommandId`, `OperationClass`, `MachineRefusal`, `CeilingKind`, `PolicyRevision`), `Shikigami.Machine.Protocol` (`CommandEnvelope`, `CommandBinding`, `MachineOperation`, `operationClass`, `ReceiptEnvelope`, `MachineOutcome` including `Refused`, the `Fence` and `FenceApplied` frames), `Shikigami.Machine.Client.MachineSessionHandler` with its `onCommand`, `onFence` and `onAck` callbacks and its guarantee that `Welcome` fences are delivered before commands, `MachineDaemonSettings.stateDirectory` and `policyPath`, and the `shikigami-machine` role's parser. Consumed from the existing tree: `Shikigami.Workspace.Settings` (`strictOptions`, `pathAdmitted`), `Shikigami.Workspace.ProcessPolicy` (`ProcessPolicy`, `IdentityRange`, `validProcessPolicy`, `validIdentityRange`, `processPolicyCommand`), `Shikigami.Workspace.Value` (`WorkspaceCoordinate`, `WorkspaceLocator`, `ProcessSeconds`, `ProcessOutputBytes`), `Shikigami.Workspace.Reference.WorkspaceRef`, `Shikigami.Workspace.Process` (`bounded`, `digestText`), `Shikigami.Decision.Contract.versionedDigest`, `Shikigami.StateRevision` and `Shikigami.Execution.Claim.ClaimOwner`.

Supplied to later plans: plan 121 consumes `AdmittedCommand`, `admittedEnvelope`, `admittedProcess`, the `Executor` record, `Ledger` (`recordReceipt`, `unacknowledgedReceipts`) and the handler's resend behavior; plan 122 relies on the documented refusal precedence and on the fact that `MachineRevoked` never originates here; plan 123 reads `policy-revision` and the ledger's pending and unacknowledged counts for `shikigami-machine status`. None of these may be widened without recording the change in the MasterPlan's Integration Points.
