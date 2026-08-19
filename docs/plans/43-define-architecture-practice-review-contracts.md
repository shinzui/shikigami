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

- [x] (2026-08-19T21:43:33Z) Preflight: reconcile this July plan with the current seven-package tree, shared attestation vocabulary, ADR corpus, core test layout, and released `uuid` dependency.
- [x] (2026-08-19T21:52:41Z) M1: define and round-trip shared repository identity plus version-1 trigger, revision-range, adoption, owner, and provenance types.
- [x] (2026-08-19T21:57:24Z) M2: define the closed verdict, claim, confidence, applicability, lineage, and re-review types.
- [x] (2026-08-19T21:57:24Z) M2: define explicit accepted/rejected/narrowed/superseded resolution commands.
- [ ] M3: add deterministic `ReviewId` derivation and semantic validators.
- [ ] M3: add valid/invalid golden fixtures and export the contract from `shikigami-core`.
- [ ] Final: focused core tests, package-architecture tests, and `cabal test all` pass with no runtime/database dependency.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The July plan expected `shikigami-api` to export Activity, Agent, and RunJob modules and
  host this contract. That package shape no longer exists.

- The first sentence above is historical rather than current: plan 36 reduced
  `shikigami-api` to public HTTP route/problem modules, while the worker-reachable domain
  vocabulary lives in `shikigami-core`. Evidence: `docs/architecture/packages.md` and
  `shikigami-core/test/Shikigami/PackageArchitectureSpec.hs` enforce that workers cannot
  depend on `shikigami-api`.

- Plan 49 has already introduced temporary `RepositoryId` and `Revision` definitions in
  `Shikigami.Attestation.Reviewed`, and no other production module consumes them yet. This
  plan can now establish their neutral home without a compatibility migration; the
  attestation module can import and re-export the shared names.

- The repository instruction for record conventions moved from
  `core/record-patterns.md` to `patterns/core/record-patterns.md`. Mori identifies it as
  `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`; the current document still
  requires direct strict fields, explicit deriving strategies, and per-module generic-lens
  imports only when `#field` is actually used.

- The existing `shikigami-core-test` suite is the correct fixture/test component; a new
  `shikigami-api-test` suite would duplicate infrastructure and violate the current package
  boundary.

- `uuid` is already a direct `shikigami-core` dependency. Mori located the source at
  `mori://haskell-hvr/uuid/packages/uuid`; Hackage and the upstream `uuid-1.3.16.1` tag both
  identify 1.3.16.1 as the current release, whose `Data.UUID.V5.generateNamed` API accepts a
  namespace UUID and name bytes.

- The ADR corpus is an unprofiled filesystem corpus; `mori show --full` reports no
  `docs/adr` OKF bundle. No existing ADR governs this practice-review wire contract. ADR
  0003 explains the current package split, while ADRs 0005 and 0006 are adjacent attestation
  decisions rather than authority for this contract.

- Aeson's generic options do not encode a one-constructor nullary type as a string unless
  `tagSingleConstructors = True`, even when `allNullaryToStringTag = True`. The first fixture
  run rejected `"advisory"` with `expected Array`; enabling single-constructor tagging made
  `ReviewMode` use the same closed-string wire shape as the other enums.


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

- Decision: Implement the public contract as `Shikigami.PracticeReview` in
  `shikigami-core`, with focused internal type/validation modules only if the implementation
  needs them; do not add an HTTP DTO or a second test suite.
  Rationale: The current package architecture places worker-reachable domain concepts in
  core and reserves `shikigami-api` for served HTTP contracts.
  Date: 2026-08-19

- Decision: Move the neutral repository vocabulary into `Shikigami.Repository` now and
  have `Shikigami.Attestation.Reviewed` import and re-export it.
  Rationale: Repository identity, strict 40-hex Mori content revisions, `RepoRef`, and safe
  relative paths are shared by practice review, evidence acquisition, and attestation; the
  current attestation-local definitions explicitly describe themselves as temporary and
  have no production consumers outside that module.
  Date: 2026-08-19

- Decision: Keep Mori content-plane revisions stricter than attestation `FullCommit`:
  exactly 40 lowercase hexadecimal characters on the wire.
  Rationale: Kikan C16 still resolves and serves explicit 40-character Git SHA-1 revisions,
  while `FullCommit` deliberately accepts 40- or 64-character hashes for the broader signed
  attestation domain. Sharing repository identity does not require weakening either wire
  invariant.
  Date: 2026-08-19

