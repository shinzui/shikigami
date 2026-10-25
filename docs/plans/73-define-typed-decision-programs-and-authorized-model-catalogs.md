---
id: 73
slug: define-typed-decision-programs-and-authorized-model-catalogs
title: "Define typed decision programs and authorized model catalogs"
kind: exec-plan
created_at: 2026-09-26T18:34:27Z
intention: "intention_01m3fft4cceb1ba9t3fammx5x4"
master_plan: "docs/masterplans/13-compose-shikumi-decisions-in-durable-flows.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-26T18:34:27Z
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
      note: "Apply review: catalog builds on plan 80 HTTP selection; own tuple predicate refactor and FlowDef slot inventory validation; name plan 82 as descriptor consumer"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T20:30:58Z
      mode: "implement"
      note: "Begin typed decision admission and shared execution/evidence contracts"
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T00:41:18Z
      verdict: "changes-requested"
      note: "Context predates plan 80: ProviderSelection now has UseHttp and Behavior.Compatibility gates options; M2 should build on the HTTP catalog; predicate refactor and slot-alias check overlap EP-2/EP-4 ownership"
---

# Define typed decision programs and authorized model catalogs


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Give Flow authors typed references to registered decision programs and operator-approved model aliases. A declaration can authorize two models without exposing provider strings or credentials to input data. Unknown programs, wrong input/result contracts, duplicate aliases, and unauthorized selections are rejected before a runner can dispatch. Pure tests and agent/config loading demonstrate this behavior without model access.

This is the admission work for [IR-12](../improvement-requests/compose-shikumi-decisions-in-durable-flows.md). There are no hard dependencies. Its consumers are `docs/plans/74-run-shikumi-decisions-through-governed-provider-calls.md`, `docs/plans/75-persist-decision-call-evidence-across-retries-and-restarts.md`, and `docs/plans/76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md`; they consume the contracts specified below. Plan 75 needs only milestones 1 and 3 of this plan. `docs/plans/82-pin-governed-execution-settings-for-agent-assignments.md`, under `docs/masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md`, is an external consumer of the model catalog and its public descriptor.


## Progress


- [x] (2026-10-25) Milestone 1: Typed immutable registry, retained pure result codecs and parameter/derivation identities pass contract tests, including rich-result preservation with no executable available.
- [x] (2026-10-25) Milestone 2: Operator catalog, Settei loading, declaration compatibility and pure slot/profile admission pass; historical JSON omits empty decision permission.
- [x] (2026-10-25) Milestone 3: Begin/finish hooks allocate unique opaque tokens and ordinals, retain unresolved expectations, and accept only convergent terminal writes. Typed evidence fixtures and all 440 core tests pass.


## Surprises & Discoveries


The selected Shikumi `Predict` dictionaries cannot JSON-encode signature-level typed demonstrations. Registration refuses those and requires demonstrations in serializable `Params`; effective base instructions and explicit derivation defaults join the retained state commitment.

FRIC-1 in `docs/friction-log/` records the absent local Kikan action packages. Validation used an isolated upstream checkout without altering the registered checkout or dependency declarations.


## Decision Log


2026-10-25: Keep the pure tuple projection and profile predicate in `Behavior.Provider.Call`, re-exported by `Behavior.Provider`, so configuration/catalog admission can reuse them without a module cycle through the runtime builder. Signature demonstrations must use `Params` to make their complete state serializable.

2026-09-26: Register typed Shikumi programs separately from arbitrary Handan tasks. A `Task` can run unrestricted IO and returns a generic envelope; a `Program i o` restricts effects and preserves input/output types.

2026-09-26: Give each agent an explicit `decisionModels` allow-list of operator aliases, defaulting to empty when decoding historical JSON. The operator catalog supplies concrete models and credentials; payloads may only influence a choice among the pinned allowed aliases.

2026-09-26: Version the implementation, schemas, validator, and model descriptor explicitly. Program shape serialization omits closures and cannot by itself identify the implementation.

