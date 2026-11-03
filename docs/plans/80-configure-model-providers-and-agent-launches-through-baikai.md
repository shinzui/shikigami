---
id: 80
slug: configure-model-providers-and-agent-launches-through-baikai
title: "Configure model providers and agent launches through Baikai"
kind: exec-plan
created_at: 2026-10-06T14:02:35Z
intention: "intention_01m47m186wenjt8ecxny19rm3m"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-06T14:02:35Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-06T14:10:30Z
      mode: "other"
      note: "Ground initial provider and launch integration plan in current Shikigami wiring and verified released Baikai surfaces"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-06T14:14:42Z
      mode: "implement"
      note: "Begin released adapter contract verification and implementation"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-02T23:45:26Z
      mode: "update"
      note: "Refresh released Baikai lifecycle status, 0.10 model/reasoning/cache migration, dependency prerequisites and current governed execution owners"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-03T00:23:44Z
      mode: "implement"
      note: "Implement independent governed endpoint and cache binding settings; verify released-cohort prerequisite"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-03T13:17:45Z
      mode: "implement"
      note: "Adopt the released Shikumi IR-5 cohort and qualify public judgment streaming with acknowledged durable outcomes"
---

# Configure model providers and agent launches through Baikai


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Distill implemented architectural decisions into `docs/adr/` before completion.


## Purpose / Big Picture


An operator can configure the model provider, transport, model, reasoning effort, and supported execution settings, with Baikai performing the provider call or agent launch. The target background reporter can use an already authenticated Codex or Claude CLI without an HTTP API key after consumer lifecycle and confinement qualification. The current Cabal candidate adopts Baikai 0.10 and passes inherited-group cancellation on Darwin; background CLI responses still require enforced deadlines, bounded retained output and descendant confinement. Shikumi 0.5.1.0 now supplies public judgment-stream support and passes the application parity/failure fixtures. Remaining work includes the rest of the consumer wire and error matrix, Linux qualification, final immutable package qualification, and CLI configuration and dispatch after its contracts qualify. The HTTP and foreground integration is independently implemented. A separate foreground command can open an interactive session or run an unattended named Baikai coding job. Effective configuration explains the selected surface and settings before a model is called.

The foundation already exists: [plan 13](13-wire-a-real-model-provider-into-behavior-runs.md) installed a shared Baikai builder and typed provider configuration. At authoring revision `f740895`, Shikigami exposed only `stub` and Anthropic HTTP; the completed part of this plan added OpenAI Chat Completions, OpenAI Responses and foreground launches. The 2026-11-02 refresh below distinguishes that installed baseline from newer upstream releases. Refresh the model catalog and compatibility rules through Baikai while preserving exact operator selections, pinned descriptors and the existing Anthropic default unless an operator explicitly changes them.

“Everything configurable through Baikai” means model and agent execution choices supported by the selected Baikai release. Database, authorization, memory, delivery, manifests and workflow supervision retain their existing owners. A model response, an attended terminal session and a coding process have different results and authority. This plan exposes all three honestly.

The expanded scope also adopts Baikai's structured answers and TypeSafe judgments. An operator can select a TypeSafe model for a declared decision slot and run a supplied-ticket example that returns an urgency predicate, issue category and severity with their probability data. Baikai owns the provider request and raw answer; Shikumi owns typed decisions and local thresholds, cuts and weights; Shikigami owns authorization, durable results and restart behavior. Operators can also explicitly disable reasoning on supported generative models and request supported shared-prefix caching. The end result must demonstrate each capability through an application consumer, not only compile newer dependencies.


## Progress


- [x] (2026-10-06 14:40 UTC) M1 released API/version inventory and bounded fake adapter probes complete; both batch adapters leave a child alive after cancellation.
- [ ] M1 remaining: adopt a compatible released Baikai cohort, prove positive cancellation locally, and qualify reporter deadlines, output handling and confinement. The owning cancellation fix is published; the application upgrade and these consumer proofs remain undone.
- [x] (2026-10-06 14:40 UTC) M2 independent HTTP typed options, conditional credentials, catalog decoding and redacted reports implemented; core suite 425 checks pass.
- [ ] M2 remaining: CLI model/config resolution after M1; update model/output compatibility, reasoning-off and cache-policy checks when adopting the latest release.
- [x] (2026-10-06 14:40 UTC) M3 three HTTP APIs dispatch through the shared builder, with pre-request compatibility and existing actual-tuple profile gates. Local Chat and Responses wire fixtures pass.
- [ ] M3 remaining: two CLI response handlers and positive confinement/profile-tuple qualification after M1, retaining invocation-local registries and pinned decision/assignment bindings.
- [x] (2026-10-06 14:40 UTC) M4 foreground interactive resolver and public unattended parser mounted. All 37 agent checks pass, including operator-ceiling and exit semantics.
- [x] (2026-10-06 14:49 UTC) M4 real attended Codex 0.160.1 terminal opened, returned the public marker with key environment variables absent, and closed with propagated exit 0; no durable/background claim.
- [x] (2026-10-06 14:40 UTC) M5 HTTP/foreground docs and ADR 0040 written. Isolated full Cabal build, core 425, worker 88, server 47, PostgreSQL 197 and migration smoke checks pass. Frozen export has only intended Baikai upgrades plus agent/KDL additions.
- [x] (2026-10-06 14:57 UTC) M5 committed-descriptor full build and unchanged keiro gate pass at `3280233` against `9872e2d`: no findings, replay-neutral, no regeneration drift and 37 conformance assertions. Final worker 88, server 47 and PostgreSQL 197 checks pass.
- [x] (2026-10-06 15:48 UTC) Final endpoint correction at `9ce65b2`: full committed-descriptor build, core 425, agent 37 and unchanged workflow gate pass. All three HTTP APIs refuse plaintext under HTTPS-only profiles and admit it only with explicit HTTP permission.
- [x] (2026-10-06 16:30 UTC) M5 all five immutable role targets build at `9ce65b2`; 11 installed checks pass outside the checkout. Exact outputs/inputs are in `docs/evidence/baikai-execution/installed-checks.json`. Superseded builds and corrected smoke-harness attempts are recorded separately.
- [x] (2026-10-06 15:03 UTC) M4 mounted unattended read-only Codex job returned the public marker and exit 0 under a separate operator ceiling and 60-second deadline. Verified repository flag is `--config`.
- [ ] M5 remaining: repeat affected regression, durable-codec and installed-role qualification for the adopted cohort; October evidence does not qualify an upgrade.
- [ ] M6: authenticated batch reporter remains blocked by application adoption and lifecycle/confinement qualification. Live HTTP alternatives are untested; no service readiness is claimed.
- [ ] M7: structured input/answer content, response-cache roundtrips and versioned application replay preserve values, probability distributions, optional confidence and method without treating cached evidence as a new call.
- [ ] M8: an operator-selected TypeSafe decision runs through real public Baikai HTTP and Shikumi interpretation in deterministic fixtures, retains raw and derived results across restart, and has a runnable supplied-ticket Flow example.

Refresh handoff (2026-11-02 UTC): this is a plan update, with no dependency or runtime change. Hackage and upstream tags verify core 0.10.0.0, Claude/OpenAI 0.7.3.0 and agent 0.2.0.4 as the latest normal releases. A coherent latest-version solve is not yet established: published Shikumi descriptors require Baikai below 0.9, and the selected Kioku 0.12.0.0 does too. Resolve those owning-package prerequisites before promoting the latest target. See the release refresh in Context and Orientation.

Scope handoff (2026-11-02 UTC): the user authorized adoption of every feature discussed, including structured answers and TypeSafe judgments. M7 and M8 are now required deliverables. The earlier generative-only scope decision is superseded; current dependency prerequisites and October qualification evidence retain their meaning.

Implementation handoff (2026-11-03 UTC): the published-release prerequisite is now reproduced with an isolated Cabal dry-run after refreshing the index, rather than inferred solely from descriptor text. See [release evidence](../evidence/baikai-execution/release-prerequisite.json) and FRIC-46. The target pair `baikai ==0.10.0.0` and `shikumi ==0.4.1.1` cannot resolve at `2026-11-02T23:00:00Z`; application pins remain unchanged. Independent M2/M3 work adds optional decision-binding endpoint/cache settings and forbids program overrides of pinned retention. All 52 focused decision checks pass through the isolated committed-descriptor project, including the real public Anthropic adapter, all retention modes, zero-dispatch HTTPS-only refusal, immutable identity and complete/stream conflicts. Broader regression passes core 666, agent 37, server 105, migration smoke 11, serial PostgreSQL 543 and serial worker 281 checks at source checkpoint `340fd633`. The committed-tree keiro gate passes 177 conformance assertions with a replay-neutral verdict and no generated drift. Migration schema isolation and strict friction validation pass. FRIC-47 accepts the established serial database-backed test profile after reproducing known parallel-fixture failures; the plan commands now specify it. M1 adoption, the latest shared-prefix/reasoning behavior, CLI promotion and M7/M8 still require the released compatible Shikumi consumer; no milestone is marked complete by this partial work.


Resume handoff (2026-11-03 UTC, after Shikumi publication): Hackage and upstream tags now verify Shikumi 0.5.0.0, tools 0.4.2.0, cache 0.2.1.0, trace/eval 0.3.1.0 and trace-otel 0.1.3.0 at `b9b7a73f276ec022a72d00a447d320eade1cb741`. An isolated `baikai ==0.10.0.0` / `shikumi ==0.5.0.0` dry-run succeeds at index-state `2026-11-03T02:09:47Z`; FRIC-46 is resolved. Adding published Kioku core 0.12.0.1 fails because it requires `shikumi ^>=0.4.1.1`, excluding 0.5. This is the next owning compatibility prerequisite (FRIC-48), not the old Shikumi/Baikai bound. See [paired solve evidence](../evidence/baikai-execution/shikumi-release-followup.json). Obtain a validated Kioku revision or release admitting the new Shikumi API, then resume the coupled application solve. No application pins, runtime code, workflow codecs or milestone acceptance changed during this prerequisite recheck.

Implementation resumed after Kioku publication (2026-11-03 UTC): Kioku API/core/migrations 0.12.0.2 at `mori://shinzui/kioku` tag `v0.12.0.2` (`5a62c3ef29cad50543f7bae97126e0431225998d`) admits Shikumi 0.5; FRIC-48 is resolved. The full candidate application solve succeeds at index-state `2026-11-03T02:59:02Z` with Baikai 0.10, the released Shikumi family, Effectful 2.7.1.0/core 2.7.1.2 and the required strict-mutable-base 2.0.0.0. Other runtime pins and the existing Handan source pin are retained; Handan builds. API/content migration is in progress. One early representative test passes through normal configuration, the application decision wrapper, real public TypeSafe HTTP and Shikumi rich decoding with one actual-attempt receipt; it preserves the provider choice separately from weighted local derivation. This is not full M1/M7/M8 acceptance. Next work is expanded structured-content/refusal fixtures, the patch-gated supplied-ticket Flow, PostgreSQL queue/restart replay, generative off/cache wire fixtures, and final committed-cohort/package qualification. Batch promotion still needs its separate deadline/output/confinement contract.

