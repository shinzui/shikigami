---
id: 113
slug: make-the-watchdog-observable-and-qualify-ir-19
title: "Make the watchdog observable and qualify IR-19"
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
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T16:46:14Z
      mode: "implement"
      note: "Add scoped operator inspection, independent telemetry sampling and integrated watchdog qualification after accepted EP-4."
---

# Make the watchdog observable and qualify IR-19

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

A watchdog that nobody can see is a watchdog nobody can trust. After plans 109 through 112 the watchdog sweeps, but an operator still cannot tell a quiet system from a watchdog that stopped sweeping, cannot list what it has found, and cannot read a guide that says how to enable it. After this plan `shikigami watchdog inspect --json` prints the last completed sweep, the coverage of the population, the refusals and the open episodes, and exits nonzero with `--fail-when-overdue` when the last sweep is older than the declared cadence allows; `shikigami watchdog episodes --json` and `shikigami watchdog findings --json` page the ledger; exported metrics count sweeps, findings and refusals and report the age of the last completed sweep from a sampler that runs whether or not the watchdog does; the operations guide, the capability record and the user guide describe enabling the watchdog, sizing its windows and allowance, and reading its findings; and every one of the eight IR-19 acceptance cases has evidence from an integrated run through real scheduled ticks, after which the request is marked completed.

You can see it working by running the qualification group, `cabal test shikigami-workers-test --test-options='-p WatchdogQualification'`, which drives all eight cases and writes `docs/evidence/plan-113/acceptance.json`, and by running `cabal run shikigami -- watchdog inspect --json` against the suite's database. This plan is EP-5 of [MasterPlan 19](../masterplans/19-supervise-active-work-with-an-independent-watchdog-agent.md) and requires plan 112 (`docs/plans/112-run-the-watchdog-as-a-scheduled-flow-agent-with-its-own-principal-allowance-and-sinks.md`) to be Complete.


## Progress

- [x] Milestone 1: Bounded ledger readers, the inspection views and the `shikigami watchdog` command family exist; `shikigami watchdog inspect --fail-when-overdue` exits nonzero on a stale ledger and zero on a fresh one.
- [x] Milestone 2: Metrics instruments and the sampler exist; `TelemetrySpec` proves the sweep-age gauge is exported from the ledger alone and the counters from the `Observe` hooks.
- [x] Milestone 3: The operations guide, capability record, user guide and coverage tables exist and validate; the integrated qualification group passes all eight acceptance cases with evidence under `docs/evidence/plan-113/`; IR-19 is completed; ADR distillation is done.


## Surprises & Discoveries

The existing ledger already supplies `SweepView`, `EpisodeView`, `Coverage` and coarse refusal counts. Inspection reuses those views and shows a separate latest attempt; it does not duplicate codecs or scan workflow bodies. Scope is the configured principal/scope claim, including for pages and sampled age. Missing coverage remains `Nothing`, rather than an empty completed population.

Migration 0048 adds claim-scoped latest-attempt/completion indexes and episode/finding keyset indexes. Schema regeneration follows the documented two-run smoke procedure. The overdue command reads the actual declaration cron: the proof watchdog runs every five minutes, so its stale fixture must age the last completion by two such intervals.


## Decision Log

- Decision: Watchdog liveness is reported through a ledger-backed gauge, a command verdict and inspection views, never through `/health/ready` or `/health/live`.
  Rationale: [ADR 0120](../adr/0120-watchdog-liveness-is-an-operator-facing-ledger-verdict.md) retains this boundary. ADR 0020 restricts readiness to what restarting or eviction fixes and liveness to in-process progress. A late sweep is neither, and a probe that restarted a healthy worker because a cron agent was late would amplify the problem. The age gauge is sampled from the ledger by the worker's existing sampler so it is exported even when no sweep runs.
  Date: 2026-11-04


## Outcomes & Retrospective

