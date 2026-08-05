---
id: 50
slug: fail-closed-profile-resolution-and-run-pinning
title: "Fail-closed profile resolution and run pinning"
kind: exec-plan
created_at: 2026-08-05T14:53:02Z
intention: "intention_01kz96h79mezmbnwm67pdjjepr"
master_plan: "docs/masterplans/10-sanctioned-execution-attestation-for-agent-runs.md"
---

# Fail-closed profile resolution and run pinning

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A sanctioned execution profile is a policy saying which combinations of provider, API, model,
and thinking level an agent run is allowed to use, and which shortcuts it is forbidden to take.
`docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md` defines that policy
as a Haskell record. This plan makes it bite.

After this plan, an agent declared as requiring a sanctioned profile cannot start a run without
first resolving that profile to an immutable digest. You can demonstrate every failure mode from
a terminal: point a run at a profile id that does not exist and the run refuses to start, naming
the id; point it at an expired one and the refusal says expired; at a withdrawn one and it says
withdrawn; at one that resolves ambiguously to two versions and it says ambiguous; at a mutable
profile — one whose stored content does not hash to the digest it claims — and it says the
profile is mutable and therefore untrustworthy. In every case the run does not open a session,
does not call a model, and does not dispatch a sink. It fails closed.

The second half is subtler and matters just as much. Once resolved, the digest is journaled
inside the durable workflow before the behavior executes, so a run that crashes and resumes
hours later is still held to the profile it started under, not to whatever the profile store
says now. You demonstrate this by resolving a profile, killing the process mid-run, changing the
stored profile, restarting, and observing that the resumed run still reports the original
digest.

The third piece is the connection to the provider seam. A resolved profile constrains what may
be dispatched: a behavior asking for a model or thinking level outside the pinned tuple set
cannot reach the provider at all. This plan makes that a pre-dispatch refusal rather than an
after-the-fact audit finding, because a call that already happened cannot be un-made.

This plan does not record evidence, does not judge overall compliance, and does not sign
anything. Recording and judging belong to
`docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md`; signing and serving belong to
`docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md`.


## Progress

- [ ] M1: profile store and `resolveProfile`, with the five fail-closed refusals — unknown,
      expired, withdrawn, ambiguous, mutable — each carrying a typed reason.
- [ ] M1: `just new-migration` for the profile table; `reconcileShikigamiReadModels` confirmed
      to cover any read model added.
- [ ] M1: tests for all five refusals plus the success case, against a real ephemeral Postgres.
- [ ] M2: a `resolve-profile` journaled step in the agent-run workflow, placed before
      `open-session`, declared through the checked specification.
- [ ] M2: pinning test — resolve, crash mid-run, mutate the stored profile, resume, assert the
      original digest survives.
- [ ] M3: the resolved profile constrains the provider seam; a call outside the pinned tuple set
      is refused before dispatch, with a typed error naming the offending tuple.
- [ ] M3: an agent declared without a profile requirement behaves exactly as it does today —
      proven by the existing suite still passing unchanged.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Resolution is a journaled workflow step placed between `lookup-agent` and
  `open-session`, not a check inside the behavior runner.
  Rationale: the request requires the profile to be resolved and journaled *before* behavior
  execution, and requires an in-flight run to stay pinned to the resolved digest. A journaled
  step is the only construct in this repository that gives both properties for free: keiro
  journals the step's return value, so a resumed workflow replays the digest instead of
  re-resolving it. Placing it before `open-session` also means a refused run leaves no memory
  session behind, which keeps the failure clean.
  Date: 2026-08-05

- Decision: A profile whose stored content does not hash to its claimed digest is treated as
  *mutable* and refused, rather than being re-hashed and accepted.
  Rationale: the whole value of the digest is that the policy could not have changed after the
  run was bound to it. Silently re-hashing would make the check decorative. The refusal reason is
  distinct from "unknown" because the two mean different things to an operator: one is a typo,
  the other is tampering or a broken deployment.
  Date: 2026-08-05

- Decision: Requiring a profile is opt-in per agent, and an agent that does not require one runs
  exactly as it does today.
  Rationale: every existing manifest under `agents/` must keep working with zero edits, which is
  the same discipline
  `docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md` establishes for
  additive declaration fields. It also means this plan can land before any agent is actually
  gated, so the machinery is proven before it is depended on.
  Date: 2026-08-05


## Context and Orientation

