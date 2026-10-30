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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T13:33:35Z
      mode: "update"
      note: "Limit typed refusals to pre-inline checks and retain tested post-write exception rollback."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-30T19:46:17Z
      mode: "update"
      note: "Expand unused-service adoption to six children, current domain census, HTTP/live inspection, Haskell corpus and first-release qualification."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-30T20:38:29Z
      mode: "implement"
      note: "Begin native guarded outcome transaction adoption after accepted plan 92"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T13:29:30Z
      verdict: "changes-requested"
      note: "Specify how post-write finalCheck and accounting refusals fit the pre-inline guarded callback, or explicitly retain their rollback exception path."
---

# Adopt guarded catalog commands and qualify current DSL consumer contracts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture


Make execution admission checks that can run before inline writes return typed refusals from the released atomic command runner. Preserve exception rollback for late checks and write-time owner refusals that the pre-inline callback cannot represent. A refused operation leaves no lifecycle event, payload, cursor movement, call settlement or accepted receipt. Accepted operations still commit those facts together. At the same boundary, qualify current generated consumers and replace only DSL adapters for which the released tool supplies an equivalent executed contract.


## Progress


- [x] M1 (2026-10-30): All 50 ExecutionTranscript PostgreSQL cases pass, including typed refusal, tentative-append rebuild rollback, accepted convergence and late refusal after observed cursor/accounting writes. `docs/evidence/keiro-0.22/guarded-outcome-m1.txt` records the native results.
- [ ] M2: All applicable execution persistence paths use the accepted protocol, preserving concurrent retry, accounting, permission and claim behavior.
- [ ] M3: Every 0.21/0.22 DSL capability and existing consumer adapter has an evidence-backed disposition, generated conformance passes, and the single first-release contract passes same-build replay qualification.


## Surprises & Discoveries

The native proof uses the actual generated ExecutionLifecycle domain/validated
stream through the released guarded runner. These two modules are now explicit
core exports for typed command integration; all remaining generated modules stay
in the ordinary generated build inventory. A finite graph assertion proves every
current live edge emits events. The fallback classifier rejects an unexpected
future silent edge instead of declaring it an accepted no-op.

Outcome preconditions lock root, execution and operation rows in that order and
return ordinary identity/revision/kind/permission refusals before inline writes.
The inline writer rereads transaction-local state under retained locks. It still
settles accounting and invokes the final hook after protected writes; native
fault injection observes those tentative facts before returning its original
refusal and proves complete rollback.


The released guarded runner calls its precondition after tentative append and catalog admission but before inline delivery. It has no post-inline typed-refusal callback. The existing `recordOutcomeAndAdvanceWith` hook runs after payload/cursor writes and accounting, so its rollback path is not superseded by this API.


## Decision Log


2026-10-28 review revision: Narrow typed-refusal adoption to checks before inline delivery. Preserve the existing post-write hook and exception rollback for late/owner failures because the released guarded runner has no post-inline refusal callback; test both paths before expanding adoption.

2026-10-28: Adopt the released typed catalog precondition for expected execution admission refusals that can be decided before inline delivery. Keep rich payload writes in the live inline projection and preserve their atomicity. Do not call an asynchronous view command authority or make encode-only provider payloads replayable.

2026-10-30: Supersede the old compatibility constraint. Adopt checked enum/construction/list support wherever it improves actual domain modeling; remove obsolete queue readers and patch branches under ADR-27. Current source producers and consumers move together. No unused declaration counts as adoption.


## Outcomes & Retrospective


To be filled during implementation.


## Context and Orientation

Shikigami has seven packages: core domain/runtime, API contracts, HTTP server, workers, client/CLI, migrations and the lightweight agent runner. The last is the deliberate ADR-3 exception to the six-package pattern. Work from this repository root and locate dependencies through Mori before using their APIs. Never traverse `/nix/store`. Current objective work under MasterPlan 17 edits configuration, generated catalogs, migrations and core tests; preserve and reconcile that work rather than reverting it. The workspace currently has ten members, including ExecutionDriver, WorkerSession, ContinuingWorker and Objective. Recount from `domain/shikigami.keiro-workspace` at implementation; neither six members nor two aggregates is a valid fixed inventory.

