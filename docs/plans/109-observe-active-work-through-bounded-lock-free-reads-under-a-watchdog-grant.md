---
id: 109
slug: observe-active-work-through-bounded-lock-free-reads-under-a-watchdog-grant
title: "Observe active work through bounded lock-free reads under a watchdog grant"
kind: exec-plan
created_at: 2026-11-04T15:58:26Z
intention: "intention_01m6kkgpehed8r75hazq4y7qqj"
master_plan: "docs/masterplans/19-supervise-active-work-with-an-independent-watchdog-agent.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-11-04T15:58:26Z
---

# Observe active work through bounded lock-free reads under a watchdog grant

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Today nothing in Shikigami can look at all the work that is currently active without taking the locks the real writers take. The objective store's `read` and `inspect` lock the objective row, the resource store locks the root, the process store locks the process row, and no function enumerates executions, roots or pending approvals at all. A supervisor that polled those functions would contend with the coordinators and workers it is meant to watch.

After this plan, one function, `Shikigami.Watchdog.Observation.observePage`, returns a bounded page of structured facts about the active population: open objectives and their coordinators, worker sessions that are active, parked or unresolved, executions that are active, parked or unresolved, the roots they draw on, the unsettled workspace commands they are running, and the approvals and tool permissions they are waiting for. Every fact is a reference, a revision, a cursor, a phase or an absolute deadline. No instruction, result, transcript or payload body is ever read. The page is produced inside one read-only transaction with a statement timeout, takes no row locks, and advances a coverage cursor so that successive pages walk the whole population and start over. Access requires an `ObservationGrant`, a read-only authority that only the configured watchdog principal can hold and that grants no command permission.

You can see it working in the PostgreSQL suite: `cabal test shikigami-core-postgres-test --test-options='-p Watchdog'` builds a fixture population, holds `FOR UPDATE` locks on an objective and a session from a second connection, and shows that the page still completes within its timeout and contains both subjects, with no body text anywhere in its JSON. This plan is EP-1 of [MasterPlan 19](../masterplans/19-supervise-active-work-with-an-independent-watchdog-agent.md); the classifier (plan 110), the drift decision (plan 111) and the watchdog agent (plan 112) all build on the types and reads defined here.


## Progress

- [ ] Milestone 1: The watchdog vocabulary, settings and grant exist in `shikigami-core`, the `Watchdog` module root is admitted by the module policy, and `just haskell-conventions`, `just domain-value-types` and `cabal test shikigami-core-test` pass with the new value and codec cases.
- [ ] Milestone 2: Lock-free observation reads exist for objectives, coordinators, sessions and executions, `observePage` composes them, and the PostgreSQL contention case completes under competing `FOR UPDATE` locks with both subjects present and no body fields.
- [ ] Milestone 3: Roots, unsettled processes, tool permissions and pending approval timers are attached as waiting facts, the coverage cursor wraps around the population, and bounds, refusals and corruption cases are covered in the PostgreSQL suite.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Owner verticals expose their own lock-free observation reads; the watchdog composes them and never writes SQL against another vertical's tables.
  Rationale: The vertical-slice standard keeps SQL and decoders with the concept that owns the table, and the owners already have the decoders that refuse corrupt stored JSON inside the transaction. A watchdog-side query over `shikigami.objectives` would duplicate the decoder and silently diverge from the owner.
  Date: 2026-11-04

- Decision: The sealed `Finding` value is not defined here. This plan defines `FindingView`, `EvidenceRef`, `DetectionKind`, `ObservedWindow` and the other shared vocabulary; plan 110 defines and alone mints `Finding`.
  Rationale: A private seal belongs in the module that validates it (ADR 0081). Minting happens in the episode ledger, so the seal lives there.
  Date: 2026-11-04


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a Cabal multi-package Haskell service. `shikigami-core` owns domain behavior and store adapters, `shikigami-workers` owns long-running loops, `shikigami-server` owns operator commands and the HTTP server, and `shikigami-migrations` owns append-only SQL migrations and the `test-support` sublibrary that gives every test an isolated migrated database. Module names express concepts (`Shikigami.Objective.*`, `Shikigami.WorkerSession.*`); packages express runtime roles. The repository's `AGENTS.md` and `docs/architecture/packages.md` describe this, and `tools/style/module-ownership.json` lists every concept root and composition module; `just haskell-conventions` fails on a module that is not under a listed root. This plan adds the root `Watchdog` to `domainRoots` with a rationale comment in the same change, as [ADR 0075](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md) requires.

