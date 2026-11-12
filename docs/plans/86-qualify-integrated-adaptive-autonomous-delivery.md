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
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-04T05:33:34Z
      mode: "implement"
      note: "Resume native runtime qualification and independently verify retained integrated Git artifacts."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T21:09:33Z
      mode: "update"
      note: "Refresh the missing guarded live adapter, accepted native matrix and explicit production-authority/actual-model acceptance."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-09T04:28:36Z
      mode: "update"
      note: "Validate remaining live dispatch, admitted-limit and evidence-verifier work; retain historical native acceptance and rerun 50 host controls."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-09T05:01:24Z
      mode: "implement"
      note: "Add admission-bound live worker receipt and root-envelope verifier controls; retain the unimplemented live dispatch and trial gate."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-09T13:28:44Z
      mode: "implement"
      note: "Consolidate adaptive qualification coverage and prefer Haskell for native controls."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-12T14:08:07Z
      mode: "update"
      note: "Credit the qualified live adapter and identify remaining trusted-billing integration and actual-model trial; preserve acceptance."
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

- [x] Milestone 1 (2026-11-04): Reproducible two-repository fixture, bounded driver, 50 host controls and native objective admission.
- [x] Milestone 2 (2026-11-04): Full native integration/recovery/refusal matrix, exact returned artifacts and a passing driver command.
- [ ] Milestone 3: integrate trusted billing reconciliation, run the bounded actual-model/production-authority trial with explicit private configuration and approved limits, and publish passing live evidence and coverage updates. The guarded live adapter and its key-free qualification are already delivered.

2026-11-12 status audit at `8d46662a`: M1/M2 remain accepted and M3 remains
partially delivered. The live implementation and adapter report below already
credit `5e5d3255`; `af5febde` consolidates its native controls in Haskell. The next
engineering step is a trusted reconciliation source/consumer using
`Execution.SelectionStore.reconcileSelectionCallTx`, with independently linked
evidence accepted by the live verifier. Then supply private model/production
authority configuration and approved bounds for an actual trial. There is no
retained passing actual-model trial to mark off. The requirement remains relevant
to full UC-1 delivery; no acceptance was waived and no runtime test or external
call was performed for this documentation audit. Earlier checkpoints below retain
their original dates and do not describe missing live-adapter implementation today.

Live implementation resumed on 2026-11-09 UTC at `ec3e1c6c`. The guarded path
now exists in `tests/workspace/prototype/Adaptive.hs`, both Linux/Apple runners
and the driver. It consumes the production HTTP handlers, explicit private
AppConfig, fresh production authorizer and finite root limits. Actual coordinator
and worker calls share the retained selection/root receipts and physical-handler
journal; format-3 evidence compares those with independent admission and source
configuration. No scripted response or usage evidence is installed in live mode.
The full host build and 1,935 requested Haskell cases pass, as do 62 Python
qualification controls (15.184 seconds), eight native CLI preflight controls on
both macOS and Linux, and migration isolation. Immutable Linux runtime
`05yi39ncc8rkxji2ag8jm3wdhgc64gx2` passes the full fixture in 448.297 seconds,
including all six independently restored Git bundles, both recomputed exact
trees and the returned-pair journey. [Adapter qualification](../evidence/adaptive-delivery/live-adapter-qualification.md)
retains commands, source hashes and evidence; it is key-free qualification,
not actual-model proof. Actual-model/production-authority trial
acceptance remains open pending operator-supplied private configuration,
approved limits, and selection/wiring of trusted billing reconciliation. [Live templates and commands](../../tests/adaptive-delivery/README.md)
make those inputs concrete. No actual model call has been made in this work.
Mori now resolves dependency source/docs; FRIC-66 is resolved. FRIC-67 in
`docs/friction-log/` records the current baseline's cold Linux dependency cache;
the final candidate consumes its completed immutable output.

On 2026-11-09, following the user's Haskell preference, the eight native
preflight controls moved from Python to the Haskell fixture's
`adaptive-live-controls` command. A shared key-free `live-control.json` replaces
the Python configuration builder. Live Python integration tests now reside in
`tools/qualification/test_adaptive_delivery.py`; overlapping helper checks are
consolidated into full evidence-verifier cases. `AGENTS.md` records Haskell as
the preferred language for implementation, tooling and tests. The consolidation
passes eight native CLI controls on macOS, 56 remaining Python tests, shell
syntax checks and formatting. This test-only change does not rerun or replace
the historical Linux containment/recovery evidence, and does not close M3.

