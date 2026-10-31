---
id: 95
slug: close-the-runtime-pattern-audit-and-qualify-the-keiro-0-22-rollout
title: "Close the runtime pattern audit and qualify the Keiro 0.22 rollout"
kind: exec-plan
created_at: 2026-10-28T13:08:17Z
intention: "intention_01m61agcfzek98hqzkb0kxcfmg"
master_plan: "docs/masterplans/16-upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-28T13:08:17Z
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
      note: "Consume verified EP-1 baseline artifacts and qualify both typed and late-write refusals."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-30T19:46:17Z
      mode: "update"
      note: "Expand unused-service adoption to six children, current domain census, HTTP/live inspection, Haskell corpus and first-release qualification."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-31T18:13:09Z
      mode: "implement"
      note: "User limits final qualification to macOS and requests bounded completion"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T13:29:30Z
      verdict: "changes-requested"
      note: "Make the captured pre-upgrade source and solve an explicit EP-1 handoff rather than capture dirty contents after upgrades."
---

# Close the runtime pattern audit and qualify the Keiro 0.22 rollout

## Purpose / Big Picture

Qualify one first-release candidate with fresh provisioning, real same-build recovery, isolated inspection and a reproducible deployment closure.

## Progress

- [x] M1: New-build histories, queues, workflow recovery and refusal atomicity pass integrated tests.
- [x] M2: The successful macOS solve is exported; built roles, CLI and live server/worker use copied assets outside the checkout. No cold Nix/Linux build is claimed.
- [x] M3: All 124 source and 93 release rows have supported scoped dispositions; the single domain follow-up is explicit, the mutation-tested validator passes and the first-deployment runbook is published in the repository.

## Surprises & Discoveries

The October 28 scope assumed a deployed population and an older domain census. The user and current tree invalidate those assumptions; no implementation acceptance is claimed.

## Decision Log

2026-10-31: The user explicitly accepts macOS-only verification and requests completion after twelve hours. Stop Linux/container qualification and new open-ended refactoring; freeze the current candidate and batch final checks. ADR-106 moves the residual exhaustive domain audit to standalone plan108; only its named clause may be deferred by the final gate.

2026-10-30: Apply the user's first-release policy and exhaustive current-guide adoption. Replace old-history qualification with fresh provisioning and same-build recovery. Preserve real transaction, authority and privacy invariants.

## Outcomes & Retrospective

Complete for the requested macOS profile. The full all-enabled build and current
593 pure/405 PostgreSQL/274 worker/95 server checks pass with 31 API, nine client,
37 agent, nine migration-composition and eleven migration-smoke cases. Native/
domain/six diagrams and 272 compiler clients pass. Eighty-four CLI checks and
three live HTTP profiles (31 Hurl requests plus actual client/worker scenarios)
pass from outside the checkout with copied schema/agent assets. The source closure
exports 383 packages/six immutable repositories, and packaging exceptions match
the accepted Cabal project. Final source/evidence validation and its mutation
checks pass. See [final evidence](../evidence/keiro-0.22/macos-final-qualification.json)
and [rollout](../operations/keiro-0.22-rollout.md).

Linux containment, cold Nix rebuilding, real Kafka and live vendor qualification
are outside this profile. The complete declaration worklist is not a semantic
compliance claim; plan108 owns that explicit follow-up. No external deployment
was performed. Repeated per-scalar full-suite runs were excessive; future work
uses focused tests and one full milestone pass, as ADR-106 records.

## Context and Orientation

Shikigami has seven packages: core domain/runtime, API contracts, HTTP server, workers, client/CLI, migrations and the lightweight agent runner. The last is the deliberate ADR-3 exception to the six-package pattern. Work from this repository root and locate dependencies through Mori before using their APIs. Never traverse `/nix/store`. Current objective work under MasterPlan 17 edits configuration, generated catalogs, migrations and core tests; preserve and reconcile that work rather than reverting it. The workspace currently has ten members, including ExecutionDriver, WorkerSession, ContinuingWorker and Objective. Recount from `domain/shikigami.keiro-workspace` at implementation; neither six members nor two aggregates is a valid fixed inventory.

On 2026-10-30 the user confirmed Shikigami is unused. [ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) and [ADR-37](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md) apply: establish one current first-release contract, remove obsolete compatibility branches/readers, and allow deliberate schema/wire changes. Do not require old binaries, old populated databases or cross-build replay as acceptance. This does not authorize deleting a developer database or weakening external authorization, accounting, protected payloads or same-build replay. Record exact breaking DSL findings and establish the accepted baseline without suppressing the differ. `docs/workflow-versioning.md` still governs durable bodies after that baseline.

The frozen guide inventory is `docs/architecture/keiro-0.22-coverage.json`: canonical resource, producer revision, relative source path, SHA-256, child owner, pending disposition and evidence. The readable audit is `docs/architecture/keiro-0.22-pattern-audit.md`. Pending rows are planned work, not compliance claims. Every applicable clause requires an implemented behavior or justified existing implementation and current evidence. Strict unprefixed fields, explicit deriving strategies and isolated generic-lens orphan imports apply to all touched Haskell and examples.

