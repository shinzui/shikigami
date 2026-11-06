---
id: 52
slug: signed-attestation-read-api-and-uc-8-conformance
title: "Signed attestation, read API, and UC-8 conformance"
kind: exec-plan
created_at: 2026-08-05T14:53:02Z
intention: "intention_01kz96h79mezmbnwm67pdjjepr"
master_plan: "docs/masterplans/10-sanctioned-execution-attestation-for-agent-runs.md"
provenance:
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T21:09:33Z
      mode: "update"
      note: "Refresh existing canonical/evidence/identity/API/workspace foundations and retain shared golden, signing and live proof."
---

# Signed attestation, read API, and UC-8 conformance

This living plan was refreshed against source checkpoint `ff00b819` on 2026-11-06.
Signing and served attestations remain unimplemented. This is a documentation refresh.

## Purpose / Big Picture

Make a completed sanctioned review verifiable without Shikigami's database. A signed
attestation must bind the immutable reviewed change, profile, agent artifacts, complete
actual-call evidence and review result. The signing key stays outside behavior, prompts,
tools and writable workspaces. A bounded authenticated read API returns the same retained
record by run or review-request identity; an offline verifier checks the exported proof
against trusted verification material. Rotation preserves old verification.

The trust claim is runtime-attested observation, not proof of hidden provider computation.
Unknown schemas, issuers, algorithms, incomplete coverage and altered artifacts fail closed.
Kotei's enforcement remains owned by
`mori://shinzui/kotei/okf/improvement-requests/concepts/IR-2`.

## Progress

- [ ] M1: reconcile the implemented canonical bytes/digest and schema metadata with the ratified Kikan envelope and golden payloads; preserve existing wire fixtures.
- [ ] M2: sign only eligible sealed evidence through a trusted key boundary, persist one immutable attestation identity, and prove key exclusion from current behavior/execution/workspace paths.
- [ ] M3: rotate signing keys while historical attestations retain their original bytes, digest and verification.
- [ ] M4: serve bounded authorized run/review lookups with generated OpenAPI and export a self-contained verifier input that verifies with the database unavailable.
- [ ] M5: pass the complete UC-8 mutation/refusal matrix and an explicitly authorized real-provider positive case, including plan 13's transferred live proof.

Local plans 49–51, 22 and 44 are complete. `canonicalPayloadBytes` and
`attestationPayloadDigest` already exist in Envelope.hs. Their existence is delivered
foundation work, not acceptance of M1's still-missing shared golden conformance.
The former Baikai 0.5/Kioku 0.3 bounds gate is superseded by the selected cohort.

## Surprises & Discoveries

On 2026-11-06, `AgentRunAttestation` still has optional signature/keyId fields with an
explicit comment assigning signing to this plan. `ShikigamiApi` serves health, agents,
objectives and OpenAPI; it has no attestation route. No Sign/Offline implementation or
attestation persistence migration is present. The existing canonical functions already
call Baikai's `canonicalEncode` and `commitmentDigest`; no new hashing implementation
is needed. `ReviewedArtifact` already uses the shared repository/revision vocabulary.

