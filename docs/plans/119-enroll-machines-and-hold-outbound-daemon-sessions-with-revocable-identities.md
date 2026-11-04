---
id: 119
slug: enroll-machines-and-hold-outbound-daemon-sessions-with-revocable-identities
title: "Enroll machines and hold outbound daemon sessions with revocable identities"
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

# Enroll machines and hold outbound daemon sessions with revocable identities

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Today every workspace operation Shikigami performs runs on the host that runs the central runtime. The process supervisor `shikigami-workspace-supervisor` listens on a Unix socket, opens the central PostgreSQL database and is reached only by queue workers on the same host. Nothing lets a developer laptop, a build box or a device host join a deployment, and nothing names such a machine, trusts it, or stops trusting it.

After this plan a central operator can run `shikigami machines offer --name laptop-a --json` and receive a one-time enrollment code; the owner of a machine can run `shikigami-machine enroll` with that code, which generates a key pair that never leaves the machine and connects outbound to a new central role, `shikigami-machine-gateway`; the central operator can compare the key fingerprint both sides print and run `shikigami machines approve laptop-a --fingerprint <hex>`; and from then on `shikigami-machine run` holds an authenticated, heartbeating session to the gateway and reconnects with bounded backoff whenever the network drops. `shikigami machines revoke laptop-a` is terminal: the gateway closes the live session, and every later connection attempt by that key is refused. The daemon in this plan executes no workspace operation yet. It establishes who a machine is, proves it per session, and gives later plans (local policy in plan 120, physical hosting in plan 121, the central relay in plan 122) one vocabulary of frames, commands, receipts and refusals to agree on.

You can see it working in the workers suite: `cabal test shikigami-workers-test --test-options='-p MachineSession'` enrolls a daemon against a gateway in the same test process over loopback TLS with a generated certificate, shows the `Welcome` frame carrying an empty fence list, two heartbeats, a revocation that closes the socket, and a refused reconnection, while the registry rows move through `Offered`, `AwaitingApproval`, `Enrolled` and `Revoked`. This plan is EP-1 of [MasterPlan 21](../masterplans/21-execute-governed-work-through-enrolled-machine-daemons.md). It has no prerequisite plan.


## Progress

- [ ] Milestone 1: `Shikigami.Machine.Types` and `Shikigami.Machine.Protocol` exist in `shikigami-core` with checked identities, closed sums, strict JSON codecs and protected `Show` instances; `Machine` is a listed domain root; `just haskell-conventions`, `just domain-value-types` and `cabal test shikigami-core-test --test-options='-p Machine'` pass with the new value, codec and compiler-probe cases.
- [ ] Milestone 2: The machine registry migration and `Shikigami.Machine.Store` exist; the PostgreSQL suite proves the offer, claim, approve and revoke lifecycle, convergent duplicate claims, expired-code refusal, concurrent claims, corrupt-row refusal inside the transaction and that `Revoked` never reopens.
- [ ] Milestone 3: `shikigami-machine-gateway` and `shikigami-machine` are real roles with settings, `shikigami machines offer|approve|revoke` and `shikigami-machine enroll|run` work, and the session check passes in the workers suite: enroll, authenticate over loopback TLS, `Welcome` with an empty fence list, heartbeat, revoke, refused reconnection, registry showing each state, plus refusal of a wrong-key proof, a replayed proof and a daemon started with a database URL present.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The daemon is a physical executor with no central credential. It never receives a database connection string, a Kikan-En client, a model provider credential or a queue setting, and `MachineDaemonRole` refuses to start when any of those keys is present.
  Rationale: IR-20 requires that a compromised central runtime reach no further than a machine's local grant and that the daemon hold no provider credentials. The existing supervisor opens the central database; copying it to a remote machine would hand every machine a central credential.
  Date: 2026-11-04

- Decision: Machines authenticate per session by Ed25519 challenge-response over a TLS connection whose gateway certificate is pinned at enrollment, not by mutual TLS with client certificates.
  Rationale: The private key still never leaves the machine, each session is bound to a fresh 32-byte server nonce so a captured proof cannot be replayed, and revocation is a registry check at hello. Mori registers `crypton` for Ed25519 and SHA-256 but no X.509 client-certificate helper, so challenge-response avoids a certificate authority and client-certificate plumbing entirely.
  Date: 2026-11-04

- Decision: The gateway is a WebSocket endpoint served through Warp with `warp-tls` and `wai-websockets`, one binary WebSocket message per JSON frame.
  Rationale: `warp`, `websockets` and `wai-websockets` are already dependencies of this repository, the gateway inherits the health, proxy and load-balancer behavior the HTTP server already has, and a framed raw TCP stream would need its own length-prefix protocol and TLS plumbing for no gain.
  Date: 2026-11-04

- Decision: The daemon binary `shikigami-machine` lives in `shikigami-workers` for the first delivery, and a dedicated lightweight package is a deliberate exclusion.
  Rationale: The physical workspace modules it will host (plan 121) live in `shikigami-workers`, `nix/qualification-package.nix` asserts seven application packages, and [ADR 0003](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md) makes a package split a recorded decision rather than a drift. The weight cost (a laptop daemon linking queue and Kafka libraries it never configures) is recorded so a later plan can take the split deliberately.
  Date: 2026-11-04


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a Cabal multi-package Haskell service. `shikigami-core` owns domain behavior and PostgreSQL store adapters, `shikigami-workers` owns long-running processes, `shikigami-server` owns the HTTP server and the administrative `shikigami` command, and `shikigami-migrations` owns append-only SQL migrations plus the `test-support` sublibrary that gives every test an isolated migrated database. Module names express concepts (`Shikigami.Workspace.*`, `Shikigami.Execution.*`); packages express runtime roles. `docs/architecture/packages.md` describes this, and `tools/style/module-ownership.json` lists every concept root and composition module; `just haskell-conventions` fails on a module outside a listed root. This plan adds the root `Machine` with a rationale comment, as [ADR 0075](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md) requires.

