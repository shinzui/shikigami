---
id: 43
slug: define-architecture-practice-review-contracts
title: "Define architecture-practice review contracts"
kind: exec-plan
created_at: 2026-07-26T04:38:46Z
intention: "intention_01kyeb9heqecv8041cmwqwqg3q"
master_plan: "docs/masterplans/9-architecture-practice-review-flow.md"
---

# Define architecture-practice review contracts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami gains one versioned, machine-checked vocabulary for architecture-practice review
triggers, pinned evidence, five-way verdicts, applicability, and explicit human resolution.
A malformed or internally inconsistent model result cannot flow into memory or notification.
The same normalized trigger and practice selection deterministically produce the same review
id, while a changed target/reference revision produces a new review linked to the prior one.

The visible proof decodes deterministic JSON fixtures for all five classifications and all
four resolution outcomes, round-trips them without losing provenance, and rejects branch
names, missing hashes, impossible verdict/owner combinations, and a bare Kizashi
acknowledgement masquerading as resolution.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: define and round-trip version-1 trigger, project, revision-range, adoption, owner, and provenance types.
- [ ] M2: define the closed verdict, claim, confidence, applicability, lineage, and re-review types.
- [ ] M2: define explicit accepted/rejected/narrowed/superseded resolution commands.
- [ ] M3: add deterministic `ReviewId` derivation and semantic validators.
- [ ] M3: add valid/invalid golden fixtures and export the API module from the plan-36 API package.
- [ ] Final: API tests and `cabal test all` pass with no runtime/database dependency.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `shikigami-api` currently exports only Activity, Agent, and RunJob modules. The review
  contract can remain a client-safe types-only addition with `aeson`, `text`, `time`, and
  `uuid`; it does not need Kioku, Keiro, Hasql, or model dependencies.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use a closed `PracticeReviewClassification` with exactly the five request values.
  Rationale: Extra catch-all or success/error constructors would blur semantic review state
  with runtime failures and violate the improvement request.
  Date: 2026-07-25

- Decision: Put project name and Mori `repoId` beside the full 40-hex revision in every
  content reference.
  Rationale: Project names are readable and `repoId` is the C16 identity; neither can safely
  substitute for the other.
  Date: 2026-07-25

- Decision: Derive `ReviewId` with UUIDv5 over the validated trigger idempotency key,
  practice key, and specialist name; derive `ResolutionId` from review id plus the resolution
  command's own idempotency key.
  Rationale: Mori's trigger key already commits to watch, target revision/path, and reference
  revision set. Evidence revisions are not all available until acquisition, so re-hashing a
  partial duplicate identity in Shikigami would create a second source of truth.
  Date: 2026-07-25


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

`shikigami-api/src/Shikigami/Api/Activity.hs` demonstrates the current client-safe API style:
strict records, explicit JSON instances, and snake-case wire options where required.
`shikigami-api/src/Shikigami/Api/RunJob.hs` carries the untyped trigger payload into a durable
run. This plan adds `Shikigami.Api.PracticeReview` and leaves trigger transport unchanged;
the domain Flow decodes the payload at its boundary.

Kikan's C16 contract, captured in its plans 25, 28, and 29 and summarized in
`docs/improvement-requests/add-architecture-practice-review-flow.md`, defines a `RepoRef` as
Mori `repoId` plus a full immutable Git commit SHA. Each content read also carries a path,
content hash, and provenance stamp. A "claim" is one statement in the verdict. `Fact` means
the statement is directly supported by cited content; `Inference` means the specialist
reasoned from cited facts. "Applicability" is the bounded project/path/dependency/practice
scope within which a resolution may guide later reviews.

An agent verdict is provisional. A resolution is a separate command from an authorized human
or approved artifact workflow. Kizashi acknowledgement alone is attention state and is not a
truth-producing resolution.


## Plan of Work

Milestone 1 creates `shikigami-api/src/Shikigami/Api/PracticeReview.hs`. Define
`PracticeReviewTrigger` with `schemaVersion = 1`, trigger kind, stable idempotency key,
canonical target project/repository identity, before/head revisions, changed decision paths,
practice-adoption bindings, optional changed-reference range, and optional prior review id.
Each adoption binding carries a stable practice key, registered reference document ids,
claimed applicability, advisory mode, target/practice/triage owners, and registered upstream
projects. The trigger contains no specialist name or candidate list. Validate every content
revision as a full lowercase 40-hex SHA; before may be absent only for an added repository
object.

Milestone 2 defines the output. `PracticeReviewVerdict` carries schema version, deterministic
review id, practice, specialist, parent/child session and workflow lineage, target and
reference/upstream content references, claim-level evidence, confidence, routing rationale,
classification, recommended owner/action, re-review condition, and applicability. The five
classifications are exactly `consistent`, `target-suspect`, `reference-suspect`,
`legitimate-exception`, and `unresolved`. Define `PracticeReviewResolution` separately with a
deterministic resolution id and idempotency key, outcome `accepted`, `rejected`, `narrowed`,
or `superseded`, resolver principal, reason, resolved time, resulting applicability, and the
review being resolved.

