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
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-29T12:59:01Z
      verdict: "comments"
      note: "Qualification is well scoped; add first-objective creation by an unassociated authorized agent and instruction-only stale-checkpoint regression coverage."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-29T13:05:53Z
      mode: "update"
      note: "Qualify autonomous first-objective recovery and instruction-only checkpoint invalidation alongside API continuity."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-02T08:51:23Z
      mode: "implement"
      note: "Qualify serving-process continuity, autonomous creation and integrated completion after completed plans 99–101."
---

# Qualify no-Rei objective continuity and close IR-13

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

After this plan, a fresh reader can reproduce the IR-13 outcome with no Rei endpoint configured: an isolated runner creates a two-assignment objective through the serving API, drives authorized progress through real workers, restarts the service, continues the objective from a second run and a conversation, survives a lost acknowledgement and a stale concurrent update, and prints the final checkpoint with its original evidence and attribution. It then shows that two successful workers leave the objective open while one integrated criterion fails, and that only explicit authorized acceptance of the exact combined artifact completes it once. Operator and user documentation describe the feature, the OKF bundles record IR-13 as completed with its delivered scope, consumer plans link the real provider, and durable decisions are distilled into ADRs. This is EP-5 of [MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md), which calls IR-13's "major task" an objective.


## Progress

- [x] Milestone 1 (2026-11-02 UTC): the fixture under `fixtures/qualification/objectives/` and the isolated runner `tests/objective-tracking/run.sh` reproduce continuity with no Rei endpoint, including first-objective agent creation, the lost-acknowledgement and instruction-only stale-conflict scenarios with the accepted result preserved across an assignment ownership transfer.
- [x] Milestone 2 (2026-11-02 UTC): integrated completion is proven: all-green workers with one failing criterion leave the objective open; current authorized review evidence for the exact combined artifact plus explicit acceptance produce one `Completed` transition; stale, unknown-operation and repeated acceptance behave as specified; cancellation preserves late facts.
- [x] Milestone 3 (2026-11-02 UTC): documentation, OKF bundle updates, consumer-plan wording, ADR distillation, friction triage and the compatibility gates establish the delivered IR-13 boundary, and IR-13 is `completed`.

Implementation baseline `fdf5119`, inspected 2026-11-02 UTC. Plans 99, 100 and 101 are Complete. Milestones 1–2 are qualified: the disposable runner exits zero, preserves first creation across SIGKILL and service restart, continues through associated runs and bound turns with memory unavailable, and reaches explicit integrated completion at revision 12. All 52 objective/provider cases pass, including instruction-only invalidation, deterministic-fence ownership recovery, terminal late facts and a real unacknowledged inspection that blocks acceptance even after logical success. [Serving transcript](../evidence/plan-102/serving-qualification.txt) retains bounded evidence. All final checks pass: 639 core, 35 API, 503 PostgreSQL, 103 server, 280 worker and 37 agent tests (1,597 total), complete build, Hurl/CLI smoke and 169 native conformance checks. The baseline `fdf5119` diff has no findings and neutral replay impact. Request/use-case/user bundles and strict friction validation pass. IR-13 is completed with its delivered scope; [qualification](../evidence/plan-102/qualification.json) records the evidence. This plan is Complete.


## Surprises & Discoveries

2026-11-02 UTC: A real rootless creating execution lost the acknowledgement of committed evidence. With the objective's own unresolved list empty, explicit acceptance returned a Completed receipt while the execution owner still retained the unacknowledged attempt. The regression now requires refusal before and after logical execution success, then delivers the original worker's retained output under its actual dispatch claim and requires the identical acceptance operation to succeed only after that late receipt settles. Logical success alone does not clear a superseded attempt's pending receipt.


## Decision Log

- Decision: Before committing an otherwise valid new acceptance, inspect the linked retained source owners: bound resource roots, the creating execution or recorded turn, associated runs and bound turn admissions. Check the same facts again inside the objective commit; preserve receipt-first recovery. Unsettled sources abort without retaining a definitive negative acceptance receipt.
  Rationale: A checkpoint is historical and may not yet project an execution's live uncertainty. Rootless finite objectives also need this check. The actual late-receipt regression preserves the original owner claim and output; it does not manufacture unresolved flags or infer settlement from a replacement's logical success.
  Date: 2026-11-02

- Decision: Positive native commands can settle superseded actual attempts from their immutable objective receipt, exact revision-1 output renderer and retained dispatch claim/continuation. Mutable inspections have no command receipt and preserve uncertainty until their real original outcome arrives. Ordinary associated Skills do not acquire coordinator grants; the recorded agent behavior distinguishes them before fresh scope creation, after retained-scope recovery.
  Rationale: The serving-process crash exposed pending accounting after honest command recovery; the subsequent associated run exposed production factory admission that library fixtures had not installed. Neither logical success nor a fresh read proves the missing original receipt. The associated Skill regressions now install both production factories.
  Date: 2026-11-02

