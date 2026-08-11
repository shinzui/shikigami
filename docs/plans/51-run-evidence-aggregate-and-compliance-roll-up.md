---
id: 51
slug: run-evidence-aggregate-and-compliance-roll-up
title: "Run-evidence aggregate and compliance roll-up"
kind: exec-plan
created_at: 2026-08-05T14:53:02Z
intention: "intention_01kz96h79mezmbnwm67pdjjepr"
master_plan: "docs/masterplans/10-sanctioned-execution-attestation-for-agent-runs.md"
---

# Run-evidence aggregate and compliance roll-up

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

By the time this plan starts, a run can be bound to an immutable policy: a sanctioned execution
profile is resolved to a digest before the behavior executes, journaled, and enforced at the
provider seam. What is still missing is the record of what actually happened, and the judgement
of whether it conformed.

After this plan, every agent run that requires a profile accumulates a durable evidence record.
Each provider call the run makes — the first call, a retry after a transient error, a fallback to
a different model, a call made by a tool, a call made by a delegated child agent — appears in
that record exactly once. When the behavior and every relevant child run have reached a terminal
state, the record seals, and a compliance roll-up says whether the run was sanctioned. Crucially,
when it was not, the roll-up says *every* way in which it was not, rather than collapsing to a
boolean: a run that used a forbidden model and also lost a child's evidence reports both facts,
because an auditor needs to know both.

You can see this working without a real provider. Three fixtures demonstrate the accounting
invariant: a program that makes two calls produces one roll-up listing two calls; a call that
fails transiently and is retried produces one roll-up listing the original and the retry, linked;
and a run that delegates to a child agent produces one roll-up that includes the child's call and
refuses to seal while the child is still running. And you can query it: given a run id,
`SELECT status, verdict FROM ...` tells you which phase the evidence reached and what the verdict
was.

Two things this plan deliberately does not do. It does not sign anything and it does not serve
anything — `docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md` owns the signature,
the read API, and the offline verifier. And it does not capture per-call observations inside a
provider adapter; that is upstream work in the baikai library.

**That upstream work has landed. Do not define `ModelCallEvidence` in this repository.**
`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-3` was `proposed` when this plan was
written on 2026-08-05; `baikai 0.5.0.0` shipped it on the same day as the module
`Baikai.Evidence`. The seam described below is still the right structure — production satisfies
it with a live source, tests with fixtures — but the *type* crossing that seam is now baikai's,
not shikigami's. See Surprises & Discoveries for what `Baikai.Evidence` provides and for the one
remaining obstacle, which is a bound rather than a missing contract.


## Progress

- [ ] M1: the run-evidence aggregate and its lifecycle, declared through the checked
      specification: requested, profile-resolved, running, evidence-sealed, attested, plus the
      non-conforming, incomplete, and failed terminal states.
- [ ] M1: illegal transitions are rejected — a run cannot seal from `requested`, and an
      `attested` record cannot be reopened.
- [ ] M2: `Baikai.Evidence.ModelCallEvidence` collected through a deterministic seam, with a
      fixture source in tests. **Import the type from baikai; do not define a local one.**
- [ ] M2 (gate): `baikai 0.5.0.0` is in the cohort. Blocked as of 2026-08-10 by
      `kioku-core 0.3.0.0`'s `baikai ^>=0.4.1.0` — see Surprises & Discoveries. Until it clears,
      M1, M3, M4, and M5 proceed unchanged and M2 uses fixtures shaped to baikai's published
      record rather than to an invented one.
- [ ] M2: every call opts in by setting `Options.evidence` to an `EvidenceRequest` carrying the
      run identifier, retry provenance, and required `EvidenceStrength`. A call that does not opt
      in behaves exactly as before, so this is additive to plan 13's provider path.
- [ ] M2: every call receives the run id and a unique call id, taken from the correlation
      vocabulary rather than minted here.
- [ ] M3: complete accounting — the two-call, retry, and delegated-child fixtures each produce one
      roll-up accounting for every call exactly once.
- [ ] M3: sealing waits for every relevant child; a run with a pending child stays `running` and
      reports why.
- [ ] M4: the compliance roll-up: all non-conforming reasons enumerated, deterministic steps
      recorded as not-applicable, mixed-model runs listing each call.
- [ ] M4: mutation tests — one fixture per reason in the taxonomy, each producing exactly that
      reason.