A *subject* is one unit of active work the watchdog observes. There are three kinds. A *worker session* is a continuing worker's durable mailbox (`shikigami-core/src/Shikigami/WorkerSession/Types.hs`): `SessionState` carries `phase :: SessionPhase` (`Idle | Active | Parked | Unresolved | Transferring | Failed | Cancelled`), `revision :: StateRevision "worker-session"`, `eventCursor` and `consumedCursor :: StateRevision "worker-event"`, `nextSequence :: StateRevision "worker-message"`, `epoch :: StateRevision "worker-owner"` and `activeAssignment`; `SessionBinding` carries `objective :: ObjectiveRef`, `rootId` and `parentIdentity`. An *execution* is one durable Skill execution (`shikigami-core/src/Shikigami/Execution/Transcript.hs`): `ExecutionState` carries `phase :: ExecutionPhase` (`Active | Parked | Unresolved | Succeeded | Failed | Cancelled`), `revision :: StateRevision "execution"`, `cursor :: StateRevision "execution-operation"`, `activeOperation` and `pendingReceipts`; each `Operation` carries `uncertain :: OperationUncertainty` (`NotMarkedUncertain | MarkedUncertain`, [ADR 0091](../adr/0091-operation-uncertainty-and-call-ordinals-retain-their-meanings.md)) and an optional `permission :: PermissionBinding` whose `expiresAt :: UTCTime` is the one durable absolute deadline for a parked tool permission. An *objective coordinator* is the agent holding the `Coordinator` role on an open objective (`shikigami-core/src/Shikigami/Objective/Types.hs`: `Objective` with `status :: Status`, `revision :: StateRevision "objective"`, `instructionsRevision`, `criteriaRevision`, `members :: [Member]`, `assignments`, `unresolved :: [UnresolvedOperation]`, `criteria`, `goal`). A coordinator's durable traces are in `shikigami-core/src/Shikigami/Coordination/Sql.hs`: `adaptive_decisions` rows (an accepted decision at an objective revision, valid only when joined to `objective_receipts`), `adaptive_observations` rows of kind `refusal` or `terminal`, and `adaptive_checkpoint_listeners` rows whose listener JSON carries `after :: StateRevision "objective"`; [ADR 0108](../adr/0108-adaptive-decisions-commit-with-authoritative-checkpoints.md) and [ADR 0111](../adr/0111-adaptive-delivery-carries-native-admission-and-reference-only-seeds.md) explain them. A coordinator that is waiting has a listener row; one that has finished has a `terminal` observation; one that is deciding has only workflow journal state.

An *activity mark* is the tuple of owner revisions and cursors that advance only when work is accepted. The watchdog compares a subject's mark across its own sweeps, because almost no owner table records wall-clock time: only `shikigami.objectives`, `shikigami.worker_sessions` and `shikigami.executions` have `updated_at`, and the first two are written with `clock_timestamp()` while the third uses `now()`. Messages, events, decisions, attempts and processes carry revisions and cursors only. `updated_at` may be included in an observation as a hint but is never used as authority.

The reads that exist today and their locking: `Objective.Store.read` and `inspect` lock the objective row `FOR UPDATE` through `lockObjective`; `listObjectives` takes `FOR SHARE` and requires an `Access` from `Objective.Capability.admitObjectiveAction`; `Execution.ResourcesStore.inspectRoot` and `inspectRootTx` lock the root; `Workspace.ProcessStore.inspectProcessTx` locks the process row. Lock-free today are `WorkerSession.Store.inspectSession`, `inspectSessionPage`, `readEvents` and `Execution.Store.inspectExecution`, `inspectExecutionTx`, `inspectExecutionPage`, `inspectOperation`. Enumerators are `listObjectives`, `ProcessStore.inspectProcessPageTx` (64 rows, includes settled) and the per-root `rootSessionsSettledTx` and `rootExecutionsSettledTx`; nothing lists all sessions, executions, roots or approvals. Tables: `shikigami.objectives(objective_id, state jsonb, updated_at)`, `objective_assignments`, `objective_cursors(objective_id, assignment_id, session_id, cursor)`, `objective_associations(kind, source_id, objective_id, binding)` (where a `BindConversation` binding lives), `worker_sessions(session_id, scope_digest, state, binding, updated_at)`, `worker_session_messages`, `worker_session_events`, `executions(execution_id, state, binding, updated_at)`, `execution_transcript_operations(execution_id, operation_id, position, state, dispatches)`, `execution_roots(root_id, state)`, `workspace_processes(operation_id, resource, fingerprint, record, settled)` with the partial index `workspace_unsettled_processes WHERE NOT settled`, `adaptive_decisions`, `adaptive_observations`, `adaptive_checkpoint_listeners`.

