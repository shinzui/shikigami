---
id: 44
slug: acquire-revision-pinned-architecture-practice-evidence
title: "Acquire revision-pinned architecture-practice evidence"
kind: exec-plan
created_at: 2026-07-26T04:38:47Z
intention: "intention_01kyeb9heqecv8041cmwqwqg3q"
master_plan: "docs/masterplans/9-architecture-practice-review-flow.md"
---

# Acquire revision-pinned architecture-practice evidence

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The practice reviewer can build one normalized evidence bundle from a target ADR and code,
every applicable shared-practice document, compatible upstream source/docs, and prior human
resolutions. Every citable item is tied to a Mori repository id, full commit SHA, path, and
content hash. The reader refuses mutable branches on content operations and rejects a response
whose provenance does not match the requested repository/revision.

The proof uses deterministic two-revision fixture repositories and a stub C16 client. It
shows that target, reference, and upstream excerpts retain exact provenance; dependency pins
select a compatible upstream revision; and missing, unpinned, mismatched, oversized, or
version-incompatible required evidence produces a structured incomplete bundle for the Flow
to turn into `unresolved`, never an accusation.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-26T14:30:41Z) Prerequisite: `docs/plans/43-define-architecture-practice-review-contracts.md`
  has landed; re-check Kikan C16 plans 25/28/29, Kikan IR-5, and the final
  Shikumi ToolEnv seam.
- [x] (2026-08-26T14:40:56Z) M1: define a fail-closed `EvidenceReader`, pinned response types, and provenance/content validation.
- [x] (2026-08-26T14:50:55Z) M2: acquire target ADR/diff/code, one-revision practice references, and compatible upstream evidence.
- [x] (2026-08-26T14:50:55Z) M2: accept prior validated resolutions as evidence without reading Kioku directly.
- [x] (2026-08-26T15:01:09Z) M3: add deterministic fixture repositories, a stub reader, redaction/limit tests, and incomplete-evidence cases.
- [ ] Final: focused evidence tests and `cabal test all` pass without live network access.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Kikan C16 defines full-SHA content routes and provenance, but its Mori implementation and
  Shikumi ToolEnv threading are planned work. This plan therefore needs a narrow local port
  with stub tests and an adapter to the final upstream seam, not a guessed direct dependency.
- C16 blob responses expose a blob object id/content hash, while diff is primarily navigation
  evidence. Claims should cite the pinned blob excerpts discovered from a diff; do not rely on
  an unversioned diff snippet as the sole material citation.
- Kikan IR-5 now provides the canonical OKF request for the revision-pinned
  content plane and bounded tool environment. The deterministic reader seam
  remains startable while that request is proposed.
- The prerequisite vocabulary is present in `Shikigami.Repository` and
  `Shikigami.PracticeReview`, but the portfolio reconciliation's bare "plan 47"
  no longer names a practice-adoption plan in the current tree; current plan 47 is the completed
  dependency-cohort upgrade. The needed `PracticeAdoptionBinding` nevertheless landed in plan 43,
  so there is no missing domain prerequisite.
- Re-checking the registered upstream sources found no content-plane Haskell implementation in
  Mori and no revision-pinned operations in Shikumi's `ToolEnv`; the latter still exposes only
  host filesystem and process operations. Kikan plans 28/29 and IR-5 remain proposed/unimplemented,
  so a live adapter cannot be added without guessing APIs.
- Deterministic `git fast-import` streams can preserve real two-commit fixture histories without
  checking nested `.git` directories into this repository. Fixed authors, timestamps, messages,
  paths, and bytes produced stable full commit and blob ids, while parallel snapshot files let the
  ordinary stub tests consume the exact bytes without invoking Git.


## Decision Log

Record every decision made while working on the plan.

- Decision: Require callers to supply or resolve a full `RepoRef` before blob, tree, grep, or
  diff content becomes citable.
  Rationale: C16 permits mutable refs only at `resolve-ref`; allowing branches in the reader
  would create unreproducible claims.
  Date: 2026-07-25

- Decision: Keep evidence acquisition judgment-free and return `EvidenceBundle` plus
  structured completeness errors.
  Rationale: Whether the target or reference is suspect belongs to the specialist; the reader
  only proves what bytes and provenance were available.
  Date: 2026-07-25

