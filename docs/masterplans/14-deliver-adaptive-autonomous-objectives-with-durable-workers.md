---
id: 14
slug: deliver-adaptive-autonomous-objectives-with-durable-workers
title: "Deliver adaptive autonomous objectives with durable workers"
kind: master-plan
created_at: 2026-10-10T23:32:09Z
intention: "intention_01m4m2pjz6es9v9aqq5jq9c4ee"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-10T23:32:09Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:19:09Z
      verdict: "changes-requested"
      note: "Registry gate semantics inconsistent across EP-4..EP-7; Progress asks to copy child milestones; MP13 2026-10-21 contracts (plan 73 predicate, ADR 0041) and ADR 0004/0017/0022/0030 not carried; IR-17 acceptance 2 owner ambiguous; all cited paths and symbols verified"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:19:09Z
      mode: "update"
      note: "Apply review: start gates vs completion gates in registry and graph; adopt MP13 2026-10-21 descriptor/predicate and ADR 0041 contracts; cite ADR 0004/0017/0022/0030; coordination-snapshot Progress; IR-17 acceptance 2 owner"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-28T03:46:48Z
      mode: "implement"
      note: "Start EP-1; reconcile completed external decision prerequisites"
---

# Deliver adaptive autonomous objectives with durable workers

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope


Deliver [UC-1: Adaptive autonomous delivery](../use-cases/adaptive-autonomous-delivery.md): a user admits an outcome, criteria, authority and shared limits; a recoverable coordinator works directly or assigns continuing workers, changes that organization on evidence, retains useful work through failure and handoff, and closes only against verified integrated artifacts. Explicit ongoing mandates can repeat bounded cycles until cutoff. Operators can inspect selected models, accepted operations, owners, resource reservations and unresolved work.

This plan covers the five requests IR-14 through IR-18. They form one coherent initiative with seven independently testable work streams. The scope is substantial but suitable for one MasterPlan: all children share execution identity, objective references, authority, resources and recovery. Use phases rather than separate master plans that would duplicate those coordination contracts. If finite delivery needs a separate release date, defer the recurrence phase without blocking the finite release; do not silently drop IR-18 from overall completion.

Scope includes durable model/tool turns and composed policies ([IR-14](../improvement-requests/record-durable-model-tool-turns-and-compose-harness-policies.md)), continuing sessions ([IR-15](../improvement-requests/support-continuing-worker-sessions.md)), adaptive decisions, resource limits and integrated qualification ([IR-16](../improvement-requests/support-adaptive-durable-orchestration.md)), governed run settings ([IR-17](../improvement-requests/select-governed-models-for-agent-runs.md)), and explicit recurring mandates ([IR-18](../improvement-requests/support-recurring-objective-supervision.md)). Start within one deployment with native admitted capabilities and supported HTTP model transports.

Separate prerequisites remain separately owned: [IR-11](../improvement-requests/provide-governed-mutable-repository-workspaces.md) supplies real mutable workspaces/integration/fences; [IR-13](../improvement-requests/support-optional-major-task-tracking.md) supplies authoritative objective/checkpoint state; [MasterPlan 13](13-compose-shikumi-decisions-in-durable-flows.md) supplies IR-12 typed decisions through plans 73–76. This plan specifies their consumer contracts and acceptance gates but does not implement their entire requests or count them as delivered. At creation, IR-11 and IR-13 have no selected implementation plan, and plans 73–76 are not started. These are real readiness constraints on completing this initiative.

A2A, general public HTTP control, vendor terminal attachment, background CLI workarounds, generic deployment-readiness remediation, remaining attestation signing, agent-artifact evolution and a project-management product are excluded. Plan 78's optional external executor is not selected. No new scheduler or orchestration framework is needed. Creating this plan and its intention installs no Skill, starts no recurring mandate and authorizes no publication or deployment.


## Decomposition Strategy


Phase A establishes the two enforcement boundaries every later child consumes: EP-1 resource accounting, then EP-2 admitted model selection. EP-1 can start immediately; EP-2 waits for EP-1's operation and attempt identities and for the existing plan 73 catalog, so that whole-run selection never defines a competing alias registry. Phase B adds EP-3 recoverable execution and EP-4 continuing workers. Phase C adds EP-5 adaptive finite coordination and EP-6 integrated coding qualification. Phase D adds EP-7 optional recurrence; its implementation can proceed alongside EP-6 after EP-5 is complete, and finite acceptance does not depend on it.