A *machine* is a computer that an operator enrolls so the central runtime can run workspace operations on it. A *daemon* is the long-running process on that machine, `shikigami-machine`. The *gateway* is the central process, `shikigami-machine-gateway`, that accepts the daemon's outbound connection. An *enrollment offer* is a central row holding a one-time code's hash and an expiry; *claiming* it is what the daemon does when it first connects with that code and its public key; *approving* is the central operator confirming the key fingerprint; *revoking* is the terminal status that refuses every later session. A *session* is one authenticated connection, identified by its own allocated id. A *frame* is one JSON object sent as one binary WebSocket message. A *fence* is a durable mark saying that writes under an owner epoch at or below a given value are refused for a workspace; this plan carries fences in the protocol but applies none (plan 120 does).

The existing single-host process owner is the model for the shapes here. `shikigami-core/src/Shikigami/Workspace/Protocol.hs` defines `RpcRequest` and `RpcReply` with `format` and `action` fields, a `keys` helper that refuses any object with unexpected keys, and `Show` instances that render `<protected>`. `shikigami-core/src/Shikigami/Workspace/RpcClient.hs` bounds request frames at 4096 bytes and replies at 8192 bytes and validates every reply against its request. `shikigami-workers/src/Shikigami/Workspace/Daemon.hs` (`runWorkspaceSupervisor`) shows how a role adopts settings, opens stores and refuses to start on misconfiguration; `shikigami-workers/src/Shikigami/Workers/Command.hs` (`workspaceSupervisorRoleInfo`, `workerRoles`) shows how an executable is declared through `Shikigami.App.Role.RoleInfo` and `runRole`; `shikigami-workers/app/workspace-supervisor/Main.hs` is six lines. `shikigami-core/src/Shikigami/App/Config.hs` declares every setting once (`workspacesKey`, `workspaceSupervisorKey`, `secretSetting`, `stableKey`), binds environment names (`SHIKIGAMI_WORKSPACES`), and owns the closed `Role` sum with `roleBinary`, `defaultHealthPort`, `roleRequiredKeys` and `missingRequirements`; `SecretText` with `revealSecretText` is the opaque secret type. `shikigami-core/src/Shikigami/Workspace/Value.hs` shows the checked-scalar pattern (`RpcPeerUserId`, `parseRpcPeerUserId`, `rpcPeerUserIdNumber`, numeric JSON), and `shikigami-core/src/Shikigami/Workspace/Types.hs` lines 39–63 show the allocated-identity pattern (`WorkspaceId` over `KindID "shikigami_workspace"`, `parseWorkspaceId`, `workspaceIdFromUUID`, `workspaceIdText`, `newWorkspaceId`). `shikigami-server/src/Shikigami/Server/Command/Resources.hs` shows an operator verb that opens the store, verifies migrations and prints JSON.

