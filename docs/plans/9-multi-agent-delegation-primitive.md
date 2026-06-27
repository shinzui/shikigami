---
id: 9
slug: multi-agent-delegation-primitive
title: "Multi-agent delegation primitive"
kind: exec-plan
created_at: 2026-06-27T16:23:56Z
intention: "intention_01kw4y6ky2eynrd9wn9p0s2z89"
---

# Multi-agent delegation primitive

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today the agents in this repository can only coordinate *indirectly*. One agent emits a
result onto a shared activity stream, and — if a second agent happens to declare a trigger
that matches it — that second agent fires. There is no way for an agent to say "hand this
subtask to a specialist and wait for the answer." That direct hand-off is what humans mean
by *delegation*, and it is the missing piece for supervisor-style work (a coordinator agent
that farms parts of a job out to focused workers and then synthesizes their answers).

After this change a behavior running inside an agent can call a new primitive, `delegate`,
naming another declared agent and an input payload. `delegate` starts that other agent as a
**child run**, and the parent run **suspends** (parks itself durably) until the child
finishes, then receives the child's result and continues. A supervisor can fan out — spawn
two specialists at once — and then await both, combining their outputs. Because the parent
suspends on durable storage rather than blocking a thread, a delegation that takes minutes
or survives a process crash resumes exactly where it left off, never re-running the child.

You can see it working three ways. First, a supervisor agent `research-supervisor` delegates
to two specialists `web-researcher` and `code-researcher`; the worker log shows the parent
suspend, the two children run, and the parent resume with a synthesized result. Second, the
parent and each child appear as linked rows in the kioku session store: each child session
records the parent run's session id and a delegation depth, so you can query the whole
delegation tree (`SELECT id, parent_session_id, delegation_depth FROM kioku_sessions ...`)
and read the provenance of any delegated run. Third, if you kill the worker while a child is
still running and restart it, the parent does not restart from the top: it replays its
journal, sees the child already in flight (or finished), and continues — proving the await
is durable, not a thread block.

This primitive is added **alongside** the existing stream coordination, not instead of it.
Stream coupling stays the default loose, declarative way agents react to the world; delegation
is the new tight, imperative way an agent commissions a specific subtask and consumes its
result.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **M1 — delegation context and depth bound (pure core).** Completed 2026-06-27T20:34:00Z. Added `Shikigami.Agent.Delegate.Context` with `DelegateCtx`, `maxDelegationDepth = 4`, `DelegationDepthExceeded`, and `checkDepth`; extended `Shikigami.Api.RunJob.TriggerKind` with `TriggeredByDelegation`; added optional `parentSessionId`, `parentRunWorkflowId`, and `delegationDepth` fields to `RunJob`; set existing producers and tests to `Nothing`; added the `Delegate.Context` unit tests. Validation: `nix develop -c cabal build shikigami-api shikigami-core` succeeded and `nix develop -c cabal test all` passed all 24 tests.
- [x] **M2a — kioku parent/child lineage implementation (dependency).** Completed 2026-06-27T20:42:54Z in `/Users/shinzui/Keikaku/bokuno/kioku` and committed as `8bcfc282484dd59b0a0b25530cca4f3ad9034ce1` (`feat(session): add delegation lineage`). Extended `StartSessionData`, `SessionStartedData`, and `SessionRow` with `parentSessionId` and `delegationDepth`; added backwards-compatible decoding for old `SessionStarted` events; added the `getDelegationChildren` read model; added the `2026-06-27-20-35-00-kioku-session-delegation-lineage.sql` migration; and added `Session.Lineage` tests. Validation: `nix develop -c cabal build all` and `nix develop -c cabal test all` passed in the kioku repo.
- [x] **M2b — shikigami kioku pin update.** Completed 2026-06-27T21:28:46Z. Verified `origin/master` in `/Users/shinzui/Keikaku/bokuno/kioku` contains `8bcfc282484dd59b0a0b25530cca4f3ad9034ce1`, then updated shikigami's `cabal.project` kioku `source-repository-package` tag to that exact commit. This keeps the dependency portable through GitHub while avoiding unrelated later kioku changes. Updated shikigami's `StartSessionData` call sites so non-delegated sessions pass `parentSessionId = Nothing` / `delegationDepth = 0`, and the durable workflow path projects lineage from `RunJob`. Validation: `nix develop -c cabal build shikigami-api shikigami-core` passed. `nix develop -c cabal test all` had one ephemeral Postgres startup timeout in `AgentWorkflow/resumes after a crash without rerunning journaled step bodies`; rerunning that exact test with `nix develop -c cabal test shikigami-core-test --test-option -p --test-option "resumes after a crash without rerunning journaled step bodies"` passed.
- [x] **M3 — the `delegate` primitive over keiro child workflows.** Completed 2026-06-27T21:40:02Z. Added `Shikigami.Agent.Delegate` with `delegate`, `awaitDelegated`, and `delegatedWorkflowId`; exposed it from `shikigami-core`; extended `DelegateCtx` with the current `sessionId` so delegated child jobs can record `parentSessionId`; mapped child cancellation/failure/decode errors into `DelegationError`; and added an integration test where a parent workflow spawns a child agent run, suspends on `awaitDelegated`, the child completes through the agent-run workflow, and the parent resumes with the child behavior output. Validation: `nix fmt` succeeded and `nix develop -c cabal test all` passed all 25 tests.
- [x] **M4 — end-to-end supervisor demo, crash/resume, lineage inspection.** Completed 2026-06-27T21:48:51Z. Added `agents/proof/research-supervisor.dhall`, `agents/proof/web-researcher.dhall`, and `agents/proof/code-researcher.dhall`; added workflow-aware execution for the proof supervisor task while keeping ordinary `ShikumiProgram`/`Skill` behavior on the existing runner; registered stub specialist tasks; documented the runbook in `docs/user/living-loop.md`; and added a DB-backed test that loads the Dhall proof agents, verifies supervisor fan-out/suspend/resume/synthesis, and asserts kioku child session lineage via `getDelegationChildren`. Validation: focused proof test `nix develop -c cabal test shikigami-core-test --test-option -p --test-option "proof supervisor fans out"` passed, then `nix develop -c cabal test all` passed all 26 tests.
- [x] **Completion audit cleanup.** Completed 2026-06-27T21:57:59Z. Removed a stale local `agentRunWorkflowName` definition from `Shikigami.Agent.Approval` so approval delivery and delegation both use the shared `Shikigami.Agent.Workflow.Name.agentRunWorkflowName`; extended the proof supervisor test to replay the parked parent while both delegated children are still pending and assert the same two deterministic child workflow links remain, proving the crash/restart invariant without a manual process kill. Validation: `nix develop -c cabal build all` passed, focused proof test passed, and `nix develop -c cabal test all` passed all 26 tests.

