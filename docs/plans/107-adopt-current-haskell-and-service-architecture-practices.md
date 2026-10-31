---
id: 107
slug: adopt-current-haskell-and-service-architecture-practices
title: "Adopt current Haskell and service architecture practices"
kind: exec-plan
created_at: 2026-10-30T19:39:42Z
intention: "intention_01m61agcfzek98hqzkb0kxcfmg"
master_plan: "docs/masterplans/16-upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-30T19:39:42Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-30T23:09:23Z
      mode: "implement"
      note: "Begin clause-level Haskell, architecture, configuration and public API/CLI adoption after accepted native inspection"
---

# Adopt current Haskell and service architecture practices

## Purpose / Big Picture

Review and fix every applicable Haskell and service-architecture guideline across the seven packages, with behavioral evidence for public API and CLI contracts.

## Progress

- [ ] M1: Core/package/record/error/resource conventions have an explicit complete applicability review and fixes.
- [x] M2: Public HTTP, CLI, configuration and telemetry clauses implemented with explicit optional-interface decisions, 28 source rows and real process/live HTTP evidence. Final packaged/Linux qualification remains plan95.

## Surprises & Discoveries

The native Relay query formatter owns a public JSON error protocol. Rewriting its response through private WAI constructors concealed that contract and was removed. Static configuration discovery previously read sources before selecting its static diagnostic; a FIFO exposes the resulting block. Both shared and interactive loaders now select static diagnostics before IO. The domain identity review found that ObjectiveId is application-owned and cannot be accepted as an arbitrary-text technical identity. The correction uses a generated checked TypeID-v7 domain while the atomic creator-scoped receipt remains the deduplication authority (ADR-73). Objective counters and command arguments now retain checked nominal StateRevision scopes, with numeric JSON/byte compatibility and four real compiler boundary cases (ADR-74). The ownership extension now retains worker-session revisions, objective/assignment/criteria instruction revisions and worker-owner epochs through checkpoint/ownership providers, workspace fences and private RPC. Mailbox sequences and event cursors now retain their separate scopes, with an explicit -1 assignment-page position and atomic refusal at the existing event capacity. The domain driver covers all four aggregates with 143 assertions. Concept placement now has a closed checked module budget and explicit ADR-75 service extensions. Moving the execution/session binding symbols changes two conservative fold fingerprints; the native affected replay report is retained despite unchanged conversion bodies and identity bytes. Execution transcript/expected-command revisions and PreparedTool now retain execution, while state cursors, operation positions and technical operation derivation retain execution-operation. Three complete codec/identity controls and fourteen compiler clients guard that boundary. Resource vectors and finite/active ceilings now retain private checked ResourceAmount values, with preflight vector arithmetic and explicit unknown billing for out-of-range provider reports (ADR-76). Attempt counts/operational ceilings now retain nominal scopes; profile refinement fails as data, and four root/assignment zero-count cases refuse before coupled settlement (ADR-77). A compiled declaration worklist now enumerates 310 hand-owned modules/882 declarations plus 14 role entrypoints, with source/interface hashes and explicit current-component selection. It is not a semantic compliance claim. Seven policy ceilings and three durable execution progress counts now have private checked types, with exact numeric wire controls and atomic full-receipt refusal (ADR-78). Thirty-seven compiler clients pass. Worker admission limits and retained instruction text now refine at private constructors while keeping exact valid wire bytes (ADR-79). Thirteen opaque Generic instances also bypassed private constructors or credential disclosure boundaries; actual probes preceded the ADR-80 fix and fourteen new compiler controls. The complete scalar/newtype review remains open.

## Decision Log

2026-10-30: Apply the user's first-release policy and exhaustive current-guide adoption. Replace old-history qualification with fresh provisioning and same-build recovery. Preserve real transaction, authority and privacy invariants.

## Outcomes & Retrospective

Public API/CLI changes are implemented and the interim acceptance is in [haskell-service-results.txt](../evidence/keiro-0.22/haskell-service-results.txt): 94 server, 37 agent, 9 client and 30 API tests; live Hurl lifecycle; 70 real-process offline CLI checks. The language checker and thirteen mutation/lexical tests pass. ObjectiveId now has its checked TypeID-v7 domain; objective prose and worker/workspace ownership scopes are checked types. The latest 559 pure, 383 serial PostgreSQL, 260 worker and 95 server tests pass, and the strict breaking diff/fold change are retained. The earlier domain-member directory move is strict-diff neutral; the later concept-binding move retains 44 native warnings and affected replay for two aggregates. The subsequent instance-only opacity fix rebuilt all enabled components and passed fourteen opaque plus 37 nominal compiler clients, 559 pure and 95 server tests. The full PostgreSQL/worker counts belong to the preceding worker-input candidate. Forty-two of the 46 assigned source rows now have explicit implemented dispositions. One local review remains (the complete scalar/identity census); three source rows retain only final-profile clauses owned by plan95. M1 and final source dispositions remain open; this is not completion or packaged Linux qualification.

## Context and Orientation

Shikigami has seven packages: core domain/runtime, API contracts, HTTP server, workers, client/CLI, migrations and the lightweight agent runner. The last is the deliberate ADR-3 exception to the six-package pattern. Work from this repository root and locate dependencies through Mori before using their APIs. Never traverse `/nix/store`. Current objective work under MasterPlan 17 edits configuration, generated catalogs, migrations and core tests; preserve and reconcile that work rather than reverting it. The workspace currently has ten members, including ExecutionDriver, WorkerSession, ContinuingWorker and Objective. Recount from `domain/shikigami.keiro-workspace` at implementation; neither six members nor two aggregates is a valid fixed inventory.