The selected Baikai is 0.10.0.0 with Kioku 0.12.0.2 and Keiro 0.22. Hackage and peeled
upstream tags confirm those selected releases. Baikai's preferred version is now
0.10.1.0; that observation does not select an upgrade. Real provider evidence APIs and
normalized restartable facts are adopted locally. The remaining shared contract is
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6`, whose owner still says
proposed; local round-trip/golden tests cannot stand in for ratified cross-project fixtures.

## Decision Log

2026-11-06 refresh: retain the five milestones, signing isolation and shared envelope
contract. Adopt the canonical implementation already delivered by plans 49–51, current
allocated review identities and current execution/workspace owners. Remove the old
package-bound and placeholder-type work; preserve the real-provider and golden gates.

Historical rationale follows; package availability and absent-hash observations below
refer to their dates and are superseded by the current Context and Plan of Work.

- Decision: The signing key is a distinct credential class layered on the outbound-authentication
  machinery, and its non-visibility is asserted by a test rather than documented in a comment.
  Rationale: both the local request and the shared upstream contract require keys held outside
  agent-controlled behavior and mutable workspaces, and the request is explicit that a signature
  produced by the same unrestricted process that may fabricate the evidence offers weaker
  assurance. A comment saying the key is unreachable is worth nothing; a test that fails when it
  becomes reachable is worth something.
  Date: 2026-08-05

- Decision: Canonical encoding is a named function with sorted keys and no insignificant
  whitespace, not `encode`.
  Rationale: the digest has to match a hash computed in another repository, possibly in another
  language. Aeson's default object key order is not a stable cross-implementation contract. Making
  the encoding explicit turns a future library upgrade from a silent digest change into a compile
  or test event.
  Date: 2026-08-05

- Decision: Use `Baikai.Evidence.canonicalEncode` as that named function rather than writing one
  here, and build `attestationPayloadDigest` on `commitmentDigest`.
  Rationale: the requirement above is exactly right and `baikai 0.5.0.0` now satisfies it, so the
  only question left is who owns the implementation. Baikai's `canonicalEncode` "gives a JSON
  value exactly one byte representation (object keys sorted, no insignificant whitespace, numbers
  normalised so `1`, `1.0`, `1.00`, and `1e0` all encode as `1`, and a hand-written string escaper
  so an aeson upgrade cannot silently invalidate a recorded digest)". The number normalisation and
  the hand-written escaper are both things a from-scratch implementation here would plausibly have
  missed on the first pass and discovered as a digest mismatch against another implementation
  later — which is the single failure this decision exists to prevent. Sharing the encoder with
  the library that produces the call evidence also removes a whole class of disagreement: the
  evidence records and the attestation that covers them are canonicalised by the same code.
  Date: 2026-08-10

- Decision: Keep `commitmentDigest` and `configurationDigest` distinct rather than collapsing to
  one hash.
  Rationale: baikai separates them deliberately — `commitmentDigest` hashes a full request
  envelope and binds a record to one particular request, while `configurationDigest` hashes an
  allow-list projection (`configurationProjection`) that keeps configuration and replaces content
  with structural summaries, so two calls that ask the same model the same way about different
  subjects agree. The attestation signature must cover the first: an auditor's question is "is
  this attestation about this exact run". A compliance comparison across runs that legitimately
  differ in content wants the second. Collapsing them would make one of those two questions
  unanswerable.
  Date: 2026-08-10

- Decision: The read API is one field on the existing umbrella route record, not a separate
  service.
  Rationale: `shikigami-api/src/Shikigami/Api.hs` states the repository's convention — one record
  whose fields are endpoints, from which the server, the typed client, and
  `docs/api/openapi.json` are all derived, so a route cannot be served without appearing in the
  document. Adding a vertical means adding one field. A separate service would break that
  property.
  Date: 2026-08-05

- Decision: Key rotation is proven by verifying a pre-rotation attestation after rotating, not by
  re-signing history.
  Rationale: re-signing would change historical payload digests, which is exactly what an auditor
  must be able to rely on not happening. Verification therefore resolves the key by the key id
  recorded in the attestation, and retired keys stay resolvable for verification while being
  unusable for signing.
  Date: 2026-08-05

## Outcomes & Retrospective

Not complete. Source inspection credits existing canonicalization, profile/evidence and
review contracts. Signing, rotation, served/offline proof and full live conformance are
still acceptance work. No cryptographic implementation, build or paid provider trial was
performed by this refresh.

## Context and Orientation

`shikigami-core/src/Shikigami/Attestation/Envelope.hs` owns `AttestationPayload`,
`AgentRunAttestation`, canonical bytes and digest; Profile/Resolve own pinned policy,
Evidence/Compliance/EvidenceStore own lifecycle, roll-up and atomic projections.
`Decision/Evidence.hs` retains actual-call expectations, exact encode-only Baikai JSON
and normalized compliance facts for restart. Do not decode provider JSON using an
invented FromJSON instance or reconstruct history from today's defaults.

`shikigami-core/test/Shikigami/AttestationContractsSpec.hs` and
`shikigami-core/test-postgres/Shikigami/RunEvidenceSpec.hs` are the existing contract
and persistence consumers. Plans 73–76 and 81–85 extend actual-attempt accounting;
unsigned generic Flow reports do not acquire a reviewed-artifact binding automatically.

`Shikigami.PracticeReview` and `PracticeReview/IdentityStore.hs` allocate review and
resolution entities behind durable receipts; distinguish those identities from caller
idempotency keys and technical UUIDv5 commitments. Reviewed content comes through the
existing `PracticeReview/Evidence.hs` public reader contract. Do not reintroduce plan 49's
removed placeholder revision types or mint a second review-id scheme.

`shikigami-api/src/Shikigami/Api.hs` is the one served route tree. Mount a new
attestation vertical through the existing `Authenticated` convention, typed NamedRoutes
and MultiVerb/problem responses, then update the server, typed client and OpenAPI from
that same proxy. Inspect `Shikigami.Caller.Api`, the agent/objective handlers and current
server environment to preserve access control. Workers must not import sibling API/server
packages. Signing/domain logic belongs in core or a separately justified trusted owner;
HTTP routes belong in api, handlers/administrative entry points in server/client.

The migration executable reads `DATABASE_URL`; use the existing manifest and
`reconcileShikigamiReadModels` rather than another migration runner. Native workspace
containment and current durable tool execution are delivered by plans 83/84/96 and their
real production adapters. Test key exclusion against these boundaries and the one-off
path, not merely an old portable-harness sketch.

Read [ADR 0006](../adr/0006-the-attestation-payload-encoding-is-a-wire-format.md),
[ADR 0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md),
[ADR 0010](../adr/0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md),
[ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md),
[ADR 0093](../adr/0093-review-entities-are-allocated-behind-durable-request-receipts.md)
and [workflow versioning](../workflow-versioning.md). Shared source is addressed by
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6` and
`mori://shinzui/kikan/okf/use-cases/concepts/UC-8`. Resolve those exact artifacts with Mori.