- Decision: Keep this plan free of Keiro workflow edits.
  Rationale: The deliverable is pure JSON/domain validation. Workflow composition belongs
  to plan 46; if that scope changes, the implementation must first review the applicable
  `mori://shinzui/keiro-runtime-patterns` guidance and `docs/workflow-versioning.md`.
  Date: 2026-08-19


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- Milestone 1 (2026-08-19): `Shikigami.Repository` now owns strict 40-hex revisions,
  normalized safe relative paths, repository identity, and `RepoRef`.
  `Shikigami.Attestation.Reviewed` imports and re-exports the moved identity names without
  changing its existing JSON. `Shikigami.PracticeReview` now decodes the complete version-1
  trigger/adoption vocabulary and rejects producer-selected specialists. Six focused tests
  and all 39 attestation-contract tests pass; no workflow or runtime code changed.

- Milestone 2 (2026-08-19): the same public module now provides the five-way verdict,
  pinned content/evidence identities, fact/inference claims, execution lineage, bounded
  applicability, semantic owner routing, exception approval, re-review condition, and four
  explicit resolution outcomes. Checked-in fixture arrays prove all five classifications and
  all four resolution outcomes decode and round-trip. The focused suite now passes eight
  tests without adding a runtime dependency.


## Context and Orientation

`shikigami-core` is the worker-reachable domain package. Its Cabal component already depends
on `aeson`, `bytestring`, `text`, `time`, and `uuid`, and its single
`shikigami-core-test` component already hosts pure contract tests. The public HTTP package
`shikigami-api` depends on core and contains only route, problem, OpenAPI, and health
contracts; workers may not depend on it. The package boundary is documented in
`docs/architecture/packages.md` and enforced by
`shikigami-core/test/Shikigami/PackageArchitectureSpec.hs`.

`shikigami-core/src/Shikigami/Agent/Decl.hs` is the local record/JSON style exemplar:
direct strict fields under `DuplicateRecordFields`, explicit deriving strategies, and
explicit JSON options when wire compatibility needs them.
`shikigami-core/src/Shikigami/Agent/RunJob.hs` remains the untyped trigger carrier. This
plan adds pure contracts and leaves trigger transport unchanged; plan 46 will decode the
payload at its Flow boundary.

`shikigami-core/src/Shikigami/Attestation/Reviewed.hs` currently owns temporary
`RepositoryId` and `Revision` newtypes. Its Haddock says those names must move when the shared
evidence vocabulary lands. This plan is now the first real consumer, so Milestone 1 creates
`shikigami-core/src/Shikigami/Repository.hs`, moves those two public names there, adds
`RepoRef` and `RelativePath`, and keeps the attestation module source-compatible by importing
and re-exporting the moved names. `Revision` in the shared module is a Mori content-plane
revision: exactly 40 lowercase hexadecimal characters. `FullCommit` remains attestation's
separate 40-or-64-character type.

