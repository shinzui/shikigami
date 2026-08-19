# 0008. Repository provenance is shared domain vocabulary

Date: 2026-08-19

Status: accepted


## Context

Several Shikigami domains identify repository content. A signed attestation binds the code it
reviewed, an architecture-practice trigger names target and reference revisions, and evidence
acquisition reads blobs and diffs at pinned revisions. These consumers need the same canonical
repository identity and provenance pair; local lookalike types would permit two parts of one
review to disagree about what repository or commit they mean.

`Shikigami.Attestation.Reviewed` originally contained temporary `RepositoryId` and `Revision`
definitions because the attestation plan landed before the evidence and practice-review plans.
Its documentation explicitly said those definitions were awaiting a shared home. Keeping the
temporary ownership after a second consumer arrived would make an attestation vertical the
dependency root for unrelated evidence code.

The current Mori content-plane contract uses a `RepoRef`: stable Mori repository identity plus
one full lowercase 40-character Git SHA-1 revision. A branch, tag, short SHA, uppercase spelling,
or pull-request number is not a pinned content-plane revision. Attestation has a related but
different `FullCommit` type that accepts either 40- or 64-character hashes and normalizes case,
because signed code-review artifacts must anticipate Git's SHA-256 object format. Treating those
two invariants as one type would either weaken the current content-plane boundary or narrow the
broader attestation boundary.


## Decision

**`Shikigami.Repository` is the canonical owner of repository identity and revision-pinned
content addressing shared by Shikigami domains. Domain verticals import these types instead of
declaring local equivalents.**

Concretely:

* `RepositoryId` is a transparent text newtype. Current values may be Mori `repo_...` TypeIDs or
  canonical `mori://` repository URIs, so domain validators reject empty identity without
  imposing one producer representation.
* `Revision` has a private constructor. `mkRevision` and its `FromJSON` instance accept exactly
  40 lowercase hexadecimal characters, matching the current Mori content-plane wire contract.
* `RepoRef` pairs `RepositoryId` with `Revision`; it is the provenance identity carried by
  triggers, evidence, and future content-plane readers.
* `RelativePath` has a private constructor. It normalizes redundant POSIX separators and `.`
  segments, and rejects absolute paths, backslashes, NUL bytes, empty paths, and `..` traversal.
* `Shikigami.Attestation.Reviewed` imports and re-exports the moved `RepositoryId` and `Revision`
  names so existing imports keep compiling. New code imports `Shikigami.Repository` directly.
* Attestation `FullCommit` remains separate. Broadening Mori's revision format requires a
  versioned shared-contract change rather than silently changing version-1 practice-review
  decoding.


## Alternatives rejected

**Leave the shared names in `Shikigami.Attestation.Reviewed`.** This preserves the first landing
site but makes practice review and evidence acquisition depend on an unrelated vertical. The
module itself already called that ownership temporary.

**Define repository and revision types inside `Shikigami.PracticeReview`.** That merely moves the
same ownership error. Attestation and general code-review evidence are not special cases of an
architecture-practice review.

**Reuse attestation `FullCommit` as the content-plane revision.** It accepts uppercase input and
64-character hashes, while current Mori C16 accepts one canonical lowercase 40-character form.
The two types represent different wire contracts even though both ultimately identify commits.

**Import repository vocabulary from a Mori client package.** Shikigami currently has no Mori
client dependency, and the live C16 adapter has not landed. Pure domain contracts and fixture
validation should not acquire a network-client dependency merely to name an identity pair.


## Consequences

Practice-review triggers and evidence now share one provenance representation, and
`Shikigami.Attestation.Reviewed` no longer owns placeholder repository types. Existing
attestation JSON is unchanged because `RepositoryId` keeps the same transparent text encoding;
its focused compatibility tests continue to pass.

`docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md` must define
`PinnedDiff` and `EvidenceReader` over `RepositoryId`, `Revision`, `RepoRef`, and `RelativePath`
from `Shikigami.Repository`. Later consumers must not declare parallel versions.

Content-plane payloads fail during decoding when a revision is a branch, tag, abbreviation,
uppercase SHA, or future 64-character hash. If Mori adopts Git SHA-256, producers and consumers
need an explicit schema/version rollout with new fixtures. Attestation does not wait for that
rollout because its separate `FullCommit` already supports both full hash widths.

The repository module is deliberately pure and carries no Mori client, database, Keiro workflow,
or model-provider dependency. Live resolution and reads remain adapter responsibilities.


## References

* `docs/plans/43-define-architecture-practice-review-contracts.md` — the first shared consumer
  and the implementation that moved the vocabulary.
* `docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md` — the next consumer,
  which adds the read seam and pinned diff over these types.
* `docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md` — the plan that
  introduced the temporary attestation-local definitions and the broader `FullCommit` invariant.
* `mori://shinzui/kikan/plans/25-author-contract-c16-the-repo-content-plane-and-its-provenance-stamp`
  — the portfolio content-plane contract.
* `mori://shinzui/kikan/plans/28-author-mori-s-content-plane-revision-pinning-bare-mirrors-and-the-repository-content-api`
  — revision resolution and pinned content API design.
* `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5` — the tracked live content-plane
  and tool-environment delivery.