2026-10-21: Revision for coordination with Shikumi's probability-backed outputs: include complete effective parameter state and local derivation semantics in immutable program identity, and retain separate model-output and durable-result codecs where their shapes differ. The Flow API remains Shikigami-owned; future upstream output types do not become a prerequisite. See [ADR 0041](../adr/0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md).

2026-10-21: Review revision after plan 80. The catalog builds on the HTTP provider selection and per-API model catalogs that plan 80 added to `Shikigami.App.Config`, not on an Anthropic-only path. This plan owns the refactor of the `Behavior.Provider` tuple predicate and the `FlowDef` decision-slot inventory with its validation; plans 74 and 76 consume them. Plan 82 is an external consumer of the public model descriptor.


2026-10-25: Plan 76 integration adds typed `resolveProgramRef` for pinned pending descriptors, an explicit historical `resultCodec` constructor, and `retainModelBindings` for historical binding resolution without active authority expansion. These remain additive shared-owner APIs.


## Outcomes & Retrospective


Completed admission and shared contracts. `nix develop --no-write-lock-file -c cabal test --project-file=.dev/mp13.cabal.project --builddir=dist-newstyle shikigami-core-test --test-show-details=direct` passed all 440 tests on GHC 9.12.4. The temporary project replaces only the two missing Kikan package paths with an isolated checkout of `mori://shinzui/kikan-en` at `16704290d527d413568bfa40c983f5c3604c35c8`; all other pins match `cabal.project`. The temporary file is local validation state, not a repository dependency change.

The baseline command with the unmodified project still requires the local Kikan action packages to be restored. FRIC-1 is accepted with the isolated-checkout workaround. No entries remain logged under this child. [ADR 0041](../adr/0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md) records parameter/codec implementation, and [ADR 0042](../adr/0042-decision-admission-intersects-operator-agent-and-pinned-profile-authority.md) records catalog and tuple ownership. Provider execution, durable storage and workflow invocation remain owned by plans 74–76.


## Context and Orientation


`shikigami-core/src/Shikigami/Program/Registry.hs` lists three Handan tasks. `shikigami-core/src/Shikigami/Behavior/Run.hs` converts `BehaviorInput` into text arguments and returns an Aeson `Value` from the task envelope. That registry remains the legacy behavior entry point. Add `shikigami-core/src/Shikigami/Program/Decision.hs` for typed, reviewed decision programs. Shikumi's `Program i o` carries a Haskell input type `i` and output type `o`; its `Embed` operation permits only the model-call effect and typed errors, not arbitrary IO. A schema describes the JSON form of these types, while a domain validator checks whether a decoded result is permitted to drive a particular business action.

`shikigami-core/src/Shikigami/Agent/Decl.hs` and `schema/Agent.dhall` define agent declarations. The current record derives its JSON decoder, so adding a field requires an explicit compatibility decoder or equivalent defaulting mechanism rather than assuming missing fields decode. `Agent.Loader` validates manifests and checks registered Flow names. `shikigami-core/src/Shikigami/App/Config.hs` uses Settei, the configuration library. Since `docs/plans/80-configure-model-providers-and-agent-launches-through-baikai.md` its `ProviderSelection` has three constructors: `UseStub`, `UseAnthropic Model SecretText`, and `UseHttp Model Options SecretText`. The `behavior.provider` setting chooses the stub, Anthropic Messages, OpenAI Chat Completions or OpenAI Responses; `httpModelSetting` decodes a model against the chosen API's generated catalog and `responseOptionsConfig` supplies typed Baikai options; the two CLI transports are refused. `Shikigami.Behavior.Provider` constructs a `BehaviorEnv` through `newBehaviorEnvFor`, projects its actual model and options into a `ProviderCall` tuple with `providerCall`, and checks that tuple against the pinned profile with `matchesCall`; `Shikigami.Behavior.Compatibility` validates actual options and requests before dispatch. Credentials deliberately lack printable or JSON instances.