On 2026-10-30 the user confirmed Shikigami is unused. [ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) and [ADR-37](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md) apply: establish one current first-release contract, remove obsolete compatibility branches/readers, and allow deliberate schema/wire changes. Do not require old binaries, old populated databases or cross-build replay as acceptance. This does not authorize deleting a developer database or weakening external authorization, accounting, protected payloads or same-build replay. Record exact breaking DSL findings and establish the accepted baseline without suppressing the differ. `docs/workflow-versioning.md` still governs durable bodies after that baseline.

The frozen guide inventory is `docs/architecture/keiro-0.22-coverage.json`: canonical resource, producer revision, relative source path, SHA-256, child owner, pending disposition and evidence. The readable audit is `docs/architecture/keiro-0.22-pattern-audit.md`. Pending rows are planned work, not compliance claims. Every applicable clause requires an implemented behavior or justified existing implementation and current evidence. Strict unprefixed fields, explicit deriving strategies and isolated generic-lens orphan imports apply to all touched Haskell and examples.


Hard prerequisite: `docs/plans/92-resolve-the-released-keiro-0-22-cohort-and-rehearse-the-composed-migration.md` must be Complete. It supplies the real released 0.22 interfaces, generated naming changes and passing migration fixtures. This child owns semantic command/DSL adoption after that baseline. `docs/plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md` separately owns the evolving execution driver; reconcile its working-tree changes before editing shared persistence.

`domain/shikigami-execution.keiro` defines the generated ExecutionLifecycle aggregate: identity, immutable snapshot digest, monotonic revision and Active/Parked/Unresolved/terminal states. `shikigami-core/src/Shikigami/Execution/Store.hs` owns protected SQL rows and `persist`. At planning time `persist` calls `runCommandWithCatalogProjections`, captures the whole command transaction as a live projection, and uses `ExecutionAbort` exceptions to return application refusals. `PersistenceFailure` deliberately separates stream rejection from a captured check failure. Its duplicate lookup must never turn a resource refusal into AlreadyAccepted. `recordOutcomeAndAdvanceWith` commits accepted outcome, cursor, normalized call facts and resource settlement together; newer claim paths add fenced attempt and wake behavior. Preserve all of it.

`shikigami-core/src/Shikigami/Execution/Catalog.hs` captures only the execution writer in the shared generated catalog. `shikigami-core/src/Shikigami/RunEvidence/Catalog.hs` does the converse for evidence. Both must preserve the other's projection sets. `domain/shikigami-run-evidence.keiro`, `Shikigami.RunEvidence.BehaviorHoles`, `Shikigami.RunEvidence.Conformance`, and the service-level generated conformance own aggregate evidence. Passing examples of identity/register equality are not automatically exhaustive guard proofs.

A catalog precondition is a bounded application SQL check inside the same transaction and catalog fence as a tentative lifecycle append. Keiro 0.22 exports `runDomainCommandWithCatalogProjectionsGuarded`, `GuardedCatalogOutcome` with `CatalogCommandOutcome` and `PreconditionRefused`, and `CatalogPreconditionContext`. Its callback returns `Transaction (Either refusal ())`; Left rolls back the whole append. The callback is skipped for a silent domain decision. A rolled-back refusal has no accepted receipt or committed position. Discover and read the released implementation using Mori; source entry is `mori://shinzui/keiro`, project-relative `keiro/src/Keiro/Projection.hs` (artifact-level URI pending), and guide `mori://shinzui/keiro/okf/guides/concepts/DOC-29`.

Relevant decisions are [ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md) for honest generated consumers, [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) for patches, and [ADR 0053](../adr/0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md) for protected payload and lifecycle atomicity. Follow `docs/workflow-versioning.md` for any Agent/Flow body edit. `mori://shinzui/keiro-runtime-patterns/docs/keiro-projection-catalogs`, `mori://shinzui/keiro-runtime-patterns/docs/keiro-command-cycle-and-errors` and `mori://shinzui/keiro-runtime-patterns/docs/keiro-mapped-consumer-surfaces` define the upstream contracts. The initial audit is `docs/architecture/keiro-0.22-pattern-audit.md`.


## Plan of Work


### M1 — Prove one producer/consumer transaction