Pending human approvals have no Shikigami table. [ADR 0030](../adr/0030-an-approval-request-is-a-durable-child-workflow.md) makes each one a `shikigami.approval` child workflow whose id is the `ReviewRequestId`, with a Keiro timer of kind `shikigami.approval-timeout` whose absolute `fireAt` is the deadline (`shikigami-core/src/Shikigami/Agent/Approval.hs`, `armApprovalDeadline`). Those timers and workflow headers are readable through Keiro's public read API; the inspection host in `shikigami-core/inspection/Shikigami/Inspection/Catalog.hs` and `Runtime.hs` already mounts the pending-timer and workflow-header reads (`keiro/timer/pending/list`, `keiro/wf/inspect/header`). Resolve the exact public functions through Mori (`mori registry show shinzui/keiro --full`, package `mori://shinzui/keiro/packages/keiro`) and call them; never query Keiro's private tables. A workspace command's absolute deadline is `ProcessRecord.deadline` (`shikigami-core/src/Shikigami/Workspace/Process.hs`), set by the supervisor as the earlier of the root cutoff and launch time plus `timeoutSeconds`; a command is within its deadline while `phase` is `ProcessLaunchRequested` or `ProcessRunning` and the deadline is in the future. A root's control facts are `Root {envelope :: Envelope {limits, cutoff}, revision, cancelled :: Cancellation, overage :: Overage, active, unknown, usage}` in `shikigami-core/src/Shikigami/Execution/Resources.hs` ([ADR 0051](../adr/0051-resource-roots-own-conservative-reservations-and-actual-attempts.md), [ADR 0082](../adr/0082-root-control-decisions-and-execution-termination-have-distinct-types.md)).

Which objective metadata is safe to expose without a membership check is settled by [ADR 0070](../adr/0070-objective-receipts-and-integrated-acceptance-share-one-command-owner.md): inspection pages goal, criterion, assignment and evidence-reference metadata and excludes instructions and result bodies. This plan follows the same line: goal text and criterion descriptions are observation facts; assignment instructions, worker inputs and outputs, transcripts and payloads are not.

