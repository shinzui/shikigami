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
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T01:00:35Z
      mode: "update"
      note: "Apply review: Baikai 0.7.2.0 facts and structuredOutput forwarding; consume plan 73 predicate and Behavior.Compatibility; drop stale Mori caveat"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T20:45:46Z
      mode: "implement"
      note: "Implement isolated Handan runner with final tuple admission and attempt evidence below retries"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-29T13:02:55Z
      mode: "update"
      note: "Refresh implemented contracts, dependency and validation evidence, completed Flow integration, and remaining runner qualification against the October 29 working tree"
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T00:41:18Z
      verdict: "changes-requested"
      note: "Selected Baikai is 0.7.2.0 (cabal.project), not the 0.7.0.0 cohort; ApiProvider wrapper must carry structuredOutput; Behavior.Compatibility pre-dispatch gate not mentioned; Mori ADR handles now resolve"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-29T13:02:55Z
      verdict: "changes-requested"
      note: "Current runner passes 13 tests; refresh completed integration and release facts, distinguish resource-root accounting, and reopen incomplete streaming/failure acceptance coverage"
---

# Run Shikumi decisions through governed provider calls


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective current. This revision reviews the
2026-10-29 working tree; it does not implement the remaining qualification work.


## Purpose / Big Picture


Execute a registered typed decision program using the exact model, credential binding and thinking setting authorized for that invocation. Every actual provider attempt, including another program node or an internal retry, must cross policy admission and evidence persistence. Key-free tests drive real Handan/Shikumi programs through fake providers so this behavior is observable without external model access.

The runner already exists. Resume from Milestone 3, which this review reopens for incomplete failure-path qualification and the missing-terminal streaming gap described below. Do not recreate the registry or runner. [Plan 73](73-define-typed-decision-programs-and-authorized-model-catalogs.md) supplies immutable typed programs, model bindings and hook contracts; [Plan 75](75-persist-decision-call-evidence-across-retries-and-restarts.md) has implemented durable attempt storage; [Plan 76](76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md) has integrated the runner into journaled Flow decisions. Their original implementation is complete, rather than a future dependency of this child.

This plan owns invocation-local provider execution. Whole-assignment execution selection and shared resource-root accounting have separate owners in [Plan 82](82-pin-governed-execution-settings-for-agent-assignments.md) and [Plan 85](85-adapt-durable-delivery-through-validated-coordinator-decisions.md). A resource root is a persistent allowance shared by related work. The current decision hooks account against the decision run; they do not by themselves reserve or settle that newer shared allowance. Dependency upgrades, judgment-only providers, calibration, and migration of legacy Handan tasks remain outside this plan.


## Progress


- [x] (2026-10-25; rechecked 2026-10-29) Milestone 1: Invocation-local Handan execution pins program state, input, model and credential. Existing tests demonstrate two real Predict nodes and concurrent binding isolation.
- [x] (2026-10-25; rechecked 2026-10-29) Milestone 2: Blocking calls and successful streams cross final compatibility/profile/evidence admission and begin/finish hooks below retries. Existing tests observe two attempts for two nodes and three for one internal retry.
- [ ] Milestone 3: Complete failure-path and evidence qualification. The original 453-core-test run and 13 runner cases remain historical evidence; all 13 runner cases pass again on 2026-10-29. Remaining work is to reject successful return after an unterminated stream, prove stream cancellation and terminal-write failure, and cover the specific refusal/error cases detailed below before claiming the full acceptance matrix complete.

The 2026-10-29 review used both the historical isolated project and the ordinary repository Cabal project; both passed all 13 runner tests. The normal command now works, so the temporary project is not a prerequisite. No runtime code changed during this refresh.


## Surprises & Discoveries


2026-10-29: The completion record overstated the runner's tested failure surface. `shikigami-core/test/Shikigami/DecisionRunnerSpec.hs` contains successful streaming and blocking timeout tests, but no explicit stream-cancellation or normal stream-exhaustion-without-terminal test. `Shikigami.Program.DecisionRunner` maps terminal events and then validates the returned program value; it does not check at normal program completion that every locally begun stream reached a terminal. In the selected Shikumi source, `raiseStreamError []` returns successfully. An embedded program can therefore ignore an unterminated event list and return a valid value. The production Flow interpreter separately rejects unresolved expectations before committing a successful outcome, but the standalone runner's evidence-completeness contract still needs enforcement. This is a source-derived finding, not a newly executed failing fixture.