- Decision: Make all size, path-count, grep-page, and excerpt limits explicit bounded domain
  values.
  Rationale: A declared reference can point at an arbitrarily large repository; the agent must
  not turn discovery into unbounded allocation or prompt growth.
  Date: 2026-07-25

- Decision: Track the live adapter through Kikan IR-5.
  Rationale: the current top-level Kikan improvement-request bundle assigns
  `IR-5` to the revision-pinned content-plane and ToolEnv work; using the
  stable concept URI prevents this plan from depending on a deleted nested
  request path.
  Date: 2026-07-30

- Decision: Land only the pure `EvidenceReader` contract, acquisition logic, and deterministic
  stub in this plan; leave the production adapter absent until Kikan IR-5 ships a real C16 client
  and bounded Shikumi tool seam.
  Rationale: both registered upstream trees confirm that the required live APIs do not exist, and
  the plan explicitly forbids ambient Git, host filesystem reads, and guessed ToolEnv APIs.
  Date: 2026-08-26

- Decision: Keep the plan-43 `EvidenceItem` as the verdict-ready citation and wrap it in
  `EvidenceSource` for the C16 freshness timestamp plus bounded redacted excerpt.
  Rationale: the existing public review contract already owns citation identity and JSON shape;
  acquisition needs specialist-readable bytes without widening or duplicating that wire contract.
  Date: 2026-08-26

- Decision: Make `DependencyPinResolver` a pure interpreter from validated target path/byte pairs
  and one `RegisteredUpstreamProject` to a mutable upstream ref plus required paths.
  Rationale: manifest syntax belongs to each package ecosystem, while this module owns the invariant
  that the returned ref is resolved once and only its resulting full SHA reaches content reads.
  Date: 2026-08-26

- Decision: A prior accepted or narrowed resolution applies only when every non-empty applicability
  dimension covers the current target; rejected resolutions supplied by the caller remain audit
  evidence, and superseded or out-of-scope guidance is excluded.
  Rationale: an applicability dimension narrows rather than broadens another dimension, and rejected
  evidence remains useful to prevent a specialist from repeating a disproven argument.
  Date: 2026-08-26

- Decision: Check in deterministic fast-import histories, a commit/blob manifest, and matching
  snapshot bytes under `fixtures/practice-review/content-plane/`.
  Rationale: the histories prove real Git identities and can be rebuilt when inspected, while the
  default unit suite remains fast, hermetic, and independent of a Git subprocess or network clone.
  Date: 2026-08-26

- Decision: Expose `summarizeEvidenceBundle` as the only log-oriented projection.
  Rationale: its type carries citation identities, completeness, and typed problems but has no raw
  response or excerpt field, making accidental source/secret serialization structurally harder.
  Date: 2026-08-26


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- Milestone 1 established the client-independent reader seam, raw pinned response types, positive
  bounded limits, redaction rules, and fail-closed blob/diff validation. The focused command from
  this plan passes 10 tests covering success, provenance, revision, path, hash, size, and count
  limits; no test or implementation path performs network or host-repository IO.
- Milestone 2 added judgment-free acquisition across target diffs/blobs, one-revision registered
  practice references, compatible upstream selections, and caller-validated prior resolutions.
  The focused suite passes 13 tests, including a complete T2/P1/U2 bundle, mixed-reference rejection,
  incompatible-version handling, and exclusion of out-of-scope or superseded guidance.
- Milestone 3 added deterministic two-commit target/practice/upstream histories with real commit and
  blob ids, snapshot-backed in-memory reads, and acquisition-level failure tests. The focused suite
  passes 21 tests and now proves P1-to-P2 isolation, added-target behavior, stale tags, P2/P1 stamp
  mismatch, missing required content, pagination ceilings, redaction, and log-safe summaries.


## Context and Orientation

The trigger/verdict vocabulary comes from
`docs/plans/43-define-architecture-practice-review-contracts.md`. Kikan C16 defines Mori's
content plane: `resolve-ref` accepts a branch/tag and returns `RepoRef`; all tree/blob/log/grep
routes require a full 40-character SHA; diff requires full base/head SHAs; and every successful
response carries `X-Content-Provenance: <repoId>@<revision>`. Blob responses also carry their
Git object id and size. The relevant source documents are Kikan plans 25, 28, and 29 at the
Mori-located project path `/Users/shinzui/Keikaku/bokuno/kikan/docs/plans/`.