`tools/qualification/export-cohort.py`, its README and `nix/qualification/cohort.json`/metadata archive define the immutable deployment closure under ADR-39. `docs/dependency-cohort.md` and `docs/architecture/shikigami-domain-inventory.md` must describe the accepted current tree. Older 0.18 qualification is historical evidence, not the target population. The machine inventories are `docs/architecture/keiro-0.22-coverage.json` and `keiro-0.22-release-coverage.json`; the human audit provides findings and decisions. Preserve ADR-53's lifecycle/payload/accounting atomicity and ADR-54's dispatch fences throughout qualification.

## Plan of Work

M1 uses an isolated coherent final source snapshot and fresh native PostgreSQL. Build representative histories and queues with this same candidate, suspend and restart every registered workflow family, compare independent folds with live state, exercise stale/corrupt snapshot fallback, duplicate/conflicting submissions and loss of committed responses. Assert no repeated provider/tool/accounting action; unknown outcomes remain unresolved and late receipts retain their original authority. Run the reviewed pre-inline typed refusal and post-write rollback cases, checking every participant. Keep protected live-only rows intact during lifecycle audit; do not assert replay can reconstruct absent rich data. Include the real administrative listener/feed tests and a command→event→projection/query plus enqueue→worker roundtrip before broad qualification.

M2 runs all suites and migration isolation, exports the final successful solve and checks source archives, revised descriptors, flags and compiler. Rebuild CLI/server/worker/migration roles and qualify outside-checkout assets/startup. No sibling checkout may supply runtime code silently. Preserve explicitly documented immutable non-registry artifacts and report them as such. The user explicitly limited acceptance to macOS on 2026-10-31. Do not run Apple-container, remote-builder or other Linux qualification for this initiative. Distinguish macOS compilation/startup/recovery from Linux containment and live-provider claims. Freeze source/dirty diff, binary hashes, tool/cohort identity, corpus revisions and exact executed profile.

M3 implements an inventory validator under `tools/` and a just recipe selecting the current inventories. It rejects missing/duplicate/source-changed rows, pending findings, unowned clauses, unsupported exclusions and nonexistent evidence. Test those rejections. Enumerate every release item across 0.19, 0.19.0.1, 0.20, 0.21 and 0.22, including errata and dependency obligations; if release metadata adds an item, refresh the frozen denominator explicitly. Check source docs without canonical metadata rather than silently dropping normative content: indexes/logs are navigation/history, but a normative unregistered document must be added with project URI and relative path pending artifact URI. Final statuses require actual code and executed evidence, not links to plans.

Write `docs/operations/keiro-0.22-rollout.md` as a first-deployment procedure: provision disposable/fresh schema, verify, configure roles/admin listener, start, exercise useful work, stop, restart and recover on the same build. Explain that old 0.18 binaries are not a fallback onto the new schema. No populated upgrade, historical reader or successful old build is a gate. Update current dependency/domain records and distill ADRs. Close recurring friction and the master registry only after all applicable behaviors are accepted.

## Concrete Steps

Run from the repository root in the declared development shell. Use disposable task-owned databases and the existing source-owned fixtures. These are implementation commands, not evidence of tests already run:

```bash
nix develop --no-write-lock-file -c cabal build all
nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-core-domain-test shikigami-core-diagrams-test shikigami-agent-test shikigami-api-test shikigami-client-test shikigami-server-test shikigami-workers-test
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test --test-options=-j1
nix develop --no-write-lock-file -c cabal test shikigami-migrations-test shikigami-migrations-smoke --test-options=-j1
nix develop --no-write-lock-file -c cabal test keiro-shikigami-conformance
bash tools/check-migration-schema-isolation.sh
python3 -m unittest discover -s tools/qualification -p 'test_*.py' -v
python3 tools/qualification/keiro_022_audit.py
git diff --check
```

Record actual cases and concise output under `docs/evidence/keiro-0.22/`. Database tests that skip are not accepted. macOS is the accepted platform by the user’s 2026-10-31 instruction. Linux qualification is excluded from this completion pass; retain historical Linux evidence without rerunning it or claiming current qualification.

## Validation and Acceptance

All source/release rows have supported final dispositions within ADR-106's scope, including its one explicitly deferred domain clause; new-build recovery is proven, all package tests pass without skipped required database coverage, and packaged roles match the exported solve. The deliberate reset diff is retained; strict evolution gates pass against its accepted baseline afterwards. No external deployment/provider claim exceeds the executed profile. A failed integration reopens its owning child and invalidates only evidence affected by the fix.

## Idempotence and Recovery

Repeat generation against an isolated coherent candidate so concurrent uncommitted work cannot masquerade as generated drift. Preserve create-once holes. Recreate only task-owned disposable fixtures after failure; never clear shared journals, leases or bindings to obtain a passing test. Record the source/dirty diff and current input artifacts for reproducibility, without requiring a successful old build before refactoring. A released-schema rollback is not promised. Future post-release evolution resumes the ordinary versioning rules. Record friction through `agents/skills/exec-plan/FRICTION.md`, promote durable decisions through the local plain-Markdown ADR convention, and scan touched code and prose for stale prefixed fields.

## Interfaces and Dependencies

Requires plans 92, 93, 94, 106 and 107 all Complete. Own final inventories/checker, artifact export, evidence and first-deployment runbook; consume the other children’s interfaces rather than defining new domain/runtime semantics.

## Revision Notes

2026-10-30: Expanded MasterPlan 16 under the user's unused-service confirmation; replaced compatibility-driven scope with current-contract adoption and explicit behavioral evidence. Previous provenance entries and review verdicts remain historical and do not certify this revision.