- Decision: Use public HumanVerifiable criteria and explicit authorized completer review of the actual retained worker outputs for serving integration. The store contract suite separately qualifies trusted automatic-verifier callbacks; no general automatic verifier is installed in serving hosts.
  Rationale: A scripted model result must not manufacture authoritative criterion checks. The exact combined artifact and current journey review are explicit attestations with the same acceptance/version checks.
  Date: 2026-11-02

- Decision: Objective acceptance in this qualification requires no real repository writes; the fence fixture stays explicitly labeled, and this plan never marks IR-11, plan 96 or plans 84–87 complete from its results.
  Rationale: Real workspace fencing belongs to plan 96 and the joint late-writer test to plan 84; claiming them here would be false evidence.
  Date: 2026-10-28

- Decision: IR-13 becomes `completed` only in this plan, with its delivered scope recorded precisely, and the bundle log and index change in the same commit.
  Rationale: The corpus lifecycle used by IR-11 and IR-15; `in-progress` was set at the first implementation commit under MasterPlan 17.
  Date: 2026-10-28


## Outcomes & Retrospective

Completed 2026-11-02 UTC. The disposable serving runner, real source owners and
provider matrix establish the IR-13 outcome without Rei: autonomous first
creation and actual crash recovery, durable continuation through a later run and
bound conversation with memory unavailable, explicit integrated acceptance,
current attribution and exact receipt replay. The final checkpoint is Completed
at revision 12. Both workers are green before the failed journey review refuses
acceptance; correcting the integration and providing current authorized review
permits one transition. The live unacknowledged inspection stays unresolved
after logical success until the real original receipt settles.

The complete build, all 1,597 package tests, Hurl and 169 native checks pass.
The native diff has no findings and neutral replay impact. Bundle and convention
gates pass. The user/operations guides, IR-13 index/log, UC-1, roadmap and consumer
provider references agree on the delivered boundary. ADR 0070 distills live source
settlement and independent positive command receipt recovery; ADRs 0067–0068
retain assignment preconditions, operation identity and creation before association.

No new qualifying friction was recorded under plan 102. Initiative entries are
triaged: FRIC-32 resolved formatter/generator ownership; FRIC-33 accepted inherited
strict recommended request metadata; FRIC-39 resolved migration filename gaps;
FRIC-40 resolved shared fixture selection of superseded attempts. Plans 98, 99
and 101 retain their own evidence and triage. No entry under plans 98–102 remains
logged.

The serving criteria use authorized explicit human-verifiable review; automatic
verifier callbacks remain a separate trusted producer contract. Real workspace
fencing, the joint plan 84 successor/restart gate, adaptive coordination and
recurrence remain open under their existing owners. IR-13 completion does not
complete IR-11, IR-15, plan 96 or plans 84–87.


## Context and Orientation

An objective is a goal spanning executions; an assignment is a versioned piece of it with a designated owner; a checkpoint is the authoritative current view; a receipt is the committed result of one keyed command. By the time this plan starts, plan 98 supplies the store and command owner under `shikigami-core/src/Shikigami/Objective/`, plan 99 the trusted associations and the providers `Objective/Checkpoint.hs`, `Objective/Ownership.hs` and `Objective/Coordination.hs` wired into `shikigami-workers/src/Shikigami/Workers/Config.hs` and `shikigami-server/src/Shikigami/Server/Command/Workers.hs` behind plan 98’s operator enablement setting in `shikigami-core/src/Shikigami/App/Config.hs`, plan 100 the `/objectives` vertical and `shikigami objectives` CLI, and plan 101 the native `objectives` tool and `Shikigami.Flow.Objectives`. Read each plan's Interfaces and Dependencies before writing the fixture.

Rei is optional: the existing `ReiAction` sink described in `docs/user/sinks.md` records against a known Rei intention when an endpoint is configured; objectives persist only an optional typed external link, and a Rei failure never changes objective state. `tests/hurl/run.sh` is the existing isolated HTTP runner and the model for the new runner: it provisions disposable resources, honors `SHIKIGAMI_CABAL_PROJECT` and cleans up what it created. `docs/user/README.md` indexes user documentation, `docs/operations/operator-cli.md` documents operator commands, `docs/architecture/shikigami-domain-inventory.md` lists domains, `docs/use-cases/adaptive-autonomous-delivery.md` is UC-1 and `docs/roadmap.md` the portfolio view. `docs/improvement-requests/` is a profile-governed OKF bundle validated by `just improvement-requests-validate`, with `index.md` and `log.md` maintained by hand as in the 2026-10-28 IR-11 update; `docs/use-cases/` and `docs/user/` are validated by `just use-cases-validate` and `just user-docs-validate`. The ADR bundle in `docs/adr/` is Markdown, not profile-governed.

