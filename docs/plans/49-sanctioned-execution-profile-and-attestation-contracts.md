---
id: 49
slug: sanctioned-execution-profile-and-attestation-contracts
title: "Sanctioned execution profile and attestation contracts"
kind: exec-plan
created_at: 2026-08-05T14:53:02Z
intention: "intention_01kz96h79mezmbnwm67pdjjepr"
master_plan: "docs/masterplans/10-sanctioned-execution-attestation-for-agent-runs.md"
---

# Sanctioned execution profile and attestation contracts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami runs declared agents. An agent is a Dhall manifest under `agents/` describing a
name, a trigger, a behavior, and some sinks; a run of that agent is a durable workflow that
opens a memory session, recalls prior learnings, executes the behavior — usually by calling a
language model through the `baikai` library — records what it learned, and dispatches sinks.
Today the only durable record of *how* a run executed is a single text field, `modelUsed`, on
the completed memory session row.

Somebody wants to use one of these agents as a code-review gate: a protected repository will
only accept a change if a trusted agent reviewed it. For that, `modelUsed` is nowhere near
enough. It does not say what thinking level was requested, what the provider said it actually
did, how many calls a multi-call program made, whether any call was retried or fell back to a
different model, whether a delegated child agent was involved, which policy version the run
was supposed to obey, which exact commits were reviewed, or what verdict came back.

This plan does not build any of that machinery. It writes down, in Haskell types, precisely
what all of those words mean — and nothing else. After this plan there is a module in the
domain package holding: a *sanctioned execution profile* (an immutable, versioned policy
saying which combinations of provider, API, model, and thinking level a run may use, and what
it may not do); an *agent version reference* and *artifact set* (which agent, at which
immutable version, with digests of its declaration, behavior, grounding, and tool catalog); a
*reviewed artifact* (canonical repository identity, full base and head commit hashes, and a
digest of the reviewed diff); a taxonomy of *non-conforming reasons*; an *evidence strength*
vocabulary; and a versioned *agent run attestation* envelope that ties all of it together with
a signature.

What you can observe after this plan is narrow but real, and it is worth being honest about
that: you can run the test suite and watch these records round-trip through JSON, watch a
record that carries no optional values encode to bytes identical to a fixture captured before
those optional fields existed, and watch the canonical encoding of an attestation payload
match, byte for byte, a golden payload published by another repository. There is no running
system to point at yet. The value is that four other plans, and nine plans elsewhere in this
repository, can now name these types instead of each inventing their own.

That last sentence is the actual reason this plan exists and is scheduled first. It is
described in full in `docs/masterplans/10-sanctioned-execution-attestation-for-agent-runs.md`
under Integration Points.


## Progress

- [ ] M1: `Shikigami.Attestation.Profile` — the sanctioned execution profile, its allowed
      `(provider, API, model, thinking)` tuples, its prohibitions, its limits, its issuer and
      validity window, its lifecycle, and its canonical digest.
- [ ] M1: round-trip and rejection tests for the profile; a profile whose allowed tuples are
      empty is rejected by construction.
- [ ] M2: `Shikigami.Attestation.Agent` — `AgentVersionRef` and `AgentArtifactSet`, shaped so
      lineage can be added additively.
- [ ] M2: byte-stability test — a record carrying no optional values encodes identically to the
      pinned fixture, proving a later plan can add lineage fields without rewriting history.
- [ ] M3: `Shikigami.Attestation.Reviewed` — `ReviewedArtifact` over the revision-pinned
      repository vocabulary, plus `NonConformingReason`. **`EvidenceStrength` is no longer
      defined here** — `baikai 0.5.0.0`'s `Baikai.Evidence` publishes it. Re-export baikai's if a
      local name is convenient; do not declare a second four-constructor sum. See Surprises &
      Discoveries.
- [ ] M3: tests proving a branch name or pull-request number alone cannot construct a
      `ReviewedArtifact`.
- [ ] M4: `Shikigami.Attestation.Envelope` — the versioned `AgentRunAttestation` mirror, its
      canonical encoding, and `attestationPayloadDigest`.
- [ ] M4: conformance test comparing the canonical encoding against the golden payload
      published by `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6`.
- [ ] M4: all four modules exposed from `shikigami-core`, registered in the test suite, full
      suite green.


## Surprises & Discoveries

**Two things this plan defines were published upstream on the day it was written (discovered
2026-08-10).** `baikai 0.5.0.0`, released 2026-08-05, added the `Baikai.Evidence` module. Its
scope overlaps this plan in two places, and the right response differs between them.

`EvidenceStrength` is baikai's now. It ships an ascending `EvidenceStrength` scale as part of the
verifiable model-call evidence vocabulary. This plan's Milestone 3 was going to declare a
four-constructor sum with a deliberate `Ord` instance for exactly the same purpose — checking that
a call meets a minimum strength. Two identical scales in one process, one owned here and one
arriving on every `ModelCallEvidence`, is a translation layer nobody wants and a silent
disagreement waiting to happen. Import baikai's, and re-export it from
`Shikigami.Attestation.Reviewed` if a local name reads better at use sites.

