---
id: 52
slug: signed-attestation-read-api-and-uc-8-conformance
title: "Signed attestation, read API, and UC-8 conformance"
kind: exec-plan
created_at: 2026-08-05T14:53:02Z
intention: "intention_01kz96h79mezmbnwm67pdjjepr"
master_plan: "docs/masterplans/10-sanctioned-execution-attestation-for-agent-runs.md"
---

# Signed attestation, read API, and UC-8 conformance

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

By the time this plan starts, an agent run that requires a sanctioned execution profile resolves
that profile to an immutable digest before it executes, accumulates a durable record of every
model call it made, seals that record when the behavior and all delegated children are terminal,
and judges it against the profile — producing a verdict plus the complete list of ways the run
failed to conform. All of that lives inside this system and is only as trustworthy as this
system.

This plan closes the loop by making the result verifiable from outside. After it, a sealed
run-evidence record is canonically encoded, hashed, and signed by a workload identity whose key
the agent's behavior, its prompt, its tools, and its repository workspace cannot reach. The
signed attestation is served by a bounded HTTP endpoint, retrievable by run id or by review-request
id, and is also emitted as a self-contained file that a verifier can check with no access to this
database at all.

You can watch it work end to end. Take the permitted run: fetch its attestation, hand the file to
the offline verifier, and get `sanctioned`. Then mutate one field at a time — change the head
commit, change the model in one call record, change the thinking level, add an undeclared fallback,
delete a delegated child's call, alter the signature — and each time the verifier refuses, naming
what it refused. Then rotate the signing key and re-verify the *old* attestation: it still
verifies, because rotation must not orphan historical proofs.

That mutation suite is the acceptance criterion of the whole initiative, and it is where the trust
statement gets honest. What this proves is that a trusted runtime emitted specific provider
requests, received correlated responses, and bound those observations to a code review. It does not
prove anything about computation inside the provider. The evidence keeps those levels distinct —
declared configuration, runtime-observed request and response, runtime-signed attestation,
provider-attested evidence — and a verifier must never promote one to another.

This plan does not decide which models are good enough and does not reject a merge; the gate that
consumes this proof is `mori://shinzui/kotei/okf/improvement-requests/concepts/IR-2`, in another
repository.


## Progress

- [ ] M1: canonical encoding and hashing of the attestation payload built on
      `Baikai.Evidence.canonicalEncode` and `commitmentDigest` — **adopted, not authored** — and
      byte-matched against the golden payload published upstream.
- [ ] M1 (gate): `baikai 0.5.0.0` in the cohort, currently excluded by `kioku-core 0.3.0.0`'s
      `baikai ^>=0.4.1.0`. Shared with `docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md`;
      `docs/plans/53-upgrade-shikigami-to-the-keiro-0-11-and-keiki-0-9-cohort.md` owns requesting
      the kioku release that lifts it.
- [ ] M1: `evidenceSchemaVersion` recorded alongside the digest algorithm, so a verifier can tell
      which evidence vocabulary the covered records used.
- [ ] M2: signing by a workload identity, with a test proving the key is unreachable from the
      behavior, the prompt, the tools, and the workspace.
- [ ] M2: pg-migrate-managed attestation table; read models reconciled.
- [ ] M3: key rotation that preserves verification of every historical attestation.
- [ ] M4: bounded read API — by run id and by review-request id — added as one field on the
      umbrella route record, with the generated OpenAPI document regenerated.
- [ ] M4: offline verifier input: a self-contained file plus a verifier that checks it with the
      database stopped.
- [ ] M5: the UC-8 conformance fixture — `sanctioned` for the permitted run, and explicit refusal
      for the model, thinking, fallback, missing-call, artifact, and signature mutations.
- [ ] M5: the live-provider positive case, which needs the credential
      `docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md` never had.


## Surprises & Discoveries

**The canonical encoder this plan was going to write already exists upstream (discovered
2026-08-10).** `baikai 0.5.0.0`, released 2026-08-05, added `Baikai.Evidence`, which includes the
canonical hashing core: `canonicalEncode` (object keys sorted, no insignificant whitespace,
numbers normalised so `1`, `1.0`, `1.00`, and `1e0` all encode as `1`, and a hand-written string
escaper so an aeson upgrade cannot silently invalidate a recorded digest), `commitmentDigest` over
a full request envelope, and `configurationDigest` over an allow-list projection.

