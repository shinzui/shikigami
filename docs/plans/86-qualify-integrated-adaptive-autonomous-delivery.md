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
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-30T16:34:26Z
      mode: "update"
      note: "Point qualification at plan 96 retained artifact integration without closing adaptive or objective acceptance"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-02T18:39:36Z
      mode: "update"
      note: "Refresh real workspace and objective prerequisites while retaining adaptive and live-trial gates."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-04T03:03:02Z
      mode: "implement"
      note: "Refresh completed native coordinator, workspace and objective prerequisites before integrated qualification."
---

# Qualify integrated adaptive autonomous delivery

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Prove [UC-1](../use-cases/adaptive-autonomous-delivery.md) finite delivery with a real adaptive coordinator, recoverable workers and exact combined repository artifacts. This closes integrated acceptance for [IR-16](../improvement-requests/support-adaptive-durable-orchestration.md) and supplies shared evidence for IR-14, IR-15 and IR-17. The hard prerequisites are now delivered: [plan 85](85-adapt-durable-delivery-through-validated-coordinator-decisions.md) supplies the native adaptive coordinator, [plan 96](96-provide-governed-mutable-repository-workspaces-for-durable-agents.md) supplies the IR-11 governed workspace provider, and [plan 99](99-supply-trusted-objective-associations-and-the-real-checkpoint-ownership-and-scope-providers.md) supplies the IR-13 checkpoint/ownership provider. Their component evidence does not prove this combined consumer. Do not mark the full use case delivered using substitutes. Recurrence remains independently qualified in plan 87.


## Progress


Implementation began on 2026-11-04 UTC at baseline
`05e2a3d94deeb0dd1d92c16e8403707dc9bb7c99`, on the existing branch.

- [ ] Milestone 1: Reproducible two-repository finite fixture, bounded qualification driver and argument/manifest tests.
- [ ] Milestone 2: Native adaptive integration, exact combined artifacts and deterministic recovery/refusal evidence through real providers.
- [ ] Milestone 3: Explicitly configured bounded live coding trial, published evidence and corresponding coverage updates.

Prerequisite update (2026-10-30):
[plan 96](96-provide-governed-mutable-repository-workspaces-for-durable-agents.md)
owns the installed configured workspace providers and the gated
`workspace.integrate:1` artifact planner. The latter consumes exact retained
worker commits under one execution root in a third workspace; edits, validation
and commit remain separately accepted effects. Its complete workspace-owned
native matrix passes 22 cases, with
[exact artifact and validation evidence](../evidence/plan-96/native-workspace-facts.json);
real ownership and accepted successor qualification remain open. This plan
retains its adaptive coordinator, objective completion and UC-1 acceptance
gates. Plan 85
and the real IR-13 provider still gate this plan's live milestones.

2026-11-02 prerequisites accepted: plan 99 supplies the real objective owner,
and plan 96's runtime `d38d2793` passes the complete 25-case native workspace
matrix. The [joint provider evidence](../evidence/plan-96/joint-native-qualification.json) retains exact
artifacts, real ownership recovery, successor effects and process fences.
At that checkpoint this plan remained Not Started and still required plan 85, adaptive coordinator
acceptance, integrated objective completion and the bounded live coding trial.
These provider facts do not complete UC-1 or its two-repository trial.

2026-11-04 refresh: plan 85 is complete, with five native adaptive Flow cases,
accepted typed decisions, shared executor capacity and real objective acceptance.
Its [acceptance report](../evidence/plan-85/acceptance.md) explicitly uses key-free
providers, a protocol fence fixture and owner-supplied synthetic artifacts. It
does not supply this plan's real two-repository consumer or live coding trial.
The installed workspace/ownership path passes the 25-case native matrix in plan
96. All start gates are satisfied; private live configuration remains an
operator-supplied prerequisite of milestone 3 only.

