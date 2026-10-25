# Bundle Update Log

## 2026-10-25
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
