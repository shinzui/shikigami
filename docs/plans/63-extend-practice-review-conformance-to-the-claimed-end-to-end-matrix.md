---
id: 63
slug: extend-practice-review-conformance-to-the-claimed-end-to-end-matrix
title: "Extend practice-review conformance to the claimed end-to-end matrix"
kind: exec-plan
master_plan: "docs/masterplans/9-architecture-practice-review-flow.md"
created_at: 2026-08-27T00:54:32Z
intention: "intention_01m10bc7hae8trp0ev5mzpvt0d"
provenance:
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T21:09:33Z
      mode: "update"
      note: "Refresh actual PostgreSQL fixtures and allocated identities while preserving the full missing integrated conformance matrix."
---

# Extend practice-review conformance to the claimed end-to-end matrix

This living plan was refreshed against `ff00b819` on 2026-11-06. Its five full
conformance outcomes remain unimplemented; later domain tests are credited separately.

## Purpose / Big Picture

Prove the advisory reviewer through its actual routed, profile-constrained, recorded-
identity and asynchronous sink-delivery boundaries. Existing direct Flow tests do not
establish that full path. The complete matrix must preserve allocation receipts and
replay while proving owner attention, history and unresolved delivery recovery.

## Progress

- [ ] M1: load both real proof declarations, route to the actual reviewer Flow and prove admitted child lineage and replay without duplicate children/evidence work.
- [ ] M2: provision and resolve the exact sanctioned-review profile through the current owner and prove constrained evaluation plus missing-profile refusal.
- [ ] M3: real receipt/outbox publication against controlled Kawa/Kizashi stubs covers retry, permanent rejection, lost acknowledgement, payloads and reservation preservation.
- [ ] M4: verified, compatibility and unresolved legacy identities exercise memory, grants, Kawa actor and attention intent, including manifest change before replay.
- [ ] M5: the semantic-key material-change/label-permutation matrix passes after plan 60, and plan 46 records the exact newly accepted cases.

The current source adds real ingress and corrupt-retained-attention controls beyond the
original nine cases. Those delivered tests remain regressions; none closes a milestone
above by itself. Plan 62 supplies a checked profile artifact; plan 61 supplies entitlement.

## Surprises & Discoveries

The entire runtime suite now lives in `shikigami-core/test-postgres/`, with the pure
review/evidence contracts still under test/. `PracticeReviewOrchestrationSpec` has a
real ingress enqueue test and a corrupt retained-result rollback test. Current request
and entity identity ownership is ADR 0093, not deterministic ReviewId/ResolutionId factories.

The production reviewer remains a constrained Flow with a fail-closed unavailable content
reader. The existing direct fixture's absence of a resolved sanctioned profile cannot
prove the real proof declaration's profile requirement. Generic sink and identity tests
are useful components but do not substitute for an attention reservation coupled to
those paths.

## Decision Log

2026-11-06 refresh: retain five outcomes, reuse the current PostgreSQL fixtures and
allocated identities, preserve the real ingress/corruption controls, and model unknown
delivery through the actual publisher/receipt failure window. Existing coverage is
regression evidence, not the missing whole matrix.

Historical decomposition rationale follows; old test-tree paths and literal line numbers
are superseded by Context. The fixture reuse and key-version ordering remain applicable.

- Decision: Build on the fixtures that already exist rather than a new harness:
  `withFixtureUsingTracer` in `SinkDeliverySpec.hs` for publisher-backed delivery,
  `kawaDoorwayApplication` in `shikigami-core/test/Main.hs` for Kawa deduplication,
  `kizashiApplication` in `ApprovalNotificationSpec.hs` for scripted Kizashi statuses, and
  `insertProfile` in `ProfileResolutionSpec.hs` for profile rows.
  Rationale: plan 46 asked for "the existing outbox publisher, and Warp Kawa/Kizashi
  stubs"; those stubs exist and are trusted by other suites. Sharing them keeps one
  definition of each external contract.
  Date: 2026-08-27.

- Decision: The key-variation matrix in M5 assumes plan 60's version-2 projection.
  Rationale: with claim ids in the key, the "same claims, different labels coalesce" case
  cannot pass; sequencing this plan after plan 60 avoids writing a test that encodes the
  wrong contract.
  Date: 2026-08-27.

