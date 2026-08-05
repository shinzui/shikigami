---
id: 10
slug: sanctioned-execution-attestation-for-agent-runs
title: "Sanctioned Execution Attestation for Agent Runs"
kind: master-plan
created_at: 2026-08-05T14:51:43Z
intention: "intention_01kz96h79mezmbnwm67pdjjepr"
---

# Sanctioned Execution Attestation for Agent Runs

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Shikigami today records one durable fact about how a run executed: the completed Kioku
session carries `modelUsed`, written from the configured `BehaviorEnv` at the two
session-completing seams in `shikigami-core/src/Shikigami/Agent/Workflow.hs`. That is
enough to tell a stub run from a configured real one forever after, which is exactly what
`docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md` set out to do. It is not
enough to gate a protected code change on. It does not record the thinking level actually
sent to the provider, what the provider said it did, the second and third calls of a
multi-call Shikumi program, retries, delegated child runs, the policy version the run was
supposed to obey, or the exact code change that was reviewed and the verdict that came back.

After this initiative a verifier who does not have access to Shikigami's database can answer
one narrow, auditable question: did the trusted agent runtime execute this review, of this
immutable code change, using only model calls permitted by this exact sanctioned profile?
A declared review agent cannot start without resolving an active, immutable execution profile
to a digest. Every provider call the run makes — root call, retry, fallback, tool-mediated
call, delegated child call — lands in a durable run-evidence record exactly once. When the
behavior and every relevant child are terminal, the evidence seals, a compliance roll-up
enumerates each non-conforming reason rather than collapsing to a boolean, and a signed
`AgentRunAttestation` binds the profile digest, the agent artifact digests, the canonical
repository identity with full base and head commits and a diff digest, and the review-result
digest. The signing key is held by a workload identity that the behavior, its prompt, its
tools, and its repository workspace cannot reach. A bounded read API serves the attestation
by run id or review-request id, and an offline fixture lets Kotei verify the proof with no
access to this system at all. Mutating any security-relevant field — commit, diff, result,
profile, call record, signature — makes verification fail.

This initiative answers `docs/improvement-requests/attest-sanctioned-agent-execution.md`
(the request kikan filed against this repository as IR-7). The portable vocabulary it
encodes is ratified upstream by
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6`; the per-call provider
observations it collects are produced upstream by
`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-3`; the driving scenario is
`mori://shinzui/kikan/okf/use-cases/concepts/UC-8`; and the consumer at the delivery gate is
`mori://shinzui/kotei/okf/improvement-requests/concepts/IR-2`.

In scope: the sanctioned-profile vocabulary and its fail-closed resolution; the immutable
agent-version and artifact-digest binding; the durable run-evidence aggregate and its
lifecycle; the compliance verdict roll-up; canonical encoding, hashing, and signing of the
attestation; the read API and the offline verifier fixture; and the UC-8 conformance fixture
with its mutation cases.

Explicitly excluded. Deciding which models are organizationally good enough, and enforcement
at a merge gate, both belong to Kotei — this initiative produces and serves the proof, it
does not consume it. Inspecting hidden provider chain-of-thought, and making provider
self-reports cryptographically independent, are out of reach and are stated as such in the
trust statement rather than implied. Capturing the per-call observations inside a provider
adapter belongs to baikai (IR-3); this initiative defines what a run's worth of those
observations means and stores it. Ratifying the shared cross-repository schema belongs to
kikan (IR-6); this initiative mirrors it under a schema version and proves conformance
against kikan's golden payloads. Baseline-and-candidate agent lineage and rollout policy
belong to the governed-evolution request `docs/improvement-requests/governed-agent-evolution.md`
(kikan IR-5 against this repository), which is unplanned as of 2026-08-05; this initiative
defines the minimum immutable agent identity it needs and shapes it so that request extends
rather than replaces it — see the Integration Points entry on `AgentVersionRef` and the
Decision Log.


## Decomposition Strategy

The request decomposes along the lifecycle of a single piece of evidence: what the words
mean, when policy is pinned, where observations accumulate, and how the result is signed and
served. Each boundary has a different failure mode and a different set of collaborators.

EP-1 is pure vocabulary. It is the only plan in this initiative with no dependency on
anything unlanded, upstream or local, so it can start the day this MasterPlan is written —
and starting it first is the point. Nine existing plans in the portfolio are about to define
something IR-7 needs (an agent version, a repository revision, a correlation id, a review
request id, a tool-catalog digest), and every one of them is cheaper to point at a landed
contract than to reconcile with one later. EP-1 exists to be that landed contract.

