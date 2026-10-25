---
id: 75
slug: persist-decision-call-evidence-across-retries-and-restarts
title: "Persist decision call evidence across retries and restarts"
kind: exec-plan
created_at: 2026-09-26T18:34:42Z
intention: "intention_01m3fft4cceb1ba9t3fammx5x4"
master_plan: "docs/masterplans/13-compose-shikumi-decisions-in-durable-flows.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-26T18:34:42Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-21T20:30:29Z
      mode: "update"
      note: "Coordinate Shikumi MP-12 without blocking current scope; bind parameter state and derivation, preserve committed results and distinguish probability data from call evidence"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:00:35Z
      mode: "update"
      note: "Apply review: prerequisite narrowed to plan 73 milestones 1 and 3"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T20:54:13Z
      mode: "implement"
      note: "Implement durable attempt ledger and restartable common compliance facts"
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T00:41:18Z
      verdict: "comments"
      note: "Evidence, store, migration and PostgreSQL test paths verified; hooks contract consistent with plans 73/74/76; no blocking findings"
---

# Persist decision call evidence across retries and restarts


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Make every provider attempt within a Flow decision visible after a worker restart, and make the final run assessment account for all of them. A two-model program, failed attempt, retry, and missing terminal must remain distinguishable. Operators can inspect a decision's parent run, static step, program version and actual model-call records without relying on a process-local trace collector.

Hard dependency: milestones 1 and 3 of `docs/plans/73-define-typed-decision-programs-and-authorized-model-catalogs.md`, which define prepared decision identities, durable-result codecs and the call callbacks with their fake evidence. Its catalog milestone is not required here. This plan can proceed alongside `docs/plans/74-run-shikumi-decisions-through-governed-provider-calls.md` with typed Baikai evidence fixtures. `docs/plans/76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md` connects the ledger to production Flow execution and finalization.


## Progress


- [x] (2026-10-25) Milestone 1: Additive ledger commits expectations and exact convergent terminal writes across connections; migration composition (5 tests), smoke/rerun (9 tests), and schema isolation pass.
- [x] (2026-10-25) Milestone 2: Versioned CallComplianceFacts feed the common live/restarted evaluator; facts-only sanctioned lifecycle finalization preserves exact provider JSON and all existing reason fixtures pass.
- [x] (2026-10-25) Milestone 3: Crash windows, terminal rollback, unsupported versions, two-model inspection, concurrent admission, run-wide limits and cost uncertainty pass; all 208 PostgreSQL and 453 core tests pass.


## Surprises & Discoveries


The existing provider record is encode-only all the way down to its usage payload. Consumer facts therefore normalize usage quantities and exact rational cost while retaining quality separately; they never decode a ModelCallEvidence. Actual retry/node relationships are not supplied at the provider seam, so the ledger marks their attribution unknown rather than inventing it. A profile constraining that unknown assessment cannot receive a clean pass.

FRIC-2 in `docs/friction-log/` records default Tasty concurrency exceeding the ephemeral PostgreSQL client ceiling. Serial test scheduling passed the complete suite.


## Decision Log

2026-10-25: Put normalized facts in `Attestation.CallFacts`, with one evaluator in `Compliance`. Preserve raw JSON through the existing EvidenceStore catalog when typed calls are unavailable at restart. Bound run reports to 10,000 attempts and detail pages to 200. Allocate the opaque token UUID before the SQL transaction and assign its ordinal under the run lock via the additive shared `withAttemptOrdinal` operation; completion verifies both against the ledger.


2026-09-26: Persist expectation before dispatch and terminal evidence before journaling a successful decision. An in-memory collector loses earlier calls when a process crashes between decisions.

2026-09-26: Preserve full Baikai evidence as encode-only JSON and persist a separate versioned Shikigami compliance fact record derived from typed evidence at capture time. Restarted evaluation must not invent a Baikai decoder or a second compliance policy.

2026-09-26: Ordinary runs receive durable decision-call reports without fabricated reviewed-artifact bindings. Existing sanctioned attestation finalization remains available only with its real caller-supplied binding.