Source checkpoint (2026-11-03 UTC): the released cohort is integrated with structured answer snapshots, scoped assistant/context replay versions, explicit judgment program capability, TypeSafe credentials/catalog/provider registration, immutable effective decision settings, and a patch-gated supplied-ticket Flow. The real public adapter proves divergent weighted local choice versus preserved raw answer, fresh changed settings, refusal/cancellation and fail-closed terminal persistence. PostgreSQL queue/restart fixtures pass with one total HTTP request after credentials/providers and current derivation settings change; a pending retired binding refuses with zero requests. Public response/cache/replay checks pass, and both vendor CLI adapters now pass positive inherited-group cancellation on Darwin. At source checkpoint `d5c7a8fc`, core 680, agent 37, serial PostgreSQL 545, server 105, migration smoke 11 and serial worker 281 checks pass. The committed native gate passes 177 conformance assertions with no generated drift, an additive judgment patch and a replay-neutral stored-data verdict. Haskell conventions and their 13 tests pass; the optional workspace fixture compiles on Darwin. The successful solve exports 387 runtime packages and seven immutable repositories, and all five Nix role attributes evaluate in a dry run. See [structured judgments](../evidence/baikai-execution/structured-judgments.md) and its machine-readable checkpoint. No M1/M7/M8 completion, fresh immutable build or installed-asset qualification is claimed. Streaming awaits Shikumi IR-5, and wire/error-matrix expansion, Linux CLI qualification and immutable role packaging remain open. The batch refusal now names deadline/output/confinement rather than the resolved cancellation publication.

IR-5 release adoption (2026-11-03 UTC): verified normal Hackage releases Shikumi 0.5.1.0, cache 0.2.1.1, tools 0.4.2.1 and trace 0.3.2.0, with descriptors matching tag commit `7b96ecf06364b37de44b15c4f58b2528b5a3e0f5` at `mori://shinzui/shikumi`. The application solve succeeds at index-state `2026-11-03T12:48:57Z` without other cohort changes or new bounds overrides. The new `streamDecisionProgramWithAnswers` entry point shares complete-call admission, private provider registry, terminal acknowledgement and raw-answer retention while composing public Shikumi streaming interpreters. All 15 real TypeSafe checks pass, including exact complete/stream request/raw/typed parity, atomic events, cancellation, refusal, consumer failure and terminal-persistence failure. FRIC-49 is resolved; the historical pre-transport refusal no longer blocks this candidate. Full core 689 and worker 281 checks pass; broader serial regression, the new PostgreSQL streamed-outcome replay fixture and the committed native gate are being finalized. M7/M8 remain open for the remaining plan matrix and packaging criteria; no paid or Linux runtime qualification is implied.

## Surprises & Discoveries

The released Shikumi 0.5.0.0 complete path supports rich judgments, but its public `streamProgram` and `routeLLM` explicitly reject decision outputs before transport. Its streaming parser also omits the complete path's explicit decision settings. FRIC-49 is promoted to `mori://shinzui/shikumi/okf/improvement-requests/concepts/IR-5` at the user's request. That request requires public complete/stream typed-result parity, atomic TypeSafe structured events, preserved raw answers and acknowledged attempt evidence in a tagged release. M7/M8 streaming acceptance remains open; do not bypass the owning router or copy its parser downstream. Independent complete-call and durable replay qualification can continue.


The October probes established live descendants after cancellation for the versions still selected by Shikigami. Keep [that contract inventory](../evidence/baikai-execution/contracts.md) as historical evidence. The owning report `mori://shinzui/baikai/okf/bug-reports/concepts/BUG-1` now records a released fix in core 0.8.0.0 and Claude/OpenAI 0.7.1.1. `mori://shinzui/baikai/okf/capabilities/concepts/CAP-25` documents positive Darwin/Linux regressions: inherited process-group members stop, readers join and direct children are reaped before the original asynchronous exception propagates. This removes the wait for publication, not the application's promotion gate. Deliberately detached process groups can escape; CLI `Options.timeoutMs` is still ignored and batch output is still accumulated to EOF. Cancellation ownership is neither confinement nor a hard deadline or retained-output limit.

The latest source checkout and published metadata differ materially. The local Shikumi 0.4.1.1 descriptor admits Baikai `>=0.9 && <0.10`, but its authoritative Hackage descriptor admits `>=0.8 && <0.9`. Both exclude 0.10. The other released Shikumi packages in the configured closure have the same published 0.8 range. Never infer a released solve from the newer local files or relax those bounds in Shikigami.

On 2026-11-03 UTC an isolated two-dependency consumer independently reproduces `Cabal-7107`: `rejecting: baikai-0.10.0.0 (conflict: shikumi => baikai>=0.8.0.0 && <0.9)`. Hackage descriptor hashes and upstream tags are retained in [release-prerequisite.json](../evidence/baikai-execution/release-prerequisite.json); [contracts.md](../evidence/baikai-execution/contracts.md) contains the complete minimal fixture. FRIC-46 in `docs/friction-log/` records this blocking occurrence. A widened local descriptor is insufficient: adoption needs the published judgment routing/derivation and structured cache consumer too.

The independent configured-endpoint loopback proof exposed an existing consumer mismatch: Baikai records canonical API name `anthropic-messages`, but the decision runner and compliance evaluator compared it directly with the profile vocabulary `messages`. Mock handlers had emitted the shorter name and hidden that failure. Normalize canonical evidence names for matching transports during comparison, retaining raw evidence and the historical profile/digest vocabulary. The real-adapter regression and wrong-API/transport cases cover this correction; ADR 0044 records the durable rule.

The Shikumi 0.5 publication removes its Baikai exclusion but exposes the reverse dependency: Kioku core 0.12.0.1 already requires Baikai 0.10 yet its `shikumi ^>=0.4.1.1` bound excludes Shikumi 0.5. At the refreshed fixed index, the minimal new pair resolves and the same pair plus Kioku is refused by Cabal. FRIC-46 is resolved; FRIC-48 records the new blocking consumer. The released Shikumi descriptor exposes judgment runtime/settings/default-filtering modules, but no application adapter or durable judgment proof is implied by this solve-only result.

Plans 73–76 and 82–83 have since implemented operator model catalogs, per-attempt governed calls, pinned assignments and accepted model/tool transcript recovery. The original plan's process-global-registry uncertainty and coarse-step-only recovery description no longer describe the whole runtime. A Baikai upgrade must preserve those existing consumers and their retained JSON/digest contracts.

TypeSafe is judgment-only, not a text generator with another provider name. Its public adapter refuses system prompts, tools, conversation history and explicit generation controls, including `thinking: none`, `maxTokens` and standard speed. Baikai preserves reported choices and expected scores; Shikumi deliberately derives typed choices and scores from probabilities under its own pinned settings. These values can differ. The application must retain the raw structured answer separately from its derived typed result, and must not let its current final-options merge reintroduce generative defaults after judgment routing.

The public unattended parser includes its own `agent` group and does not export the inner parser. The mounted spelling is therefore `unattended agent run|show|list`, preserving Baikai grammar without copying it.


## Decision Log


Decision (2026-10-06 UTC): Extend `behavior.provider`, preserving `stub` and `anthropic`. Add `openai`, `openai-responses`, `claude-cli` and `codex-cli`, meaning OpenAI Chat Completions HTTP, OpenAI Responses HTTP, Claude batch CLI and Codex batch CLI respectively. Vendor request rendering, subprocess output parsing and model invocation belong to Baikai.

Decision (2026-10-06 UTC): Put attended and unattended launches in a separate foreground executable in `shikigami-agent`. A durable Skill needs a Baikai `Response`; interactive launchers return process exit and own the terminal, while unattended jobs can change a working tree. Neither replaces `run-behavior-v2`. Plans 48 and 78 retain governed workspace and durable external-job ownership.

Decision (2026-10-06 UTC): Reuse `Baikai.Agent.Config` and `Baikai.Agent.Cli` for unattended named jobs, including the operator-only policy ceiling and source reports. Settei remains Shikigami's existing resolver for response calls and the interactive wrapper. Baikai has an unattended job loader, not one universal configuration API for every surface; do not invent one or duplicate its KDL parser.

Decision (2026-10-06 UTC): Require explicit models and constrained vendor-native authority for background batch calls. Returning text does not prove a coding CLI's internal tools were disabled. If a public Baikai adapter cannot uphold confinement or cancellation, an owning Baikai release becomes a prerequisite; Shikigami must not copy its process engine to work around that gap.

Decision (2026-10-06 UTC): Inherit plan 79's active intention because this work enables its API-key-free provider path. Correct its earlier unconditional Anthropic key prerequisite during authoring. CLI login does not replace authorization or delivery credentials, and a CLI trial does not close plan 13's specifically Anthropic HTTP smoke acceptance.


Decision (2026-10-06 UTC): Keep CLI response selection unavailable while the released process lifecycle cannot establish descendant cleanup. Implement the independent HTTP and foreground paths and retain a typed request gate. Do not copy Baikai supervision into Shikigami.

Decision (2026-10-06 UTC): Preserve the public unattended parser's `agent` group under `unattended`. Its inner parser is not exported, so target examples adopt `unattended agent`.

Decision (2026-11-02 UTC): Treat the upstream cancellation publication as satisfied and consumer qualification as outstanding. Target the latest coherent Baikai 0.10 family after owning Shikumi compatibility is published and the Kioku/Effectful closure solves without new bounds overrides. Preserve the configured cohort until then; do not silently substitute a 0.8-only migration or claim the latest target is already buildable.

Decision (2026-11-02 UTC, initial scope; TypeSafe exclusion superseded below): Refresh the existing generative model surfaces and their compatibility checks without adding TypeSafe judgment execution to this plan. Explicit `none` reasoning is distinct from omitted/default reasoning; requested values must never be silently clamped. New model metadata changes descriptor identity, so retain old admitted bindings or drain their pending work rather than replacing them in place.

Decision (2026-11-02 UTC, expanded scope): The user now requests adoption of batch CLI responses, explicit reasoning off, shared-prefix caching, structured answers and TypeSafe judgments in this plan. This supersedes the TypeSafe exclusion above. TypeSafe enters the finite operator decision catalog and registered judgment programs; the legacy text/tool behavior path continues to require a generative model. Preserve the existing Flow-facing decision API and authority intersections.

Decision (2026-11-02 UTC): Reuse public `Baikai.Judgment`, `Baikai.Response.JSON`, `Baikai.Provider.TypeSafe.Api` and qualified Shikumi decision/routing APIs. Baikai retains neutral provider answer data; Shikumi applies declared local derivation settings. Version and retain both the raw answer snapshot and the committed rich result. Replay reads committed outcomes without fresh derivation or fresh provider evidence. Automatic calibration fitting is not required to adopt these features; explicit thresholds, cuts and weights are supported and pinned.

Decision (2026-11-03 UTC): Deliver the independent decision-binding endpoint/cache configuration against the retained qualified cohort while the released solve is blocked. Reuse existing endpoint and retention validation and the model/options digest preimage, preserving omitted-field identity. An explicitly pinned retention, including `none`, cannot be changed by a program node; conflicts refuse before actual-attempt admission. This does not qualify the newer adapter's shared-prefix caching or TypeSafe and does not change workflow bodies, step shapes or journal codecs. ADR 0052 records the durable binding rule.

## Outcomes & Retrospective


