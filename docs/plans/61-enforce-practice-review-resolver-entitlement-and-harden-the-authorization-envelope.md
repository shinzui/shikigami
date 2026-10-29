---
id: 61
slug: enforce-practice-review-resolver-entitlement-and-harden-the-authorization-envelope
title: "Enforce practice-review resolver entitlement and harden the authorization envelope"
kind: exec-plan
created_at: 2026-08-27T00:54:32Z
intention: "intention_01m10bc7hae8trp0ev5mzpvt0d"
provenance:
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-29T13:47:31Z
      mode: "update"
      note: "Refresh current source and PostgreSQL suite paths, ingress entitlement and target checks, typed lookups, replay and rollout prerequisites, and receipt documentation."
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
the credential newtype has a redacted `Show` instance; ADR 0034 and the user guide say exactly
what the boundary checks and what the trusted boundary is. An operator can see it working
by running the expanded orchestration tests, which will include a resolver that is neither an owner
nor an authority and is refused before any memory write.


## Progress


- [ ] M1: entitlement policy and verdict-bound specialist target at ingress, receipt
      version 2, and configuration key.
- [ ] M2: Flow-side re-derivation from journaled data and tests.
- [ ] M3: credential `Show` redaction, source reference tightening, ADR 0034 amendment,
      and user guide corrections.


## Surprises & Discoveries


Refresh on 2026-10-29 against `92f8f0f`: the entitlement check is still absent,
`ResolutionSubmissionEvidence` still derives `Show`, and source validation still accepts
scheme-only references. No implementation milestone is complete. The orchestration tests
now live under `shikigami-core/test-postgres/`; they construct envelopes directly and do
not call the enqueue function. That function already accepts an agent name but restricts
it to a literal specialist. The Flow's `opentelemetrySpecialist` constant is private.

The receipt id currently commits to receipt fields and the resolution id, not the whole
resolution payload. `deriveResolutionId` derives that id from the review id and command
key; it does not hash the outcome or reason. Documentation must not imply that the UUID
is a signature or a complete payload digest. The source tree cannot establish the absence
of deployed version-1 payloads; that prerequisite remains unverified.


## Decision Log


- Decision: Entitlement is decided at ingress and *recorded* in the receipt; the Flow
  re-checks only the case it can re-derive from journaled data (recommended owner) and
  trusts the receipt for the authority case.
  Rationale: the Flow body must be replay-safe. A membership test against a configuration
  set inside the workflow would let an operator change the answer between the first run and
  a resume. Recording the entitlement in the receipt, which is bound into the deterministic
  authorization id, retains the decision for replay within the trusted queue boundary;
  the public id does not itself prevent a queue writer from replacing that decision.
  Date: 2026-08-27.

- Decision: Bump the envelope schema version to 2 and accept only 2.
  Rationale: ADR 0034 requires a new version for changed receipt fields. This remains
  conditional on rechecking ADR 0027 immediately before implementation: no release or
  deployment freezing the old shape, no resumable old journals, no queued/stored old
  payloads that must decode, and no external wire consumers. Absence of an in-tree
  caller is supporting evidence, not proof of deployment state. If those facts do not
  hold, revise the rollout and compatibility strategy before removing version-1 decoding;
  never default a missing entitlement to authority.
  Date: 2026-08-27; prerequisite clarified 2026-10-29.

- Decision: The authority set is a new boot-validated configuration key,
  `practice_review.resolution_authorities`, empty by default.
  Rationale: this mirrors `practice_review.attention_recipients`, which already establishes
  that semantic principals are mapped explicitly and fail closed. An empty default means a
  deployment that has not thought about resolution authority admits only recommended
  owners.
  Date: 2026-08-27.


- Decision: Authenticate and check subject equality before loading review ownership;
  then derive entitlement at ingress from that verified subject. Match the existing
  target argument against the stored verdict's `specialist` rather than adding a second
  caller-supplied target.
  Rationale: callers must not assign their own entitlement or bypass specialist routing
  by supplying two matching arbitrary strings. Authentication failure must not initiate a
  review lookup. Preserve the admitted `AgentIdentity` unchanged.
  Date: 2026-10-29.

