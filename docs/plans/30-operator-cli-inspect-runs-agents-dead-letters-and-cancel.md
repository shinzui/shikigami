---
id: 30
slug: operator-cli-inspect-runs-agents-dead-letters-and-cancel
title: "Operator CLI: inspect runs, agents, dead letters, and cancel"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tyx3yehmsq9eyywdcf5c7"
master_plan: "docs/masterplans/6-operations-and-observability-run-shikigami-as-a-real-service.md"
---

# Operator CLI: inspect runs, agents, dead letters, and cancel

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

**This plan was refreshed on 2026-08-19 and it changed shape, not just citations.** Keiro now
ships an operational console — `keiro-ops 0.13.0.0`, released on Hackage, with an explicit
embedding boundary — that owns most of what Milestones 2, 3, and 4 were going to hand-build, and
a Keiro ADR forbids the raw-SQL approach those milestones specified. This plan becomes "mount the
console and add the three things only Shikigami can own." See the Revision Note of 2026-08-19.


## Purpose / Big Picture

An operator of shikigami today cannot answer basic questions from the command line. There is no
way to list the declared agents and their load state, no way to list or inspect runs (an agent run
is a keiro workflow plus a kioku session), no way to cancel a stuck run, no tooling for
dead-lettered jobs, and no way to see the outbox's pending or dead-lettered sink intents. The
`shikigami` administrative binary has seven subcommands
(`shikigami-server/src/Shikigami/Server/Command.hs:98-107`) — `validate`, `render-lifecycle`,
`enqueue-run`, `publish-fixture`, `stub-kawa`, `danwa-spike`, `grants` — and only `grants` is an
inspection-and-control verb. When a workflow is stuck, the run-job worker handles a `Cancelled`
outcome (`shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs:235-245`), but nothing in
shikigami can *issue* a cancel.

After this plan, an operator has a read-mostly, safe-by-default surface with two halves.

The **substrate half** comes from `keiro-ops`, mounted into the `shikigami` binary as a command
group. That is where `workflow list|show|steps|journal|awakeable|cancel|resurrect|lease|gc` lives,
where `outbox backlog|list|show|requeue-stuck|gc-sent|maintenance-pass|dead-letters list` lives,
and where `pgmq dlq read|redrive|archive|purge` lives — over the real
`shikigami_run_jobs_dlq` that plan 17 configured. Every one of those is a thin adapter over an
exported Keiro operation, every mutating one previews by default and acts only under `--force`,
and none of them is code this repository has to write, test, or keep in step with Keiro's schema.

The **Shikigami half** is what `keiro-ops` cannot know: `shikigami agents list`, which renders the
declared-agent load report including manifests that failed to parse and agents that are disabled;
and `shikigami runs show`, which joins a keiro workflow instance to its kioku session so an
operator sees the agent, the session status, and the summary next to the workflow status —
because keiro knows nothing about kioku and kioku knows nothing about keiro.

The user-visible proof: `shikigami agents list` prints one row per manifest including a `failed`
row for `agents/broken.dhall`; with a run in flight, `shikigami workflow list --status running`
prints its workflow id and status, `shikigami workflow cancel <id>` prints what it *would* do and
exits non-zero, `shikigami workflow cancel <id> --force` records the cancellation, and
`shikigami runs show <id>` reports the workflow as `cancelled` alongside its kioku session; a
poison job drained into the DLQ appears in `shikigami pgmq dlq read --queue shikigami_run_jobs_dlq`
and `shikigami pgmq dlq redrive --queue shikigami_run_jobs_dlq --force` puts it back on the live
queue.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-19) Prerequisite audit. Plans 36 and 37 have landed. Plan 20's Milestone 4 report
      slice — `AgentLoadReport`, `loadAgentsReport`, `loadedAgents`, `loadAgentsLoud` — landed
      through plan 33 (commit `cf513b7`), so M1's hard dependency is satisfied. Plan 17's real DLQ
      landed, so M4's gate is cleared. Plan 33 added `enabled`, `identity`, and `memory` to
      `AgentDecl`, which `agents list` should render.
- [x] (2026-08-19) Citation audit. Every `shikigami-cli/...` and
      `shikigami-core/src/Shikigami/Worker.hs:NN` pointer in this plan referred to a package and a
      module plan 36 deleted; `Shikigami.Api.Agent` and `Shikigami.Api.RunJob` were renamed; the
      kioku session table moved schema. All corrected in Context and Orientation.
- [x] (2026-08-19) **Scope reduced by an upstream release.** `keiro-ops 0.13.0.0` is published on
      Hackage and ships an embeddable command tree covering workflows, timers, the outbox, PGMQ
      dead letters, projections, snapshots, streams, shards, replay audit, and rebuild. Keiro
      ADR-28 makes wrapping those exported operations mandatory and ad hoc operator SQL
      forbidden. Milestones 2, 3, and 4 are rewritten around it; see the Decision Log.
- [ ] M0: add `keiro-ops ==0.13.0.0` to `cabal.project`'s constraints block and record the row in
      `docs/dependency-cohort.md`; confirm `cabal build all --dry-run` still resolves with no
      `allow-newer` between co-developed packages.
- [ ] M1: `shikigami agents list` — renders `loadAgentsReport` with name, behavior kind, trigger
      summary, enabled state, and load state; `--json` for machine consumption.
- [ ] M2: mount `Keiro.Ops.opsCommandTree` into the `shikigami` dispatcher with the Settei
      database URL supplied from `AppConfig`, and decide (recording the reason) which `AppHooks`
      are populated.
- [ ] M2: verify the `ResumeHook` effect-row question — `keiro-ops` wants a registry over
      `'[Store, Error StoreError, IOE]` and shikigami's is over `Kioku.App.AppEffects`; see
      Surprises & Discoveries.
- [ ] M3: `shikigami runs show <workflow-id>` — the keiro-instance-to-kioku-session join that
      neither library can do alone, built from `listWorkflowInstances`/`lookupInstance` plus
      `Kioku.Session.getById`, after verifying how the two identities actually relate.
- [ ] M4: an audit line through `Shikigami.Log` for every mutation issued through the mounted
      tree, and a dispatch test proving the preview/`--force` gate reaches the right handler.
