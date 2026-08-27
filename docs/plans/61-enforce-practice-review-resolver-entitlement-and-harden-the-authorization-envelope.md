---
id: 61
slug: enforce-practice-review-resolver-entitlement-and-harden-the-authorization-envelope
title: "Enforce practice-review resolver entitlement and harden the authorization envelope"
kind: exec-plan
created_at: 2026-08-27T00:54:32Z
intention: "intention_01m10bc7hae8trp0ev5mzpvt0d"
---

# Enforce practice-review resolver entitlement and harden the authorization envelope

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A practice-review *resolution* is the command by which a person or an approved artifact
accepts, rejects, narrows, or supersedes an advisory review that the OpenTelemetry
specialist recorded. Today the ingress boundary in
`shikigami-core/src/Shikigami/PracticeReview/Authorization.hs` proves that the submitter
is who they say they are; it never asks whether that person is allowed to decide this
review. Review record [REV-4](../reviews/practice-review-resolution-authorization.md)
found that any authenticated subject can resolve any review, that the opaque credential
type can be printed, and that ADR 0034 overstates what the receipt's id protects against.
Review record [REV-7](../reviews/architecture-practice-reviews-user-guide.md) found that
the user guide does not say who may resolve.

After this plan, a resolution is admitted only when its resolver is one of the review's
recommended owners or a member of an operator-configured set of resolution authorities;
the admitted envelope records which of the two entitled it; the specialist Flow re-derives
the owner case from journaled data on every run so a config change cannot alter a replay;
the credential newtype cannot leak through `Show`; ADR 0034 and the user guide say exactly
what the boundary checks and what the trusted boundary is. An operator can see it working
by running the orchestration tests, which now include a resolver that is neither an owner
nor an authority and is refused before any memory write.


## Progress

- [ ] M1: entitlement policy at ingress, receipt version 2, and configuration key.
- [ ] M2: Flow-side re-derivation from journaled data and tests.
- [ ] M3: credential `Show` removal, source reference tightening, specialist target as
      data, ADR 0034 amendment, user guide paragraph.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Entitlement is decided at ingress and *recorded* in the receipt; the Flow
  re-checks only the case it can re-derive from journaled data (recommended owner) and
  trusts the receipt for the authority case.
  Rationale: the Flow body must be replay-safe. A membership test against a configuration
  set inside the workflow would let an operator change the answer between the first run and
  a resume. Recording the entitlement in the receipt, which is bound into the deterministic
  authorization id, makes the decision immutable once admitted, which is what ADR 0034
  already says about the rest of the receipt.
  Date: 2026-08-27.

- Decision: Bump the envelope schema version to 2 and accept only 2.
  Rationale: ADR 0034 says changing receipt fields requires a new version. No production
  path constructs a version-1 envelope (REV-4 and REV-1 confirm the enqueue boundary has no
  caller), and ADR 0027 permits replacing an unreleased shape before the first release, so
  there is nothing to keep decoding.
  Date: 2026-08-27.

- Decision: The authority set is a new boot-validated configuration key,
  `practice_review.resolution_authorities`, empty by default.
  Rationale: this mirrors `practice_review.attention_recipients`, which already establishes
  that semantic principals are mapped explicitly and fail closed. An empty default means a
  deployment that has not thought about resolution authority admits only recommended
  owners.
  Date: 2026-08-27.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The vocabulary lives in `shikigami-core/src/Shikigami/PracticeReview.hs`. A
