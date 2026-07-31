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
| F2 | Adopt Settei configuration across Shikigami binaries | docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md | F1 | None | Complete (2026-07-31), except the migration executable — see Surprises |
| F3 | Upgrade Shikigami to the coherent July 2026 dependency cohort | docs/plans/47-upgrade-shikigami-to-the-coherent-july-2026-dependency-cohort.md | F2 | plan 38 integration | Complete (2026-07-31) |
| 1 | Wire a real model provider into behavior runs | docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md | F3 | None | Complete (2026-07-31), except the live smoke — see Surprises |
| 2 | Approval and human-in-the-loop end to end | docs/plans/14-approval-and-human-in-the-loop-end-to-end.md | F3; cross-MP: plans 17 and 22 | EP-1 | Not Started |
| 3 | Inject recalled memory and trigger payload into behavior context | docs/plans/15-inject-recalled-memory-and-trigger-payload-into-behavior-context.md | F3 | EP-1 | Complete (2026-07-31) |
| 4 | Honest sink handlers: real ReiAction and honored declaration fields | docs/plans/16-honest-sink-handlers-real-reiaction-and-honored-declaration-fields.md | F3 | None | Complete (2026-07-31) |


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

As implemented (2026-07-31), both plans have landed and this seam is settled.
`BehaviorEnv` and `runBehavior` are in `shikigami-core/src/Shikigami/Behavior/Run.hs`;
`BehaviorInput` is in `shikigami-core/src/Shikigami/Behavior/Input.hs` and re-exported
from `Behavior/Run.hs`, because `Run` imports `Skill` and `runSkill`/`runSkillWith` take
the input record too. A later plan adding to this seam extends `BehaviorInput` rather
than adding a parameter, uses `triggerOnly` at any call site with no memory to offer,
and keeps the skill arm's memory rendering local to `Behavior/Skill.hs` — importing
`Shikigami.Agent.Run.renderMemoryRecord` would close a cycle, so the one-line format is
duplicated there on purpose and marked in both places.

**Configuration boundary — plan 37 defines; all feature plans consume.**
`docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md` owns stable
keys, typed strict records, explicit environment bindings, source precedence,
redaction, diagnostics, and exit semantics. Plans 13, 14, 16, 22, 28–32, and 34 must
declare Settei `Setting`s and extend the process-level application config rather than
calling `getEnv`/`lookupEnv` or building one-off parsers. Secrets are credential
references or redacted secret types and never gain `Show`, JSON, or log rendering.
Standard OpenTelemetry environment variables remain SDK-owned as plan 37 documents.

As implemented (2026-07-31), the shared artifacts are concrete. `AppConfig` and the
`Config AppConfig` declaration live in `shikigami-core/src/Shikigami/App/Config.hs`; source
assembly, the five diagnostics, and exit codes 2/3/4 live in
`shikigami-core/src/Shikigami/App/Config/Load.hs`. A consuming plan adds a stable key, a
`Setting` with a bounded decoder, a field on `AppConfig`, a line in `appConfig`, an
environment binding, and entries in the key and binding lists of
`shikigami-core/test/Shikigami/AppConfigSpec.hs` — the six-step recipe is at the end of
`docs/operations/configuration.md`. Three rules bind them: declare a key only when code
reads it, give every public setting a renderer, and express a per-binary requirement as a
`Role` entry rather than a separate declaration. Operator flags are added with
`Settei.Optparse.namedOption` aimed at a declared key, never as a private parser.

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
- [x] (2026-07-31T05:55:00Z) F2 M1–M4: nine of the ten executables resolve one typed
      `AppConfig` through Settei with explicit environment bindings, fixed precedence,
      rejected unknown keys, structurally redacted secrets, all five diagnostic modes, and
      exit codes 2/3/4. `docs/operations/configuration.md` and
      `config/shikigami.example.yaml` document the surface; 31 conformance cases in
      `shikigami-core/test/Shikigami/AppConfigSpec.hs` pin precedence, strictness, the
      accepted key and binding lists, and the absence of a planted secret from every
      rendering. 132 tests pass across seven suites.