Kikan's C16 contract defines a `RepoRef` as Mori `repoId` plus a full immutable
40-character Git commit SHA. The current sources are
`mori://shinzui/kikan/plans/25-author-contract-c16-the-repo-content-plane-and-its-provenance-stamp`,
`mori://shinzui/kikan/plans/28-author-mori-s-content-plane-revision-pinning-bare-mirrors-and-the-repository-content-api`,
and
`mori://shinzui/kikan/plans/29-author-the-content-plane-toolenv-and-ephemeral-worktrees-for-shikumi-and-shikigami`.
The live content-plane delivery remains tracked by
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`. Each content reference in this
plan carries a project name, the exact `RepoRef`, a safe repository-relative path, and a
non-empty content hash. A validator checks that the readable project identity and provenance
repository identity agree.

A "claim" is one statement in the verdict. `Fact` means the statement is directly supported
by cited content; `Inference` means the specialist reasoned from cited facts. An evidence id
names one pinned content reference and every claim cites ids present in the same verdict.
"Applicability" is the bounded project/path/dependency/practice scope within which an
exception or adjudicated resolution may guide later reviews.

An agent verdict is provisional. A resolution is a separate command from an authorized
human or approved artifact workflow. Kizashi acknowledgement alone is attention state and is
not a truth-producing resolution. This contract contains no Keiro workflow body, database
operation, model provider, sink call, or runtime dependency. No current ADR directly governs
the wire shape; the package boundary is current architecture documentation, and the shared
repository-module ownership decision will be distilled into a new filesystem ADR before
completion.


## Plan of Work

Milestone 1 creates `shikigami-core/src/Shikigami/Repository.hs` and
`shikigami-core/src/Shikigami/PracticeReview.hs`. The repository module owns
`RepositoryId`, strict `Revision`, `RepoRef`, and safe `RelativePath` smart constructors.
Move the two temporary definitions out of `Shikigami.Attestation.Reviewed`, importing and
re-exporting them there so existing consumers keep compiling. The practice-review module
defines `PracticeReviewTrigger` with `schemaVersion = 1`, trigger kind, stable idempotency
key, canonical target project/repository identity, an added-or-modified revision range,
changed decision paths, practice-adoption bindings, optional changed-reference range, and
optional prior review id. Each adoption binding carries a stable practice key, pinned
registered reference project/document ids, claimed applicability, advisory mode,
target/practice/triage owners, optional exception approver, and registered upstream projects.
The trigger type contains no specialist or candidate field, and its decoder explicitly
rejects a top-level `specialist` key instead of silently ignoring it.

Milestone 2 defines output and resolution values in `Shikigami.PracticeReview`.
`PracticeReviewVerdict` carries schema version, deterministic review id, the originating
trigger idempotency key, practice, specialist, parent/child session and workflow lineage,
target/reference/upstream evidence items, claim-level evidence, integer confidence from 0
through 100, routing rationale, classification, recommended owner/action, exception approval
requirement, re-review condition, and applicability. The five JSON classifications are
exactly `consistent`, `target-suspect`, `reference-suspect`, `legitimate-exception`, and
`unresolved`. A recommended owner is a closed role (`target-owner`, `practice-owner`,
`triage-owner`, `joint-owners`, or `exception-approver`) plus one or more resolved principals;
this makes impossible routing choices machine-checkable without comparing display strings.
`PracticeReviewResolution` is separate and carries deterministic resolution id, command
idempotency key, outcome `accepted`, `rejected`, `narrowed`, or `superseded`, resolver
principal, reason, resolved time, resulting applicability when the outcome can guide later
reviews, and the optional newer review required by `superseded`.

Milestone 3 adds pure validators and deterministic identifiers in the same module, splitting
an internal `Shikigami.PracticeReview.Validation` module only if the single source file
becomes materially harder to navigate. Validation returns all discovered
`ReviewContractError` values as a `NonEmpty`, and successful wrappers carry normalized values.
Trim surrounding whitespace from opaque idempotency keys; case-fold and trim practice keys
and specialist names for UUID input; normalize safe relative paths in their smart constructor.
Reject empty ids/statements/owners/hashes, invalid repository identity, confidence outside
0–100, unsupported schema versions, inconsistent provenance, duplicate evidence identities,
and claims citing missing evidence. Enforce classification invariants: `consistent` has no
recommended attention owner; `target-suspect` selects `target-owner`; `reference-suspect`
selects `practice-owner`; `unresolved` selects triage or joint adjudication and never a target
or practice accusation; `legitimate-exception` has non-empty applicability and selects an
exception approver exactly when approval is required. Suspect classifications require at
least one cited material claim.

Derive UUIDv5 identifiers with the released `uuid` package. The fixed v1 namespace is itself
derived from the URL namespace and the canonical project/domain name; review names concatenate
the normalized trigger idempotency key, practice key, and specialist name with unambiguous
length-prefixing, and resolution names concatenate review id plus the normalized command key.
Add checked-in JSON under `fixtures/practice-review/` and register
`shikigami-core/test/Shikigami/PracticeReviewSpec.hs` in the existing core test suite. Expose
`Shikigami.Repository` and `Shikigami.PracticeReview` from
`shikigami-core/shikigami-core.cabal`. Do not touch Keiro workflow modules.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`.

