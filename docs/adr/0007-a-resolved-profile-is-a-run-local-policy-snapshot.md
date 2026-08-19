# 0007. A resolved profile is a run-local policy snapshot

Date: 2026-08-19

Status: accepted


## Context

A sanctioned execution profile says which complete provider/API/transport/model/
thinking tuples an agent run may dispatch. The profile store is consulted at the
start of a run, but an agent run is a durable Keiro workflow: it can crash or
suspend, then replay hours later after the stored row has changed.

Pinning only a `SanctionedExecutionProfileRef` is not enough. Its digest proves
which policy bytes the run originally saw, but the reference cannot reconstruct
the original allowed tuples. Re-reading the store during replay would enforce
today's row while claiming the run remained pinned to yesterday's digest. A
database mutation would therefore change policy halfway through one run without
changing the audit identity attached to it.

The enforcement boundary is Baikai's `Model` plus per-call `Options` from
`mori://shinzui/baikai/packages/baikai`. Together they contain the values that
will actually dispatch: provider, API tag, exact catalog model id, and optional
thinking level. Checking a separate copy of provider configuration would allow
that copy and the dispatched value to drift.


## Decision

**The journaled `resolve-profile` result is the authoritative, run-local policy
snapshot: the complete resolved profile content together with its digest-bearing
reference. Provider dispatch is constrained from that snapshot before any
session or provider request is created.**

Concretely:

* `resolve-profile` runs after `lookup-agent` and before `open-session`. Its
  persisted type is
  `Either ProfileResolutionError (Maybe ResolvedProfile)`, where
  `ResolvedProfile` contains both `SanctionedExecutionProfile` and
  `SanctionedExecutionProfileRef`.
* Unknown, expired, withdrawn, ambiguous, and digest-mismatched profiles are
  permanent workflow failures. They return the workflow's existing `Left Text`
  result rather than throwing, and no session or sink intent is created.
* The step is guarded by the permanent patch id
  `shikigami-resolve-profile-v1`. Generations already in flight retain the old
  body shape; fresh generations record the patch and resolve any declared
  requirement.
* Only a `Skill` behavior is checked against a provider tuple, because it is the
  only behavior arm that reaches Baikai. Non-model behaviors may still resolve
  and pin a declared profile, but they have no model call to constrain.
* The exact `BehaviorEnv` later handed to `runBehavior` is checked. A violation
  is typed and carries the attempted tuple and pinned reference; its rendered
  permanent failure names the profile digest.
* Baikai API tags are normalized once into the profile vocabulary. Anthropic
  Messages is `(messages, https)`, OpenAI Chat Completions is
  `(chat-completions, https)`, CLI variants use endpoint class `cli`, and the
  deterministic stub is `(stub, in-process)`.
* An absent thinking level is an observable request to use the SDK/provider
  default. It is refused unless `defaultedThinkingAllowed` is explicitly true.
  Provider and model fallback are unavailable in this construction path, and a
  model id different from the exact allowed tuple is refused rather than treated
  as an alias.
* An agent with no `sanctionedProfile` declaration journals `Nothing` and keeps
  its previous behavior.
* Every shipped model-dispatch entry point follows the same boundary. The
  deployed workflow and `shikigami-agent-run` resolve from PostgreSQL;
  `shikigami-run-behavior`, which intentionally opens no database, refuses a
  profiled declaration before it constructs a provider environment.


## Alternatives rejected

**Journal only the profile reference and re-read content when dispatching.**
Smaller journals, but a replay would enforce mutable current state rather than
the policy identified by the run's original digest. That is not pinning.

**Journal only the reference and reject if the store changed.** This detects the
mutation but makes an otherwise recoverable in-flight run permanently unable to
finish. It also turns store retention into a hidden availability requirement for
workflow replay.

**Check the provider response after the call.** Too late: a forbidden call has
already reached the provider and cannot be undone. Evidence and compliance
roll-up may still report what happened, but they are not substitutes for this
pre-dispatch gate.

**Resolve at worker startup and constrain the process-wide environment once.**
Profiles are declared per agent and pinned per run. A process-level decision
cannot represent two agents with different profiles, and a restarted worker
would silently adopt newer policy for an older workflow.

**Constrain every behavior against the selected provider.** This would reject a
`ShikumiProgram`, deterministic rule, or Flow because of a provider it never
calls. The profile is still resolved for those declarations; only the
nonexistent call check is omitted.


## Consequences

The journal stores more than a digest. That is intentional: the extra bytes are
the policy needed to enforce replay without mutable external state. The JSON
shape of `ResolvedProfile` and the `resolve-profile` step name are now durable
interfaces. They may evolve only compatibly, or under a new step name/patch as
required by `docs/workflow-versioning.md`.

Changing a policy means publishing a new immutable version and digest. Editing a
row in place is detected on first resolution; editing it after a run resolved
cannot change that run's journaled policy. The crash/resume test deliberately
replaces the row and proves that resolution runs once and the original content
and digest survive.

Strict profiles that do not permit defaulted thinking will refuse the current
process environment when its Baikai `Options.thinking` is `Nothing`. This is a
fail-closed result, not an implicit choice of one allowed effort. A caller must
request an exact allowed level or the profile must explicitly sanction the
default.

The patch id appears in fresh workflow journals and in the checked Keiro
specification. Its activation and retirement follow
[ADR-0004](0004-one-options-value-and-a-checked-patch-set.md); it must not be
renamed or removed independently of its runtime branch.

Plans that record call evidence or judge compliance consume this same pinned
snapshot. They must not independently resolve the profile and create a second
answer to which policy governed the run.


## References

* `docs/plans/50-fail-closed-profile-resolution-and-run-pinning.md` — the
  implementation plan and its crash/resume and pre-dispatch acceptance evidence.
* `docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md` — the
  profile and reference vocabulary.
* `docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md` — the next
  consumer of the pinned policy snapshot.
* `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6` — the shared
  sanctioned-execution and attestation requirements.
* `mori://shinzui/baikai/packages/baikai` — the provider model, options, and
  thinking vocabulary inspected at the enforcement boundary.
* [ADR-0004](0004-one-options-value-and-a-checked-patch-set.md) — patch-set and
  rollout ownership.
* [ADR-0006](0006-the-attestation-payload-encoding-is-a-wire-format.md) — the
  canonical digest seam also used to compute profile digests.
