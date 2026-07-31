---
id: 2
slug: production-reality-de-stub-the-runtime-behavior-and-integration-path
title: "Production Reality: De-stub the Runtime Behavior and Integration Path"
kind: master-plan
created_at: 2026-07-08T20:13:36Z
intention: "intention_01kx1tygnxenvarsw91bjsy19r"
---

# Production Reality: De-stub the Runtime Behavior and Integration Path

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

MasterPlan 1 bootstrapped shikigami into a runtime that provably runs the whole
declared-agent loop — triggers, durable workflows, behaviors, sinks, memory — but it
did so on deliberate stubs, and several of those stubs *report success*. An
architecture review (2026-07) found four places where the production worker path is
wired to fakes with no configuration escape hatch, each verified in code. A subsequent
portfolio-conformance review also found two prerequisites shared by all four streams:
Shikigami has not yet adopted the fleet's six-package deployed-service architecture or
its Settei configuration model. Those prerequisites are now explicit children rather
than conventions repeated differently in feature plans:

1. The worker always builds its behavior environment with a stub LLM provider, so every
   Skill agent "succeeds" with the fixed sentence
   `"stub-skill: instructions acknowledged; no model was called"` and durably records
   it as a learning (`shikigami-core/src/Shikigami/Behavior/Run.hs:45-49`,
   `Behavior/StubProvider.hs:32`, `shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs:30`).
2. Approval/human-in-the-loop is a stub end to end: policy always answers "not
   required", the notify hooks are no-ops, and nothing external can call
   `resolveApproval` — a parked Flow notifies nobody and can only time out
   (`Shikigami/Agent/Approval.hs:91-98,117-122`, `Shikigami/Worker.hs:204`,
   `Agent/Workflow.hs:312-314`).
3. Recalled memory never reaches the model, the `ShikumiProgram` arm discards even the
   trigger payload, and the recall query is constant boilerplate
   (`Agent/Workflow.hs:175,197-205`, `Behavior/Run.hs:53-74`,
   `Behavior/Skill.hs:104-110`, `Agent/Run.hs:221-223`,
   `Flow/AtRiskCustomer.hs:62-63`).
4. Sink handlers lie: `ReiAction` is a no-op whose `Stubbed` outcome counts as
   `PublishSucceeded` (`Sink/ReiAction.hs:16-22`, `Sink.hs:62`,
   `Agent/Workflow.hs:581-583`), and the declaration fields
   `KizashiSignal.recipientFrom` and `DanwaConversation.topic` are silently ignored
   (`Sink/KizashiClient.hs:22-45`, `Sink/Danwa.hs:24-31`).

When this MasterPlan is complete, the production path is *honest*: Shikigami has the
standard six-package boundary, every executable resolves typed configuration through
Settei, and an operator can wire a real Anthropic model without exposing secrets while the worker says loudly which
provider is active (stub included); a human can be asked for approval through danwa or
kizashi and answer from the CLI, with the tested durable park/resume/timeout semantics
unchanged; agents actually use what they remember and what triggered them, in both
behavior arms; and every sink either really delivers, really fails (visibly, into the
outbox retry path), or is rejected at validate time — nothing declared is silently
dropped, and nothing stubbed masquerades as delivered.

In scope: the four work streams above, entirely within this repository plus its
already-pinned dependencies (baikai gains no changes; `baikai-claude` is merely added
to `build-depends`). Out of scope, owned by sibling MasterPlans: delivery/retry
semantics and downstream idempotency (MasterPlan 3), credentials for sink clients and
grant storage (MasterPlan 4), flow versioning and journal migration (MasterPlan 5),
serving/packaging/observability (MasterPlan 6), and schema evolution including
declarative approval policy (MasterPlan 7). Building a rei HTTP API is explicitly out
of scope — rei has none today, and plan 16's contribution is refusing to pretend
otherwise.


## Decomposition Strategy

The review's findings fall into six distinct concerns. Two are foundations:
**deployed-service architecture** (where runtime responsibilities live) and
**configuration** (how every executable obtains validated settings). Four are feature
concerns, and the decomposition follows the concerns rather than the files: **model execution** (what
runs a Skill), **human-in-the-loop** (who may stop a sink), **context assembly** (what
the behavior gets to see), and **sink truth** (what happens to the output). Each
produces an independently demonstrable behavior — a real model reply, a CLI-resolved
approval, a memory-changed verdict, a visible delivery failure — and each is
independently testable against the existing deterministic stubs, so the four child
plans can be verified without each other and largely without API keys.