Milestone 3 adds pure smart constructors/validators in the same API package or a companion
`Shikigami.Api.PracticeReview.Validation` module if
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`
permits it. Normalize keys and
paths, reject empty ids/statements/owners, validate content hashes and revision/path tuples,
ensure each claim cites existing evidence identities, and enforce classification invariants:
consistent has no recommended attention owner; target-suspect selects the target owner;
reference-suspect selects the practice owner; unresolved selects triage/both-owner
adjudication; legitimate-exception includes non-empty applicability and names an approver
only when approval is required. Suspect classifications require at least one cited material
claim. Add deterministic id derivation with `Data.UUID.V5`, golden fixtures under
`fixtures/practice-review/`, plus
`shikigami-api/test/Shikigami/Api/PracticeReviewSpec.hs` and a small
`shikigami-api/test/Main.hs`. Add a `shikigami-api-test` test suite to
`shikigami-api/shikigami-api.cabal` (or the exact API package paths produced by
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`).
Export the module from the final API Cabal component and re-export only if that plan's package
convention calls for it.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`.

```bash
sed -n '1,280p' docs/improvement-requests/add-architecture-practice-review-flow.md
sed -n '1,240p' shikigami-api/src/Shikigami/Api/Activity.hs
sed -n '1,220p' shikigami-api/src/Shikigami/Api/RunJob.hs
```

After authoring types and fixtures:

```bash
nix develop -c fourmolu -i shikigami-api/src/Shikigami/Api/PracticeReview.hs
nix develop -c cabal test shikigami-api:shikigami-api-test --test-show-details=direct
nix develop -c cabal test all
```

If `docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`
creates a separately named API test component, use its landed equivalent and
update this plan before implementation. The focused output must show five valid
classification fixtures, four valid resolution fixtures, stable review-id derivation, and
rejection of every invalid fixture.


## Validation and Acceptance

For each classification, decode a version-1 fixture, validate it, encode it, decode it again,
and compare the domain value. The reference-suspect fixture must cite a target dependency pin,
a registered practice excerpt, and compatible upstream content at full revisions, with at
least one inference claim and the practice owner. The unresolved fixture may report missing
required evidence but must not accuse an owner. The consistent fixture has no attention
owner. The legitimate-exception fixture has bounded applicability.

Invalid fixtures must cover a branch name used as revision, uppercase/short SHA, absent
content hash, claim referencing an unknown evidence id, target-suspect pointing at the
practice owner, consistent with a notification owner, empty exception scope, trigger naming a
specialist, unsupported schema version, and a Kizashi acknowledgement-shaped payload decoded
as a resolution. Reordering reference bindings while retaining Mori's normalized trigger
idempotency key must not change `ReviewId`; changing a material revision and therefore the
trigger key must. All API tests and `nix develop -c cabal test all` exit zero.


## Idempotence and Recovery

This plan changes only types, pure validation, and fixtures. It has no migration or external
write. Formatting and tests are safe to repeat. Golden files should be regenerated only by an
explicit repository script or reviewed patch; never silently bless a changed wire shape. If
the wire contract changes after implementation, add a new schema version and decoder path
rather than reinterpreting version 1 in place.


## Portfolio Reconciliation (2026-07-30)

This contract-only plan may start in parallel with the foundation chain, but any package
implementation/fixture build consumes plan 47's released cohort. Its wire types precede plans 44 and
45 and must remain judgment-free, versioned, bounded, and directly named under
`DuplicateRecordFields`.


## Interfaces and Dependencies

The module must expose at least these domain concepts (field lists above are normative even
if constructors are split for readability):

```haskell
newtype ReviewId = ReviewId { value :: Text }
newtype ResolutionId = ResolutionId { value :: Text }
newtype PracticeKey = PracticeKey { value :: Text }

data ClaimKind = Fact | Inference
data PracticeReviewClassification
  = Consistent
  | TargetSuspect
  | ReferenceSuspect
  | LegitimateException
  | Unresolved
data ResolutionOutcome = Accepted | Rejected | Narrowed | Superseded

deriveReviewId :: PracticeReviewTrigger -> PracticeKey -> Text -> ReviewId
deriveResolutionId :: ReviewId -> Text -> ResolutionId
validateTrigger :: PracticeReviewTrigger -> Either (NonEmpty ReviewContractError) ValidatedPracticeReviewTrigger
validateVerdict :: PracticeReviewVerdict -> Either (NonEmpty ReviewContractError) ValidatedPracticeReviewVerdict
validateResolution :: PracticeReviewResolution -> Either (NonEmpty ReviewContractError) ValidatedPracticeReviewResolution
```

All records use strict direct fields, `DuplicateRecordFields`, explicit deriving strategies,
and shared Aeson options. Dependencies are the existing `aeson`, `text`, `time`, and `uuid`
packages in `shikigami-api`; `mmzk-typeid` is not required unless the implementation chooses a
portfolio TypeID after verifying its source with Mori. This plan introduces no dependency on
Kioku, Keiro, Mori client code, or a model provider.