- Decision: Preserve typed memory-read failures at ingress and share the pure provisional
  selection rule with the Flow, without adding an unjournaled read inside the Flow.
  Rationale: a missing review, malformed content, and a store failure are different
  outcomes; none may fall through to authority admission. Immutable provisional content,
  including a retired provisional row, is still the basis for retry authorization.
  Date: 2026-10-29.


## Outcomes & Retrospective


The 2026-10-29 refresh updates implementation guidance and acceptance against current
source, suite declarations, and the cited ADRs. M1–M3 remain unimplemented. This is a
plan-only update; build, PostgreSQL acceptance, and workflow gate results must be recorded
when implementation occurs. Refresh validation passed for local links, named file paths,
required sections, language-tagged fences, and `git diff --check`; the gate recipe was
checked with `just --dry-run keiro-gate HEAD`. No implementation tests were run.


## Context and Orientation


The vocabulary lives in `shikigami-core/src/Shikigami/PracticeReview.hs`. A
`PracticeReviewVerdict` is the specialist's advisory result; its `recommendedOwner ::
Maybe RecommendedOwner` names a role (`TargetOwner`, `PracticeOwner`, `TriageOwner`, or
`ExceptionApprover`) and a list of `OwnerPrincipal` values (team names such as
`architecture-council`). A `PracticeReviewResolution` carries `reviewId`, `outcome`, and
`resolver :: OwnerPrincipal`, which is supplied JSON. `validateResolution` checks contract
shape, deterministic resolution-id agreement, and non-blankness of `resolver`; it does not check entitlement.

Ingress is `enqueueAuthorizedPracticeReviewResolution` in
`shikigami-core/src/Shikigami/PracticeReview/Authorization.hs`. It validates the
resolution, calls an injected `ReviewResolutionAuthorizer` with the resolution and the
opaque `ResolutionSubmissionEvidence`, checks the returned `AuthorizedResolutionReceipt`
with `validateReceipt` (subject equals resolver; source has a `mori://` or `activity://`
prefix; `authorizationId` equals a UUIDv5 over the receipt fields and the resolution id),
and enqueues an `AuthorizedPracticeReviewResolution` envelope as an addressed run job for
the agent supplied as `Text`, currently guarded by the literal
`opentelemetry-practice-reviewer`. Searches of current Haskell sources find no caller,
including in tests. Existing tests cover receipt construction and Flow dispatch, not
actual ingress enqueue. A deployment authentication adapter and a public endpoint or
command remain outside this plan; document that limitation without waiting for plan 62.

The specialist Flow's resolution branch is `resolveAuthorized` in
`shikigami-core/src/Shikigami/Flow/OpenTelemetryPracticeReview.hs`. It revalidates the
envelope, loads the review chain with `recallPracticeReviewChain`, finds the provisional
verdict whose `reviewId` matches, calls `resolveReview` (a journaled memory step), and
emits Kawa history. The provisional verdict is journaled data, so anything derived from it
is stable across replays.

Configuration is declared in `shikigami-core/src/Shikigami/App/Config.hs`;
`practiceReviewAttentionRecipientsSetting` is the template for a new
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
permits an unused pre-release reset only after the current unused-state facts are
recorded. These ADRs contain historical patch descriptions; the current workflow baseline
and [workflow-versioning guide](../workflow-versioning.md) govern implementation.
No cross-repository ADR is needed for this change.

The integration suite is
`shikigami-core/test-postgres/Shikigami/PracticeReviewOrchestrationSpec.hs`, registered by
`shikigami-core/test-postgres/Main.hs` in `shikigami-core-postgres-test`.
`shikigami-core/test-postgres/Shikigami/PracticeReviewMemorySpec.hs` covers persistence;
`shikigami-core/test/Shikigami/AppConfigSpec.hs` remains in `shikigami-core-test`.
Plan 60 separately changes failure classification in the same specialist Flow, and plan
62 owns broader operator documentation and profile provisioning. Preserve any work from
those plans; this plan neither depends on their completion nor claims their acceptance.


