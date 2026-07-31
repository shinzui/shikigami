---
id: 13
slug: wire-a-real-model-provider-into-behavior-runs
title: "Wire a real model provider into behavior runs"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tygnxenvarsw91bjsy19r"
master_plan: "docs/masterplans/2-production-reality-de-stub-the-runtime-behavior-and-integration-path.md"
---

# Wire a real model provider into behavior runs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today every Skill-behavior agent that the production worker runs "succeeds" without ever
calling a model. The worker unconditionally builds its behavior environment with a stub
LLM provider, so every skill run returns the literal string
`"stub-skill: instructions acknowledged; no model was called"`
(`shikigami-core/src/Shikigami/Behavior/StubProvider.hs:32`), and that fixed string is
then durably recorded as the agent's "learning" in kioku memory. There is no code path,
flag, or environment variable that can make the worker call a real model.

After this plan, an operator selects a provider through plan 37's Settei application
configuration (with explicit compatibility bindings for `SHIKIGAMI_MODEL_PROVIDER` and
`ANTHROPIC_API_KEY` only inside the Settei adapter) and the same worker
binary runs skills against a real Anthropic Claude model through baikai. The choice is
LOUD: at startup the worker prints exactly which provider and model are active, and it
refuses to start if the operator asked for a real provider but the key is missing. When
the provider setting is absent, the stub remains the default (CI and the existing test suite
stay deterministic and key-free) — but the startup log now says so explicitly, so a stub
can never again masquerade silently as production. The kioku session row additionally
records which model produced each run's output (`modelUsed`), so runs made by the stub
are distinguishable from real runs forever after.

Plan 37, not this feature plan, establishes the repository's configuration idiom. This
plan contributes typed provider settings, validation, and a redacted description to the
shared composition root. The provider secret remains a credential reference/redacted
value and never gains `Show`, JSON, or log rendering.


## Progress

- [ ] Prerequisites: plans 36 and 37 complete; provider modules live in the six-package
      boundary and consume the shared Settei application config.
- [ ] Milestone 1: `Shikigami.Behavior.Provider` module with `ProviderSelection`,
      provider `Setting`s/validation, and `newBehaviorEnvFor`; `baikai-claude` added to
      `shikigami-core.cabal`; worker and `run-behavior` CLI resolve the selection and
      log it loudly; stub remains the default; `cabal test all` green.
- [ ] Milestone 2: `Options` threaded through the skill arm (`BehaviorEnv.options`,
      `runSkill`/`runSkillWith` take `Options`); the already-resolved opaque credential is
      lowered to Baikai only at the provider boundary; unit test proving the options reach
      the completion call without an environment read.
- [ ] Milestone 3: `modelUsed` recorded on session completion from the active
      `BehaviorEnv` model; live smoke transcript with a real key captured in this plan.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The real provider is baikai's Anthropic Messages handler (`baikai-claude`
  package, `Baikai.Provider.Claude.Api.register`), selected by Settei settings with
  explicit legacy environment bindings rather than direct environment reads or secret
  CLI flags.
  Rationale: `cabal.project` already includes the `baikai-claude` subdir, but implementation
  must use Mori for source/docs and verify the coherent current release against Hackage and
  upstream tags before choosing bounds. Settei replaces the repository's fragmented direct
  environment reads, and secrets must never be CLI arguments.
  Date: 2026-07-22
- Decision: The stub remains the default when `behavior.provider` is unset, but
  both branches log loudly at startup which provider is active; requesting `anthropic`
  without a resolvable `credentials.providers.anthropic.api_key` is a typed configuration
  startup failure (exit 4), not a per-job
  runtime error.
  Rationale: CI and the entire existing test suite (`shikigami-core/test`) depend on the
  deterministic, key-free stub; making a real key mandatory would break every
  contributor's loop. But the architecture review's core complaint is that the stub
  reports success silently — the loud log line plus the recorded `modelUsed` close that
  hole. Failing fast at startup prevents a misconfigured worker from draining the queue
  and journaling stub outputs while the operator believes a model is running.
  Date: 2026-07-08
