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
its `delegates` allow-list. A uniquely resolved entry includes the specialist's description and
expertise; every entry says whether it is available, why it was excluded when unavailable, and
which lifecycle source was consulted. No inbound payload can add a candidate.

The observable proof builds a catalog for `architecture-practice-router`: the enabled
OpenTelemetry specialist is available; a disabled, paused, missing, or failed-load candidate
is represented honestly; and the same declaration/lifecycle snapshot produces the same catalog
version. A failed manifest whose agent name never decoded is not falsely attached to a delegate:
the missing delegate is excluded and the catalog carries only an unassociated load-failure
count. Explicit directory-disabled mode says `local-enabled`; the shipped file-backed
directory says `directory-file` and honors active/paused/deactivated without claiming a live
Meibo service call.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-23T14:41:54Z) Refreshed this plan against the delivered `AgentLoadReport`,
  file-backed `DirectoryHandle`, last-known-valid lifecycle policy, and six-package layout.
- [x] (2026-08-23T14:41:54Z) External prerequisites verified: plans 23, 33, 35, 36, and 47
  have landed. Only child plan 40 remains as the hard prerequisite.
- [x] (2026-08-23T19:28:46Z) Prerequisite:
  `docs/plans/40-declare-specialist-expertise-and-router-policy.md` has landed.
- [x] (2026-08-23T19:28:46Z) M1: added the read-once immutable directory
  snapshot, explicit source-kind attribution, and content-derived snapshot version; 15 focused
  directory tests pass.
- [x] (2026-08-23T19:37:35Z) M1: defined candidate, availability, exclusion,
  load-failure-count, and catalog-version types.
- [x] (2026-08-23T19:37:35Z) M1: resolve candidates only from the router's
  validated `delegates` order using the exact names enforced by plan 35.
- [x] (2026-08-23T19:37:35Z) M2: read one directory snapshot, then distinguish
  duplicate declaration, disabled, paused, deactivated, unknown principal, unavailable directory,
  and explicit directory-disabled compatibility mode.
- [x] (2026-08-23T19:37:35Z) M2: keep missing candidates distinct from the
  unassociated manifest-load count; never infer an agent identity from a failed file.
- [x] (2026-08-23T19:37:35Z) M3: compute a deterministic catalog version,
  redact content bodies, and add pure/stubbed tests; all eight focused router-catalog cases pass.
- [x] (2026-08-23T19:40:11Z) Final: `nix develop -c cabal test all` passes
  every package, including 482 core tests and all catalog cases.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `Shikigami.Agent.Loader.AgentLoadReport` has landed and preserves loaded and failed entries
  in filename order. A failed entry contains only its path and diagnostic because Dhall did not
  produce a trustworthy `AgentDecl`; there is no sound way to decide which missing delegate
  name that file intended to define.
- The same report does not enforce unique decoded agent names. Catalog lookup must group loaded
  entries by exact name and exclude a duplicate group rather than selecting whichever file
  happened to sort first.
- `DirectoryHandle` already publishes complete `DirectoryView` values atomically and retains
  the last valid snapshot on refresh failure. Its public `consultLifecycle` and
  `lookupPrincipal` operations each read the handle independently, however, and
  `directoryPrincipals` does not expose mode or a semantic version. Calling once per candidate
  could mix generations if a refresh lands midway through catalog construction.
- `loadedAt` is intentionally private and must not become the catalog source version. A refresh
  of identical principal contents changes the timestamp without changing which specialists are
  available.
- The existing configured-handle constructor is used by both file-backed production composition
  and static tests. Keeping source attribution inside the private handle let the additive API
  preserve those callers while preventing a catalog caller from choosing a source label.
- Full-suite evidence after implementation is 482 passing core tests, plus passing conformance,
  migration, agent, API, client, worker, and server suites. The focused additions are eight router
  catalog cases and three new directory-snapshot cases.


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

- Decision: Export one immutable `DirectorySnapshot` read operation and build every candidate
  against that value rather than calling `consultLifecycle` repeatedly.
  Rationale: the handle is atomically refreshed, but repeated reads can still observe different
  complete generations. A catalog is one decision input and must represent one generation.
  Date: 2026-08-23

- Decision: Version the semantic snapshot contents and source kind, not `loadedAt` or the most
  recent refresh error.
  Rationale: reloading identical policy and retaining a last-known-valid view after a source
  failure must preserve the same catalog version.
  Date: 2026-08-23

