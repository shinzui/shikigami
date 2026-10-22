---
id: 81
slug: enforce-root-resource-reservations-across-durable-work
title: "Enforce root resource reservations across durable work"
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
      verdict: "approved"
      note: "DelegationBudget, Delegate context and spec paths verified; no hard child deps; acceptance observable"
---

# Enforce root resource reservations across durable work

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Give every descendant, resumed assignment and recurring cycle one durable resource envelope. Two local orchestrators competing for the final slot can cause at most one dispatch, and unknown provider usage remains visible after restart. This delivers the shared-accounting portion of [IR-16](../improvement-requests/support-adaptive-durable-orchestration.md), independently of model coordination. It does not implement a major-task store or recurring scheduling. There are no hard child-plan dependencies.


## Progress


Implementation has not started. Seed unchecked milestone entries when implementation begins.


## Surprises & Discoveries


None recorded during implementation.


## Decision Log


2026-10-10: Separate resource accounting from adaptive scheduling: atomic store tests can establish conservation before any model controls work. Extend the existing descendant ledger transactionally for enrolled roots and preserve legacy behavior for unenrolled jobs.


## Outcomes & Retrospective


To be filled during implementation. Do not claim request completion until every acceptance case below, including stated external integration gates, has evidence.


## Context and Orientation


`shikigami-core/src/Shikigami/Store/DelegationBudget.hs` already reserves deterministic child workflow ids under a row lock in `reserveDelegationSlots`; it counts lifetime descendants, not currently executing work, tokens or unknown attempts. `shikigami-core/src/Shikigami/Agent/Delegate.hs` reserves before spawning; `Agent/Delegate/Context.hs` and `Agent/RunJob.hs` propagate the root id. Preserve this boundary and historical jobs. A reservation is capacity committed before an effect; settlement records measured consumption or explicit uncertainty afterward. A fencing token is a monotonically increasing owner generation checked when dispatching, not a claim that a former process stopped.

[ADR 0023](../adr/0023-delegation-is-governed-at-the-child-spawn-boundary.md) requires one governed spawn boundary and stable reservation repair. [ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md) requires fresh exact authorization in addition to resource admission. [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md) requires measured pool headroom before raising workflow concurrency. This plan defines accounting only; plan 85 owns runtime scheduling.

The repository is a Cabal multi-package Haskell service. `shikigami-core` owns domain behavior and store adapters; `shikigami-workers` owns queue, resume and timer processes; `shikigami-server` owns operator commands. `shikigami-migrations/sql-migrations/manifest` owns append-only SQL ordering. `shikigami-core/test-postgres/Main.hs` registers tests using `Shikigami.Migrations.TestSupport.withShikigamiMigratedSuite`, which supplies isolated disposable PostgreSQL databases. Register new modules and tests in the owning Cabal file and test entry point; generated files under `Generated/` are regenerated, never hand-edited.


## Plan of Work


### Milestone 1: Specify and prove atomic resource admission

Create `shikigami-core/src/Shikigami/Execution/Identity.hs`, `Execution/Resources.hs` and `Store/ExecutionResources.hs`. Define separate root, logical operation and actual attempt ids. Store immutable admitted envelope, absolute cutoff, root revision, per-dimension limits, reservations, settlement facts and narrowed descendant allocations. Dimensions include active work, lifetime descendants, model attempts, tool/command attempts, wall-time cutoff, tokens and cost when measurable. Amounts are nonnegative bounded integers or fixed decimal currency values with explicit units, never floating-point money. Missing limits mean operator policy decides admission, not an inferred infinite allowance.

Use one transaction locking the root before operation rows. Idempotent reservation compares immutable request fingerprints; the same key with different dimensions or scope conflicts. Atomically reserve every requested dimension or none. Child suballocations consume root capacity and can only narrow; they never establish an independent accounting root. Add `ExecutionResourcesSpec` to core and PostgreSQL suites. Two concurrent last-slot requests must yield one admitted operation and one `ResourceExhausted`, with no partial reservation. Repeating the admitted request returns its existing reservation.

### Milestone 2: Preserve measured and unknown consumption

Add begin-attempt, settle and reconcile commands. Logical retries retain the operation key but every actual transport attempt gets a new attempt id and fresh applicable reservation. Known usage settles once; conflicting repeated settlement is rejected. Unknown outcomes retain conservative reservation and a reason; expiry of a worker lease alone never releases them. Token/cost-bounded admission requires an enforceable request ceiling or conservative reservation. If the transport cannot bound a dimension, fail that admission or require an explicitly admitted unknown-usage policy; never silently claim a hard cost cap. Record overage explicitly and stop further admission.

Cutoff, cancellation and reduced concurrency deny new work while allowing result recording and reconciliation. A lower active-work cap may be below current occupancy; existing accepted work drains without cancellation being fabricated. Race settlement and duplicate retries, drop a client after commit, and reopen the database. Counters and unknown reservations must match the uninterrupted case.