The haddock warning this plan wanted to write is still worth writing on the re-export: ordering
exists to *check* a minimum, never to promote a weaker claim to a stronger one. That caution is
shikigami's, not baikai's, and it should not be lost in the move.

**The canonical encoding is a different case, and the answer is the opposite.** Baikai also ships
`canonicalEncode`, `commitmentDigest`, and `configurationDigest` — the canonical hashing core, with
number normalisation and a hand-written string escaper so an aeson upgrade cannot silently change
a recorded digest. That is exactly what Milestone 4's `canonicalPayloadBytes` needs, and
`docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md` has adopted it. But this plan
should still define `canonicalPayloadBytes` as a *named function of its own*, implemented in terms
of `canonicalEncode` — because what this plan owns is which fields the payload contains and in
what shape, and that is the part kikan IR-6 ratifies. The encoder is borrowed; the payload
definition is not.

**A note on the gate.** `kioku-core 0.3.0.0` caps `baikai ^>=0.4.1.0`, so the cohort cannot take
baikai 0.5 yet, and this plan is otherwise contract-only with no dependencies. Do not let that
gate delay Milestones 1, 2, and 4. For Milestone 3, if the import is not yet available, declare
`EvidenceStrength` locally *with a haddock note naming baikai as its future home* and delete it
when the bound lifts — the same pattern this plan already uses for `RepositoryId` and `Revision`
pending plan 44. What must not happen is a locally owned scale that outlives the gate silently.


## Decision Log

- Decision: Put every record in this plan in `shikigami-core`, not `shikigami-api`.
  Rationale: `docs/architecture/packages.md:35-48` makes `shikigami-api` the *public HTTP
  contract* package, which depends on `shikigami-core`, and forbids `shikigami-workers` from
  depending on it. `shikigami-core/test/Shikigami/PackageArchitectureSpec.hs` fails the build
  on that forbidden edge. Background workers must be able to resolve a profile and record
  evidence, so these records cannot live in `shikigami-api` at all. Some older plans in this
  repository still say "shikigami-api" and name modules such as `Shikigami.Api.Agent` and
  `Shikigami.Api.RunJob`; those modules no longer exist — plan 36 moved the domain into
  `shikigami-core` (the run job is now `shikigami-core/src/Shikigami/Agent/RunJob.hs`, the
  declaration is `shikigami-core/src/Shikigami/Agent/Decl.hs`).
  Date: 2026-08-05

- Decision: Define `AgentVersionRef` here rather than waiting for a governed-evolution plan.
  Rationale: binding a run to an immutable agent version is required by the request this work
  answers, and nothing in the repository provides it.
  `docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md` covers the
  `identity`, `memory`, and `enabled` declaration fields and never mentions declaration
  revision or run pinning. `docs/improvement-requests/governed-agent-evolution.md` asks for
  exactly that, and has no ExecPlan. Defining a minimal, lineage-ready record here and pinning
  its byte encoding means the governed-evolution work extends one vocabulary instead of
  reconciling two.
  Date: 2026-08-05

- Decision: `ReviewedArtifact` is defined over the revision-pinned repository vocabulary that
  `docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md` introduces, and
  this plan carries a local definition of those few types only until plan 44 lands.
  Rationale: two revision vocabularies in one repository is the exact failure this plan exists
  to prevent. Plan 44 is not yet started, so waiting for it would gate the one plan that has no
  dependencies. Milestone 3 defines the minimum locally and states the single follow-up edit
  that replaces it, so the reconciliation is one import change rather than a redesign.
  Date: 2026-08-05


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

You need nothing but this file and the working tree. Everything below names full paths.

**The repository.** Shikigami is a Haskell project built with Cabal inside a Nix development
shell. There are six packages, listed in `cabal.project` and documented in
`docs/architecture/packages.md`. Only two matter for this plan:

- `shikigami-core` is the domain. Declarations, agent runs, behaviors, flows, sinks, memory,
  and durable workflow logic live here. It depends on no sibling package. Everything this plan
  writes goes here.
- `shikigami-api` is the public HTTP contract and depends on `shikigami-core`. Nothing in this
  plan touches it.

`shikigami-core/test/Shikigami/PackageArchitectureSpec.hs` is a test that fails the build if a
package takes a forbidden dependency. You will not trip it if you stay inside
`shikigami-core`.

**Building and testing.** All commands run from the repository root,
`/Users/shinzui/Keikaku/bokuno/shikigami`. The project builds inside a Nix shell:

```bash
nix develop -c cabal build shikigami-core
nix develop -c cabal test shikigami-core-test
```

The test framework is `tasty` with `tasty-hunit`. Each test module exports a single
`tests :: TestTree`, and `shikigami-core/test/Main.hs` imports it and lists it inside a
`testGroup "shikigami"`. Adding a test module means three edits: create the file, add its
module name to the `other-modules:` list of the `test-suite shikigami-core-test` stanza in
`shikigami-core/shikigami-core.cabal`, and add an import plus a list entry in
`shikigami-core/test/Main.hs`. Read that file before editing — it shows the exact shape.

To run one test group while iterating:

```bash
nix develop -c cabal test shikigami-core-test --test-option -p --test-option "attestation"
```

**House style for records.** Read `shikigami-core/src/Shikigami/Agent/RunJob.hs` first; it is
short and it is the pattern. Records use strict fields (a `!` before each field type),
`deriving stock (Eq, Show, Generic)`, and `deriving anyclass (ToJSON, FromJSON)`. Modules
import `Shikigami.Prelude`, which re-exports the Aeson names you need (`ToJSON`, `FromJSON`,
`Options (..)`, `defaultOptions`, `genericToJSON`, `genericParseJSON`, `camelTo2`,
`SumEncoding (..)`) plus `Text`, `UTCTime`, and `Generic`. It also exports
`eventAesonOptions`, which encodes sum types as `{"type": ..., "data": ...}` with
snake-cased constructor tags.

**The `omitNothingFields` discipline, which this plan depends on.** When a record has an
optional field and you encode with the default Aeson options, a `Nothing` still appears in the
JSON as `"field": null`. That means adding an optional field to a record changes the bytes of
every value, including ones already written to a database or a queue. The repository's answer
is to encode such records with `omitNothingFields = True`, so a record that resolved nothing
is byte-identical to one written before the field existed. You can see it applied at
`shikigami-core/src/Shikigami/Agent/Workflow.hs:139` and
`shikigami-core/src/Shikigami/Flow/SinkOutbox.hs:67`. This is exactly the mechanism that lets
Milestone 2 promise that a future plan can add agent-version lineage without rewriting
history, and Milestone 2's test is what makes the promise checkable.

**Byte-pinned fixtures.** `shikigami-core/test/Shikigami/WireCompatSpec.hs` holds literal JSON
strings captured from encoders, with a module comment explaining why they are literals: a
fixture built by calling the current encoder would pass no matter what the encoder did. Follow
that convention. Write the expected bytes as a literal; never generate them.

**Terms used below, defined once.**

*Provider* is the service that runs a language model — for example Anthropic. *API* or
*transport* is how the provider is reached: an HTTP API, or a command-line executable. In this
repository the provider choice is currently a configuration value, `ProviderSelection`, in
`shikigami-core/src/Shikigami/App/Config.hs:173`, turned into a live environment by
`shikigami-core/src/Shikigami/Behavior/Provider.hs`. Read the module comment at the top of
that file — it explains that the stub is a real provider and why the runtime announces which
one is active.

*Thinking level* is a canonical name for how much reasoning effort a model is asked to spend.
Providers express it differently (an effort word, a token budget, an adaptive mode), so a
canonical level has to be *translated* per provider, and the translation can clamp or collapse
one level into another. That is why a policy in this plan permits whole tuples of
`(provider, API, model, thinking)` rather than independent lists — permitting model `X` and
thinking `high` separately would silently permit a combination nobody sanctioned.

*Digest* means a hash of a canonical byte encoding of something, used as an immutable
identifier. *Canonical* means there is exactly one byte encoding for a given logical value, so
two parties hashing the same value get the same digest. This plan defines the canonical
encoding for the attestation payload; it does not yet compute signatures.

*Attestation* is a signed statement of facts about a run. The signature and the signing key
are not this plan's work — `docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md`
owns them. This plan defines the envelope those facts go in, including a field to hold the
signature once it exists.

**The upstream documents this plan mirrors.** Two other repositories own parts of this
vocabulary, and both requests are in the `proposed` state as of 2026-08-05 — meaning written
down and reviewed, but not implemented:

- `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6` ratifies the shared,
  cross-repository canonical envelope. It names five logical records:
  `SanctionedExecutionProfileRef`, `ModelCallEvidence`, `ReviewedArtifact`,
  `AgentArtifactSet`, and `AgentRunAttestation`. It also defines the four evidence strengths —
  `declared`, `runtime-observed`, `runtime-attested`, `provider-attested` — and states that a
  verifier must never silently promote one to another. Resolve the local path with
  `mori path mori://shinzui/kikan` and read
  `docs/improvement-requests/define-sanctioned-agent-execution-attestations.md` there. Its
  "Shared contract" and "Invariants" sections are normative for this plan.
- `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-3` will make the provider
  adapter emit one `ModelCallEvidence` per terminal call. This plan defines the *shape* of the
  record Shikigami stores; it does not depend on baikai emitting anything, because nothing here
  calls a provider. Read
  `docs/improvement-requests/capture-verifiable-model-call-evidence.md` in the baikai
  repository for the field list its "Requested contract" section specifies.

The request this plan serves is checked into this repository at
`docs/improvement-requests/attest-sanctioned-agent-execution.md`; read it. The driving
scenario is `mori://shinzui/kikan/okf/use-cases/concepts/UC-8`, which in the kikan repository
is `docs/use-cases/008-sanctioned-agent-review-attestation.md`; its "Failure cases" section is
the best short summary of what the taxonomy in Milestone 3 must be able to express.

Because both upstream requests are only `proposed`, this plan mirrors their vocabulary under
an explicit local schema version rather than importing a package that does not exist. If the
upstream shape changes before it is ratified, the conformance test in Milestone 4 fails and
tells you exactly which field moved. That is the intended behavior.