- [ ] M5: pg-migrate-managed evidence tables; read models reconciled; state queryable by run id.


## Surprises & Discoveries

**Baikai IR-3 landed the same day this plan was written, and nobody noticed for five days
(discovered 2026-08-10).** `baikai 0.5.0.0`, released 2026-08-05, adds the exposed module
`Baikai.Evidence` — "the vocabulary for verifiable model-call evidence — a record of what actually
crossed the boundary to a provider, as opposed to what the process was configured to ask for".
That sentence is this plan's Milestone 2 restated by its author.

What it provides, and what each thing replaces here:

`ModelCallEvidence` itself, with `evidenceSchemaVersion` as the string consumers pin against.
This replaces the local record sketched in Interfaces and Dependencies. `Observed` is a
deliberate non-`Maybe` for a value the provider either did or did not report, with no function
that supplies a default — which is a stricter and better answer than a `Maybe` field for the
plan's "the transport used could not report this" case. `ThinkingTranslation`, with `ThinkingMode`
and `ThinkingAdjustment`, describes what a requested reasoning-effort level actually became on the
wire and every clamp, collapse, or drop applied on the way; the non-conformance taxonomy in
Milestone 4 should be built on that rather than on a locally invented notion of "the provider did
something other than what we asked". `EndpointIdentity`, `TransportKind`, `CallStatus`, and the
ascending `EvidenceStrength` scale round it out — `EvidenceStrength` in particular is what lets a
roll-up say *how well* a call is evidenced instead of only whether a record exists.

`Options` gains an `evidence` field carrying an optional `EvidenceRequest` with the caller's run
identifier, retry provenance, and required strictness. A call whose `evidence` is `Nothing` — that
is, every call that does not opt in — behaves exactly as it did before. So wiring this into
shikigami's provider path is additive and cannot regress plan 13's behavior.

Baikai's changelog is explicit that "nothing constructs a `ModelCallEvidence` from a real call
yet". The vocabulary and the opt-in field exist; the provider-side population does not. That is
the correct reading of the seam's status: the *type* is settled and must be adopted, the *live
source* is still pending, and the fixture source in tests remains the right way to prove
Milestones 3 and 4.

**The remaining obstacle is a bound, not a missing contract.** `kioku-core 0.3.0.0` declares
`baikai ^>=0.4.1.0`, which caps below 0.5, so the cohort cannot take `baikai 0.5.0.0` today. The
release that lifts it is a kioku version admitting `baikai ^>=0.5`, requested by
`docs/plans/53-upgrade-shikigami-to-the-keiro-0-11-and-keiki-0-9-cohort.md`. This blocks Milestone
2 only. Milestones 1, 3, 4, and 5 — the aggregate lifecycle, complete accounting, the
non-conformance taxonomy, and the tables — never needed a real provider observation and still do
not.

**Also relevant to Milestone 4, and to plan 52.** `Baikai.Evidence` ships the canonical hashing
core: `canonicalEncode` gives a JSON value exactly one byte representation, `commitmentDigest`
hashes a full request envelope, and `configurationDigest` hashes an allow-list projection
(`configurationProjection`) that keeps configuration and replaces content with structural
summaries. The two digests are separate on purpose: the first binds a record to a particular
request, the second is safe to compare across runs that legitimately differ in content. That
distinction is directly useful here — a compliance roll-up comparing "did these calls ask the same
way" wants `configurationDigest`, not a content hash — and it is the reason plan 52 no longer
needs to author its own encoder.


## Decision Log

- Decision: Build against a deterministic evidence seam with stub fixtures rather than waiting for
  baikai IR-3.
  Rationale: the aggregate lifecycle, the complete-accounting invariant across retries and
  delegated children, and the non-conformance taxonomy are all provable without a single real
  provider observation. This is the same technique
  `docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md` uses for its own
  pending upstream adapter — a reader record with function fields, satisfied by a stub in tests and
  a live client in production. It keeps a `proposed` upstream request off the critical path of
  three milestones.
  Date: 2026-08-05