- Decision: Plan 37 owns Settei source composition, environment bindings, diagnostics,
  and exit behavior; this plan owns only the provider domain settings and validation.
  Rationale: feature plans should extend one configuration service instead of becoming
  competing configuration frameworks.
  Date: 2026-07-22
- Decision: Baikai never resolves `ApiKeyEnv` in Shikigami. Settei resolves a secret
  `CredentialValue`, and the provider composition root lowers it to Baikai's literal-key
  representation immediately before constructing the process-local `Options`.
  Rationale: allowing the client library to read an environment variable would create a
  second precedence/redaction system outside Settei. The process-local options are never
  serialized or logged, and the opaque application secret has no `Show` or JSON instances.
  Date: 2026-07-22
- Decision: Keep `newBehaviorEnv` / `newBehaviorEnvWithTraceSink` exported with their
  current stub-only semantics instead of changing their meaning in place.
  Rationale: the test suite constructs environments through them in many places
  (`shikigami-core/test/Shikigami/AgentWorkflowSpec.hs:54` and elsewhere); keeping them
  stub-only and adding a new explicit `newBehaviorEnvFor` keeps every existing call site
  compiling and honest about what it builds.
  Date: 2026-07-08


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

shikigami is a Haskell runtime (repo root `/Users/shinzui/Keikaku/bokuno/shikigami`)
that runs "declared agents": each agent is a Dhall file (`schema/Agent.dhall`,
examples under `agents/`) declaring a trigger, a behavior, and sinks. A worker process
(the current pre-plan-36 `cabal run shikigami -- worker --agents agents/`) drains run jobs from a Postgres
pgmq queue and drives each agent through a durable keiro workflow.

The behavior union (`shikigami-api/src/Shikigami/Api/Agent.hs:55-66`) has four arms.
Two are executable today: `ShikumiProgram` (a typed program run through the handan
runtime) and `Skill` (a directory containing a `SKILL.md` whose instructions are sent
to an LLM). The LLM call goes through **baikai**, a separate library at
`/Users/shinzui/Keikaku/bokuno/baikai` (verify with `mori registry show baikai --full`)
that abstracts model providers: a `Model` record carries an `Api` tag, and a
process-global **provider registry** (`Baikai.Provider.Registry`) maps each `Api` tag
to an `ApiProvider` handler. `completeRequest model ctx opts` looks up the handler for
`model`'s tag and runs the completion.

The stub problem, precisely:

- `shikigami-core/src/Shikigami/Behavior/Run.hs:45-49` — `newBehaviorEnvWithTraceSink`
  always calls `registerStubProvider` and builds `BehaviorEnv` with `stubModel`. There
  is no other constructor.
- `shikigami-core/src/Shikigami/Behavior/StubProvider.hs:27-65` — the stub registers
  under the `Custom "stub"` API tag and answers every completion with the fixed text at
  line 32.
- `shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs:30` — the production worker
  command calls `newBehaviorEnvWithTraceSink (Just (otelSink tr))`, so production runs
  the stub, always.
- `shikigami-core/src/Shikigami/Behavior/Skill.hs:104-111` — the skill arm builds a
  baikai `Context` and calls the completion with the hardcoded empty `_Options`
  (line 110); there is no seam to pass an API key even if a real model were selected.
- The stub's reply is recorded as a durable learning: `recordLearning` in
  `shikigami-core/src/Shikigami/Agent/Workflow.hs:585-605` stores
  `renderLearning output` into kioku memory, and `completeSession`
  (`Agent/Workflow.hs:607-618`) writes the session row with `modelUsed = Nothing`
  (line 615), so nothing distinguishes a stub run from a real one.

What baikai already provides (all verified in
`/Users/shinzui/Keikaku/bokuno/baikai`):

- `Baikai.Provider.Claude.Api.register :: IO ()`
  (`baikai-claude/src/Baikai/Provider/Claude/Api.hs:101-102`) installs the real
  Anthropic Messages handler under the `AnthropicMessages` tag in the global registry.
  Registration is idempotent per tag (second registration replaces the first).
