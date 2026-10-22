---
id: 74
slug: run-shikumi-decisions-through-governed-provider-calls
title: "Run Shikumi decisions through governed provider calls"
kind: exec-plan
created_at: 2026-09-26T18:34:42Z
intention: "intention_01m3fft4cceb1ba9t3fammx5x4"
master_plan: "docs/masterplans/13-compose-shikumi-decisions-in-durable-flows.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-26T18:34:42Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-21T20:30:29Z
      mode: "update"
      note: "Coordinate Shikumi MP-12 without blocking current scope; bind parameter state and derivation, preserve committed results and distinguish probability data from call evidence"
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T00:41:18Z
      verdict: "changes-requested"
      note: "Selected Baikai is 0.7.2.0 (cabal.project), not the 0.7.0.0 cohort; ApiProvider wrapper must carry structuredOutput; Behavior.Compatibility pre-dispatch gate not mentioned; Mori ADR handles now resolve"
---

# Run Shikumi decisions through governed provider calls


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Execute a registered typed decision program using exactly the model, credential binding, and thinking mode authorized for that invocation. Every real provider attempt, including a second node or internal retry, crosses the same policy and evidence callbacks. A deterministic two-node program and isolated fake providers demonstrate the result without a live key.

Hard dependency: `docs/plans/73-define-typed-decision-programs-and-authorized-model-catalogs.md` supplies typed programs, immutable descriptors, bounded errors, model resolution, and call callbacks. This plan can proceed alongside `docs/plans/75-persist-decision-call-evidence-across-retries-and-restarts.md` using fake callbacks. `docs/plans/76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md` later places this runner inside durable Flow steps.


## Progress


Implementation has not started. Seed unchecked milestone entries when implementation begins.


## Surprises & Discoveries


None recorded during implementation.


## Decision Log


2026-09-26: Use Handan's public `Runtime` with an invocation-local default model and an isolated Baikai provider registry. Released APIs permit this without copying Handan's interpreter chain or changing upstream packages.

2026-09-26: Wrap actual provider attempts below Shikumi's retry layer. A wrapper around the whole task would miss internal calls; Shikumi's billing observer does not contain full provider evidence and cannot replace the evidence boundary.

2026-09-26: Preserve program-owned schemas and prompt rendering while enforcing the final model, credentials, thinking, evidence request and limits. Fill-only defaults are not an authorization gate.

2026-10-21: Revision for [Shikumi MP-12](mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs) coordination: verify pinned effective parameter and derivation identities before pending execution and keep upstream API adaptation inside this runner. Probability-bearing results remain ordinary validated typed outputs; Jev and calibration are outside this plan. See [ADR 0041](../adr/0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md).


## Outcomes & Retrospective


To be filled during implementation. Record the qualified dependency versions and distill the provider ownership decision into local ADRs.


## Context and Orientation


`shikigami-core/src/Shikigami/Behavior/Run.hs` stores a Handan runtime beside Baikai `model`, `options`, `traceSink`, tools and limits. Its `runProgramTask` calls a registered Handan task with that runtime but never forwards the other fields. `Shikigami.Program.Registry` currently contains deterministic tasks, so existing tests do not expose the missing model/credential boundary. `Shikigami.Behavior.Provider` owns `ProviderCall`, `providerCall`, and `constrainBehaviorEnv`. Refactor their shared predicate so the exact model/options passed to transport can be checked without constructing unrelated environments.

Mori locates dependency sources at `mori://shinzui/handan`, `mori://shinzui/shikumi`, and `mori://shinzui/baikai`. Project-relative source files are `handan-core/src/Handan/Runtime.hs`, `shikumi/src/Shikumi/LLM.hs`, `shikumi/src/Shikumi/Routing.hs`, and `baikai/src/Baikai/Provider/Registry.hs`; artifact-level source-file URIs are pending. Handan's pinned revision `8e98b0a955f908f70657c04f384b6286e4967422` exports `Runtime(..)` and `runProgramWith`. Its default constructor selects an Anthropic model independently of Shikigami configuration. Construct or derive an invocation runtime explicitly instead of using that default selection.

Shikumi 0.4.0.0 exports `LLMConfig.registry` and `runLLMResilient`; the latter performs retries around calls dispatched through the supplied registry. Ambient routing replaces a Program node's placeholder model and applies the derived response schema before reaching the registry. Baikai exports `newProviderRegistryFrom`, `lookupApiProviderWith`, `apiProviderWith`, handler selectors `complete` and `stream`, and `completeRequestWith`. These public APIs exist in the inspected Baikai 0.7.0.0 tag as well. A private wrapper can therefore enforce the final request and capture actual transport attempts. Never mutate the global provider handler to carry run-specific credentials or model choice.