Implementation checkpoint `f468b6b9` supplies deterministic producer/consumer
Git seeds, a separately executable failing-then-corrected journey, the bounded
driver and eight argument/manifest controls. All 29 qualification-tool cases
pass, the five existing native adaptive PostgreSQL regressions pass, and
`nix develop --no-write-lock-file -c cabal build workspace-linux-fixture` passes.
`tests/workspace/prototype/Adaptive.hs` is the new coupled consumer; its
`--adaptive-only` Apple runner is not yet runtime-qualified. The driver therefore
retains a blocked gate, and no milestone or request is marked complete from
these compiler and fixture-mechanics results.

The [host qualification report](../evidence/adaptive-delivery/host-qualification.md)
records the full build, 1,674 requested Haskell suite cases and 36 Python tool
cases, including fifteen new adaptive controls. An actual Git bundle restores
the exact returned commit/tree and bytes in a fresh repository after removing
access to its original source path. The guest's cleanup now archives its four
worker commits and two integrated commits before disposal; failed runs retain
available HEADs as forensic evidence without settling unknown effects. Native
runtime evidence is still required before accepting these joined paths.

## Surprises & Discoveries


The pre-implementation audit found obsolete provider and coordinator blockers.
Plan 85's native Flow, plan 96's configured transfer-aware workspace host and
plan 99's actual objective owner exist. The remaining gap is their coupled
repository consumer. The historical `AdaptiveWorkflowSpec` integration check
uses a synthetic artifact and must not be relabeled as real repository evidence.

The existing integration planner accepts only direct worker commits from the
same repository/common base, and requires at least two artifacts. The new
fixture therefore uses a delivery worker and a bounded review worker in each
repository, with the consumer correction committed only after its follow-up.
It combines each pair in a separate configured workspace and runs the journey
on blobs read from the resulting exact trees. It never feeds cross-repository
artifacts into that planner.

FRIC-54 in `docs/friction-log/` records that a fixture-only native derivation
change recompiles the complete frozen Cabal graph. Local compilation precedes
the configured-builder run; that build is preparation, not runtime evidence.


## Decision Log


2026-10-10: Give integrated qualification its own child so green component tests cannot close UC-1. Require both deterministic fault tests through real durability boundaries and a bounded live coding trial; retain external workspace/checkpoint blockers explicitly.

2026-11-04: Consume the completed native coordinator and provider owners rather
than recreate them. Use the disposable Apple-container Linux substrate for
physical effects and host PostgreSQL tests for focused controller contracts.
Retain the full original acceptance, including a distinct live gate. Existing
component reports may establish prerequisites but cannot stand in for a coupled
adaptive repository run.


## Outcomes & Retrospective


To be filled during implementation. Do not claim request completion until every acceptance case below, including stated external integration gates, has evidence.


## Context and Orientation


The use case requires two repository workstreams, an evidence-triggered adaptation, restart recovery and integrated user-journey checks. `shikigami-workers/src/Shikigami/Workers/Config.hs` installs the reviewed configured workspace host when operator workspace settings are supplied; absent settings retain `emptyCapabilityRuntime`. A declaration alone grants no allocation or tool authority. Plan 96, rather than the older portable harness plans 48/59, delivers the mutable provider. Existing `tools/qualification/` and `docs/evidence/local-qualification/readiness.md` separate environment readiness from actual runtime proof; their baseline cannot establish autonomous coding.

The concrete consumer entry points now exist. The `adaptive-delivery` Flow is
registered in `shikigami-core/src/Shikigami/Flow.hs`; its native controller is
`shikigami-core/src/Shikigami/Coordination/Workflow.hs`. Start an objective-bound
run through `Ledger.acceptObjectiveRunRequest` and the normal AgentRun producer,
as exercised by `shikigami-core/test-postgres/Shikigami/AdaptiveWorkflowSpec.hs`.
Never insert bare fresh workflow input: the producer must pin the deployment
patch snapshot with the original input. `Objective.Capability` owns creation,
criteria, membership, evidence and final acceptance; `Coordination.Checkpoint`
owns accepted adaptive manifests, not another objective state store.