The two properties worth dwelling on are number normalisation and the hand-written escaper. Both
are the kind of thing a first implementation gets almost right, and both fail in the same way:
silently, and only when compared against another implementation in another repository — which is
precisely the cross-repository byte match this plan's Milestone 1 exists to achieve. Adopting the
upstream encoder removes that risk and has the additional property that the evidence records and
the attestation covering them are canonicalised by the same code, so they cannot disagree.

**This shrinks what Kikan IR-6 has to ratify.** The upstream request was carrying two jobs: agree
the attestation *envelope* — which fields the signature covers, in what shape, with what redaction
— and agree the *encoding* that turns that envelope into bytes. The encoding half is now answered
by a published library that both sides can depend on. IR-6 still genuinely binds on the envelope
and on the golden payloads this plan must match byte-for-byte; it no longer needs to specify a
canonicalisation algorithm in prose. Worth saying in the request, because it makes the request
smaller and easier to accept.

**The gate is shared with plan 51 and is a bound, not a contract.** `kioku-core 0.3.0.0` declares
`baikai ^>=0.4.1.0`, which excludes 0.5, so the cohort cannot take `Baikai.Evidence` yet. A kioku
release admitting `baikai ^>=0.5` lifts it for both plans at once.


## Decision Log

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


## Context and Orientation

You need this file, the working tree, and three checked-in plans:
`docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md` (the envelope and its
canonical encoding), `docs/plans/50-fail-closed-profile-resolution-and-run-pinning.md` (profile
resolution and pinning), and `docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md` (the
sealed evidence and the verdict this plan signs). Read all three.

**What already exists that this plan extends.** Plan 49 defines `AttestationPayload` (everything
the signature covers), `AgentRunAttestation` (that payload plus a signature and key id), and
`canonicalPayloadBytes`. It deliberately left the *hash* unimplemented behind a `PayloadDigest`
newtype. Plan 50 may already have added the hashing dependency — it needs a profile digest — so
check `shikigami-core/src/Shikigami/Attestation/Envelope.hs` before adding one, and check plan 50's
Surprises & Discoveries, which is where that change is recorded if it happened.

**The HTTP surface, and its one convention.** `shikigami-api/src/Shikigami/Api.hs` holds
`ShikigamiApi`, a Servant *named-routes record*: a record whose fields are endpoints, rather than a
chain of `:<|>` operators. Read its module haddock in full — it is short and it is the contract.
Three rules from it bind this plan. Adding a vertical means adding one field whose type is
`mode :- "segment" :> NamedRoutes SomeApi`, with `SomeApi` defined in that vertical's own module.
Terminal routes must use `MultiVerb` so every status code, media type, and body is part of the
type. Error alternatives must be declared with `RespondAs ProblemJSON` so they render the single
problem body defined in `shikigami-api/src/Shikigami/Api/Problem.hs`.

The server that serves that record is `shikigami-server`; see
`shikigami-server/src/Shikigami/Server/App.hs` and the existing
`shikigami-server/src/Shikigami/Health/Handler.hs` for the handler shape. `docs/api/openapi.json`
is generated from the same record by the `shikigami-openapi` executable, so adding an endpoint
means regenerating that file in the same commit.

The package rules matter here because this is the one plan in the initiative that crosses packages.
`docs/architecture/packages.md` states them: `shikigami-api` depends on `shikigami-core`,
`shikigami-server` depends on both, `shikigami-workers` may depend on neither `shikigami-api` nor
`shikigami-server`, and `shikigami-core/test/Shikigami/PackageArchitectureSpec.hs` fails the build
on a forbidden edge. So the attestation *types* and the *signing* live in `shikigami-core` (a worker
must be able to sign), the *route* lives in `shikigami-api`, and the *handler* lives in
`shikigami-server`.

