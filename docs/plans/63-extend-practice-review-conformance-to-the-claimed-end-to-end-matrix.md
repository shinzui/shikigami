---
id: 63
slug: extend-practice-review-conformance-to-the-claimed-end-to-end-matrix
title: "Extend practice-review conformance to the claimed end-to-end matrix"
kind: exec-plan
created_at: 2026-08-27T00:54:32Z
intention: "intention_01m10bc7hae8trp0ev5mzpvt0d"
---

# Extend practice-review conformance to the claimed end-to-end matrix

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Plan 46 described an end-to-end conformance matrix for the OpenTelemetry practice-review
specialist: a trigger enters the router and is delegated to the specialist; the specialist
runs under its sanctioned execution profile; Kizashi delivery is retried, dead-lettered, or
left unknown without disturbing the semantic attention reservation; Kawa deduplicates a
redelivered history event; the reviewer's memory, grants, Kawa actor, and Kizashi intent
all use the identity recorded on the job across three identity kinds; and every material
change to a verdict yields a new attention key. Review record
[REV-1](../reviews/plan-46-review-orchestration-closeout.md) established that the
committed spec proves a smaller set. Plan 62 makes the closeout say so; this plan makes
the larger set true.

After this plan, `nix develop -c cabal test shikigami-core-test -j1 --test-options='-p
"practice review orchestration"'` runs a matrix that starts at the router with the real
proof declarations, provisions and resolves the real profile, drives Kizashi and Kawa
through in-process Warp stubs with scripted responses, exercises the three identity kinds,
and varies every input the attention key depends on. A maintainer can then change the
specialist with the confidence the plan-46 closeout claimed.


## Progress

- [ ] M1: router-to-specialist delegation with the real proof declarations.
- [ ] M2: provisioned `sanctioned-review` version 1 and a profile-constrained evaluator.
- [ ] M3: delivery matrix against a reservation: transient 500, terminal 4xx, unknown
      outcome, Kawa redelivery, and payload assertions.
- [ ] M4: three recorded identities across memory, grants, Kawa, and Kizashi.
- [ ] M5: attention-key variation matrix and plan 46 revision note.


## Surprises & Discoveries

(None yet.)


## Decision Log

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

(To be filled during and after implementation.)


## Context and Orientation

The orchestration spec is `shikigami-core/test/Shikigami/PracticeReviewOrchestrationSpec.hs`.
Its groups are `authorizationTests`, `attentionIdentityTests`,
`completeClassificationTests`, `agentRunSpecialistTests`, `replayTests`, and
`atomicAttentionTests`. `runPracticeReviewInput` runs the Flow directly under
`runWorkflowWith` with test interpreters; `specialistAgentRunDeps` runs the real
`shikigami.agent-run` workflow (`Shikigami.Agent.Workflow.runAgentRunWorkflow`) with
`deliveryPool = Nothing`, every sink base URL at `http://localhost:1`, the
`compatibilityIdentity` for the reviewer, and `resolveRunProfile` answering
`UnknownProfile`. `reviewerDecl` is a hand-written declaration with `sanctionedProfile =
Nothing`, not the checked-in `agents/proof/opentelemetry-practice-reviewer.dhall`.

The router is `architecture-practice-router`, declared in
`agents/proof/architecture-practice-router.dhall` and implemented by
`Shikigami.Flow.Routing`; `shikigami-core/test/Shikigami/RouterWorkflowSpec.hs` drives it
with a `routerDeps` builder, a scripted `Routing.RoutingRuntime` whose `evaluateRoute`
returns a chosen candidate, and specialists built by `successSpecialist`, which today is a
`ShikumiProgram {task = "noop-summary"}`. Delegation spawns a child `shikigami.agent-run`
whose `RunJob` carries `parentRunWorkflowId`, `parentSessionId`, `delegationDepth`, and
`lineage`; the child's declaration comes from the same `agents` list in `AgentRunDeps`.