The independent HTTP and foreground integration is implemented and qualified at `9ce65b2`: full source build, affected regression suites, unchanged journal gate, all five immutable role targets and 11 installed command checks pass. Real attended and operator-ceiling-controlled unattended Codex trials both returned public markers and exit 0 with API-key variables absent. See [qualification evidence](../evidence/baikai-execution/qualification.md).

The overall plan remains open. The application's pinned adapters are still the affected versions, so background CLI selection remains a typed refusal. Upstream has now released the fix; the remaining M1 adoption and positive lifecycle/confinement proof, M2 CLI resolver, M3 CLI response dispatch and M6 authenticated reporter are application work subject to the dependency prerequisites below. The 2026-11-02 refresh verified release metadata and source contracts only; it ran no upgraded build, no positive consumer cancellation test and no new live trial. Live HTTP alternatives remain untested; no background reporter, memory/delivery or service qualification is claimed.

The subsequent scope expansion adds structured-content persistence and TypeSafe application integration as M7 and M8. These remain unimplemented and unqualified. Neither a TypeSafe credential nor a remote judgment call was used while updating this document.

The 2026-11-03 implementation delivers optional governed endpoint and retention configuration against the retained cohort, protects explicitly pinned retention, and fixes canonical API comparison for real decision terminals and shared compliance evaluation without rewriting recorded facts. The focused 52-case decision suite passes. FRIC-46 remains logged because the owning published Shikumi prerequisite is unresolved; no bound override, package promotion, journal codec change or new provider readiness claim is introduced. Final current-cohort qualification at `340fd633` passes all six affected suites: core 666, agent 37, server 105, migration smoke 11, PostgreSQL 543 and workers 281. The committed-tree workflow gate passes with no drift, a replay-neutral verdict and 177 conformance assertions; migration isolation and strict friction validation pass. FRIC-47 is accepted with the documented serial qualification profile; the earlier parallel worker and PostgreSQL failures remain recorded as superseded attempts in [qualification.md](../evidence/baikai-execution/qualification.md). This validates the independent current-cohort changes only; the adopted-cohort, installed-role, Linux, structured-content, TypeSafe and live batch milestones remain open.


After the user published the Shikumi compatibility cohort, the follow-up confirmed its release descriptors/tags and successful Baikai 0.10 pair resolution. FRIC-46 is resolved. The full application remains blocked by Kioku core 0.12.0.1 excluding Shikumi 0.5 (FRIC-48, logged). The retained application pins and the previous runtime regression evidence are unchanged; these new probes establish dependency contracts only.

## Context and Orientation


`shikigami-core/src/Shikigami/App/Config.hs` owns typed settings and explicit environment bindings. At the authoring baseline, `ProviderSelection` was `UseStub | UseAnthropic Model SecretText`; the implementation adds `UseHttp Model Options SecretText`. `behaviorProviderConfig` conditionally requires the matching HTTP vendor credential and decodes models against the selected API/vendor catalog. Anthropic keeps its existing default; OpenAI requires an explicit model. Settei resolves files, environment and command overrides, retaining sources and redacting secrets. `shikigami-core/src/Shikigami/App/Config/Load.hs` and `shikigami-core/src/Shikigami/App/Role.hs` implement shared configuration commands. The default stub contacts no provider.

`shikigami-core/src/Shikigami/Behavior/Provider.hs:newBehaviorEnvFor` creates the Shikumi runtime and registers the selected Baikai handler. Its `BehaviorEnv` carries the actual Baikai `Model`, `Options`, tool registry and trace sink. `shikigami-core/src/Shikigami/Behavior/Provider/Call.hs` now owns `providerCallFor`, `callSurface` and the shared pure profile predicate, re-exported by the builder. Both CLI tags already map to endpoint class `cli`, but the builder has no CLI selection branch. `shikigami-core/src/Shikigami/Behavior/Compatibility.hs` owns the pure request guard and its `BatchCancellationReleaseRequired` refusal. A transport is the mechanism used to call a model: HTTP or a local subprocess here.

`shikigami-core/src/Shikigami/Behavior/Skill.hs` invokes `completeRequest`. With no Shikumi tools it takes a single-completion path; with tools it runs a bounded model/tool loop. `shikigami-core/src/Shikigami/Flow/Routing.hs` and `shikigami-core/src/Shikigami/PracticeReview/Capability.hs` also call Baikai and request `JsonObject` output. CLI response adapters do not support Shikigami's advertised tool loop. Current vendor releases support JSON schema output, but `JsonObject` has no CLI analogue. Do not silently drop a requirement or claim every Flow works through a CLI.

`shikigami-workers/src/Shikigami/Workers/Command/Worker.hs`, `shikigami-agent/src/Shikigami/Agent/Command/AgentRun.hs` and `shikigami-agent/src/Shikigami/Agent/Command/RunBehavior.hs` reuse the builder. Find every builder caller, including server/conversation composition, during implementation. The database-free behavior command deliberately refuses a manifest requiring a sanctioned profile. Database-backed runs resolve that policy before calling a provider. A sanctioned profile is a journaled permission snapshot naming exact provider/API/transport/model/thinking combinations; new transport configuration must preserve that admission boundary. `shikigami-core/src/Shikigami/Decision/ModelCatalog.hs`, `shikigami-core/src/Shikigami/Program/DecisionRunner.hs` and `shikigami-core/src/Shikigami/Execution/SelectionRuntime.hs` also consume the models/options. They retain exact descriptors, private provider registries and per-attempt checks. `behavior.decisionModels` currently resolves three HTTP APIs and finite stubs. M8 extends that catalog with TypeSafe judgment bindings, not CLI decision aliases.

Discover dependency roots using `mori registry show shinzui/baikai --full` and read source at selected release tags. Never search `/nix/store`. Canonical packages are `mori://shinzui/baikai/packages/baikai`, `mori://shinzui/baikai/packages/baikai-claude`, `mori://shinzui/baikai/packages/baikai-openai` and `mori://shinzui/baikai/packages/baikai-agent`. Guides are `mori://shinzui/baikai/docs/cli-providers`, `mori://shinzui/baikai/docs/interactive-launches`, `mori://shinzui/baikai/docs/unattended-agent-runs` and `mori://shinzui/baikai/docs/model-call-evidence`. Necessary contracts are summarized here so those references are supporting material rather than unstated design requirements.

Public response modules are `Baikai.Provider.Claude.Api`, `Baikai.Provider.Claude.Cli`, `Baikai.Provider.OpenAI.Api`, `Baikai.Provider.OpenAI.Responses` and `Baikai.Provider.OpenAI.Cli`. Their tags are `AnthropicMessages`, `AnthropicMessagesCli`, `OpenAIChatCompletions`, `OpenAIResponses` and `OpenAICompletionsCli`. CLI config records expose executable, extra arguments and working directory; Codex also exposes ephemeral and Git-repository-check choices. Build CLI models with public `emptyModel`, explicit vendor/model id and the CLI tag. Do not dispatch an HTTP catalog descriptor unchanged through a CLI or fabricate model pricing/limits. Catalog limits may be reused only for the same explicit model and remain configured facts rather than evidence of the model actually served.

The interactive vocabulary is `Baikai.Interactive.InteractiveLaunchRequest`, with prompt, optional system prompt/model/effort, working directory, extra directories, safety and arguments. Vendor `launchClaudeInteractive` and `launchCodexInteractive` return `Either AgentRenderError InteractiveLaunchResult`. Refusal starts no process; a nonzero result means the process ran and failed. The unattended surface uses `Baikai.Agent.Config` for named jobs, `Baikai.Agent.Cli` for parsing/policy-aware execution, and `Baikai.Agent.Run.runAgentCommand` for bounded execution. Its operator ceiling is the maximum permission set repository jobs may request; repository config cannot raise it. Its runner bounds retained output and terminates the process group on timeout. These guarantees must not be assumed for the separate batch adapters without testing.

The authoring baseline froze core/Claude/OpenAI at 0.7.0.0; `cabal.project` and `nix/qualification/cohort.json` still select core 0.7.2.0, Claude/OpenAI 0.7.1.0, agent 0.2.0.1, Effectful adapter 0.4.0.1 and trace adapter 0.4.0.1. The project index has since advanced to `2026-10-30T19:00:00Z`, with Keiro 0.22, Kioku 0.12.0.0 and Effectful/core 2.6.1.0. Preserve this accepted runtime baseline, including subsequent Rei source additions documented in `docs/dependency-cohort.md`. Core/vendor 0.7 tags peel to `7dd44f96e5bba1a0dfa6a693a6c4858d81ab9831`; agent 0.2.0.1 peels to `4a9547b00de18b095259e3720e1ede82670787c9`. Both application packages already declare their public Baikai imports directly.


### Shikumi compatibility publication and remaining Kioku prerequisite — 2026-11-03 UTC


The current released target uses `mori://shinzui/shikumi/packages/shikumi` 0.5.0.0, tools 0.4.2.0, cache 0.2.1.0, trace/eval 0.3.1.0 and trace-otel 0.1.3.0. All six upstream package tags peel to `b9b7a73f276ec022a72d00a447d320eade1cb741`; their Hackage descriptors admit Baikai `>=0.10.0.0 && <0.11`. This supersedes the earlier missing-Shikumi-release prerequisite below. Public judgment runtime, decision settings and request-default filtering are exposed by the new core descriptor. Runtime, cache, application decoder and replay qualification are still required after a coherent application solve.

The latest published `mori://shinzui/kioku/packages/kioku-core` remains 0.12.0.1 at upstream tag `v0.12.0.1`, commit `78c9d0eeeb6f4c4b138122fe6c6a3e0deda80343`. Its Baikai requirement admits 0.10, but `shikumi ^>=0.4.1.1` means `>=0.4.1.1 && <0.5`. A minimal three-dependency solve fails on this bound even though the two-dependency Baikai/Shikumi solve succeeds. Preserve application pins and require a compatible owning Kioku release or authoritative revision; do not add an application bounds override. The exact descriptors, SHA256 hashes and reproducible projects are in [shikumi-release-followup.json](../evidence/baikai-execution/shikumi-release-followup.json). This is a prerequisite check, not an upgraded source build. The remaining Effectful pair and frozen closure still need the whole-project solve once Kioku admits this target.


### Released dependency and model refresh — 2026-11-02 UTC


Hackage `preferred.json`, the published Cabal descriptors and `git ls-remote --tags` agree on latest normal releases: core 0.10.0.0, Claude/OpenAI 0.7.3.0, agent 0.2.0.4, Effectful adapter 0.4.0.5 and trace adapter 0.4.1.1. Core, vendor, Effectful and trace tags peel to `03140cf60381ac154ebfa86d3bb2208d7df8626c`; agent 0.2.0.4 peels to `4eba8c8f780da1b6a82b7232f5833db6608237dd`, including the isolated-stdin regression fix. The earlier cancellation-fix family, core 0.8.0.0 and vendors 0.7.1.1, peels to `358e1f23163237f39221e32634621d5e5084d863`. Read public source at each actual package tag; a single checkout revision is not every package's release identity.

