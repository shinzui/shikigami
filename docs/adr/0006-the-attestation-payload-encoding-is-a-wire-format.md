# 0006. The attestation payload's canonical encoding is a wire format, and its encoder is borrowed

Date: 2026-08-19

Status: accepted


## Context

An agent-run attestation is verified by parties outside this repository —
`mori://shinzui/kotei` consumes it, and
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6` intends Baikai,
Shikigami, and Kotei to agree on golden payloads. Verification means recomputing
a digest over the payload and comparing. That only works if one logical payload
has exactly one byte encoding, in every implementation that touches it.

`Data.Aeson.encode` does not provide that. Aeson makes no guarantee about object
key order across versions, its number rendering has more than one spelling for
one mathematical value (`1`, `1.0`, `1e0`), and its string escaper can change
without any change here. Any of those would alter a recorded digest and present
to a verifier as tampering, which is indistinguishable from the thing digests
exist to detect.

`baikai 0.5.0.0` already solves this. `Baikai.Evidence.canonicalEncode` sorts
object keys, emits no insignificant whitespace, normalises numbers through
`Scientific.normalize`, and hand-writes its string escaper specifically so an
aeson upgrade cannot silently invalidate a stored digest. baikai is already a
direct dependency of `shikigami-core`.


## Decision

**`Shikigami.Attestation.Envelope.canonicalPayloadBytes` is the single definition
of what an attestation digest covers. It is a named function of this repository's
own, implemented in terms of baikai's encoder.**

* The *encoder* is borrowed: `canonicalPayloadBytes = canonicalEncode . toJSON`.
  Reimplementing it here would plausibly miss number normalisation or the escaper
  and surface as a cross-repository digest mismatch — the one failure this design
  exists to prevent.
* The *payload definition* is not borrowed. Which fields `AttestationPayload`
  contains and in what shape is what IR-6 ratifies and what this repository owns,
  which is why this is a named function rather than a direct call to
  `canonicalEncode` at each site.
* **Its output is a wire format.** Changing the field set, a field name, a nested
  record's shape, or the encoder changes every digest this repository has ever
  produced, and every stored attestation stops verifying at once. Such a change
  needs a `SchemaVersion` bump and a migration story, not an edit.
* `AttestationPayload` and `AgentRunAttestation` are separate types so that a
  signature cannot cover itself. `canonicalPayloadBytes` takes a payload, and a
  payload has no signature field, so the error is inexpressible rather than
  merely discouraged.
* `attestationPayloadDigest` is `sha256` over exactly those bytes, via baikai's
  `commitmentDigest`. It is implemented, not stubbed.
* Full commit hashes normalise to lowercase in
  `Shikigami.Attestation.Reviewed.mkFullCommit`. Case is meaningless in a hex
  digest but not to a byte-level encoding, and two attestations of the same
  commit differing only in case would digest differently.


`ProfileDigest` and `PayloadDigest` are private, non-Generic values. Their parsers
and complete-document JSON decoders accept exactly `sha256:` followed by 64
lowercase hexadecimal digits, matching their concrete canonical producers. The
profile owner now constructs its digest through `profileContentDigest`; the
existing envelope `profileDigest` facade delegates to it without changing the
hash input or encoder. Renderers replace public constructor access at SQL and
presentation adapters. Syntax alone does not verify a claim: profile resolution
and decision admission still compare the computed content commitment, and an
attestation verifier/signing service remains separate work.

`SchemaVersion` is the closed supported vocabulary. The producer still emits
`shikigami.agent-run-attestation/1` byte for byte. Unknown versions fail explicitly
when a complete payload is decoded; they do not become supported domain values.
The public constant and checked parser are its construction boundary.


The Plan 108 nominal-value audit also preserves exact review-author scope,
Merkle-commitment, signature and review-class strings. A signed review scope is
an attested claim, not a filesystem access capability. Reusing a normalizing
content-path parser for that field would silently change historical canonical
bytes; actual content access continues to use checked Repository.RelativePath.
Signing-key coordinates reuse the existing nominal key domain. Run correlation,
session and deterministic-step references retain native types and their valid
string encodings; noncanonical or non-UUIDv7 session claims refuse on complete
decoding rather than being rewritten. The existing canonical byte golden and
pinned payload digest remain unchanged.

## Alternatives rejected

**Use `Data.Aeson.encode` and pin the bytes with a test.** A test pins what the
current aeson does, not what the next one will. The failure mode is a dependency
bump silently changing digests on records already signed and stored, discovered
by a third party as a verification failure.

**Write the canonical encoder here.** Considered, and the original plan allowed
it as a fallback while baikai 0.5 was believed unavailable. Rejected once the
dependency was confirmed present: an independent implementation has to
rediscover number normalisation and escaping, and a divergence between two
canonical encoders in the same fleet is precisely the class of bug that is
invisible locally and only appears across a repository boundary.

**Defer the digest computation to
`docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md`.** This is
what plan 49 specified, on the stated grounds that hashing needs a dependency
that plan would add. The premise was wrong — baikai already exports it at zero
cost — and the alternative was a function that returns a placeholder while
claiming to be a digest, which a caller in plan 50 or 51 could store. Plan 52
still owns signing and the key.

**Keep the payload and the signature in one record.** Fewer types, and it makes
hashing the signature along with the payload a one-line mistake that produces
normal-looking digests which never verify anywhere.


## Consequences

`AttestationPayload`'s field set is now a versioned interface. Adding an optional
field is safe only in the sense that `omitNothingFields` keeps absent fields out
of the bytes; adding a field that is ever *populated* changes the digest of every
payload that populates it, which is correct but means old and new payloads are
not comparable by digest.

`shikigami-core/test/Shikigami/AttestationContractsSpec.hs` pins both the
canonical bytes and the resulting digest as literals. They are a matched pair —
those exact bytes hash to that exact digest — and neither may be regenerated to
make a failing test pass. A diff there is a wire-format change.

The conformance claim is currently **one-sided**. IR-6's "Conformance fixtures"
section promises golden payloads that all three repositories consume; as of
2026-08-19 kikan publishes none, and `AgentRunAttestation` appears in that
repository only inside the request document. The pinned fixture is therefore ours
and proves only that this repository's encoding has not drifted. When kikan
publishes, replace the literal with kikan's bytes; a difference at that point is
the test working.

`CallEvidenceSet` holds already-encoded evidence records rather than baikai's
`ModelCallEvidence`, because that type derives `ToJSON` but not `FromJSON` and an
attestation that cannot be decoded is useless to the verifier it exists for. This
also preserves the producer's exact bytes, which is what the digest covers.


Previously unchecked malformed commitment strings and unsupported schema names
now fail decoding. This deliberately narrows invalid or unsupported admission;
it does not normalize or rewrite retained documents, alter valid canonical
payload bytes, waive compatibility under a first-release exception, or claim
that an unsupported historical payload can resume. Compiler clients exercise
public factories before constructor, coercion and Generic refusal controls.
Complete reference, payload and envelope mutations exercise the actual codecs.
The profile SQL reader preserves its existing exception seam for malformed data
and native query failures; tests distinguish their diagnostics from absence and
prove exact row recovery after repair. Decision evidence's composable readers
continue to condemn their owning transaction for an invalid pinned reference.


## References

* `docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md` — the
  plan that introduced these types, and the Surprises entries recording the
  absent upstream fixture and the encode-only evidence record.
* `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6` — the shared
  canonical envelope, its invariants, and the conformance-fixture promise.
* `docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md` — owns
  signing over this digest, and the served-attestation guarantee that
  `signature` and `keyId` are present.
* [ADR-0005](0005-two-evidence-strength-scales-named-apart.md) — the other
  cross-repository vocabulary decision made alongside this one.
