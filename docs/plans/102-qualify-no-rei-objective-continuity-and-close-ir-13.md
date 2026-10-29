---
id: 102
slug: qualify-no-rei-objective-continuity-and-close-ir-13
title: "Qualify no-Rei objective continuity and close IR-13"
kind: exec-plan
created_at: 2026-10-29T00:19:50Z
intention: "intention_01m62265gjex4a0k54gsbwx4gs"
master_plan: "docs/masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-29T00:19:50Z
---

# Qualify no-Rei objective continuity and close IR-13

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

After this plan, a fresh reader can reproduce the IR-13 outcome with no Rei endpoint configured: an isolated runner creates a two-assignment objective through the serving API, drives authorized progress through real workers, restarts the service, continues the objective from a second run and a conversation, survives a lost acknowledgement and a stale concurrent update, and prints the final checkpoint with its original evidence and attribution. It then shows that two successful workers leave the objective open while one integrated criterion fails, and that only explicit authorized acceptance of the exact combined artifact completes it once. Operator and user documentation describe the feature, the OKF bundles record IR-13 as completed with its delivered scope, consumer plans link the real provider, and durable decisions are distilled into ADRs. This is EP-5 of [MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md), which calls IR-13's "major task" an objective.


## Progress

- [ ] Milestone 1: the fixture under `fixtures/qualification/objectives/` and the isolated runner `tests/objective-tracking/run.sh` reproduce continuity with no Rei endpoint, including the lost-acknowledgement and stale-conflict scenarios with the accepted result preserved across an assignment ownership transfer.
- [ ] Milestone 2: integrated completion is proven: all-green workers with one failing criterion leave the objective open; a passing verifier result for the exact combined artifact plus explicit acceptance produce one `Completed` transition; stale, unknown-operation and repeated acceptance behave as specified; cancellation preserves late facts.
- [ ] Milestone 3: documentation, OKF bundle updates, consumer-plan wording, ADR distillation, friction triage and the compatibility gates establish the delivered IR-13 boundary, and IR-13 is `completed`.

Planning baseline `3900c0e634d9b559e92a6989bb10f9943e0beab1`, inspected 2026-10-28. No implementation or test results are claimed. Hard prerequisites: plans 99, 100 and 101 Complete.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Objective acceptance in this qualification requires no real repository writes; the fence fixture stays explicitly labeled, and this plan never marks IR-11, plan 96 or plans 84–87 complete from its results.
  Rationale: Real workspace fencing belongs to plan 96 and the joint late-writer test to plan 84; claiming them here would be false evidence.
  Date: 2026-10-28

- Decision: IR-13 becomes `completed` only in this plan, with its delivered scope recorded precisely, and the bundle log and index change in the same commit.
  Rationale: The corpus lifecycle used by IR-11 and IR-15; `in-progress` was set at the first implementation commit under MasterPlan 17.
  Date: 2026-10-28


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

An objective is a goal spanning executions; an assignment is a versioned piece of it with a designated owner; a checkpoint is the authoritative current view; a receipt is the committed result of one keyed command. By the time this plan starts, plan 98 supplies the store and command owner under `shikigami-core/src/Shikigami/Objective/`, plan 99 the trusted associations and the providers `Objective/Checkpoint.hs`, `Objective/Ownership.hs` and `Objective/Coordination.hs` wired into `shikigami-workers/src/Shikigami/Workers/Config.hs` and `shikigami-server/src/Shikigami/Server/Command/Workers.hs` behind the operator enablement setting in `shikigami-core/src/Shikigami/App/Config.hs`, plan 100 the `/objectives` vertical and `shikigami objectives` CLI, and plan 101 the native `objectives` tool and `Shikigami.Flow.Objectives`. Read each plan's Interfaces and Dependencies before writing the fixture.