- Decision: Do not correlate a missing delegate with a failed manifest unless the load report
  provides a decoded identity.
  Rationale: the delivered failure entry contains only a path and diagnostic. Filename inference
  would fabricate authority because filenames are not the agent-name contract.
  Date: 2026-08-23

- Decision: Put only an unassociated failure count in the catalog; retain paths and diagnostics
  in the canonical load report and operator surfaces.
  Rationale: failures remain visible without exposing source paths or Dhall diagnostics to a
  model-facing routing input or pretending they describe a particular candidate.
  Date: 2026-08-23

- Decision: Exclude a candidate resolved by zero declarations as `MissingDeclaration` and one
  resolved by multiple declarations as `DuplicateDeclaration`.
  Rationale: file order is deterministic but is not authority to choose between two manifests
  claiming the same delegation target.
  Date: 2026-08-23

- Decision: Store configured source attribution inside the private `DirectoryHandle`; preserve
  the existing `newDirectoryHandle` test/adapter API by assigning its only currently shipped
  configured kind, `DirectoryFileSource`.
  Rationale: a catalog caller cannot relabel a handle, while existing lifecycle tests and adapters
  remain source-compatible. A future typed client must construct its distinct kind at the
  directory composition boundary.
  Date: 2026-08-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

This child plan is complete. `Shikigami.Directory` now supplies one immutable, honestly attributed
snapshot with a semantic version, and `Shikigami.Router.Catalog` resolves only a validated router's
declared delegates against that value and one `AgentLoadReport`. Missing declarations, duplicate
names, disabled agents, paused/deactivated principals, unknown principals, and directory
unavailability remain distinct typed exclusions. Broken manifests contribute a count without paths,
diagnostics, or fabricated identities.

Catalog JSON contains bounded specialist metadata and availability, not behavior bodies, trigger
payloads, credentials, tools, profiles, overlays, sinks, or loader diagnostics. Equal semantic inputs
produce equal JSON and UUIDv5 versions; metadata, lifecycle, source, ordering, or failure-count
changes move the version. Eight focused router-catalog cases, fifteen directory cases, 482 core tests,
and every other package suite pass. Durable catalog authority, snapshot, redaction, and versioning
rules are distilled in
[ADR 0028](../adr/0028-a-router-catalog-is-a-bounded-snapshot-of-declared-authority.md). EP-3 can
now journal and consume the catalog without rereading declarations or lifecycle state.


## Context and Orientation

`docs/plans/40-declare-specialist-expertise-and-router-policy.md` adds expertise and
router policy to `AgentDecl`. Plan 35 adds the `delegates` allow-list. The declarations are
loaded once by `shikigami-core/src/Shikigami/Agent/Loader.hs` into the delivered
`AgentLoadReport`. Its `AgentLoaded` entries carry a declaration and path; `AgentLoadFailed`
entries carry a path and `LoadError`. This plan consumes that report and introduces no second
directory traversal.

Plan 33 delivered the `enabled` Boolean. Plan 23 delivered
`shikigami-core/src/Shikigami/Directory.hs`: `DirectoryDisabled` is explicit compatibility
mode, while configured file mode requires one valid snapshot, publishes replacements
atomically, retains the last valid view after refresh failure, and distinguishes active,
paused, deactivated, unknown, and unavailable. The relevant durable decision is
`docs/adr/0024-a-configured-principal-directory-fails-closed-to-its-last-valid-snapshot.md`.
This plan adds a read-only snapshot projection; it does not weaken that policy or add network IO.
A lifecycle source is an availability fact, not permission to use tools, sinks, or delegation.

A "candidate catalog" is the exact data shown to a router behavior. It is a snapshot, not a
global registry. A "catalog version" identifies the normalized declarations and lifecycle
snapshot that produced it so the workflow can later prove which choices were possible.


## Plan of Work

Milestone 1 creates `shikigami-core/src/Shikigami/Router/Catalog.hs`. Define strict domain
types for `CatalogVersion`, `CandidateAvailability`, `ExclusionReason`, `CandidateEntry`, and
`CandidateCatalog`. Add an immutable public projection to
`shikigami-core/src/Shikigami/Directory.hs`, which owns `DirectorySnapshotVersion`,
`DirectorySourceKind`, and `DirectorySnapshot`: one `readDirectorySnapshot` call returns
disabled, configured-valid, or configured-unavailable state plus the complete normalized
principals and a content-derived version. Carry `DirectorySourceKind` from the same validated
`DirectorySettings` value that constructs `DirectoryRuntime`; do not let a routing caller guess
whether a handle came from file mode or a future client. Do not export `DirectoryView` internals
or its `IORef`.