**Credentials.** `docs/plans/22-outbound-authentication-for-sink-clients.md` owns credential
resolution for outbound clients. This plan reuses that machinery for a different class of secret. Be
clear on the difference: a sink credential authenticates this system to a downstream service, and a
behavior that leaked it could impersonate the runtime to that service. A signing key is worse — a
behavior that could reach it could forge the very attestation that is supposed to constrain the
behavior. That is why the request prefers a separate trusted attestation component where deployment
architecture permits, and why the non-visibility test in Milestone 2 is not optional.

The related constraint is in `docs/plans/48-add-a-portable-one-off-repository-agent-harness.md`,
which is unregistered — it belongs to no MasterPlan — and which defines a workspace, a command
policy, and a permission boundary for an agent working on a repository checkout. The signing key
must sit outside that boundary. If plan 48 has landed by the time you read this, read its workspace
model and assert the exclusion against it; if it has not, record in Surprises & Discoveries that
the assertion is against this plan's own boundary only, so plan 48's author knows to check.

**The reviewed artifact.** `ReviewedArtifact` (plan 49) needs a canonical repository identity, full
base and head commits, and a diff digest. Acquiring those values is
`docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md`'s job — it defines an
`EvidenceReader` whose `readDiff` takes a repository identity and two revisions and returns a
pinned diff. Use it. Plan 49 carries local `RepositoryId` and `Revision` definitions only as a
placeholder, with a note that they are deleted and imported from plan 44 when it lands; if plan 44
has landed, doing that deletion is part of this plan's Milestone 1.

**The upstream contract this must match.** Resolve the path with `mori path mori://shinzui/kikan`
and read `docs/improvement-requests/define-sanctioned-agent-execution-attestations.md`. Its "Shared
contract" section names the records, its "Invariants" section is normative, and its "Conformance
fixtures" section promises golden payloads that baikai, this repository, and kotei must all consume.
Two invariants bear directly on this plan: unknown schemas, issuers, strengths, algorithms, or
incomplete coverage must fail closed; and replay must preserve attestation identity and must not be
able to manufacture a second successful review. The driving scenario is
`docs/use-cases/008-sanctioned-agent-review-attestation.md` in the same repository; its "Failure
cases" and "Verification semantics" sections are the checklist Milestone 5 implements.

That request was `proposed` as of 2026-08-05. Check its status before starting — if it is still
`proposed`, the golden payloads may not exist, and Milestone 1's conformance test is one-sided. Say
so in Surprises & Discoveries rather than implying otherwise.

**Commands.** From `/Users/shinzui/Keikaku/bokuno/shikigami`:

```bash
nix develop -c cabal build all
nix develop -c cabal test all
nix fmt
```


## Plan of Work

### Milestone 1 — canonical bytes and the payload digest

Finish what plan 49 started, and do it by adopting an encoder rather than writing one.

`baikai 0.5.0.0`'s `Baikai.Evidence` module ships the canonical hashing core this milestone was
going to build: `canonicalEncode` gives a JSON value exactly one byte representation, and
`commitmentDigest` hashes a full request envelope. Implement `canonicalPayloadBytes` as
`canonicalEncode` applied to the payload's JSON, and `attestationPayloadDigest` as
`commitmentDigest` over it. Do not add a separate hashing dependency for this — baikai already
pulls `cryptohash-sha256` and `base16-bytestring` for exactly this purpose. Check
`shikigami-core/src/Shikigami/Attestation/Envelope.hs` and plan 50's Surprises & Discoveries first
in case plan 50 already added one for the profile digest; if it did, prefer converging on baikai's
core so one canonicalisation serves both.

Two properties of baikai's encoder are worth knowing, because they are the ones a from-scratch
implementation would most plausibly have gotten wrong and discovered later as a cross-repository
digest mismatch. Numbers are normalised, so `1`, `1.0`, `1.00`, and `1e0` all encode as `1`. And
the string escaper is hand-written specifically so that an aeson upgrade cannot silently
invalidate a recorded digest — which is the same hazard this plan's Decision Log identified from
the other direction.

Record the algorithm in the attestation itself, because the upstream invariant requires an unknown
algorithm to fail closed, which is impossible if the algorithm is implicit. Also record
`Baikai.Evidence.evidenceSchemaVersion` alongside it, so a verifier can tell which vocabulary
version the covered evidence used.