`PracticeReviewVerdict` is the specialist's advisory result; its `recommendedOwner ::
Maybe RecommendedOwner` names a role (`TargetOwner`, `PracticeOwner`, `TriageOwner`, or
`ExceptionApprover`) and a list of `OwnerPrincipal` values (team names such as
`architecture-council`). A `PracticeReviewResolution` carries `reviewId`, `outcome`, and
`resolver :: OwnerPrincipal`, which is supplied JSON. `validateResolution` checks only
shape and non-blankness of `resolver` (line 886).

Ingress is `enqueueAuthorizedPracticeReviewResolution` in
`shikigami-core/src/Shikigami/PracticeReview/Authorization.hs`. It validates the
resolution, calls an injected `ReviewResolutionAuthorizer` with the resolution and the
opaque `ResolutionSubmissionEvidence`, checks the returned `AuthorizedResolutionReceipt`
with `validateReceipt` (subject equals resolver; source has a `mori://` or `activity://`
prefix; `authorizationId` equals a UUIDv5 over the receipt fields and the resolution id),
and enqueues an `AuthorizedPracticeReviewResolution` envelope as an addressed run job for
the `opentelemetry-practice-reviewer` agent, whose name is a literal on line 204. No
production code calls this function yet; the plan-46 closeout and REV-1 record that.

The specialist Flow's resolution branch is `resolveAuthorized` in
`shikigami-core/src/Shikigami/Flow/OpenTelemetryPracticeReview.hs`. It revalidates the
envelope, loads the review chain with `recallPracticeReviewChain`, finds the provisional
verdict whose `reviewId` matches, calls `resolveReview` (a journaled memory step), and
emits Kawa history. The provisional verdict is journaled data, so anything derived from it
is stable across replays.

Configuration is declared in `shikigami-core/src/Shikigami/App/Config.hs`;
`practiceReviewAttentionRecipientsSetting` (around line 796) is the template for a new
key: a `Setting` with a decoder, a renderer, a stable key, and an environment binding in
`environmentBindings`. `shikigami-core/test/Shikigami/AppConfigSpec.hs` lists every
public key and environment binding in `surfaceTests` and rejects malformed values in
`strictnessTests`; both lists must grow.

Relevant local ADRs: [0034](../adr/0034-review-resolutions-enter-as-verified-durable-envelopes.md)
defines the envelope and is amended here;
[0031](../adr/0031-practice-review-adjudication-is-a-logical-memory-transition.md) is the
memory transition the entitlement protects;
[0033](../adr/0033-recorded-agent-principals-key-durable-state.md) is why the executing
agent's identity is not a resolver; [0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md)
is the precedent for snapshotting policy into a durable record rather than reading it in
the body; [0027](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md)
permits the version bump without a compatibility branch. No cross-repository ADR applies.


## Plan of Work

### Milestone 1: Entitlement at ingress

At the end of this milestone `enqueueAuthorizedPracticeReviewResolution` refuses a resolver
who is neither a recommended owner of the review nor a configured authority, and an
admitted envelope says which one applied.

In `Authorization.hs`, add `data ResolutionEntitlement = RecommendedOwnerEntitlement |
ResolutionAuthorityEntitlement` with the same kebab-case JSON encoding as
`ResolutionAuthorityKind`. Add an `entitlement :: !ResolutionEntitlement` field to
`AuthorizedResolutionReceipt`, to `receiptKeys`, and to the `expectedAuthorizationId`
preimage (append its rendered text after the authority kind). Set
`authorizationEnvelopeSchemaVersion = 2`; `validateAuthorizedPracticeReviewResolution`
already refuses any other version. `mkAuthorizedResolutionReceipt` gains the entitlement
as its first argument.

Add `data ResolutionAuthorities` as a newtype over `Set OwnerPrincipal` with
`parseResolutionAuthorities :: Text -> Either Text ResolutionAuthorities` (comma-separated,
trimmed, non-empty, duplicates rejected) and `renderResolutionAuthorities`. Add a
`ResolutionAuthorizationError` constructor `ResolutionNotEntitled !OwnerPrincipal` and one
`ProvisionalReviewNotFound !ReviewId`.