- Decision: Keep the seam, but import `ModelCallEvidence` and its companions from
  `Baikai.Evidence` instead of defining them here.
  Rationale: baikai IR-3 landed as `baikai 0.5.0.0` on 2026-08-05, the same day this plan was
  written. The seam was always the right structure and stays; what changes is that the type
  crossing it is now published upstream. Defining a local lookalike would mean two vocabularies
  for one concept, a translation layer between them, and — worst — a shikigami-owned record that
  silently disagrees with what the provider adapter will eventually populate. Baikai's version is
  also better than the sketch it replaces: `Observed` is a deliberate non-`Maybe` with no
  defaulting function, `ThinkingTranslation` records what a requested reasoning effort actually
  became on the wire including every clamp and drop, and `EvidenceStrength` is an ascending scale
  rather than a boolean. Milestone 4's non-conformance taxonomy should be expressed against those
  rather than against locally invented equivalents.
  Date: 2026-08-10

- Decision: Do not treat the missing live evidence source as a reason to delay Milestones 1, 3, 4,
  or 5, and do not treat the `baikai ^>=0.4.1.0` cap as a reason to delay Milestone 2's design.
  Rationale: baikai's changelog states plainly that "nothing constructs a `ModelCallEvidence` from
  a real call yet" — the vocabulary and the `Options.evidence` opt-in exist, the provider-side
  population does not. So the fixture source remains the way to prove complete accounting and the
  non-conformance taxonomy, exactly as before. Separately, `kioku-core 0.3.0.0` caps `baikai`
  below 0.5, so the cohort cannot take the module yet. Neither fact changes what this plan should
  build; both change only when the import can be written. Shape the fixtures to baikai's published
  record now so that adopting it later is an import change rather than a redesign.
  Date: 2026-08-10

- Decision: A deterministic step records `NotApplicable`, never a synthesised model call.
  Rationale: the request is explicit that deterministic steps are not-applicable rather than
  fabricated calls. A fabricated call would corrupt the one property the whole record exists to
  guarantee — that every model call is accounted for exactly once — by making the count
  unverifiable.
  Date: 2026-08-05

- Decision: The roll-up records a list of reasons, not a boolean, and there is no
  "generally non-conforming" catch-all.
  Rationale: the request requires every non-conforming reason to be recorded rather than reducing
  partial evidence to a boolean, and the consuming gate needs to distinguish "wrong model" from
  "missing child" to give a useful message. A catch-all constructor would let a future
  contributor avoid extending the taxonomy, which defeats it.
  Date: 2026-08-05

- Decision: Correlation identifiers come from the structured-logging plan, not from here.
  Rationale: `docs/plans/28-structured-logging-metrics-and-trace-propagation.md` Milestone 1 owns
  the run and call correlation vocabulary for logs and traces. Minting a second scheme here would
  mean an audit record and a log line about the same call could not be joined, which is precisely
  what an operator will need to do when a verdict is disputed.
  Date: 2026-08-05


## Context and Orientation

You need this file, the working tree, and two checked-in plans:
`docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md` (the vocabulary) and
`docs/plans/50-fail-closed-profile-resolution-and-run-pinning.md` (the resolution and pinning this
plan builds on). Read both.

**What a run is, concretely.** An agent is a Dhall manifest under `agents/`. A run of one is a
durable workflow in `shikigami-core/src/Shikigami/Agent/Workflow.hs`, executed as a sequence of
*journaled steps* — `ingest-job`, `lookup-agent`, `resolve-profile` (added by plan 50),
`open-session`, `recall`, `run-behavior`, then `record` and `complete`, or `fail-session`. A
journaled step's return value is written to a durable journal after the body returns, so a
resumed workflow replays recorded values instead of re-executing. Journaled step names are
permanent identifiers and are never renamed.

**How a behavior makes model calls.** `shikigami-core/src/Shikigami/Behavior/Run.hs` runs a
behavior in a `BehaviorEnv`. A behavior is either a *skill* — a prompt-shaped call through the
`baikai` library — or a *program*, a typed multi-step computation from the `shikumi` library. The
difference matters here: a skill makes one call, while a program can make several, and the
accounting invariant has to hold for both. Read
`shikigami-core/src/Shikigami/Behavior/Skill.hs` for the skill arm and
`shikigami-core/src/Shikigami/Program/Registry.hs` for the program arm.

**Delegation, which already exists.** An agent can spawn a child agent run as a child workflow.
The primitive is `shikigami-core/src/Shikigami/Agent/Delegate.hs`, with a maximum depth of four,
and the lineage travels on the run job: `shikigami-core/src/Shikigami/Agent/RunJob.hs` carries
`parentSessionId`, `parentRunWorkflowId`, and `delegationDepth`, plus a `TriggeredByDelegation`
trigger kind. Those three fields are how this plan finds a run's children — do not invent a
parallel lineage mechanism, and note that
`docs/plans/35-delegation-as-a-first-class-declared-capability.md` will later make delegation
declarative and must not break them.