Then make the encoding's stability a test rather than a hope. Encode a fixed payload, assert the
exact bytes as a literal, and assert that the digest of those bytes is a literal too. Follow the
convention documented at the top of `shikigami-core/test/Shikigami/WireCompatSpec.hs`: a fixture
generated by calling the current encoder proves nothing about the encoder. This test matters more
now, not less — it is what would catch a future baikai release changing the canonical form under
you, and it is cheap insurance for having delegated the encoder.

Now the conformance half. Locate kikan's golden payload; if it exists, assert byte equality against
it and you have a two-sided test. If it does not, keep the local pinned fixture, add a haddock
comment naming the upstream request, and record the absence and the date in Surprises & Discoveries.
Either way the test exists.

If `docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md` has landed, delete
plan 49's placeholder `RepositoryId` and `Revision` definitions and import plan 44's instead.
`ReviewedArtifact` itself does not change; this is an import swap, and doing it now prevents two
revision vocabularies from ever both being live.

### Milestone 2 — sign, outside agent authority

Add `shikigami-core/src/Shikigami/Attestation/Sign.hs`. It takes a sealed `RunEvidence` and its
`ComplianceRollUp` from plan 51, assembles an `AttestationPayload`, computes the digest, signs it,
and returns an `AgentRunAttestation` whose signature and key id are populated.

Resolve the key through the credential machinery
`docs/plans/22-outbound-authentication-for-sink-clients.md` provides, as a distinct credential
class. Record with the signature everything a verifier needs to check it without asking this
system: the algorithm, the key id, the signing identity, a certificate or verification reference,
the issuance time, and the schema version.

The non-visibility test is the milestone's real content, and it needs to test a property rather than
an intention. Construct the environment a behavior actually runs in — the `BehaviorEnv` from
`shikigami-core/src/Shikigami/Behavior/Run.hs`, the arguments a program receives via its registry
at `shikigami-core/src/Shikigami/Program/Registry.hs`, the tool environment, and the prompt inputs
assembled in `shikigami-core/src/Shikigami/Behavior/Input.hs` — plant a recognisable sentinel value
as the signing key, and assert the sentinel appears in none of them. Then assert it appears in no
rendering of the application configuration either; there is an existing precedent for this exact
technique in `shikigami-core/test/Shikigami/AppConfigSpec.hs`, which asserts a planted secret is
absent from every rendering of the config, so read that first and follow it.

Persist the result. Create the migration with `just new-migration name=run-attestations`, storing
the payload's canonical bytes, the digest, the signature, the key id, the algorithm, the issuance
time, and the run and review-request ids, with the run id and review-request id indexed because
Milestone 4 queries by both. Confirm `Shikigami.Migrations.reconcileShikigamiReadModels` covers any
read model you add — a test against a freshly created database will not catch its absence, so read
that function's source.

### Milestone 3 — rotation that does not orphan history

Signing keys rotate. Historical proofs must keep verifying, so verification resolves the key by the
key id recorded *in the attestation*, never by "the current key".

Implement a small key registry: several keys resolvable by id, exactly one marked current for
signing, retired keys still resolvable for verification. Then write the test that matters: sign an
attestation, rotate to a new current key, and verify the old attestation — it still verifies. And
the negative: signing with a retired key is refused.

Do not re-sign history under the new key. That would change historical payload digests, which is
precisely the thing an auditor relies on not happening.

### Milestone 4 — serve it, and let it be checked offline

Two deliverables, and the second is the one that matters most to the consumer.

The endpoint: define `AttestationApi` in a new module in `shikigami-api`, add one field to
`ShikigamiApi` in `shikigami-api/src/Shikigami/Api.hs` — following the convention its haddock
states — with terminal routes declared using `MultiVerb` and error alternatives using
`RespondAs ProblemJSON` against `shikigami-api/src/Shikigami/Api/Problem.hs`. Two lookups: by run
id and by review-request id. Bounded means bounded: a not-found is a problem response, not an empty
success, and there is no list-everything route. Implement the handler in `shikigami-server`
alongside `shikigami-server/src/Shikigami/Health/Handler.hs`, then regenerate the document:

```bash
nix develop -c cabal run shikigami-openapi
git diff docs/api/openapi.json
```

The diff must show your new endpoint. If it does not, the route is not reachable from the umbrella
record and the server is not actually serving it.

The offline verifier input: a self-contained file carrying the canonical payload bytes, the
signature, the key id and algorithm, and the verification reference — everything needed to check
the proof with no access to this database. Add a verifier entry point that reads such a file and
answers, and prove it properly: stop the database, run the verifier against the file, and observe
it succeed. A verifier that quietly needs a database connection is not an offline verifier, and
stopping the database is the only way to find out.

### Milestone 5 — the UC-8 conformance fixture

The end-to-end case, built on the mutation fixtures plan 51's Milestone 4 already produced.

The positive case first: a permitted run, sealed, judged sanctioned, signed, served, and verified
offline. Then one mutation at a time, each of which must be refused with its own named reason:
change the head commit; change the model recorded in one call; change the thinking translation; add
a fallback the profile does not permit; delete a delegated child's call record; alter one byte of
the signature. Six mutations, six refusals, each naming what it refused. Read UC-8's "Failure
cases" section and check your list against it.

Then the honest part, which needs to be stated in the plan rather than discovered at the end. The
positive case is only fully meaningful with a real provider call, and
`docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md` is Complete *except* its live
Anthropic smoke transcript — it was never performed because no credential was available, and it was
recorded as unproven rather than assumed. Attesting a run that never reached a real provider proves
the plumbing, not the claim. So: run the full mutation suite with the stub provider, which needs no
credential and is where all six refusals are proven; and separately run the positive case once
against a real provider and paste the transcript into Outcomes & Retrospective. If no credential is
available when you get here, do not fake it and do not quietly drop it — mark that one item
outstanding in Progress and say so, exactly as plan 13 did.


## Concrete Steps

From `/Users/shinzui/Keikaku/bokuno/shikigami`, orient:

```bash
cat docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md
cat docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md
sed -n 1,60p shikigami-api/src/Shikigami/Api.hs
cat shikigami-server/src/Shikigami/Health/Handler.hs
sed -n 30,60p docs/architecture/packages.md
mori path mori://shinzui/kikan
```

Check the gates before starting:

```bash
grep -rn "sealEvidence" shikigami-core/src              # plan 51
grep -rn "credential" shikigami-core/src/Shikigami/App  # plan 22
grep -rn "EvidenceReader" shikigami-core/src            # plan 44
```

Then check the two upstream requests' status fields, in the repositories `mori path` resolves, and
record both in Surprises & Discoveries with the date:

```bash
grep -m1 "^status:" <kikan>/docs/improvement-requests/define-sanctioned-agent-execution-attestations.md
grep -m1 "^status:" <baikai>/docs/improvement-requests/capture-verifiable-model-call-evidence.md
```

Per milestone:

```bash
nix develop -c cabal build all
nix develop -c cabal test all --test-option -p --test-option "attestation"
nix fmt
```

A passing Milestone 5 run looks like this:

```text
shikigami
  UC-8 conformance
    permitted run verifies as sanctioned:            OK
    changed head commit is refused:                  OK
    changed call model is refused:                   OK
    changed thinking translation is refused:         OK
    undeclared fallback is refused:                  OK
    deleted child call is refused as incomplete:     OK
    altered signature fails verification:            OK
    rotated key still verifies old attestation:      OK

All 8 tests passed
```

Commit per milestone with all three trailers:

```text
feat(attestation): sign a sealed run outside agent authority

Sign the canonical payload with a workload-resolved key and assert the
key is absent from the behavior environment, prompt inputs, tool
environment, and every config rendering.

MasterPlan: docs/masterplans/10-sanctioned-execution-attestation-for-agent-runs.md
ExecPlan: docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md
Intention: intention_01kz96h79mezmbnwm67pdjjepr
```


## Validation and Acceptance

Full suite:

```bash
nix develop -c cabal test all
```

The baseline as of 2026-07-31 was 157 tests across seven suites; expect that plus yours, with no
failures.

Acceptance, as things a person can watch:

Encode one attestation payload and print its canonical bytes and digest. Run it again; identical.
If kikan's golden payload exists, the bytes match it exactly.

