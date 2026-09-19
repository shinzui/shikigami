---
id: 71
slug: qualify-the-keiro-0-17-rollout-and-close-pattern-coverage
title: "Qualify the Keiro 0.17 rollout and close pattern coverage"
kind: exec-plan
created_at: 2026-09-18T16:22:03Z
intention: intention_01m2trbg5ze1dt6dfz50mxg4bq
master_plan: "docs/masterplans/12-adopt-keiro-0-17-and-applicable-runtime-haskell-and-postgresql-patterns.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-18T16:22:03Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-19T00:14:28Z
      mode: "implement"
      note: "Started aggregate qualification and reconciled pattern coverage"
---

# Qualify the Keiro 0.17 rollout and close pattern coverage

This ExecPlan is a living document governed by agents/skills/exec-plan/PLANS.md. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Update durable decisions in docs/adr/ when implementation changes them.


## Purpose / Big Picture


Demonstrate that the complete Keiro 0.17 adoption works as one Shikigami system and can be rolled out without losing queued work, journal progress or rich evidence. Close the coverage record for every applicable runtime, Haskell and PostgreSQL pattern so completion means verified behavior rather than a successful build alone.


## Progress


- [x] (2026-09-19T00:14:28Z) Reconciled 116 normative corpus rows with no open applicability or owner disposition.
- [x] (2026-09-19T00:14:28Z) Distilled Language 6, queue, guarded-timer and schema-isolation decisions into ADRs 0037 and 0038.
- [x] (2026-09-19T00:14:28Z) Added executable upgrade, hostile-schema, timer recovery and selected PGMQ operator evidence.
- [ ] Run the aggregate build, test, generation, evolution, HTTP and Nix gates from the implementation revision.
- [ ] Repeat the solve and aggregate gates without `cabal.project.local` after Kioku 0.7 is visible in the public Hackage index.


## Surprises & Discoveries


2026-09-18: Corpus reconciliation closed 116 rows: 81 applicable, 18
contextual, 16 not applicable, and one superseded. None remains open.

2026-09-18: The implementation can be exercised against Kioku's exact clean
0.7 release commit, but the public secure Hackage index has not yet advanced to
the publisher-reported upload. This prevents the required clean-release proof,
not the remaining local qualification work.


## Decision Log


2026-09-18: Final qualification is a hard integration gate. A compatible source experiment, fresh-database-only test, skipped PostgreSQL suite or unresolved applicable pattern row cannot count as completion. Deployment rehearsal is local and isolated; publishing or operating a real environment is a separate action.


## Outcomes & Retrospective


Integration qualification is in progress. Child implementation evidence, the
rollout procedure, ADR amendments, and the closed corpus ledger are present.
`docs/evidence/keiro-0.17/qualification.md` will record the final command results
after the public Hackage solve succeeds.


## Context and Orientation


Hard prerequisites are docs/plans/67-adopt-language-6-and-executable-nominal-domain-contracts.md, docs/plans/68-qualify-keiro-0-17-queue-inbox-and-delivery-semantics.md, docs/plans/69-adopt-guarded-timer-recovery-and-schema-isolated-migrations.md and docs/plans/70-apply-haskell-service-api-and-cli-patterns-with-wire-compatibility.md. They transitively require the released cohort in docs/plans/66-resolve-and-adopt-the-released-keiro-0-17-dependency-cohort.md. Each prerequisite must be Complete in the parent registry before integration acceptance.

The system has seven packages: core owns agent/workflow/domain behavior, API owns route types, client derives clients, migrations owns schema composition, server owns HTTP/operator commands, workers own continuous loops, and agent owns one-off tools. Keiro-generated conformance is an additional local package under shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/. PostgreSQL suites use Shikigami.Migrations.TestSupport and an ephemeral server, not a shared developer database.

docs/architecture/keiro-0.17-pattern-adoption.md is the per-pattern ledger. docs/dependency-cohort.md records actual selected releases. docs/operations/keiro-0.17-rollout.md records stop/migrate/start and rollback rules. docs/architecture/shikigami-domain-inventory.md records executed generated surfaces and justified semantic exclusions. Those artifacts must agree.

[ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md) demands executable authority. [ADR 0009](../adr/0009-kafka-offsets-advance-only-after-durable-dispositions.md) requires durable disposition before acknowledgement. [ADR 0010](../adr/0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md) protects rich evidence. [ADR 0037](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md) records generated adoption, and [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md) records startup/maintenance boundaries. Read their implementation amendments; do not restore superseded prose. docs/workflow-versioning.md controls replay safety and the conditional pre-v1 exception.


## Plan of Work


### Milestone 1 — Prove a reproducible complete build

Use a clean disposable checkout of the implementation revision, without cabal.project.local or dependency source overrides. Resolve the documented released cohort and record compiler, package versions and selected hashes. Build all components, run every application test suite and generated conformance, run the strict Keiro gate against the recorded pre-upgrade baseline, and regenerate both Haskell and OpenAPI artifacts to verify no drift. Because a Nix flake may export checks rather than a default build, inspect flake.nix and use its actual supported targets; never search /nix/store.

Record exact outcomes in docs/evidence/keiro-0.17/qualification.md. Tests requiring PostgreSQL must execute; report an unavailable binary/service as a qualification failure, not a skip. Keep unrelated package changes out of the cohort. Acceptance is reproducible resolution/build plus all applicable existing and newly added checks, with any intentional evolution findings explicitly accounted for rather than suppressed.