Implementation resumed on 2026-11-09 UTC at source
`217dd7bde45743d5ab425434783e479efa92e3a6`. The live worker verifier now accepts
an independent admitted descriptor map rather than requiring scripted model ids,
bindings or fixed call counts. It checks stored receipt/assignment/root links,
actual HTTP provider/API/model/thinking facts, token accounting and known billing.
A separate root-envelope check requires finite enforceable resource limits,
an explicit unsupported invoice-ceiling policy, the admitted cutoff and settled
work. The Linux selection snapshot now retains the owner's complete receipt and
outcome records. All 54 Python qualification tests pass (13.519 seconds), including
four new live verifier control groups. At that earlier checkpoint these helpers
were not yet connected to live dispatch: `native_evidence` and the executable
driver qualified only the deterministic fixture. The subsequent live composition
described above closed that implementation gap. No actual model was called and
M3 remains open.
The full fixture driver also passes with the expanded owner snapshots: its native
phase takes 448.241 seconds on reused immutable runtime `5ee0dd83`, retaining ten
complete worker receipt/outcome records and independently checking all six Git
bundles and both exact integrated trees. [Verifier evidence](../evidence/adaptive-delivery/live-verifier-controls.md)
and [native facts](../evidence/adaptive-delivery/live-verifier-native-facts.json)
retain this candidate's results. No Haskell rebuild was performed.
FRIC-66 in `docs/friction-log/` records unavailable Mori dependency discovery:
the configured PostgreSQL tunnel refuses connections and the host's independent
PostgreSQL instance has no Mori database. Do not substitute a new empty registry.

Refresh verified on 2026-11-08 at source `091c95abe5ef193d116b62e96298e9e952c731ab`:
all 50 Python qualification tests pass (12.124 seconds), including the live-mode
refusal and exact-artifact tamper controls. Source inspection at that checkpoint
confirmed the live qualification path was still unimplemented. At that point the
driver could not admit a live run; the native consumer scripted both coordinator
proposals and worker edits; the evidence verifier required fixture provider
bindings and fixed call counts. The later live composition supersedes those
implementation findings. Private production configuration and the actual-model trial remain
separate outstanding inputs/evidence. No Haskell rebuild, Linux runtime trial
or paid model call was performed in this refresh. M1/M2 retain their dated
acceptance below, not a new qualification of the current runtime.

Plans 85, 96 and 99 are complete. They supply the native adaptive controller,
configured transfer-aware workspace provider and real objective/checkpoint owner.
Their component evidence establishes prerequisites; this plan's joined fixture
now supplies its own repository, durability and exact-artifact evidence.

The clean final driver source is `805b34f6`, selecting immutable Linux runtime
`5ee0dd83`. Its full fixture command exits zero with `state: passed`; the native
phase takes 449.866 seconds. [Final native facts](../evidence/adaptive-delivery/native-facts.json)
retain exact source/runtime identities, artifacts, resource accounting, provider
bindings, owner epochs and recovery receipts. The two exact integrated trees
pass their native validations and the returned-pair journey after independent
restoration of all six Git bundles and recomputation from both worker pairs.
Four sessions retain five messages/results. Seven adaptive calls and two calls
for each of the five worker roles survive reconstruction without repetition.
Root accounting ends with no active or unknown work.

The full matrix covers adaptive-validation acknowledgement loss, committed tool
outcome, unconsumed atomic result/wake, accepted follow-up, objective ownership
commit before local successor establishment, and a lost real mutable-edit reply.
The original edit's independent late receipt reconciles its held root. During
uncertainty, the concrete production workspace owner admits an original-owner
control and refuses the eventual successor; fresh authority, real OS locks and
an unchanged root hold prevent service unavailability from satisfying that
probe. The later ownership cut uses the live private socket. A separate valid
integrated proposal refuses completion with `ObjectiveUnresolved` during an
accounting-only hold, then retries the exact acceptance after reconciliation.
Same-root last-slot reservations, foreign alias, undeclared target, action
authority and process-default drift controls also pass. Terminal replay preserves
all evidence, worker selection tuples and actual-call receipts.

