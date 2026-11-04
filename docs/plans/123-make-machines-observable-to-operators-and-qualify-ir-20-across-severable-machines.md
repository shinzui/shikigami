---
id: 123
slug: make-machines-observable-to-operators-and-qualify-ir-20-across-severable-machines
title: "Make machines observable to operators and qualify IR-20 across severable machines"
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

# Make machines observable to operators and qualify IR-20 across severable machines

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Plans 119 through 122 give Shikigami enrolled machines, a local policy that each machine enforces, a daemon that hosts workspace operations, and a central relay that places assignments on machines and settles their receipts. None of them yet lets an operator answer the ordinary questions: which machines are enrolled, which are connected, what policy revision each runs, what is placed on each, what is queued or unresolved, and whether any fence is still pending. None of them yet proves, on real separate machines behind a network that can be cut, that the nine acceptance cases in [IR-20](../improvement-requests/execute-governed-work-through-machine-daemons.md) hold together.

After this plan, `shikigami machines list --json` pages every enrolled machine with its status, connection state, platform, containment profile and policy revision; `shikigami machines inspect <name> --json` adds the placed assignments, command counts by state, pending fences and the age of the oldest unresolved command, and `--fail-when-disconnected 10m` exits nonzero when the machine has been away longer than ten minutes; on the machine itself, `shikigami-machine status --json` reports the daemon's own view (identity fingerprint, gateway pin, connection state, policy revision, containment profile and ledger counts) without exposing key bytes, enrollment codes, host paths outside its state directory or any command content. Five new metrics are exported by the gateway and the relay. A new operations guide, `docs/operations/machines.md`, explains enrollment on both sides, the local policy file, what leaves a machine, absence and partition behavior, revocation and inspection.

The plan then closes the request. A new harness, `tests/workspace/run-machines-apple.sh`, starts three disposable Apple containers on a dedicated container network: one central runtime and two machines. It enrolls both machines, runs the nine IR-20 acceptance cases as named checks (severing the network from inside a guest with a firewall rule and restoring it), and copies bounded evidence back to the host. That evidence is retained under `docs/evidence/plan-123/`, IR-20 is marked completed, MasterPlan 21's registry and progress are updated, and the six durable decisions the initiative made are distilled into ADRs. This plan is EP-5 of [MasterPlan 21](../masterplans/21-execute-governed-work-through-enrolled-machine-daemons.md); it requires plans 121 and 122 to be Complete, which in turn require plans 119 and 120.


## Progress

- [ ] Milestone 1: `shikigami machines list|inspect --json` with `--fail-when-disconnected`, `shikigami-machine status --json`, the five `shikigami.machine.*` instruments, `docs/operations/machines.md`, the configuration guide additions and a validated capability entry exist; `cabal test shikigami-server-test --test-options='-p Machines'`, `just capabilities-validate` and `just haskell-conventions` pass.
- [ ] Milestone 2: `bash tests/workspace/run-machines-apple.sh --smoke` creates the network and three guests, enrolls both machines with explicit approval, runs one edit, validation and commit through machine-a, severs and restores machine-a's path to the gateway while a command is in flight, and tears everything down, with the smoke evidence copied to the private task directory.
- [ ] Milestone 3: `bash tests/workspace/run-machines-apple.sh --qualify` passes all nine named IR-20 cases; evidence is retained under `docs/evidence/plan-123/`; IR-20 is completed with `completedAt`, `resolution` and `targetPlan`; MasterPlan 21's registry marks EP-5 Complete; and the six initiative ADRs exist.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: IR-20 qualification requires at least two enrolled machines behind a network the harness can sever; host-only compilation, the PostgreSQL suites and single-guest runs are supporting evidence and do not qualify the request.
  Rationale: The request states this directly in its acceptance preamble, and the partition cases (4, 5 and 6) have no meaning on one host. Reusing the one-guest `run-apple.sh` would prove relay mechanics but not absence, fencing across a partition or identity binding between machines.
  Date: 2026-11-04

- Decision: Severance is a guest-side firewall rule (an `iptables` or `nft` DROP toward the gateway address and port) applied and removed inside the machine guest, not detaching the container from its network.
  Rationale: Apple `container` 1.5.0 offers `container network create|delete|inspect|list|prune` but no verb to detach a running container from a network and reattach it, so detaching would require stopping the guest and would conflate a partition with a daemon restart (case 6). A firewall rule severs only the network path, leaves the daemon running, and is reversible without changing the guest's address.
  Date: 2026-11-04

- Decision: `machine.name` is the only identifier-like metric attribute this plan adds; machine ids, session ids, command ids, paths and error text never appear as attributes.
  Rationale: Metric attributes must have bounded cardinality. A machine name is an operator-chosen label from a bounded enrolled set, while ids and paths are unbounded and would also leak coordinates the request keeps off the central host. The existing instruments follow the same rule (`agent`, `trigger`, `topic`, `outcome` only).
  Date: 2026-11-04

- Decision: IR-20 is marked completed only by this child, after the full nine-case matrix passes on the multi-machine harness; no earlier child changes the request's status.
  Rationale: Earlier children prove parts of the request with fixtures and single guests. Claiming completion before the integrated evidence exists would repeat the mistake MasterPlan 14 guarded against when it kept IR-11 open until plan 96's full native matrix passed.
  Date: 2026-11-04


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a Cabal multi-package Haskell service. `shikigami-core` owns domain behavior and PostgreSQL store adapters, `shikigami-workers` owns long-running loops and the physical workspace adapters, `shikigami-server` owns the public HTTP API and the administrative `shikigami` command, and `shikigami-migrations` owns append-only SQL migrations and the `test-support` sublibrary that gives every test an isolated migrated database. `docs/architecture/packages.md` describes this and lists every executable in a table; `tools/style/module-ownership.json` lists every concept root and every individually reviewed composition module, and `just haskell-conventions` fails on an unlisted module. [ADR 0075](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md) is the decision behind that list.