- `Baikai.Models.Generated` ships ready-made `Model` values, e.g.
  `anthropic_claude_sonnet_4_6`, `anthropic_claude_haiku_4_5`,
  `anthropic_claude_opus_4_8` (see `baikai/src/Baikai/Models/Generated.hs`), each with
  the right `api = AnthropicMessages`, base URL, and cost/window metadata.
- API keys are described by `Baikai.Auth.ApiKeySource`
  (`ApiKeyLiteral | ApiKeyEnv | ApiKeyEnvChain`; `baikai/src/Baikai/Auth.hs:26-30`) and
  carried in `Baikai.Options.Options.apiKey :: Maybe ApiKeySource`
  (`baikai/src/Baikai/Options.hs:70-73`). Although the Claude handler can fall back to
  `ANTHROPIC_API_KEY`, Shikigami must not use that fallback: plan 37 resolves all candidates,
  provenance, and redaction first. Only the provider composition module may unwrap the opaque
  `CredentialValue` long enough to construct `ApiKeyLiteral`; the `Options` value is never
  logged, encoded, journaled, or stored.
- `_Options` is deprecated in baikai in favour of `emptyOptions`
  (`baikai/src/Baikai/Options.hs:91-110`).

Dependency plumbing: `cabal.project:124-128` already fetches the baikai repo with
`subdir: baikai baikai-claude baikai-effectful baikai-trace-otel`, but
`shikigami-core/shikigami-core.cabal` (`build-depends` block around line 70) lists only
`baikai` and `baikai-trace-otel`. Adding `baikai-claude` is a one-line cabal edit, no
new pins.

One term of art: "loud" in this plan means an unconditional single-line `stderr` log at
startup naming the active provider and model, in the same style as the existing
`[shikigami.worker]` lines (`shikigami-core/src/Shikigami/Worker.hs:69`).

Coordination note (from the parent MasterPlan): this plan and
`docs/plans/15-inject-recalled-memory-and-trigger-payload-into-behavior-context.md`
both edit `Behavior/Run.hs` and `Behavior/Skill.hs`. This plan owns the `BehaviorEnv`
shape and the provider/config wiring and should land first; plan 15 then extends the
per-run input (payload + recalled memory) on top. Neither plan may rename existing
keiro journal step names (see MasterPlan Integration Points).


## Plan of Work

The work is three milestones: introduce an explicit, Settei-driven provider
selection (behavior unchanged by default); thread real `Options` through the skill arm
so the key source is explicit; and make the model identity observable in the durable
session record, then prove the real path live.

### Milestone 1 — Provider selection and loud typed-config construction

Scope: a new module `shikigami-core/src/Shikigami/Behavior/Provider.hs` plus wiring in
the worker and `run-behavior` CLI commands. At the end of this milestone the worker
prints which provider it runs and can be switched to Anthropic by resolved setting,
while all defaults and all tests behave exactly as before.

Create `Shikigami.Behavior.Provider` exporting:

```haskell
data ProviderSelection
  = UseStub
  | UseAnthropic
      { model :: !Model,
        credential :: !CredentialValue
      }

providerSettings :: [Settei.Setting]
resolveProviderSelection :: AppConfig -> Either ConfigError ProviderSelection
describeProviderSelection :: ProviderSelection -> Text
newBehaviorEnvFor :: ProviderSelection -> Maybe TraceSink -> IO BehaviorEnv
lookupAnthropicModel :: Text -> Maybe Model
```

`ProviderSelection` deliberately has no `Show`, `Read`, or JSON instances because its real
branch owns an opaque credential. `describeProviderSelection` pattern-matches and renders only
provider, model id, and `credential=present`.

`resolveProviderSelection` reads typed values already resolved by plan 37. This plan declares
the stable keys `behavior.provider`, `behavior.model`, and secret
`credentials.providers.anthropic.api_key`. The Settei binding table preserves these legacy names:

- `SHIKIGAMI_MODEL_PROVIDER` — `"stub"` (or unset) selects `UseStub`; `"anthropic"`
  selects the real provider; any other value is `Left` with a message listing the
  accepted values.
- `SHIKIGAMI_MODEL` — only consulted for `anthropic`; a catalog model id, default
  `"claude-sonnet-4-6"`. `lookupAnthropicModel` maps ids to the curated
  `Baikai.Models.Generated` values (at minimum `claude-sonnet-4-6`,
  `claude-haiku-4-5`, `claude-opus-4-8`, matching on the catalog `modelId` field). An
  unknown id is `Left` with the known ids in the message.

For `anthropic`, `resolveProviderSelection` additionally requires the configured opaque
credential value and returns a path-qualified `ConfigError` when absent. It never asks Baikai
or `System.Environment` to resolve the secret. This is the fail-fast: the worker must not
start, drain jobs, and journal stub output while the operator believes a model is wired.

`newBehaviorEnvFor` builds the `BehaviorEnv`:

- `UseStub` — exactly what `newBehaviorEnvWithTraceSink` does today
  (`registerStubProvider`, `model = stubModel`).
- `UseAnthropic {model, credential}` — call `Baikai.Provider.Claude.Api.register`, lower the
  opaque credential to process-local Baikai `Options`, and also
  `registerStubProvider` (harmless, keeps the `Custom "stub"` tag answered for any
  test tooling in the same process), and set `model = m`.

Both branches print one loud line to stderr, produced by `describeProviderSelection`:

```text
[shikigami.behavior] model provider: STUB — no model will be called; set behavior.provider=anthropic to use a real model
[shikigami.behavior] model provider: anthropic model=claude-sonnet-4-6 credential=present
```

Keep `newBehaviorEnv` and `newBehaviorEnvWithTraceSink` in
`Shikigami.Behavior.Run` unchanged (stub-only); update their Haddock to say they are
the deterministic test constructors and point at `newBehaviorEnvFor`.

Wire the callers in the worker executable components assigned to `shikigami-workers` by
plan 36 (the legacy source locations named below are orientation only):

- `shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs` (`runWorkerCmd`): replace the
  `newBehaviorEnvWithTraceSink (Just (otelSink tr))` call at line 30 with
  `resolveProviderSelection` followed by `newBehaviorEnvFor sel (Just (otelSink tr))`;
  Configuration resolution happens before this call; typed failures use plan 37's standard
  diagnostic and exit code 4 before any worker resource is acquired.
- `shikigami-cli/src/Shikigami/Cli/Commands/RunBehavior.hs` (`runRunBehavior`): same
  substitution for its `newBehaviorEnv` call, so `run-behavior` becomes the cheapest
  live smoke test of the real provider (no database needed).

Add `baikai-claude` to the `build-depends` of the `shikigami-core` library stanza in
`shikigami-core/shikigami-core.cabal`.

Acceptance: `cabal build all` and `cabal test all` pass; `cabal run shikigami --
run-behavior --agent agents/triage-note.dhall --payload '{}'` with no environment
provider override prints the STUB provider line to stderr and the familiar
`{"reply":"stub-skill: instructions acknowledged; no model was called"}` to stdout;
with `--set behavior.provider=anthropic` and no credential source it exits 4 with a redacted,
path-qualified configuration error.

### Milestone 2 — Thread Options through the skill arm

Scope: make the key source explicit instead of relying on the handler's implicit
fallback, and remove the hardcoded `_Options`.

Edit `shikigami-core/src/Shikigami/Behavior/Run.hs`: add `options :: !Options` to
`BehaviorEnv`. `newBehaviorEnvFor` sets it to `emptyOptions` for the stub and, for Anthropic,
uses a package-internal eliminator to lower `CredentialValue` into
`emptyOptions { apiKey = Just (ApiKeyLiteral secretText) }`. Keep the eliminator adjacent to
the provider builder, never export or retain `secretText`, and never render the resulting
`Options`. Do not use `ApiKeyEnv` or Baikai's `defaultApiKeyEnvForBaseUrl` fallback.

