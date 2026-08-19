---
id: 24
slug: flow-versioning-with-keiro-patch-and-continue-as-new
title: "Flow versioning with keiro patch and continue-as-new"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tytnwe53rdd4es99ztv1p"
master_plan: "docs/masterplans/5-durable-evolution-versioning-and-replay-safety-for-long-lived-workflows.md"
---

# Flow versioning with keiro patch and continue-as-new

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

**Scope note added 2026-08-10, and it changes what this plan must prove without changing what it
must build.** Shikigami has no users. There is no deployed instance, no parked conversation, and
no suspended workflow anywhere. So every acceptance criterion below phrased as "an instance that
was already in flight when the change shipped keeps working" currently has no subject, and cannot
be demonstrated against real data.

That does not make this plan optional or premature — it makes it cheap, and it is the reason to
do it now rather than later. What this plan actually delivers is a *discipline* and its
*machinery*: the written rule for which code changes are safe, the `Shikigami.Workflow.Versioning`
module with its process-wide `activePatches` set and run options threaded through every workflow
and the resume worker, and the caller-supplied-label convention for capability step names. Six
later plans (25, 26, 27, 35, 50, 51) each add a journaled value or restructure a durable state
machine, and each is required to pass through this discipline. Building it before them is what
makes those plans cheap; building it after would mean retrofitting six of them.

Concretely, this means: build every mechanism, and prove it with **constructed** instances rather
than real ones. A test that starts a workflow under old-shape code, suspends it, swaps in
new-shape code, and resumes it is entirely achievable and is the right acceptance — it just has
to manufacture the in-flight instance rather than find one. Where a milestone below asks for
evidence about "existing parked conversations", read it as asking for a test that creates one.
Do not weaken a mechanism on the grounds that nothing depends on it yet; the mechanism is the
deliverable.

Shikigami executes agent runs and danwa conversations as durable keiro workflows: each step
of a run is journaled (recorded to Postgres under a step name), and a resumed run replays
journaled steps instead of re-running their side effects. That machinery is correct only as
long as the code never changes while instances are in flight. Today shikigami has no
versioning story at all: there is no rule about which code changes are safe to deploy over
suspended workflows, one capability (`emitSignal`) derives its journal step names from a
fresh in-memory counter so that inserting a single emission in a new deploy makes resumed
workflows replay the wrong recorded results, and keiro's two evolution primitives — `patch`
(journal a stable old-code/new-code branch decision per instance) and `continueAsNew`
(rotate an unbounded journal onto a fresh generation) — are never called.

After this plan, three things are true and demonstrable. First, there is a written
versioning discipline (`docs/workflow-versioning.md`) that states exactly which step-shape
changes are deploy-safe, and every other plan that touches
`shikigami-core/src/Shikigami/Agent/Workflow.hs` is governed by it. Second, every workflow
run in shikigami — worker runs, conversation runs, and resume-worker re-invocations — is
executed through shared `WorkflowRunOptions` carrying the process-wide active-patch set, so
`patch` actually works end to end; a test proves a workflow started under an old code shape
and resumed under a new shape takes the old branch while a fresh instance takes the new
branch. Third, `emitSignal` step names come from caller-supplied stable labels rather than
ordinals (guarded by a `patch` so in-flight flows are unharmed), and an agent declaring an
unknown `Flow{name}` is rejected at validate/boot time instead of failing mid-run.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Write `docs/workflow-versioning.md` (discipline rules, keiro semantics summary,
      step-name inventory) and add a pointer to it in `AGENTS.md`.
- [ ] M2: Add `shikigami-core/src/Shikigami/Workflow/Versioning.hs` with
      `shikigamiActivePatches`, `shikigamiWorkflowRunOptions`, `shikigamiWorkflowResumeOptions`.
- [ ] M2: Rewire `runAgentRunWorkflow`, `runConversationWorkflow`, and
      `Shikigami.Agent.Workflow.Resume.runResumeWorker` through the shared options.
- [ ] M3: Change the `Sink` capability so `emitSignal` takes a stable label; add the
      `shikigami.emit-signal-labels-v1` patch guard in `runSink`; update
      `atRiskCustomerFlow` call sites and existing tests.
- [ ] M4: Expose `registeredFlowNames`; make `shikigami validate` and worker boot fail on
      unknown `Flow{name}`.
- [ ] M5: Add `shikigami-core/test/Shikigami/WorkflowVersioningSpec.hs` deploy-simulation
      tests; wire into `shikigami-core/test/Main.hs`; full suite green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision (2026-08-19): **Refresh every file:line citation in this plan before implementation,
  and keep them mechanically checkable.**
  Rationale: this plan was authored 2026-07-08 against keiro 0.4.0.1 and the pre-split package
  layout. Two later changes invalidated its citations wholesale. Plan 36 split shikigami into six
  packages, so `shikigami-cli/src/Shikigami/Cli/Commands/{Validate,RenderLifecycle}.hs` and
  `shikigami-core/src/Shikigami/Worker.hs` name packages and modules that **no longer exist** —
  the CLI commands are `shikigami-server/src/Shikigami/Server/Command/*.hs`, the resume loop is
  `shikigami-workers/src/Shikigami/Agent/Workflow/Resume.hs`, and the run-job worker is
  `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs`. Plan 53 moved keiro from 0.4.0.1 to
  0.13.0.0, and **all fourteen** keiro line citations drifted — `patch` moved from `:289` to
  `:368`, `WorkflowStepDecodeError` from `:347` to `:829`, the patch-API test from
  `keiro/test/Main.hs:5257` to `:9241`. A novice following this plan would have opened the wrong
  lines or missing files at nearly every step, which is exactly the failure the self-containment
  rule exists to prevent. All 59 citations now resolve; three name files this plan creates.