The latest family is a target, not a solved selection. Published `mori://shinzui/shikumi/packages/shikumi` and `mori://shinzui/shikumi/packages/shikumi-tools` 0.4.1.1, `mori://shinzui/shikumi/packages/shikumi-cache` 0.2.0.2, `mori://shinzui/shikumi/packages/shikumi-trace` 0.3.0.2, `mori://shinzui/shikumi/packages/shikumi-trace-otel` 0.1.2.2 and `mori://shinzui/shikumi/packages/shikumi-eval` 0.3.0.2 require Baikai `>=0.8.0.0 && <0.9`. Their local descriptors already moving to 0.9 are not released compatibility evidence. Selected `mori://shinzui/kioku/packages/kioku-core` 0.12.0.0 also requires Baikai below 0.9; published 0.12.0.1 instead requires core 0.10 and the newer adapters. `mori://shinzui/baikai/packages/baikai-effectful` 0.4.0.5 requires `effectful-core ^>=2.7`, beyond the current 2.6.1.0 pin. Kioku and Keiro 0.22 permit 2.7.1.1 and later below 2.8 while excluding 2.7.0; inspect all released dependents and authoritative Effectful metadata before selecting a compatible pair. Obtain an owning Shikumi release or revision explicitly admitting the target, then solve the coupled Baikai/Shikumi/Kioku/Effectful changes with the unrelated runtime frozen. Do not add `allow-newer`, silently use sibling source, or advance unrelated packages to force a solve.

Core 0.9 adds structured `UserData`/`AssistantData` content, stream constructors, model `OutputKind` and `isJudgmentOnly`, plus fields in errors, traces and evidence. Core 0.10 adds `ThinkingNone`, Anthropic `supportsThinkingDisabled` and endpoint-specific `NativeCachePolicy`. Audit exhaustive matches and explicit record construction throughout the application and its consumers; prefer public empty/default records. Refresh generated models by exact API/vendor/model id, preserving the legacy `anthropic_claude_sonnet_4_6` default. Exclude judgment-only models from generative text/tool paths and admit them through the qualified decision path in M8.

`none` explicitly requests reasoning off; omission and decision-catalog `default` leave the provider default untouched. On supported Anthropic HTTP bindings it emits disabled thinking; unsupported bindings may clamp to low. Claude CLI and interactive renderers map both `none` and `minimal` to low, so Shikigami must refuse an explicit off request there before spawning. Codex renders `none` verbatim, which still requires installed-vendor qualification and says nothing about remote execution. API checks must use declared accepted efforts and disabling capability rather than treating every non-reasoning model as an invalid off request. Preserve separate requested, translated and observed evidence, and exact profile permission for `Just ThinkingNone` versus `Nothing`.

Native cache support now depends on `NativeCachePolicy` for the exact catalog binding and endpoint; older `cacheControlFormat` and `supportsPromptCacheOptions` predicates alone are insufficient. Claude/OpenAI 0.7.3.0 can mark nonempty shared system prefixes. OpenAI modern Short and verified Luna Responses Long have distinct policies; unsupported retention must fail locally. Keep retention configurable through the existing setting, leave breakpoint placement and effective pricing to Baikai, and do not promise a cache hit. CLI adapters still ignore retention. Supporting guides are `mori://shinzui/baikai/docs/models-and-providers`, `mori://shinzui/baikai/docs/prompt-caching` and `mori://shinzui/baikai/docs/model-call-evidence`. Latest evidence schema 2.8 and model serialization changes must not reinterpret historical application-owned facts or pinned descriptor digests.

The TypeSafe target is `mori://shinzui/baikai/packages/baikai-typesafe` 0.1.0.1, verified against Hackage and tag `baikai-typesafe-0.1.0.1` at `03140cf60381ac154ebfa86d3bb2208d7df8626c`. Its released descriptor requires core `^>=0.10.0` and `mori://shinzui/typesafe-hs/packages/typesafe-hs` `^>=0.1.0.0`; that wire client is published as 0.1.0.0 with tag `v0.1.0.0` at `f79344b9bb48ac49626b1065d7de255bea4b5464`. Import only `Baikai.Provider.TypeSafe.Api`, not its exposed `Internal` modules. The guide `mori://shinzui/baikai/docs/typesafe-judgments` and `mori://shinzui/baikai/okf/capabilities/concepts/CAP-27` describe the public contract. These newer artifacts and package are absent from the stale local Mori registry; use their canonical URIs and inspect their producer sources rather than treating resolution failure as feature absence.

Select exact catalog models `jev-latest` or `jev-preview` with `TypeSafeSystemOne` and provider `typesafe`. `isJudgmentOnly` is the routing fact. `prepareJudgment` accepts one user text/data message, no system prompt or tools, and a closed-set `JsonSchema`: boolean predicates, distinct string choices, or integer scores over contiguous levels 0 through N−1. Score declarations have two through ten levels. Baikai validates names, alternatives, finite probabilities and confidence; it preserves provider choices, fractional expected scores and distributions without normalizing them. A response contains `AssistantData` with `value`, optional `probabilities`, optional `confidence` and `method`. Call evidence is a separate optional record. Synthetic streaming emits atomic `DataStart`/`DataEnd`, not text chunks. Public `Baikai.Response.JSON.responseToJSON` and `responseFromJSON` preserve full responses; do not introduce orphan JSON instances or assume exact arbitrary-rational cost roundtrips.

Qualified Shikumi support is coordinated with `mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs` and `mori://shinzui/shikumi/plans/63-declare-decision-outputs-and-route-them-to-system-one-models`. The Mori-discovered project `mori://shinzui/shikumi` implements decision types, local derivation and request-default filtering under `shikumi/src/Shikumi/Decision.hs`, `shikumi/src/Shikumi/Decision/Setting.hs`, `shikumi/src/Shikumi/Program.hs` and `shikumi/src/Shikumi/LLM/Defaults.hs` (artifact-level source URIs pending). The dependency prerequisite now includes a released, compatible consumer path for these APIs, not merely widened bounds. Use Shikumi's public rich `Noul`, `Choice` and `Score` outputs, where a predicate carries its probability, a choice carries its distribution, and a score carries level probabilities and a derived level. Effective `Params.decisionSettings` and all defaults must join the immutable program parameter/derivation commitment.

`shikigami-core/src/Shikigami/Execution/Transcript.hs` currently captures text, thinking and tool blocks but has no structured-data replay block. `shikigami-core/src/Shikigami/Decision/Contract.hs` has a format-1 `DecisionOutcome` carrying a typed result and attempt IDs; `shikigami-core/src/Shikigami/Program/Decision.hs` retains its pure result codec. M7 extends these application-owned records without replacing their historical codecs. [ADR 0041](../adr/0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md) already distinguishes deliberate probability re-derivation from committed replay; [ADR 0045](../adr/0045-flow-policy-pins-pending-decisions-and-retains-completed-result-codecs.md) requires complete slot-state pinning and codec-only completed replay. These decisions govern TypeSafe adoption too.

Relevant architectural context is established. [ADR 0003](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md) keeps foreground commands in the light agent package. [ADR 0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md) gates actual dispatch against pinned policy. [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) protects durable identities. [ADR 0021](../adr/0021-operator-verbs-wrap-the-owning-library.md) requires mounting owning-library commands. [ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) keeps requested tools distinct from acquired authorized tools. [ADR 0026](../adr/0026-outbound-sink-credentials-stay-opaque-and-http-policy-lives-at-the-process-boundary.md) keeps secrets opaque until request construction and preserves cancellation. [ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md) requires fresh admission of protected actions. [ADR 0020](../adr/0020-readiness-covers-only-what-restarting-can-fix.md) excludes provider/login availability from readiness. [ADR 0039](../adr/0039-deployment-roles-share-a-frozen-cabal-source-closure.md) requires a frozen package/source closure and installed-asset proof.

[Plan 48](48-add-a-portable-one-off-repository-agent-harness.md) owns declared-agent workspace policy; this plan adds no manifest tool authority. [Plan 73](73-define-typed-decision-programs-and-authorized-model-catalogs.md) now supplies authorized aliases and immutable model descriptors; plans 74–76 execute and retain typed decisions. [Plan 82](82-pin-governed-execution-settings-for-agent-assignments.md) pins whole-run settings, and [plan 83](83-recover-durable-model-and-tool-turns-with-composed-policies.md) owns accepted model/tool transcript recovery. Preserve [ADR 0042](../adr/0042-decision-admission-intersects-operator-agent-and-pinned-profile-authority.md), [ADR 0043](../adr/0043-decision-provider-wrappers-own-actual-attempt-boundaries.md), [ADR 0044](../adr/0044-decision-attempts-persist-expectations-and-consumer-owned-compliance-facts.md) and [ADR 0052](../adr/0052-assignments-pin-whole-run-selection-and-account-every-provider-attempt.md): finite authority, private registries, per-attempt evidence and exact retained bindings survive this upgrade. [Plan 78](78-run-external-operations-from-durable-flows-through-idempotent-shiki-jobs.md) owns durable external-job submission/observation. [Plan 79](79-qualify-local-agent-execution-and-prioritize-production-readiness.md) owns real authorization, memory, delivery, restart and human-wait qualification. A standalone launch does not close those plans.


## Plan of Work


Retain the original milestone numbers so October evidence remains attributable. Establish M1's coherent released interfaces first. Develop M2/M3's reasoning and cache adoption and M7's structured-content support before M8's TypeSafe consumer. M4's foreground behavior remains a regression obligation. Repeat M5 packaging/journal qualification after all feature changes, then close M6's existing live CLI handoff. An upstream blocker for one surface does not prevent independent consumer work or justify marking that blocked surface complete.


### Milestone 1: Prove contracts and inventory the settings


Extend `docs/evidence/baikai-execution/contracts.md`, preserving its October negative probes and recording the newly selected release descriptors, public imports, provider tags, option translations and mode-specific requirements. Begin with the published compatibility prerequisites in Context and Orientation; establish a release-only solve before treating the latest target as selected. In the Mori-discovered Baikai root read `baikai/src/Baikai/Options.hs`, `baikai/src/Baikai/Interactive.hs`, all five vendor response modules, both interactive modules and `baikai-agent/src/Baikai/Agent/{Config,Cli,Run}.hs` at their actual package tags. Also inspect public model, compatibility, thinking, content/event and evidence changes since 0.7.2.0. Do not depend on `Internal` modules or vendor `Transport` modules explicitly documented as unstable.

Use temporary fake vendor executables to prove response decoding, failure classification, cancellation and schema support through public adapters before wiring new Shikigami branches. Keep contract cases in `shikigami-core/test/Shikigami/BehaviorProviderSpec.hs`. Replace the negative cancellation expectations only after both adapters pass positive no-survivor checks against the selected released packages. Cover complete calls, active synthetic-stream consumption, repeated cancellation, signal-resistant inherited children and executable-version evidence probes. Verify the original asynchronous exception and Codex schema cleanup after termination. Distinguish stopped zombies from live descendants, synchronize fixture readiness, and keep an unrelated sentinel alive. Use the threaded runtime and make `/bin/ps` available in the installed environment. Qualify native Darwin and Linux; use a disposable Apple container for Linux runtime evidence, with the configured builder fallback for stalled compilation. Require an explicit operator working directory for a background subprocess; the worker's ambient directory is not a stable launch setting.

Audit vendor-native authority separately from Baikai's lack of advertised tool calling. Read bounded installed CLI `--help` output and official vendor documentation, then prove the selected disabling/confinement policy with fake argument assertions and a disposable real probe before promotion. The reporter must not receive edit/full-access flags or inherit a coding job's unrestricted policy. Separately settle the deadline and output contract: published batch adapters ignore `Options.timeoutMs` and retain output to EOF. Do not label the cancellation release as fixing these. Identify an existing owning boundary that enforces the needed bounds or obtain a public owning-library change; if neither meets the reporter's contract, keep that surface refused with the precise remaining reason. The same applies to detached descendants outside the inherited process group. Keep HTTP and foreground integration independently deliverable; do not copy a parser or supervisor into Shikigami.

