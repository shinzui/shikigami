---
id: 85
slug: adapt-durable-delivery-through-validated-coordinator-decisions
title: "Adapt durable delivery through validated coordinator decisions"
kind: exec-plan
created_at: 2026-10-10T23:32:15Z
master_plan: "docs/masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md"
intention: "intention_01m4m2pjz6es9v9aqq5jq9c4ee"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-10T23:32:15Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:19:09Z
      verdict: "changes-requested"
      note: "ADR 0041 pinned decision identity not cited for the submit/observe call site; IR-13 stated as hard start dependency while M1 is fixture-first; maxConcurrentAdvances=1 verified"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:19:09Z
      mode: "update"
      note: "Cite ADR 0041 and ADR 0004; IR-13 provider is a completion gate, not a start gate"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-03T19:13:47Z
      mode: "update"
      note: "Refresh delivered decision and objective prerequisites without claiming adaptive coordinator implementation."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-03T20:19:48Z
      mode: "implement"
      note: "Implement validated adaptive proposals, durable decisions and shared executor admission."
---

# Adapt durable delivery through validated coordinator decisions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Let a coordinator change its organization when new evidence warrants it: work directly, create bounded workers or local orchestrators, narrow/split/consolidate assignments, request a specialist or move ownership safely. This delivers adaptive control and actual bounded concurrency for [IR-16](../improvement-requests/support-adaptive-durable-orchestration.md). Hard dependencies are `docs/plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md` (and its transitive resource, model and harness dependencies) and existing `docs/plans/76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md` (including plans 73–75). A delivered IR-13 checkpoint provider is a completion gate: milestone 1 may prove validation against the fixture adapter defined there, but this child cannot be marked Complete until the production adapter passes its acceptance. Plan 86 separately qualifies integrated repository delivery. Recurring scheduling is not required.


## Progress


- [x] (2026-11-03) Milestone 1: Versioned bounded proposals, whole-proposal validation and the production checkpoint adapter atomically retain graph changes and executable manifests. `AdaptiveProposalSpec` has thirteen passing cases and PostgreSQL `AdaptiveDeliverySpec` has seven. The latter proves protected restart reads before live policy, revision races, revocation, exhausted root refusal and rejection of completion with a failing combined check.
- [ ] Milestone 2: Execute adaptive cycles with durable typed decisions and continuing-worker commands.
- [ ] Milestone 3: Shared database capacity, existing executor admission, positive worker configuration and real executor overlap are implemented. Complete the held typed-decision, timer, two-process and integrated root fairness cases after milestone 2.
- [ ] Milestone 4: Publish decision inspection, exact completion proposals and compatible workflow declarations.

The first implementation checkpoint is commit `8f4d40a0`. The capacity foundation adds `Execution.Capacity`, migration 0039, accepted-attempt ticket admission and configuration through the single workflow options owner. The broad checkpoint checks pass: 703 core unit tests, 554 core PostgreSQL tests, 288 worker tests and 105 server tests, plus schema isolation. Subsequent focused checks pass 13 proposal cases, seven adaptive PostgreSQL cases (including unprojected session authority) and eight capacity cases (including two runtime processes). The actual executor fixture records two overlapping provider intervals while an unrelated workflow advances. This is not yet the required typed coordinator decision fixture.

Implementation started 2026-11-03 from baseline `1a7d5ebd2b4a7eca058fe61726807b38076fe6e8` on the existing branch. Hard prerequisites are complete. `nix develop --no-write-lock-file -c cabal build all` passes; the required baseline tests are running. Use the Nix environment because plain Cabal cannot locate the configured GHC.


## Surprises & Discoveries


The real objective owner already supplies expected-revision command deduplication and atomic projection callbacks. Adaptive manifests now commit in that same boundary; a second mutable assignment or budget owner is unnecessary.

The prescribed baseline test command exhausted disposable PostgreSQL clients and pushed bounded Git fixtures past their deadlines at default Tasty concurrency. FRIC-51 records the occurrence. Run the suites sequentially with `TASTY_NUM_THREADS=2`; this passes the broad checkpoint checks reported in Progress.

Runtime occupancy differs from uncertain root usage. A local executor that has returned or unwound can acknowledge its exact runtime permit as stopped while its unknown root spending remains held. Lease expiry from another process cannot make that acknowledgement. The real lost-acknowledgement and safe-recovery regressions distinguish these cases.

A session may exist before its first checkpoint publishes a session reference into the objective. The proposal adapter therefore checks the authoritative session binding for graph restructuring instead of treating an absent projected reference as proof of fencing. The dedicated PostgreSQL case leaves both the graph and root unchanged on refusal.


## Decision Log