2026-10-29: Plans 75 and 76 already delivered the durable evidence store, production wiring, retained result codecs and replay tests. Later assignment execution adds another private provider registry and resource ledger in `shikigami-core/src/Shikigami/Execution/SelectionRuntime.hs`. It does not replace this decision runner or implicitly enroll its calls in resource-root accounting.

2026-10-29: The selected stack remains Shikumi 0.4.0.0, Baikai 0.7.2.0 and Handan revision `8e98b0a955f908f70657c04f384b6286e4967422`. Hackage and remote tags now confirm released Shikumi 0.4.1.1 and Baikai 0.10.0.0, including Baikai 0.8 and 0.9. The old assertion that Baikai 0.8 is unreleased is obsolete. The local [Shikumi MP-12](mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs) records completion on 2026-10-25 against a released Baikai 0.9 cohort; that does not mean Shikigami has adopted those APIs. Mori currently resolves the cited upstream ADRs but not this MasterPlan URI; the document exists in the owning checkout, so retain the canonical reference.

Application correlation metadata remains transport-specific. Anthropic Messages and OpenAI Chat Completions reject arbitrary application metadata under the current compatibility contract. Their requests retain evidence run/attempt correlation, and the finish hook joins the application attempt token to Baikai's independent call ID. Compatibility and evidence preflight run again after final evidence configuration.

The earlier Kikan package-path workaround is historical: [FRIC-1](../friction-log/1-baseline-build-references-absent-kikan-action-packages.md) documents the isolated project used in the initial acceptance, while [FRIC-14](../friction-log/14-configured-kikan-authorization-packages-are-absent.md) records restoration of the configured checkout on 2026-10-28. No new friction entry is required for this review.


## Decision Log


2026-09-26: Use Handan's public `Runtime` with an invocation-local default model and isolated Baikai registry. Preserve runtime retry, budget and rate-limit configuration instead of copying Handan's interpreter stack or mutating global provider state.

2026-09-26: Wrap actual transport attempts below Shikumi retry. Task-level wrappers miss internal calls, and billing observations lack the full terminal evidence required by the durable store. Preserve program-owned schema and prompt construction while enforcing the authorized final request; fill-only defaults are not an authorization boundary.

2026-10-21: Bind effective parameter-state digest/format and local derivation version before pending execution. Probability/confidence fields remain ordinary validated result data. [ADR 0041](../adr/0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md) keeps upstream adaptation behind the registry/runner and preserves committed outcomes.

2026-10-21: Consume the shared tuple predicate and `Behavior.Compatibility`; preserve every field of the selected Baikai provider, including `structuredOutput`.

2026-10-29: Keep the selected dependency cohort and existing API ownership. Newer upstream releases remove the historical release blocker but do not authorize a dependency migration. Reopen Milestone 3 for obligations already present in this plan, preserving the initial acceptance evidence rather than treating 13 passing tests as proof of untested cases. Shared root accounting and coordinator integration stay with their owning plans; they are not new acceptance requirements here.


## Outcomes & Retrospective


The initial runner implementation landed in `3674001`, with subsequent durable integration in `2c609ec`. Its 2026-10-25 acceptance recorded 453 core tests, including 13 runner tests. Two-node success observed two transport calls; one retry observed three; concurrent invocations produced four isolated requests; a successful stream produced one terminal; denied tuples dispatched nothing; blocking timeout left one unresolved expectation. These are historical measurements, not the current full-suite size.

On 2026-10-29 the targeted runner suite passed all 13 cases on GHC 9.12.4 through the ordinary project. Source review verified current dependency selections, actual interfaces, the implemented persistence/Flow consumers and the newer resource-accounting boundary. The full core and PostgreSQL suites were not rerun for this documentation refresh. Milestone 3 remains open until the missing-terminal defect and uncovered acceptance cases are exercised and corrected. [ADR 0043](../adr/0043-decision-provider-wrappers-own-actual-attempt-boundaries.md) already records the intended boundary; this review does not introduce a new architecture decision.