## Outcomes & Retrospective

No milestone is complete. This documentation refresh inspected current code and retained
acceptance but ran no new conformance fixture or live reader. The future matrix below
continues to answer REV-1/2 without treating original overclaims as proof.

## Context and Orientation

`shikigami-core/test-postgres/Shikigami/PracticeReviewOrchestrationSpec.hs` defines
`specialistAgentRunDeps`, `runPracticeReviewInput`, classification/identity/replay/
reservation fixtures and `ingressTests`. Neighboring RouterWorkflowSpec,
ProfileResolutionSpec, AgentWorkflowSpec, SinkDeliverySpec and ApprovalNotificationSpec
supply real owner fixtures. Locate helper definitions in their current tree before
extracting common fixtures; do not import executable Main from a library test helper.
Register new reusable helpers in the owning Cabal suite and entry point.

Production owners are `Flow/OpenTelemetryPracticeReview.hs`, `PracticeReview/Capability.hs`,
`Memory.hs`, `Attention.hs`, `Authorization.hs`, `IdentityStore.hs` and `Sink/Intent.hs`/
`Delivery.hs`, under `shikigami-core/src/Shikigami/`. Current domain declarations are in
`domain/shikigami/agent-run.keiro`, not the removed root-level file.
The allocation owner reserves review identity before decoding a model proposal and
allocates an ID-free resolution only after matching the provisional review. Use those
actual receipts; do not invent entities or duplicate private constructors in fixtures.

Read [ADR 0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md),
[ADR 0033](../adr/0033-recorded-agent-principals-key-durable-state.md),
[ADR 0035](../adr/0035-practice-review-attention-reserves-semantics-not-delivery-state.md),
[ADR 0092](../adr/0092-review-values-are-checked-and-source-citations-use-structured-coordinates.md)
and [ADR 0093](../adr/0093-review-entities-are-allocated-behind-durable-request-receipts.md).
`RunJob.identity` controls recorded reviewer behavior, not the authenticated resolver.

## Plan of Work

### M1 — Route the real declarations

Load `agents/proof/architecture-practice-router.dhall` and
`agents/proof/opentelemetry-practice-reviewer.dhall` through the actual loader. Use the
real candidate catalog and a controlled routing evaluator selecting the reviewer, normal
AgentRun admission, governed delegation and the actual review Flow. Retain both router
candidates rather than silently narrowing the catalog. The child verdict must bind the
recorded parent workflow/session and current child identities. Read allocated review
identity from its retained owner result, not a deterministic fixture factory.

Prove replay does not spawn a second child, allocate a second review or reacquire accepted
evidence. Keep noop-summary router helpers for cases needing only a successful child;
add a real reviewer variant rather than replacing unrelated routing semantics.
M2's profile can be developed first, or M1 can resolve the same valid profile through a
controlled owner fixture until M2 proves the store path.

### M2 — Exercise the real profile boundary

Provision `sanctioned-review` version 1 through the actual store/installation operation,
using plan 62's artifact when available. If developed earlier, use a validated owner
fixture with exactly the same requirement; reconcile it when the artifact lands.
Use real profile resolution and the proof declaration, not `sanctionedProfile = Nothing`.
The controlled evaluator observes the constrained environment. Missing/expired/drifted
profile must refuse before evidence/evaluation; a planted process-default model cannot
silently replace admitted selection. Assert store/durable facts, not merely validator success.

### M3 — Couple reservation and delivery recovery

Use real prepared intents, outbox publisher and sink receipts with bounded in-process
Warp stubs. Extract reusable stub helpers from their current fixture modules where useful.
Run an actionable review, then exercise transient 500 followed by acknowledged success,
permanent 4xx rejection, and a lost acknowledgement/receipt-persistence window that the
current delivery owner classifies as unknown. A malformed response alone is not assumed
to create unknown: choose and assert the real owner transition.

For every case assert the reservation/association, same outbox/receipt identity and
expected publisher outcome. Record actual HTTP attempts separately from one logical
notification; transient failure plus success naturally requires more than one request.
An equivalent second review coalesces without reserving/enqueueing another attention item.
Dead or unknown delivery never releases the reservation. Reconcile unknown acceptance
using independent downstream evidence rather than blind redispatch.