- [ ] F2 remaining: `shikigami-migrate` resolves `DATABASE_URL` with `lookupEnv` instead of
      the shared `AppConfig`. The codd half of this item is closed — F3 (plan 47) moved the
      whole migration stack to pg-migrate, so the `CODD_*` contract no longer exists
      anywhere (`shikigami-migrations/app/Main.hs`, `Justfile:31,38`, `cabal.project:74-79`).
      What remains is only the Settei unification, still blocked by the cabal package cycle
      (see Surprises & Discoveries); reassigned to plan 38, which owns the migration CLI and
      can restructure the package boundary.
- [x] (2026-07-31T03:46:15Z) F3 M0: Kioku `v0.2.0.0` published with
      released Keiki 0.4 / Keiro 0.4 bounds and codec-compatibility evidence.
- [x] (2026-07-31) F3 M1–M5: `cabal.project` selects the whole cohort from Hackage by
      version with no co-developed `allow-newer`; every call site the cohort moved is
      ported; `docs/dependency-cohort.md` records the matrix, tag commits, canonical
      `mori://` project URIs, and compatibility evidence; wire, provider-failure, and
      migration-idempotence fixtures are in place. 157 tests pass across seven suites
      under `-j1`, twice.
- [x] (2026-07-31) EP-1 M1: `ProviderSelection` and its three keys are declared in the
      shared `AppConfig`; `Shikigami.Behavior.Provider` owns `newBehaviorEnvFor`, which
      cannot build an environment without announcing the provider; the worker,
      `run-behavior`, and `agent-run` are wired; the stub remains the default. Asking for
      anthropic without a credential, or with an unknown model, exits 4 before any resource
      is opened — including under `--check-config`.
- [x] (2026-07-31) EP-1 M2: `BehaviorEnv.options` threaded through the skill arm; the
      resolved `SecretText` is lowered to `ApiKeyLiteral` at one boundary, with baikai's
      environment fallback deliberately unused; capture-seam test confirmed to fail against
      the code it replaces.
- [x] (2026-07-31) EP-1 M3 (durable half): `modelUsed` recorded at both session-completing
      seams; the crash-resume case asserts `Just "stub-v1"` on the completed row.
- [ ] EP-1 M3 (live half): live anthropic smoke transcript. Not performed — no credential
      available; recorded as unproven in plan 13 rather than assumed.
- [ ] EP-2 M1: `ApprovalPolicy` + notifying `ApprovalEnv` (danwa/kizashi asks embed
      the token); policy parsing tests.
- [ ] EP-2 M2: worker consults the policy; loud startup log; danwa-stub integration
      test (park → ask captured → approve → one outbox row).
- [ ] EP-2 M3: `resolve-approval` CLI; token round-trip test.
- [ ] EP-2 M4: manual three-terminal end-to-end transcript recorded.
- [x] (2026-07-31) EP-3 M1: `BehaviorInput` threaded into both arms; program arm
      receives payload+prior via `ArgMap`; capture tests, confirmed to fail against the
      code they replace. The record lives in `Shikigami.Behavior.Input` and is
      re-exported from `Behavior/Run.hs` — see Surprises.
- [x] (2026-07-31) EP-3 M2: payload-aware `recallQuery` — agent name, behavior kind,
      declaration description, and the payload's string leaves one level deep, capped at
      512 characters.
- [x] (2026-07-31) EP-3 M3: `classifyRisk` takes `[MemoryRecord]` and uses prior; the
      same calm payload the low-risk workflow case completes on instead emits a
      high-risk signal when an escalation is in memory.
- [x] (2026-07-31) EP-4 M1: `sinks.rei.base_url` declared with no default; ReiAction fails
      with a message naming the intention and the key, or really POSTs a `ReiActionReq`
      carrying the deterministic dedup key; `Stubbed` deprecated and no longer produced.
      Both halves asserted — the handler's outcome, and that outcome's effect on the
      outbox verdict.
- [x] (2026-07-31) EP-4 M2: `resolvedRecipient` through both copies of `SinkIntent`;
      `Actor` routing honored, the two directory strategies warn; old rows decode /and/ the
      pinned pre-upgrade bytes are unchanged, because the record now encodes with
      `omitNothingFields`.
- [x] (2026-07-31) EP-4 M3: danwa `topic` opens a fresh conversation; `validate` rejects a
      directory strategy with no `defaultRecipient`; every shipped manifest re-validated.


