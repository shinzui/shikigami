---
id: 10
slug: sanctioned-execution-attestation-for-agent-runs
title: "Sanctioned Execution Attestation for Agent Runs"
kind: master-plan
created_at: 2026-08-05T14:51:43Z
intention: "intention_01kz96h79mezmbnwm67pdjjepr"
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T18:24:04Z
      mode: "update"
      note: "Reconciled status and progress during the 2026-09-21 portfolio audit"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T21:09:33Z
      mode: "update"
      note: "Refresh current code, completed prerequisites, shared ownership and genuine remaining acceptance; preserve historical decisions."
---

# Sanctioned Execution Attestation for Agent Runs

This MasterPlan was refreshed against `ff00b819` on 2026-11-06. Three children are
Complete; the signing/served-verification child remains Not Started.

## Vision & Scope

An external verifier must be able to establish that a trusted runtime reviewed an exact
immutable change under a pinned sanctioned profile, with complete actual-call evidence,
agent artifacts and result bound by a signature. The key must be outside agent authority;
a bounded authorized API and offline proof must preserve historical verification after
rotation. The claim is runtime-attested observation, not independent proof of hidden
provider computation. Kotei retains merge-policy enforcement.

The profile/envelope vocabulary, fail-closed profile pinning and durable evidence/compliance
are implemented. Canonical payload bytes and digest already exist. Signing, key isolation,
rotation, attestation persistence/API/offline verification and full UC-8 proof remain.
This initiative does not create governed evolution, a content plane or a second provider/
resource ledger.

## Decomposition Strategy

Retain four ownership boundaries: pure vocabulary (49), profile admission (50), evidence
and roll-up (51), signed/public/offline conformance (52). Keep signing/API/verifier together
because they share one immutable envelope and the same end-to-end acceptance. Plans 49–51
are accepted foundations, extended by later actual-attempt/runtime work; plan 52 must consume
their existing functions and exact provider JSON rather than recreate them.

Relevant durable context is
[ADR 0006](../adr/0006-the-attestation-payload-encoding-is-a-wire-format.md),
[ADR 0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md),
[ADR 0010](../adr/0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md),
[ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md),
[ADR 0093](../adr/0093-review-entities-are-allocated-behind-durable-request-receipts.md),
[ADR 0096](../adr/0096-decision-call-expectations-have-allocated-identities-and-positive-ordinals.md)
and [ADR 0110](../adr/0110-accepted-typed-decisions-account-for-every-transport-call.md).
The refresh changes no accepted architecture decision.

## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Profile and attestation contracts | docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md | None | None | Complete (2026-08-19) |
| 2 | Fail-closed profile resolution and pinning | docs/plans/50-fail-closed-profile-resolution-and-run-pinning.md | EP-1 | None | Complete (2026-08-19) |
| 3 | Run evidence and compliance roll-up | docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md | EP-1, EP-2 | None | Complete (2026-08-19) |
| 4 | Signed attestation, read API and UC-8 | docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md | EP-3 | None | Not Started (shared golden contract and live positive acceptance remain open) |

Statuses are Not Started, In Progress, Complete and Cancelled. Local prerequisites
22/28/36–39/44 are accepted. The old Baikai-0.5/Kioku-0.3 bound and proposed evidence
API are no longer start gates. Shared-format acceptance still requires Kikan IR-6.

## Dependency Graph

EP-1 → EP-2 → EP-3 → EP-4 retains the original order, with EP-3 also consuming EP-1.
Current sources provide canonical encoding/hashing, reviewed-artifact types, encode-only
provider evidence and restartable compliance facts. Baikai IR-3 is completed and adopted;
it is not another upstream blocker. The selected releases are Baikai 0.10.0.0, Kioku
0.12.0.2 and Keiro 0.22 under index `2026-11-03T12:48:57Z`.