## Plan of Work

### M1 — Conform existing bytes to the shared contract

Read the selected Baikai source through Mori and preserve Envelope.hs's canonical
implementation and literal fixtures. Obtain Kikan's ratified envelope, evidence-schema
binding, algorithm/issuer/redaction rules and golden payloads before freezing a signed
format. Record their exact canonical artifact/release coordinates. If unavailable,
prepare local fixtures but leave cross-project acceptance open; do not invent a second
encoder or describe a local test as two-sided conformance.

Require the signed/exported proof to identify the evidence vocabulary it covers using
retained schema metadata, not whatever `evidenceSchemaVersion` today's library exports.
Current payload version and digest bytes are persisted contracts. If the agreed envelope
needs additional fields, introduce the explicit version/codec/compatibility strategy
before changing it. Complete matching local bytes/digest literals, unknown-version and
algorithm refusal cases. Existing repository/revision types are already shared.

### M2 — Sign sealed evidence outside agent authority

Implement `Attestation/Sign.hs` and a bounded trusted signing interface. Resolve a
workload credential separately from behavior/sink credentials; select and verify a
released signature library through Mori, registry and upstream tags before choosing a
bound. No signature algorithm or key-service API is assumed by this refresh. Match the
ratified issuer/algorithm contract and keep private keys non-serializable/redacted.

Consume the authoritative sealed evidence and roll-up, including all relevant terminal
children and unresolved expectations. Reject incomplete, unknown, mismatched or
nonconforming coverage as specified; never manufacture an artifact binding from a generic
run. Freeze the payload, issuance and attestation identity once and persist them with
canonical bytes, digest, signature, key/algorithm/verification coordinates and run/review
lookup keys. Retrying after a lost reply must recover the same record rather than create
a new issuance or re-sign changed data. Use additive schema-qualified migrations and
current read-model registration/projection rules.

Prove key exclusion using the actual BehaviorEnv, local ProgramRuntime, decision and
accepted-execution tool environments, prompts/config renderings, one-off execution and
configured workspace supervisor/child environment. Plant a distinctive test secret and
prove the behavior cannot access it through those interfaces. A render-only sentinel
scan does not prove process/filesystem containment. Qualify a separate trusted signer
where needed for the accepted boundary; retain the provider-vs-runtime trust distinction.

### M3 — Rotate without rewriting history

Resolve verification by the retained key id and trusted issuer policy, never today's
current signing key. Rotation introduces a new signing key and retires the previous key
for signing while retaining historical verification. Verify an old proof after rotation,
refuse signing with the retired key, and assert old payload/signature bytes are unchanged.
Verification material supplied by an untrusted file is not its own trust anchor.

### M4 — Serve bounded lookups and verify offline

Implement a new attestation route vertical and server handler under the existing caller
authentication/authorization mount. Lookup by run identity or exact review-request
identity returns one retained signed proof or declared missing/not-ready/refused problems;
no unbounded list endpoint. Bound returned evidence and references under the agreed
contract. Never serve the optional unsigned internal shape as an accepted signed proof.
Regenerate `docs/api/openapi.json` and exercise both successful and refused dispatch.