`tests/workspace/prototype/Durable.hs` supplies the normal AgentRun/accepted
execution consumer with a configured writable host. `Qualification.hs` supplies
retained Git artifact integration in a separate workspace; `Continuing.hs`
supplies real objective ownership and accepted successor effects. Their
`workspace-linux-fixture.cabal` executable is built by the existing Nix
`shikigami-workspace-prototype` attribute. `tests/workspace/run-apple.sh` provisions
a disposable guest with no host mounts or existing credentials and copies only
explicit fixture sources. Extend or reuse this substrate for the coupled test;
do not turn host filesystem mocks into containment evidence. Account for the
guest's periodic realtime step as documented in AGENTS.md: observe a step before
short admissions and keep the absolute deadline guard enabled.

[ADR 0108](../adr/0108-adaptive-decisions-commit-with-authoritative-checkpoints.md)
requires proposal manifests and objective receipts to commit atomically.
[ADR 0109](../adr/0109-runtime-capacity-admission-shares-accepted-attempt-fences.md)
separates shared runtime occupancy from root usage and unknown spending.
[ADR 0110](../adr/0110-accepted-typed-decisions-account-for-every-transport-call.md)
requires every actual internal decision call to spend the same root.
[ADR 0111](../adr/0111-adaptive-delivery-carries-native-admission-and-reference-only-seeds.md)
defines pinned role catalogs, native objective child association, generation
wakes and reference-only controller seeds. Consume these implemented boundaries
without altering old journal branches. Workspace integration is per canonical
repository identity; a two-repository journey must retain one exact resulting
tree per repository and test that exact pair, rather than feed cross-repository
commits to a same-repository integration planner.

[ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) requires admitted provider revisions; [ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md) requires live external authority. [ADR 0040](../adr/0040-response-options-and-foreground-launches-have-separate-authority.md) says a foreground process exit is not durable agent completion. The `IntegratedAcceptance` contract from plan 85 binds exact artifact/evidence identities to the criteria revision; IR-11 owns workspace creation/edit/process/Git/integration and IR-13 owns objective completion.

The repository is a Cabal multi-package Haskell service. `shikigami-core` owns domain behavior and store adapters; `shikigami-workers` owns queue, resume and timer processes; `shikigami-server` owns operator commands. `shikigami-migrations/sql-migrations/manifest` owns append-only SQL ordering. `shikigami-core/test-postgres/Main.hs` registers tests using `Shikigami.Migrations.TestSupport.withShikigamiMigratedSuite`, which supplies isolated disposable PostgreSQL databases. Register new modules and tests in the owning Cabal file and test entry point; generated files under `Generated/` are regenerated, never hand-edited.


## Plan of Work


### Milestone 1: Build a reproducible finite delivery fixture

Create `tests/adaptive-delivery/` with two small temporary Git repositories and a combined user journey. Use a producer that emits a versioned record and a consumer that reads it, with an independently executable contract test. Choose the fixture so each worker's initial local checks can pass while the combined behavior fails until coordinated schema assumptions are reconciled. Provide per-repository instructions and canonical admitted fixture repository identities through the IR-11 catalog; no model-chosen absolute paths. Store starting revisions, expected behavior, authority/resource envelope and test commands in `tests/adaptive-delivery/README.md`.

Add `tools/qualification/adaptive-delivery.py` with `--mode fixture|live`, `--config` and `--artifact-dir`. The driver prepares only isolated fixture workspaces, starts an explicitly finite objective via the supported CLI/internal enqueue adapter, observes durable state, and writes a bounded evidence manifest. Missing provider/checkpoint/authority prerequisites yield a clear blocked result and nonzero exit, not a simulated success. The fixture-mode provider supplies scripted model responses but still traverses real journals, reservations, session messages, authority adapters and workspace tools. Add driver argument/manifest tests without requiring live credentials.

The implementation entry points are now `tests/adaptive-delivery/prepare.py`,
the per-repository templates, `journey.py`, `fixture.yaml` and
`tests/workspace/prototype/Adaptive.hs`. The latter is compiled in the existing
optional `workspace-linux-fixture` package. `tests/workspace/run-apple.sh
--adaptive-only` provisions the real Linux substrate and the guest runner
initializes the same deterministic seeds. The native consumer creates the
objective with its real owner, accepts an objective-bound run through
`Ledger.acceptObjectiveRunRequest`, pins native admission and resumes accepted
decision and worker jobs. It uses the configured transfer-aware provider and
the production C13 proof-verification client against a disposable fixture
issuer. It does not qualify live production authority.