Two alternatives were considered and rejected. Merging plans 13 and 15 into one
"behavior reality" plan was rejected because they deliver on different axes (provider
wiring vs. input assembly), have different validation regimes (13 needs a live key for
its final proof; 15 is fully provable request-side against the stub), and merging
would produce a plan touching ten-plus files across five modules — exactly the
unwieldy shape the decomposition principles warn about. Their real coupling is two
shared files, which is handled as an integration point with an explicit landing order
instead. Second, deferring plan 16's declaration-field honesty to the schema-evolution
plan (33, MasterPlan 7) was rejected: silently ignored fields are a present-tense
runtime lie, not a future schema concern, and the fix (honor or reject) requires no
schema change.

Plan 36 establishes the six-package shape, plan 37 establishes Settei inside that shape,
and plan 47 ports one coherent released dependency cohort. Plans 14 and 16 share only
additive record fields, but their portfolio landing order is now plan 36 → plan 37 → plan
47 → plans 16/17/19 → plan 22 → plan 14: plan 22 wraps the settled sink clients with the
authenticated `SinkHttp` that approval notifications consume. Plan 15 is sequenced
after 13 by soft dependency (same-file coordination, and the feature is only meaningful
with a real model) but is not blocked by it.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| F1 | Align Shikigami with the six-package deployed-service architecture | docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md | None | None | Complete (2026-07-31) |
| F2 | Adopt Settei configuration across Shikigami binaries | docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md | F1 | None | In Progress |
| F3 | Upgrade Shikigami to the coherent July 2026 dependency cohort | docs/plans/47-upgrade-shikigami-to-the-coherent-july-2026-dependency-cohort.md | F2 | plan 38 integration | Not Started; M0 complete |
| 1 | Wire a real model provider into behavior runs | docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md | F3 | None | Not Started |
| 2 | Approval and human-in-the-loop end to end | docs/plans/14-approval-and-human-in-the-loop-end-to-end.md | F3; cross-MP: plans 17 and 22 | EP-1 | Not Started |
| 3 | Inject recalled memory and trigger payload into behavior context | docs/plans/15-inject-recalled-memory-and-trigger-payload-into-behavior-context.md | F3 | EP-1 | Not Started |
| 4 | Honest sink handlers: real ReiAction and honored declaration fields | docs/plans/16-honest-sink-handlers-real-reiaction-and-honored-declaration-fields.md | F3 | None | Not Started |


## Dependency Graph

F1 is the first implementation step. F2 follows F1 because configuration ownership is
expressed at executable and package boundaries. F3 follows F2 because the major library ports
must land into the final package/configuration shape. Its former external release gate is
satisfied by Kioku `v0.2.0.0`.
EP-1, EP-3, and EP-4 then consume F3. EP-2 has two hard dependencies: F3 and
`docs/plans/22-outbound-authentication-for-sink-clients.md`: approval asks are outbound
danwa or kizashi calls and must use plan 22's authenticated `SinkHttp` rather than
introduce a second, unauthenticated client path. EP-2 also soft-depends on EP-1 for the
model-provider integration seam, not for configuration ownership.

The remaining intra-MasterPlan soft dependency is EP-3 on EP-1. Both edit
`shikigami-core/src/Shikigami/Behavior/Run.hs` and `Behavior/Skill.hs`; EP-1 defines
the `BehaviorEnv` shape, the provider/config idiom, and the `Options` parameter on the
skill functions, while EP-3 changes the *input* side (`BehaviorInput` and context
assembly). EP-1 should land first so EP-3 rebases mechanically; if EP-3 must start
early, it implements against the current signatures and treats EP-1's `Options`
parameter as absent (both plans document this). Functionally, EP-3's memory injection
is fully testable against the stub provider (its tests assert the outbound request,
not the reply) but only becomes *meaningful* to users once EP-1's real provider can
read the injected context — hence soft, not hard.