Begin with `recordOutcomeAndAdvanceWith` and its PostgreSQL transcript/selection tests, before converting all persistence operations. Adapt the generated validated stream to `DomainCommandHandler` with a total classifier. ExecutionLifecycle currently emits an event on every accepted edge; do not add fake silent edges, public reject payloads or a blanket normal no-op to evade rejection semantics. If a classifier is needed for an unreachable silent case, return a bounded explicit execution refusal; prove the current aggregate contains no silent live edge. Unmatched edges remain outer `CommandRejected`.

Split expected relational admission checks from rich inline writes. The precondition performs minimal indexed identity/revision/permission/root/claim checks under the admitted catalog bindings and returns `Either ExecutionError ()`. Keep payload writes, outcome storage, cursor movement and accounting settlement inside the accepted command transaction's live projection. Keep the existing `recordOutcomeAndAdvanceWith` final transaction hook in its post-write position. The released guarded runner cannot translate a failure from inline delivery into `PreconditionRefused`: its callback has already returned by then. Retain `ExecutionAbort` and the surrounding `catchExecutionWith CheckFailed` path for this hook, accounting/settlement owner refusals and other write-time integrity failures. Let the exception escape the transaction so all tentative writes roll back before mapping it to the existing application error. Do not catch it inside the inline projection and return success.

Move only checks whose answer can be established before inline delivery into the typed precondition. Acquire their application row locks in the existing order and retain them through inline writes; re-read under those locks where necessary. Do not move a hook merely because its type returns `Either`: it may observe tentative state or perform coupled writes. Preserve post-write hooks and write-time refusal paths unless a separate proof establishes equivalent semantics. Record each retained call site, error identity and rollback test in audit row K22-4. Do not move accounting to a second transaction. Avoid mutable cross-callback cells; use transaction-local rereads under retained application row locks when values must be checked again. Keep one documented lock order across all participating application writers.

The upstream callback may be retried by Hasql. It must contain no provider/network effect, recursive append, extra stream/group lock, independent transaction/savepoint/isolation control, sequence, session lock or effect that survives rollback. Catalog serving bindings are valid only during this invocation; retaining their value retains no lock. Preserve typed infrastructure errors separately from business refusals. Catch asynchronous cancellation correctly; do not replace it with a successful refusal.

Use the released same-database fixture to run the accepted outcome and a typed refusal on separate connections, then fence the execution rebuild group. Check the generated lifecycle stream and every application participant before and after. Also inject a refusal from the existing final hook after tentative payload, cursor and accounting writes, and assert the original application error and complete rollback. M1 succeeds only when accepted work commits once and typed-refused, late-refused and fenced operations change nothing, with no fabricated receipt or global position. The late case must exercise the retained exception path, not a precondition that refuses before writes.

### M2 — Integrate the accepted execution boundary

Apply the proven split to admission, accepted operations, permissions, terminal transitions, executor claims, uncertain results and reconciliation wherever they use catalog commands. Preserve stable fingerprints, operation positions, owner/generation fences, late-receipt rules, original accounting and protected replay permits. Admission checks moved before inline delivery must leave through `PreconditionRefused` and retain exact application error identities. Late-hook and write-time owner refusals remain exception-triggered transaction rollback mapped to `CheckFailed`; do not fabricate a guarded-runner outcome for them. Preserve stream rejection, retry exhaustion, catalog refusal, corrupt history and unexpected infrastructure failure as distinguishable operational outcomes.

Remove exception use only at the admission checks actually migrated to the typed callback. Retain the exception type and transaction-boundary handler for late hooks, write-time owner refusals and integrity failures; read-side decode/access errors remain a separate obligation. Document retained sites and their invariants in the audit. Completion means all applicable pre-inline checks are migrated and every retained rollback path is justified and tested, not that `ExecutionAbort` disappears. `Attestation.EvidenceStore` retains its justified rich inline projection; adopt the guarded runner there only if an actual relational precondition exists, not to rewrite an already correct upsert.

Expand race tests to equal retries, conflicting immutable inputs, root cancellation, stale claim generation, permission expiry, injected failure after tentative work and rebuild-fence refusal. Update ADR 0053 with the supported typed refusal protocol and lock/atomicity constraints when accepted.

### M3 — One complete current domain contract

