---
id: 86
slug: qualify-integrated-adaptive-autonomous-delivery
title: "Qualify integrated adaptive autonomous delivery"
kind: exec-plan
created_at: 2026-10-10T23:32:16Z
master_plan: "docs/masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md"
intention: "intention_01m4m2pjz6es9v9aqq5jq9c4ee"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-10T23:32:16Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:19:09Z
      verdict: "approved"
      note: "Workers.Config emptyCapabilityRuntime, tools/qualification and readiness evidence paths verified; external gates explicit"
---

# Qualify integrated adaptive autonomous delivery

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Prove [UC-1](../use-cases/adaptive-autonomous-delivery.md) finite delivery with a real adaptive coordinator, recoverable workers and exact combined repository artifacts. This closes integrated acceptance for [IR-16](../improvement-requests/support-adaptive-durable-orchestration.md) and supplies shared evidence for IR-14, IR-15 and IR-17. Hard dependencies are `docs/plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md`, a delivered IR-11 governed workspace provider, and a delivered IR-13 checkpoint provider. Neither external provider has a selected implementation plan at this planning baseline. Do not mark the full use case delivered using substitutes. Recurrence remains independently qualified in plan 87.


## Progress


Implementation has not started. Seed unchecked milestone entries when implementation begins.


## Surprises & Discoveries


None recorded during implementation.


## Decision Log


2026-10-10: Give integrated qualification its own child so green component tests cannot close UC-1. Require both deterministic fault tests through real durability boundaries and a bounded live coding trial; retain external workspace/checkpoint blockers explicitly.


## Outcomes & Retrospective


To be filled during implementation. Do not claim request completion until every acceptance case below, including stated external integration gates, has evidence.


## Context and Orientation


The use case requires two repository workstreams, an evidence-triggered adaptation, restart recovery and integrated user-journey checks. `shikigami-workers/src/Shikigami/Workers/Config.hs` currently installs `emptyCapabilityRuntime`; writable workspaces are not available merely because the agent declares a tool. `docs/plans/48-add-a-portable-one-off-repository-agent-harness.md` and completed read-only plan 59 do not implement IR-11. Existing `tools/qualification/` and `docs/evidence/local-qualification/readiness.md` separate environment readiness from actual runtime proof; their baseline cannot establish autonomous coding.

[ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) requires admitted provider revisions; [ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md) requires live external authority. [ADR 0040](../adr/0040-response-options-and-foreground-launches-have-separate-authority.md) says a foreground process exit is not durable agent completion. The `IntegratedAcceptance` contract from plan 85 binds exact artifact/evidence identities to the criteria revision; IR-11 owns workspace creation/edit/process/Git/integration and IR-13 owns objective completion.

The repository is a Cabal multi-package Haskell service. `shikigami-core` owns domain behavior and store adapters; `shikigami-workers` owns queue, resume and timer processes; `shikigami-server` owns operator commands. `shikigami-migrations/sql-migrations/manifest` owns append-only SQL ordering. `shikigami-core/test-postgres/Main.hs` registers tests using `Shikigami.Migrations.TestSupport.withShikigamiMigratedSuite`, which supplies isolated disposable PostgreSQL databases. Register new modules and tests in the owning Cabal file and test entry point; generated files under `Generated/` are regenerated, never hand-edited.


## Plan of Work


### Milestone 1: Build a reproducible finite delivery fixture

Create `tests/adaptive-delivery/` with two small temporary Git repositories and a combined user journey. Use a producer that emits a versioned record and a consumer that reads it, with an independently executable contract test. Choose the fixture so each worker's initial local checks can pass while the combined behavior fails until coordinated schema assumptions are reconciled. Provide per-repository instructions and canonical admitted fixture repository identities through the IR-11 catalog; no model-chosen absolute paths. Store starting revisions, expected behavior, authority/resource envelope and test commands in `tests/adaptive-delivery/README.md`.

Add `tools/qualification/adaptive-delivery.py` with `--mode fixture|live`, `--config` and `--artifact-dir`. The driver prepares only isolated fixture workspaces, starts an explicitly finite objective via the supported CLI/internal enqueue adapter, observes durable state, and writes a bounded evidence manifest. Missing provider/checkpoint/authority prerequisites yield a clear blocked result and nonzero exit, not a simulated success. The fixture-mode provider supplies scripted model responses but still traverses real journals, reservations, session messages, authority adapters and workspace tools. Add driver argument/manifest tests without requiring live credentials.

### Milestone 2: Exercise adaptation, integration and fault recovery

Run two admitted workers with different allowed execution aliases. Inject an early schema finding that changes one task boundary or requests a temporary specialist; record friction, proposed benefit and eventual evidence. Accept revision-pinned worker artifacts, combine them through IR-11's separate integration workspace, expose conflicts, and run checks on the exact combined tree. Preserve repository identities, base/worker/integrated revisions or tree digests, command/exit status and user-journey evidence. An obsolete green worker artifact must not satisfy current acceptance.