EP-4 (sink honesty) remains independent. EP-2 touches the approval seam and worker
wiring after plan 22 has established authenticated clients; EP-4 touches the sink
dispatch path. Both add
fields to `WorkerEnv`/`AgentRunDeps` and flags to the `worker` CLI command — a
mechanical merge, called out in each plan. All four plans may be worked concurrently
where their dependencies allow, provided the EP-1/EP-3 landing order is respected and
the `worker` command's flag additions are merged deliberately.

### Cross-MasterPlan execution order for MasterPlans 2–7

The six MasterPlans are not six serial phases. Their child plans form one directed
acyclic graph, and implementing the MasterPlans in numeric order would create avoidable
adapters and merge work. The canonical landing order is expressed as waves; plans in
the same wave may proceed in parallel unless an intra-MasterPlan dependency says
otherwise.

Foundation wave: land plan 36 (package architecture), plan 37 (Settei configuration), and
plan 47 (the coherent released dependency cohort), in that order. Then land plan 38
(pg-migrate transition) and plan 39 (checked Keiro DSL). These plans turn recurring fleet
conventions into owned, testable prerequisites. No later plan may recreate a seventh
top-level package, raw environment resolver, arbitrary pre-release dependency cohort, Codd
migration path, or unchecked workflow topology.

Core semantics wave: land plan 13 (model provider), plan 16 (honest sink behavior),
plans 17 and 18 (worker failure taxonomy and transactional enqueue), plan 21 (grant
schema), and plan 24 (workflow-versioning discipline) after their applicable
foundation predecessors.

Shared-seam wave: land plan 20 after plans 17 and 18 so it consumes their worker and
enqueue seams; land plan 22 after plans 13 and 16 so it owns the single authenticated,
header-capable HTTP layer; plans 25 and 26 may land after plan 24. Plan 15 lands after
plan 13. Plan 28's logging and metrics milestones may start earlier, but its HTTP trace
propagation lands after plan 22 and extends the same HTTP helper.

Semantic-consumer wave: land plan 19 after plan 16 and plan 28 Milestone 1, then plan
27 after plans 19, 24, and 28 so consolidation preserves the final sink semantics,
wire format, and trace context. Land plan 33 after plan 20 so it extends the canonical
loader with enabled-agent filtering instead of creating another loader. Land plan 30
after plan 20 so its agent inspection command consumes the same load report. Plan 14
lands after plan 22 and uses its authenticated clients.

Feature-completion wave: plan 23 lands after plans 30 and 33 (and preferably plan 21),
extending the existing `agents` command with principal/lifecycle state and persisting
the shared load report. Plan 35 lands after plans 24 and 33. Plan 34 may implement
distillation, bounded fallback, and retention earlier, but its shared-scope milestone
lands after plan 33. Plan 32 lands after plan 22 and preferably after plans 21, 19, and
27. Plan 12's runtime milestones land after plan 13, plan 33, and its cross-repository
baikai/shikumi prerequisites.

Operations closure wave: plan 29 follows plan 28 where practical, and plan 31 lands
last, after the health, provider, outbound-authentication, and channel-egress
configuration surfaces it documents have stabilized. This wave ordering is a delivery
optimization; only dependencies explicitly marked hard in a registry prevent an
earlier start.

The exact edge ledger is:

| Consumer | Predecessor(s) | Strength |
|---|---|---|
| all deployed feature plans | plan 36 | Hard: package and executable ownership must be settled first |
| every process/config plan | plan 37 | Hard: Settei is the sole process-configuration surface |
| every plan that imports a co-developed runtime library | plan 47 | Hard: one released dependency cohort and its compatibility fixtures |
| every database-evolution plan | plan 38 | Hard: pg-migrate owns components, manifests, CLI, and test support |
| plans 24–27 and 35 | plan 39 | Hard: durable topology and identifiers pass the checked Keiro DSL gate |
| plan 14 | plans 17 and 22 | Hard: approval asks import authenticated clients and preserve failure class through workflow retry/dead-letter semantics |
| plan 19 | plan 28 M1 | Hard: delivery events import `Shikigami.Log` |
| plan 22 | plan 19 | Hard: authenticated clients preserve the terminal/transient delivery taxonomy |
| plan 20 | plans 17 and 18 | Hard: routing/enqueue hardening consumes their final seams |
| plans 25 and 26 | plan 24 | Hard: both change durable workflow behavior |
| plan 23 | plans 30 and 33 | Hard: it extends the owned CLI and consumes declared identity |
| plan 30 | plan 20 | Hard: `agents list` renders `AgentLoadReport` |
| plan 32 | plans 19 and 22 | Hard: kanmon extends the canonical auth/HTTP layer and terminal delivery taxonomy |
| plan 33 | plan 20 | Hard: enabled selection consumes `AgentLoadReport` |
| plan 35 | plans 24, 33, and 38 | Hard: delegation changes the durable workflow/agent schema and adds a durable global budget ledger |
| plan 22 | plans 13 and 16 | Preferred landing order: reuse final provider and sink-client shapes |
| plan 27 | plans 19, 24, and 28 | Preferred landing order: consolidate final semantics once |
| plan 31 | plans 13, 22, 28, 29, and 32 | Preferred landing order: document and package settled surfaces |

