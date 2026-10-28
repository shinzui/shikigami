---
id: 93
slug: adopt-guarded-catalog-commands-and-qualify-current-dsl-consumer-contracts
title: "Adopt guarded catalog commands and qualify current DSL consumer contracts"
kind: exec-plan
created_at: 2026-10-28T13:08:07Z
intention: "intention_01m61agcfzek98hqzkb0kxcfmg"
master_plan: "docs/masterplans/16-upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-28T13:08:07Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-28T13:21:22Z
      mode: "update"
      note: "Complete source-grounded draft and link the requested Mina intention"
---

# Adopt guarded catalog commands and qualify current DSL consumer contracts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture


Make an execution's expected relational refusal a typed result from the released atomic command runner. A refused operation leaves no lifecycle event, payload, cursor movement, call settlement or accepted receipt. Accepted operations still commit those facts together. At the same boundary, qualify current generated consumers and replace only DSL adapters for which the released tool supplies an equivalent executed contract.


## Progress


- [ ] M1: One accepted execution outcome and one typed refused outcome prove the guarded catalog protocol with real PostgreSQL transactions and an active rebuild fence.
- [ ] M2: All applicable execution persistence paths use the accepted protocol, preserving concurrent retry, accounting, permission and claim behavior.
- [ ] M3: Every 0.21/0.22 DSL capability and existing consumer adapter has an evidence-backed disposition, generated conformance passes, and any adopted mapping passes historical replay qualification.


## Surprises & Discoveries


None yet.


## Decision Log


2026-10-28: Adopt the released typed catalog precondition for expected execution business refusals. Keep rich payload writes in the live inline projection and preserve their atomicity. Do not call an asynchronous view command authority or make encode-only provider payloads replayable.

2026-10-28: Structural enum equality and mapped construction are adopted only where an actual consumer needs them. Existing queue enum spellings and v1/v2/v3 readers are durable contracts; replacing them solely to use new syntax is outside this upgrade's compatibility promise.


## Outcomes & Retrospective


To be filled during implementation.


## Context and Orientation


Hard prerequisite: `docs/plans/92-resolve-the-released-keiro-0-22-cohort-and-rehearse-the-composed-migration.md` must be Complete. It supplies the real released 0.22 interfaces, generated naming changes and passing migration fixtures. This child owns semantic command/DSL adoption after that baseline. `docs/plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md` separately owns the evolving execution driver; reconcile its working-tree changes before editing shared persistence.

`domain/shikigami-execution.keiro` defines the generated ExecutionLifecycle aggregate: identity, immutable snapshot digest, monotonic revision and Active/Parked/Unresolved/terminal states. `shikigami-core/src/Shikigami/Execution/Store.hs` owns protected SQL rows and `persist`. At planning time `persist` calls `runCommandWithCatalogProjections`, captures the whole command transaction as a live projection, and uses `ExecutionAbort` exceptions to return application refusals. `PersistenceFailure` deliberately separates stream rejection from a captured check failure. Its duplicate lookup must never turn a resource refusal into AlreadyAccepted. `recordOutcomeAndAdvanceWith` commits accepted outcome, cursor, normalized call facts and resource settlement together; newer claim paths add fenced attempt and wake behavior. Preserve all of it.

`shikigami-core/src/Shikigami/Execution/Catalog.hs` captures only the execution writer in the shared generated catalog. `shikigami-core/src/Shikigami/RunEvidence/Catalog.hs` does the converse for evidence. Both must preserve the other's projection sets. `domain/shikigami-run-evidence.keiro`, `Shikigami.RunEvidence.BehaviorHoles`, `Shikigami.RunEvidence.Conformance`, and the service-level generated conformance own aggregate evidence. Passing examples of identity/register equality are not automatically exhaustive guard proofs.

A catalog precondition is a bounded application SQL check inside the same transaction and catalog fence as a tentative lifecycle append. Keiro 0.22 exports `runDomainCommandWithCatalogProjectionsGuarded`, `GuardedCatalogOutcome` with `CatalogCommandOutcome` and `PreconditionRefused`, and `CatalogPreconditionContext`. Its callback returns `Transaction (Either refusal ())`; Left rolls back the whole append. The callback is skipped for a silent domain decision. A rolled-back refusal has no accepted receipt or committed position. Discover and read the released implementation using Mori; source entry is `mori://shinzui/keiro`, project-relative `keiro/src/Keiro/Projection.hs` (artifact-level URI pending), and guide `mori://shinzui/keiro/okf/guides/concepts/DOC-29`.

