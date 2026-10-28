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
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-28T03:46:48Z
      mode: "implement"
      note: "Begin root resource admission and durable attempt accounting"
---

# Enforce root resource reservations across durable work

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Give every descendant, resumed assignment and recurring cycle one durable resource envelope. Two local orchestrators competing for the final slot can cause at most one dispatch, and unknown provider usage remains visible after restart. This delivers the shared-accounting portion of [IR-16](../improvement-requests/support-adaptive-durable-orchestration.md), independently of model coordination. It does not implement a major-task store or recurring scheduling. There are no hard child-plan dependencies.


## Progress


- [x] (2026-10-27) Milestone 1: Atomic resource admission and exclusive narrowed allocations. PostgreSQL tests prove all-dimension and batch atomicity, last-slot competition, key conflicts, bounded units and root conservation.
- [x] (2026-10-27) Milestone 2: Durable attempts, settlement and conservative unknown usage. Fresh connections, racing settlement, explicit reconciliation, cutoff/cancellation, reduced active capacity and overage cases pass.
- [x] (2026-10-27) Milestone 3: Delegation integration, compatible v1/v2 job transport, explicit root enrollment and bounded `resources inspect` output. Full PostgreSQL suite: 250 cases pass, including production delegation propagation and 20 resource-store cases. Core unit suite: 464 pass; server suite: 63 pass; worker suite: 98 pass. The workflow gate against the implementation baseline passes with one additive patch, no breaking change and generated conformance green.

Implementation baseline: `4ff109c7f6e9156fc948046e3e2aca3b40978e70`.


## Surprises & Discoveries


The generated queue admits only required structural fields, including nullable ones. Adding a root field would reject retained jobs. The application now uses the public Keiro codec with version 2 and a v1 upcaster, carrying resource metadata inside the existing opaque trigger payload and restoring the original domain input on decode. Literal v1 fixtures remain accepted and cannot grant enrollment. See FRIC-9 in `docs/friction-log/`. The current Hackage keiro-dsl release (0.22.0.0, upstream tag verified) retains this required-field policy; no dependency bound changed.

The default baseline build cannot resolve two local Kikan packages. Validation uses the pre-existing `.dev/mp13.cabal.project` and isolated upstream checkout; FRIC-8 in `docs/friction-log/` records this occurrence.

A delegation budget must bind to its enrolled resource root. Checking only the new root reservation lets a descendant strip or replace its reference and spend through another path. Both paths now verify the binding; failure rolls both ledgers back.


## Decision Log


2026-10-10: Separate resource accounting from adaptive scheduling: atomic store tests can establish conservation before any model controls work. Extend the existing descendant ledger transactionally for enrolled roots and preserve legacy behavior for unenrolled jobs.


2026-10-27: Use normalized operation/attempt/allocation rows plus one bounded aggregate root, locking the root first for every mutation. Allocations exclusively hold finite capacity in their parent. Cancellation and cutoff stop admission while settlement remains available. The accepted storage and transport constraints are distilled in [ADR 0051](../adr/0051-resource-roots-own-conservative-reservations-and-actual-attempts.md).

2026-10-27: Enrollment is explicit through `Execution.Admission.enrollRootRun`, which rejects descendants and deterministically derives the root from the stable run identity. Historical producers remain unenrolled. The new root-validation step uses a real `shikigami-execution-resources-v1` patch branch. Queue v2 is application-owned; retain the generated structural payload and a literal v1 upcaster instead of adding a required field.

## Outcomes & Retrospective


The shared root ledger, explicit enrollment boundary, actual-attempt accounting, settlement/reconciliation hooks, exclusive allocations, atomic delegation integration and operator inspection are delivered. Unknown usage survives fresh connections; refusal leaves both ledgers untouched; replay repairs accepted reservations without new spending. Historical journal omission and literal v1 queue fixtures preserve unenrolled behavior.

Validation used `nix develop --no-write-lock-file -c cabal` with `--project-file=.dev/mp13.cabal.project`: `build all`, the complete core/PostgreSQL/server/worker suites, and a focused rerun of the 20 resource cases after the final admission-policy change. `just migration-schema-isolation` and `git diff --check` pass. `just keiro-gate 4ff109c7f6e9156fc948046e3e2aca3b40978e70` used a temporary Cabal wrapper pointing to that same isolated project; check/inspect/scaffold/diff/conformance pass. The hand-owned conformance expectations accept only the new root-validation patch.

[ADR 0051](../adr/0051-resource-roots-own-conservative-reservations-and-actual-attempts.md) and [the operations guide](../operations/execution-resources.md) preserve the identity, conservation, retention and rollout constraints. FRIC-8 is accepted with the isolated dependency-source workaround; FRIC-9 is accepted with the versioned application codec. No entries remain logged under this plan.

This closes EP-1 only. Plan 82 consumes selection/accounting hooks, plan 83 enforces transport ceilings and durable execution, and plan 85 owns real progress and fairness. This does not establish full IR-16 or finite-delivery qualification.


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