Split resource accounting from orchestration because a database race can prove conservation before a model makes decisions. Keep policies and turn persistence together because they must share an atomic progress boundary. Keep continuing sessions separate from recurrence because idle worker continuity does not imply permission to schedule future work. Give qualification its own child because worker-local tests and simulated acceptance cannot prove the exact integrated result. One child per request would hide resource conservation and qualification inside a disproportionately large IR-16 plan; further file-based subdivision would fragment shared invariants.

Choose a compiled adaptive Flow using the existing planned typed-decision capability for the first coordinator. It consumes pinned coordinator instructions and bounded model proposals, then invokes admitted session capabilities. Workers use the durable Skill harness. Existing fixed non-Flow supervisors preserve their behavior and journal population. Flow and model-tool coordination share one command implementation; model instructions never become executable workflow code or authority.

Research covered the current Skill/behavior/provider path, agent and conversation lifecycle, child delegation and root descendant ledger, run-evidence persistence, worker configuration, shared registry, timer dispatch, migrations and PostgreSQL tests. Current constraints include in-memory intermediate Skill turns, process-wide model defaults, observation-only durable overlays, no installed worker workspace provider, and one concurrent workflow advance. None is cured by installing coordinator instructions alone. No dependency bounds or pins are changed or selected by this planning work; future dependency selection must verify registry releases and upstream tags after Mori discovery.

Relevant local decisions consulted include [ADR 0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md) for pinned profile policy, [ADR 0010](../adr/0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md) for atomic lifecycle/evidence, [ADR 0011](../adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md) for historical declarations, [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) and [workflow versioning](../workflow-versioning.md) for real patch branches and rotation, [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md) for Flow capability isolation, [ADR 0015](../adr/0015-a-kioku-write-answers-on-two-layers-and-a-journaled-step-keeps-its-bytes.md) for recorded bytes, [ADR 0016](../adr/0016-a-cron-agent-runs-about-now-not-once-per-missed-minute.md) and [ADR 0018](../adr/0018-a-workflow-that-ends-is-re-keyed-by-epoch.md) for cadence and epoch semantics, [ADR 0023](../adr/0023-delegation-is-governed-at-the-child-spawn-boundary.md) for governed spawning, [ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) for additive pinned capabilities, [ADR 0028](../adr/0028-a-router-catalog-is-a-bounded-snapshot-of-declared-authority.md) and [ADR 0029](../adr/0029-model-routing-output-is-a-proposal-until-validated-against-journaled-authority.md) for catalog/proposal authority, [ADR 0033](../adr/0033-recorded-agent-principals-key-durable-state.md) for principal continuity, [ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md) for fresh exact actions, [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md) for shared runtime/retention ownership and measured concurrency, and [ADR 0040](../adr/0040-response-options-and-foreground-launches-have-separate-authority.md) for HTTP versus foreground-launch authority, and [ADR 0041](../adr/0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md) for the typed-decision identity and committed-outcome contract that EP-5's decision call site must preserve. Four earlier records govern mechanics every child repeats: [ADR 0004](../adr/0004-one-options-value-and-a-checked-patch-set.md) keeps one `WorkflowRunOptions` owner and one checked patch set, [ADR 0017](../adr/0017-rotate-to-make-a-label-static-rather-than-computing-it.md) forbids computed journal labels, [ADR 0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md) separates journaled decisions from delivery receipts, and [ADR 0030](../adr/0030-an-approval-request-is-a-durable-child-workflow.md) makes each approval a durable child keyed by `ReviewRequestId`. Mori discovery also supplied [Keiro ADR-7](mori://shinzui/keiro/okf/adrs/concepts/ADR-7): timer completion belongs to the generation that armed it. Each affected child repeats the applicable context.


## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Enforce root resource reservations across durable work | [docs/plans/81-enforce-root-resource-reservations-across-durable-work.md](../plans/81-enforce-root-resource-reservations-across-durable-work.md) | None | None | Complete |
| EP-2 | Pin governed execution settings for agent assignments | [docs/plans/82-pin-governed-execution-settings-for-agent-assignments.md](../plans/82-pin-governed-execution-settings-for-agent-assignments.md) | EP-1; external plan 73 | None | Complete |
| EP-3 | Recover durable model and tool turns with composed policies | [docs/plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md](../plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md) | EP-1, EP-2 | None | In Progress |
| EP-4 | Coordinate continuing worker sessions and fenced handoffs | [docs/plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md) | EP-1, EP-2, EP-3; completion gates IR-11 and IR-13 providers | None | Not Started |
| EP-5 | Adapt durable delivery through validated coordinator decisions | [docs/plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md](../plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md) | EP-4; external plan 76; completion gate IR-13 provider | None | Not Started |
| EP-6 | Qualify integrated adaptive autonomous delivery | [docs/plans/86-qualify-integrated-adaptive-autonomous-delivery.md](../plans/86-qualify-integrated-adaptive-autonomous-delivery.md) | EP-5; IR-11 and IR-13 providers before milestones 2–3 | None | Not Started |
| EP-7 | Supervise recurring objectives from current durable checkpoints | [docs/plans/87-supervise-recurring-objectives-from-current-durable-checkpoints.md](../plans/87-supervise-recurring-objectives-from-current-durable-checkpoints.md) | EP-5; completion gate IR-13 provider | EP-6 fixture reuse | Not Started |

EP numbers identify rows in this master plan; the linked ExecPlan file ids are 81–87. A child reference is a whole-child start gate: that child must be Complete before the dependent child begins. External plans 73 and 76 are start gates of the same kind, owned by [MasterPlan 13](13-compose-shikumi-decisions-in-durable-flows.md). IR-11 and IR-13 have no owning implementation plan; where a row names one as a completion gate, the child may build its mechanics against the fixture adapter its own plan defines, but it cannot be marked Complete until the real provider passes the acceptance cases named in the ownership matrix below. EP-6 is the exception: its milestones 2–3 exercise real workspaces and checkpoints, so both providers must exist before those milestones start. Initial status is Not Started, not a claim that every row is currently implementable.


## Dependency Graph


The hard child edges are EP-1 → EP-2; EP-1 and EP-2 → EP-3; EP-1, EP-2 and EP-3 → EP-4; EP-4 → EP-5; EP-5 → EP-6 and EP-7. Transitive edges explain shared foundations rather than duplicate implementation work.

```text
plan 73 ----------+
                  v
EP-1 (81) -> EP-2 (82) -> EP-3 (83) -> EP-4 (84) -> EP-5 (85) -> EP-6 (86)
                                                       ^   \
                                           plan 76 ----+    +-> EP-7 (87)

IR-11 provider: completion gate for EP-4; start gate for EP-6 milestones 2-3
IR-13 provider: completion gate for EP-4, EP-5, EP-7; start gate for EP-6 milestones 2-3
```

EP-2 requires EP-1 to account for actual calls, EP-3 requires a stable descriptor and atomic resource hooks, EP-4 requires recoverable assignment execution, and EP-5 requires real session commands/events. EP-6 qualifies the functioning coordinator; EP-7 schedules the same bounded cycle. No recurrence edge points back into finite delivery. EP-7 has a soft dependency on EP-6 only for fixture reuse.

External plan 73 supplies the single operator model catalog before EP-2, together with the refactored `providerCall`/`matchesCall` tuple predicate in `Behavior.Provider` that MasterPlan 13 assigned to plan 73 on 2026-10-21; EP-2 calls that predicate for whole-run selection and reports any gap back to plan 73 rather than reshaping it. External plan 76, transitively plans 73–75, supplies governed typed decision execution before EP-5. EP-2 uses the current HTTP builder and does not wait for plans 74–76 merely to run a Skill. Plan 75 evidence and EP-3 operation records have an integration dependency: they correlate calls but retain distinct purposes and owners; EP-5 reconciles their shared root accounting when composing them.

IR-13 must provide current authoritative objective/assignment reads, instruction and criteria revisions, conflict-aware updates, stable operation deduplication and accepted artifact/evidence references. EP-4 can build against a fixture adapter, but production checkpoint integration must be delivered before EP-4 closes; EP-5 and EP-7 require it to begin production wiring. IR-11 must provide admitted isolated workspaces, exact artifact identity, process recovery and write fencing against the session owner's epoch. EP-4 and IR-11 meet at an integration gate: EP-4's early store/fence contract and EP-3's operation contract can be consumed before EP-4 is complete, so there is no requirement that IR-11 wait for the entire session plan. The real late-writer/handoff tests then close both sides. EP-6 cannot start full qualification without the delivered provider.