Value and record rules every new type follows: [ADR 0080](../adr/0080-opaque-checked-values-do-not-expose-generic-construction.md) (no `Generic` on opaque checked values; private constructors; checked parsers), [ADR 0081](../adr/0081-validated-results-use-private-seals-and-public-read-views.md) (sealed results with public read views), [ADR 0091](../adr/0091-operation-uncertainty-and-call-ordinals-retain-their-meanings.md) (closed sums instead of booleans; scoped counters), [ADR 0094](../adr/0094-accounting-entities-use-allocated-identities-and-root-origin-receipts.md) (allocated identities are private `KindID` UUIDv7 values with full singular prefixes), the shared `Shikigami.Duration` (`Duration (scope :: Symbol)`, `parseDuration`, `durationTime`) and `Shikigami.StateRevision` (`StateRevision (scope :: Symbol)`, `type role ... nominal`), and the house record style in `docs/architecture/packages.md` rule 4 and [the record patterns](mori://shinzui/haskell-jitsurei/docs/core-record-patterns): unprefixed strict fields under `DuplicateRecordFields` and `NoFieldSelectors`, `OverloadedRecordDot` reads, explicit deriving strategies, and a local `import Data.Generics.Labels ()` where `#field` lenses are used. The compiler-client controls in `tests/types/opaque-values.py` (run by `just domain-value-types`) are how the repository proves a value cannot be constructed generically; this plan adds its own probe file in that style. The cross-repository scalar standard is [the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids).

Settings: process configuration is declared once in `shikigami-core/src/Shikigami/App/Config.hs` and loaded by `App/Config/Load.hs` through Settei. The optional objective settings object (`SHIKIGAMI_OBJECTIVES`, delivered by plan 98) and the inspection settings (`shikigami-core/src/Shikigami/Inspection/Settings.hs`, whose every limit is an `InspectionLimit "name"` in 1..16777216) are the models to copy. Tests: `shikigami-core/test/Main.hs` registers unit groups, `shikigami-core/test-postgres/Main.hs` registers PostgreSQL groups under `Shikigami.Migrations.TestSupport.withShikigamiMigratedSuite`; every new spec module is added to the suite's `other-modules` in `shikigami-core/shikigami-core.cabal`. The suites use tasty and tasty-hunit only. PostgreSQL suites have exhausted fixture connections when run with default parallelism (friction entries FRIC-2, FRIC-5, FRIC-17 and FRIC-51 in `docs/friction-log/`); run them with `--test-options='--num-threads 1'` when that recurs.


## Plan of Work

### Milestone 1: Vocabulary, settings and grant

Create `shikigami-core/src/Shikigami/Watchdog/Types.hs`. It owns the shared vocabulary that plans 110 through 113 consume and must not import from any of them. Allocated identities are private newtypes with checked parsers and explicit renderers, no `Generic`, no `IsString`, and `KindID` prefixes `shikigami_watchdog_sweep`, `shikigami_watchdog_episode` and `shikigami_watchdog_finding`; follow the shape of the execution root identity introduced by [ADR 0094](../adr/0094-accounting-entities-use-allocated-identities-and-root-origin-receipts.md) (grep `shikigami_execution_root` for the pattern), including `parseSweepId :: Text -> Either Text SweepId`, `sweepIdText`, and a `newSweepId :: IO SweepId` that mints UUIDv7. The subject, its storage key and its activity mark look like this:

```haskell
data Subject
  = ObjectiveCoordinator !ObjectiveId
  | WorkerSession !WorkerSessionId
  | Execution !ExecutionId
  deriving stock (Eq, Ord, Show)

-- | Stable storage rendering of a subject: a versioned, prefixed text such as
-- @coordinator/1/<objective id>@. Private; parsed back by 'parseSubjectKey'.
newtype SubjectKey = SubjectKey Text
  deriving stock (Eq, Ord, Show)

subjectKey :: Subject -> SubjectKey
parseSubjectKey :: Text -> Either Text Subject

data SessionActivity = SessionActivity
  { revision :: !(StateRevision "worker-session")
  , eventCursor :: !(StateRevision "worker-event")
  , consumedCursor :: !(StateRevision "worker-event")
  , nextSequence :: !(StateRevision "worker-message")
  , epoch :: !(StateRevision "worker-owner")
  , phase :: !SessionPhase
  , assignmentPhase :: !(Maybe AssignmentPhase)
  }
  deriving stock (Eq, Show, Generic)

data ExecutionActivity = ExecutionActivity
  { revision :: !(StateRevision "execution")
  , cursor :: !(StateRevision "execution-operation")
  , phase :: !ExecutionPhase
  , activeOperation :: !(Maybe (StateRevision "execution-operation"))
  , uncertainOperations :: !Word
  , pendingReceipts :: !PendingReceiptCount
  }
  deriving stock (Eq, Show, Generic)

data CoordinatorActivity = CoordinatorActivity
  { status :: !Status
  , revision :: !(StateRevision "objective")
  , latestDecision :: !(Maybe (StateRevision "objective"))
  , listener :: !(Maybe (StateRevision "objective"))
  , integratedCursors :: !Word
  , terminal :: !CoordinatorTerminal
  }
  deriving stock (Eq, Show, Generic)

data ActivityMark
  = SessionMark !SessionActivity
  | ExecutionMark !ExecutionActivity
  | CoordinatorMark !CoordinatorActivity
  deriving stock (Eq, Show)

newtype MarkDigest = MarkDigest Text
  deriving stock (Eq, Ord, Show)

-- | SHA-256 over the canonical JSON object @{"v":"shikigami.watchdog-mark/1", ...}@.
markDigest :: ActivityMark -> MarkDigest
```

`CoordinatorTerminal` is a closed sum (`CoordinatorOpen | CoordinatorTerminal`), not a `Bool`. `WaitingReason` has exactly five constructors: `AwaitingApproval {until, review}`, `AwaitingPermission {until}`, `RunningCommand {until, operationId}`, `ParkedAssignment {since}` and `ObjectiveBlocked` (an objective whose `status` is `Blocked` was marked so by an explicit `SetBlocked` command and is waiting on purpose). `Verdict`, `DetectionKind`, `EvidenceRef`, `ObservedWindow` and `ObservationLimit` are closed sums or small records with explicit JSON codecs; `EvidenceRef` constructors carry only structured coordinates (an `ObjectiveId` with a `StateRevision "objective"`, an `ObjectiveAssignmentId` with its revision and owner epoch, a `WorkerSessionId` with a `StateRevision "worker-event"`, an `ExecutionId` with a `StateRevision "execution-operation"`, an `OperationId` for an adaptive decision or a process, an `ExecutionRootId` with a `StateRevision "execution-root"`, a `ReviewRequestId`). `FindingView` is an ordinary `Generic` record with an explicit object codec and the fields the request names: finding, episode and sweep identities, optional objective, subject, detection kind, non-empty evidence, observed window and observation limit. Windows are `Duration "watchdog-stuck"`, `Duration "watchdog-parked"`, `Duration "watchdog-coordinator"` and `Duration "watchdog-drift"`; limits are a new `WatchdogLimit (scope :: Symbol)` positive bounded `Int` modelled on `InspectionLimit`, with `parseWatchdogLimit` and `limitValue`.

Add `WatchdogSettings` to `shikigami-core/src/Shikigami/App/Config.hs` and its loader as an optional object under the key `watchdog` (environment binding `SHIKIGAMI_WATCHDOG`) with fields `principal` (an `AgentPrincipal`, or an agent name in directory-disabled mode, mirroring how the objective settings name a local operator), `scope` (`all`, or an object with a non-empty `objectives` list), `stuckWindowSeconds`, `parkedWindowSeconds`, `coordinatorWindowSeconds` and `subjectsPerSweep`. Plans 111 and 112 add fields to this record additively. Invalid or nonpositive values fail configuration with the key named, like every other settings object; omission leaves the field `Nothing`, which means the watchdog is disabled. Settei diagnostics must redact nothing here because the object holds no secret, but confirm `--describe-config` renders it.

Create `shikigami-core/src/Shikigami/Watchdog/Grant.hs` with the sealed grant:

```haskell
data ObservationScope = AllObjectives | SelectedObjectives !(NonEmpty ObjectiveId)

-- | Read authority for one sweep. Private constructor; no JSON decoder.
data ObservationGrant

resolveObservationGrant
  :: WatchdogSettings -> AgentIdentity -> Either GrantRefusal ObservationGrant

grantScope :: ObservationGrant -> ObservationScope
grantWindows :: ObservationGrant -> Windows
grantBudget :: ObservationGrant -> WatchdogLimit "subjects"

-- | The journalable, principal-free part of a grant: scope, windows and budget.
-- A durable sweep records this once and restores the grant on replay.
data GrantSnapshot

snapshotGrant :: ObservationGrant -> GrantSnapshot
restoreGrant :: GrantSnapshot -> AgentIdentity -> WatchdogSettings -> Either GrantRefusal ObservationGrant
```

`GrantSnapshot` is an ordinary `Generic` record with an explicit object codec; `restoreGrant` rebuilds the sealed grant from the snapshot's scope, windows and budget and rechecks only that the identity is still the configured watchdog principal, so a sweep that replays after a settings change keeps the windows it was admitted with, in the manner of the run-local policy snapshots of [ADR 0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md). `GrantRefusal` is a closed sum (`NotTheWatchdogPrincipal`, `WatchdogDisabled`, `UnresolvedIdentity`). A `CompatibilityIdentity` is accepted only when the settings name an agent name rather than a principal, exactly as [ADR 0033](../adr/0033-recorded-agent-principals-key-durable-state.md) separates the two modes; an `UnresolvedLegacyIdentity` is always refused.

Add `Watchdog` to `domainRoots` in `tools/style/module-ownership.json`. Add `tests/types/watchdog-values.py` beside `opaque-values.py`: a positive client that uses the public parsers and view codecs, then negative clients proving that `SweepId`, `EpisodeId`, `FindingId`, `MarkDigest`, `SubjectKey` and `ObservationGrant` cannot be constructed through a constructor, `coerce`, record update or `Generic`. Register it in the `domain-value-types` recipe in the `justfile`. Register the new modules in `shikigami-core.cabal` `exposed-modules`, add `shikigami-core/test/Shikigami/WatchdogTypesSpec.hs` (codec round trips, parser refusals, `markDigest` stability against a recorded golden digest, `subjectKey` round trip, settings loading and refusals) and list it in the unit suite's `other-modules`.

### Milestone 2: Lock-free owner reads and the composed page

Add one additive read to each owner, returning an owner-defined observation record defined beside the owner's existing views. Each is a `Hasql.Transaction.Transaction` value (or the owner's existing `Eff` read shape where the sibling functions use it), uses a plain `SELECT` with a keyset condition on the primary key and an explicit limit, never `FOR UPDATE` or `FOR SHARE`, decodes stored JSON through the owner's existing decoders, and refuses corruption with the owner's existing error inside the transaction (the rule [ADR 0107](../adr/0107-profile-and-objective-corruption-refuses-within-the-owning-transaction.md) records for objectives). Record types carry no bodies:

```haskell
-- Shikigami.Objective.Store
observeOpenObjectives
  :: Maybe ObjectiveId -> Int -> Transaction (Either ObjectiveError [ObjectiveObservation])

-- Shikigami.WorkerSession.Store
observeOpenSessions
  :: Maybe WorkerSessionId -> Int -> Transaction (Either SessionError [SessionObservation])
observeSessionsFor
  :: NonEmpty WorkerSessionId -> Transaction (Either SessionError [SessionObservation])

-- Shikigami.Execution.Store
observeOpenExecutions
  :: Maybe ExecutionId -> Int -> Transaction (Either ExecutionError [ExecutionObservation])

-- Shikigami.Coordination.Sql
observeCoordinators
  :: NonEmpty ObjectiveId -> Transaction (Either ObjectiveError [CoordinatorObservation])
```

`ObjectiveObservation` (define it in `shikigami-core/src/Shikigami/Objective/Inspection.hs` beside `ObjectiveView`) carries the objective id, status, the three revisions, the coordinator members' identities, the goal, the criteria metadata (`key`, `description`, `kind`, `journeyRequired`), the assignment observations (assignment id, owner identity, state, revision, owner epoch, session id, root id, cutoff), the unresolved operation count, the bound conversation reference if any, the integrated cursor count from `objective_cursors`, and `updated_at` as a hint. `SessionObservation` (in `WorkerSession/Types.hs` or a new `WorkerSession/Observation.hs` under the owner) carries the session id, the `SessionActivity` fields, the objective reference, root id, parent identity, the active assignment's child workflow id and execution id when present, and `updated_at`. `ExecutionObservation` carries the execution id, the `ExecutionActivity` fields, the root id, the parked permission's `expiresAt` and resolution when the phase is `Parked`, counts of `MarkedUncertain` operations and of attempts in `AttemptUncertain` or `DispatchStarted` past `expiresAt`, and the operation ids of operations whose specification is a workspace command (so milestone 3 can join processes). `CoordinatorObservation` carries the objective id, the latest accepted decision's operation id and revision, the listener's generation and `after` revision if any, and whether a `terminal` observation exists. Open means: objectives with `status` in `Open` or `Blocked`; sessions with phase `Active`, `Parked`, `Unresolved` or `Transferring`; executions with phase `Active`, `Parked` or `Unresolved`. Filtering on JSON fields must use the owners' existing expression indexes or the state columns the owners already index; add an expression index in a migration only if `EXPLAIN` shows a sequential scan over the whole table, and record that decision.