2026-10-21: Revision for [Shikumi MP-12](mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs) coordination: retain parameter/derivation identities in invocation bindings and keep judgment probabilities separate from provider-attempt/compliance evidence. Probability data belongs to the validated result envelope, not a substitute terminal record. See [ADR 0041](../adr/0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md).

2026-10-21: Review revision. The prerequisite is narrowed to plan 73's milestones 1 and 3; persistence needs the typed contracts and hooks, not configuration loading.


## Outcomes & Retrospective


Completed durable expectation/terminal accounting and restartable policy evaluation. The core suite passes 453 tests. The PostgreSQL suite passes 208 tests with `--test-options=-j1`; the nine new ledger tests include separate connection lifetimes, two different model decisions, conflicting terminal writes, injected SQL faults, unknown fact versions, concurrent admission and conservative cost handling. Existing run-evidence cases also prove evaluator parity and raw-payload preservation through facts-only finalization.

Migration composition (5 tests), migration smoke/reapplication (9 tests), and `just migration-schema-isolation` pass. Validation uses plan 73's temporary project to preserve the local Kikan checkout and repository dependency declarations. No checked domain or workflow shape changed, so this child adds no workflow labels or patch. [ADR 0044](../adr/0044-decision-attempts-persist-expectations-and-consumer-owned-compliance-facts.md) distills the persistent boundary. FRIC-2 is accepted with serial PostgreSQL scheduling; no friction entries remain logged under this child. Plan 76 still owns production wiring, whole-Flow policy pinning and journal replay acceptance.


## Context and Orientation


`shikigami-core/src/Shikigami/Attestation/Evidence.hs` defines `ExpectedCall`, `RecordedCallEvidence`, `RunEvidence`, `configureEvidenceCall`, and `newEvidenceCollector`. The collector uses an IORef and assigns correlation ordinals from terminal event order. It is useful in a live process but cannot recover calls from earlier processes. The current workflow does not wire these helpers around general Shikumi execution. `Shikigami.Attestation.Compliance.evaluateCompliance` consumes typed Baikai evidence and applies call, completeness, artifact, result, and limit rules.

`shikigami-core/src/Shikigami/Attestation/EvidenceStore.hs` persists accepted evidence lifecycle transitions and rich JSON projections atomically through a validated Keiro catalog. `shikigami-core/src/Shikigami/RunEvidence/Catalog.hs`, `Live.hs`, and `Query.hs` own the live projection and queries; the checked shapes live in `domain/shikigami-run-evidence.keiro` and related workspace declarations. `RunEvidence` requires a real agent/artifact/review/profile binding. Ordinary `RunJob` execution does not carry all those facts. Do not manufacture them to attach a model-call log.

[ADR 0010](../adr/0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md) states that Baikai `ModelCallEvidence` has no supported FromJSON decoder. Full evidence remains encode-only in durable projections; the current implementation uses catalog-aware projection writes, superseding the ADR's historical runner name. [ADR 0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md) makes the pinned profile authoritative. [ADR 0023](../adr/0023-delegation-is-governed-at-the-child-spawn-boundary.md) explains why child closure and stable parent identity matter. [Workflow versioning](../workflow-versioning.md) explains that provider actions can repeat if the journal append is lost.

Migrations are append-only files under `shikigami-migrations/sql-migrations/` with entries in `manifest`. `Shikigami.Migrations.TestSupport` provides one migrated template and a fresh database per test. Use `shikigami-core/test-postgres/Shikigami/RunEvidenceSpec.hs` as the atomic persistence example. Dependency APIs and types belong to `mori://shinzui/baikai/packages/baikai`, `mori://shinzui/keiro/packages/keiro`, and `mori://shinzui/kiroku`; discover their source through Mori before editing integration code.


## Plan of Work


### Milestone 1: Add a durable attempt ledger


