---
id: 82
slug: pin-governed-execution-settings-for-agent-assignments
title: "Pin governed execution settings for agent assignments"
kind: exec-plan
created_at: 2026-10-10T23:32:15Z
master_plan: "docs/masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md"
intention: "intention_01m4m2pjz6es9v9aqq5jq9c4ee"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-10T23:32:15Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:19:09Z
      verdict: "changes-requested"
      note: "Missing the plan 73 descriptor field list and reusable providerCall/matchesCall predicate that MasterPlan 13 assigned on 2026-10-21"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:19:09Z
      mode: "update"
      note: "Consume plan 73 public descriptor fields and reusable tuple predicate from MasterPlan 13"
---

# Pin governed execution settings for agent assignments

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Allow one deployment to run a coordinator and workers with distinct admitted model and reasoning settings, then preserve those choices through suspension and restart. Fulfill [IR-17](../improvement-requests/select-governed-models-for-agent-runs.md) without allowing inbound credentials, endpoints or arbitrary model strings. Hard dependencies are `docs/plans/81-enforce-root-resource-reservations-across-durable-work.md` for attempt accounting and existing `docs/plans/73-define-typed-decision-programs-and-authorized-model-catalogs.md` for the single operator catalog. Plan 73 is currently not started; this is an explicit prerequisite, not an existing implementation.


## Progress


Implementation has not started. Seed unchecked milestone entries when implementation begins.


## Surprises & Discoveries


None recorded during implementation.


## Decision Log


2026-10-10: Use the already planned operator catalog rather than establish another provider configuration. Make plan 73 an explicit external hard dependency; reuse current HTTP dispatch without requiring all typed-decision work to finish first.


## Outcomes & Retrospective


To be filled during implementation. Do not claim request completion until every acceptance case below, including stated external integration gates, has evidence.


## Context and Orientation


`shikigami-core/src/Shikigami/Behavior/Run.hs` stores one process model/options in `BehaviorEnv`. `Behavior/Provider.hs` owns `providerCall`, `constrainBehaviorEnv` and `newBehaviorEnvFor`; `Behavior/Compatibility.hs` checks actual options before dispatch. `schema/Agent.dhall`, `Agent/Decl.hs` and `Agent/Loader.hs` have no whole-run execution alias selection. Plan 73 owns the planned `Decision/ModelCatalog.hs` and operator `behavior.decisionModels`; plan 74 owns decision invocation dispatch. Reuse that catalog and current HTTP builder, with separate permissions for decision slots and whole-run selection. Do not require a typed Shikumi invocation to run a Skill. On 2026-10-21 MasterPlan 13 fixed two contracts this plan consumes: the public model descriptor carries alias, descriptor version and digest, provider, API, endpoint class, exact model, explicit thinking preference, and an opaque binding identity and version, with HTTP option compatibility staying in `Behavior.Provider` and `Behavior.Compatibility`; and plan 73 refactors `providerCall` and `matchesCall` to run over a descriptor's declared tuple or an actual model/options pair without constructing a `BehaviorEnv`. Call that predicate for whole-run admission and before each dispatch; a gap found here is reported to plan 73 as a contract change, not patched locally.

[ADR 0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md) pins the resolved profile; [ADR 0011](../adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md) preserves missing-field defaults. [ADR 0040](../adr/0040-response-options-and-foreground-launches-have-separate-authority.md) shares HTTP compatibility and keeps foreground CLI launches separate. Background CLI support is outside this plan.

The repository is a Cabal multi-package Haskell service. `shikigami-core` owns domain behavior and store adapters; `shikigami-workers` owns queue, resume and timer processes; `shikigami-server` owns operator commands. `shikigami-migrations/sql-migrations/manifest` owns append-only SQL ordering. `shikigami-core/test-postgres/Main.hs` registers tests using `Shikigami.Migrations.TestSupport.withShikigamiMigratedSuite`, which supplies isolated disposable PostgreSQL databases. Register new modules and tests in the owning Cabal file and test entry point; generated files under `Generated/` are regenerated, never hand-edited.


## Plan of Work


### Milestone 1: Admit an immutable execution selection

Add `shikigami-core/src/Shikigami/Execution/Selection.hs` with a serializable application-owned `ExecutionSelection` referencing the immutable public model descriptor from `Decision.ModelCatalog`. If its descriptor lacks compatible HTTP options now supplied by `Behavior.Provider`, extend that single owner additively and its tests; do not introduce another alias registry. The public selection contains alias, descriptor/version/digest, provider/API/endpoint class, exact model, explicit reasoning preference, effective compatible options, opaque binding id/version and policy references. Secrets and live provider closures remain process-local.

Extend declaration and Dhall defaults with an optional execution request containing default alias and permitted aliases. Accept a user requirement and parent assignment request through typed run input, never arbitrary vendor flags. Resolve the intersection of operator ceilings, current target declaration, user requirements, parent delegation, pinned sanctioned profile and harness/resource constraints. Explicit user choices constrain the answer; conflict is a typed refusal, not fallback. Historical declarations retain the process-default path; when newly admitted they pin its full effective descriptor. Test pure admission with no provider calls.

### Milestone 2: Pin and dispatch at the assignment boundary

Integrate selection into `Agent/Workflow.hs` before the first model call, and carry it through compatible `Agent/RunJob.hs` and delegation context. One assignment keeps one selection. A later assignment or explicit escalation may admit a new selection with rationale; an already accepted operation retains its earlier selection. Plan 84 will supply continuing assignment ids; ordinary runs use their stable workflow identity now. Apply the corresponding pinned selection to conversation Skill execution without enabling conversation overlays.

