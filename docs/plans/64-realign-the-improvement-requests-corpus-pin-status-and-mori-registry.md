---
id: 64
slug: realign-the-improvement-requests-corpus-pin-status-and-mori-registry
title: "Realign the improvement-requests corpus pin, status, and Mori registry"
kind: exec-plan
created_at: 2026-08-27T00:54:32Z
intention: "intention_01m10bc7hae8trp0ev5mzpvt0d"
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T18:24:05Z
      mode: "update"
      note: "Reconciled status and progress during the 2026-09-21 portfolio audit"
---

# Realign the improvement-requests corpus pin, status, and Mori registry

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Shikigami keeps two OKF bundles: `docs/improvement-requests`, now eleven requests for changes to
this runtime, and `docs/reviews`, the commit-pinned review records adopted on
2026-08-27. An OKF bundle is a directory of Markdown documents whose frontmatter is checked
by the `okf` tool against a *profile*, a Dhall description of the required fields pinned
to a release of the shared `okf-profiles` catalog. Review record
[REV-8](../reviews/improvement-requests-okf-corpus.md) found that the two bundles pin
different catalog releases (v0.10.0 and v0.13.1), that the request the landed
practice-review flow fulfils (IR-4) still says `proposed`, and that the Mori registry entry
for this project reports no bundles and a stale schema, so the `mori://` URIs the review
records cite do not resolve.

After this plan, both bundles pin the authoritative okf-profiles v0.18.0 release and validate strictly; every
request's `status` reflects the plans that exist for it; the project pins the current Mori schema; and
`mori registry bundles shinzui/shikigami` plus OKF concept URIs answer correctly from the registry.
Plan URI resolution is also tested and any remaining Mori coverage gap is recorded explicitly.


## Progress

- [x] (2026-09-21T18:03:06Z) M1: repinned both OKF bundles to v0.18.0 and validated them strictly.
- [x] (2026-09-21T18:03:06Z) M2: audited all eleven requests, updated five lifecycle values, added catalog-metadata review provenance, and logged the result.
- [x] (2026-09-21T18:03:06Z) M3: pinned the current Mori schema, refreshed the local registry, verified bundle and OKF concept resolution, and recorded the remaining plan-artifact coverage gap.
- [x] (2026-09-21T18:03:06Z) M4 disposition: human verification remains optional and was not fabricated; the model audit is recorded separately.


## Surprises & Discoveries

- The authoritative catalog advanced to v0.18.0 after this plan was written. Releases 0.14
  through 0.18 do not change the improvement-request or review document rules, but they do change
  the package semantic hash. The audit therefore pins the current released tag rather than
  implementing the historical v0.13.1 instruction literally.
- `mori.dhall` already declared all three OKF bundles, but pinned an old Mori schema. Repinning it
  to upstream commit `3522f4a51181d73c9c90fc27a7c0838bd29ae95f` and refreshing the registry
  removed the schema warning and made bundle and concept discovery current.
- The current Mori registry still does not index repository-local ExecPlans or MasterPlans from
  their conventional directories. `mori path
  mori://shinzui/shikigami/plans/46-orchestrate-review-delivery-and-end-to-end-conformance`
  returns `artifact ... not found` after a successful refresh. Per this plan's M3 recovery rule,
  this is recorded as a Mori artifact-coverage gap; the intended canonical URI remains in durable
  references.
- The bundle grew from nine to eleven requests after this plan was authored. The audit includes
  IR-10 and IR-11 rather than preserving the stale cardinality.


## Decision Log

- Decision: Repin without adopting the optional v0.12.0 `dependencies` and
  `acceptanceCriteria` fields in the same change.
  Rationale: the catalog changelog states a bundle valid under v0.11.0 stays valid when
  repinned without the new fields, and the installed okf is 0.8.0.0, which the repin
  requires. Promoting prose into structured fields is the separate
  `adopt-improvement-request-contracts` blueprint and is not a finding.
  Date: 2026-08-27.

- Decision: Pin both bundles to v0.18.0, the latest authoritative release verified against the
  upstream tag, rather than the v0.13.1 target named by the 2026-08-27 draft.
  Rationale: the newer releases preserve both profiles' document rules, while a roadmap audit
  should not intentionally leave a known stale catalog pin.
  Date: 2026-09-21.

- Decision: Preserve each review record's original `outcome` and represent present-day closure in
  the roadmap and bundle log.
  Rationale: the reviews profile defines a review as immutable evidence about one subject at one
  commit; rewriting an old outcome would destroy that evidence.
  Date: 2026-09-21.

- Decision: Status is set per request from the plan corpus, using `in-progress` for a
  request whose plans have landed but which still names an open external gate, and
  `completed` only when the request's own acceptance is met.
  Rationale: the v0.13.1 profile allows `proposed`, `accepted`, `in-progress`,
  `completed`, `rejected`, `withdrawn`, and `superseded`; a request cannot be `completed`
  while its live-evidence acceptance depends on Kikan IR-5.
  Date: 2026-08-27.


