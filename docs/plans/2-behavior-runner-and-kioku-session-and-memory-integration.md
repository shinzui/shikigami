---
id: 2
slug: behavior-runner-and-kioku-session-and-memory-integration
title: "Behavior Runner and kioku Session and Memory Integration"
kind: exec-plan
created_at: 2026-06-24T23:41:28Z
intention: "intention_01kvy04813ehbv9aghj3tn4zjx"
master_plan: "docs/masterplans/1-shikigami-declared-agent-runtime-bootstrap.md"
---

# Behavior Runner and kioku Session and Memory Integration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

**shikigami** (式神, "summoned spirit-servant") is a runtime in which an autonomous agent is
*declared*, not coded: you write a short typed file that says "run **this behavior**, when
**this trigger** fires, send the result to **these sinks**," and a thin worker runs it forever.
This ExecPlan builds the *heart* of that runtime — the part that actually **runs an agent's
behavior** — and gives the runtime a **memory** it never had in the original design.

Concretely, after this plan a developer can, from a fresh checkout of
`/Users/shinzui/Keikaku/bokuno/shikigami` in its nix dev shell, do two things they could not do
before:

1. **Run an agent's behavior with one function and see a JSON result, with no model key and no
   database.** A declared agent's `behavior` is a *union* of two arms — a typed `shikumi` program
   run through `shinzui/handan`, or a Skill directory (an instruction file `SKILL.md`) run through
   `shinzui/baikai`. A new function `Shikigami.Behavior.Run.runBehavior` dispatches on that union
   and returns the behavior's output as a JSON value. Both arms run **deterministically with
   stubs**: the program arm runs a registered `noop-summary` task whose body returns a fixed JSON
   value (built with `shikumi`'s `Embed` constructor, which carries an opaque effectful step and
   so makes *no* model call), and the skill arm runs against a **stub baikai provider** that
   returns a fixed assistant reply, so neither needs an API key. A tiny CLI command,
   `shikigami run-behavior --agent <file>`, prints the output value.

2. **Run an agent and watch it remember across runs.** Each run opens a **kioku session** (記憶,
   "memory" — a separate, reusable, event-sourced Haskell library at
   `/Users/shinzui/Keikaku/bokuno/kioku`), **recalls** the agent's prior learnings *before* the
   behavior runs, runs the behavior, **records** the behavior's output as a durable **kioku
   memory** scoped to that agent, then **completes** the session. A new CLI command,
   `shikigami agent-run --agent <name>`, prints `recalled 0 prior memories` on the first run and
   `recalled 1 prior memories: <the learning from run 1>` on the second — proving the agent
   accumulates knowledge instead of starting blank every hour.

This is the headline change from the design spec `docs/initial-spec.md`: the spec planned a
bespoke `agent_runs` SQL table and a `Shikigami.Session` module to record runs. **That table and
module are not built.** kioku's `Session` aggregate *is* "the intention-free mirror of rei's
`AgentSessionExistsData`" the spec wanted, generalized — so shikigami records each run as a kioku
session and each learning as a kioku memory, which both removes a bespoke table and *adds* the
across-run memory the spec explicitly lacked ("an agent that runs every hour learns nothing from
its previous runs").

What this plan deliberately leaves to later plans: the **supervised worker** that drains a job
queue and calls `runBehavior` in a retry loop is EP-5 (`docs/plans/5-the-supervised-worker-and-run-orchestration.md`);
the **sinks** that consume `runBehavior`'s output value (write a kawa digest, raise a kizashi
signal) are EP-3 (`docs/plans/3-sink-dispatcher-permission-gate-and-kawa-stub.md`); the **triggers**
that decide *when* to fire are EP-4 (`docs/plans/4-trigger-evaluators-and-the-activity-v1-stream-consumer.md`).
This plan proves the runner and the kioku seam **in isolation** through its own demo CLI; the
worker, sinks, and triggers integrate it afterward.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: `shikigami-core` exposes `Shikigami.Program.Registry.programRegistry :: [Task]` with a
      `noop-summary` task whose program is built with `shikumi`'s `embed` and returns a fixed JSON
      value (no model call). ✅ 2026-06-24
- [x] M1: `shikigami-core` exposes `Shikigami.Behavior.StubProvider.registerStubProvider :: IO ()`
      that installs a deterministic baikai provider (`Custom "stub"` tag) returning a fixed assistant
      reply (no key). ✅
- [x] M1: `Shikigami.Behavior.Skill.runSkill` loads a skill `SKILL.md` (hand-rolled frontmatter
      split), builds a `Baikai.Context`, runs `completeRequest` against the stub provider, and
      returns the reply as `{"reply": …}`. (The stub returns no tool calls, so a single completion
      suffices — the `appendToolResult` loop is unnecessary; recorded in the Decision Log.) ✅
- [x] M1: `Shikigami.Behavior.Run.runBehavior :: BehaviorEnv -> AgentDecl -> Value -> IO (Either RunError Value)`
      dispatches all three arms (Deterministic → `UnsupportedBehavior`, EP-6's concern);
      `shikigami run-behavior --agent <file>` prints the fixed output for a program-agent
      (`{"summary":…,"verb":"heartbeat.tick"}`) and a skill-agent (`{"reply":…}`), no DB, no key. ✅
- [x] M2: `Shikigami.Memory.Scope` (consumed from EP-1, already present) exposes
      `agentScope`/`sharedScope`; `Shikigami.Agent.Run.runAgentWithMemory` opens a kioku session,
      recalls, runs the behavior, records the output as a memory, completes the session. ✅ 2026-06-24
- [x] M2: `shikigami agent-run --agent <name>` first run prints `recalled 0 prior memories` and
      records a learning; one `kiroku.kioku_sessions` row (`focus='ShikumiProgram'`, status
      `completed`) and one `kiroku.kioku_memories` row exist under `scope_kind='agent',
      scope_ref='heartbeat'`. ✅
- [x] M3: a second `agent-run` of the same agent prints `recalled 1 prior memories:` + run 1's
      learning (`… [pattern/medium] noop-summary produced a fixed digest`); two session rows and two
      memory rows under the agent scope (across-run persistence). ✅
- [x] M3 (optional): `agent-run --from-activity <file>` maps an `activity.v1` envelope (EP-1's
      `ActivityEnvelope`) into a kioku memory under the agent scope — content = rendered payload,
      tags `["subject:intention","verb:digest.produced"]`, `created_at` = the envelope `occurred_at`. ✅


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **kioku's `*Data` command records are NOT re-exported from the top-level modules (affects M2
  imports).** Verified against the pinned clone (commit kioku `608fbc9`):
  `Kioku.Session` exports `start/complete/failSession/recordTurn` but not the `StartSessionData`/
  `CompleteSessionData`/`FailSessionData` constructors; `Kioku.Memory` likewise omits
  `RecordMemoryData`. Per the Context import caveat, the compliant route is
  `import Kioku.Session.Domain (StartSessionData (..), CompleteSessionData (..), FailSessionData (..))`
  and `import Kioku.Memory.Domain (RecordMemoryData (..))` (the *data* modules, part of the command
  surface — distinct from internal transducer/event-stream internals).

- **baikai's `Api` type has a `Custom !Text` escape hatch (affects M1 stub).** The pinned baikai
  (commit `a219ace`, which differs from the local `bokuno/baikai` checkout — the pinned clone was the
  source of truth) defines `Api = OpenAIChatCompletions | AnthropicMessages | OpenAICompletionsCli |
  AnthropicMessagesCli | Custom !Text`. The stub provider and stub model both use `Custom "stub"` as
  the API tag, so the stub answers its own model without colliding with a real provider. baikai also
  ships base values `_Model`, `_Response`, `_Context`, `_Options` for record-update construction —
  used instead of `#field` lenses (IP-9 forbids `Data.Generics.Labels`).


## Decision Log

Record every decision made while working on the plan.

- Decision: Build the `noop-summary` program with `shikumi`'s `Embed` constructor (a node carrying
  an opaque effectful step), not a `Predict` node.
  Rationale: `Embed`'s body has type
  `forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o` (verified in
  `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Program.hs`), so it runs under the
  ordinary `runProgram`/`Handan.Runtime.runProgramWith` interpreter chain **without issuing any
  `LLM` call** — it just `pure`s a fixed value. That makes the program arm provable with no API
  key, exactly as the kioku prior-art plan and the spec's "Conformance & De-risking" require.
  Date: 2026-06-24

- Decision: Run the skill arm against a **stub baikai provider** registered in baikai's process-
  global provider registry, not a live model.
  Rationale: `Baikai.Provider.Registry` (verified at
  `/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Provider/Registry.hs`) dispatches
  `completeRequest` by the model's `Api` tag and throws `ProviderUnavailable` if no handler is
  registered. Registering an `ApiProvider` whose `complete = \_ _ _ -> pure fixedResponse` makes
  the skill arm deterministic and key-free in CI — the open question "provider registration for
  the skill arm in CI" (initial-spec) is settled to "stub provider, mirrors noop-summary".
  Date: 2026-06-24

- Decision: **kioku replaces the spec's `agent_runs` table.** An agent run is a `Kioku.Session`
  (started at run begin, completed/failed at run end); the agent's learnings are `Kioku.Memory`
  records. shikigami builds no `agent_runs` table and no `Shikigami.Session` module.
  Rationale: MasterPlan #1 Decision Log and IP-3; the spec itself calls `agent_runs` "the
  intention-free mirror of rei's `AgentSessionExistsData`", which kioku's Session aggregate *is*,
  generalized. Reusing kioku adds across-run memory the spec lacked.
  Date: 2026-06-24