[ADR 0007](../adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md) makes the full journaled `ResolvedProfile` authoritative for a run. [ADR 0011](../adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md) requires compatible declaration decoding. [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md) restricts Flow effects. [ADR 0028](../adr/0028-a-router-catalog-is-a-bounded-snapshot-of-declared-authority.md) establishes that catalogs describe declared authority, not authority invented by input. These constraints mean catalog resolution is a pure operation over trusted configuration, the journaled declaration, and the resolved profile.

Use Mori before reading dependency APIs. `mori://shinzui/shikumi` owns `shikumi/src/Shikumi/Program.hs` and schema APIs; source-file artifact URIs are pending. Research verified the released 0.4.0.0 tag and Hackage on 2026-09-26. Recheck authoritative releases before changing bounds. Follow the project's direct record-field naming convention and `DuplicateRecordFields`.

`mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs` plans `Noul`, `Choice`, `Score` and local decision settings in `Params`. It is a coordination dependency only. Current `Params` already contains instruction overrides and demonstrations, and parameter changes can change a program's meaning without changing its structural shape. Future thresholds, cuts and weights may change a derived answer without changing the provider request. [ADR 0041](../adr/0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md) requires the entire effective state and derivation version to be bound before execution; no unreleased upstream type is needed to implement this contract.


## Plan of Work


### Milestone 1: Define typed programs and durable contracts


Create `Shikigami.Program.Decision` and `Shikigami.Decision.Contract`. A typed `DecisionProgramRef i o` identifies a registered program by stable ID, immutable version, implementation digest, input/output schema versions, and validator version. Registration bundles `Program i o`, JSON codecs and pure input/result validators. An existential wrapper allows a finite registry, while typed lookup checks both type witnesses and stored contract identities; never cast an Aeson value without decoding it. Keep the existing Handan task registry intact. Detect duplicate program/version identities at construction.

Add a parameter-state format version, a digest over a canonical encoding of the complete effective program parameter state, and a local derivation version to the immutable descriptor. Include the ordered per-node `Params` values, resolve effective defaults under the recorded version, and bind any additional state used by local result derivation. The implementation identity still covers opaque code and closures that parameter serialization cannot represent. Retain the matching state with its immutable executable registration; snapshots and prepared decisions carry the identities without copying prompts or demonstrations into the attempt ledger. Reject replacement of a program/version by different parameter or derivation state. Changing settings requires a new immutable registration even if the provider request/cache key is unchanged.

The model's response schema and the stored typed result need not have the same JSON shape. Keep the model schema used by Shikumi distinct from the versioned durable-result codec for `o`, and retain that codec independently of the executable registration. Preserve the complete validated result, including probability/confidence fields if a future program uses them; do not reduce a rich result to its selected label. Shikigami owns these contracts and its static-slot interface, while dependency-specific adaptation stays in the registry and runner. This plan adds no Jev adapter, probability type or calibration engine.

Define a finite `DecisionSlot` descriptor with a static label, allowed typed program versions, and allowed model aliases. The workflow integration later supplies actual slots. Define a serializable `DecisionPolicySnapshot` containing the pinned descriptors for all slots, allowed model descriptors, and a policy reference consistent with the separately journaled `ResolvedProfile`. Define `PreparedDecision` with workflow/run/generation/label identity, exact program and schema identities, validated input, selected model descriptor, and the profile reference. Define a versioned `DecisionOutcome` containing either bounded failure or validated JSON result plus preparation/evidence references. None contains secrets, a provider handler, or a Haskell closure.

Failures distinguish unknown program, contract mismatch, invalid input, unknown/forbidden/unavailable model, unavailable pinned implementation, output decode/validation, provider failure, and evidence failure. Bound displayed detail to 512 characters and never include raw prompts or secrets. Unit tests prove round trips, rejection of unknown versions, registry collisions, and incompatible typed lookups. Run the core test command below and observe these cases pass before proceeding.

Use current instruction/demonstration parameters to prove that a state change changes identity despite an unchanged program shape, that a reused program/version with changed state is rejected, and that pinned descriptors round-trip all state/derivation identities. A plain typed result fixture with a confidence field proves the durable codec retains the full result without depending on future Shikumi decision types.