2026-11-03: Qualify the existing executor capacity boundary before extending it with typed decision work. Admission is atomic with the existing attempt claim/fence. Unknown dispatch without a confirmed local stop retains its permit; the exact local executor finalizer may release runtime occupancy while leaving unknown root usage charged. Tests deliberately allowing recovery alongside unknown work configure both root and runtime capacity separately. A capacity deferral acknowledges only its queue delivery and leaves repair to the accepted driver's existing timer, avoiding exhaustion of provider-delivery retries. [ADR 0109](../adr/0109-runtime-capacity-admission-shares-accepted-attempt-fences.md) records the storage, fairness and configuration contract.

2026-11-03: Validator version 2 binds model permissions to the assignment's named role, refuses repeated ancestor roles and requires a pinned workspace reference for transfer. Version 1 manifests retain their decoder and empty-workspace wire representation; committed decisions are not revalidated. Manifest reads also verify their original objective receipt and payload commitment before revealing executable operations.

2026-11-03: Accept organization changes through an internal objective command, retaining the complete accepted manifest with its objective receipt. Keep current definitions/owners authoritative and retain only hierarchy edges from prior adaptive manifests. [ADR 0108](../adr/0108-adaptive-decisions-commit-with-authoritative-checkpoints.md) records the durable contract.

2026-10-10: Use a compiled Flow with governed typed decisions for the first coordinator. Keep fixed supervisors compatible and model-generated instructions as proposals. Separate runtime capacity from per-objective reservations and measure useful overlap before changing defaults.


## Outcomes & Retrospective


Milestone 1 is implemented and validated. Shared capacity now gates the existing accepted executor and configured worker/resume paths. The adaptive Flow, accepted typed-decision adapter, its joint resource/capacity qualification and operator inspection remain unfinished; this plan is not complete. No durable workflow body or existing supervisor branch has changed at these checkpoints. FRIC-51 remains logged until final triage.


## Context and Orientation


`shikigami-core/src/Shikigami/Agent/Workflow.hs` retains a fixed supervisor for an ordinary Skill declaring delegates. Its explicit CoordinatingSkill arm consumes admitted continuing-worker scopes; declaration text supplies no authority. `shikigami-core/src/Shikigami/Flow.hs` registers compiled behaviors. Select a new compiled `adaptive-delivery` Flow that consumes governed typed decisions and continuing-worker capabilities; the coordinator instructions become pinned decision inputs. Do not silently change the old supervisor branch or add raw provider IO to a Flow.

`shikigami-core/src/Shikigami/Workflow/Versioning.hs` currently fixes `maxConcurrentAdvances` to one. Child count therefore does not demonstrate useful simultaneous progress. Plan 83's submit/observe execution driver separates long external work from short workflow advancement. A runtime capacity limit bounds executor occupancy; a root resource limit bounds one objective across all processes. Both must hold.

[ADR 0028](../adr/0028-a-router-catalog-is-a-bounded-snapshot-of-declared-authority.md) pins the permitted target universe; [ADR 0029](../adr/0029-model-routing-output-is-a-proposal-until-validated-against-journaled-authority.md) validates model output before action. [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md) preserves capability-only IO, and [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md) requires measured pool headroom. [ADR 0041](../adr/0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md) binds every typed decision to an immutable program registration, a versioned digest of its complete parameter state and its derivation version, and requires a committed outcome to be read through its retained codec before any live registration is consulted; milestone 2's submit/observe call site must persist those identities with the prepared work and never recompute a committed result. [ADR 0004](../adr/0004-one-options-value-and-a-checked-patch-set.md) is why milestone 3 changes `maxConcurrentAdvances` only through the single `WorkflowRunOptions` owner in `Workflow/Versioning.hs`. The existing IR-12 plans 73–76 are complete and supply the typed decision engine. Plan 99 supplies the real objective/checkpoint provider. This child still owns adapting its new decision call site to the durable submit/observe executor and proving shared accounting and capacity; completion of those providers does not implement the adaptive coordinator.

The repository is a Cabal multi-package Haskell service. `shikigami-core` owns domain behavior and store adapters; `shikigami-workers` owns queue, resume and timer processes; `shikigami-server` owns operator commands. `shikigami-migrations/sql-migrations/manifest` owns append-only SQL ordering. `shikigami-core/test-postgres/Main.hs` registers tests using `Shikigami.Migrations.TestSupport.withShikigamiMigratedSuite`, which supplies isolated disposable PostgreSQL databases. Register new modules and tests in the owning Cabal file and test entry point; generated files under `Generated/` are regenerated, never hand-edited.


## Plan of Work


### Milestone 1: Validate bounded organization proposals

Create `shikigami-core/src/Shikigami/Coordination/Proposal.hs`, `Coordination/Validate.hs` and `Coordination/Checkpoint.hs`. Use a closed versioned proposal sum for direct work, create/narrow/split/consolidate assignment, follow-up context, transfer, permitted model escalation, concurrency change, integrate-result, await and propose-completion. Each proposal names the objective/checkpoint revision, evidence references and operation identity. Include bounded rationale, observed friction, expected benefit and a later evidence reference. No proposal contains arbitrary workflow code, tool names, host paths or credential values.

