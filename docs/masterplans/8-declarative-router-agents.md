---
id: 8
slug: declarative-router-agents
title: "Declarative router agents"
kind: master-plan
created_at: 2026-07-26T04:38:46Z
intention: "intention_01kyeb9j20e8prwv62v7mzp574"
---

# Declarative router agents

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

After this initiative, a Shikigami agent can declare that it is a router, expose a bounded
catalog of specialists from its existing `delegates` allow-list, and make one replay-safe,
typed route decision. An `architecture-practice-router` presented with an
OpenTelemetry-shaped payload can select `opentelemetry-practice-reviewer`, explain the
selection, and launch the specialist through the durable delegation mechanism planned in
`docs/plans/35-delegation-as-a-first-class-declared-capability.md`, which is now delivered. A
replay reuses the recorded catalog and decision instead of consulting changed declarations or
a model again.

The initiative includes additive Dhall and Haskell declaration types, candidate discovery,
lifecycle filtering, typed `matched` / `no-match` / `ambiguous` decisions, policy and
allow-list validation, durable delegation, and parent-session observability. Existing
non-router declarations remain valid. It excludes domain-specific review verdicts (owned by
`docs/masterplans/9-architecture-practice-review-flow.md`), global agent marketplaces,
repository watching, tool or sink authorization, source edits, and merge gating.


## Decomposition Strategy

The request spans three functional concerns that are independently demonstrable. EP-1 owns
the author-facing declaration language and complete v1 wire-format proof. EP-2 turns those declarations
into a versioned, lifecycle-aware candidate catalog without running a model or spawning a
child. EP-3 owns the durable workflow boundary: typed decisions, journaling, validation,
delegation, and observability. This makes the schema reviewable before runtime work starts
and lets catalog behavior be tested as a pure boundary.

A single ExecPlan was rejected because it would mix Dhall evolution, directory policy, and
Keiro workflow semantics across more than five milestones. Splitting observability into a
fourth plan was also rejected because the routing decision and its audit record must be
written atomically under the same parent session; separating them would create an
unverifiable intermediate state.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Declare specialist expertise and router policy | docs/plans/40-declare-specialist-expertise-and-router-policy.md | delivered foundations: plans 33, 35, 36, and 47 | None | Complete |
| 2 | Resolve lifecycle-aware router candidate catalogs | docs/plans/41-resolve-lifecycle-aware-router-candidate-catalogs.md | EP-1; delivered foundations: plans 23 and 33 | None | Not Started |
| 3 | Execute replay-safe typed routing and delegation | docs/plans/42-execute-replay-safe-typed-routing-and-delegation.md | EP-1, EP-2; delivered foundations: plans 24, 35, and 39 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 precedes both other children because it defines the `expertise` and `routing` fields
that candidate discovery reads and the validation rules that runtime code may assume. EP-2
then produces the resolved, versioned catalog consumed by EP-3. EP-3 therefore waits for
both EP-1 and EP-2.

All external foundations have landed. Plan 33 delivered the additive declaration and manual
workflow-journal codec pattern; plans 35 and 36 delivered governed delegation and final package
ownership; plan 23 delivered the cached principal-directory lifecycle boundary; and plans 24
and 39 delivered workflow patching plus the checked Keiro specification. Plans 37 and 38 still
carry unrelated migration-CLI configuration cleanup, but the declaration, configuration, and
migration surfaces consumed here are already present and are not blockers. The only remaining
hard ordering is therefore EP-1, then EP-2, then EP-3.


## Integration Points

IP-1 — the canonical agent declaration. EP-1 owns additive `ExpertiseDecl` and
`RouterPolicy` shapes in `schema/Agent.dhall` and their mirrors in
`shikigami-core/src/Shikigami/Agent/Decl.hs`. Dhall defaults keep every checked-in manifest
valid, while EP-1 replaces the pre-release omission/missing-key JSON shim with one complete v1
declaration shape under
`docs/adr/0027-the-first-release-establishes-one-clean-durable-baseline.md`. After v1,
`docs/adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md` governs further
evolution. EP-2 and EP-3 only consume these shapes. The
fields use direct names under `DuplicateRecordFields`; no type-prefixed record fields are
introduced.

IP-2 — the candidate catalog. EP-2 owns `Shikigami.Router.Catalog`, including catalog
versioning, exclusion reasons, lifecycle-source attribution, and an atomic read-once directory
snapshot. EP-3 journals the complete catalog before it evaluates a route. A catalog never
performs one live lifecycle lookup per candidate because a background refresh could otherwise
mix two directory snapshots in one decision boundary.