Kikan plan 29 authors a Shikumi `ToolEnv` backed by the content plane and threads it into
Shikigami's `BehaviorEnv`. That work is not present in the current tree. This plan defines
`EvidenceReader` as a record of the minimum read operations and later adapts the landed
ToolEnv/client. Tests use an in-memory reader; production code must not shell out to local
Git or read arbitrary host paths.

An "evidence bundle" is a bounded set of validated excerpts and metadata, not a prompt. It
separates target material, registered practice material, compatible upstream material, prior
resolutions, and acquisition problems so downstream behavior cannot confuse absence with
contradiction.


## Plan of Work

Milestone 1 creates `Shikigami.PracticeReview.Evidence` in the plan-36 core package. Define a
record-of-functions `EvidenceReader` for pinned blob, diff, tree/grep discovery, and ref
resolution. The production adapter delegates to the final C16/Shikumi client; the stub returns
fixture values. `validatePinnedContent` checks requested/returned `repoId` and revision,
lowercase full SHA, normalized relative path without `..`, declared size ceiling, non-empty
content hash/object id, and actual returned byte count. Preserve the content-plane provenance
stamp in every `EvidenceItem`.

Milestone 2 implements `acquireEvidence`. Read target changed paths at the target head and the
base/head diff to identify relevant code/dependency manifests. Read every applicable practice
document at one declared reference revision; mixed revisions for one binding are rejected.
Extract target dependency pins through a supplied, deterministic `DependencyPinResolver`, map
each registered upstream project/version to a ref, call `resolveRef` once, then use only its
full SHA for content. When a compatible upstream revision cannot be identified, record
`IncompatibleUpstreamVersion`. Accept prior resolutions validated by
`docs/plans/43-define-architecture-practice-review-contracts.md` from the caller and
include only accepted/narrowed results whose applicability covers the current target; include
rejected results as non-guiding audit evidence. Do not query Kioku in this module.

Each read returns either a validated item or a typed problem. Mark target ADR, every adopted
reference, and required upstream evidence as required. If any required item fails, set bundle
completeness to incomplete and retain successful evidence for adjudication. This module never
creates `target-suspect` or `reference-suspect`.

Milestone 3 adds a two-commit target repository, a two-commit practice repository, and a
tagged upstream fixture under `fixtures/practice-review/content-plane/` plus a deterministic
stub reader in tests. Keep fixtures small and checked in; no test clones the network. Tests
cover added/changed ADR, reference change, compatible tag resolution, mixed reference
revisions, stale pin, provenance mismatch, hash absence, traversal path, size/page limits,
missing required source, and redaction. The rendered bundle may include bounded excerpts for
the specialist but logs include identities/problems only. Put these cases in
`shikigami-core/test/Shikigami/PracticeReviewEvidenceSpec.hs` (or the exact plan-36 core test
package) and register the module in that test component.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`.

Locate and re-read upstream contracts before implementing the adapter:

```bash
mori registry show shinzui/mori --full
mori registry show shinzui/shikumi --full
sed -n '290,448p' /Users/shinzui/Keikaku/bokuno/kikan/docs/plans/25-author-contract-c16-the-repo-content-plane-and-its-provenance-stamp.md
sed -n '562,714p' /Users/shinzui/Keikaku/bokuno/kikan/docs/plans/29-author-the-content-plane-toolenv-and-ephemeral-worktrees-for-shikumi-and-shikigami.md
```

Then format and test:

```bash
nix develop -c fourmolu -i shikigami-core/src/Shikigami/PracticeReview/Evidence.hs
nix develop -c cabal test shikigami-core-test --test-options='-p "practice review evidence"' --test-show-details=direct
nix develop -c cabal test all --test-show-details=direct
```

The focused tests must print successful pinned target/reference/upstream cases followed by
typed incomplete cases; they must make no HTTP request outside the stub.


## Validation and Acceptance

Given a target ADR change at commit T2, practice documents at P1, and a target dependency pin
compatible with upstream tag U2, `acquireEvidence` returns a complete bundle in which every
target item says T2, every practice item says P1, every upstream item says U2's resolved full
SHA, and all content hashes match fixture blob ids. A prior narrowed resolution outside the
current path/dependency scope is excluded from guiding evidence; one inside scope is included.

Changing a practice reference to P2 changes only the practice provenance. Returning P2 bytes
while stamping P1 is rejected. A missing upstream tag, missing required file, branch in a
content request, absent hash, oversized blob, path escape, or incompatible version returns an
incomplete bundle with a precise problem and no fabricated content. The module emits no
verdict, memory, activity, or signal. `nix develop -c cabal test all` exits zero.


## Idempotence and Recovery

Acquisition is read-only. Repeating it against immutable RepoRefs returns equivalent items.
Ref resolution is mutable by nature and must be journaled by
`docs/plans/46-orchestrate-review-delivery-and-end-to-end-conformance.md` before its result is used;
after resolution, retry only with the recorded full SHA. The fixture builder, if a script is
added, must recreate repositories in a task-specific temporary directory and compare/copy
known fixture outputs rather than deleting broad paths. A partial content-plane failure is
returned as data for `unresolved`, not retried indefinitely inside this module.


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 43 and 47. Its deterministic `EvidenceReader`, fixtures,
limits, and stub tests may land immediately after those predecessors. The live adapter is blocked on
Kikan IR-5 at
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`;
do not substitute ambient Git, host filesystem reads, or guessed ToolEnv APIs.