## Surprises & Discoveries

- Plan 15 implementation (2026-07-31): **a type that an existing function's new parameter
  introduces belongs in a module the function's /callees/ can also import.** This
  MasterPlan's Integration Points said EP-1 owns `BehaviorEnv` in `Behavior/Run.hs` and
  EP-3 adds `BehaviorInput` there. That is not implementable: `Run.hs` imports
  `Skill.hs`, and EP-3 gives `runSkill`/`runSkillWith` the new parameter, so `Skill.hs`
  needs the type. `BehaviorInput` lives in `shikigami-core/src/Shikigami/Behavior/Input.hs`
  and is re-exported from `Shikigami.Behavior.Run`, so the interface every consumer sees
  is the one this MasterPlan documents. **Plans 12, 17, and 34 all add parameters to these
  same functions and should check the callee side before choosing a module.**
- Plan 15 implementation (2026-07-31): **the `Flow` arm never reaches `runBehavior`, so a
  flow run now recalls twice.** `runBehaviorStep` dispatches `Flow` to `runFlowBehavior`
  before the `runBehavior` call, and a flow recalls for itself through the `Memory`
  capability, which calls the same `recallPriorLearnings`. The workflow's journaled
  `recall` step still runs, and its result now goes to the behavior — which for a flow is
  nobody. Not a correctness problem; a duplicated query and a second place memory enters
  the same run. **Plan 27, which consolidates the duplicated agent-run and flow dispatch
  paths, inherits this alongside the duplicated `SinkIntent`.**
- Plan 16 implementation (2026-07-31): **`SinkIntent` is defined twice, and the publisher
  decodes both copies with one of them.** `Shikigami.Agent.Workflow` and
  `Shikigami.Flow.SinkOutbox` each carry the record because the flow module cannot import
  the workflow module without a cycle; `publishSinkIntent` decodes rows from both paths
  with the workflow's copy. A field added to one and not the other is dropped in transit
  with nothing to notice — the flow path would have journaled a resolved recipient the
  publisher never read. `Shikigami.WireCompatSpec` now asserts the two encoders produce
  identical bytes. **Plan 27 inherits this as a concrete reason to consolidate**, along
  with `Agent.Workflow.enqueueSinkIntentStep`, which is exported, duplicates the flow
  module's function, and is called by nothing.
- Plan 16 implementation (2026-07-31): **a new field on a journaled or outboxed record
  should be added with `omitNothingFields`, not by rewriting the pinned byte fixture.**
  Aeson emits `"field":null` by default, which would have changed the encoder and forced
  `WireCompatSpec`'s pre-upgrade bytes to be edited — discarding the evidence they exist to
  preserve. Encoding with `omitNothingFields` makes a record that does not use the new
  field byte-identical to one written before it existed. **Plans 19, 22, 27, and 35 all add
  fields to durable records and should do the same.**
- Plan 16 implementation (2026-07-31): the plan's fixture-revalidation loop expects only
  `agents/broken.dhall` to fail. **`agents/detectors/schema.dhall` fails too, and always
  did** — it is a retired tombstone that is a record type rather than a manifest, rejected
  on the Dhall annotation before any sink check. Not a regression; recorded so the next
  plan running that loop does not investigate it.
- Plan 13 implementation (2026-07-31): **a cross-key requirement belongs in the Settei
  declaration, not in a function beside it.** Plan 13 specified
  `resolveProviderSelection :: AppConfig -> Either ConfigError ProviderSelection`. Settei's
  `whenEq` expresses the same rule as a conditional branch, so
  `credentials.providers.anthropic.api_key` is `required` only when
  `behavior.provider=anthropic` — which makes `--check-config` catch it, makes
  `--describe-config` print it as a condition row, and lets the resolved type carry the
  invariant so no consumer re-checks it. **Every later plan with a "this key is required
  when that one says X" rule should do this** rather than add a validation pass; plans 14,
  16, 22, and 32 all have credentials shaped that way. The six-step recipe in
  `docs/operations/configuration.md` now has a worked conditional example above it.