Relevant decisions are [ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md) for honest generated consumers, [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) for patches, and [ADR 0053](../adr/0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md) for protected payload and lifecycle atomicity. Follow `docs/workflow-versioning.md` for any Agent/Flow body edit. `mori://shinzui/keiro-runtime-patterns/docs/keiro-projection-catalogs`, `mori://shinzui/keiro-runtime-patterns/docs/keiro-command-cycle-and-errors` and `mori://shinzui/keiro-runtime-patterns/docs/keiro-mapped-consumer-surfaces` define the upstream contracts. The initial audit is `docs/architecture/keiro-0.22-pattern-audit.md`.


## Plan of Work


### M1 — Prove one producer/consumer transaction

Begin with `recordOutcomeAndAdvanceWith` and its PostgreSQL transcript/selection tests, before converting all persistence operations. Adapt the generated validated stream to `DomainCommandHandler` with a total classifier. ExecutionLifecycle currently emits an event on every accepted edge; do not add fake silent edges, public reject payloads or a blanket normal no-op to evade rejection semantics. If a classifier is needed for an unreachable silent case, return a bounded explicit execution refusal; prove the current aggregate contains no silent live edge. Unmatched edges remain outer `CommandRejected`.

Split expected relational admission checks from rich inline writes. The precondition performs minimal indexed identity/revision/permission/root/claim checks under the admitted catalog bindings and returns `Either ExecutionError ()`. Keep payload writes, outcome storage, cursor movement and accounting settlement inside the accepted command transaction's live projection. Where a late hook can refuse after tentative writes, prove the chosen supported callback arrangement rolls back every participant and does not convert the refusal to accepted work. Do not move accounting to a second transaction. Avoid mutable cross-callback cells; use transaction-local rereads under retained application row locks when values must be checked again. Keep one documented lock order across all participating application writers.

The upstream callback may be retried by Hasql. It must contain no provider/network effect, recursive append, extra stream/group lock, independent transaction/savepoint/isolation control, sequence, session lock or effect that survives rollback. Catalog serving bindings are valid only during this invocation; retaining their value retains no lock. Preserve typed infrastructure errors separately from business refusals. Catch asynchronous cancellation correctly; do not replace it with a successful refusal.

Use the released same-database fixture to run the accepted outcome and a typed refusal on separate connections, then fence the execution rebuild group. Check the generated lifecycle stream and every application participant before and after. M1 succeeds only when accepted work commits once and a refused/fenced operation changes nothing, with no fabricated receipt or global position.

### M2 — Integrate the accepted execution boundary

Apply the proven split to admission, accepted operations, permissions, terminal transitions, executor claims, uncertain results and reconciliation wherever they use catalog commands. Preserve stable fingerprints, operation positions, owner/generation fences, late-receipt rules, original accounting and protected replay permits. Expected relational refusals must leave through `PreconditionRefused` and retain exact application error identities. Preserve stream rejection, retry exhaustion, catalog refusal, corrupt history and unexpected infrastructure failure as distinguishable operational outcomes.

Retire exception-based expected-refusal plumbing at the migrated catalog boundary. Integrity checks in accepted writes and read-side decode/access errors are separate obligations; do not remove rollback protections merely to eliminate a helper name. If a remaining exception cannot be replaced by this API, document its exact scope and invariant in the audit. `Attestation.EvidenceStore` retains its justified rich inline projection; adopt the guarded runner there only if an actual relational precondition exists, not to rewrite an already correct upsert.

Expand race tests to equal retries, conflicting immutable inputs, root cancellation, stale claim generation, permission expiry, injected failure after tentative work and rebuild-fence refusal. Update ADR 0053 with the supported typed refusal protocol and lock/atomicity constraints when accepted.

### M3 — Current DSL capabilities on real consumers