Rei is optional: the existing `ReiAction` sink described in `docs/user/sinks.md` records against a known Rei intention when an endpoint is configured; objectives persist only an optional typed external link, and a Rei failure never changes objective state. `tests/hurl/run.sh` is the existing isolated HTTP runner and the model for the new runner: it provisions disposable resources, honors `SHIKIGAMI_CABAL_PROJECT` and cleans up what it created. `docs/user/README.md` indexes user documentation, `docs/operations/operator-cli.md` documents operator commands, `docs/architecture/shikigami-domain-inventory.md` lists domains, `docs/use-cases/adaptive-autonomous-delivery.md` is UC-1 and `docs/roadmap.md` the portfolio view. `docs/improvement-requests/` is a profile-governed OKF bundle validated by `just improvement-requests-validate`, with `index.md` and `log.md` maintained by hand as in the 2026-10-28 IR-11 update; `docs/use-cases/` and `docs/user/` are validated by `just use-cases-validate` and `just user-docs-validate`. The ADR bundle in `docs/adr/` is Markdown, not profile-governed.

Consumer plans: [plan 84](84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md) had its IR-13 gate closed by plan 99 and keeps its IR-11 gate; [plan 96](96-provide-governed-mutable-repository-workspaces-for-durable-agents.md) owns real fencing; [plans 85](85-adapt-durable-delivery-through-validated-coordinator-decisions.md) and [87](87-supervise-recurring-objectives-from-current-durable-checkpoints.md) consume the provider and `Shikigami.Objective.Acceptance`; [MasterPlan 14](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md) records the prerequisite. Relevant decisions: [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md), [ADR 0047](../adr/0047-public-api-authentication-is-a-verifier-at-the-vertical-mount.md), [ADR 0061](../adr/0061-continuing-sessions-own-ordered-assignments-and-retained-receipts.md), [ADR 0062](../adr/0062-session-generations-await-governed-children-and-retain-checkpoint-intents.md), [ADR 0063](../adr/0063-handoffs-establish-epochs-only-after-fences-and-versioned-owner-receipts.md) and [ADR 0066](../adr/0066-worker-commands-require-retained-scopes-and-fresh-exact-authority.md); this plan adds the ADRs that MasterPlan 17 identifies as cross-plan decisions.


## Plan of Work

### Milestone 1 — The no-Rei continuity fixture and runner