- Plan 13 implementation (2026-07-31): **a setting whose valid values come from a library
  catalog should decode against the catalog.** `behavior.model` decodes through
  `enumDecoder` over `Baikai.Models.Generated.allModels`, so `AppConfig` holds a `Model`,
  an unknown id is an exit-4 decode failure listing the real accepted set, and the list
  cannot drift from baikai. The cost is that `Shikigami.App.Config` imports baikai. **Plans
  12 and 34, which also select models, inherit both the pattern and the precedent that a
  library type in `AppConfig` is acceptable when it is what makes validation real.**
- Plan 13 implementation (2026-07-31): **`--describe-config` on `shikigami-run-behavior`
  exits 2 instead of printing the schema**, because `--agent` is a required
  `optparse-applicative` option and parsing fails before any diagnostic runs. This breaks
  plan 37's promise that all five diagnostics answer anywhere. Pre-existing and confined to
  that one binary; the fix is to make `--agent` optional and demand it after the diagnostic
  branch, the way `requireDatabaseUrl` demands a connection string at the point of use.
  **Unowned — the next plan touching that role's arguments should take it.**
- Plan 13 implementation (2026-07-31): the live Anthropic smoke **was not performed** — no
  credential exists in this environment. Everything checkable without a key was checked,
  including that the resolved credential reaches the completion call; what remains unproven
  is the round trip itself. Recorded as unproven in plan 13 rather than assumed, and it is
  a single command to close.
- Plan 47 implementation (2026-07-31): **the codd migration path could not be deferred to
  plan 38.** `kiokuMigrations` in Kioku 0.2 is a pg-migrate `MigrationComponent`, not a codd
  migration list, so there was nothing left for `shikigami-migrations` to append to. The
  whole migration API — library, executable, and `test-support` — moved to pg-migrate here,
  and the codd / hasql-migration / hasql-notifications forks were removed. **Plan 38's scope
  narrows to what actually needs a rollback story:** importing an existing codd ledger into
  the native one, and the operational cutover. The migration filenames and their
  `-- codd: in-txn` headers are preserved verbatim as that import's payload evidence. The
  operator contract changed: `CODD_*` → `DATABASE_URL`, and `shikigami-migrate` now takes a
  subcommand (`up`, `status`, `plan`, `verify`, `repair`, …).
- Plan 47 implementation (2026-07-31): **Kioku 0.2 requires the host that applies the
  migration plan to reconcile keiro's `keiro_read_models` registry.** Registration no longer
  happens on first query and `registerReadModel` only inserts, so a stale row makes every
  query for that model fail closed. `Shikigami.Migrations.reconcileShikigamiReadModels` runs
  after a successful `up`. **Any plan that adds a Kioku read model inherits this** — it is a
  live production concern, not an upgrade artifact.
- Plan 47 implementation (2026-07-31): **the skill arm was rendering Baikai provider
  failures as successful empty replies.** Baikai 0.4 reports failure in band, and
  `runSkillWith` read only the assistant text, so a rate limit or a missing credential
  produced `{"reply": ""}`, was recorded as a learning, and dispatched sinks. Now translated
  to `RunError.ProviderFailed` carrying baikai's `isRetryable`. **This is EP-1 and plan 17
  territory that landed early because the cohort exposed it**: plan 13 still owns provider
  selection, plan 17 still owns what the worker does with the retryable flag.
- Plan 47 implementation (2026-07-31): **the only dependency that actually blocked was the
  unreleased commit-pinned one.** `handan-core` did not compile against shikumi 0.3 /
  shikumi-trace 0.2, and its HEAD had the same code; it needed an upstream fix
  (`mori://shinzui/handan` at `8e98b0a955f908f70657c04f384b6286e4967422`) before the pin
  could move. Every released cohort member resolved and compiled without incident. Worth
  carrying into the next bump.
- Plan 47 implementation (2026-07-31): Shikigami's `shikigami_run_jobs` queue is **not**
  scaffolded by `keiro-dsl`, so Keiro 0.4's versioned queue envelope does not reach it and
  no drain gate was needed. **Plan 39 inherits this as a live constraint**: moving the queue
  to the envelope is a wire change that needs a drain or a transitional decoder.