Plan 28 Milestone 3 also waits for plan 22, while its logging and metrics milestones can
start immediately. Plan 34 starts after plan 33 so its scope semantics and bounded memory
policy are the only types threaded through the lifecycle worker.


### Authoritative portfolio order (2026-07-30)

This table supersedes the earlier wave wording where it differs. It covers every unfinished
MasterPlan (2–9), includes plan 47, and separates hard blockers from partial work that can land
behind a stable seam.

| Wave | Implement in this order | Gate / parallelism |
|---:|---|---|
| 0 | Advance the seven open upstream IRs; retain completed Kioku IR-1 as evidence; plan 43 contract design | Plan 43's types may be designed now; package implementation waits for plan 47 |
| 1 | plan 36 | First code change: six-package ownership and composition roots |
| 2 | plan 37 | Settei 0.2 is the sole process-config surface; no Kubernetes adapter |
| 3 | plan 47 | Kioku `v0.2.0.0` satisfies the former release gate; after plan 37, port the entire released dependency cohort together |
| 4 | plan 38; plan 39; plan 28 M1 | pg-migrate cutover, checked Keiro topology, and structured-log vocabulary can proceed in parallel after plan 47 where their file ownership permits |
| 5 | plans 13, 16, 17, 18, 21, and 24 | Core provider, sink, retry/lease, atomic enqueue, grants, and versioning semantics; plan 24 follows plan 39 and plan 21 follows plan 38 |
| 6 | plan 20; plan 19; plan 22; plan 15; plans 25 and 26; plans 30 and 33 | Respect 17+18→20, 16+28M1+Keiro IR-3→19→22, 13→15, 24→25/26, and 20→30/33; plan 26's indexed-session slice waits for Kioku IR-2 |
| 7 | plans 14, 23, 27, 29, 32, 34, and 35; plan 12 runtime | Follow the exact registry edges; plan 29 waits for Shibuya IR-1, plan 34 M2/M3 waits for Kioku IR-2, and plan 12 M3–M5 waits for its three upstream requests |
| 8 | plan 40 → plan 41 → plan 42 | Plan 40 follows plan 33; plan 42 also follows plan 35 |
| 9 | plan 44 and plan 45 after plan 43, then plan 46 | Plan 44's stub seam can land before Kikan IR-5; live plan 44/46 conformance waits for it. Plan 45 also follows plan 25; plan 46 follows MasterPlan 8 and plans 16, 19, 25, and 35 |
| 10 | plan 31 | Operations closure after health, auth, egress, migrations, and configuration have stabilized |

Cross-repository blocker ledger:

Kioku IR-1 is completed by `v0.2.0.0` at
`5765f98add2a87a356c70793a6ba54375ef5feec`; it is retained in plan 47 and the
visual map as completion evidence, not as an open blocker.

