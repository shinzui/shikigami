---
id: 41
slug: resolve-lifecycle-aware-router-candidate-catalogs
title: "Resolve lifecycle-aware router candidate catalogs"
kind: exec-plan
created_at: 2026-07-26T04:38:46Z
intention: "intention_01kyeb9j20e8prwv62v7mzp574"
master_plan: "docs/masterplans/8-declarative-router-agents.md"
---

# Resolve lifecycle-aware router candidate catalogs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A declared router can ask Shikigami for a deterministic catalog of only the specialists in
its `delegates` allow-list. Each entry includes the specialist's description and expertise,
whether it is currently available, why it was excluded when unavailable, and which lifecycle
source was consulted. No inbound payload can add a candidate.

The observable proof builds a catalog for `architecture-practice-router`: the enabled
OpenTelemetry specialist is available; a disabled, paused, missing, or failed-load candidate
is excluded with a distinct reason; and the same declaration/lifecycle snapshot produces the
same catalog version. Before Meibo plan 23 lands, the result says `local-enabled`; after its
adapter is present it says `meibo` and honors active/paused/deactivated.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Prerequisite: `docs/plans/40-declare-specialist-expertise-and-router-policy.md` and `docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md` have landed; use `docs/plans/20-explicit-trigger-routing-scheduler-catch-up-policy-and-loud-failures.md`'s canonical load report if present.
- [ ] M1: define candidate, availability, exclusion, source, and catalog-version types.
- [ ] M1: resolve candidates only from the router's normalized `delegates` order.
- [ ] M2: add the local-enabled lifecycle adapter and the plan-23 Meibo adapter when its seam is available.
- [ ] M2: distinguish disabled, paused, deactivated, missing declaration, and failed-load exclusions.
- [ ] M3: compute a deterministic catalog version, redact content bodies, and add pure/stubbed tests.
- [ ] Final: `cabal test all` proves stable ordering, versions, source attribution, and exclusions.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The current loader returns one declaration at a time. Existing plans 20, 23, and 30 assign
  ownership of a canonical load report and fleet inspection; this plan must consume that
  artifact if it has landed rather than introduce a fourth directory scan.


## Decision Log

Record every decision made while working on the plan.

- Decision: Preserve the router's declared delegate order after rejecting duplicates.
  Rationale: Stable order makes model inputs, catalog versions, tests, and replay evidence
  deterministic without pretending that order grants priority.
  Date: 2026-07-25

- Decision: Represent unavailable candidates in the catalog with exclusion reasons instead
  of silently dropping them.
  Rationale: Operators need to distinguish semantic no-match from a candidate excluded by
  lifecycle or a broken declaration.
  Date: 2026-07-25

- Decision: Derive `CatalogVersion` with UUIDv5 over a canonical textual projection of the
  resolved entries and lifecycle-source version.
  Rationale: The repository already uses `Data.UUID.V5` for deterministic workflow ids; this
  needs stable identity, not a security digest, and therefore adds no dependency.
  Date: 2026-07-25


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

`docs/plans/40-declare-specialist-expertise-and-router-policy.md` adds expertise and
router policy to `AgentDecl`. Plan 35 adds the `delegates` allow-list. The declarations are
loaded by `shikigami-core/src/Shikigami/Agent/Loader.hs`; several runtime entry points
currently build lists independently, while plan 20 owns their eventual canonical load report.

Plan 33 adds an `enabled` Boolean. Plan 23 defines a cached Meibo directory view and a
`consultLifecycle` seam that distinguishes active, paused, deactivated, unknown, and
unavailable. This plan uses a small `LifecycleSource` record of functions so catalog logic is
independent of whether the current deployment has only local enablement or the Meibo-backed
view. A lifecycle source is an availability fact, not permission to use tools or sinks.

A "candidate catalog" is the exact data shown to a router behavior. It is a snapshot, not a
global registry. A "catalog version" identifies the normalized declarations and lifecycle
snapshot that produced it so the workflow can later prove which choices were possible.


## Plan of Work