- Decision: Scope mapping — per-agent memory is
  `ScopeEntity (Namespace "shikigami") (ScopeKind "agent") <agentName>`; cross-agent shared memory
  is `ScopeGlobal (Namespace "shikigami")`. The session for a run carries the same per-agent scope
  plus `subjectRef = Just (idText sid)` (the run id).
  Rationale: MasterPlan IP-3 reserves this scope shape; keyed by the *stable agent name* (not a run
  id) so memory is the "memory of this agent across its runs". The helper `Shikigami.Memory.Scope`
  is owned by EP-1 per IP-3; if EP-1 already shipped it this plan consumes it unchanged, otherwise
  this plan adds it (see Interfaces and Dependencies). Verified `MemoryScope` shape against
  `/Users/shinzui/Keikaku/bokuno/kioku/kioku-api/src/Kioku/Api/Scope.hs`.
  Date: 2026-06-24

- Decision: kioku's write/read API runs in **`Eff AppEffects`**, not `IO`; consumers wrap each call
  in `Kioku.App.runAppIO env`. `Kioku.Session.start`/`complete`/`failSession` take their `*Data`
  records and return `Either SessionWriteError SessionId`; `Kioku.Memory.record` takes
  `RecordMemoryData` and returns `Either MemoryWriteError MemoryId`; `Kioku.Recall.getActiveByScope`
  returns `Either ReadModelError [MemoryRecord]`.
  Rationale: verified against the real sources `Kioku/Session.hs`, `Kioku/Memory.hs`,
  `Kioku/Recall.hs`, `Kioku/App.hs`. **This corrects the kioku prior-art plan
  `/Users/shinzui/Keikaku/bokuno/kioku/docs/plans/6-shikigami-memory-integration-with-kioku.md`,
  which sketched `runAppIO env $ Session.start StartSessionData{…}` returning a bare `SessionId` in
  IO and a `Kioku.Session.complete sid done summary` 3-arg form.** The real `complete` takes one
  `CompleteSessionData` record; the demo here uses the real signatures. The *shape* of the
  prior-art seam (open → recall → record → complete) is reused faithfully; only the exact
  signatures are corrected.
  Date: 2026-06-24

- Decision (impl): the skill arm runs a **single** `completeRequest` rather than an
  `appendToolResult` tool loop.
  Rationale: with the stub provider the reply carries no tool calls, so the loop would terminate
  after one completion anyway. A single completion keeps the M1 code minimal and key-free while
  still exercising `Context` construction + `completeRequest` + `flattenAssistantBlocks` rendering.
  When a real provider that emits tool calls is wired (a later plan), the loop can be reintroduced
  around `completeRequest`/`appendToolResult` without changing `runSkill`'s signature.
  Date: 2026-06-24

- Decision (impl): the `Behavior` union shipped by EP-1 has **three** arms (Deterministic,
  ShikumiProgram, Skill), not the two this plan's prose assumed. `runBehavior` handles
  `Deterministic{}` by returning `Left (UnsupportedBehavior "Deterministic")` (deterministic-rule
  behaviors are EP-6's detector concern), keeping the pattern match total under `-Wincomplete-patterns`.
  Date: 2026-06-24

- Decision: `runBehavior`'s contract is
  `runBehavior :: BehaviorEnv -> AgentDecl -> Value -> IO (Either RunError Value)` (IP-4). The
  input `Value` is the trigger payload (the demo passes `Aeson.Null` or a tiny fixture); the output
  `Value` is the behavior's result, which the sinks (EP-3) later consume.
  Rationale: MasterPlan IP-4; matches the spec's "behavior runner (the new surface)" exactly. EP-3
  and EP-4 build against a fixed sample output `Value` until this plan lands.
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-24): EP-2 complete; all three milestones built and verified.** Both Purpose
behaviors hold from the dev shell:

1. `shikigami run-behavior --agent <file>` runs either behavior arm and prints a JSON result with no
   model key and no database — `{"summary":…,"verb":"heartbeat.tick"}` for the `noop-summary` program
   arm (a shikumi `Embed` run through handan), `{"reply":…}` for the skill arm (a baikai completion
   against the `Custom "stub"` provider).
2. `shikigami agent-run --agent heartbeat` opens a kioku session, recalls prior memory, runs the
   behavior, records the output as a kioku memory under the agent scope, and completes the session.
   Run twice, the second run prints `recalled 1 prior memories:` and run 1's learning — the agent
   accumulates knowledge across runs, the capability the spec explicitly lacked. The spec's
   `agent_runs` table is replaced: a run is a `kioku_sessions` row, a learning is a `kioku_memories`
   row (verified by SQL). `--from-activity` additionally maps an `activity.v1` envelope into a memory.