Audit every workspace member and live domain consumer, including newly added WorkerSession, ContinuingWorker, ExecutionDriver and Objective. Replace primitive Text/Int domain choices with checked nominal/structural types where their meaning warrants it. Adopt total mapped initial/write-lift, ordered scalar-list contracts and exact structural enum equality on actual guards. Remove custom equality/transition adapters when the generated implementation owns the same behavior. Preserve refined admission and authorization even when wire spelling changes; a new enum does not automatically prove unrelated identity guards exhaustive.

Use ADR-27's confirmed first-release freedom to replace RunJobs' v1/v2/v3 upcasters and its v4 wrapper with one intentional current codec. Move all current producers/consumers together and remove now-dead branches. Audit Agent and Flow patch branches and consolidate those serving only unreleased histories. Keep genuinely different runtime paths and future evolution mechanisms. Review exact breaking diagnostics, current fixture bytes, finite owner/key laws, construction totality, snapshot/state-codec and declaration-specific fold evidence. Do not globally bump every fold because one enum guard changes. Test same-build crash/replay and corrupt/stale snapshot fallback before deleting superseded logic.

Keep external protocols hand-owned where they are genuinely different: an HTTP sink is not a Kafka publisher; rich protected payloads absent from event history cannot become replayable by declaration. Reassess each retained hole and workaround against released support, including missing optional queue fields: that upstream limitation may justify a current application codec, but never obsolete historical readers. Update `docs/architecture/shikigami-domain-inventory.md` from the actual workspace. Run independent positive/negative command histories and generated behavior witnesses against the application implementation.

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


Run the full core PostgreSQL suite serially because shared ephemeral connection budgets have previously failed under parallel suites. Strengthen existing `shikigami-core/test-postgres/Shikigami/ExecutionTranscriptSpec.hs` and `ExecutionSelectionWorkflowSpec.hs`, using separate connections for real concurrency. An accepted outcome, lifecycle append, call settlement and cursor advance are one fact. A typed precondition refusal, a fenced group, a post-write final-hook refusal and a stale claim each leave every participant unchanged. Assert the typed runner outcome only for the precondition case; assert the preserved application error through `CheckFailed` for the late case after verifying payload, cursor and accounting were tentatively written. A committed response loss followed by the same request converges; a changed request under the same identity refuses. Classifiers do not turn corrupt replay or ambiguity into business rejection. Read-side protection remains intact.

Generated service conformance must pass with all required witnesses, including the updated behavior obligation reports from 0.21 and declaration-specific enum evidence from 0.22. A mapping adoption requires independent wire, fold, snapshot and replay evidence; no application mapper is removed based solely on successful compilation. The audit has a concrete disposition for each new DSL feature and every retained workaround. Review FRIC-9 against the current release; it may justify a current hand-owned field codec, not historical version readers.


## Idempotence and Recovery

Use fresh isolated databases. Keep current accepted fixtures and same-build replay, but do not retain historical readers or add upcasters/patch false branches for nonexistent deployments. Record intentional breaks and establish a new reviewed baseline under ADR-27; keep the differ strict. No destructive rebuild can recover live-only execution/evidence payloads. Preserve concurrent work and transaction-level safety during refactoring.

## Interfaces and Dependencies


The released guarded runner consumes `DomainCommandHandler`, a typed target stream, one validated catalog and the matching projection set. It returns outer `CommandError` or `GuardedCatalogOutcome`; only accepted domain work supplies committed metadata. Application `ExecutionError`, `PersistenceFailure`, operation fingerprints and transaction-level resource/selection hooks remain the public owner boundaries. This child owns their adapter, not a new root ledger or accounting protocol. `docs/plans/94-adopt-current-runtime-lifecycle-patterns-and-bounded-operator-inspection.md` consumes runtime result meanings; `docs/plans/106-expose-bounded-administrative-inspection-and-live-feeds.md` owns catalog/display integration. Both may proceed after plan 92. `docs/plans/95-close-the-runtime-pattern-audit-and-qualify-the-keiro-0-22-rollout.md` requires this entire child Complete.

## Revision Notes

2026-10-30: Retain reviewed pre-inline versus late-write rollback semantics; broaden domain adoption and replace historical compatibility with the user-authorized clean first-release baseline. Inspection is owned by docs/plans/106-expose-bounded-administrative-inspection-and-live-feeds.md.