All 50 qualification-tool tests pass. The [host report](../evidence/adaptive-delivery/host-qualification.md)
retains the earlier full build and 1,674 requested Haskell suite cases; production
workflow bodies, domain contracts and migrations have not changed in this plan.
The [native report](../evidence/adaptive-delivery/native-qualification.md) records
both passing complete native runs, the reduced baseline, and earlier failed
attempts. Those failures include an invalid initial root/cutoff pair, an
incorrect expectation that active work must reject a queued transfer request,
and a host parser expecting the wrong objective-error JSON encoding. The
corrected complete run above exercises the final interpretation and verdict.
Integration-helper receipt wakeups now receive their two known starts through
the normal execution driver; the earlier unseeded wake retries are absent.

Prototype preparation reuses the same frozen dependency solve and verifier
through `shikigami-qualification-dependencies`. Haskell fixture edits reuse its
Nix derivation; manifest edits invalidate it. Runtime assembly replaces current
application sources and rechecks original descriptor bytes before compiling.
The prototype selects the five executables consumed by the Linux runner and
runs serially to bound shared-builder disk demand. Production assembly retains
its full targets. [ADR 0039](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md)
records this qualified cache boundary. FRIC-54, FRIC-55 and FRIC-56 in
`docs/friction-log/` retain the rebuild/interruption costs.

The [historical live missing-configuration control](../evidence/adaptive-delivery/live-blocked-control.json)
records blocked/exit 2 without model work. The current driver still refuses
absent/invalid private live input and scripted evidence, but a valid live
configuration now selects a separate real HTTP composition. Models, fresh
production authority, enforced root limits and actual evidence are all required.
The actual trial remains open; fixture models and disposable issuers do not
close UC-1/IR-16. Codex CLI execution remains outside the accepted scope.


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

`WorkerSession.Store.recordResult` publishes its result event and prepared
awakeable notifications in the same checked transaction (`mutate` and
`prepareNotification`). There is no committed-result/unpublished-wake boundary
to kill between. The coupled result probe therefore targets the actual boundary:
a committed result/wake with its result cursor still beyond `consumedCursor`,
followed by controller death and reconstruction. It does not fabricate a lost
wake by changing framework or application projections.


The 2026-11-08 audit found a second live integration gap beyond the driver's
unconditional refusal. `validate_worker_selections` in
`tools/qualification/adaptive-delivery.py` requires provider/API/endpoint
`stub`/`stub`/`in-process`, model ids equal to role aliases and
`adaptive-fixture-` bindings. `native_evidence` also requires exact scripted
session/result and call counts. `tests/workspace/prototype/Adaptive.hs` constructs
proposal and tool-call responses itself and installs zero-usage evidence. These
are intentional deterministic controls; merely enabling live dispatch would
neither exercise actual-model coding through that consumer nor produce evidence
the current verifier accepts. M3 must supply both real dispatch and a verifier
bound to its admitted live selections, retaining the deterministic controls.


The live verifier work also confirms that an unbounded invoice policy does not
turn missing invoice facts into settled usage. The existing
`Execution.SelectionRuntime.outcomeFor` records missing token/cost dimensions,
and `Execution.SelectionStore` preserves that uncertainty. A future live trial
must retain measured facts or the owner's independent reconciliation evidence;
model estimates cannot silently clear the root. This is existing acceptance,
not a new invoice-ceiling requirement.


The native live preflight exposed two consumer assumptions hidden by synthetic
controls. Native `Dimension` maps serialize as key/value-pair arrays, including
limits and measured usage; the verifier and staging now consume that exact owner
format and reject duplicate dimensions. The regression reads retained real
native root evidence. Also, ordinary AppConfig environment precedence let an
inherited key satisfy a deliberately omitted credential. The live CLI boundary
now clears ambient configuration before loading its explicit file; the eight
native controls verify both valid parsing and refusal without model dispatch.
Production configuration semantics and workflow journals are unchanged.


The real HTTP provider source confirms the billing gate is substantive, not
merely a missing key. The OpenAI and Anthropic HTTP assemblers derive estimated
cost from catalog pricing. `Execution.SelectionRuntime.outcomeFor` accepts cost
only with `ProviderReportedTotal`, so successful HTTP calls may retain unknown
cost. `Execution.SelectionStore.reconcileSelectionCallTx` can consume independent
trusted measurements while preserving prior evidence, but this fixture has no
production invoice/reconciliation source configured. The direct live verifier
therefore refuses these unresolved calls rather than manufacture zero billing.
Selecting and qualifying a trusted billing reconciliation source remains an
actual-trial prerequisite; private model/service credentials alone cannot close
M3. This preserves [ADR 0052](../adr/0052-assignments-pin-whole-run-selection-and-account-every-provider-attempt.md).
Source ownership is `mori://shinzui/baikai`, project-relative
`baikai-openai/src/Baikai/Provider/OpenAI/Internal/Stream.hs`,
`baikai-openai/src/Baikai/Provider/OpenAI/Responses/Stream.hs` and
`baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs` (artifact-level source
URIs pending); use Mori to locate that checkout.


