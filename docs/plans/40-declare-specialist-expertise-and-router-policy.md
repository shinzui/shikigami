---
id: 40
slug: declare-specialist-expertise-and-router-policy
title: "Declare specialist expertise and router policy"
kind: exec-plan
created_at: 2026-07-26T04:38:46Z
intention: "intention_01kyeb9j20e8prwv62v7mzp574"
master_plan: "docs/masterplans/8-declarative-router-agents.md"
---

# Declare specialist expertise and router policy

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

An agent author can describe a specialist's expertise and mark another agent as a bounded
router without changing any existing manifest. The declaration says what a specialist knows;
it does not grant tools, sinks, or permission to run. A router policy applies only to the
`delegates` allow-list introduced by
`docs/plans/35-delegation-as-a-first-class-declared-capability.md`.

The behavior is visible through `shikigami validate`: the new
`agents/proof/architecture-practice-router.dhall` and
`agents/proof/opentelemetry-practice-reviewer.dhall` print their decoded expertise and
policy, invalid bounds fail with a specific diagnostic, and every pre-existing declaration
under `agents/` still validates unchanged.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-23T14:41:54Z) Refreshed this plan against the delivered six-package tree,
  governed delegation, manual `AgentDecl` journal codec, current proof-manifest tests, and
  Keiro 0.14 dependency cohort.
- [x] (2026-08-23T14:41:54Z) Prerequisites verified: plans 33, 35, 36, 39, and 47 have
  landed. The implementation can begin in `shikigami-core` without waiting on another plan.
- [x] (2026-08-23T19:00:21Z) Reconciled the declaration work with the imminent first release:
  keep Dhall manifest defaults, remove the pre-release JSON compatibility shim, and establish
  one complete v1 declaration object under ADR 0027.
- [ ] M1: add `Expertise`, routing-policy unions, and manifest-compatible `expertise` / `routing` fields to `schema/Agent.dhall`.
- [ ] M2: mirror the types in `Shikigami.Agent.Decl`, establish one complete v1 JSON shape, and validate router-only invariants with bounded `Natural` conversion.
- [ ] M2: prove every existing Dhall manifest decodes with `expertise = []` and `routing = None`, while the v1 JSON object encodes every declaration field explicitly.
- [ ] M3: add router/specialist proof manifests and document authoring, authority boundaries, and diagnostics.
- [ ] Final: `cabal test all` and validation of both proof manifests succeed.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The checked-in schema now includes `delegates`, `delegationBudget`, `sanctionedProfile`,
  `capabilityOverlays`, `identity`, `memory`, and `enabled`. The Haskell mirror moved from the
  deleted `Shikigami.Api.Agent` module to `Shikigami.Agent.Decl` in `shikigami-core`.
- `AgentDecl` is journaled by the durable `lookup-agent` step, but Shikigami has no users,
  stored journals, queued declarations, or external wire consumers before its imminent first
  release. The current hand-written omission/missing-key codec protects an empty pre-release
  population. This plan removes that shim and establishes one complete derived v1 JSON shape;
  after release, that complete shape becomes the compatibility baseline.


## Decision Log

Record every decision made while working on the plan.

- Decision: Add `expertise : List Expertise` with default `[]` and
  `routing : Optional RouterPolicy` with default `None`.
  Rationale: These defaults keep every checked-in Dhall manifest source-compatible and keep
  routing an explicit opt-in.
  Date: 2026-07-25

- Decision: Keep `delegates` as the sole candidate authority and reject a router policy on an
  empty allow-list.
  Rationale: Plan 35 already owns delegation authorization; accepting a second candidate list
  would create conflicting sources of authority.
  Date: 2026-07-25

- Decision: Validate `maxSelections` into a bounded positive domain value before converting
  Dhall `Natural` to `Int`.
  Rationale: Unbounded Naturals can overflow or admit resource-exhausting fan-out. A limit of
  1 through 16 is enough for the requested local routers and remains below the durable budget.
  Date: 2026-07-25

- Decision: Put router declaration validation in `Shikigami.Router.Declaration` and keep the
  schema mirror in `Shikigami.Agent.Decl`.
  Rationale: the delivered package architecture puts agent domain types in `shikigami-core`,
  while router-only semantic validation is a separate functional concern consumed by the
  catalog and routing plans.
  Date: 2026-08-23

- Decision: Extend the manual `AgentDecl` JSON codec so default expertise and routing values
  preserve historical journal bytes and missing keys restore those defaults.
  Status: Superseded on 2026-08-23 by the clean-v1 decision below.
  Rationale: `lookup-agent` values outlive the binary; source-compatible Dhall defaults do not
  make old JSON journal records decode or keep unchanged declarations byte-compatible.
  Date: 2026-08-23