IP-3 — the route decision. EP-3 owns `RouteDecision`, `RouteSelection`, `RouteOutcome`, and
their strict decoder/validator. A model-facing program may produce the JSON, but only the
validator may convert it into authority to delegate.

IP-4 — delegation governance. Existing plan 35 owns `delegates`, the durable tree-wide
budget, ancestor-cycle rejection, deterministic child workflow ids, and partial child
results. It currently reserves one child at a time. EP-3 extends the same owned store module
with one atomic, idempotent batch reservation over deterministic child ids, then calls the
existing governed `delegate` boundary for every already-reserved child. It does not create a
second ledger or spawn path.

IP-5 — lifecycle availability. Existing plan 23 owns `DirectoryHandle`, its last-known-valid
snapshot semantics, and lifecycle decisions. EP-2 adds a public immutable snapshot projection
so one catalog uses one directory view. Explicit directory-disabled mode is attributed as
`local-enabled`; the currently shipped file source is attributed as `directory-file`, not as a
live Meibo client. A future typed client may use `meibo-client` without changing the catalog
algorithm.

IP-6 — durable routing and observability. EP-3 owns statically declared, hyphenated catalog
and decision step names in the first released workflow baseline. Because Shikigami has no users,
durable state, or external wire consumers before its imminent v1 release, the labels land directly
without a patch id or unreachable legacy branch, following
`docs/adr/0027-the-first-release-establishes-one-clean-durable-baseline.md`. EP-3 records the
expected pre-v1 `WorkflowBodyChanged` report and passes every non-diff gate component; after v1,
`docs/adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md` applies normally.
Routing attributes are added through the tracing effect already used by
`Shikigami.Agent.Workflow`; the worker-only `Shikigami.Telemetry` module remains tracer setup,
not domain policy. Payload document bodies are excluded from logs and traces.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] (2026-08-23T19:20:10Z) EP-1 M1: Added manifest-compatible expertise and
  router-policy declaration types.
- [x] (2026-08-23T19:20:10Z) EP-1 M2: Mirrored and validated the types in Haskell,
  pinned the complete v1 JSON shape, and proved every live manifest still loads.
- [x] (2026-08-23T19:20:10Z) EP-1 M3: Added router and specialist proof manifests,
  CLI diagnostics, and author documentation.
- [ ] EP-2 M1: Build a deterministic catalog from the router's declared delegates.
- [ ] EP-2 M2: Apply enabled/Meibo lifecycle availability with explicit exclusion reasons.
- [ ] EP-2 M3: Version, redact, and test the catalog boundary.
- [ ] EP-3 M1: Define and strictly decode the typed route decision.
- [ ] EP-3 M2: Journal catalog and decision under stable checked Keiro step names.
- [ ] EP-3 M3: Validate policy, lifecycle, allow-list, and budget before using plan 35 delegation.
- [ ] EP-3 M4: Record observability and prove matched, no-match, ambiguous, replay, and failure behavior.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Plans 33, 35, 36, 39, and 23 have landed. The current declaration already carries identity,
  memory, enablement, delegates, delegation budget, sanctioned profile, and capability overlays;
  expertise and routing are the only MasterPlan-8 declaration fields still absent.
- `AgentLoadReport` now preserves every loaded and failed manifest, but a failed entry has a
  path and diagnostic rather than a trustworthy agent name. EP-2 must not attribute an
  arbitrary failed file to a missing delegate; it records the candidate as missing and carries
  only a bounded unassociated load-failure count in the catalog. Full diagnostics remain in
  the canonical load report and operator logs.
- The report can also contain multiple successfully decoded declarations with the same name.
  EP-2 excludes that candidate as `duplicate-declaration` instead of choosing by file order.
- `DirectoryHandle` publishes complete snapshots atomically, but its public lookup functions
  each read the handle independently and expose no stable snapshot identity. EP-2 needs one
  read-once immutable projection so a catalog cannot mix refresh generations.
- Governed delegation now checks allow-list, lineage cycle, depth, and the durable root budget,
  but its store API reserves one child per transaction. EP-3 must add the already-planned batch
  reservation before any routed child is spawned.
- The July proposal's `route-catalog:<label>` and `route-decision:<label>` spellings cannot be
  declared by the checked Keiro language because `:` is not a workflow wire-word character.
  EP-3 uses static hyphenated labels in the v1 baseline. `keiro-diff` deliberately reports the
  direct pre-v1 body growth as `WorkflowBodyChanged`; the owning plan records that report while
  all structural, generated, conformance, replay, and full-suite checks remain mandatory.