Create `shikigami-core/src/Shikigami/Watchdog/Observation.hs`:

```haskell
data CoverageCursor = CoverageCursor
  { objectives :: !(Maybe ObjectiveId)
  , sessions :: !(Maybe WorkerSessionId)
  , executions :: !(Maybe ExecutionId)
  }
  deriving stock (Eq, Show, Generic)

data SubjectObservation = SubjectObservation
  { subject :: !Subject
  , objective :: !(Maybe ObjectiveId)
  , mark :: !ActivityMark
  , waits :: ![WaitingFact]
  , evidence :: !(NonEmpty EvidenceRef)
  }
  deriving stock (Eq, Show, Generic)

data ObservationPage = ObservationPage
  { observedAt :: !UTCTime
  , cursor :: !CoverageCursor
  , passCompleted :: !PassCompletion
  , subjects :: ![SubjectObservation]
  , refusals :: ![ObservationRefusal]
  }
  deriving stock (Eq, Show, Generic)

observePage
  :: ObservationEffects es
  => ObservationGrant -> ObservationBounds -> CoverageCursor -> Eff es (Either ObservationError ObservationPage)
```

`ObservationBounds` carries the statement timeout and lock timeout as `Duration "watchdog-statement"` and `Duration "watchdog-lock"` with defaults of two seconds and 250 milliseconds, the same values the inspection host uses. `observePage` opens one read-only transaction, issues `SET LOCAL statement_timeout` and `SET LOCAL lock_timeout`, reads `observedAt` from the database clock inside that transaction (`SELECT clock_timestamp()`), pages objectives, sessions and executions up to the grant's budget divided across the three kinds, then issues set-based follow-up reads (`observeCoordinators` for the paged objectives, `observeSessionsFor` for sessions referenced by paged assignments but not in the page), and assembles one `SubjectObservation` per subject with an `EvidenceRef` for each fact it used. The number of statements per page is fixed by construction; document it in the module header and keep it under ten. A `SelectedObjectives` scope restricts objectives to the list and sessions and executions to those whose binding references one of them. `ObservationRefusal` records owner errors (unavailable, corrupt, timed out) per subject kind without aborting the page; a timeout of the whole transaction is an `ObservationError`.