**The seam technique, which this plan depends on.** When a plan in this repository needs a
capability an upstream library has not shipped, the pattern is a record of function fields — a
"reader" — that production satisfies with a live client and tests satisfy with a stub. You can see
the shape in `docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md`, whose
`EvidenceReader` has fields like `resolveRef` and `readDiff`. This plan uses the same shape for
`ModelCallEvidence`: an `EvidenceSource` record whose one job is to hand over terminal call
observations, satisfied in tests by a stub returning fixtures.

**What the upstream will eventually supply.** Resolve the baikai repository path with
`mori path mori://shinzui/baikai` and read
`docs/improvement-requests/capture-verifiable-model-call-evidence.md`. Its "Requested contract"
section lists what one `ModelCallEvidence` must preserve, and three points from it shape this
plan's types. Requested, effective, and observed values are *separate fields* — a provider that
does not echo the model records `unobserved` rather than copying the request into an "observed"
field. Retry and fallback are relationships between call records, not flags. And a caller can
demand a minimum evidence strength, so a transport that cannot supply required correlation fields
is refused rather than silently accepted. `EvidenceStrength` is defined by plan 49.

**The database.** One authority. `shikigami-migrations` holds `sql-migrations/manifest`; create a
migration with `just new-migration name=<slug>`, apply with `just migrate`, inspect with
`just migrate-status`. Never rename an existing migration file, never hand-edit manifest ordering,
never add a second runner. And the obligation that is easy to miss:
`Shikigami.Migrations.reconcileShikigamiReadModels` must run after a successful `up`, because the
Kioku library stopped registering read models on first query and its `registerReadModel` only
inserts. If this plan adds a read model — and Milestone 5 does — confirm the reconciliation covers
it, or every projection query fails `ReadModelUnregistered` in production while passing in a
freshly created test database.

**The checked specification.** `domain/shikigami.keiro`, introduced by
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md`, declares this
repository's durable contracts and gates changes to them in CI. The run-evidence aggregate is a
durable state machine and therefore belongs in that specification. Declaring it there first and
generating from it is the difference between this plan landing once and landing twice.

**Commands.** From `/Users/shinzui/Keikaku/bokuno/shikigami`:

```bash
nix develop -c cabal build all
nix develop -c cabal test all
nix fmt
```

Database-backed tests use the public `shikigami-migrations:test-support` sublibrary; see
`shikigami-migrations/test-support/Shikigami/Migrations/TestSupport.hs` and how
`shikigami-core/test/Shikigami/AgentWorkflowSpec.hs` uses it. These are slow and parallelism-
sensitive; on an ephemeral-Postgres startup timeout, re-run the single test with `--test-option -p`
before assuming a real failure.


## Plan of Work

Five milestones. The first four are provable with no database beyond the test harness and no
provider at all; the fifth makes the state durable and queryable.

### Milestone 1 — the aggregate and its lifecycle

Declare the run-evidence aggregate in `domain/shikigami.keiro` first, then implement it in
`shikigami-core/src/Shikigami/Attestation/Evidence.hs`.

The lifecycle is a state machine with five ordinary phases and three terminal failures:

```text
requested -> profile-resolved -> running -> evidence-sealed -> attested
                                    \-> non-conforming
                                    \-> incomplete
                                    \-> failed
