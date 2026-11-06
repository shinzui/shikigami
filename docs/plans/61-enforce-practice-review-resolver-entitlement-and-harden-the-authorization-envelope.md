---
id: 61
slug: enforce-practice-review-resolver-entitlement-and-harden-the-authorization-envelope
title: "Enforce practice-review resolver entitlement and harden the authorization envelope"
kind: exec-plan
master_plan: "docs/masterplans/9-architecture-practice-review-flow.md"
created_at: 2026-08-27T00:54:32Z
intention: "intention_01m10bc7hae8trp0ev5mzpvt0d"
provenance:
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-29T13:47:31Z
      mode: "update"
      note: "Refresh current source and PostgreSQL suite paths, ingress entitlement and target checks, typed lookups, replay and rollout prerequisites, and receipt documentation."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T21:09:33Z
      mode: "update"
      note: "Credit v2 ID-free/full-request/redaction work and refresh remaining entitlement through a new version and real ingress/replay owners."
---

# Enforce practice-review resolver entitlement and harden the authorization envelope

This living plan was refreshed against `ff00b819` on 2026-11-06. Owner-or-authority
entitlement is still unimplemented; later identity hardening already supplies several
original subtasks. This refresh changes no runtime code.

## Purpose / Big Picture

An authenticated resolver should adjudicate a review only when named among its
recommended owners or explicitly admitted by operator authority policy. Ingress records
which entitlement applied, and replay rechecks the owner case from retained provisional
content without contacting live authentication/configuration. Refusals enqueue nothing
and write no adjudication. Credentials and source references remain appropriately bounded.

## Progress

- [ ] M1: add owner/authority policy, verdict-bound target admission and entitlement in a newly versioned full-request receipt, with actual queue-boundary acceptance.
- [ ] M2: rederive owner entitlement from journaled provisional content before resolution, preserving retained authority admission and replay after live configuration changes.
- [ ] M3: retain existing credential redaction/request binding, tighten source coordinates, and update ADR/user/configuration documentation and rollout evidence for the new entitlement format.

Already delivered by plan 107/ADR 0093: redacted submission Show, schema-2 ID-free
resolution requests, full canonical request binding, allocated entity receipts and one
real ingress enqueue/refusal test. These do not enforce resolver entitlement and do
not complete M1–M3. The current v2 format must not be reused for different semantics.

## Surprises & Discoveries

`ResolutionSubmissionEvidence` currently renders exactly
`<resolution-submission-evidence>` and has no JSON instance. The old claim that it
still derives Show is false. `authorizationEnvelopeSchemaVersion` is already the closed
`AuthorizationV2`, and its UUIDv5 binds the full request, authority kind, subject,
source and time through `versionedDigest` domain `/2`. It is a binding checksum,
not a signature or independent authentication.

`enqueueAuthorizedPracticeReviewResolution` accepts `PracticeReviewResolutionRequest`,
which strictly rejects caller-selected resolutionId. Ingress authorizes before queue
publication; `PracticeReview/Memory.hs` allocates the final resolution after validating
the provisional review. `PracticeReviewOrchestrationSpec.ingressTests` exercises that
actual queue path. No recommended-owner/authority membership check exists, source
validation still accepts scheme-only prefixes and the target is a fixed reviewer literal.

## Decision Log

2026-11-06 refresh: preserve ADR 0093's allocated identities, v2 ID-free request and
full-request commitment; introduce entitlement through the next explicit envelope version
(v3), not by reusing v2. Preserve redaction and actual ingress coverage as regressions.
Default to compatible evolution for retained state; require fresh deployment/population
evidence before retiring any reader. The existing owner/authority and replay design stays.

Historical decisions follow. Instructions to create v2, derive a ResolutionId or bind
only the resolution id are superseded by ADR 0093 and the current Plan of Work.

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

Not complete. Credential rendering/request-binding/allocation/queue-admission foundations
are now delivered. Entitlement, stronger source validation, new-version rollout and the
expanded real ingress/Flow replay matrix remain. No runtime tests were rerun for this
refresh, and absence of an in-tree public adapter is not proof of unused deployment state.

## Context and Orientation

`shikigami-core/src/Shikigami/PracticeReview/Authorization.hs` owns the authorizer,
opaque submission, receipt, current v2 envelope and enqueue helper. Its current target
argument is Text but is parsed to AgentName before enqueue. Resolution requests live in
`PracticeReview.hs`; use `ValidatedResolutionRequest` and `validatedResolutionRequestValue`,
not a constructor-selected application resolution entity. `PracticeReview/IdentityStore.hs`
and Memory.hs own entity allocation and idempotency receipts.