- Decision: Remove the pre-release `AgentDecl` omission/missing-key codec and derive one complete
  v1 JSON object containing every declaration field, including default values.
  Rationale: Shikigami has no users or durable/external values encoded under the earlier shape,
  and its first release is imminent. Carrying a compatibility shim into v1 would create debt for
  an empty population. Dhall defaults continue to protect repository source manifests; the full
  v1 JSON object becomes the durable baseline after release under ADR 0027.
  Date: 2026-08-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

`schema/Agent.dhall` is the canonical declaration. Its `Agent.Type` record is decoded by
`Shikigami.Agent.Loader.loadAgent` in
`shikigami-core/src/Shikigami/Agent/Loader.hs` into `AgentDecl` from
`shikigami-core/src/Shikigami/Agent/Decl.hs`. The CLI command in
`shikigami-server/src/Shikigami/Server/Command/Validate.hs` is the author-facing proof that
Dhall and Haskell agree. Existing declaration and compatibility tests live in
`shikigami-core/test/Shikigami/AgentLoaderSpec.hs` and
`shikigami-core/test/Shikigami/WireCompatSpec.hs`.

Plan 33 adds general identity, memory, and `enabled` fields and establishes the repository's
additive schema-evolution pattern. Plan 35 adds `delegates` and `delegationBudget`. Read both
plans and their landed code before editing. Plan 50 and the capability-overlay MasterPlan have
also added `sanctionedProfile` and `capabilityOverlays`; preserve all of these fields. This plan
adds no delegation implementation.

The relevant durable decisions are
`docs/adr/0027-the-first-release-establishes-one-clean-durable-baseline.md`, which requires one
complete pre-release declaration shape without compatibility paths for nonexistent data;
`docs/adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md`, which governs
future changes after v1; and
`docs/adr/0023-delegation-is-governed-at-the-child-spawn-boundary.md`, which makes `delegates`
the authority boundary this routing metadata must not replace.

"Expertise" means routing metadata: a stable key such as `opentelemetry`, a plain-language
description, aliases, and optional evidence hints. A "router policy" bounds semantic
selection and defines what a behavior returns when it cannot make one confident selection.
Neither concept is an authorization grant.


## Plan of Work

Milestone 1 adds the declaration vocabulary. In `schema/Agent.dhall`, define `Expertise`,
`RouterConfidence` (`RoutingLow | RoutingMedium | RoutingHigh`), `NoMatchPolicy`,
`AmbiguousPolicy`, and `RouterPolicy` next to the other
shared declaration types. Add `expertise` and `routing` to `Agent.Type`; extend `Agent.default`
with empty/absent values. Do not repeat or rename plan 35's `delegates`. Export every new
Dhall type from the schema record. At the end, an old manifest imports the new schema without
editing its body.

Milestone 2 mirrors the declaration in
`shikigami-core/src/Shikigami/Agent/Decl.hs` with strict, direct field names, explicit deriving
strategies, and no type-name prefixes. Remove the existing hand-written `ToJSON` and `FromJSON`
instances and derive both classes for `AgentDecl`, producing one complete v1 object whose keys
include default-valued `delegates`, `delegationBudget`, `sanctionedProfile`,
`capabilityOverlays`, `identity`, `memory`, `enabled`, `expertise`, and `routing`. Add
`shikigami-core/src/Shikigami/Router/Declaration.hs`. Validation rejects an expertise
entry with an empty/duplicate normalized key, routing with no delegates, zero or more than 16
selections, `maxSelections` greater than the number of distinct delegates, and duplicate
delegate names. Use distinct `RoutingLow` / `RoutingMedium` / `RoutingHigh` constructors
because `Priority` already owns `Low` and `High` in this module; record fields remain direct
and unprefixed. Keep Dhall/JSON decoding and semantic validation separate so diagnostics name
the actual invariant. Add focused tests in
`shikigami-core/test/Shikigami/RouterDeclarationSpec.hs`; extend
`shikigami-core/test/Shikigami/AgentLoaderSpec.hs` with default/non-default complete-v1 JSON cases and
the existing all-manifest regression. Register the new module in `shikigami-core-test`.

