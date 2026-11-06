---
id: 110
slug: classify-stuck-work-deterministically-and-coalesce-findings-into-episodes
title: "Classify stuck work deterministically and coalesce findings into episodes"
kind: exec-plan
created_at: 2026-11-04T15:58:26Z
intention: "intention_01m6kkgpehed8r75hazq4y7qqj"
master_plan: "docs/masterplans/19-supervise-active-work-with-an-independent-watchdog-agent.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-11-04T15:58:26Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-06T04:40:28Z
      mode: "update"
      note: "Reconciled proposed APIs, ownership and acceptance with current source review."
---

# Classify stuck work deterministically and coalesce findings into episodes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Given a page of observed subjects (plan 109), nothing yet says whether any of them is stuck. After this plan a pure function, `Shikigami.Watchdog.Classify.classify`, answers that question deterministically and without a model: a subject whose activity mark has not changed for the configured window, and which is not legitimately waiting on an approval, a tool permission, a running command, a parked grace or an explicit block, is stuck; a coordinator of an open objective that waits for a checkpoint no idle worker will ever publish, or whose run has vanished, is a stuck coordinator; an uncertain operation outcome that persists is reported as unresolved and never called failed. A ledger remembers each subject's mark and when it last changed, opens one episode per subject and detection kind, mints exactly one typed finding when an episode opens, and mints another only when the evidence summary changes materially. Replaying the same sweep page converges on the same rows and the same findings.

You can see it working in two suites. `cabal test shikigami-core-test --test-options='-p Classify'` runs the verdict tables: the same observation produces the same verdict, a waiting deadline in the future suppresses a stuck verdict and its passing produces one, and a coordinator whose workers are all idle is reported while a worker's own stuck verdict never makes a coordinator stuck. `cabal test shikigami-core-postgres-test --test-options='-p WatchdogStore'` records a page twice and shows one finding, records a progressing page and shows the episode closed, and records a materially different page and shows a second finding. This plan is EP-2 of [MasterPlan 19](../masterplans/19-supervise-active-work-with-an-independent-watchdog-agent.md). It requires plan 109 (`docs/plans/109-observe-active-work-through-bounded-lock-free-reads-under-a-watchdog-grant.md`) to be Complete, because it consumes that plan's `SubjectObservation`, `ActivityMark`, `WaitingFact`, `Verdict`, `DetectionKind`, `EvidenceRef`, `FindingView` and identity types without redefining them.


## Progress

- [ ] Milestone 1: The pure classifier exists with exhaustive verdict tables covering every subject kind, every waiting fact and the coordinator rule; `cabal test shikigami-core-test` passes with the new group.
- [ ] Milestone 2: Migration `NNNN-watchdog-ledger` and `Shikigami.Watchdog.Store` exist; recording a page twice converges on one finding per opened episode, and the PostgreSQL group passes.
- [ ] Milestone 3: Material-change notices, episode closure on progress or disappearance, pass-completion closure and the coverage singleton work end to end; the staleness-by-marks ADR is written and `cabal test` for core and PostgreSQL passes in full.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Time enters the classifier only as the page's journaled `observedAt` and the ledger's recorded `firstSeenAt` and `lastChangedAt`; the classifier never reads a clock and the ledger never writes `now()`.
  Rationale: The watchdog runs inside a replayed durable workflow (plan 112), so a fresh clock read inside classification would make replay diverge from the first run. Owner `updated_at` columns are written by two different clock functions and do not cover the facts that matter, so they are hints, not authority.
  Date: 2026-11-04

- Decision: A finding is minted only by the episode ledger, inside the transaction that opens or materially changes an episode, and its constructor is private to `Shikigami.Watchdog.Episode`.
  Rationale: The request requires one notice per episode and a further notice only on material change. Making the ledger the sole minter makes that rule a type-level fact (ADR 0081) rather than a convention the Flow must remember.
  Date: 2026-11-04


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a Cabal multi-package Haskell service; `shikigami-core` owns domain code and store adapters, `shikigami-migrations` owns append-only SQL migrations and the `test-support` sublibrary that supplies an isolated migrated PostgreSQL database to every test. Modules are grouped by concept under `Shikigami.<Concept>.*`; this plan lives entirely under `Shikigami.Watchdog.*`, a concept root that plan 109 admits to `tools/style/module-ownership.json`.