`buildCandidateCatalog` receives the validated router declaration, `AgentLoadReport`, and one
already-read `DirectorySnapshot`. It iterates only over `delegates`; payload data is not an
argument. Group loaded entries by exact declaration name, matching plan 35's allow-list check. A delegate with no loaded
declaration is `MissingDeclaration`; one with multiple loaded declarations is
`DuplicateDeclaration`; neither receives a fabricated description. Failed report entries
contribute only an unassociated count, with no paths, diagnostics, or invented candidate
association. A uniquely resolved declaration contributes only name, description, expertise,
declared identity, enabled state, and availability; never behavior prompts, changed documents,
credentials, tool configuration, capability overlays, sanctioned profiles, or sinks.

Milestone 2 applies policy to that immutable value. `enabled = False` always produces
`Excluded Disabled` before principal lookup. In `DirectoryDisabledSnapshot`, an enabled agent
is available and the source is `DirectoryDisabledSource`, rendered as `local-enabled`; this is
compatibility mode, not verification. In `DirectoryConfiguredSnapshot`, join by authoritative
`identity.principal` when present and by the normalized declaration name only when absent,
matching `consultLifecycle`: active is available;
paused and deactivated have distinct exclusions; a miss is `UnknownPrincipal`. A configured
snapshot that has never produced a valid view is `LifecycleUnavailable`. Attribute the shipped
configured source as `DirectoryFileSource`; reserve `MeiboClientSource` for a future typed
transport that implements the same snapshot contract.

Milestone 3 canonicalizes entries in declared order and renders all fields with unambiguous
length prefixes before deriving a UUIDv5 `CatalogVersion`. Include source name/version and
every availability/exclusion value plus the unassociated failure count, so any model-visible
catalog change changes the version. Add tests in
`shikigami-core/test/Shikigami/RouterCatalogSpec.hs` for determinism, atomic snapshot use,
changes, the load-failure count, redaction, and every exclusion. Catalog construction itself emits
no telemetry; EP-3 owns trace attributes after the catalog is journaled. Raw descriptions,
aliases, payloads, behavior definitions, source documents, and full Dhall diagnostics never
enter trace attributes.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`.

```bash
sed -n '1,240p' docs/plans/40-declare-specialist-expertise-and-router-policy.md
sed -n '1,260p' docs/plans/23-agent-lifecycle-control-with-meibo-principals.md
sed -n '1,220p' shikigami-core/src/Shikigami/Agent/Loader.hs
sed -n '1,330p' shikigami-core/src/Shikigami/Directory.hs
```

After adding the module and tests:

```bash
nix develop -c fourmolu -i shikigami-core/src/Shikigami/Router/Catalog.hs
nix develop -c fourmolu -i shikigami-core/src/Shikigami/Directory.hs
nix develop -c fourmolu -i shikigami-core/test/Shikigami/RouterCatalogSpec.hs
nix develop -c cabal test shikigami-core-test --test-options='-p "router catalog"' --test-show-details=direct
nix develop -c cabal test all
```

The focused test group should report cases equivalent to:

```text
router catalog: declared candidates only: OK
router catalog: one immutable lifecycle snapshot: OK
router catalog: lifecycle exclusions are explicit: OK
router catalog: duplicate declaration names fail closed: OK
router catalog: failed manifests contribute only an unassociated count: OK
router catalog: identical snapshots have identical versions: OK
router catalog: changed lifecycle changes version: OK
router catalog: catalog output contains no behavior or payload body: OK
```


## Validation and Acceptance

Build a router whose declared delegates are an OpenTelemetry reviewer, a disabled reviewer,
a duplicate-name reviewer, and a missing name. Include a separate manifest that failed to
load. Give the OpenTelemetry reviewer one expertise entry. The returned catalog must preserve
the four declared names in order, mark exactly one available, attach `disabled`,
`duplicate-declaration`, and `missing-declaration` to the other three, and report one
unassociated load failure without carrying its path or diagnostic. Adding an undeclared
`security-reviewer` to the trigger payload must not change the catalog because the payload is
not an input to `buildCandidateCatalog`.

Under a fixed configured directory snapshot, paused and deactivated candidates are excluded
distinctly and active is included. A refresh failure that retains the last valid contents
produces the same snapshot and catalog versions; a genuine lifecycle-content change changes
both. Refreshing identical contents at a later `loadedAt` does not. Under explicit disabled
mode, output states `local-enabled`; configured file mode states `directory-file`; neither says
`meibo-client`. A test that swaps the handle after `readDirectorySnapshot` proves the in-flight
catalog continues to use the captured value. Rebuilding identical inputs twice produces
identical JSON and `CatalogVersion`. `nix develop -c cabal test all` exits zero.


## Idempotence and Recovery

Reading a snapshot and constructing a catalog write no state and are safe to repeat. Tests use
fixed semantic contents and do not derive versions from wall-clock time. A source refresh
failure leaves the plan-23 last-known snapshot exactly as supplied; do not mint a new version
for the error. If the snapshot projection is implemented before the catalog, existing lifecycle
callers remain unchanged because the new API is additive.


## Portfolio Reconciliation (2026-08-23)

Plans 23, 33, 35, 36, and 47 are complete. This plan now hard-depends only on child plan 40.
It consumes the delivered load report and cached directory directly. Explicit disabled mode
is `local-enabled`; the delivered configured source is `directory-file`; no current code path
is labeled as a live Meibo client.


## Interfaces and Dependencies

The core interface is:

```haskell
newtype CatalogVersion = CatalogVersion { value :: Text }