### Milestone 2: Load operator catalogs and agent permissions


Add `Shikigami.Decision.ModelCatalog`. Operator configuration under `behavior.decisionModels` is a finite list of entries with alias, immutable descriptor version, provider choice, exact catalog model ID, explicit thinking preference or explicit default, and an opaque credential binding. Resolve secret values through the existing Settei process boundary. Support the stub and the HTTP transports plan 80 made configurable, Anthropic Messages, OpenAI Chat Completions and OpenAI Responses, by reusing the per-API generated model catalogs and typed response options in `Shikigami.App.Config` rather than a second decoder; CLI transports stay refused. Two distinct permitted model IDs are sufficient for the example. Reject duplicate aliases, malformed versions, unknown generated model IDs, unsupported thinking values, and unresolved credentials. Do not make arbitrary model strings into Baikai `Model` values. The public descriptor must carry alias, descriptor version and digest, provider, API, endpoint class, exact model, explicit thinking preference, and an opaque binding identity and version, because `docs/plans/82-pin-governed-execution-settings-for-agent-assignments.md` references it for whole-run selection.

Add `decisionModels : List Text` to `schema/Agent.dhall` and the Haskell declaration. Default historical JSON to an empty list and omit the field when empty on encoding, preserving historical bytes; update authored Dhall defaults and fixtures to supply the new field. Give `FlowDef` in `shikigami-core/src/Shikigami/Flow.hs` a finite inventory of `DecisionSlot` descriptors, defaulting to none for every existing flow, and extend `Flow.flowDeclarationErrors` and registry construction so that duplicate slot labels, slot contracts that do not match the typed program registry, and slot aliases the declaration does not authorize are rejected at load time without a runtime. Introduce no workflow steps or Flow effects here; `docs/plans/76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md` adds the `Decision` effect and reads this inventory. Expose a pure resolver taking a catalog, declaration and optional `ResolvedProfile`; intersect those permissions. An absent sanctioned profile preserves unsanctioned execution with the operator and agent checks still mandatory. Resolve the whole finite slot catalog before the first decision in the later workflow plan.

Configuration tests must demonstrate two valid aliases resolving to different exact model IDs, unknown aliases failing, agent/profile intersections narrowing access, and no credential bytes in diagnostics or serializable descriptors. Test existing manifests as well as old journal JSON. A configuration snapshot identifies the model metadata that affects routing and options, not merely a mutable alias.

### Milestone 3: Freeze execution and evidence callback contracts


Define `DecisionCallContext` and `DecisionCallHooks` in `Decision.Contract` for the other plans. Context contains parent run/workflow/generation, static decision label, prepared decision identity, exact effective tuple and pinned policy, with no secret. `beginCall` durably allocates a unique attempt ID before provider dispatch; `finishCall` accepts that ID, terminal status and optional typed Baikai evidence and records it before success returns. Define a bounded call-admission refusal and an opaque attempt token so callers cannot invent completions. Retry attempts get new IDs; a repeated completion of the same attempt must agree byte-for-byte. A failure with no provider evidence remains a recorded failure or unknown outcome, never fabricated evidence.

The interfaces may use typed wrappers around these concepts; their ownership and semantics are fixed here. Add in-memory fake hooks used by the runner tests and fake typed evidence used by persistence tests. Document that the production hook fails closed when persistence is unavailable. Publish module exports and test registration in `shikigami-core/shikigami-core.cabal` and `shikigami-core/test/Main.hs`. Update or create the relevant ADRs following `agents/skills/exec-plan/ADR.md` after checking whether the local manifest has adopted a profile.


## Concrete Steps


Run from the repository root in its configured GHC 9.12.4 development environment. Inspect local dependency overrides before using build results; do not silently qualify unreleased checkout APIs.