Read `docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md` first; it is
checked into this repository and it defines every type this plan resolves and pins. In particular
it defines `SanctionedExecutionProfile` (the policy content), `SanctionedExecutionProfileRef`
(profile id, version, digest), `ProfileLifecycle` with `Active`, `Expired`, and `Withdrawn`, and
`ProfileDigest`. This plan does not redefine any of them.

**Where a run happens.** The durable agent run is
`shikigami-core/src/Shikigami/Agent/Workflow.hs`. Read `agentRunWorkflow` and `runResolvedAgent`
there. The shape is a sequence of *journaled steps*: `runStep deps (StepName "ingest-job") ...`,
then `lookup-agent`, then `open-session`, `recall`, `run-behavior`, then either `fail-session` or
the success path through `record` and `complete`. A journaled step is one whose return value
keiro writes to a durable journal after the body returns; if the process dies and the workflow
resumes, journaled steps are not re-executed — their recorded values are replayed. That property
is what this plan uses for pinning, and it is also why the step's return value must be
serialisable and must never be renamed once shipped.

`AgentRunDeps` at `shikigami-core/src/Shikigami/Agent/Workflow.hs:84` is the record of everything
a run needs: the application environment, the behavior environment, the loaded agent
declarations, the four sink configurations, hooks, approval, and a deadline. This plan adds one
field to it.

**The provider seam.** `shikigami-core/src/Shikigami/Behavior/Provider.hs` turns a configured
`ProviderSelection` into a live `BehaviorEnv`. Read its module comment — it explains that the
stub is a real provider and that `newBehaviorEnvFor` cannot build an environment without
announcing which provider is active. `ProviderSelection` itself is declared in the typed
application configuration at `shikigami-core/src/Shikigami/App/Config.hs:173` and is resolved
through Settei, the configuration library this repository uses for every process.

Understand the distinction this plan must not blur. `ProviderSelection` is *process*
configuration: one answer for the whole worker, resolved at startup from environment variables
and YAML. A sanctioned execution profile is *run* configuration: immutable, versioned,
digest-addressed, resolved per run, and journaled. Folding the profile into `ProviderSelection`
would be the natural-looking mistake here and it would be wrong — a profile cannot be an
environment variable, because a run must be able to prove which exact policy revision it obeyed
months later.

**The database.** Schema changes go through one authority. `shikigami-migrations` holds
`sql-migrations/manifest` and the SQL files it lists; the operator contract is `DATABASE_URL`
plus `cabal run shikigami-migrate -- up`. Create a new migration with:

```bash
just new-migration name=sanctioned-execution-profiles
```

That recipe timestamps the filename and appends it to the manifest for you. Never hand-edit the
manifest ordering, never rename an existing migration file, and never create a second migration
runner.

One obligation comes with this component and it is easy to miss.
`Shikigami.Migrations.reconcileShikigamiReadModels` must run after a successful `up`, because the
Kioku library stopped registering read models on first query and its `registerReadModel` only
inserts. If you add a read model, confirm the reconciliation covers it. If you skip this, every
projection query against your new read model fails with `ReadModelUnregistered` in production
while passing in a freshly created test database — which is the worst possible failure shape,
because tests are green.