Values follow the house rules: [ADR 0080](../adr/0080-opaque-checked-values-do-not-expose-generic-construction.md) (opaque checked values have private constructors, checked parsers, no `Generic`, no `IsString`), [ADR 0081](../adr/0081-validated-results-use-private-seals-and-public-read-views.md) (validated results are sealed with public read views), [ADR 0094](../adr/0094-accounting-entities-use-allocated-identities-and-root-origin-receipts.md) (allocated identities are private `KindID` UUIDv7 values with full singular prefixes), [ADR 0101](../adr/0101-process-intent-decoding-preserves-launch-and-receipt-uncertainty.md) (a store read decodes inside the transaction and refuses corruption rather than treating it as absence), and the record style in `docs/architecture/packages.md` and [the record patterns](mori://shinzui/haskell-jitsurei/docs/core-record-patterns): unprefixed strict fields under `DuplicateRecordFields` and `NoFieldSelectors`, `OverloadedRecordDot` reads, explicit deriving strategies. The compiler probes in `tests/types/opaque-values.py` (run by `just domain-value-types`) prove a value cannot be constructed generically; this plan adds controls there. The cross-repository standards are [the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids), [the vertical-slice guide](mori://shinzui/keiro-runtime-patterns/docs/architecture-vertical-slice-modules), [the cross-cutting allowlist](mori://shinzui/keiro-runtime-patterns/docs/architecture-cross-cutting-modules) and [the Settei service standard](mori://shinzui/keiro-runtime-patterns/docs/config-settei-service-standard).

Other local decisions that bind this plan: [ADR 0003](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md) requires every executable to link only its own package's library, enforced by `shikigami-core/test/Shikigami/PackageArchitectureSpec.hs`; [ADR 0021](../adr/0021-operator-verbs-wrap-the-owning-library.md) requires operator verbs to wrap the owning library rather than write their own SQL; [ADR 0026](../adr/0026-outbound-sink-credentials-stay-opaque-and-http-policy-lives-at-the-process-boundary.md) keeps credentials opaque and transport policy at the process boundary, which is how the gateway's TLS material and the daemon's private key are handled; [ADR 0047](../adr/0047-public-api-authentication-is-a-verifier-at-the-vertical-mount.md) is the replaceable-verifier shape the gateway's hello check follows, with one indistinguishable refusal for every bad credential; and [ADR 0066](../adr/0066-worker-commands-require-retained-scopes-and-fresh-exact-authority.md) fixes that core owns wire types and that the server must not depend on the workers package, which is why `Shikigami.Machine.Types`, `Protocol` and `Store` live in core and the gateway and client live in workers.

Dependencies. The workers package already depends on `warp` and `websockets`; core already depends on `http-client-tls`. New direct dependencies are `warp-tls` and `wai-websockets` (both in the `yesodweb/wai` project), `crypton` (`kazu-yamamoto/crypton`) for Ed25519 and SHA-256, and a TLS client stream for the daemon (`tls` with `crypton-connection`, which `http-client-tls` already pulls transitively). Discover them with `mori registry search crypton`, `mori registry show yesodweb/wai --full` and `mori registry show kazu-yamamoto/crypton --full`, read the source on disk, and verify the released version on Hackage and the upstream tag before writing any bound; the local corpus may lag upstream. No X.509 client-certificate helper is registered in Mori, which is one reason machine authentication is challenge-response rather than mutual TLS.


## Plan of Work

### Milestone 1: Vocabulary and protocol

Create `shikigami-core/src/Shikigami/Machine/Types.hs`. It owns the shared vocabulary that plans 120 through 123 consume and imports from none of them. The four allocated identities follow the `WorkspaceId` pattern exactly, each with its own singular prefix: `MachineId` over `KindID "shikigami_machine"`, `EnrollmentOfferId` over `KindID "shikigami_machine_enrollment"`, `MachineSessionId` over `KindID "shikigami_machine_session"` and `MachineCommandId` over `KindID "shikigami_machine_command"`. Each has a checked parser that rejects another prefix, a non-UUIDv7 payload and a noncanonical encoding, a text renderer, a `newXId :: IO XId` minting UUIDv7, a from-UUID capture for allocator rows, and JSON instances over the canonical text; none has `Generic`, `IsString` or a coercion escape.

```haskell
newtype MachineId = MachineId (KindID.KindID "shikigami_machine")
  deriving stock (Eq, Ord, Show)

parseMachineId :: Text -> Either Text MachineId
machineIdFromUUID :: UUID -> Either Text MachineId
machineIdText :: MachineId -> Text
newMachineId :: IO MachineId

-- | Operator-facing label: 1..64 characters of [a-z0-9-], no leading or trailing hyphen.
newtype MachineName = MachineName Text
  deriving stock (Eq, Ord, Show)

parseMachineName :: Text -> Either Text MachineName
machineNameText :: MachineName -> Text

-- | Lowercase hex SHA-256 of the raw 32-byte Ed25519 public key (64 characters).
newtype KeyFingerprint = KeyFingerprint Text
  deriving stock (Eq, Ord, Show)

-- | Exactly 32 bytes; the only way in is the checked parser or the key generator.
newtype MachinePublicKey = MachinePublicKey ByteString
  deriving stock (Eq)

keyFingerprint :: MachinePublicKey -> KeyFingerprint

-- | One-time enrollment secret. No Show, no ToJSON; the offer verb prints it once.
newtype EnrollmentCode = EnrollmentCode Text

generateEnrollmentCode :: IO EnrollmentCode
enrollmentCodeDigest :: EnrollmentCode -> WorkspaceCoordinate "enrollment-digest"

data MachineStatus = Offered | AwaitingApproval | Enrolled | Revoked
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Platform = LinuxPlatform | DarwinPlatform | OtherPlatform
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | 'UnqualifiedPlatform' is deliberately not spelled like the refusal
-- 'UnqualifiedContainment' below: GHC forbids two constructors of one name
-- in one module, and the two values answer different questions.
data ContainmentProfile
  = SystemdCgroupV2 !(WorkspaceCoordinate "process-properties")
  | UnqualifiedPlatform
  deriving stock (Eq, Show)

type PolicyRevision = WorkspaceCoordinate "machine-policy"

data ConnectionState
  = NeverConnected
  | Connected {since :: !UTCTime, session :: !MachineSessionId}
  | Disconnected {since :: !UTCTime, lastSession :: !MachineSessionId}
  deriving stock (Eq, Show)

data OperationClass
  = ProvisionClass | ReadClass | EditClass | ProcessClass
  | GitClass | IntegrationClass | OwnershipClass | CleanupClass
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data CeilingKind = ConcurrentCommands | ProcessSeconds | OutputBytes | DiskBytes
  deriving stock (Eq, Show)

data MachineRefusal
  = OutsidePolicy !OperationClass | WrongMachine | StaleEpoch | UnknownRepository
  | UnqualifiedContainment | CeilingExceeded !CeilingKind | MalformedCommand | MachineRevoked
  deriving stock (Eq, Show)
```

`ContainmentProfile`, `ConnectionState`, `OperationClass`, `CeilingKind` and `MachineRefusal` get hand-written JSON codecs with a fixed tag vocabulary (`{"kind": "systemd-cgroup-v2", "properties": ...}` and so on) so a stored or transmitted value is never widened by a derived encoding. `WorkspaceCoordinate` comes from `Shikigami.Workspace.Value` and is reused rather than duplicated. The scope names `"enrollment-digest"`, `"machine-policy"` and `"process-properties"` (the last already exists in `Shikigami.Workspace.Systemd`) are the only new coordinate scopes.

Create `shikigami-core/src/Shikigami/Machine/Protocol.hs`. Every frame is one JSON object with an integer `format` (1 for this plan) and a `frame` tag, decoded through a `keys` helper identical in spirit to `Workspace.Protocol.keys` so that an object with any unexpected key is refused. The `Show` instances of `CommandEnvelope`, `ReceiptEnvelope` and every frame render `<protected>`.

```haskell
data MachineFrame
  = Hello !HelloFrame                 -- daemon -> gateway: public key, platform, profile, policy revision, optional enrollment code
  | Challenge !Nonce                  -- gateway -> daemon: fresh 32-byte nonce
  | Proof !Signature                  -- daemon -> gateway: Ed25519 over (nonce <> gateway fingerprint <> protocol version)
  | Welcome !WelcomeFrame             -- gateway -> daemon: session id, heartbeat seconds, pending fences (applied before anything else)
  | Refused !SessionRefusal           -- gateway -> daemon: one indistinguishable reason for every credential failure, distinct reason for revocation
  | Heartbeat !(StateRevision "machine-heartbeat")
  | Command !CommandEnvelope          -- gateway -> daemon
  | Receipt !ReceiptEnvelope          -- daemon -> gateway
  | Ack !MachineCommandId             -- gateway -> daemon: receipt retained centrally
  | Fence !FenceEnvelope              -- gateway -> daemon
  | FenceApplied !FenceEnvelope       -- daemon -> gateway

data CommandBinding = CommandBinding
  { machine :: !MachineId,
    workspace :: !WorkspaceRef,
    bindingDigest :: !(WorkspaceCoordinate "binding-digest"),
    repository :: !RepositoryId,
    base :: !(WorkspaceCoordinate "git-object"),
    assignment :: !AssignmentKey,
    owner :: !AgentIdentity,
    epoch :: !(StateRevision "worker-owner"),
    operationId :: !OperationId,
    attemptId :: !AttemptId,
    claimOwner :: !ClaimOwner,
    generation :: !(StateRevision "execution-attempt")
  }
  deriving stock (Eq, Generic)

data CommandEnvelope = CommandEnvelope
  { commandId :: !MachineCommandId,
    binding :: !CommandBinding,
    operation :: !MachineOperation,
    deadline :: !UTCTime,
    issuedAt :: !UTCTime
  }
  deriving stock (Eq, Generic)

data MachineOperation
  = Provision {policyRevision :: !(WorkspaceCoordinate "policy-identity")}   -- repository and base come from the binding
  | ReadFile {path :: !(WorkspaceCoordinate "relative-path"), bound :: !CapturedBytes}
  | ListFiles {prefix :: !(WorkspaceCoordinate "path-prefix"), bound :: !CapturedBytes}
  | ReplaceFile !Replacement
  | LaunchProcess {rule :: !(WorkspaceCoordinate "process-rule"), record :: !ProcessRecord}
  | ObserveProcess
  | CancelProcess
  | GitStatus
  | GitDiff {bound :: !CapturedBytes}
  | GitCommit !GitCandidate
  | Integrate ![(WorkspaceRef, WorkspaceCoordinate "git-object")]
  | FenceOwner !TransferIntent
  | AdmitWrite {session :: !WorkerSessionId}
  | Cleanup
  deriving stock (Eq)

operationClass :: MachineOperation -> OperationClass   -- total

data MachineOutcome
  = Provisioned !(WorkspaceCoordinate "git-object")
  | FileRead {digest :: !(WorkspaceCoordinate "content-digest"), bytes :: !CapturedBytes, truncation :: !OutputTruncation, content :: !Text}
  | FilesListed ![(WorkspaceCoordinate "relative-path", GitMode)]
  | FileReplaced !FileReceipt
  | ProcessObserved !ProcessView
  | GitObserved {head :: !(WorkspaceCoordinate "git-object"), changed :: ![WorkspaceCoordinate "relative-path"], diff :: !(Maybe Text)}
  | GitCommitted {commit :: !(WorkspaceCoordinate "git-object"), tree :: !(WorkspaceCoordinate "git-object"), changed :: ![WorkspaceCoordinate "relative-path"]}
  | Integrated {commit :: !(WorkspaceCoordinate "git-object"), conflicts :: ![WorkspaceCoordinate "relative-path"]}
  | Fenced !FenceOutcome
  | WriteAdmitted !Bool
  | CleanedUp
  | Refused !MachineRefusal
  | Unresolved
  deriving stock (Eq)

data ReceiptEnvelope = ReceiptEnvelope
  { commandId :: !MachineCommandId, binding :: !CommandBinding, outcome :: !MachineOutcome, settledAt :: !UTCTime }
  deriving stock (Eq, Generic)

data FenceEnvelope = FenceEnvelope
  { workspace :: !WorkspaceRef, oldEpoch :: !(StateRevision "worker-owner"), newEpoch :: !(StateRevision "worker-owner"), operationId :: !OperationId }
  deriving stock (Eq, Show, Generic)
```

Payload types are the existing ones: `Replacement` and `FileReceipt` from `Shikigami.Workspace.Provider`, `ProcessRecord` from `Shikigami.Workspace.Process`, `ProcessView` from `Shikigami.Workspace.Protocol`, `GitCandidate` and `GitMode` from `Shikigami.Workspace.GitTypes` and `Shikigami.Workspace.Value`, `TransferIntent` and `FenceOutcome` from `Shikigami.WorkerSession.Transfer`, `ClaimOwner` from `Shikigami.Execution.Claim`, `AssignmentKey` from `Shikigami.Execution.AssignmentKey`, and `CapturedBytes` and `OutputTruncation` from `Shikigami.Workspace.Value`. `GitCandidate` (parent, tree, result and changed paths) already lives in `Shikigami.Workspace.GitTypes`, so the protocol names it without moving anything. Bounded content fields keep the 1 MiB combined ceiling that `Workspace.Protocol.validView` enforces for stdout and stderr; `validReceipt :: ReceiptEnvelope -> Bool` enforces it for `FileRead`, `GitObserved` and `ProcessObserved`. The protocol module exports `frameLimit :: Int` (65536 bytes for a frame, because `FileRead` and `GitDiff` carry content) and the decoder refuses a frame above it before parsing.

Add `Machine` to `domainRoots` in `tools/style/module-ownership.json` with a comment that enrolled machines, their sessions and their commands are a concept with its own store and wire contract, citing ADR 0075. Add `Shikigami.MachineValueSpec` and `Shikigami.MachineProtocolSpec` to `shikigami-core/test/Shikigami/`, register them in `shikigami-core/test/Main.hs` and in the `shikigami-core-test` `other-modules` list in `shikigami-core/shikigami-core.cabal`. Add controls to `tests/types/opaque-values.py` proving that `MachineId`, `MachineName`, `KeyFingerprint`, `MachinePublicKey` and `EnrollmentCode` cannot be constructed with `coerce`, `Generic` or `fromString`, and that `EnrollmentCode` has no `Show` or `ToJSON` instance.

### Milestone 2: Registry migration and store

Allocate the migration with `just new-migration machine-registry`. Do not hard-code its number in code or docs: MasterPlan 19 and MasterPlan 20 also allocate migrations and none of them has landed, so the number is whatever `just new-migration` assigns at implementation time. The migration creates three schema-qualified tables.

```sql
CREATE TABLE shikigami.machines (
  machine_id text PRIMARY KEY,
  name text NOT NULL UNIQUE,
  status text NOT NULL CHECK (status IN ('offered', 'awaiting-approval', 'enrolled', 'revoked')),
  key_fingerprint text UNIQUE,
  public_key bytea,
  platform text,
  containment jsonb,
  policy_revision text,
  enrolled_at timestamptz,
  revoked_at timestamptz,
  revision numeric NOT NULL CHECK (revision >= 0)
);

CREATE TABLE shikigami.machine_enrollments (
  offer_id text PRIMARY KEY,
  machine_id text NOT NULL REFERENCES shikigami.machines(machine_id),
  code_digest text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  claimed_at timestamptz,
  approved_by text,
  approved_at timestamptz
);

CREATE TABLE shikigami.machine_sessions (
  session_id text PRIMARY KEY,
  machine_id text NOT NULL REFERENCES shikigami.machines(machine_id),
  gateway_instance text NOT NULL,
  opened_at timestamptz NOT NULL,
  closed_at timestamptz,
  close_reason text
);
CREATE INDEX machine_sessions_open ON shikigami.machine_sessions (machine_id) WHERE closed_at IS NULL;
```

Create `shikigami-core/src/Shikigami/Machine/Store.hs`. Every function is a hasql `Transaction` returning `Either MachineStoreError`, every state change is a conditional transition on the current status and revision, and every row read goes through an `Either`-typed decoder that condemns the transaction on a corrupt `containment` or status value instead of returning absence, as `Shikigami.Workspace.ProcessStore` does.

```haskell
data MachineStoreError = MachineMissing | MachineConflict | MachineCorrupt | EnrollmentExpired | EnrollmentMissing | MachineAlreadyRevoked
  deriving stock (Eq, Show)

data MachineRecord = MachineRecord
  { id :: !MachineId, name :: !MachineName, status :: !MachineStatus,
    fingerprint :: !(Maybe KeyFingerprint), publicKey :: !(Maybe MachinePublicKey),
    platform :: !(Maybe Platform), containment :: !(Maybe ContainmentProfile),
    policyRevision :: !(Maybe PolicyRevision), revision :: !(StateRevision "machine") }
  deriving stock (Eq, Show, Generic)

offerEnrollmentTx :: MachineName -> WorkspaceCoordinate "enrollment-digest" -> UTCTime -> Transaction (Either MachineStoreError (MachineId, EnrollmentOfferId))
claimEnrollmentTx :: WorkspaceCoordinate "enrollment-digest" -> MachinePublicKey -> Platform -> ContainmentProfile -> PolicyRevision -> UTCTime -> Transaction (Either MachineStoreError MachineRecord)
approveMachineTx :: MachineName -> KeyFingerprint -> Text -> UTCTime -> Transaction (Either MachineStoreError MachineRecord)
revokeMachineTx :: MachineName -> UTCTime -> Transaction (Either MachineStoreError MachineRecord)
recordSessionOpenedTx :: MachineId -> Text -> UTCTime -> Transaction (Either MachineStoreError MachineSessionId)
recordSessionClosedTx :: MachineSessionId -> Text -> UTCTime -> Transaction (Either MachineStoreError ())
inspectMachineTx :: MachineName -> Transaction (Either MachineStoreError (Maybe (MachineRecord, ConnectionState)))
inspectMachinePageTx :: Maybe MachineName -> Transaction (Either MachineStoreError [(MachineRecord, ConnectionState)])
authenticateMachineTx :: KeyFingerprint -> Transaction (Either MachineStoreError (Maybe MachineRecord))
```

`offerEnrollmentTx` inserts the `Offered` machine and its offer in one transaction and refuses a duplicate name. `claimEnrollmentTx` matches the code digest, refuses an expired or already-claimed offer, stores the public key and fingerprint, and moves the machine to `AwaitingApproval`; a second claim with the same digest and same key converges on the same record, and a different key conflicts. `approveMachineTx` requires `AwaitingApproval` and the exact fingerprint and moves to `Enrolled`. `revokeMachineTx` moves any non-revoked status to `Revoked` and records the time; nothing moves a `Revoked` machine anywhere. `authenticateMachineTx` is what the gateway calls at hello: it returns the record only when the fingerprint belongs to an `Enrolled` machine. Identities are allocated in IO through `newMachineId`, `newEnrollmentOfferId` and `newMachineSessionId` and passed in; the store never mints inside SQL. `inspectMachinePageTx` returns at most 64 rows after the cursor. Add `Shikigami.MachineStoreSpec` under `shikigami-core/test-postgres/Shikigami/`, register it in `shikigami-core/test-postgres/Main.hs` and the suite's `other-modules`, using `Shikigami.Migrations.TestSupport.withShikigamiMigratedSuite`.

### Milestone 3: Gateway, daemon, roles, settings and verbs

Declare the settings in `shikigami-core/src/Shikigami/App/Config.hs` beside `workspacesKey`: `machineGatewayKey = stableKey "machine.gateway"` bound to `SHIKIGAMI_MACHINE_GATEWAY`, and `machineKey = stableKey "machine"` bound to `SHIKIGAMI_MACHINE`, both optional `secretSetting`s decoded as strict JSON into new types in `shikigami-core/src/Shikigami/Machine/Settings.hs`.

```haskell
data MachineGatewaySettings = MachineGatewaySettings
  { bind :: !Text, port :: !Port, certificatePath :: !(WorkspaceLocator "tls-certificate"), privateKeyPath :: !(WorkspaceLocator "tls-private-key"),
    heartbeatSeconds :: !HeartbeatSeconds, maxSessions :: !SessionLimit, gatewayInstance :: !Text }
  deriving stock (Eq, Generic)

data GatewayEndpoint = GatewayEndpoint {host :: !Text, port :: !Port, pinnedFingerprint :: !(WorkspaceCoordinate "certificate-fingerprint")}
  deriving stock (Eq, Generic)

data MachineDaemonSettings = MachineDaemonSettings
  { stateDirectory :: !(WorkspaceLocator "machine-state"), policyPath :: !(WorkspaceLocator "machine-policy-file"), gateway :: !GatewayEndpoint }
  deriving stock (Eq, Generic)
```

`HeartbeatSeconds` is checked to 5..300 and `SessionLimit` to 1..1024, both numeric JSON with private constructors like `RpcRequestSeconds`. `pinnedFingerprint` is the lowercase hex SHA-256 of the gateway's DER certificate, typed as `WorkspaceCoordinate "certificate-fingerprint"` so it can never be confused with a machine key's `KeyFingerprint`; the sketch above is corrected accordingly and the same scope is used in `machine.json`, in the client's pin check and in every log classification. Add `MachineGatewayRole` and `MachineDaemonRole` to the `Role` sum with `roleBinary` `shikigami-machine-gateway` and `shikigami-machine`, `defaultHealthPort` `Just (Port 8095)` for the gateway and `Nothing` for the daemon, and `roleRequiredKeys` `[databaseConnectionStringKey, machineGatewayKey]` and `[machineKey]`. Extend `missingRequirements` so the daemon role additionally fails resolution when `databaseUrl`, any queue setting or any Kafka setting is present, naming the offending key; the daemon must be impossible to start with a central credential in its environment.

Create `shikigami-workers/src/Shikigami/Machine/Gateway.hs`. It serves one WebSocket route over TLS using `warp-tls` with the configured certificate and key and `wai-websockets` for the upgrade, and shares the two health routes the other roles serve. For each connection it runs the exchange: read `Hello` (bounded by `frameLimit`), look the fingerprint up with `authenticateMachineTx` or, when `Hello` carries an enrollment code, call `claimEnrollmentTx` and answer `Refused` with the enrollment-pending reason; generate a fresh 32-byte nonce with `crypton`'s `getRandomBytes`, send `Challenge`, read `Proof`, verify the Ed25519 signature over the nonce, the gateway's own certificate fingerprint and the protocol version with the stored public key; on success allocate a session through `recordSessionOpenedTx`, send `Welcome` with the heartbeat interval and an empty fence list (plan 122 fills it), and bind the socket to the `MachineId` for its lifetime. Wrong key, unknown fingerprint, malformed proof and a proof for a stale nonce all produce the same `Refused` reason; only a `Revoked` machine receives the distinct revocation reason, because the request requires revocation to be visible on retries. The gateway sends `Heartbeat` every interval and closes the socket after two missed replies; it polls the machine's status every heartbeat and closes with a revocation reason when it is `Revoked`; it refuses the connection outright when open sessions equal `maxSessions`. Frames beyond the hello exchange are dispatched to a `GatewaySessionHandler` record that this plan fills with a loop accepting only `Heartbeat` and refusing anything else, which plan 122 replaces. Logs carry the machine name, session id and refusal class only, never key bytes, nonces, codes or certificate material.

Create `shikigami-workers/src/Shikigami/Machine/Client.hs`. It opens a TLS connection to the configured endpoint with `tls` and `crypton-connection`, computes the SHA-256 of the presented leaf certificate's DER bytes and refuses the connection unless it equals `pinnedFingerprint`, upgrades to WebSocket with `websockets`, sends `Hello`, answers `Challenge` by signing with the private key loaded from the state directory, and on `Welcome` applies every pending fence through the handler before processing anything else. Reconnection uses exponential backoff from 1 second doubling to a 300-second ceiling with jitter, resetting after a successful `Welcome`; a `Refused` with the revocation reason stops reconnection and exits nonzero, while any other `Refused` keeps backing off. The handler record is what later plans implement.

```haskell
data MachineSessionHandler = MachineSessionHandler
  { onCommand :: !(CommandEnvelope -> IO (Maybe ReceiptEnvelope)),
    onFence :: !(FenceEnvelope -> IO ()),
    onAck :: !(MachineCommandId -> IO ()),
    onSession :: !(MachineSessionId -> IO [ReceiptEnvelope])   -- receipts to resend when a session opens
  }
```

This plan installs a handler whose `onCommand` answers `Refused OutsidePolicy` for every class, whose `onFence` records nothing, and whose `onSession` returns no receipts. Create `shikigami-workers/src/Shikigami/Machine/Identity.hs` for the state directory: `shikigami-machine enroll --code <code>` creates the directory with mode 0700 if absent, refuses one that is group- or world-readable, generates an Ed25519 key pair with `crypton`, writes `key` (0600), `machine.json` (public key, fingerprint, gateway endpoint and pinned fingerprint) with fsync and atomic rename, prints the fingerprint once for the operator to compare, connects with the code in `Hello`, and exits 0 when the gateway answers with the enrollment-pending reason. `shikigami-machine run` loads the identity, refuses a missing or unreadable key, and runs the client until revoked or interrupted. The platform in `Hello` is detected from the operating system and the containment profile is `UnqualifiedPlatform` in this plan (plan 121 qualifies systemd); the policy revision is the digest of the policy file if present or a fixed placeholder digest otherwise, which plan 120 replaces.

Create `shikigami-server/src/Shikigami/Server/Command/Machines.hs` following `Shikigami.Server.Command.Resources`: `shikigami machines offer --name <name> [--expires-minutes 15] --json` prints `{"machine": name, "offerId": ..., "code": ..., "expiresAt": ...}` exactly once and stores only the digest; `shikigami machines approve <name> --fingerprint <hex> --json` prints the enrolled record; `shikigami machines revoke <name> --json` prints the revoked record. Register the verbs in `shikigami-server/src/Shikigami/Server/Command.hs` beside `resources` and add `Shikigami.Server.Command.Machines` to `compositionModules`. Add `machineGatewayRoleInfo` and `machineDaemonRoleInfo` to `shikigami-workers/src/Shikigami/Workers/Command.hs` and `workerRoles`, create `shikigami-workers/app/machine-gateway/Main.hs` and `shikigami-workers/app/machine/Main.hs` on the six-line `runRole` pattern, register both executables in `shikigami-workers/shikigami-workers.cabal`, add both rows to the executable table in `docs/architecture/packages.md`, and add both names to `prototypeExecutables` in `nix/qualification-package.nix`. Add `Shikigami.MachineSessionSpec` to the workers suite: it generates a self-signed test certificate in a temporary directory, starts the gateway on a loopback port against the migrated test database, runs the daemon client in-process against it, and asserts the MasterPlan's session check.


## Concrete Steps

Run from the repository root. Discover and verify dependencies before touching any Cabal file:

```bash
mori registry search crypton
mori registry show kazu-yamamoto/crypton --full
mori registry show yesodweb/wai --full
```

Then read the relevant source on disk (Ed25519 and SHA-256 in `crypton`, `runTLS`/`tlsSettings` in `warp-tls`, `websocketsOr` in `wai-websockets`, `runClientWithStream` in `websockets`) and verify each released version on Hackage and the upstream tag before adding bounds to `shikigami-workers/shikigami-workers.cabal`. Then, per milestone:

```bash
nix develop --no-write-lock-file -c cabal build shikigami-core
just haskell-conventions
just domain-value-types
nix develop --no-write-lock-file -c cabal test shikigami-core-test --test-options='-p Machine' --test-show-details=direct
```

Expected after Milestone 1: a nonzero count of `Machine` cases passes, the conventions check reports the new root as allowed, and the opaque-values probe prints the new controls as refused compilations. Milestone 2:

```bash
just new-migration machine-registry
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test --test-options='-p MachineStore --num-threads 1' --test-show-details=direct
just migration-schema-isolation
```

Expected: the lifecycle, convergence, expiry, concurrency, corruption and revocation cases pass; run PostgreSQL suites with `--num-threads 1` when connection exhaustion recurs (friction entries FRIC-2 and FRIC-5 in `docs/friction-log/`). Milestone 3:

```bash
nix develop --no-write-lock-file -c cabal build all
nix develop --no-write-lock-file -c cabal test shikigami-workers-test --test-options='-p MachineSession' --test-show-details=direct
nix develop --no-write-lock-file -c cabal run shikigami-machine-gateway -- --check-config
SHIKIGAMI_DATABASE_URL=postgres://... nix develop --no-write-lock-file -c cabal run shikigami-machine -- --check-config
just keiro-gate
```

Expected: the session case passes; the gateway's configuration check names `machine.gateway` when it is missing; the daemon's configuration check fails naming `database.url` because a connection string is present. A manual walk-through on one host, with the gateway running on a loopback port with a self-signed certificate:

```bash
shikigami machines offer --name laptop-a --json
SHIKIGAMI_MACHINE='{"stateDirectory":"/tmp/shikigami-machine","policyPath":"/tmp/shikigami-machine/policy.json","gateway":{"host":"127.0.0.1","port":8443,"pinnedFingerprint":"<hex>"}}' shikigami-machine enroll --code <code>
shikigami machines approve laptop-a --fingerprint <hex> --json
SHIKIGAMI_MACHINE='...' shikigami-machine run
shikigami machines revoke laptop-a --json
```

Expected: `enroll` prints the fingerprint and exits 0 with the pending reason; `approve` prints `"status":"enrolled"`; `run` logs `machine.session.welcome` and periodic heartbeats; `revoke` makes `run` log `machine.session.revoked` and exit nonzero, and a second `run` is refused immediately. Every implementation commit carries `MasterPlan: docs/masterplans/21-execute-governed-work-through-enrolled-machine-daemons.md`, `ExecPlan: docs/plans/119-enroll-machines-and-hold-outbound-daemon-sessions-with-revocable-identities.md` and `Intention: intention_01m6m0b6zxebfv3yatcy7fvbgk` trailers.


## Validation and Acceptance

Milestone 1 is accepted when the codec tests show that every frame round-trips, that an object with an extra key, a wrong `format` or a 65537-byte body is refused, that `operationClass` is total over every `MachineOperation` constructor (an exhaustiveness check with `-Wincomplete-patterns` as an error plus a test enumerating constructors), that `MachineId` refuses a UUIDv4 payload, a foreign prefix and a noncanonical encoding, that `MachineName` refuses uppercase, 65 characters and a leading hyphen, and that `EnrollmentCode` has no `Show` or `ToJSON` instance (compiler probe). Milestone 2 is accepted when the PostgreSQL suite shows offer, claim, approve and revoke in order with the row's status at each step; a second claim with the same digest and key returning the same record and a different key returning `MachineConflict`; an expired offer returning `EnrollmentExpired`; two concurrent claims for one offer producing one winner; a row with a malformed `containment` value causing `MachineCorrupt` and no mutation; and `approveMachineTx` on a `Revoked` machine returning `MachineAlreadyRevoked`.

Milestone 3 is accepted when the workers-suite session case shows, in order: a `Hello` with an enrollment code producing an `AwaitingApproval` row and the pending refusal; after `approveMachineTx`, a `Hello`, `Challenge`, `Proof` and `Welcome` whose `fences` list is empty and whose `heartbeatSeconds` equals the configured value; two `Heartbeat` exchanges; a `revokeMachineTx` followed by the gateway closing the socket with the revocation reason within one heartbeat interval; a reconnection refused with the revocation reason and the client exiting instead of backing off; a `Proof` signed with a different key refused with the generic reason; the same `Proof` bytes replayed on a new connection refused because the nonce differs; and `machine_sessions` holding one closed row with the revocation reason. It also requires a daemon configuration check failing when a database URL is present, a gateway refusing the connection when `maxSessions` sessions are open, and log fixtures containing neither the enrollment code, the nonce, the signature nor key bytes. Bounds are part of acceptance: frames above 65536 bytes refused, heartbeat interval outside 5..300 refused at configuration, at most 64 rows per registry page.


## Idempotence and Recovery

`offerEnrollmentTx` for an existing name conflicts rather than reissuing a code; issue a new offer under a new name or revoke the old machine first. `claimEnrollmentTx` converges for the same key and conflicts for a different one, so a daemon that crashed after sending `Hello` can rerun `enroll` safely. `enroll` refuses to overwrite an existing key file; delete the state directory deliberately to re-enroll, and expect the old fingerprint to need revocation centrally. Session rows left open by a crashed gateway are closed on the gateway's next start with reason `gateway-restart`; a live socket is the only proof of connection. Revocation is terminal and idempotent. The migration is additive and creates no backfill; rolling forward is the only path once a row exists.


## Interfaces and Dependencies

Shared types and the store belong in `shikigami-core` (`Shikigami.Machine.Types`, `Shikigami.Machine.Protocol`, `Shikigami.Machine.Store`, `Shikigami.Machine.Settings`); the gateway, client, identity directory and both executables belong in `shikigami-workers` (`Shikigami.Machine.Gateway`, `Shikigami.Machine.Client`, `Shikigami.Machine.Identity`); the operator verbs belong in `shikigami-server` (`Shikigami.Server.Command.Machines`) and reach the store through core only. Reuse `OperationId`, `AttemptId`, `ClaimOwner`, `StateRevision`, `WorkspaceRef`, `WorkspaceCoordinate`, `AssignmentKey`, `AgentIdentity`, `RepositoryId` and the existing workspace payload types; introduce no second identity, digest or receipt vocabulary. Plan 120 consumes `CommandEnvelope`, `MachineOperation`, `OperationClass`, `MachineRefusal`, `MachineCommandId`, `FenceEnvelope` and `MachineSessionHandler`; plan 121 fills the handler; plan 122 consumes the store, the gateway's session handler and `Welcome`'s fence list; plan 123 adds page readers and inspection verbs. Widening `MachineRefusal` or `MachineOperation` is a MasterPlan integration change, recorded there before it is made.

New third-party dependencies are `crypton`, `warp-tls`, `wai-websockets` and the TLS client stream (`tls` with `crypton-connection`), each discovered through Mori and verified against Hackage and upstream tags before a bound is written. This plan selects no version. The daemon must pass `Shikigami.PackageArchitectureSpec`: both executables link only `shikigami-workers`. No declared workflow body changes; `just keiro-gate` confirms it.