- Shikigami has no users and its first release is imminent. There are no historical
  `lookup-agent` values or pre-router workflow generations to protect, so extending the old JSON
  omission shim or adding a router patch would create first-release technical debt for an empty
  population. ADR 0027 records the bounded pre-v1 exception and its release cutoff.
- EP-1's strict Haskell fields made every direct `AgentDecl` test constructor compile-visible,
  while Dhall record completion kept every source manifest unchanged. The complete v1 JSON value
  is pinned separately, so source compatibility and the durable release baseline are tested at
  their actual boundaries.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Make plan 33 and plan 47 hard foundations for declaration/catalog work and make
  plan 35 a hard predecessor of routed execution.
  Rationale: the router extends the canonical agent schema and durable delegation machinery;
  recreating either would split validation, budget, lineage, and replay semantics.
  Date: 2026-07-30

- Decision: Use one MasterPlan with three child plans: declaration, catalog, and durable
  execution.
  Rationale: These are independently verifiable functional boundaries with a natural data
  flow, while a single plan would exceed the ExecPlan complexity threshold and mix unrelated
  schema, directory, and workflow risks.
  Date: 2026-07-25

- Decision: Treat plan 23 as a soft dependency of catalog construction and require honest
  source attribution when only local enablement is available.
  Rationale: The improvement request permits the interim, but explicitly forbids claiming a
  Meibo check that did not occur.
  Date: 2026-07-25

- Decision: Make the catalog snapshot and typed decision replay artifacts, not live lookups
  performed again on resume.
  Rationale: A router must not select a different specialist because declarations, lifecycle,
  or model output changed after the original workflow step.
  Date: 2026-07-25

- Decision: Keep the three-child decomposition but refresh every child against the delivered
  August architecture before implementation begins.
  Rationale: the functional boundaries remain sound, while package ownership, lifecycle,
  workflow evolution, delegation governance, and dependency versions have all become concrete.
  Date: 2026-08-23

- Decision: Read one immutable directory snapshot per catalog and version semantic contents,
  not refresh time.
  Rationale: per-candidate reads can mix generations, while including `loadedAt` would change a
  catalog version when identical policy content is merely refreshed.
  Date: 2026-08-23

- Decision: Use declarable hyphenated route-step labels under a real workflow patch and reserve
  every selected child in one transaction before spawning any of them.
  Rationale: the checked specification rejects colon labels, and one-at-a-time reservation can
  create a partial routed fan-out before discovering that the complete selection exceeds the
  remaining budget.
  Date: 2026-08-23

- Decision: Supersede the router-patch half of the preceding decision and establish both the
  complete `AgentDecl` JSON object and route-step labels directly as the v1 baseline.
  Rationale: Shikigami has no users, stored declarations, resumable workflows, or external wire
  consumers, and the first release is imminent. Compatibility code would protect no state while
  becoming debt in v1. Static labels remain declared and journaled; only the empty-population
  migration branch is removed. ADR 0027 makes the exception expire at release.
  Date: 2026-08-23

- Decision: Treat the checked complete `AgentDecl` JSON fixture as the post-release baseline for
  future declaration evolution.
  Rationale: a concrete fixture makes the first durable contract explicit without retaining a
  decoder for nonexistent pre-release values.
  Date: 2026-08-23


## Outcomes & Retrospective

EP-1 is complete. Shikigami now has an author-facing expertise and router-policy vocabulary,
bounded semantic declaration validation, proof manifests, CLI diagnostics, and a pinned complete
v1 declaration value. Existing Dhall manifests still load through defaults, and no compatibility
shim was carried into the first release for an empty historical population. EP-2 and EP-3 remain:
no candidate catalog, route decision, or routed workflow execution exists yet.


## Revision Notes

- 2026-07-30: Added the previously prose-only external edges to plans 33, 35, and 47 and
  kept plan 23 as a source-attributed soft dependency.
- 2026-08-23: Refreshed the MasterPlan after plans 23, 24, 33, 35, 36, and 39 landed; removed
  false external blockers, corrected package and lifecycle ownership, made directory snapshot
  consistency and batch reservation explicit, and reconciled routing steps with the checked
  workflow patch contract.
- 2026-08-23: Rebased the initiative on the imminent first release and confirmed absence of users
  or durable state. Replaced pre-release declaration-codec and workflow-patch shims with one clean
  v1 baseline, retained Dhall source defaults and replay journaling, and recorded the release
  cutoff in ADR 0027.
- 2026-08-23: Completed EP-1 with declaration types, bounded validation, proof manifests,
  documentation, a pinned complete v1 JSON fixture, and full-suite validation. Advanced the
  checkpoint to EP-2.