- Plan 47 implementation (2026-07-31): Keiki 0.4's new `checkStateChangingEpsilon` fires on
  every edge of the at-risk-customer lifecycle transducer. It is a rendered specification,
  not an event source, so that one check is scoped off with the reasoning at the definition.
  **Plan 39 owns giving the lifecycle a real emitted-event type** if it should be validated
  under the full option set.
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
- Plan 37 implementation (2026-07-31): **`shikigami-migrate` cannot consume the shared
  configuration declaration, and every later plan that wants to configure a migration step
  inherits this.** `shikigami-core`'s test suite depends on
  `shikigami-migrations:test-support`, so the reverse edge makes the two packages mutually
  dependent and cabal's solver — which detects cycles at package rather than component
  granularity — refuses the whole project with
  `rejecting: shikigami-core:*test (cyclic dependencies)`. The migration executable therefore
  reads its one variable itself, documented at its call site. Plan 38 owns the migration CLI
  and is the right place to restructure the boundary.
  Superseded in part (2026-07-31): when written, that one variable was codd's `CODD_*`
  contract. F3 (plan 47) moved the migration stack to pg-migrate, so the executable now reads
  `DATABASE_URL`. **The cycle itself is unchanged and still binding** — it is a property of
  the package graph, not of the migration library, so any later plan wanting configuration in
  `shikigami-migrations` inherits it regardless of which migration tool is in use.
- Plan 37 implementation (2026-07-31): the configuration surface is **one** `AppConfig`
  shared by every binary, not one per binary, with per-binary requirements expressed as a
  `Role` and checked after resolution. Plans 13, 14, 16, 22, 28–32 and 34 extend that single
  declaration in `shikigami-core/src/Shikigami/App/Config.hs`; the six-step recipe is at the
  end of `docs/operations/configuration.md`. Two conventions bind them. Only declare a key
  something reads — `--describe-config` is a promise, and an accepted key nothing consults
  breaks it, which is why this plan left `behavior.*`, `approval.*`, `credentials.*`,
  `health.port`, `worker.run_timeout_seconds` and `http.request_max_bytes` to the plans that
  introduce the code reading them. And give every public setting a renderer, or
  `--explain-config` prints `<derived>` instead of the defaulted value.
- Plan 37 implementation (2026-07-31): operator-facing flags are not an alternative to
  settings. `Settei.Optparse.namedOption` makes a flag an ordinary command-line source aimed
  at a declared key, so `--broker X` and `--set kafka.broker=X` are the same thing and
  cannot disagree about defaults or decoders. Every plan adding a flag for something that is
  really deployment configuration should do this rather than introduce a parser.
- Plan 37 implementation (2026-07-31): `cabal test all` run in parallel intermittently fails
  `shikigami-core-test` while every suite passes under `-j1` — the database-backed suites
  each stand up an ephemeral PostgreSQL and contend. Trust `-j1` when judging a run.


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

- 2026-07-31: Corrected the F2-remaining record, which had gone stale. Its Progress entry
  and the plan 37 Surprises entry both still said `shikigami-migrate` uses codd's `CODD_*`
  contract; F3 (plan 47) removed codd from the repository entirely, and the executable has
  read `DATABASE_URL` and driven pg-migrate subcommands since. Verified in the working tree
  rather than inferred: `shikigami-migrations.cabal` names only `pg-migrate*` packages,
  `shikigami-migrations/app/Main.hs` calls `lookupEnv "DATABASE_URL"` and
  `runMigrationCommand`, `Justfile:31,38` pass `DATABASE_URL`, `cabal.project:74-79` records
  the removal of codd and its two forks, and every surviving `codd` string in code is prose
  explaining the absence. F2's open item is now stated as what it actually is — the
  executable does not resolve through the shared `AppConfig` — and the cabal package cycle
  is marked as the durable cause, independent of which migration library is in use. No code
  changed. **`docs/plans/38-...md:80,139` still describes rewriting the `CODD_*` surface as
  its own work; that scope narrowing is already recorded in this MasterPlan's plan 47
  Surprises entry and should be absorbed into plan 38 when it is implemented.**