Release verification on 2026-09-26 found Shikumi 0.4.0.0 on Hackage/tag `59d38bcfcedc85602564063d35703f75480a6156`, Baikai 0.7.1.0 on Hackage/tag `9f269c917c15d5449067f3c96e7ce3452fc6d7eb`, and no released Handan package/tag. `docs/dependency-cohort.md` documents an older selected Baikai cohort, and `cabal.project.local` currently overrides some packages. Inspect the actual solver plan and tagged sources rather than assuming a local checkout's newer APIs are released. No upgrade or bound workaround is required by this design; if qualification shows otherwise, verify the registry and upstream tags before changing `cabal.project` or package bounds.

[ADR 0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md) requires checking the pinned policy at dispatch. [ADR 0010](../adr/0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md) requires preserving upstream evidence as encode-only data. [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md) keeps all IO in interpreters. Upstream request-default and billing decisions `mori://shinzui/shikumi/okf/adrs/concepts/ADR-12` and `mori://shinzui/shikumi/okf/adrs/concepts/ADR-13` (locally verified IDs; current registry handle resolution is stale) confirm that defaults exclude credentials and that billing callbacks are not complete execution evidence.


## Plan of Work


### Milestone 1: Qualify an isolated typed runner


Create `shikigami-core/src/Shikigami/Program/DecisionRunner.hs` with an IO runner taking a typed registered program, `PreparedDecision`, the pinned profile, a process-local model/credential binding, call hooks, and validated input. Verify descriptor equality before executing a pending decision. Run the program using `Handan.Runtime.runProgramWith` and a runtime whose model and `LLMConfig.registry` belong to this invocation. Preserve configured retry, budget and rate-limit policy when deriving the runtime; do not reset them by repeatedly calling default constructors.

Descriptor equality includes EP-1's parameter-state digest/format and local derivation version. Execute the immutable registered state rather than applying current optimizer settings or mutable defaults. A mismatch or unavailable pinned state fails before dispatch; a matching provider request/cache key cannot authorize substitution. Test this with current `Params` fixtures. `mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs` may later extend parameters, output types and routing, but is not a hard dependency here. Qualify a future adoption inside the adapter without changing the Flow-facing static-slot/model/input contract or weakening actual-option checks for existing transports.

Start with a key-free two-node `Predict` fixture in `shikigami-core/test/Shikigami/DecisionRunnerSpec.hs` and two isolated fake providers. Assert the registered schema actually reaches transport, input affects the typed result, and both nodes use the chosen exact model. A concurrent test runs two invocations with distinct credentials/models and observes no cross-talk. Keep old `runProgramTask` behavior compatible; this change adds a decision runner, not an incidental migration of all existing Handan tasks. Run the core suite at the end of this milestone.

### Milestone 2: Govern every actual attempt


Build a private `ApiProvider` wrapper around the selected trusted handler. Both its blocking and streaming operations must assemble effective options, inject the operator-resolved credential, constrain thinking and token settings, set the evidence request, and enforce the exact pinned provider/API/endpoint/model/thinking tuple before delegating. Preserve response schema, sampling, and continuation metadata owned by Shikumi. Reject an explicit node setting that would escape the invocation's permitted tuple rather than silently accepting it. Refuse unauthorized base URLs, credential overrides, fallback models and tools; the decision programs expose no protected-effect tools. An authorized credential may rotate under the same opaque binding only if its authority and endpoint semantics remain the same; a missing binding cannot fall back to environment lookup.

Use Baikai's public evidence strictness checks on the final options as well as the Shikigami profile predicate. If the outer registry checked earlier options, repeat the strictness check after adding required evidence; retain the wrapped handler's `describeThinking` and `strengthCeiling`. Dispatch through the real registry's public entry point or its equivalent complete public preflight/terminal contract, without recursively re-entering the wrapper. Ensure a blocking call drained from a stream is counted once, not once per wrapper method. A stream cancellation must leave an unresolved expected attempt rather than invent a successful terminal.

After preflight, call `beginCall` before invoking the handler. Use its attempt ID in `configureEvidenceCall`, preserve Baikai's independent provider call ID, and call `finishCall` with the actual response/terminal evidence before returning success. Every retry inside `runLLMResilient` traverses this wrapper again and receives a distinct attempt ID. Only record retry/fallback/continuation relationships when the runtime supplies enough evidence; otherwise preserve decision-level grouping and attempt order without inventing a structural node identity. Await evidence persistence even if optional telemetry fails. Exceptions from admission/evidence callbacks must not become retryable provider errors.

