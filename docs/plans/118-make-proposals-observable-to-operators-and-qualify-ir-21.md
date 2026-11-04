---
id: 118
slug: make-proposals-observable-to-operators-and-qualify-ir-21
title: "Make proposals observable to operators and qualify IR-21"
kind: exec-plan
created_at: 2026-11-04T18:38:36Z
intention: "intention_01m6kxnhhjekdvwtpnm74m8d46"
master_plan: "docs/masterplans/20-propose-unrequested-work-from-observed-activity-under-governed-standing-policies.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-11-04T18:38:36Z
---

# Make proposals observable to operators and qualify IR-21

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

An agent that proposes work nobody asked for must be more visible than one that was asked. After plans 114 through 117 the proposer observes, proposes and, under a policy, admits, but an operator still cannot list what it skipped and why, cannot see whether an observer's attention window or a policy's totals are exhausted without reading tables, cannot tell from metrics whether proposals are flowing or being refused, and has no guide that says how to enable the agent, size its allowance, install a policy and stop it. After this plan `shikigami proposals list|inspect|candidates|admissions|prune --json` page the ledger and show each observer's window usage and each policy's remaining totals with an explicit `exhausted` state; exported metrics count candidates by verdict, proposals by status, admissions and refusals by kind; the operations guide, the user guide, the capability record and the use case describe the path from a message to a proposal to an objective and how to stop it at every stage; and every one of the nine [IR-21](../improvement-requests/propose-unrequested-work-from-observed-activity.md) acceptance cases has evidence from an integrated run through the real stream intake, run queue and approval resolution, after which the request is marked completed.

You can see it working with the worker and PostgreSQL suites running and then `cabal run shikigami -- proposals inspect --json`, which prints the observers with their usage and limits, the live policies with remaining totals and admissions, and the count of pending proposals; `cabal test shikigami-workers-test --test-options='-p InitiativeAcceptance'` runs the nine acceptance cases end to end and writes their evidence under `docs/evidence/plan-118/`. This plan is EP-5 of [MasterPlan 20](../masterplans/20-propose-unrequested-work-from-observed-activity-under-governed-standing-policies.md). It requires [plan 117](117-admit-bounded-objectives-autonomously-under-explicit-revocable-standing-policies.md) to be Complete, because inspection reads admissions and policies, the metrics hooks are installed on plan 116's and 117's interpreter, and the acceptance runner drives real admissions.


## Progress

- [ ] Milestone 1: Bounded ledger readers, the inspection views and the `shikigami proposals` read verbs exist; `inspect` shows exhausted observers and policies explicitly and `prune` removes only skip rows older than a given instant.
- [ ] Milestone 2: Metrics for candidates, proposals, admissions and refusals are recorded through the `Initiative` hooks and exported; the operations guide, user guide, capability record and use case are written and the catalogs validate.
- [ ] Milestone 3: The integrated acceptance runner proves all nine IR-21 cases with evidence under `docs/evidence/plan-118/`; IR-21 is marked completed and MasterPlan 20's registry and retrospective are updated.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: An exhausted limit is a visible state of the ledger and the command output, not a probe condition or a silent skip.
  Rationale: IR-21 item 8 says an exhausted limit stops evaluation visibly. [ADR 0020](../adr/0020-readiness-covers-only-what-restarting-can-fix.md) restricts readiness to what restarting fixes, which an exhausted window is not; the skip row, the inspect output and the refusal metric together make the stopped state observable.
  Date: 2026-11-04


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a Cabal multi-package Haskell service; the operator binary `shikigami` is `shikigami-server`, its command tree is `shikigami-server/src/Shikigami/Server/Command.hs`, and each noun's verbs wrap the owning library ([ADR 0021](../adr/0021-operator-verbs-wrap-the-owning-library.md)). Plan 117 created `shikigami-server/src/Shikigami/Server/Command/Proposals.hs` with the `policy install|revoke|list` verbs and the pattern for acting as the configured local operator (`withObjectives` in `Server/Command/Objectives.hs` is the original model). Every composition module is listed in `tools/style/module-ownership.json`; the `Proposals` module already is.