Create `shikigami-core/test-postgres/Shikigami/WatchdogObservationSpec.hs` and register it. Build a fixture through the existing owner stores: at least one open objective with a coordinator member and two assignments, two sessions (one `Active` with a running assignment, one `Parked`), two executions (one `Active`, one `Parked` with a permission binding), using the same fixture helpers `WorkerSessionStoreSpec.hs`, `ExecutionTranscriptSpec.hs` and `ObjectiveStoreSpec.hs` use. The contention case opens a second connection, runs `BEGIN; SELECT objective_id FROM shikigami.objectives WHERE objective_id = $1 FOR UPDATE; SELECT session_id FROM shikigami.worker_sessions WHERE session_id = $1 FOR UPDATE;` and holds it while the test calls `observePage` with a two-second statement timeout; the page must return `Right` within the timeout and contain the locked objective's coordinator and the locked session. A second case encodes the page to JSON and asserts the absence of the keys `instructions`, `input`, `output`, `transcript`, `payload`, `prompt` and `result`, and the absence of a sentinel string that the fixture wrote into a session result body and an execution operation input. A unit case in `WatchdogTypesSpec` asserts that the SQL text of every new observe statement contains neither `FOR UPDATE` nor `FOR SHARE`.

### Milestone 3: Waiting facts, roots, processes, approvals and coverage

Add `Shikigami.Execution.ResourcesStore.observeRoots :: NonEmpty ExecutionRootId -> Transaction (Either ResourceError [RootObservation])` (root id, revision, `cancelled`, `overage`, `cutoff`, active and unknown counts) and `Shikigami.Workspace.ProcessStore.observeUnsettledProcesses :: NonEmpty OperationId -> Transaction (Either WorkspaceError [ProcessObservation])` (operation id, phase, deadline, whether a receipt exists), both lock-free and bounded by the input list. Add the approval read in `Watchdog/Observation.hs`: for sessions whose active assignment has a child workflow id, and for executions whose phase is `Parked` without a permission binding, read Keiro's pending timers of kind `shikigami.approval-timeout` and the in-flight `shikigami.approval` workflow headers through Keiro's public read API, join them to the parent workflow ids, and produce `AwaitingApproval {until, review}`. Produce `AwaitingPermission {until}` from the parked permission's `expiresAt` when the resolution is absent, `RunningCommand {until, operationId}` from a process in `ProcessLaunchRequested` or `ProcessRunning` with a future deadline, and `ParkedAssignment` for a parked session or assignment (the `since` is filled by plan 110 from the mark ledger; this plan records only the fact). A process past its deadline with no receipt, a permission past `expiresAt` with no resolution, or an approval timer that has fired with the parent still parked produce no waiting fact and are therefore classified from the mark alone; record each as an `EvidenceRef` so the finding can cite it. `WaitingFact` is the closed sum of these facts with their deadlines; the request's "within its deadline" comparison belongs to the classifier, which receives `observedAt`.

Attach root facts to every subject with a root id: `cancelled`, `overage` and whether `observedAt` is past `cutoff`. These are evidence, not verdicts; a subject under a cancelled or exhausted root must still be observed and reported (IR-19 acceptance 7).

Implement coverage: when a kind's page returns fewer rows than its share, its cursor resets to `Nothing`; when all three reset in the same page, `passCompleted` is `PassCompleted`, otherwise `PassContinuing`. Add PostgreSQL cases: a population of 2 × `subjectsPerSweep` subjects is fully covered after exactly three pages when fed back its own cursor, and the fourth page restarts from the beginning; a corrupt `state` JSON written directly into one `worker_sessions` row produces one `ObservationRefusal` naming the session kind while the rest of the page succeeds; a `SelectedObjectives` scope excludes sessions bound to other objectives; a fixture process past its deadline yields no `RunningCommand` fact but does yield a process `EvidenceRef`; an approval timer armed by the existing approval fixture (`shikigami-core/test-postgres/Shikigami/FlowLifecycleSpec.hs` arms one through `fireDueApprovalTimer`) appears as `AwaitingApproval` with the timer's `fireAt`.


## Concrete Steps