The driver configuration is JSON-form YAML, with no additional parser
dependency. It admits exactly the two canonical fixture identities, bounds
duration and model attempts, strips ambient provider/database configuration and
writes private per-attempt manifests. Required `runtime` selects an explicitly
built Nix output; record that actual output alongside source facts. Missing
runtime selection returns blocked before native admission. Cold compilation is
a separate preparation step and cannot consume the finite objective budget. The current
native envelope has a 48-model-attempt ceiling and 1,200-second cutoff. Its
provider is free and deterministic; token/invoice dimensions are explicitly
unbounded fixture policy. `--mode live` remains blocked until a separate actual
provider/authority adapter and operator-supplied limits are installed. Do not
reuse these fixture policies as a live spending claim.

### Milestone 2: Exercise adaptation, integration and fault recovery

Run two admitted workers with different allowed execution aliases. Inject an early schema finding that changes one task boundary or requests a temporary specialist; record friction, proposed benefit and eventual evidence. Accept revision-pinned worker artifacts, combine them through IR-11's separate integration workspace, expose conflicts, and run checks on the exact combined tree. Preserve repository identities, base/worker/integrated revisions or tree digests, command/exit status and user-journey evidence. An obsolete green worker artifact must not satisfy current acceptance.

Inject restart after a worker operation outcome, after a follow-up acceptance, after adaptation commit, after result commit before notification, and during ownership transfer. Redeliver messages/events and verify one accepted assignment/result integration per operation. Hold a mutable operation unknown; successor write and successful completion must remain blocked until reconciliation. Race the final root reservation between local orchestrators, deny a forbidden alias/action/target before dispatch, and change deployment defaults while suspended. Inspect persisted records and actual provider/workspace counters, not model narratives.

### Milestone 3: Run a bounded live coding trial and publish evidence

With explicitly supplied live configuration, run the same finite fixture using at least one actual model-driven coding path, governed writable workspaces and the actual production authorization boundary. Set bounded attempts, duration, cost/token policy where enforceable, and exact local-edit/test scope; no publication or deployment is required. Validate service availability before starting and report absent configuration as blocked. This planning task does not create a deployment or incur live model work.

Write `docs/evidence/adaptive-delivery/` summaries containing tested service/source versions, operation and selection ids, exact integrated artifacts, check outcomes, observed latency/resources/rework and uncertainty. Distinguish fixture mechanics from live behavior and do not generalize fleet-wide improvement from one trial. A failed live run preserves artifacts and exact unresolved scope and is not a passing gate. Update capability/use-case coverage and owning request status only after the corresponding evidence exists, using their declared OKF profiles and log commands. Complete ADR distillation across this initiative's storage, ownership, scheduling and acceptance decisions.


## Concrete Steps


Run from the repository root. Use the existing Nix development environment:
plain Cabal cannot locate this project's configured GHC. PostgreSQL tests own
disposable databases and must not be pointed at production. FRIC-51 established
that database suites need bounded concurrency and sequential execution. Capture
the baseline before implementation and run these at coherent boundaries:

```bash
MP14_BASE=$(git rev-parse HEAD)
nix develop --no-write-lock-file -c cabal build all
TASTY_NUM_THREADS=2 nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-server-test --test-show-details=direct
TASTY_NUM_THREADS=2 nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test --test-show-details=direct
TASTY_NUM_THREADS=2 nix develop --no-write-lock-file -c cabal test shikigami-workers-test --test-show-details=direct
nix develop --no-write-lock-file -c just migration-schema-isolation
python3 -m unittest discover -s tools/qualification -p 'test_*.py' -v
```

The build and tests must exit zero; tests report all cases passed. These are future implementation checks, not results of creating this plan. Add the named new test groups before using their success as evidence. If domain or workflow contracts change, scaffold with the checked workspace, stage/commit generated artifacts so the existing regeneration check compares the intended baseline, then run:

```bash
TASTY_NUM_THREADS=2 nix develop --no-write-lock-file -c just keiro-gate "$MP14_BASE"
```

The gate must report no unexplained breaking change and generated conformance must pass. Record actual commands, baseline revision and bounded evidence in the living sections. Dependency source lookup starts with Mori; no new dependency bound is selected here. Before a later bound, pin or workaround change, verify the authoritative registry and upstream release tags as well as the Mori-located source.


## Validation and Acceptance


Prepare the immutable Linux runtime before admitting the bounded objective.
The checked-in fixture configuration deliberately has no machine-specific output
path. From the repository root, build the runtime separately and create a private
copy selecting that exact output:

```bash
umask 077
mkdir -p build/adaptive-delivery-config
nix build .#packages.x86_64-linux.shikigami-workspace-prototype --max-jobs 0 --cores 2 --no-link --no-write-lock-file --json > build/adaptive-delivery-config/runtime.json
python3 - <<'PY'
import json
from pathlib import Path
directory = Path("build/adaptive-delivery-config")
runtime = json.loads((directory / "runtime.json").read_text())
assert len(runtime) == 1
config = json.loads(Path("tests/adaptive-delivery/fixture.yaml").read_text())
config["runtime"] = runtime[0]["outputs"]["out"]
(directory / "fixture.yaml").write_text(json.dumps(config, indent=2) + "\n")
PY
```

After implementation, run the driver against the selected runtime and the
separately supplied live configuration:

```bash
python3 tools/qualification/adaptive-delivery.py --mode fixture --config build/adaptive-delivery-config/fixture.yaml --artifact-dir build/adaptive-delivery-fixture
python3 tools/qualification/adaptive-delivery.py --mode live --config "$MP14_LIVE_CONFIG" --artifact-dir "$MP14_LIVE_EVIDENCE"
```

The two `MP14_LIVE_*` variables name operator-supplied private configuration and evidence directories, not credentials embedded in commands. A passing driver exits zero and produces a manifest with exact integrated artifact identities, checks, observed adaptation and recovery case results. Missing prerequisites or a failed combined journey exit nonzero with `blocked` or `failed` state. Confirm accepted context and budgets survive follow-up/compaction, actual provider tuples match admitted aliases, completed turns are not repeated, old owners are fenced, unknown effects remain visible and a finite objective closes only against integrated acceptance. No recurring mandate or publication intent is created. These proofs collectively cover UC-1 acceptance 1–4 and 6; plan 87 covers acceptance 5.


## Idempotence and Recovery


Use additive, schema-qualified migrations created through `just new-migration`; never edit an applied migration or upstream private tables. Re-running migrations and accepted commands must converge. Retain payloads and deduplication records referenced by live executions, idle sessions, pending handoffs or unresolved effects; terminal workflow GC is not permission to delete them. Roll forward after introducing a journal patch, because an older binary cannot serve its new branch. A storage or authority failure stops admission and preserves recorded work; retry with the same logical identities, not a newly minted root. At completion, distill durable storage/interface decisions into local ADRs under the contract in `agents/skills/exec-plan/ADR.md`.


## Interfaces and Dependencies


This plan owns only the fixture, qualification driver, evidence format and integration test/report changes. IR-11 owns real workspace tools and fences; IR-13 owns task/checkpoint state; plan 85 owns adaptive decisions and `IntegratedAcceptance`; plan 84 owns session events; plan 83 owns durable turns; plan 82 owns selections; plan 81 owns shared budgets. The providers and coordinator are delivered; a missing operator configuration is a visible blocked trial, not permission to bypass their boundaries. Provider/checkpoint adapter interface mismatches are coordinated in the master plan before changing owners. Generic deployment readiness, external executor plan 78, public HTTP control and signed attestation completion remain separate.

## Revision Notes


2026-11-04: Audited the working tree and completed plans 85, 96 and 99 before
implementation. Replaced obsolete blockers with concrete native producer,
controller, configured host and Linux qualification entry points; added ADRs
0108–0111, per-repository integration semantics and bounded sequential Nix test
commands. Acceptance and ownership remain unchanged.