Plans 114 through 117 supply the ledger (`shikigami.initiative_candidates`, `initiative_proposals`, `initiative_observers`, `initiative_standing_policies`, `initiative_admissions`), `Shikigami.Initiative.Ledger` (writers plus `readProposal`, `readPendingByKey`, `checkWindows` returning `WindowUsage {evaluations, proposals, notifications, exhausted}`), `Shikigami.Initiative.Policy` (`listPolicies`, `coveringPolicies`, `PolicyView`), `Shikigami.Initiative.Settings` (`InitiativeSettings`, `ObserverAllowance`), the views `CandidateView`, `ProposalView` and `AssessmentView`, the `Initiative` capability with `InitiativeHooks {onCandidate, onProposal, onRefusal}` (no-ops by default), the `propose-work` Flow, `agents/proof/proposer.dhall`, the chat fixture source `fixture/chat` and the stub decision answers for model id `stub-propose`.

Metrics are OpenTelemetry instruments on the `ShikigamiMetrics` record in `shikigami-core/src/Shikigami/Telemetry/Metrics.hs`, created once (`meterCreateCounterInt64 meter "shikigami.runs.started" ...`), named `shikigami.<noun>.<verb>`, with only bounded attributes (never ids, excerpts, URLs or error text). The worker role builds them in `shikigami-workers/src/Shikigami/Telemetry.hs` and samples process-level gauges in `shikigami-workers/src/Shikigami/Telemetry/Sampler.hs`; `shikigami-workers/test/Shikigami/TelemetrySpec.hs` proves a force-flush exports every instrument. Export is OTLP when `OTEL_EXPORTER_OTLP_ENDPOINT` is set and a no-op otherwise. Health probes are fixed by [ADR 0019](../adr/0019-a-loop-that-stops-stops-the-process.md) and [ADR 0020](../adr/0020-readiness-covers-only-what-restarting-can-fix.md) and do not change.