Create `shikigami-core/src/Shikigami/Decision/Evidence.hs` and an additive migration for decision invocation and attempt records. Store parent run/workflow/generation, static decision label, prepared-decision identity, immutable program/schema/validator IDs, selected model descriptor, pinned profile reference, and a versioned status. Store each actual provider attempt with a unique call ID, attempt ordinal, effective tuple, expected/terminal state, optional relationship, optional Baikai call ID, and preserved terminal evidence JSON. An idempotent ensure-invocation operation must compare immutable binding bytes on conflict; a mismatch is a refusal. Do not put credentials, prompts, or unvalidated output into these operational rows.

The immutable invocation binding includes EP-1's parameter-state digest/format and local derivation version. Store these references, not the instruction/demonstration payloads; changed state under the same invocation identity is a conflict. Expose the identities in bounded inspection so two equal provider requests with different local program meaning remain distinguishable.

Implement the shared `beginCall` and `finishCall` hooks. Under the run ledger's serialization boundary, `beginCall` checks remaining duration/call/budget limits, allocates a fresh attempt identity, and commits its expectation before returning. An expectation proves admission, not that the network request reached a provider. `finishCall` atomically persists the terminal status, exact provider evidence when present, and normalized compliance facts. Retrying the same finish with identical data converges; different evidence under the same attempt ID is a conflict. Distinct actual retries always remain distinct rows. Enforce accounting across concurrent calls rather than using a mutable per-process ordinal as persistent identity.

Migrate twice against the test fixture and prove the second run changes nothing. Add `DecisionEvidenceSpec` to the PostgreSQL test suite. Simulate a crash after begin but before finish and verify that a fresh connection observes the unresolved expectation. An evidence-write fault must leave no successful terminal marker.

### Milestone 2: Make compliance restartable without decoding provider evidence


Define a versioned consumer-owned `CallComplianceFacts` containing exactly the fields the current compliance evaluator needs: requested/effective/observed identities with their evidence quality, thinking and sampling translations, outcome, usage/cost uncertainty, strength, and correlation/relationship data. Derive it once from typed `ModelCallEvidence` at terminal capture. Preserve unknown values as unknown. Keep the exact upstream JSON beside it for inspection; never rebuild a typed provider record from that JSON or infer an observed model from an echoed request model.

`mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs` plans probability-bearing decision results. Their probabilities/confidence describe a judgment, not whether an authorized provider attempt occurred. EP-1's result codec and EP-4's outcome journal preserve any such validated result data; this ledger and its compliance evaluator continue to require actual attempt/terminal facts. Do not derive a new decision from those facts during report reload. Use current typed fixtures to prove a confidence-bearing result cannot close an unresolved attempt. No upstream probability type or Jev release is required for this plan.

Refactor `Shikigami.Attestation.Compliance` so both live typed records and persisted facts feed one shared call-policy evaluator. Preserve all existing reason semantics. Add a run decision-evidence report keyed by run identity containing all decision invocations, expected and terminal attempts, pinned profile, completeness status, and the common call/limit assessment. A report without a profile says so; a call-policy pass is not a signed sanctioned attestation.

For runs supplied a valid existing reviewed-artifact binding, feed the same facts into the existing complete accounting and artifact/result/child checks, and finalize using the owning `EvidenceStore` lifecycle/catalog boundary. Extend that boundary to preserve rich stored call payloads when replay finalization has only normalized facts. Do not create a competing lifecycle authority or rewrite stored provider evidence. If checked projection shapes change, update their declarations/mapping artifacts and regenerate through the standard gate; no manually edited generated SQL/code. Keep unsupported historical fact versions explicit and fail closed rather than skipping those calls.

A fresh-process test writes two different model calls, releases all process-local collectors, reloads facts and exact JSON, and produces the same assessment and call IDs as live evaluation. Missing evidence, wrong model, weakened thinking, missing child, unknown cost, and unsupported fact versions produce explicit reasons. Existing attestation fixture encodings and tests must remain compatible or receive a declared new version; ordinary ledger rows must not alter signed payloads incidentally.

### Milestone 3: Prove crash convergence and bounded accounting


Exercise a failure after the provider terminal is persisted but before the enclosing decision journal append. A subsequent actual attempt gets a new ID; both remain visible and counted. Exercise a failure after expectation but before dispatch and leave that expectation uncertain. Completion cannot erase uncertainty or seal a fully accounted sanctioned result while an expected call lacks a terminal. A conservative limit refusal may require operator reconciliation; it must not silently restart a spent budget from zero.