Complete on 2026-11-06. Inspection is implemented in `23949ce5`; `1c48b31a` adds independent telemetry, the eight-case scheduled qualification and operator/user guides. Scoped readers expose the latest attempt separately from completion, retain unavailable coverage, bound keyset pages and refuse corrupt metadata. A stale or missing completion exits 2 with the overdue flag. Age is sampled independently using the database clock; fixed-tag runtime counters are at least once and the ledger remains the audit authority.

All eight IR-19 cases and the additional lost-append control pass through real scheduler, generated queue worker and resume paths. Final validation passes 1,994 package tests (784 core unit, 665 PostgreSQL, 351 worker, 37 agent, 35 API, 9 client, 113 server), 91 built CLI contracts, the complete build, Haskell conventions, migration isolation, documentation/profile/graph checks and 183 native conformance checks. `just keiro-gate c68af1a5` reports replay-neutral impact and clean generated sources. Migration unit/smoke acceptance at milestone 1 passes 9/11 cases. The generated OpenAPI artifact is refreshed to match existing adaptive objective views; no route is added.

[Acceptance evidence](../evidence/plan-113/acceptance.md) and [machine-readable facts](../evidence/plan-113/acceptance.json) retain the results. CAP-32, DOC-20, the coverage census and roadmap describe adoption and limits. IR-19 is completed. The ADR distillation pass over plans 109–113 and the parent confirms ADRs 0115–0119 and adds [ADR 0120](../adr/0120-watchdog-liveness-is-an-operator-facing-ledger-verdict.md) for independent ledger liveness. Timers must use their production multi-kind dispatcher in coupled qualification. One logical decision does not promise one actual provider call across a lost append.

Optional native Linux watchdog and live-model trials were not run; Apple containers are available. This is a visible additional-evidence gap, not a claim of native containment or model-quality qualification.


## Context and Orientation

Shikigami's operator commands live in `shikigami-server/src/Shikigami/Server/Command/` and are registered in `shikigami-server/src/Shikigami/Server/Command.hs` (`adminSubcommands`, each an `AdminAction = (AppConfig -> IO (), [Source])`). They wrap the owning library and write no SQL of their own ([ADR 0021](../adr/0021-operator-verbs-wrap-the-owning-library.md)). `Command/Executions.hs` is the template for an inspect command: optparse-applicative arguments, `requireDatabaseUrl`, `verifyShikigamiMigrations`, `runAppIO` with a `noopTracer`, the owning store's reader, one compact JSON line on stdout through `Aeson.encode`, and `die` with a fixed message and nonzero exit for refusals; page bounds (`after` 0..10000, `limit` 1..100) are checked in the command and again in the store. `shikigami-server/test/Shikigami/Server/CommandSpec.hs` holds command tests; `tests/cli/contracts.py` exercises built binaries without a database. Every new command module is listed in `compositionModules` of `tools/style/module-ownership.json` ([ADR 0075](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md)).

Metrics are OpenTelemetry instruments on the `ShikigamiMetrics` record in `shikigami-core/src/Shikigami/Telemetry/Metrics.hs`, created once (`meterCreateCounterInt64 meter "shikigami.runs.started" ...`, `meterCreateGaugeInt64 ...`), named `shikigami.<noun>.<verb>`, with only bounded attributes (`agent.name`, `trigger.kind`, `outcome`; never run ids, URLs or error text). The worker role builds them in `shikigami-workers/src/Shikigami/Telemetry.hs` (`withRunTelemetry`) and samples process-level gauges in `shikigami-workers/src/Shikigami/Telemetry/Sampler.hs`; `shikigami-workers/test/Shikigami/TelemetrySpec.hs` proves force-flush exports every instrument. Export is OTLP when `OTEL_EXPORTER_OTLP_ENDPOINT` is set and a no-op otherwise; there is no Prometheus endpoint. Health probes are fixed by [ADR 0019](../adr/0019-a-loop-that-stops-stops-the-process.md) and [ADR 0020](../adr/0020-readiness-covers-only-what-restarting-can-fix.md): `/health/ready` reports PostgreSQL only, `/health/live` reports loop progress from in-memory heartbeats (`shikigami-workers/src/Shikigami/Health/Worker.hs`), and neither changes here.