## Context and Orientation


A decision program is a typed `Shikumi.Program i o`: it accepts an `i` and produces an `o`. A Predict node constructs a model request with a derived response schema. Handan executes the program and selects the ambient model. Baikai dispatches the actual provider call and supplies typed terminal evidence. A terminal is the response or stream event establishing completion or failure; cancellation or loss of the terminal leaves an attempt unresolved.

`shikigami-core/src/Shikigami/Program/Decision.hs` owns `DecisionProgramRef`, immutable executable registration, parameter-state commitments and separate retained result codecs. `shikigami-core/src/Shikigami/Decision/Contract.hs` owns `PreparedDecision`, bounded `DecisionFailure`, `DecisionOutcome`, `AttemptToken` and `DecisionCallHooks`. The prepared value pins program, validated input, model descriptor and profile identity before dispatch. `shikigami-core/src/Shikigami/Decision/ModelCatalog.hs` resolves opaque process-local credentials through `pinnedBinding`; missing historical bindings cannot fall back to process defaults.

`shikigami-core/src/Shikigami/Program/DecisionRunner.hs` owns `DecisionRuntime`, `DecisionAbort`, `decisionProviders` and `runDecisionProgram`. It selects exactly one handler for the model API, creates a private registry and updates the supplied Handan runtime. `decisionProviders` contains the stub, Anthropic Messages, OpenAI Chat Completions and OpenAI Responses handlers. The provider record update overrides only `complete` and `stream`, retaining thinking/evidence/schema capability declarations. The complete path uses `completeRequestWith` on the trusted registry; the stream path invokes the trusted handler with explicit final preflight and `requireEvidenceOnTerminal`.

`shikigami-core/src/Shikigami/Behavior/Provider/Call.hs` now owns `providerCallFor` and `validateProfileCall`; this is the implemented shared predicate, not a refactor still waiting on Plan 73. `shikigami-core/src/Shikigami/Behavior/Compatibility.hs` checks request/option support. `shikigami-core/src/Shikigami/Behavior/Provider.hs` remains the composition boundary for existing behavior callers. Legacy `runProgramTask` in `shikigami-core/src/Shikigami/Behavior/Run.hs` still runs unrestricted Handan tasks; it is a distinct path and is not made governed by this adapter.

`shikigami-core/src/Shikigami/Decision/Evidence.hs` supplies `decisionCallHooks` over `DecisionEvidenceStore`: expectation allocation precedes dispatch, terminal writes preserve rich encode-only Baikai evidence and normalized facts, and admission checks durable run-wide limits. `shikigami-core/src/Shikigami/Flow/Decision.hs` invokes the runner only inside an uncommitted result step, supplies those hooks, encodes the full validated result, and decodes committed results without consulting executables or secrets. It currently supplies a local invocation call limit of 64; durable profile limits are additional restrictions. Confidence fields are retained result data, never provider evidence.

Whole-run selection in `shikigami-core/src/Shikigami/Execution/SelectionRuntime.hs` is separate. [ADR 0051](../adr/0051-resource-roots-own-conservative-reservations-and-actual-attempts.md) and [ADR 0052](../adr/0052-assignments-pin-whole-run-selection-and-account-every-provider-attempt.md) describe root reservations, current authority and actual request ceilings for that path. This runner still has invocation limits and Plan 75's decision-run accounting. Plan 85 owns connecting coordinator decisions to the shared root and proving separation of decision permissions from unused whole-run defaults.

The selected dependency versions are confirmed by `cabal.project` and `dist-newstyle/cache/plan.json`: Shikumi 0.4.0.0, Baikai 0.7.2.0, Baikai Claude/OpenAI 0.7.1.0 and pinned Handan above, under index-state `2026-10-06T14:00:00Z`. Remote peeled tags remain `59d38bcfcedc85602564063d35703f75480a6156` for Shikumi 0.4.0.0 and `7dd44f96e5bba1a0dfa6a693a6c4858d81ab9831` for Baikai 0.7.2.0. On 2026-10-29 the preferred Hackage versions were Shikumi 0.4.1.1 (`db4eb373803552762edc9e86a231dfb529f8105b`) and Baikai 0.10.0.0 (`03140cf60381ac154ebfa86d3bb2208d7df8626c`); Handan still had no remote tags and its `handan-core` registry endpoint returned 404. Newer local source is not evidence of the selected API.

