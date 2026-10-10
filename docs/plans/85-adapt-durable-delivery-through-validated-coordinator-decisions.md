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
---

# Adapt durable delivery through validated coordinator decisions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Let a coordinator change its organization when new evidence warrants it: work directly, create bounded workers or local orchestrators, narrow/split/consolidate assignments, request a specialist or move ownership safely. This delivers adaptive control and actual bounded concurrency for [IR-16](../improvement-requests/support-adaptive-durable-orchestration.md). Hard dependencies are `docs/plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md` (and its transitive resource, model and harness dependencies), existing `docs/plans/76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md` (including plans 73–75), and a delivered IR-13 checkpoint adapter. Plan 86 separately qualifies integrated repository delivery. Recurring scheduling is not required.


## Progress


Implementation has not started. Seed unchecked milestone entries when implementation begins.


## Surprises & Discoveries


None recorded during implementation.


## Decision Log


2026-10-10: Use a compiled Flow with governed typed decisions for the first coordinator. Keep fixed supervisors compatible and model-generated instructions as proposals. Separate runtime capacity from per-objective reservations and measure useful overlap before changing defaults.


## Outcomes & Retrospective


To be filled during implementation. Do not claim request completion until every acceptance case below, including stated external integration gates, has evidence.


## Context and Orientation


`shikigami-core/src/Shikigami/Agent/Workflow.hs` currently substitutes a fixed supervisor for a non-Flow agent declaring delegates, and refuses delegating-Skill overlays. `shikigami-core/src/Shikigami/Flow.hs` registers compiled behaviors. Select a new compiled `adaptive-delivery` Flow that consumes governed typed decisions and continuing-worker capabilities; the coordinator instructions become pinned decision inputs. Do not silently change the old supervisor branch or add raw provider IO to a Flow.

`shikigami-core/src/Shikigami/Workflow/Versioning.hs` currently fixes `maxConcurrentAdvances` to one. Child count therefore does not demonstrate useful simultaneous progress. Plan 83's submit/observe execution driver separates long external work from short workflow advancement. A runtime capacity limit bounds executor occupancy; a root resource limit bounds one objective across all processes. Both must hold.

[ADR 0028](../adr/0028-a-router-catalog-is-a-bounded-snapshot-of-declared-authority.md) pins the permitted target universe; [ADR 0029](../adr/0029-model-routing-output-is-a-proposal-until-validated-against-journaled-authority.md) validates model output before action. [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md) preserves capability-only IO, and [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md) requires measured pool headroom. The existing IR-12 plans are not implemented yet and must not be treated as a working decision engine.

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
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-workers-test shikigami-server-test --test-show-details=direct
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