Redeliver Kawa history and assert one stored `(source, source_event_id)`/activity identity.
Decode payload/context refs and exact cited immutable artifacts; unresolved-before-content
has only refs the implementation actually emits. Preserve reviewer identity and bounded
semantic fields. Exercise all five classifications, both exception-approval branches and
four authorized resolution outcomes through the applicable real owners.

### M4 — Exercise recorded identity and authority

Verified identity uses the recorded principal for memory scope/actor, grant lookup, Kawa
actor and attention intent. Compatibility identity uses the explicit disabled-directory
path. Unresolved legacy identity refuses before review memory/sinks/reservation. Reuse
current checked identity factories and directory fixtures. Change/rename the live manifest
after an admitted run and replay it; original recorded coordinates and effects remain.
Keep the specialist's read-only effect/declaration boundary: no repository mutation,
merge blocking or extra action authority appears in the test environment.

### M5 — Prove semantic equivalence and record coverage

After plan 60's accepted projection/renderer change, vary classification, material statement,
materiality, cited content hash, owner role/recipient mapping and recommended action and
require a new key when the normalized dispute changes. Rename/swap labels and reverse
multi-claim/evidence order without changing semantic content and require the same key.
Keep current citation-label/allocated-entity distinction and frozen namespace rules.
A one-claim test cannot establish label-independent sorting.

Append actual named acceptance to plan 46 and this plan's Outcomes. Do not rewrite the
immutable historical reviews or claim a live content-plane result from hermetic evidence.
Include plan-61 ingress entitlement/refusal regressions when its versioned format lands.

## Concrete Steps

Run from the repository root with fixture-owned disposable databases. These are future
conformance commands, not claims of execution by the refresh:

```bash
plan63_base=$(git rev-parse HEAD)
nix develop --no-write-lock-file -c cabal build all
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-options='--num-threads=1 -p "practice review orchestration"' --test-show-details=direct
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-options='--num-threads=1 -p router' --test-show-details=direct
nix develop --no-write-lock-file -c cabal test all -j1 --test-options=--num-threads=1 --test-show-details=direct
nix develop --no-write-lock-file -c just keiro-gate "$plan63_base"
git diff --check
```

The focused command must select the newly named groups. Where relevant, verify a
negative control fails at the actual protected boundary. An unexpected runtime repair
belongs in its existing owner, not a weakened test or fabricated success transcript.

## Validation and Acceptance

All five outcomes must have actual passing owner-integrated cases: routed real reviewer,
provisioned profile, coupled receipt/recovery matrix, three recorded identity kinds and
semantic key equivalence. Preserve existing allocation, full-request ingress, corrupt
retained-result, classification, resolution and replay controls. The full applicable
suite and workflow gate pass at the final candidate, and plan 46 identifies precisely
which earlier coverage gaps are closed. Live Kikan acquisition remains separate.

## Idempotence and Recovery

Use suite-owned fresh databases and bracketed Warp servers. Repeat runs cannot share
ambient profile/workflow state. Preserve allocation and receipt keys across interrupted
retries; never clear reservations to make a delivery succeed. No production format change
is planned here. Any necessary Agent/Flow change follows workflow versioning and its
actual baseline, even if a structural diff appears neutral.

## Interfaces and Dependencies

This child owns tests, reusable fixtures and coverage reporting. Existing production
ports stay authoritative. Plan 60 gates the v2 semantic-key matrix; plan 61 owns resolver
entitlement and its own next-version codec; plan 62 owns the installable profile artifact.
M1–M4 may develop against real existing owner fixtures without claiming those absent
contracts are accepted. The local dependency versions are already sufficient; no new
library, upstream work or live credential is needed for deterministic conformance.

## Revision Notes

2026-11-06: Refresh PostgreSQL suite/helper paths, allocated review/resolution contracts,
current ingress/corruption controls and profile/delivery semantics. Preserve all five
missing outcomes, distinguish transport attempts from logical notifications, and remove
invented exact-output and old deterministic-ID assumptions.