Documentation is three OKF bundles plus plain guides: the capability catalog `docs/capabilities/` (`CAP-N` handles allocated with `okf id next docs/capabilities CAP --profile docs/capabilities/profile.dhall`, validated by `just capabilities-validate`, indexed by `just capabilities-index`, maintained per `docs/capabilities-maintenance.md`), the use cases `docs/use-cases/` (`docs/use-cases/adaptive-autonomous-delivery.md` is UC-1 with a `features` list and `jobs`; `just use-cases-validate` and `just use-cases-index`), the user guides `docs/user/` (`just user-docs-validate`, `just user-docs-index`; `docs/user/triggers.md`, `docs/user/flows.md`, `docs/user/objectives.md` are the neighbours), and the improvement requests `docs/improvement-requests/` (`just improvement-requests-validate`, `just improvement-requests-index`, with `log.md` entries appended by hand in the bundle's dated format, as the entries for IR-13 and IR-15 show). `docs/operations/` holds plain-Markdown runbooks (`objective-tracking.md`, `operator-cli.md`, `execution-resources.md` are the models). Evidence for a plan lives under `docs/evidence/plan-<N>/` as JSON files plus an `acceptance.md` (see `docs/evidence/plan-108/`).

The worker and PostgreSQL suites register groups in `shikigami-workers/test/Main.hs` and `shikigami-core/test-postgres/Main.hs`. Plan 116's `shikigami-workers/test/Shikigami/ProposeWorkSpec.hs` and plan 117's `AdmitProposalSpec.hs` drive the path from `processDecodedActivity` through the worker; the approval child is resolved in tests by calling `Shikigami.Agent.Approval.resolveApproval` with the token the recording notifier captured, and its timeout by firing the timer as `AgentWorkflowSpec.hs` does. Friction to expect: PostgreSQL connection exhaustion under parallel suites (FRIC-2, FRIC-5, FRIC-17, FRIC-51 in `docs/friction-log/`) and, for the optional native trial, the frozen-runtime rebuild cost recorded in FRIC-54 through FRIC-56.


## Plan of Work

### Milestone 1: Readers, views and read verbs

Add to `Shikigami.Initiative.Ledger` the bounded, lock-free, keyset-paged readers: `listProposals :: Maybe AgentPrincipal -> Maybe ProposalStatusFilter -> Maybe ProposalId -> InitiativeLimit "page" -> Transaction [ProposalView]`, `listCandidates :: AgentPrincipal -> Maybe UTCTime -> Maybe ActivityId -> InitiativeLimit "page" -> Transaction [CandidateView]`, `listAdmissions :: Maybe StandingPolicyId -> Maybe ProposalId -> InitiativeLimit "page" -> Transaction [AdmissionView]` (plan 117's rows rendered as a `Generic` view with stage, objective, root and workflow ids as text), `observerUsage :: ObserverAllowance -> UTCTime -> Transaction ObserverUsageView` (the window counts, the limits, and `exhausted :: [Text]` naming each exhausted limit, computed with the same `checkWindows` arithmetic but without the anchor lock), `policyUsage :: StandingPolicy -> UTCTime -> Transaction PolicyUsageView` (admissions in window, limit, reserved totals per dimension, remaining per dimension, `exhausted`), and `pruneCandidatesBefore :: UTCTime -> InitiativeLimit "pruneBatch" -> Transaction Int`, which deletes only rows whose verdict is `skipped` or `not-actionable` and whose `recorded_at` is before the instant, at most a batch at a time, so skip rows stay bounded over time. Page sizes are capped at 100 like the objective readers. Create `Shikigami.Initiative.Inspection` with `InspectionView {observers :: [ObserverUsageView], policies :: [PolicyUsageView], pendingProposals :: Int, inspectedAt :: UTCTime}` and `inspect :: Maybe InitiativeSettings -> UTCTime -> Transaction InspectionView`, which lists every configured observer (an observer with no rows shows zero usage, so a quiet system is distinguishable from an absent one) and every live policy.

Extend `Shikigami.Server.Command.Proposals`:

```text
shikigami proposals list [--principal P] [--status pending|accepted|admitted|rejected|expired|refused] [--after ID] [--limit N] [--json]
shikigami proposals inspect [--json] [--fail-when-exhausted]
shikigami proposals candidates --principal P [--since ISO8601] [--after ACTIVITY_ID] [--limit N] [--json]
shikigami proposals admissions [--policy ID] [--after PROPOSAL_ID] [--limit N] [--json]
shikigami proposals prune --before ISO8601 [--batch N] [--json]
```

`inspect --fail-when-exhausted` exits nonzero when any observer or live policy reports an exhausted limit, so an operator's periodic check can alarm on the stopped state. Read verbs need the database and migrations but not the local operator identity, since they reveal no excerpt or body (the ledger stores none); `prune` requires the configured local operator like the objective commands. Register the verbs in `proposalsInfo`. Tests in `shikigami-server/test`: option parsing for each verb; with a fixture ledger (reuse plan 116's and 117's fixtures through the PostgreSQL suite if the server suite has no database, else add the cases to `shikigami-core/test-postgres/Shikigami/InitiativeInspectionSpec.hs`): `inspect` on an empty ledger lists the configured observer with zero usage and no policy; after an evaluation window is exhausted it lists `evaluations` under `exhausted` and `--fail-when-exhausted` exits nonzero; `candidates` pages in `recorded_at` order with a stable cursor; `prune --before` removes skip rows but never `evaluating`, `proposed` or proposal rows.

### Milestone 2: Metrics and documentation

Add to `ShikigamiMetrics`: `initiativeCandidates` (counter, attribute `verdict` in `skipped`, `evaluating`, `proposed`, `not-actionable`, and `skip.reason` as the kebab-case `SkipReason` tag without its payload), `initiativeProposals` (counter, attribute `status` in `pending`, `accepted`, `admitted`, `rejected`, `expired`, `refused`), `initiativeAdmissions` (counter, attribute `stage`) and `initiativeRefusals` (counter, attribute `refusal.kind`). Install them through `InitiativeHooks` in `shikigami-workers/src/Shikigami/Workers/Config.hs` when telemetry is configured, and record the consumer-side skips from `Shikigami.Trigger.Consumer` through the same hook record passed into the intake call (plan 114's `disposition` caller), so a skip recorded at intake and a skip recorded in the Flow use one instrument. Extend `TelemetrySpec`: a force-flush after a recorded candidate, proposal, admission and refusal exports the four counters with their attributes; confirm no attribute carries a proposal id, policy id, activity id, excerpt or error text.

Write `docs/operations/unrequested-work.md`: what the proposer is and is not (it observes `activity.v1`, it proposes, it never acts without a person or a policy); enabling it (the `initiatives` settings object with a worked allowance, the principal in `objectives.agentCreation`, the C11 Kizashi grant for notices, the approval channel, promoting `agents/proof/proposer.dhall` into `agents/` and changing its source to `external/intercom` or `external/transcripts`, the `propose` alias in `behavior.decisionModels`); sizing the allowance (evaluation envelope, windows, expiry, suppression) with the reasoning that an evaluation is one model call; installing, listing and revoking a standing policy with a complete `policy.json` example and the rule that a changed policy is a new policy; reading `proposals inspect`, `list`, `candidates` and `admissions`; stopping at each stage (remove the allowance, revoke the policy, reject a proposal, cancel the admitted objective with `shikigami objectives command`, cancel its root with `shikigami resources`); pruning; and the metrics with suggested alerts on `initiativeRefusals` and on `inspect --fail-when-exhausted`. Add a `proposals` entry to `docs/operations/operator-cli.md`. Write `docs/user/unrequested-work.md` in the user bundle (frontmatter like `docs/user/flows.md`) explaining what a person sees (the ask's first line, the evidence coordinates, the accept and reject commands), what acceptance does and does not do, and what an admitted objective looks like; link it from `docs/user/triggers.md`'s stream section and from `docs/user/objectives.md`. Allocate a `CAP-N` handle and write `docs/capabilities/unrequested-work-proposals.md` with `status: shipped`, `stability: experimental`, `since: unreleased`, evidence pointing at the specs this initiative added and a `Limits` section that states the sources supported, that observation runs only on `activity.v1`, that admission never publishes and that totals are reservations not measurements; regenerate the index and validate. Add a `propose-unrequested-work` feature to `docs/use-cases/adaptive-autonomous-delivery.md` (status `delivered` only after milestone 3, `in-progress` until then) linking `mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-21`, and refresh `docs/capabilities-coverage.md` for the new modules and verbs. Update `docs/README.md`'s reader table with the new guide and `docs/roadmap.md` if it lists IR-21.

### Milestone 3: Integrated acceptance and closure

Create `shikigami-workers/test/Shikigami/InitiativeAcceptanceSpec.hs`, one tasty group with nine cases named `IR-21 acceptance N: <phrase>`, each driving the real path: `processDecodedActivity` with a fixture envelope for the proposer declaration, the queue worker draining the run, the stub decision provider, the recording approval notifier, `resolveApproval` for answers and the timer worker for expiry, and for admission a policy installed through `installPolicy` naming the harness coordinator. Each case writes a bounded JSON evidence file under `docs/evidence/plan-118/` (ids, counts, statuses, step names, never excerpts) and asserts:

1. A chat fixture describing a reproducible double-click bug, not addressing the agent, yields one pending proposal whose evidence references name the fixture activity; no objective exists; after `--approve`, exactly one objective exists, its `external` names the proposal and the source, and the proposal is `accepted` with that objective id.
2. With no standing policy installed, a fixture of every kind (bug report, planted instructions, restatement) creates no objective and no run job for any coordinator before approval, and approval creates an objective with no assignment, no root and no run.
3. With a policy installed, the equivalent bug fixture yields one objective with one `Pending` assignment, one root equal to the policy's per-objective envelope, one queued coordinator run with the association and root, one admission at `launched`, and no sink intent other than the admission notice, no workspace publication row and no pull request anywhere.
4. Fixtures whose text says to ignore limits, to target another repository, to notify another channel and to act for their author yield proposals whose repository is in the catalog, whose ask goes to the configured channel and recipient, whose objective owner is the proposer principal, and, under a policy, whose admission uses the policy's repository and coordinator; scope, repository, recipient and authority equal the control fixture's.
5. Short, agent-authored, unsupported-source and not-actionable fixtures leave skip rows with their reasons, no run job (for intake skips), no approval child and no outbox intent; the recording notifier captured nothing.
6. Delivering one envelope twice (same activity id), crashing the run after `decision-result-propose` and resuming, and delivering three restatements by three authors yield one proposal, one decision invocation and one approval child.
7. With an accepted proposal whose objective is open, a restatement is `already-owned`; after the objective is cancelled through the objective owner, a restatement proposes again.
8. With `evaluationsPerWindow = 1`, the second conversation is `evaluations-exhausted` and `proposals inspect --fail-when-exhausted` exits nonzero; with `admissionsPerWindow = 1`, the second covered proposal records `AdmissionsExhausted` and parks for a person; `initiativeRefusals` was incremented.
9. After `--reject`, a restatement is `suppressed` until the suppression instant and proposes after it; after `proposals policy revoke`, the next covered proposal parks for a person while the earlier admitted objective, assignment and root are unchanged; a policy whose `expiresAt` has passed behaves the same way.

Optionally, if an Apple container or the configured remote builder is available, run plan 86's native fixture (`tests/workspace/prototype`, see `AGENTS.md`) with one admitted objective and record whether the coordinator's first assignment produced a retained artifact and no publication; record the result as additional evidence, not as acceptance. Write `docs/evidence/plan-118/acceptance.md` summarizing each case with the commands run and the baseline commit. Then set IR-21's frontmatter `status` to `completed`, add a dated `Completion` entry to `docs/improvement-requests/log.md`, regenerate and validate the bundle, mark the use-case feature `delivered`, update MasterPlan 20's registry, Progress gates and Outcomes & Retrospective, triage this initiative's friction entries, and perform the ADR distillation pass the MasterPlan requires (confirm the ADRs plans 116 and 117 wrote cover the Decision Log; add one only if a durable decision is still unrecorded).


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
cabal test shikigami-server-test --test-show-details=direct --test-options='-p Proposals'
cabal test shikigami-core-postgres-test --test-show-details=direct --test-options='-p InitiativeInspection --num-threads 1'
cabal run shikigami -- proposals inspect --json
```

Expected: the inspection prints the configured observers, the live policies and the pending count; with an exhausted fixture, `--fail-when-exhausted` exits nonzero.

After milestone 2:

```bash
cabal test shikigami-workers-test --test-show-details=direct --test-options='-p Telemetry'
okf id next docs/capabilities CAP --profile docs/capabilities/profile.dhall
just capabilities-index && just capabilities-validate
just use-cases-index && just use-cases-validate
just user-docs-index && just user-docs-validate
```

After milestone 3:

```bash
cabal test shikigami-workers-test --test-show-details=direct --test-options='-p InitiativeAcceptance'
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-workers-test shikigami-server-test shikigami-agent-test --test-show-details=direct
just improvement-requests-index && just improvement-requests-validate
ls docs/evidence/plan-118/
```

Expected: nine passing cases and nine evidence files plus `acceptance.md`; every bundle validates; the full suites exit zero. Commit at milestone boundaries:

```text
feat(initiative): expose proposals to operators and qualify IR-21

MasterPlan: docs/masterplans/20-propose-unrequested-work-from-observed-activity-under-governed-standing-policies.md
ExecPlan: docs/plans/118-make-proposals-observable-to-operators-and-qualify-ir-21.md
Intention: intention_01m6kxnhhjekdvwtpnm74m8d46
```


## Validation and Acceptance

The nine integrated cases are IR-21's acceptance list verbatim, each proved through the real intake, worker, approval and admission paths with the stub provider and fixture channel. Observability acceptance: `proposals inspect` distinguishes a quiet observer (zero usage) from an exhausted one and from an absent one, `--fail-when-exhausted` makes the stopped state a nonzero exit, and the four instruments export with bounded attributes. Documentation acceptance: every bundle validates and the operations guide's commands run as written against a fixture database. Required acceptance is the named groups, the bundle validations and the full suites exiting zero; the native trial is optional evidence.


## Idempotence and Recovery

Readers take no locks and page by key, so they can be run at any time. `prune` is bounded per batch and deletes only terminal skip rows, so a repeated prune is safe and a mistaken instant removes only skips, never proposals or admissions. Metrics recording is unconditional and backed by a no-op provider when telemetry is off. The acceptance runner uses a fresh database per run through the existing fixture, so it is repeatable; its evidence files are overwritten deterministically. If a case fails, fix the owning child plan's surface and re-run the whole group rather than editing the evidence.


## Interfaces and Dependencies

This plan owns the ledger readers (`listProposals`, `listCandidates`, `listAdmissions`, `observerUsage`, `policyUsage`, `pruneCandidatesBefore`), `Shikigami.Initiative.Inspection`, the `list`, `inspect`, `candidates`, `admissions` and `prune` verbs of `Shikigami.Server.Command.Proposals`, the four `ShikigamiMetrics` instruments and their hook installation, `docs/operations/unrequested-work.md`, `docs/user/unrequested-work.md`, the `CAP-N` capability record, the use-case feature, the coverage census update, `shikigami-workers/test/Shikigami/InitiativeAcceptanceSpec.hs`, `docs/evidence/plan-118/` and the IR-21 completion. It consumes plans 114 through 117 unchanged and requires plan 117 to be Complete. It adds no new tables, no new durable body steps and no new authority. Dependency source lookup starts with Mori: `mori registry show shinzui/okf-profiles --full` for the capability and improvement-request profiles, and `mori registry docs shinzui/keiro-runtime-patterns` for the operations-console and test-layout standards.