Coordinate those prerequisite deliverables with their separate owning plans when they are created; record real paths and readiness here instead of inventing completion dates or assuming names for nonexistent modules. There is no authorization in this plan to absorb general task or workspace implementation. If a required owner is unavailable, preserve the blocked milestone and complete only independently verifiable work. A fixture is development evidence, not a waiver of a full-request acceptance case.


## Integration Points


**Root identities and resource accounting — EP-1 owns; EP-2 through EP-7 consume.** `Execution.Identity`, `Execution.Resources`, `Store.ExecutionResources` and associated tables distinguish root, logical operation and actual attempt. Root identity survives new runs, assignments, hierarchy changes, compaction and recurrence. A shared transaction reserves applicable dimensions before dispatch and atomically settles known/unknown usage with accepted outcomes. Old descendant count remains an additional ceiling; no consumer creates a fresh root to regain allowance.

**Execution catalog and selection — existing plan 73 owns catalog descriptors; EP-2 owns whole-assignment selection.** `Decision.ModelCatalog` is the one planned operator alias registry; `Behavior.Provider`/`Behavior.Compatibility` remain the HTTP builder and tuple checker. MasterPlan 13 records EP-2 as a consumer of the public model descriptor (alias, descriptor version and digest, provider, API, endpoint class, exact model, explicit thinking preference, opaque binding identity and version) and of the plan 73 tuple predicate; EP-2 adds `Execution.Selection` and separate run permissions on top of them; existing plan 74 retains decision-slot dispatch. EP-3 snapshots the selection, EP-4 carries it on assignments, EP-5 proposes permitted later escalation. A mutable alias never replaces a pending operation's immutable descriptor or binding. Descriptor extensions require coordination with MasterPlan 13 and its child provenance rather than an incompatible duplicate registry.

**Durable operations and long external work — EP-3 owns; EP-4, EP-5 and EP-7 consume.** `Execution.Transcript`, `Execution.Store`, policy/runner/driver modules and bounded submit/observe executor own versioned replay data, policy configuration and operation progress. Upstream Baikai evidence remains encode-only; use application replay records and protected payload references. EP-1 supplies transaction-level resource hooks. Existing plan 75 owns typed-decision evidence and existing `Attestation.EvidenceStore` owns sanctioned evidence lifecycle. Store correlation, not contradictory success histories. EP-3 also owns atomic executor claim/dispatch-start transitions, claim-generation fencing, uncertain-claim reconciliation and late-receipt handling. That executor reuses the existing run-job queue inside this deployment; the generic external executor in plan 78 is not selected, and if it is selected later it must consume EP-3's accepted-operation/attempt-claim contract rather than introduce a second one. EP-5 adapts its new typed-decision call site from the existing synchronous runner to this submit/observe boundary, preserving decision descriptors/evidence and old journals, and wires decision attempt accounting and measured global execution capacity into it.

**Continuing assignments, messages and ownership — EP-4 owns; EP-5 and EP-7 consume.** `WorkerSession` modules, `Flow.Workers`, coordination tools and session tables own ordered acceptance, events, cursor and owner epoch. Persist each immutable assignment id to its distinct child/run identity; generations and stable worker ids cannot substitute for that mapping. Regular follow-ups queue for a new assignment; interruption and transfer reconcile explicitly. IR-13 owns task/checkpoint records and IR-11 enforces workspace fences. Cross-owner writes use stable intents/receipts if no shared transaction exists. A lease expiry never proves a process stopped, and unknown effects block conflicting successor writes.

**Adaptive decisions and accepted completion — EP-5 owns; EP-6 and EP-7 consume.** `Coordination` modules and `Flow.AdaptiveDelivery` define closed proposals, validation and `IntegratedAcceptance`. IR-12 provides typed decision invocation; the submit/observe call site EP-5 adds must carry the complete pinned decision identities from ADR 0041 (program reference, parameter-state digest and derivation version, model descriptor, binding) in its persisted prepared work and read committed outcomes through their retained codecs, never recomputing them. IR-13 remains authoritative for objective completion. EP-6 supplies exact combined repository artifacts/checks and full delivery evidence. An all-green worker roster cannot substitute for the integrated criteria revision and user journey.