## Plan of Work


### Milestone 1: Entitlement at ingress


At the end of this milestone `enqueueAuthorizedPracticeReviewResolution` refuses a resolver
who is neither a recommended owner of the review nor a configured authority, and an
admitted envelope says which one applied.

In `shikigami-core/src/Shikigami/PracticeReview/Authorization.hs`, add
`ResolutionEntitlement = RecommendedOwnerEntitlement | ResolutionAuthorityEntitlement`
with kebab-case JSON encoding. Add `entitlement :: !ResolutionEntitlement` to the receipt,
its explicit export list, `receiptKeys`, and its hand-written decoder; missing or unknown
entitlements fail decoding. Add entitlement after authority kind in the authorization-id
preimage and change its domain tag to `practice-review-resolution-authorization-v2`.
Set the outer `authorizationEnvelopeSchemaVersion` to 2; the nested resolution's schema
version remains 1. Update the frozen UUID vector in the orchestration test deliberately.
`mkAuthorizedResolutionReceipt` gains entitlement as its first argument. Update existing
constructor call sites, outer envelope versions, and fixtures in this milestone so the
suite still compiles; M2 adds the ownership refusal and replay assertions.

Introduce opaque `ResolutionAuthorities`, backed by `Set OwnerPrincipal`, with
`emptyResolutionAuthorities`, `parseResolutionAuthorities`, and
`renderResolutionAuthorities`. Entirely empty or whitespace-only input means the empty
set. Otherwise split on commas, trim entries, reject empty elements and duplicates after
trimming, and preserve case-sensitive principal identity. Render sorted principals joined
by commas; the empty set renders as `""`. No new principal naming grammar is introduced.

Narrow `ReviewResolutionAuthorizer.authorize` to return verified identity facts
`(ResolutionAuthorityKind, OwnerPrincipal, Text, UTCTime)` inside its existing
`IO (Either ResolutionAuthorizationError ...)`; it must not choose entitlement or return
a ready-made receipt. Extend the error type with `ResolutionNotEntitled !OwnerPrincipal`,
`ProvisionalReviewNotFound !ReviewId`, `ProvisionalReviewLookupFailed !ReviewMemoryError`,
and `ResolutionSpecialistMismatch !Text !Text` (expected specialist, supplied target).

Change `enqueueAuthorizedPracticeReviewResolution` to accept, after the pool, a lookup
`ReviewId -> IO (Either ReviewMemoryError ValidatedPracticeReviewVerdict)` and a
`ResolutionAuthorities`. Keep the existing identity and target arguments. Validate the
resolution, call the authorizer, and require its verified subject to equal the resolver
before any lookup. Load the exact requested provisional verdict, reject mismatched review
ids, and require its `specialist` to equal the supplied target. A missing review maps to
`ProvisionalReviewNotFound`; other typed read failures map to
`ProvisionalReviewLookupFailed`. Store exceptions retain their operational failure
semantics and must never become successful authorization or fabricated absence.

Compute entitlement from the verified subject: membership in
`recommendedOwner.principals` wins, otherwise membership in the configured authorities
wins, otherwise refuse. `Nothing` for recommended owner allows only an authority.
Triage and exception roles do not independently grant access unless they are the selected
recommended owner or explicitly configured authorities. Construct and validate the receipt
from the verified facts and computed entitlement, then enqueue using the existing key,
route, and admitted identity. No refusal may enqueue a job.