**The checked specification.**
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md` introduces
`domain/shikigami.keiro`, a checked declaration of this repository's durable contracts —
aggregates, workflows, timers, queues, inbox and outbox contracts, and read models — together
with an evolution gate that fails CI when a persisted contract or workflow shape changes without
passing through the specification. Plan 39 is a hard dependency of this plan precisely because
the `resolve-profile` step's journaled value is a new persisted contract. Adding the step by hand
and re-expressing it under the specification afterward is guaranteed rework; adding it through
the specification is not.

**Running things.** All commands run from `/Users/shinzui/Keikaku/bokuno/shikigami`:

```bash
nix develop -c cabal build all
nix develop -c cabal test all
nix fmt
```

Database-backed tests in this repository start an ephemeral Postgres and apply the migration plan
through the public test-support sublibrary, `shikigami-migrations:test-support` — read
`shikigami-migrations/test-support/Shikigami/Migrations/TestSupport.hs` and follow how
`shikigami-core/test/Shikigami/AgentWorkflowSpec.hs` uses it. Those tests can be slow and are
sensitive to parallelism; if you see an ephemeral-Postgres startup timeout, re-run the single
test with `--test-option -p` before assuming a real failure, and note it in Surprises &
Discoveries if it recurs.


## Plan of Work

### Milestone 1 — the profile store and fail-closed resolution

Create `shikigami-core/src/Shikigami/Attestation/Resolve.hs`. It holds one function and one error
type, and the error type is the milestone's substance.

`ProfileResolutionError` enumerates exactly five refusals, each carrying what an operator needs to
act: `UnknownProfile` with the id and version asked for; `ProfileExpired` with the id, the
version, and the expiry that has passed; `ProfileWithdrawn` with the id, version, and the
lifecycle state found; `AmbiguousProfile` with the id and the list of versions that matched; and
`MutableProfile` with the id, the version, the digest claimed, and the digest recomputed from
stored content. Do not add a catch-all constructor — a sixth failure mode should force a sixth
constructor and a decision, not fall into a bucket.

`resolveProfile` takes a profile reference — an id and optionally a version — and returns either a
`ProfileResolutionError` or a resolved pair of the profile content and its
`SanctionedExecutionProfileRef`. Resolution reads the stored profile, checks that exactly one
version matched, recomputes the digest over the stored content using the canonical encoding,
compares it to the stored digest, and checks the lifecycle against the current time. Order matters
for error-message quality: check existence, then ambiguity, then integrity, then lifecycle — so a
tampered expired profile reports tampering, which is the more urgent fact.

The digest computation needs a hash function, and
`docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md` deliberately left
hashing to `docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md`. This plan needs it
sooner. Add the hashing dependency here, and when you do, verify the released version against the
authoritative package registry and the upstream release tags rather than taking a version from a
local corpus — this repository's `AGENTS.md` requires that. Put the hash function next to the
canonical encoding it consumes, in `Shikigami.Attestation.Envelope`, and record in this plan's
Surprises & Discoveries that plan 52's Interfaces section should be updated to say the hash
arrived here instead.

Storage is a single table holding the profile id, version, issuer, lifecycle, validity window, the
canonical JSON of the content, and the digest, with a uniqueness constraint on
`(profile_id, version)` — which makes `AmbiguousProfile` unreachable through this table, so
document that the constructor exists for the resolution *path*, which will later also serve
profiles fetched by id alone with no version pinned.

Create the migration with `just new-migration name=sanctioned-execution-profiles`. Write the
table, then apply and check:

```bash
just migrate
just migrate-status
```

Tests go in a new `shikigami-core/test/Shikigami/ProfileResolutionSpec.hs`, database-backed.
Insert a good profile and resolve it. Then, one refusal per test: ask for an id that was never
inserted; insert one whose `validUntil` is in the past; insert one with lifecycle `Withdrawn`;
mutate the stored content JSON without updating the digest column and observe `MutableProfile`
reporting both digests. For ambiguity, exercise the resolution function directly with two matching
rows supplied by a seam rather than fighting the uniqueness constraint, and say in the test name
that this is what you are doing.

### Milestone 2 — resolve before the behavior, and stay pinned

Add the step to `shikigami-core/src/Shikigami/Agent/Workflow.hs`. Declare it through
`domain/shikigami.keiro` first, per plan 39, then implement.

Add a field to `AgentRunDeps` — a resolver function rather than a database handle, so tests can
supply a deterministic one without a database, matching how `approval` is already a function field
on that record. In `runResolvedAgent`, add `runStep deps (StepName "resolve-profile") ...`
immediately before the existing `open-session` step. The step returns the resolved
`SanctionedExecutionProfileRef` for an agent that requires a profile, and a value meaning "not
required" for one that does not. Model that as a `Maybe`, and be careful with the encoding: this
is a journaled value, so it follows the additive-only versioning discipline that
`docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md` establishes, and it
encodes with `omitNothingFields` so an agent that requires nothing journals nothing new.

When resolution fails, return `Left` from the workflow with a message naming the refusal, and do
not proceed to `open-session`. Note the existing convention you are joining: the workflow's result
type is `Either Text AgentRunResult`, and a journaled `Left` means a permanent failure while a
transient failure is expressed by throwing so the step re-runs on the next execution. A profile
refusal is permanent — retrying an expired profile will not make it valid — so `Left` is correct.
Do not change the workflow's result type; that decision is recorded in
`docs/masterplans/3-correctness-and-delivery-semantics-stop-dropping-and-duplicating-work.md` and
changing it would alter the JSON encoding of already-journaled completions.

Which profile an agent requires has to come from somewhere. Read the declaration record at
`shikigami-core/src/Shikigami/Agent/Decl.hs` and the Dhall schema at `schema/Agent.dhall`. Add an
optional profile requirement as an additive field with a default that preserves today's behavior
exactly, then prove byte-compatibility the way this repository proves it: run `validate` over
every existing manifest under `agents/` and observe them all still pass unchanged. Note that
`agents/broken.dhall` is a deliberate load-failure fixture and `agents/detectors/schema.dhall` is
a retired tombstone that is a record *type* rather than a manifest and has always failed
validation — two expected failures under `agents/`, not zero and not one. Treating either as a
regression is the trap here.

The pinning test is the milestone's acceptance.
`shikigami-core/test/Shikigami/AgentWorkflowSpec.hs` already contains a crash-and-resume test —
find the case about resuming without rerunning journaled step bodies and copy its structure.
Resolve a profile, let the run reach a point after `resolve-profile` and before completion,
abandon the workflow, mutate the stored profile row (bump its version and digest), resume, and
assert the resumed run reports the original digest. If it reports the new one, the step is not
journaled correctly and the pinning claim is false.

### Milestone 3 — the profile constrains dispatch

A pinned profile that nothing consults is decoration. This milestone makes a call outside the
allowed tuple set impossible to dispatch.

The behavior environment is built by `newBehaviorEnvFor` in
`shikigami-core/src/Shikigami/Behavior/Provider.hs`. Add a constrained construction path that
takes the resolved profile alongside the `ProviderSelection` and refuses, before any request is
built, to dispatch a call whose `(provider, API, model, thinking)` tuple is not in the profile's
allowed set — or whose dispatch would require a prohibition the profile withholds, such as a
defaulted thinking level or a model alias. The error names the offending tuple and the profile
digest it violated, because that message will end up in an audit record.

Two design notes. First, this is a pre-dispatch refusal, not a post-hoc check: the point is that
the call never reaches the provider. Second, the refusal is a *permanent* failure for the run in
the same sense as a profile refusal — a run asking for a forbidden model will ask again on
retry — so it flows to the same `Left` path rather than throwing.

Then prove the negative: an agent declared without a profile requirement must behave exactly as it
does today. The evidence is the existing suite passing unchanged, so run it in full and compare the
count against the recorded baseline.


## Concrete Steps

From `/Users/shinzui/Keikaku/bokuno/shikigami`, orient first:

```bash
cat docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md
sed -n 84,100p shikigami-core/src/Shikigami/Agent/Workflow.hs
sed -n 196,235p shikigami-core/src/Shikigami/Agent/Workflow.hs
sed -n 1,60p shikigami-core/src/Shikigami/Behavior/Provider.hs
cat shikigami-migrations/sql-migrations/manifest
```

Confirm plan 39 has landed before starting Milestone 2 — the specification file must exist:

```bash
ls domain/shikigami.keiro
```

If it does not exist, plan 39 is not done and this plan's Milestone 2 must wait. Milestone 1 is
independent of it and can proceed.

Per milestone, build, migrate, test, format:

```bash
nix develop -c cabal build shikigami-core
just migrate
just migrate-status
nix develop -c cabal test shikigami-core-test --test-option -p --test-option "profile"
nix fmt
```

A passing Milestone 1 run looks like this:

```text
shikigami
  profile resolution
    resolves an active profile to its digest:            OK
    unknown id is refused by id:                         OK
    expired profile is refused, naming the expiry:       OK
    withdrawn profile is refused, naming the lifecycle:  OK
    tampered content is refused as mutable:              OK
    ambiguous match is refused, listing versions:        OK

