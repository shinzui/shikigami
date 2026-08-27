---
type: Review
title: Improvement-requests OKF corpus before the reviews bundle joins it
description: The nine requests validate strictly and their log and index are current, but the bundle pins a profile three catalog releases behind the one the new reviews bundle pins, the request the landed review flow fulfils is still proposed, and the Mori registry entry that should resolve their URIs is stale.
generated:
  by: process:claude-code
  at: "2026-08-27T00:12:00Z"
reviewId: REV-8
subject: mori://shinzui/shikigami/okf/improvement-requests
subjectKind: component
reviewedSha: 62861267b8e4994ad15e7083ca0eb6b9a5dc2999
coverage: full
reviewedAt: "2026-08-27T00:12:00Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: high
outcome: changes-requested
dimensions:
  - documentation
  - operability
context: >-
  Ran okf 0.8.0.0 validation, log staleness, and trust reports over the
  bundle; read its profile pin, log, and index; compared the pin with the
  okf-profiles catalog tags and changelog on disk; resolved the bundle and
  concept URIs through the Mori registry; and read the practice-review
  request against plans 43 through 46. The uncommitted reviews bundle
  bootstrap was read for its pin only.
---

# Improvement-requests OKF corpus before the reviews bundle joins it

## Verdict

Changes requested. As a corpus the bundle is healthy: `okf validate --strict
--profile-enforce --log-enforce` exits 0 over nine requests, every record
carries v0.2 `generated` provenance and a stable `IR-N` handle, the log
records the v0.2 migration and every addition, and the index lists all nine.
The problems are about the corpus's relationship to the rest of the
repository, which the reviews bundle being adopted alongside it makes visible.

## Required

1. **Repin `docs/improvement-requests/profile.dhall` to okf-profiles
   v0.13.1.** It pins v0.10.0; the reviews bundle pins v0.13.1, so one
   repository will validate two catalog releases. The only change to
   `coordination.improvementRequests` between them is v0.12.0's optional
   typed `dependencies` and `acceptanceCriteria`, which requires okf-core
   0.8.0.0 or later; the installed okf is 0.8.0.0, and the catalog's own
   migration note says a v0.11 bundle stays valid when repinned without the
   new fields. Record the repin in the log as the 2026-08-17 entry did.
2. **Move IR-4 out of `proposed`.** "Add the architecture-practice review
   flow" is the request plans 43 through 46 implement, and master plan 9 and
   plan 46 both cite it. Its frontmatter still says `status: proposed` with
   a 2026-07-30 timestamp. Whichever profile status the repository uses for
   accepted-and-being-delivered, the corpus should say it, and the log should
   carry the transition.
3. **Refresh the Mori registry entry for this project.** `mori registry
   show shinzui/shikigami --full` reports zero bundles and a stale schema
   pin although `mori.dhall` declares the improvement-requests bundle, and
   `mori path mori://shinzui/shikigami/plans/46-…` fails to resolve. REV-1
   through REV-7 cite plan and concept URIs; the registry that should answer
   for them is behind the repository.

## Follow-ups that do not block

- Under `--strict` every request reports the recommended `reviews` family as
  missing. That family is where a document records that it was reviewed;
  now that this bundle exists, the two mechanisms should be used
  deliberately: `reviews` on a request when a person reads it, a record here
  when the examination is the artifact.
- `okf trust` reports every request `unverified`. A `verified.by: human:…`
  entry on the requests Nadeem authored would move them to the
  human-reviewed tier at no cost.

## Evidence

- `okf validate docs/improvement-requests --strict --profile
  docs/improvement-requests/profile.dhall --profile-enforce --log-enforce`
  exited 0 with nine `missing profile-recommended field: reviews`
  advisories; `okf log docs/improvement-requests --check-stale` reported no
  stale concept; `okf trust` listed nine rows `unverified proposed ok`.
- `docs/improvement-requests/profile.dhall` imports
  `okf-profiles/v0.10.0/profiles/coordination/improvement-requests.dhall`;
  `docs/reviews/profile.dhall` imports v0.13.1. `git -C okf-profiles tag`
  lists v0.13.1 as the newest tag; `git diff --stat v0.10.0 v0.13.1 --
  profiles/coordination/improvement-requests.dhall Profile/` shows 121
  insertions, and `CHANGELOG.md` sections 0.12.0 and 0.13.x state the
  compatibility above.
- `docs/improvement-requests/add-architecture-practice-review-flow.md`
  frontmatter: `requestId: IR-4`, `status: proposed`, `timestamp:
  2026-07-30T00:43:00Z`; `docs/plans/46-…` and `docs/masterplans/9-…` cite
  it.
- `mori registry show shinzui/shikigami --full`: `Bundles (0)`, schema pin
  marked stale; `mori path` resolved
  `mori://shinzui/shikigami/okf/improvement-requests` and
  `…/concepts/IR-1` but not the plan-46 URI.