In `shikigami-core/src/Shikigami/PracticeReview/Memory.hs`, export
`loadProvisionalVerdict :: PracticeReviewMemoryEnv -> ReviewId -> IO (Either
ReviewMemoryError ValidatedPracticeReviewVerdict)`. Build it on the existing
`loadEnvelope env (provisionalMemoryId reviewId)` so typed malformed/not-found/refused
results stay distinct. Require a `ProvisionalReview` envelope with the matching review id;
reuse `ReviewExpectedProvisional` and `ReviewIdMismatch` for the other cases. Do not
require active status: retries must still read the immutable provisional after retirement.
Extract the Flow's pure `provisionalReview` selection into an exported
`provisionalVerdictFromChain :: ReviewId -> PracticeReviewChain -> Maybe
ValidatedPracticeReviewVerdict`, requiring both the deterministic provisional memory id
and the embedded review id. Use that helper in the Flow; it still obtains its chain from
the existing journaled effect. Both paths must agree on the selected original verdict.

In `shikigami-core/src/Shikigami/App/Config.hs`, add
`practiceReviewResolutionAuthorities :: !ResolutionAuthorities` to `AppConfig`, wire its
applicative constructor, and add the setting, exported key, and environment binding:
`practice_review.resolution_authorities` /
`SHIKIGAMI_PRACTICE_REVIEW_RESOLUTION_AUTHORITIES`. Use `emptyResolutionAuthorities`
with constant `practice-review-resolution-owner-only`. In
`shikigami-core/test/Shikigami/AppConfigSpec.hs`, extend the public key and binding lists,
default rendering, successful CLI/environment resolution, and strictness tests for
`a,,b`, `a,a`, and `a, a`. Test whitespace-only input and deterministic render/parse
round trips. Document the key beside attention recipients in
`docs/operations/configuration.md`.

Verify M1 through a PostgreSQL integration group in
`shikigami-core/test-postgres/Shikigami/PracticeReviewOrchestrationSpec.hs` using its
`DatabaseFixture`. Persist a real provisional review, supply `loadProvisionalVerdict`
and a counting fake authorizer, call the actual enqueue boundary, and decode the queued
RunJob. Assert receipt entitlement, version, identity, specialist route, and absence of
raw credentials. Cover owner-only admission, authority admission, owner precedence when
both apply, no recommended owner, unauthorised resolver, subject mismatch, authorizer
refusal, missing/malformed/wrong-id verdicts, and wrong specialist. Refusals leave queue
counts unchanged; authorizer refusal and subject mismatch do not invoke the lookup.
Use existing fixture/queue helpers rather than introducing a deployment endpoint.
Prove a real ingress-produced envelope runs through the specialist before expanding the
remaining cases. Existing direct receipt tests alone do not satisfy this milestone.


### Milestone 2: Flow-side re-derivation


At the end of this milestone the Flow refuses an envelope whose entitlement claims
recommended-owner status the journaled verdict does not support, and tests cover both
entitlement cases and the refusal.

In `shikigami-core/src/Shikigami/Flow/OpenTelemetryPracticeReview.hs`, keep the validated
receipt returned by `validateAuthorizedPracticeReviewResolution`. After journaled chain
recall and provisional selection, before `resolveReview`, require the resolver in
`recommendedOwner.principals` when entitlement is `RecommendedOwnerEntitlement`.
Fail with a bounded message when absent. `ResolutionAuthorityEntitlement` proceeds from
the retained admission decision; the Flow must not consult live configuration or call the
authorizer. Both cases still require a valid original review. Use the shared pure chain
selector described in M1 and unwrap its validated verdict for history output.

In `shikigami-core/test-postgres/Shikigami/PracticeReviewOrchestrationSpec.hs`, update all
receipt constructors and outer envelope versions, leaving trigger/verdict/resolution
schema versions unchanged. Preserve strict unknown-field, subject, source, and altered-id
coverage. The classification loop currently constructs receipts directly: use an explicit
authority-entitled receipt for its `architecture-council` resolver, backed by the separate
real-ingress authority test from M1, and add an owner-entitled target-suspect case for
`team-example-service`. Add a validly recomputed owner-entitled receipt for a non-owner,
so rejection proves ownership enforcement rather than merely detecting a bad UUID.
Assert no `practice-review-resolve` journal entry, resolved memory, or resolution-history
outbox effect. It may have a `practice-review-chain` read entry.