## Portfolio Reconciliation (2026-08-05)

The `EvidenceReader` seam and its vocabulary — `RepositoryId`, `Revision`, `RepoRef`, `PinnedDiff`,
and especially `readDiff` — are **portfolio-shared, not private to MasterPlan 9**.
`docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md` defines `ReviewedArtifact`
(canonical repository identity, full base and head commits, reviewed diff digest, path scope) over
these types, and `docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md` acquires those
values through this reader when binding a signed attestation to the exact code change reviewed.

Because plan 49 has no dependencies and lands first, it carries local placeholder definitions of
`RepositoryId` and `Revision` with a note that they are deleted and imported from this plan once it
exists; plan 52's Milestone 1 performs that swap. Keep the definitions general enough to serve a
code-review binding — full commit hashes at both ends of a diff, with branch names and pull-request
numbers explicitly insufficient — and do not narrow them to Mori-addressed architecture decision
records. Also expect a second consumer of the live adapter once Kikan IR-5 lands: an attested code
review needs the same revision-pinned read that an architecture-practice review does.


## Interfaces and Dependencies

The implementation exposes this shape, adjusted only to match the final C16 client types:

```haskell
data EvidenceReader = EvidenceReader
  { resolveRef :: !(RepositoryId -> Text -> IO (Either EvidenceReadError RepoRef))
  , readBlob :: !(RepoRef -> RelativePath -> IO (Either EvidenceReadError PinnedContent))
  , readDiff :: !(RepositoryId -> Revision -> Revision -> Maybe RelativePath -> IO (Either EvidenceReadError PinnedDiff))
  , grep :: !(RepoRef -> EvidenceQuery -> IO (Either EvidenceReadError [PinnedMatch]))
  }

data EvidenceBundle = EvidenceBundle
  { target :: ![EvidenceItem]
  , references :: ![EvidenceItem]
  , upstream :: ![EvidenceItem]
  , priorResolutions :: ![PracticeReviewResolution]
  , problems :: ![EvidenceProblem]
  , completeness :: !EvidenceCompleteness
  }

acquireEvidence
  :: EvidenceLimits
  -> EvidenceReader
  -> DependencyPinResolver
  -> ValidatedPracticeReviewTrigger
  -> PracticeAdoptionBinding
  -> [ValidatedPracticeReviewResolution]
  -> IO EvidenceBundle
```

All records use direct strict fields. External dependencies are Kikan C16 plans
25/28/29, Kikan IR-5, and the final Shikumi ToolEnv/content client discovered
with Mori. Do not select dependency bounds
from the local corpus: when implementation adds a package dependency, verify its released
version against the authoritative registry and upstream tags as required by `AGENTS.md`.


## Revision Notes

- 2026-08-05: Added a Portfolio Reconciliation note declaring the `EvidenceReader` seam and its
  `RepositoryId`/`Revision`/`RepoRef`/`PinnedDiff` vocabulary portfolio-shared rather than private to
  MasterPlan 9. MasterPlan 10's `ReviewedArtifact` is defined over them and carries placeholders only
  until this plan lands. Keep them general enough for a code-review binding; no milestone scope changed.

- 2026-07-30: Repointed the live content-plane/ToolEnv blocker to Kikan IR-5
  and its stable OKF concept URI. The deterministic reader and fixture work
  remain startable.