## Decision Log

2026-11-09: Give live qualification its own explicit private configuration and
format-3 consumer, while keeping the format-1/2 deterministic matrix intact.
Use the production parser/handlers/authorizer and native owner wire formats;
exclude ambient configuration at the live CLI boundary. Keep actual trial
acceptance and unknown-billing settlement distinct from key-free guard success.
This changes qualification composition, not workflow or owner contracts.


2026-10-10: Give integrated qualification its own child so green component tests cannot close UC-1. Require both deterministic fault tests through real durability boundaries and a bounded live coding trial; retain external workspace/checkpoint blockers explicitly.

2026-11-04: Consume the completed native coordinator and provider owners rather
than recreate them. Use the disposable Apple-container Linux substrate for
physical effects and host PostgreSQL tests for focused controller contracts.
Retain the full original acceptance, including a distinct live gate. Existing
component reports may establish prerequisites but cannot stand in for a coupled
adaptive repository run.

2026-11-04: Exercise result recovery at the owner's atomic result/wake commit
before consumer integration. The original “after result commit before
notification” wording described an interleaving the real owner prevents. Retain
the no-lost-result guarantee and explicit committed-record evidence rather than
introduce a fixture-only split transaction.

2026-11-04: Reuse a Nix-built frozen dependency tree for prototype qualification
after FRIC-54–56 and earlier plan-96 occurrences repeatedly delayed consumer
feedback. Keep one cohort/verifier, replace current application sources, restore
original descriptor bytes before verification, and retain a distinct immutable
candidate output. This changes prototype build preparation, not workflow,
authorization or production runtime contracts.


## Outcomes & Retrospective

The guarded HTTP/production-authority composition, explicit private staging,
ambient-configuration refusal, native resource-wire handling and format-3
consumer are implemented and guard-qualified. Full host checks and the current
immutable Linux fixture pass. The actual trial remains open for an operator's
private inputs/limits and selection/wiring of trusted invoice reconciliation.
The next integration must use `Execution.SelectionStore.reconcileSelectionCallTx`
with actual source evidence, preserving its prior compliance facts, and retain
an independently linked reconciliation record for the verifier. Current HTTP
estimates cannot close that gate. No use-case/request status has been promoted.
FRIC-66 is resolved; FRIC-67's cache miss is mitigated by the published immutable
dependency output. Final whole-plan friction triage remains with actual completion.


Milestones 1 and 2 are delivered with a reproducible, passing full fixture and
independently returned exact artifacts. Milestone 3 remains open pending the actual-model trial with private production configuration and trusted
billing reconciliation; no request/use-case status
has been marked complete.

Qualification must observe the owner's actual boundaries: result/wake
publication is atomic, a queued handoff is not successor establishment, and a
paused service cannot supply a meaningful refusal without a positive control.
Accepted integration tools also need an admitted initial execution start when
their receipt wakeups are consumed by the native driver. The final matrix and
its independent artifact checks exercise these corrections.

The frozen dependency cache and reduced serial prototype assembly mitigate the
rebuild costs recorded in FRIC-54–56. These entries remain logged; final friction
triage belongs to completion of the remaining live milestone.
[ADR 0039](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md)
retains the cache/assembly decision and
[ADR 0061](../adr/0061-continuing-sessions-own-ordered-assignments-and-retained-receipts.md)
retains the atomic result/wake contract.


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
a separate preparation step and cannot consume the finite objective budget. The original accepted
native run used a 48-model-attempt ceiling and 1,200-second cutoff. The current
checked-in `fixture.yaml` sets 48 attempts and a 1,800-second driver timeout;
record both configured driver bounds and the native root cutoff separately. Its
provider is free and deterministic; token/invoice dimensions are explicitly
unbounded fixture policy. The separate live composition is now implemented and
guard-qualified as described in M3. It requires its own private actual-provider/
authority configuration, enforceable limits and trusted billing settlement;
do not reuse fixture policies as a live spending claim.

### Milestone 2: Exercise adaptation, integration and fault recovery