Documentation is profile-governed. Capabilities: `docs/capabilities-maintenance.md` says to allocate a handle with `okf id next docs/capabilities CAP --profile docs/capabilities/profile.dhall`, write one flat record with `status: shipped`, `stability: experimental`, `since: unreleased`, evidence links in both body and frontmatter, a dated entry in `docs/capabilities/log.md`, then `just capabilities-index`, `just capabilities-validate`, `mori validate` and `okf graph docs/capabilities`, and reconcile `docs/capabilities-coverage.md` (its administrative command table already lacks `objectives`; add `watchdog` and fix the gap you find). Operations guides live in `docs/operations/` (`inspection.md`, `execution-resources.md`, `objective-tracking.md` are the models); user guides in `docs/user/` validate with `just user-docs-validate`. Improvement requests: `docs/improvement-requests/` is an OKF bundle validated by `just improvement-requests-validate`; a completed request carries `status: completed`, `completedAt` and a status paragraph with evidence links (see `support-optional-major-task-tracking.md` for the shape), and `docs/improvement-requests/log.md` takes a dated entry. `docs/roadmap.md` has a plan and request table that should name IR-19 and plans 109–113. Evidence directories are `docs/evidence/plan-<N>/`; plan 102's `qualification.json` and `serving-qualification.txt` are the model for recorded acceptance.

Plans 109–112 supply the ledger (`shikigami.watchdog_sweeps`, `watchdog_marks`, `watchdog_episodes`, `watchdog_findings`, `watchdog_coverage`, `watchdog_drift_checks`), `Shikigami.Watchdog.Store`, `FindingView`, `WatchdogSettings`, the `Observe` capability with `ObserveHooks {onSweepCompleted, onFinding, onRefusal, onSweepFailed}` (no-ops by default), the `watchdog-sweep` Flow, `agents/proof/watchdog.dhall` with its cron, and the fixture that stalls a worker while its session stays `Active`. The scheduler's `Shikigami.Trigger.Schedule.nextDue :: CronSchedule -> UTCTime -> Maybe UTCTime` gives the expected next tick after an instant, and `Shikigami.Agent.Loader.loadAgentsReport` loads a declaration directory, which is how the command learns the watchdog's cron. The worker and PostgreSQL suites register groups in `shikigami-workers/test/Main.hs` and `shikigami-core/test-postgres/Main.hs`. Friction to expect: PostgreSQL connection exhaustion under parallel suites (FRIC-2, FRIC-5, FRIC-17, FRIC-51) and, for the optional native trial, the frozen-runtime rebuild cost recorded in FRIC-54 through FRIC-56 and the Apple guest clock step in FRIC-24 that expires absolute deadline guards.


## Plan of Work

### Milestone 1: Inspection readers and the command family

Add bounded readers to `shikigami-core/src/Shikigami/Watchdog/Store.hs` and views to a new `shikigami-core/src/Shikigami/Watchdog/Inspection.hs`:

```haskell
data InspectionView = InspectionView
  { latestAttempt :: !(Maybe SweepView)
  , lastCompletedSweep :: !(Maybe SweepView)
  , coverage :: !(Maybe Coverage)
  , openEpisodes :: !Word
  , inspectedAt :: !UTCTime
  }

data EpisodeFilter = EpisodeFilter { openOnly :: !Bool, objective :: !(Maybe ObjectiveId) }
data OverdueVerdict = SweepFresh | SweepOverdue { expectedBy :: !UTCTime } | NoSweepYet | ScheduleUnknown

overdueVerdict :: CronSchedule -> Duration "watchdog-grace" -> UTCTime -> Maybe SweepView -> OverdueVerdict
readLastCompletedSweep :: AgentIdentity -> ObservationScope -> Transaction (Either WatchdogError (Maybe SweepView))
inspectWatchdog :: AgentIdentity -> ObservationScope -> Transaction (Either WatchdogError InspectionView)
listEpisodes :: AgentIdentity -> ObservationScope -> EpisodeFilter -> Maybe EpisodeId -> Int -> Transaction (Either WatchdogError [EpisodeView])
listFindings :: AgentIdentity -> ObservationScope -> EpisodeId -> Maybe FindingId -> Int -> Transaction (Either WatchdogError [FindingView])
readSweepAgeSeconds :: AgentIdentity -> ObservationScope -> Transaction (Either WatchdogError (Maybe Int64))
```