Review candidate Language 6 scalar-list public contracts, mapped-register initial/write-lift, and exact structural enum equality against every real queue, query, event and register consumer. The current ExecutionLifecycle is primitive Text/Int and has no mapped structural enum. RunEvidence's six identity-equality guards are nominal ID/Text comparisons; structural enum support alone does not make them total. Queue route/trigger enums intentionally preserve application Aeson spelling. Do not rename those bytes or widen RunEvidenceId admission to claim feature adoption.

For any demonstrated matching consumer, replace the old adapter with the checked generated binding, preserve one codec authority, and run binding round trips, finite fixture/owner/key laws, event-history and register-layout comparison, fold/snapshot identity and replay checks before removing the old code. Construction lifts must be pure, total and versioned. Where no consumer matches, record the exact type/surface and reason rather than adding unused declarations. Preserve create-once witness bodies and require service conformance to execute all obligations. Update `docs/architecture/shikigami-domain-inventory.md` for the six-member workspace and actual evidence/execution ownership.


## Concrete Steps


Use the repository root and declared development shell. Before API design, resolve the source through Mori:

```bash
mori registry show shinzui/keiro --full
mori registry docs shinzui/keiro
mori path mori://shinzui/keiro/okf/guides/concepts/DOC-29
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test --test-options=-j1
nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-core-domain-test
nix develop --no-write-lock-file -c just keiro-check
nix develop --no-write-lock-file -c cabal test keiro-shikigami-conformance
git diff --check
```

Run the direct pinned scaffold and `just keiro-diff` against the explicit pre-change revision recorded at this child's start. The `keiro-scaffold` recipe checks all unstaged core files, so preserve a reviewed candidate snapshot/index before invoking `just keiro-gate <recorded-ref>`; do not stage someone else's unreviewed work or weaken the recipe to hide drift. Retain concise transaction and DSL reports under `docs/evidence/keiro-0.22/`.


## Validation and Acceptance


Run the full core PostgreSQL suite serially because shared ephemeral connection budgets have previously failed under parallel suites. Strengthen existing `shikigami-core/test-postgres/Shikigami/ExecutionTranscriptSpec.hs` and `ExecutionSelectionWorkflowSpec.hs`, using separate connections for real concurrency. An accepted outcome, lifecycle append, call settlement and cursor advance are one fact. A relational refusal, a fenced group, a failed last check and a stale claim each leave every participant unchanged. A committed response loss followed by the same request converges; a changed request under the same identity refuses. Classifiers do not turn corrupt replay or ambiguity into business rejection. Read-side protection remains intact.

Generated service conformance must pass with all required witnesses, including the updated behavior obligation reports from 0.21. A mapping adoption requires independent wire, fold, snapshot and replay evidence; no application mapper is removed based solely on successful compilation. The audit has a concrete disposition for each new DSL feature and every retained workaround. Missing optional queue fields remain a justified upstream limitation recorded in FRIC-9.


## Idempotence and Recovery


Preserve literal historical event/queue fixtures and snapshot/journal readers. Refactor internal transaction plumbing first without changing stored event or workflow shapes. If semantics require a persisted change, add versioned codecs/upcasters or a real patch branch and rerun the declared evolution gate; do not erase old results. No destructive rebuild is needed for live-only execution/evidence payloads. Revert an unaccepted code change against its captured candidate, preserving unrelated execution work. After any new contract is written, rollback requires its explicit reader/schema compatibility evidence.


## Interfaces and Dependencies


The released guarded runner consumes `DomainCommandHandler`, a typed target stream, one validated catalog and the matching projection set. It returns outer `CommandError` or `GuardedCatalogOutcome`; only accepted domain work supplies committed metadata. Application `ExecutionError`, `PersistenceFailure`, operation fingerprints and transaction-level resource/selection hooks remain the public owner boundaries. This child owns their adapter, not a new root ledger or accounting protocol. `docs/plans/94-adopt-current-runtime-lifecycle-patterns-and-bounded-operator-inspection.md` shares catalog/display integration; it may proceed after plan 92 and should consume these result meanings. `docs/plans/95-close-the-runtime-pattern-audit-and-qualify-the-keiro-0-22-rollout.md` requires this entire child Complete.
