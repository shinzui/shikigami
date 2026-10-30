# Keiro 0.22 adoption audit

Updated 2026-10-30. This ledger records partial implementation acceptance. Plans92,93,94 and106 are complete; the Haskell corpus and final qualification remain pending. [MasterPlan 16](../masterplans/16-upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds.md) and its six children own implementation.

## Scope and source denominator

The user confirmed Shikigami is unused. ADR-27 permits a clean current baseline: obsolete queue readers, workflow patch false branches and pre-release schema assumptions may be refactored. Old-build/populated-upgrade compatibility is withdrawn. Same-build replay, authority, accounting, current manifest loading and protected payload constraints remain.

[Source inventory](keiro-0.22-coverage.json) freezes 124 canonical documents: 94 from `mori://shinzui/keiro-runtime-patterns` at 62531b00b415785be61584a3c44b569fdfb35c4e and 30 from `mori://shinzui/haskell-jitsurei` at cce10bd4d22c30b52a5d18b1be8ae16755f5435c. Paths, hashes and owners are explicit; unregistered documents are separately listed for inspection, not silently omitted. Each applicable clause needs implementation and evidence. Accepted rows carry current evidence; shared final-qualification clauses retain explicit pending owners. Native inspection evidence is recorded in `docs/evidence/keiro-0.22/native-inspection-runtime.md`; it does not certify final deployment artifacts.

[Release inventory](keiro-0.22-release-coverage.json) freezes 93 changelog bullets from the released Keiro source and DSL changelog across 0.19–0.22. Source paths are relative to `mori://shinzui/keiro` at b28201f2063fa4f6dcb724cbf474959107e36b74; artifact-level file URIs are pending. Plan 92 reconciles published descriptors and errata, assigns each item to an implementation owner and records any explicit denominator revision. Plan 95 rejects incomplete closure. Registry and remote tag rechecks still show 0.22.0.0 on 2026-10-30.

## Findings and ownership

| Finding | Evidence | Required outcome | Owner |
|---|---|---|---|
| Old dependency cohort and fixture relaxation | cabal.project | Released compatible cohort, no unjustified bounds escapes, immutable source closure | [92](../plans/92-resolve-the-released-keiro-0-22-cohort-and-rehearse-the-composed-migration.md) |
| Vendored PGMQ baseline | migrations/0002 in the composed application inventory | One supported fresh schema owner with PGMQ 0007 and current Kiroku/Kioku prerequisites | [92](../plans/92-resolve-the-released-keiro-0-22-cohort-and-rehearse-the-composed-migration.md) |
| Pre-inline and late-write refusals differ | Execution.Store.persist and recordOutcomeAndAdvanceWith | Native typed guard where applicable; whole-transaction rollback after late failure | [93](../plans/93-adopt-guarded-catalog-commands-and-qualify-current-dsl-consumer-contracts.md) |
| Domain census is stale | workspace now has ten members | All current contracts, witnesses and catalog sources covered, including objectives | [93](../plans/93-adopt-guarded-catalog-commands-and-qualify-current-dsl-consumer-contracts.md) |
| RunJobs carries v1–v3 upcasters under v4 | Shikigami.RunJobs.domainCodec | One intended first-release codec; current producer/consumer admission laws | [93](../plans/93-adopt-guarded-catalog-commands-and-qualify-current-dsl-consumer-contracts.md) |
| Unreleased workflow patch branches | agent-run/conversation specifications | Consolidated baseline, exact breaking diff and same-build recovery | [93](../plans/93-adopt-guarded-catalog-commands-and-qualify-current-dsl-consumer-contracts.md) |
| Direct AppConfig and lifecycle adaptation | Trigger.Consumer | Default-based config, basic metrics, delivery admission, Paused and finalizer failure evidence | [94](../plans/94-adopt-current-runtime-lifecycle-patterns-and-bounded-operator-inspection.md) |
| Growing workflow/wake registry | Workflow.Registry and execution/worker/objective code | Current census, native ownership, cancellation and restart proof | [94](../plans/94-adopt-current-runtime-lifecycle-patterns-and-bounded-operator-inspection.md) |
| Missing administrative visibility | Server.Command.Ops hooks and no selected host | Safe aggregate CLI catalogs, authenticated HTTP, bounded live feeds | [106](../plans/106-expose-bounded-administrative-inspection-and-live-feeds.md) |
| Haskell corpus missing from original scope | original runtime-only inventory | Clause-level review/fixes across all seven packages, API and CLI | [107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md) |
| Separate frozen deployment closure | nix/qualification | Final solve exported and actual role artifacts qualified | [95](../plans/95-close-the-runtime-pattern-audit-and-qualify-the-keiro-0-22-rollout.md) |

## Adoption decisions

Use exact enum equality, mapped initial/write-lift and scalar lists where they simplify real domain contracts; old wire spelling is not a reason to retain an adapter. Preserve honest DSL declarations, total refined admission, declaration-specific fold evidence and current same-build fixtures. Missing optional queue fields can justify a current application codec, never historical upcasters for nonexistent users.

Keep rich live-only projection handlers when source history lacks their protected payloads; do not claim destructive replay can reconstruct them. Typed guarded callbacks occur before inline writes. Preserve late-hook rollback and accounting/permission/claim fences rather than calling every exception obsolete. Read-side inspection uses narrow explicit encoders, not snapshot JSON.

HTTP and live inspection are selected, with dedicated bounded resources and administrative authorization. Shibuya live metrics stay with the process owning AppHandle. No compiled reaction manager means no invented pm descriptor; no namespace-spanning consumer means no broadened subscription merely to use the API. Reinspect resource-aware resume and the ops connection adapter against released exports, retaining them only for a demonstrated capability mismatch.

## Closure contract

Each source row records applicable clauses, owner, concrete code, regression evidence, rationale and final status. Release rows receive the same supported disposition. `pending`, plan links alone, nonexistent evidence or blanket exclusions fail final acceptance. Plan 95 adds mutation-tested inventory validation and the first-deployment runbook. Prior review approvals apply only to their historical scope; this expanded plan has not received a separate review.