Change `enqueueAuthorizedPracticeReviewResolution` to take, after the pool, a
`ReviewId -> IO (Maybe ValidatedPracticeReviewVerdict)` lookup and a
`ResolutionAuthorities` value. After contract validation and before calling the
authorizer, load the provisional verdict for `resolution.reviewId`; refuse with
`ProvisionalReviewNotFound` when absent. Compute the entitlement: if the verdict's
`recommendedOwner` lists the resolver, `RecommendedOwnerEntitlement`; otherwise if the
authorities contain the resolver, `ResolutionAuthorityEntitlement`; otherwise refuse with
`ResolutionNotEntitled`. Pass the entitlement to the authorizer's result by constructing
the receipt through `mkAuthorizedResolutionReceipt` from the authorizer's verified
subject, source, and time, so the authorizer contract narrows to returning
`(ResolutionAuthorityKind, OwnerPrincipal, Text, UTCTime)`; update the
`ReviewResolutionAuthorizer` newtype accordingly. Provide the lookup from
`Shikigami.PracticeReview.Memory` by exporting a small
`loadProvisionalVerdict :: PracticeReviewMemoryEnv -> ReviewId -> IO (Maybe
ValidatedPracticeReviewVerdict)` built on the existing chain recall, so ingress and Flow
read the same envelope.

In `App/Config.hs`, add `practiceReviewResolutionAuthorities :: !ResolutionAuthorities`
to `AppConfig`, the `practiceReviewResolutionAuthoritiesSetting` with key
`practice_review.resolution_authorities` and environment name
`SHIKIGAMI_PRACTICE_REVIEW_RESOLUTION_AUTHORITIES`, defaulting to the empty set with a
constant named `practice-review-resolution-owner-only`. Extend `AppConfigSpec.hs`:
the key and binding in `surfaceTests`, the default renders as `""`, and a strictness case
rejecting `"a,,b"` and `"a,a"`. Document the key in `docs/operations/configuration.md`
beside `practice_review.attention_recipients`.


### Milestone 2: Flow-side re-derivation

At the end of this milestone the Flow refuses an envelope whose entitlement claims
recommended-owner status the journaled verdict does not support, and tests cover both
entitlement cases and the refusal.

In `OpenTelemetryPracticeReview.hs`, in `resolveAuthorized`, after `provisionalReview`
returns the verdict and before `resolveReview`, add: when the receipt's `entitlement` is
`RecommendedOwnerEntitlement`, require `resolver` to be among
`recommendedOwner.principals`, else `failFlow "authorized resolution claims recommended
owner entitlement the provisional review does not grant"`. When it is
`ResolutionAuthorityEntitlement`, proceed; the receipt is inside the trusted queue
boundary and the id binds it.

In `PracticeReviewOrchestrationSpec.hs`, update every `mkAuthorizedResolutionReceipt` call
for the new argument, and add to `authorizationTests`: an owner resolver is admitted with
`RecommendedOwnerEntitlement`; an authority resolver not in the owners is admitted with
`ResolutionAuthorityEntitlement`; a resolver in neither is refused with
`ResolutionNotEntitled`; an envelope carrying `RecommendedOwnerEntitlement` for a
non-owner is refused by the Flow before any `practice-review-resolve` step appears in the
step index. The existing resolution loop in `completeClassificationTests` uses
`architecture-council`, which is the fixture's triage owner and exception approver but
not the recommended owner of a target-suspect verdict; make that loop configure
`architecture-council` as an authority so it keeps passing, and add one owner-entitled
case using `team-example-service` against the target-suspect review.


### Milestone 3: Hardening and documents

At the end of this milestone the credential type is unprintable, the source reference
rule is meaningful, the specialist target is data, and the ADR and guide match the code.

Remove `Show` from `ResolutionSubmissionEvidence`'s deriving clause and add a manual
instance that renders `ResolutionSubmissionEvidence <redacted>`, so debugging output stays
possible without the token. Tighten `validateSource` to require, after the scheme, at least
two non-empty `/`-separated segments for `mori://` (namespace and project) and at least
one segment plus an identifier for `activity://`; add a test with `mori://` alone and
`activity://approval` alone refused. Replace the literal agent name on line 204 with a
`specialistAgent :: Text` argument supplied by the caller; the only caller today is the
test, and the Flow module's `opentelemetrySpecialist` constant is the value to pass.

Amend `docs/adr/0034-review-resolutions-enter-as-verified-durable-envelopes.md` under
Decision: add the entitlement rule and its two cases, state that the authorization id is
an integrity commitment over public fields that detects accidental corruption and binds the
receipt to one resolution, and that tamper resistance comes from the run-job queue being
inside the trusted runtime boundary, not from the id. Also remove the trailing blank line
at end of file if plan 62 has not already done so.