A *machine* is a host enrolled through [plan 119](119-enroll-machines-and-hold-outbound-daemon-sessions-with-revocable-identities.md): it has an allocated `MachineId`, an operator-chosen `MachineName`, a key fingerprint, a `MachineStatus` (`Offered | AwaitingApproval | Enrolled | Revoked`), a `Platform`, a `ContainmentProfile` (`SystemdCgroupV2` or `UnqualifiedPlatform`; the refusal `UnqualifiedContainment` is a different type), a `PolicyRevision` digest of its local policy, and a `ConnectionState` (`NeverConnected`, `Connected {since, session}`, `Disconnected {since, lastSession}`), all defined in `shikigami-core/src/Shikigami/Machine/Types.hs` and persisted by `shikigami-core/src/Shikigami/Machine/Store.hs` in `shikigami.machines`, `shikigami.machine_enrollments` and `shikigami.machine_sessions`. The *daemon* is the `shikigami-machine` executable in `shikigami-workers`; the *gateway* is the `shikigami-machine-gateway` executable that accepts the daemon's outbound WebSocket-over-TLS session. A *command* is one `CommandEnvelope` the central relay from [plan 122](122-place-assignments-on-machines-and-relay-durable-commands-with-absence-and-partition-fencing.md) enqueues in `shikigami.machine_commands` with the closed `CommandState` (`Queued | Delivered | Settled | Refused | Unresolved | Superseded`); a *pending fence* is a `shikigami.machine_fences` row recorded when a transfer leaves a disconnected machine, applied by the daemon before any other exchange on its next session. The daemon's *ledger* from [plan 120](120-enforce-local-machine-policy-over-typed-bound-commands-with-a-retained-ledger.md) retains identity, applied fences and unacknowledged receipts under its state directory. [Plan 121](121-host-workspace-operations-on-the-machine-with-local-deadlines-and-retained-receipts.md) executes admitted commands through the physical workspace interface.

Operator commands follow [ADR 0021](../adr/0021-operator-verbs-wrap-the-owning-library.md): a verb in `shikigami-server/src/Shikigami/Server/Command/*.hs` wraps the owning library's store functions and writes no SQL of its own. The existing modules are the pattern: `Shikigami.Server.Command.Resources.runResourcesInspect :: ExecutionRootId -> Bool -> AppConfig -> IO ()` wraps `Execution.ResourcesStore.inspectRoot`, `Shikigami.Server.Command.Workers.runWorkersInspect :: Text -> MessagePosition -> Int -> Bool -> AppConfig -> IO ()` pages a session, and `Shikigami.Server.Command.Agents.runAgentsList :: Bool -> AppConfig -> IO ()` chooses JSON or a table from a `--json` flag. The `shikigami` command tree in `shikigami-server/src/Shikigami/Server/Command.hs` registers each top-level verb as `("name", command "name" info)`; `ResolveApproval` and `Ops` show how a verb exits with `System.Exit.exitWith (ExitFailure 1)` on a negative verdict. Plan 119 created `shikigami-server/src/Shikigami/Server/Command/Machines.hs` with `offer`, `approve` and `revoke` and listed it in `compositionModules`; this plan adds `list` and `inspect` to that module. The server does not depend on `shikigami-workers` ([ADR 0066](../adr/0066-worker-commands-require-retained-scopes-and-fresh-exact-authority.md)), so every reader this plan needs must live in `shikigami-core`.

Metrics are OpenTelemetry instruments on `ShikigamiMetrics` in `shikigami-core/src/Shikigami/Telemetry/Metrics.hs`, constructed once by `newShikigamiMetrics` from the process meter, named `shikigami.<noun>.<verb>` (`shikigami.runs.started`, `shikigami.queue.depth`), recorded through small `record*` functions, and carrying only bounded attributes (`agent`, `trigger`, `outcome`, `topic`). Gauges are created with `meterCreateGaugeInt64`. Health probes are governed by [ADR 0020](../adr/0020-readiness-covers-only-what-restarting-can-fix.md): `/health/ready` reports PostgreSQL reachability only and `/health/live` in-process progress only; a disconnected machine is neither, so it never appears in a probe. Bounded inspection follows [ADR 0071](../adr/0071-first-release-inspection-is-an-isolated-administrative-runtime.md): operator reads show lifecycle metadata, never protected bodies, and every page has a limit.