Inventory every public response option, CLI config field, interactive request field and unattended job field. Each must be configurable, supplied per invocation by its existing caller, or explicitly inapplicable with a reason. Select verified released dependencies that satisfy the proofs, preserving unrelated runtime pins and changing Kioku/Effectful only as required by the checked compatibility closure. The milestone passes when a committed-descriptor solve, fake-provider tests and the inventory establish executable contracts without API credentials. If published Shikumi still excludes the target, record the owning release prerequisite and leave adoption unchecked; a local descriptor edit is not qualification. Record unresolved upstream requirements with canonical artifact references if one is needed.

Include TypeSafe's public provider, judgment grammar, structured response codec and Shikumi's judgment-only routing/derivation in the inventory and released solve. Before expanding fixtures, run one representative supplied-ticket request through the application decision wrapper, real public TypeSafe adapter, loopback HTTP server and Shikumi typed decoder. Success requires one HTTP call, no generative defaults, a rich typed result and actual-attempt evidence. If the published consumer cannot carry that path, record the precise owning API prerequisite rather than copying Shikumi's router or Baikai's wire translation into Shikigami.


### Milestone 2: Extend typed configuration and effective reports


Refactor `ProviderSelection` and `behaviorProviderConfig` in `shikigami-core/src/Shikigami/App/Config.hs` into a resolved response configuration with choice, explicit Baikai model, supported options and conditional opaque credential. Preserve `stub`, existing Anthropic defaults and existing precedence. HTTP lookup filters the generated catalog by the chosen API, rather than using Anthropic's list for OpenAI. CLI models require a nonblank explicit vendor model id and carry their actual CLI tag. An unknown HTTP catalog model or unsupported API/option pair fails resolution; do not substitute a nearby model.

Add `behavior.base_url`, `behavior.options.*` and `behavior.cli.*` settings with explicit environment bindings. Map supported `thinking`, `max_tokens`, `temperature`, `timeout_ms`, `top_p`, `stop_sequences`, `seed`, `frequency_penalty`, `presence_penalty`, `cache_retention`, `speed`, `response_format`, `tool_choice`, `headers` and `metadata` to Baikai's public types. Decode schema JSON structurally, validate finite positive deadlines and numeric ranges, and preserve an explicitly configured endpoint in the actual model and public report. Model limits remain catalog facts, not unchecked operator claims. Evidence run identity/strength, tool registry and trace sink remain caller-owned; default configuration can request evidence only under that caller's policy.

CLI settings correspond to executable, canonical working directory, ephemeral session and Git-check fields in the selected vendor config. HTTP-only options on a CLI fail with the key named instead of being silently ignored. Raw provider arguments are secret-classified, operator-only escape hatches allowed only under the surface policy proven in M1; they cannot silently replace the constrained reporter policy. A foreground interactive operator may explicitly set arguments, and unattended arguments use Baikai's ceiling. Report support and source for every accepted setting.

On the 0.10 target, update both response and launch decoders/help to the seven canonical reasoning values, including `none`. Keep decision-catalog `default` distinct from `none`; never map absence to off. Update `Shikigami.Behavior.Compatibility` to use `supportsThinkingDisabled`, accepted-effort policies and `NativeCachePolicy` rather than the old blanket reasoning/cache predicates. Refuse Claude CLI/interactive off or minimal when their renderer substitutes low; do not weaken the request to make it run. With local HTTP fixtures prove supported off renders the intended wire request and unsupported off/cache policies refuse before IO. Cover admitted native Short and Long cache bindings and refused alternatives without assuming a real cache hit. Update `shikigami-core/test/Shikigami/AppConfigSpec.hs` and provider tests for legacy saved-model defaults and generative versus judgment-only catalog selection.

Demonstrate feature adoption through the application builder: issue two generative requests with identical nonempty system/tool prefixes but different user questions, and assert the selected Baikai cache controls and prefix placement on both wire requests. Cover Anthropic plus supported OpenAI Chat/Responses bindings, omitted retention and refused unsupported Long. Preserve usage/cost uncertainty and effective retention in existing observations. Test `none` versus omitted reasoning for behavior and decision aliases independently; native caching and reasoning-off do not apply to TypeSafe judgments. These deterministic fixtures are required even when live cache credentials are absent.

Extend the finite decision-model setting with optional `cache_retention` for generative bindings and optional `base_url` for an intentional endpoint override. Reuse the existing retention decoder and endpoint policy, include both in descriptor identity, and preserve historical behavior when absent. Require the configured retention to survive final request merging, while a node cannot silently weaken its pinned requirement. TypeSafe accepts absent/none retention and refuses short/long. Effective reports name supported retention and endpoint sources without credentials. This exposes caching for governed decisions as well as legacy behavior calls.

Require `credentials.providers.anthropic.api_key` only for Anthropic HTTP and new `credentials.providers.openai.api_key` only for OpenAI HTTP. Bind `OPENAI_API_KEY` explicitly through Settei. Keep `SecretText` until the existing Baikai credential boundary; secret-bearing headers and raw arguments also stay redacted in configuration, errors and logs. CLI branches do not require or unwrap HTTP keys and never parse/copy vendor login stores. The subprocess uses the login of its actual process user. An inherited API environment variable can affect vendor authentication, so prove API-key-free operation with those variables removed.

Extend `shikigami-core/test/Shikigami/AppConfigSpec.hs` for all selections, conditional secrets, precedence, unknown models, invalid options and redaction. `--check-config` resolves without provider calls, database IO or CLI spawning. Executable/login availability is an explicit run/provider diagnostic rather than a hidden config probe. Acceptance is valid CLI configuration with both API variables absent, missing HTTP credentials refused by key name, identical legacy defaults and complete redacted effective reports.


### Milestone 3: Dispatch through one Baikai builder and gate every request


Extend `shikigami-core/src/Shikigami/Behavior/Provider.hs:newBehaviorEnvFor` to select the public CLI provider after M1. For custom CLI settings use the value returned by `claudeCliProvider` or `codexCliProvider` through the public Baikai registry API; direct vendor dependencies already exist. Preserve existing invocation-local registries in governed decision and assignment execution. Keep the common composition boundary across worker, server/conversation composition and both existing one-off commands; entry points must not render vendor arguments or parse subprocess JSON. Replace the hardcoded CLI decoder and `BatchCancellationReleaseRequired` refusals only after the selected release passes all applicable promotion checks, retaining specific refusals for any surface whose confinement or bounds remain unsupported.

Extend the existing typed request-compatibility check in `shikigami-core/src/Shikigami/Behavior/Compatibility.hs`. Preserve its calls before every request in `shikigami-core/src/Shikigami/Behavior/Skill.hs`, `shikigami-core/src/Shikigami/Flow/Routing.hs` and `shikigami-core/src/Shikigami/PracticeReview/Capability.hs`, plus final-request checks in decision and assignment provider wrappers. It checks actual options, response format and context/tool requirements. A CLI with advertised Shikumi tools or `JsonObject` refuses permanently before spawning. Reject lossy unsupported image, tool-history or structured assistant content rather than silently flattening it. CLI JSON schema requests are admitted only when the selected public adapter and installed vendor capability support them; otherwise refuse before spawn. Preserve provider retry classification and rethrow asynchronous cancellation.

Keep `providerCall` derived from the actual model/options. Preserve `(messages, cli)` for Claude and `(completions, cli)` for Codex, with vendors `anthropic` and `openai`; OpenAI Responses uses `(responses, https)` at its default endpoint. For HTTP overrides, derive endpoint class from the actual URL scheme, matching compliance evidence; an HTTPS-only profile must refuse plaintext before dispatch. Do not loosen existing profiles or default CLI prohibitions. Tests prove explicitly allowed CLI tuples and refusal for HTTP-only policy, changed model, unapproved thinking and disallowed defaulted thinking. A CLI process success proves it ran, not which remote model served it; preserve Baikai's weaker evidence and unknown usage semantics.

Extend `shikigami-core/test/Shikigami/BehaviorProviderSpec.hs` and `shikigami-core/test/Shikigami/CapabilityProviderSpec.hs` with fake vendor and local HTTP fixtures, malformed JSON, missing executable, nonzero exit, cancellation, unsupported tool/schema and profile refusal. Invocation markers prove no process or HTTP call occurred for refusals. Discover and exercise every builder caller. The public explicit registry API is now established: preserve private registries and prove simultaneous differently configured environments cannot overwrite one another. Include changed model/options, `none` versus default reasoning, retained bindings and actual-attempt evidence in governed-call regressions. Acceptance is the same resolved selection reaching the public adapter through worker and one-off composition, with actual request/policy violations refused before dispatch.


### Milestone 4: Expose attended and unattended foreground launches


Add `shikigami-agent/src/Shikigami/Agent/Command/Launch.hs`, `shikigami-agent/app/agent-launch/Main.hs` and executable `shikigami-agent-launch` in `shikigami-agent/shikigami-agent.cabal`. Its executable depends on its own library and stays free of worker/server/Kafka dependencies. Direct public Baikai vendor/agent dependencies belong only to packages importing them.

Add an `interactive` subcommand with the existing shared Settei configuration flags and a dedicated launch resolver requiring no database: `launch.provider=claude|codex`, optional `launch.model`, `launch.thinking`, required `launch.working_directory`, `launch.extra_directories`, vendor executable/arguments and typed `launch.safety` fields. Map per-invocation prompt and optional system prompt into `InteractiveLaunchRequest` and use the vendor launcher. Require a terminal for a real attended session; config/command inspection works without one and starts nothing. Require explicit safety: Codex sandbox/approval or Claude allowed-tools vocabulary. Preserve Baikai's cross-provider and unsupported-policy refusals, rather than silently weakening them. An omitted foreground model is a visibly reported vendor default, not an exact-model claim. Propagate process exit and distinguish refusal from an executed nonzero result.

Mount `Baikai.Agent.Cli.agentCliParser` under an `unattended` subtree and interpret `runAgentCli` or `runAgentCliWithPaths`. Expose its existing `run`, `show` and `list` commands and named-job settings. Reuse `.baikai/agents.kdl`, the operator file, resolution reports and separate ceiling source. Do not flatten these into `behavior.*`, duplicate precedence or allow repository input to raise the ceiling. Preserve Baikai's exit codes and output modes: inherited output goes to real streams and is not captured in the returned record. This wrapper adds no policy exemptions, memory session, delivery receipt or durable execution claim.

Add `shikigami-agent/test/Shikigami/Agent/LaunchSpec.hs` and extend `shikigami-agent/test/Shikigami/Agent/CommandSpec.hs`. Fake commands and temporary source files prove cwd, prompt, model, effort, policy refusal, operator ceiling, redaction and exit propagation. Compare mounted unattended parsing/results to Baikai's own API. Do not install vendor assets or commit workspace changes as a launch side effect. Acceptance is config-selected Claude or Codex for both foreground surfaces, with refusals proven before process creation.


### Milestone 5: Preserve journals, package commands and document the boundary