(Replace this seed list as work proceeds; split any partially done item into "done" / "remaining".)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (2026-06-27T20:34:00Z): Running `cabal build shikigami-api shikigami-core`
  directly from the ambient shell compiled the Haskell modules but failed at the linker with
  `ld: library not found for -lrdkafka`. The same build succeeded with
  `nix develop -c cabal build shikigami-api shikigami-core`, confirming the plan's Nix dev-shell
  requirement is necessary for local validation.

- Discovery (2026-06-27T20:42:54Z): `kioku-migrations/src/Kioku/Migrations.hs` embeds SQL
  migrations with Template Haskell. Adding the lineage SQL file alone did not update the embedded
  migration list; the first kioku test run applied only 23 migrations and failed with
  `column "parent_session_id" does not exist`. Touching the source binding comment rebuilt the
  embed list, after which tests saw 24 migrations and passed.

- Discovery (2026-06-27T21:40:02Z): `Keiro.Workflow.Child.spawnChild` records the parent/child
  relationship and parks the parent, but it does not run the supplied child body inline. Shikigami's
  agent-run registry drives the child later, so `delegate` must pre-seed the child workflow journal
  with the `ingest-job` `StepRecorded` entry containing the delegated `RunJob`. Without that seed,
  `agentRunWorkflow deps Nothing` has no durable job payload to replay when the child worker starts.

- Discovery (2026-06-27T21:48:51Z): The manifest behavior path is still mostly plain `IO`:
  `runBehavior` dispatches `ShikumiProgram` and `Skill` outside the `Workflow` effect, and
  `agentRunWorkflow` journals that call as the `run-behavior` step. A manifest task cannot call
  `delegate` through the generic `Handan.Task` surface yet. The M4 proof therefore adds a narrow
  workflow-aware branch for the `research-supervisor` proof task, leaving general behavior-language
  delegation for a future API extension.

- Discovery (2026-06-27T21:57:59Z): The first completion audit found `Shikigami.Agent.Approval`
  still carried its own `agentRunWorkflowName = WorkflowName "shikigami.agent-run"` constant after
  M4 introduced `Shikigami.Agent.Workflow.Name`. The duplicate had the same value, so tests passed,
  but it violated the "single constant workflow name" design. The audit cleanup removed the local
  binding and imported the shared module.


## Decision Log

Record every decision made while working on the plan.

- Decision (cross-plan coherence review, 2026-06-27): A delegated child is an instance of plan 7's
  **single** agent-run workflow `agentRunWorkflowName = WorkflowName "shikigami.agent-run"` with a
  distinct `WorkflowId` and a child `RunJob` — *not* a per-agent-named workflow. The "keyed by agent
  name" wording was corrected. Cross-noted that plan 10 also extends `TriggerKind`/`RunJob` additively.
  Rationale: The audit of plans 7–11 found this plan implied plan 7 keys its registry by agent name;
  plan 7 actually uses one constant workflow name and carries agent identity in the journaled `RunJob`.
  Pinning to plan 7's actual registry keeps the plans coherent and the child-spawn mechanism correct.
  Date: 2026-06-27

- Decision (M1 implementation, 2026-06-27): Treat `maxDelegationDepth = 4` as an exclusive
  attempted-child-depth ceiling: current depths 0, 1, and 2 may create children at depths 1, 2,
  and 3 respectively; a current depth of 3 rejects attempted depth 4 with
  `DelegationDepthExceeded 4`.
  Rationale: The plan's rationale says the four practical levels are supervisor → lead → worker
  → helper. With top-level runs at depth 0, the helper is depth 3; allowing a depth-3 run to
  create depth 4 would add a fifth level. This resolves the checklist/prose ambiguity in favor
  of the explicit "attempted depth 4 fails" validation wording.
  Date: 2026-06-27

- Decision (M2 implementation, 2026-06-27): Use `text` for `kioku_sessions.parent_session_id`
  rather than `uuid`.
  Rationale: The existing `kioku_sessions.session_id` column is `text` and all read-model encoders
  pass `SessionId` through `idText`. Matching the existing column type keeps parent lookups simple
  and avoids an artificial cast or malformed UUID assumption for TypeID-formatted session ids.
  Date: 2026-06-27

- Decision (M2 implementation, 2026-06-27): Do not rewrite shikigami's kioku dependency to a local
  filesystem path just to consume the freshly committed local kioku change.
  Rationale: `cabal.project` explicitly documents co-developed dependencies as GitHub
  `source-repository-package` pins. Pointing the committed shikigami config at a local checkout
  would make the repository non-portable. The remaining pin step should update the GitHub tag once
  `8bcfc282484dd59b0a0b25530cca4f3ad9034ce1` is available from that remote, or be changed
  deliberately with an explicit local-development override.
  Date: 2026-06-27