`Flow/OpenTelemetryPracticeReview.hs:resolveAuthorized` validates the envelope, obtains
its provisional chain through a journaled memory effect, then calls `resolveReview` with
the validated ID-free request. `ResolvedPracticeReview` returns memory and allocated
resolution so history uses the authoritative entity. `recommendedOwner` is part of the
validated provisional verdict; its principal values are opaque checked OwnerPrincipal.

`App/Config.hs` owns settings, renderers and explicit environment bindings.
`practice_review.attention_recipients` is the existing pattern for a boot-validated
mapping; there is no resolution-authorities setting yet. AppConfigSpec's surface and
strictness controls must remain complete. All source paths above are under
`shikigami-core/src/Shikigami/`.

Integration fixtures live in
`shikigami-core/test-postgres/Shikigami/PracticeReviewOrchestrationSpec.hs`,
`PracticeReviewMemorySpec.hs` and `AgentWorkflowSpec.hs`. They own disposable migrated
databases. Use the actual ingress fixture, not only manually constructed receipts.
Read [ADR 0034](../adr/0034-review-resolutions-enter-as-verified-durable-envelopes.md),
[ADR 0031](../adr/0031-practice-review-adjudication-is-a-logical-memory-transition.md),
[ADR 0092](../adr/0092-review-values-are-checked-and-source-citations-use-structured-coordinates.md),
[ADR 0093](../adr/0093-review-entities-are-allocated-behind-durable-request-receipts.md)
and [workflow versioning](../workflow-versioning.md). They retain distinct caller keys,
entity ids, evidence citations, technical commitments and trusted queue-writer authority.

## Plan of Work

### M1 — Admit entitlement through the actual ingress

Add a closed `ResolutionEntitlement` with recommended-owner and configured-authority
cases. Create opaque ResolutionAuthorities with empty default, checked principal parsing,
canonical sorted rendering and duplicate/empty-element refusal. Add
`practice_review.resolution_authorities` and explicit binding
`SHIKIGAMI_PRACTICE_REVIEW_RESOLUTION_AUTHORITIES` through AppConfig. Whitespace-only
means empty; `a,,b`, `a,a` and `a, a` refuse. Empty policy admits only owners.

Narrow the injected authorizer to return verified identity facts (authority kind,
subject, source and time), not an entitlement selected by the caller. Validate the
request and authenticate/compare the verified subject before loading any review.
Load the exact immutable original provisional via a typed owner loader in Memory.hs;
preserve absent, malformed, refused and store-failure distinctions. The loader must allow
a retired provisional for an idempotent retry. Check review id/creator context and the
supplied specialist against the stored verdict's specialist, rather than comparing two
caller-controlled target strings. Use current AgentName/OwnerPrincipal/refined values.

Derive entitlement from the authenticated subject: recommended-owner membership wins,
otherwise configured authority wins, otherwise refuse. No selected owner allows only an
authority. Record that decision in a v3 receipt and include it in the versioned full-request
commitment; retain all current canonical request fields and exclude allocated resolutionId.
Never default a missing entitlement to authority. Add a closed AuthorizationV3 codec and
new commitment domain. Before exclusivity, record current deployment/journal/queue/wire
populations; preserve a real compatible reader/branch if prior v2 work must survive.
A source-only scan or ADR 0027's historical reset cannot authorize dropping v2.

Extend the real ingress test: persist an actual provisional through the memory owner,
call enqueue with a counting authorizer and decode the RunJob/envelope. Cover owner,
authority, owner precedence, absent owner, unrelated resolver, subject mismatch, auth
refusal, malformed/missing/wrong review and specialist mismatch. Every refusal leaves
queue counts unchanged; failed auth/subject comparison performs no ownership lookup.
A real admitted envelope must then execute through the Flow before expanding variants.

### M2 — Recheck retained owner facts during replay

Share a pure selector for the original provisional from the existing journaled chain.
Do not add an unjournaled IO ownership lookup inside the Flow. For owner-entitled v3
receipts require resolver membership in the retained recommended owner before
`practice-review-resolve`. Authority-entitled receipts consume retained admission and
never reread today's authority set. Both require the matching provisional and preserve
current allocated-resolution conflict/idempotency behavior.