Inject restart after a worker operation outcome, after a follow-up acceptance, after adaptation commit, after result commit before notification, and during ownership transfer. Redeliver messages/events and verify one accepted assignment/result integration per operation. Hold a mutable operation unknown; successor write and successful completion must remain blocked until reconciliation. Race the final root reservation between local orchestrators, deny a forbidden alias/action/target before dispatch, and change deployment defaults while suspended. Inspect persisted records and actual provider/workspace counters, not model narratives.

### Milestone 3: Run a bounded live coding trial and publish evidence

With explicitly supplied live configuration, run the same finite fixture using at least one actual model-driven coding path, governed writable workspaces and the actual production authorization boundary. Set bounded attempts, duration, cost/token policy where enforceable, and exact local-edit/test scope; no publication or deployment is required. Validate service availability before starting and report absent configuration as blocked. This planning task does not create a deployment or incur live model work.

Write `docs/evidence/adaptive-delivery/` summaries containing tested service/source versions, operation and selection ids, exact integrated artifacts, check outcomes, observed latency/resources/rework and uncertainty. Distinguish fixture mechanics from live behavior and do not generalize fleet-wide improvement from one trial. A failed live run preserves artifacts and exact unresolved scope and is not a passing gate. Update capability/use-case coverage and owning request status only after the corresponding evidence exists, using their declared OKF profiles and log commands. Complete ADR distillation across this initiative's storage, ownership, scheduling and acceptance decisions.


## Concrete Steps


Run from the repository root in the existing development environment; if native tools are unavailable, enter `nix develop` first. PostgreSQL tests own disposable databases and must not be pointed at production. Capture a baseline before implementation, then run the following after each applicable milestone:

```bash
MP14_BASE=$(git rev-parse HEAD)
cabal build all
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-workers-test shikigami-server-test --test-show-details=direct
just migration-schema-isolation
python3 -m unittest discover -s tools/qualification -p 'test_*.py' -v
```

The build and tests must exit zero; tests report all cases passed. These are future implementation checks, not results of creating this plan. Add the named new test groups before using their success as evidence. If domain or workflow contracts change, scaffold with the checked workspace, stage/commit generated artifacts so the existing regeneration check compares the intended baseline, then run:

```bash
just keiro-gate "$MP14_BASE"
```

The gate must report no unexplained breaking change and generated conformance must pass. Record actual commands, baseline revision and bounded evidence in the living sections. Dependency source lookup starts with Mori; no new dependency bound is selected here. Before a later bound, pin or workaround change, verify the authoritative registry and upstream release tags as well as the Mori-located source.


## Validation and Acceptance


After implementation, from the repository root run the new driver against explicit configuration files:

```bash
python3 tools/qualification/adaptive-delivery.py --mode fixture --config tests/adaptive-delivery/fixture.yaml --artifact-dir build/adaptive-delivery-fixture
python3 tools/qualification/adaptive-delivery.py --mode live --config "$MP14_LIVE_CONFIG" --artifact-dir "$MP14_LIVE_EVIDENCE"
```

The two `MP14_LIVE_*` variables name operator-supplied private configuration and evidence directories, not credentials embedded in commands. A passing driver exits zero and produces a manifest with exact integrated artifact identities, checks, observed adaptation and recovery case results. Missing prerequisites or a failed combined journey exit nonzero with `blocked` or `failed` state. Confirm accepted context and budgets survive follow-up/compaction, actual provider tuples match admitted aliases, completed turns are not repeated, old owners are fenced, unknown effects remain visible and a finite objective closes only against integrated acceptance. No recurring mandate or publication intent is created. These proofs collectively cover UC-1 acceptance 1–4 and 6; plan 87 covers acceptance 5.


## Idempotence and Recovery


Use additive, schema-qualified migrations created through `just new-migration`; never edit an applied migration or upstream private tables. Re-running migrations and accepted commands must converge. Retain payloads and deduplication records referenced by live executions, idle sessions, pending handoffs or unresolved effects; terminal workflow GC is not permission to delete them. Roll forward after introducing a journal patch, because an older binary cannot serve its new branch. A storage or authority failure stops admission and preserves recorded work; retry with the same logical identities, not a newly minted root. At completion, distill durable storage/interface decisions into local ADRs under the contract in `agents/skills/exec-plan/ADR.md`.


## Interfaces and Dependencies


This plan owns only the fixture, qualification driver, evidence format and integration test/report changes. IR-11 owns real workspace tools and fences; IR-13 owns task/checkpoint state; plan 85 owns adaptive decisions and `IntegratedAcceptance`; plan 84 owns session events; plan 83 owns durable turns; plan 82 owns selections; plan 81 owns shared budgets. An unavailable external provider is a visible blocking prerequisite, not permission to build its entire feature here. Provider/checkpoint adapter interface mismatches are coordinated in the master plan before changing owners. Generic deployment readiness, external executor plan 78, public HTTP control and signed attestation completion remain separate.