- 2026-07-31: Marked EP-3 (plan 15) Complete. The third runtime lie is closed: both
  executable behavior arms now receive the trigger payload and the memories the journaled
  `recall` step returned, the recall query is built from the agent's description and the
  payload's own words instead of a constant string, and the at-risk-customer example
  flow's verdict demonstrably changes when it remembers a prior escalation on the same
  subject. Recorded two findings other plans depend on: a type introduced by a new
  parameter on an existing function must live where the function's callees can import it
  too — this MasterPlan's own Integration Points asked for something that would have
  closed an import cycle, and plans 12, 17, and 34 touch the same functions; and the
  `Flow` arm never passes through `runBehavior`, so a flow run now issues two recall
  queries, which plan 27 inherits along with the duplicated `SinkIntent`. The Behavior
  run seam integration point is now settled and described as implemented.
  **EP-2 (plan 14) is the only remaining child of this MasterPlan, and it is not yet
  implementable** — its hard dependencies are plans 17 and 22, neither of which has
  landed.

- 2026-07-31: Marked EP-4 (plan 16) Complete. The fourth runtime lie is closed: a
  `ReiAction` either really delivers or really fails into the outbox retry path, and the
  three declaration fields that were parsed and discarded are now honored (`Actor` routing,
  danwa `topic`) or refused up front (`SubjectOwner`/`AreaOwner` with nothing to fall back
  to). `Stubbed` survives only as a decoder for historical journals. Recorded three
  findings other plans depend on: `SinkIntent` is duplicated across the agent-run and flow
  paths with the publisher decoding both through one copy — now guarded by a byte-equality
  test and left to plan 27 to consolidate, together with a dead `enqueueSinkIntentStep`; a
  field added to a durable record should use `omitNothingFields` so the pinned wire fixture
  stays true rather than being rewritten, which plans 19, 22, 27, and 35 will each need;
  and `agents/detectors/schema.dhall`'s validation failure is pre-existing and not a sink
  error. Plan 19 now has truthful failures to manage, and plan 22 has settled client shapes
  to wrap. **EP-3 (plan 15) is the only remaining child of this MasterPlan that is
  implementable** — EP-2 (plan 14) still waits on plans 17 and 22.

- 2026-07-31: Marked EP-1 (plan 13) Complete except the live smoke. The first of the four
  runtime lies is closed: `behavior.provider` selects the provider, the stub is still the
  default but can no longer run unannounced, the resolved credential travels to the model
  call instead of the handler finding one in the environment, and every completed session
  records which model answered it. Recorded three findings other plans depend on: a
  cross-key requirement belongs in the Settei declaration rather than beside it (plans 14,
  16, 22, 32 all have credentials shaped that way); a catalog-valued setting should decode
  against the catalog (plans 12 and 34); and `--describe-config` on
  `shikigami-run-behavior` is broken by a required `--agent`, which is unowned. EP-3 (plan
  15) and EP-4 (plan 16) are both implementable now; the EP-1 → EP-3 landing order this
  MasterPlan asked for is satisfied.

- 2026-07-31: Marked F3 (plan 47) Complete. Shikigami now builds against one coherent set of
  published releases selected by version rather than commit, with no `allow-newer` between
  co-developed packages, and 157 tests pass across seven suites. Recorded the four findings
  that change other plans' assumptions: plan 38's scope narrows to the ledger import because
  the migration API port landed here; every plan touching Kioku read models must reconcile
  the registry; plan 39 inherits both the un-enveloped run-job queue and the lifecycle
  transducer's scoped validation; and plans 13/17 inherit an in-band provider failure that is
  now visible instead of silent. EP-1 (plan 13) is the next implementable child.

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

- 2026-07-31: Marked F2 (plan 37) Complete except for the migration executable. Nine of the
  ten binaries now resolve one typed `AppConfig` through Settei, with all five diagnostic
  modes, reserved exit codes, rejected unknown keys, and a planted-secret conformance test.
  Recorded the cabal package cycle that blocks `shikigami-migrate` and reassigned that piece
  to plan 38; recorded the conventions later plans must follow when extending the single
  declaration, and the parallel-test caveat. F3 (plan 47) is now the next implementable
  child.
- 2026-07-31: Marked F1 (plan 36) Complete. The repository now has the six-package
  deployed-service architecture with the dependency arrows asserted by a test, a typed
  public HTTP contract with a generated `docs/api/openapi.json`, and every command
  redistributed to the package owning its runtime role. Recorded the module renames that
  make older child-plan citations stale, the `servant-health` adoption that settles both
  the health route and the OpenAPI cohort, and the Nix dev-shell requirement for all
  builds. F2 (plan 37) is now the next implementable child.