```

Model the phase as a sum type and the transitions as a function that rejects anything not on that
diagram, returning a typed error naming the attempted transition. The rejections are the
milestone's substance, so be specific about which ones matter: a run cannot seal from `requested`
because there is nothing to seal; a run cannot reach `attested` except from `evidence-sealed`,
because signing an unsealed roll-up would sign an incomplete set; and an `attested` record cannot
be reopened at all, because a second successful review must not be manufacturable from an existing
attestation. That last one is invariant 8 of the shared upstream contract and it is worth a test of
its own.

Binding happens at `profile-resolved`. That is the phase where the record acquires everything it
will be judged against: the logical agent and its immutable version, the declaration and behavior
and grounding and tool-catalog digests, the reviewed artifact with its repository identity and full
base and head commits and diff digest, the profile digest, and the review-request id with its
idempotency key. All of those types come from plan 49 — `AgentVersionRef`, `AgentArtifactSet`,
`ReviewedArtifact`, `SanctionedExecutionProfileRef`. Do not redefine them. The review-request id is
an opaque typed value supplied by the caller until
`docs/plans/14-approval-and-human-in-the-loop-end-to-end.md` lands and defines it properly; write a
haddock note saying so.

Tests in a new `shikigami-core/test/Shikigami/RunEvidenceSpec.hs`: every legal transition succeeds,
and each of the three illegal ones named above fails with its own error.

### Milestone 2 — collecting call evidence behind a seam

Define `EvidenceSource` as a record of function fields in the same module. Its job is narrow: hand
over terminal `ModelCallEvidence` records for a run, and report whether the transport used could
meet a required minimum evidence strength.

Then wire collection into the run. Every call the run makes must carry the Shikigami run id and a
unique call id — and those identifiers must come from
`docs/plans/28-structured-logging-metrics-and-trace-propagation.md` Milestone 1, which owns the
correlation vocabulary, rather than being minted here. If you find yourself writing a UUID
generator in this plan, stop and go read plan 28's identifiers instead; two correlation schemes
would mean a disputed verdict cannot be joined to the logs of the call that caused it.

The stub source lives in the test tree and returns fixtures. Write three fixtures now, because
Milestone 3 needs them: a two-call program, a call plus its retry, and a parent call plus a
delegated child's call. Store them as literal JSON in the test module, following the convention
documented at the top of `shikigami-core/test/Shikigami/WireCompatSpec.hs` — a fixture built by
calling the current encoder proves nothing about the encoder.

Record in Surprises & Discoveries the date you checked baikai IR-3's status and what it was, so a
later reader knows how stale the stub is.

### Milestone 3 — complete accounting

This milestone establishes the invariant the whole record exists for: every relevant call appears
exactly once.

"Exactly once" needs care in three directions. A retry is a *second* call with a relationship to
the first, not an amendment of the first — both appear, linked. A fallback is likewise a second
call, and if the profile prohibits fallback then its mere presence is a non-conforming reason,
which Milestone 4 reports. A delegated child's calls belong to the parent's closure: the parent
cannot seal while a child is non-terminal, and it must be able to say which child it is waiting
for. Use the lineage already on the run job — `parentRunWorkflowId` and `parentSessionId` from
`shikigami-core/src/Shikigami/Agent/RunJob.hs` — to find children.

Sealing is therefore a guarded transition, not a timer. Write it as a function that takes the
behavior's terminal state and the set of child states and either seals or returns the reason it
cannot, naming the pending child. Test both branches with the delegated-child fixture: seal
refused while the child runs, seal accepted once it is terminal.

Each of the three fixtures produces exactly one roll-up, and the roll-up's call count equals the
fixture's call count. Assert the count, and also assert the identity of each call — a test that
only counts would pass if two calls were recorded as the same call twice.

### Milestone 4 — the compliance roll-up

Now judge. Take the sealed evidence and the pinned profile, and produce a roll-up carrying a
sanctioned verdict plus the list of `NonConformingReason` values from plan 49 that apply.

Three rules the implementation must follow, all from the request and all easy to get wrong.
Compliance is evaluated against *resolved and effective* values, never the requested alias — a run
that asked for a friendly model name and got something else is judged on what it got. A
deterministic step records `NotApplicable`, never a synthesised model call. And a run that legally
used several permitted models is a *mixed-model run*: it stays sanctioned and lists each call,
rather than being flagged for inconsistency.

The verdict is not a boolean with a reason attached; it is a verdict plus a complete list. A run
that used a forbidden model *and* lost a child's evidence reports both reasons. Write the test that
proves this — a fixture violating two rules yields two reasons — because it is the assertion that
stops someone later short-circuiting the evaluation on the first failure.

Then write one mutation fixture per reason in the taxonomy: wrong model, prohibited thinking
translation, prohibited default, alias drift, undeclared fallback, forbidden transport, missing
call, missing retry, missing delegated child, artifact digest mismatch, result digest mismatch, and
evidence below the required strength. Each yields exactly that reason and no others. This suite is
what `docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md` builds its end-to-end
conformance case on, so name the fixtures clearly enough to be reused.

### Milestone 5 — durable and queryable

Make it persist. Create the migration with
`just new-migration name=run-evidence-and-call-records`, and design for the query an operator will
actually run: given a run id, what phase did the evidence reach, what was the verdict, and which
reasons applied. Two tables — one per run, one per call, the call table keyed by run id and call id
with the retry and parent relationships as columns — plus whatever index that query needs.

Apply and check:

```bash
just migrate
just migrate-status
```

If you add a Kioku read model for the operator query, confirm
`Shikigami.Migrations.reconcileShikigamiReadModels` covers it before you finish the milestone. A
test against a freshly created database will not catch its absence, so check the reconciliation
function's source directly.

Then prove durability the way this repository proves it: run to sealing, restart, and query. The
phase, verdict, reasons, and every call record are still there.


## Concrete Steps

From `/Users/shinzui/Keikaku/bokuno/shikigami`, orient:

```bash
cat docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md
cat docs/plans/50-fail-closed-profile-resolution-and-run-pinning.md
cat shikigami-core/src/Shikigami/Agent/RunJob.hs
sed -n 1,60p shikigami-core/src/Shikigami/Agent/Delegate.hs
sed -n 1,45p shikigami-core/test/Shikigami/WireCompatSpec.hs
mori path mori://shinzui/baikai
```

Confirm the hard dependencies have landed before starting:

```bash
ls domain/shikigami.keiro                                  # plan 39
ls shikigami-core/src/Shikigami/Log.hs                     # plan 28 M1
grep -rn "resolve-profile" shikigami-core/src              # plan 50
grep -c . shikigami-migrations/sql-migrations/manifest     # plan 38's cutover
```

If `domain/shikigami.keiro` or `Shikigami/Log.hs` is missing, this plan is not startable yet — say
so in Progress and stop rather than working around it, because both workarounds are exactly the
rework this decomposition exists to avoid.

Per milestone:

```bash
nix develop -c cabal build shikigami-core
nix develop -c cabal test shikigami-core-test --test-option -p --test-option "evidence"
nix fmt
```

A passing Milestone 3 run looks like this:

```text
shikigami
  run evidence
    two-call program: one roll-up, two distinct calls:        OK
    retry: original and retry both present, linked:           OK
    delegated child: parent will not seal while child runs:    OK
    delegated child: seals once child is terminal:             OK
    child's call appears in the parent's closure exactly once:  OK