| Downstream plan/milestone | Owning request | What remains startable |
|---|---|---|
| plans 26 and 34 bounded/indexed read milestones | `mori://shinzui/kioku/docs/improvement-requests/add-indexed-session-and-bounded-memory-read-models.md` (IR-2) | Other workflow/memory seams and fixtures |
| plan 19 terminal rejection | `mori://shinzui/keiro/docs/improvement-requests/add-an-explicit-terminal-outbox-rejection-outcome.md` (IR-3) | Handler truth and delivery receipt schema |
| plan 29 Shibuya probe | `mori://shinzui/shibuya/docs/improvement-requests/expose-a-public-worker-probe-contract.md` (IR-1) | Typed HTTP health API and local loop supervision |
| plan 12 MCP client/auth | `mori://shinzui/baikai/docs/improvement-requests/ship-the-mcp-client-tool-and-authentication-contracts.md` (IR-2) | M1–M2 declaration and registry seam |
| plan 12 MCP tool adapter | `mori://shinzui/shikumi/docs/improvement-requests/ship-the-mcp-to-tool-registry-adapter.md` (IR-1) | M1–M2 declaration and registry seam |
| plan 12 per-action authorization | `mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-3` | Inert schema only; no live connection/invocation |
| plan 44 live evidence and plan 46 live conformance | `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5` | Deterministic reader seam and stub fixtures |


## Integration Points

**Behavior run seam — `Behavior/Run.hs` and `Behavior/Skill.hs` (EP-1, EP-3).**
Shared artifacts: the `BehaviorEnv` record, `runBehavior`'s signature, and the
`runSkill`/`runSkillWith` signatures. EP-1 owns `BehaviorEnv` (adds `options ::
Options`) and the `Options` parameter; EP-3 owns the new `BehaviorInput { payload,
recalled }` record and the context-assembly logic that renders it. EP-1 defines first;
EP-3 extends. End state:
`runBehavior :: BehaviorEnv -> AgentDecl -> BehaviorInput -> IO (Either RunError Value)`.

**Configuration boundary — plan 37 defines; all feature plans consume.**
`docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md` owns stable
keys, typed strict records, explicit environment bindings, source precedence,
redaction, diagnostics, and exit semantics. Plans 13, 14, 16, 22, 28–32, and 34 must
declare Settei `Setting`s and extend the process-level application config rather than
calling `getEnv`/`lookupEnv` or building one-off parsers. Secrets are credential
references or redacted secret types and never gain `Show`, JSON, or log rendering.
Standard OpenTelemetry environment variables remain SDK-owned as plan 37 documents.

**Keiro journal discipline — `Agent/Workflow.hs` step structure vs. MasterPlan 5's
plan 24 (all four EPs constrained).**
`docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md` introduces
flow-versioning discipline for long-lived journals. Until it lands, the rule for this
MasterPlan is: never rename, remove, or reorder existing journaled step names
(`ingest-job`, `lookup-agent`, `open-session`, `recall`, `run-behavior`,
`dispatch-sinks`, `record`, `complete`, `approval:<kind>:<ordinal>`, the `:notify`
suffix, `emit-signal:<n>`); additive steps and additive `Maybe` fields on journaled
JSON only. Concretely: EP-3 changes the `run-behavior` step *body* but not its name or
result shape; EP-4 adds `resolvedRecipient :: Maybe Text` to the journaled/outboxed
`SinkIntent` and keeps the deprecated `Stubbed` constructor of `SinkOutcome` so
historical journals still decode (each plan carries a decode-compat test or an
explicit keep-constructor decision).

**Approval notification transport — plan 22 (EP-2 consumes).**
`docs/plans/22-outbound-authentication-for-sink-clients.md` owns `SinkHttp`, the shared
connection managers, `TokenSource`, and the canonical header-capable POST helper. EP-2
uses those artifacts for danwa/kizashi approval asks and does not open a parallel raw
HTTP path. `ApprovalPolicy` remains a small typed record local to EP-2, resolved as
part of the Settei application config defined by plan 37.
Plan 33 does not own approval policy—it owns identity, memory policy, and enablement—so
there is no approval dependency on MasterPlan 7.

**Sink outcome semantics — vs. MasterPlan 3's plan 19 (EP-4 feeds it).**
`docs/plans/19-sink-delivery-truth-and-downstream-idempotency.md` owns retry ceilings,
dead-lettering, and delivery accounting for the outbox path. EP-4's contribution is
upstream of that: it stops minting fake `PublishSucceeded` outcomes so plan 19 has
truthful failures to manage. EP-4 must not implement its own retry policy beyond what
`publishClaimedOutbox` already does. Preferred landing order is plan 16 plus plan 28
Milestone 1 → plan 19 → plan 27: first make individual handlers honest and establish
structured logging, then make asynchronous delivery state truthful, then move the
settled machinery into its shared module.