Consumer plans: [plan 84](84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md) had its IR-13 gate closed by plan 99 and keeps its IR-11 gate; [plan 96](96-provide-governed-mutable-repository-workspaces-for-durable-agents.md) owns real fencing; [plans 85](85-adapt-durable-delivery-through-validated-coordinator-decisions.md) and [87](87-supervise-recurring-objectives-from-current-durable-checkpoints.md) consume the provider and `Shikigami.Objective.Acceptance`; [MasterPlan 14](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md) records the prerequisite. Relevant decisions: [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md), [ADR 0047](../adr/0047-public-api-authentication-is-a-verifier-at-the-vertical-mount.md), [ADR 0061](../adr/0061-continuing-sessions-own-ordered-assignments-and-retained-receipts.md), [ADR 0062](../adr/0062-session-generations-await-governed-children-and-retain-checkpoint-intents.md), [ADR 0063](../adr/0063-handoffs-establish-epochs-only-after-fences-and-versioned-owner-receipts.md) and [ADR 0066](../adr/0066-worker-commands-require-retained-scopes-and-fresh-exact-authority.md); this plan adds the ADRs that MasterPlan 17 identifies as cross-plan decisions.


The reviewed contracts are recorded in [ADR 0067](../adr/0067-objective-checkpoints-use-assignment-scoped-preconditions.md) (checkpoint preconditions and instruction invalidation) and [ADR 0068](../adr/0068-objective-creation-has-authority-before-association.md) (creation authority before association). These are accepted design decisions; implementation and acceptance evidence remain outstanding.

## Plan of Work

### Milestone 1 — The no-Rei continuity fixture and runner

Add a reproducible fixture under `fixtures/qualification/objectives/` (at least `create.json`, command and evidence JSON matching plan 100's public schema, scripted model responses and authenticated caller configuration) and an isolated runner `tests/objective-tracking/run.sh`. The runner provisions only disposable resources, selects scripted model responses and authenticated objective callers, honors `SHIKIGAMI_CABAL_PROJECT`, and uses the serving API and workers with the real objective and session stores. It creates a two-assignment finite objective, runs authorized progress, restarts the service, continues from a second run and a conversation, and prints the objective ID, final revision, original and replayed receipt IDs and final status without protected payloads. It replays plan 99's lost-acknowledgement and stale-conflict scenario and preserves the accepted result across an assignment ownership transfer; the fence fixture remains explicitly labeled, and no real repository writes are required. Its real API path also exercises the CLI's shared command owner. Milestone 1 is accepted when the runner exits zero and reports the unauthorized cases refused, the stale cases conflicted and the continued objective at its expected revision.

Milestone 1 also starts with no objectives and drives an unassociated declared Skill granted creation by operator policy. Through the actual native tool, create an objective, crash after commit before tool-result recording, recover the same objective/receipt/origin link and record progress without replacing the accepted tool binding. Continue it through a newly associated run and an explicitly bound conversation turn with memory recall disabled. Refuse a denied creator and a forged unrelated objective selector. Retain the API-created two-assignment scenario as separate surface coverage. Prepare a worker checkpoint, revise only objective instructions, and prove the old intent conflicts without evidence or cursor changes; reverting instructions does not revive it. Sibling-only progress must still permit both commits. Print these outcomes in the runner transcript so IR-13 closure cannot omit autonomous creation or instruction invalidation.

### Milestone 2 — Integrated completion

Extend the runner: report both workers successful while one integrated criterion fails, and verify the objective remains open. Record current authorized completer review evidence for the exact combined artifact and criteria, submit explicit authorized acceptance and observe exactly one `Completed` transition. Submit an older completion command and verify it cannot close an objective whose criteria changed. Leave an unknown child or tool operation unresolved and verify acceptance is blocked. Repeat the acceptance and verify it returns its original receipt. Cancel a separate objective and verify new work stops while late facts and unresolved operations are preserved without any claim that external effects stopped. Milestone 2 is accepted when the runner prints the failed integrated acceptance still open and the final explicit acceptance completed, plus first-objective creation/replay identity and instruction-only invalidation results.

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

The objective runner must exit zero and print the objective ID, final revision, original and replayed receipt IDs and final status, the refused unauthorized cases, the conflicted stale cases, the failed integrated acceptance still open and the final explicit acceptance completed, plus first-objective creation/replay identity and instruction-only invalidation results. Its smoke invocation uses the CLI, keeping the same create key across retries so creation returns the same objective:

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


## Revision Notes

2026-10-29: Added real agent-created objective recovery and instruction-only conflict cases to qualification.


## Revision Notes

2026-11-02: Serving qualification selects public HumanVerifiable criteria and
explicit authorized review of actual retained outputs. Trusted automatic-verifier
callback validation remains in the store contract suite; no scripted model result
or fixture pass flag is presented as an installed automatic producer. Actual
SIGKILL recovery also required live source settlement checks, factual positive
command receipt acknowledgement and distinguishing ordinary Skills from native
coordinators. No workflow step shape or dependency pin changed.