**Deliverables for downstream plans:** `Shikigami.Behavior.Run.runBehavior` (IP-4, the contract EP-5's
worker calls and EP-3's sinks consume the output of), `Shikigami.Behavior.{StubProvider,Skill}`,
`Shikigami.Program.Registry` (the `[Task]` seam EP-6's detectors extend), `Shikigami.Behavior.Error`,
and `Shikigami.Agent.Run.{runAgentWithMemory,recordActivityAsMemory}`.

**Deviations from the plan as written (recorded in the Decision Log / Surprises):** (a) the skill arm
runs a single `completeRequest` rather than a tool loop (the stub emits no tool calls); (b) `Behavior`
has three arms (EP-1 added `Deterministic`), handled as `UnsupportedBehavior`; (c) kioku's `*Data`
records are imported from `Kioku.Session.Domain`/`Kioku.Memory.Domain` (not re-exported top-level);
(d) the plan's code sketches were completed against the **pinned** library sources (baikai `a219ace`,
which differs from the local checkout) — `Api`'s `Custom "stub"` tag, the `_Model`/`_Response`/
`_Context` bases, and record-update construction (no `#field` lenses, per IP-9).

**Gaps / forward notes:** the recommended `tasty` tests (plan Step 4 — runner-no-DB + ephemeral-DB
across-run proof via `withShikigamiMigratedDatabase`) were not added; the milestone acceptances are
proven via the CLI + SQL instead. A later hardening pass (or EP-5/EP-6) can add the automated test.


## Context and Orientation

Read this section fully before running anything. It assumes you have never seen any of these
repositories.

### Where you are working and what already exists

You work inside `/Users/shinzui/Keikaku/bokuno/shikigami`, a Haskell project laid out as four
cabal packages (the kizashi/kioku template): `shikigami-api` (client-safe wire types),
`shikigami-core` (the runtime), `shikigami-cli` (the `shikigami` executable), and
`shikigami-migrations` (the database migration composition). **This plan hard-depends on EP-1**
(`docs/plans/1-scaffold-agent-schema-loader-and-validate-cli.md`), which delivers, and which you
must read and rely on:

- The buildable four-package project, the `flake.nix` dev shell, and the `cabal.project` pin-set
  (which already pins kioku, handan, shikumi, baikai, and the kikan stack — MasterPlan IP-8). You
  do **not** add dependencies to `cabal.project`; if a package you need is not pinned, that is an
  amendment to EP-1's deliverable (record it here and in EP-1).
- The wire types in `shikigami-api` (`Shikigami.Api.Agent`): `AgentDecl { name, behavior, trigger,
  sinks }`, `Behavior = ShikumiProgram { task :: Text } | Skill { path :: FilePath }`,
  `Trigger`, `StreamMatch`, `Sink`, and the nine-field `ActivityEnvelope` (MasterPlan IP-1/IP-6).
  This plan **imports** these; it never redefines them.
- The Dhall loader `Shikigami.Agent.Loader.loadAgent :: FilePath -> IO (Either LoadError AgentDecl)`
  and the `validate` CLI (so `run-behavior --agent <file>` can load a manifest).
- The migration composition (`shikigami-migrations`) that lands kioku's tables
  (`kiroku.kioku_sessions`, `kiroku.kioku_memories`, `kiroku.kioku_turns`) plus the shikigami
  suppression table, and the test-support sublibrary
  `Shikigami.Migrations.TestSupport.withShikigamiMigratedDatabase :: (Text -> IO a) -> IO a`
  (MasterPlan IP-3). The `agent-run` demo needs these tables to exist.
- Possibly `Shikigami.Memory.Scope` (MasterPlan IP-3 assigns it to EP-1). **Check first**: if
  `shikigami-core/src/Shikigami/Memory/Scope.hs` exists, consume it; if not, this plan creates it
  (the module is small and self-contained — see Interfaces and Dependencies — and EP-1 can later
  adopt it). Either way, record which happened in the Progress and Decision Log.

### The libraries this plan consumes (and exactly what from each)

You will read these real sources to copy signatures, **never guess**:

- **handan** at `/Users/shinzui/Keikaku/bokuno/handan` — the typed-program runtime. From
  `handan-core/src/Handan/Runtime.hs`: `newRuntime :: IO Runtime` (registers the Claude provider
  and returns a handle holding an LLM config + default model) and
  `runProgramWith :: Runtime -> Program i o -> i -> IO (Either ShikumiError o)`. From
  `handan-core/src/Handan/Task.hs`: the existential record
  `data Task = forall i o. Task { taskName :: Text, taskKind :: TaskKind, taskSummary :: Text,
  taskParse :: ArgMap -> Either Text i, taskRun :: Runtime -> i -> IO Envelope, taskEval :: Maybe (EvalHandle i o) }`,
  and the worked `SmokeInput`/`SmokeOutput` `predict` example. From
  `handan-cli/src/Handan/Registry.hs`: `registry :: [Task]` + `lookupTask :: Text -> Maybe Task`
  (the pattern shikigami's own `Shikigami.Program.Registry` mirrors). From
  `handan-cli/src/Handan/Demo.hs`: how `demoTask` builds a `Task` whose `taskRun` ignores the
  `Runtime` and runs key-free (the pattern for a deterministic stub).
- **shikumi** at `/Users/shinzui/Keikaku/bokuno/shikumi` — the typed program GADT. From
  `shikumi/src/Shikumi/Program.hs`: the `Program i o` GADT with constructors
  `Predict | Compose | FMap | Map | Parallel | Retry | RetryWhen | Validate | MajorityVote |
  Ensemble | Embed`, the smart constructor
  `embed :: (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Program i o`,
  and `runProgram :: (LLM :> es, Error ShikumiError :> es) => Program i o -> i -> Eff es o`. The
  `Embed` body runs with **no** `LLM` call when it just `pure`s a value — that is the key to a
  key-free `noop-summary`.
- **baikai** at `/Users/shinzui/Keikaku/bokuno/baikai` — the provider abstraction (the skill arm).
  From `baikai/src/Baikai/Provider/Registry.hs`:
  `completeRequest :: Model -> Context -> Options -> IO Response`, the `ApiProvider` record
  (`{ apiTag :: Api, stream :: …, complete :: Model -> Context -> Options -> IO Response }`),
  `registerApiProvider :: ApiProvider -> IO ()` (installs into the process-global registry), and
  `newProviderRegistry`/`registerApiProviderWith`/`completeRequestWith` (an isolated registry, used
  by the test). From `baikai/src/Baikai/Context.hs`:
  `data Context = Context { systemPrompt :: Maybe Text, messages :: Vector Message, tools :: Vector Tool }`,
  `_Context` (the empty base), and `appendToolResult :: Context -> Response -> (ToolCall -> IO ToolResult) -> IO Context`
  / `appendToolResultText :: Context -> Response -> (ToolCall -> IO Text) -> IO Context`. From
  `baikai/src/Baikai/Tool.hs`: `data Tool = Tool { name :: Text, description :: Text, parameters :: Value }`
  and `ToolChoice`. From `baikai/src/Baikai/Response.hs`: `data Response { message :: AssistantPayload, … }`,
  `_Response` (a blank assistant turn at epoch — the base for the stub reply), and
  `flattenAssistantBlocks :: Response -> Vector AssistantContent`. baikai ships **no SKILL.md
  parser**; this plan parses the `SKILL.md` YAML frontmatter + Markdown body itself (a tiny split
  on the `---` fences; see Plan of Work).
- **kioku** at `/Users/shinzui/Keikaku/bokuno/kioku` — the memory/session library (the kioku seam).
  Import only top-level modules + `kioku-api` types — **never** `Kioku.*.Domain.*` internals
  (MasterPlan IP-3). The exact surface you use:
  - `kioku-api` `Kioku.Api.Scope`: `Namespace (..)`, `ScopeKind (..)`,
    `MemoryScope (ScopeGlobal Namespace | ScopeEntity Namespace ScopeKind Text)`.
  - `kioku-api` `Kioku.Api.Types`: `MemoryType (MemoryFact|MemoryPattern|MemoryPreference|
    MemoryConstraint|MemoryInstruction)`, `Confidence (HighConfidence|MediumConfidence|
    LowConfidence)`, `MemoryRecord (..)` (fields `memoryId, agentId, sessionId, scope, memoryType,
    content, priority, confidence, tags, status, createdAt`).
  - `kioku-api` `Kioku.Id`: `SessionId`, `MemoryId`, `genSessionId :: MonadIO m => m SessionId`,
    `genMemoryId :: MonadIO m => m MemoryId`, `idText :: KindID prefix -> Text`.
  - `kioku-core` `Kioku.App`: `data AppEnv = AppEnv { store :: KirokuStore, tracer :: Tracer,
    metrics :: Maybe KeiroMetrics }`, `runAppIO :: AppEnv -> Eff AppEffects a -> IO (Either StoreError a)`,
    `noopTracer :: IO Tracer`.
  - `kioku-core` `Kioku.Session`: `start :: StartSessionData -> Eff es (Either SessionWriteError SessionId)`,
    `complete :: CompleteSessionData -> Eff es (Either SessionWriteError SessionId)`,
    `failSession :: FailSessionData -> Eff es (Either SessionWriteError SessionId)`,
    `recordTurn :: RecordTurnData -> Eff es (Either SessionWriteError SessionId)`. The `*Data`
    records (re-exported via `Kioku.Session` — confirm with the import below — defined in
    `Kioku.Session.Domain`): `StartSessionData { sessionId, agentId, focus, scope, subjectRef,
    previousSessionId, startedAt }`, `CompleteSessionData { sessionId, completedAt, modelUsed,
    summary }`, `FailSessionData { sessionId, failedAt, errorMessage }`.
  - `kioku-core` `Kioku.Memory`: `record :: RecordMemoryData -> Eff es (Either MemoryWriteError MemoryId)`.
    `RecordMemoryData { memoryId, agentId, sessionId, scope, memoryType, content, priority,
    confidence, tags, supersedes, recordedAt }`.
  - `kioku-core` `Kioku.Recall`: `getActiveByScope :: MemoryScope -> Eff es (Either ReadModelError [MemoryRecord])`.
  - `kiroku-store` `Kiroku.Store.Connection`: `KirokuStore`, `withStore`, `defaultConnectionSettings`
    (open the store in the CLI, as kioku's own demo does).

  **Import-availability caveat:** MasterPlan IP-3 says consume only top-level `Kioku.*` modules +
  `kioku-api` types. The `*Data` command records live in `Kioku.Session.Domain` /
  `Kioku.Memory.Domain` (you read those only to learn the fields). Before writing the imports,
  **verify whether the top-level `Kioku.Session` / `Kioku.Memory` modules re-export the `*Data`
  constructors** (run the check in Concrete Steps Step 0). If they do, import the records from the
  top-level module. If they do not, the smallest compliant route is `import Kioku.Session.Domain
  (StartSessionData (..), CompleteSessionData (..), FailSessionData (..))` and
  `import Kioku.Memory.Domain (RecordMemoryData (..))` — these are the *data* modules holding the
  command records, which are part of the consumable command surface, distinct from internal
  transducer/event-stream modules. Record which route was needed in Surprises & Discoveries.

### Terms of art (defined in plain language)

- **Behavior union.** A declared agent's `behavior` field is one of two shapes: `ShikumiProgram
  { task :: Text }` names a typed program in shikigami's program registry; `Skill { path ::
  FilePath }` points at a directory containing a `SKILL.md` instruction file. `runBehavior`
  pattern-matches this to choose which arm to run.
- **`shikumi` program.** A typed, inspectable tree of LM operations (`Program i o`). Here we only
  use the `Embed` node, which carries an opaque effectful step; our step just returns a fixed JSON
  value, making no model call.
- **handan `Task`.** An existential record bundling a named `shikumi` program with how to parse its
  input and how to run it. shikigami keeps its own list of `Task`s in `Shikigami.Program.Registry`.
- **Skill / `SKILL.md`.** A skill is a directory `<name>/` containing `SKILL.md`: YAML frontmatter
  (required `name` matching the directory, required `description`, optional `allowed-tools`) plus a
  Markdown instruction body. The skill arm turns the frontmatter+body into a baikai `Context` and
  drives a completion.
- **baikai provider / stub provider.** baikai dispatches a completion request to a *provider*
  registered for the model's API tag. A **stub provider** is a handler whose `complete` ignores the
  request and returns a fixed `Response`, so the run is deterministic and needs no API key.
- **kioku session.** An event-sourced record of one agent run: `Kioku.Session.start` opens it,
  `complete`/`failSession` closes it. Projected to the `kiroku.kioku_sessions` read-model table.
- **kioku memory.** An event-sourced durable learning recorded by `Kioku.Memory.record`. Projected
  to `kiroku.kioku_memories`, queryable by scope via `Kioku.Recall.getActiveByScope`.
- **MemoryScope.** kioku's generic scoping value. shikigami uses `Namespace "shikigami"`, kind
  `"agent"`, ref = the agent name for per-agent memory.


## Plan of Work

The work is three milestones. **M1** builds the behavior runner over both arms with deterministic
stubs and proves it via a CLI that prints a fixed output value — no database, no model key. **M2**
adds the kioku seam: a run that opens a session, recalls prior memory, runs the behavior, records
the output as a memory, and completes the session, proved via SQL on the first run. **M3** proves
across-run persistence (run twice, second run recalls the first) and optionally maps an
`activity.v1` envelope into a memory. Each milestone leaves the tree building (`cabal build all`)
and is independently verifiable.

All new code lives in `shikigami-core` (the runtime modules) and `shikigami-cli` (the demo
commands), under `/Users/shinzui/Keikaku/bokuno/shikigami`. New modules must be added to the
`exposed-modules` of their package's `.cabal` file (a module left in `other-modules` produces a
"hidden module" build error). All Haskell follows MasterPlan IP-9 (GHC2024, the `common` stanza,
postpositive `qualified` imports, strict `!` fields, explicit deriving, the `Shikigami.Prelude`
that does **not** re-export `Data.Generics.Labels`) — see Coding Conventions at the end.

### Milestone M1 — the behavior runner over both arms, with deterministic stubs

**Scope and result.** At the end of M1, `Shikigami.Behavior.Run.runBehavior` dispatches a loaded
`AgentDecl` on its behavior union and returns the behavior's output as a JSON `Value`. The
`ShikumiProgram` arm looks the named task up in `Shikigami.Program.Registry`, builds a
`Handan.Runtime` once, and runs the task's program via `runProgramWith`; the registered
`noop-summary` task returns a fixed JSON value via `shikumi`'s `Embed` (no model call). The `Skill`
arm loads `SKILL.md`, builds a baikai `Context`, and runs `completeRequest` + a tool loop against a
**stub baikai provider** (no key). A CLI command `shikigami run-behavior --agent <file>` prints the
output for both a program-agent and a skill-agent. No database is touched in M1.

**Files created/changed in M1** (all under `/Users/shinzui/Keikaku/bokuno/shikigami`):

`shikigami-core/src/Shikigami/Program/Registry.hs` — the program registry, mirroring
`Handan.Registry`. It exposes the catalog and a name lookup, and defines the `noop-summary` task:

```haskell
module Shikigami.Program.Registry
  ( programRegistry
  , lookupTask
  , noopSummaryTask
  ) where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Handan.Task (Task (..), TaskKind (KEffect), EvalHandle)
import Handan.Contract (Envelope (..), Kind (Effect), Status (Ok))
import Data.List qualified as List

-- | The single list of every program shikigami knows about. EP-5's real
--   detectors append their tasks here. For this plan it is just the stub.
programRegistry :: [Task]
programRegistry = [noopSummaryTask]

lookupTask :: Text -> Maybe Task
lookupTask nm = List.find (\(Task { taskName }) -> taskName == nm) programRegistry

-- | A deterministic, key-free task. Its program is a shikumi 'Embed' node whose
--   body returns a fixed JSON value and issues NO model call, so the program arm
--   is provable without a provider configured. EP-5 swaps Embed for Predict.
noopSummaryTask :: Task
noopSummaryTask = ...   -- see noopSummaryProgram below; taskRun runs it via the Runtime
```

The `noop-summary` *program* is the load-bearing detail. shikumi's `embed` smart constructor has
type `embed :: (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Program i o`,
and `runProgram (Embed f) i = f i`. So a program that ignores its input and `pure`s a fixed value
runs with no model call:

```haskell
import Shikumi.Program (Program, embed)
import Data.Aeson (Value, object, (.=))

-- input and output are both Aeson Value so the runner is uniform across tasks.
noopSummaryProgram :: Program Value Value
noopSummaryProgram = embed (\_input -> pure noopBody)

noopBody :: Value
noopBody =
  object
    [ "summary" .= ("noop-summary produced a fixed digest" :: Text)
    , "verb"    .= ("heartbeat.tick" :: Text)
    ]
```

There are two equally valid ways to wire this into a `Task`; **pick the one that compiles cleanly
against the real `Handan.Task` and record the choice in the Decision Log**:

1. **Via `Handan.Task` builders (preferred if it typechecks):** `decisionTask`/`effectTask` require
   the program's `i`/`o` to satisfy `ToSchema`/`FromModel`/`ToPrompt` (they are written for
   `Predict` programs). A raw `Value` does not satisfy those, so the builders likely will not accept
   `noopSummaryProgram` directly.
2. **As a raw `Task` record whose `taskRun` runs the program (robust, recommended):** mirror
   `Handan.Demo.demoTask`, which constructs a `Task` directly and whose `taskRun` ignores the
   `Runtime`. Here, `taskRun` *uses* the `Runtime` to run the embedded program through handan's
   interpreter, proving the handan path end-to-end while staying key-free:

   ```haskell
   import Handan.Runtime (Runtime, runProgramWith)
   import Handan.Task (Task (..), TaskKind (KEffect), EvalHandle)
   import Handan.Contract (Envelope (..), Kind (Effect), Status (Ok, ErrorS))
   import Data.Text qualified as Text

   noopSummaryTask :: Task
   noopSummaryTask =
     Task
       { taskName    = "noop-summary"
       , taskKind    = KEffect
       , taskSummary = "Deterministic stub: returns a fixed JSON digest, no model call."
       , taskParse   = \_args -> Right Aeson.Null            -- input is the trigger payload Value
       , taskRun     = \rt input -> do
           result <- runProgramWith rt noopSummaryProgram input
           pure $ case result of
             Left err -> Envelope { program = "noop-summary", kind = Effect, status = ErrorS
                                  , verdict = Nothing, artifacts = []
                                  , trace = Nothing, message = Text.pack (show err) }
             Right v  -> Envelope { program = "noop-summary", kind = Effect, status = Ok
                                  , verdict = Just v, artifacts = []
                                  , trace = Nothing, message = "noop-summary ok" }
       , taskEval    = Nothing :: Maybe (EvalHandle Value Value)
       }
   ```

   Note `taskParse :: ArgMap -> Either Text i` and `taskRun :: Runtime -> i -> IO Envelope` mention
   the existential `i`/`o`, so consumers must **pattern-match the `Task` constructor** to bind them
   (the `Handan.Task` haddock warns of this). The `Envelope`'s `verdict :: Maybe Value` carries the
   output JSON, which is what the runner extracts.

`shikigami-core/src/Shikigami/Behavior/StubProvider.hs` — the deterministic baikai provider:

```haskell
module Shikigami.Behavior.StubProvider
  ( registerStubProvider
  , stubApiProvider
  , stubReplyText
  ) where

import Baikai.Provider.Registry (ApiProvider (..), registerApiProvider)
import Baikai.Response (Response (..), _Response)
import Baikai.Message (AssistantPayload (..))
import Baikai.Content (AssistantContent (..))   -- the text-block constructor
import Baikai.Api (Api)                          -- the tag the stub answers for
import Data.Vector qualified as V
import Data.Text (Text)

-- | The fixed reply text the stub returns; the skill arm renders it into the
--   output Value so the demo is deterministic.
stubReplyText :: Text
stubReplyText = "stub-skill: instructions acknowledged; no model was called"

-- | A provider whose 'complete' ignores the request and returns a fixed
--   assistant reply. 'apiTag' must equal the Api tag of the Model the skill arm
--   dispatches with (see Shikigami.Behavior.Skill.stubModel) — read Baikai.Api /
--   Baikai.Model for the exact tag/value and align them.
stubApiProvider :: ApiProvider
stubApiProvider =
  ApiProvider
    { apiTag   = stubApi
    , stream   = \_ _ _ -> error "stub provider: stream unused"
    , complete = \model _ctx _opts -> pure (stubResponse model)
    }

registerStubProvider :: IO ()
registerStubProvider = registerApiProvider stubApiProvider
```

The exact constructor for a text content block (`AssistantContent`) and the `Api`/`Model` tag come
from reading `Baikai.Content`, `Baikai.Api`, and `Baikai.Model` — fill `stubResponse`/`stubApi` by
copying `_Response` and overwriting `message.content` with one text block carrying `stubReplyText`.
Because `registerApiProvider` is idempotent (insert is overwrite-by-tag), calling
`registerStubProvider` twice is harmless.

`shikigami-core/src/Shikigami/Behavior/Skill.hs` — the skill arm:

```haskell
module Shikigami.Behavior.Skill
  ( SkillDir (..)
  , SkillManifest (..)
  , loadSkillManifest
  , runSkill
  ) where

import Baikai.Model (Model)
import Baikai.Context (Context (..), _Context, appendToolResult)
import Baikai.Options (Options, _Options)            -- read Baikai.Options for the base value
import Baikai.Provider.Registry (completeRequest)
import Baikai.Response (Response, flattenAssistantBlocks)
import Data.Aeson (Value)
import Data.Text (Text)

newtype SkillDir = SkillDir FilePath

-- | The parsed SKILL.md: required name + description from the YAML frontmatter,
--   plus the Markdown instruction body and any allowed-tools.
data SkillManifest = SkillManifest
  { skillName        :: !Text
  , skillDescription :: !Text
  , skillBody        :: !Text
  , skillAllowedTools :: ![Text]
  }

-- | Read <dir>/SKILL.md, split on the '---' frontmatter fences, parse the simple
--   key: value frontmatter and the Markdown body. baikai ships no SKILL.md parser,
--   so this is hand-rolled (a small, dependency-free split — no full YAML parser).
loadSkillManifest :: SkillDir -> IO (Either RunError SkillManifest)

-- | Build a baikai Context whose systemPrompt is the skill's description and whose
--   first user message is the Markdown body (+ the trigger payload rendered as
--   JSON), declare any allowed-tools, run completeRequest, then loop with
--   appendToolResult until the model stops requesting tools. Return the final
--   reply as a JSON Value.
runSkill :: Model -> SkillDir -> Value -> IO (Either RunError Value)
```

The tool loop is the spec's "after each response, dispatch the model's tool calls and fold the
results back with `appendToolResult ctx resp dispatcher`, then call `completeRequest` again until
the model stops requesting tools." With the stub provider the first reply requests no tools, so the
loop terminates after one completion; the structure is still written so a real provider would drive
it. The final `Response` is rendered into a `Value` (e.g.
`object ["reply" .= renderedAssistantText resp]` using `flattenAssistantBlocks`), which is the
skill arm's output. The skill arm dispatches with a fixed `stubModel :: Model` whose `Api` tag
matches `stubApiProvider`'s `apiTag` (so the stub handles it) — read `Baikai.Model` for how to
construct a `Model` with a chosen `Api` tag.

`shikigami-core/src/Shikigami/Behavior/Run.hs` — the dispatcher and the run environment:

```haskell
module Shikigami.Behavior.Run
  ( BehaviorEnv (..)
  , RunError (..)
  , newBehaviorEnv
  , runBehavior
  ) where

import Data.Aeson (Value)
import Handan.Runtime (Runtime, newRuntime)
import Shikigami.Api.Agent (AgentDecl (..), Behavior (..))
import Shikigami.Program.Registry (lookupTask)
import Shikigami.Behavior.Skill (SkillDir (..), runSkill)
import Shikigami.Behavior.StubProvider (registerStubProvider)

-- | What runBehavior needs to run either arm: a handan Runtime (built once) and
--   the model the skill arm dispatches with. Built once at worker startup.
data BehaviorEnv = BehaviorEnv
  { behaviorRuntime :: !Runtime
  , behaviorModel   :: !Model        -- the stub model for the skill arm in CI
  }

data RunError
  = UnknownTask !Text                 -- ShikumiProgram named a task not in the registry
  | ProgramFailed !Text               -- handan/shikumi returned an error
  | SkillLoadFailed !Text             -- SKILL.md missing or malformed
  | SkillRunFailed !Text              -- baikai completion failed
  deriving stock (Generic, Eq, Show)

-- | Build the env once: construct the handan Runtime and register the stub baikai
--   provider so the skill arm runs without a key.
newBehaviorEnv :: IO BehaviorEnv
newBehaviorEnv = do
  rt <- newRuntime
  registerStubProvider
  pure BehaviorEnv { behaviorRuntime = rt, behaviorModel = stubModel }

-- | Dispatch on the behavior union. The input Value is the trigger payload; the
--   output Value is the behavior's result (consumed by the sinks in EP-3).
runBehavior :: BehaviorEnv -> AgentDecl -> Value -> IO (Either RunError Value)
runBehavior env decl payload =
  case behavior decl of
    ShikumiProgram { task } ->
      case lookupTask task of
        Nothing -> pure (Left (UnknownTask task))
        Just t  -> runProgramTask (behaviorRuntime env) t payload   -- pattern-match Task, run, read verdict
    Skill { path } ->
      runSkill (behaviorModel env) (SkillDir path) payload
```

`runProgramTask` pattern-matches the `Task` constructor to bind the existential `i`/`o`, parses the
payload into the task's input via `taskParse` (the stub task ignores it and returns `Aeson.Null`),
runs `taskRun runtime input` to get an `Envelope`, and extracts `verdict` (the output `Value`),
mapping `status = ErrorS` to `Left (ProgramFailed message)`.

`shikigami-cli/src/Shikigami/Cli/Commands/RunBehavior.hs` (+ wire into `Shikigami.Cli`'s subparser)
— the M1 demo command. `shikigami run-behavior --agent <file> [--payload <json>]` calls
`Shikigami.Agent.Loader.loadAgent` (from EP-1), builds a `BehaviorEnv` with `newBehaviorEnv`, calls
`runBehavior`, and prints the resulting `Value` (or the `RunError`). No store is opened.

**Acceptance for M1.** From `/Users/shinzui/Keikaku/bokuno/shikigami` in the dev shell:
`cabal build all` exits 0. Running `run-behavior` against a program-agent manifest prints the fixed
`noop-summary` body; against a skill-agent manifest it prints the stub skill reply. Neither needs a
database or an API key (see Concrete Steps for the exact transcripts).

### Milestone M2 — the kioku seam (open session → recall → run → record → complete)

**Scope and result.** At the end of M2, a new function `Shikigami.Agent.Run.runAgentWithMemory`
wraps `runBehavior` with the kioku lifecycle: it opens a kioku session scoped to the agent, recalls
the agent's prior memory (empty on the first run), runs the behavior, records the behavior's output
as a kioku memory under the agent scope, and completes the session (or fails it if the behavior
errored). A CLI command `shikigami agent-run --agent <name>` runs it and prints the across-run
report. On the first run it prints `recalled 0 prior memories` and records one learning; a `psql`
query shows one `kioku_sessions` row (status `completed`) and one `kioku_memories` row under the
agent scope. This is the observable replacement of the spec's `agent_runs` table.

**Files created/changed in M2:**

`shikigami-core/src/Shikigami/Memory/Scope.hs` — **only if EP-1 did not already ship it** (check
first, per Context). The module:

```haskell
module Shikigami.Memory.Scope
  ( shikigamiNamespace
  , agentScope
  , sharedScope
  ) where

import Data.Text (Text)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))

shikigamiNamespace :: Namespace
shikigamiNamespace = Namespace "shikigami"

-- | Per-agent memory: everything THIS agent learned across its own runs.
agentScope :: Text -> MemoryScope
agentScope name = ScopeEntity shikigamiNamespace (ScopeKind "agent") name

-- | Cross-agent shared learnings any shikigami agent may consult.
sharedScope :: MemoryScope
sharedScope = ScopeGlobal shikigamiNamespace
```

`shikigami-core/src/Shikigami/Agent/Run.hs` — the run-with-memory seam. The signatures are exact;
bodies call kioku's public API in `Eff AppEffects` via `runAppIO env`:

```haskell
module Shikigami.Agent.Run
  ( AgentRunResult (..)
  , runAgentWithMemory
  ) where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kioku.App (AppEnv, runAppIO)
import Kioku.Api.Types (MemoryRecord, MemoryType (MemoryPattern), Confidence (MediumConfidence))
import Kioku.Id (SessionId, MemoryId, genSessionId, genMemoryId, idText)
import Kioku.Session qualified as Session
import Kioku.Memory  qualified as Memory
import Kioku.Recall  qualified as Recall
import Shikigami.Api.Agent (AgentDecl (..), Behavior (..))
import Shikigami.Behavior.Run (BehaviorEnv, RunError, runBehavior)
import Shikigami.Memory.Scope (agentScope)
-- (import the *Data records per the import-availability caveat in Context)

data AgentRunResult = AgentRunResult
  { runSessionId  :: !SessionId
  , recalledPrior :: ![MemoryRecord]   -- what the agent remembered from earlier runs
  , behaviorOutput :: !Value           -- the behavior's result Value
  , recordedMemId :: !(Maybe MemoryId) -- the learning recorded this run (Nothing if behavior failed)
  }

-- | Run an agent end to end with memory: open a kioku session, recall this agent's
--   prior memory, run the behavior, record the output as a memory, complete the
--   session. On a behavior error, fail the session and record no memory.
runAgentWithMemory ::
  AppEnv -> BehaviorEnv -> AgentDecl -> Value -> IO (Either Text AgentRunResult)
runAgentWithMemory appEnv behEnv decl payload = do
  let scope = agentScope (name decl)
      focus = behaviorKindText (behavior decl)   -- "ShikumiProgram" | "Skill"
  now <- getCurrentTime
  sid <- genSessionId
  -- 1. open the session (replaces the spec's agent_runs insert)
  _ <- runAppIO appEnv $ Session.start StartSessionData
         { sessionId = sid, agentId = name decl, focus = focus, scope = scope
         , subjectRef = Just (idText sid), previousSessionId = Nothing, startedAt = now }
  -- 2. recall what this agent already knows (empty on the first ever run)
  priorE <- runAppIO appEnv $ Recall.getActiveByScope scope
  let prior = either (const []) (either (const []) id) (Right priorE)  -- flatten StoreError/ReadModelError
  -- 3. run the behavior
  behaviorE <- runBehavior behEnv decl payload
  case behaviorE of
    Left runErr -> do
      done <- getCurrentTime
      _ <- runAppIO appEnv $ Session.failSession FailSessionData
             { sessionId = sid, failedAt = done, errorMessage = Text.pack (show runErr) }
      pure (Left (Text.pack (show runErr)))
    Right output -> do
      -- 4. record this run's learning as a durable memory under the agent scope
      mid <- genMemoryId
      recAt <- getCurrentTime
      _ <- runAppIO appEnv $ Memory.record RecordMemoryData
             { memoryId = mid, agentId = name decl, sessionId = Just sid, scope = scope
             , memoryType = MemoryPattern, content = renderLearning output, priority = 100
             , confidence = MediumConfidence, tags = Set.fromList ["agent-run", focus]
             , supersedes = Nothing, recordedAt = recAt }
      -- 5. complete the session
      doneAt <- getCurrentTime
      _ <- runAppIO appEnv $ Session.complete CompleteSessionData
             { sessionId = sid, completedAt = doneAt, modelUsed = Nothing
             , summary = Just "agent-run completed" }
      pure (Right AgentRunResult { runSessionId = sid, recalledPrior = pickPrior prior
                                 , behaviorOutput = output, recordedMemId = Just mid })
```

`renderLearning :: Value -> Text` turns the behavior's output JSON into the memory `content` (e.g.
the `summary`/`reply` field, falling back to the compact JSON encoding). `behaviorKindText` maps
`ShikumiProgram{}` → `"ShikumiProgram"` and `Skill{}` → `"Skill"`. The double-`either` flattening
exists because `runAppIO` wraps the result in `Either StoreError`, and `getActiveByScope` itself
returns `Either ReadModelError [MemoryRecord]` — implement a small helper that collapses both error
layers to `[]` on failure (a recall failure must not abort the run). **Verify the exact nesting
when you compile and simplify the helper accordingly; the shape above is illustrative of the two
layers, not final.**

`shikigami-cli/src/Shikigami/Cli/Commands/AgentRun.hs` (+ wire into the subparser) — the demo. It
takes `--agent <name>` (resolved to a manifest path `agents/<name>.dhall`, or `--file <path>`),
opens the kioku store with `withStore (defaultConnectionSettings connStr)`, builds the `AppEnv`
(`AppEnv { store = st, tracer = tr, metrics = Nothing }` with `tr <- noopTracer`), builds a
`BehaviorEnv` with `newBehaviorEnv`, calls `runAgentWithMemory`, and prints:

```haskell
Right r -> do
  putStrLn ("agent " <> show (name decl) <> " run " <> Text.unpack (idText (runSessionId r)))
  putStrLn ("recalled " <> show (length (recalledPrior r)) <> " prior memories:")
  mapM_ (putStrLn . ("  - " <>) . renderRecord) (recalledPrior r)
  maybe (pure ()) (\m -> putStrLn ("recorded learning " <> Text.unpack (idText m))) (recordedMemId r)
```

The connection string comes from the dev-shell env var the kioku store uses (`PG_CONNECTION_STRING`
in the kioku prior-art; confirm the exact name EP-1's scaffold exports and reuse it — do not invent
a new one).

**Acceptance for M2.** `cabal build all` exits 0. After `just create-database` (lands kioku's
tables), `shikigami agent-run --agent heartbeat` prints `recalled 0 prior memories` and `recorded
learning kioku_memory_…`. A `psql` query of `kiroku.kioku_sessions` shows one row with
`scope_kind='agent', scope_ref='heartbeat', status='completed'` and `kiroku.kioku_memories` shows
one row in that scope (see Concrete Steps).

### Milestone M3 — memory persists across runs (+ optional activity mapping)

**Scope and result.** At the end of M3, running `shikigami agent-run --agent <name>` a *second*
time recalls the learning recorded by the first run (the headline acceptance): it prints `recalled
1 prior memories:` followed by run 1's learning text. Two `kioku_sessions` rows and ≥1
`kioku_memories` row exist under the agent scope. Optionally, an `--from-activity <file>` mode reads
an `activity.v1` Activity Envelope (EP-1's `ActivityEnvelope` type from `shikigami-api`) and records
its `payload` as a kioku memory under the agent scope, with the envelope's `verb`/`subject.type` as
tags — demonstrating the `activity.v1`→kioku mapping.

**Files created/changed in M3:**

No new runtime module is strictly required for the headline proof — it falls out of M2's
`getActiveByScope` recall once two runs have happened. M3's work is (a) the *proof* (run twice;
assert the recall count goes 0 → 1) and (b) the optional activity mapping:

`shikigami-cli/src/Shikigami/Cli/Commands/AgentRun.hs` — extend with `--from-activity <file>`. When
present, decode the file into `Shikigami.Api.Activity.ActivityEnvelope` (EP-1's type; if EP-1
named/located it differently, import from wherever EP-1 placed the nine-field envelope), derive the
agent name from the envelope `actor.id` (or `--agent`), and record the envelope as a memory:

```haskell
-- map the envelope into a RecordMemoryData under the agent scope:
--   content    = compact JSON of the envelope payload
--   memoryType = MemoryPattern
--   tags       = Set.fromList ["verb:" <> envVerb, "subject:" <> envSubjectType]
--   recordedAt = envelope occurredAt
```

This reuses M2's `Memory.record` call shape with tags/content derived from the envelope. The
rationale (stated for the reader): an `activity.v1` envelope an agent *produces* (`actor.kind:
"agent"`, e.g. `verb:"digest.produced"`) is exactly a learning L0 should capture, so it becomes a
`Kioku.Memory` under the producing agent's scope; the envelope's `verb`/`subject.type` become
searchable tags and the `payload` becomes the memory content.

**Acceptance for M3.** Running `shikigami agent-run --agent heartbeat` twice: the first run prints
`recalled 0 prior memories`, the second prints `recalled 1 prior memories:` followed by run 1's
learning text. `kiroku.kioku_sessions` has two rows under the agent scope; `kiroku.kioku_memories`
has the learning(s). The optional `--from-activity` records a memory whose tags carry the
envelope's `verb`/`subject.type` (see Concrete Steps).


## Concrete Steps

Run all commands from inside `/Users/shinzui/Keikaku/bokuno/shikigami` in the nix dev shell (enter
with `direnv allow` or `nix develop`; the shell exports the PG env vars and the store connection
string). EP-1 must be Complete and `cabal build all` must already succeed before you start.

### Step 0 — Confirm EP-1's deliverables and the kioku import surface

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
ls shikigami-core/src/Shikigami/Memory/Scope.hs 2>/dev/null && echo "Scope EXISTS (consume it)" || echo "Scope MISSING (create it in M2)"
# Confirm the wire types and loader EP-1 ships:
grep -RnE 'data (AgentDecl|Behavior)' shikigami-api/src
grep -Rn 'loadAgent' shikigami-core/src shikigami-cli/src
```

Verify which kioku modules re-export the command records (drives the imports in `Shikigami.Agent.Run`):

```bash
# Do the top-level modules re-export the *Data constructors?
sed -n '1,40p' /Users/shinzui/Keikaku/bokuno/kioku/kioku-core/src/Kioku/Session.hs | grep -nE 'StartSessionData|CompleteSessionData|FailSessionData'
sed -n '1,40p' /Users/shinzui/Keikaku/bokuno/kioku/kioku-core/src/Kioku/Memory.hs  | grep -nE 'RecordMemoryData'
```

If those greps print nothing, the records are exported only from `Kioku.Session.Domain` /
`Kioku.Memory.Domain`; import them from there (the *data* modules, allowed per the Context caveat).
Record the outcome in Surprises & Discoveries.

### Step 1 — M1: behavior runner + stubs

Create `shikigami-core/src/Shikigami/Program/Registry.hs`,
`shikigami-core/src/Shikigami/Behavior/StubProvider.hs`,
`shikigami-core/src/Shikigami/Behavior/Skill.hs`, and
`shikigami-core/src/Shikigami/Behavior/Run.hs` per the Plan of Work, adding each to
`shikigami-core.cabal` `exposed-modules`. Create the CLI command
`shikigami-cli/src/Shikigami/Cli/Commands/RunBehavior.hs` and wire it into the subparser in
`Shikigami.Cli`. Create two tiny manifests to run against (use EP-1's `schema/Agent.dhall`):

```bash
mkdir -p agents agents/skills/triage-note
# a program-agent (behavior = ShikumiProgram { task = "noop-summary" }):
#   author agents/heartbeat.dhall per the spec's sample manifest.
# a skill-agent (behavior = Skill { path = "agents/skills/triage-note" }):
#   author agents/triage-note.dhall + agents/skills/triage-note/SKILL.md
cat > agents/skills/triage-note/SKILL.md <<'MD'
---
name: triage-note
description: Acknowledge a triage instruction; used to prove the skill arm end to end.
---

Read the incoming item and acknowledge it. (This body is the instruction the skill arm
turns into a baikai Context; with the stub provider the reply is fixed.)
MD
```

Build and run both arms:

```bash
cabal build all
cabal run shikigami -- run-behavior --agent agents/heartbeat.dhall
cabal run shikigami -- run-behavior --agent agents/triage-note.dhall
```

Expected transcript for the program-agent (the fixed `noop-summary` body):

```text
{"summary":"noop-summary produced a fixed digest","verb":"heartbeat.tick"}
```

Expected transcript for the skill-agent (the stub reply, rendered):

```text
{"reply":"stub-skill: instructions acknowledged; no model was called"}
```

Neither command opens a database or reads an API key. This closes M1.

### Step 2 — M2: the kioku seam + `agent-run`

Create `shikigami-core/src/Shikigami/Memory/Scope.hs` (only if Step 0 reported it missing) and
`shikigami-core/src/Shikigami/Agent/Run.hs`; add both to `shikigami-core.cabal` `exposed-modules`.
Create `shikigami-cli/src/Shikigami/Cli/Commands/AgentRun.hs` and wire it into the subparser. Build,
land the schema, and run the first agent:

```bash
cabal build all
just create-database                       # lands kioku's tables in the kiroku schema
cabal run shikigami -- agent-run --agent heartbeat
```

Expected transcript on the **first** run:

```text
agent "heartbeat" run kioku_session_01j...
recalled 0 prior memories:
recorded learning kioku_memory_01j...
```

Verify the session and memory rows (use the PG vars the dev shell exports):

```bash
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "SELECT session_id, agent_id, focus, scope_kind, scope_ref, status FROM kiroku.kioku_sessions;"
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "SELECT memory_id, scope_kind, scope_ref, content FROM kiroku.kioku_memories;"
```

Expected: one session row (`scope_kind='agent'`, `scope_ref='heartbeat'`, `status='completed'`) and
one memory row in the same scope. This closes M2.

### Step 3 — M3: persistence across runs (+ optional activity mapping)

Run the **same** agent a second time:

```bash
cabal run shikigami -- agent-run --agent heartbeat
```

Expected transcript on the **second** run (the headline proof — run 2 remembers run 1):

```text
agent "heartbeat" run kioku_session_01j...
recalled 1 prior memories:
  - kioku_memory_01j... [pattern/medium] noop-summary produced a fixed digest
recorded learning kioku_memory_01j...
```

Optional activity mapping: write a fixture envelope and feed it in:

```bash
mkdir -p fixtures
cat > fixtures/digest.json <<'JSON'
{
  "activity_id": "0192f000-0000-7000-8000-000000000001",
  "occurred_at": "2026-06-24T07:00:00Z",
  "source": "shinzui/shikigami",
  "actor": { "kind": "agent", "id": "heartbeat" },
  "subject": { "type": "intention", "id": "intention_01jrei" },
  "verb": "digest.produced",
  "payload": { "summary": "intention has had no action for 7 days" },
  "context_refs": [],
  "idempotency_key": "heartbeat:0192f000"
}
JSON
cabal run shikigami -- agent-run --agent heartbeat --from-activity fixtures/digest.json
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "SELECT memory_id, content, tags::text FROM kiroku.kioku_memories WHERE scope_ref='heartbeat' ORDER BY created_at DESC LIMIT 1;"
```

Expected: a new memory row whose `content` is the rendered payload and whose `tags` include
`verb:digest.produced` and `subject:intention`. This closes M3.

### Step 4 — Tests (recommended)

Add a `tasty` test in `shikigami-core/test` (or `shikigami-cli/test`) with two cases:

1. **Behavior runner, no DB (M1):** build a `BehaviorEnv` with `newBehaviorEnv`, call `runBehavior`
   on a hand-built `AgentDecl` for each arm, and assert the output `Value` equals the fixed
   `noop-summary` body / the stub skill reply. This needs no database and no key.
2. **kioku seam, ephemeral DB (M2/M3):** use EP-1's
   `Shikigami.Migrations.TestSupport.withShikigamiMigratedDatabase` to spin up an ephemeral migrated
   Postgres, build an `AppEnv` against it, call `runAgentWithMemory` twice for the same agent, and
   assert the second call's `recalledPrior` has length 1 with content equal to the first run's
   learning. This is the across-run proof as an automated test.

```bash
cabal test shikigami-core
```


## Validation and Acceptance

The plan is accepted when all three milestone acceptances hold on a fresh checkout, each phrased as
something a human runs and sees:

1. **Behavior runner, both arms, no DB/no key (M1).** `cabal build all` exits 0;
   `shikigami run-behavior --agent agents/heartbeat.dhall` prints the fixed `noop-summary` JSON body
   (proving the handan/shikumi `Embed` path runs key-free); `shikigami run-behavior --agent
   agents/triage-note.dhall` prints the stub skill reply JSON (proving the baikai skill arm runs
   against the stub provider, key-free). The program arm is the typed path; the skill arm is the
   instruction path; both are observable as printed JSON.
2. **One run records a session + memory (M2).** `shikigami agent-run --agent heartbeat` prints the
   run id, `recalled 0 prior memories`, and `recorded learning …`; `psql` shows one
   `kioku_sessions` row scoped to `shikigami/agent/heartbeat` with `status='completed'` and one
   `kioku_memories` row in the same scope. This is the observable replacement of the spec's
   `agent_runs` table by kioku's Session.
3. **Memory persists across runs (M3, headline).** Running `agent-run --agent heartbeat` a second
   time prints `recalled 1 prior memories:` followed by run 1's learning text; two `kioku_sessions`
   rows and ≥1 `kioku_memories` row exist under the agent scope. This is the user-visible behavior
   promised in Purpose: an agent remembers across runs.
4. **Activity → memory mapping (M3, optional).** `agent-run --agent heartbeat --from-activity
   fixtures/digest.json` records a memory whose tags carry the envelope's `verb`/`subject.type`,
   demonstrating the documented `activity.v1`→kioku mapping aligned with EP-1's `ActivityEnvelope`.

Acceptance is *behavioral*, not "code added": each check is a command whose output a novice can
compare against the transcripts above. The change is effective beyond compilation because the second
run's recall demonstrably depends on the first run's memory write landing in the event store and its
inline projection, and because the printed behavior outputs prove both arms actually executed (the
`Embed` body ran; the stub provider answered the completion).

**Scope boundary (what this plan does NOT prove, by design).** This plan does not run a real model
(both arms use deterministic stubs), does not dispatch any sink (EP-3 owns `Shikigami.Sink.dispatch`
which consumes `runBehavior`'s output `Value`), does not evaluate any trigger (EP-4 owns the schedule
and `activity.v1` stream evaluators), and does not run the supervised worker loop (EP-5 owns the
`shibuya` `QueueProcessor` that calls `runBehavior` with retries). Those plans integrate the seams
this plan delivers; the demo CLIs here prove the runner and kioku seam in isolation.


## Idempotence and Recovery

- **Source edits (Steps 1–3).** Creating modules and re-running `cabal build all` is safe to repeat;
  a build that fails with "hidden module in package shikigami-core" means a new module is in
  `other-modules` instead of `exposed-modules` — fix the `.cabal` file and rebuild. Do **not** delete
  inplace `.conf` registrations to "fix" a solve conflict — that forces a long clean rebuild and is a
  known kikan-stack gotcha; a dependency conflict almost always means `cabal.project`'s pin block
  diverged from kioku's (EP-1 owns it; make it byte-identical to kioku's).
- **The stub baikai provider.** `registerStubProvider` is idempotent: the registry insert is
  overwrite-by-API-tag, so calling it once per `newBehaviorEnv` (or repeatedly) keeps exactly one
  stub handler. Running `run-behavior` many times is harmless.
- **`run-behavior` (M1).** Pure with respect to the database (it opens no store), so it is fully
  repeatable; it prints the same fixed output every time.
- **Migrations.** All kioku/kikan DDL is `CREATE … IF NOT EXISTS`; `codd` records applied migrations
  by timestamped filename and skips already-applied ones, so `just create-database` is safe to
  re-run. **Every database the demo opens must have kioku's migrations applied first** — if a query
  errors with `relation "kioku_sessions" does not exist`, re-run `just create-database`.
- **`agent-run` (M2/M3).** Each run records a *new* memory (fresh id) — harmless, and exactly what
  the across-run proof relies on. To reset to a clean "first run", truncate and re-run:
  ```bash
  psql -h "$PGHOST" -d "$PGDATABASE" -c \
    "TRUNCATE kiroku.kioku_memories, kiroku.kioku_sessions, kiroku.kioku_turns;"
  ```
  (kioku is event-sourced; for a complete reset also drop the corresponding `kioku_memory-*` /
  `kioku_session-*` event streams, or recreate the database with `just create-database`.) After a
  truncate, the next `agent-run` again prints `recalled 0 prior memories`.
- **`--from-activity` (M3).** Re-feeding the same envelope records a duplicate memory (EP-1's scoped
  recall does not dedup on `idempotency_key`); acceptable for the demo. Real dedup is a worker/sink
  concern (EP-4/EP-5), not this plan.
- **A behavior error mid-run.** `runAgentWithMemory` fails the session (`Kioku.Session.failSession`)
  and records no memory, leaving an auditable `status='failed'` row rather than a dangling
  `status='running'` one. A crash *before* `complete`/`failSession` leaves a `status='running'` row —
  the recovery signal; re-running the agent opens a fresh session (a new id), and the stale row stays
  as audit (the worker, EP-5, owns reconciling stale `running` rows).


## Interfaces and Dependencies

This section names the exact types/functions that must exist at the end of each milestone and the
binding integration contracts (IP-1, IP-3, IP-4, IP-9 from
`docs/masterplans/1-shikigami-declared-agent-runtime-bootstrap.md`).

### Libraries depended on (and why)

- **`shikigami-api`** (EP-1, IP-1) — `Shikigami.Api.Agent` (`AgentDecl`, `Behavior =
  ShikumiProgram { task } | Skill { path }`) and `Shikigami.Api.Activity` (the nine-field
  `ActivityEnvelope`, IP-6). Imported, never redefined.
- **`shikigami-core`** (EP-1) — `Shikigami.Agent.Loader.loadAgent` (load a manifest for the demo),
  the `Shikigami.Prelude`, and possibly `Shikigami.Memory.Scope` (IP-3).
- **`handan`** (`handan-core`) — `Handan.Runtime` (`Runtime`, `newRuntime`, `runProgramWith`),
  `Handan.Task` (`Task (..)`, `TaskKind`, `EvalHandle`), `Handan.Contract` (`Envelope (..)`,
  `Kind`, `Status`). The typed-program arm.
- **`shikumi`** — `Shikumi.Program` (`Program`, `embed`); the `noop-summary` program node.
- **`baikai`** — `Baikai.Provider.Registry` (`completeRequest`, `ApiProvider (..)`,
  `registerApiProvider`, `newProviderRegistry`, `registerApiProviderWith`, `completeRequestWith`),
  `Baikai.Context` (`Context (..)`, `_Context`, `appendToolResult`, `appendToolResultText`),
  `Baikai.Tool` (`Tool (..)`, `ToolChoice`), `Baikai.Response` (`Response (..)`, `_Response`,
  `flattenAssistantBlocks`), `Baikai.Model` (`Model`), `Baikai.Options` (`Options`, base value),
  `Baikai.Content`/`Baikai.Message`/`Baikai.Api` (to build the stub reply and choose the stub Api
  tag). The skill arm.
- **`kioku`** — `kioku-api` (`Kioku.Api.Scope`, `Kioku.Api.Types`, `Kioku.Id`) and `kioku-core`
  (`Kioku.App`, `Kioku.Session`, `Kioku.Memory`, `Kioku.Recall`). The memory seam. **Import only
  these top-level modules + `kioku-api` types — never `Kioku.*.Domain.*` internals, except the
  `*Data` command records from `Kioku.Session.Domain`/`Kioku.Memory.Domain` if and only if the
  top-level modules do not re-export them** (IP-3; see the Context caveat).
- **`kiroku-store`** — `Kiroku.Store.Connection` (`KirokuStore`, `withStore`,
  `defaultConnectionSettings`) to open the store in the CLI.
- **`aeson`, `text`, `time`, `containers`, `vector`** — values, rendering, scopes/tags, the baikai
  context vectors. (All already in the EP-1 pin-set; if any is missing from a `.cabal` `build-depends`
  add it there.)

### Module/function signatures by milestone

**End of M1.**

- `Shikigami.Program.Registry`: `programRegistry :: [Task]` (includes `noopSummaryTask`),
  `lookupTask :: Text -> Maybe Task`, `noopSummaryTask :: Task` (its program is a `shikumi` `Embed`
  node returning a fixed `Value`; no model call).
- `Shikigami.Behavior.StubProvider`: `registerStubProvider :: IO ()`, `stubApiProvider ::
  ApiProvider`, `stubReplyText :: Text`.
- `Shikigami.Behavior.Skill`: `data SkillDir = SkillDir FilePath`, `data SkillManifest`,
  `loadSkillManifest :: SkillDir -> IO (Either RunError SkillManifest)`,
  `runSkill :: Model -> SkillDir -> Value -> IO (Either RunError Value)` (this is the spec's
  `Shikigami.Behavior.Skill.runSkill`).
- `Shikigami.Behavior.Run` (IP-4): `data BehaviorEnv = BehaviorEnv { behaviorRuntime :: Runtime,
  behaviorModel :: Model }`, `data RunError = UnknownTask Text | ProgramFailed Text |
  SkillLoadFailed Text | SkillRunFailed Text`, `newBehaviorEnv :: IO BehaviorEnv`,
  `runBehavior :: BehaviorEnv -> AgentDecl -> Value -> IO (Either RunError Value)`.
- `Shikigami.Cli.Commands.RunBehavior`: a `run-behavior --agent <file> [--payload <json>]`
  subcommand printing the output `Value` or the `RunError`.

**End of M2.**

- `Shikigami.Memory.Scope` (IP-3; consumed from EP-1 if present, else added here):
  `shikigamiNamespace :: Namespace`, `agentScope :: Text -> MemoryScope` (=
  `ScopeEntity (Namespace "shikigami") (ScopeKind "agent") <name>`), `sharedScope :: MemoryScope`
  (= `ScopeGlobal (Namespace "shikigami")`).
- `Shikigami.Agent.Run`: `data AgentRunResult { runSessionId :: SessionId, recalledPrior ::
  [MemoryRecord], behaviorOutput :: Value, recordedMemId :: Maybe MemoryId }`,
  `runAgentWithMemory :: AppEnv -> BehaviorEnv -> AgentDecl -> Value -> IO (Either Text AgentRunResult)`
  — opens a session (`Kioku.Session.start`), recalls (`Kioku.Recall.getActiveByScope`), runs the
  behavior (`runBehavior`), records a memory (`Kioku.Memory.record`), completes
  (`Kioku.Session.complete`) or fails (`Kioku.Session.failSession`).
- `Shikigami.Cli.Commands.AgentRun`: an `agent-run --agent <name> [--file <path>]` subcommand that
  opens the kioku store, builds the `AppEnv` + `BehaviorEnv`, calls `runAgentWithMemory`, and prints
  the across-run report.

**End of M3.**

- `Shikigami.Cli.Commands.AgentRun` extended with `--from-activity <file>` that decodes EP-1's
  `ActivityEnvelope` and records its payload as a kioku memory under the agent scope (tags from the
  envelope `verb`/`subject.type`). No new runtime module required for the headline across-run proof.

### IP-1 — `shikigami-api` wire types (consumed)

This plan imports `AgentDecl`, `Behavior`, and (for M3) `ActivityEnvelope` from `shikigami-api`
unchanged. It needs no new fields. If, while wiring, a field the runner needs is absent, that is an
amendment to EP-1's deliverable — record it here and in EP-1, do not redefine the type locally.

### IP-3 — kioku session/memory integration (consumed)

`Shikigami.Agent.Run` uses `Kioku.Session.start`/`complete`/`failSession`, `Kioku.Memory.record`,
and `Kioku.Recall.getActiveByScope` through `Kioku.App.runAppIO env`, with scopes from
`Shikigami.Memory.Scope`. It records each run as a kioku session and each learning as a kioku memory
— there is no `agent_runs` table and no `Shikigami.Session` module. The migration composition and
the `Shikigami.Memory.Scope` helper are EP-1's; this plan consumes them (and supplies `Scope` if
EP-1 did not).

### IP-4 — the behavior-runner contract (owned by this plan)

`Shikigami.Behavior.Run.runBehavior :: BehaviorEnv -> AgentDecl -> Value -> IO (Either RunError
Value)` is owned and defined here. The worker (EP-5) calls it; the sink dispatcher (EP-3) consumes
its output `Value`; EP-3 and EP-4 build against a fixed sample output `Value` until this lands. The
program registry seam (`Shikigami.Program.Registry`, including `noop-summary`) and the skill runner
(`Shikigami.Behavior.Skill.runSkill`) are also owned here.

### IP-9 — coding conventions

See Coding Conventions below.


## Coding Conventions (haskell-jitsurei)

All Haskell in this plan follows the binding conventions in
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/` (browse with
`mori registry docs haskell-jitsurei`), as mandated by MasterPlan #1 Integration Point IP-9 — the
same standards kioku and kizashi adopt:

- GHC 9.12.4 with the `GHC2024` language edition; a `common` cabal stanza enabling
  `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings` (and
  `MultilineStrings` for any embedded SQL), with every library/exe/test stanza doing
  `import: common`.
- Postpositive `qualified` imports (`import Data.Text qualified as Text`, never
  `import qualified Data.Text`).
- The project prelude `Shikigami.Prelude` (re-exporting the common surface + `Control.Lens`) must
  **not** re-export `Data.Generics.Labels` — its orphan `IsLabel` instance collides with the keiki
  DSL's `#label` overloading the kikan stack relies on. Modules that need generic-lens `#label`
  import `"generic-lens" Data.Generics.Labels ()` per-module. (Note: `Baikai.Context` already pulls
  in `Data.Generics.Labels ()` internally with `#message`/`#content`/`#messages` lens access — that
  is baikai's own module, unaffected by shikigami's prelude choice.)
- Record patterns: no field prefixes, strict `!` fields, entity-ID-first on event/command records,
  explicit `deriving stock`/`anyclass`/`newtype` strategies, and lens operators over record-update
  syntax where lenses are in scope.
- `eventAesonOptions` (from the prelude) for any event JSON. `cli/agents/claude-cli-pitfalls.md`
  applies only if a future behavior arm spawns the `claude` CLI — not in this plan (the stubs make
  no model call).


## Revision Note

2026-06-24 — Initial authoring. Filled all sections of the EP-2 skeleton against the binding
contracts: the shikigami design spec (`docs/initial-spec.md` — "behavior runner", "shikumi-program
arm", "skill arm", "session store" now replaced by kioku, "API Surface"); MasterPlan #1
(`docs/masterplans/1-shikigami-declared-agent-runtime-bootstrap.md` — IP-1/IP-3/IP-4/IP-9, owning
IP-4, consuming IP-1/IP-3); the kioku prior-art plan
(`/Users/shinzui/Keikaku/bokuno/kioku/docs/plans/6-shikigami-memory-integration-with-kioku.md` —
the open → recall → record → complete shape, reused faithfully); and the REAL sources of kioku
(`Kioku/Session.hs`, `Kioku/Memory.hs`, `Kioku/Recall.hs`, `Kioku/App.hs`, `Kioku/Session/Domain.hs`,
`Kioku/Memory/Domain.hs`, `Kioku/Api/{Scope,Types}.hs`, `Kioku/Id.hs`), handan
(`Handan/Runtime.hs`, `Handan/Task.hs`, `Handan/Registry.hs`, `Handan/Demo.hs`), shikumi
(`Shikumi/Program.hs` — the `Embed` constructor and `embed`), and baikai
(`Baikai.hs`, `Baikai/Context.hs`, `Baikai/Provider/Registry.hs`, `Baikai/Tool.hs`,
`Baikai/Response.hs`). The most important correction over the prior-art sketch: kioku's
session/memory API runs in `Eff AppEffects` (wrapped by `runAppIO env`) and returns
`Either …Error …`, and `complete` takes a single `CompleteSessionData` record — the demo here uses
the verified signatures, not the prior-art's IO/3-arg sketch. Scoped EP-2 to the runner + kioku seam
proved in isolation by its own demo CLI (`run-behavior`, `agent-run`); the worker (EP-5), sinks
(EP-3), and triggers (EP-4) integrate these seams afterward and are explicitly out of scope here.