Add a reproducible fixture under `fixtures/qualification/objectives/` (at least `create.json`, command and evidence JSON matching plan 100's public schema, scripted model responses and authenticated caller configuration) and an isolated runner `tests/objective-tracking/run.sh`. The runner provisions only disposable resources, selects scripted model responses and authenticated objective callers, honors `SHIKIGAMI_CABAL_PROJECT`, and uses the serving API and workers with the real objective and session stores. It creates a two-assignment finite objective, runs authorized progress, restarts the service, continues from a second run and a conversation, and prints the objective ID, final revision, original and replayed receipt IDs and final status without protected payloads. It replays plan 99's lost-acknowledgement and stale-conflict scenario and preserves the accepted result across an assignment ownership transfer; the fence fixture remains explicitly labeled, and no real repository writes are required. Its real API path also exercises the CLI's shared command owner. Milestone 1 is accepted when the runner exits zero and reports the unauthorized cases refused, the stale cases conflicted and the continued objective at its expected revision.

### Milestone 2 — Integrated completion

Extend the runner: report both workers successful while one integrated criterion fails, and verify the objective remains open. Record a passing verifier result for the exact combined artifact and current criteria, submit explicit authorized acceptance and observe exactly one `Completed` transition. Submit an older completion command and verify it cannot close an objective whose criteria changed. Leave an unknown child or tool operation unresolved and verify acceptance is blocked. Repeat the acceptance and verify it returns its original receipt. Cancel a separate objective and verify new work stops while late facts and unresolved operations are preserved without any claim that external effects stopped. Milestone 2 is accepted when the runner prints the failed integrated acceptance still open and the final explicit acceptance completed.

### Milestone 3 — Documentation, bundles, ADRs and gates

Write `docs/operations/objective-tracking.md` and `docs/user/objectives.md`, describing configuration, commands, role boundaries, operation-key retry rules, conflict reconciliation, protected evidence, retention and the distinction between objective and assignment, run, memory session, conversation, Rei intention and A2A task. Update `docs/user/README.md`, `docs/operations/operator-cli.md`, `docs/architecture/shikigami-domain-inventory.md`, IR-13, UC-1, `docs/roadmap.md`, and the MasterPlan 14, plan 84 and plan 96 prerequisite wording to link this provider and its actual evidence. Do not mark IR-11, plan 96 or plans 84–87 complete from this plan's results. Set IR-13 to `completed`, record its delivered scope precisely, and update `docs/improvement-requests/log.md` and `index.md` in the same change. Maintain OKF profile metadata, timestamps, indexes and logs for every changed profiled document with the repository's existing commands.

Add or update ADRs for objective ownership inside Shikigami, receipt-before-revision ordering under authentication, the mapping from objective assignment to session assignment, assignment-scoped conflict with explicit reconciliation, and integrated completion as the only terminal path, drawing on the Decision Logs of plans 98–101 and MasterPlan 17. Triage the friction entries recorded under plans 98–102 with the exec-plan skill's `record-friction.ts update`, cite them in each plan's Outcomes & Retrospective, and record recurring friction in MasterPlan 17. Milestone 3 is accepted when the isolated runner, the relevant package suites and the ordinary compatibility and documentation gates pass, and a fresh reader can reproduce continuity with no Rei endpoint configured.


## Concrete Steps

Run commands from the repository root, `/Users/shinzui/Keikaku/bokuno/shikigami`, inside `nix develop --no-write-lock-file` if needed. Capture `git rev-parse HEAD` as the implementation baseline. If the checked-in project cannot resolve its co-developed dependencies, follow `docs/dependency-cohort.md` and plan 98's local-project convention, set `SHIKIGAMI_CABAL_PROJECT=.dev/mp13.cabal.project` for both runners, and record the chosen project in evidence. Build and run the runners:

```bash
cabal build all
just hurl
bash tests/objective-tracking/run.sh
```

The objective runner must exit zero and print the objective ID, final revision, original and replayed receipt IDs and final status, the refused unauthorized cases, the conflicted stale cases, the failed integrated acceptance still open and the final explicit acceptance completed. Its smoke invocation uses the CLI, keeping the same create key across retries so creation returns the same objective:

```bash
cabal run shikigami -- objectives create --operation-key ir13-demo-create --file fixtures/qualification/objectives/create.json --json
cabal run shikigami -- objectives inspect OBJECTIVE_ID_FROM_CREATE --json
```

The fixture documents its isolated configuration and replaces the placeholder with the returned ID. At the final boundary, run the complete suites and gates against the saved baseline:

```bash
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-server-test shikigami-workers-test shikigami-agent-test --test-show-details=direct --test-options='--num-threads=1'
just keiro-gate IMPLEMENTATION_BASELINE
just improvement-requests-validate
just use-cases-validate
just user-docs-validate
git diff --check
```

All commands must exit zero, and the gate report must contain no unexplained breaking findings. Every commit follows Conventional Commits and ends with:

```text
MasterPlan: docs/masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md
ExecPlan: docs/plans/102-qualify-no-rei-objective-continuity-and-close-ir-13.md
Intention: intention_01m62265gjex4a0k54gsbwx4gs
```


## Validation and Acceptance

The user's outcome: with no Rei configuration, the objective outlives runs and process restarts, preserves authorship and evidence, and completes only after explicit current integrated acceptance. The real objective provider closes the IR-13 prerequisite; it does not claim an IR-11 late-writer test, an adaptive coordinator or a recurring scheduler that this repository has not delivered. Required acceptance is the zero exit of `tests/objective-tracking/run.sh` with the transcript described above, the passing package suites, the passing compatibility and documentation gates, IR-13 recorded as `completed` with validated bundle metadata, and the ADRs committed. Record actual passing counts and fixture output only after running them.


## Idempotence and Recovery

The runner owns and cleans up only resources it created and can be rerun from scratch. The same create key across retries returns the same objective. Documentation and bundle edits are repeatable; rerun the validate recipes after each change. If a gate fails, fix the cause or record the blocked prerequisite explicitly; never weaken a gate or mark a consumer plan complete to make the closure pass.


## Interfaces and Dependencies

Hard prerequisites: plans 99, 100 and 101 Complete. Soft: plan 96's `WorkspaceProvider` for a real fence, which this plan does not require. This plan adds no new domain modules; it owns the fixture, the runner, the documentation pages, the IR-13 lifecycle transition to `completed` and the ADR distillation for MasterPlan 17. Consumers: MasterPlan 14's EP-6 may reuse the fixture; plan 84 keeps its own joint late-writer test. Dependencies and cohort are unchanged.
