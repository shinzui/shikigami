---
type: Review
title: Practice-review resolution authorization boundary
description: The envelope binds a verified subject to a resolution and survives replay without a second authorizer call, but nothing in the runtime asks whether that subject is entitled to resolve this review, and the opaque credential type derives Show.
generated:
  by: process:claude-code
  at: "2026-08-27T00:12:00Z"
reviewId: REV-4
subject: mori://shinzui/shikigami
subjectKind: component
component: Shikigami.PracticeReview.Authorization
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
  - correctness
  - security
  - design
  - test-coverage
context: >-
  Read the complete module, ADR 0034, the resolution contract validator and
  memory interpreter it hands off to, the Flow's resolution branch, and the
  authorization tests; searched every package for a production caller of the
  enqueue boundary. Did not evaluate any concrete authorizer, because none
  exists in the tree.
---

# Practice-review resolution authorization boundary

## Verdict

Changes requested. The mechanism does what ADR 0034 says: a resolution is
validated, an injected authorizer returns a receipt, the receipt's subject
must equal `resolution.resolver`, the source must be a `mori://` or
`activity://` reference, and a UUIDv5 over the receipt fields and the
resolution id lets replay revalidate without contacting the authorizer. Bare
resolutions, unknown fields, mismatched subjects, and altered ids are refused,
and the tests prove each refusal. What the boundary does not do is decide
*who may resolve*. The verdict contract carries a `recommendedOwner`, a
`triageOwner`, and an `exceptionApprover` precisely so that ownership is
data, and no code path consults any of them when a resolution arrives.

## Required

1. **Enforce or explicitly delegate resolver entitlement.** With the current
   boundary any subject the authorizer authenticates can accept, reject,
   narrow, or supersede any review, because `validateReceipt` checks only
   that the subject equals the self-declared `resolver`, `resolutionErrors`
   checks only that `resolver` is non-blank, and `resolveReviewIO` checks
   only review-id agreement. The authorizer seam cannot enforce entitlement
   either: `authorize` receives the resolution and the submission evidence,
   not the review's owners. Either look the provisional verdict up at ingress
   and require the subject to match its recommended owner, triage owner, or
   exception approver, or state in ADR 0034 and the user guide that
   entitlement is the deployment authorizer's job and give the seam the data
   it needs.
2. **Remove the derived `Show` from `ResolutionSubmissionEvidence`.** The
   type is documented as opaque authentication material that never crosses
   the run-job boundary, and it carries a raw token. A derived `Show` puts
   that token one `show` away from any log line or exception message that
   renders the enclosing value. Derive nothing, or render a redacted
   placeholder.
3. **Say what the receipt's id does and does not protect against.** ADR 0034
   lists "altered receipts" among the refused inputs, and the test alters
   `authorizationId`. An adversary who can write to the run-job queue can
   recompute the id from the public preimage, so the id is an integrity
   check against accidental corruption, not tamper evidence; the plan says as
   much when it names the queue writer as the trusted boundary. The ADR
   should say it too.

## Follow-ups that do not block

- `enqueueAuthorizedPracticeReviewResolution` hard-codes the reviewer's
  manifest name while also taking an `AgentIdentity`. A second specialist
  will need the target to be data, and ADR 0033 argues the recorded principal
  should key it.
- `validateSource` accepts any text with the right prefix, including
  `mori://` alone. A canonical-reference check that at least demands a
  namespace and project would match what "canonical" promises.
- There is no production caller. `enqueueAuthorizedPracticeReviewResolution`
  is referenced only by this module and its tests; see REV-1 and REV-7.

## Evidence

- `Authorization.hs` lines 152-165 (`validateReceipt`), 167-173
  (`validateSource`), 175-188 (public preimage), 58-59 (`deriving stock (Eq,
  Show)` on the credential newtype), and 203-205 (hard-coded agent).
- `PracticeReview.hs` line 886: the resolver rule is `blankErrors`.
  `Memory.hs` `resolveReviewIO`: the only checks are provisional-id,
  envelope shape, and review-id agreement.
- `Capability.hs` and `OpenTelemetryPracticeReview.hs` never read
  `recommendedOwner` or `ReviewOwners` on the resolution path.
- `PracticeReviewOrchestrationSpec.hs` "authorized resolution" group: three
  cases passed at the reviewed commit, covering round-trip, subject mismatch,
  invalid source, altered id, and unknown fields.
- `grep -rn "enqueueAuthorizedPracticeReviewResolution\|ReviewResolutionAuthorizer"`
  across all package `src` and `app` trees matches only
  `shikigami-core/src/Shikigami/PracticeReview/Authorization.hs`.