## Plan of Work

Four milestones, each adding one module and its tests. Nothing in this plan calls a provider,
touches a database, opens a socket, or reads a repository, so every milestone is verified
purely by `nix develop -c cabal test shikigami-core-test`.

### Milestone 1 — the sanctioned execution profile

Create `shikigami-core/src/Shikigami/Attestation/Profile.hs`. This module answers: what is a
policy that says how a run is allowed to execute?

A profile is immutable and versioned. It carries a profile id, a version, a canonical digest
of itself, an issuer, a validity window, and a lifecycle state. The lifecycle needs at least
`Active`, `Expired`, and `Withdrawn`, because the resolution step in
`docs/plans/50-fail-closed-profile-resolution-and-run-pinning.md` must refuse a withdrawn
profile differently from an unknown one, and the refusal reason ends up in an audit record.

The heart of the profile is a non-empty set of allowed tuples. Define a record for one
permitted combination — provider, API or transport, endpoint class, exact model id, and
canonical thinking level — and make the profile hold a `NonEmpty` of them. `NonEmpty` is
re-exported from `Shikigami.Prelude`. Using `NonEmpty` rather than a list is the point: a
profile that permits nothing would make every run non-conforming, which is a configuration
mistake that should be impossible to express rather than caught later.

Alongside the allowances, the profile carries explicit prohibitions, because the request is
specific that omitted defaults are not evidence of compliance. Model them as a record of
booleans with names that read as questions a verifier asks: are model aliases allowed, is a
defaulted thinking level allowed, is provider fallback allowed, is model fallback allowed, is
effort clamping allowed, are command-line transports allowed. Default every one of them to
disallowed, and say so in the haddock, so that a hand-written profile that forgets a field
fails closed rather than open.

The profile also carries limits — maximum calls, retries, delegated child runs, tokens, cost,
and duration, and a concurrency cap — a minimum required evidence strength, the set of
provider correlation fields it requires to be present, and the signer and retention
requirements for the eventual attestation. Model limits as a record of `Maybe` values where
absent means unlimited, and document that choice: an absent limit is a deliberate "no ceiling"
rather than a zero.

Encode the whole module's records with `omitNothingFields = True` for the same reason
Milestone 2 needs it. Export a single `profileAesonOptions` from the module and use it in every
instance, so there is one place to change.

The digest field deserves care. A profile's digest is over the profile's *content*, so the
digest cannot be part of the content it covers. Model this as two types: a
`SanctionedExecutionProfile` holding the content, and a `SanctionedExecutionProfileRef`
holding the profile id, the version, and the digest — matching the name kikan IR-6 uses. This
plan does not compute the digest (no hashing dependency is added here); it defines the
`ProfileDigest` newtype the computation will fill in, and Milestone 4 of
`docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md` adds the hashing.

Tests go in a new `shikigami-core/test/Shikigami/AttestationContractsSpec.hs`. For this
milestone: every record round-trips through `toJSON` and `fromJSON`; a profile with all
prohibitions at their defaults encodes with no `null` fields; and the three lifecycle states
are distinguishable after a round trip. Register the module in the cabal `other-modules:` list
and in `shikigami-core/test/Main.hs`.

### Milestone 2 — agent version and artifact set

Create `shikigami-core/src/Shikigami/Attestation/Agent.hs`. This module answers: which agent,
at which exact version, made of which exact parts?

Two records. `AgentVersionRef` is this repository's own notion of agent identity: a logical
agent id (the stable name, which for a manifest under `agents/` is its declared `name` — see
`shikigami-core/src/Shikigami/Agent/Decl.hs`), an immutable version identifier, and the
declaration digest. `AgentArtifactSet` is the portable digest bundle kikan IR-6 names: digests
of the declaration, the executable behavior or serialized program, the skills or instructions,
the tool catalog, the grounding bundle, the runtime, and the policy.

The design constraint that matters more than the field list: this repository will later grow
*governed agent evolution* — the ability to keep a baseline and a candidate version of an
agent active at once, relate them, and roll one out. That work is requested in
`docs/improvement-requests/governed-agent-evolution.md` and has no plan yet. When it arrives it
must extend `AgentVersionRef` rather than replace it. So every field it will need — a baseline
pointer, a candidate relation, a rollout state — must be addable as an optional field without
changing the bytes of records written today.

That is what this milestone proves rather than asserts. Encode both records with
`omitNothingFields = True`. Then add a test that pins the exact JSON bytes of a fully populated
`AgentVersionRef` as a *literal string* in the test module, following the convention documented
at the top of `shikigami-core/test/Shikigami/WireCompatSpec.hs`. Add a second test that
constructs the same value and asserts `encode` produces those exact bytes. When a later plan
adds an optional lineage field, that test still passes — and if someone adds a *required*
field, or forgets `omitNothingFields`, it fails immediately with a byte diff. Write a haddock
comment on `AgentVersionRef` saying this in plain words, naming the governed-evolution request
by path, so the next person understands why the test exists.

