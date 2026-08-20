---
id: 33
slug: agent-schema-evolution-identity-memory-policy-and-enablement
title: "Agent schema evolution: identity, memory policy, and enablement"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tyzqcerzv4ysbktgr9sw9"
master_plan: "docs/masterplans/7-platform-feature-completion-egress-schema-memory-lifecycle-delegation.md"
---

# Agent schema evolution: identity, memory policy, and enablement

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The README (README.md:11-17) describes an agent as five declared parts — behavior, trigger,
sinks, **identity** ("under whose authority it acts"), and **memory** ("what it carries
forward across runs") — but the schema (schema/Agent.dhall:59-68) declares only the first
three plus name/description. There is also no way to turn an agent off short of deleting its
manifest. After this plan, an agent author can write:

```dhall
, identity = Some { principal = "principal_shikigami_heartbeat" }
, memory = { scope = A.MemoryScope.AgentScope, recallLimit = 25, recordPolicy = A.RecordPolicy.OnSuccess }
, enabled = True
```

and every one of those declarations is parsed, validated, printed by `validate`, and — for
`enabled`, `recallLimit`, and `recordPolicy` — enforced by the runtime. Crucially, all three
fields carry defaults that encode today's exact behavior, so **every existing manifest stays
valid with zero edits** (proven, not assumed: the validation section runs `validate` over the
whole `agents/` tree). A disabled agent is skipped by every loader path with a loud stderr
line, so an operator can park an agent without losing the manifest. This plan is also the
pattern-setter for this MasterPlan: it establishes the "additive Dhall field with a default,
mirrored in `Shikigami.Api.Agent`, proven by validate" discipline that plans 32, 35, and 12
follow (see the MasterPlan's IP-1,
docs/masterplans/7-platform-feature-completion-egress-schema-memory-lifecycle-delegation.md).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-20T03:25:00Z) M1: added `Identity`, `MemoryScope`, `RecordPolicy`, `MemoryPolicy` types and the `identity`/`memory`/`enabled` fields (with defaults) to schema/Agent.dhall; exported the new names.
- [x] (2026-08-20T02:58:12Z) Prerequisites: plans 36 and 47 are complete; record mirrors follow the current `mori://shinzui/haskell-jitsurei/docs/core-record-patterns` strict direct-field and Generic Lens conventions.
- [x] (2026-08-20T03:25:00Z) Prerequisite gap: implemented plan 20's narrowly required `AgentLoadReport`/`loadAgentsReport` and loud-loader slice before enabled-agent selection; the rest of plan 20 remains out of scope.
- [x] (2026-08-20T02:58:12Z) Baseline: `nix develop --command cabal build all` succeeds on the clean pre-plan tree.
- [x] (2026-08-20T03:25:00Z) M1: proved source compatibility — every live manifest under `agents/` validates unchanged; `agents/broken.dhall` and the retired detector-schema tombstone remain expected failures.
- [x] (2026-08-20T03:25:00Z) M2: mirrored `IdentityDecl`, `MemoryScopeDecl`, `RecordPolicy`, `MemoryPolicy`, bounded `RecallLimit`, and the three new `AgentDecl` fields in `Shikigami.Agent.Decl`; exported the new API.
- [x] (2026-08-20T03:25:00Z) M2: added `agents/proof/declared-identity.dhall` plus loader tests for explicit values, defaults, old JSON bytes, non-default JSON, and invalid recall bounds.
- [x] (2026-08-20T03:25:00Z) M3: consumed the new load report in every worker role, added loud enabled-agent selection, and kept single-file validation/runs available for parked agents.
- [x] (2026-08-20T03:25:00Z) M3: validated `recallLimit` into `RecallLimit` (1–1000) before conversion, capped vector and fallback recall, and enforced all three record-policy branches in direct and durable runs; `cabal test shikigami-core` passes all 309 tests.
- [x] (2026-08-20T03:25:00Z) M4: updated docs/user/writing-agents.md and docs/user/memory.md with defaults, enforcement boundaries, and lifecycle semantics.
- [ ] M4: full-suite regression `cabal test all`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- (Authoring-time) `loadAgents` is not in the core loader at all: it is copy-pasted three
  times in the CLI (shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs:45-49,
  Scheduler.hs:77-80, ConsumeStream.hs:90-93) and each copy **silently drops** any manifest
  that fails to load (`pure [a | Right a <- loaded]`). A typo in one agent file makes that
  agent vanish from the worker with no diagnostic. The "skip disabled agents LOUDLY"
  requirement originally included consolidation. The 2026-07-22 portfolio audit assigned
  that consolidation and failure reporting to plan 20; this plan now extends its report with
  enabled-agent selection.