data ExclusionReason
  = Disabled
  | Paused
  | Deactivated
  | MissingDeclaration
  | DuplicateDeclaration
  | UnknownPrincipal
  | LifecycleUnavailable

data CandidateAvailability
  = Available
  | Excluded !ExclusionReason

data CandidateEntry = CandidateEntry
  { name :: !Text
  , description :: !(Maybe Text)
  , expertise :: ![ExpertiseDecl]
  , availability :: !CandidateAvailability
  }

data CandidateCatalog = CandidateCatalog
  { router :: !Text
  , version :: !CatalogVersion
  , lifecycleSource :: !DirectorySourceKind
  , lifecycleSourceVersion :: !DirectorySnapshotVersion
  , candidates :: ![CandidateEntry]
  , unassociatedLoadFailures :: !Natural
  }

data DirectorySourceKind
  = DirectoryDisabledSource
  | DirectoryFileSource
  | MeiboClientSource

data DirectorySnapshot
  = DirectoryDisabledSnapshot
      { version :: !DirectorySnapshotVersion
      }
  | DirectoryConfiguredSnapshot
      { source :: !DirectorySourceKind
      , version :: !DirectorySnapshotVersion
      , principals :: ![PrincipalRecord]
      }
  | DirectoryUnavailableSnapshot
      { source :: !DirectorySourceKind
      , version :: !DirectorySnapshotVersion
      }

buildCandidateCatalog
  :: AgentLoadReport
  -> DirectorySnapshot
  -> ValidatedRouterDeclaration
  -> CandidateCatalog
```

Dependencies are the declaration types in
`docs/plans/40-declare-specialist-expertise-and-router-policy.md`, delegates from
`docs/plans/35-delegation-as-a-first-class-declared-capability.md`, the enabled field from
`docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md`, and the
`DirectoryHandle` from `docs/plans/23-agent-lifecycle-control-with-meibo-principals.md`.
`DirectoryRuntime` supplies the handle and validated source kind used by the additive snapshot
reader; production never labels a handle independently at the call site. UUIDv5 comes from the
already-declared `uuid` package.
No new network call is added to the routing hot path.


## Revision Notes

- 2026-08-23: Replaced the pre-plan-23 adapter design with the delivered load-report and
  cached-directory APIs. Added a read-once immutable snapshot boundary, semantic content
  versioning, honest file/disabled source attribution, and an unassociated failed-manifest
  count; removed the unsound assumption that a failed Dhall file has a decoded agent
  name.
- 2026-08-23: Completed all milestones with immutable directory snapshots, pure delegate-bounded
  catalog resolution, typed exclusions, deterministic semantic versions, redacted JSON, focused
  tests, full-suite validation, and ADR 0028 distillation.