Build a per-execution `BehaviorEnv` with the shared provider builder and compatibility/profile predicates. Before every actual call, validate the pinned tuple, current authority and resource reservation. Resolve credentials only by pinned opaque binding identity. An unavailable binding produces `PinnedBindingUnavailable`; never resolve the mutable alias again or use a new environment default. Persist application-owned effective descriptor data, not Baikai `Options` values requiring an unsupported decoder. Guard workflow changes through the versioning rules below.

### Milestone 3: Correlate evidence and expose refusals

Correlate each actual provider attempt with root, run, assignment, selection and operation/attempt ids from plan 81. Preserve requested/configured and provider-reported model identities separately. Use the existing provider evidence boundary; normalized usage settles the root and absent usage stays unknown. Plan 83 supplies the durable transcript and consumes this selection, rather than this child implementing turn replay. Reuse decision evidence facts if existing plan 75 is complete; otherwise keep the adapter narrowly scoped to selection and resource facts, and record the integration reconciliation in the master plan.

Extend operator run inspection and `docs/operations/baikai-execution.md` with selected descriptor, binding availability and bounded refusal reasons. Demonstrate two worker aliases and one coordinator alias using HTTP provider fixtures. At this milestone, prove permission/catalog isolation with pure plan-73 fixtures: an unused whole-run default cannot grant or deny a decision slot. The real Flow invocation regression needs plans 74–76 and is explicitly owned by plan 85, not a hidden prerequisite for this child. Follow [workflow versioning](../workflow-versioning.md) for every durable-body change. Keep old journal populations on real old branches behind newly declared patch ids; preserve result codecs. Add declarations to `domain/shikigami.keiro-workspace`, regenerate the runtime and conformance artifacts, and union new workflow patch sets in `shikigami-core/src/Shikigami/Workflow/Versioning.hs`. Long-lived workflows restore a seed first, use static labels within each generation, rotate with `continueAsNew`, and republish generation-owned wake references. Do not invoke the pre-v1 reset exception without separately proving all four documented empty-population conditions. Default this plan to compatible evolution.


## Concrete Steps


Run from the repository root in the existing development environment; if native tools are unavailable, enter `nix develop` first. PostgreSQL tests own disposable databases and must not be pointed at production. Capture a baseline before implementation, then run the following after each applicable milestone:

```bash
MP14_BASE=$(git rev-parse HEAD)
cabal build all
cabal test shikigami-core-test shikigami-core-postgres-test --test-show-details=direct
just migration-schema-isolation
```

The build and tests must exit zero; tests report all cases passed. These are future implementation checks, not results of creating this plan. Add the named new test groups before using their success as evidence. If domain or workflow contracts change, scaffold with the checked workspace, stage/commit generated artifacts so the existing regeneration check compares the intended baseline, then run:

```bash
just keiro-gate "$MP14_BASE"
```

The gate must report no unexplained breaking change and generated conformance must pass. Record actual commands, baseline revision and bounded evidence in the living sections. Dependency source lookup starts with Mori; no new dependency bound is selected here. Before a later bound, pin or workaround change, verify the authoritative registry and upstream release tags as well as the Mori-located source.


## Validation and Acceptance


Add `ExecutionSelectionSpec` and `ExecutionSelectionWorkflowSpec`, registering them in core and PostgreSQL test trees. Capture actual fixture provider requests proving three distinct admitted model/reasoning tuples. Forbidden alias, cross-provider option, unsupported reasoning, user/parent restriction and profile conflict leave the request counter unchanged. Suspend before a call, change defaults/catalog, and resume: the pinned descriptor is used or the named binding refusal occurs. An explicit later escalation preserves previous results and root usage. Old declaration fixtures decode and retain defaults. Operator JSON contains no credential marker. Plan 83 subsequently proves zero re-dispatch of completed individual turns; this plan must not claim the old coarse loop already provides that property.


## Idempotence and Recovery


Use additive, schema-qualified migrations created through `just new-migration`; never edit an applied migration or upstream private tables. Re-running migrations and accepted commands must converge. Retain payloads and deduplication records referenced by live executions, idle sessions, pending handoffs or unresolved effects; terminal workflow GC is not permission to delete them. Roll forward after introducing a journal patch, because an older binary cannot serve its new branch. A storage or authority failure stops admission and preserves recorded work; retry with the same logical identities, not a newly minted root. At completion, distill durable storage/interface decisions into local ADRs under the contract in `agents/skills/exec-plan/ADR.md`.


## Interfaces and Dependencies


Catalog descriptor ownership stays with `docs/plans/73-define-typed-decision-programs-and-authorized-model-catalogs.md`; this plan owns `Execution.Selection`, whole-assignment permissions and the resolver returning `Either ExecutionSelectionFailure ExecutionSelection`. `Behavior.Provider` remains the common HTTP builder/tuple checker, including uses from `docs/plans/74-run-shikumi-decisions-through-governed-provider-calls.md`. Keep decision-only permissions and run permissions distinct. Reflect any descriptor extension in the owning plan 73 and MasterPlan 13 when implemented, using their provenance scripts. Plan 75 is an integration dependency for correlated facts, not a hard prerequisite to whole-run model choice. Plans 83–85 consume the pinned selection without reevaluating mutable configuration.