Plan 109 supplies the inputs. A `SubjectObservation` (`shikigami-core/src/Shikigami/Watchdog/Observation.hs`) is one observed unit of active work: its `subject :: Subject` (`ObjectiveCoordinator ObjectiveId`, `WorkerSession WorkerSessionId` or `Execution ExecutionId`), its optional `objective`, its `mark :: ActivityMark` (the owner revisions and cursors that advance only when work is accepted, with `markDigest :: ActivityMark -> MarkDigest`), its `waits :: [WaitingFact]` (an approval or permission deadline, a running command's deadline, a parked phase, or an explicitly blocked objective) and the `evidence :: NonEmpty EvidenceRef` it was built from. An `ObservationPage` carries `observedAt :: UTCTime` read from the database clock inside the observation transaction, the `CoverageCursor`, a `PassCompletion` (`PassContinuing | PassCompleted`) and the subjects. `Windows` carries `Duration "watchdog-stuck"`, `Duration "watchdog-parked"` and `Duration "watchdog-coordinator"` (from `shikigami-core/src/Shikigami/Duration.hs`, whose `durationTime` lowers to `NominalDiffTime`). `Verdict` is the closed sum `Progressing | Waiting WaitingReason | Unresolved | Stuck | StuckCoordinator | Terminal`; `DetectionKind` is `StuckWork | StuckCoordinator | UnresolvedOutcome | Drift`. `FindingView` is the public read record of a finding; `SweepId`, `EpisodeId` and `FindingId` are private `KindID` UUIDv7 newtypes with `newSweepId`, `newEpisodeId`, `newFindingId :: IO ...` and checked parsers. `SubjectKey` is the stable storage rendering of a `Subject`.

What the owner semantics mean for verdicts. [ADR 0061](../adr/0061-continuing-sessions-own-ordered-assignments-and-retained-receipts.md) states that parking and unresolved observations retain the active assignment and child and do not establish that an external effect ended, and that a lease expiry never proves a process stopped; [ADR 0051](../adr/0051-resource-roots-own-conservative-reservations-and-actual-attempts.md) states that unknown completion holds capacity and expiry never proves an effect did not happen. Those are why `Unresolved` is its own verdict that is never folded into `Stuck` or into a failure. [ADR 0067](../adr/0067-objective-checkpoints-use-assignment-scoped-preconditions.md) states that an objective instruction or status change advances every assignment revision, so an operator editing instructions changes a subject's mark; that is correct, because the edit is new input the worker and coordinator should respond to within the window. [ADR 0108](../adr/0108-adaptive-decisions-commit-with-authoritative-checkpoints.md) and [ADR 0111](../adr/0111-adaptive-delivery-carries-native-admission-and-reference-only-seeds.md) describe the coordinator: it decides by committing an accepted proposal at an objective checkpoint revision, waits through a checkpoint listener whose `after` revision names the checkpoint it needs, is woken by worker result events and objective publications, reflects on findings and never on silence, and records a `terminal` observation when it ends. A coordinator whose listener waits for a revision above the current one while every worker session is idle with nothing queued has nothing left that will wake it; that is the stuck coordinator the request describes in acceptance 3. [ADR 0091](../adr/0091-operation-uncertainty-and-call-ordinals-retain-their-meanings.md) is the precedent for closed sums instead of booleans, and [ADR 0080](../adr/0080-opaque-checked-values-do-not-expose-generic-construction.md) and [ADR 0081](../adr/0081-validated-results-use-private-seals-and-public-read-views.md) govern the sealed finding. [ADR 0094](../adr/0094-accounting-entities-use-allocated-identities-and-root-origin-receipts.md) sets the identity rule this plan follows: allocate UUIDv7 values in IO, write them behind a durable receipt that makes retries idempotent, and refuse a changed binding.

Prior art for staleness verdicts is `shikigami-workers/src/Shikigami/Health/Worker.hs`: `loopLivenessAt :: Heartbeats -> UTCTime -> IO ProbeVerdict` and `processorStateVerdictWithStaleness` take an explicit instant and a last-activity record and return a verdict, with `Idle` counting as healthy. That is the shape to follow, lifted to durable state.

Migrations: `shikigami-migrations/sql-migrations/manifest` lists one file per line in apply order; `just new-migration name=<slug>` writes `NNNN-slug.sql` with the standard header and appends it. Every object must be schema-qualified (`shikigami.`); `just migration-schema-isolation` and the migrations test both enforce it. After adding a file, append its `sha256  <file>` line to `shikigami-migrations/sql-migrations/migrations.lock` (no tool writes it) and regenerate `shikigami-migrations/expected-schema.txt` with `SHIKIGAMI_REGENERATE_EXPECTED_SCHEMA=1 cabal test shikigami-migrations-test`. Research found the lock listing 36 files while the manifest lists 41 (`0038` through `0042` absent); run `cabal test shikigami-migrations-test` before editing and, if it fails on the lock, repair the missing lines in a separate commit and record the friction. The latest migration at research time is `0042-adaptive-delivery-observations.sql`; allocate the next available number at implementation time. Store modules in this repository are `Hasql.Transaction.Transaction` values or `Eff` computations over the `Store` effect; `shikigami-core/src/Shikigami/Coordination/Sql.hs` (`saveDecision`, `saveObservation`, `readObservations` with its 4096-row cap) is the closest model for an application-owned metadata table written in the same transaction as other facts. Tests use tasty and tasty-hunit only; register unit specs in `shikigami-core/test/Main.hs` and PostgreSQL specs in `shikigami-core/test-postgres/Main.hs`, each also in the suite's `other-modules` in `shikigami-core.cabal`. PostgreSQL suites have exhausted fixture connections under default parallelism (FRIC-2, FRIC-5, FRIC-17, FRIC-51); use `--num-threads 1` when that recurs.


## Plan of Work

### Milestone 1: The pure classifier

Create `shikigami-core/src/Shikigami/Watchdog/Classify.hs`. Everything in it is pure and total.

```haskell
data PriorMark = PriorMark
  { digest :: !MarkDigest
  , firstSeenAt :: !UTCTime
  , lastChangedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

-- | What one detector family concluded about one subject. 'Clear' closes matching
-- episode for the subject; 'Detected' opens or continues one.
data Outcome
  = Clear !Verdict
  | Detected !Detection
  deriving stock (Eq, Show)

data Detection = Detection
  { kind :: !DetectionKind
  , verdict :: !Verdict
  , summary :: !EvidenceSummary
  , evidence :: !(NonEmpty EvidenceRef)
  , window :: !ObservedWindow
  , limit :: !ObservationLimit
  }
  deriving stock (Eq, Show, Generic)

data Observed = Observed
  { subject :: !Subject
  , objective :: !(Maybe ObjectiveId)
  , mark :: !ActivityMark
  , outcome :: !Outcome
  }
  deriving stock (Eq, Show, Generic)

classify :: Windows -> UTCTime -> Maybe PriorMark -> SubjectObservation -> Observed

classifyPage :: Windows -> ObservationPage -> Map SubjectKey PriorMark -> [Observed]
```

`classify` applies rules in a fixed order and the module documents them in that order. First, a subject whose mark says it is finished (a session in `Failed` or `Cancelled`, an execution in `Succeeded`, `Failed` or `Cancelled`, a coordinator whose `terminal` is `CoordinatorTerminal` or whose objective status is `Completed` or `Cancelled`) is `Clear Terminal`. Second, with no prior mark, or with a prior whose digest differs from the current mark's digest, the subject is `Clear Progressing`; the caller records the new mark with `lastChangedAt = observedAt`. Third, the quiet duration is `observedAt` minus `lastChangedAt`. A waiting fact whose deadline is after `observedAt` yields `Clear (Waiting reason)`; a parked session or assignment is `Waiting (ParkedAssignment since)` with `since = lastChangedAt` while the quiet duration is below the parked window and the subject's root cutoff, if known, is after `observedAt`; an objective with status `Blocked` yields `Waiting ObjectiveBlocked` for its coordinator. Fourth, a subject whose mark reports uncertain operations, an `Unresolved` phase or an `AssignmentUnresolved` assignment, quiet for at least the stuck window, is `Detected` with kind `UnresolvedOutcome` and verdict `Unresolved`; below the window it is `Clear Progressing`. Fifth, a session or execution quiet for at least the stuck window with no live waiting fact is `Detected` with kind `StuckWork` and verdict `Stuck`; a waiting fact whose deadline has passed is included in the evidence so the finding can say which deadline lapsed. Sixth, a coordinator of an `Open` objective is `Clear Progressing` while any of the objective's assignment sessions is active or progressing, `Clear (Waiting ...)` while any of them is legitimately waiting, and `Detected` with kind `StuckCoordinator` and verdict `StuckCoordinator` when every assignment session is `Idle` with nothing queued or absent, no execution under the objective is active, the mark has been quiet for at least the coordinator window, and either a listener exists or neither a listener nor a decision in flight exists. The coordinator rule reads only coordinator and session facts from the page; a worker's own `Stuck` outcome never contributes to it, which is what acceptance 3 of the request requires. Below the coordinator window, the same situation is `Clear Progressing`.

`EvidenceSummary` is the closed record whose equality defines a material change: the detection kind, the kind of waiting fact that lapsed if any, the subject's owner epoch, the root control facts (`Cancellation`, `Overage` and whether the cutoff has passed), the count of uncertain operations, and for drift (plan 111) the drift category. Elapsed time, sweep identity and evidence revisions are deliberately excluded. `summaryDigest :: EvidenceSummary -> SummaryDigest` hashes its canonical JSON under the version tag `shikigami.watchdog-summary/1`. `ObservedWindow` is `since = lastChangedAt`, `until = observedAt`; `ObservationLimit` is `FirstObservedAt firstSeenAt`, which is how a finding reports that the watchdog cannot know what happened before it first saw the subject.

Create `shikigami-core/test/Shikigami/WatchdogClassifySpec.hs`. Use fixed instants (`UTCTime (fromGregorian 2026 11 4) 0` plus offsets) and table-driven cases, one table per rule, naming each row. Required rows: an unchanged mark below and above the stuck window; a changed mark; each of the five waiting facts before and after its deadline, including a parked session crossing the parked window and a parked session whose cutoff has passed; an uncertain operation below and above the window; a terminal subject with an open prior; a coordinator with an active worker, with a waiting worker, with all workers idle below and above the coordinator window, with a `terminal` observation, with no listener and no decision; and a table proving `summaryDigest` is unchanged by `observedAt` and sweep changes and changed by owner epoch, lapsed-deadline kind and root control. Register the module in `shikigami-core/test/Main.hs` and the cabal file.

### Milestone 2: The ledger

Allocate the next available migration (do not reserve 0043) through `just new-migration name=watchdog-ledger`. Observation timestamps come from the journaled page. Opening and completion retain their own database timestamps on first insert so retries recover the same values:

```sql
-- Watchdog sweep, mark, episode and finding ledger. Metadata and references only;
-- no instruction, result or transcript bodies are stored here.
CREATE TABLE IF NOT EXISTS shikigami.watchdog_sweeps (
  sweep_id uuid PRIMARY KEY,
  workflow_name text NOT NULL,
  workflow_id text NOT NULL,
  due_at timestamptz NOT NULL,
  opened_at timestamptz NOT NULL,
  completed_at timestamptz,
  grant_snapshot jsonb NOT NULL,
  summary jsonb,
  UNIQUE (workflow_name, workflow_id)
);
CREATE TABLE IF NOT EXISTS shikigami.watchdog_marks (
  subject_key text PRIMARY KEY,
  subject jsonb NOT NULL,
  objective_id uuid,
  mark_digest text NOT NULL,
  mark jsonb NOT NULL,
  first_seen_at timestamptz NOT NULL,
  last_changed_at timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL,
  last_seen_sweep uuid NOT NULL REFERENCES shikigami.watchdog_sweeps (sweep_id)
);
CREATE TABLE IF NOT EXISTS shikigami.watchdog_episodes (
  episode_id uuid PRIMARY KEY,
  subject_key text NOT NULL,
  objective_id uuid,
  kind text NOT NULL,
  opened_at timestamptz NOT NULL,
  opened_sweep uuid NOT NULL REFERENCES shikigami.watchdog_sweeps (sweep_id),
  closed_at timestamptz,
  closed_reason text,
  last_summary_digest text NOT NULL,
  last_seen_sweep uuid NOT NULL REFERENCES shikigami.watchdog_sweeps (sweep_id),
  notified_count integer NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS watchdog_open_episodes
  ON shikigami.watchdog_episodes (subject_key, kind) WHERE closed_at IS NULL;
CREATE TABLE IF NOT EXISTS shikigami.watchdog_findings (
  finding_id uuid PRIMARY KEY,
  episode_id uuid NOT NULL REFERENCES shikigami.watchdog_episodes (episode_id),
  sweep_id uuid NOT NULL REFERENCES shikigami.watchdog_sweeps (sweep_id),
  recorded_at timestamptz NOT NULL,
  finding jsonb NOT NULL,
  UNIQUE (episode_id, sweep_id)
);
CREATE TABLE IF NOT EXISTS shikigami.watchdog_coverage (
  singleton boolean PRIMARY KEY DEFAULT TRUE CHECK (singleton),
  cursor jsonb NOT NULL,
  pass_started_at timestamptz NOT NULL,
  last_pass_completed_at timestamptz
);
```

Create `shikigami-core/src/Shikigami/Watchdog/Episode.hs`, which owns the sealed finding and the coalescing rule, and `shikigami-core/src/Shikigami/Watchdog/Store.hs`, which owns the SQL. The finding is a private newtype over its view with no `Generic` and no `FromJSON`; `findingView :: Finding -> FindingView` is the only way out and `Episode.mint` the only way in. The store API, with every write keyed so that a replay converges:

```haskell
data SweepOrigin = SweepOrigin
  { workflowName :: !WorkflowName
  , workflowId :: !WorkflowId
  , dueAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

-- | Opens the sweep for this run or returns the one already opened for the same
-- workflow coordinates; the supplied identity is used only on first open.
openSweep :: SweepId -> SweepOrigin -> GrantSnapshot -> UTCTime -> Transaction (Either WatchdogError SweepId)

data PageOutcome = PageOutcome
  { notices :: ![Finding]
  , opened :: !Word
  , continued :: !Word
  , closed :: !Word
  }
  deriving stock (Show, Generic)

-- | Records marks and outcomes for one page in one transaction. Fresh identities
-- are consumed only for rows actually inserted; replaying the same sweep and
-- page returns the findings recorded the first time.
recordSweepPage :: SweepId -> DetectionFamily -> UTCTime -> IdentityPool -> [Observed] -> Transaction (Either WatchdogError PageOutcome)

-- | Closes open episodes whose subject was not seen since the pass began.
completePass :: SweepId -> UTCTime -> Transaction (Either WatchdogError [EpisodeId])

closeSweep :: SweepId -> UTCTime -> SweepSummary -> Transaction (Either WatchdogError ())

readPriorMarks :: NonEmpty SubjectKey -> Transaction (Either WatchdogError (Map SubjectKey PriorMark))
readCoverage :: Transaction (Either WatchdogError (Maybe Coverage))
writeCoverage :: Coverage -> Transaction (Either WatchdogError ())
```

`IdentityPool` holds `EpisodeId` and `FindingId` values allocated in IO before the transaction, at most one of each per observed subject; `recordSweepPage` refuses a pool smaller than the page rather than allocating inside the transaction. `recordSweepPage` upserts the mark row (`last_changed_at` advances only when the digest differs; `first_seen_at` is kept), then for each `Detected` outcome either continues the open episode for `(subject_key, kind)` or inserts a new one, and inserts a finding only when the episode is new or the summary digest differs from `last_summary_digest`; for each `Clear` outcome it closes only episodes for the subject in the supplied detector family with `closed_reason` `progressing`, `waiting` or `terminal`. A finding insert that conflicts on `(episode_id, sweep_id)` returns the existing row, which is what makes a crash between the transaction's commit and the caller's journal append safe (plan 112 relies on this). `completePass` identifies unseen candidates only after a complete, refusal-free pass in the same scope. It does not infer termination from absence: active-population scans omit idle and terminal subjects and race with transitions. Close only after a bounded direct owner recheck confirms terminal/deleted state; unknown or inaccessible subjects retain episodes and report incomplete coverage. Advance the pass boundary once via a retained receipt.

Create `shikigami-core/test-postgres/Shikigami/WatchdogStoreSpec.hs` with cases: open the same origin twice and get the same `SweepId`; record a page with one `Detected` subject and get one notice, record the identical page again under the same sweep and get the same notice (same `FindingId`), then under a new sweep with the same summary and get none; record a `Clear Progressing` outcome and see the episode closed with the right reason; a pool smaller than the page is refused with no partial writes (check row counts); concurrent recording of the same page from two connections (use `Keiro.Test.Postgres.withFreshResourceStoresSameDatabase` as the test layout standard recommends) yields one episode and one finding.

### Milestone 3: Material change, closure and the ADR

Extend the store cases: a second sweep whose summary differs in owner epoch yields a second finding on the same episode with `notified_count` 2; a lapsed deadline changes the summary and yields a finding; a complete pass that omits a subject followed by a bounded owner recheck confirming deletion closes its episode as `vanished`, while an omitted subject before the pass completes leaves it open; `readCoverage` returns `Nothing` before the first sweep and the written cursor afterwards. Add a classifier-to-ledger case that drives `classifyPage` over a fixture `ObservationPage` built by plan 109's observation (reuse its fixture helpers) and records the result, so the two plans are proven together on the real types.

Write the ADR `docs/adr/<next>-watchdog-staleness-is-measured-against-its-own-sweep-marks.md` (take the next free number at the time; do not renumber) with the context (owner timestamps absent or inconsistent; replay determinism), the decision (marks, digests, `observedAt` as the only time input, first-seen limits reported), the alternatives rejected (owner timestamps, Kiroku event times per subject, a heartbeat column on sessions) and the consequences (first-observation delay, honest observation limits, no owner change). Link it from this plan and the MasterPlan.


## Concrete Steps

Run from the repository root; enter `nix develop` if native tools are unavailable.

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
EP2_BASE=$(git rev-parse HEAD)
cabal test shikigami-migrations-test --test-show-details=direct
```

The migrations test must pass before you add a file; if its lock check fails on `0038`–`0042`, repair the lock in a separate commit and record friction with `bun agents/skills/exec-plan/record-friction.ts log --plan docs/plans/110-classify-stuck-work-deterministically-and-coalesce-findings-into-episodes.md ...`.

After milestone 1:

```bash
just haskell-conventions
cabal test shikigami-core-test --test-show-details=direct --test-options='-p Classify'
```

After milestone 2:

```bash
just new-migration name=watchdog-ledger
# edit shikigami-migrations/sql-migrations/NNNN-watchdog-ledger.sql
sha256sum shikigami-migrations/sql-migrations/NNNN-watchdog-ledger.sql
# append "<digest>  NNNN-watchdog-ledger.sql" to shikigami-migrations/sql-migrations/migrations.lock
just migration-schema-isolation
SHIKIGAMI_REGENERATE_EXPECTED_SCHEMA=1 cabal test shikigami-migrations-test
cabal test shikigami-migrations-test shikigami-core-postgres-test --test-show-details=direct --test-options='-p WatchdogStore --num-threads 1'
```

Expected: the schema isolation check prints nothing and exits zero; the migrations test passes after the schema regeneration; the PostgreSQL group prints `All N tests passed`.

After milestone 3:

```bash
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-workers-test shikigami-server-test --test-show-details=direct
```

Commit at milestone boundaries with the trailers:

```text
feat(watchdog): classify stuck work and coalesce findings into episodes

MasterPlan: docs/masterplans/19-supervise-active-work-with-an-independent-watchdog-agent.md
ExecPlan: docs/plans/110-classify-stuck-work-deterministically-and-coalesce-findings-into-episodes.md
Intention: intention_01m6kkgpehed8r75hazq4y7qqj
```


## Validation and Acceptance

The request's acceptance 1 at the verdict and ledger level: a fixture session whose mark stops changing while its phase stays `Active` is `Clear Progressing` on the first sweep, `Clear Progressing` while quiet for less than the stuck window, `Detected StuckWork` once the window has elapsed, and recording that detection yields exactly one finding; later sweeps with the same summary yield no further finding. Acceptance 2: a parked execution with a permission deadline in the future is `Waiting (AwaitingPermission until)` and yields no finding; the same subject observed after the deadline with the mark unchanged is `Detected StuckWork` with the lapsed permission in its evidence. A process within its deadline is `Waiting (RunningCommand ...)`. Acceptance 3: an open objective whose coordinator listener waits while every assignment session is idle is `Detected StuckCoordinator` after the coordinator window; a page containing only a stuck worker and a coordinator with that worker active yields no coordinator detection. Acceptance 8 at the ledger level: the same sweep page recorded twice yields the same finding identities and no duplicate rows.

Required acceptance is the unit and PostgreSQL groups described above, run with the exact commands in Concrete Steps, plus the full core and PostgreSQL suites exiting zero. An exhaustive property check is a proposal, not acceptance: the suites have no property-testing library and adding one is a dependency decision outside this plan.


## Idempotence and Recovery

The migration is additive and idempotent. Every ledger write is keyed by sweep and subject so a retry after a crash converges; `recordSweepPage` runs in one transaction and either commits all rows for the page or none. Identities allocated in IO and not consumed are simply dropped; nothing refers to them. If a classifier rule turns out wrong after findings exist, change the rule and bump `summaryDigest`'s version tag so that existing episodes receive one honest new notice rather than a silent change of meaning. Rolling back the code leaves the tables in place; an older binary ignores them.


## Reviewed persistence contract

EP-2 owns the sweep claim and transaction receipts. Retain a claim keyed by watchdog principal and scope; a newer tick cannot advance coverage while an older sweep holds it. Recover the claim from its native workflow coordinates after restart; do not use an expiring lease alone to permit two writers. Journal observation, prior marks and cadence checks together as bounded inputs; classify from those values, not a second live read at record time. Each record operation has a receipt keyed by `(sweep_id, family)` that returns the original `PageOutcome` on retry before coalescing again. A unique finding index alone is insufficient: a retry otherwise sees an unchanged summary and returns no notice. Serialize updates to the subject/family episode before inserting or updating it.

`PageOutcome` is an internal value containing sealed `Finding`s. Define a separate explicit-codec `PageOutcomeView` containing `[FindingView]` for journal results; do not add `FromJSON` to sealed findings. Allocate the identity pool per subject and family. Liveness records update activity marks; drift records update only drift episodes and cadence, never reset activity timestamps or close liveness episodes. A progressing liveness sweep between two adverse drift assessments must leave one drift episode open and send no duplicate notice. Test replay after the ledger commit but before journal append, overlapping ticks with reversed completion order, and incomplete passes without episode closure.

Opening requires a journaled successful grant and timestamp. Grant refusal emits no authorized sweep row; expose it through refusal telemetry and the native run outcome. Completion time is a fresh database time retained by the idempotent close receipt, rather than the earlier page observation time.

## Interfaces and Dependencies

This plan owns `Shikigami.Watchdog.Classify` (`PriorMark`, `Outcome`, `Detection`, `Observed`, `EvidenceSummary`, `SummaryDigest`, `classify`, `classifyPage`), `Shikigami.Watchdog.Episode` (the sealed `Finding`, `findingView`, the coalescing rule) and `Shikigami.Watchdog.Store` (`SweepOrigin`, `IdentityPool`, `PageOutcome`, `SweepSummary`, `Coverage`, `openSweep`, `recordSweepPage`, `completePass`, `closeSweep`, `readPriorMarks`, `readCoverage`, `writeCoverage`), migration `NNNN-watchdog-ledger` and the next available staleness ADR. Plan 112 adapts plan 111 assessments into `Detected Drift` outcomes; this plan includes the shared optional drift category from the outset. Plan 112 calls every store function from journaled capability steps and supplies `observedAt` from the page. Plan 113 adds bounded readers to `Shikigami.Watchdog.Store` for inspection. It consumes plan 109's types unchanged and depends on that plan being Complete. It does not define any Flow, capability effect, decision program, operator command or metric.

Revision 2026-11-05: separated detector-family closure, journal views and retained page receipts; specified overlap recovery and conservative missing-subject handling.

The reviewed coordination constraints are recorded in [ADR 0116](../adr/0116-watchdog-observation-preserves-completeness-and-detector-boundaries.md); operator-owned spend follows [ADR 0115](../adr/0115-evaluation-spend-is-a-root-enrolled-at-the-trigger-and-accounted-slots-refuse-without-one.md).