Milestone 1 creates `Shikigami.Router.Catalog` in the package assigned by
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`
(under the current tree, `shikigami-core/src/Shikigami/Router/Catalog.hs`). Define strict domain types
for `CatalogVersion`, `LifecycleSourceVersion`, `CandidateAvailability`, `ExclusionReason`,
`CandidateEntry`, and `CandidateCatalog`. `buildCandidateCatalog` receives the already
validated router declaration, the canonical declaration/load report, and a lifecycle source.
It iterates only over `delegates`; payload data is not an argument. A missing or failed-load
declaration becomes an excluded entry. A resolved declaration contributes only name,
description, expertise, availability, and declaration identity; never behavior prompts,
changed documents, credentials, tool config, or sinks.

Milestone 2 defines adapters. `localEnabledLifecycleSource` maps plan 33's `enabled = True` to
available and `False` to `ExcludedDisabled`, with source name `local-enabled`; it does not use
the word Meibo. If plan 23 is complete, add `meiboLifecycleSource` over its cached
`DirectoryHandle`: active is available; paused and deactivated have distinct exclusions;
unknown and directory-unavailable remain exclusions. A last-known-valid snapshot uses the
source version of that snapshot. If plan 23 is not complete, keep the interface and stub tests
that exercise all states, record the Meibo adapter as remaining in Progress, and do not block
the local catalog slice.

Milestone 3 canonicalizes entries in declared order and renders all fields with unambiguous
length prefixes before deriving a UUIDv5 `CatalogVersion`. Include source name/version and
every availability/exclusion value so a lifecycle change changes the version. Add tests in
the plan-36 test package (or `shikigami-core/test/Shikigami/RouterCatalogSpec.hs` before the
restructure) for determinism, changes, redaction, and every exclusion. Add catalog attributes
to `Shikigami.Telemetry` only as bounded names/keys/reasons; do not log descriptions, aliases,
payloads, or source documents.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`.

```bash
sed -n '1,240p' docs/plans/40-declare-specialist-expertise-and-router-policy.md
sed -n '1,260p' docs/plans/23-agent-lifecycle-control-with-meibo-principals.md
sed -n '1,220p' shikigami-core/src/Shikigami/Agent/Loader.hs
```

After adding the module and tests:

```bash
nix develop -c fourmolu -i shikigami-core/src/Shikigami/Router/Catalog.hs
nix develop -c fourmolu -i shikigami-core/test/Shikigami/RouterCatalogSpec.hs
nix develop -c cabal test all
```

The focused test group should report cases equivalent to:

```text
router catalog: declared candidates only: OK
router catalog: lifecycle exclusions are explicit: OK
router catalog: identical snapshots have identical versions: OK
router catalog: changed lifecycle changes version: OK
router catalog: catalog output contains no behavior or payload body: OK
```


## Validation and Acceptance

Build a router whose declared delegates are OpenTelemetry reviewer, a disabled reviewer, a
missing name, and a manifest that failed to load. Give the OpenTelemetry reviewer one
expertise entry. The returned catalog must preserve those four names in declaration order,
mark exactly one available, and attach `disabled`, `missing-declaration`, and `load-failed`
reasons to the rest. Adding an undeclared `security-reviewer` to the trigger payload must not
change the catalog because the payload is not an input to `buildCandidateCatalog`.

Under the stubbed Meibo adapter, paused and deactivated candidates are excluded distinctly;
active is included; a source outage with a last-known snapshot produces the same catalog
version; a genuinely newer snapshot changes it. Under the local adapter, output states
`local-enabled` and never `meibo`. Rebuilding an identical catalog twice produces identical
JSON and `CatalogVersion`. `nix develop -c cabal test all` exits zero.


## Idempotence and Recovery

Catalog construction is pure apart from the lifecycle-source read and writes no state, so it
is safe to repeat. Tests use fixed source versions and do not depend on wall-clock time. If a
source refresh fails, return the plan-23 last-known snapshot exactly as supplied; do not mint
a new version for the failure. If implementation begins before plan 20 or 23 lands, isolate
adapters behind the named interface so their later arrival replaces an adapter rather than
the catalog algorithm.


## Interfaces and Dependencies

The core interface is:

```haskell
newtype CatalogVersion = CatalogVersion { value :: Text }

data ExclusionReason
  = Disabled
  | Paused
  | Deactivated
  | MissingDeclaration
  | LoadFailed !Text
  | UnknownPrincipal
  | LifecycleUnavailable

data CandidateAvailability
  = Available
  | Excluded !ExclusionReason

data CandidateEntry = CandidateEntry
  { name :: !Text
  , description :: !Text
  , expertise :: ![ExpertiseDecl]
  , availability :: !CandidateAvailability
  }

data CandidateCatalog = CandidateCatalog
  { router :: !Text
  , version :: !CatalogVersion
  , lifecycleSource :: !Text
  , lifecycleSourceVersion :: !Text
  , candidates :: ![CandidateEntry]
  }

data LifecycleSource = LifecycleSource
  { sourceName :: !Text
  , sourceVersion :: !(IO Text)
  , availabilityFor :: !(AgentDecl -> IO CandidateAvailability)
  }

buildCandidateCatalog
  :: LifecycleSource
  -> AgentLoadReport
  -> ValidatedRouterDeclaration
  -> IO CandidateCatalog
```

If plan 20 names its load-report type differently, use the landed type and update this plan.
Dependencies are the declaration types in
`docs/plans/40-declare-specialist-expertise-and-router-policy.md`, delegates from
`docs/plans/35-delegation-as-a-first-class-declared-capability.md`, the enabled field from
`docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md`, and optionally
the `DirectoryHandle` from `docs/plans/23-agent-lifecycle-control-with-meibo-principals.md`.
UUIDv5 comes from the already-declared `uuid` package.
No new network call is added to the routing hot path.