- 2026-08-20: Plan 36 did centralize the old copies as
  `Shikigami.Agent.Loader.loadAgentsIn`, but plan 20's report API and loud failure behavior
  are still absent. Evidence: `Shikigami.Agent.Loader` exports only `loadAgent` and
  `loadAgentsIn`, and all four worker-role load paths still call `loadAgentsIn`. This plan
  must supply the report slice it consumes while leaving plan 20's unrelated routing,
  scheduling, kioku-error, and enqueue hardening milestones untouched.
- 2026-08-20: The repository instruction's old
  `/haskell-jitsurei/core/record-patterns.md` path has moved. Mori resolves the current
  guide as `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`, stored at
  `patterns/core/record-patterns.md`; its direct, strict, unprefixed-field convention is
  unchanged.
- 2026-08-20: `AgentDecl` is itself a durable workflow value: the `lookup-agent` step
  journals its JSON. Generic derivation after adding three fields would preserve Dhall
  source compatibility but not old journal bytes or missing-key decoding. The mirror now
  omits compatibility-default fields and restores them when absent; ADR 0011 records the
  rule.
- 2026-08-20: GHC rejects a strict field annotation on a `newtype` constructor. The plan's
  allowed one-field `data` fallback for `IdentityDecl` therefore also satisfies the
  repository's strict-field convention and decodes the Dhall record successfully.
- 2026-08-20: The plan's manifest-validation loop also selects
  `agents/detectors/schema.dhall`, an intentionally retired text-valued tombstone that
  explicitly must not load as an agent. Compatibility validation excludes that file as
  well as the intentional `agents/broken.dhall` negative fixture.


## Decision Log

Record every decision made while working on the plan.

- Decision: The three fields and their defaults are
  `identity : Optional { principal : Text }` (default `None`),
  `memory : { scope : < AgentScope | Shared >, recallLimit : Natural, recordPolicy : < Always | OnSuccess | Never > }`
  (default `{ scope = AgentScope, recallLimit = 10, recordPolicy = OnSuccess }`), and
  `enabled : Bool` (default `True`).
  Rationale: each default is today's verified behavior, so an undeclared field changes
  nothing. Recall is hard-coded to `maxResults = 10` today
  (shikigami-core/src/Shikigami/Agent/Run.hs:207); memories are recorded only on the
  behavior-success arm (Run.hs:93-112; Workflow.hs recordLearning at 585-605 runs only under
  `Right output` at Workflow.hs:187-196), which is exactly `OnSuccess`; all memory today is
  agent-scoped (`agentScope`, Shikigami/Memory/Scope.hs:17-19); and every agent on disk is
  effectively enabled. `identity` is `Optional` because no current agent has a principal and
  there is no verification to fail against yet.
  Date: 2026-07-08
- Decision: Dhall keeps `recallLimit : Natural`, but loading validates it into the
  bounded domain type `RecallLimit` with inclusive range 1–1000 before runtime use.
  Rationale: `Natural` is unbounded; unchecked conversion can overflow `Int` or authorize
  excessive SQL rows/allocation. A named domain type makes the bound unavoidable.
  Date: 2026-07-22

- Decision: This plan *defines* all three fields but *enforces* only `enabled`,
  `recallLimit`, and `recordPolicy`. `memory.scope = Shared` semantics are implemented by
  docs/plans/34-memory-lifecycle-distillation-retention-and-shared-scope.md (MasterPlan IP-4),
  and the `identity.principal` join to meibo principals is consumed by
  docs/plans/23-agent-lifecycle-control-with-meibo-principals.md (MasterPlan 4, IP-5) — the
  field shape `identity.principal : Text` is the coordinated contract with that plan.
  Rationale: scope semantics need the shared-recall design and real-Postgres verification
  that plan 34 owns; principal verification needs meibo, which this repo does not talk to
  yet. Parsing-but-not-yet-enforcing is made honest by `validate` printing the fields and by
  documenting the enforcement owner per field in docs/user/writing-agents.md.
  Date: 2026-07-08