- [ ] M5: `docs/operations/` gains an operator runbook naming which verb answers which question,
      including the ones that come from `keiro-ops` rather than from this repository.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **(2026-08-19, refresh) Keiro shipped the console this plan was going to build, and made
  building it by hand a documented mistake.** `keiro-ops 0.13.0.0` is on Hackage; its synopsis is
  "Operational command-line interface for Keiro deployments" and its description is "A standalone
  database-only console **and embeddable command tree** for inspecting and operating Keiro
  deployments" (`/Users/shinzui/Keikaku/bokuno/keiro/keiro-ops/keiro-ops.cabal:2-7`).
  `Keiro.Ops` exports `opsCommandTree :: AppHooks -> ParserInfo OpsInvocation`,
  `runOpsInvocation`, `AppHooks`, `emptyAppHooks`, and `mainWithHooks`
  (`keiro-ops/src/Keiro/Ops.hs:1-11`), and the embedding boundary has its own ADR
  (`keiro-ops/src/Keiro/Ops/Embed.hs:1-9`).

  Its command tree is `Workflow | Timer | Outbox | Inbox | Pgmq | Projection | Shard | Snapshot |
  Stream | ReplayAudit | Rebuild` (`Keiro/Ops.hs:62-73`). The three that matter here:

  - `workflow list|show|steps|journal|awakeable|cancel|resurrect|lease|gc` (plus `resume-once`
    when the hook is supplied) — `keiro-ops/src/Keiro/Ops/Workflow.hs:120-159`.
  - `outbox backlog|list|show|requeue-stuck|gc-sent|maintenance-pass|dead-letters list` —
    `keiro-ops/src/Keiro/Ops/Outbox.hs:45-67`.
  - `pgmq dlq read|redrive|archive|purge` — `keiro-ops/src/Keiro/Ops/Pgmq.hs:30-62`.

  That covers Milestone 2's `runs list`, Milestone 3's `runs cancel`, and all of Milestone 4
  except the Shikigami-specific rendering.