All 5 tests passed
```

Commit per milestone with all three trailers:

```text
feat(attestation): account for every model call exactly once

Add complete-accounting closure over retries, fallbacks, and delegated
children, with the three fixtures that prove it.

MasterPlan: docs/masterplans/10-sanctioned-execution-attestation-for-agent-runs.md
ExecPlan: docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md
Intention: intention_01kz96h79mezmbnwm67pdjjepr
```


## Validation and Acceptance

Full suite:

```bash
nix develop -c cabal test all
```

The baseline as of 2026-07-31 was 157 tests across seven suites; expect that plus yours, with no
failures.

Acceptance, as observable behavior:

Run the two-call program fixture. One evidence record exists for the run, in phase
`evidence-sealed`, listing exactly two calls with distinct call ids. Query it by run id and read
the phase and verdict out of the database.

Run the retry fixture. The record lists two calls, the second marked as a retry of the first. The
transient failure is still in the evidence — it is not erased by the successful retry — because an
auditor needs to see that the run had trouble.

Run the delegated-child fixture and hold the child open. The parent's record stays in `running` and
reports which child it is waiting for. Let the child finish; the parent seals, and the child's call
appears in the parent's closure exactly once.

Present a fixture whose call used a model the profile does not permit. The verdict is not
sanctioned and the reasons name the model and the profile digest. Present one that violates two
rules at once; both reasons appear.

Present a run whose behavior made no model call at all — a deterministic step. The record says
not-applicable, and the call list is empty rather than containing a fabricated entry.

Present a run that used two different permitted models. It is sanctioned, and both calls are
listed.

Finally, restart the process and re-query every one of the above by run id. Everything is still
there, with the same verdicts.


## Idempotence and Recovery

Evidence collection is append-only and keyed by run id plus call id, so replaying a call record is
an upsert that converges rather than a duplicate. That is what makes the "exactly once" invariant
survive a crash-and-resume: the second recording of the same call id is the same row.

The lifecycle is monotonic and its terminal states are final. Re-running a seal on an already
sealed record is a no-op; attempting to reopen an `attested` record fails, by design, and that
failure is a test.

Migrations are additive — two new tables, no column added to an existing one — and applying twice
is a no-op because `shikigami-migrate` tracks what it applied. Rolling code back while leaving the
tables in place is harmless. To back out mid-milestone, remove the migration file and its manifest
line together; one without the other fails the plan's completeness check, which is intended.

The stub `EvidenceSource` is test-only. When baikai IR-3 lands, the live source replaces the stub
behind the same record, and the fixtures stay as regression tests. Do not delete the fixtures at
that point — they are the only thing that will tell you the live source changed shape.


## Interfaces and Dependencies

Hard dependencies: `docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md`
(vocabulary), `docs/plans/50-fail-closed-profile-resolution-and-run-pinning.md` (a pinned profile
to judge against), `docs/plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md`
(the one schema authority), `docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md`
(the aggregate must be declared through the checked specification), and Milestone 1 of
`docs/plans/28-structured-logging-metrics-and-trace-propagation.md` (the run and call correlation
identifiers).

Upstream: `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-3` was `proposed` as of
2026-08-05 and **delivered on 2026-08-05** as `Baikai.Evidence` in `baikai 0.5.0.0`. Import
`ModelCallEvidence`, `evidenceSchemaVersion`, `Observed`, `ThinkingTranslation` (with
`ThinkingMode` and `ThinkingAdjustment`), `EndpointIdentity`, `TransportKind`, `CallStatus`, and
`EvidenceStrength` from there. `Options` gains an `evidence :: Maybe EvidenceRequest` field
carrying the run identifier, retry provenance, and required strictness; a call that leaves it
`Nothing` behaves exactly as before, so adopting this cannot regress plan 13's provider path.

Remaining gate, and it is a bound rather than a contract: `kioku-core 0.3.0.0` declares
`baikai ^>=0.4.1.0`, which excludes 0.5, so the cohort cannot take the module yet. A kioku release
admitting `baikai ^>=0.5` lifts it, and
`docs/plans/53-upgrade-shikigami-to-the-keiro-0-11-and-keiki-0-9-cohort.md` owns requesting it.
This blocks Milestone 2's import only. Note also that baikai's changelog states nothing
constructs a `ModelCallEvidence` from a real call yet, so the live source is still pending even
after the bound clears — the fixture source remains how Milestones 3 and 4 are proven.

Coordination, not blocking: `docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md`
sets the additive-only discipline every journaled or persisted value here follows, and
`docs/plans/35-delegation-as-a-first-class-declared-capability.md` must preserve the run-job
lineage fields this plan reads.

Libraries: `hasql` and `hasql-transaction` for the tables and `keiro` for the aggregate, all
already in `shikigami-core/shikigami-core.cabal`. If any new dependency is needed, verify its
released version against the authoritative package registry and upstream release tags before
choosing bounds, per this repository's `AGENTS.md`.

Signatures that must exist at the end:

```haskell
-- shikigami-core/src/Shikigami/Attestation/Evidence.hs
data EvidencePhase
  = Requested
  | ProfileResolved
  | Running
  | EvidenceSealed
  | Attested
  | NonConforming
  | Incomplete
  | Failed