`overdueVerdict` is pure: with no completed sweep it is `NoSweepYet`; otherwise it computes `nextDue cron completedAt` and adds the grace, and the sweep is overdue when `now` is past that instant. Limits are 1..100 with keyset paging on the identity, as the sibling commands do. Create `shikigami-server/src/Shikigami/Server/Command/Watchdog.hs` with `watchdog inspect [--agents DIR] [--grace SECONDS] [--fail-when-overdue] --json`, `watchdog episodes [--open] [--objective ID] [--after ID] [--limit N] --json` and `watchdog findings EPISODE [--after ID] [--limit N] --json`; `inspect` loads the declaration directory (default `agents/`), finds the declaration whose behavior is the `watchdog-sweep` Flow, parses its cron, reads the last sweep and coverage, prints one JSON object with the sweep, coverage, verdict and the configured windows and budget, and exits 2 on `SweepOverdue` or `NoSweepYet` when `--fail-when-overdue` is given. Register the subcommand, add the module to `compositionModules`, and add `CommandSpec` cases: a fresh ledger yields `SweepFresh` and exit zero; a ledger whose last sweep is two cron intervals old yields `SweepOverdue` and exit 2 with the flag; `episodes --open` pages only open episodes; bounds are refused with the fixed messages. Add the three commands to `tests/cli/contracts.py` for help and exit-code coverage.

### Milestone 2: Metrics and the sampler

Add to `ShikigamiMetrics`: `watchdogSweeps` (counter, attribute `outcome` in `completed`, `refused`, `failed`), `watchdogFindings` (counter, attribute `detection.kind`), `watchdogRefusals` (counter, attribute `refusal.kind`) and `watchdogSweepAge` (gauge, seconds since the last completed sweep). Install the first three through plan 112's `ObserveHooks` in `Workers/Command/Worker.hs` through `Telemetry.Sampler.watchdogHooks`. Sample the gauge in `Telemetry/Sampler.hs` from `readLastCompletedSweep` on the sampler's existing cadence, using the database clock for `now`, and emit nothing (not zero) when there is no completed sweep, matching the inspection host's rule that a missing optional metric is unavailable rather than zero. Extend `TelemetrySpec`: a force-flush after a recorded sweep exports the counters with their attributes and the gauge with a nonnegative value; with an empty ledger the gauge is absent; a failed sampler read leaves other instruments exported. Confirm no attribute carries a sweep id, episode id, objective id or error text.

### Milestone 3: Documentation, qualification and closure

Write `docs/operations/watchdog.md`: what the watchdog observes and does not read; enabling it (the `watchdog` settings object with every key, the principal and its directory entry, the sink grant rows through `shikigami grants`, promoting `agents/proof/watchdog.dhall` into `agents/`, sizing the operator-configured envelope and the windows, and the statement that default windows must be chosen from observed data); reading `watchdog inspect`, `episodes` and `findings`; the overdue verdict and the age gauge; what a finding means and does not mean (observation limit, advisory, no authority); what refusals mean; and how to use the existing objective and worker commands to intervene, since the watchdog never does. Allocate a capability handle and write `docs/capabilities/active-work-watchdog.md` with `provides`, `adopt` (pointing at the guide), evidence (the classifier spec, the observation spec, the sweep spec, the qualification spec and the guide), limits (bounded per sweep, observation-limited, advisory, no transcripts), and `requires` on the typed-agent, root-accounting and typed-decision capabilities; add the log entry; run the index, validate, `mori validate` and graph commands; reconcile `docs/capabilities-coverage.md`. Write `docs/user/watchdog.md` for people who receive notices. Add IR-19 and plans 109–113 to `docs/roadmap.md`.