- **(2026-08-19, refresh) Keiro ADR-28 forbids the approach Milestones 2–4 specified.**
  `mori://shinzui/keiro/okf/adrs/concepts/ADR-28` ("Operator commands wrap supported library APIs
  and respect schema ownership", Accepted 2026-08-08) decides: "Every operator command is a thin adapter over an exported
  operation from the library that owns the affected state. A command must not reproduce a
  supported mutation with ad hoc SQL, and it must not query or mutate another library's private
  tables. When an operator primitive is missing, it is added and tested in the owning library
  before a command exposes it." This plan's `Shikigami.Operator.Query` — read-only hasql
  statements over `keiro.keiro_workflows`, `keiro.keiro_workflow_steps`, and the kioku session
  table — is exactly the second sentence. It is struck.

- **(2026-08-19, refresh) `cancelWorkflow` exists now, so this plan's central Decision Log claim
  is false.** The 2026-07-08 entry said "keiro has no top-level 'cancel workflow by id' function;
  cancellation is modeled as appending `WorkflowCancelled`". At `keiro 0.13.0.0`,
  `Keiro.Workflow` re-exports `cancelWorkflow` and `CancelWorkflowOutcome`
  (`keiro/src/Keiro/Workflow.hs:158-159`):

  ```haskell
  -- keiro/src/Keiro/Workflow/Instance.hs:139-144, 250-254
  data CancelWorkflowOutcome
    = WorkflowCancelRecorded
    | WorkflowAlreadyTerminal !WorkflowStatus
    | WorkflowCancelUnknown

  cancelWorkflow :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> Eff es CancelWorkflowOutcome
  ```

  It already refuses a terminal instance and already reports "no such workflow" honestly, which
  is what this plan's M3 was going to hand-roll around `appendJournalEntry`. `resurrectFailedWorkflow`
  and `ResurrectOutcome` exist beside it (`Instance.hs:133-137,427-444`) — an operator verb this
  plan never imagined.

- **(2026-08-19, refresh) Keiro also shipped the bounded enumeration this plan specified.**
  `WorkflowInstanceFilter {statuses, workflowName, afterKey, pageSize}` with
  `listWorkflowInstances :: (Store :> es) => WorkflowInstanceFilter -> Eff es [WorkflowInstanceRow]`
  (`Instance.hs:106-118,221-224`). Its Haddock states the ordering and cursor contract: "Results
  are ordered by `(workflow_name, workflow_id)`. Pass the final row's name and id as `afterKey` to
  fetch the next page without the instability and growing scan cost of an `OFFSET` query. A
  non-positive `pageSize` returns an empty page." That is this plan's 2026-07-22 keyset-pagination
  decision, implemented upstream, so `PageSize`/`PageRequest`/`RunCursor`/`StepCursor` are no
  longer this plan's to define.

- **(2026-08-19, refresh) The confirmation flag is `--force`, not `--confirm`.**
  `keiro-ops`'s global options are
  `GlobalOptions {databaseUrl, outputMode, force, allowSchemaDrift}`
  (`keiro-ops/src/Keiro/Ops/Env.hs:22-28`), with `force` parsed as
  `switch (long "force" <> help "Apply a mutating command after its preview")`
  (`Env.hs:51`). Every mutating subcommand's `progDesc` is "Preview or …". Mounting that tree and
  then spelling Shikigami's own gate `--confirm` would give one binary two words for one concept.

- **(2026-08-19, refresh) An effect-row mismatch to resolve before mounting the resume hook.**
  `Keiro.Ops.Workflow.ResumeHook` is
  `(WorkflowRegistry '[Store, Error StoreError, IOE], WorkflowResumeOptions)`
  (`keiro-ops/src/Keiro/Ops/Workflow.hs:109-112`), while shikigami's registry is over
  `Kioku.App.AppEffects = '[Store, KirokuStoreResource, Error StoreError, Tracing, IOE]`
  (`/Users/shinzui/Keikaku/bokuno/kioku/kioku-core/src/Kioku/App.hs:26`). They are not the same
  row. `TimerFire` has no such problem —
  `TimerRow -> Eff '[Store, Error StoreError, IOE] (Maybe EventId)`
  (`keiro-ops/src/Keiro/Ops/Timer.hs:44`) and `shikigamiTimerFallback`'s constraint is the
  polymorphic `(Store :> es, IOE :> es)`
  (`shikigami-workers/src/Shikigami/Trigger/Scheduler.hs:105`), so it instantiates directly.
  Resolve the registry question in M2 and record the answer; the cheapest correct one may be to
  leave `workflowResume` unmounted, because the worker process already runs the resume loop and an
  operator-triggered `resume-once` is a convenience rather than a capability.

- (Findings from implementation go below this line.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Issue run cancellation by appending keiro's terminal `WorkflowCancelled` journal
  marker via `Keiro.Workflow.appendJournalEntry`, not via a bespoke SQL `UPDATE`.
  Rationale: keiro has no top-level "cancel workflow by id" function.
  Date: 2026-07-08
  **Superseded 2026-08-19.** The premise expired. `keiro 0.13.0.0` exports
  `cancelWorkflow :: WorkflowName -> WorkflowId -> Eff es CancelWorkflowOutcome`
  (`keiro/src/Keiro/Workflow/Instance.hs:250-254`), which does what the hand-rolled append was
  going to do and additionally returns an honest three-way outcome —
  `WorkflowCancelRecorded | WorkflowAlreadyTerminal status | WorkflowCancelUnknown` — that the
  append-based version would have had to reconstruct from a prior lookup. Keiro ADR-28 makes
  wrapping the exported operation mandatory, not merely preferable. What survives from the
  original entry is its *reasoning about why*: a raw `UPDATE` would bypass the journal, which is
  the source of truth for replay, and desynchronize it from the status table. That reasoning is
  now enforced upstream. `cancelChild` remains parent-to-child only and is still not used here.

- Decision: Inspection subcommands are read-only SQL against the substrate's tables; there is no
  new "runs" table.
  Rationale: an agent run's durable state already lives across keiro's and kioku's tables, and
  reading them directly is simpler and truthful; a synthesized runs table would duplicate and risk
  drifting from the source of truth.
  Date: 2026-07-08
  **Half superseded 2026-08-19.** "No new runs table" stands and is now doubly justified. "Read-only
  SQL against the substrate's tables" does not: Keiro ADR-28 forbids an operator command querying
  another library's tables, and both libraries now export the reads this plan needs — keiro's
  `listWorkflowInstances`/`lookupInstance`/`loadStepIndex`, kioku's `Session.getById`/`getByScope`/
  `getTurns`/`getChain`. `Shikigami.Operator.Query` is struck; there is no hand-written SQL in this
  plan.

- Decision: Dead-letter tooling targets plan 17's configured direct DLQ and uses public
  queue/store helpers or schema-qualified documented SQL. PGMQ archive tables are not an operator
  contract.
  Rationale: a real DLQ supports inspection, controlled replay, repair, and discard; incidental
  archive layout is private, incomplete remediation state.
  Date: 2026-07-22
  Amended 2026-08-19: the gate is cleared and the implementation is upstream. Plan 17 landed
  `shikigami_run_jobs_dlq` as a policy-enabled keiro-pgmq DLQ, reconciled at worker startup by
  `ensureJobQueue runJob` (`shikigami-workers/src/Shikigami/Workers/Registry.hs:60-69`).
  `keiro-ops` operates exactly that shape with `pgmq dlq read|redrive|archive|purge`
  (`keiro-ops/src/Keiro/Ops/Pgmq.hs:30-62`). The `pgmq.a_*` archive is still not an operator
  contract, and `keiro-ops` does not touch it.

- Decision: Read-only by default; every destructive subcommand requires an explicit flag and
  prints what it will do first.
  Rationale: the MasterPlan scopes this plan as "read-mostly and safe". A single switch is
  unambiguous and testable; without it the command prints the intended action and exits non-zero.
  Every mutation emits an audit event; list/show are pure reads.
  Date: 2026-07-08
  **Amended 2026-08-19: the flag is `--force`, not `--confirm`.** `keiro-ops` already spells this
  concept `--force` as a global option, and every mutating subcommand's help text is "Preview or
  …" (`keiro-ops/src/Keiro/Ops/Env.hs:22-28,51`). Once its tree is mounted inside `shikigami`, a
  second spelling for the same idea in the same binary is a usability bug, not a stylistic
  preference. Shikigami's own mutating verbs adopt `--force` and the preview-first behaviour. The
  audit-event requirement is unchanged and is now Shikigami's contribution: `keiro-ops` does not
  know about `Shikigami.Log`.

- Decision: Every row-producing database query is server-side bounded and keyset-paginated.
  Rationale: a CLI is not an excuse for unbounded database transfer or heap use. Keyset pages
  remain stable as rows are appended and avoid offset scan cost.
  Date: 2026-07-22
  Status 2026-08-19: **satisfied upstream, and the bespoke types are struck.**
  `WorkflowInstanceFilter` carries `afterKey :: Maybe (Text, Text)` and `pageSize :: Int`, orders
  by `(workflow_name, workflow_id)`, and returns an empty page for a non-positive size
  (`keiro/src/Keiro/Workflow/Instance.hs:106-118,221-237`); `keiro-ops`'s `workflow list` exposes
  it. This plan defines no `PageSize`, `PageRequest`, `RunCursor`, or `StepCursor`. The rule still
  binds anything Shikigami adds: `agents list` reads a directory, which is bounded by the
  filesystem, and `runs show` reads one instance and one session.

- Decision: This plan owns the `agents` operator command group but consumes plan 20's
  `AgentLoadReport`; plan 23 later extends the command with principal/lifecycle state and adds
  `sync`.
  Rationale: plan 20 is the sole directory traversal and preserves parse failures, while the
  operations initiative owns presentation and CLI parsing. This division prevents a second loader
  here and a second `agents` command in plan 23.
  Date: 2026-07-22
  Status 2026-08-19: **the dependency is satisfied.** Plan 33 (commit `cf513b7`) implemented plan
  20's narrowly required report slice — `AgentLoadReport`, `loadAgentsReport`, `loadedAgents`, `loadAgentsLoud`,
  and `enabledAgentsFromReport` in `shikigami-core/src/Shikigami/Agent/Loader.hs`, used by every
  long-running role (`shikigami-workers/src/Shikigami/Workers/Command/Worker.hs:40-41`). Consume
  it; do not traverse `agents/` here. Plan 33 also added `enabled`, `identity`, and `memory` to
  `AgentDecl`, so `agents list` has three more columns' worth of truth to show than this plan
  originally specified — in particular, a disabled agent looks identical to an enabled one unless
  the listing says otherwise.

- Decision: **Mount `keiro-ops`'s command tree rather than reimplementing its verbs.**
  Rationale: three separate arguments point the same way. Keiro ADR-28 requires operator commands
  to be thin adapters over exported operations of the owning library, so a hand-written
  `runs list` over `keiro.keiro_workflows` is now a rule violation rather than a shortcut. The
  verbs already exist, tested, in a released package with an explicit embedding boundary
  (`Keiro.Ops.Embed`), so writing them here would be duplicated work that must then be kept in
  step with Keiro's schema across every upgrade — which is exactly the coupling
  `docs/dependency-cohort.md`'s "released versions only" rule exists to avoid. And the verbs
  `keiro-ops` supplies are strictly broader than what this plan scoped: journal decoding, awakeable
  inspection and cancellation, lease release, workflow resurrection, outbox maintenance passes,
  and stuck-timer triage were all out of scope and all arrive free.
  What this plan keeps is what `keiro-ops` cannot know: the declared-agent inventory, and the join
  between a keiro workflow instance and its kioku session.
  Date: 2026-08-19

- Decision: **Keep `runs show` as a Shikigami verb, and verify the join before relying on it.**
  Rationale: `keiro-ops workflow show` reports the instance, its children, and its awakeables — all
  keiro state. It cannot report the agent name, the session status, the summary, or the recorded
  turns, because those are kioku's and keiro has no business knowing about them. A Shikigami
  operator asking "what happened to this run" wants both halves in one place, and joining them is
  a Shikigami concern by construction. The 2026-07-08 entry hypothesised the join key is
  `workflow_id = session_id`; that hypothesis is unverified and must be checked against how
  `Shikigami.Agent.Workflow` actually mints each identity before any code depends on it. If they
  are independent, `runs show` looks the session up through kioku's own indexed queries — by
  scope, or by subject reference once kioku IR-2 lands — and records the finding.
  Date: 2026-08-19


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

All shikigami paths are repository-relative to `/Users/shinzui/Keikaku/bokuno/shikigami`.
Dependency sources are given as absolute paths into the local checkouts; the canonical references
are `mori://shinzui/keiro` and `mori://shinzui/kioku`.

### Terms

An **agent** is a Dhall manifest under `agents/`, decoded into `AgentDecl`
(`shikigami-core/src/Shikigami/Agent/Decl.hs`). An **agent run** is one execution of a declared
agent; its durable state spans two libraries. *keiro* is the durable-workflow engine, and a run is
a keiro **workflow instance** with a status of `running`, `suspended`, `completed`, `cancelled`, or
`failed`. *kioku* is the session and memory store, and a run opens a **session** with its own
lifecycle. *pgmq* is the Postgres message queue; the run-job queue is `shikigami_run_jobs` and its
dead-letter queue is `shikigami_run_jobs_dlq`. The keiro **outbox** holds queued sink intents. A
**preview** is what a mutating operator command prints when run without `--force`: what it would
do, and nothing else.

### What moved, and what to stop citing

`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md` deleted the
`shikigami-cli` package and `shikigami-core/src/Shikigami/Worker.hs`, and renamed the domain
modules. Every one of this plan's original citations pointed at something that no longer exists:

| Was | Is now |
|---|---|
| `shikigami-cli/src/Shikigami/Cli.hs` (twelve-subcommand dispatcher) | `shikigami-server/src/Shikigami/Server/Command.hs:98-107` (seven subcommands, Settei-resolved) |
| `shikigami-cli/src/Shikigami/Cli/Commands/*.hs` | `shikigami-server/src/Shikigami/Server/Command/*.hs` |
| `shikigami-core/src/Shikigami/Worker.hs:190` (Cancelled → dead-letter ack) | `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs:235-245` (`agentJobOutcome`) |
| `shikigami-core/src/Shikigami/Api/Agent.hs` (`AgentDecl`) | `shikigami-core/src/Shikigami/Agent/Decl.hs` |
| `shikigami-core/src/Shikigami/Api/RunJob.hs` (`RunJob`) | `shikigami-core/src/Shikigami/Agent/RunJob.hs` |
| `kiroku.kioku_sessions` | `kioku.sessions` — kioku migration `0012` relocated the projections; see below |
| `getEnv "PG_CONNECTION_STRING"` | one resolved `Shikigami.App.Config.AppConfig`; plan 37 removed every environment read |

The kioku projection tables are now `kioku.sessions`, `kioku.turns`, and `kioku.memories`
(`/Users/shinzui/Keikaku/bokuno/kioku/kioku-core/src/Kioku/Database/Schema.hs:45-73`). This plan
does not query them — it goes through `Kioku.Session` — but the old names appear in other
documents and are wrong.

### The dispatcher this plan extends

`Shikigami.Server.Command` is one `optparse-applicative` parser producing
`type AdminAction = (AppConfig -> IO (), [Source])` — the action to run once configuration is
resolved, plus any Settei sources the subcommand's own flags supplied
(`Server/Command.hs:61-63`). `runAdmin` (`:80-92`) parses, resolves configuration, then runs the
action; resolution happens *after* parsing and *before* the action, so every diagnostic mode
completes without a subcommand opening a database, a socket, or a Kafka producer. The subcommand
is optional so `shikigami --describe-config` works with none.

`adminSubcommands :: [(String, Mod CommandFields AdminAction)]` (`:98-107`) exists specifically so
a test can assert every subcommand parses and renders help without listing them twice. Adding a
command group means adding one entry there. `grants` (`:109-131`) is the worked example of a
*group* rather than a flat verb, and is the shape `agents` and the mounted `keiro-ops` tree
follow.

The header of that module also records why these commands live in `shikigami-server` at all: they
reach downstream HTTP and Kafka surfaces the server package owns, `shikigami-workers` may not be
imported by the server, and core may hold no listener. That constraint governs where this plan's
new modules go.

### `keiro-ops`

Pinned target `0.13.0.0`, published on Hackage. Canonical
`mori://shinzui/keiro/packages/keiro-ops`; local checkout
`/Users/shinzui/Keikaku/bokuno/keiro/keiro-ops`.

`Keiro.Ops` exports `main`, `mainWithHooks`, `AppHooks (..)`, `OpsAuditConfig (..)`,
`emptyAppHooks`, `OpsInvocation`, `opsCommandTree`, and `runOpsInvocation`
(`Keiro/Ops.hs:1-11`). The embedding pattern is: build a `ParserInfo OpsInvocation` with
`opsCommandTree hooks`, and run the parsed value with `runOpsInvocation hooks invocation`, which
returns an `ExitCode`.

```haskell
-- keiro-ops/src/Keiro/Ops.hs:62-73
data Command
  = Workflow Workflow.Command | Timer Timer.Command | Outbox Outbox.Command
  | Inbox Inbox.Command | Pgmq Pgmq.Command | Projection Projection.Command
  | Shard Shard.Command | Snapshot Snapshot.Command | Stream Stream.Command
  | ReplayAudit ReplayAudit.Command | Rebuild Rebuild.Command
```

```haskell
-- keiro-ops/src/Keiro/Ops/Env.hs:17-28
data OutputMode = HumanTable | Json

data GlobalOptions = GlobalOptions
  { databaseUrl      :: !(Maybe Text),
    outputMode       :: !OutputMode,
    force            :: !Bool,
    allowSchemaDrift :: !Bool
  }
```

```haskell
-- keiro-ops/src/Keiro/Ops/Embed.hs:11-26
data AppHooks = AppHooks
  { workflowResume    :: !(Maybe ResumeHook),
    timerFire         :: !(Maybe TimerFire),
    replayAudit       :: !(Maybe OpsAuditConfig),
    projectionCatalog :: !(Maybe ProjectionCatalogOperations)
  }
```

Commands whose hook is absent are simply not mounted — `Keiro.Ops.Embed`'s header says so, and
`Workflow.commandParserWithResume False` (`Keiro/Ops/Workflow.hs:136-159`) shows the mechanism:
the `resume-once` command is `mempty` when resume is unavailable. So an incremental mount is
legitimate: start with `emptyAppHooks` and add hooks as their questions are answered.

The hook types, and the one that does not fit today:

```haskell
-- keiro-ops/src/Keiro/Ops/Workflow.hs:109-112
type ResumeHook = (WorkflowRegistry '[Store, Error StoreError, IOE], WorkflowResumeOptions)

-- keiro-ops/src/Keiro/Ops/Timer.hs:44
type TimerFire = TimerRow -> Eff '[Store, Error StoreError, IOE] (Maybe EventId)
```

Shikigami's registry is `Shikigami.Agent.Workflow.Resume.workflowRegistry :: WorkerEnv ->
WorkflowRegistry AppEffects`, and `AppEffects` is
`'[Store, KirokuStoreResource, Error StoreError, Tracing, IOE]`. Those rows differ; see Surprises
& Discoveries. `shikigamiTimerFallback` is polymorphic in its row and fits directly.

`keiro-ops` also has its own operator ADR corpus. The binding one here is
`mori://shinzui/keiro/okf/adrs/concepts/ADR-28`, "Operator commands wrap supported library APIs
and respect schema ownership": every operator command is a thin adapter over an exported operation
from the library that owns the affected state; no ad hoc SQL for a supported mutation; no querying
or mutating another library's private tables; and when a primitive is missing, it is added and
tested in the owning library before a command exposes it. It also warns against inventing derived
metrics — its worked example is that a checkpoint-to-head subtraction is a "global position
distance" and must never be called event lag, backlog, or events-behind, because a sparse cursor
makes those claims false. Take the caution generally: a listing renders what a library reports and
does not compute a number the library declined to define.

### The keiro operations this plan's Shikigami half uses

```haskell
-- keiro/src/Keiro/Workflow/Instance.hs:88-118
data WorkflowInstanceRow = WorkflowInstanceRow
  { workflowId, workflowName :: !Text,
    generation               :: !Int32,
    status                   :: !WorkflowStatus,
    attempts                 :: !Int32,
    lastError                :: !(Maybe Text),
    nextAttemptAt, wakeAfter, leaseExpiresAt, completedAt :: !(Maybe UTCTime),
    leasedBy                 :: !(Maybe Text),
    createdAt, updatedAt     :: !UTCTime
  }

data WorkflowInstanceFilter = WorkflowInstanceFilter
  { statuses     :: !(Maybe (NonEmpty WorkflowStatus)),
    workflowName :: !(Maybe Text),
    afterKey     :: !(Maybe (Text, Text)),
    pageSize     :: !Int
  }
```

`listWorkflowInstances :: (Store :> es) => WorkflowInstanceFilter -> Eff es [WorkflowInstanceRow]`
(`Instance.hs:221-224`), `lookupInstance` (`Instance.hs`), `defaultWorkflowInstanceFilter`,
`cancelWorkflow`, `resurrectFailedWorkflow`, and `forceReleaseInstanceLease` are all re-exported
from `Keiro.Workflow` (`keiro/src/Keiro/Workflow.hs:152-163`).

The two workflow names an operator will pass are
`Shikigami.Agent.Workflow.Name.agentRunWorkflowName` (`WorkflowName "shikigami.agent-run"`) and
`Shikigami.Agent.Conversation.conversationWorkflowName`, which since plan 39 is
`Shikigami.AgentRun.Generated.WorkflowRuntime.workflowName` and
`Shikigami.DanwaConversation.Generated.WorkflowRuntime.workflowName` respectively — the literals
live in `domain/shikigami-agent-run.keiro` and `domain/shikigami-conversation.keiro` and reach
Haskell through the generated modules. Do not hard-code either string in a command module; import
the constant, so a rename stays a one-place change gated by `just keiro-gate`.

### The kioku operations this plan's Shikigami half uses

`Kioku.Session` exports `getById`, `getRecentInNamespace`, `getByScope`, `getByFocus`,
`getByStartedRange`, `getChain`, `getDelegationChildren`, `getAwaitingByCorrelationKey`, and
`getTurns` (`/Users/shinzui/Keikaku/bokuno/kioku/kioku-core/src/Kioku/Session.hs:39-49`). Every
read takes a leading `MemorySpaceId`; shikigami answers that question in exactly one module,
`shikigami-core/src/Shikigami/Memory/Access.hs` (`shikigamiMemorySpace`, `agentActor`,
`shikigamiReadContext`). Use it rather than naming `legacyMemorySpaceId` directly — that is a
standing instruction in `docs/architecture/implementation-order.md` for every plan that touches
memory-scoped facts.

`SessionRow` carries `agentId`, `focus`, `scopeKind`, `scopeRef`, `subjectRef`,
`previousSessionId`, `parentSessionId`, `delegationDepth`, `status`, `startedAt`, `completedAt`,
`modelUsed`, `summary`, and `errorMessage`
(`kioku-core/src/Kioku/Session/ReadModel.hs:53-76`) — everything `runs show` wants from the kioku
half.

Note for M3: there is no subject-reference session query. That is kioku IR-2
(`mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2`), still `status: proposed`.

### The agent loader

`shikigami-core/src/Shikigami/Agent/Loader.hs` owns the directory traversal and the load report:
`loadAgentsReport`, `loadedAgents`, `loadAgentsLoud`, and `enabledAgentsFromReport`. Every
long-running role already goes through it — see
`shikigami-workers/src/Shikigami/Workers/Command/Worker.hs:40-41`, which calls
`loadAgentsLoud (Config.agentsDirectory config) False` and then `enabledAgentsFromReport`. The
report preserves parse failures rather than skipping them, which is the whole reason `agents list`
consumes it rather than walking the directory.

`agents/broken.dhall` exists in the repository and is an expected failure, so it is the fixture
that proves the `failed` row renders.

Plan 33 added three fields to `AgentDecl` that a listing should show:
`enabled :: Bool`, `identity`, and `memory` (with `MemoryScope` and `RecordPolicy`). A disabled
agent is loaded but never selected for work; an operator looking at a silent agent needs the
listing to say which of "not loaded", "loaded but disabled", and "loaded and enabled" is true.

### Relevant Shikigami ADRs

- `docs/adr/0001-declare-only-what-the-runtime-executes.md` — do not describe something the
  runtime does not do. Applies to a listing as much as to a specification: render what the library
  reports, not a derived figure it declined to define.
- `docs/adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md` — the package-boundary
  reasoning that decides where a new command module may live.

No ADR covers operator tooling or the mount-versus-reimplement question. If the decision to mount
`keiro-ops` survives implementation, it is durable project context — it constrains every future
operator verb — and should be promoted to a new ADR during the distillation pass.


## Plan of Work

### Milestone 0 — take the dependency

Scope: one `cabal.project` change and one documentation row, so everything after it compiles.

Add `keiro-ops ==0.13.0.0` to the constraints block in `cabal.project`, in the durable-execution
group beside the other `keiro*` rows. It is a library this repository *links against* (unlike
`keiro-dsl`, which is a build-time tool listed under `extra-packages`), so it is an ordinary
constraint and an ordinary `build-depends` entry in `shikigami-server.cabal`.

Add its row to `docs/dependency-cohort.md`'s release matrix with the upstream tag
(`keiro-ops-0.13.0.0`) and tag commit, following the format the existing rows use. That document
is a contract: a drift between it and the solver is a bug in one of them.

**Acceptance.**

```bash
nix develop --command cabal build all --dry-run
```

resolves and selects `keiro-ops-0.13.0.0` with no `allow-newer` between co-developed packages.

### Milestone 1 — `shikigami agents list`

Scope: the one operator verb that is entirely Shikigami's, and the simplest. It establishes the
`agents` command group and the output convention: a compact aligned table by default, `--json` for
machine consumption.

Add an `agents` group to `adminSubcommands` (`Server/Command.hs:98-107`) following the shape
`grants` establishes (`:109-131`), with a `list` subparser. Create the command module beside the
others in `shikigami-server/src/Shikigami/Server/Command/`.

The action takes the resolved `AppConfig`, reads `Config.agentsDirectory`, and calls
`loadAgentsReport`. Render every entry — loaded and failed. For each loaded `AgentDecl`: name,
behavior kind (reuse `Shikigami.Agent.Run.behaviorKindText`; do not re-derive it), a trigger
summary derived from the `Trigger` constructor (`schedule <cron>` / `stream <topic/match>` /
`event <eventType>`), and the enabled state plan 33 added. For each failure: the file and the
diagnostic the report preserved.

Do not walk `agents/` here, and do not call `loadAgent` directly. Plan 20 owns the traversal and
plan 23 extends this same command later with principal and lifecycle state; a second loader or a
second `agents list` is exactly what that division exists to prevent.

**Acceptance.**

```bash
cabal run shikigami -- agents list --config config/operator-dev.yaml
```

prints one row per manifest, including a `failed` row for `agents/broken.dhall` and a visibly
different state for any agent whose manifest sets `enabled = False`.

### Milestone 2 — mount the `keiro-ops` command tree

Scope: give the operator the whole substrate surface without writing it.

Add an entry to `adminSubcommands` that mounts `Keiro.Ops.opsCommandTree`. The mechanical
question is how `keiro-ops`'s parser composes with Shikigami's, since both want to own global
options. `keiro-ops`'s `GlobalOptions` carries its own `--database-url`, and Shikigami resolves the
connection string from Settei (`Shikigami.App.Config.Load.requireDatabaseUrl`, used at
`shikigami-workers/src/Shikigami/Workers/Command/Worker.hs:44`). Resolve this by supplying the
Settei-resolved value as the default and letting `--database-url` override it, exactly as plan 37's
"a flag is a Settei source aimed at a declared key" convention does for `--broker`. Do not read an
environment variable, and do not let the mounted tree open a connection before configuration
resolves — `runAdmin` guarantees resolution happens first, and that guarantee must survive.

Decide, and record with reasons, which `AppHooks` are populated:

- `timerFire` — populate it. `shikigamiTimerFallback`
  (`shikigami-workers/src/Shikigami/Trigger/Scheduler.hs:105-109`) fits `TimerFire`'s row
  directly. This gives an operator `timer drain-once` and stuck-timer triage against Shikigami's
  own timer semantics rather than keiro's defaults. Note the package direction: `shikigami-server`
  may not import `shikigami-workers`, so if the fallback is to be reachable from the admin binary
  it must move to a package both can see — probably `shikigami-core` — or the hook stays
  unpopulated. Resolve that before promising the verb.
- `workflowResume` — probably leave it empty, and say why. The effect rows do not match (see
  Surprises & Discoveries), and the worker process already runs the resume loop continuously, so
  `resume-once` is a convenience rather than a capability. If it is wanted, the work is to expose
  a registry over `'[Store, Error StoreError, IOE]`, which is a change to how shikigami builds its
  registry and belongs in its own commit.
- `replayAudit` and `projectionCatalog` — leave empty. Shikigami has no projection catalog and no
  replay-audit targets; `docs/architecture/shikigami-domain-inventory.md` established that it has
  no aggregate, read model, projection, router, or process manager of its own. Populating either
  would be declaring something the runtime does not do, which is the mistake
  `docs/adr/0001-declare-only-what-the-runtime-executes.md` exists to prevent.

**Acceptance.** `shikigami --help` lists the mounted group. With a run in flight:

```bash
cabal run shikigami -- workflow list --status running
cabal run shikigami -- workflow show <workflow-id>
cabal run shikigami -- workflow cancel <workflow-id>            # previews, exits non-zero
cabal run shikigami -- workflow cancel <workflow-id> --force    # records the cancellation
cabal run shikigami -- outbox backlog
cabal run shikigami -- pgmq dlq read --queue shikigami_run_jobs_dlq
```

and each behaves as `keiro-ops` documents. A cancel of an already-terminal instance reports
`WorkflowAlreadyTerminal` rather than pretending to succeed.

### Milestone 3 — `shikigami runs show`

Scope: the one inspection verb `keiro-ops` structurally cannot provide — the join across the two
libraries.

**First, verify the join key.** Read `shikigami-core/src/Shikigami/Agent/Workflow.hs` and
establish how the workflow id and the session id are actually minted for an agent run. The
2026-07-08 hypothesis was that the workflow id is the job's idempotency key and the session id is
independently generated, in which case they are *not* equal and a `workflow_id = session_id` join
is wrong. Record what you find in Surprises & Discoveries before writing the command, because the
command's shape depends on the answer:

- If they are equal, `runs show <id>` reads the instance with `lookupInstance` and the session
  with `Session.getById`, and prints both.
- If they are independent, the command reads the instance, extracts the agent name and time
  window, and finds the session through kioku's indexed reads (`getByScope` for the agent's scope,
  narrowed by `startedAt`). Say so in the help text: an inferred join is not a guaranteed one, and
  an operator must be able to tell.
- If neither is reliable, the honest outcome is that shikigami needs to record the linkage, and
  that is a design change belonging in its own plan — not a guess in a listing.

Build the command from library reads only. `Keiro.Workflow`'s `lookupInstance` and `loadStepIndex`
for the workflow half; `Kioku.Session.getById` and `getTurns` for the session half, through
`Shikigami.Memory.Access`'s space. No hasql `Statement` is written by this plan.

Render: workflow id, workflow name, status, generation, attempts, last error, timestamps; then
agent id, session status, summary, error message, and turn count. `--json` emits both halves as
one object.

**Acceptance.** With a run in flight, `shikigami runs show <id>` prints the workflow as `running`
alongside its kioku session; after `shikigami workflow cancel <id> --force`, the same command
reports `cancelled`, and a direct `keiro-ops workflow show` agrees about the workflow half.

### Milestone 4 — audit and the dispatch test

Scope: the two things mounting a third-party tree does not give you.

**Audit.** Every mutation issued through the `shikigami` binary emits one structured line through
`Shikigami.Log` (which exists — plan 28's Milestone 1 landed), naming the verb, the target
identity, the outcome, and a correlation id. `keiro-ops` does not know about `Shikigami.Log`, so
this wraps the mount: log the intent before `runOpsInvocation` and the resulting `ExitCode` after.
Follow plan 28's `component.subject.verb` naming — `operator.workflow.cancelled`,
`operator.dlq.redriven` — rather than inventing a parallel vocabulary.

**The dispatch test.** Extend the existing subcommand-parsing test that `adminSubcommands` exists
to serve, so it covers the new groups: every subcommand parses and renders `--help` through
`execParserPure`, with no database or socket touched. Then a behavioural test: seed one running
workflow and one DLQ entry, run each mutating verb without `--force` and assert nothing changed,
then with `--force` and assert exactly the intended change plus its audit line.

**Acceptance.** The test fails with the gate inverted and passes with it. `cabal test all` green.

### Milestone 5 — the runbook

Scope: a short operator document, because a mounted third-party tree is discoverable only if
someone says it is there.

Write `docs/operations/operator-cli.md` mapping questions to verbs: "which agents are declared and
are any broken?" → `agents list`; "what is running right now?" → `workflow list --status running`;
"what happened to this run?" → `runs show`; "this run is stuck" → `workflow cancel … --force`, and
the `workflow lease`/`workflow resurrect` verbs for the cases cancel does not fit; "jobs are
disappearing" → `pgmq dlq read` then `redrive --force`; "sinks are not being delivered" →
`outbox backlog` and `outbox list`. Name which verbs come from `keiro-ops` and link its
documentation, so an operator knows where to look when a verb behaves in a way this repository did
not define.

Add the `keiro-ops` row to whatever configuration reference plan 31 owns, if the mount introduces
a setting.

**Acceptance.** The document exists, every command in it runs, and its transcripts match.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shikigami` inside the Nix dev shell, against
the dev Postgres cluster.

```bash
nix develop
just create-database
```

Take the dependency (M0) and confirm the solver:

```bash
cabal build all --dry-run
cabal build all
cabal test all
```

M1:

```bash
cabal run shikigami -- agents list --config config/operator-dev.yaml
```

Expected (columns; `broken.dhall` shows a failed load state):

```text
NAME              BEHAVIOR   TRIGGER                 ENABLED  STATE
heartbeat         flow       schedule */5 * * * *    yes      loaded
triage-note       task       event ...               yes      loaded
broken            -          -                       -        failed
```

M2 (with a worker draining in another terminal and a job enqueued):

```bash
cabal run shikigami -- enqueue-run heartbeat
cabal run shikigami -- workflow list --status running
cabal run shikigami -- workflow cancel heartbeat:<activity-id>
cabal run shikigami -- workflow cancel heartbeat:<activity-id> --force
```

Expected: the third command previews and exits non-zero; the fourth records the cancellation.
Cross-check through the library rather than by hand:

```bash
cabal run shikigami -- workflow show heartbeat:<activity-id>
```

M3:

```bash
cabal run shikigami -- runs show heartbeat:<activity-id>
```

Expected: the workflow half reports `cancelled`, and the kioku half reports the agent id and
session status beside it.

M4 (dead letters, with a poison job drained by the worker):

```bash
cabal run shikigami -- enqueue-run does-not-exist
cabal run shikigami -- pgmq dlq read --queue shikigami_run_jobs_dlq
cabal run shikigami -- pgmq dlq redrive --queue shikigami_run_jobs_dlq
cabal run shikigami -- pgmq dlq redrive --queue shikigami_run_jobs_dlq --force
cabal run shikigami -- outbox backlog
```

Every commit while working on this plan carries both trailers:

```text
ExecPlan: docs/plans/30-operator-cli-inspect-runs-agents-dead-letters-and-cancel.md
Intention: intention_01kx1tyx3yehmsq9eyywdcf5c7
```


## Validation and Acceptance

Acceptance is behavior an operator can observe.

1. `shikigami agents list` enumerates every manifest with its trigger summary, its enabled state,
   and a `failed` row for `agents/broken.dhall`.
2. The mounted `keiro-ops` groups appear in `shikigami --help` and work against the dev database:
   `workflow list|show|cancel`, `outbox backlog|list`, `pgmq dlq read|redrive`, and `timer` if its
   hook was populated.
3. `shikigami workflow cancel <id> --force` moves a running instance to `cancelled`, verified by
   `workflow show`; without `--force` it previews and changes nothing; against an already-terminal
   instance it reports `WorkflowAlreadyTerminal` rather than succeeding.
4. `shikigami runs show <id>` prints the keiro instance and the kioku session together, and its
   help text states whether the join is exact or inferred.
5. Every mutation emits one `Shikigami.Log` audit line naming the verb, target, outcome, and
   correlation id.
6. **No hand-written operator SQL exists in this repository.** `rg 'keiro_workflows|keiro_outbox|
   kioku\.sessions|pgmq\.'` finds no `Statement` or raw query in any command module. This is the
   check that keeps Keiro ADR-28 satisfied over time.
7. The parser/dispatch test proves the preview gate: each mutating verb makes no state change
   without `--force` and reaches the correct handler once forced.
8. Regression: `cabal build all` and `cabal test all` pass; the seven existing subcommands are
   unchanged.


## Idempotence and Recovery

Every inspection verb is a pure read and safe to run repeatedly. Every mutating verb previews by
default, so the dangerous form is never the one an operator reaches by accident.

The mutating verbs' idempotence is upstream's contract and this plan does not reimplement it:
`cancelWorkflow` refuses an already-terminal instance and reports which terminal status it found,
so a repeated cancel is a report rather than a second write; the PGMQ DLQ operations claim and
finalize entries through the queue API, so a repeated redrive does not enqueue an unbounded number
of copies. Verify both claims against the dev database during M2 rather than assuming them, and
record what you observe — an operator will trust these.

M0 is trivially reversible: remove the constraint and the `build-depends` entry. M2's mount is
additive to the dispatcher, so removing the entry from `adminSubcommands` removes the whole group.
If the `timerFire` hook turns out to require moving `shikigamiTimerFallback` across a package
boundary and that move looks disruptive, leave the hook unpopulated and record it — the timer
verbs are the least load-bearing part of the mount.

No schema change is owned by this plan.


## Interfaces and Dependencies

**Hard dependencies, all landed:** plans 36 and 37 (the package split and one resolved
configuration), plan 20's report slice as delivered by plan 33 (`AgentLoadReport` and friends),
plan 17 (the real `shikigami_run_jobs_dlq`), and plan 28's Milestone 1 (`Shikigami.Log`, for the
audit lines).

**New dependency:** `keiro-ops ==0.13.0.0`, a released Hackage package —
`mori://shinzui/keiro/packages/keiro-ops`. It brings `optparse-applicative` and a database connection path this
repository already has.

**Existing libraries.** `keiro 0.13.0.0` — `Keiro.Workflow` (`listWorkflowInstances`,
`lookupInstance`, `defaultWorkflowInstanceFilter`, `WorkflowInstanceRow`,
`WorkflowInstanceFilter`, `WorkflowStatus`, `cancelWorkflow`, `CancelWorkflowOutcome`,
`resurrectFailedWorkflow`, `forceReleaseInstanceLease`, `loadStepIndex`). `kioku 0.4.1.0` —
`Kioku.Session` (`getById`, `getByScope`, `getTurns`, `getChain`) and
`Kioku.Session.ReadModel.SessionRow`. Shikigami — `Shikigami.Agent.Loader`
(`loadAgentsReport`, `loadedAgents`), `Shikigami.Agent.Decl.AgentDecl`,
`Shikigami.Agent.Run.behaviorKindText`, `Shikigami.Memory.Access`, `Shikigami.Log`, the two
generated `workflowName` constants, and `Shikigami.App.Config`.

**Signatures that must exist at the end**, with full paths:

```haskell
-- shikigami-server/src/Shikigami/Server/Command/Agents.hs (new)
runAgentsList :: AppConfig -> OutputMode -> IO ()

-- shikigami-server/src/Shikigami/Server/Command/Runs.hs (new)
runRunsShow :: AppConfig -> Text -> OutputMode -> IO ()

-- shikigami-server/src/Shikigami/Server/Command/Ops.hs (new — the keiro-ops mount)
shikigamiOpsHooks :: AppConfig -> IO AppHooks
runOps           :: AppConfig -> OpsInvocation -> IO ()

-- shikigami-server/src/Shikigami/Server/Command.hs (extended)
-- adminSubcommands gains "agents", "runs", and the mounted keiro-ops group
```

There is deliberately **no** `Shikigami.Operator.Query`, no `PageSize`/`PageRequest`/`RunCursor`/
`StepCursor`, and no `runRunsList`/`runRunsCancel`/`runDlq*`/`runOutboxStatus`. Those were the
2026-07-08 plan's hand-built substrate layer; keiro owns all of it now.

**Cross-plan contracts** (mirrored in MasterPlan 6's Integration Points).
`docs/plans/20-explicit-trigger-routing-scheduler-catch-up-policy-and-loud-failures.md` owns the
agent load report `agents list` renders — do not call `loadAgent` or walk the directory here.
`docs/plans/23-agent-lifecycle-control-with-meibo-principals.md` extends this same `agents` group
with principal and lifecycle state and adds `sync`; it must find one group to extend, not a
competing one. `docs/plans/54-key-durable-agent-state-by-meibo-principal.md` re-keys durable state
by principal, which changes what `agents list` and `runs show` should display — coordinate the
column set rather than adding a second listing.
`docs/plans/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md` owns in-workflow
run timeouts (a run that cancels itself on overrun) and the DLQ configuration; this plan owns the
operator-issued cancel, and both now go through the same `cancelWorkflow`.
`docs/plans/29-health-liveness-and-worker-loop-supervision.md` tells an operator *that* something
is wrong; this plan gives them the verbs to find out *what*.
`docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md` owns
`docs/operations/configuration.md` and must gain any setting this mount introduces.


## Revision Notes

- 2026-07-22: Made plan 20's `AgentLoadReport` a hard dependency and assigned this plan ownership
  of the `agents` command group. Plan 23 now extends that command instead of defining a competing
  `agents list`.

- 2026-07-22: Rebased on plans 36/37, replaced PGMQ archive coupling with plan 17's real DLQ and
  complete inspect/repair/replay/discard flow, required schema-qualified public queries, and
  expanded CLI parser/dispatch/confirmation tests.

- 2026-08-19: **Full refresh; the plan changed shape.** Superseded by this note: the 2026-07-30
  "Portfolio Reconciliation" section.

  *Why the refresh was needed.* `docs/architecture/implementation-order.md` names this plan among
  the 19 open plans citing `shikigami-cli` or `shikigami-core/src/Shikigami/Worker.hs`, both
  deleted by plan 36, and records a standing requirement to audit citations immediately before
  implementing. Every path in this plan was wrong, the CLI has seven subcommands rather than
  twelve, `Shikigami.Api.Agent`/`Shikigami.Api.RunJob` were renamed, `getEnv` was replaced by
  Settei, and the kioku session table moved from the `kiroku` schema to `kioku.sessions`.

  *The shape change.* `keiro-ops 0.13.0.0` is released on Hackage and ships an embeddable command
  tree covering workflows, timers, the outbox, PGMQ dead letters, and more, with hooks
  (`Keiro.Ops.Embed.AppHooks`) for the operations that need an application's compiled values.
  Keiro ADR-28 — "operator commands wrap supported library APIs and respect schema ownership" —
  makes wrapping those exported operations mandatory and forbids the ad hoc SQL over
  `keiro.keiro_workflows` and the kioku session table that this plan's Milestones 2 and 4
  specified. So Milestones 2, 3, and 4 are rewritten as "mount the tree, populate the hooks that
  fit, and add only what neither library can know". `Shikigami.Operator.Query` is struck along
  with `runRunsList`, `runRunsCancel`, the four `runDlq*` verbs, `runOutboxStatus`, and the
  bespoke pagination types. The plan gets smaller, and the operator gets *more* verbs — journal
  decoding, awakeable inspection, lease release, workflow resurrection, outbox maintenance, and
  stuck-timer triage were all out of scope and all arrive with the mount.

  *Two specific corrections.* The Decision Log's central claim — "keiro has no top-level cancel
  workflow by id function" — is false at keiro 0.13; `cancelWorkflow` exists and returns a
  three-way outcome the append-based version would have had to reconstruct. And the confirmation
  flag becomes `--force` rather than `--confirm`, because that is what `keiro-ops` already spells
  it, and one binary with two words for one concept is a usability bug.

  *One dependency satisfied, one still open.* Plan 20's `AgentLoadReport` landed through plan 33,
  so Milestone 1 is unblocked, and plan 33's new `enabled` field gives the listing a column it
  needs — a disabled agent is otherwise indistinguishable from an enabled one. Kioku IR-2
  (subject-reference session lookup) is still proposed and may affect how Milestone 3 finds a
  session if the workflow and session identities turn out to be independent.

  *One risk surfaced.* `keiro-ops`'s `ResumeHook` wants a `WorkflowRegistry '[Store, Error
  StoreError, IOE]` and shikigami's registry is over `Kioku.App.AppEffects`, which is a wider row.
  Recorded in Surprises & Discoveries with a resolution and a cheap fallback (leave the hook
  unpopulated; the worker already runs the resume loop). `TimerFire` has no such problem, but its
  Shikigami implementation lives in `shikigami-workers`, which `shikigami-server` may not import —
  a package-boundary question Milestone 2 must answer before promising the verb.