data TransitionError = IllegalTransition !EvidencePhase !EvidencePhase

newtype CallId = CallId {value :: Text}
data CallRelationship = RootCall | RetryOf !CallId | FallbackFrom !CallId | ChildOf !CallId

-- ModelCallEvidence is NOT defined here. Import it, and the vocabulary around it, from
-- Baikai.Evidence (baikai 0.5.0.0):
--
--   import Baikai.Evidence
--     ( ModelCallEvidence (..), evidenceSchemaVersion, Observed (..)
--     , ThinkingTranslation (..), ThinkingMode (..), ThinkingAdjustment (..)
--     , EndpointIdentity (..), TransportKind (..), CallStatus (..), EvidenceStrength (..)
--     )
--
-- The earlier draft of this plan sketched a local record with a `Maybe Text` observed model and
-- a comment promising "plus provider, API, endpoint, thinking translation, ...". Baikai ships
-- all of that, and answers the Maybe question better: `Observed` is a deliberate non-Maybe for a
-- value the provider either did or did not report, with no function that supplies a default, so
-- an unobserved model cannot silently become a copy of the requested one.
--
-- What this repository still owns is the correlation of calls to a run, which baikai has no
-- opinion about:

data EvidenceSource = EvidenceSource
  { terminalCallsFor :: !(Text -> IO [ModelCallEvidence]),
    meetsMinimumStrength :: !(EvidenceStrength -> IO Bool)
  }