Run from the repository root in the development environment; enter `nix develop` first if native tools are unavailable. Record the baseline revision before editing:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
EP1_BASE=$(git rev-parse HEAD)
cabal build shikigami-core
```

After milestone 1:

```bash
just haskell-conventions
just domain-value-types
cabal test shikigami-core-test --test-show-details=direct --test-options='-p Watchdog'
```

Expected: the conventions check prints no violations; `domain-value-types` reports the new probe's positive client compiled and every negative client refused; the unit suite prints `All N tests passed` for the `Watchdog` pattern.

After milestones 2 and 3:

```bash
cabal test shikigami-core-postgres-test --test-show-details=direct --test-options='-p Watchdog --num-threads 1'
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-workers-test shikigami-server-test --test-show-details=direct
```

Expected: the `WatchdogObservationSpec` group passes, including a case whose name states the contention (`observes locked subjects within the statement timeout`), and the full suites exit zero. No migration is added by this plan unless milestone 2's `EXPLAIN` check requires an index; if it does, create it with `just new-migration name=watchdog-observation-indexes`, append its `sha256` line to `shikigami-migrations/sql-migrations/migrations.lock`, regenerate `shikigami-migrations/expected-schema.txt` with `SHIKIGAMI_REGENERATE_EXPECTED_SCHEMA=1 cabal test shikigami-migrations-test`, and run `just migration-schema-isolation`.

Commit at each milestone boundary with the trailers:

```text
feat(watchdog): observe active work through lock-free bounded reads

MasterPlan: docs/masterplans/19-supervise-active-work-with-an-independent-watchdog-agent.md
ExecPlan: docs/plans/109-observe-active-work-through-bounded-lock-free-reads-under-a-watchdog-grant.md
Intention: intention_01m6kkgpehed8r75hazq4y7qqj
```


## Validation and Acceptance

Acceptance is behavioral. With the fixture population in place and a competing transaction holding `FOR UPDATE` on an objective row and a session row, `observePage` returns within its statement timeout, the returned page contains a `SubjectObservation` whose subject is `ObjectiveCoordinator` for the locked objective and one whose subject is `WorkerSession` for the locked session, and the JSON encoding of the page contains none of the body keys and none of the sentinel text written into bodies. Feeding a page's cursor back produces the next page and the population is covered after the expected number of pages, after which the cursor restarts. A parked execution with a future permission deadline carries `AwaitingPermission`, a running fixture process carries `RunningCommand`, an armed approval timer carries `AwaitingApproval`, and each of those facts' deadlines equals the owner's recorded value. A corrupt session row yields one refusal and does not abort the page. Any identity other than the configured watchdog principal is refused by `resolveObservationGrant`, and with the `watchdog` settings omitted the refusal is `WatchdogDisabled`.

The early producer/consumer check named by the MasterPlan is the contention case; run it before adding roots, processes and approvals, so that the lock-free property is established on the core subjects first. Property-style coverage is not available (the suites use tasty-hunit only); use table-driven cases over every `Subject` kind and every `WaitingFact` constructor.


## Idempotence and Recovery

Every read here is side-effect free and may be repeated. The only durable change is the optional index migration, which is additive and idempotent (`CREATE INDEX IF NOT EXISTS`). Adding the `Watchdog` root to the module policy and the settings object to the configuration record are additive; omitting the settings object changes no existing behavior. If a follow-up read turns out to need a lock to be correct, stop and record the finding in Surprises & Discoveries rather than adding `FOR UPDATE`: the contract of this plan is that observation never blocks a writer, and the classifier in plan 110 is designed to tolerate a slightly stale fact.


## Interfaces and Dependencies

This plan owns `Shikigami.Watchdog.Types`, `Shikigami.Watchdog.Grant`, `Shikigami.Watchdog.Observation`, the `WatchdogSettings` record and loader fields `principal`, `scope`, `stuckWindowSeconds`, `parkedWindowSeconds`, `coordinatorWindowSeconds` and `subjectsPerSweep`, the `Watchdog` module root, the probe `tests/types/watchdog-values.py`, and the additive observation reads in `Shikigami.Objective.Store`, `Shikigami.Objective.Inspection`, `Shikigami.WorkerSession.Store`, `Shikigami.Execution.Store`, `Shikigami.Execution.ResourcesStore`, `Shikigami.Workspace.ProcessStore` and `Shikigami.Coordination.Sql`. It defines `Subject`, `SubjectKey`, `ActivityMark`, `MarkDigest`, `WaitingReason`, `WaitingFact`, `Verdict`, `DetectionKind`, `EvidenceRef`, `ObservedWindow`, `ObservationLimit`, `Windows`, `WatchdogLimit`, `FindingView`, `CoverageCursor`, `SubjectObservation` and `ObservationPage` exactly as plans 110, 111 and 112 consume them; a change to any of these after plan 110 starts is recorded in the MasterPlan's Integration Points first. It does not define the sealed `Finding` (plan 110), the ledger tables (plan 110), the drift decision (plan 111), any Flow or capability effect (plan 112), or any operator command (plan 113). It depends on no unfinished plan. Dependency source lookup starts with Mori: `mori registry show shinzui/keiro --full` for the public pending-timer and workflow-header reads, and `mori registry docs keiro-runtime-patterns` for the scalar, vertical-slice and test-layout standards.