```bash
pwd
mori registry search shikumi
mori registry show shinzui/shikumi --full
mori registry docs shinzui/shikumi
cabal build shikigami-core
cabal test shikigami-core-test --test-show-details=direct
```

Register new tests as `DecisionContractSpec` and `DecisionModelCatalogSpec` in the core test tree. The build exits zero, Tasty reports all tests passed, and old manifest/codec tests remain green. Record actual counts and any toolchain blockers during implementation. These are commands to execute after the edits, not claimed results of planning.


## Validation and Acceptance


A registry lookup with the right program/version/input/output witness succeeds; replacing the result contract or looking up an unknown version yields a bounded error. A payload containing a new model ID or a credential cannot add a model to the resolver's output. With aliases `triage` and `investigate` declared by both operator and agent, an unrestricted or two-model profile admits both; a one-model profile admits only its exact tuple. A different thinking setting is independently refused.

Old `AgentDecl` JSON decodes to no decision permission and re-encodes without a new empty-field key. Current Dhall fixtures load with explicit defaults. A test `FlowDef` whose slot names an alias the declaration does not authorize, or a program version absent from the typed registry, is rejected by `flowDeclarationErrors` or registry construction before any runtime exists, and every existing registered flow validates with an empty inventory. Neither a serialized policy snapshot nor a rendered refusal contains a test credential marker. No provider test counter changes during admission. The contract tests fail before these types/resolvers exist and pass with the implementation.

All slot descriptors in the policy snapshot and all prepared decisions identify parameter state and derivation semantics as well as code, schemas and validators. Two registrations with the same structure but different effective parameters cannot share immutable identity. The retained durable-result codec preserves all validated output fields and can decode a completed outcome without looking up an executable program.


## Idempotence and Recovery


This plan adds no persisted workflow steps or database migration. Repeated config validation and tests are safe. Never reuse a registered immutable version for changed code or validators. Preserve old declaration JSON decoding; a permission default must deny new capabilities rather than authorize them. Do not rewrite user changes or dependency overrides while establishing the baseline.


## Interfaces and Dependencies


`DecisionProgramRef i o`, `DecisionSlot`, `DecisionPolicySnapshot`, `PreparedDecision`, `DecisionOutcome`, `DecisionFailure`, `DecisionCallContext`, `DecisionCallHooks`, and the opaque call attempt token belong to `Shikigami.Decision.Contract` or `Shikigami.Program.Decision` as specified above. `Shikigami.Decision.ModelCatalog` owns pure catalog validation/resolution and runtime-only credential lookup. Inputs to resolution are `AgentDecl`, the operator catalog, and `Maybe ResolvedProfile`; output is `Either DecisionFailure DecisionPolicySnapshot` plus process-local runtime bindings kept separately.

Use Shikumi's typed Program and schema support, Baikai's model/options/evidence vocabulary, and existing Shikigami correlation/profile types. Do not introduce a parallel profile evaluator. This plan owns the refactor of the `Behavior.Provider` tuple predicate: make `providerCall` and `matchesCall` reusable over an actual model and options pair, and over a descriptor's declared tuple, without constructing a `BehaviorEnv`, while `constrainBehaviorEnv` and `newBehaviorEnvFor` keep their callers and semantics. The resolver uses it for admission; plan 74 calls it on every attempt's final options and plan 82 calls it for whole-run selection, and neither reshapes it. `docs/plans/74-run-shikumi-decisions-through-governed-provider-calls.md` owns runner implementation; `docs/plans/75-persist-decision-call-evidence-across-retries-and-restarts.md` owns durable hooks; `docs/plans/76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md` owns all journal step names, the `Decision` effect and workflow evolution. Contract changes found by a consumer must be reflected in this file and the master plan before changing another consumer.

2026-10-25 integration note: plan 75 adds `withAttemptOrdinal` to the opaque token contract so the durable allocator can generate a UUID before a retryable SQL transaction and assign the run ordinal under its lock. The token constructor stays hidden; finish verifies persisted ownership and ordinal. This is an additive storage-consumer contract, with the in-memory hook behavior unchanged.