**HTTP request layer — plans 22, 28, and 32 (plan 22 defines).** Plan 22 owns
`HttpEnv`, `TokenSource`, and `postJSONWithHeaders`; plan 28 adds `traceparent` through
that helper; plan 32 adds the kanmon `HttpEnv`/token source and consumes the same helper.
No plan may add a second `postJSONWith` variant or store bearer-token text in a
serializable sink config.

**Worker construction — `WorkerEnv`/`AgentRunDeps`/worker executable (EP-1, EP-2,
EP-4).** Three plans add fields (provider selection, approval policy, `ReiConfig`) to
the same constructors and extend plan 37's Settei config. All additions are independent record fields;
merge order is irrelevant, but each plan keeps its additions in a clearly-named block
inside the plan-36 worker composition root so the merges stay mechanical.


## Progress

- [x] (2026-07-31T06:05:00Z) F1 M1–M5: six-package architecture, ownership rules, API
      boundary, and package tests from plan 36 are complete. The repository now has exactly
      `shikigami-core`, `shikigami-api`, `shikigami-server`, `shikigami-workers`,
      `shikigami-migrations`, and `shikigami-client`; `docs/architecture/packages.md` states
      the arrows and executable ownership; `docs/api/openapi.json` is generated from the
      served route proxy; and `shikigami-core/test/Shikigami/PackageArchitectureSpec.hs`
      fails the build on a forbidden sibling edge. 101 tests pass across six suites.
- [ ] F2 M1–M4: every executable uses Settei with explicit bindings, diagnostics,
      secret redaction, and compatibility tests from plan 37.
- [x] (2026-07-31T03:46:15Z) F3 M0: Kioku `v0.2.0.0` published with
      released Keiki 0.4 / Keiro 0.4 bounds and codec-compatibility evidence.
- [ ] F3 M1–M5: verified dependency matrix, released API ports, wire/replay
      fixtures, and full cohort build/test evidence from plan 47.
- [ ] EP-1 M1: provider selection module + loud typed-config construction; stub default; worker
      and run-behavior wired; tests green.
- [ ] EP-1 M2: `Options` threaded through the skill arm; Settei's opaque credential is
      lowered only at the Baikai boundary, with no library environment fallback; capture-seam test.
- [ ] EP-1 M3: `modelUsed` recorded on sessions; live anthropic smoke transcript.
- [ ] EP-2 M1: `ApprovalPolicy` + notifying `ApprovalEnv` (danwa/kizashi asks embed
      the token); policy parsing tests.
- [ ] EP-2 M2: worker consults the policy; loud startup log; danwa-stub integration
      test (park → ask captured → approve → one outbox row).
- [ ] EP-2 M3: `resolve-approval` CLI; token round-trip test.
- [ ] EP-2 M4: manual three-terminal end-to-end transcript recorded.
- [ ] EP-3 M1: `BehaviorInput` threaded into both arms; program arm receives
      payload+prior via `ArgMap`; capture tests.
- [ ] EP-3 M2: payload-aware `recallQuery`.
- [ ] EP-3 M3: `classifyRisk` uses prior; memory-flips-verdict workflow test.
- [ ] EP-4 M1: Settei-backed `ReiConfig`; ReiAction fails loudly or really POSTs;
      `Stubbed` no longer produced.
- [ ] EP-4 M2: `resolvedRecipient` through `SinkIntent`; `Actor` routing honored;
      old-row decode-compat test.
- [ ] EP-4 M3: danwa `topic` visible; `validate` rejects unresolvable
      `recipientFrom`; all fixtures re-validated.


## Surprises & Discoveries

- Fleet conformance audit (2026-07-22): the portfolio repeated package-placement and
  raw-environment conventions in nearly every child plan. Plans 36 and 37 now own those
  cross-cutting decisions once, and downstream plans depend on them.
- Cross-MasterPlan audit (2026-07-22): plan 33 contains no approval-policy work,
  despite the earlier EP-2 integration note saying it might replace the policy source.
  The false edge was removed; approval policy remains owned by plan 14.
