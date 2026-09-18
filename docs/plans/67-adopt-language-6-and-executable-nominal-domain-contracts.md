---
id: 67
slug: adopt-language-6-and-executable-nominal-domain-contracts
title: "Adopt Language 6 and executable nominal domain contracts"
kind: exec-plan
created_at: 2026-09-18T16:22:03Z
master_plan: "docs/masterplans/12-adopt-keiro-0-17-and-applicable-runtime-haskell-and-postgresql-patterns.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-18T16:22:03Z
---

# Adopt Language 6 and executable nominal domain contracts

This ExecPlan is a living document governed by agents/skills/exec-plan/PLANS.md. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Update durable decisions in docs/adr/ when implementation changes them.


## Purpose / Big Picture


Make every Shikigami workspace member explicitly use Language 6 and let generated contracts carry the domain types they actually represent. Invalid identifiers and enum values should be rejected at the correct boundary while existing valid queue messages, journal results, and evidence records remain usable. The generated conformance suite must prove the same contracts used by production.


## Progress


No implementation has started. Populate a timestamped checklist at the first implementation step.


## Surprises & Discoveries


None during implementation yet.


## Decision Log


2026-09-18: Adopt Language 6 despite its Candidate metadata, as required by the current runtime-patterns policy. Keep idiomatic-v2 generation, existing workflow identities and live-only evidence. Nominal types are not permission to force TypeID validation onto externally owned or composite identifiers.


## Outcomes & Retrospective


To be filled during implementation, including the exact language findings, codec evidence and remaining upstream gaps.


## Context and Orientation