EP-2 is the policy gate: resolving a profile reference to an immutable digest before the
behavior runs, journaling it, keeping an in-flight run pinned to it, and failing closed on
anything unknown, expired, withdrawn, ambiguous, or mutable. It is deliberately separate
from EP-3 because a fail-closed gate is verifiable on its own — a run that must not start
demonstrably does not start — and because it is the plan that touches the existing provider
seam, which is settled code that EP-3 has no reason to disturb.

EP-3 is accumulation and judgement: the durable aggregate, its lifecycle, complete call
accounting across retries and delegated children, and the roll-up that enumerates
non-conformance. This is the largest plan and the one with a real upstream gate, so it is
built against a deterministic seam with stub fixtures — the same shape
`docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md` uses for its own
pending upstream adapter — which lets the aggregate, the accounting invariants, and the
verdict logic all be proven before baikai emits a single real `ModelCallEvidence`.

EP-4 is the trust boundary and the audience: canonical encoding, hashing, signing outside
agent authority, key rotation that does not orphan historical proofs, the bounded read API,
the offline verifier input, and the end-to-end UC-8 fixture with its mutation cases. It is
last because a signature over an incomplete roll-up is worse than no signature.

Alternatives considered. Folding this into
`docs/masterplans/9-architecture-practice-review-flow.md` was rejected: MasterPlan 9 is an
advisory, read-only review of Mori-addressed architecture decision records that returns one
of five classifications and writes memory, while this initiative is a signed gate over code
changes at commit granularity with a cryptographic trust boundary. They share revision-pinned
reading — which this MasterPlan consumes as an integration point rather than by merging — and
nothing else. A single ExecPlan was rejected on size: the work spans contracts, the provider
seam, a durable aggregate, a migration, a signing boundary, an HTTP surface, and a
cross-repository conformance fixture, which is far past five milestones and ten files.
Merging EP-1 into EP-2 was rejected because EP-1's whole value is being landable immediately
and citable by nine other plans; gating it behind
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md`, which EP-2
needs, would destroy that. Splitting EP-4's read API into a fifth plan was rejected: the API
serves exactly one record whose shape EP-4 defines, and the offline verifier fixture is the
same fixture the conformance milestone needs, so the two cannot be proven apart.

Each plan is independently verifiable. EP-1 by round-trip and canonical-encoding tests over
its own types plus a byte-comparison against kikan's published fixtures. EP-2 by tests that
present an expired, withdrawn, mutable, ambiguous, and unknown profile reference and observe
the run refuse to start, and by a journal assertion that the resolved digest survives replay.
EP-3 by fixtures — a two-call Shikumi program, a retry, and a delegated child — that each
produce one roll-up accounting for every call exactly once, and by mutation cases that yield
each non-conforming reason. EP-4 by the six UC-8 mutations each making verification fail, and
by an offline verifier run against a fixture file with the database stopped.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Sanctioned execution profile and attestation contracts | docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md | None | cross-MP: plan 43 (shared record conventions) | Not Started (startable now) |
| 2 | Fail-closed profile resolution and run pinning | docs/plans/50-fail-closed-profile-resolution-and-run-pinning.md | EP-1; cross-MP: plans 36 ✅, 37 ✅, 47 ✅, 39 ⏳ | cross-MP: plan 13 ✅ (provider seam) | Not Started (blocked on EP-1, plan 39) |
| 3 | Run-evidence aggregate and compliance roll-up | docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md | EP-1, EP-2; cross-MP: plans 38 ⏳, 39 ⏳, 28 M1 ⏳; upstream Baikai IR-3 ⏳ | cross-MP: plans 24, 35 | Not Started (blocked on EP-2, plans 38, 39, 28 M1) |
| 4 | Signed attestation, read API, and UC-8 conformance | docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md | EP-3; cross-MP: plans 22 ⏳, 44 ⏳; upstream Kikan IR-6 ⏳, Baikai IR-3 ⏳ | cross-MP: plans 13 live smoke, 48 | Not Started (blocked on EP-3, plans 22, 44) |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).
✅ marks a dependency verified Complete as of 2026-08-05; ⏳ marks one still outstanding.

Upstream gates, verified 2026-08-05. Both are `proposed`, neither has landed:
`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-3` supplies `ModelCallEvidence`
and is what EP-3 stubs behind a seam;
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6` ratifies the canonical
envelope, encoding, hashing, and redaction rules that EP-4 must match byte-for-byte. These
two are new to the portfolio's upstream ledger — before this MasterPlan there were seven open
upstream gates, and there are now nine.


## Dependency Graph

EP-1 depends on nothing and is startable immediately. Everything else in this initiative
depends on it, because everything else either resolves, stores, judges, or signs one of its
records.