### Milestone 3: Connect existing delegation and expose inspection

Extend `Agent/Delegate/Context.hs`, `Agent/RunJob.hs` and `Agent/Delegate.hs` to carry an optional execution-root reference in addition to historical delegation context. At new-root admission seed it once; descendants cannot seed a missing root. For enrolled roots make the old lifetime-descendant reservation and new resource reservation a single store transaction through a shared transaction-level helper, retaining the old cap as an additional ceiling. Spawn still follows the committed reservation and replay repairs reservation-without-child. Old jobs decode without enrollment and retain their existing behavior.

Add bounded read-only resource inspection to `shikigami-server/src/Shikigami/Server/Command/` and its parser, using a proposed `resources inspect ROOT --json` command. Return limits, settled amounts, held/unknown reservations, cutoff and refusal categories, without prompts or secrets. Test old JSON, duplicate child ids, missing root and a nested child that attempts to mint a fresh allowance. Follow [workflow versioning](../workflow-versioning.md) for every durable-body change. Keep old journal populations on real old branches behind newly declared patch ids; preserve result codecs. Add declarations to `domain/shikigami.keiro-workspace`, regenerate the runtime and conformance artifacts, and union new workflow patch sets in `shikigami-core/src/Shikigami/Workflow/Versioning.hs`. Long-lived workflows restore a seed first, use static labels within each generation, rotate with `continueAsNew`, and republish generation-owned wake references. Do not invoke the pre-v1 reset exception without separately proving all four documented empty-population conditions. Default this plan to compatible evolution.


## Concrete Steps


Run from the repository root in the existing development environment; if native tools are unavailable, enter `nix develop` first. PostgreSQL tests own disposable databases and must not be pointed at production. Capture a baseline before implementation, then run the following after each applicable milestone:

```bash
MP14_BASE=$(git rev-parse HEAD)
cabal build all
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-server-test --test-show-details=direct
just migration-schema-isolation
```

The build and tests must exit zero; tests report all cases passed. These are future implementation checks, not results of creating this plan. Add the named new test groups before using their success as evidence. If domain or workflow contracts change, scaffold with the checked workspace, stage/commit generated artifacts so the existing regeneration check compares the intended baseline, then run:

```bash
just keiro-gate "$MP14_BASE"
```

The gate must report no unexplained breaking change and generated conformance must pass. Record actual commands, baseline revision and bounded evidence in the living sections. Dependency source lookup starts with Mori; no new dependency bound is selected here. Before a later bound, pin or workaround change, verify the authoritative registry and upstream release tags as well as the Mori-located source.


## Validation and Acceptance


The new PostgreSQL suite must prove atomic all-dimension reservations, competing local orchestrators, batch refusal without partial writes, duplicate acceptance, conflicting key rejection and no double settlement. Restart after reservation, after dispatch expectation and after settlement; fresh readers see the same consumed and uncertain totals. A fake dispatch counter remains zero on denial. Replacing a worker or narrowing an allocation cannot reset totals. Lowering a cap does not destroy admitted work. Existing `DelegationBudgetSpec`, `DelegationBatchSpec` and historical wire tests remain green. The inspection command returns bounded JSON distinguishing known consumption and unknown usage. Downstream plan 83 supplies model/tool wiring; plan 85 supplies real progress/fairness proof, so this child alone does not establish all of IR-16.


## Idempotence and Recovery


Use additive, schema-qualified migrations created through `just new-migration`; never edit an applied migration or upstream private tables. Re-running migrations and accepted commands must converge. Retain payloads and deduplication records referenced by live executions, idle sessions, pending handoffs or unresolved effects; terminal workflow GC is not permission to delete them. Roll forward after introducing a journal patch, because an older binary cannot serve its new branch. A storage or authority failure stops admission and preserves recorded work; retry with the same logical identities, not a newly minted root. At completion, distill durable storage/interface decisions into local ADRs under the contract in `agents/skills/exec-plan/ADR.md`.


## Interfaces and Dependencies


This plan owns `Execution.Identity`, `Execution.Resources`, root reservation tables and `Store.ExecutionResources`. Expose typed operations conceptually named `reserveOperation`, `beginAttempt`, `settleAttempt`, `reconcileAttempt`, `narrowAllocation` and `inspectRoot`; all accept root and stable operation identity, enforce expected revision where state changes, and return typed admitted/conflict/exhausted/unknown results. Provide transaction-level settlement hooks so plan 83 can commit turn outcome and usage in one database transaction. Do not expose raw SQL or an unrestricted refund operation to models.

Consumers are `docs/plans/82-pin-governed-execution-settings-for-agent-assignments.md`, `docs/plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md`, `docs/plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md`, `docs/plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md` and `docs/plans/87-supervise-recurring-objectives-from-current-durable-checkpoints.md`. They propagate the root; none owns another counter. Objective references come from separately owned IR-13; the ledger can be tested with a stable fixture reference without implementing task management.