Run two admitted workers with different allowed execution aliases. Inject an early schema finding that changes one task boundary or requests a temporary specialist; record friction, proposed benefit and eventual evidence. Accept revision-pinned worker artifacts, combine them through IR-11's separate integration workspace, expose conflicts, and run checks on the exact combined tree. Preserve repository identities, base/worker/integrated revisions or tree digests, command/exit status and user-journey evidence. An obsolete green worker artifact must not satisfy current acceptance.

Inject restart after a worker operation outcome, after a follow-up acceptance, after adaptation commit, after atomic result/wake commit before consumer integration, and during ownership transfer. Result and wake publication already share the owner transaction, so the result probe must observe a result cursor beyond the session's `consumedCursor` before killing its controller. Redeliver messages/events and verify one accepted assignment/result integration per operation. Hold a mutable operation unknown; successor write and successful completion must remain blocked until reconciliation. Race the final root reservation between local orchestrators, deny a forbidden alias/action/target before dispatch, and change deployment defaults while suspended. Inspect persisted records and actual provider/workspace counters, not model narratives.

### Milestone 3: Run a bounded live coding trial and publish evidence

The guarded composition is implemented in `tests/workspace/prototype/Adaptive.hs`
and selected by native stages `admit-live` / `drive-live`, exposed through
`tests/workspace/run-apple.sh --adaptive-live-only` and the driver `--mode live`.
Live mode installs only the existing production HTTP handlers and authorizer;
it does not construct model responses, zero usage or disposable issuer proofs.
`Main.hs` clears ambient configuration for those entry points. Native
`adaptive-live-preflight CONFIG LIMITS` uses the production AppConfig parser and
live validation without model dispatch. The key-free controls are executable:

```bash
nix develop --no-write-lock-file -c cabal build workspace-linux-fixture
nix develop --no-write-lock-file -c cabal run workspace-linux-fixture -- adaptive-contract
nix develop --no-write-lock-file -c cabal run workspace-linux-fixture -- adaptive-live-controls tests/adaptive-delivery/live-control.json
python3 -m unittest discover -s tools/qualification -p 'test_*.py' -v
```

`tests/adaptive-delivery/live.py` validates a private JSON application file with
exactly `authorization`, `credentials` and `behavior`, plus explicit root limits
and duration from the private driver configuration. The two checked-in example
JSON files and `tests/adaptive-delivery/README.md` specify every field and
operator preparation step. Both inputs are bounded private owned regular files;
staging copies only these approved values into the disposable guest, and removes
the host's staged credential copy on success or failure. The guest supplies its
own database, workspace roots and directory; operator files cannot redirect it
to production storage. Live mode skips both disposable issuer services and uses
the configured production Kikan-En/Shomei boundary. No publication is required.

The admitted root requires finite model/tool attempts, tokens, active work and
descendants, with a cutoff at most 1,200 seconds after admission. The outer
model-attempt ceiling must agree with the admitted root. Per-binding output and
request deadlines are mandatory. HTTP invoice ceilings remain unsupported and
explicitly unbounded; missing billing still retains uncertainty. The physical
handler journal records the unmodified provider response identity and applied
caps, while the owner records actual measured usage. No estimate is promoted to
settled billing to obtain completion.

Format-3 verification compares actual coordinator and worker receipts with the
separate admission snapshot and private operator specs, including root, provider,
API, exact model, thinking, binding versions and applied request caps. It requires
native resource-pair encoding, unique settled attempts, measured provider facts,
fresh production authority coordinates, a continuing-worker follow-up, terminal
replay and the same exact returned Git artifact checks as fixture mode. Failure
retains bounded owner root/call/authority records and available Git bundles as
forensic evidence, preserving unresolved scope without a passing verdict. The
deterministic fixture keeps its original fault-matrix acceptance. The final native fixture regression and eight Linux preflight controls pass.
An actual approved trial with trusted billing settlement remains required;
these controls alone cannot close M3.

With that adapter accepted and explicitly supplied live configuration, run the same finite fixture using at least one actual model-driven coding path, governed writable workspaces and the actual production authorization boundary. Set bounded attempts, duration, cost/token policy where enforceable, and exact local-edit/test scope; no publication or deployment is required. Validate service availability before starting and report absent configuration as blocked. This planning task does not create a deployment or incur live model work.

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

The build and tests must exit zero; tests report all cases passed. M1/M2 already have the named historical acceptance in Progress. These commands
are requalification instructions for a changed candidate. The 2026-11-08 refresh
reran only the Python command (50 passed); the Haskell and Linux checks remain
historical evidence. Add the named new test groups before using their success as evidence. If domain or workflow contracts change, scaffold with the checked workspace, stage/commit generated artifacts so the existing regeneration check compares the intended baseline, then run:

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