Use Mori to locate `mori://shinzui/handan`, `mori://shinzui/shikumi` and `mori://shinzui/baikai`, then inspect the selected Git revisions. Relevant project-relative files are respectively `handan-core/src/Handan/Runtime.hs`; `shikumi/src/Shikumi/LLM.hs` and `shikumi/src/Shikumi/Routing.hs`; and `baikai/src/Baikai/Provider/Registry.hs` and `baikai/src/Baikai/Stream.hs`. Artifact-level source-file URIs are pending. Handan exposes `Runtime(..)` and `runProgramWith`; Shikumi's `LLMConfig.registry` supplies the registry beneath resilient retries. Baikai's public isolated-registry and strict evidence APIs suffice without an upstream fork.

Relevant local ADRs are [0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md) (pinned policy), [0010](../adr/0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md) (encode-only evidence and atomic persistence), [0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md) (capability-owned IO), [0041](../adr/0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md) (program identity and retained results), [0042](../adr/0042-decision-admission-intersects-operator-agent-and-pinned-profile-authority.md) (intersected admission), [0043](../adr/0043-decision-provider-wrappers-own-actual-attempt-boundaries.md) (this runner), [0044](../adr/0044-decision-attempts-persist-expectations-and-consumer-owned-compliance-facts.md) (durable hooks), and [0045](../adr/0045-flow-policy-pins-pending-decisions-and-retains-completed-result-codecs.md) (completed Flow integration). Upstream [request defaults](mori://shinzui/shikumi/okf/adrs/concepts/ADR-12) exclude credentials; [transport billing](mori://shinzui/shikumi/okf/adrs/concepts/ADR-13) does not replace full evidence. Consult selected sources for API details because those living ADRs also discuss newer upstream features.


## Plan of Work


### Milestone 1: Preserve isolated typed execution — implemented


Maintain `shikigami-core/src/Shikigami/Program/DecisionRunner.hs` and its existing `DecisionRunnerSpec.hs` tests. Admission checks exact descriptor equality, profile reference, registered type/state, retained model binding, validated input and the prepared JSON value before executing the immutable registration. Parameter and local derivation identities must match even when provider request bytes happen to match. Preserve the supplied runtime's budget and rate policy and narrow retries by the pinned profile.

Acceptance is the existing two-node Predict and concurrent-invocation tests: schema reaches transport, input affects the typed result, both nodes use the selected model and credentials, distinct invocations do not cross-talk, and mismatched prepared state/input makes zero provider calls. Keep the legacy task path compatible. Do not rebuild these delivered components.

### Milestone 2: Preserve admission at every actual attempt — implemented


Both provider entry points must enforce exact model/endpoint, credential binding, thinking, token/timeout caps, tool refusal and final compatibility/evidence checks. Preserve program-owned schema, sampling and supported continuation behavior. Reject node credentials or headers, conflicting thinking, changed models/endpoints and tool requests. Do not silently replace a missing authorized binding with environment lookup.

After preflight, allocate a fresh expectation through `beginCall`, configure correlation, repeat checks on final options and dispatch. Persist terminal evidence through `finishCall` before returning a response or exposing a terminal. Keep Baikai's independent call identity. Preserve all provider capability fields by record update. A complete handler implemented by draining its own stream counts once. Internal retries cross this wrapper again. Do not infer structural node/retry lineage that the wrapper cannot observe.

Acceptance is two attempts for a two-node success, three for one internal retry, one for a successful stream, zero dispatches for admission refusal, and no internal retry of evidence callback failures. Local call counts supplement durable hook admission. Unknown usage must remain unknown across restart. Maintain the bounded transient exception for timeouts/exhausted transient errors, bounded permanent failures for invalid output/policy, and asynchronous cancellation propagation.

### Milestone 3: Close evidence and refusal qualification gaps — remaining


Start in `shikigami-core/test/Shikigami/DecisionRunnerSpec.hs` with the existing embedded `LLM.stream` fixture and a provider whose stream exhausts without `EventDone` or `EventError`. The program may return otherwise valid typed output, but `runDecisionProgram` must not return success with an unresolved expected attempt. Reproduce the source-derived gap first, then fix the runner locally: track begun and terminally persisted attempts for the invocation, and refuse normal program completion if any remain unresolved. Preserve the durable expectation and return bounded `EvidenceFailure`; do not synthesize a provider terminal. Keep bookkeeping concurrency-safe and mark completion only after successful terminal persistence. This local guard supplements, rather than replaces, the Flow store check.

Add a controlled streaming cancellation fixture: signal once `beginCall` has completed and transport consumption starts, cancel the invocation, and observe one expectation with no terminal and no fabricated success. Use synchronization rather than sleeps to establish the ordering. Add a failing finish-hook fixture that throws a retryable provider-shaped exception after receiving a real terminal: it must become bounded evidence failure with one actual attempt and no internal retry. The existing callback test covers begin failure; the durable Flow test covers store write failure, but neither alone proves the stream finish boundary.

Complete the original error/refusal matrix with a permanent provider failure that makes one attempt despite configured retries; exhausted transient retries that retain distinct attempt IDs and throw `TransientBehaviorFailure`; well-formed JSON with the wrong output shape; and explicit node credential/header/tool escape attempts that make zero calls. Exercise final evidence-strength/model-identity mismatch, unavailable or ambiguous provider handlers, and changed prepared policy/binding using the existing public fixtures. Assert bounded failure codes and absence of private prompt/body/credential/callback text rather than only `isLeft`. Keep existing valid two-node, confidence-codec and state-pinning cases passing.

Run the focused runner group first, then the full core suite. Run the existing PostgreSQL decision evidence and workflow groups after the runner change to prove the production store/interpreter still compose correctly. Confidence round-trip and committed-result reuse are already covered in `shikigami-core/test/Shikigami/DecisionContractSpec.hs` and `shikigami-core/test-postgres/Shikigami/DecisionWorkflowSpec.hs`; reuse those tests rather than duplicating journal ownership in the runner. Record actual counts and failures after qualification. Do not add durable step labels. If any fix touches a workflow body under Agent or Flow, follow `docs/workflow-versioning.md` and its applicable gate rather than assuming runner-local safety covers a workflow change.


## Concrete Steps


Run from the repository root. Dependency discovery is read-only; compare selected revisions with current releases before proposing any cohort change:

```bash
mori registry list
mori registry search shikumi
mori registry show shinzui/handan --full
mori registry show shinzui/shikumi --full
mori registry show shinzui/baikai --full
mori registry docs shinzui/shikumi
mori registry docs shinzui/baikai
curl -fsSL https://hackage.haskell.org/package/shikumi/preferred.json
curl -fsSL https://hackage.haskell.org/package/baikai/preferred.json
git ls-remote --tags https://github.com/shinzui/shikumi.git 'refs/tags/shikumi-[0-9]*'
git ls-remote --tags https://github.com/shinzui/baikai.git 'refs/tags/baikai-[0-9]*'
git ls-remote --tags https://github.com/shinzui/handan.git
```

Use the configured Nix development shell for GHC and native libraries. The ordinary project works as of this refresh; do not require an untracked `.dev/mp13.cabal.project` or change dependency bounds merely to reproduce historical commands.

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test \
  --test-options='-p "governed decision runner"' --test-show-details=direct
nix develop --no-write-lock-file -c cabal test shikigami-core-test \
  --test-show-details=direct
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test \
  --test-options='-j1 -p "decision"' --test-show-details=direct
git diff --check
```

The first command currently reports `All 13 tests passed`; the count must grow with the remaining qualification. A passing existing suite does not close the missing-terminal finding. PostgreSQL tests own disposable databases and run serially to avoid fixture connection exhaustion. They need no live model credentials. Inspect only project build metadata and Mori-located sources; never traverse `/nix/store`. If a fresh checkout lacks the configured Kikan packages, use Mori to locate `mori://shinzui/kikan-en` and consult FRIC-14 above before changing dependency paths or pins.


## Validation and Acceptance


A two-node program uses the authorized invocation model on both calls despite a different process default. Payload text naming another model or credential has no authority. Two concurrent invocations retain their selected bindings. Program, parameter-state, derivation, prepared policy or input mismatch causes zero dispatch. Full typed output, including confidence, survives the separate retained result codec.

Every permitted actual call has a fresh expected token before dispatch, and each real terminal is persisted before returning success. Provider evidence contains the provider's own identity, not a requested model copied into an application record. One internal retry means a third attempt, not an overwritten record. Callback failure cannot be retried as a transport error. Permanent and transient failure paths preserve their distinct classification.

Policy, credential/header/tool and incompatible thinking refusals make zero calls. Invalid JSON, schema mismatch and domain rejection remain failures with bounded diagnostics. A stream ending without a terminal cannot return a successful runner result; cancellation propagates and retains an unresolved expectation. A failed terminal write cannot publish success. These cases must traverse real Handan/Shikumi and the private provider wrapper, not a replacement evaluator.

The existing production integration additionally proves durable limits, lost-append repeat accounting, original pending-state/binding retention, committed replay without provider calls, retained confidence and protected-effect validation. Those checks belong to Plans 75/76 and are regression consumers of this change. Shared resource-root settlement and judgment-only provider adoption are not claimed by this acceptance.


## Idempotence and Recovery


The runner owns no workflow journal. Completed outcomes are reused by the Flow interpreter; a repeated provider action after a lost append receives a fresh durable attempt ID. Equal prompts/models never authorize deduplication of actual attempts. Private registries and credentials disappear with the invocation and never replace global state.

Cancellation, missing terminals and failed evidence writes preserve uncertainty rather than refunding or erasing it. Do not run an extra provider call to repair evidence or decode a committed result. Pending work requires the pinned executable and binding; completed work requires its retained codec. Changes here should remain local to the wrapper/tests. Any changed shared contract must be reflected in its owning Plan 73/75/76 and the Integration Points of MasterPlan 13 before implementation proceeds.

Rerunning fake-provider tests is safe and key-free. Keep dependency source/pin changes separate from qualification. Preserve unrelated working-tree edits. If released APIs cannot uphold the contract, record the exact failing fixture and coordinate an upstream change; do not weaken admission or fabricate terminals.


## Interfaces and Dependencies


The implemented runner signature is:

```haskell
runDecisionProgram
  :: (Typeable i, Typeable o, ToJSON i)
  => DecisionRuntime
  -> PreparedDecision
  -> DecisionProgramRef i o
  -> i
  -> IO (Either DecisionFailure o)
```

`DecisionRuntime` holds `runtime`, `programs`, `catalog`, `profile`, `hooks`, `providers`, `timeoutMicros` and `callLimit`. It has no JSON or secret-revealing Show instance. `DecisionAbort` carries bounded refusal across the provider retry layer; `TransientBehaviorFailure` and asynchronous exceptions can escape the `Either` result as documented above. `beginCall` accepts `DecisionCallContext` and returns an `AttemptToken`; `finishCall` accepts that token, `CallTerminal` and optional typed `ModelCallEvidence`. Their `Either DecisionFailure` result is authoritative; synchronous callback exceptions become bounded evidence failure, while asynchronous cancellation propagates.

The runner returns validated `o`; it does not itself construct `DecisionOutcome` or serialize the journal. `Shikigami.Flow.Decision` owns those operations and supplies `decisionCallHooks` from the persistent store. Registry identity/validation remain in `Shikigami.Program.Decision`; model bindings remain in `Shikigami.Decision.ModelCatalog`; the tuple predicate remains in `Shikigami.Behavior.Provider.Call`. Keep those ownership boundaries when completing Milestone 3.

The selected public dependencies already support this work. [Shikumi MP-12](mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs) is now implemented upstream, but adoption in Shikigami requires separate release-cohort and adapter qualification. Preserve static Flow slots, model/input authority, immutable state and full retained results if that future adoption occurs.


Revision note (2026-10-29): Refreshed the implemented runner, completed persistence/Flow consumers, actual shared predicate, release status and runnable validation commands; distinguished newer assignment/resource ownership; preserved historical evidence and reopened Milestone 3 for missing-terminal enforcement and incomplete original failure-path qualification.