- Decision (2026-08-19): **Construct `WorkflowRunOptions` by record update, and make
  `Shikigami.Workflow.Versioning` the single construction site.**
  Rationale: `WorkflowRunOptions` gained `leaseHeartbeat` and `onJournalAppend` between 0.4 and
  0.13 and keiro's own haddock says to extend it additively, so spelling out every field would
  break on the next release for no benefit. More importantly,
  `docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md` M3 needs a
  shibuya lease heartbeat threaded around workflow execution, and `leaseHeartbeat` is where it
  goes. If this plan leaves the construction site implicit, plan 17 will introduce a second
  options value and the two will disagree about `activePatches` — which is the precise failure
  this plan exists to prevent.

- Decision (2026-08-19): **M3's stable labels stay undeclarable, and this plan says so rather
  than implying otherwise.**
  Rationale: replacing `emit-signal:<ordinal>` with `emit-signal:<label>` fixes the
  deploy-fragility this plan owns, but a keiro-dsl workflow label is a wire word
  (`[A-Za-z0-9][A-Za-z0-9_-]*`) and the result still carries a colon. Claiming the checked
  specification will gate these labels afterwards would be false. Changing the separator is a
  second decision about a persisted step name; plan 16 owns that family per
  `docs/architecture/shikigami-domain-inventory.md`.

- Decision: `domain/shikigami.keiro-workspace` is the authoritative durable-topology inventory;
  this plan's discipline and active patches must agree with its checker/scaffold/harness.
  Rationale: stable names are persisted compatibility identifiers and need a machine-
  checked declaration/code drift gate, not prose alone.
  Date: 2026-07-22

- Decision: Fix `emitSignal` with caller-supplied stable labels plus a `patch` guard, not
  with keiro's `freshOrdinal`.
  Rationale: `freshOrdinal` is also a per-run counter and keiro's own documentation warns
  ordinal names are stable only if the order of calls never changes across deploys
  (`keiro/src/Keiro/Workflow.hs:306-311`); labels are unconditionally stable and match the
  named-form guidance keiro gives for sleeps and awakeables. The `patch` guard keeps
  in-flight flows on the old ordinal scheme so their journaled `emit-signal:0` entries and
  deterministic outbox ids stay valid.
  Date: 2026-07-08
- Decision: Do not add a `version` field to `FlowDef`.
  Rationale: keiro replays by step name, not by workflow version; a version number on the
  definition would be decorative unless something branches on it, and `patch` is that
  branching mechanism at the right granularity (per change, not per definition). The
  discipline document instead requires a new `WorkflowName` for wholesale rewrites.
  Date: 2026-07-08
- Decision: Keep the flow registry a hardcoded list; validation only.
  Rationale: one flow exists (`shikigami-core/src/Shikigami/Flow.hs:57-65`); the failure
  mode worth closing is unknown-flow-at-run-time, which load-time validation closes
  cheaply. See the MasterPlan Decision Log (2026-07-08).
  Date: 2026-07-08
- Decision: Leave the `ContinuedAsNew` outcome handling in `Shikigami.Agent.RunJob.Worker` (`AckOk`) and
  `Shikigami.Agent.Conversation` (error) as-is in this plan; plan 26 changes conversation
  behavior.
  Rationale: nothing in shikigami calls `continueAsNew` until plan 26, so those branches
  are unreachable today; changing conversation semantics here would couple the foundation
  plan to conversation redesign.
  Date: 2026-07-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section is self-contained; it explains every term and names every file. All shikigami
paths are relative to the repository root `/Users/shinzui/Keikaku/bokuno/shikigami`. The
keiro workflow engine is a separate repository; locate it with
`mori registry show keiro --full` (path `/Users/shinzui/Keikaku/bokuno/keiro`; the library
package lives in its `keiro/` subdirectory, so file references below like
`keiro/src/Keiro/Workflow.hs` mean `/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Workflow.hs`).

A "durable workflow" is an ordinary Haskell computation (an `effectful` `Eff` program) run
through keiro's `runWorkflow`. Each `step (StepName "x") action` either runs `action` and
appends a `StepRecorded "x" <json result>` event to a per-instance journal stream in
Postgres, or — if the journal already contains an entry named `"x"` — returns the recorded
result without running `action`. Verified semantics from `keiro/src/Keiro/Workflow.hs`
(module header, lines 1-29, and the `Step` handler at line 689):

- Replay is keyed by step name, not by source position. Reordering code between deploys
  does not corrupt an in-flight workflow as long as the names are stable
  (`keiro/src/Keiro/Workflow/Types.hs:129-132`).
- Renaming a step intentionally orphans the old journal entry: the renamed step has no
  journal history under its new name, so its action runs fresh on the next replay. This is
  keiro's recommended treatment for a single-step semantic change
  (`keiro/src/Keiro/Workflow.hs:24-26`).
- Step side effects are at-least-once at the step boundary: if the process crashes after
  the action ran but before the journal append commits, a resume runs the action again.
- If a journaled result no longer decodes into the type the replaying step expects, the
  runtime throws `WorkflowStepDecodeError` (`keiro/src/Keiro/Workflow.hs:829`) — a
  changed result type is a deploy-breaking change unless the JSON stays compatible.

keiro provides two evolution primitives shikigami does not use today:

`patch :: PatchId -> Eff es Bool` (`keiro/src/Keiro/Workflow.hs:368`; the effect
constructor `Patch :: PatchId -> Workflow m Bool` is at line 266). A patch is a named,
journaled branch decision for a cross-cutting code change. The deployed code declares its
active patch ids in `WorkflowRunOptions.activePatches` (`keiro/src/Keiro/Workflow.hs:406`).
When a workflow generation starts fresh, the runtime records the active set once under the
reserved step `__workflow_patches__` (`recordPatchSetIfFresh`, defined at line 657 and called at line 584; the step-name
constant is `patchSetStepName`, `keiro/src/Keiro/Workflow/Types.hs:389`). Each
`patch pid` call journals its `Bool` decision under `patch:<pid>` on first encounter and
replays it verbatim forever after (handler at line 781). The net effect: an instance
that was already in flight when the patch shipped has no recorded patch set, so its
decision is `False` (old branch); a fresh instance records the set containing the id, so
its decision is `True` (new branch). Crucially, `runWorkflow` (the plain entry point,
line 516) uses `defaultWorkflowRunOptions`, whose `activePatches` is empty — so
adopting `patch` REQUIRES switching call sites to `runWorkflowWith` with explicit options,
and threading the same options through the resume worker
(`WorkflowResumeOptions.runOptions`, `keiro/src/Keiro/Workflow/Resume.hs:182-186`;
`defaultWorkflowResumeOptions` at line 229). keiro's own test
("Keiro.Workflow patch API", `keiro/test/Main.hs:9241` onward) is the reference idiom:
run an instance to suspension under pre-patch code, re-run the same id under post-patch
code with `activePatches` set, observe the old branch; a fresh id observes the new branch;
the decision is journaled exactly once under `patch:<id>`.