Hard prerequisite: docs/plans/66-resolve-and-adopt-the-released-keiro-0-17-dependency-cohort.md supplies the released 0.17 toolchain. domain/shikigami.keiro-workspace composes domain/*.keiro members. justfile currently requires --min-language 5, effectiveLanguageVersion 5 and languageSupport stable. On released 0.17, Language 6 reports candidate and stable=false; keiro-dsl new still emits 5. Replace the support-label requirement with an exact version-6 declaration check, retaining warning, opaque-root and evolution checks.

A nominal type distinguishes values with the same representation, such as AgentName and a free-form Text. Language 6 supports nominal IDs/enums/scalars inside structural mapped values, declared contract IDs and identifier-keyed maps. Current domain/shikigami-run-jobs.keiro uses Text for agentName, triggerKind, idempotencyKey, routeKind and several IDs. shikigami-core/src/Shikigami/RunJobs.hs converts between the generated Queue.RunJobMessage and the real Shikigami.Agent.RunJob.RunJob through an Aeson round trip. Assess which conversions can become checked mapped bindings without changing wire bytes.

Relevant decisions are [ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md), [ADR 0004](../adr/0004-one-options-value-and-a-checked-patch-set.md), [ADR 0010](../adr/0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md), [ADR 0027](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md), and [ADR 0037](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md). Generated contracts must execute; the shared Workflow.Versioning module owns options; rich evidence is encode-only and LiveOnly/Preserve; an earlier unused-state claim does not authorize a new reset.

Normative sources include mori://shinzui/keiro-runtime-patterns/docs/keiro-language-versions, mori://shinzui/keiro-runtime-patterns/docs/keiro-mapped-consumer-surfaces, mori://shinzui/keiro-runtime-patterns/docs/keiro-nominal-bindings, mori://shinzui/keiro-runtime-patterns/docs/keiro-identifier-domains and mori://shinzui/keiro-runtime-patterns/docs/architecture-generated-compilation-contract. Locate remaining architecture, Keiki and projection standards through Mori and summarize applicable requirements in the adoption matrix.


## Plan of Work


### Milestone 1 — Move the language without changing behavior

Capture the implementation baseline commit and current check, coverage, inspect and conformance results. Change every workspace member preamble together to language keiro-dsl 6. Canonicalize using the released pretty command, preserving declaration semantics. In justfile raise the language floor and exact inspected version to 6; verify all sourceForm values remain declared. Permit the truthful candidate metadata rather than forging stable=true. Regenerate through the existing scaffolder invocation and reconcile generated module lists and create-once conformance expectations.

Run diff against the captured revision. A declaration-only move should yield SourceLanguageDeclarationChanged with compatible impact; any other findings require explanation and regression tests. Confirm aggregate fold identities, JSON bytes, queue names and workflow names remain unchanged. Generated banner/comment changes are expected. Acceptance is passing strict check, explicit Language 6 inspection, conformance and repeatable regeneration.

### Milestone 2 — Adopt executable nominal boundaries

Inventory all persisted generated surfaces and actual hand-owned consumers in docs/architecture/shikigami-domain-inventory.md. Begin with RunJobMessage, AgentName, RunKey, TriggerKind, RunRouteKind, workflow IDs, delegation depth/budget, and lineage. For each field state its owner, wire representation, validator and whether it is a TypeID, externally owned ID, composite key, enum or unrestricted payload. Preserve RunKey composite retry identity and Keiro's opaque WorkflowId values rather than inventing TypeID domains. Preserve the conversation generation-zero unbound AgentName seed documented by ADR 0037.

Declare applicable Language 6 structural mappings and nominal leaves; wire generated codecs directly to the real RunJob boundary, replacing redundant string conversions only where supported. Update consumer-owned adapters, create-once bindings and conformance expectations, never generated files. Add positive round-trip and negative admission tests to shikigami-core/test/Shikigami/WireCompatSpec.hs and KeiroSpecificationSpec.hs. Compare encoded fixtures byte-for-byte or by the existing canonical wire contract. If strict admission excludes an existing valid payload, implement an explicit compatibility path or versioned migration before changing it.

Review architecture, Keiki constructor evidence, guard validation, domain command outcomes, projection catalogs, freshness, external read ownership and semantic-local regeneration. Implement applicable gaps in their actual runtime owners. RunEvidence already uses a generated lifecycle and an atomic catalog-aware rich-payload write; preserve both, including non-destructive reconciliation. Keep external Danwa codec and HTTP publication exclusions where the generator still cannot express their semantics. An unused generated declaration is not adoption.

### Milestone 3 — Prove durable and generated compatibility

Run wire, domain, PostgreSQL workflow and evidence suites, plus generated conformance. For any change under Agent/ or Flow/, follow docs/workflow-versioning.md: declare a new patch and real old/new branches for changed journal shapes, keep stable labels and decode types, and preserve restoreSeed/continueAsNew generation behavior. The pre-v1 exception requires fresh evidence of all four conditions immediately before a reset and an explicit accepted diagnostic; it is not the default of this plan. Document fulfilled rows and real exclusions in the adoption matrix, and update ADR 0037 or a new local ADR with the Language 6 policy.


## Concrete Steps


Run from /Users/shinzui/Keikaku/bokuno/shikigami, inside nix develop when needed:

```bash
git rev-parse HEAD
mori path mori://shinzui/keiro-runtime-patterns/docs/keiro-language-versions
rg -n '^language keiro-dsl' domain
just keiro-check
just keiro-inspect
cabal run -v0 keiro-dsl -- pretty --help
cabal run -v0 keiro-dsl -- scaffold --help
cabal test keiro-shikigami-conformance shikigami-core-test shikigami-core-domain-test
cabal test shikigami-core-postgres-test
```

Use the exact workspace scaffold command in justfile for initial generation. Record the baseline SHA, then substitute it below:

```bash
just keiro-diff BASELINE_SHA
just keiro-gate BASELINE_SHA
```

The scaffold recipe intentionally fails if regenerated output differs from committed files. Review and commit intended generation first, then rerun to prove no drift; do not weaken that recipe.


## Validation and Acceptance


Every workspace member declares version 6 and the gate checks that exact value while accurately reporting candidate support. Conformance consumes the runtime-owned facade. Invalid enum/ID inputs fail before queue/workflow execution; valid prior fixtures remain readable and re-encode identically. Replaying an existing workflow does not execute an already journaled side effect again. Evidence rollback and LiveOnly/Preserve tests still pass. No new opaque persisted roots, ignored warnings, handwritten generated output or undeclared semantic changes remain. Each architecture/Keiki/DSL/projection pattern row has executable evidence or a documented semantic non-applicability reason.


## Idempotence and Recovery


Scaffolding is repeatable once create-once edits and generated bytes are committed. Preserve a baseline revision and generation diff. Before deployment, source-only changes can be reverted together. After any new patch branch or new wire identity reaches durable state, follow the documented forward-fix/drain process; never roll old code back across true patch journals. Do not edit applied SQL or erase journals to make conformance pass.


## Interfaces and Dependencies


The hard prerequisite is docs/plans/66-resolve-and-adopt-the-released-keiro-0-17-dependency-cohort.md. This plan owns domain declarations, generated output, nominal mapping adapters and create-once conformance. Coordinate runJobCodec :: JobCodec RunJob with docs/plans/68-qualify-keiro-0-17-queue-inbox-and-delivery-semantics.md, which owns Job construction and delivery policy. Coordinate hand-owned record findings with docs/plans/70-apply-haskell-service-api-and-cli-patterns-with-wire-compatibility.md. Retain generated queue identity shikigami_run_jobs, retry policy and Unordered semantics unless a separately evidenced domain requirement changes them. The rich evidence catalog remains the authority for atomic writes and generated queries.