Retain the outer behavior attempt timeout and existing limits. Profile forbiddance and malformed results are permanent bounded failures; transient provider failures retain existing retry classification. Unknown cost or a lost terminal cannot reset budget usage to zero on restart: the durable hook owns conservative run-level accounting. Shikumi's in-memory budget is an additional limit, not a replacement for that durable check. The test provider must observe zero dispatches for all denied final tuples.

### Milestone 3: Prove validation and evidence completeness


Decode and domain-validate the typed output before returning a successful `DecisionOutcome`. Failures must not become a successful no-match. Test two calls in one program, a transient failure followed by retry, permanent failure, invalid JSON, schema mismatch, domain rejection, missing evidence, evidence-write failure, cancellation, and an explicit forbidden thinking override. A fake hook counter records expected IDs before dispatch and matches every terminal to its unique attempt. A failure that occurs before transport is represented as a refusal without claiming a provider call occurred.

Return the complete validated `o` through EP-1's durable-result codec, including any registered confidence/probability fields, rather than extracting only a label. Such fields are result data; they never substitute for typed Baikai terminal evidence in `finishCall`. A current-API result fixture with a confidence field must preserve it while a missing provider terminal still fails evidence completeness. No probability schema or derivation algorithm is implemented in this adapter.

Add a bounded runner duration and call-count fixture, and prove limits apply across both nodes. Confirm no prompt, response body, or credential appears in diagnostic text. Add module/test entries to the Cabal file and main test tree. Record the verified stack and the authority rules in an ADR through `agents/skills/exec-plan/ADR.md`. Do not add durable Flow labels in this plan.


## Concrete Steps


Run from the repository root in the configured development environment:

```bash
mori registry show shinzui/handan --full
mori registry show shinzui/shikumi --full
mori registry show shinzui/baikai --full
curl -fsSL https://hackage.haskell.org/package/shikumi/preferred.json
curl -fsSL https://hackage.haskell.org/package/baikai/preferred.json
git ls-remote --tags https://github.com/shinzui/shikumi.git 'refs/tags/shikumi-[0-9]*'
git ls-remote --tags https://github.com/shinzui/handan.git
cabal build shikigami-core
cabal test shikigami-core-test --test-show-details=direct
```

Inspect only selected source packages from Mori and the project's build-plan metadata; never traverse `/nix/store`. The fake-provider suite needs no network model access or credentials. Expected results are zero dispatches on forbidden tuples, two observed calls for a two-node success, three for a fixture with one retry, and all existing core tests passing. Record exact observed counts during implementation.


## Validation and Acceptance


A two-node registered program invoked with alias `investigate` sends the authorized investigation tuple on both calls despite a different process default. Changing payload text to contain a model/credential does not change dispatch. Two concurrent invocations use distinct selected bindings. Every permitted actual call receives a run correlation and unique call correlation before dispatch; the final terminal evidence contains the provider's own identity, not just the requested model copied into an application record.

A profile forbidding the selected model or final thinking level causes no actual call. Invalid output returns a bounded typed failure. Evidence persistence failure prevents a successful decision return, and cancellation remains distinguishable from a provider terminal. Tests exercise the real Handan/Shikumi path with fake provider handlers, not a replacement decision evaluator that would bypass internal calls.

A registration whose parameter or derivation identity differs from `PreparedDecision` produces zero provider calls. Matching state preserves the entire typed result through serialization independently of the model-facing schema. These checks run against current dependency APIs; adoption of [Shikumi MP-12](mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs) remains optional.


## Idempotence and Recovery


The runner itself has no journal: the later Flow interpreter owns reuse of completed results. A provider call repeated after a crash is another actual attempt and must receive a new durable ID. Do not deduplicate two calls merely because their prompt and model match. Private registries and bindings are discarded after an invocation and never replace process-global state. Dependency qualification must not rewrite unrelated local overrides. If the public API proves inadequate, record the precise failing probe and revise all consumers before proposing an upstream extension; do not bypass policy to finish the runner.


## Interfaces and Dependencies


Export a runner with the semantic shape `runDecisionProgram :: DecisionRuntime -> PreparedDecision -> DecisionProgramRef i o -> i -> IO (Either DecisionFailure o)`. `DecisionRuntime` contains resolved secret-bearing bindings, the pinned profile, limits, and `DecisionCallHooks`; it has no JSON or secret-revealing Show instance. Contract identity checking and input/output validation remain shared with the registry.

The durable hooks from `docs/plans/75-persist-decision-call-evidence-across-retries-and-restarts.md` replace the fake hooks without changing the runner. The Flow interpreter in `docs/plans/76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md` invokes this runner only inside a named result step and stores the versioned result envelope. Provider policy refactoring must preserve `constrainBehaviorEnv` for existing Skill/routing callers. The program-call path remains selected by an immutable reference; it is not arbitrary Handan task execution.