Edit `shikigami-core/src/Shikigami/Behavior/Skill.hs`: give `runSkill` and
`runSkillWith` an `Options` parameter and pass it to the completion call instead of
`_Options` at line 110. New signatures:

```haskell
runSkill :: Model -> Options -> SkillDir -> Value -> IO (Either RunError Value)

runSkillWith ::
  Model ->
  Options ->
  SkillDir ->
  Value ->
  (Model -> Context -> Options -> IO Response) ->
  IO (Either RunError Value)
```

Update the two call sites in `Behavior/Run.hs` (`runSkillWithTrace`, lines 84-88) to
pass `options env`. While here, replace the deprecated `_Options`/`_Context` bases with
`emptyOptions` only where `_Options` was used (leave `_Context` alone; it is not the
subject of this plan).

Add a unit test (new file
`shikigami-core/test/Shikigami/BehaviorProviderSpec.hs`, registered in
`shikigami-core/test/Main.hs`): call `runSkillWith` with a capturing completion
function (an `IORef` that stores the `Options` it received) against the fixture skill
directory `agents/skills/triage-note`, and use a sentinel opaque test credential to assert the
captured `apiKey` is the expected literal source when the env was built for Anthropic and
`Nothing` for the stub. Failure output must not contain the sentinel. The capture seam exists precisely because `runSkillWith` takes
the completion function as an argument — no network, no key needed.

Acceptance: `cabal test all` green including the new spec.

### Milestone 3 — Record modelUsed and prove the real path live

Scope: durable observability plus a manual live smoke.

Edit `shikigami-core/src/Shikigami/Agent/Workflow.hs` `completeSession`
(lines 607-618): replace `modelUsed = Nothing` with
`modelUsed = Just (modelId (model (behaviorEnv deps)))` (import `Baikai.Model
(Model (..))` field accessors as needed; `BehaviorEnv` already carries the `Model`).
The stub records `"stub-v1"` (`StubProvider.hs:39`), a real run records e.g.
`"claude-sonnet-4-6"`. This is a change to a kioku write inside the existing
`complete` step body — the journal step name and its recorded JSON shape (`()`) are
untouched, so replay safety is preserved. Make the equivalent edit in the non-workflow
seam `shikigami-core/src/Shikigami/Agent/Run.hs` (`runAgentWithMemory`, line 121).

