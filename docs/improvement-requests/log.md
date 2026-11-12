# Bundle Update Log

## 2026-11-12
* **Addition**: IR-24 requests pinned, allowlisted, read-only repository evidence for durable runs, with ref resolution at admission and a content reference per read, for `mori://tan/tan-product-management/masterplans/2-add-shikigami-product-management-reviews-and-follow-up`; it also asks whether IR-18 is closed at the read-only boundary on purpose.

## 2026-11-11

* **Addition**: IR-23 requests publication of a validated workspace commit to an operator-granted ref of the source repository, for `mori://shinzui/mori/okf/use-cases/concepts/UC-2`.

* **Addition**: IR-22 requests attested workspace run outcomes: a required validated commit decides run success, and the commit and validation facts recorded by Shikigami's tools appear on the public status response, for `mori://shinzui/mori/okf/use-cases/concepts/UC-2`.

## 2026-11-06
* **Completion**: Complete IR-19 under MasterPlan 19 and plans 109–113. All eight scheduled watchdog acceptance cases and lost-append accounting pass; scoped inspection, independent age telemetry and operator guides are qualified. Evidence: docs/evidence/plan-113/acceptance.md. Optional native/live-model trials remain explicit additional gaps.

## 2026-11-05
* **Completion**: Complete IR-21 under MasterPlan 20: all nine acceptance cases pass through real stream intake, run queue, approval resolution and admission, with evidence under docs/evidence/plan-118/.

## 2026-11-04
* **Accept**: Accept IR-21 under MasterPlan 20 with child plans 114–118: bounded observation with observer allowances, source adapters, a deterministic pre-filter and the proposal ledger; a registered typed assessment decision whose output cannot select repository, authority or recipient; the stream-triggered proposing Flow with durable human acceptance; standing policies with autonomous admission of bounded objectives; and operator observability with the integrated acceptance runner.
* **Accept**: Accept IR-19 under MasterPlan 19 with child plans 109–113: lock-free bounded observation under a watchdog grant, deterministic stuck classification with episode coalescing, a registered typed drift decision, the scheduled Flow agent with its own principal, allowance and sinks, and operator observability with the integrated acceptance runner.
* **Addition**: IR-19 requests an independent watchdog agent that reports stuck or drifting work from authoritative state and holds no intervention authority of its own.
* **Addition**: IR-20 requests enrolled outbound machine daemons for durable workspace operations, with each machine's local policy as the enforcement point against a compromised central runtime.
* **Addition**: IR-21 requests a governed path from observed activity to proposed objectives, with autonomous admission only under an explicit, bounded and revocable standing policy.

## 2026-11-03
* **Completion**: Complete IR-15 under plan 84: all six consumer cases, continuing followup compaction/replay and real native operator handoff recovery are qualified. IR-14 acceptance 8 is established for the continuing consumer; its integrated UC-1 recheck remains in plan 86. Retain the separate plan 85/86/87 gates.

## 2026-11-02
* **Implement**: Complete IR-11 with plan 96: all 25 native workspace cases and final host checks pass, including real ownership receipt recovery, accepted successor effects, exact integration and terminal cleanup.
* **Completion**: IR-13 completed by MasterPlan 17, plans 98–102. Real API/worker restart, first agent creation and receipt recovery, cross-run/bound-turn continuity, integrated explicit acceptance, stale/denied inputs and source uncertainty pass. Full qualification: 1,597 package tests, 169 native checks, Hurl and complete build. Human-verifiable review, deterministic fixture fencing and remaining workspace/adaptive/recurring gates are explicit; no IR-11/IR-15 or plan 84–87 completion is inferred.

## 2026-10-30
* **Progress**: IR-13 moves to in-progress: plan 98 implements the conditional objective store, receipt recovery and integrated-acceptance boundary. Plans 99–102 retain real-provider, API/tool and no-Rei qualification ownership; this does not close plan 84.
* **Qualification**: IR-11 plan 96 passes all 22 workspace-owned native cases, including exact integration, continuing writes/cleanup, restart fencing and privacy. Preserve in-progress status and the separately owned real objective ownership/accepted successor gate; bounded evidence is retained in docs/evidence/plan-96/native-workspace-facts.json.
* **Progress**: Refresh IR-11 implementation evidence: configured native durable upgrades and recovery are qualified; successor, integration and full reassignment gates remain open under plan 96 and the separately owned real objective provider.