Test a validly recomputed owner receipt for a non-owner to prove the policy check rather
than UUID mismatch; assert no resolved memory/history, allowing the journaled chain read.
Replay both admitted cases with authorizer/lookup unavailable and authority configuration
changed to empty. Suspend after chain recall and resume to prove the retained verdict is
used. Test genuine v2 retained inputs according to the selected rollout; the change may
not reinterpret their authority silently. Follow the actual domain/body baseline and
workflow-versioning gate, including unchanged result codecs and admitted identities.

### M3 — Source hardening and truthful operator contracts

Preserve the existing exact redacted Show and non-serializable submission; add regression
coverage if the new admission environment could expose it. Tighten source validation to
trim once, require exact mori/activity scheme and at least two nonempty path segments,
and reject scheme-only, double/interior/trailing slash and embedded whitespace forms.
Valid `activity://approval/1` and canonical Mori references remain accepted. This is
structural validation; the injected authorizer owns actual artifact/authentication proof.

Amend ADR 0034 consistently with ADR 0093: full-request binding detects inconsistency
but does not authenticate against a trusted queue writer who can recompute it. Record
owner precedence, empty-default authority and replay trust. Update the user guide and
configuration reference together to the implemented version and ID-free request; no
caller chooses ResolutionId. State that a deployed ingress adapter is still separate.
Use checked JSON fixtures and update user OKF timestamp/log/index through its workflow.

## Concrete Steps

From the repository root, save the pre-implementation baseline. Current dependency
versions need no change for this work. Run focused actual fixture groups and then full
applicable checks; keep PostgreSQL fixtures serial and independent of developer data.

```bash
plan61_base=$(git rev-parse HEAD)
nix develop --no-write-lock-file -c cabal build all
nix develop --no-write-lock-file -c cabal test shikigami-core-test -j1 --test-options='--num-threads=1 -p "application configuration"' --test-show-details=direct
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-options='--num-threads=1 -p "practice review"' --test-show-details=direct
nix develop --no-write-lock-file -c cabal test all -j1 --test-options=--num-threads=1 --test-show-details=direct
nix develop --no-write-lock-file -c just keiro-gate "$plan61_base"
just user-docs-validate
git diff --check
```

A zero-case filter is not proof. A neutral structural diff also cannot prove codec,
authorization or deployed-reader compatibility. Record the selected rollout evidence
and actual refusal/replay outcomes at completion.

## Validation and Acceptance

The real queue boundary admits a recommended owner and configured authority with distinct
retained entitlement; owner takes precedence; unrelated subjects and invalid originals
never enqueue. Flow refuses a forged owner claim before writes and replays valid results
without live policy/authentication. New-version codecs reject missing/unknown entitlement
and preserve any required v2 behavior through an explicit strategy. Request/allocated-id
separation, full-request commitment and redacted credential behavior remain unchanged.
Source hardening and all policy/config/docs checks pass. This plan creates no public
ingress endpoint and makes no authentication claim from a checksum alone.

## Idempotence and Recovery

Keep current review/caller-key allocation receipts and exact-command conflict refusal.
Retries may read retired provisional content but cannot overwrite an adjudication or
change a retained entitlement. Do not clear databases to create unused-state evidence.
After v3 admission, old-only binaries cannot consume it; prefer forward repair with
retained readers. Authorization/store errors stop admission and never become authority.

## Interfaces and Dependencies

Authorization.hs owns entitlement, v3 receipt/codec, checked policy and typed ingress
errors. Memory.hs owns the typed provisional lookup and pure retained selector; the
Flow owns only pure replay validation. AppConfig owns the authority setting. Current
request/allocation interfaces and nominal types are supplied by ADRs 92/93, not recreated.
Plans 60/62/63 share the specialist source/fixtures and documents; preserve their work.
No external library or upstream release is needed. Original review obligations remain
[REV-4](../reviews/practice-review-resolution-authorization.md) and
[REV-7](../reviews/architecture-practice-reviews-user-guide.md).

## Revision Notes

2026-11-06: Credit redaction/full-request v2 binding, ID-free admission, allocated entities
and ingress tests already delivered. Replace obsolete v2/derived-ID/absence claims with
a v3 entitlement rollout, current memory/queue interfaces and unchanged owner/authority,
source-hardening and replay acceptance. Preserve dated rationale as history.