**Recurring admission — EP-7 owns.** `Mandate` modules own explicit recurrence, current authority, cycle/watermark, next due, expiry and stop. Worker events are wake hints; `Trigger/Timer.hs` and `Trigger/Scheduler.hs` keep the single timer dispatcher. The desired wake is recorded with accepted cycle progress and reconciled after crashes. EP-7 reuses the coordinator and resource root, and cannot revive a stopped mandate from an old timer.

**Shared process/schema wiring — each child owns its feature additions; EP-5 coordinates reconciliation.** `Agent/RunJob.hs`, `Agent/Delegate/Context.hs`, `Agent/Workflow.hs`, `Agent/Conversation.hs`, `Workflow/Registry.hs`, `Workflow/Versioning.hs`, `Flow.hs`, worker/server configuration, operator parser, Cabal/test inventories, migration manifest and `domain/shikigami.keiro-workspace` are shared. EP-1 introduces root propagation, EP-2 selection fields, EP-3 the execution driver, EP-4 session capabilities, EP-5 coordinator/capacity and EP-7 mandate registration. Serialize edits to these central files, allocate migrations only at implementation time, preserve each prior consumer and rerun its compatibility tests. No child hand-edits generated code or creates a second registry/options/timer owner.

**Retention and project decisions — EP-3 owns transcript retention policy; each state owner supplies references.** Live executions, idle sessions, pending handoffs, open mandates and uncertain effects protect payloads/deduplication records regardless of terminal workflow GC. Operator inspection is bounded and redacted. During implementation promote the shared identity/atomicity contract, transcript/evidence distinction, assignment fencing, explicit model precedence, scheduling/pool limits and finite-versus-recurring authority to focused ADRs. EP-6 coordinates final distillation; EP-7 adds its recurrence findings before overall closure. No new ADR is marked accepted merely from this planning proposal.

**Acceptance ownership.** IR-14 acceptance 1–7 belongs to EP-3; its acceptance 8 is closed by EP-4 and exercised in EP-6. IR-15 acceptance 1–3 and 5–6 belongs to EP-4; acceptance 4 additionally requires the real IR-11 handoff fixture. IR-16 acceptance 4 is rooted in EP-1 and rechecked in EP-5; acceptance 1, 3 and 5 belongs to EP-5; acceptance 2 and 6 require EP-6. IR-17 acceptance 1–4 and 6 belongs to EP-2, with transcript/continued-assignment cases completed through EP-3/EP-4; acceptance 2's permitted escalation is additionally exercised by a coordinator proposal in EP-5 and in EP-6's integrated trial; acceptance 5 has historical-declaration/pure permission checks in EP-2 and its real IR-12 Flow regression in EP-5 after external plans 74–76. IR-18 acceptance 1–6 belongs to EP-7. UC-1 acceptance 1–4 and 6 is qualified by EP-6, and acceptance 5 by EP-7. This is the completion matrix, not a claim of current implementation.


## Progress


2026-10-27: Phase A is complete: EP-1 and EP-2 are Complete; EP-3 is In Progress and the remaining four children are Not Started. EP-2 passed the full build, 476 core, 260 PostgreSQL, 37 agent, 63 server and 98 worker cases, plus its final 10-case selection qualification, migration isolation and the additive workflow gate. EP-3 has accepted its protected transcript storage and atomic outcome boundary; composed policies, individually accepted tools, bound permissions and fenced executor primitives are implemented checkpoints. The callable automatic driver is qualified independently; parent workflow adoption, policy configuration and remaining recovery work are still in progress. External plans 73–76 now have accepted implementation evidence in MasterPlan 13. IR-11 and IR-13 remain separately owned provider gates; fixture evidence cannot close them.


## Surprises & Discoveries


EP-1 established an application-owned v2 run-input codec because the generated queue requires every structural field. Future selection and execution metadata must retain the v1/v2 decoder paths rather than adding undeclared required fields. [ADR 0051](../adr/0051-resource-roots-own-conservative-reservations-and-actual-attempts.md) records the shared identity, atomicity, retention and rollout contract; FRIC-9 in `docs/friction-log/` records the queue-interface detour. Resource inspection reports unknown attempts and exclusive allocation holds without reading operation histories.