```bash
sed -n '1,280p' docs/improvement-requests/add-architecture-practice-review-flow.md
sed -n '1,260p' shikigami-core/src/Shikigami/Agent/Decl.hs
sed -n '1,220p' shikigami-core/src/Shikigami/Agent/RunJob.hs
sed -n '1,220p' shikigami-core/src/Shikigami/Attestation/Reviewed.hs
sed -n '1,230p' shikigami-core/shikigami-core.cabal
```

Mori has already located the record convention and `uuid` source. Re-run these lookups if the
registered paths change; read source from the reported project paths rather than a package store:

```bash
mori registry show shinzui/haskell-jitsurei --full
mori registry docs shinzui/haskell-jitsurei
mori registry show haskell-hvr/uuid --full
uuid_repo="$(mori path mori://haskell-hvr/uuid/repos/uuid)"
sed -n '1,220p' "$uuid_repo/uuid/src/Data/UUID/V5.hs"
```

After each milestone, format only the hand-authored modules and run the focused contract
tests. Cabal executes the suite from the package directory, so the test loader resolves
fixtures through `../fixtures/practice-review`.

```bash
nix develop -c fourmolu -i \
  shikigami-core/src/Shikigami/Repository.hs \
  shikigami-core/src/Shikigami/PracticeReview.hs \
  shikigami-core/src/Shikigami/Attestation/Reviewed.hs \
  shikigami-core/test/Shikigami/PracticeReviewSpec.hs \
  shikigami-core/test/Main.hs
nix develop -c cabal test shikigami-core-test \
  --test-options='-p "practice review"' \
  --test-show-details=direct
```

At completion, prove the package edge and the entire workspace remain healthy:

```bash
nix develop -c cabal test shikigami-core-test \
  --test-options='-p "package architecture"' \
  --test-show-details=direct
nix develop -c cabal test all --test-show-details=direct
```

The focused output must show five valid classification fixtures, four valid resolution
fixtures, stable review/resolution id derivation, normalized-key identity behavior, and
rejection of every invalid fixture.


## Validation and Acceptance

For each classification, decode a version-1 fixture, validate it, encode it, decode it again,
and compare the domain value. The reference-suspect fixture must cite a target dependency pin,
a registered practice excerpt, and compatible upstream content at full revisions, with at
least one inference claim and the practice owner. The unresolved fixture may report missing
required evidence but must not accuse an owner. The consistent fixture has no attention
owner. The legitimate-exception fixture has bounded applicability.

Invalid fixtures must cover a branch name used as revision, uppercase SHA, short SHA, absent
content hash, project/provenance repository mismatch, a claim referencing an unknown evidence
id, `target-suspect` pointing at the practice owner, `consistent` with a notification owner,
empty exception scope, trigger naming a specialist, unsupported schema version, and a Kizashi
acknowledgement-shaped payload decoded as a resolution. Reordering reference bindings while
retaining Mori's normalized trigger idempotency key must not change `ReviewId`; changing a
material revision and therefore the producer-supplied trigger key must. Changing only leading
or trailing whitespace in an opaque trigger key, or case/whitespace in a practice key or
specialist name, must not change it either. A different command idempotency key must change
`ResolutionId`.

`Shikigami.AttestationContractsSpec` must still pass after the repository types move, proving
the existing attestation JSON is unchanged. `Shikigami.PackageArchitectureSpec` must still
pass, proving the new module did not create an API-to-worker dependency inversion. The focused
core tests and `nix develop -c cabal test all --test-show-details=direct` all exit zero.


## Idempotence and Recovery

This plan changes only shared/domain types, pure validation, Cabal exposure, tests, fixtures,
and the attestation module's import site. It has no migration, workflow journal, database,
network call, or external write. Formatting and tests are safe to repeat. The
`RepositoryId`/`Revision` move is recoverable by restoring the two definitions to
`Shikigami.Attestation.Reviewed`; no stored value changes representation. Golden files are
changed only by reviewed patches and are never silently regenerated or blessed. If the wire
contract changes after implementation, add a new schema version and decoder path rather than
reinterpreting version 1 in place.


## Portfolio Reconciliation (2026-08-19)