### Milestone 2 — Rehearse upgrade, crash and recovery behavior

Use the isolated old-cohort database fixture from the migration plan. Seed an agent run paused after a committed step, a conversation at a generation boundary, an approval child, pending queue delivery, scheduled and parked timers, pending sink intent, and rich run/call evidence. Capture the baseline values and identifiers. Stop old writers, apply the new composed migrations, start only upgraded test hosts, and resume work. Verify the already journaled effect is not repeated, conversation seed/awakeable handling remains valid, approval resolves through its child, pending jobs finish, sink receipts stay authoritative and rich evidence remains queryable.

Exercise a database failure at the inbox/fanout boundary, a crash after database commit before acknowledgement, visibility expiry/redelivery, and timer token expiry. Check both absence of lost work and bounded progress; do not infer success solely from process exit. Reuse focused fault-injection tests rather than relying on timing races with a live broker. Add a broker-backed smoke only if the repository fixture supports it, and distinguish that evidence from the broker-free transaction tests.

Follow docs/operations/keiro-0.17-rollout.md literally in the disposable environment. Verify startup refuses a pending ledger. Confirm every simulated writer is upgraded before guarded resume can occur. Rehearse disabling resume and draining/recovering claims before an old writer is allowed back, without deleting schema or resetting attempts. Record which rollback paths are unavailable after new workflow branches or identities have been stored. Acceptance is preserved data and progress across the tested cutover plus explicit rollback boundaries.

### Milestone 3 — Close pattern coverage and durable decisions

Re-enumerate the three corpora through Mori and their current indexes. Compare with the inspected corpus revisions to detect new/changed guidance during implementation. A newly applicable rule must be routed to its owning child, implemented and requalified; update the master registry if that child must reopen. Do not add an unreviewed blanket claim of adopting all patterns.

Every normative row must end as implemented with a code/test reference, already satisfied with equivalent evidence, or not applicable with a concrete semantic reason. Upstream gaps, undecided applicability and deferred applicable work remain blockers, even if the application runs. Navigation and legacy guidance receive explicit classifications. Review the finite PostgreSQL corpus, which at planning time contains the schema-qualification standard, rather than inventing an unrelated database redesign.

Distill all child decisions and lessons into docs/adr/ using agents/skills/exec-plan/ADR.md. Preserve the existing local format unless a profiled bundle has actually been adopted. Update cohort, domain inventory, workflow-versioning and operations documentation where the final behavior differs. Mark children and the parent complete only after their evidence agrees and the entire acceptance gate passes.


## Concrete Steps


Run from /Users/shinzui/Keikaku/bokuno/shikigami or the root of the clean disposable checkout:

```bash
cabal build all
cabal test all --test-show-details=direct
cabal test keiro-shikigami-conformance --test-show-details=direct
just keiro-check
just keiro-inspect
just keiro-scaffold
cabal run shikigami-openapi
git diff --exit-code docs/api/openapi.json
bash tools/check-migration-schema-isolation.sh
bash tests/hurl/run.sh
```

Substitute the exact captured pre-upgrade revision for BASELINE_SHA:

```bash
just keiro-gate BASELINE_SHA
mori registry docs shinzui/keiro-runtime-patterns
mori registry docs shinzui/haskell-jitsurei
mori registry docs shinzui/postgresql-jitsurei
git status --short
```

Run the relevant repository Nix checks once the source is included in the clean checkout. A generation check must leave no tracked diff. The test output must show executed PostgreSQL/worker/migration suites, not only compiled test executables.


## Validation and Acceptance


The release solve is reproducible and includes all seven 0.17 Keiro packages with compatible released transitive dependencies. Every domain member is explicitly Language 6; its Candidate metadata is documented. Strict check, conformance, coverage and evolution gates remain enabled. Both clean installation and old-to-new migration preserve ledger/data correctness. Crash/replay tests show no lost fanout, no duplicated committed workflow effects, preserved rich evidence and properly fenced timer claims. API/CLI/Hurl checks pass without external credentials. The per-pattern matrix has no unresolved applicable entries, and durable decisions have been recorded as ADRs.


## Idempotence and Recovery


Each rehearsal uses its own ephemeral database and test queues, with owned-process cleanup on failure. Preserve sanitized evidence before discarding test resources. Re-run only failed or affected checks during iteration; after changes are stable run the final aggregate gate once. If a regression appears, reopen the owning child and fix it before resuming qualification. Do not modify production ledgers, clear tokens, remove checks or mark failures not applicable to obtain a green result.


## Interfaces and Dependencies


This plan integrates completed artifacts from docs/plans/67-adopt-language-6-and-executable-nominal-domain-contracts.md, docs/plans/68-qualify-keiro-0-17-queue-inbox-and-delivery-semantics.md, docs/plans/69-adopt-guarded-timer-recovery-and-schema-isolated-migrations.md and docs/plans/70-apply-haskell-service-api-and-cli-patterns-with-wire-compatibility.md. It owns qualification evidence, final matrix reconciliation and ADR distillation, not a competing runtime implementation. Normative corpora are mori://shinzui/keiro-runtime-patterns, mori://shinzui/haskell-jitsurei and mori://shinzui/postgresql-jitsurei. All external durable references use canonical Mori URIs; registry lag does not justify ambiguous cross-repository paths.