Validate the whole proposal against current authoritative objective instructions and pinned permitted catalog before committing it. Check dependency acyclicity, target/principal availability, parent allow-list, hierarchy depth/cycle, ownership/fences, model policy, resource/cutoff limits and artifact identity. Model syntactic success is not admission. An accepted decision records its input checkpoint, proposal/validator version and executable operations before any dispatch. Concurrent checkpoint change creates a conflict and a new explicit decision; replay of a committed decision reuses it. Test invalid proposals produce no assignment or reservation writes.

Consume IR-13 through a narrow checkpoint adapter returning objective revision, acceptance criteria, instructions version, graph and evidence/owner references. Write by stable operation key and expected revision. Ownership, session and budget facts remain references to their owning authorities, not mutable copied counters. This production adapter is an external prerequisite; a pure fixture may prove validation first but cannot complete the milestone's current-state behavior.

### Milestone 2: Execute one adaptive cycle through governed capabilities

Add `shikigami-core/src/Shikigami/Flow/AdaptiveDelivery.hs` and register `adaptive-delivery` in `Flow.hs`. Use the decision capability delivered by plan 76 with fixed registered program/slot descriptors. Snapshot coordinator instructions, catalog and execution policy before its first decision. Each bounded cycle reads authoritative state and new worker events, invokes a typed decision when meaningful evidence exists, journals proposal/validation, then invokes plan 84's session commands. Every coordination command uses a stable operation id, and ambiguous results remain reconcilable intents rather than causing replacement workers.

Carry objective revision, root, event cursor, accepted decision id, pending dispatch/intents and retained evidence references through journal generations. Rotate at cycle boundaries with static labels; republish current waits. A restart after a decision but before command acknowledgement resumes the same operation. New authority revocation may stop pending dispatch without changing the historical decision. A changed operator catalog never expands the pinned universe silently. Reflection occurs on an early finding, repeated failure, changed critical path or integration evidence, not on silence or token activity.

Wire resource hooks into every actual IR-12 decision attempt, including retries/internal model calls and model-assisted policy work. Reuse plan 75's evidence owner; plan 81 remains root accounting authority. Do not run decision calls outside shared budgets while only charging workers. Existing plans 74/76 execute a typed program synchronously inside a named result step. This child owns adapting the new adaptive decision call site to plan 83's durable submit/observe executor: persist the prepared program/input/selection and stable operation/attempt binding, submit accepted work, suspend the Flow, and observe the recorded typed outcome. Preserve plan 75 as decision-evidence owner and the complete prepared descriptor; do not convert decisions into untyped Skill calls. Use a compatible new interpreter/call site so existing synchronous decision journals still replay unchanged. Executor claims/fences and all real provider calls obey the same root and runtime capacity boundaries. The real IR-17 acceptance-5 regression belongs here: exercise an IR-12 Flow slot with independent decision permissions after plans 74–76 are delivered. A fixture should choose one worker for a small case and a permitted local orchestrator plus descendants for a larger case, then adapt after an injected finding.

### Milestone 3: Establish useful bounded overlap and fairness

Extend worker configuration with a validated positive execution capacity and workflow-advance bound; preserve the default of one until measured. Route all plan-83 executor jobs through one capacity admission mechanism that accounts for multiple worker processes, and schedule ready roots fairly with bounded round-robin admission. Do not hold a database transaction or workflow lease during long external work. Root reservations remain authoritative even if another runtime replica has available local capacity. Update `Workflow/Versioning.hs` through its single options owner, and keep pool headroom plus timer/resume paths within measured bounds.

Use two independent barrier-controlled fixture operations to prove both enter useful execution before either completes; record executor intervals, not only spawn times. Start an unrelated ready root and prove it progresses within a bounded number of admissions while a large root remains busy. Serialize overlapping writers through session/workspace fences. Lower concurrency below current occupancy and show draining, no forced duplicate work and no fresh admission above the new bound. Repeat with two runtime processes and a root last-slot race. Hold a coordinator decision provider call open as well as a worker call: both consume the same execution capacity, while their workflow advances release and an unrelated root and due timer continue to progress. This test must traverse the new submit/observe decision adapter, not only a mocked worker queue.

### Milestone 4: Publish observable decisions and exact completion proposals