`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6` remains proposed and must
ratify signed envelope/schema/algorithm/redaction rules and golden payloads before shared
canonical conformance is accepted. Local preparation/fixtures cannot claim that acceptance.
The real-provider positive case remains separately required, including plan 13's existing
transferred live-proof obligation. Missing credentials do not imply missing provider APIs.

Plans 83/84/96 now deliver accepted execution and governed workspace containment; qualify
signer key exclusion against those real adapters and the one-off path. Plan 48's older
portable harness is lineage, not a currently absent substrate gate.

## Integration Points

**Envelope/artifacts.** Core Attestation/Envelope.hs, Agent.hs and Reviewed.hs own versioned
payload, agent artifact identity, reviewed repository/revision and canonical bytes/digest.
EP-4 must preserve those bytes or explicitly version the signed format. Future agent evolution
extends the same identity vocabulary; ordinary unsigned runs do not gain reviewed artifacts.

**Actual-call evidence.** Evidence/Compliance/EvidenceStore and Decision/Evidence retain
expectations, terminals, exact provider JSON and normalized compliance facts. Current
accepted/root-accounted decisions separately preserve resource holds. EP-4 consumes sealed,
complete eligible coverage, including child/uncertain calls, and never treats today's
library version or configured model as evidence for historical execution.

**Review identities.** PracticeReview/IdentityStore and Memory allocate application entities
behind durable receipts. Distinguish run correlation, review entity, caller idempotency key
and technical commitment. The bounded by-review lookup uses the agreed exact identity;
it does not derive a new application UUID from review text.

**Catalog and capabilities.** Plans 56–59 own generic overlay descriptors, tool schemas and
pinned leases; plan 12 now owns only MCP-specific integration. Artifact catalog digests
consume those current owners and actual admitted snapshots. There is no agent-authored
mcpServers catalog to implement in this initiative.

**Signing/API.** EP-4 owns a distinct workload-signing credential boundary with real key
exclusion tests against behavior, local ProgramRuntime, accepted tools and workspace/one-off
processes. HTTP mounts through the existing authenticated umbrella route and retains package
boundaries: core domain/signing, api routes, server handlers and client commands. The offline
verifier uses trusted issuer material without database dependence. Never expose optional
unsigned internal records as verified public attestations.

**Storage and evolution.** Append schema-qualified migrations through the existing manifest
and reconcile required read models. Freeze immutable issuance/payload/signature and recover
that record on lost replies. Signed format changes require explicit schema/codec evolution;
Agent/Flow body changes follow the current workflow guide and strict gate.

## Progress

Three of four children are Complete. Plan 52 is refreshed around five remaining outcomes:
shared golden/schema conformance, trusted signing/persistence, rotation, authorized bounded
lookups/offline verification, and UC-8 mutation plus real-provider qualification. Source
contains canonicalPayloadBytes/attestationPayloadDigest but no signer, offline verifier
or attestation API route. No runtime or paid-provider proof was executed in this refresh.

## Surprises & Discoveries

The former plan-52 text asked to implement hashes/types already delivered and to lift
package bounds superseded several cohorts ago. It also treated Baikai evidence as still
proposed. The owner request is now completed, selected releases are verified on Hackage/
peeled tags, and local consumers already use evidence. Kikan IR-6 remains a real separate
gate; neither an unsigned compliance verdict nor Kotei's unrelated execution attestation
ratifies this review envelope.

## Decision Log

2026-11-06 refresh: retain the four ownership streams and signed/live/shared acceptance;
credit delivered canonical/provider/identity/workspace foundations, remove obsolete bounds
and upstream-evidence gates, and consume the current authenticated API and trusted-key
boundary. No signing algorithm or new dependency bound is selected by this refresh.

Historical rationale follows; absent-vocabulary/proposed-provider observations describe
their dates and are superseded by current Context and child plan 52.