## 2026-10-29
* **Audit**: Reconcile all 18 request lifecycles and their selected delivery plans
against current child Progress/Outcomes and parent acceptance matrices. Six requests
remain completed (IR-1/3/8/9/10/12); seven are in progress (IR-4/7/11/14/15/16/17);
two remain accepted and unstarted (IR-13/18); three remain proposed without selected
full-contract plans (IR-2/5/6).
* **Correction**: Move IR-14 through IR-17 from accepted to in-progress. Plans 81–83
are complete and plan 84 is partial, but remaining real-provider, Flow-regression,
coordinator and integrated acceptance gates prevent request completion. Replace stale
current-coverage claims while preserving the requested contracts and acceptance cases.
* **Links**: Add direct links to IR-12's completed child plans, identify IR-13's
superseded plan 97 and link IR-18's real provider/coordinator prerequisites. Verify all
15 targetPlan values exist and have matching request-body links. Regenerate the
catalog and its metadata-derived lifecycle/plan table.
* **Scope**: Preserve historical review/completion records. Runtime acceptance evidence
was inspected, not rerun; no independent design review is asserted.

## 2026-10-28
* **Update**: IR-13 moves from proposed to accepted: MasterPlan 17 owns the authoritative objective record through plans 98–102 (PostgreSQL store and conditional commands, trusted associations and the real providers that close plan 84's IR-13 gate, authenticated API and CLI, durable Skill/Flow/conversation capabilities, no-Rei qualification), with implementation not started. The single-plan draft, plan 97, is superseded.
* **Progress**: IR-11 selects plan 96 for its complete durable workspace contract. Repository catalog admission is implemented; allocation, mutation, process recovery, worker composition and real fencing/integration acceptance remain outstanding.

## 2026-10-26
* **Completion**: Plan 91 and MasterPlan 15 complete: lifecycle/history HTTP and typed client, shared operator JSON, and automatic pre-workflow exhaustion reconciled transactionally through the released PGMQ API. Receipts survive DLQ cleanup; the runbook requires retention until reconciliation. All 930 package tests and the workflow gate pass.

## 2026-10-25
* **Progress**: IR-10 now has implemented and verified HTTP status/history, client commands and live worker success. Automatic retry exhaustion bypasses the domain receipt hook in released Keiro; plan 91 and MasterPlan 15 remain open for that reproduced terminal-closure gate (FRIC-7).
* **Completion**: IR-8 completed by plan 90 under MasterPlan 15: authenticated addressed runs with an atomic acceptance ledger, stable workflow IDs, replay/conflict handling, and verified concurrent deduplication.
* **Completion**: IR-12 completed by MasterPlan 13 and plans 73–76: governed typed two-model decisions, retained rich-result replay, durable actual-attempt evidence, production wiring and authoring documentation. All package tests and the additive replay-neutral workflow gate against 436e9f8 pass.

## 2026-10-22
* **Audit**: Rechecked all 18 lifecycle values against the current plans and master plans,
recorded acceptance evidence, Git history through `4f472df`, and repository tree. All
statuses remain correct: completed IR-1, IR-3, IR-9; in-progress IR-4, IR-7; accepted
IR-12 and IR-14 through IR-18; proposed IR-2, IR-5, IR-6, IR-8, IR-10, IR-11, IR-13.
The October 21 revisions to MasterPlans 13 and 14 and their child plans change planning
contracts, not implementation readiness; all those children remain not started.
* **Update**: Add a status and selected-plan table to the index. Verify all 11 `targetPlan`
paths and their request-body links; requests without selected full-contract plans retain
their proposed status and separately identify related or consuming work.
* **Correction**: IR-6 now links completed delegation and service-boundary prerequisites
instead of calling plans 35 and 36 pending. Add the missing prerequisite link to plan 73
in IR-17 and clarify that its catalog is not implemented. Refresh `generated.at` only on
these two edited requests; preserve completion timestamps and prior review provenance.
* **Update**: IR-8 moves from proposed to accepted: plan 90 owns the addressed-run route
under MasterPlan 15, after the agent catalog (plan 88) and bearer authentication (plan 89),
with implementation not started.
* **Update**: IR-10 moves from proposed to accepted: plan 91 owns the run-status and history
routes under MasterPlan 15, after plan 90, with implementation not started.

## 2026-10-11
* **Audit**: Reconciled all 18 requests with the current plan corpus, recorded implementation
evidence, and repository tree. IR-1, IR-3, and IR-9 remain completed; IR-4 and IR-7 remain
in progress; IR-2, IR-5, IR-6, IR-8, IR-10, IR-11, and IR-13 remain proposed without
selected implementation plans for their full contracts.
* **Update**: IR-12 moves from proposed to accepted: MasterPlan 13 and plans 73–76 are
selected, with implementation not started.
* **Update**: IR-14 moves from proposed to accepted: plan 83 owns durable model/tool turns
under MasterPlan 14, with implementation not started.
* **Update**: IR-15 moves from proposed to accepted: plan 84 owns continuing worker sessions
under MasterPlan 14, with implementation not started and workspace/checkpoint gates open.
* **Update**: IR-16 moves from proposed to accepted: MasterPlan 14 and plans 81, 85, and 86
own resource accounting, adaptive coordination, and qualification, with implementation not started.
* **Update**: IR-17 moves from proposed to accepted: plan 82 owns governed run settings
under MasterPlan 14, with implementation not started.
* **Update**: IR-18 moves from proposed to accepted: plan 87 owns recurring supervision
under MasterPlan 14, with implementation not started and checkpoint integration still required.
* **Update**: Add profile-supported `targetPlan` metadata to the 11 requests with selected
implementation plans. Add missing plan links for IR-7 and IR-9 and the IR-4 closeout
plans 60–63. Identify related or consuming plans for unplanned requests without treating
them as full implementation coverage. Refresh `generated.at` on all audited requests;
prior review records and completion evidence retain their original timestamps.

## 2026-10-10
* **Update**: Link IR-14 through IR-18 to MasterPlan 14 and their owning ExecPlans
81–87. Record planned, not-started coverage and preserve separate prerequisite
and integration gates.
* **Addition**: IR-15 requests continuing worker sessions and durable coordination;
IR-16 requests adaptive orchestration and shared resource limits; IR-17 requests
governed execution settings for whole agent runs; IR-18 requests recurring objective
supervision. All remain proposed and link to UC-1 in the new use-case bundle.
* **Update**: Extend IR-11 with assignment-scoped workspaces, ownership fencing,
instruction discovery, and integrated-artifact validation; IR-13 with authoritative
assignment checkpoints and conflict handling; IR-14 with follow-up recovery and
shared-budget/coordination composition. Preserve their original consumers and scopes.
* **Correction**: IR-12 now records existing unimplemented MasterPlan 13 and plans
73–76, and distinguishes Flow decision selection from whole-worker model selection.
No implementation or independent review is claimed by this change.

## 2026-10-06
* **Addition**: IR-14 requests durable recording and recovery of individual model and tool
operations, with composable harness policies, pinned configuration, and existing authorization
and workflow-evolution boundaries.

## 2026-09-26
* **Addition**: IR-13 proposes optional major-task tracking without Rei and records the current
memory, Flow, overlay, replay, and authorization boundaries for further design.
* **Addition**: IR-12 requests replay-safe Shikumi decision steps within durable Flows and
governed model selection per step, with pinned policy, replay, and mixed-model evidence.

## 2026-09-21
* **Audit**: Reconciled all eleven lifecycle values against the current ExecPlans,
MasterPlans, Git history, and repository tree. IR-1, IR-3, and IR-9 are complete; IR-4
and IR-7 are in progress; IR-2, IR-5, IR-6, IR-8, IR-10, and IR-11 remain proposed.
* **Review**: Added model review provenance for the lifecycle and planning-coverage audit to
every request. The review covers catalog metadata, not a fresh review of each design.
* **Update**: Repinned the improvement-request profile from v0.10.0 to the authoritative
okf-profiles v0.18.0 release.

## 2026-09-20
* **Addition**: IR-11 requests governed isolated mutable repository workspaces and bounded coding
tools for durable upgrade agents.
* **Addition**: IR-10 requests a public terminal agent-run status endpoint so Mori can correlate
an accepted run with its durable succeeded or failed outcome.

## 2026-08-17
* **Migration**: Move the bundle to OKF v0.2, adding `generated` provenance to every request
and declaring `okf_version` in the bundle root.
* **Update**: Repin the profile descriptor to `okf-profiles` v0.10.0.

## 2026-08-10
* **Addition**: IR-9 requests Meibo-principal keying for durable agent memory, grants,
lineage, and outbound authorship, including migration from name-keyed history.

## 2026-08-07
* **Addition**: IR-8 requests an addressed agent-run vertical on the public HTTP API so
`mori://shinzui/mori` can fire agents from matched repository events across the service
boundary, instead of writing into the shared run-job queue.

## 2026-08-02
* **Addition**: IR-7 requests sanctioned execution profiles, complete call roll-ups, artifact
binding, and signed run attestations for
`mori://shinzui/kikan/okf/use-cases/concepts/UC-8`.

## 2026-07-30
* **Migrate**: Assign stable handles to Shikigami improvement requests.
* **Move**: Accept cross-cluster diagnostics and governed-evolution requests from Kikan.
* **Link**: Relate the A2A owner request to Kikan's accepted portfolio request.