- Cross-MasterPlan audit (2026-07-22): approval notification, sink authentication,
  trace propagation, and channel egress all need the same outbound HTTP seam. Making
  plan 22 the owner removes three incompatible proposed helper signatures and prevents
  approval asks from bypassing authentication.
- Cross-MasterPlan audit (2026-07-22): a correct portfolio order must be expressed at
  child-plan granularity. MP-5's versioning foundation and MP-6's observability work
  precede some work in numerically earlier MasterPlans, while MP-6's deployable stack
  remains the final closure step.
- Upstream release update (2026-07-30): Kioku `v0.2.0.0` publishes all five
  packages with Keiki 0.4 / Keiro 0.4 bounds. Plan 47's external release gate
  is closed; its remaining hard predecessor is plan 37.
- Plan 36 implementation (2026-07-31): the fleet dependency graph requires
  `shikigami-api` to depend on `shikigami-core`, which is the reverse of the arrow that
  existed. The declared-agent domain types moved into core and were renamed —
  `Shikigami.Api.Agent` → `Shikigami.Agent.Decl`, `Shikigami.Api.Activity` →
  `Shikigami.Activity`, `Shikigami.Api.RunJob` → `Shikigami.Agent.RunJob` — and
  `Shikigami.Worker` was split into per-loop modules under `shikigami-workers`.
  **Every child plan that cites the old module or file paths is now stale**; the mapping is
  in plan 36's Decision Log, and each plan's own implementation is when to correct it.
  Plans 28 and 31 additionally cite `shikigami-core/src/Shikigami/Telemetry.hs`, which is
  now `shikigami-workers/src/Shikigami/Telemetry.hs`.
- Plan 36 implementation (2026-07-31): health arrived as a real typed route rather than a
  placeholder, because the released `servant-health` package already ships the exact
  `MultiVerb` 200/503 probe surface the API standard requires. Plan 29 now supplies checks
  into a finished seam (`Shikigami.Health.Handler`) instead of building the route tree, and
  the OpenAPI cohort question is settled by that package's own bounds: `openapi-hs 5.0`,
  `servant-openapi-hs 5.1`, `servant 0.20.3`.
- Plan 36 implementation (2026-07-31): all builds and tests must run inside the Nix dev
  shell. A bare `cabal build all` compiles everything and then fails at link with
  `ld: library not found for -lrdkafka`. Use `nix develop --command cabal ...`.


## Decision Log

- Decision: Treat Kioku IR-1 as completed evidence and remove it from plan 47's
  hard dependencies.
  Rationale: `v0.2.0.0` is tagged at
  `5765f98add2a87a356c70793a6ba54375ef5feec`; all five packages are published
  on Hackage and the released bounds admit the selected Keiki/Keiro cohort.
  Date: 2026-07-30

- Decision: Insert plan 47 between Settei adoption and every feature that consumes a
  co-developed runtime library, and use the wave table plus blocker ledger as the portfolio's
  authoritative implementation order.
  Rationale: current released libraries contain coordinated major API, solver, wire-codec,
  and migration changes; independent bumps or numeric MasterPlan order would create invalid
  intermediate states and duplicate adapters.
  Date: 2026-07-30


- Decision: Decompose the review into three foundation plans plus four feature plans:
  architecture (36), configuration (37), dependency cohort (47), model execution (13), human-in-the-loop (14),
  context assembly (15), and sink truth (16), with
  the dependency matrix EP-1=plan 13, EP-2=plan 14, EP-3=plan 15, EP-4=plan 16;
  EP-3 soft-depends on EP-1. The 2026-07-22 revision adds plan 22 as EP-2's
  cross-MasterPlan hard dependency.
  Rationale: each concern yields an independently demonstrable behavior and an
  independent test story; the only real coupling (two shared behavior files) is
  cheaper as an ordered integration point than as a merged mega-plan. See
  Decomposition Strategy for the rejected alternatives.
  Date: 2026-07-22
- Decision: "De-stub" means *honest*, not *stub-free*: deterministic stubs remain the
  default for CI and tests everywhere, but every stub in the production path must be
  loudly labeled (startup logs, recorded `modelUsed`, explicit `Failed` outcomes) and
  every real path must be reachable by configuration.
  Rationale: the entire test suite's determinism depends on the stubs
  (key-free skill runs, fixed program outputs); the review's actual complaint is
  silent success, which labeling and configuration escape hatches fix without
  sacrificing CI.
  Date: 2026-07-08