The fixture driver is implemented. Reuse its accepted runtime for unchanged
mechanics or requalify a rebuilt candidate. For the remaining actual-model
acceptance, run the implemented live adapter against the selected runtime and the
separately supplied live configuration:

```bash
python3 tools/qualification/adaptive-delivery.py --mode fixture --config build/adaptive-delivery-config/fixture.yaml --artifact-dir build/adaptive-delivery-fixture
python3 tools/qualification/adaptive-delivery.py --mode live --config "$MP14_LIVE_CONFIG" --artifact-dir "$MP14_LIVE_EVIDENCE"
```

The two `MP14_LIVE_*` variables name operator-supplied private configuration and evidence directories, not credentials embedded in commands. A passing driver exits zero and produces a manifest with exact integrated artifact identities, checks, observed adaptation and recovery case results. Missing prerequisites or a failed combined journey exit nonzero with `blocked` or `failed` state. Confirm accepted context and budgets survive follow-up/compaction, actual provider tuples match admitted aliases, completed turns are not repeated, old owners are fenced, unknown effects remain visible and a finite objective closes only against integrated acceptance. No recurring mandate or publication intent is created. These proofs collectively cover UC-1 acceptance 1–4 and 6; plan 87 covers acceptance 5.


## Idempotence and Recovery


Use additive, schema-qualified migrations created through `just new-migration`; never edit an applied migration or upstream private tables. Re-running migrations and accepted commands must converge. Retain payloads and deduplication records referenced by live executions, idle sessions, pending handoffs or unresolved effects; terminal workflow GC is not permission to delete them. Roll forward after introducing a journal patch, because an older binary cannot serve its new branch. A storage or authority failure stops admission and preserves recorded work; retry with the same logical identities, not a newly minted root. At completion, distill durable storage/interface decisions into local ADRs under the contract in `agents/skills/exec-plan/ADR.md`.


## Interfaces and Dependencies


This plan owns only the fixture, qualification driver, evidence format and integration test/report changes. IR-11 owns real workspace tools and fences; IR-13 owns task/checkpoint state; plan 85 owns adaptive decisions and `IntegratedAcceptance`; plan 84 owns session events; plan 83 owns durable turns; plan 82 owns selections; plan 81 owns shared budgets. The production provider and coordinator components are delivered; the guarded live composition and verifier are implemented, with the actual-model trial and trusted billing reconciliation remaining as M3 acceptance. Missing operator configuration is a visible blocked trial, not permission to bypass their boundaries. Provider/checkpoint adapter interface mismatches are coordinated in the master plan before changing owners. Generic deployment readiness, external executor plan 78, public HTTP control and signed attestation completion remain separate.

## Revision Notes


2026-11-12: Audit source, history and retained adapter evidence; update M3 to the
remaining trusted-reconciliation/private-input/actual-trial work and label obsolete
missing-live-adapter observations as historical. Preserve all milestone acceptance.

2026-11-04: Audited the working tree and completed plans 85, 96 and 99 before
implementation. Replaced obsolete blockers with concrete native producer,
controller, configured host and Linux qualification entry points; added ADRs
0108–0111, per-repository integration semantics and bounded sequential Nix test
commands. Acceptance and ownership remain unchanged.

2026-11-04: Align the result-recovery cut with the implemented atomic result/wake
owner transaction. The preserved acceptance is recovery without losing or
repeating a committed result, now observed before consumer integration.

Revision note (2026-11-06): Preserve accepted native M1/M2 evidence; identify the unconditional live-mode block and missing guarded adapter as real M3 work, reconcile driver/native cutoffs, and keep production authority/approved limits and actual-model proof open.


Revision note (2026-11-08): Revalidated all 50 host controls and inspected the
live driver, scripted consumer and evidence verifier at `091c95ab`. Preserve
M1/M2 historical acceptance, distinguish missing live implementation from private
operator inputs, and specify the live dispatch, admitted-limit and verifier work
needed for M3 without expanding scope or claiming a new runtime qualification.

Revision note (2026-11-09): Implement explicit private live composition, production
HTTP dispatch, ambient-configuration isolation, native resource-wire handling and
format-3 evidence checks. Retain 62 host controls, eight native guard controls,
1,935 requested Haskell cases and the passing current Linux fixture. Actual-model
acceptance still needs approved private inputs and trusted billing reconciliation.