## Outcomes & Retrospective

Completed 2026-09-21. Both OKF bundles now pin okf-profiles v0.18.0. The improvement-request
corpus records three completed requests (IR-1, IR-3, IR-9), two in progress (IR-4, IR-7), and six
proposed (IR-2, IR-5, IR-6, IR-8, IR-10, IR-11), with catalog-metadata review provenance on every
request. Strict validation, index regeneration, log freshness, and trust reporting pass. The local
Mori registry now uses the current schema, lists the declared OKF bundles, and resolves the IR-4
concept URI. It does not yet resolve conventional `docs/plans` and `docs/masterplans` artifacts;
the exact plan-46 failure is recorded above as a Mori coverage gap rather than misreported as
repository completion evidence.


## Context and Orientation

`docs/improvement-requests/profile.dhall` is a single Dhall import of
`https://raw.githubusercontent.com/shinzui/okf-profiles/v0.18.0/profiles/coordination/improvement-requests.dhall`
with a `sha256:` integrity hash. `docs/reviews/profile.dhall` is the same shape at v0.18.0
for the reviews profile. The catalog is checked out at
`/Users/shinzui/Keikaku/bokuno/okf-profiles` (registered as `mori://shinzui/okf-profiles`);
its `CHANGELOG.md` records per release what changes for consumers. Repinning means
replacing the URL and recomputing the hash; the `dhall` executable computes it with
`dhall hash`. `mori.dhall` at the repository root declares both bundles discussed here, plus the
user-documentation bundle, under `okfBundles` with their profile paths; Mori reads it when the
project is registered.