Sign a sealed run. `GET` the attestation by run id and get it back; `GET` it by review-request id
and get the same record; `GET` a run id that does not exist and get a problem response, not an
empty success. Confirm `docs/api/openapi.json` describes all of it — the diff from regenerating it
is your evidence.

Plant a sentinel signing key. Grep every behavior-facing structure for the sentinel and find
nothing: the behavior environment, the program arguments, the tool environment, the assembled prompt
inputs, and every rendering of the application configuration.

Write the attestation to a file. Stop the database. Run the verifier against the file. It answers
`sanctioned` without a database connection.

Rotate the signing key. Verify an attestation signed before the rotation; it still verifies. Try to
sign with the retired key; refused.

Run the six mutations. Each is refused, and each refusal names what it refused — not a generic
verification failure.

Run the positive case against a real provider and paste the transcript. If no credential is
available, leave that Progress item unchecked and say so plainly; do not substitute a stub run and
call it proven.


## Idempotence and Recovery

Signing the same sealed evidence twice must produce the same payload digest, because the payload is
a function of the sealed record. Store attestations keyed by run id so a replayed signature is an
upsert that converges rather than a second attestation for one run — that is what makes the upstream
invariant "replay preserves attestation identity and cannot manufacture a second successful review"
hold. A test should assert it: sign twice, get one row and one digest.

Migrations are additive — one new table — and applying twice is a no-op because `shikigami-migrate`
tracks what it applied. Adding a field to the route record is additive to the served API; removing
one is not, so if you need to change the endpoint shape before release, do it in one commit
together with the regenerated `docs/api/openapi.json`.

Key rotation is append-only: add a key, mark it current, mark the previous one retired. Never delete
a key that has signed anything, because verification resolves keys by the id recorded in the
attestation and deleting one makes every proof it signed unverifiable — the exact failure this
milestone exists to prevent.

The one genuinely irreversible artifact is a published canonical encoding. Once an attestation has
been served to a consumer, changing `canonicalPayloadBytes` changes every digest and invalidates
every historical proof. Treat it as a wire format: a change needs a schema-version bump and a
migration story, not an edit.


## Interfaces and Dependencies

Hard dependencies: `docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md` (the sealed
evidence and roll-up to sign), `docs/plans/22-outbound-authentication-for-sink-clients.md` (the
credential machinery the signer reuses), and
`docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md` (the revision-pinned
repository, revision, and diff vocabulary `ReviewedArtifact` binds).

Upstream gates, both `proposed` as of 2026-08-05:
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6` ratifies the canonical envelope,
encoding, hashing, redaction, and strength rules this plan must match byte-for-byte and publishes
the golden payloads Milestone 1 compares against;
`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-3` supplies real per-call observations,
without which Milestone 5's positive case runs on stub evidence. Re-check both statuses at the
start of implementation and record what you found.

Coordination, not blocking: `docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md`'s
unperformed live smoke is a precondition of the fully meaningful positive case, and
`docs/plans/48-add-a-portable-one-off-repository-agent-harness.md` must keep the signing key outside
its workspace and command-policy boundary.

Libraries: a hashing library and a signature library. Verify both released versions against the
authoritative package registry and the upstream release tags before choosing bounds — do not take a
version from a local corpus; this repository's `AGENTS.md` requires it. `servant` and
`servant-openapi-hs` are already in `shikigami-api`; `warp` and `servant-server` are already in
`shikigami-server`.

Signatures that must exist at the end:

```haskell
-- shikigami-core/src/Shikigami/Attestation/Envelope.hs (completed here)
attestationPayloadDigest :: AttestationPayload -> PayloadDigest
data DigestAlgorithm = ...   -- recorded in the attestation; unknown values fail closed

-- shikigami-core/src/Shikigami/Attestation/Sign.hs
newtype KeyId = KeyId {value :: Text}
data SigningKey = SigningKey {keyId :: !KeyId, algorithm :: !SignatureAlgorithm, ...}
data KeyRegistry = KeyRegistry
  { currentSigningKey :: !(IO (Either KeyError SigningKey)),
    resolveForVerification :: !(KeyId -> IO (Either KeyError VerificationKey))
  }