Milestone 3 adds `agents/proof/architecture-practice-router.dhall` with routing enabled and
`agents/proof/opentelemetry-practice-reviewer.dhall` with one expertise entry. Update
`docs/user/writing-agents.md` (created by plan 33 if it does not yet exist) with field shapes,
defaults, the distinction between metadata and authority, the reliance on `delegates`, and
examples of validation errors. The proof router uses `maxSelections = 2`, medium minimum
confidence, typed no-match/ambiguous policies, and no inbound candidate list.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/shikigami`.

First inspect prerequisite progress and the final schema before editing:

```bash
sed -n '1,220p' docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md
sed -n '1,240p' docs/plans/35-delegation-as-a-first-class-declared-capability.md
sed -n '1,240p' schema/Agent.dhall
```

Format and test inside the repository development environment:

```bash
nix develop -c fourmolu -i shikigami-core/src/Shikigami/Agent/Decl.hs
nix develop -c fourmolu -i shikigami-core/src/Shikigami/Router/Declaration.hs
nix develop -c fourmolu -i shikigami-core/test/Shikigami/RouterDeclarationSpec.hs
nix develop -c cabal test shikigami-core-test --test-options='-p "router"' --test-show-details=direct
nix develop -c cabal test all
```

Exercise the declarations directly:

```bash
nix develop -c cabal run shikigami -- validate agents/proof/architecture-practice-router.dhall
nix develop -c cabal run shikigami -- validate agents/proof/opentelemetry-practice-reviewer.dhall
```

Both commands exit zero and print the decoded expertise/routing values. A test fixture with
`maxSelections = 0` exits non-zero with a diagnostic containing `maxSelections must be between
1 and 16`.


## Validation and Acceptance

Acceptance requires all existing valid manifests to load unchanged and decode to empty
expertise/no router policy. The two proof manifests must load with their exact declared
values. A default declaration must encode every v1 field, decode back to the same value, and
the resulting complete object becomes the checked first-release fixture. Non-default
expertise/routing must round-trip.
Semantic tests must prove empty and duplicate expertise keys, duplicate delegates,
router-without-delegates, zero/oversized selection bounds, and a selection bound larger than
the allow-list are rejected. An ordinary manifest whose payload later contains an `agent`
field must still have no routing authority because only declaration fields are inspected.

`nix develop -c cabal test all` must exit zero. The two `validate` commands above provide the
human-visible proof beyond compilation.


## Idempotence and Recovery

The change is additive and contains no database migration. Formatting, validation, and tests
are safe to repeat. If a proof manifest fails, update its record completion against the current
`Agent.default`; do not add a second default or duplicate any delivered field. If implementation
stops after Dhall changes, Haskell compilation will fail until the mirror is updated. Complete
the Dhall mirror, complete v1 JSON derivation, and declaration tests in the same commit so the
first release exposes only one coherent declaration shape.


## Portfolio Reconciliation (2026-08-23)

Plans 33, 35, 36, 39, and 47 are complete, so this first MasterPlan-8 child is ready to
implement. Reuse plan 33's Dhall declaration pattern, preserve plan 35's governed `delegates`
authority, and target the delivered `Shikigami.Agent.Decl` module. Keep
policy closed, bounded, and source-compatible through Dhall defaults; replace the pre-release
manual JSON pattern with the complete v1 shape, and do not start runtime routing
here.


## Interfaces and Dependencies

The final declaration surface is conceptually:

```haskell
data ExpertiseDecl = ExpertiseDecl
  { key :: !Text
  , description :: !Text
  , aliases :: ![Text]
  , evidenceHints :: ![Text]
  }

data RouterConfidence = RoutingLow | RoutingMedium | RoutingHigh
data NoMatchPolicy = ReturnNoMatch | ReturnUnresolved
data AmbiguousPolicy = ReturnAmbiguous | SelectAllWithinBound

data RouterPolicy = RouterPolicy
  { maxSelections :: !Natural
  , minimumConfidence :: !RouterConfidence
  , onNoMatch :: !NoMatchPolicy
  , onAmbiguous :: !AmbiguousPolicy
  }

validateRouterDeclaration
  :: AgentDecl
  -> Either [RouterDeclarationError] ValidatedRouterDeclaration
```

The exact `AgentDecl` record also contains `delegates`, `delegationBudget`,
`sanctionedProfile`, `capabilityOverlays`, `identity`, `memory`, and `enabled`; this plan adds
`expertise :: ![ExpertiseDecl]` and `routing :: !(Maybe RouterPolicy)`. All records use strict
direct fields and the project's `DuplicateRecordFields` / Generic Lens convention. Its derived
JSON codec writes all fields as the complete v1 durable shape; future post-release additions
follow ADR 0011 rather than silently changing that baseline.
Dependencies are Dhall decoding already used by `Shikigami.Agent.Loader`, the additive schema
pattern in `docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md`,
`delegates` from `docs/plans/35-delegation-as-a-first-class-declared-capability.md`, and final
package ownership from
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`. No new external
library or service is required.


## Revision Notes

- 2026-08-23: Refreshed the plan after its external foundations landed. Corrected package and
  command paths, incorporated the manual `AgentDecl` journal codec and relevant ADRs, updated
  tests and commands, and marked the declaration child ready to implement.
- 2026-08-23: Reconciled the plan with the imminent first release and confirmed absence of users
  or durable/external declaration values. Replaced the planned extension of a pre-release
  compatibility shim with one complete v1 JSON shape, retained Dhall defaults for checked-in
  manifests, and adopted ADR 0027 as the release boundary.