- Decision: For `ReiAction`, ship loud failure now (`PublishFailed` into the visible
  outbox retry path) behind an off-by-default `sinks.rei.base_url` Settei setting, rather
  than waiting for rei to grow an API or keeping the success-reporting stub.
  Rationale: verified that rei (`/Users/shinzui/Keikaku/bokuno/rei-project/rei`) is a
  CLI-only application with no HTTP surface; the choice was between two honest options
  (fail loudly vs. reject at validate) and failing loudly keeps existing declarations
  deployable while making the gap operationally visible and self-healing once an
  endpoint exists. Details and the validate-time rejection chosen for unresolvable
  `recipientFrom` strategies are in plan 16's Decision Log.
  Date: 2026-07-08
- Decision: Constrain all four plans to additive-only changes to journaled artifacts
  (step names frozen, new JSON fields must be `Maybe`, deprecated constructors kept),
  ahead of plan 24's formal versioning discipline.
  Rationale: the crash/replay tests in
  `shikigami-core/test/Shikigami/AgentWorkflowSpec.hs` encode the current journal
  contract; breaking it now would silently invalidate parked or historical workflows
  and pre-empt MasterPlan 5's migration story.
  Date: 2026-07-08
- Decision: Plan 37 owns configuration through Settei; feature plans may define domain
  settings but may not read the environment or invent precedence rules directly.
  Rationale: one typed composition point provides consistent source ordering,
  diagnostics, validation, and secret redaction across every binary.
  Date: 2026-07-22
- Decision: Plan 36 owns the exact six-package architecture and the public HTTP/API
  boundary used by later plans.
  Rationale: package ownership and API-generation rules must be settled before feature
  plans add executables, configuration, or public endpoints.
  Date: 2026-07-22
- Decision: Coordinate MasterPlans 2–7 through the child-plan waves in Dependency Graph,
  not by imposing a coarse MP-2 → MP-3 → … → MP-7 chain.
  Rationale: the actual hard edges cross initiative numbers in both directions (for
  example plan 14 needs plan 22, plan 23 needs plans 30 and 33, and plan 35 needs plan
  24). A whole-MasterPlan chain would either contain cycles or serialize independent
  work; the child-plan DAG is precise and acyclic.
  Date: 2026-07-22
- Decision: Plan 22 owns the authenticated, header-capable HTTP seam; plan 14 consumes
  it for approval asks, plan 28 extends it with trace propagation, and plan 32 extends
  it for kanmon.
  Rationale: the prior plans proposed incompatible helpers and allowed approval asks to
  bypass outbound authentication. One owner yields one manager/token/header contract.
  Date: 2026-07-22


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Revision Notes

- 2026-07-30: Recorded Kioku `v0.2.0.0` as completion of IR-1 and plan 47 M0,
  removed the upstream release edge from F3, reduced the open blocker ledger
  to seven requests, and made plan 37 the only remaining predecessor of plan 47.
- 2026-07-30: Added plan 47, extended the child-plan DAG through MasterPlans 8–9, recorded
  eight upstream OKF requests, and published the authoritative wave/blocker ledger.

- 2026-07-22: Added the MP-2 through MP-7 child-plan execution waves, made plan 14's
  authenticated-client dependency explicit, removed the false approval-policy edge to
  plan 33, and fixed ownership of the shared HTTP seam. The update prevents numeric
  MasterPlan order from driving implementation and gives contributors a single acyclic
  landing order.
- 2026-07-22: Added plans 36 and 37 as architecture and Settei foundations, rewired all
  MP-2 children to consume them, and replaced the obsolete `lookupEnv` convention.

- 2026-07-31: Marked F1 (plan 36) Complete. The repository now has the six-package
  deployed-service architecture with the dependency arrows asserted by a test, a typed
  public HTTP contract with a generated `docs/api/openapi.json`, and every command
  redistributed to the package owning its runtime role. Recorded the module renames that
  make older child-plan citations stale, the `servant-health` adoption that settles both
  the health route and the OpenAPI cohort, and the Nix dev-shell requirement for all
  builds. F2 (plan 37) is now the next implementable child.
