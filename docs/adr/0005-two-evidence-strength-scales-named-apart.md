# 0005. Two evidence-strength scales, kept separate and named apart

Date: 2026-08-19

Status: accepted


## Context

Sanctioned-execution attestation needs to say how much a claim proves. Two
upstream sources supply a vocabulary for that, both are ascending ordered scales,
both were called `EvidenceStrength`, and they measure different things.

`baikai 0.5.0.0` publishes `Baikai.Evidence.EvidenceStrength`:
`EvidenceRequestedOnly`, `EvidenceCorrelated`, `EvidenceModelObserved`,
`EvidenceFullyObserved`. It grades **how much the provider corroborated one
call** — whether a correlation id came back, whether the response named the model
it ran, whether it named the effective thinking configuration. A value arrives on
every `ModelCallEvidence` record.

`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6` defines a table of
`declared`, `runtime-observed`, `runtime-attested`, `provider-attested`. It
grades **who vouches for a claim** — configuration, the runtime's own records, a
runtime signature over a complete roll-up, or the provider itself.

These are not two rankings of one thing. Every value baikai can emit is a runtime
observation of some completeness, so the whole of baikai's four-level scale sits
inside kikan's single `runtime-observed` tier. baikai cannot emit
`runtime-attested` — it does not sign Shikigami run attestations — and it cannot
emit `declared`, since it only speaks about calls that actually happened.

`docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md` was
revised on 2026-08-10 to delete its own four-constructor scale and adopt baikai's,
on the belief that baikai had published "an identical scale". Implementing that
revision literally would have removed the vocabulary IR-6 ratifies. It would also
have made IR-6 acceptance criterion 6 — "a declaration-only record cannot satisfy
a runtime-attested policy" — impossible to state, because neither `declared` nor
`runtime-attested` would be a value any type in the repository could hold.


## Decision

**Both scales exist, they are never converted into one another, and they do not
share a name.**

* `Baikai.Evidence.EvidenceStrength` is the per-call floor. It is what
  `SanctionedExecutionProfile.minimumEvidenceStrength` is compared against, and
  what UC-8's "response evidence is below the profile's required strength"
  measures. `Shikigami.Attestation.Reviewed` re-exports it; nothing in this
  repository declares a competing per-call scale.
* `Shikigami.Attestation.Strength.AttestationStrength` is kikan's four trust
  tiers, declared here because nothing upstream publishes them as a type. It is
  what `AttestationPayload.strength` carries.
* Neither is derived from the other, and no function maps between them. A
  `ModelCallEvidence` reaching `EvidenceFullyObserved` does not make a run
  `RuntimeAttested`; only signing a complete roll-up does.
* `AttestationStrength` encodes with kikan's hyphenated spellings — `declared`,
  `runtime-observed`, `runtime-attested`, `provider-attested` — not the
  underscored form `Shikigami.Prelude.eventAesonOptions` would produce. These
  exact strings are read by verifiers in other repositories, so the spelling is
  the shared contract's rather than this repository's house style.
* Both `Ord` instances exist to **check a minimum** and for nothing else. Ask
  `observed >= required` and refuse when it does not hold. An unknown or
  unparseable strength is an indeterminate verdict, never a passing one.


## Alternatives rejected

**Adopt baikai's scale alone, as the plan's revision note said.** This is the
option that was written down and that implementation reversed. It loses
`declared` and `runtime-attested`, which are the two tiers a gate actually
decides on, and it silently reinterprets a per-call observation grade as a
statement about who vouches for a whole run — a promotion of exactly the kind
IR-6 forbids.

**Declare our own four tiers and ignore baikai's.** Recreates the duplication the
revision note was right to fear. baikai's value arrives on every evidence record
whether or not we model it, so ignoring it means translating at the point where a
profile's floor is checked, which is the one comparison that has to be
trustworthy.

**Keep both but call them both `EvidenceStrength`, disambiguating by import.**
Two same-named ordered types in one process, one of which is on every record
`docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md` collects. The
disambiguation would live in import lists rather than at use sites, and a
qualified-import mistake would type-check whenever both scales appeared in the
same comparison position. The names carry the distinction instead.

**Model kikan's tiers as a computed function of the evidence set.** Tempting,
because `runtime-attested` really is "signed a complete roll-up". But it makes
the tier a derived opinion rather than a recorded claim, and IR-6 requires the
attestation to state its strength explicitly so a verifier can refuse an
unfamiliar one.


## Consequences

Anyone reading `minimumEvidenceStrength` on a profile and `strength` on an
attestation payload is looking at two different vocabularies in two adjacent
records. That is intended, and the haddock on both says so, but it will surprise
someone at least once.

`docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md` collects
`ModelCallEvidence` values carrying baikai's strength and must roll them up into a
payload carrying kikan's. There is deliberately no helper for that step: the
roll-up decides `RuntimeAttested` by whether it signed a complete set, not by
inspecting call strengths. If a future contributor writes a
`toAttestationStrength :: EvidenceStrength -> AttestationStrength`, this record is
the argument against it.

If baikai ever renames its type or adds a tier, only the per-call floor moves;
`AttestationStrength` is ours and is pinned to IR-6's table. Conversely, if IR-6
is ratified with a changed table, `AttestationStrength` changes and baikai's does
not.


## References

* `docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md` — the
  plan this record corrects, including the 2026-08-10 revision note that reached
  the opposite conclusion and the Surprises entry explaining the reversal.
* `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6` — the
  evidence-strength table and invariant 7 (unknown strengths fail closed).
* `mori://shinzui/kikan/okf/use-cases/concepts/UC-8` — "response evidence is
  below the profile's required strength: indeterminate and reject", the failure
  case that fixes which scale the profile's floor is on.
* `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-3` — the
  provider-boundary capture whose records carry baikai's scale.