Digests are `newtype`s over `Text` in this milestone, not computed values. Give each a distinct
type — a declaration digest is not interchangeable with a tool-catalog digest — because the
compiler catching a swapped digest is worth more than the brevity of a shared alias.

### Milestone 3 — reviewed artifact, non-conformance, and evidence strength

Create `shikigami-core/src/Shikigami/Attestation/Reviewed.hs`. This module answers: what code
was reviewed, how strong is a piece of evidence, and in what specific ways can a run fail to
conform?

`ReviewedArtifact` identifies the canonical repository, the full base and head commits, a
digest of the reviewed diff or tree, the path scope, and an optional pull-request identity.
Both upstream documents are emphatic on one point: a branch name or a pull-request number
alone is insufficient, because both can move. Enforce that in the type. A full commit hash gets
a newtype whose smart constructor rejects anything that is not a full-length hexadecimal hash —
export the constructor function, not the data constructor, so a short hash cannot be built at
all. The pull-request identity is `Maybe` and is documented as decoration: it must never be
load-bearing for verification.

Repository identity and revisions are shared vocabulary.
`docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md` introduces an
`EvidenceReader` whose `readDiff` takes a repository identity and two revisions and returns a
pinned diff, and that is the vocabulary this repository will standardise on. Plan 44 is not
started, so define the minimum here — `RepositoryId` and `Revision` newtypes — and write a
haddock note saying that when plan 44 lands, these two definitions are deleted and imported
from it instead, and that `ReviewedArtifact` itself does not change. Record the same note in
this plan's Decision Log (already recorded above) so the follow-up is not lost.

`EvidenceStrength` is **not defined here.** `baikai 0.5.0.0`'s `Baikai.Evidence` publishes an
ascending `EvidenceStrength` scale as part of the model-call evidence vocabulary, and it arrives
on every `ModelCallEvidence` that `docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md`
collects. Declaring a second identical scale here would mean translating between two orderings for
one concept. Import baikai's, and re-export it from this module if a local name reads better at
use sites.

Keep the haddock warning on the re-export, because it is shikigami's caution and not baikai's:
the ordering exists to *check* a minimum, never to promote a weaker claim to a stronger one.