Create `shikigami-workers/test/Shikigami/WatchdogQualificationSpec.hs`, one named case per IR-19 acceptance item, driven through real scheduler ticks, the queue worker and the resume worker in one process against the suite database, with fixtures from plans 110 and 112: (1) a stalled active worker yields one finding within the window and later sweeps of the same episode yield none; (2) a worker parked on a permission within its deadline and a running fixture command within its deadline yield no finding, and the permission's lapse yields one; (3) an open objective whose coordinator waits while every worker is idle yields a coordinator finding, and a sweep over a stuck worker alone yields no coordinator finding; (4) a worker continuing out-of-scope operations yields a drift finding with evidence references through the stub provider and the objective's revision and receipts are unchanged; (5) cancel and transfer under the watchdog identity are refused and the work is unaffected; (6) planted instructions change neither subject nor recipient; (7) an objective with a cancelled root is still reported and the watchdog's attempts appear only on its own root; (8) a crash mid-sweep and a resume duplicate no finding and resample no drift decision, and a skipped tick is visible as `SweepOverdue` from `overdueVerdict` and as a `RunSkip` row. The group writes `docs/evidence/plan-113/acceptance.json` (case, result, identities, counts) and the implementer records the transcript as `docs/evidence/plan-113/acceptance.md`. The optional native trial reuses plan 86's `tests/workspace/prototype` fixture under `bash tests/workspace/run-apple.sh` with the watchdog declaration added; if the environment is unavailable, record that as a visible gap, not a failure.

Close the request: set IR-19's frontmatter to `status: completed` with `completedAt`, replace its status paragraph with the evidence links, add the `docs/improvement-requests/log.md` entry, run `just improvement-requests-index` and `just improvement-requests-validate`. Perform the ADR distillation pass over plans 109–113 and the MasterPlan: confirm the ADRs written by plans 110 and 112, add a record for `watchdog liveness is an operator-facing ledger verdict, not a probe` if the Decision Log here still holds it only locally, and update the MasterPlan's Outcomes & Retrospective and registry.


## Concrete Steps

Run from the repository root; enter `nix develop` if native tools are unavailable.

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
EP5_BASE=$(git rev-parse HEAD)
cabal build all
```

After milestone 1:

```bash
just haskell-conventions
cabal test shikigami-server-test --test-show-details=direct --test-options='--num-threads 1'
python3 tests/cli/contracts.py
cabal run shikigami -- watchdog inspect --help
```

Expected: the command group passes; the contracts script reports the three new commands; the help text lists `--fail-when-overdue`.

After milestone 2:

```bash
cabal test shikigami-workers-test --test-show-details=direct --test-options='-p Telemetry'
```

After milestone 3:

```bash
cabal test shikigami-workers-test --test-show-details=direct --test-options='-p WatchdogQualification --num-threads 1'
just capabilities-index && just capabilities-validate && mori validate && okf graph docs/capabilities
just user-docs-validate
just improvement-requests-index && just improvement-requests-validate
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-workers-test shikigami-server-test shikigami-agent-test shikigami-api-test shikigami-client-test --test-show-details=direct
git diff --check
```

Expected: the qualification group prints eight passing cases and writes `docs/evidence/plan-113/acceptance.json`; every validation exits zero; the full suites exit zero.

Commit at milestone boundaries with the trailers:

```text
feat(watchdog): expose sweep inspection, metrics and qualify IR-19