data RunEvidence = RunEvidence
  { phase :: !EvidencePhase,
    agentVersion :: !AgentVersionRef,
    artifacts :: !AgentArtifactSet,
    reviewed :: !ReviewedArtifact,
    profile :: !SanctionedExecutionProfileRef,
    reviewRequestId :: !Text,
    idempotencyKey :: !Text,
    calls :: ![ModelCallEvidence]
  }

data SealRefusal = PendingChild !Text | BehaviorNotTerminal
sealEvidence :: RunEvidence -> [EvidencePhase] -> Either SealRefusal RunEvidence

data ComplianceRollUp = ComplianceRollUp
  { sanctioned :: !Bool,
    reasons :: ![NonConformingReason],
    accountedCalls :: ![CallId]
  }
evaluateCompliance :: SanctionedExecutionProfile -> RunEvidence -> ComplianceRollUp
```

`AgentVersionRef`, `AgentArtifactSet`, `ReviewedArtifact`, `SanctionedExecutionProfileRef`, and
`NonConformingReason` all come from plan 49 and are imported, never redefined. `runId` and
`CallId` values come from plan 28's correlation vocabulary. `ModelCallEvidence` and
`EvidenceStrength` come from `Baikai.Evidence` — note that `EvidenceStrength` moved out of plan
49's ownership when baikai published it, and plan 49 records that it now cites rather than
defines it.

Milestone 4's non-conformance taxonomy should be expressed against baikai's vocabulary wherever
one fits, rather than against locally invented equivalents. In particular, a run whose requested
reasoning effort was clamped, collapsed, or dropped on the wire is described exactly by
`ThinkingTranslation`'s `ThinkingAdjustment`, and "how well is this call evidenced" is
`EvidenceStrength` rather than a boolean. Reasons that have no baikai counterpart — a missing
delegated child, an artifact digest mismatch, a call that no roll-up accounted for — stay
shikigami's own.


## Revision Notes

- 2026-08-10: Adopted `Baikai.Evidence` instead of defining a local evidence vocabulary.

  Baikai IR-3 was recorded here as `proposed` and worked around with a stub seam. It was in fact
  delivered on the same day this plan was written, 2026-08-05, as the `Baikai.Evidence` module in
  `baikai 0.5.0.0`, and went unnoticed for five days. The seam itself was never the problem and
  is unchanged — production satisfies it with a live source, tests with fixtures. What changed is
  that the type crossing the seam is baikai's, so the local `ModelCallEvidence` sketch in
  Interfaces and Dependencies is deleted and replaced with the import list, and `EvidenceStrength`
  moves from plan 49's ownership to a citation of baikai's.

  Baikai's record is also better than the sketch it replaces, in ways that reach the design:
  `Observed` is a deliberate non-`Maybe` with no defaulting function, so an unobserved model
  cannot silently become a copy of the requested one — which was precisely the hazard the sketch's
  inline comment warned about. `ThinkingTranslation` records what a requested reasoning effort
  actually became on the wire including every clamp, collapse, and drop, which Milestone 4's
  non-conformance taxonomy should be built on rather than reinventing. `EvidenceStrength` is an
  ascending scale, so a roll-up can report how well a call is evidenced rather than only whether a
  record exists.

  Two limits are now stated explicitly rather than left implied. Baikai's changelog says nothing
  constructs a `ModelCallEvidence` from a real call yet — the vocabulary and the `Options.evidence`
  opt-in exist, provider-side population does not — so the fixture source remains how Milestones 3
  and 4 are proven, exactly as before. And `kioku-core 0.3.0.0` caps `baikai ^>=0.4.1.0`, so the
  cohort cannot take 0.5 yet; that gate belongs to plan 53, blocks only Milestone 2's import, and
  changes nothing about what this plan should build. Fixtures should be shaped to baikai's
  published record now so adoption is an import change rather than a redesign.

  Milestone 2 also gained the `Options.evidence` opt-in as an explicit step, with the note that a
  call leaving it `Nothing` behaves exactly as before — this is additive to plan 13's provider
  path and cannot regress it.