Update `docs/operations/configuration.md`, `docs/operations/operator-cli.md`, `docs/architecture/packages.md`, `README.md` and new `docs/operations/baikai-execution.md`. Include checked field/support inventory, effective reports, complete examples, unsupported-option errors, mode/result distinctions and login requirements. Document actual process user, `HOME`, `PATH`, executable and explicit cwd for a supervised Mac worker. Host service changes remain owned by `mori://shinzui/dotfiles.nix/plans/4-bootstrap-persistent-shikigami-agents-and-validate-service-migration-learning`; no vendor login store is copied into configuration or package outputs.

Credentials remain process-local, but decision and assignment model/options descriptors and effective selection are now pinned durably. Preserve serialized inputs/results, application-owned evidence codecs, descriptor digests and existing workflow steps. New Baikai fields can change the encoded model digest even when the visible model id is unchanged. Give changed descriptors new versions, retain bindings needed to resume old work, and prove historical selections/results decode without redispatch or silent rebinding. Follow existing accepted-transcript recovery for model/tool outcomes. Document draining old work or retaining its compatible worker/bindings during promotion. If any body under `shikigami-core/src/Shikigami/Agent/` or `shikigami-core/src/Shikigami/Flow/` changes, follow `docs/workflow-versioning.md`: classify the change, declare any needed patch in `domain/`, preserve old branches and pass `just keiro-gate`. Do not hide a journal change inside a configuration refactor.

Refresh the isolated committed solve and `nix/qualification/cohort.json` plus exact metadata/vendor archives when dependencies change. A release newer than `cabal.project`'s index cutoff requires a deliberate index-state/cohort update, not an ignored override. Use `tools/qualification/export-cohort.py` as documented in `tools/qualification/README.md`. Update `nix/qualification-package.nix` and `flake.module.nix`, the actual immutable executable assembly, to include the launch executable in the operator package. Vendor CLI binaries/login are external host prerequisites. Prove installed commands outside the checkout and no reliance on sibling sources or relative assets.

Run the full affected suites and gates below after M7/M8 as well as the existing response/launch work. Update `docs/dependency-cohort.md`, `docs/shikumi-flow-decisions.md` and the Baikai contract/runbook evidence for the actual solved release family, structured result formats, TypeSafe configuration and remaining limitations. Update ADR 0040's selected-release status only after consumer proofs pass; preserve its lifecycle/confinement boundary. Record implemented structured-result and judgment adoption under ADR 0041/0045 or a focused new ADR using the existing ADR workflow. Acceptance is a successful isolated build, regression and journal compatibility proof, all five immutable role targets at the selected revision, and installed launch and judgment-example assets outside the repository. Record failed trials separately from successful retries.


### Milestone 6: Prove CLI login and hand off plan 79


With an already authenticated CLI under the intended process user, run the supplied-payload reporter through `shikigami-run-behavior` with both HTTP API key variables absent and no key in config. Select an explicit model supported by that login. Record revision, vendor version, transport, requested model, command, duration, process user and real outcome in `docs/evidence/baikai-execution/qualification.md`, retaining Baikai's weaker evidence claim. Separately open and close one real attended session in a disposable workspace with explicit policy. Never capture login files, keys or private prompts.

Each other provider has deterministic adapter coverage; mark live coverage individually. Live HTTP trials require their matching API credentials and remain optional, including TypeSafe and shared-prefix cache trials. A supplied real key alone does not cause an automatic paid smoke run. If explicitly selected during implementation, record the TypeSafe result's raw and derived values and a cache trial's actual cache-read observation separately from fixture proof; do not infer a hit from sending a marker. Lack of CLI login leaves the existing live milestone unchecked with a concrete reason. Update plan 79, `docs/evidence/local-qualification/readiness.md` and `docs/roadmap.md` with implemented transport and remaining service/trust/destination prerequisites. A standalone response proves no memory, delivery, restart or human wait. Only an actual Anthropic HTTP run can close plan 13's HTTP smoke. Complete this expanded plan only after M1–M8's required deterministic, durable and installed acceptance plus the original authenticated batch CLI and attended-session evidence, naming every untested live alternative.


### Milestone 7: Preserve structured inputs and answers through application boundaries


Adopt `UserData`, `AssistantData`, `DataContent` and atomic data stream events in the actual response consumers, cache/trace integration and application replay. Add `shikigami-core/src/Shikigami/Decision/Answer.hs` for a bounded, versioned application-owned answer snapshot containing the structured value, complete probability maps, optional confidence and method. Preserve absence as absence. A response without call evidence must still retain its answer data. Use public Baikai full-response codecs where a Baikai response is persisted, including the qualified Shikumi response cache; do not replace an application-owned journal codec with upstream JSON.

Extend `shikigami-core/src/Shikigami/Execution/Transcript.hs` to capture and restore user data and assistant data with explicit new replay versions where necessary. Retain old text/thinking/tool encodings and the existing block, payload-size and protected-read restrictions. Data blocks are allowed only at their proper user/assistant positions and never as fabricated tool invocations. `assistantText` must not turn a data-only response into successful empty prose; text-only consumers refuse incompatible results, while judgment consumers read the structured value. Restoring a response for replay must not attach historical evidence as a fresh terminal observation.

Extend the internal decision runner result with bounded structured answer observations correlated to their actual attempt IDs. Keep existing callers' typed-result API through a compatibility wrapper. In `shikigami-core/src/Shikigami/Decision/Contract.hs` add a format-2 `DecisionOutcome` that can retain these answer snapshots alongside the derived typed `result`. Read format 1 unchanged, write its original representation for historical/no-observation paths, and use the new representation only behind the declared workflow compatibility boundary. Snapshot content belongs in the protected decision outcome/payload path, not in public compliance facts or the payload-free decision ledger. Capture each successful complete or stream terminal exactly once; intermediate/failed streams cannot publish a successful answer. Bound each answer to 256 blocks and the aggregate encoded retained answer content per invocation to 1 MiB, or a stricter existing admission limit. Oversized or malformed snapshots produce bounded failure without treating missing data as success.

Add `shikigami-core/test/Shikigami/BaikaiStructuredContentSpec.hs`, register it in the test entry point and Cabal module list, and extend `shikigami-core/test-postgres/Shikigami/ExecutionTranscriptSpec.hs`. Cover mixed and data-only content, optional fields, non-unit-sum distributions, fractional provider scores, malformed shapes, unknown versions and retained historical fixtures. Exercise a real Shikumi cache hit: answer probabilities survive, historical call evidence is removed, and no new remote-attempt receipt is invented. Restart an accepted structured model operation and verify exact snapshot/result recovery with a zero-call provider fixture. M7 passes only when structured data survives complete, synthetic stream, response persistence/cache and application replay without flattening or renewed execution claims.


### Milestone 8: Expose governed TypeSafe judgments and a durable example


Add direct `baikai-typesafe` dependencies only to application components importing its public provider. Extend `DecisionModelSpec` parsing and credential resolution in `shikigami-core/src/Shikigami/App/Config.hs` with `behavior.decisionModels[].provider: typesafe`, filtering exact models by `TypeSafeSystemOne` and catalog judgment capability. Add opaque `credentials.providers.typesafe.api_key` with explicit `TYPESAFE_API_KEY` binding, required only when a TypeSafe binding is configured. Support an optional per-binding `base_url` for a local fixture or intentional gateway; it participates in the immutable descriptor/digest and effective report. Require the explicit credential binding for that endpoint, retaining redaction of nested malformed configuration. Do not make TypeSafe a legacy generative `behavior.provider` or a whole-run coding model. Require `thinking: default` and omit `max_tokens` for TypeSafe; explicit `none` is a forbidden reasoning request here.

In `shikigami-core/src/Shikigami/Decision/ModelCatalog.hs`, admit TypeSafe only for judgment-capable registered programs and closed-set schemas. Add an application-owned decision-output capability to the program descriptor, distinguishing the existing generative contract from an explicitly declared closed-set judgment contract. Historical descriptors decode to the generative contract and retain their old encoding; new judgment metadata joins a new immutable registration and its digest. Slot admission intersects that contract with the selected model before dispatch. Plain free-text, mixed open-ended output or tool programs refuse before transport. Extend `shikigami-core/src/Shikigami/Behavior/Compatibility.hs` with a TypeSafe branch using public `refuseGenerationControls`/`prepareJudgment` checks, and extend `shikigami-core/src/Shikigami/Behavior/Provider/Call.hs` with the actual `(typesafe, typesafe-system-one, endpoint scheme, exact model id, unset thinking)` tuple. Preserve explicit profile and alias admission; do not automatically grant defaulted thinking, another endpoint or another model.

Register `Baikai.Provider.TypeSafe.Api.typesafeProvider` in the invocation-local decision provider set in `shikigami-core/src/Shikigami/Program/DecisionRunner.hs`. Let the qualified Shikumi router select judgment capability before generative schema handling and build one structured state containing effective instructions, input and any permitted demonstrations. Reuse its public schema reader/typed derivation; compare representative declarations with Baikai's `compileJudgments`, including question ordering and unsupported constraints. The final application merge must retain transport deadline, opaque credentials, correlation and evidence while refusing explicit generation controls. It must not reintroduce generative defaults after routing or strip an operator constraint to make a call pass. In particular a finite output-token policy cannot be honored by adding `maxTokens` to TypeSafe: refuse that unsupported policy before IO. Unknown prices or catalog limits remain unknown and cannot satisfy finite accounting requirements as zero. Preserve actual-call counting, bounded retries, asynchronous cancellation and terminal persistence below Shikumi's retry loop.

Add `shikigami-core/src/Shikigami/Program/Decision/JudgmentExample.hs` with a registered ticket judgment program returning rich `Noul` urgency, `Choice` category (`billing` or `technical`) and `Score` severity (`Minor`, `Disruptive`, `Blocking`) values through qualified public Shikumi APIs. Explicitly pin the effective boolean threshold, choice weights, score cuts, defaults, schemas and derivation version in registration. Baikai's neutral answer remains unchanged; Shikumi's derived answer is a separate committed result. Do not renormalize raw probabilities, manufacture missing confidence or overwrite a provider-selected label/expected score with the local derivation. Include a fixture whose provider choice differs from the locally weighted choice so this separation is observable. A new threshold/cut/weight version changes fresh decisions only, never a committed result.

Add `shikigami-core/src/Shikigami/Flow/ShikumiJudgmentExample.hs`, register Flow `shikumi-judgment-example` with one finite `judge` slot/alias, extend the closed labels in `Shikigami.Flow.Decision`, and add `agents/proof/shikumi-judgment-example.dhall`. The Flow takes `{"ticket":"Checkout is unavailable."}` and returns the rich judgment result; its committed decision outcome separately retains the raw answer snapshot. It neither delegates nor emits an undeclared effect. Declare that it does not use the process default model. Add its programs/codecs to `DecisionServices`; use the existing queue/worker commands and retained-codec replay rather than inventing a separate execution engine. Follow `docs/workflow-versioning.md` for every affected Flow/workflow body and generated specification, preserving old branches and step names.