Provide a read-only query returning a bounded summary plus paginated or otherwise bounded call detail by run/decision. Reuse the existing internal query style; a new public read API or signing service is outside scope. Add fault injection around terminal persistence and final lifecycle writes and assert atomicity. Preserve all previous child relationship semantics, and never count one terminal twice when folded into a parent. Add a parity fixture for live versus resumed mixed-model runs and an inspection assertion that each record identifies its decision step and program.

Update the evidence ADR, or create a focused new one, following `agents/skills/exec-plan/ADR.md`. Record why normalized facts are a consumer contract and why unresolved attempts prevent a clean compliance claim. This plan changes storage and evidence boundaries; the Flow integration plan remains the sole owner of workflow-body labels.


## Concrete Steps


From the repository root, capture the revision used for any declaration evolution before edits:

```bash
DECISION_EVIDENCE_BASE=$(git rev-parse HEAD)
cabal test shikigami-migrations --test-show-details=direct
just migration-schema-isolation
cabal test shikigami-core-test --test-show-details=direct
cabal test shikigami-core-postgres-test --test-show-details=direct
```

If the evidence catalog or checked domain shape changes, additionally run:

```bash
just keiro-gate "$DECISION_EVIDENCE_BASE"
```

The PostgreSQL suite obtains isolated databases through `withShikigamiMigratedSuite`; use the repository development environment with the required PostgreSQL binaries/extension support. Do not aim fault-injection tests at an operator database. Expected output is all tests passed and a migration rerun with no pending changes. Record actual output and bounded query samples in this plan during implementation.


## Validation and Acceptance


Two terminal calls under one decision yield two unique call rows and exact preserved upstream evidence; a second model in a later decision appears separately in the same parent run report. Restarting the process and querying/evaluating that report preserves every ID, outcome and compliance reason. Repeating an identical terminal write yields one row, while a different payload with its ID fails.

An unresolved expected call blocks complete sanctioned accounting. A denied tuple never creates an actual provider terminal. A retried provider call after a lost decision append increases the attempt count and retains the first call. No in-memory cache reset erases spending or turns uncertain usage into zero. The sanctioned fixture needs real fixture artifact/review bindings; the ordinary-run fixture explicitly lacks them and still exposes accurate mixed-model call evidence.

Reloaded invocation reports preserve parameter-state and derivation identities exactly. Reusing an invocation identity with different state fails rather than merging its evidence. Confidence or probability fields in a decision result never turn a missing terminal into complete accounting.


## Idempotence and Recovery


Never edit an applied migration. Migration reruns use the manifest and are safe. Keep raw provider JSON and normalized fact versions side by side; unknown versions fail visibly without destructive repair. On storage outage the runner refuses to dispatch before a durable expectation, or refuses to return a successful decision before a durable terminal. After an ambiguous network/persistence failure, keep the unresolved record until evidence-backed reconciliation is available; do not delete it to make a test or run pass. Use forward migrations for deployed schema changes.


## Interfaces and Dependencies


Implement the `DecisionCallHooks` contract from `docs/plans/73-define-typed-decision-programs-and-authorized-model-catalogs.md` in `Shikigami.Decision.Evidence`. Expose ensure-invocation, begin/finish, read-report, and finalize operations over an injected durable store. `CallComplianceFacts` and its decoder belong to Shikigami, while Baikai `ModelCallEvidence` remains upstream-owned and encode-only. Shared evaluation belongs in `Shikigami.Attestation.Compliance`; rich projection persistence belongs in `EvidenceStore` and its validated catalog.

`docs/plans/74-run-shikumi-decisions-through-governed-provider-calls.md` supplies typed provider terminals and calls these hooks below internal retry. `docs/plans/76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md` supplies stable workflow/generation/label and pinned policy identity, calls finalization on success or bounded failure, and reuses stored evidence after replay. The callback contract must match exactly across all three plans. Tests can use typed fixture evidence without depending on the runner being complete.