Delivery: a sink intent becomes a row in keiro's outbox and a `pending` receipt in
`shikigami.sink_deliveries`; `Shikigami.Sink.Delivery` publishes asynchronously and moves
the receipt through `attempting`, `delivered`, `failed`, `dead`, or `unknown`.
`SinkDeliverySpec.hs` (`withFixtureUsingTracer`, line 445) wires `AgentRunDeps` with
`deliveryPool = Just pool` and starts Warp stubs for Kizashi and Danwa; its tests show how
to run a publisher pass and read receipts. Kawa's doorway stub `kawaDoorwayApplication`
in `shikigami-core/test/Main.hs` stores `(source, source_event_id)` and returns the same
activity id on redelivery.

Identity: `Shikigami.Agent.Principal.AgentIdentity` has `VerifiedIdentity AgentPrincipal`,
`CompatibilityIdentity Text`, and `UnresolvedLegacyIdentity`; `RunJob.identity` records
it, and ADR 0033 requires memory actors, grant checks, Kawa actors, and sink intents to use
the recorded value. `AgentWorkflowSpec.hs` ("verified recall composes the principal scope
with an accepted legacy alias", line 417) shows how a verified principal, an alias pool,
and a directory handle are built; the same file's sink and grant tests show how
`UnresolvedLegacyIdentity` is refused.

Profiles: `ProfileResolutionSpec.hs` inserts a profile row with `insertProfile pool
content digest` and resolves it with `resolveProfile (postgresProfileStore pool)`;
`AgentWorkflowSpec.hs` builds a version-1 profile with `workflowProfileWith
defaultThinkingProhibitions (ProfileVersion "1")` and shows, in "a profiled Flow is
constrained before its capability interpreters run", how a constrained `BehaviorEnv`
surfaces. Plan 62 adds `config/profiles/sanctioned-review-1.json`; if it has landed, use
that file's content instead of the test builder so the test and the operator provision the
same bytes.

Relevant local ADRs: [0033](../adr/0033-recorded-agent-principals-key-durable-state.md)
(identity), [0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md)
(delivery truth), [0035](../adr/0035-practice-review-attention-reserves-semantics-not-delivery-state.md)
(reservation never released), [0029](../adr/0029-model-routing-output-is-a-proposal-until-validated-against-journaled-authority.md)
and [0028](../adr/0028-a-router-catalog-is-a-bounded-snapshot-of-declared-authority.md)
(router), [0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md)
(profiles). No cross-repository ADR applies.


## Plan of Work

### Milestone 1: Router to specialist with the real declarations

At the end of this milestone one test loads both proof declarations from `agents/proof`,
enqueues a version-1 trigger to the router, and observes the specialist child complete with
a verdict whose lineage names the router's workflow and session.

Add a group `routedSpecialistTests` to the orchestration spec. Load the declarations with
the same loader `AgentLoaderSpec.hs` uses (`expectLoaded "../agents/proof/architecture-practice-router.dhall"`
and the reviewer file), build `AgentRunDeps` from `specialistAgentRunDeps` but with
`agents = [routerDecl, reviewerDecl]` and a `Routing.RoutingRuntime` whose
`resolveCatalog` returns the real catalog for those agents (see `routerDeps` in
`RouterWorkflowSpec.hs`) and whose `evaluateRoute` selects `opentelemetry-practice-reviewer`.
Because the proof reviewer requires a profile, either land M2 first or, for this
milestone only, resolve `sanctioned-review` to the test profile through
`resolveRunProfile`. Run the router job with `runAgentRunWorkflow`, then locate the child
workflow id the way `RouterWorkflowSpec.hs` does (from the delegation step's journaled
child id) and load its outcome; assert the child's behaviour output has `kind =
practice-review`, that the verdict's `lineage.parentWorkflowId` equals the router's
workflow id, and that `practice-review-evidence` appears in the child's step index.
Replay the router job and assert the child is not spawned twice and the fixture reader's
call count is unchanged.

Also change `RouterWorkflowSpec.successSpecialist` to accept a behaviour so at least one
existing router case delegates to a `Flow {name = "opentelemetry-practice-review"}`
specialist, keeping the `noop-summary` variant for the cases that only need a child to
finish.


### Milestone 2: The provisioned profile

At the end of this milestone the specialist runs under the real `sanctioned-review`
version 1 profile and the evaluator observes the constrained environment.

In `agentRunSpecialistTests`, replace `reviewerDecl` with the loaded proof declaration
(or set `sanctionedProfile = Just ProfileRequirement {profileId = "sanctioned-review",
version = Just "1"}` on it) and replace `resolveRunProfile` with `\profileId version -> do
now <- getCurrentTime; resolveProfile (postgresProfileStore pool) now profileId version`,
the composition the worker uses (`shikigami-workers/src/Shikigami/Workers/Config.hs`,
`agentRunDeps`). Before the run, insert the profile with `insertProfile`. Make the
counting evaluator record the `BehaviorEnv` it received and assert its `model` equals the
profile's sanctioned model, proving `behaviorEnvForProfile`'s `Flow` case reached the
interpreter. Add a negative case: with no profile row the run completes with
`PermanentAgentRunFailure` naming the profile, before any `practice-review-evidence` step.


### Milestone 3: Delivery matrix against a reservation

At the end of this milestone the receipt lifecycle for an attention message is proven
against scripted Kizashi responses, the reservation row is proven untouched by all of it,
and Kawa redelivery is proven to deduplicate.

Add `deliveryTests`. Build deps as `withFixtureUsingTracer` does, with `deliveryPool =
Just pool`, a Warp Kizashi stub whose response status is read from an `IORef` (start from
`kizashiApplication` in `ApprovalNotificationSpec.hs`), and the Kawa doorway stub. Run a
target-suspect review through the real AgentRun with the complete fixture reader and a
recipient map. Then, per case: with the stub answering 500, run one publisher pass and
assert the receipt is `failed` with the outbox message id unchanged; flip the stub to 201
and run another pass and assert `delivered` with the Kizashi id in `detail`, one POST
recorded, and the reservation row identical to before. With the stub answering 400 from
the start, assert the receipt reaches `dead` and the reservation row still exists and
still points at the same outbox id. For the unknown case, make the stub accept the POST
and then close the connection before responding (or return a body the client cannot
decode), and assert `unknown`. In each case, run a second equivalent review and assert it
journals `Coalesced`, adds one association row, enqueues nothing, and that the POST count
does not change. For Kawa, redeliver the review-history outbox message twice and assert
the doorway stored one `(source, source_event_id)` pair and returned one activity id; also
decode the stored envelope and assert `context_refs` contains the target repository as a
`mori://` ref and `activity://practice-review/<review-id>`.


### Milestone 4: Three recorded identities

At the end of this milestone the specialist is proven to use the identity recorded on the
job for review memory, grant checks, the Kawa actor, and the Kizashi intent, under all
three identity kinds, even when the manifest changes before replay.

Add `identityTests` with three cases built on the M3 deps. Verified: construct a
`VerifiedIdentity` principal and directory handle as the AgentWorkflowSpec verified-recall
test does, run the review, and assert the provisional memory's actor, the grant lookup
(use `DbGrants` with a grant on the principal), the Kawa envelope's `actor.id`, and the
sink intent's identity all render the principal, not the name. Compatibility: the
existing path with `disabledDirectoryHandle`; assert the same four surfaces render the
name. Unresolved legacy: `identity = UnresolvedLegacyIdentity`; assert the run is refused
at the first identity-gated boundary in the way `AgentWorkflowSpec.hs` already establishes
for that constructor, and that no reservation or outbox row exists. For the manifest-change
half, after the verified run completes, mutate the in-memory `agents` list to rename the
reviewer, replay the same job, and assert the four surfaces are byte-identical to the
first run.


### Milestone 5: Key variation matrix and closeout revision

At the end of this milestone every input the attention key depends on has a test that
changes it and observes a new key, and plan 46 records the new coverage.

Extend `attentionIdentityTests` with cases that change, one at a time, the
classification, a material claim's statement, a material claim's `material` flag, a cited
evidence item's `contentHash`, the owner role, and the recipient mapping, asserting a
different key each time; and cases that change only a claim id or the order of claims or
evidence items, asserting the same key (these require plan 60). Then append a revision
note to plan 46 stating which Milestone 4 sentences are now realised by which test names.
Do not edit REV-1 in `docs/reviews/`: a review record is an immutable event, so the
coverage change is recorded in this plan's Outcomes, and a later review of the same
subject at a later commit supersedes REV-1 by existing.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shikigami` inside the Nix shell with
the local PostgreSQL cluster running.

```bash
nix develop -c cabal build all
nix develop -c cabal test shikigami-core-test -j1 --test-options='-p "practice review orchestration"' --test-show-details=direct
nix develop -c cabal test shikigami-core-test -j1 --test-options='-p "router"' --test-show-details=direct
nix develop -c cabal test all -j1 --test-show-details=direct
nix develop -c just keiro-gate <merge-base>
git diff --check
```

Expected new groups in the orchestration transcript, each case `OK`:

```text
    routed specialist
      router delegates the proof trigger to the Flow specialist and records lineage: OK
    provisioned profile
      specialist runs under sanctioned-review 1 and the evaluator sees the constrained env: OK
      missing profile is refused before evidence:                                  OK
    delivery
      transient 500 retries the same outbox and receipt:                            OK
      terminal 400 dead-letters without releasing the reservation:                  OK
      unknown outcome is recorded without a second reservation:                     OK
      kawa redelivery yields one activity with the expected context refs:           OK
    recorded identity
      verified principal keys memory, grants, kawa actor, and kizashi intent:        OK
      compatibility identity keys the same four surfaces by name:                   OK
      unresolved legacy identity is refused before any review effect:               OK
      manifest rename before replay does not change any surface:                    OK
```

Every commit carries:

```text
ExecPlan: docs/plans/63-extend-practice-review-conformance-to-the-claimed-end-to-end-matrix.md
Intention: intention_01m10bc7hae8trp0ev5mzpvt0d
```


## Validation and Acceptance

Each milestone is accepted by its group passing and by the negative half of each case
failing when the behaviour it guards is broken: for example, temporarily deleting the
`Tx.condemn`-guarded enqueue in `reserveAttention` makes the 500-retry case fail on the
outbox count, and swapping `RunJob.identity` for the manifest name in
`practiceReviewAttentionEnv` makes the verified-identity case fail on the intent's
identity. The plan is accepted when `cabal test all -j1` passes with every group above,
`just keiro-gate` reports no practice-review finding (this plan adds no step or patch),
and plan 46 carries the revision note.


## Idempotence and Recovery

All additions are tests and fixtures. `withShikigamiMigratedDatabase` creates a fresh
database per case, so a failed run leaves nothing to clean. Warp stubs are started per
test with `testWithApplication` and stop with it. If the profile JSON from plan 62 changes
after M2 lands, the digest assertion fails with both digests printed; update the test's
expected model only if the profile's model changed. Run the groups individually with
`-p` while iterating; the full suite must stay serialized (`-j1`) because the repository
has a history of capacity-shaped parallel failures.


## Interfaces and Dependencies

No production interface changes. Test-side helpers to add: a `scriptedKizashiApplication ::
IORef Status -> IORef [CreateSignalReq] -> Application` shared between
`ApprovalNotificationSpec.hs` and the orchestration spec (move it to
`shikigami-core/test/Shikigami/Fixture/` beside `SinkHttp.hs`), and a
`loadProofDeclaration :: FilePath -> IO AgentDecl` wrapper over the loader used by
`AgentLoaderSpec.hs`. Dependencies: `warp`, `wai`, and `hasql` as already used by the
test suite. Ordering: M5's coalescing cases depend on plan 60; M2 prefers plan 62's
checked-in profile file. The review record this plan answers is
[REV-1](../reviews/plan-46-review-orchestration-closeout.md), required items 1 through 3,
together with the test-coverage item of
[REV-2](../reviews/practice-review-attention-reservation.md) that plan 60 does not cover.