EP-2 hard-depends on EP-1 for the profile vocabulary and on
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md` because the
resolved profile digest becomes a journaled value inside the agent-run workflow, and plan 39
establishes the checked specification and evolution gate that every new journaled value in
this repository must pass through. Writing the journaling by hand first and re-expressing it
under the DSL afterward is the single largest avoidable rework in this initiative. EP-2 is
soft-dependent on `docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md`, which is
Complete: it built the `Shikigami.Behavior.Provider` seam that EP-2 extends.

EP-3 hard-depends on EP-2 (a run with no pinned profile has nothing to be compliant with),
on `docs/plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md` because
its tables must be delivered through the one schema authority, on plan 39 because the
run-evidence lifecycle is a durable state machine, and on Milestone 1 of
`docs/plans/28-structured-logging-metrics-and-trace-propagation.md` because the run id and
per-call id that correlate Shikigami to baikai must be the portfolio's one correlation
vocabulary rather than a second one invented here. Its upstream gate is baikai IR-3, worked
around with a deterministic reader seam.

EP-4 hard-depends on EP-3 (nothing to sign until evidence seals), on
`docs/plans/22-outbound-authentication-for-sink-clients.md` for the credential-resolution
machinery the signer reuses, and on
`docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md` for the
revision-pinned repository identity, revision, and diff vocabulary that `ReviewedArtifact`
binds. Its upstream gates are kikan IR-6, which must be at least accepted before the
canonical encoding can be frozen, and baikai IR-3, without which the conformance fixture's
positive case cannot use real evidence.

Two coordination edges reach outside this initiative's hard dependencies.

`docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md` is Complete except its live
Anthropic smoke transcript, which was never performed because no credential was available
and is recorded as unproven rather than assumed. IR-7 acceptance criterion 8 requires a
permitted run that yields `sanctioned`, and a run that never reached a real provider cannot
demonstrate that. That deferred item is therefore a precondition of EP-4's positive
conformance case, not a cosmetic gap.

`docs/plans/48-add-a-portable-one-off-repository-agent-harness.md` is unregistered — it
belongs to no MasterPlan — and it owns a workspace, a command policy, and a permission
boundary for an agent operating on a repository checkout. IR-7 requires the signing key to be
invisible to the behavior, the prompt, the tools, and the workspace. Those two designs must
agree before either ships, or plan 48's boundary gets retrofitted. EP-4 records the
constraint; plan 48 must record the obligation.


## Integration Points

`AgentVersionRef` and `AgentArtifactSet` — defined by EP-1 in `shikigami-core`. Involved:
EP-1, EP-3, EP-4; cross-MasterPlan
`docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md`,
`docs/plans/23-agent-lifecycle-control-with-meibo-principals.md`, and the unplanned
governed-evolution request `docs/improvement-requests/governed-agent-evolution.md`.

This is the initiative's most consequential shared artifact, because the thing IR-7 needs
does not exist anywhere in the portfolio today. IR-7 must bind a run to a logical agent and
an immutable agent or deployment version, plus digests of the declaration, the behavior or
serialized Shikumi program, the grounding bundle, and the tool catalog. Plan 33 was checked
on 2026-08-05 and does not provide this: its scope is the `identity`, `memory`, and `enabled`
declaration fields, and it neither identifies a declaration revision nor pins a run to an
immutable version. The request that *would* provide it is the governed-evolution request,
which asks for exactly declaration revision, behavior artifact identity, run pinning,
baseline-to-candidate relation, and rollout policy — and which has no ExecPlan.

EP-1 therefore defines the minimum: `AgentVersionRef`, carrying a logical agent id, an
immutable version identifier, and the declaration digest; and `AgentArtifactSet`, the
digest bundle kikan IR-6 names. Both are shaped so that lineage — a baseline pointer, a
candidate relation, a rollout state — is an additive field rather than a replacement, and
EP-1's tests pin that the encoding of a record with no lineage is byte-identical to one
written before lineage existed. A future governed-evolution plan extends these records; it
must not introduce a second agent-version vocabulary. Plan 33 should state that it does not
own declaration revision and point here.

`ReviewedArtifact` and revision-pinned repository reading — `RepositoryId`, `Revision`,
`RepoRef`, `PinnedDiff`, and the `EvidenceReader` record defined by
`docs/plans/44-acquire-revision-pinned-architecture-practice-evidence.md`. Involved: EP-1,
EP-4; cross-MasterPlan plans 43, 44, 46.

Plan 44 already defines a reader whose `readDiff` takes a repository identity and two
revisions and returns a pinned diff. That is precisely what `ReviewedArtifact` needs to bind
canonical repository identity, full base and head commits, and a diff digest. EP-1 defines
`ReviewedArtifact` over plan 44's types rather than declaring its own; EP-4 acquires the
values through plan 44's reader. Plans 43 and 44 should record that these types are
portfolio-shared rather than private to MasterPlan 9.

Run and call correlation identifiers — owned by Milestone 1 of
`docs/plans/28-structured-logging-metrics-and-trace-propagation.md`. Involved: EP-3;
cross-MasterPlan plans 28, 29, 30.

IR-7 requires every baikai call to receive the Shikigami run id plus a unique call id, and
requires retries and parent/child relationships to survive in the evidence. That is the same
correlation concern plan 28 owns for logs and traces. EP-3 consumes plan 28's identifiers and
must not mint a parallel scheme; plan 28 should record that its correlation ids become
durable audit evidence, which raises the bar on their stability.

Review-request identity — owned by
`docs/plans/14-approval-and-human-in-the-loop-end-to-end.md`. Involved: EP-3, EP-4.

IR-7 binds the run to the approval or review request id and an idempotency key, and EP-4's
read API serves attestations by review-request id. Plan 14 owns approval policy and tokens
and is the natural definer of a stable typed review-request identifier. Until plan 14 lands,
EP-3 accepts the identifier as an opaque typed value supplied by its caller.

Tool-catalog digest — owned by
`docs/plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md`. Involved: EP-1, EP-3.

`AgentArtifactSet` includes a tool-catalog digest. Plan 12 declares per-agent MCP servers and
therefore owns what a run's tool catalog *is*. For a digest over it to be meaningful the
catalog needs a stable canonical encoding, which plan 12 should commit to.

Signing credential class — `docs/plans/22-outbound-authentication-for-sink-clients.md` owns
credential resolution; EP-4 adds a distinct class. Involved: EP-4; cross-MasterPlan plans 22,
48.

The attestation signing key is not an outbound sink credential: it must be unreachable from
the behavior, the prompt, the tools, and the repository workspace, and IR-7 prefers it live in
a separate trusted component. EP-4 reuses plan 22's resolution machinery and adds the
non-visibility assertion as a test, not as a comment.

Database schema — the `pg-migrate` component in `shikigami-migrations`, delivered by
`docs/plans/47-upgrade-shikigami-to-the-coherent-july-2026-dependency-cohort.md`, with the
remaining cutover owned by
`docs/plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md`. Involved:
EP-3, EP-4.

EP-3's evidence tables and EP-4's attestation table are added by appending files to
`shikigami-migrations/sql-migrations/manifest` via `just new-migration`. No plan in this
initiative creates a second migration runner. One non-obvious obligation comes with the
component: `Shikigami.Migrations.reconcileShikigamiReadModels` must run after a successful
`up`, because Kioku 0.2 stopped registering read models on first query and `registerReadModel`
only inserts. If EP-4's read API is backed by a Kioku read model, it must be covered by that
reconciliation, or every query against it fails `ReadModelUnregistered` in production while
passing in a freshly created test database.

Journaled value evolution — `docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md`
establishes additive-only journaled value versioning, and plan 39 establishes the checked
specification. Involved: EP-2, EP-3. The pinned profile digest and the evidence lifecycle are
both journaled; both follow the additive-only discipline, and journaled step names are never
renamed.

Delegated child evidence — `docs/plans/35-delegation-as-a-first-class-declared-capability.md`
and the landed delegation primitive in `shikigami-core/src/Shikigami/Agent/Delegate.hs`.
Involved: EP-3. Complete call accounting must include delegated children, and the run cannot
seal until every relevant child is terminal. The lineage fields exist today —
`parentSessionId`, `parentRunWorkflowId`, and `delegationDepth` on `RunJob` — so EP-3 consumes
them; plan 35 must not break them when it makes delegation declarative.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-1: Milestone 1 — profile vocabulary: allowed `(provider, API, model, thinking)` tuples, prohibitions, limits, issuer and validity, canonical digest
- [ ] EP-1: Milestone 2 — `AgentVersionRef` and `AgentArtifactSet` with lineage-ready additive shape and byte-stability tests
- [ ] EP-1: Milestone 3 — `ReviewedArtifact` over plan 44's revision types, plus the non-conforming reason taxonomy and evidence-strength vocabulary
- [ ] EP-1: Milestone 4 — the local `AgentRunAttestation` mirror under a schema version, with canonical encoding and a conformance test against kikan's published fixtures
- [ ] EP-2: Milestone 1 — profile store and resolution to an immutable digest, with fail-closed rejection of unknown, expired, withdrawn, ambiguous, and mutable references
- [ ] EP-2: Milestone 2 — resolution journaled before behavior execution; in-flight runs stay pinned across replay
- [ ] EP-2: Milestone 3 — the resolved profile constrains the provider seam: a call outside the pinned tuple set cannot be dispatched
- [ ] EP-3: Milestone 1 — the run-evidence aggregate and its lifecycle, declared through plan 39's checked specification
- [ ] EP-3: Milestone 2 — `ModelCallEvidence` collection behind a deterministic seam; stub fixtures pending baikai IR-3
- [ ] EP-3: Milestone 3 — complete call accounting across retries, fallbacks, and delegated children; sealing only when every relevant child is terminal
- [ ] EP-3: Milestone 4 — the compliance roll-up: every non-conforming reason enumerated, deterministic steps `not-applicable`, mixed-model runs listing each call
- [ ] EP-3: Milestone 5 — pg-migrate-managed evidence tables, reconciled read models, queryable state
- [ ] EP-4: Milestone 1 — canonical encoding and hashing of the attestation payload, byte-matched against kikan's golden payloads
- [ ] EP-4: Milestone 2 — signing by a workload identity, with a test proving the key is unreachable from behavior, prompt, tools, and workspace
- [ ] EP-4: Milestone 3 — key rotation that preserves historical verification
- [ ] EP-4: Milestone 4 — bounded read API by run id and review-request id, plus the offline verifier input
- [ ] EP-4: Milestone 5 — the UC-8 end-to-end conformance fixture: `sanctioned` for the permitted run, explicit non-conforming verdicts for the model, thinking, fallback, missing-call, artifact, and signature mutations


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Portfolio audit (2026-08-05): **the immutable agent version IR-7 depends on is owned by
  nobody.** Plan 33's Purpose section scopes it to the `identity`, `memory`, and `enabled`
  declaration fields and explicitly frames itself as the additive-Dhall-field pattern-setter;
  it never mentions declaration revision, artifact digest, or run pinning. The request that
  asks for those — `docs/improvement-requests/governed-agent-evolution.md` — has no ExecPlan
  and appears in no MasterPlan registry. EP-1 therefore defines the minimum itself, shaped for
  additive extension. See the Decision Log.
- Portfolio audit (2026-08-05): **contracts belong in `shikigami-core`, not `shikigami-api`.**
  Plan 36 made `shikigami-api` the public HTTP contract package that *depends on*
  `shikigami-core` (`docs/architecture/packages.md:35-48`), and its exposed modules are only
  `Shikigami.Api`, `Shikigami.Api.OpenApi`, `Shikigami.Api.Problem`, and `Shikigami.Health.Api`.
  The modules older plans call `Shikigami.Api.Agent` and `Shikigami.Api.RunJob` no longer
  exist — `RunJob` is now `shikigami-core/src/Shikigami/Agent/RunJob.hs` and the declaration
  is `shikigami-core/src/Shikigami/Agent/Decl.hs`. Domain vocabulary that workers must reach
  cannot live in `shikigami-api` at all, because `shikigami-workers` is forbidden from
  depending on it and `shikigami-core/test/Shikigami/PackageArchitectureSpec.hs` fails the
  build on that edge. EP-1's records go in `shikigami-core`; only EP-4's HTTP surface touches
  `shikigami-api` and `shikigami-server`.
- Portfolio audit (2026-08-05): **this initiative adds two upstream gates to a ledger that
  had seven.** Verified by reading the `status:` field of every improvement request in the
  producing repositories: baikai IR-3 and kikan IR-6 are both `proposed`. Neither blocks EP-1
  or EP-2; both bind EP-4.
- Portfolio audit (2026-08-05): **plan 13's unperformed live smoke became load-bearing.**
  MasterPlan 2 records it as an accepted gap — no credential was available, so it was recorded
  as unproven rather than assumed. IR-7 acceptance criterion 8 needs a permitted run that
  yields `sanctioned`, which a run that never reached a real provider cannot supply. The gap
  is now a precondition of EP-4's positive case.
- Upstream check (2026-08-05): **the sibling terminal-rejection gate shows how slowly these
  move.** Keiro IR-3, which MasterPlan 3 has tracked since 2026-07-30, is still `proposed`; its
  implementing plan `mori://shinzui/keiro/plans/165-add-terminal-outbox-publication-rejection-outcomes`
  has none of its four milestones done and `PublishRejected` appears nowhere in keiro's
  sources. Plan the EP-4 schedule on the assumption that kikan IR-6 and baikai IR-3 take
  comparable time, and keep EP-1 through EP-3 genuinely independent of them.


## Decision Log

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

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