Add `shikigami-core/test/Shikigami/TypeSafeDecisionSpec.hs` and `shikigami-core/test-postgres/Shikigami/TypeSafeDecisionWorkflowSpec.hs`, and register them in their actual test entry points/Cabal modules. Use the real public TypeSafe adapter against a loopback server with public synthetic credentials, through normal configuration, alias/profile admission and the real Handan/Shikumi runner. Assert one `POST /v1/systemone`, exact state/question schema, no forbidden defaults, and complete/stream result parity. Prove missing/wrong-provider credentials, unsupported schemas/history/tools, invalid probabilities/legends, provider refusal, unknown model, nonzero HTTP status, timeout and cancellation produce the expected bounded failure and actual-attempt records. A finite unrepresentable policy must leave the HTTP counter at zero.

PostgreSQL acceptance enqueues the proof Flow, captures raw and derived results, restarts the worker, and replays the committed outcome with executables/credentials absent and changed current derivation settings; results remain identical and the HTTP counter does not increase. Pending runs either retain the original model/program/settings or refuse before dispatch. Terminal-persistence failure stays unresolved, never a probability-shaped success. Record deterministic evidence in `docs/evidence/baikai-execution/structured-judgments.md` and document the runnable example and optional live trial in `docs/shikumi-flow-decisions.md`. M8 passes when an operator can configure and execute the example against the fixture through normal queue/worker entry points, with full answer preservation and governed restart behavior. Remote TypeSafe coverage is recorded separately and is not implied by these local proofs.


## Concrete Steps


Run from the repository root. Discover sources and verify registry/releases before selecting new bounds or pins:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
git status --short
mori registry list
mori registry search baikai
mori registry show shinzui/baikai --full
mori registry docs shinzui/baikai
curl -fsSL https://hackage.haskell.org/package/baikai/preferred.json
curl -fsSL https://hackage.haskell.org/package/baikai-claude/preferred.json
curl -fsSL https://hackage.haskell.org/package/baikai-openai/preferred.json
curl -fsSL https://hackage.haskell.org/package/baikai-agent/preferred.json
curl -fsSL https://hackage.haskell.org/package/baikai-effectful/preferred.json
curl -fsSL https://hackage.haskell.org/package/baikai-trace-otel/preferred.json
curl -fsSL https://hackage.haskell.org/package/baikai-typesafe/preferred.json
curl -fsSL https://hackage.haskell.org/package/baikai-typesafe-0.1.0.1/baikai-typesafe.cabal
curl -fsSL https://hackage.haskell.org/package/typesafe-hs/preferred.json
curl -fsSL https://hackage.haskell.org/package/shikumi/preferred.json
curl -fsSL https://hackage.haskell.org/package/shikumi-0.5.0.0/shikumi.cabal
curl -fsSL https://hackage.haskell.org/package/kioku-core-0.12.0.1/kioku-core.cabal
curl -fsSL https://hackage.haskell.org/package/baikai-effectful-0.4.0.5/baikai-effectful.cabal
git ls-remote --tags https://github.com/shinzui/baikai.git 'refs/tags/baikai-*'
git ls-remote --tags https://github.com/shinzui/shikumi.git 'refs/tags/shikumi-*'
```

Expected after the Shikumi 0.5 publication: the latest Baikai/Shikumi pair resolves, but adding published Kioku core 0.12.0.1 refuses because its Shikumi bound excludes 0.5. The original missing-Shikumi-release prerequisite is resolved; the owning Kioku compatibility revision or release remains outstanding. Recheck the whole imported Shikumi family, Kioku and Effectful descriptors/release tags before changing application pins; discovery does not itself establish a successful solve. If an owning release has not yet admitted the target, retain the current pins and record the precise outstanding dependency. Do not run the following as an upgrade qualification until the descriptor prerequisites are met.

Preserve ignored `cabal.project.local`. The helper prints one isolated committed project filename. Use it consistently and regenerate after changing the committed descriptor. First use `--dry-run` to establish the exact dependency closure; a solver refusal is evidence of an unresolved prerequisite, not permission for a bounds override:

```bash
qualification_project=$(python3 tools/qualification/prepare-project.py)
nix develop --command cabal build all --enable-tests --dry-run --project-file="$qualification_project"
nix develop --command cabal build all --enable-tests --project-file="$qualification_project"
nix develop --command cabal test shikigami-core-test shikigami-agent-test \
  shikigami-workers-test shikigami-server-test -j1 \
  --test-options=--num-threads=1 --project-file="$qualification_project"
nix develop --command just keiro-gate
bash tools/check-migration-schema-isolation.sh
git diff --check
```

Run these database-backed suites serially: `-j1` selects one Cabal suite at a time and `--num-threads=1` selects one case inside each suite. FRIC-38 and the repeated occurrence FRIC-47 show that concurrent Git fixtures can overrun their native executor deadlines. Keep those production/fixture deadlines unchanged. The workflow gate compares all source files with the commit, so run it after committing the candidate.

Expected: all selected suites pass, no unapproved workflow change, only the documented historical migration exception, and no whitespace errors. For the 0.10 migration run disposable PostgreSQL suites as well, because pinned selection/digest and accepted-result recovery compatibility are part of upgrade acceptance:

```bash
nix develop --command cabal test shikigami-core-postgres-test \
  shikigami-migrations-smoke -j1 --test-options=--num-threads=1 \
  --project-file="$qualification_project"
```

After exporting the actual solved `plan.json` with the existing exporter, verify all role packages:

```bash
nix build --no-link .#shikigami .#shikigami-server .#shikigami-worker .#shikigami-migrate .#shikigami-agent-launch
```

The following batch response interfaces remain deferred: the application still pins affected releases and its resolver refuses both CLI choices. Execute these future acceptance commands only after compatible released adoption, positive cleanup/deadline/output/confinement checks and the remaining CLI resolver/dispatch implementation. Create a private config `/tmp/shikigami-baikai/cli.yaml` and a disposable existing working directory. Replace `EXPLICIT_CLI_MODEL_ID` with an actual model id supported by the login; it is a placeholder, not an application alias:

```yaml
behavior:
  provider: codex-cli
  model: EXPLICIT_CLI_MODEL_ID
  options:
    thinking: low
  cli:
    executable: codex
    working_directory: /tmp/shikigami-baikai/workspace
    ephemeral: true
    skip_git_repo_check: true
```

```bash
nix develop --command cabal run shikigami-run-behavior \
  --project-file="$qualification_project" -- --check-config \
  --config /tmp/shikigami-baikai/cli.yaml
nix develop --command env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u CODEX_API_KEY \
  cabal run shikigami-run-behavior --project-file="$qualification_project" -- \
  --config /tmp/shikigami-baikai/cli.yaml \
  --agent fixtures/qualification/agents/service-health-reporter.dhall \
  --payload '{"text":"Qualification marker EP80: all supplied services are healthy."}'
```

Expected: `configuration valid` without spawning for the first command, and real reporter text referencing the supplied marker from the selected CLI for the second. This proves a response, not delivery. Repeat with `claude-cli`, Claude executable/model and no Codex-only settings when that login is available. An HTTP `anthropic` selection without a key must refuse naming `credentials.providers.anthropic.api_key` before dispatch.

An attended target config in `/tmp/shikigami-baikai/interactive.yaml` uses separate vocabulary:

```yaml
launch:
  provider: codex
  working_directory: /tmp/shikigami-baikai/workspace
  safety:
    codex_sandbox: read-only
    codex_approval: on-request
```

```bash
nix develop --command cabal run shikigami-agent-launch \
  --project-file="$qualification_project" -- interactive --check-config \
  --config /tmp/shikigami-baikai/interactive.yaml
nix develop --command cabal run shikigami-agent-launch \
  --project-file="$qualification_project" -- interactive \
  --config /tmp/shikigami-baikai/interactive.yaml \
  --prompt 'Describe the current directory without changing files.'
nix develop --command cabal run shikigami-agent-launch \
  --project-file="$qualification_project" -- unattended --help
```

Expected: the check starts nothing; attended execution opens the selected CLI terminal session and propagates exit. Unattended help displays Baikai's `agent` group; `unattended agent --help` displays `run`, `show`, `list` and original configuration options. Put this job in a disposable repository's `.baikai/agents.kdl`:

```kdl
jobs {
  inspect {
    provider "codex"
    working-dir "."
    timeout "2m"
    output "capture"
    safety {
      capability "read-only"
    }
  }
}
```

Run from that disposable repository with the installed command:

```bash
shikigami-agent-launch unattended agent show inspect
printf '%s\n' 'Describe this disposable repository without changing files.' \
  | shikigami-agent-launch unattended agent run inspect --prompt-stdin
```

Expected: source/policy report followed by a bounded job honoring the operator ceiling and preserving vendor exit. No Shikigami durable run or sink receipt is created. Execute these live model commands during implementation/qualification, not merely plan authoring.

After M7/M8 exist, run their focused deterministic consumer and restart checks from the repository root. Name both new groups `TypeSafe judgments` so the pattern selects the real adapter and durable Flow cases, and ensure the structured-content group is included in the full suites above:

```bash
nix develop --command cabal test shikigami-core-test \
  --project-file="$qualification_project" --test-options='--num-threads=1 -p TypeSafe'
nix develop --command cabal test shikigami-core-postgres-test \
  --project-file="$qualification_project" --test-options='--num-threads=1 -p TypeSafe'
```

Expected: the local HTTP fixture observes the one-state closed-set request, raw provider selection and fractional score are preserved, the pinned rich derivation is correct, and restart replay adds zero HTTP calls. These suites provision their own disposable fixture/database; they require neither `TYPESAFE_API_KEY` nor a vendor account. Historical generative decision and transcript cases must still pass in the full suites.

The new TypeSafe operator configuration below is an implementation target, not an interface available at plan-update time. Save it privately as `/tmp/shikigami-baikai/judgment.yaml`. An explicit live run uses a separately supplied `TYPESAFE_API_KEY`; a manual loopback run instead sets per-binding `base_url` to the test server and supplies only its public synthetic credential. Do not point a real credential at the fixture. Keep the key out of YAML and command arguments:

```yaml
behavior:
  provider: stub
  decisionModels:
    - alias: judge
      version: "1"
      bindingId: typesafe-judge
      bindingVersion: "1"
      provider: typesafe
      model: jev-latest
      thinking: default
      timeout_ms: 30000
```

With the normal disposable migration/bootstrap setup, run the same installed entry points used by the PostgreSQL fixture:

```bash
export SHIKIGAMI_AGENTS_DIRECTORY=agents/proof
shikigami --config /tmp/shikigami-baikai/judgment.yaml --check-config
shikigami --config /tmp/shikigami-baikai/judgment.yaml \
  enqueue-run shikumi-judgment-example \
  --payload '{"ticket":"Checkout is unavailable."}' --key ep80-judgment-1