Documentation lives in three governed places. `docs/operations/*.md` are plain Markdown runbooks (`workspaces.md` is the model for this plan's `machines.md`, and `configuration.md` has one subsection per settings object under "The settings" and "Which binary needs what"). `docs/capabilities/` is an OKF bundle governed by `docs/capabilities/profile.dhall` (profile `coordination.capabilities`); each entry carries `type: Capability`, `title`, `description`, `capabilityId` (the highest is `CAP-30`, so the next is allocated with `okf id next` at implementation time), `provider`, `status`, `stability`, `since`, `packages`, `interface`, `tags`, `generated`, `requires` and `evidence`; `just capabilities-validate` enforces the profile and `just capabilities-index` regenerates `index.md`. `docs/improvement-requests/` is likewise an OKF bundle: a completed request carries `status: completed`, `completedAt`, `resolution` and `targetPlan` (see `support-continuing-worker-sessions.md`), `log.md` receives a dated `**Completion**` entry, and `just improvement-requests-validate` and `just improvement-requests-index` check and regenerate it. Evidence for earlier plans is retained under `docs/evidence/plan-<n>/` as bounded JSON (`docs/evidence/plan-96/joint-native-qualification.json` records `caseCount`, `cases`, `command`, `date`, `environment`, `exitCode` and redacted receipts) beside a Markdown matrix (`docs/evidence/plan-84/acceptance.md` maps each acceptance item to its proof).

The Linux qualification environment is Apple containers, as `AGENTS.md` directs. `tests/workspace/run-apple.sh` is the one-guest recipe: it builds the runtime with Nix, starts a disposable `docker.io/kindest/node` arm64 guest with `/sbin/init`, installs D-Bus, PostgreSQL, Git and an SSH server, generates a throwaway SSH key, verifies the guest host key, publishes SSH on loopback only, copies the Nix closure with `nix copy`, copies only explicit fixture sources, runs `tests/workspace/run-linux.sh` inside the guest, and on exit copies bounded evidence to a private task directory and stops the guest. `tests/workspace/build-apple.sh` builds `packages.aarch64-linux.<attribute>` the same way and falls back to the configured remote builder when the two-core Cabal configuration stalls (FRIC-21). Apple `container` 1.5.0 on this Mac supports `container network create [--internal] [--subnet <subnet>] <name>`, `container network delete`, `inspect`, `list` and `prune`, and `container run --network <name>`. The guest image ships `iptables`.

The ADRs this plan's matrix proves are [ADR 0060](../adr/0060-safe-recovery-spends-new-attempts-and-retains-independent-receipts.md), under which a late receipt from a former attempt settles only that attempt's accounting and never completes a replaced assignment, and [ADR 0063](../adr/0063-handoffs-establish-epochs-only-after-fences-and-versioned-owner-receipts.md), under which a successor never writes the same resource before the former writer is fenced; plan 122's partition transfer satisfies it by allocating a new workspace on an explicit base. Value rules every new type follows are [ADR 0080](../adr/0080-opaque-checked-values-do-not-expose-generic-construction.md) and [ADR 0081](../adr/0081-validated-results-use-private-seals-and-public-read-views.md), the shared `Shikigami.Duration` (`Duration (scope :: Symbol)`, `parseDuration`, `durationTime`), and the house record style of unprefixed strict fields under `DuplicateRecordFields` and `NoFieldSelectors` from [the record patterns](mori://shinzui/haskell-jitsurei/docs/core-record-patterns). The cross-repository standards are [the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids), [the vertical-slice guide](mori://shinzui/keiro-runtime-patterns/docs/architecture-vertical-slice-modules) and [the test layout](mori://shinzui/keiro-runtime-patterns/docs/architecture-test-layout). ADRs are plain Markdown files in `docs/adr/` numbered sequentially with `Date`, `Status`, Context, Decision, Alternatives rejected, Consequences and References sections; the bundle is not profile-governed, so no OKF frontmatter is added.


## Plan of Work

### Milestone 1: Inspection verbs, daemon status, metrics and documentation

Add two bounded readers to `shikigami-core/src/Shikigami/Machine/Store.hs`. Both run inside a read-only transaction, take no row locks, decode stored JSON through the owner's existing decoders and refuse corruption inside the transaction with the store's existing error, following [ADR 0101](../adr/0101-process-intent-decoding-preserves-launch-and-receipt-uncertainty.md). The page reader is keyset-paged on `MachineName` and bounded by a checked limit; the detail reader joins the machine row with its latest session, placed workspace bindings (`placement = OnMachine name` from plan 122), command counts grouped by `CommandState`, pending fences and the oldest `Unresolved` command's issue time. Neither returns command operations, receipts, policy bodies or key bytes. The sketch, with the new types marked:

```haskell
-- New in Shikigami.Machine.Store (core).
newtype MachinePageLimit = MachinePageLimit Int   -- private; 1..64; parseMachinePageLimit
data MachinePage = MachinePage
  { machines :: ![MachineView], next :: !(Maybe MachineName) }
  deriving stock (Eq, Show, Generic)

inspectMachinePageTx :: Maybe MachineName -> MachinePageLimit -> Transaction (Either MachineError MachinePage)

data MachineDetail = MachineDetail
  { machine :: !MachineView
  , connection :: !ConnectionState
  , placements :: ![PlacementView]               -- workspace id, repository, assignment key, owner epoch
  , commands :: !(Map CommandState Word)          -- counts only, every state present
  , pendingFences :: ![PendingFenceView]          -- workspace ref, old and new epoch, recorded at
  , oldestUnresolved :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show, Generic)

inspectMachineDetailTx :: MachineName -> Transaction (Either MachineError (Maybe MachineDetail))
```

`MachineView` is plan 119's public read view of a machine row (id, name, status, fingerprint, platform, containment profile, policy revision, enrolled and revoked times). `PlacementView` and `PendingFenceView` are new ordinary records with explicit `ToJSON` instances whose field names are the JSON keys; none has a `FromJSON` instance, because nothing decodes an inspection view.

Extend `shikigami-server/src/Shikigami/Server/Command/Machines.hs` with `list` and `inspect`:

```haskell
-- New verbs; offer/approve/revoke exist from plan 119.
runMachinesList :: Maybe MachineName -> MachinePageLimit -> Bool -> AppConfig -> IO ()
runMachinesInspect :: MachineName -> Maybe (Duration "machine-disconnected") -> Bool -> AppConfig -> IO ()
```

`runMachinesList` prints a table (name, status, connection, platform, profile, policy revision) or, with `--json`, the `MachinePage` encoded as one JSON object with `machines` and `next`; `--after <name>` and `--limit <1..64>` page it, defaulting to 32. `runMachinesInspect` prints the detail or its JSON; an unknown name exits 1 with `machine not found` on stderr. With `--fail-when-disconnected <duration>`, where the duration is parsed into `Duration "machine-disconnected"` from a `30s`, `10m` or `2h` literal, the verb exits 2 when the connection state is `Disconnected {since}` and now minus `since` exceeds the duration, or `NeverConnected`, and exits 0 otherwise; it still prints the detail first. Register both in the `machines` subtree of `shikigami-server/src/Shikigami/Server/Command.hs` with `progDesc` strings, and add server-suite cases in `shikigami-server/test/Shikigami/Server/Command/MachinesSpec.hs` that run the verbs against a migrated database seeded through plan 119's and plan 122's store functions, checking JSON shape, paging, the unknown-name exit code and both branches of `--fail-when-disconnected`.

On the daemon, add `status` to `shikigami-machine` in `shikigami-workers/src/Shikigami/Machine/Command.hs` (or wherever plan 119 placed the daemon's subcommand parser). It reads the ledger through plan 120's `recoverLedger` without connecting to the gateway and prints:

```haskell
-- New in shikigami-workers (Shikigami.Machine.Status).
data DaemonStatus = DaemonStatus
  { fingerprint :: !KeyFingerprint
  , gatewayPin :: !(WorkspaceCoordinate "certificate-fingerprint")
  , connection :: !ConnectionState       -- as last recorded by the running daemon in the ledger
  , policyRevision :: !PolicyRevision
  , containment :: !ContainmentProfile
  , ledger :: !LedgerCounts
  }
data LedgerCounts = LedgerCounts
  { admitted :: !Word, executing :: !Word, unacknowledgedReceipts :: !Word, appliedFences :: !Word }
```

`shikigami-machine status --json` encodes that record; the text form is one line per field. The status never includes the private key, the enrollment code, any path other than the state directory itself, or any command envelope or receipt body. `shikigami-machine check-policy` already exists from plan 120 and is only documented here. Add a worker-suite case that writes a fixture ledger, runs the status renderer and asserts the exact JSON keys and the absence of the forbidden fields.

Add the five instruments to `ShikigamiMetrics`:

```haskell
-- Added to Shikigami.Telemetry.Metrics.ShikigamiMetrics.
machineSessions :: !(Gauge Int64)          -- shikigami.machine.sessions, unit {session}
machineCommands :: !(Counter Int64)        -- shikigami.machine.commands, attrs outcome, operation.class
machineReceipts :: !(Counter Int64)        -- shikigami.machine.receipts, attrs outcome
machineRefusals :: !(Counter Int64)        -- shikigami.machine.refusals, attrs refusal.kind, operation.class
machineDisconnectedAge :: !(Gauge Int64)   -- shikigami.machine.disconnected.age, unit s, attr machine.name

recordMachineSessions :: (MonadIO m) => ShikigamiMetrics -> Int64 -> m ()
recordMachineCommand :: (MonadIO m) => ShikigamiMetrics -> CommandState -> OperationClass -> m ()
recordMachineReceipt :: (MonadIO m) => ShikigamiMetrics -> ReceiptOutcome -> m ()
recordMachineRefusal :: (MonadIO m) => ShikigamiMetrics -> MachineRefusal -> OperationClass -> m ()
recordMachineDisconnectedAge :: (MonadIO m) => ShikigamiMetrics -> MachineName -> Int64 -> m ()
```

Attribute values are rendered from the closed sums by total functions (`commandStateText`, `operationClassText`, `refusalKindText`, which drops the `CeilingExceeded` payload and renders only `ceiling-exceeded`), so no identifier, path or error text can enter an attribute. The gateway from plan 119 records sessions on open and close and the disconnected age on each heartbeat sweep (one gauge record per enrolled machine, `0` while connected); the relay from plan 122 records commands on each state transition and receipts on settlement; the gateway records refusals from `Refused` receipts. Extend `shikigami-workers/test/Shikigami/TelemetrySpec.hs` with a case that uses the in-memory exporter to assert the instrument names, units and attribute keys, and that a refusal carrying a ceiling payload renders only the constant kind.

Write `docs/operations/machines.md` with these sections: what a machine daemon is and what stays on the machine; enrollment on both sides (`shikigami machines offer`, `shikigami-machine enroll`, `shikigami machines approve`, with the fingerprint comparison the operator performs out of band); the local policy file reference with the complete example from plan 120 and the rule that the central grant can never widen it; placement in `SHIKIGAMI_WORKSPACES` grants; what leaves a machine (receipts, artifact identities, bounded read, diff and output bytes under the 1 MiB ceiling, never the working tree); absence and partition behavior (queued commands, unresolved executions, local deadlines, pending fences, explicit base transfer); revocation; the inspection verbs with example output; and the metrics. Add two subsections to `docs/operations/configuration.md` for `SHIKIGAMI_MACHINE_GATEWAY` and `SHIKIGAMI_MACHINE` under "The settings" and the two new binaries under "Which binary needs what", stating that `shikigami-machine` requires `machine` only and refuses a database connection string. Add a capability entry `docs/capabilities/enrolled-machine-daemons.md` with the frontmatter the profile requires, `capabilityId` allocated with `okf id next docs/capabilities --profile docs/capabilities/profile.dhall CAP`, `packages: ["shikigami-core", "shikigami-workers", "shikigami-server"]`, `interface` naming `Shikigami.Machine.Protocol`, `Shikigami.Machine.Policy` and `Shikigami.Machine.Store`, `requires: [CAP-30]` for repository catalog admission plus the workspace capability ids plan 96 registered, and evidence entries pointing at the module files and this plan's evidence directory; run `just capabilities-validate` and `just capabilities-index`. Check `docs/architecture/packages.md`'s executable table carries both new binaries; add rows if plan 119 did not.

The milestone is accepted when the server, worker and core suites pass with the new cases, `just capabilities-validate`, `just haskell-conventions` and `just domain-value-types` pass, and `shikigami machines list --json` against a developer database with two seeded machines prints a page whose `machines` array has two entries and whose `next` is `null`.

### Milestone 2: The three-container harness and the smoke case

Write `tests/workspace/run-machines-apple.sh`, modelled on `tests/workspace/run-apple.sh` but with three guests. It accepts `--smoke` or `--qualify` and an optional runtime store path. It builds the runtime once: `nix build .#packages.aarch64-linux.shikigami-runtime` with the same flags `run-apple.sh` uses, and if plan 121 or 122 added a dedicated fixture attribute (for example `shikigami-machine-prototype` in `nix/qualification-package.nix`), that attribute instead; when the two-core build stalls, follow FRIC-21 and use the configured remote builder through `bash tests/workspace/build-apple.sh packages.aarch64-linux.<attribute>`. It then creates a dedicated network with a unique name, `container network create --subnet 10.137.<n>.0/24 shikigami-machines-<timestamp>-<pid>`, and starts three arm64 guests on it from the pinned `kindest/node` image with `/sbin/init` and `--network <name>`: `central`, `machine-a` and `machine-b`. Each guest gets its own generated SSH key authorized for `nix copy`, published on a distinct loopback port, with host-key verification as `run-apple.sh` does. No host directory is mounted and no existing host credential is used. The script copies the runtime closure to all three guests and copies only explicit fixture sources (`tests/workspace/run-machines-linux.sh`, `tests/workspace/fixture-oauth.py`, `tests/workspace/prototype-payload.c`, `nix/workspace-deadline.nix`, the fixture repository seed under `tests/workspace/machines/`) into `/var/lib/shikigami-machines-fixture-code`.

The in-guest driver `tests/workspace/run-machines-linux.sh` takes a role argument and the runtime path. In `central` it provisions PostgreSQL 18 as `run-linux.sh` does, runs `shikigami-migrate`, generates a TLS certificate and key for the gateway and prints the certificate's SHA-256 fingerprint to a file the host script reads, writes `SHIKIGAMI_MACHINE_GATEWAY`, `SHIKIGAMI_WORKSPACES` (two repositories sourced `OnMachines`, grants placing an upgrade agent on `machine-a` and an integration agent on `machine-b`), and the worker configuration, starts `shikigami-machine-gateway` and `shikigami-worker` as systemd units, and runs `shikigami machines offer` for both names, writing the one-time codes to files the host script carries to the machines. In `machine-a` and `machine-b` it creates the fixture repository object store from `tests/workspace/machines/fixture-repo.tar` (a bare repository with the approved base commit) under `/var/lib/shikigami-machine/repos`, writes the local policy (`machine-a` with `SystemdProcessPolicy` and the validation rule; `machine-b` with `NoProcessTools`), writes `SHIKIGAMI_MACHINE` with the gateway address and pinned fingerprint, runs `shikigami-machine enroll --code <code>`, and installs `shikigami-machine run` as a systemd service. Back in `central`, the driver runs `shikigami machines approve <name> --fingerprint <fp>` for each, where the fingerprint is read from `shikigami-machine status --json` on that machine; the host script compares it with the one `approve` prints, so both sides see the same value.

The smoke case then runs the plan 122 upgrade fixture: it enqueues an addressed run that admits a workspace on `machine-a`, replaces the dependency constraint, runs the validation rule and commits. While the validation command is in flight, the host script asks `machine-a` to sever: `iptables -I OUTPUT -d <gateway-ip> -p tcp --dport <gateway-port> -j DROP`, recorded in `severance.log` with a timestamp. The driver on `central` observes `shikigami machines inspect machine-a --json` reporting `Disconnected` within the heartbeat budget and the command in `Delivered` or `Unresolved`, never `Refused` or a failed execution; it then restores with `iptables -D OUTPUT ...`, observes `Connected`, and waits for the execution to finish with one commit. The smoke case passes when the run's terminal result carries exact repository, base and resulting commit identities, the commit exists in `machine-a`'s workspace object store, and `shikigami machines inspect machine-a --json` shows zero `Queued`, zero `Unresolved` and no pending fence.

On exit, as `run-apple.sh` does, the host script copies a bounded allowlist of evidence files from each guest (`enroll-*.log`, `approve-*.json`, `status-*.json`, `inspect-*.json`, `severance.log`, `case-*.json`, `case-*.log`, `public-metadata.jsonl`, at most 8 MiB per guest), stops the three guests, deletes the network, removes the generated keys, and prints the private task directory. A failed step still runs teardown. The harness budget is 45 minutes for `--smoke` and 90 minutes for `--qualify`, enforced by `timeout` around the in-guest driver; exceeding it is a failure.

The milestone is accepted when `bash tests/workspace/run-machines-apple.sh --smoke` exits 0, `container network list` and `container ls` show nothing left from the run, and the task directory holds the smoke evidence named above.

### Milestone 3: The nine-case matrix, evidence, request closure and ADR distillation

Extend the driver with the nine named cases below; `--qualify` runs them in order after enrollment and requires every one to print `PASS <name>` with a nonzero case count of nine. Each case writes `case-<n>.json` with its observations and `case-<n>.log` with bounded command transcripts.

Case 1, *fresh enrollment runs an authorized edit, validation and commit and returns exact artifacts*: the smoke flow without severance, asserting the central run result's `repository`, `base`, `commit`, `changedPaths` and validation statuses equal the identities read from `machine-a`'s object store.

Case 2, *a machine's local policy refuses a centrally allowed operation and a forged wider command alike*: the central grant for the integration agent on `machine-b` includes the process class, `machine-b`'s policy is `NoProcessTools`; a validation command is refused with `Refused (OutsidePolicy ProcessClass)` and the central command row shows `Refused`. Then a driver running on `central` with the gateway's own database credentials inserts a `Queued` command through plan 122's `enqueueCommandTx` naming a repository `machine-a` does not host, and another naming `ProcessClass` for `machine-b`; both are refused with `UnknownRepository` and `OutsidePolicy ProcessClass`, and no workspace directory changes on either machine (directory hashes before and after are equal).

Case 3, *a compromised runtime holding central credentials cannot read outside a repository, obtain a shell, or borrow an identity*: the same credentialed driver enqueues a `ReadFile` for `../../etc/hostname` and for a path outside the repository's read prefixes (refused `OutsidePolicy ReadClass`, no bytes returned); sends a raw frame over an authenticated gateway session with `"action": "shell"` (refused as malformed by `Machine.Protocol`'s decoder and logged as `MalformedCommand`); enqueues a command whose binding names `machine-a` but is routed to `machine-b`'s session (refused `WrongMachine`); and attempts a `Hello` from `machine-b` presenting `machine-a`'s fingerprint (the challenge fails because `machine-b` cannot sign with `machine-a`'s key, and the registry records no session for `machine-a`).

Case 4, *severance during a command settles locally and centrally once*: the smoke severance, held past the command's local deadline so that the daemon's absolute-deadline guard settles the process on `machine-a` while disconnected; the central execution shows `Unresolved` with a pending receipt and the command `Delivered`, never `Failed`; on restoration the receipt settles the attempt exactly once (`execution_attempts` shows one settled attempt and the commit count is one).

Case 5, *transfer during a partition fences the former machine*: sever `machine-a` during an assignment, run the transfer with an explicit base to `machine-b` through plan 122's partition transfer (`shikigami workers transfer ... --explicit-base <commit>` or the driver's equivalent), observe a `shikigami.machine_fences` row and the old commands `Superseded`; restore `machine-a`, observe the `Welcome` carried the fence (daemon `status --json` shows `appliedFences` incremented and `inspect` shows no pending fence), enqueue a stale edit under the old epoch and observe `Refused StaleEpoch`; and confirm the late receipt from the severed command settled only the old attempt while the assignment completed on `machine-b`'s workspace.

Case 6, *restart on each side of an accepted operation recovers from retained receipts*: during an accepted validation command, `systemctl kill -s KILL shikigami-machine` on `machine-a`, then `systemctl start`; the daemon reconciles the unit and invocation from its ledger and resends the retained receipt, which settles once. Then, in a second command, `systemctl kill -s KILL shikigami-worker` on `central` after the receipt is recorded but before the execution advances; after restart the execution completes with one commit and no second launch (process unit count on `machine-a` is one for that operation).

Case 7, *revocation refuses new commands and retries while uncertain outcomes stay inspectable*: with an `Unresolved` command on `machine-a` (severed), run `shikigami machines revoke machine-a`; restore the network; the daemon's `Hello` is refused and logged `MachineRevoked`; a new command for `machine-a` is refused at enqueue; the retried dispatch is refused; and `shikigami machines inspect machine-a --json` still lists the `Unresolved` command and the machine as `Revoked`.

Case 8, *an unqualified containment profile refuses process tools at admission*: `machine-b` reports the profile `UnqualifiedPlatform`; a grant placing an agent with the process overlay on `machine-b` is refused at central selection before any command is enqueued (the refusal reason is recorded in the execution's bounded diagnostics), and a directly enqueued `LaunchProcess` is refused on the machine with `UnqualifiedContainment`. Edits and Git operations on `machine-b` still succeed.

Case 9, *an uncommitted file is neither read nor sent*: before enrollment the driver plants `SECRET-MARKER-<random>` in an untracked file inside the fixture repository's working tree on `machine-a` (the object store the policy names has a working tree beside it); after cases 1 through 8, grep every captured frame log, every receipt, `public-metadata.jsonl`, the central database's protected payload references by digest, and the central run results for the marker; it must appear nowhere. A `ListFiles` on the workspace must not show the file.

Retain evidence under `docs/evidence/plan-123/`: `acceptance.md` mapping each IR-20 item to its case, the proof it retained and its exit code, in the style of `docs/evidence/plan-84/acceptance.md`; `multi-machine-qualification.json` with `caseCount: 9`, `cases`, `command`, `date`, `environment` (host, guest arch, container version, network subnet, PostgreSQL version, `hostMounts: false`, `existingHostCredentials: false`), `exitCode`, the two machines' fingerprints and policy revisions, the redacted fence and receipt coordinates for cases 4 through 6, and the severance timestamps; and `host-qualification.json` recording the host suite commands and exit codes. Every evidence file stays under 256 KiB and contains no key material, enrollment code, marker or path outside the fixture prefix; the driver's redaction step is itself a check.

Close the request: set `status: completed`, `completedAt`, `resolution` (one sentence naming the nine passing cases and this plan) and `targetPlan: docs/plans/123-...` in `docs/improvement-requests/execute-governed-work-through-machine-daemons.md`, replace its Status paragraph, add a dated `**Completion**` line to `docs/improvement-requests/log.md`, and run `just improvement-requests-validate` and `just improvement-requests-index`. Update MasterPlan 21: mark EP-5 Complete in the registry, record the three cross-plan gates as checked in Progress with evidence paths, and fill Outcomes & Retrospective.

Distill the initiative's decisions into ADRs, one file each, numbered after the highest existing `docs/adr/` number at implementation time and following the existing plain-Markdown form: the daemon is a physical executor with no durable bookkeeping or central credential; machine identity is a machine-held Ed25519 key authenticated per session over a pinned TLS gateway, with two-sided enrollment and registry revocation; local policy is the enforcement point and every command is bound to machine, workspace, assignment, epoch, operation and attempt; absence is a durable queued state, a timeout is never a failure, and a partition transfer starts a new workspace on an explicit base with a pending fence applied first on reconnection; each platform declares its containment profile and an unqualified platform refuses process operations at both admission points; and the daemon binary lives in `shikigami-workers` as a recorded weight cost. Where plans 119 through 122 already created an ADR for one of these, amend it rather than duplicating. Each ADR cites this plan's evidence directory. Triage the friction entries recorded under plans 119 through 123, cite them in Outcomes & Retrospective, and record recurring surfaces in MasterPlan 21's Surprises & Discoveries.


## Concrete Steps

Run every command from the repository root. Verify dependency sources and released versions through Mori before changing any bound; this plan adds no dependency.

Milestone 1 commands:

```bash
nix develop --no-write-lock-file -c cabal build shikigami-core shikigami-server shikigami-workers
nix develop --no-write-lock-file -c cabal test shikigami-server-test --test-options='-p Machines' --test-show-details=direct
nix develop --no-write-lock-file -c cabal test shikigami-workers-test --test-options='-p "Machine|Telemetry"' --test-show-details=direct
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test --test-options='-p Machine --num-threads 1' --test-show-details=direct
okf id next docs/capabilities --profile docs/capabilities/profile.dhall CAP
just capabilities-validate
just capabilities-index
just haskell-conventions
just domain-value-types
```

Expected: each suite reports a nonzero count of selected cases and `All N tests passed`; `okf id next` prints the next `CAP-` handle to use in the new entry; the `just` recipes exit 0. A run of the list verb against a seeded developer database looks like:

```text
$ shikigami machines list --json | jq '.machines | length, .next'
2
null
$ shikigami machines inspect machine-a --fail-when-disconnected 10m --json >/dev/null; echo $?
0
```

Milestone 2 and 3 commands:

```bash
container network create --help
bash tests/workspace/run-machines-apple.sh --smoke
bash tests/workspace/run-machines-apple.sh --qualify
container network list
container ls
```

Expected for `--qualify`:

```text
PASS enrollment runs an authorized edit, validation and commit with exact artifacts
PASS local policy refuses a centrally allowed operation and a forged wider command
PASS compromised runtime cannot read outside, obtain a shell, or borrow an identity
PASS severance settles under the local deadline and reconnection settles once
PASS partition transfer fences the former machine and its late results
PASS daemon and central worker restarts recover from retained receipts
PASS revocation refuses new commands and retries while uncertain outcomes remain inspectable
PASS unqualified containment refuses process tools at admission
PASS an uncommitted file is neither read nor sent
Cases: 9/9
Private fixture evidence: /tmp/shikigami-machines-run.XXXXXX
```

`container network list` and `container ls` afterwards show no `shikigami-machines-*` entries. Closure commands:

```bash
just improvement-requests-validate
just improvement-requests-index
nix develop --no-write-lock-file -c cabal test all --test-options=-j2 --test-show-details=direct </dev/null
just keiro-gate
git diff --check
```

`just keiro-gate` must report no declared-body change; this plan edits no workflow body. Every commit carries `MasterPlan: docs/masterplans/21-execute-governed-work-through-enrolled-machine-daemons.md`, `ExecPlan: docs/plans/123-make-machines-observable-to-operators-and-qualify-ir-20-across-severable-machines.md` and `Intention: intention_01m6m0b6zxebfv3yatcy7fvbgk` trailers.


## Validation and Acceptance

Required acceptance for Milestone 1: `shikigami machines list --json` returns at most the requested limit (default 32, maximum 64; `--limit 65` is refused at parse time with exit 64), pages with `--after`, and contains no `operation`, `receipt`, `policy` or `publicKey` key anywhere in its output; `shikigami machines inspect <name> --json` includes `commands` with all six `CommandState` keys present as integers, `pendingFences` as an array, and `oldestUnresolved` as an RFC 3339 string or `null`; an unknown name exits 1; `--fail-when-disconnected 1s` exits 2 for a `NeverConnected` fixture and 0 for a `Connected` fixture; `shikigami-machine status --json` on a fixture ledger contains exactly the keys `fingerprint`, `gatewayPin`, `connection`, `policyRevision`, `containment` and `ledger`, and the string `BEGIN PRIVATE KEY` appears nowhere in the output; the in-memory exporter observes the five instrument names with the stated units and attribute keys and no attribute value longer than 64 characters; `just capabilities-validate --strict` through the recipe passes with the new entry; `curl /health/ready` and `/health/live` on a server with a disconnected machine still return 200.

Required acceptance for Milestone 2: the smoke run exits 0 within 45 minutes; the host and the two machines agree on both fingerprints (the value printed by `approve` equals the value in `status-<machine>.json`); `severance.log` records a sever and a restore with the inspect output between them reporting `Disconnected`; and teardown leaves no container or network behind.

Required acceptance for Milestone 3: all nine `PASS` lines, `Cases: 9/9`, exit 0 within 90 minutes; every evidence file under `docs/evidence/plan-123/` is under 256 KiB and free of key material, enrollment codes, the case 9 marker and any absolute path outside `/var/lib/shikigami-machine` or `/var/lib/shikigami-machines-fixture-code`; the IR bundle validates; `cabal test all` passes; and each of the six ADRs exists with Context, Decision, Alternatives rejected, Consequences and References.

The uncertain interaction this plan exercises first is the fingerprint handoff across guests (case 1's enrollment): run the enrollment portion of `--smoke` before writing any later case, because every case depends on both machines being `Enrolled`. The host-only suites, the single-guest `run-apple.sh` matrix and the PostgreSQL fake-daemon cases from plan 122 are supporting evidence; only the multi-machine `--qualify` run qualifies IR-20. Adding an amd64 variant, a fourth machine, or a macOS daemon guest is additional scope, not required acceptance.


## Idempotence and Recovery

Every verb in this plan is read-only against the central database and the daemon ledger; running them repeatedly changes nothing. The harness is safe to rerun: it names its network and containers with a timestamp and process id, refuses to start if a network with its exact name exists, and tears down on every exit path including `TERM` and `INT`, with the teardown itself tolerant of a guest that already stopped. If a run is interrupted hard enough to leave containers or a network behind, `container ls`, `container stop <name>`, `container network list` and `container network delete <name>` remove them; the task directory under `/tmp` holds whatever evidence was copied and may be deleted. Guest state never touches host state: there are no mounts and no host credentials, and the generated SSH keys are removed in teardown.

The firewall severance is applied with `iptables -I` and removed with the matching `iptables -D`; the in-guest driver records both and, on any failure after a sever, runs the delete rule before exiting so a guest is never left partitioned while another case runs. Case 7 revokes `machine-a`; the harness provisions a fresh machine name for any later case that needs an enrolled machine rather than attempting to un-revoke (revocation is terminal by plan 119's store contract). Evidence writing is idempotent: the host script overwrites the task directory's copies, and the committed files under `docs/evidence/plan-123/` are replaced wholesale by the final run. If the IR frontmatter update fails validation, revert the single file with `git checkout -- docs/improvement-requests/execute-governed-work-through-machine-daemons.md` and reapply; `just improvement-requests-index` regenerates `index.md` from scratch each time.


## Interfaces and Dependencies

Prerequisites declared by MasterPlan 21: plan 121 (EP-3) and plan 122 (EP-4) must be Complete before this plan starts, which implies plans 119 (EP-1) and 120 (EP-2). This plan consumes, without changing: `Shikigami.Machine.Types` (`MachineId`, `MachineName`, `KeyFingerprint`, `MachineStatus`, `Platform`, `ContainmentProfile`, `PolicyRevision`, `ConnectionState`, `OperationClass`, `MachineRefusal`) and `Shikigami.Machine.Protocol` (`CommandEnvelope`, `ReceiptEnvelope`, `MachineOutcome`, the frames) from plan 119; `Shikigami.Machine.Policy` (`LocalPolicy`, `policyRevision`) and the daemon ledger's `recoverLedger` from plan 120; the daemon's `Hello` platform and profile declaration and the physical host from plan 121; and `CommandState`, `shikigami.machine_commands`, `shikigami.machine_fences`, `enqueueCommandTx`, `Placement` and the partition transfer from plan 122. It adds `inspectMachinePageTx`, `inspectMachineDetailTx`, `MachinePageLimit`, `MachinePage`, `MachineDetail`, `PlacementView` and `PendingFenceView` to `shikigami-core/src/Shikigami/Machine/Store.hs`; `runMachinesList` and `runMachinesInspect` to `shikigami-server/src/Shikigami/Server/Command/Machines.hs`; `Shikigami.Machine.Status` with `DaemonStatus` and `LedgerCounts` to `shikigami-workers`; five instruments and their `record*` functions to `shikigami-core/src/Shikigami/Telemetry/Metrics.hs`; `tests/workspace/run-machines-apple.sh`, `tests/workspace/run-machines-linux.sh` and `tests/workspace/machines/`; `docs/operations/machines.md`; `docs/capabilities/enrolled-machine-daemons.md`; `docs/evidence/plan-123/`; and the new ADRs.

No new library dependency is introduced. The operator verbs use `optparse-applicative`, `aeson` and `hasql-transaction` as the existing command modules do; metrics use `hs-opentelemetry-api` through the existing `Metrics` module; the harness uses the Apple `container` CLI at version 1.5.0 or later with `container network` support, `nix`, `ssh`, `jq`, `python3` and `tar` on the host, and `iptables`, `systemd`, `git`, `postgresql` and `jq` in the pinned guest image. `Shikigami.Duration` supplies the scoped `Duration "machine-disconnected"`. If a later plan changes the closed `CommandState` or `MachineRefusal` sums, the detail view's `commands` map and the metric attribute renderers must be updated in the same change, and MasterPlan 21's Integration Points record the change first.