All 6 tests passed
```

Commit per milestone with all three trailers:

```text
feat(attestation): refuse a run whose profile will not resolve

Add Shikigami.Attestation.Resolve with five typed fail-closed refusals
and the sanctioned_execution_profiles migration.

MasterPlan: docs/masterplans/10-sanctioned-execution-attestation-for-agent-runs.md
ExecPlan: docs/plans/50-fail-closed-profile-resolution-and-run-pinning.md
Intention: intention_01kz96h79mezmbnwm67pdjjepr
```


## Validation and Acceptance

Full suite, every time:

```bash
nix develop -c cabal test all
```

The baseline as of 2026-07-31 was 157 tests across seven suites. Your run reports that plus what
you added, with no failures and no skips.

Acceptance, phrased as things a person can watch happen:

Point a run at a profile id that does not exist. The run returns a failure naming the id, and a
`SELECT` against the memory-session table shows no session was opened for it. Nothing was sent to
a provider; nothing was enqueued to the sink outbox.

Repeat with an expired profile, a withdrawn profile, and a profile whose stored content has been
edited without updating its digest. Each refusal names its own reason, and the tampered one reports
both the claimed and the recomputed digest.

Resolve a valid profile, start a run, kill it after `resolve-profile` has journaled, change the
stored profile row, and resume. The resumed run reports the *original* digest. This is the test
that makes "an in-flight run remains pinned to the resolved digest" a fact rather than a wish.

Declare an agent whose profile forbids a model, and ask its behavior to use that model. The run
fails before the provider is contacted, and the message names the offending tuple and the profile
digest. Confirm nothing reached the provider — with the stub provider active, the absence of the
stub's announcement line and the absence of any recorded learning are both observable.

Finally, run `validate` over the whole `agents/` tree and confirm exactly the two known failures
(`agents/broken.dhall` and `agents/detectors/schema.dhall`) and no others, proving the new
declaration field broke no existing manifest.


## Idempotence and Recovery

`resolveProfile` is a pure read plus a hash; calling it repeatedly is free and has no effect. The
journaled step is idempotent by construction — that is what journaling means here: a resumed
workflow replays the recorded digest rather than resolving again.

The migration is additive: it creates one table and adds no column to an existing one. Applying it
twice is a no-op because `shikigami-migrate` tracks what it has applied. Rolling the code back
while leaving the table in place is harmless — an unused table costs nothing. If you need to back
out mid-milestone, remove the new migration file *and* its manifest line together; a manifest
entry with no file, or a file with no entry, will fail the plan's completeness check, which is the
intended behavior.

The declaration field is optional with a behavior-preserving default, so a manifest written before
this plan stays valid and a rollback does not invalidate manifests written after it.

The one thing to be careful with: never rename the `resolve-profile` step. Journaled step names
are permanent identifiers. A rename makes every in-flight workflow unable to find its own journal
entry.


## Interfaces and Dependencies

Hard dependencies: `docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md` for
the vocabulary, and
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md` for the checked
specification the new journaled step must be declared through. Milestone 1 does not need plan 39;
Milestones 2 and 3 do.