- Decision: Give IR-7 its own MasterPlan rather than extending
  `docs/masterplans/9-architecture-practice-review-flow.md`.
  Rationale: MasterPlan 9 delivers an advisory, read-only review of Mori-addressed
  architecture decision records, returning one of five classifications and writing Kioku
  memory; its own Vision & Scope excludes policy enforcement. IR-7 is a signed gate over code
  changes at commit granularity with a cryptographic trust boundary and an external consumer
  at a merge gate. The one thing they share — revision-pinned reading — is better modeled as
  an integration point on plan 44's `EvidenceReader` than as a merged initiative.
  Date: 2026-08-05

- Decision: EP-1 defines `AgentVersionRef` and `AgentArtifactSet` now, rather than waiting for
  a governed-evolution plan to define them.
  Rationale: IR-7 cannot bind a run to an immutable agent version without them, plan 33 does
  not own them, and `docs/improvement-requests/governed-agent-evolution.md` has no ExecPlan
  and no MasterPlan. Waiting would push the whole initiative behind an unplanned request.
  Defining them in EP-1 with a lineage-ready additive shape — plus a test pinning that a
  record with no lineage encodes byte-identically to one written before lineage existed — means
  the governed-evolution work extends one vocabulary instead of reconciling two.
  Date: 2026-08-05

- Decision: EP-1 has no hard dependencies and is startable immediately, even though every
  other plan here is gated.
  Rationale: nine plans across MasterPlans 2 through 9 are about to define something IR-7
  binds. Landing the vocabulary first turns nine future reconciliations into nine citations.
  This is the same role `docs/plans/43-define-architecture-practice-review-contracts.md`
  plays for MasterPlan 9, and it is why that plan was also authored dependency-free.
  Date: 2026-08-05

- Decision: EP-2 and EP-3 hard-depend on
  `docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md`.
  Rationale: the pinned profile digest is a journaled workflow value and the run-evidence
  lifecycle is a durable state machine. Both are exactly what plan 39's checked specification
  and evolution gate govern. Hand-authoring them first guarantees a rewrite, and plan 39 is
  startable today, so the dependency costs ordering rather than time.
  Date: 2026-08-05

- Decision: EP-3 builds against a deterministic `ModelCallEvidence` seam with stub fixtures
  instead of waiting for baikai IR-3.
  Rationale: the aggregate lifecycle, the complete-accounting invariant across retries and
  delegated children, and the non-conformance taxonomy are all provable without a real
  provider observation. This mirrors how
  `docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md` handles its own
  pending upstream adapter, and it keeps a `proposed` upstream request off the critical path
  of three milestones.
  Date: 2026-08-05

- Decision: EP-4 mirrors kikan's `AgentRunAttestation` under an explicit local schema version
  and proves conformance against kikan's published fixtures, rather than importing a kikan
  package.
  Rationale: kikan IR-6 is `proposed`, so there is nothing stable to import, but the canonical
  encoding must eventually agree byte-for-byte. A versioned local mirror plus a golden-payload
  conformance test lets EP-1 and EP-4 proceed and makes divergence a test failure rather than
  a production mismatch.
  Date: 2026-08-05

- Decision: Signing is a distinct credential class layered on plan 22's resolution machinery,
  and its non-visibility is asserted by a test.
  Rationale: IR-7 invariant 5 and kikan IR-6 invariant 5 both require keys held outside
  agent-controlled behavior and mutable workspaces. Reusing plan 22 avoids a second secret
  mechanism; asserting non-visibility in a test rather than a comment is what makes the claim
  worth anything, since a signature produced by a process that could fabricate the evidence
  is weaker assurance.
  Date: 2026-08-05

## Outcomes & Retrospective

In progress. Profile enforcement and queryable evidence/compliance are delivered. Completion
still requires plan 52's signed portable proof with rotation, bounded authorized serving,
trusted offline verification, shared golden agreement and a real-provider positive case.

## Revision Notes

2026-11-06: Refresh selected evidence/cohort, canonical and allocated-identity ownership,
current execution/workspace/API dependencies and the genuine remaining signing acceptance.
