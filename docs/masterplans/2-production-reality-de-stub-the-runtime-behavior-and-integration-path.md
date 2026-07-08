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
wired to fakes with no configuration escape hatch, each verified in code:

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

When this MasterPlan is complete, the production path is *honest*: an operator can wire
a real Anthropic model with two environment variables and the worker says loudly which
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

The review's findings fall into four distinct functional concerns, and the
decomposition follows the concerns rather than the files: **model execution** (what
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

Plans 14 and 16 share nothing but additive record fields on `WorkerEnv`/`AgentRunDeps`
and CLI flag blocks; they can proceed fully in parallel. Plan 15 is sequenced after 13
by soft dependency (same-file coordination, and the feature is only meaningful with a
real model) but is not blocked by it.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Wire a real model provider into behavior runs | docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md | None | None | Not Started |
| 2 | Approval and human-in-the-loop end to end | docs/plans/14-approval-and-human-in-the-loop-end-to-end.md | None | None | Not Started |
| 3 | Inject recalled memory and trigger payload into behavior context | docs/plans/15-inject-recalled-memory-and-trigger-payload-into-behavior-context.md | None | EP-1 | Not Started |
| 4 | Honest sink handlers: real ReiAction and honored declaration fields | docs/plans/16-honest-sink-handlers-real-reiaction-and-honored-declaration-fields.md | None | None | Not Started |


## Dependency Graph

There are no hard dependencies: every plan compiles and verifies against the current
tree. The one soft dependency is EP-3 on EP-1. Both edit
`shikigami-core/src/Shikigami/Behavior/Run.hs` and `Behavior/Skill.hs`; EP-1 defines
the `BehaviorEnv` shape, the provider/config idiom, and the `Options` parameter on the
skill functions, while EP-3 changes the *input* side (`BehaviorInput` and context
assembly). EP-1 should land first so EP-3 rebases mechanically; if EP-3 must start
early, it implements against the current signatures and treats EP-1's `Options`
parameter as absent (both plans document this). Functionally, EP-3's memory injection
is fully testable against the stub provider (its tests assert the outbound request,
not the reply) but only becomes *meaningful* to users once EP-1's real provider can
read the injected context — hence soft, not hard.

EP-2 (approval) and EP-4 (sink honesty) are independent of everything: EP-2 touches
the approval seam and worker wiring; EP-4 touches the sink dispatch path. Both add
fields to `WorkerEnv`/`AgentRunDeps` and flags to the `worker` CLI command — a
mechanical merge, called out in each plan. All four plans may be worked concurrently
by different contributors provided the EP-1/EP-3 landing order is respected and the
`worker` command's flag additions are merged deliberately.


## Integration Points

**Behavior run seam — `Behavior/Run.hs` and `Behavior/Skill.hs` (EP-1, EP-3).**
Shared artifacts: the `BehaviorEnv` record, `runBehavior`'s signature, and the
`runSkill`/`runSkillWith` signatures. EP-1 owns `BehaviorEnv` (adds `options ::
Options`) and the `Options` parameter; EP-3 owns the new `BehaviorInput { payload,
recalled }` record and the context-assembly logic that renders it. EP-1 defines first;
EP-3 extends. End state:
`runBehavior :: BehaviorEnv -> AgentDecl -> BehaviorInput -> IO (Either RunError Value)`.

**Config-loading idiom — shared with MasterPlan 4's plan 22 (EP-1 defines).**
`docs/plans/22-outbound-authentication-for-sink-clients.md` will add credential fields
to `shikigami-core/src/Shikigami/Sink/Config.hs`. EP-1 establishes the repository's
one config idiom first: a typed record per concern, a single `lookupEnv`-based
resolver returning `Either Text` (fatal at startup on `Left`), and a loud one-line
stderr description of the resolved choice with secrets rendered through baikai's
redacting `ApiKeySource`. Plan 22 must consume this idiom, not invent a second one.
EP-2's `resolveApprovalPolicy` and EP-4's `ReiConfig` already follow it inside this
MasterPlan.

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

**Approval policy interface — vs. MasterPlan 7's plan 33 (EP-2 defines).**
`docs/plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md` may
move approval policy into `schema/Agent.dhall`. EP-2 therefore keeps policy behind the
small `ApprovalPolicy` record and one `policyApprovalEnv` constructor: plan 33 swaps
the policy *source* (Dhall instead of environment) without touching the park/notify/
resolve machinery or the CLI.

**Sink outcome semantics — vs. MasterPlan 3's plan 19 (EP-4 feeds it).**
`docs/plans/19-sink-delivery-truth-and-downstream-idempotency.md` owns retry ceilings,
dead-lettering, and delivery accounting for the outbox path. EP-4's contribution is
upstream of that: it stops minting fake `PublishSucceeded` outcomes so plan 19 has
truthful failures to manage. EP-4 must not implement its own retry policy beyond what
`publishClaimedOutbox` already does.

**Worker construction — `WorkerEnv`/`AgentRunDeps`/`Cli.hs` worker flags (EP-1, EP-2,
EP-4).** Three plans add fields (provider selection, approval policy, `ReiConfig`) and
flags/env-reads to the same constructors. All additions are independent record fields;
merge order is irrelevant, but each plan keeps its additions in a clearly-named block
inside `runWorkerCmd` so the merges stay mechanical.


## Progress

- [ ] EP-1 M1: provider selection module + loud env construction; stub default; worker
      and run-behavior wired; tests green.
- [ ] EP-1 M2: `Options` threaded through the skill arm with explicit
      `ApiKeyEnv "ANTHROPIC_API_KEY"`; capture-seam test.
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
- [ ] EP-4 M1: `ReiConfig`/`--rei-url`; ReiAction fails loudly or really POSTs;
      `Stubbed` no longer produced.
- [ ] EP-4 M2: `resolvedRecipient` through `SinkIntent`; `Actor` routing honored;
      old-row decode-compat test.
- [ ] EP-4 M3: danwa `topic` visible; `validate` rejects unresolvable
      `recipientFrom`; all fixtures re-validated.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Decompose the review's findings into four child plans along functional
  concerns (model execution, human-in-the-loop, context assembly, sink truth), with
  the dependency matrix EP-1=plan 13, EP-2=plan 14, EP-3=plan 15, EP-4=plan 16; no
  hard dependencies; EP-3 soft-depends on EP-1.
  Rationale: each concern yields an independently demonstrable behavior and an
  independent test story; the only real coupling (two shared behavior files) is
  cheaper as an ordered integration point than as a merged mega-plan. See
  Decomposition Strategy for the rejected alternatives.
  Date: 2026-07-08
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
  outbox retry path) behind an off-by-default `--rei-url` real-client flag, rather
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
- Decision: EP-1 defines the environment-variable config idiom; EP-2 and EP-4 follow
  it within this MasterPlan, and plan 22 (MasterPlan 4) is directed to reuse it.
  Rationale: one config style keeps credentials out of argv and logs (baikai's
  redacting `ApiKeySource` is the model) and makes later config surfaces (plan 31's
  deployable stack) a rename problem instead of a redesign.
  Date: 2026-07-08


## Outcomes & Retrospective

(To be filled during and after implementation.)