Landed work this plan builds on, all Complete:
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md` (package
layout), `docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md` (configuration),
`docs/plans/47-upgrade-shikigami-to-the-coherent-july-2026-dependency-cohort.md` (the released
library cohort and the pg-migrate component), and
`docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md` (the provider seam this plan
constrains).

Libraries: `hasql` and `hasql-transaction` for the profile table, both already in
`shikigami-core/shikigami-core.cabal`; `keiro` for the journaled step, already there; and one new
hashing dependency, whose released version must be verified against the authoritative registry and
upstream tags before bounds are chosen.

Signatures that must exist at the end:

```haskell
-- shikigami-core/src/Shikigami/Attestation/Resolve.hs
data ProfileResolutionError
  = UnknownProfile !ProfileId !(Maybe ProfileVersion)
  | ProfileExpired !ProfileId !ProfileVersion !UTCTime
  | ProfileWithdrawn !ProfileId !ProfileVersion !ProfileLifecycle
  | AmbiguousProfile !ProfileId ![ProfileVersion]
  | MutableProfile !ProfileId !ProfileVersion !ProfileDigest !ProfileDigest

data ResolvedProfile = ResolvedProfile
  { profile :: !SanctionedExecutionProfile,
    ref :: !SanctionedExecutionProfileRef
  }

resolveProfile ::
  ProfileStore ->
  UTCTime ->
  ProfileId ->
  Maybe ProfileVersion ->
  IO (Either ProfileResolutionError ResolvedProfile)

-- shikigami-core/src/Shikigami/Attestation/Envelope.hs (extended by this plan)
profileDigest :: SanctionedExecutionProfile -> ProfileDigest

-- shikigami-core/src/Shikigami/Agent/Workflow.hs (extended)
data AgentRunDeps = AgentRunDeps
  { -- ... existing fields unchanged ...
    resolveRunProfile ::
      !(ProfileId -> Maybe ProfileVersion -> IO (Either ProfileResolutionError ResolvedProfile))
  }

-- shikigami-core/src/Shikigami/Behavior/Provider.hs (extended)
newBehaviorEnvForProfile ::
  ResolvedProfile -> ProviderSelection -> Maybe TraceSink -> IO (Either ProfileViolation BehaviorEnv)
```

The journaled step is `StepName "resolve-profile"`, returning `Maybe SanctionedExecutionProfileRef`,
encoded with `omitNothingFields`. That name and that encoding are permanent; changes to the value
are additive only.