On 2026-10-30 the user confirmed Shikigami is unused. [ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) and [ADR-37](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md) apply: establish one current first-release contract, remove obsolete compatibility branches/readers, and allow deliberate schema/wire changes. Do not require old binaries, old populated databases or cross-build replay as acceptance. This does not authorize deleting a developer database or weakening external authorization, accounting, protected payloads or same-build replay. Record exact breaking DSL findings and establish the accepted baseline without suppressing the differ. `docs/workflow-versioning.md` still governs durable bodies after that baseline.

The frozen guide inventory is `docs/architecture/keiro-0.22-coverage.json`: canonical resource, producer revision, relative source path, SHA-256, child owner, pending disposition and evidence. The readable audit is `docs/architecture/keiro-0.22-pattern-audit.md`. Pending rows are planned work, not compliance claims. Every applicable clause requires an implemented behavior or justified existing implementation and current evidence. Strict unprefixed fields, explicit deriving strategies and isolated generic-lens orphan imports apply to all touched Haskell and examples.

The source inventory includes all 30 canonical Haskell Jitsurei documents, not merely records. `shikigami-core/src/Shikigami/Prelude.hs` already explicitly avoids exporting Data.Generics.Labels; preserve that boundary. `shikigami-core/test/Shikigami/PackageArchitectureSpec.hs` guards package arrows. `Shikigami.App.Config` and `.Load`, role configuration, API/client packages, `Shikigami.Server.Boot`, telemetry and command modules are the entry points. [ADR-3](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md) justifies the seventh package; [ADR-32](../adr/0032-the-migration-cli-keeps-a-dedicated-configuration-boundary.md) keeps migration config separate; [ADR-47](../adr/0047-public-api-authentication-is-a-verifier-at-the-vertical-mount.md) preserves authentication at vertical mounts.

## Plan of Work

M1 reads every assigned frozen guide and records its applicable clauses, implementation site, deviation/fix and test/evidence. Cover GHC2024 and baseline extensions in every component, strict unprefixed records, explicit deriving, postpositive qualified imports, custom Prelude package imports and orphan propagation, multiline SQL, domain newtypes/identity admission, concept verticals, cross-cutting exceptions and generated compilation/test layout. Correct actual violations instead of exempting whole directories. Generated code stays generator-owned and outside formatter rewriting; fix generator selection or consumer declarations rather than hand-edit output. Coordinate domain edits with plan 93 and runtime exceptions with plan 94. Preserve cancellation through typed error mapping and bracket resource lifetimes; do not mechanically replace transaction rollback exceptions with business Either values.

M2 reviews all API and CLI clauses against actual consumers: typed Servant routes, pagination, RFC9457 errors, generated OpenAPI, request logging/redaction, OpenTelemetry, health/readiness, Hurl tests, shell completion/help/options, stdin, aliases, version/Git identity and agent-assistance discovery. Applicable improvements must be implemented; no matching consumer may be excluded solely to save refactoring. A purely optional UI convenience needs a concrete product decision, not a false compliance claim. Preserve public authority boundaries while changing unreleased internal types. Settei source precedence, validation and secrets remain consistent across roles and no ambient fallback silently overrides configuration.

Add focused architecture/style checks under `tools/` where a stable invariant is mechanically enforceable, with mutation/self-tests that reject real regressions. Structural scans are not proof of JSON, API or cancellation behavior. Run actual CLI stdin/help/version and authenticated HTTP/error cases with source-owned fixtures. Update guide rows and narrow ADR exceptions; do not copy a source's example API bounds without verifying its current released dependency through Mori and registries.

## Concrete Steps

Run from the repository root in the declared development shell. Use disposable task-owned databases and the existing source-owned fixtures. These are implementation commands, not evidence of tests already run:

```bash
mori registry docs shinzui/haskell-jitsurei
nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-api-test shikigami-client-test shikigami-server-test shikigami-agent-test shikigami-workers-test
nix develop --no-write-lock-file -c just hurl
git diff --check
```

Record actual cases and concise output under `docs/evidence/keiro-0.22/`. Database tests that skip are not accepted. Before claiming Linux is unavailable, inspect `container --help`, `container list --all` and `tests/workspace/build-apple.sh`; use native ARM64 Apple containers, retaining the documented remote-builder fallback only when needed. Do not claim runtime containment from compilation alone.

## Validation and Acceptance

Every Haskell/architecture source is reviewed clause-by-clause with a supported final disposition, and changed behavior has focused regression evidence. All seven package boundaries remain intentional; record-field/deriving scans cover touched source and prose. Existing Prelude compliance is verified rather than rewritten. CLI and HTTP scenarios pass against actual fixtures; record exact setup and test names.

## Idempotence and Recovery

Repeat generation against an isolated coherent candidate so concurrent uncommitted work cannot masquerade as generated drift. Preserve create-once holes. Recreate only task-owned disposable fixtures after failure; never clear shared journals, leases or bindings to obtain a passing test. Record the source/dirty diff and current input artifacts for reproducibility, without requiring a successful old build before refactoring. A released-schema rollback is not promised. Future post-release evolution resumes the ordinary versioning rules. Record friction through `agents/skills/exec-plan/FRICTION.md`, promote durable decisions through the local plain-Markdown ADR convention, and scan touched code and prose for stale prefixed fields.

## Interfaces and Dependencies

Requires plan 92 Complete for a compilable target. Plans 93/94/106 own semantic domain/runtime/inspection changes; this child owns residual language, package, public API/CLI and configuration fixes. Coordinate shared App.Config and Cabal edits sequentially. Plan 95 requires completion and all final source dispositions.

## Revision Notes

2026-10-30: Expanded MasterPlan 16 under the user's unused-service confirmation; replaced compatibility-driven scope with current-contract adoption and explicit behavioral evidence. Previous provenance entries and review verdicts remain historical and do not certify this revision.