Extend supported objective/run inspection with current graph, owner/result references, decision history, reservations, refusal and uncertainty summaries. Define `IntegratedAcceptance` as objective/criteria revision plus exact combined artifact identifiers, actual check results, user-journey evidence and unresolved limitations. Only the IR-13 checkpoint owner may accept completion against that versioned evidence. Model prose or all children completing cannot close the objective. Plan 86 supplies the real repository integration consumer; this child uses exact fixture artifacts to establish the contract. Document a finite example with no recurrence and no implicit publish/merge/deploy action. Follow [workflow versioning](../workflow-versioning.md) for every durable-body change. Keep old journal populations on real old branches behind newly declared patch ids; preserve result codecs. Add declarations to `domain/shikigami.keiro-workspace`, regenerate the runtime and conformance artifacts, and union new workflow patch sets in `shikigami-core/src/Shikigami/Workflow/Versioning.hs`. Long-lived workflows restore a seed first, use static labels within each generation, rotate with `continueAsNew`, and republish generation-owned wake references. Do not invoke the pre-v1 reset exception without separately proving all four documented empty-population conditions. Default this plan to compatible evolution.


## Concrete Steps


Run from the repository root in the existing development environment; if native tools are unavailable, enter `nix develop` first. PostgreSQL tests own disposable databases and must not be pointed at production. Capture a baseline before implementation, then run the following after each applicable milestone:

```bash
MP14_BASE=$(git rev-parse HEAD)
cabal build all
TASTY_NUM_THREADS=2 cabal test shikigami-core-test shikigami-server-test --test-show-details=direct
TASTY_NUM_THREADS=2 cabal test shikigami-core-postgres-test --test-show-details=direct
TASTY_NUM_THREADS=2 cabal test shikigami-workers-test --test-show-details=direct
just migration-schema-isolation
```

The build and tests must exit zero; tests report all cases passed. These are future implementation checks, not results of creating this plan. Add the named new test groups before using their success as evidence. If domain or workflow contracts change, scaffold with the checked workspace, stage/commit generated artifacts so the existing regeneration check compares the intended baseline, then run:

```bash
just keiro-gate "$MP14_BASE"
```

The gate must report no unexplained breaking change and generated conformance must pass. Record actual commands, baseline revision and bounded evidence in the living sections. Dependency source lookup starts with Mori; no new dependency bound is selected here. Before a later bound, pin or workaround change, verify the authoritative registry and upstream release tags as well as the Mori-located source.


## Validation and Acceptance


Add `AdaptiveProposalSpec`, PostgreSQL `AdaptiveDeliverySpec` and worker `ExecutionCapacitySpec`. Inputs select different organizations for small/large cases and a recorded early finding changes an assignment. Resume after decision commit with provider/capability counters reset; no new decision or duplicate assignment occurs. Forbidden target/model, cycle, stale checkpoint and exhausted budget refuse before effect. Reconfiguration while suspended cannot expand authority. Independent worker intervals overlap within configured bounds; shared writers never overlap, an unrelated root progresses, and a lower bound drains safely. Actual coordinator decision usage and worker usage settle the same root and runtime capacity. A held coordinator call does not hold a workflow advance or prevent unrelated root/timer progress. A real IR-12 decision slot obeys its decision-only permissions independently of an unused whole-run default. A fake all-green child set with a failing combined check leaves objective open. Passing this child proves coordinator mechanics; only plan 86's real integrated artifact/live trial closes IR-16.


## Idempotence and Recovery


Use additive, schema-qualified migrations created through `just new-migration`; never edit an applied migration or upstream private tables. Re-running migrations and accepted commands must converge. Retain payloads and deduplication records referenced by live executions, idle sessions, pending handoffs or unresolved effects; terminal workflow GC is not permission to delete them. Roll forward after introducing a journal patch, because an older binary cannot serve its new branch. A storage or authority failure stops admission and preserves recorded work; retry with the same logical identities, not a newly minted root. At completion, distill durable storage/interface decisions into local ADRs under the contract in `agents/skills/exec-plan/ADR.md`.


## Interfaces and Dependencies


This plan owns `Coordination.Proposal`, validation, adaptive Flow/program registration, checkpoint adapter consumption, `IntegratedAcceptance`, decision inspection and runtime scheduling/capacity configuration. It consumes plan 84 session commands/events, plan 82 execution selections, plan 81 reservation APIs and plan 83 execution jobs. Existing `docs/plans/73-define-typed-decision-programs-and-authorized-model-catalogs.md`, `docs/plans/74-run-shikumi-decisions-through-governed-provider-calls.md`, `docs/plans/75-persist-decision-call-evidence-across-retries-and-restarts.md` and `docs/plans/76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md` keep typed decision/catalog/evidence ownership.

IR-13's authoritative checkpoint contract must support current reads, expected-revision writes, stable operation deduplication and atomic accepted-progress/evidence updates. Cross-store transitions use persisted intents and idempotent acknowledgements, never a presumed distributed transaction. Plan 86 owns artifact qualification and plan 87 owns mandate fields/wakes; neither duplicates the coordinator or its proposal validator.