`continueAsNew :: (ToJSON s) => s -> Eff es a` (`keiro/src/Keiro/Workflow.hs:337`)
rotates an unbounded workflow onto a fresh journal "generation". The runtime appends the
carried seed as a `StepRecorded __workflow_seed__` on generation g+1 first (so a crash
between the two appends still converges forward), then appends a terminal
`WorkflowContinuedAsNew` marker on generation g (`rotateGeneration`, lines 923-932). The
run's outcome is `ContinuedAsNew` (`keiro/src/Keiro/Workflow/Types.hs:299-310`), which
means "unfinished, continue on the new generation" — the resume worker rediscovers and
drives it (proven by keiro's test "rediscovers and resumes a rotated workflow on its
current generation"). The next run reads the seed back with
`restoreSeed :: s -> Eff es s` called at the top of the body
(`keiro/src/Keiro/Workflow.hs:347`). Generation 0 keeps the legacy stream name; later
generations get a `#<g>` suffix (`workflowGenerationStreamName`,
`keiro/src/Keiro/Workflow/Types.hs:166`). This plan adopts `continueAsNew` only in its
discipline document and test; plan 26 is the production consumer (the conversation loop).

What shikigami does today, verified in code:

- `FlowDef {name, lifecycle, run}` has no version field
  (`shikigami-core/src/Shikigami/Flow.hs:41-46`). The flow registry is a hardcoded
  one-element list (`shikigami-core/src/Shikigami/Flow.hs:57-65`) and `lookupFlow` is a linear name match (`shikigami-core/src/Shikigami/Flow.hs:66-68`).
- Both workflow names now come from the checked specification rather than from a Haskell
  literal. `shikigami-core/src/Shikigami/Agent/Workflow/Name.hs:19` re-exports
  `Shikigami.AgentRun.Generated.WorkflowRuntime.workflowName`, and
  `shikigami-core/src/Shikigami/Agent/Conversation.hs:100-101` reads
  `Shikigami.DanwaConversation.Generated.WorkflowRuntime.workflowName`. The literals
  `"shikigami.agent-run"` and `"shikigami.danwa-conversation"` live in
  `domain/shikigami-agent-run.keiro` and `domain/shikigami-conversation.keiro`, and renaming
  either is gated by `just keiro-diff`, which classifies it `BREAKING` on the
  persisted-identity surface with the code `WorkflowStableNameChanged`.
- Every workflow run uses default options: `runAgentRunWorkflow` calls plain `runWorkflow`
  (`shikigami-core/src/Shikigami/Agent/Workflow.hs:193-207`), `runConversationWorkflow`
  calls plain `runWorkflow` (`shikigami-core/src/Shikigami/Agent/Conversation.hs:200-214`), and the worker's resume loop
  calls `runWorkflowResumeWorker` with defaults
  (`shikigami-workers/src/Shikigami/Agent/Workflow/Resume.hs:35-41`). Nothing sets `activePatches`; nothing
  calls `patch` or `continueAsNew`. The only mentions of rotation are unreachable
  pattern-matches on the `ContinuedAsNew` outcome (`shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs:130` maps it to `AckOk`;
  `shikigami-core/src/Shikigami/Agent/Conversation.hs:115` maps it to an error).
- The `emitSignal` capability is deploy-fragile. `runSink`
  (`shikigami-core/src/Shikigami/Flow/Capability.hs:129-141`) allocates a fresh `IORef`
  counter per interpreted flow run and names each emission's journal step
  `emit-signal:<n>` from it (line 136). The counter restarts at 0 on every run, including
  replays — which is fine while the code is frozen (the i-th emission always gets ordinal
  i) but wrong across a deploy that inserts, removes, or reorders an emission: a suspended
  flow resumed under the new code assigns shifted ordinals, so a NEW emission can land on
  an ALREADY-JOURNALED step name and silently replay the wrong recorded `SinkResult`, while
  the old journal entry for the shifted emission is orphaned and its outbox enqueue re-runs
  under a new deterministic id (the outbox id is derived from workflow id + step name,
  `shikigami-core/src/Shikigami/Flow/SinkOutbox.hs:125-126,183-184`) — a duplicate signal.
- The flow behavior path fails on unknown flows only at run time:
  `runFlowBehavior` returns `Left ("unknown flow " <> flowName)` when `lookupFlow` misses
  (`shikigami-core/src/Shikigami/Agent/Workflow.hs:369-370`). The `validate` CLI command
  (`shikigami-server/src/Shikigami/Server/Command/Validate.hs`) parses the manifest and checks
  skill directories but never consults the flow registry; only `render-lifecycle`
  (`shikigami-server/src/Shikigami/Server/Command/RenderLifecycle.hs:40`) does.
- The test harness: real-Postgres tests use
  `withShikigamiMigratedDatabase` (`shikigami-migrations/test-support/Shikigami/Migrations/TestSupport.hs`),
  which provisions a migrated throwaway database and hands the test a connection string.
  `shikigami-core/test/Shikigami/AgentWorkflowSpec.hs` shows the idiom for driving
  workflows (e.g. the crash/replay tests at lines 67-159 count step-body executions via
  `AgentRunHooks`), and `shikigami-core/test/Shikigami/FlowLifecycleSpec.hs` shows the flow
  harness (`runFlowBody`, lines 239-261). Tests are tasty; the suite is the
  `shikigami-core-test` cabal test-suite with specs registered in
  `shikigami-core/test/Main.hs`.

Term definitions used below: "in-flight instance" means a workflow whose journal exists and
carries no terminal marker (it is suspended waiting on an awakeable, timer, or child);
"deploy" means restarting the worker with changed workflow-body code against the same
database; "step shape" means the set and order of journaled step names a body produces.


## Plan of Work

The work is five milestones. Each is independently verifiable; M2 must precede M3 and M5
(they need the options plumbing), and M1 can be written in parallel with everything.

Milestone 1 — the versioning discipline document. Create `docs/workflow-versioning.md`. It
is a normative document other plans cite, written for a reader who has never used keiro. It
must contain, in prose: (a) a plain-language summary of keiro's journal semantics as
verified above (replay by step name; rename-orphans; at-least-once step bodies; JSON
result-type compatibility; the `WorkflowStepDecodeError` failure mode); (b) the rules —
workflow names and ids are permanent; step changes must be additive (new names) by default;
renaming a step is the deliberate way to re-run a single changed step; `patch` (with an id
registered in `Shikigami.Workflow.Versioning.shikigamiActivePatches`) is required for any
change that adds, removes, or reorders steps an in-flight instance may straddle, or that
changes the meaning of an already-journaled result; `continueAsNew` is required for any
workflow that journals an unbounded number of steps (with `restoreSeed` at the top of the
body); step names must never be derived from run-local mutable counters — use
caller-supplied labels, or keiro's named primitives (`sleepNamed`, `awakeableNamed`); patch
ids are never reused and are removed from the active set only after the corresponding
`patch` call is deleted from the body; (c) the step-name inventory: a fenced `text` block
listing every step name shikigami journals today, gathered from the code — agent-run
lifecycle (`ingest-job`, `lookup-agent`, `open-session`, `recall`, `run-behavior`,
`dispatch-sinks`, `record`, `complete`, `fail-session`, `approval:<kind>:<ordinal>` from
`shikigami-core/src/Shikigami/Agent/Workflow.hs:299-300`), conversation (`ingest-start`, `lookup-agent`,
`resolve-session`, `record-user:<messageId>`, `run-behavior:<messageId>`,
`record-assistant-and-reply:<messageId>`, `turn-result:<messageId>`, `next-message:<n>`
awakeables, from `shikigami-core/src/Shikigami/Agent/Conversation.hs:127-193,248-262`), flow capabilities
(`classify`, `await-ack`, `emit-signal:<n>` pre-patch / `emit-signal:<label>` post-patch,
plus `<step>:notify` from `shikigami-core/src/Shikigami/Agent/Approval.hs:156-157`), and keiro's reserved names
(`__workflow_completed__`, `__workflow_seed__`, `__workflow_patches__`, `patch:<id>`,
`sleep:`/`awk:`/`awkid:`/`child:` prefixes); (d) a worked example — the M3 emitSignal
change — showing the before/after code and why the patch guard is needed. Add a short
pointer paragraph to `AGENTS.md` ("Durable workflow changes must follow
docs/workflow-versioning.md"). Acceptance: the document exists, every code claim in it
carries a file:line citation, and `rg "workflow-versioning" AGENTS.md` hits.

Milestone 2 — options plumbing. Create
`shikigami-core/src/Shikigami/Workflow/Versioning.hs` exporting:

```haskell
shikigamiActivePatches :: Set PatchId
shikigamiWorkflowRunOptions :: WorkflowRunOptions
shikigamiWorkflowResumeOptions :: WorkflowResumeOptions
```

`shikigamiActivePatches` starts as the singleton set of `PatchId
"shikigami.emit-signal-labels-v1"` (added in M3; if M2 is committed first, start empty and
let M3 add it). `shikigamiWorkflowRunOptions` is `defaultWorkflowRunOptions` with
`activePatches = shikigamiActivePatches` (a record update; the type derives `Generic`, and
plain record-update syntax works).

Build it as a record update on `defaultWorkflowRunOptions` rather than by writing every
field, because `WorkflowRunOptions` has grown since this plan was written. At keiro 0.13 it
also carries `leaseHeartbeat :: Maybe LeaseHeartbeat` and `onJournalAppend :: Maybe (IO ())`
(`keiro/src/Keiro/Workflow.hs:389-418`), neither of which this plan sets. That matters
beyond compilation: this module becomes the **one** place shikigami constructs
`WorkflowRunOptions`, so
`docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md` M3, which
needs a shibuya lease heartbeat threaded around workflow execution, will set
`leaseHeartbeat` here rather than introducing a second options value. Leave a haddock note
saying so. `shikigamiWorkflowResumeOptions` is
`defaultWorkflowResumeOptions` with `runOptions = shikigamiWorkflowRunOptions`. Then rewire
the three call sites: in `shikigami-core/src/Shikigami/Agent/Workflow.hs:193-207` replace
`runWorkflow agentRunWorkflowName ...` with `runWorkflowWith shikigamiWorkflowRunOptions
agentRunWorkflowName ...`; in `shikigami-core/src/Shikigami/Agent/Conversation.hs:200-214`
likewise for the conversation run; in `shikigami-workers/src/Shikigami/Agent/Workflow/Resume.hs:38` replace
`runWorkflowResumeWorker registry` with `runWorkflowResumeWorkerWith
shikigamiWorkflowResumeOptions registry` (import from `Keiro.Workflow.Resume`). Register
the new module in `shikigami-core/shikigami-core.cabal` under `exposed-modules`. Acceptance:
`cabal build all` succeeds and the whole existing test suite passes unchanged (an empty or
irrelevant patch set is behaviorally identical to defaults for workflows that never call
`patch`; note keiro only journals `__workflow_patches__` on fresh generations when the set
is non-empty, `keiro/src/Keiro/Workflow.hs:657` — after M3 lands, fresh workflow
journals will contain that extra reserved step, which is additive and invisible to
`loadStepIndex` consumers that look up specific names, but the AgentWorkflowSpec assertion
`loadLifecycleStepKeys` (`shikigami-core/test/Shikigami/AgentWorkflowSpec.hs:664-667`) compares an exact
step-name set and must be updated to delete `__workflow_patches__` alongside
`completedStepName`).

Milestone 3 — stable labels for `emitSignal`. In
`shikigami-core/src/Shikigami/Flow/Capability.hs` change the effect and smart constructor:

```haskell
data Sink :: Effect where
  EmitSignal :: Text -> Agent.Sink -> Value -> Sink m SinkResult

emitSignal :: (Sink :> es) => Text -> Agent.Sink -> Value -> Eff es SinkResult
```

The first argument is the caller-supplied stable label: a short lowercase token, unique per
emission site within one flow, never derived from runtime data that varies across replays
(the message/subject ids that ARE replay-stable, such as a journaled verdict's ticket id,
are permissible but discouraged; prefer static tokens). In `runSink` (currently lines
129-141) decide the scheme once per interpreted run with the patch primitive:

```haskell
runSink SinkEnv {agent, runId, occurredAt, danwaTarget, activity, grants} action = do
  useLabels <- patch (PatchId "shikigami.emit-signal-labels-v1")
  ordinalRef <- liftIO (newIORef (0 :: Int))
  interpret
    ( \_ -> \case
        EmitSignal label sink output -> do
          ordinal <- liftIO (atomicModifyIORef' ordinalRef \n -> (n + 1, n))
          let stepName =
                if useLabels
                  then StepName ("emit-signal:" <> label)
                  else StepName ("emit-signal:" <> Text.pack (show ordinal))
          enqueueSinkIntentStep grants stepName agent runId ordinal occurredAt danwaTarget (resolveSinkRecipient sink activity) sink output
    )
    action
```

`runSink` already has `Workflow :> es` so `patch` is in scope. The `ordinal` field inside
the `SinkIntent` payload keeps its existing meaning (position of the emission) in both
branches — only the JOURNAL STEP NAME and hence the outbox message id / deterministic
outbox UUID change on the new branch. In-flight flow workflows (suspended, e.g., at the
`await-ack` awakeable of `atRiskCustomerFlow`) resume with `useLabels = False` because
their generation's journal predates the patch set, so their journaled `emit-signal:0`
replays correctly and the escalation emission still lands on `emit-signal:1`. Fresh flows
record the patch set and use labels. Update the call sites in
`shikigami-core/src/Shikigami/Flow/AtRiskCustomer.hs`: line 49 becomes
`emitSignal "alert" (alertFor verdict activity) (toJSON verdict)` and line 59 becomes
`emitSignal "escalate" (escalationFor verdict activity) (toJSON verdict)`. Update
`shikigami-core/test/Shikigami/FlowLifecycleSpec.hs`: `sinkFlow` (line 196) passes a label
(use `"alert"`), and the expected delivered detail at line 87 becomes
`"outbox:flow-sink-spike:emit-signal:alert"` (fresh test workflows take the new branch
because the harness now runs with `shikigamiWorkflowRunOptions` — also switch the spec's
`runFlowBody` at lines 246-253 from `runWorkflow` to `runWorkflowWith
shikigamiWorkflowRunOptions`). Add `"shikigami.emit-signal-labels-v1"` to
`shikigamiActivePatches` and record it in the discipline document's worked example.
Acceptance: FlowLifecycle tests pass with the new label-based outbox detail, and the M5
deploy-simulation test (below) proves the old-branch behavior.

Milestone 4 — load-time flow validation. Add the flow names and their stable workflow
relationships to plan 39's checked `domain/shikigami.keiro-workspace` specification, regenerate, and
export the generated runtime-free name list so callers can validate without constructing
approval environments:

```haskell
registeredFlowNames :: [Text]
```

The generated list is the validation source; hand-owned `flowRegistry` construction must have a
conformance test proving it contains exactly that set. Do not maintain a second literal list or
edit a generated module. Then, in the validation command component in `shikigami-server`, after the manifest parses, add a
case for `Flow {name = flowName}` that fails (`exitFailure` with
`validate: unknown flow <name>; registered flows: ...`) when `flowName` is not in
`registeredFlowNames`. In the worker composition component in `shikigami-workers`, validate each loaded
`AgentDecl` the same way and refuse to start listing the offending agents. Acceptance: a
manifest with `behavior = Flow { name = "no-such-flow" }` is rejected by
`cabal run shikigami -- validate <path>` with a non-zero exit, and the worker refuses to
boot with it in the agents directory, while `agents/*.dhall` manifests in the repo still
validate.

Milestone 5 — the deploy-simulation test. Add
`shikigami-core/test/Shikigami/WorkflowVersioningSpec.hs` (register in
`shikigami-core/test/Main.hs` and in the test-suite's `other-modules` in
`shikigami-core/shikigami-core.cabal`). Two test cases, both against
`withShikigamiMigratedDatabase`:

Test A, "in-flight workflow survives a simulated deploy under a patch guard": define two
body functions of type `Eff (Workflow : AppEffects) Text` sharing a `WorkflowName
"shikigami.test-versioning"`. The OLD shape does `step "collect"` (returning `"v1"`),
then parks on an awakeable via `Shikigami.Agent.Workflow.Input.awaitInput (StepName
"external-answer")`. The NEW shape first calls `patch (PatchId
"shikigami.test-versioning-v2")`; on `True` it runs an inserted `step "enrich"` before
`collect`'s successor and returns `"v2:" <> answer`, on `False` it follows the old order
and returns `"v1:" <> answer`. Drive it: run the old body with
`runWorkflowWith shikigamiWorkflowRunOptions` (the test constructs its own options value
`testOptions = defaultWorkflowRunOptions {activePatches = Set.singleton (PatchId
"shikigami.test-versioning-v2")}` for the "new deploy" and plain
`defaultWorkflowRunOptions` for the "old deploy", so the test does not depend on the
production patch set) — old deploy, instance `wid-inflight`: outcome `Suspended`. Deliver
the answer with `Shikigami.Agent.Workflow.Input.deliverInputTo`. Resume the SAME id under
the NEW body with the NEW options: outcome `Completed "v1:..."` (old branch; `collect` was
replayed not re-run — assert via an `IORef` execution counter in the step body). Run a
FRESH id under the new body/options end to end: `Completed "v2:..."`, and its step index
(`loadStepIndex`) contains `patch:shikigami.test-versioning-v2` with recorded value `true`
plus `__workflow_patches__`.

Test B, "emitSignal ordinals are preserved for in-flight flows and labeled for fresh ones":
using the FlowLifecycleSpec harness style, run `atRiskCustomerFlow` with the high-risk
payload (`shikigami-core/test/Shikigami/FlowLifecycleSpec.hs:362`) to suspension under OLD options (empty patch set)
— journal now holds `emit-signal:0`. Resolve the acknowledgement-timeout timer path (fire
the approval timer as `fireDueApprovalTimer` does at `shikigami-core/test/Shikigami/FlowLifecycleSpec.hs:308-312`) and
resume under NEW options (patch set containing `shikigami.emit-signal-labels-v1`): the
escalation emission must journal as `emit-signal:1` (old scheme — assert via
`loadStepIndex`), and the outbox must contain exactly two rows (no duplicate alert). Then
run a fresh workflow id fully under NEW options and assert its step index contains
`emit-signal:alert` and not `emit-signal:0`.

Acceptance for the milestone: both tests pass, and they fail if either the patch plumbing
(M2) or the guarded interpreter (M3) is reverted.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikigami`, inside
the dev shell. Enter it once:

```bash
nix develop
```

Build and test baseline before changing anything (requires the dev-shell Postgres; run
`just create-database` first if the dev database does not exist):

```bash
cabal build all
cabal test all
```

Work through the milestones in order M1, M2, M3, M4, M5 (M1 may interleave). After each
milestone:

```bash
cabal build all
cabal test shikigami-core-test
```

To iterate on just the new spec while writing M5:

```bash
cabal test shikigami-core-test --test-options='-p Versioning'
```

Expected transcript shape for the final state (names indicative):

```text
AgentWorkflow
  replays completed lifecycle steps for the same run id:            OK
  ...
FlowLifecycle
  emitSignal enqueues an allowed sink outbox intent:                OK
  ...
WorkflowVersioning
  in-flight workflow survives a simulated deploy under patch guard: OK
  emitSignal ordinals preserved in flight, labels when fresh:       OK

All N tests passed
```

Manual validation of M4 (uses the repo's own manifests):

```bash
cabal run shikigami -- validate agents/at-risk-customer.dhall   # expect: OK
printf 'unknown flow' && cabal run shikigami -- validate /tmp/bad-flow.dhall  # after writing a manifest with Flow { name = "no-such-flow" }; expect non-zero exit
```

(If `agents/at-risk-customer.dhall` does not exist under `agents/`, list `agents/` and use
any manifest whose behavior is `Flow`; the FlowLifecycleSpec agent declaration shows the
shape.)


## Validation and Acceptance

The change is accepted when all of the following observable behaviors hold.

1. Discipline document: `docs/workflow-versioning.md` exists, contains the rules, the
   keiro-semantics summary, the step-name inventory, and the emitSignal worked example;
   `AGENTS.md` points to it.
2. Patch plumbing: `rg "runWorkflow " shikigami-core/src shikigami-workers/src shikigami-server/src` shows no
   production call site using the default-options entry point for the agent-run or
   conversation workflows; all go through `Shikigami.Workflow.Versioning`.
3. Deploy simulation: `cabal test shikigami-core-test --test-options='-p Versioning'`
   passes; reverting the `runSink` patch guard (forcing `useLabels = True`
   unconditionally) makes Test B fail with a duplicated outbox row or an unexpected
   `emit-signal:escalate` step on the in-flight instance — this is the "wrong replay"
   defect the plan exists to prevent, made visible.
4. Labels: after a fresh high-risk flow run, `loadStepIndex` for its workflow contains
   `emit-signal:alert`; the delivered `SinkResult` detail is
   `outbox:<workflowId>:emit-signal:alert`.
5. Load-time validation: `cabal run shikigami -- validate` rejects unknown `Flow{name}`
   manifests with exit code 1 and a message naming the registered flows; the worker
   refuses to boot with such a manifest in its agents directory.
6. No regressions: `cabal test all` is green, including the pre-existing AgentWorkflowSpec
   crash/replay and conversation tests (with the single sanctioned update: the expected
   lifecycle step-name set additionally filters keiro's `__workflow_patches__`).


## Idempotence and Recovery

Every step is an ordinary code-plus-test change; re-running builds and tests is always
safe. The database used by tests is provisioned per test via
`withShikigamiMigratedDatabase` and discarded, so failed test runs leave no state to clean.

The one deployment-order hazard this plan itself creates: once M3 ships, the patch id
`shikigami.emit-signal-labels-v1` must remain in `shikigamiActivePatches` until no workflow
generation journaled before M3 can still resume (for the current system that means: until
all pre-M3 flow instances have completed) AND the `False` branch is deleted; per the
discipline document, remove the id only in the same change that deletes the guarded old
branch. Rolling BACK a deploy after fresh instances have journaled
`patch:shikigami.emit-signal-labels-v1 = true` is safe for those instances only if the
rolled-back code still contains the labeled branch; therefore tag the M3 commit and note in
the discipline doc that rollbacks must not cross a patch introduction. If M2 must be
reverted in an emergency, reverting to plain `runWorkflow` is safe provided no `patch` call
sites exist yet (i.e., revert M3 first, then M2).


## Portfolio Reconciliation (2026-07-30)

This plan hard-depends on plans 39 and 47. Implement against Keiro 0.4.0.1, including
explicit state-shape hashes, checked structural/opaque declarations, codec comparison/goldens, and
the released atomic `continueAsNew` behavior. Every topology change updates
`domain/shikigami.keiro-workspace` and passes the plan-39 coverage/opaque gates.


## Interfaces and Dependencies

Hard dependencies: plans 36 and 39. Every step/patch/name change updates the checked
Keiro DSL and passes its generated-artifact diff gate.

Libraries and modules used, all already dependencies of `shikigami-core` (see
`shikigami-core/shikigami-core.cabal`): `keiro` (workflow runtime), `effectful`,
`containers`, `aeson`. No new package dependencies.

From keiro, the following existing interfaces are consumed (verified signatures):

```haskell
-- keiro/src/Keiro/Workflow.hs
patch          :: (Workflow :> es) => PatchId -> Eff es Bool
continueAsNew  :: (Workflow :> es, ToJSON s) => s -> Eff es a
restoreSeed    :: (Workflow :> es, ToJSON s, FromJSON s) => s -> Eff es s
runWorkflowWith :: (IOE :> es, Store :> es, Error StoreError :> es)
                => WorkflowRunOptions -> WorkflowName -> WorkflowId
                -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)
defaultWorkflowRunOptions :: WorkflowRunOptions   -- activePatches = Set.empty

-- keiro/src/Keiro/Workflow/Resume.hs
runWorkflowResumeWorkerWith :: (IOE :> es, Store :> es, Error StoreError :> es)
                            => WorkflowResumeOptions -> WorkflowRegistry es -> Eff es ()  -- (loops forever)
defaultWorkflowResumeOptions :: WorkflowResumeOptions

-- keiro/src/Keiro/Workflow/Types.hs
newtype PatchId = PatchId {unPatchId :: Text}
patchStepName    :: PatchId -> Text   -- "patch:<id>"
patchSetStepName :: Text              -- "__workflow_patches__"
```

New shikigami interfaces that must exist at the end of the plan:

```haskell
-- shikigami-core/src/Shikigami/Workflow/Versioning.hs
module Shikigami.Workflow.Versioning
  ( shikigamiActivePatches,
    shikigamiWorkflowRunOptions,
    shikigamiWorkflowResumeOptions,
  ) where

shikigamiActivePatches :: Set PatchId
shikigamiWorkflowRunOptions :: WorkflowRunOptions
shikigamiWorkflowResumeOptions :: WorkflowResumeOptions

-- shikigami-core/src/Shikigami/Flow/Capability.hs (changed)
emitSignal :: (Sink :> es) => Text -> Agent.Sink -> Value -> Eff es SinkResult

-- shikigami-core/src/Shikigami/Flow.hs (added)
registeredFlowNames :: [Text]
```

Downstream plans that consume these: plan 25 (label convention, patch plumbing, and the
same `shikigami-core/src/Shikigami/Flow/Capability.hs` module), plan 26 (`continueAsNew`/`restoreSeed` usage under the
discipline; `shikigamiWorkflowRunOptions` at conversation call sites), plan 27 (the
discipline document and step-name inventory as the review standard for code motion), and
plans 15/17/23 in other MasterPlans (any change to `shikigami-core/src/Shikigami/Agent/Workflow.hs` step structure must
follow `docs/workflow-versioning.md`). Plan 35 (MasterPlan 7) is a hard downstream
consumer: delegation work begins only after this plan and updates the step inventory for
any added durable steps.


## Revision Notes

- 2026-07-22: Added plan 35 as a hard downstream consumer of the workflow-versioning
discipline and patch plumbing, matching the cross-MasterPlan execution order.
- 2026-07-22: Added plan 39 as a hard checked-DSL predecessor and made the DSL/checker/
  scaffold/harness/diff gate part of purpose, acceptance, and interfaces.
- [ ] Prerequisite: plans 36 and 39 complete; update the checked Keiro DSL before changing durable code.


## Revision Notes

- 2026-08-10: Added a scope note to Purpose recording that shikigami has no users, and what that
  does and does not change here.

  It does not change the deliverable. This plan's product is a discipline plus the
  `Shikigami.Workflow.Versioning` machinery — `activePatches`, the run and resume options threaded
  through every workflow, and the caller-supplied-label convention that fixes `emitSignal`'s
  counter-derived step names. Plans 25, 26, 27, 35, 50, and 51 each add a journaled value or
  restructure a durable state machine and are required to pass through it, so building it first is
  what keeps those six cheap.

  It does change the evidence. Acceptance criteria phrased as "an instance already in flight when
  this shipped keeps working" have no subject today, so they must be proven with constructed
  instances: start a workflow under old-shape code, suspend it, swap in new-shape code, resume it.
  That is achievable and is the right test — it just manufactures the in-flight instance instead of
  finding one. The note states explicitly that no mechanism should be weakened on the grounds that
  nothing depends on it yet.


## Reconciliation with the delivered plan 39 (2026-08-19)

`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md` has landed, and
three of its assumptions turned out to be wrong. Anything this plan says that contradicts the
following is superseded.

**The specification is a workspace, not one file.** The service input is
`domain/shikigami.keiro-workspace`, a manifest naming `service shikigami`,
`runtime-package shikigami-core`, and `layout collocated`, plus two members —
`domain/shikigami-agent-run.keiro` and `domain/shikigami-conversation.keiro`. Every file-taking
`keiro-dsl` command takes the manifest and validates the composed service. Every reference to
`domain/shikigami.keiro` in this plan has been repointed; a startability check that looks for the
old path would fail against a repository where plan 39 *is* done.

The manifest declares **no `module` clause**: `context shikigami` already supplies the
`Shikigami` prefix, and adding `module Shikigami` scaffolds `Shikigami.Shikigami.*`. Do not add
one, and do not pass `--module-root` or `--collocate`.

**Shikigami has no aggregate, no read model, no projection, no router, and no process manager.**
Plan 39's Milestone 1 census, with evidence in
`docs/architecture/shikigami-domain-inventory.md`, found that the only Keiro command runner in the
repository targets *kioku's* session stream, and that
`Shikigami.Flow.Lifecycle.AtRiskCustomer` is a Keiki transducer that renders a Mermaid diagram
rather than an event source. The declared surface today is exactly two durable workflows and
their `run` operations.

**Three surfaces are deliberately undeclared, and the reason is binding on this plan too:** do not
certify a schema that differs from the codec actually executed. The `shikigami_run_jobs` queue
keeps its bare `RunJob` payload rather than acquiring Keiro's `{v,t,data}` envelope; the Kafka
inbox and the Danwa contract stay hand-written because a generated contract codec writes a
discriminator into a body that has none; and the sink outbox stays hand-written because its
publisher calls HTTP sinks rather than publishing to Kafka. Declaring any of them is a wire change
that needs its own commit, its own decision, and its own fixture.

**The gate is `just keiro-gate`.** It runs `keiro-check` (with `--min-language 5`,
`--deny-warnings`, and `--fail-on-opaque`), `keiro-inspect` (asserting every member declares its
language at effective version 5), `keiro-scaffold` (regenerate, then `git diff --exit-code`),
`keiro-diff <ref>` (the six-surface evolution classification), and `cabal test
keiro-shikigami-conformance`. Run it before merging any change to `domain/`, to the generated
layer under `shikigami-core/src/Shikigami/*/Generated/`, or to a durable identity. A `BREAKING`
finding exits non-zero and is a deployment gate, not an advisory.

**A workflow label is a wire word.** keiro-dsl parses a `step`, `await`, `sleep`, or `child` label
with `[A-Za-z0-9][A-Za-z0-9_-]*`. A label containing a colon or a value computed at run time
cannot be declared at all. Shikigami's `approval:<SinkKind>:<ordinal>`, `<label>:notify`,
`emit-signal:<ordinal>`, and every per-message conversation label are therefore outside the
specification until the plan that owns them makes them static.

### What changes for this plan

The versioning discipline this plan owns now has a second, mechanical half. A Keiro `patch` id and
a `continueAsNew` seed are both declared surfaces: `patch <id> { ... }` inside a workflow body and
`continueAsNew <SeedType>` as its final top-level item. Declare them in the owning member and run
`just keiro-diff <merge-base>` **in addition to** exercising the runtime `patch`, because the two
check different things — the runtime keeps an in-flight instance coherent across a deploy, and the
diff refuses a change that would strand it in the first place. Neither substitutes for the other.

Concretely, `AgentRun.patches` and `DanwaConversation.patches` are both `[]` today, and both are
asserted by the generated conformance target against
`shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/src/KeiroConformance/Expectations.hs`.
Adding the first patch id changes that fact, so this plan must review and commit the
`Expectations` change deliberately — it is create-once hand-owned code and keiro-dsl will never
rewrite it.

**M3's stable labels do not become declarable, and the plan should not claim they will.**
`emit-signal:<ordinal>` is listed in `docs/architecture/shikigami-domain-inventory.md` as one
of six undeclarable label families. M3 replaces the ordinal with a caller-supplied token, which
fixes the deploy-fragility this plan is about — but the resulting `emit-signal:alert` still
carries a colon, and a keiro-dsl workflow label is parsed by the wire-word production
`[A-Za-z0-9][A-Za-z0-9_-]*`. So after M3 the label is *stable* but still outside the
specification, and `just keiro-diff` will not gate a later rename of it. Making it declarable
means choosing a separator the grammar accepts (`emit-signal-alert`), which is a second,
independent decision about a persisted step name and belongs to whichever plan is willing to
own it — most naturally
`docs/plans/16-honest-sink-handlers-real-reiaction-and-honored-declaration-fields.md`, which the
inventory already names as this family's owner. If this plan takes it, take it deliberately and
declare the labels in `domain/shikigami-agent-run.keiro` in the same change.

This plan also inherits the run-job queue decision. If it moves `shikigami_run_jobs` onto the
declared `workqueue` surface, that is a codec change on both the producer
(`Shikigami.Trigger.Enqueue`) and the consumer (`Shikigami.Agent.RunJob.Worker`), and it must
retire the live assertion at `shikigami-core/test/Shikigami/WireCompatSpec.hs:76-81` that the
payload is bare — in its own commit, with its own Decision Log entry and its own fixture.

Revision note (2026-08-19): Citation refresh and three corrections; no scope change, no
milestone added or removed.

Every `file:line` reference in this plan was resolved mechanically against the working tree and
against `keiro-0.13.0.0`, and **21 of them were wrong**. Two causes, both external to this plan:
plan 36's six-package split retired `shikigami-cli` and `shikigami-core/src/Shikigami/Worker.hs`
entirely, and plan 53's move from keiro 0.4.0.1 to 0.13.0.0 shifted every keiro line number. The
Decision Log entry of 2026-08-19 records the specifics. All 59 citations now resolve; the only
ones that do not name an existing file are the three artifacts this plan creates.

Three substantive corrections came out of the same pass. The two keiro signatures this plan
quotes as "verified" were missing constraints — `runWorkflowWith` needs `Error StoreError :> es`
and `runWorkflowResumeWorkerWith` had no constraint list at all — so the M2 rewiring would not
have compiled as written. The `enqueueSinkIntentStep` call sketched in M3 was missing the
`grants` and `resolvedRecipient` arguments the current signature takes. And the claim that the
two workflow names are Haskell constants is no longer true: plan 39 moved both into the checked
specification, so `Agent/Workflow/Name.hs` and `Agent/Conversation.hs` now read them from the
generated `WorkflowRuntime`, and renaming either is gated by `just keiro-diff` as
`BREAKING [WorkflowStableNameChanged]`.

Two forward-looking notes were added rather than corrected. `WorkflowRunOptions` grew
`leaseHeartbeat` and `onJournalAppend` at 0.13, and this plan's `Shikigami.Workflow.Versioning`
becomes the single construction site — which is where plan 17 M3's lease heartbeat must go, so
the two plans do not end up with disagreeing options values. And M3's stable `emit-signal:<label>`
step names remain outside the keiro-dsl grammar because they still carry a colon; the plan now
states that instead of leaving a reader to assume the specification will gate them.