In `docs/user/architecture-practice-reviews.md`, in the "Resolve a review" section, add
one paragraph stating who may resolve: a principal named in the review's recommended
owner, or a principal listed in `practice_review.resolution_authorities`, and that the
admitted envelope records which. Keep plan 62's "not yet reachable" note if it has landed.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shikigami` inside the Nix shell with
the local PostgreSQL cluster running.

```bash
nix develop -c cabal build all
nix develop -c cabal test shikigami-core-test -j1 --test-options='-p "practice review orchestration"' --test-show-details=direct
nix develop -c cabal test shikigami-core-test -j1 --test-options='-p "AppConfig"' --test-show-details=direct
nix develop -c cabal test all -j1 --test-show-details=direct
nix develop -c just keiro-gate <merge-base>
git diff --check
```

Expected new lines in the orchestration transcript:

```text
    authorized resolution
      owner resolver is admitted with recommended-owner entitlement:       OK
      authority resolver is admitted with authority entitlement:            OK
      resolver that is neither owner nor authority is refused:              OK
      flow refuses a recommended-owner claim the verdict does not support:  OK
```

`just keiro-gate` must not report any practice-review finding: this plan adds no step.
Every commit carries:

```text
ExecPlan: docs/plans/61-enforce-practice-review-resolver-entitlement-and-harden-the-authorization-envelope.md
Intention: intention_01m10bc7hae8trp0ev5mzpvt0d
```


## Validation and Acceptance

Acceptance is behavioural. Given a provisional target-suspect review whose recommended
owner is `team-example-service`, and a configuration with
`practice_review.resolution_authorities = architecture-council`: a resolution by
`team-example-service` is admitted and its envelope's receipt says
`recommended-owner-entitlement`; one by `architecture-council` is admitted with
`resolution-authority-entitlement`; one by `team-haskell-platform` is refused with
`ResolutionNotEntitled` and no run job is enqueued; and an envelope hand-built with
`recommended-owner-entitlement` for `team-haskell-platform` is refused by the Flow before
`practice-review-resolve` is journaled. `show (ResolutionSubmissionEvidence "token")`
does not contain `token`. `cabal test all -j1` passes with the new cases and the amended
configuration surface list.


## Idempotence and Recovery

All edits are local rewrites and additive tests; rerunning the suites is safe. The
envelope version bump is safe because nothing has produced a version-1 envelope outside
tests; if a stored test database holds one from a previous run, `withShikigamiMigratedDatabase`
creates a fresh database per test, so no cleanup is needed. If the `AppConfigSpec`
surface test fails after adding the key, the failure lists the exact missing entry; add it
rather than removing the assertion. Nothing here touches `domain/` or the generated layer.


## Interfaces and Dependencies

`Shikigami.PracticeReview.Authorization` exports `ResolutionEntitlement (..)`,
`ResolutionAuthorities`, `parseResolutionAuthorities`, `renderResolutionAuthorities`, the
widened `ResolutionAuthorizationError`, `mkAuthorizedResolutionReceipt` with the
entitlement argument, and `enqueueAuthorizedPracticeReviewResolution :: Pool -> (ReviewId ->
IO (Maybe ValidatedPracticeReviewVerdict)) -> ResolutionAuthorities -> AgentIdentity ->
Text -> ReviewResolutionAuthorizer -> PracticeReviewResolution ->
ResolutionSubmissionEvidence -> IO (Either ResolutionAuthorizationError MessageId)`.
`Shikigami.PracticeReview.Memory` exports `loadProvisionalVerdict`.
`Shikigami.App.Config` exports `practiceReviewResolutionAuthoritiesKey` and the field.
The Flow reads `entitlement` from the envelope it already decodes. Dependencies are
unchanged. The review records this plan answers are
[REV-4](../reviews/practice-review-resolution-authorization.md) and the "who may resolve"
requirement of [REV-7](../reviews/architecture-practice-reviews-user-guide.md).