Extend an existing workflow spec assertion (e.g. in
`shikigami-core/test/Shikigami/AgentWorkflowSpec.hs`, the "resumes after a crash
between record and complete" case already fetches the session row at lines 156-159) to
assert the completed session's `modelUsed` is `Just "stub-v1"`. Check the
`SessionRow` field name in kioku before writing the assertion.

Then perform the live smoke (requires a real key; do not automate in CI) and paste the
transcript into Surprises & Discoveries:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
cabal run shikigami-run-behavior -- --config /run/secrets/shikigami-anthropic-smoke.yaml \
  --agent agents/triage-note.dhall \
  --payload '{"text":"customer reports the export button crashes the app"}'
```

The root-readable `0600` secret file is supplied out of band and ignored by Git. It sets
`behavior.provider = anthropic`, `behavior.model = claude-haiku-4-5`, and the secret
`credentials.providers.anthropic.api_key`; do not paste its value into this plan, a shell
command, or the transcript.

Expected: the stderr provider line names anthropic and the model; stdout is a
`{"reply": ...}` object whose reply is a genuine model-written triage of the payload —
observably not the fixed stub sentence.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shikigami` inside the nix dev
shell (`nix develop`). Tests provision their own ephemeral Postgres via
`shikigami-migrations` test-support; no database setup is needed for `cabal test`.

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
nix develop
cabal build all
cabal test all
```

Milestone 1 file work: create
`shikigami-core/src/Shikigami/Behavior/Provider.hs`; add it to `exposed-modules` and
add `baikai-claude` to `build-depends` in `shikigami-core/shikigami-core.cabal`; edit
the worker and `run-behavior` command components after plan 36 relocates them into
`shikigami-workers`; do not recreate `shikigami-cli`.

Milestone 1 checks, with expected transcripts:

```bash
cabal run shikigami-run-behavior -- --agent agents/triage-note.dhall --payload '{}' \
  --config /run/secrets/shikigami/provider-live.yaml
```

```text
[shikigami.behavior] model provider: STUB — no model will be called; set behavior.provider=anthropic to use a real model
{"reply":"stub-skill: instructions acknowledged; no model was called"}
```

```bash
cabal run shikigami-run-behavior -- --set behavior.provider=anthropic \
  --agent agents/triage-note.dhall --payload '{}'; echo "exit=$?"
```

```text
[shikigami] config: credentials.providers.anthropic.api_key is required when behavior.provider=anthropic
exit=4
```

The unknown-model case is an in-memory Settei resolution test using a sentinel secret, not a
shell command carrying a fake key. It exits 4 and lists the known model ids while every
diagnostic rendering omits the sentinel.

Milestone 2 file work: edit `shikigami-core/src/Shikigami/Behavior/Run.hs` and
`shikigami-core/src/Shikigami/Behavior/Skill.hs`; add
`shikigami-core/test/Shikigami/BehaviorProviderSpec.hs` and register it in
`shikigami-core/test/Main.hs`. Then:

```bash
cabal test all
```

Milestone 3 file work: edit `shikigami-core/src/Shikigami/Agent/Workflow.hs` (line 615
region) and `shikigami-core/src/Shikigami/Agent/Run.hs` (line 121 region); extend the
session assertion in `shikigami-core/test/Shikigami/AgentWorkflowSpec.hs`; run the live
smoke shown in Milestone 3 (manual, key required).

Worker startup check (needs a migrated local database; `just create-database` sets one
up using the dev stack's Settei source):

```bash
cabal run shikigami-worker -- --config config/dev.yaml
```

```text
[worker] loaded 4 agents
[shikigami.behavior] model provider: STUB — no model will be called; set behavior.provider=anthropic to use a real model
[shikigami.worker] starting; draining shikigami_run_jobs
```


## Validation and Acceptance

Behavioral acceptance, in order of strength:

1. Default is unchanged and loud. With no provider override, `cabal test all`
   passes untouched tests, and both `worker` and `run-behavior` print the STUB provider
   line to stderr on startup. The stub reply text is byte-identical to before.
2. Misconfiguration cannot run. `behavior.provider=anthropic` without
   `credentials.providers.anthropic.api_key`, or with an unknown `behavior.model`, exits 4
   before any queue draining, with the messages shown in Concrete Steps.
3. Options provably reach the model call. `BehaviorProviderSpec` captures the `Options`
   passed to the completion function and asserts the Anthropic path carries the sentinel
   literal lowered from the opaque Settei value. This test fails before Milestone 2 (the
   hardcoded `_Options` has `apiKey = Nothing`) and passes after without reading the environment.
4. Model identity is durable. The extended `AgentWorkflowSpec` assertion shows the
   completed kioku session row carries `modelUsed = Just "stub-v1"` under the stub;
   after a live run, querying the session row shows the real model id.
5. Live smoke (manual). The Milestone 3 transcript shows a model-authored reply that is
   not the stub sentence, with the anthropic provider line on stderr.
6. Configuration conformance. A test resolves equivalent file, secret, environment, and
   CLI-source inputs through Settei; direct `getEnv`/`lookupEnv` calls do not exist in
   provider code, and diagnostic output contains no API-key bytes.


## Idempotence and Recovery

Every step is additive and re-runnable. Provider registration in baikai is
overwrite-by-tag, so calling `newBehaviorEnvFor` (or the old constructors) repeatedly
is harmless. The cabal edit is idempotent. If Milestone 2's signature change breaks
compilation midway, the two call sites in `Behavior/Run.hs` plus the new spec are the
complete caller set — `cabal build all` lists any missed site. Rolling back is a plain
`git checkout` of the touched files; no data or migration is involved. The live smoke
spends real API money — use `claude-haiku-4-5` and a single small payload.


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 36, 37, and 47. Port against Baikai 0.4.1.0: construct
configuration with `emptyOptions`/`emptyContext` and treat provider failures reported in
`Response.errorInfo` as failures, using `isRetryable` to feed plan 17's taxonomy. Do not
construct hidden records directly or preserve an environment fallback below Settei's
composition root.


## Interfaces and Dependencies

Hard dependencies: plans 36 and 37. Libraries: `settei`, `baikai` (already a dependency) and `baikai-claude` (added by this plan;
already fetched by `cabal.project:126-128`). No new external services.

Signatures that must exist at the end (all verified against the baikai sources at
`/Users/shinzui/Keikaku/bokuno/baikai`):

```haskell
-- shikigami-core/src/Shikigami/Behavior/Provider.hs (new)
data ProviderSelection
  = UseStub
  | UseAnthropic
      { model :: !Baikai.Model.Model,
        credential :: !Shikigami.App.Config.CredentialValue
      }
resolveProviderSelection :: Shikigami.App.Config.AppConfig -> Either ConfigError ProviderSelection
describeProviderSelection :: ProviderSelection -> Data.Text.Text
lookupAnthropicModel :: Data.Text.Text -> Maybe Baikai.Model.Model
newBehaviorEnvFor :: ProviderSelection -> Maybe Baikai.Trace.TraceSink -> IO Shikigami.Behavior.Run.BehaviorEnv

-- shikigami-core/src/Shikigami/Behavior/Run.hs (extended)
data BehaviorEnv = BehaviorEnv
  { runtime :: !Handan.Runtime.Runtime,
    model :: !Baikai.Model.Model,
    options :: !Baikai.Options.Options,
    traces :: !(Maybe Baikai.Trace.TraceSink)
  }

-- shikigami-core/src/Shikigami/Behavior/Skill.hs (changed)
runSkill :: Baikai.Model.Model -> Baikai.Options.Options -> SkillDir -> Data.Aeson.Value -> IO (Either RunError Data.Aeson.Value)
runSkillWith :: Baikai.Model.Model -> Baikai.Options.Options -> SkillDir -> Data.Aeson.Value -> (Baikai.Model.Model -> Baikai.Context.Context -> Baikai.Options.Options -> IO Baikai.Response.Response) -> IO (Either RunError Data.Aeson.Value)
```

Revision note (2026-07-22): Rebased configuration and package ownership on plans 36/37;
removed the plan-local `lookupEnv` convention and made secret redaction/non-serialization
an acceptance requirement.

Consumed baikai interfaces (verified):

```haskell
Baikai.Provider.Claude.Api.register :: IO ()                          -- baikai-claude .../Api.hs:101
Baikai.Provider.Registry.completeRequest :: Model -> Context -> Options -> IO Response
Baikai.Auth.ApiKeySource                                              -- Auth.hs:26; process-local boundary only
Baikai.Options.Options { apiKey :: Maybe ApiKeySource, ... }          -- Options.hs:70
Baikai.Options.emptyOptions :: Options                                -- Options.hs:91
Baikai.Models.Generated.anthropic_claude_sonnet_4_6 :: Model          -- Generated.hs:201
Baikai.Models.Generated.anthropic_claude_haiku_4_5 :: Model           -- Generated.hs:63
Baikai.Models.Generated.anthropic_claude_opus_4_8 :: Model            -- Generated.hs:155
```

Downstream consumers to keep compiling: `Shikigami.Agent.Workflow.runBehaviorStep`,
`Shikigami.Agent.Run.runAgentWithMemory`, `Shikigami.Agent.Conversation` (line 165),
and the `run-behavior` command component in `shikigami-workers` — all call `runBehavior`, whose signature this
plan does not change (plan 15 does).
