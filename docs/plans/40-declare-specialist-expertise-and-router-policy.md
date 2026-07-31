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

- [ ] Prerequisites: `docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md`, `docs/plans/35-delegation-as-a-first-class-declared-capability.md`, and `docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md` have landed; use their final package paths and declaration fields.
- [ ] M1: add `Expertise`, routing-policy unions, and backward-compatible `expertise` / `routing` fields to `schema/Agent.dhall`.
- [ ] M2: mirror the types in Haskell and validate router-only invariants with bounded `Natural` conversion.
- [ ] M2: prove every existing manifest decodes with `expertise = []` and `routing = None`.
- [ ] M3: add router/specialist proof manifests and document authoring, authority boundaries, and diagnostics.
- [ ] Final: `cabal test all` and validation of both proof manifests succeed.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The checked-in schema currently stops at `name`, `description`, `trigger`, `behavior`, and
  `sinks`. Plans 33 and 35 describe additive fields but their Progress sections are unchecked,
  so implementation must re-read their final landed shapes rather than duplicating them.


## Decision Log

Record every decision made while working on the plan.

- Decision: Add `expertise : List Expertise` with default `[]` and
  `routing : Optional RouterPolicy` with default `None`.
  Rationale: These defaults make every ordinary agent byte-compatible and keep routing an
  explicit opt-in.
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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

`schema/Agent.dhall` is the canonical declaration. Its `Agent.Type` record is decoded by
`Shikigami.Agent.Loader.loadAgent` in
`shikigami-core/src/Shikigami/Agent/Loader.hs` into `AgentDecl` from
`shikigami-api/src/Shikigami/Api/Agent.hs`. The CLI command in
`shikigami-cli/src/Shikigami/Cli/Commands/Validate.hs` is the author-facing proof that Dhall
and Haskell agree.

Plan 33 adds general identity, memory, and `enabled` fields and establishes the repository's
additive schema-evolution pattern. Plan 35 adds `delegates` and `delegationBudget`. Read both
plans and their landed code before editing. This plan adds no delegation implementation.

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
`shikigami-api/src/Shikigami/Api/Agent.hs` with strict, direct field names, explicit deriving
strategies, and no type-name prefixes. Add a core validation module at the package path
assigned by `docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`, expected to be
`shikigami-core/src/Shikigami/Agent/Router/Declaration.hs`. Validation rejects an expertise
entry with an empty/duplicate normalized key, routing with no delegates, zero or more than 16
selections, `maxSelections` greater than the number of distinct delegates, and duplicate
delegate names. Use distinct `RoutingLow` / `RoutingMedium` / `RoutingHigh` constructors
because `Priority` already owns `Low` and `High` in this module; record fields remain direct
and unprefixed. Keep decode and semantic validation separate so diagnostics name the actual
invariant. Add focused unit tests and a regression test that loads every `.dhall` file except
the deliberate `agents/broken.dhall` fixture in
`shikigami-core/test/Shikigami/RouterDeclarationSpec.hs`, registering the module in the final
core test component.

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
nix develop -c fourmolu -i shikigami-api/src/Shikigami/Api/Agent.hs
nix develop -c fourmolu -i shikigami-core/src/Shikigami/Agent/Router/Declaration.hs
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
values. Semantic tests must prove empty and duplicate expertise keys, duplicate delegates,
router-without-delegates, zero/oversized selection bounds, and a selection bound larger than
the allow-list are rejected. An ordinary manifest whose payload later contains an `agent`
field must still have no routing authority because only declaration fields are inspected.

`nix develop -c cabal test all` must exit zero. The two `validate` commands above provide the
human-visible proof beyond compilation.


## Idempotence and Recovery

The change is additive and contains no data migration. Formatting, validation, and tests are
safe to repeat. If a proof manifest fails after a prerequisite plan changed the schema, update
its record completion against the landed `Agent.default`; do not add a second default or
duplicate a plan-35 field. If implementation stops after Dhall changes, Haskell compilation
will fail loudly until the mirror is updated; complete both sides in the same commit.


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 33 and 47. It is the first MasterPlan-8 child and reuses
plan 33's additive Dhall/Haskell declaration pattern. Keep policy closed, bounded, and backward
compatible through defaults; do not start runtime routing here.


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

The exact `AgentDecl` record also contains the fields landed by plans 33 and 35; this plan
adds `expertise :: ![ExpertiseDecl]` and `routing :: !(Maybe RouterPolicy)`. All records use
strict direct fields and the project's `DuplicateRecordFields` / Generic Lens convention.
Dependencies are Dhall decoding already used by `Shikigami.Agent.Loader`, the additive schema
pattern in `docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md`,
`delegates` from `docs/plans/35-delegation-as-a-first-class-declared-capability.md`, and final
package ownership from
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`. No new external
library or service is required.
