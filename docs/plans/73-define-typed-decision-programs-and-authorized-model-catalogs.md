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
---

# Define typed decision programs and authorized model catalogs


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Give Flow authors typed references to registered decision programs and operator-approved model aliases. A declaration can authorize two models without exposing provider strings or credentials to input data. Unknown programs, wrong input/result contracts, duplicate aliases, and unauthorized selections are rejected before a runner can dispatch. Pure tests and agent/config loading demonstrate this behavior without model access.

This is the admission work for [IR-12](../improvement-requests/compose-shikumi-decisions-in-durable-flows.md). There are no hard dependencies. Its consumers are `docs/plans/74-run-shikumi-decisions-through-governed-provider-calls.md`, `docs/plans/75-persist-decision-call-evidence-across-retries-and-restarts.md`, and `docs/plans/76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md`; they consume the contracts specified below.


## Progress


Implementation has not started. Seed unchecked milestone entries when implementation begins.


## Surprises & Discoveries


None recorded during implementation.


## Decision Log


2026-09-26: Register typed Shikumi programs separately from arbitrary Handan tasks. A `Task` can run unrestricted IO and returns a generic envelope; a `Program i o` restricts effects and preserves input/output types.

2026-09-26: Give each agent an explicit `decisionModels` allow-list of operator aliases, defaulting to empty when decoding historical JSON. The operator catalog supplies concrete models and credentials; payloads may only influence a choice among the pinned allowed aliases.

2026-09-26: Version the implementation, schemas, validator, and model descriptor explicitly. Program shape serialization omits closures and cannot by itself identify the implementation.

2026-10-21: Revision for coordination with Shikumi's probability-backed outputs: include complete effective parameter state and local derivation semantics in immutable program identity, and retain separate model-output and durable-result codecs where their shapes differ. The Flow API remains Shikigami-owned; future upstream output types do not become a prerequisite. See [ADR 0041](../adr/0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md).


## Outcomes & Retrospective


To be filled during implementation; distill catalog and typed-program ownership into local ADRs before completion.


## Context and Orientation


`shikigami-core/src/Shikigami/Program/Registry.hs` lists three Handan tasks. `shikigami-core/src/Shikigami/Behavior/Run.hs` converts `BehaviorInput` into text arguments and returns an Aeson `Value` from the task envelope. That registry remains the legacy behavior entry point. Add `shikigami-core/src/Shikigami/Program/Decision.hs` for typed, reviewed decision programs. Shikumi's `Program i o` carries a Haskell input type `i` and output type `o`; its `Embed` operation permits only the model-call effect and typed errors, not arbitrary IO. A schema describes the JSON form of these types, while a domain validator checks whether a decoded result is permitted to drive a particular business action.

`shikigami-core/src/Shikigami/Agent/Decl.hs` and `schema/Agent.dhall` define agent declarations. The current record derives its JSON decoder, so adding a field requires an explicit compatibility decoder or equivalent defaulting mechanism rather than assuming missing fields decode. `Agent.Loader` validates manifests and checks registered Flow names. `shikigami-core/src/Shikigami/App/Config.hs` uses Settei and has `ProviderSelection = UseStub | UseAnthropic Model SecretText`. `Shikigami.Behavior.Provider` constructs a `BehaviorEnv` and extracts `ProviderCall` for profile validation. Credentials deliberately lack printable or JSON instances.

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


Add `Shikigami.Decision.ModelCatalog`. Operator configuration under `behavior.decisionModels` is a finite list of entries with alias, immutable descriptor version, provider choice, exact catalog model ID, explicit thinking preference or explicit default, and an opaque credential binding. Resolve secret values through the existing Settei process boundary. Initially support the existing stub and Anthropic transports, sufficient for two distinct permitted model IDs. Reject duplicate aliases, malformed versions, unknown generated model IDs, unsupported thinking values, and unresolved credentials. Do not make arbitrary model strings into Baikai `Model` values.

Add `decisionModels : List Text` to `schema/Agent.dhall` and the Haskell declaration. Default historical JSON to an empty list and omit the field when empty on encoding, preserving historical bytes; update authored Dhall defaults and fixtures to supply the new field. Update `Agent.Loader` and `Flow.flowDeclarationErrors` as needed for declaration validation, but introduce no workflow steps here. A declared Flow requiring a decision slot must authorize the aliases its slot may choose. Expose a pure resolver taking a catalog, declaration and optional `ResolvedProfile`; intersect those permissions. An absent sanctioned profile preserves unsanctioned execution with the operator and agent checks still mandatory. Resolve the whole finite slot catalog before the first decision in the later workflow plan.

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

Old `AgentDecl` JSON decodes to no decision permission and re-encodes without a new empty-field key. Current Dhall fixtures load with explicit defaults. Neither a serialized policy snapshot nor a rendered refusal contains a test credential marker. No provider test counter changes during admission. The contract tests fail before these types/resolvers exist and pass with the implementation.

All slot descriptors in the policy snapshot and all prepared decisions identify parameter state and derivation semantics as well as code, schemas and validators. Two registrations with the same structure but different effective parameters cannot share immutable identity. The retained durable-result codec preserves all validated output fields and can decode a completed outcome without looking up an executable program.


## Idempotence and Recovery


This plan adds no persisted workflow steps or database migration. Repeated config validation and tests are safe. Never reuse a registered immutable version for changed code or validators. Preserve old declaration JSON decoding; a permission default must deny new capabilities rather than authorize them. Do not rewrite user changes or dependency overrides while establishing the baseline.


## Interfaces and Dependencies


`DecisionProgramRef i o`, `DecisionSlot`, `DecisionPolicySnapshot`, `PreparedDecision`, `DecisionOutcome`, `DecisionFailure`, `DecisionCallContext`, `DecisionCallHooks`, and the opaque call attempt token belong to `Shikigami.Decision.Contract` or `Shikigami.Program.Decision` as specified above. `Shikigami.Decision.ModelCatalog` owns pure catalog validation/resolution and runtime-only credential lookup. Inputs to resolution are `AgentDecl`, the operator catalog, and `Maybe ResolvedProfile`; output is `Either DecisionFailure DecisionPolicySnapshot` plus process-local runtime bindings kept separately.

Use Shikumi's typed Program and schema support, Baikai's model/options/evidence vocabulary, and existing Shikigami correlation/profile types. Do not introduce a parallel profile evaluator: reuse the predicate in `Behavior.Provider`, refactoring it to accept an actual model/options pair if required. `docs/plans/74-run-shikumi-decisions-through-governed-provider-calls.md` owns runner implementation; `docs/plans/75-persist-decision-call-evidence-across-retries-and-restarts.md` owns durable hooks; `docs/plans/76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md` owns all journal step names and workflow evolution. Contract changes found by a consumer must be reflected in this file and the master plan before changing another consumer.