Exercise replay of both admitted entitlement cases with the authorizer and ingress lookup
made unusable and authority configuration changed to empty. Existing journaled chain and
resolution results must replay unchanged with no repeated writes or history delivery.
Also stop after chain recall and resume before resolution to prove the owner check uses
the retained verdict rather than rereading mutable state.

Follow `docs/workflow-versioning.md`: this design keeps all four memory effect labels and
result codecs, adds no step, and performs only pure validation between existing calls.
Run the gate and focused replay tests; an empty structural diff alone cannot validate
input-codec compatibility. Before making version 2 exclusive, record the unused-state
prerequisite from the Decision Log. If historical version-1 work exists, revise the plan
with an explicit compatible rollout before changing its replay behavior. Do not treat
plan 65's historical baseline reset as permission for another reset.


### Milestone 3: Hardening and documents


At the end of this milestone credential rendering is redacted, the source reference
rule is meaningful, the specialist target is data, and the ADR and guide match the code.

In `shikigami-core/src/Shikigami/PracticeReview/Authorization.hs`, replace derived `Show`
for `ResolutionSubmissionEvidence` with a manual instance rendering exactly
`ResolutionSubmissionEvidence <redacted>`. Keep it non-serializable. Test a distinctive
secret token, including its absence from the enqueued payload.

Tighten `validateSource`: after stripping surrounding whitespace, require the exact
`mori://` or `activity://` scheme, at least two non-empty slash-separated segments
(namespace/project or activity-kind/identifier), and no empty interior/trailing segments
or embedded whitespace. Reject scheme-only values, `activity://approval`, double slashes,
and trailing slashes. Accept canonical project/artifact references and
`activity://approval/1`; store the normalized reference before deriving the id. This is
structural validation, not online reference resolution or proof of artifact approval;
the injected authorizer owns authentication and artifact verification.

The target-as-data change is implemented with M1's verdict-specialist check, replacing the
literal-name restriction without adding an argument. Do not export the Flow's private
constant merely to satisfy an imagined existing caller. Test a mismatch and a matching
non-default specialist in the ingress helper; this does not register a new specialist Flow.

Amend `docs/adr/0034-review-resolutions-enter-as-verified-durable-envelopes.md` to state
both entitlement cases, owner precedence, and the trusted queue-writer boundary. The
public UUIDv5 commits to receipt fields and the resolution id, detects inconsistent ids,
and cannot prove authenticity against a writer who can recompute it. It is not a digest
of the complete resolution payload. Correct the claim that generic addressed messages
cannot claim authority merely by adopting this shape: every ingress exposing arbitrary
addressed payloads must restrict resolution envelopes to trusted verified admission;
this plan does not add a cryptographic signature or a public adapter. Explain that an
owner-entitlement rejection can follow a journaled read but precedes writes and sinks.

In `docs/user/architecture-practice-reviews.md`, update the "Resolve a review" paragraph
and example together: outer version 2, nested resolution version 1, and the explicit
`entitlement` field. State the owner-or-authority rule, empty default, config/environment
names, and the need for a deployment authentication adapter because no production caller
is currently wired. Preserve plan 62's callout if already present. Keep user-document
frontmatter and `docs/user/log.md` consistent using the established OKF log workflow;
run `just user-docs-validate`. Check the configuration page and ADR for stale version-1
or tamper-resistance claims.


## Concrete Steps


All commands run from `/Users/shinzui/Keikaku/bokuno/shikigami`. Use the Nix development
shell for the native linker dependencies. The PostgreSQL suite's
`withShikigamiMigratedSuite` provides isolated migrated database fixtures; it does not
require a manually started development cluster. Save the pre-implementation revision
once and use it as the gate base even after committing on the current branch.

```bash
plan61_base=$(git rev-parse HEAD)
nix develop -c cabal build all
nix develop -c cabal test shikigami-core-test -j1 --test-options='--num-threads=1 -p "application configuration"' --test-show-details=direct
nix develop -c cabal test shikigami-core-postgres-test -j1 --test-options='--num-threads=1 -p "practice review"' --test-show-details=direct
nix develop -c cabal test all -j1 --test-options=--num-threads=1 --test-show-details=direct
nix develop -c just keiro-gate "$plan61_base"
just user-docs-validate
git diff --check
```