Export canonical payload/signature and all required evidence, verification references and
trusted public material in a self-contained offline input. Put the verifier at the package
boundary consistent with the current executable ownership. Prove verification with the
fixture database stopped or unreachable and no hidden database/provider dependency.
Require a supplied trusted verification policy; an arbitrary embedded public key cannot
make an issuer trusted.

### M5 — Qualify UC-8 and the real-provider case

Start from a permitted review, exact immutable code/artifact/profile/result identities
and complete actual-call evidence. Seal, sign, fetch by both lookup keys, export and
verify offline. Independently mutate head/diff/result/profile, call model/thinking,
undeclared fallback, child-call completeness, evidence strength, issuer/algorithm and
signature. Each must refuse at its proper boundary with a bounded named reason. Test
rotation, replay and repeated signing convergence as well as successful plumbing.

Use controlled provider fixtures for deterministic mutation coverage, then run the
positive case once through an explicitly configured real provider with fresh production
authority and approved limits. This plan owns plan 13's previously transferred live
provider proof. An ordinary deterministic stub response cannot close that claim. Missing
configuration remains blocked, and a failed live run preserves evidence without closing
the milestone. Do not perform a paid call as part of a planning refresh.

## Concrete Steps

From the repository root, inspect current owners and save the implementation baseline:

```bash
plan52_base=$(git rev-parse HEAD)
mori path mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6
mori registry show shinzui/baikai --full
nix develop --no-write-lock-file -c cabal test shikigami-core-test -j1 --test-options='--num-threads=1 -p attestation' --test-show-details=direct
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test -j1 --test-options='--num-threads=1 -p evidence' --test-show-details=direct
```

After adding the signer/verifier/API tests, run the actual new groups; a zero-test filter
is not evidence. Regenerate OpenAPI using the existing `shikigami-openapi` executable,
exercise fresh/repeated migrations and registry reconciliation, build all packages and
run serialized applicable suites. Follow workflow versioning and run the normal gate
against `plan52_base` for any affected durable body or declaration.

```bash
nix develop --no-write-lock-file -c cabal build all
nix develop --no-write-lock-file -c cabal test all -j1 --test-options=--num-threads=1 --test-show-details=direct
nix develop --no-write-lock-file -c just keiro-gate "$plan52_base"
git diff --check
```

Record actual counts, source/output identities and platform. The old 157/801-test totals
are historical, not expected current counts. Live verification needs separately supplied
private configuration; never place credentials or signing material in a transcript.

## Validation and Acceptance

All five milestones must pass. Canonical bytes match the ratified shared golden;
unknown schemas/algorithms fail; signing is unreachable from agent authority;
sealed records and replay converge; historical proofs verify after rotation;
authenticated lookups return the same record; offline verification needs no database;
the mutation matrix refuses each alteration; and a real-provider positive proof is
retained. No new acceptance guarantee is inferred from earlier unsigned evidence tests.

## Idempotence and Recovery

Persist a single immutable signed record with stable issuance before publication and
recover it on retry. Keep old canonical codecs, keys and required evidence for retained
proofs. Add migrations through the manifest; never rewrite applied files. Refused or
uncertain signing cannot be reported as success. Do not re-sign history or accept an
untrusted embedded key as issuer authority. Signed-format changes require a new version
and an explicit compatibility story.

## Interfaces and Dependencies

Core owns envelope/evidence/signing/verifier contracts; api owns the typed route;
server/client own serving and commands; migrations own persistence. Reuse nominal
run/review/profile/artifact values and existing digest helpers. Plans 49–51/22/44
are satisfied prerequisites. Kikan IR-6 remains the shared-format gate. Baikai evidence
is already delivered and adopted; its historical IR-3 proposal is not a current
package-availability blocker. The real-provider trial and independent signing-key
boundary remain required evidence. Library selection is implementation work requiring
Mori plus current registry/tag verification; this refresh changes no dependency bounds.

## Revision Notes

2026-11-06: Refreshed canonicalization, allocated identities, evidence/HTTP/workspace
owners and commands. Removed the obsolete Baikai/Kioku bound, duplicate hash/type work
and hypothetical signatures. Added missing Outcomes while preserving the original five
milestones, historical decisions and all live/shared-contract acceptance obligations.