If the cohort has not yet taken baikai 0.5 when this milestone runs — `kioku-core 0.3.0.0` caps
`baikai ^>=0.4.1.0`, so it may not have — declare the four-constructor sum locally (declared,
runtime-observed, runtime-attested, provider-attested, in that order, with a deliberate `Ord`
instance, exactly as kikan IR-6's table defines them) *and* write a haddock note naming baikai as
its future home, in the same style as the `RepositoryId` and `Revision` note above. Delete it when
the bound lifts. A local definition that outlives the gate without that note is the failure mode.

`NonConformingReason` is the taxonomy, and it should be generous rather than clever, because a
roll-up that records every reason is worth far more than one that reduces partial evidence to a
boolean. Read the "Failure cases" section of UC-8 and the "Compliance verdict" section of
`docs/improvement-requests/attest-sanctioned-agent-execution.md` and give each a constructor
carrying the specifics: a call whose model was not in the profile, a thinking level whose
provider translation was not permitted, a prohibited default, alias, fallback, transport,
endpoint, or effort translation, a missing call, retry, continuation, or delegated child, a
reviewed artifact that no longer matches its bound digests, a review result that does not match
the result digest, and evidence below the profile's required strength. Add a distinct
`NotApplicable` marker for deterministic steps — a step that made no model call must be
recorded as not applicable, never as a fabricated call. Encode the sum with
`eventAesonOptions` from `Shikigami.Prelude` so the tagging matches the rest of the
repository.

Tests: a short hash and an empty hash are both rejected by the commit constructor, and a full
one is accepted; a `ReviewedArtifact` cannot be built from a branch name alone (demonstrated by
the constructor's type, and asserted by a test that a pull-request-only value still requires
both commits); the strength ordering is as documented; and every `NonConformingReason`
constructor round-trips.

### Milestone 4 — the attestation envelope and its canonical encoding

Create `shikigami-core/src/Shikigami/Attestation/Envelope.hs`. This module answers: what is
the signed document, and what exactly gets hashed?

`AgentRunAttestation` carries a schema version, the issuer and key identity, an issue time and
optional expiry, the run and session identity, the review class, the profile reference, the
reviewed and agent artifact digests, the ordered complete call-evidence set or its Merkle root,
the review-result digest, a completeness verdict, a sanctioned verdict with its typed reasons,
the payload digest, and the signature. The schema version is a required field with a named
constant for the current value — `currentAttestationSchemaVersion` — because kikan IR-6's
invariant 7 requires an unknown schema to fail closed, which is impossible if the version is
optional.

Separate the payload from the envelope. Define an `AttestationPayload` holding everything the
signature covers, and let `AgentRunAttestation` hold that payload plus the signature and key
identity. This is not cosmetic: the digest must be over a byte encoding that does not include
the signature, and keeping them in one flat record makes that error easy to make and hard to
see.

Define the canonical encoding as a named function rather than relying on `encode`. Aeson's
default object key order is not guaranteed to be stable across versions or across
implementations in other languages, and this digest has to match a hash computed by a
different repository, possibly in a different language. Write
`canonicalPayloadBytes :: AttestationPayload -> ByteString` that produces keys in sorted order
with no insignificant whitespace, and document in the haddock that this function's output is a
wire format: changing it changes every digest, so it needs a schema-version bump and a
migration story, not an edit.

Implement that function in terms of `Baikai.Evidence.canonicalEncode` rather than writing the
encoder by hand. Baikai 0.5 already normalises numbers (so `1`, `1.0`, `1.00`, and `1e0` agree)
and uses a hand-written string escaper precisely so an aeson upgrade cannot silently invalidate a
recorded digest — two properties a fresh implementation would plausibly miss and discover later as
a cross-repository digest mismatch, which is the one failure this design exists to prevent. Keep
`canonicalPayloadBytes` as a named function of this plan's own anyway: what this plan owns is
which fields the payload contains and in what shape, which is the part kikan IR-6 ratifies. The
encoder is borrowed; the payload definition is not. If the cohort has not yet taken baikai 0.5,
write the encoder locally with a haddock note pointing at `canonicalEncode` as its replacement.

Then define
`attestationPayloadDigest :: AttestationPayload -> PayloadDigest` as a `newtype` wrapper whose
*computation* is deliberately left to plan 52 — this milestone provides the canonical bytes and
the type, and plan 52 adds the hash function together with the hashing dependency it needs.
Say so in the haddock so nobody thinks the digest is already being computed.

The conformance test is the milestone's real acceptance. Locate kikan's published golden
payload — run `mori path mori://shinzui/kikan` to find the repository, then look for the
fixtures its IR-6 "Conformance fixtures" section promises. If those fixtures exist, add a test
asserting `canonicalPayloadBytes` over the equivalent value matches the golden bytes exactly.
If they do not exist yet — likely, since IR-6 is `proposed` — then write the test as a pinned
local fixture with a haddock comment naming the upstream request, and record in Surprises &
Discoveries that the upstream fixture was absent on the date you looked, so the next
contributor knows the conformance claim is still one-sided. Do not skip the test, and do not
pretend it is two-sided.

Finish by exposing all four modules from `shikigami-core`, registering the spec module, and
running the whole suite.


## Concrete Steps

Work from the repository root, `/Users/shinzui/Keikaku/bokuno/shikigami`.

First, read the material that makes the rest of this plan concrete:

```bash
cat docs/improvement-requests/attest-sanctioned-agent-execution.md
cat shikigami-core/src/Shikigami/Agent/RunJob.hs
sed -n 1,45p shikigami-core/test/Shikigami/WireCompatSpec.hs
sed -n 30,60p docs/architecture/packages.md
```

Then read the two upstream requests. Resolve the paths first — do not guess them, and do not
search the filesystem root:

```bash
mori path mori://shinzui/kikan
mori path mori://shinzui/baikai
```

Read `docs/improvement-requests/define-sanctioned-agent-execution-attestations.md` and
`docs/use-cases/008-sanctioned-agent-review-attestation.md` under the kikan path, and
`docs/improvement-requests/capture-verifiable-model-call-evidence.md` under the baikai path.

For each milestone: create the module under `shikigami-core/src/Shikigami/Attestation/`, add
its name to the `exposed-modules:` list in the `library` stanza of
`shikigami-core/shikigami-core.cabal`, extend
`shikigami-core/test/Shikigami/AttestationContractsSpec.hs`, then build and test:

```bash
nix develop -c cabal build shikigami-core
nix develop -c cabal test shikigami-core-test --test-option -p --test-option "attestation"
```

The first time you add the spec module, also add `Shikigami.AttestationContractsSpec` to the
`other-modules:` list of the `test-suite shikigami-core-test` stanza and wire it into
`shikigami-core/test/Main.hs` — add the qualified import next to the others and add
`AttestationContractsSpec.tests` to the list inside `testGroup "shikigami"`.

Format before committing; the repository uses a Nix formatter:

```bash
nix fmt
```

A passing focused run looks like this, with the group name from your `testGroup`:

```text
shikigami
  attestation contracts
    profile round-trips:                             OK
    profile with default prohibitions omits nulls:   OK
    agent version ref matches pinned bytes:          OK
    short commit hash is rejected:                   OK
    evidence strength ordering:                      OK
    canonical payload bytes match golden fixture:    OK

All 6 tests passed (0.01s)
```

Commit at each milestone. Every commit under this initiative carries both trailers and the
intention:

```text
feat(attestation): declare the sanctioned execution profile

Add Shikigami.Attestation.Profile with allowed (provider, API, model,
thinking) tuples, fail-closed prohibitions, and limits.

MasterPlan: docs/masterplans/10-sanctioned-execution-attestation-for-agent-runs.md
ExecPlan: docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md
Intention: intention_01kz96h79mezmbnwm67pdjjepr
```


## Validation and Acceptance

The whole suite must pass, not only the new group:

```bash
nix develop -c cabal test all
```

As of 2026-07-31 the repository had 157 passing tests across seven suites; your run should
report that count plus the tests you added, with no failures. If the count is lower than 157,
something regressed — investigate before proceeding rather than assuming the baseline moved.

Acceptance is these observable behaviors, each backed by a named test:

A profile that permits nothing cannot be constructed, because the allowed tuples are a
`NonEmpty`; attempting it is a compile error, which you demonstrate by leaving a commented
example in the spec module explaining what fails and why.

A profile built with every prohibition left at its default encodes to JSON containing no
`null` values and no fields for the unset limits. Assert the exact bytes.

A fully populated `AgentVersionRef` encodes to the exact bytes pinned as a literal in the spec
module. This is the test that protects the governed-evolution follow-up, so its failure message
should say so.

`mkFullCommit "abc123"` fails and `mkFullCommit` with a full-length hexadecimal hash succeeds;
a `ReviewedArtifact` therefore cannot be assembled from a branch name or a pull-request number.

`Declared < RuntimeObserved < RuntimeAttested < ProviderAttested` holds, and the haddock on
that instance states that the ordering is for checking a minimum only.

Every `NonConformingReason` constructor survives a JSON round trip, including the specifics it
carries, and `NotApplicable` is distinguishable from every failure reason.

`canonicalPayloadBytes` over a fixed `AttestationPayload` produces byte-identical output on
repeated calls and matches the pinned fixture. If kikan's golden payload was available, the
fixture *is* kikan's bytes and the test is two-sided; if not, Surprises & Discoveries records
that it is one-sided and why.

Beyond compilation, the demonstration that this plan did something real is a short transcript
in Outcomes & Retrospective: encode one profile, one agent version ref, and one attestation
payload, and paste the JSON. Someone reading those three objects should be able to say what
policy a run was held to, which agent version ran, and what was signed — without reading any
Haskell.


## Idempotence and Recovery

Every step here is additive and safe to repeat. The plan creates four new modules and one new
test module and edits two lists (the cabal file's `exposed-modules:` and `other-modules:`, and
the imports and test list in `shikigami-core/test/Main.hs`). Re-running a build or a test
changes nothing on disk. No migration, no database, no network call, no destructive operation
appears anywhere in this plan.

If a milestone's design turns out wrong, deleting its module and its cabal entries returns the
tree to the previous state; nothing else depends on these modules until
`docs/plans/50-fail-closed-profile-resolution-and-run-pinning.md` begins.

The one irreversible-by-convention artifact is a pinned byte fixture. Once a literal is
committed and a downstream plan has stored records shaped by it, changing that literal is a
wire-format change and needs a migration story rather than a fixture edit — the same rule
`shikigami-core/test/Shikigami/WireCompatSpec.hs` states for its own fixtures. Until plan 50
lands, nothing has been stored, so a fixture can still be corrected freely; say so in the
Progress notes if you do.


## Interfaces and Dependencies

No new package dependencies. Every record here needs only `aeson`, `bytestring`, `text`,
`time`, and `containers`, all already in the `library` stanza of
`shikigami-core/shikigami-core.cabal`. Hashing and signing dependencies are deliberately
deferred to `docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md`; when that plan
adds one, it must verify the released version against the authoritative package registry and
upstream release tags rather than taking a version from a local corpus, per this repository's
`AGENTS.md`.

All records use strict direct fields, explicit deriving strategies, and a single per-module
Aeson options function with `omitNothingFields = True`. Sum types encode with
`eventAesonOptions` from `Shikigami.Prelude`.

These are the module paths and the signatures that must exist when the plan is complete. Field
lists in the milestone narratives are normative even where a constructor is split for
readability.

```haskell
-- shikigami-core/src/Shikigami/Attestation/Profile.hs
newtype ProfileId = ProfileId {value :: Text}
newtype ProfileVersion = ProfileVersion {value :: Text}
newtype ProfileDigest = ProfileDigest {value :: Text}
newtype Issuer = Issuer {value :: Text}

data ProfileLifecycle = Active | Expired | Withdrawn
data AllowedCall = AllowedCall
  { provider :: !Text,
    api :: !Text,
    endpointClass :: !Text,
    modelId :: !Text,
    thinking :: !ThinkingLevel
  }
data Prohibitions = Prohibitions
  { aliasesAllowed :: !Bool,
    defaultedThinkingAllowed :: !Bool,
    providerFallbackAllowed :: !Bool,
    modelFallbackAllowed :: !Bool,
    effortClampingAllowed :: !Bool,
    cliTransportsAllowed :: !Bool
  }
data SanctionedExecutionProfile = SanctionedExecutionProfile
  { profileId :: !ProfileId,
    version :: !ProfileVersion,
    issuer :: !Issuer,
    lifecycle :: !ProfileLifecycle,
    validFrom :: !UTCTime,
    validUntil :: !(Maybe UTCTime),
    allowedCalls :: !(NonEmpty AllowedCall),
    prohibitions :: !Prohibitions,
    limits :: !ProfileLimits,
    minimumEvidenceStrength :: !EvidenceStrength,
    requiredCorrelationFields :: ![Text],
    signerRequirements :: !SignerRequirements
  }
data SanctionedExecutionProfileRef = SanctionedExecutionProfileRef
  { profileId :: !ProfileId,
    version :: !ProfileVersion,
    digest :: !ProfileDigest
  }
defaultProhibitions :: Prohibitions   -- every field disallowed
profileAesonOptions :: Options

-- shikigami-core/src/Shikigami/Attestation/Agent.hs
newtype LogicalAgentId = LogicalAgentId {value :: Text}
newtype AgentVersion = AgentVersion {value :: Text}
newtype DeclarationDigest = DeclarationDigest {value :: Text}
newtype BehaviorDigest = BehaviorDigest {value :: Text}
newtype ToolCatalogDigest = ToolCatalogDigest {value :: Text}
newtype GroundingDigest = GroundingDigest {value :: Text}

data AgentVersionRef = AgentVersionRef
  { logicalAgentId :: !LogicalAgentId,
    agentVersion :: !AgentVersion,
    declarationDigest :: !DeclarationDigest
  }
data AgentArtifactSet = AgentArtifactSet {..}

-- shikigami-core/src/Shikigami/Attestation/Reviewed.hs
newtype RepositoryId = RepositoryId {value :: Text}
newtype Revision = Revision {value :: Text}
newtype DiffDigest = DiffDigest {value :: Text}
newtype FullCommit = FullCommit {value :: Text}   -- data constructor NOT exported

mkFullCommit :: Text -> Either Text FullCommit
data EvidenceStrength = Declared | RuntimeObserved | RuntimeAttested | ProviderAttested
data ReviewedArtifact = ReviewedArtifact
  { repository :: !RepositoryId,
    baseCommit :: !FullCommit,
    headCommit :: !FullCommit,
    diffDigest :: !DiffDigest,
    pathScope :: ![Text],
    pullRequest :: !(Maybe Text)
  }
data NonConformingReason = ... | NotApplicable !Text

-- shikigami-core/src/Shikigami/Attestation/Envelope.hs
newtype PayloadDigest = PayloadDigest {value :: Text}
newtype SchemaVersion = SchemaVersion {value :: Text}

currentAttestationSchemaVersion :: SchemaVersion
data AttestationPayload = AttestationPayload {..}
data AgentRunAttestation = AgentRunAttestation
  { payload :: !AttestationPayload,
    payloadDigest :: !PayloadDigest,
    signature :: !(Maybe Text),
    keyId :: !(Maybe Text)
  }
canonicalPayloadBytes :: AttestationPayload -> ByteString
```

`ThinkingLevel`, `ProfileLimits`, and `SignerRequirements` are defined in
`Shikigami.Attestation.Profile` alongside the records that use them.
`EvidenceStrength` is defined in `Shikigami.Attestation.Reviewed` and imported by
`Shikigami.Attestation.Profile`; if that import direction causes an awkward cycle when you get
there, move `EvidenceStrength` into a small `Shikigami.Attestation.Strength` module rather than
duplicating it, and note the change in Surprises & Discoveries.

The signature and key fields on `AgentRunAttestation` are `Maybe` in this plan because nothing
signs yet; `docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md` owns making a
served attestation always carry them, and owns the hash function behind `PayloadDigest`.


## Revision Notes

- 2026-08-10: Reconciled with `baikai 0.5.0.0`, which published two things this plan defines. The
  two overlaps have opposite resolutions, which is the point worth remembering.

  `EvidenceStrength` leaves this plan. Baikai's `Baikai.Evidence` ships an ascending
  `EvidenceStrength` scale as part of the model-call evidence vocabulary, and it arrives on every
  `ModelCallEvidence` that plan 51 collects. A second identical scale owned here would mean
  translating between two orderings for one concept, with a silent disagreement available whenever
  they drift. Milestone 3 now imports baikai's and may re-export it. The haddock warning stays and
  moves with the re-export, because it is shikigami's caution rather than baikai's: the ordering
  exists to check a minimum, never to promote a weaker claim to a stronger one.

  The canonical encoding stays. Baikai also ships `canonicalEncode`, and Milestone 4 should
  implement `canonicalPayloadBytes` in terms of it — the upstream encoder normalises numbers and
  hand-writes its string escaper so an aeson upgrade cannot silently change a digest, both of which
  a fresh implementation would plausibly miss and only discover as a cross-repository mismatch. But
  `canonicalPayloadBytes` remains a named function of this plan's own, because what this plan owns
  is which fields the payload contains and in what shape, and that is the part kikan IR-6 ratifies.
  The encoder is borrowed; the payload definition is not.

  Both changes carry a fallback, because `kioku-core 0.3.0.0` caps `baikai ^>=0.4.1.0` and the
  cohort cannot take baikai 0.5 yet. Where the import is unavailable, define locally *with a
  haddock note naming baikai as the future home* — the same pattern this plan already uses for
  `RepositoryId` and `Revision` pending plan 44 — and delete it when the bound lifts. A local
  definition that outlives the gate without that note is the failure this records against. Nothing
  about the gate should delay Milestones 1, 2, or 4; this plan remains contract-only and startable.