- Decision: `recordPolicy` semantics — `OnSuccess` (default): record the behavior output as a
  memory only when the behavior succeeds (today's behavior). `Never`: skip the record step
  entirely (the session still completes; `recordedMemId = Nothing`). `Always`: additionally
  record a failure memory on the behavior-failure arm, with content
  `"run failed: " <> err` and tag `"failure"`, before the session is failed.
  Rationale: the three alternatives must differ observably or the union is decoration.
  `Never` supports pure act-only agents whose outputs would pollute recall; `Always` gives
  agents a memory of their failures, which is the cheapest useful interpretation and adds no
  new machinery (same `Memory.record` call, different arm).
  Date: 2026-07-08

- Decision: Hard-depend on plan 20's `Shikigami.Agent.Loader.loadAgentsReport` and add
  `enabledAgentsFromReport`, which logs one loud line per disabled agent and returns enabled,
  successfully loaded declarations. Plan 20 retains ownership of directory traversal,
  load-failure logging, and strict mode.
  Rationale: enforcing `enabled` in three copy-pasted places would triple the bug surface,
  while reimplementing plan 20's loader would create the same duplication under a new name.
  Single-file commands
  (`validate`, `run-behavior`, `render-lifecycle`, `agent-run`) intentionally still load
  disabled agents: you must be able to validate and hand-run an agent you have parked;
  `validate` prints `note: agent is disabled (enabled = False)` so the state is visible.
  Date: 2026-07-22

- Decision: Haskell mirror names are `IdentityDecl`, `MemoryScopeDecl` (constructors
  `AgentScope | Shared`), `RecordPolicy` (constructors `Always | OnSuccess | Never`), and
  `MemoryPolicy` — the constructor names must match the Dhall union alternative names exactly
  (that is how generic `FromDhall` decodes unions), while the *type* names avoid clashing
  with kioku's `Kioku.Api.Scope.MemoryScope` which shikigami-core imports in the same
  modules that import `Shikigami.Api.Agent`.
  Rationale: a name collision would force qualified imports through half of shikigami-core;
  the Dhall side keeps the pretty names (`A.MemoryScope`, `A.RecordPolicy`) since Dhall
  names are namespaced by the schema record.
  Date: 2026-07-08

- Decision: `KizashiSignal.recipientFrom` and `DanwaConversation.topic` are owned by
  docs/plans/16-honest-sink-handlers-real-reiaction-and-honored-declaration-fields.md
  (MasterPlan 2). This plan lands after plan 16 where practical and does not add a stale
  "currently not honored" marker while updating the same schema documentation.
  Rationale: duplicating plan 16's scope would create conflicting edits in the sink handlers.
  Date: 2026-07-22

- Decision: Carry `RecallLimit` through `recallPriorLearnings` rather than converting it to
  the plan's intermediate `Int` parameter at each caller; convert only at Kioku's
  `RecallRequest.maxResults` and the local `take` boundary.
  Rationale: the bounded type makes an invalid or overflowing value unrepresentable for the
  entire application path instead of proving the bound and immediately discarding that
  proof. Kioku 0.4.1.0 requires `Int`, so the total accessor remains at that dependency
  boundary.
  Date: 2026-08-20

- Decision: Preserve the pre-evolution `AgentDecl` JSON bytes when `identity`, `memory`, and
  `enabled` have their defaults, and restore those defaults when their keys are missing.
  Rationale: `lookup-agent` journals the declaration in the durable agent workflow. Dhall
  record completion protects source manifests, but a separate compatibility codec is
  required for historical journals. The exact old bytes and missing-key round trip are
  tested; non-default declarations still encode every effective value.
  Date: 2026-08-20

- Decision: Do not add a workflow patch for record-policy enforcement.
  Rationale: old journaled declarations decode as `OnSuccess` and follow the identical
  existing branches. The `record` step remains present and returns the same result shape;
  `Always` failure recording occurs inside the existing `fail-session` step. `Always` and
  `Never` could not appear in historical declarations, so there is no old execution that
  needs a different branch. This conclusion is checked by `just keiro-gate` and documented
  in ADR 0011.
  Date: 2026-08-20

- Decision: Implement only plan 20's canonical report and loud lenient-loading slice here;
  leave its Settei `agents.strict`, cron strictness, routing, scheduling, and enqueue work
  pending in that plan.
  Rationale: plan 33 cannot enforce `enabled` once at the canonical selection boundary
  without the report it hard-depends on, but absorbing the rest of plan 20 would conflate two
  independently scoped ExecPlans. All current worker roles now report malformed manifests
  and disabled agents; strict-startup configuration remains explicit plan 20 work.
  Date: 2026-08-20


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Shikigami (this repo) runs agents declared as typed Dhall values. Dhall is a typed
configuration language; the schema `schema/Agent.dhall` exports record and union types, and
each manifest under `agents/` imports it (`let A = ../schema/Agent.dhall`) and builds
`A.Agent::{ ... }` — the `::` is Dhall *record completion*, which merges the author's fields
over the schema's `default` record. That `default` record is the whole backward-compatibility
mechanism of this plan: a field listed in `Agent.default` need not appear in any manifest.
Today the `Agent` type (schema/Agent.dhall:59-68) is:

```dhall
let Agent =
      { Type =
          { name : Text
          , description : Text
          , trigger : Trigger
          , behavior : Behavior
          , sinks : List Sink
          }
      , default = { description = "", sinks = [] : List Sink }
      }
```

Every Dhall type is mirrored by a Haskell type in
shikigami-api/src/Shikigami/Api/Agent.hs; the top-level mirror is `AgentDecl` (lines 85-93)
with exactly the five fields above, deriving `FromDhall` generically — which means **the
Haskell field names and union constructor names must match the Dhall names exactly**, or
decoding fails at runtime with a type error. The loader,
`Shikigami.Agent.Loader.loadAgent :: FilePath -> IO (Either LoadError AgentDecl)`
(shikigami-core/src/Shikigami/Agent/Loader.hs:21-26), is generic over the `FromDhall`
instance and needs no per-field changes.

Before plan 20, directory loading is different: three CLI commands each define a private
`loadAgents :: FilePath -> IO [AgentDecl]` that lists `*.dhall` files and silently discards
failures — shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs:45-49, Scheduler.hs:77-80,
ConsumeStream.hs:90-93. This plan begins after plan 20 has replaced those copies with
`loadAgentsReport`. The single-file commands `validate`
(Commands/Validate.hs), `run-behavior`, `render-lifecycle`, and `agent-run` call `loadAgent`
directly.

The runtime behavior the new `memory` defaults must encode, verified in code: recall runs
through `recallPriorLearnings` (shikigami-core/src/Shikigami/Agent/Run.hs:191-212), which
issues a kioku `Recall.recall` with hard-coded `maxResults = 10` (line 207) and, when the
vector path yields nothing (or no vector extension is installed), falls back to
`recallActiveByScope` (lines 214-219) which returns *all* active memories in the scope.
Recording happens in two places, both only on the success path: `runAgentWithMemory`
(Run.hs:93-112, step 4 under `Right output`) and the durable workflow's `record` step
(`recordLearning`, shikigami-core/src/Shikigami/Agent/Workflow.hs:585-605, called at
Workflow.hs:195 inside the `Right output` arm). The Flow capability `remember`
(shikigami-core/src/Shikigami/Flow/Capability.hs:93-114) also records, but is invoked
explicitly by flow code, so `recordPolicy` does not gate it (a flow author who calls
`remember` means it).

"Meibo principal" (the `identity` field's target): meibo is the platform's directory of
principals (humans, agents, services); a principal id is a stable Text identifier. This plan
only *carries* the principal; docs/plans/23-agent-lifecycle-control-with-meibo-principals.md
verifies and uses it.


## Plan of Work

### Milestone 1 — The Dhall surface

Scope: the schema exports the new types and fields with defaults; every existing manifest
still validates. In schema/Agent.dhall, before `let Agent`, add:

```dhall
let Identity = { principal : Text }

let MemoryScope = < AgentScope | Shared >

let RecordPolicy = < Always | OnSuccess | Never >

let MemoryPolicy =
      { scope : MemoryScope
      , recallLimit : Natural
      , recordPolicy : RecordPolicy
      }

let defaultMemoryPolicy =
      { scope = MemoryScope.AgentScope
      , recallLimit = 10
      , recordPolicy = RecordPolicy.OnSuccess
      }
```

Extend the `Agent` record: add `identity : Optional Identity`, `memory : MemoryPolicy`, and
`enabled : Bool` to `Type`, and add `identity = None Identity`, `memory =
defaultMemoryPolicy`, `enabled = True` to `default`. Export `Identity`, `MemoryScope`,
`RecordPolicy`, and `MemoryPolicy` in the final record (`in { SignalType, ..., Agent }`).

Acceptance: `for f in $(find agents -name '*.dhall' ! -name broken.dhall); do cabal run
shikigami -- validate "$f"; done` succeeds for every manifest without editing any of them
(note `agents/broken.dhall` is an intentional negative fixture and must still fail). This is
the "defaults mean no changes required" proof.

### Milestone 2 — The Haskell mirror and the proof manifest

Scope: the runtime decodes the new fields. In shikigami-api/src/Shikigami/Api/Agent.hs add
(deriving stock `Eq, Show, Generic` and anyclass `FromDhall, ToJSON, FromJSON`, matching the
module's convention):

```haskell
newtype IdentityDecl = IdentityDecl {principal :: !Text}

data MemoryScopeDecl = AgentScope | Shared

data RecordPolicy = Always | OnSuccess | Never

data MemoryPolicy = MemoryPolicy
  { scope :: !MemoryScopeDecl,
    recallLimit :: !Natural,
    recordPolicy :: !RecordPolicy
  }
```

(`IdentityDecl` decodes the Dhall record `{ principal : Text }`; a `newtype` over a single
field decodes as a one-field record with generic `FromDhall` — verify with the loader test,
and fall back to a one-field `data` record if the instance disagrees.) Add to `AgentDecl`:
`identity :: !(Maybe IdentityDecl)`, `memory :: !MemoryPolicy`, `enabled :: !Bool`. Export
the new types from the module head.

Create `agents/proof/declared-identity.dhall`:

```dhall
let A = ../../schema/Agent.dhall

in  A.Agent::{
    , name = "declared-identity"
    , description = "Proof agent: exercises identity, memory policy, and enablement"
    , behavior =
        A.Behavior.ShikumiProgram
          { task = "noop-summary"
          , preferEnrichment = False
          , grounding = None Text
          , enabledBy = None Text
          }
    , trigger = A.Trigger.Event { eventType = "proof.identity" }
    , identity = Some { principal = "principal_shikigami_proof" }
    , memory =
        { scope = A.MemoryScope.AgentScope
        , recallLimit = 3
        , recordPolicy = A.RecordPolicy.Never
        }
    , enabled = False
    }
```

Add a loader unit test group in shikigami-core/test/Main.hs: load
`agents/proof/declared-identity.dhall` and assert the three decoded values; load
`agents/heartbeat.dhall` and assert the defaults (`identity == Nothing`,
`memory == MemoryPolicy AgentScope 10 OnSuccess`, `enabled == True`).

Acceptance: `cabal test shikigami-core` passes; `cabal run shikigami -- validate
agents/proof/declared-identity.dhall` prints the decoded record including all three fields.

### Milestone 3 — Enforcement: enabled, recallLimit, recordPolicy

Scope: the declared values change runtime behavior. Three edits.

First, `enabled`. Consume plan 20's report and add to
shikigami-core/src/Shikigami/Agent/Loader.hs:

```haskell
enabledAgentsFromReport :: AgentLoadReport -> IO [AgentDecl]
```

For each successfully loaded declaration with `enabled = False`, print
`hPutStrLn stderr ("[loader] skipping disabled agent '" <> name <> "' (" <> path <> ")")`;
return the enabled declarations. The CLI commands already consume the report through plan
20's loud/strict loader; apply `enabledAgentsFromReport` before constructing each runtime. In
Commands/Validate.hs, after printing the decl, print
`note: agent is disabled (enabled = False)` when applicable (still exit 0 — validation is
about well-formedness).

Second, `recallLimit`. Change
`recallPriorLearnings :: AppEnv -> MemoryScope -> Text -> IO [MemoryRecord]`
(Run.hs:191) to take the limit:
`recallPriorLearnings :: AppEnv -> Int -> MemoryScope -> Text -> IO [MemoryRecord]`, use it
as `maxResults` (replacing the literal 10 at Run.hs:207) and pass it to
`recallActiveByScope`, which takes the newest `limit` records (ordering work beyond a plain
`take` is plan 34's milestone 2; here just cap the count so the declared limit is honored on
both paths). Update the call sites — Run.hs:78, Workflow.hs:175, and the Flow capability's
`Recall` interpreter (Flow/Capability.hs:91-92) — to pass
`fromIntegral (recallLimit (memory decl))`.

Third, `recordPolicy`. In `runAgentWithMemory` (Run.hs) and in the workflow arms
(Workflow.hs): under `OnSuccess` keep today's code paths; under `Never` skip the
`Memory.record` call (Run.hs step 4; Workflow.hs `recordLearning` returns `Nothing` without
recording — keep the journaled `record` step present so step order is unchanged, it simply
records a `Nothing` result); under `Always` additionally record the failure memory (content
`"run failed: " <> err`, tags `["agent-run","failure"]`) in the `Left` arms
(Run.hs:81-92 and Workflow.hs:184-186, before `fail-session`). Note the workflow constraint
from the MasterPlan's IP-3: do not rename or remove journaled steps; `Always`'s
failure-record happens inside the existing `fail-session` step body or a *new appended* step
(`record-failure`), never by reordering existing steps.

Acceptance: (a) `cabal run shikigami-worker -- --config
config/worker-agent-schema-proof.yaml` logs
`[loader] skipping disabled agent 'declared-identity' (agents/proof/declared-identity.dhall)`
and the agent never runs; (b) a `withShikigamiMigratedDatabase` test runs a workflow for a
decl with `recordPolicy = Never` and asserts no memory row is written while the session
still completes; a run with a failing behavior and `recordPolicy = Always` leaves a
`failure`-tagged memory; (c) a recall test seeds 5 memories, sets `recallLimit = 3`, and
asserts exactly 3 are recalled.

### Milestone 4 — Documentation and regression

Scope: the declared surface is documented and the whole suite is green. Update
docs/user/writing-agents.md: extend the "schema at a glance" block and field table with the
three fields, their defaults, and — honestly — who enforces what (`enabled`, `recallLimit`,
`recordPolicy` here; `memory.scope` by plan 34; `identity.principal` verified by plan 23).
Keep plan 16's final documentation for `KizashiSignal.recipientFrom` and
`DanwaConversation.topic` intact. Update docs/user/memory.md's description of recall/record
with the policy knobs. Run `cabal test all`.


## Concrete Steps

All commands from the repo root, inside `nix develop`. Database-backed tests need
`just create-database` once.

Step 1 — baseline:

```bash
cabal build all
cabal run shikigami -- validate agents/heartbeat.dhall
```

Expected: the five-field `AgentDecl` printed, `OK: 1 agent parsed.`.

Step 2 — after M1, prove no manifest needs edits:

```bash
for f in agents/*.dhall agents/proof/*.dhall agents/detectors/*.dhall; do
  case "$f" in *broken*) continue;; esac
  cabal run shikigami -- validate "$f" || echo "FAILED: $f"
done
```

Expected: every line ends `OK: 1 agent parsed.` (or the skill variant); no `FAILED:` lines.
(`agents/broken.dhall` is excluded — it is the loader's negative fixture and must keep
failing; check that separately: `cabal run shikigami -- validate agents/broken.dhall` exits
non-zero.)

Step 3 — after M2:

```bash
cabal run shikigami -- validate agents/proof/declared-identity.dhall
cabal test shikigami-core
```

Expected: the printed record shows `identity = Just (IdentityDecl {principal =
"principal_shikigami_proof"})`, `memory = MemoryPolicy {scope = AgentScope, recallLimit = 3,
recordPolicy = Never}`, `enabled = False`, plus the disabled note; tests green.

Step 4 — after M3, observe the loud skip (no database needed to see the loader line; the
worker will then wait on its queue):

```bash
cabal run shikigami-worker -- --config config/worker-agent-schema-proof.yaml 2>&1 | head -5
```

Expected transcript (shape):

```text
[loader] skipping disabled agent 'declared-identity' (agents/proof/declared-identity.dhall)
[worker] loaded N agents
[shikigami.worker] starting; draining shikigami_run_jobs
```

Step 5 — full regression:

```bash
cabal test all
```

Expected: green, including the new recall-limit, record-policy, and loader tests.


## Validation and Acceptance

Acceptance is behavioral, with a before/after contrast:

1. Byte-compatibility: every pre-existing manifest validates unchanged (Step 2). Before this
   plan the new fields do not exist; after it they exist and are invisible unless declared.
2. Enablement: with `enabled = False`, the agent is absent from the worker's, scheduler's,
   and stream-consumer's loaded set, and each skip is a visible stderr line naming agent and
   path. Before: no such thing as a disabled agent. Also: a manifest with a type error now
   produces a loud `SKIPPING unloadable manifest` line instead of vanishing silently.
3. Recall limit: with `recallLimit = 3` and 5 seeded memories in the agent's scope, a run
   recalls exactly 3 (asserted via `recalledPrior` in `AgentRunResult`). Before: always 10 on
   the vector path and unbounded on the fallback path.
   Values 0 and 1001 fail validation with path/value/bound diagnostics; a huge Natural
   never reaches an `Int` conversion or query.
4. Record policy: `Never` leaves zero memory rows for a successful run (session row still
   `completed`); `Always` leaves a `failure`-tagged row for a failing run; `OnSuccess`
   matches today's rows exactly.
5. `validate` prints the full new surface, so the declaration is inspectable.

Exact commands: `cabal test shikigami-core` (loader/decoding units, hermetic);
`cabal test all` (adds the `withShikigamiMigratedDatabase` Postgres tests for items 3-4).


## Idempotence and Recovery

All schema and mirror edits are additive and re-runnable; re-validating and re-testing are
side-effect free. The one behavioral risk is the `recallPriorLearnings` signature change: it
is a compile-time-visible break, so the compiler enumerates every call site — there is no
silent partial state. If M3's enforcement must be rolled back, the fields safely revert to
"parsed but not enforced" (M1/M2 state) by reverting the three enforcement edits; manifests
declaring the fields remain valid either way. Plan 20's loader consolidation is already
behavior-preserving for well-formed agents; this plan's enabled selection only removes
well-formed declarations that explicitly opt out with `enabled = False`.


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 20, 36, and 47. It owns the additive declaration-field
pattern consumed by plans 12, 23, 34, 35, and 40. Keep defaults backward compatible, reject unknown
fields through the canonical loader, and update the checked Keiro/codec artifacts where durable
values are affected.


## Portfolio Reconciliation (2026-08-10) — the module this plan edits does not exist

**Every reference in this plan to `shikigami-api/src/Shikigami/Api/Agent.hs` or to the module
`Shikigami.Api.Agent` is stale and will send an implementer to a file that is not there.**
Verified on 2026-08-10: `shikigami-api/src/Shikigami/Api/` contains exactly `OpenApi.hs` and
`Problem.hs`. There is no `Agent.hs`.

Plan 36 made `shikigami-api` the public HTTP contract package and moved the domain into
`shikigami-core`. The agent declaration now lives at
`shikigami-core/src/Shikigami/Agent/Decl.hs`, and the run job at
`shikigami-core/src/Shikigami/Agent/RunJob.hs`. The reason this matters beyond a path fix is the
package-architecture rule plan 36 also introduced: `shikigami-workers` is forbidden from depending
on `shikigami-api`, and `shikigami-core/test/Shikigami/PackageArchitectureSpec.hs` fails the build
on that edge. So mirroring declaration types into `shikigami-api` would not merely be misplaced —
it would put the declaration somewhere the worker cannot reach, and the build would say so.

Read every occurrence with this substitution: `shikigami-api/src/Shikigami/Api/Agent.hs` becomes
`shikigami-core/src/Shikigami/Agent/Decl.hs`, and the module `Shikigami.Api.Agent` becomes
`Shikigami.Agent.Decl`. That covers the Purpose section's "mirrored in `Shikigami.Api.Agent`,
proven by validate" discipline, Milestone 2's mirror step, the Context orientation, the
new-field instructions, and the Interfaces list including `Shikigami.Api.Agent.RecallLimit`.
The discipline itself is unchanged and still correct — a Dhall field, a `default` entry, a Haskell
mirror, and a `validate` proof — only the file it lands in has moved.

Confirm before editing rather than trusting this note, since it is a snapshot:

```bash
ls shikigami-api/src/Shikigami/Api/
ls shikigami-core/src/Shikigami/Agent/
```

The same substitution applies to the sibling plans that inherit this plan's additive-field
pattern: 12 (`mcpServers`), 32 (the channel-egress sink variant), 35 (`delegates`), and 40
(`expertise` and `routing`). This plan establishes the pattern, so getting the path right here is
what keeps four later plans from repeating the error.


## Portfolio Reconciliation (2026-08-05)

**This plan does not own agent declaration revision, artifact identity, or run pinning, and must not
grow them.** Its scope is the three additive declaration fields `identity`, `memory`, and `enabled`,
and the pattern they establish. An audit of the portfolio on 2026-08-05 confirmed that nothing in
this repository provided an immutable agent version — the request that asks for it is
`docs/improvement-requests/governed-agent-evolution.md` (declaration revision, behavior artifact
identity, run pinning, baseline-to-candidate relation, rollout policy), and it has no ExecPlan and
appears in no MasterPlan registry.

That vocabulary is now defined by
`docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md` as `AgentVersionRef`
(logical agent id, immutable version, declaration digest) and `AgentArtifactSet` (the digest bundle
covering declaration, behavior, skills, tool catalog, grounding, runtime, and policy), shaped so
lineage can be added additively and byte-pinned so a record with no lineage encodes identically to
one written before lineage existed. If `identity` work here needs to name an agent version, import
plan 49's type. When a governed-evolution plan is eventually written, it extends those records; it
must not introduce a second agent-version vocabulary.


## Interfaces and Dependencies

Hard dependencies: plans 36 and 20. Public/declaration records use strict unprefixed
fields under `DuplicateRecordFields` and Generic Lens conventions from plan 36.

Owned and defined by this plan:

- `schema/Agent.dhall` — `Identity`, `MemoryScope`, `RecordPolicy`, `MemoryPolicy` types;
  `identity : Optional Identity`, `memory : MemoryPolicy`, `enabled : Bool` on `Agent` with
  defaults `None Identity` / `defaultMemoryPolicy` / `True`; all exported.
- `Shikigami.Api.Agent` (shikigami-api) — `IdentityDecl(..)`, `MemoryScopeDecl(..)`,
  `RecordPolicy(..)`, `MemoryPolicy(..)`; `AgentDecl` gains
  `identity :: !(Maybe IdentityDecl)`, `memory :: !MemoryPolicy`, `enabled :: !Bool`.
- `Shikigami.Api.Agent.RecallLimit` — smart constructor/decoder enforcing 1–1000 and a
  total accessor for the validated SQL/runtime bound.
- `Shikigami.Agent.Loader` — consume plan 20's `AgentLoadReport` and
  `loadAgentsReport`; add `enabledAgentsFromReport :: AgentLoadReport -> IO [AgentDecl]`.
- `Shikigami.Agent.Run` —
  `recallPriorLearnings :: AppEnv -> Int -> MemoryScope -> Text -> IO [MemoryRecord]`
  (limit threaded to both the vector `maxResults` and the fallback cap); record-policy
  branching in `runAgentWithMemory`.
- `Shikigami.Agent.Workflow` — record-policy branching around `recordLearning`; no step
  renames or reorders (MasterPlan IP-3).

Consumed / coordinated (do not implement here):

- `memory.scope = Shared` semantics —
  docs/plans/34-memory-lifecycle-distillation-retention-and-shared-scope.md implements them
  over `Shikigami.Memory.Scope.sharedScope`; the field shape defined here is normative for
  both plans (MasterPlan IP-4).
- `identity.principal` verification and lifecycle control —
  docs/plans/23-agent-lifecycle-control-with-meibo-principals.md (MasterPlan 4); the field
  name/shape is the coordinated contract (MasterPlan IP-5).
- `KizashiSignal.recipientFrom` / `DanwaConversation.topic` honoring —
  docs/plans/16-honest-sink-handlers-real-reiaction-and-honored-declaration-fields.md
  (MasterPlan 2); this plan preserves plan 16's final documentation.
- kioku recall/record APIs — `Kioku.Recall.recall` (`RecallRequest {scope, query, strategy,
  maxResults}`), `Kioku.Recall.getActiveByScope`, `Kioku.Memory.record` — used as today, no
  kioku changes.

Build/test toolchain: Nix dev shell; `cabal build all`; `cabal test all`;
`cabal run shikigami -- validate <file>`; `just create-database` +
`Shikigami.Migrations.TestSupport.withShikigamiMigratedDatabase` for Postgres-backed tests.

Hard dependency: plan 20 defines the load-report API consumed by Milestone 3. Soft
landing dependency: plan 16 should settle the sink-field documentation before Milestone
4. Plan 30 is an independent consumer of the same report; plan 23 hard-depends on both
this plan and plan 30 before adding lifecycle state.


## Revision Notes

- 2026-08-05: Added a Portfolio Reconciliation note stating explicitly that this plan does not own
  agent declaration revision, artifact identity, or run pinning, and must not grow them. An audit found
  that vocabulary owned by nobody — the request asking for it,
  `docs/improvement-requests/governed-agent-evolution.md`, has no ExecPlan — so
  `docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md` now defines
  `AgentVersionRef` and `AgentArtifactSet`, shaped for additive extension. This plan's three declaration
  fields are unchanged.

- 2026-07-22: Replaced this plan's duplicate loader consolidation with a hard
  dependency on plan 20's `loadAgentsReport`, scoped this plan to enabled-agent
  selection, and removed the stale sink-field warning that would contradict plan 16.
- 2026-07-22: Added plan 36 and bounded `Natural` validation; recall limits now become a
  1–1000 domain type before any `Int`, query, or allocation use.


## Revision Notes

- 2026-08-10: Added a Portfolio Reconciliation correcting every reference to
  `shikigami-api/src/Shikigami/Api/Agent.hs`, which does not exist.

  The 2026-08-05 audit corrected this plan's *scope* — recording that it does not own governed
  agent evolution — but left its *paths* pointing at a module plan 36 had already moved. Verified
  2026-08-10: `shikigami-api/src/Shikigami/Api/` contains only `OpenApi.hs` and `Problem.hs`; the
  declaration is `shikigami-core/src/Shikigami/Agent/Decl.hs`.

  This is worth more than a path fix because of the package-architecture rule plan 36 introduced
  alongside the move: `shikigami-workers` may not depend on `shikigami-api`, and
  `PackageArchitectureSpec` fails the build on that edge. An implementer who followed this plan
  literally would mirror the declaration types into a package the worker cannot reach and would
  discover it as a build failure rather than as a design error.

  The note gives the substitution to apply throughout, and extends it to the four sibling plans —
  12, 32, 35, and 40 — that inherit this plan's additive-field pattern, since this plan is where
  the pattern is established.