- Decision: Add an *imperative* `delegate` primitive alongside the existing stream coupling,
  rather than expressing delegation purely through the stream.
  Rationale: Stream coupling is loose and declarative — agent A emits, and any agent whose
  predicate matches reacts. It cannot express "run *this specific* agent on *this* input and
  give me *its* answer back," which supervisor/specialist work needs. The gap analysis
  ([`docs/architecture/evolution/agent-infrastructure-gaps.md`](../../../kikan/docs/architecture/evolution/agent-infrastructure-gaps.md)
  in the kikan repo, gap #4) classes delegation as "Partial (stream-only)" and prescribes a
  `delegate(agent, input) → awaitable`, depth-bounded. We keep the stream path untouched so
  loose coupling remains the default and delegation is an additive, opt-in capability.
  Date: 2026-06-27

- Decision: Cap delegation recursion at depth 4 (`maxDelegationDepth = 4`).
  Rationale: An agent that can delegate can delegate to an agent that delegates, so without a
  bound a buggy or adversarial declaration recurses without limit, exhausting the queue and
  the database. The TypeScript reference framework Flue (cited as prior art in the gap
  analysis) bounds sub-agent delegation at four levels; we adopt the same number for parity
  and because four levels (supervisor → lead → worker → helper) covers realistic decomposition
  while staying shallow enough to reason about. The bound is enforced in `delegate` itself, not
  left to authors.
  Date: 2026-06-27

- Decision: Represent lineage with a new `parentSessionId` (plus `delegationDepth`) on the
  kioku session, distinct from the existing `previousSessionId`.
  Rationale: kioku already chains sessions linearly with `previousSessionId`
  (`Kioku.Session.Domain.StartSessionData`), but that field means "the session that came
  *before* this one in a continuation" — a single predecessor, used for conversation/run
  continuation and traversed by `getChain`. Delegation is a *tree*: one parent fans out to
  many children, and a child is not a continuation of its parent. Overloading `previousSessionId`
  would conflate the two relationships and break `getChain`. A separate `parentSessionId` keeps
  both relationships inspectable independently. This is the kioku dependency (M2).
  Date: 2026-06-27

- Decision: Build `delegate` on keiro's child-workflow primitive
  (`Keiro.Workflow.Child.spawnChild` / `awaitChild`) rather than on a bare pgmq enqueue.
  Rationale: A bare enqueue cannot *await* — the parent would have to poll or block. keiro's
  child workflow records the spawn in the parent's journal, links parent↔child in
  `keiro_workflow_children`, and resolves the parent's `awaitChild` via a durable journaled
  step when the child completes; the whole relationship survives a crash. This requires agent
  runs to already *be* keiro workflows, which is exactly what shikigami plan 7 delivers — hence
  the hard dependency on plan 7.
  Date: 2026-06-27

- Decision (M3 implementation, 2026-06-27): Carry the current run's kioku `sessionId` in
  `DelegateCtx`, in addition to the parent lineage fields present on a delegated child.
  Rationale: `delegate` is the call site that constructs the child `RunJob`, and that job must
  include `parentSessionId = Just currentSession` before the child opens its own kioku session.
  The existing `parentSessionId` field describes this run's parent, not this run's own session, so
  reusing it would attach grandchildren to the wrong ancestor.
  Date: 2026-06-27

- Decision (M3 implementation, 2026-06-27): Seed the delegated child workflow's `ingest-job`
  journal entry immediately after `spawnChild`.
  Rationale: The agent-run workflow normally receives a `RunJob` argument only for a freshly
  invoked top-level run. A delegated child is resumed by Keiro's registry as `agentRunWorkflow deps
  Nothing`, so its `RunJob` must already be present in the child's durable journal.
  Date: 2026-06-27

- Decision (M4 implementation, 2026-06-27): Implement the proof supervisor as a named
  workflow-aware behavior branch for `ShikumiProgram { task = "research-supervisor" }`, rather
  than changing the whole `Handan.Task` API to run in `Workflow`.
  Rationale: M4 needs a real Dhall agent to demonstrate delegation, but a general workflow-capable
  behavior/task interface is larger than this plan and would affect all program and skill execution.
  The proof branch keeps the demo end to end while preserving the existing behavior runner for all
  other tasks.
  Date: 2026-06-27

- Decision (M4 implementation, 2026-06-27): Move `agentRunWorkflowName` into
  `Shikigami.Agent.Workflow.Name` and re-export it from `Shikigami.Agent.Workflow`.
  Rationale: `Shikigami.Agent.Delegate` needs the agent-run workflow name to spawn children, and
  `Shikigami.Agent.Workflow` now needs `delegate` for the proof supervisor. A tiny name module
  breaks that import cycle without changing existing callers.
  Date: 2026-06-27

- Decision (completion audit, 2026-06-27): Treat a DB-backed automated replay of the parked
  supervisor as the acceptance evidence for the crash/restart invariant.
  Rationale: The operator runbook still explains the manual kill-and-restart demonstration, but the
  durable property itself is better guarded by a deterministic test: after the supervisor first
  suspends, the test re-runs the same parent workflow before either child completes and asserts the
  `keiro_workflow_children` table still contains exactly the same two running child workflow ids.
  This models the same journal replay path a restarted worker uses and prevents regressions in CI.
  Date: 2026-06-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- Outcome (M1, 2026-06-27T20:34:00Z): The pure delegation context and additive run-job wire
  fields are in place. Existing stream and addressed-run producers continue to produce
  top-level jobs by setting the delegation fields to `Nothing`. The depth bound is covered by
  the `Delegate.Context` tasty group, and the full shikigami test suite passed in the Nix
  development environment:

```text
Delegate.Context
  checkDepth admits child depths 1 through 3:              OK
  checkDepth rejects attempted depth 4:                    OK
  checkDepth rejects deeper attempts with attempted depth:  OK

All 24 tests passed
```

- Outcome (M2a, 2026-06-27T20:42:54Z): Kioku can now record delegation lineage independently of
  `previousSessionId`. A child session row carries `parentSessionId = Just parent` and
  `delegationDepth = 1`, `getDelegationChildren parent` returns the direct children, and the old
  `getChain` query still follows only `previousSessionId`. The full kioku validation passed:

```text
Session.Lineage
  child sessions record parent id and delegation depth: OK

All 9 tests passed
```

- Outcome (M3, 2026-06-27T21:40:02Z): The Haskell primitive exists and is covered by a durable
  parent/child workflow test. A parent can call `delegate`, suspend on `awaitDelegated`, have the
  child driven through `agentRunWorkflow`, and then resume with the child's `behaviorOutput`. The
  full shikigami suite passed after the implementation and record-pattern cleanup:

```text
AgentWorkflow
  Delegate
    parent suspends awaiting delegated child and resumes with child output: OK

All 25 tests passed
```

- Outcome (M4, 2026-06-27T21:48:51Z): The proof manifests exercise delegation through real agent
  declarations. The `research-supervisor` manifest fans out to `web-researcher` and
  `code-researcher`, awaits both child runs, synthesizes their fixed findings, and records child
  kioku sessions with `parentSessionId = Just supervisorSession` and `delegationDepth = 1`.
  Focused validation passed:

```text
AgentWorkflow
  Delegate
    proof supervisor fans out to specialists and records lineage: OK

All 26 tests passed
```

- Outcome (completion audit, 2026-06-27T21:57:59Z): The implementation now has direct evidence for
  every acceptance item. The final proof supervisor test covers fan-out, parent suspension, parent
  replay while children remain pending without duplicate child workflow links, child completion,
  parent synthesis, and kioku lineage. The duplicate workflow-name constant in approval delivery was
  removed so every caller uses the shared constant.

```text
AgentWorkflow
  Delegate
    proof supervisor fans out to specialists and records lineage: OK

All 26 tests passed
```


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

### What this repository is

`shinzui/shikigami` (working tree at `/Users/shinzui/Keikaku/bokuno/shikigami`) is a
declarative agent runtime written in Haskell. An "agent" is a unit of automated work declared
in a Dhall configuration file under `agents/` (Dhall is a typed configuration language; a
`.dhall` file evaluates to a typed record). Each agent declares a **trigger** (when it should
run) and a **behavior** (what it does when it runs). The repo is split into cabal packages:

- `shikigami-api` — client-safe types shared by producers and consumers (no database deps).
  The run-job contract lives in `shikigami-api/src/Shikigami/Api/RunJob.hs`.
- `shikigami-core` — the runtime: trigger evaluation, the worker, the behavior runner, sinks,
  and the kioku session/memory integration. This is where most new code lands.
- `shikigami-cli` — the `shikigami` executable (`worker`, `enqueue-run`, `consume-stream`, …).
- `shikigami-migrations` — the database schema (codd migrations + the embedded kiroku schema).

Build with `cabal build all`; tests are a tasty suite named `shikigami-core-test`
(declared in `shikigami-core/shikigami-core.cabal`), run with `cabal test all`. Database setup
is `just create-database` then `just migrate`, run inside the nix dev shell with Postgres up
(`process-compose up`). All commands below are run from the repo root unless stated otherwise.

### How a run happens today

A fired trigger becomes a **run job** — a `RunJob` record
(`shikigami-api/src/Shikigami/Api/RunJob.hs`) carrying `agentName`, a `triggerKind`
(`TriggeredBySchedule | TriggeredByStream | TriggeredByEvent`), the `triggerPayload`, and an
`idempotencyKey`. Run jobs are enqueued onto a **pgmq** queue named `shikigami_run_jobs`
(pgmq is a Postgres-backed message queue). The producer side is
`shikigami-core/src/Shikigami/Trigger/Enqueue.hs` (`enqueueRunJob`, `enqueueAddressedRun`,
`runJobFromEnvelope`). The consumer side is the **worker**
(`shikigami-core/src/Shikigami/Worker.hs`): a `shibuya` `QueueProcessor` (shibuya is this
portfolio's supervised concurrent queue-processing library) that drains `shikigami_run_jobs`
with up to 100 concurrent jobs and, for each job, returns an `AckDecision`
(`AckOk` removes the message, `AckRetry` redelivers after a delay, `AckDeadLetter` parks a
poison message). For each job the worker calls
`Shikigami.Agent.Run.runAgentWithMemory` (`shikigami-core/src/Shikigami/Agent/Run.hs`), which
opens a **kioku session**, runs the behavior via `Shikigami.Behavior.Run.runBehavior`, records
the output as a kioku memory, completes the session, and then dispatches the agent's sinks.

Crucially, **the behavior runs to completion inside the handler** — it cannot pause. There is
no suspend/resume today. That is the limitation plan 7 removes (see Dependencies below).

### Define: "stream coupling" vs "delegation"

**Stream coupling** is the *only* coordination model agents have today, documented in
`docs/user/living-loop.md`. It works like this: agent A produces a result whose **sink** is a
`KawaDigest` (kawa is the activity-ingest service); that digest reappears on the
`activity.v1` stream; the `consume-stream` consumer matches the digest against every declared
**Stream** agent's predicate and enqueues a run job for each match; the worker then runs those
agents. The coupling is *loose* (A does not name B; B simply declares a predicate that happens
to match) and *declarative* (the wiring is in each agent's trigger, not in code). A never
learns B's result. This is excellent for open-ended, fan-out reactions and we keep it exactly
as is.

**Delegation** (this plan) is the opposite shape: *tight* and *imperative*. A parent run, in
the middle of its behavior, explicitly names a child agent and an input, starts that child as
its own run, **suspends** until the child finishes, and then receives the child's result value
back to continue with. "Suspend" here is durable: the parent's progress is journaled to the
database and the in-memory computation is unwound, so a suspended parent occupies no thread and
survives a crash; "resume" replays the journal and continues past the await. We add delegation
*alongside* stream coupling, not as a replacement.

### Terms of art used below

- **keiro workflow** — `shinzui/keiro` (`/Users/shinzui/Keikaku/bokuno/keiro`) is this
  portfolio's event-sourcing + durable-workflow engine. A *workflow* is an ordinary
  `effectful` computation run with `Keiro.Workflow.runWorkflow`; each `step name action` is
  journaled to a kiroku stream named `wf:<name>-<id>`, and on replay a journaled step returns
  its recorded result *without* re-running the side effect. A workflow can pause at an
  unresolved `awaitStep`, in which case `runWorkflow` returns `Suspended` instead of
  `Completed`. The authoring surface is the `Workflow` effect in
  `keiro/src/Keiro/Workflow.hs`.
- **child workflow** — `keiro/src/Keiro/Workflow/Child.hs` lets one workflow (the *parent*)
  spawn another (the *child*) and await its result durably. `spawnChild name wid def` records a
  `child:<childId>` step in the parent journal and a `running` row in
  `keiro_workflow_children`, then returns a `ChildHandle`. `awaitChild handle` is
  `awaitStep "child:<childId>:result"` — it suspends the parent until the child completes, then
  decodes and returns the child's result (or throws `WorkflowChildCancelled` /
  `WorkflowChildFailed`). The child is **not** run inline: the resume worker drives it from a
  `WorkflowRegistry` keyed by `WorkflowName`, so **a child's workflow name must be registered
  there**.
- **durable await** — the suspend-then-resume behavior above: the parent parks on
  `keiro_workflow_children` + its journal, not on a live thread.
- **lineage** — the recorded provenance linking a child run back to its parent run. kioku
  sessions already chain linearly via `previousSessionId`
  (`Kioku.Session.Domain` at `/Users/shinzui/Keikaku/bokuno/kioku/kioku-core/src/Kioku/Session/Domain.hs`);
  delegation needs a *tree* link, added as `parentSessionId` (M2).
- **depth bound** — a cap on how deep delegation may recurse, here `maxDelegationDepth = 4`.

### The keystone dependency (plan 7)

This plan **requires** the checked-in plan
[`docs/plans/7-agent-runs-as-durable-keiro-workflows.md`](7-agent-runs-as-durable-keiro-workflows.md)
("Agent runs as durable keiro workflows"). Plan 7 re-platforms the worker's behavior execution
from "run to completion inside the shibuya handler" onto a keiro workflow, so that a run gains
suspend/resume, a journal, and a `WorkflowRegistry`. Delegation's durable await is built
directly on that: `delegate` calls `spawnChild` and `awaitDelegated` calls `awaitChild`, both
of which only work *inside* a `Workflow` effect. Until plan 7 lands, the agent run is plain `IO`
(`runAgentWithMemory` returns `IO (Either Text AgentRunResult)`), which cannot suspend. The
milestones below are written so that M1 and M2 (the pure context, the depth bound, and the
kioku lineage fields) can proceed *before* plan 7 completes, while M3 and M4 (the `delegate`
primitive and the end-to-end demo) consume plan 7's workflow runner and registry. If plan 7 is
not yet merged when you reach M3, implement plan 7 first.


## Plan of Work

The work is four milestones. M1 and M2 are pure/additive and can land before plan 7; M3 wires
the primitive onto plan 7's workflow runner; M4 proves it end to end.

### Milestone 1 — Delegation context and depth bound (pure core)

**Scope.** Establish the data and the safety bound before any keiro wiring, so the depth cap
is testable in isolation. At the end there is a new module `Shikigami.Agent.Delegate.Context`
(new file `shikigami-core/src/Shikigami/Agent/Delegate/Context.hs`) and an extended `RunJob`.

Add to `Shikigami.Agent.Delegate.Context`:

- `data DelegateCtx = DelegateCtx { delegateDepth :: !Int, parentSessionId :: !(Maybe Text), parentRunWorkflowId :: !(Maybe Text) }` — the context a run carries so it knows how deep it already is and who its parent is. A top-level (non-delegated) run has `DelegateCtx 0 Nothing Nothing`.
- `maxDelegationDepth :: Int` = `4` (with a Haddock comment citing Flue's four-level limit as prior art).
- `data DelegationError = DelegationDepthExceeded !Int` (the attempted depth) `deriving stock (Eq, Show)` and an `Exception` instance.
- `checkDepth :: DelegateCtx -> Either DelegationError DelegateCtx` — returns the *child's* context (`delegateDepth + 1`, with `parentSessionId`/`parentRunWorkflowId` filled by the caller in M3) when `delegateDepth < maxDelegationDepth`, else `Left (DelegationDepthExceeded (delegateDepth + 1))`.

Extend `shikigami-api/src/Shikigami/Api/RunJob.hs`:

- Add constructor `TriggeredByDelegation` to `TriggerKind` (it already derives `ToJSON`/`FromJSON` generically, so this is additive and forward-compatible — older readers simply never see it).
- Add three optional fields to `RunJob`: `parentSessionId :: !(Maybe Text)`, `parentRunWorkflowId :: !(Maybe Text)`, `delegationDepth :: !(Maybe Int)`. They are `Maybe` so existing producers (`runJobFromEnvelope`, `enqueueAddressedRun` in `Shikigami/Trigger/Enqueue.hs`) keep compiling by passing `Nothing`; update those two producers to set the new fields to `Nothing` explicitly.

Coherence note (cross-plan review): plan 10 (`docs/plans/10-timer-driven-schedules-mid-run-resume-and-run-tracing.md`)
*also* extends this same `TriggerKind` sum (adding `TriggeredBySchedule`). Both edits are additive and
independent; whichever lands second adds its constructor alongside the other's. Expect to find the other
plan's constructor already present in `shikigami-api/src/Shikigami/Api/RunJob.hs`.

**Verify.** `cabal build all` compiles. Add a tasty test group `Delegate.Context` to the
`shikigami-core-test` suite asserting `checkDepth` succeeds for `delegateDepth` 0..3 and fails
with `DelegationDepthExceeded 4` at `delegateDepth = 3`'s ceiling and beyond. `cabal test all`
is green.

### Milestone 2 — kioku parent/child lineage (the kioku dependency)

**Scope.** Make a delegated run's provenance inspectable by giving kioku sessions a parent link
and a depth, distinct from the existing linear `previousSessionId`. This milestone edits the
`shinzui/kioku` repository at `/Users/shinzui/Keikaku/bokuno/kioku`, not shikigami. At the end a
session row carries `parent_session_id` and `delegation_depth`, and there is a query returning a
parent's direct children.

Edits in `kioku-core/src/Kioku/Session/Domain.hs`:

- Add `parentSessionId :: !(Maybe SessionId)` and `delegationDepth :: !Int` to `StartSessionData` and to the wire event payload `SessionStartedData` (which already derives `FromJSON`/`ToJSON`). Thread both through the `StartSession` arm of `sessionTransducer` into the emitted `SessionStartedTermFields` (extend the term fields record accordingly). Keep `previousSessionId` exactly as is — these are independent fields.
- A new event field on an event-sourced aggregate is additive: old journaled `SessionStarted` events lack the field. Give `delegationDepth` a default of `0` and `parentSessionId` a default of `Nothing` in the `FromJSON` instance (or make the wire field optional) so historical events still decode. Note this explicitly in the kioku PR.

Edits in `kioku-core/src/Kioku/Session/ReadModel.hs`:

- Add `parentSessionId :: !(Maybe Text)` (already present pattern: `previousSessionId` is `Maybe Text` here) and `delegationDepth :: !Int` to `SessionRow`, populate them in the inline projection, and add the columns to the read-model schema/migration.
- Add `SessionDelegationChildrenQuery` + `getDelegationChildren :: SessionId -> Eff es (Either ... [SessionRow])` returning every session whose `parent_session_id` equals the given id (mirror the existing `SessionChainQuery` / `getChain` shape, but match on `parent_session_id` instead of walking `previous_session_id`).

Edits in `Kioku.Session` (`kioku-core/src/Kioku/Session.hs`): export `getDelegationChildren` and
the new query type.

Add a kioku migration adding the `parent_session_id uuid NULL` and
`delegation_depth int NOT NULL DEFAULT 0` columns to the sessions read-model table.

**Verify.** In the kioku repo, `cabal build all` and `cabal test all`. Add a kioku test that
starts a parent session and two child sessions with `parentSessionId = Just parent` /
`delegationDepth = 1`, then asserts `getDelegationChildren parent` returns exactly those two and
`getChain` is unaffected. (If kioku's actual module layout differs from the paths above, adapt
to the real layout; the contract that matters is: a session can record its parent and depth, and
children are queryable by parent.)

### Milestone 3 — the `delegate` primitive over keiro child workflows

**Scope.** Add the imperative primitive. This milestone consumes plan 7: it assumes agent runs
now execute inside a `Keiro.Workflow.Workflow` effect and that the resume worker drives runs from
a `WorkflowRegistry`. At the end a behavior running inside a run-workflow can `delegate` to
another agent and `awaitDelegated` its result, with the parent suspending durably.

New module `Shikigami.Agent.Delegate`
(`shikigami-core/src/Shikigami/Agent/Delegate.hs`):

```haskell
-- | A pending delegated child run; @a@ is the child's result type.
newtype Delegated a = Delegated (Keiro.Workflow.Child.ChildHandle a)

-- | Start @childAgent@ as a child run of the current run, returning a handle.
-- Enforces the depth bound (throws 'DelegationDepthExceeded' when the child
-- would exceed 'maxDelegationDepth'). Does NOT block: the child is driven by
-- the resume worker; call 'awaitDelegated' to get its result.
delegate ::
  (Keiro.Workflow.Workflow :> es, Kiroku.Store.Effect.Store :> es, IOE :> es) =>
  DelegateCtx ->          -- the current run's delegation context (depth, parent ids)
  Text ->                 -- the child agent's declared name
  Aeson.Value ->          -- the input payload handed to the child run
  Eff es (Delegated Aeson.Value)

-- | Suspend the parent run until the delegated child completes, then return its
-- result. On a crash/replay the parent resumes here without re-running the child.
awaitDelegated ::
  (Keiro.Workflow.Workflow :> es, Kiroku.Store.Effect.Store :> es, IOE :> es, Aeson.FromJSON a) =>
  Delegated a ->
  Eff es a
```

Implementation notes:

- `delegate` first calls `checkDepth ctx` (M1); on `Left` it throws `DelegationDepthExceeded`.
- It derives a **replay-stable** child workflow id so a parent replay re-spawns the *same*
  child rather than a fresh one. Use the parent run's identity plus a per-call ordinal:
  `freshOrdinal "delegate"` from `Keiro.Workflow`, combined with the child agent name and the
  parent's `WorkflowId` from `currentWorkflow`, hashed into a deterministic `WorkflowId`
  (mirror keiro's `deterministicJournalId` v5-UUID approach). Document that `freshOrdinal` is
  only stable if the order of `delegate` calls is stable across deploys (true for our fixed
  supervisor bodies).
- The child run's input — the payload, the child's `DelegateCtx` (depth+1, `parentSessionId` =
  this run's session id, `parentRunWorkflowId` = this run's workflow id) — is carried into the
  child workflow. Encode it as the child's `RunJob` (the M1-extended record with
  `TriggeredByDelegation` and the delegation fields). The child workflow body is plan 7's
  agent-run workflow, which on start opens its kioku session passing `parentSessionId` /
  `delegationDepth` from the `RunJob` (so M2's lineage is recorded).
- `delegate` calls `Keiro.Workflow.Child.spawnChild childWfName childWfId childDef`, where
  `childWfName` is the run-workflow name plan 7 uses for an agent run (so the child resolves in
  the registry), and returns `Delegated handle`.
- `awaitDelegated (Delegated h)` = `Keiro.Workflow.Child.awaitChild h`, catching
  `WorkflowChildFailed` / `WorkflowChildCancelled` and re-surfacing them as a delegation-level
  error the supervisor body can handle (e.g. record a failed sub-result and continue).

Registry wiring: ensure the agent-run workflow name is registered in plan 7's
`WorkflowRegistry` (the resume worker's source of truth), because `spawnChild` does not run the
child inline — the resume worker does, keyed by `WorkflowName`. Plan 7 registers exactly one
"run an agent" workflow under a **single constant name** `agentRunWorkflowName = WorkflowName "shikigami.agent-run"`
(the agent's identity is *not* the workflow name — it is carried inside the child's `RunJob`, which
plan 7's workflow reads in its `ingest-job`/`lookup-agent` steps). A delegated child is therefore
another instance of that same `agentRunWorkflow` with a **different `WorkflowId`** (deterministically
derived from the parent's workflow id, the child agent name, and a `freshOrdinal "delegate"` counter)
and a child `RunJob` naming the child agent. Reuse plan 7's `agentRunRegistry`; do not register a new
per-agent workflow name.

**Verify.** `cabal build all`. Add a tasty integration test (in `shikigami-core-test`, gated on
a test Postgres like the other DB tests) that runs a tiny supervisor workflow which `delegate`s
to a trivial child workflow and `awaitDelegated`s it: assert the first `runWorkflow` returns
`Suspended` (parent parked on the child), then drive the child to completion via
`Keiro.Workflow.Child.runChildWorkflow`, then re-run the parent and assert it returns
`Completed` with the child's result. Also assert a depth-5 attempt throws
`DelegationDepthExceeded`.

### Milestone 4 — end-to-end supervisor demo, crash/resume, lineage inspection

**Scope.** Prove the user-visible behavior from Purpose with real agents and the real worker. At
the end there are three new Dhall agents under `agents/proof/` and a documented runbook.

Add `agents/proof/research-supervisor.dhall` (a Skill or ShikumiProgram behavior that, in its
body, calls `delegate` twice — to `web-researcher` and `code-researcher` — then `awaitDelegated`
on both and synthesizes a combined result), and the two specialist agents
`agents/proof/web-researcher.dhall` and `agents/proof/code-researcher.dhall` (trivial behaviors
returning a stub finding). Extend `docs/user/living-loop.md` with a short "Delegation" section
documenting the runbook (it currently documents only stream coupling).

**Verify.** The full acceptance scenario in "Validation and Acceptance": enqueue the supervisor,
watch the worker log show suspend → two children run → resume → synthesized output; query kioku
for the parent/child rows with correct `parent_session_id` and `delegation_depth`; kill the
worker mid-delegation and restart it and observe the parent resume rather than restart.


## Concrete Steps

All commands run from the shikigami repo root `/Users/shinzui/Keikaku/bokuno/shikigami` inside
the nix dev shell, except the M2 commands which run from the kioku repo root
`/Users/shinzui/Keikaku/bokuno/kioku`. Enter the dev shell first:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
nix develop        # or: direnv allow, if .envrc is present
```

### M1 — context + depth bound

```bash
# Create the new module and extend RunJob (edits per "Plan of Work").
$EDITOR shikigami-core/src/Shikigami/Agent/Delegate/Context.hs
$EDITOR shikigami-api/src/Shikigami/Api/RunJob.hs
$EDITOR shikigami-core/src/Shikigami/Trigger/Enqueue.hs   # pass Nothing for new fields
# Remember to add the new module to shikigami-core.cabal `exposed-modules`.
cabal build all
cabal test all
```

Expected (tail of `cabal test all`):

```text
Delegate.Context
  checkDepth admits depth 0..3:      OK
  checkDepth rejects depth 4:        OK
All N tests passed
```

### M2 — kioku lineage (in the kioku repo)

```bash
cd /Users/shinzui/Keikaku/bokuno/kioku
$EDITOR kioku-core/src/Kioku/Session/Domain.hs       # add parentSessionId, delegationDepth
$EDITOR kioku-core/src/Kioku/Session/ReadModel.hs    # add fields + getDelegationChildren
$EDITOR kioku-core/src/Kioku/Session.hs              # export getDelegationChildren
# add a migration adding parent_session_id + delegation_depth columns
cabal build all
cabal test all
```

Expected:

```text
Session.Lineage
  child sessions record parent id + depth:  OK
  getDelegationChildren returns both:       OK
  getChain unaffected by parent link:       OK
All M tests passed
```

After kioku is updated, if shikigami pins kioku by a local path or revision, update that pin so
shikigami picks up the new `StartSessionData` fields.

### M3 — the delegate primitive (requires plan 7 merged)

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
$EDITOR shikigami-core/src/Shikigami/Agent/Delegate.hs      # delegate / awaitDelegated
# add Shikigami.Agent.Delegate to shikigami-core.cabal exposed-modules
# in Shikigami/Agent/Run.hs (plan 7's workflow version): pass parentSessionId/
# delegationDepth from the RunJob into StartSessionData when opening the session.
cabal build all
# DB-backed integration test (needs Postgres up + migrated):
process-compose up &        # postgres
just create-database
cabal test all
```

Expected (the delegation integration group):

```text
Delegate.Workflow
  parent suspends awaiting child:    OK
  parent resumes with child result:  OK
  depth-5 delegate throws:           OK
```

### M4 — end-to-end demo

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
# Author the three agents.
$EDITOR agents/proof/research-supervisor.dhall
$EDITOR agents/proof/web-researcher.dhall
$EDITOR agents/proof/code-researcher.dhall

# Bring up the database and the worker (the worker now drives runs as keiro
# workflows and the resume worker drives child runs — both per plan 7).
process-compose up &
just create-database
cabal run shikigami -- worker --agents agents \
  --kawa-url http://localhost:8088 --kizashi-url http://localhost:8089 &

# Trigger the supervisor directly (the addressed/event path, no broker needed).
cabal run shikigami -- enqueue-run research-supervisor --payload '{"topic":"durable workflows"}'
```

Expected worker log (abridged; ids will differ):

```text
[shikigami.worker] agent=research-supervisor session=<sup> -> Suspended (awaiting 2 children)
[shikigami.worker] agent=web-researcher    session=<c1> parent=<sup> depth=1 -> AckOk
[shikigami.worker] agent=code-researcher   session=<c2> parent=<sup> depth=1 -> AckOk
[shikigami.worker] agent=research-supervisor session=<sup> -> AckOk (resumed; synthesized 2 findings)
```

Inspect lineage in Postgres:

```bash
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "SELECT id, agent_id, parent_session_id, delegation_depth
     FROM kioku_sessions ORDER BY started_at;"
```

```text
        id        |       agent_id       | parent_session_id | delegation_depth
------------------+----------------------+-------------------+------------------
 <sup>            | research-supervisor  |                   |                0
 <c1>             | web-researcher       | <sup>             |                1
 <c2>             | code-researcher      | <sup>             |                1
```

(The exact table/column names follow kioku's read model from M2; adjust if they differ.)


## Validation and Acceptance

The change is accepted when all four behaviors below are observable. Each is phrased as an input
and the output to look for, beyond mere compilation.

**A1 — depth bound (unit, no database).** Run `cabal test all` in the shikigami repo. The
`Delegate.Context` group passes: `checkDepth` returns a `delegateDepth = n+1` context for inputs
0..3 and throws/returns `DelegationDepthExceeded 4` once the next step would reach depth 4. This
proves a misconfigured recursive delegation cannot run unbounded.

**A2 — durable suspend/resume (integration).** Run `cabal test all` with Postgres up. The
`Delegate.Workflow` group passes: a supervisor workflow that `delegate`s to one child and
`awaitDelegated`s it returns `Suspended` on its first `runWorkflow` (the parent parked, no thread
blocked); after the child is driven to `Completed`, re-running the parent returns
`Completed result` carrying the child's value. This proves the await is durable rather than a
blocking call.

**A3 — supervisor fan-out and synthesis (end-to-end).** Follow M4's Concrete Steps manually, or
run `nix develop -c cabal test shikigami-core-test --test-option -p --test-option "proof supervisor fans out"`.
The proof test loads `agents/proof/research-supervisor.dhall`,
`agents/proof/web-researcher.dhall`, and `agents/proof/code-researcher.dhall`; runs the
supervisor to `Suspended`; drives the two child agent-run workflows; then resumes the supervisor
and asserts its synthesized output references *both* findings. This proves an agent can commission
specific specialists and consume their results — the capability that did not exist before.

**A4 — lineage is inspectable.** After the manual A3 run, use the `psql` query in Concrete Steps;
or rely on the proof supervisor test's `Session.getDelegationChildren parentSession` assertion.
The evidence must show the supervisor row with no parent and `delegation_depth 0`, and both child
rows with `parent_session_id = <sup>` and `delegation_depth 1`. This proves a delegated run's
provenance is recorded and queryable.

**A5 — crash mid-delegation resumes (the keystone proof).** The manual runbook remains: after the
supervisor logs `Suspended` but before both children finish, kill the worker process, restart it
with the same `worker` command, and observe that the parent resumes rather than starts over. The
CI-grade proof is the replay assertion inside the proof supervisor test: after the first
`Suspended`, it re-runs the same parent workflow while both child links are still `running` and
asserts the `keiro_workflow_children` table still contains exactly the same two deterministic
child workflow ids. This models the same journal replay path a restarted worker uses and proves a
long delegation survives a crash without duplicating delegated children.

Acceptance = A1 and A2 green in CI, plus A3, A4, and A5 either demonstrated manually per the
runbook or proven by the DB-backed proof supervisor test and captured in the Outcomes section.


## Idempotence and Recovery

Every step here is designed to be re-runnable.

**Builds and tests** (`cabal build all`, `cabal test all`) are naturally idempotent. The kioku
migration (M2) adds columns with `IF NOT EXISTS`-style codd semantics and a `DEFAULT 0` /
`NULL` default, so applying it twice is a no-op and existing session rows backfill to depth 0 /
no parent. Re-running `just migrate` is safe (codd records applied migrations and skips them).

**The delegate primitive is idempotent by construction**, because it is built on keiro's
journaled steps:

- `spawnChild` records a `child:<childId>` step in the parent journal and an
  `ON CONFLICT DO NOTHING` row in `keiro_workflow_children`; a parent replay short-circuits the
  spawn and never re-spawns. The child workflow id is derived deterministically (parent id +
  ordinal + child agent name), so even across a crash the *same* child id is produced — a
  re-spawn attaches to the existing child rather than starting a second one (this is exactly
  what A5 verifies).
- `awaitChild` is `awaitStep` on `child:<childId>:result`: on resume it re-runs only an
  idempotent arming check and either re-suspends (child still running) or decodes the journaled
  result (child finished). It never double-consumes a result.
- Workflow step side effects are **at-least-once** at the step boundary (keiro's documented
  contract): if the process crashes after a step's action runs but before its journal append
  commits, the action runs again on resume. The child agent run's own steps must therefore be
  idempotent — which they already are under plan 7, and the run-job `idempotencyKey`
  (`Shikigami.Api.RunJob`) plus kioku's `Session.start` early-return on an existing session id
  (`Kioku.Session.start` returns the existing id rather than re-starting) guard against a
  doubled child run.

**Recovery.** If a delegation wedges (a child neither completes nor fails), the operator can
`Keiro.Workflow.Child.cancelChild` the child handle, which flips the child row to `cancelled` and
writes the parent's await-step sentinel so `awaitDelegated` throws `WorkflowChildCancelled` and
the supervisor body runs its compensation path. To abandon the whole experiment, drop the test
database (`dropdb`/`just`); no destructive change is made to production data.

**Rollback.** All shikigami changes are additive (a new module, three new optional `RunJob`
fields, a new `TriggerKind` constructor). Reverting the M3/M4 commits removes the primitive and
the demo agents without affecting stream coupling. The M1 `RunJob` fields are `Maybe`/additive,
so even a partial revert leaves the wire format readable.


## Interfaces and Dependencies

### Libraries and services consumed

- **`shinzui/keiro`** (`/Users/shinzui/Keikaku/bokuno/keiro`) — the durable workflow engine.
  Used modules:
  - `Keiro.Workflow` (`keiro/src/Keiro/Workflow.hs`): the `Workflow` effect, `step`,
    `awaitStep`, `currentWorkflow`, `freshOrdinal`, `runWorkflow` / `runWorkflowWith`, and
    `data WorkflowOutcome = Completed a | Suspended | Cancelled | Failed | ContinuedAsNew`.
  - `Keiro.Workflow.Child` (`keiro/src/Keiro/Workflow/Child.hs`): the child-workflow surface —
    `data ChildHandle a = ChildHandle { childName :: WorkflowName, childWfId :: WorkflowId }`,
    `spawnChild :: (Workflow :> es, Store :> es) => WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (ChildHandle a)`,
    `awaitChild :: (Workflow :> es, Store :> es, IOE :> es, FromJSON a) => ChildHandle a -> Eff es a`,
    `cancelChild`, `runChildWorkflow` (used by the resume worker to drive children), and the
    exceptions `WorkflowChildCancelled` / `WorkflowChildFailed`.
- **`shinzui/kioku`** (`/Users/shinzui/Keikaku/bokuno/kioku`) — session + memory. Used:
  `Kioku.Session` (`start`, `complete`, `failSession`, `getChain`, and the new
  `getDelegationChildren`), `Kioku.Session.Domain` (`StartSessionData`, `SessionStartedData`),
  `Kioku.Session.ReadModel` (`SessionRow`). M2 extends these with `parentSessionId` and
  `delegationDepth`.
- **`shinzui/shibuya`** (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`) — the
  supervised queue processor the worker is built on (`Shibuya.App`, `Shibuya.Core.Ack`). The
  pgmq queue `shikigami_run_jobs` is the dispatch substrate for run jobs, including delegated
  ones. No change to shibuya itself.
- **pgmq / Postgres** — the message queue and the durable store under both kioku sessions and
  keiro journals.

### Cross-plan dependencies

- **shikigami repo, plan 7 "Agent runs as durable keiro workflows"**
  ([`docs/plans/7-agent-runs-as-durable-keiro-workflows.md`](7-agent-runs-as-durable-keiro-workflows.md))
  — **REQUIRED (keystone).** Provides: agent runs that execute inside the `Keiro.Workflow`
  effect (so `delegate`/`awaitDelegated` can call `spawnChild`/`awaitChild` at all), the
  durable await substrate (suspend/resume), and the resume worker's `WorkflowRegistry` keyed by
  `WorkflowName` (so a spawned child resolves and is driven to completion). M3 and M4 cannot be
  implemented until plan 7 is merged; M1 and M2 can proceed before it.
- **kioku repo, lineage work** — the M2 edits above are a dependency on kioku. The existing
  `previousSessionId` (linear chaining) is **insufficient** for delegation because delegation is
  a tree (one parent, many children) and a child is not a continuation of its parent; a new
  `parentSessionId` + `delegationDepth` is required. Treat M2 as a kioku change that must land
  (and be re-pinned) before shikigami M3 records lineage.

### Interfaces that must exist at each milestone's end

End of **M1** — in `Shikigami.Agent.Delegate.Context`
(`shikigami-core/src/Shikigami/Agent/Delegate/Context.hs`):

```haskell
data DelegateCtx = DelegateCtx
  { delegateDepth        :: !Int
  , parentSessionId      :: !(Maybe Text)
  , parentRunWorkflowId  :: !(Maybe Text)
  }

maxDelegationDepth :: Int            -- = 4 (Flue prior art)
data DelegationError = DelegationDepthExceeded !Int
checkDepth :: DelegateCtx -> Either DelegationError DelegateCtx
```

and in `Shikigami.Api.RunJob` (`shikigami-api/src/Shikigami/Api/RunJob.hs`): `TriggerKind`
gains `TriggeredByDelegation`; `RunJob` gains `parentSessionId :: Maybe Text`,
`parentRunWorkflowId :: Maybe Text`, `delegationDepth :: Maybe Int`.

End of **M2** — in kioku: `StartSessionData` and `SessionStartedData` carry
`parentSessionId :: Maybe SessionId` and `delegationDepth :: Int`; `SessionRow` carries
`parentSessionId :: Maybe Text` and `delegationDepth :: Int`;
`getDelegationChildren :: SessionId -> Eff es (Either SessionWriteError [SessionRow])` is
exported from `Kioku.Session`.

End of **M3** — in `Shikigami.Agent.Delegate`
(`shikigami-core/src/Shikigami/Agent/Delegate.hs`):

```haskell
newtype Delegated a = Delegated (Keiro.Workflow.Child.ChildHandle a)

delegate ::
  (Keiro.Workflow.Workflow :> es, Kiroku.Store.Effect.Store :> es, IOE :> es) =>
  DelegateCtx -> Text -> Aeson.Value -> Eff es (Delegated Aeson.Value)

awaitDelegated ::
  (Keiro.Workflow.Workflow :> es, Kiroku.Store.Effect.Store :> es, IOE :> es, Aeson.FromJSON a) =>
  Delegated a -> Eff es a
```

and `Shikigami.Agent.Run` (plan 7's workflow version) passes `parentSessionId` /
`delegationDepth` from the `RunJob` into `Kioku.Session.Domain.StartSessionData` when opening
the run's session.

End of **M4** — three Dhall agents under `agents/proof/`
(`research-supervisor.dhall`, `web-researcher.dhall`, `code-researcher.dhall`) and a
"Delegation" section in `docs/user/living-loop.md`.


## Revision Notes

- 2026-06-27 — **Cross-plan coherence pass (plans 7–11).** Corrected the registry-wiring description:
  a delegated child is an instance of plan 7's single constant workflow `WorkflowName "shikigami.agent-run"`
  with a distinct `WorkflowId` and a child `RunJob` (agent identity travels in the job, not the workflow
  name), not a per-agent-named workflow. Added a cross-note that plan 10 also extends
  `TriggerKind`/`RunJob` additively in `shikigami-api/src/Shikigami/Api/RunJob.hs`. Reason: the audit
  found this plan mis-described plan 7's registry keying; the rest of plan 9's design (the `delegate`/
  `awaitDelegated` primitives over `spawnChild`/`awaitChild`, the kioku lineage fields) was already
  coherent with plan 7 and is unchanged.
- 2026-06-27 — **Completion audit evidence update.** Recorded the final shared workflow-name cleanup
  and the automated pending-child replay assertion added to the proof supervisor test. Reason: the
  audit found the code met the main delegation behavior, but the plan's A5 crash/restart claim needed
  stronger current-state evidence than the runbook alone.
- 2026-06-27 — **Validation criteria alignment.** Updated A3-A5 to accept the DB-backed proof
  supervisor test as evidence alongside the manual runbook. Reason: the implementation now proves
  fan-out, lineage, and pending-child replay deterministically in CI, so the acceptance text must
  match the current verified evidence.