signAttestation ::
  KeyRegistry -> RunEvidence -> ComplianceRollUp -> IO (Either SignError AgentRunAttestation)
verifyAttestation :: KeyRegistry -> AgentRunAttestation -> IO (Either VerifyError Verified)

-- shikigami-core/src/Shikigami/Attestation/Offline.hs
data OfflineVerifierInput = OfflineVerifierInput
  { canonicalPayload :: !ByteString,
    payloadDigest :: !PayloadDigest,
    signature :: !Text,
    keyId :: !KeyId,
    algorithm :: !SignatureAlgorithm,
    verificationReference :: !Text
  }
verifyOffline :: OfflineVerifierInput -> Either VerifyError Verified

-- shikigami-api/src/Shikigami/Attestation/Api.hs
data AttestationApi mode = AttestationApi
  { byRunId :: mode :- "runs" :> Capture "runId" Text :> MultiVerb ...,
    byReviewRequestId :: mode :- "reviews" :> Capture "reviewRequestId" Text :> MultiVerb ...
  }

-- shikigami-api/src/Shikigami/Api.hs (extended by one field)
data ShikigamiApi mode = ShikigamiApi
  { health :: mode :- "health" :> NamedRoutes HealthApi,
    attestations :: mode :- "attestations" :> NamedRoutes AttestationApi
  }
```

`AttestationPayload`, `AgentRunAttestation`, `PayloadDigest`, and `canonicalPayloadBytes` come from
plan 49. `RunEvidence` and `ComplianceRollUp` come from plan 51. None are redefined here.
`canonicalEncode`, `commitmentDigest`, `configurationDigest`, and `evidenceSchemaVersion` come from
`Baikai.Evidence` in `baikai 0.5.0.0`; `canonicalPayloadBytes` is implemented in terms of the first
of those rather than being an independent encoder.


## Revision Notes

- 2026-08-10: Adopted `Baikai.Evidence`'s canonical hashing core instead of authoring one, and
  recorded the consequences for Kikan IR-6.

  Milestone 1 was going to implement a canonical encoder and a payload digest from scratch, and the
  Decision Log of 2026-08-05 had already identified the right requirement — a named function with
  sorted keys and no insignificant whitespace, not `encode`, because the digest must match a hash
  computed in another repository and possibly another language. `baikai 0.5.0.0` shipped exactly
  that on 2026-08-05: `canonicalEncode`, `commitmentDigest`, and `configurationDigest`. The
  original decision stands; what changed is who implements it.

  The reason to prefer the upstream version over a local one is specific rather than general.
  Baikai's encoder normalises numbers so `1`, `1.0`, `1.00`, and `1e0` agree, and uses a
  hand-written string escaper so an aeson upgrade cannot silently change a recorded digest. Both
  are failure modes that a first local implementation plausibly misses and that surface only as a
  cross-repository mismatch — the exact failure this milestone exists to prevent. Sharing the
  encoder with the library producing the call evidence also means the evidence and the attestation
  covering it cannot disagree about canonical form.

  A second decision was added rather than inherited: keep `commitmentDigest` and
  `configurationDigest` distinct. The signature must cover the first, because an auditor's question
  is whether an attestation is about this exact run; comparing runs that legitimately differ in
  content wants the second. Collapsing them makes one of those questions unanswerable.

  Milestone 1 also now records `evidenceSchemaVersion` beside the digest algorithm, so a verifier
  can tell which evidence vocabulary the covered records used, and the byte-pinning test is
  described as more important rather than less — it is what would catch a future baikai release
  changing the canonical form, which is the cost of having delegated the encoder.

  Finally, Surprises & Discoveries records that this shrinks Kikan IR-6. That request was carrying
  both the attestation envelope and its encoding; the encoding half is now answered by a published
  library both sides can depend on. IR-6 still binds on the envelope and the golden payloads, and
  saying so should make the request easier to accept.

  Gate: `baikai 0.5.0.0` is excluded by `kioku-core 0.3.0.0`'s `baikai ^>=0.4.1.0`. Shared with
  plan 51; plan 53 owns requesting the kioku release that lifts it.