shikigami-worker --config /tmp/shikigami-baikai/judgment.yaml
```

Expected: configuration validates without calling TypeSafe; enqueue/worker execution records a completed rich judgment outcome inspectable through the existing run inspection command and payload-authorized result path. The deterministic fixture expects urgency probability 0.83, category probabilities 0.2/0.7 and severity probabilities 0.1/0.3/0.6 with provider expected score 1.5; the locally derived score follows the separately pinned Shikumi settings. A live answer need not match those synthetic values. Repeat observation after restart without increasing the fixture's call count. Use fresh idempotency keys for deliberately new trials. Package qualification supplies an installed proof-agent directory outside the checkout rather than relying on the relative development path above.


## Validation and Acceptance


With no configuration, stub commands still run without keys/database. Legacy Anthropic retains its API/model and opaque key requirement. Every new response choice reaches its intended public Baikai handler, proved by fake markers or local HTTP fixtures. Unknown selections/models, missing matching credentials, invalid options, unsupported tool/schema requests and forbidden profiles refuse before external IO. CLI config validates without keys; missing executable/logout is a visible failure rather than fallback to HTTP or stub.

Meaningful regression cases cover exact cwd/argument transport, cancellation including children, API key/header/raw-argument redaction, no unsupported option loss, allowed/refused CLI tuples and no registry leakage. A configured reporting process must not silently acquire vendor-native mutation authority. Fake tests establish dispatch/policy contracts, not vendor login or remote model evidence.

For the refreshed cohort, prove explicit off versus omission in config, profile tuples, translated requests and evidence; refuse unsupported clamping before dispatch. Prove native cache policy admission/refusal for the exact binding and retain older saved-model defaults. Existing pinned descriptors must either resolve to their retained compatible binding or refuse explicitly, never rebind to a newly encoded model. Completed decision and accepted model/tool outcomes must survive the dependency change without another provider call. The model/output/event migration must compile all affected consumers and keep judgment-only models out of generative paths. Positive cancellation probes on native Darwin and Linux qualify the selected release under its documented inherited-process-group limit; deadline/output bounds and reporter authority need separate proof.

The expanded acceptance additionally requires all of M7/M8: structured content through complete/stream/cache/replay; configured TypeSafe through the public adapter and real Shikumi decoder; default and weighted local derivation with preserved neutral provider answers; and a runnable durable supplied-ticket Flow. Invalid schema, generation controls, model/alias/profile escapes and unsupported finite budgets must leave invocation markers untouched. Complete and stream terminals persist one actual-attempt outcome without treating probabilities as compliance evidence. Fresh decisions under changed settings can change answers, while restart of a committed old decision preserves its full raw/derived outcome using retained codecs and zero new transport calls. Do not mark this plan complete with only dependency builds or pure decoder tests.

Launch tests prove wrong-provider safety, exceeded ceiling and repository ceiling override start nothing; nonzero exit propagates; process results never become durable `Response` success. The isolated build, affected suites, workflow gate, frozen role builds and installed commands outside checkout must pass. Real CLI response and attended session records name vendor version, requested model, user and outcome, and distinguish reported facts from unverified served-model identity. Plan 79's remaining service and fault scenarios stay independently unchecked until observed.


## Idempotence and Recovery


Config checks, fake tests and command inspection are repeatable and make no real model call. Test fixtures own and clean up processes, directories and markers on success, exception and cancellation. Never stop unrelated user CLI sessions. Real model trials can consume usage every time; use fresh public markers and record attempts rather than promising one physical call.

A remote call can still finish before its local durable acknowledgement, so do not promise exactly-once remote execution. Preserve the accepted model/tool transcript recovery and pinned assignment/decision semantics already implemented by their owners. Keep mutable coding jobs out of the response path. Drain old runs or retain compatible workers and descriptor/binding versions during rollout; pending selections and profiles must refuse unavailable replacements rather than silently rebinding. Roll back with the prior configuration and immutable package only while all written journal/selection codecs remain readable; otherwise roll forward using retained compatibility branches. Relogin never rewrites policy snapshots.

Use disposable workspaces for live attended/unattended trials. Preserve changed trees as evidence and use a new directory for retry rather than resetting a user's work. Recover API failures by fixing matching credential references, CLI failures by fixing executable/login/cwd, and policy refusals by an explicit operator decision rather than automatic downgrade. Provider/login availability remains outside readiness probes.

For judgments, changing thresholds, cuts or weights is an explicit new immutable program registration. Cached answer data may be reused for a deliberately new derivation, with old call evidence removed; it cannot rewrite an existing committed workflow result. Retain format-1 outcome/context/assistant readers when introducing structured versions, and deploy readers before writers. On partial terminal persistence or a lost result append, preserve the unresolved attempt and existing retry accounting; never fabricate a fresh observation from a cached response. Structured input/answer snapshots remain subject to the existing protected-payload access and size limits.


## Interfaces and Dependencies


The implemented resolved response type in `shikigami-core/src/Shikigami/App/Config.hs` distinguishes stub and three HTTP APIs, carrying exact Baikai model/options and opaque credentials. The two CLI names are currently refused; their future configuration will name operator executable/cwd after released adoption and consumer qualification. Preserve `newBehaviorEnvFor` as the common composition boundary and `providerCallFor` in `Behavior.Provider.Call` as the shared actual-dispatch projection. Keep the operator decision catalog, durable execution selection and retained-binding owners intact. Use direct Haskell record field names and follow the repository's record-pattern guidance.

The typed compatibility check in `Shikigami.Behavior.Compatibility` accepts actual selected model/options plus request context/tool requirements and returns a permanent refusal before IO. Each model caller maps that result into its existing failure algebra. A launch-specific resolver/entry point in the agent package needs no database; mounted unattended parsing/running uses public `Baikai.Agent.Cli` records and returns exit/output without a local process engine.

Preserve the response guard's pure contract, extending its refusal constructors for unsupported requirements as needed. Rendering identifies the public setting or requirement and never includes a credential, prompt or raw arguments:

```haskell
validateResponseRequest ::
  Model -> Options -> Context -> Either ResponseCompatibilityError ()

renderResponseCompatibilityError :: ResponseCompatibilityError -> Text
```

`Model`, `Options` and `Context` are the selected public Baikai types. The guard validates support; it neither changes the request nor downgrades its requirements. Profile permission checking remains the existing separate check against the pinned policy and actual `providerCall`.

The TypeSafe binding belongs to the finite decision catalog and an explicitly judgment-capable registered program. Public integration uses `TypeSafeSystemOne`, `isJudgmentOnly`, `Baikai.Judgment.prepareJudgment`, `Baikai.Provider.TypeSafe.Api.typesafeProvider` and the named full-response codecs. The application-owned `Decision.Answer` snapshot preserves neutral data, while qualified Shikumi `Noul`/`Choice`/`Score` outputs and pinned `Params.decisionSettings` define local derivation. New outcome/replay codecs retain historical readers and serialize answer data separately from transport/compliance facts. A compatibility wrapper preserves the existing typed `runDecisionProgram` contract while the durable path receives structured observations correlated to actual attempts.

Required response packages are `mori://shinzui/baikai/packages/baikai`, `mori://shinzui/baikai/packages/baikai-claude` and `mori://shinzui/baikai/packages/baikai-openai`. Foreground integration already uses `mori://shinzui/baikai/packages/baikai-agent` at the agent composition leaf. Include the existing Effectful and trace adapters in the coherent release solve. Select verified released versions in M1 subject to the published Shikumi/Kioku/Effectful prerequisites above, freezing exact descriptors and source hashes; do not weaken bounds or advance unrelated runtime packages to obtain a solve. Models, reasoning constructors and safety vocabulary must come from the selected coherent Baikai release.

M8 adds `mori://shinzui/baikai/packages/baikai-typesafe` 0.1.0.1 and its released transitive wire client `mori://shinzui/typesafe-hs/packages/typesafe-hs` 0.1.0.0 to the target closure. The qualified Shikumi release must support judgment routing, rich output derivation, decision settings and structured cache codecs against the selected Baikai version. A local checkout containing those APIs does not establish published compatibility. The existing Hackage/cohort prerequisite applies to every one of these packages.

No authorization or delivery service is needed for deterministic adapter tests or foreground launch commands. M7/M8's durable acceptance uses disposable PostgreSQL and local HTTP fixtures; optional live TypeSafe tests require its own matching API key, never a Claude/Codex login. M6 requires an authenticated vendor CLI; other live HTTP tests require matching API credentials. PostgreSQL 18, Shomei/Kikan-En trust/grants, Kawa and later Danwa/Kizashi remain plan 79 prerequisites. Vendor CLI login replaces none of those credentials.


## Revision Notes


2026-10-06 UTC: Created after auditing the existing plan-13 builder and released Baikai surfaces. Scoped missing selectable transports/options and foreground integration, retained existing policy owners, and corrected the unconditional API-key prerequisite in plan-79 readiness guidance.

2026-10-06 UTC: Implementation separates deliverable HTTP/foreground integration from the batch release prerequisite; the public unattended grammar retains its `agent` group. Trials and final acceptance remain tracked independently.

2026-10-06 14:40 UTC: Split implemented HTTP/foreground work from remaining CLI acceptance after both released adapters failed descendant cancellation probes. Added actual parser spelling, frozen cohort, pure request guards and ADR 0040; no authenticated batch or service result is claimed.

2026-10-06 14:49 UTC: Added preflight refusals for Anthropic adaptive minimal clamping, none-tool choice with advertised tools, and invalid schema document roots. Real attended Codex trial returned the public marker and exit 0; batch remains blocked.

2026-10-06 15:03 UTC: Qualified the mounted unattended foreground job with a real read-only Codex marker/exit trial. Corrected the runbook repository flag to the released parser's `--config`; this leaves batch reporter acceptance open.

2026-10-06 15:40 UTC: Final review found that the legacy pre-dispatch tuple classified every HTTP tag as HTTPS even though compliance evidence already derives its actual scheme. Corrected the tuple for endpoint overrides and extended the five-surface matrix with plaintext refusal/explicit admission. The earlier immutable build is superseded and must be rerun at this corrected code revision.

2026-10-06 16:30 UTC: Final `9ce65b2` source build, core/agent tests and unchanged journal gate pass; five immutable role targets and 11 outside-checkout installed checks pass. Recorded exact package outputs, corrected harness attempts and independent integration outcomes. The overall plan remains open for the owning released batch lifecycle/confinement fix and deferred CLI reporter milestones.

2026-10-06 16:40 UTC: Filed the cancellation defect in the owning Baikai bug-report OKF as `mori://shinzui/baikai/okf/bug-reports/concepts/BUG-1`. Reran both bounded negative probes and recorded strict profile/log validation. The report is consumer-observed (`reported`), not an owning-repository confirmation or a fix; remaining CLI milestones stay open.

2026-11-02 UTC: Refreshed against authoritative Hackage descriptors, upstream release tags and current Shikigami/Baikai source. The cancellation fix is published, but remains unadopted here. Added the latest 0.10 model/output, reasoning-off, native-cache and evidence migration, published Shikumi/Kioku/Effectful solve prerequisites, and current decision/assignment/transcript ownership. Preserved October qualification as historical evidence and all unverified batch/upgrade milestones as open; no dependency or runtime change was made during this update.

2026-11-02 UTC: Expanded scope at the user's request to adopt all discussed capabilities. Added structured content/cache/replay preservation as M7 and governed TypeSafe judgments with a runnable durable example as M8, pinned raw-versus-derived result semantics, conditional credentials, compatible released Shikumi prerequisites and explicit restart/refusal acceptance. Strengthened reasoning-off/shared-prefix-cache consumer proof and updated completion, packaging and operator examples. No implementation or live qualification is claimed by this plan edit.

2026-11-03 UTC, Shikumi release follow-up: Verified the new published Shikumi 0.5 family and successful Baikai 0.10 pair solve, resolved FRIC-46 and recorded the next consumer prerequisite in Kioku as FRIC-48. Added exact paired positive/negative solve evidence and current release guidance while preserving the application pins and historical runtime qualification.