The eleven requests carry `requestId: IR-N`, `status`, `timestamp`, and `generated` in their
frontmatter. `docs/improvement-requests/log.md` is the bundle's reserved change log,
newest section first, with `**Addition**`, `**Update**`, and `**Migration**` bullets;
`docs/improvement-requests/index.md` is generated by `okf index --write`. The
repository's plans in `docs/plans/` and master plans in `docs/masterplans/` are what a
status audit reads: for example IR-4 ("Add the architecture-practice review flow") is
realised by plans 43 through 46 under master plan 9; IR-9 ("Key durable agent continuity
and outbound attribution by Meibo principal") by plan 54; IR-7 ("Attest sanctioned model
execution for agent runs") by plans 49 through 52 under master plan 10; the router
request by plans 40 through 42 under master plan 8. Each plan's Progress section says
whether it finished.

The Mori registry is a local database of projects; `mori register` (run from a project
root) records or refreshes one project from its `mori.dhall`, `mori registry show
shinzui/shikigami --full` prints what is recorded, `mori registry bundles
shinzui/shikigami` lists its OKF bundles, `mori registry pins` lists shared pinned imports
and their staleness, and `mori path <uri>` resolves a `mori://` URI to a path. The
project's schema import in `mori.dhall` is the `mori-schema` package pin the registry
flagged as stale.

No local ADR governs the OKF corpora (`docs/adr/README.md` explains the ADR corpus is
deliberately not an OKF bundle). The global instruction that cross-repository references
use canonical `mori://` URIs is the reason M3 matters. No cross-repository ADR applies.


## Plan of Work

### Milestone 1: Repin the profile

At the end of this milestone both bundles validate strictly against okf-profiles v0.18.0.

Compute the hash and rewrite the descriptor:

```bash
dhall hash <<< 'https://raw.githubusercontent.com/shinzui/okf-profiles/v0.18.0/profiles/coordination/improvement-requests.dhall'
```

It prints a line `sha256:<64 hex>`. Replace both lines of
`docs/improvement-requests/profile.dhall` with the v0.18.0 URL and that hash, keeping the
two-line layout the reviews descriptor uses and adding the same `--|` comment header
naming the source `mori://shinzui/okf-profiles/profiles/improvement-requests`. Run the
strict validation in Concrete Steps; the expected result is eleven valid concepts with the
catalog-metadata review family populated by this audit.
Add a `**Update**` bullet under a new `## 2026-08-27` section at the top of
`docs/improvement-requests/log.md` stating the repin and that no request content changed.


### Milestone 2: Status audit

At the end of this milestone every request's `status` matches the plan corpus and the
log records each transition.

For each of the eleven files, find the plans and master plans that cite its `requestId` or
title (`grep -rn "IR-4\|architecture-practice review" docs/plans docs/masterplans` and
so on), read their Progress sections, and set `status` accordingly: `in-progress` when at
least one plan has started and something remains, `completed` when the request's own
acceptance is met by finished plans, `accepted` when plans exist but none has started,
and leave `proposed` only where no plan cites it. Advance `timestamp` and `generated.at`
to the edit time on every file whose status changes, because the profile treats
`timestamp` as the last meaningful revision. For IR-4 the expected result is
`in-progress`, with a sentence in its `## Status` body naming plans 43 through 46 and
the open Kikan IR-5 gate. Write one `**Update**` log bullet per changed request, then run
`okf index docs/improvement-requests --write` and the strict validation; `okf log
docs/improvement-requests --check-stale` must report nothing.


### Milestone 3: Registry refresh

At the end of this milestone the registry uses the current schema, knows all declared bundles,
resolves OKF concept URIs, and records the tested plan-URI coverage gap.

Run `mori registry pins` and note the mori-schema commit it reports as current; if the
project's `mori.dhall` schema import is behind it, run `mori registry upgrade-schema
--help` and use it if it can be scoped to this project, otherwise update the import URL
and hash in `mori.dhall` by hand to the current commit (the hash comes from `dhall hash`
over the new URL) and confirm `dhall type --file mori.dhall` still succeeds. Then run
`mori register` from the repository root and verify:

```bash
mori registry show shinzui/shikigami --full
mori registry bundles shinzui/shikigami
mori path mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-4
mori path mori://shinzui/shikigami/plans/46-orchestrate-review-delivery-and-end-to-end-conformance
```

The first must report the current schema without a schema `[stale]` marker; the second lists
`improvement-requests`, `reviews`, and `user`; the third resolves to
`docs/improvement-requests/add-architecture-practice-review-flow.md`. The fourth currently fails
with `artifact ... not found`. If `mori path` cannot resolve plan artifacts after a fresh
registration, that is a Mori coverage gap rather than a repository defect: record the
exact error in Surprises & Discoveries and keep the intended URI in the review records,
as the repository's cross-reference rule prescribes.


### Milestone 4 (optional): Human verification

This milestone needs Nadeem, not an agent. Each request authored by `human:nadeem` may
carry a `verified` entry (`by: human:nadeem`, `at: <time>`) once its content has been
re-read after this plan's status changes; `okf trust docs/improvement-requests` then
reports the human-reviewed tier. An agent must not add these entries. Record in Progress
whether it was done or deliberately skipped.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shikigami`.

```bash
okf --version
dhall hash <<< 'https://raw.githubusercontent.com/shinzui/okf-profiles/v0.18.0/profiles/coordination/improvement-requests.dhall'
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
okf index docs/improvement-requests --write
okf log docs/improvement-requests --check-stale
okf trust docs/improvement-requests
just reviews-validate
mori register
mori registry bundles shinzui/shikigami
```

Expected: `okf v0.8.0.0` or later; a `sha256:` line; `OK: 11 concepts (okf_version 0.2)`;
`Wrote index.md files`; no stale report;
a trust table whose `status` column shows the audited values; `OK: 8 concepts` for the
reviews bundle; and a bundle listing with three rows.

Every commit carries:

```text
ExecPlan: docs/plans/64-realign-the-improvement-requests-corpus-pin-status-and-mori-registry.md
Intention: intention_01m10bc7hae8trp0ev5mzpvt0d
```


## Validation and Acceptance

The bundle validates strictly at v0.18.0 with no error; `git diff docs/improvement-requests`
shows only the audited metadata, status prose, log, index, and descriptor changes; `mori registry
show shinzui/shikigami --full` reports the current schema; the bundle listing and IR-4 concept path
resolve; and any failed plan-artifact resolution is recorded as a Mori coverage gap. A reader of
`docs/improvement-requests/log.md` can see when and why each status moved.


## Idempotence and Recovery

Every step is repeatable. `dhall hash` is deterministic; `okf index --write` regenerates
the same file; `mori register` refreshes in place. If validation fails after the repin
with a message about an unknown field or decoder version, confirm `okf --version` is at
least 0.8.0.0 before changing any request. If `mori register` rejects `mori.dhall` after a
schema change, revert `mori.dhall` with `git checkout -- mori.dhall` and register at the
old schema; the stale marker is cosmetic and the plan can complete without M3's schema
half.


## Interfaces and Dependencies

No code changes. Tools: `okf` (0.8.0.0 or later), `dhall`, `mori`, `just`. Inputs:
`docs/improvement-requests/**`, `mori.dhall`, and the okf-profiles checkout for the
changelog. The review record this plan answers is
[REV-8](../reviews/improvement-requests-okf-corpus.md), required items 1 through 3 and both
follow-ups.


## Revision Notes

- 2026-09-21: Implemented the corpus audit against eleven requests, advanced both OKF profile
  pins to the authoritative v0.18.0 release, preserved historical review outcomes, repinned the
  current Mori schema, refreshed the local registry, recorded its plan-artifact coverage gap, and
  added `docs/roadmap.md` as the current disposition ledger.