MasterPlan: docs/masterplans/19-supervise-active-work-with-an-independent-watchdog-agent.md
ExecPlan: docs/plans/113-make-the-watchdog-observable-and-qualify-ir-19.md
Intention: intention_01m6kkgpehed8r75hazq4y7qqj
```


## Validation and Acceptance

Required acceptance: `shikigami watchdog inspect --json` prints the last completed sweep, coverage and verdict, and `--fail-when-overdue` exits 2 against a ledger whose last sweep is older than the cron's next due time plus the grace and 0 against a fresh one; `episodes` and `findings` page with bounds; the four instruments are exported with bounded attributes and the age gauge is exported from the ledger with no sweep running; the operations guide, capability record and user guide validate; the qualification group passes all eight IR-19 cases through real scheduled ticks with evidence recorded; IR-19 is `completed` and validates. The native trial and a live model trial are proposals for additional evidence, recorded as gaps if not run. Do not mark this plan or the request complete while any of the eight cases lacks evidence.


## Idempotence and Recovery

Readers and commands are side-effect free. Documentation index and validation commands are idempotent. The qualification group runs against the disposable suite database and may be repeated; its evidence file is regenerated each run and the committed copy is the accepted one. If a qualification case fails because a prior plan's behavior is wrong, the fix belongs to that plan's modules and is ordinary implementation work; record the discovery here and in the MasterPlan's Surprises & Discoveries if it changes another child's assumptions.


## Interfaces and Dependencies

This plan owns `Shikigami.Watchdog.Inspection` (`InspectionView`, `EpisodeFilter`, `OverdueVerdict`, `overdueVerdict`), reusing existing ledger `SweepView`, `Coverage`, `EpisodeView` and summary refusal counts, the readers `readLastCompletedSweep`, `listEpisodes` and `listFindings` in `Shikigami.Watchdog.Store`, `Shikigami.Server.Command.Watchdog` and its registration, the four `ShikigamiMetrics` instruments and their hook and sampler wiring, `docs/operations/watchdog.md`, `docs/capabilities/active-work-watchdog.md`, `docs/user/watchdog.md`, the roadmap and coverage updates, `shikigami-workers/test/Shikigami/WatchdogQualificationSpec.hs`, `docs/evidence/plan-113/`, the IR-19 lifecycle transition and the final ADR distillation. It consumes plans 109–112 unchanged and requires plan 112 to be Complete. It adds no domain behavior: a defect found by qualification is fixed in the owning plan's modules, and this plan records the result.

Revision 2026-11-05: inspection and the age sampler select the latest completed sweep (`completed_at IS NOT NULL`), with the latest attempt shown separately. Scope all readers to the configured watchdog principal and observation scope. A newer incomplete attempt must not hide the previous completion. Add cases for no completed sweep, a newer unfinished attempt, and incomplete population coverage; report unavailable coverage distinctly from an empty population. The qualification restart case requires no resampling only after the result append committed; inject lost append separately and verify conservative attempt accounting. Use the existing Apple container setup for the optional native trial, with the configured builder fallback described in AGENTS.md.

The reviewed coordination constraints are recorded in [ADR 0116](../adr/0116-watchdog-observation-preserves-completeness-and-detector-boundaries.md); operator-owned spend follows [ADR 0115](../adr/0115-evaluation-spend-is-a-root-enrolled-at-the-trigger-and-accounted-slots-refuse-without-one.md).

EP-5 implementation note: reuse the existing ledger views and claim-scoped readers without introducing duplicate `SweepView`/`CoverageView` types. `InspectionView` retains unavailable coverage and a separate latest attempt. Refusals are bounded retained counts; runtime metrics are at least once and use no identifiers. The eight-case runner records current-run facts atomically in `acceptance.json`; permission and command subjects have independent workflow parents so one wait cannot mask the other.

Qualification discovery: when advancing to an approval deadline, another schedule timer can be due first. The integrated fixture uses the production multi-kind dispatcher, temporarily refuses incidental schedule admission, and admits the following tick under the original policy. A single-timer call against only the approval handler would leave the approval pending and would not qualify expiration. This is fixture construction, not a production timeout-policy change.

Final regression discovery: the checked-in OpenAPI artifact lagged the existing objective inspection schema. Regeneration adds AdaptiveView/decision/observation, placement and resource view definitions plus the existing ObjectiveView.adaptive property; it adds no route. The API artifact equality test exposed this documentation drift. Regenerate with the owning `shikigami-openapi` executable and rerun API/client/server checks; the passed core, PostgreSQL, worker and agent suites need no repeat for that generated-document correction.