EP-2 integration: the resource ledger now distinguishes known transport stop from
unknown billing with `PartialUsage`. The selected provider adapter commits
normalized `Attestation.CallFacts` (the same facts used by decision evidence),
assignment admission and root settlement together. EP-3 must consume those
transaction hooks when adding transcript outcomes; EP-5 still owns reconciling
typed-decision root accounting. Finite invoice-cost ceilings cannot be enforced
by the released HTTP APIs and refuse dispatch. Queue v3 retains v1/v2 readers
without granting selection authority to historical metadata. The durable
contract is [ADR 0052](../adr/0052-assignments-pin-whole-run-selection-and-account-every-provider-attempt.md).


The migration-template defect recurred across EP-2 and EP-3. FRIC-10 and FRIC-11
in `docs/friction-log/` are resolved by the recipe fix and isolated probe. EP-3's
storage boundary shares the existing catalog and retains explicit resource versus
transcript ownership; [ADR 0053](../adr/0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md)
records its protected replay and atomic outcome/cursor/accounting contract.


EP-3 dispatch integration preserves the existing execution projection/query
identities. Attempt metadata uses a bounded column on the owned operation target;
queue delivery observes prepared references, and late receipts reconcile without
redispatch or double accounting. Explicit tool invoice semantics prevent unknown
cost from becoming zero. [ADR 0054](../adr/0054-execution-attempts-own-dispatch-fences-and-generation-wakes.md)
records the cross-plan contract consumed by continuing assignments. The worker route and independently qualified callable driver are available.
[ADR 0055](../adr/0055-execution-drivers-rotate-around-accepted-work.md) fixes the
bounded-generation and accepted-reference repair contract for later continuing
assignments. Recorded summaries now use ordinary accepted attempts with protected source and
outcome references; [ADR 0056](../adr/0056-context-summaries-are-accepted-accounted-model-operations.md)
records that shared context contract. Parent workflow patches, configuration and
remaining recovery qualification are not yet accepted, so EP-3 and its dependent-child start
gates remain unchanged.

## Decision Log


2026-10-10: Interpret IR-14 through IR-18 inclusively as five related requests. One seven-child master plan is an appropriate coordination boundary; finite delivery and optional recurrence use separate phases.

2026-10-10: Keep IR-11, IR-13 and existing IR-12 plans separately owned and make their actual readiness explicit. Contract fixtures allow early mechanics work but cannot satisfy full coding/checkpoint acceptance.

2026-10-10: Select a compiled Flow with typed decisions for adaptive coordination and a durable Skill harness for workers. Preserve existing non-Flow fixed supervisor behavior and journal compatibility.

2026-10-10: Separate root accounting, immutable execution settings, operation transcripts, session authority, objective checkpoints, workspace effects and mandates by ownership. They share stable references and atomic/idempotent protocols, not duplicate mutable histories.

2026-10-10: Require real useful overlap, exact integrated-source checks and one bounded live coding trial before full delivery claims. Component success and process exits alone do not close an objective.

2026-10-10: Create the user-requested intention with `mina ci --json` and associate this master plan and all children with `intention_01m4m2pjz6es9v9aqq5jq9c4ee`. No recurring automation is implied.

2026-10-21: Revision after review. Distinguish whole-child start gates from external completion gates in the registry so EP-4 through EP-7 are described consistently; IR-11 and IR-13 providers are completion gates except for EP-6's live milestones. Adopt the 2026-10-21 MasterPlan 13 contracts (plan 73 owns the public model descriptor and the reusable `providerCall`/`matchesCall` predicate; ADR 0041 governs pinned decision identity and committed-outcome reads) as consumed interfaces for EP-2 and EP-5. Cite ADR 0004, 0017, 0022 and 0030, which already govern the shared options owner, static labels, receipt ownership and approval children the children rely on. Replace the Progress instruction to copy child milestones with a coordination snapshot. No decomposition or dependency edge changed, so no ADR changes.


## Outcomes & Retrospective


To be filled during implementation. Completion requires all seven children, the external integration gates, the acceptance ownership matrix above, workflow evolution/conformance evidence and ADR distillation. Finite delivery may be qualified before recurrence; report that narrower milestone honestly without marking the entire initiative complete.