Confirm the focused test filters select the intended groups rather than passing with no
tests. The new ingress tests must demonstrate owner and authority admission plus refusal
without enqueue; the Flow tests must demonstrate refusal before resolution and replay
without live authorization. Both existing and new cases must report `OK`.

`just keiro-gate` should report no practice-review structural findings because no labels
or result codecs change. Do not weaken the gate to accommodate an unexpected finding;
resolve it under the workflow-versioning rules. This gate does not establish absence of
version-1 deployment state. Record that separately before the codec change.

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
does not contain `token`. The actual enqueue path, not just receipt construction, must
prove these outcomes. Subject mismatch, authorizer refusal, missing/malformed review,
wrong specialist, and malformed source never enqueue. Missing or unknown entitlement
is rejected when decoding an envelope; ingress computes entitlement rather than accepting
it from the submitter. Owner wins
when both policy cases apply, and a review without a recommended owner admits only an
authority. Version 2 round-trips, version 1 is explicitly refused under the verified
unused-state prerequisite, and the frozen v2 UUID is stable. Replay preserves both
entitlement cases after live authority changes. The full suite, workflow gate, and user
document validation pass; document the results and any rollout limitation.


## Idempotence and Recovery


All edits are local rewrites and additive tests; rerunning fixture-based suites is safe.
The version bump is conditional on the deployment-state check, not on test database
cleanup. Do not reset a developer or deployment database to manufacture that evidence.
If version-1 state must survive, stop the incompatible codec change and revise the rollout.
After version-2 admission begins, rolling back to version-1-only code cannot decode those
queued envelopes; prefer a forward fix and retain the admitted receipts.

Retries read the immutable original provisional verdict, even after retirement, and keep
the existing queue idempotency key and memory conflict handling. Adding entitlement must
not overwrite previously adjudicated memory or bypass its concurrency rules. A failed
config parse never falls back to permissive defaults. No domain declaration or generated
file change is expected; if one becomes necessary, follow the workflow-versioning gate.


## Interfaces and Dependencies


`Shikigami.PracticeReview.Authorization` exports `ResolutionEntitlement (..)`, opaque
`ResolutionAuthorities`, its empty/parser/renderer helpers, the widened error type and
receipt field selectors, and the revised constructor and enqueue boundary. The final
boundary type is:

```haskell
enqueueAuthorizedPracticeReviewResolution ::
  Pool ->
  (ReviewId -> IO (Either ReviewMemoryError ValidatedPracticeReviewVerdict)) ->
  ResolutionAuthorities ->
  AgentIdentity ->
  Text ->
  ReviewResolutionAuthorizer ->
  PracticeReviewResolution ->
  ResolutionSubmissionEvidence ->
  IO (Either ResolutionAuthorizationError MessageId)
```

The `Text` argument remains the specialist target, checked against the original verdict.
`ReviewResolutionAuthorizer.authorize` returns verified facts as specified in M1;
ingress alone derives entitlement and constructs the receipt.
`Shikigami.PracticeReview.Memory` exports `loadProvisionalVerdict` and the pure
`provisionalVerdictFromChain`; the Flow never calls the IO loader.
`Shikigami.App.Config` exports `practiceReviewResolutionAuthoritiesKey` and the field.
No dependency version changes are planned. If implementation needs an unfamiliar
external API, use Mori to locate its source and documentation before choosing it; verify
registry releases and upstream tags before changing dependency bounds.

The review records this plan answers are
[REV-4](../reviews/practice-review-resolution-authorization.md) and the "who may resolve"
requirement of [REV-7](../reviews/architecture-practice-reviews-user-guide.md).

Revision note (2026-10-29): refreshed against current code and PostgreSQL suite layout;
corrected the existing target argument, absent ingress tests, typed lookup failures,
version-retirement prerequisite, replay checks, source validation, and receipt integrity
claims while retaining the three-milestone scope.