The package foundation and attestation contracts that were future work when this plan was
written are now present. The implementation consumes the released cohort in `cabal.project`,
lands in `shikigami-core`, uses its existing test suite, and replaces the attestation-local
repository placeholders with a neutral `Shikigami.Repository` module. Plans 44 and 45 continue
to consume the contract through `Shikigami.PracticeReview`; they must not define local
lookalikes. Plan 44 still owns `PinnedDiff` and `EvidenceReader`, which it should define over
the `RepositoryId`, `Revision`, `RepoRef`, and `RelativePath` types landed here.

The repository types remain general enough for code-review attestations, but `Revision` is
intentionally the current Mori C16 wire revision: a full lowercase 40-character SHA. The
attestation-only `FullCommit` retains its broader 40-or-64-character invariant. If the Mori
content plane later adopts SHA-256 object format, that is a versioned shared-contract change,
not a reason to silently broaden version 1 fixtures.


## Interfaces and Dependencies

The module must expose at least these domain concepts (field lists above are normative even
if constructors are split for readability):

```haskell
-- Shikigami.Repository
newtype RepositoryId = RepositoryId { value :: Text }
newtype Revision = Revision { value :: Text }
data RepoRef = RepoRef { repository :: !RepositoryId, revision :: !Revision }
newtype RelativePath = RelativePath { value :: Text }

mkRevision :: Text -> Either Text Revision
mkRelativePath :: Text -> Either Text RelativePath

-- Shikigami.PracticeReview
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

`Revision` and `RelativePath` constructors are not exported; their `FromJSON` instances call
the same smart constructors, so branch names, uppercase or short hashes, absolute paths, and
traversal cannot enter through JSON. `RepositoryId` remains a transparent newtype because
both Mori TypeIDs and canonical repository URIs occur in current portfolio values; the
practice-review validator rejects only empty/whitespace identity.

All records use strict direct fields, `DuplicateRecordFields`, explicit deriving strategies,
and explicit Aeson options. Record keys are camelCase to match existing Shikigami payloads;
closed semantic enums use the exact lowercase hyphenated strings named in this plan. Optional
fields are omitted rather than encoded as `null`, so a future optional field can remain
backward-compatible. Every schema-bearing top-level type carries integer version 1.

Dependencies are the existing `aeson`, `bytestring`, `text`, `time`, and `uuid` packages in
`shikigami-core`; no new dependency or bound is required. `uuid` 1.3.16.1 is the verified
released API used for `Data.UUID.V5.generateNamed`. This plan introduces no dependency on
Kioku, Keiro, Mori client code, `mmzk-typeid`, a database, or a model provider.


## Revision Notes

- 2026-08-19: Reconciled the entire plan before implementation. Replaced the stale API
  package/test paths with `shikigami-core`, incorporated the already-landed package and
  attestation architecture, assigned shared repository provenance to
  `Shikigami.Repository`, made the current Mori 40-hex revision invariant explicit, updated
  fixtures and validation cases, added current formatting/test commands, corrected
  cross-repository references to canonical `mori://` URIs, recorded the no-Keiro boundary,
  and documented the verified `uuid` 1.3.16.1 API. The requested user-visible contract is
  unchanged; this revision removes obsolete implementation instructions and resolves
  ownership that July plans could only describe as future work.

- 2026-08-10: Corrected the two exemplar file paths in Context and Orientation, which named
  modules that plan 36 had already moved.

  The Portfolio Reconciliation of 2026-08-05 had already decided the placement question on
  package-architecture grounds — these contracts belong in `shikigami-core`, because
  `shikigami-workers` may not depend on `shikigami-api` and `PackageArchitectureSpec` fails the
  build on that edge. What it did not do was update the Context section, which still pointed an
  implementer at `shikigami-api/src/Shikigami/Api/Activity.hs` and
  `shikigami-api/src/Shikigami/Api/RunJob.hs` as style exemplars. Verified 2026-08-10: neither
  exists; `shikigami-api/src/Shikigami/Api/` holds only `OpenApi.hs` and `Problem.hs`.

  The substitutions are now stated inline: the style exemplar is
  `shikigami-core/src/Shikigami/Agent/Decl.hs`, the trigger-payload carrier is
  `shikigami-core/src/Shikigami/Agent/RunJob.hs`, and the module this plan adds is
  `Shikigami.PracticeReview` rather than `Shikigami.Api.PracticeReview`. No decision changed —
  the file paths were made to agree with a decision already recorded.
