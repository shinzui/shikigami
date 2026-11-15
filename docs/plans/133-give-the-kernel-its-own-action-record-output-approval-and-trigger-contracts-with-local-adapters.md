---
id: 133
slug: give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters
title: "Give the kernel its own action, record, output, approval and trigger contracts with local adapters"
kind: exec-plan
created_at: 2026-11-15T14:37:16Z
intention: "intention_01m7fq4tf3ejrt0tjxvsy8ejdt"
master_plan: "docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-15T14:37:16Z
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-15T14:44:49Z
      mode: "other"
      note: "Drafted plan body under MasterPlan 22"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-15T15:08:44Z
      mode: "update"
      note: "Composition default output: registry default, admission-time resolution pinned in the journal (user decision 2026-11-15)"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-15T15:57:53Z
      mode: "implement"
      note: "M1 implemented: kernel Action, Authority port, action record, Kikan-En adapter, record list, ADR-123"
---

# Give the kernel its own action, record, output, approval and trigger contracts with local adapters

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Shikigami runs declared agents as durable workflows. Today the contracts through which a run
touches the outside world belong to another product. Every authorization decision takes
`AgentAction`, a closed type imported from the Kikan-En contract package, so the kernel cannot
name an action of its own (running a declared CLI tool, launching a coding agent) without a
Kikan-En release. A declaration's outputs are a closed list of Kikan services (Kawa, Kizashi,
Rei, Danwa, channel egress). A human approval can be asked only through Danwa or Kizashi. A
declaration must name a schedule, stream or event trigger; it cannot say "the operator runs
this". And an authorization decision is only written to the log, so nothing durable answers
"what did this run do, and who allowed it".

After this plan the kernel owns five contracts, called *ports*: the action vocabulary with
its authority, the action record, outputs, approval channels and triggers. Kikan's services
become adapters of those ports, and local adapters ship beside them. The operator can see it
working three ways on this Mac. First, any run, even one whose actions are all refused,
leaves rows that `shikigami record list --run <id>` prints: one per decision, with the
principal, the action and who decided. Second, a declaration with no trigger line and no
`outputs` line runs under the `LocalOperator` tier, pauses at an approval that arrives as a
file in a local inbox, and writes its result as a report file, because the stock composition's
default output is `local.report`. Third, that same declaration
runs unchanged under a composition that uses the Kikan adapters, and the two action records
differ only in who decided.

This is EP-8 of
`docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md`.
Its first milestone has no prerequisite and is the first work of that initiative.


## Progress

- [x] M1 (2026-11-15): The kernel action type, the authority port and the action record exist. The
  Kikan-En authorizer is an adapter that maps kernel actions to `AgentAction`. Every decision
  is appended to the record before the effect proceeds, and a failed append is a refusal. No
  module outside the adapter imports `Kikan.En.Action`. A real `shikigami-agent-run` on this
  Mac leaves decisions that `shikigami record list` prints, and behavior is otherwise
  unchanged. The new ADR is written.
  Evidence: `shikigami-agent-run --agent agents/triage-note.dhall` (stub provider, after
  `shikigami grants grant triage-note KizashiSignal`) printed
  `… authority.decided emit_output kizashi.signal:person:nadeem refused unavailable: …
  (source: none)` through `shikigami record list --limit 5`. `AuthoritySpec`, `RecordSpec`,
  `ActionRecordStoreSpec` (including an unreachable store refusing an allowed action) and the
  new architecture case pass; `just haskell-conventions` passes;
  [ADR-123](../adr/0123-the-kernel-owns-its-action-vocabulary-authority-port-and-action-record.md)
  is written. The full-suite and `just keiro-gate` results are recorded under Outcomes.
- [ ] M2: Outputs, approval channels and triggers are kernel contracts. `sinks` is replaced
  by `outputs` with an adapter registry validated at load; the five Kikan sinks are
  registered adapters; `local.report` and `local.inbox` exist; `Trigger.Manual` is the
  default; and a declaration with no outputs receives the composition's default output,
  resolved at admission and pinned in the journal. A real `LocalOperator` run of a
  declaration with no trigger line and no `outputs` line pauses at a local-inbox approval,
  resumes, and writes its report through the default. (Needs EP-1.)
- [ ] M3: The portability check passes. One declaration that uses only kernel vocabulary
  runs under the stock composition and under a composition with the Kikan adapters, and
  `shikigami record check` asserts invariants K1 to K8 from each run's record. (Needs EP-1.)


## Surprises & Discoveries

These came from reading the working tree on 2026-11-15, before implementation.

- Observation: The Kikan-En action sum has no constructor for two effects this initiative
  adds, and it splits one kernel effect three ways.
  Evidence: `AgentAction` in `kikan-en-contract/src/Kikan/En/Action.hs`
  (`mori://shinzui/kikan-en/packages/kikan-en-contract`) has eleven constructors:
  `ConnectCapability`, `DiscoverCapabilityTools`, `InvokeCapabilityTool`, `ReadWorkspace`,
  `WriteWorkspace`, `ExecuteWorkspace`, `DispatchKawa`, `DispatchKizashi`, `ActOnIntention`,
  `AttachDanwa` and `DispatchChannel`. The kernel's `UseCapability` therefore carries an
  operation (connect, discover or invoke) so the adapter can map it exactly.
- Observation: The authorizer record carries a Kawa field, and the sink gate recovers the
  authorizer by matching on the grant source's constructor.
  Evidence: `ActionAuthorizer {authorize, kawaSource}` in
  `shikigami-core/src/Shikigami/Action/Authorization.hs`; `actionAuthorizerFor` in
  `shikigami-core/src/Shikigami/Sink/GrantStore.hs` returns allow-all for `StaticGrants` and
  deny-all for a bare `DbGrants`.
- Observation: The sink declaration is durable in three places, not one.
  Evidence: `AgentDecl` is journaled by the `lookup-agent` step; `SinkIntent` in
  `shikigami-core/src/Shikigami/Sink/Intent.hs` carries `sink :: Sink` into the outbox; and
  `SinkResult {kind :: SinkKind, ...}` in `Sink/Types.hs` is journaled per dispatch.
- Observation: No Shikigami code builds Kikan-En's `ReadWorkspace`, `WriteWorkspace` or
  `ExecuteWorkspace`, and none calls `DiscoverCapabilityTools`. Every workspace, worker-session,
  objective and maintenance effect is an `InvokeCapabilityTool` on a reserved `shikigami.*`
  capability whose tool name is a digest of the exact effect.
  Evidence: the M1 conversion touched `Workspace/Provider.hs`, `WorkerSession/Capability.hs`,
  `Objective/{Capability,Runtime}.hs` and `Workspace/Cleanup.hs`; all used
  `mkCapabilityToolTarget "shikigami.…"`. This is why the kernel sum has two constructors.
- Observation: The migration checksum lock was stale again before this plan: it had no line
  for `0049-recurring-mandates.sql`. See FRIC-71 (a recurrence of FRIC-58).
- Observation: The dev database did not exist on this Mac; `just create-database` created and
  migrated it. Nothing was dropped.
- Observation: Approval channels are chosen in code as well as configuration.
  Evidence: `ViaDanwa` is hard-coded in `shikigami-core/src/Shikigami/Execution/Driver.hs`
  (tool permission asks) and in `Flow/AtRiskCustomer.hs`; `ViaKizashi` in
  `Initiative/Notice.hs`; the default comes from `approvalChannelSetting` in `App/Config.hs`.


## Decision Log

- Decision: `UseCapability` carries a `CapabilityOperation` (`ConnectProvider`,
  `DiscoverTools` or `InvokeTool`) instead of being one undifferentiated action.
  Rationale: The MasterPlan sketch wrote one constructor commented "connect, discover or
  invoke". ADR-36 authorizes each of the three afresh, and Kikan-En has one constructor for
  each, so the adapter needs the distinction to map without guessing.
  Date: 2026-11-15
- Decision: `Principal` in the port signatures is the existing checked value
  `DeclarationCoordinate "principal"`, exported from `Shikigami.Authority` under that name.
  Rationale: About twenty modules already pass that coordinate. A second principal type
  would be a rename with no added meaning.
  Date: 2026-11-15
- Decision: An output's configuration is carried in Dhall and in the journal as canonical
  JSON text, and each adapter ships a typed Dhall helper that produces it.
  Rationale: Dhall has no open sum, so an open contract cannot be a union. A helper keeps
  authoring typed (`K.kizashiSignal { ... }`), while the kernel sees `{ kind, config }` and
  asks the registered adapter to validate `config` when the declaration loads.
  Date: 2026-11-15
- Decision: A declaration whose `outputs` is empty receives its composition's default
  output. The default is a property of the `OutputRegistry`, it is resolved when the run is
  admitted and journaled there, and an explicit `outputs` list always wins. The stock
  composition's default is `local.report`; a composition may register none, and then the
  result stays in the journal as it does today.
  Rationale: The user decided on 2026-11-15 to "use composition default output", so that a
  routine agent can be promoted into the Kikan distribution unchanged (whose default,
  `kawa.digest`, EP-10 registers). The default is never invisible: `shikigami validate`,
  the confirmation prompt and the `run.admitted` record entry all show the resolved output
  and say it came from the composition. Pinning it in the journal means a later change of
  the composition's default cannot change where an admitted run reports.
  Date: 2026-11-15
- Decision: The action record for durable runs is a PostgreSQL table in the Shikigami
  schema; the database-free command writes a JSON Lines file.
  Rationale: Every durable run already needs that database, and the run evidence lives
  there, so one query answers "what did this run do". `shikigami-run-behavior` has no
  database by design ([ADR-3](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md)).
  Date: 2026-11-15
- Decision: The M1 `Action` has two constructors, `UseCapability` (with `ConnectProvider` or
  `InvokeTool`) and `EmitOutput`. `ReadWorkspace`, `WriteWorkspace`, `ExecuteWorkspace`,
  `DiscoverTools`, `RequestApproval` and `DelegateRun` are not declared.
  Rationale: ADR-1. None has an executed call site (see Surprises); the kernel's own effects
  are capability tools of `shikigami.*`. M2 adds `RequestApproval` with the approval-channel
  port that asks it, and the plan that first executes a delegation authorization adds
  `DelegateRun`.
  Date: 2026-11-15
- Decision: `Authority` is an abstract record read with `authority.decide` and
  `authority.source` (`HasField` instances), built with `authority source decide`. It carries
  a hidden run context: `scopeToRun (Maybe WorkflowId) AgentName` sets it, and `recorded`
  writes it into each event. `Decision` is `{action, reference, expiresAt}`; who decided is
  the authority's `source`, recorded as `decidedBy`.
  Rationale: The worker builds one authority per process, but each record event must carry
  its run. A sealed constructor makes scoping and recording composable without threading a
  run argument through about twenty call sites. `observeDecisions` replaces the one fixture
  that wrapped `authorize` by hand.
  Date: 2026-11-15
- Decision: The kernel target of a `kawa.digest` output is the sink's subject kind and verb;
  the Kikan-En adapter maps every `kawa.digest` to `DispatchKawa` on its configured Kawa source
  (`KikanEnMapping.kawaSource`). The other outputs' targets are the resolved recipient,
  intention, Danwa thread or channel provider and conversation. The autonomy context for
  `ActOnIntention` is built by the adapter from its own clock.
  Rationale: The Kawa source is a deployment fact of the Kikan composition, not something the
  kernel names. The other Kikan targets were already the resolved sink coordinates.
  Date: 2026-11-15
- Decision: `App.Config` reads Kikan-En schema hashes through
  `Shikigami.Authority.KikanEn.Settings`, a re-export, so that the architecture rule "only the
  adapter imports Kikan-En" holds without moving configuration in M1.
  Rationale: Moving the setting decoders is EP-10's work; a re-export keeps the rule checkable
  now.
  Date: 2026-11-15
- Decision: `shikigami-run-behavior` refuses every action when its record file cannot be
  opened, rather than refusing to start.
  Rationale: An agent that needs no external action still runs; an action that cannot be
  recorded never proceeds (K3).
  Date: 2026-11-15
- Decision: The counter is the OpenTelemetry instrument `shikigami.record.events` with
  attributes `record.kind` and `decision` (`append_failed` for a refused append), exported as
  `shikigami_record_events_total`.
  Rationale: The existing instruments use dotted OpenTelemetry names; the Prometheus spelling
  in the plan is the exporter's rendering of the same instrument.
  Date: 2026-11-15
- Decision: Server HTTP objective handlers, `shikigami objective-trackers`, the workspace
  maintenance command and the conversation tool wiring in `Agent/Conversation.hs` keep
  composing `denyAll` without a record in M1.
  Rationale: Their decisions are refusals that reach no effect, and they have no store pool in
  scope. ADR-123 records the gap; recording them belongs to the composition that owns them.
  Date: 2026-11-15
- Decision: Pre-release recheck for M1, 2026-11-15: `git tag --list` is empty; no deployment
  or user exists (MasterPlan 22, `docs/workflow-versioning.md` 2026-10-30 confirmation); no
  stored payload carries an authorization decision; no external wire consumer exists. M1
  changes no journaled value.
  Rationale: Required before every milestone by Concrete Steps.
  Date: 2026-11-15
- Decision: The C11 sink-grant table stays, as an optional requirement an output adapter
  declares. The Kikan adapters require it; `local.report` does not.
  Rationale: The grant table is existing Kikan behavior that must not change in M2. Under
  `LocalOperator` the authority port alone decides `EmitOutput`.
  Date: 2026-11-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a Haskell monorepo of seven Cabal packages. `shikigami-core` is the domain
library. `shikigami-agent` holds light one-off commands (`shikigami-agent-run`,
`shikigami-run-behavior`), `shikigami-workers` the background processes (`shikigami-worker`,
`shikigami-scheduler`, the stream and event consumers), and `shikigami-server` the HTTP
server and the `shikigami` admin command. Records use `DuplicateRecordFields` with unprefixed
strict fields (`AGENTS.md`).

An *agent* is a Dhall file typed by `schema/Agent.dhall` and decoded into `AgentDecl` in
`shikigami-core/src/Shikigami/Agent/Decl.hs`. A *durable workflow* is a function run by the
keiro library (`mori://shinzui/keiro`) whose side effects are wrapped in named *steps*; each
step's result is appended to a PostgreSQL *journal*, and after a crash the function replays,
answering completed steps from the journal. The agent-run workflow is in
`shikigami-core/src/Shikigami/Agent/Workflow.hs`, and its step labels are declared in
`domain/shikigami/agent-run.keiro`. `docs/workflow-versioning.md` governs any change to a
workflow body or a journaled value, and `just keiro-gate` checks it.

**Authorization today.** `Shikigami.Action.Authorization` defines
`ActionAuthorizer {authorize :: DeclarationCoordinate "principal" -> AgentAction -> IO (Either
ActionAuthorizationFailure ActionAuthorizationDecision), kawaSource}`. `AgentAction` and its
target types come from `Kikan.En.Action`. Three values exist: `denyAllActionAuthorizer`,
`allowAllActionAuthorizerForTests` and `newKikanActionAuthorizer`, which calls the Kikan-En
service with a Shomei token and verifies the returned proof. `logDecision` writes a log line;
no table holds decisions. `ActionAuthorizer` is consumed in `shikigami-core` by
`Agent/Conversation.hs`, `Agent/Workflow.hs`, `Capability/Provider.hs`, `Execution/Tools.hs`,
`Flow/Workers.hs`, `Objective/{Capability,Coordination,Runtime}.hs`,
`Objective/Tracker/Runtime.hs`, `Sink/{Authorization,GrantStore}.hs` and
`WorkerSession/{Capability,Tools}.hs`; in `shikigami-workers` by `Workers/Config.hs`,
`Workers/Command/Worker.hs` and nine `Workspace/*` modules; in `shikigami-server` by the
objective handlers and two commands; and in `shikigami-agent` by `Capability/OneOff.hs`,
`Command/AgentRun.hs` and `Command/RunBehavior.hs`. Modules that construct Kikan targets
directly are `Capability/Provider.hs`, `Sink/Authorization.hs`, `Objective/Capability.hs`,
`Objective/Runtime.hs`, `WorkerSession/Capability.hs`, `Workspace/Provider.hs`, `App/Config.hs`
and, in the workers, `Workspace/GitProvider.hs` and `Workspace/Cleanup.hs`. The worker selects
its authorizer from the setting `authorization.actions.mode`
(`Action/Authorization/Config.hs`); the light commands and conversations hard-code deny-all.

**Outputs today.** `Sink` in `Agent/Decl.hs` is a closed sum: `KawaDigest`, `KizashiSignal`,
`ReiAction`, `DanwaConversation`, `ChannelEgress`. `SinkKind` in `Sink/Permission.hs` mirrors
it. `Sink.dispatch` (`shikigami-core/src/Shikigami/Sink.hs`) checks the principal's
lifecycle, checks the *C11 grant* (a row in `shikigami.sink_grants` saying this agent may use
this sink kind; `Sink/GrantStore.hs`), authorizes the exact action
(`Sink/Authorization.hs`), then `runSink` matches on the constructor and calls a per-service
client. `SinkContext` (`Sink/Types.hs`) has one configuration field per service. Delivery is
already generic in mechanism: a run journals a `SinkIntent`, writes it to keiro's
transactional *outbox* (a table drained by a publisher after commit), and records a
`DeliveryReceipt` in `shikigami.sink_deliveries` (`Sink/Intent.hs`, `Sink/Delivery.hs`).

**Approvals today.** An approval is a `shikigami.approval` child workflow
([ADR-30](../adr/0030-an-approval-request-is-a-durable-child-workflow.md)).
`ApprovalRequest {prompt, context, channel}` and the closed `ApprovalChannel = ViaKizashi |
ViaDanwa` are in `Agent/Approval.hs`. `ApprovalNotifier {recordPark, postAsk}` is in
`Agent/Approval/Workflow.hs`, and its one implementation, `approvalNotifier` in
`Agent/Approval/Notification.hs`, matches on the channel and posts to Danwa or Kizashi. The
ask contains an opaque one-shot token (an `AwakeableId`); `shikigami resolve-approval TOKEN`
resolves it. The token is never derived from the public review id and never logged.

**Triggers today.** `Trigger = Schedule {cron} | Stream {match} | Event {eventType}` in
`Agent/Decl.hs`; the field is required in `schema/Agent.dhall`. All intake ends in a `RunJob`
(`Agent/RunJob.hs`) whose `TriggerKind` is `TriggeredBySchedule`, `TriggeredByStream`,
`TriggeredByEvent` or `TriggeredByDelegation`, mirrored by `RunTriggerKind` in
`domain/shikigami/run-jobs.keiro`. `shikigami-agent-run` starts a run by hand and labels it
`TriggeredByEvent`.

**What sibling plans supply.** EP-1
(`docs/plans/126-run-declared-agents-on-the-operator-s-own-machine-through-a-local-operator-trust-tier.md`)
adds `data TrustTier = LocalOperator | Contained | MultiTenant` and a composition that
resolves, per run, the ports that tier uses. Under `LocalOperator` the operator is the
authority. M1 of this plan needs none of it. M2 and M3 install local adapters through EP-1's
`LocalOperator` composition and so need EP-1 accepted.

**The invariants this plan makes checkable.** The MasterPlan states eight guarantees that
hold in every composition. K1: every run and action carries a principal, and a paused
principal is refused. K2: exactly one authority decides every external action immediately
before the effect, failing closed. K3: every decision and effect is appended to the action
record before the effect proceeds, where the agent cannot write. K4: a run pins the exact
declaration it executes. K5: every run spends under a resource root with deadlines. K6:
effects happen in journaled steps and an uncertain effect is never retried automatically. K7:
observed content is evidence, never instruction. K8: run admission is idempotent on its key.

Relevant ADRs.
[ADR-36](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md) requires
fresh, exact authorization immediately before every external action, deny-all when
unconfigured; this plan restates it over the kernel's own type.
[ADR-25](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) makes a
declaration a request that an operator catalog grants; outputs follow the same rule.
[ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) and
`docs/workflow-versioning.md` allow unreleased declaration and journal shapes to be replaced
directly after rechecking four facts.
[ADR-11](../adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md) omits
defaulted fields from the journaled declaration.
[ADR-30](../adr/0030-an-approval-request-is-a-durable-child-workflow.md) governs approval
tokens. [ADR-80](../adr/0080-opaque-checked-values-do-not-expose-generic-construction.md) and
[ADR-81](../adr/0081-validated-results-use-private-seals-and-public-read-views.md) govern
checked newtypes and sealed registries.
[ADR-75](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md) requires new
namespace roots to be listed in `tools/style/module-ownership.json`.
[ADR-1](../adr/0001-declare-only-what-the-runtime-executes.md): a contract is declared only
when the runtime executes it, so `LaunchCodingAgent` and `RunDeclaredTool` are added by the
plans that execute them, not here.


## Plan of Work

### Milestone 1: the kernel's action type, authority port and action record

This milestone changes types, not behavior. At its end the authorization path speaks a
kernel-owned vocabulary, Kikan-En is one adapter of it, and every decision is a durable row.

Add `shikigami-core/src/Shikigami/Authority.hs` (new root `Authority`, listed in
`tools/style/module-ownership.json`):

```haskell
type Principal = DeclarationCoordinate "principal"

data Action
  = UseCapability !CapabilityOperation !CapabilityTarget
  | ReadWorkspace !WorkspaceTarget
  | WriteWorkspace !WorkspaceTarget
  | ExecuteWorkspace !WorkspaceCommandTarget
  | EmitOutput !OutputKind !OutputTarget
  | RequestApproval !ApprovalChannelKind
  | DelegateRun !AgentName
data CapabilityOperation = ConnectProvider | DiscoverTools | InvokeTool !ToolCoordinate

newtype Authority = Authority
  { decide :: Principal -> Action -> IO (Either AuthorityFailure Decision) }

data AuthorityFailure
  = PolicyDenied !BoundedText | AuthorityUnavailable !BoundedText
  | ProofRejected !BoundedText | InvalidCoordinates !BoundedText
data Decision = Decision
  { action :: !Action, decidedBy :: !DecisionSource, reference :: !DecisionReference
  , expiresAt :: !(Maybe UTCTime) }
data DecisionSource = DecidedByOperator | DecidedByService !ServiceName | DecidedByFixture

actionTag :: Action -> Text          -- "use_capability", "emit_output", ...
actionResource :: Action -> Text     -- canonical, bounded; never tool input or content
denyAll :: Authority                 -- the default when nothing is composed
allowAllForTests :: Authority
recorded :: RecordContext -> ActionRecord -> Authority -> Authority
```

The target types (`CapabilityTarget`, `WorkspaceTarget`, `WorkspaceCommandTarget`,
`OutputTarget`) are kernel-owned sealed values with checked factories, built from the same
inputs the Kikan targets take today. `OutputKind` and `ApprovalChannelKind` are checked dotted
names (`[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+`, at most 64 bytes); until M2 the only output
kinds are the five Kikan ones. The MasterPlan's sketch also lists `RunDeclaredTool` and
`LaunchCodingAgent`; EP-3 and EP-2 add those constructors with their executors (ADR-1).

`recorded` is the only way a composition root may install an authority. It runs `decide`,
appends one `authority.decided` event, and returns `AuthorityUnavailable "action record
unavailable"` if the append fails, so an unrecorded action never proceeds (K3).

Add `shikigami-core/src/Shikigami/Record.hs` (new root `Record`):

```haskell
newtype RecordKind = RecordKind Text   -- mkRecordKind: dotted name, as above
newtype ActionRecord = ActionRecord { append :: RecordEvent -> IO (Either RecordError ()) }
data RecordEvent = RecordEvent
  { at :: !UTCTime, run :: !(Maybe WorkflowId), principal :: !Principal
  , tier :: !TierLabel, agent :: !AgentName, entry :: !RecordEntry }
data RecordEntry   -- sealed: mkRecordEntry refuses a payload over 8 KiB of canonical JSON
recordEntry :: RecordEntry -> (RecordKind, Value)
data RecordError = RecordStoreUnavailable !BoundedText | RecordEntryTooLarge !Natural

postgresRecord :: Pool -> ActionRecord
fileRecord :: FilePath -> IO (Either RecordError ActionRecord)   -- JSON Lines, mode 0600
readRecord :: Pool -> RecordQuery -> IO (Either RecordError [RecordEvent])
data RecordQuery = RecordQuery
  { run :: !(Maybe WorkflowId), kinds :: !KindFilter, limit :: !RecordLimit }
data KindFilter = AllKinds | KindPrefix !Text | RefusalsOnly
```

A producer owns its kind and a typed constructor, kept beside the code that performs the
effect; for example `Shikigami.Authority` exports `decisionEntry :: Principal -> Action ->
Either AuthorityFailure Decision -> RecordEntry` for the kind `authority.decided`. A new
effect therefore needs no change to a shared sum. `TierLabel` is a checked text
(`unspecified` until EP-1 supplies `TrustTier`). A payload never contains tool input, file
content or a credential. Add the migration
`shikigami-migrations/sql-migrations/0050-action-record.sql`: table
`shikigami.action_record (seq bigint identity primary key, at timestamptz, run_id text null,
principal text, tier text, agent text, kind text, payload jsonb)` with an index on
`(run_id, seq)`. Rows are insert-only; the migration grants no update or delete to the
runtime role if the repository's role setup distinguishes one, and records in the plan if it
does not. Update `manifest` and `migrations.lock` with the repository's migration recipe.

Add the adapter `shikigami-core/src/Shikigami/Authority/KikanEn.hs`, which EP-10 later moves
out of the core. It holds everything `Shikigami.Action.Authorization` holds today, plus:

```haskell
data KikanEnMapping = KikanEnMapping { kawaSource :: !(ActivityCoordinate "source") }
toAgentAction :: KikanEnMapping -> UTCTime -> Action -> Either UnmappedAction AgentAction
data UnmappedAction = NoKikanAction !Text | InvalidKikanTarget !Text
kikanEnAuthority :: Log.Logger -> Text -> KikanEnMapping -> KikanEnClient
  -> IO (Either Text ShomeiAccessToken) -> Authority
```

`UseCapability ConnectProvider` maps to `ConnectCapability`, `DiscoverTools` to
`DiscoverCapabilityTools`, `InvokeTool` to `InvokeCapabilityTool`; the workspace actions map
one to one; `EmitOutput` maps by kind to `DispatchKawa`, `DispatchKizashi`, `ActOnIntention`,
`AttachDanwa` or `DispatchChannel`. `RequestApproval`, `DelegateRun` and any output kind
Kikan-En does not know map to `NoKikanAction` and are refused with `PolicyDenied`, which is
what happens today because nothing asks. The `kawaSource` field leaves the port.

Then convert the consumers listed in Context: each takes an `Authority` and builds kernel
targets. `Sink/Authorization.hs` builds `EmitOutput` targets. `GrantSource`'s
`ActionGatedGrants` holds an `Authority`. Delete `Shikigami.Action.Authorization` and
`Action/Authorization/Config.hs` in favour of `Authority/KikanEn/Config.hs`, keeping the
setting `authorization.actions.mode` and its values byte for byte. Every composition root
(`Workers/Command/Worker.hs`, `Workers/Config.hs`, `AgentRun.hs`, `RunBehavior.hs`, the
conversation paths in `Agent/Conversation.hs`, the server objective handlers) wraps its
authority with `recorded`: the worker and `shikigami-agent-run` over `postgresRecord`, and
`shikigami-run-behavior` over `fileRecord` at `$XDG_STATE_HOME/shikigami/record.jsonl`. Add an
architecture test in `shikigami-core/test/Shikigami/PackageArchitectureSpec.hs`: no module
outside `Shikigami.Authority.KikanEn*` imports `Kikan.En.Action` or `Kikan.En.Client`.

Add the admin verb `shikigami record list [--run ID] [--refusals] [--kind PREFIX] [--limit N]
[--json]` in a new `shikigami-server/src/Shikigami/Server/Command/Record.hs`, listed in
`compositionModules`. It prints events oldest first: time, run, agent, principal, kind, action
tag, resource, decision and source. Log one line `record.appended` per event at debug level
and `record.append_failed` at error level, and add the counter
`shikigami_record_events_total{kind,decision}` beside the existing metrics.

Write the next free ADR in `docs/adr/` (0123 on 2026-11-15), "The kernel owns its action
vocabulary, authority port and action record". It restates ADR-36 over `Action`: fresh exact
authorization before every external action, deny-all when nothing is composed, one authority
per run, a decision recorded before the effect, and service authorizers as adapters that
refuse what they cannot map. Add an "Amended by" line to ADR-36's References.

Journaled values do not change in M1: `ActionAuthorizationDecision` is not journaled, and
step results keep their rendered failure text. Still run the recheck and gate below.

### Milestone 2: outputs, approval channels and the manual trigger

This milestone needs EP-1 accepted. It replaces three closed sums with kernel contracts and
adds the local adapters that give a `LocalOperator` run somewhere to send a result and
somewhere to ask.

*Outputs.* Add `shikigami-core/src/Shikigami/Output.hs` (new root `Output`):

```haskell
data OutputDecl = OutputDecl { kind :: !OutputKind, config :: !CanonicalJson }
data OutputAdapter = OutputAdapter
  { kind :: !OutputKind
  , validate :: CanonicalJson -> Either OutputConfigError ValidatedOutput
  , target :: ValidatedOutput -> OutputResolution -> Either Text OutputTarget
  , grant :: !GrantRequirement                  -- RequiresSinkGrant !Text | NoSinkGrant
  , deliver :: OutputDelivery -> IO OutputOutcome }
data OutputRegistry   -- sealed; mkOutputRegistry refuses duplicate kinds (ADR-81)
data DefaultOutput = NoDefaultOutput | DefaultOutput !OutputDecl   -- a closed sum, not a Maybe
mkOutputRegistry :: [OutputAdapter] -> DefaultOutput -> Either (NonEmpty OutputRegistryError) OutputRegistry
  -- refuses a default whose kind is unregistered or whose config its adapter rejects
registeredKinds :: OutputRegistry -> [OutputKind]
validateOutputs :: OutputRegistry -> [OutputDecl] -> Either (NonEmpty OutputLoadError) ()
data OutputLoadError
  = UnregisteredOutputKind !OutputKind ![OutputKind]   -- names what is registered
  | InvalidOutputConfig !OutputKind !OutputConfigError

data ResolvedOutputs
  = DeclaredOutputs !(NonEmpty OutputDecl)   -- the declaration's own list always wins
  | CompositionDefault !OutputDecl           -- the declaration listed none
  | JournalOnly                              -- none declared and the composition has no default
resolveOutputs :: OutputRegistry -> [OutputDecl] -> ResolvedOutputs   -- pure and total
resolvedOutputList :: ResolvedOutputs -> [OutputDecl]
```

*Default output.* A composition passes its default to `mkOutputRegistry` once, at startup.
The agent-run workflow gains one journaled step, `resolve-outputs`, immediately after
`lookup-agent` and inside admission: it runs `resolveOutputs` over the journaled declaration
and stores the `ResolvedOutputs`. Dispatch reads that journaled value and never consults the
registry's default again, so a run admitted under one default keeps it after a restart with
another. The declaration itself is not rewritten: its journaled JSON and its digest still say
"no outputs", which keeps the declaration portable. Declare the step in
`domain/shikigami/agent-run.keiro` and record its `keiro-diff` finding under the pre-release
exception. The `run.admitted` record entry carries the resolved kinds and whether they were
declared or defaulted. `shikigami validate` prints the same resolution for the registry it was
given, for example `outputs: local.report (composition default)`, and EP-1's confirmation
prompt shows it through `resolveOutputs`, so the operator approves where the result goes.

`OutputDelivery` carries what `SinkContext` carries that is not service-specific (identity,
directory handle, run id, ordinal, trace headers, occurred-at, the triggering activity id,
the receipt guard, the logger) plus the validated output and the behavior's result value.
`OutputOutcome` is today's `SinkOutcome` without the deprecated `Stubbed` constructor.
`dispatch` keeps its order (lifecycle, grant when the adapter requires one, `EmitOutput`
authorization, delivery) and replaces `runSink`'s `case` with a registry lookup. `SinkIntent`
carries `output :: OutputDecl` in place of `sink :: Sink`, and `SinkResult.kind` becomes an
`OutputKind`. The intent, outbox and receipt code in `Sink/Intent.hs` and `Sink/Delivery.hs`
is otherwise reused as it is. Service configuration leaves `SinkContext`: each Kikan adapter
closes over its own configuration and HTTP client when it is built.

Register the five existing sinks as adapters in a new
`shikigami-core/src/Shikigami/Output/Kikan.hs` (`kikanOutputAdapters :: KikanOutputConfig ->
[OutputAdapter]`), with kinds `kawa.digest`, `kizashi.signal`, `rei.action`,
`danwa.conversation` and `channel.egress`, each `RequiresSinkGrant` with its existing label
(`KawaDigest` and so on), and each `validate` decoding exactly the fields its `Sink`
constructor has today. They stay in the core until EP-10 moves them. Add
`shikigami-core/src/Shikigami/Output/Local.hs` with `localReportAdapter :: ReportRoot ->
OutputAdapter` for kind `local.report`: configuration `{ format : Markdown | Json, name :
optional file stem }`; it writes
`<state>/reports/<agent>/<run-id>-<ordinal>.<ext>` atomically with mode 0600, bounds the
file at 1 MiB (a larger result is truncated with a marker and reported as such in the
outcome), returns `Delivered` with the path, and appends `output.delivered`. `ReportRoot` is
built only by the composition, so a declaration cannot choose a directory.

In `schema/Agent.dhall`, replace `sinks : List Sink` with `outputs : List Output`, where
`Output = { kind : Text, config : Text }` and the default is the empty list. Add
`schema/outputs/Local.dhall` (`report`) and `schema/outputs/Kikan.dhall` (`kawaDigest`,
`kizashiSignal`, `reiAction`, `danwaConversation`, `channelEgress`), each a function from a
typed record to an `Output` whose `config` is rendered with a vendored copy of the Dhall
Prelude's `JSON.render` under `schema/prelude/` so that loading needs no network. Rewrite the
checked-in manifests under `agents/` to the helpers. `Shikigami.Agent.Loader` takes an
`OutputRegistry` and calls `validateOutputs`, so `shikigami validate`, worker boot and the
light commands all refuse a declaration naming an unregistered kind, listing the registered
ones. The stock light commands and the stock worker register `local.report` under
`LocalOperator` and pass it as the default (`DefaultOutput` with `format = Markdown`). A
worker that registers the Kikan adapters, when their services are configured as today, passes
`NoDefaultOutput` until EP-10's distribution registers `kawa.digest` as its default, so
existing Kikan behavior does not change in this plan.

*Approval channels.* Add `shikigami-core/src/Shikigami/Approval/Channel.hs`:

```haskell
data ApprovalChannelAdapter = ApprovalChannelAdapter
  { kind :: !ApprovalChannelKind
  , postAsk :: ReviewRequestId -> AwakeableId -> Duration "approval" -> ApprovalRequest
            -> IO (Either ApprovalNotificationError ()) }
data ApprovalChannels   -- sealed; mkApprovalChannels refuses duplicates and an absent default
channelNotifier :: Log.Logger -> ApprovalChannels -> ApprovalNotifier
```

`ApprovalRequest.channel` becomes an `ApprovalChannelKind`, with `danwa` and `kizashi` as
the kinds of the two existing implementations (moved to
`shikigami-core/src/Shikigami/Approval/Channel/Kikan.hs`, in the core until EP-10). The
hard-coded `ViaDanwa` and `ViaKizashi` sites become `DefaultChannel` lookups against the
composition, except where a flow deliberately names one. A request naming an unregistered
kind fails with `PermanentNotification`, and the ask is authorized as `RequestApproval`
first. Add `Approval/Channel/Local.hs` with `localInboxAdapter :: InboxRoot ->
ApprovalChannelAdapter` for kind `local.inbox`. It writes
`<state>/approvals/<review-id>.json` atomically with mode 0600 (the directory is 0700),
containing the review id, the parent run, the bounded prompt, the absolute deadline and the
token. Nothing else ever holds the token: not the log, not the record, not `runs show`.
Appending `approval.requested` records the review id and the channel kind only. Add
`shikigami-local approvals pending` and `shikigami-local approvals resolve <review-id>
[--reject REASON]` to EP-1's `shikigami-local` executable; `resolve` reads the token from the
file, calls the existing `resolveApproval`, and deletes the file. EP-4's `shikigami playbook
approve` calls the same function.

*Triggers.* Add `Manual` to `Trigger` in `Agent/Decl.hs` and to the union in
`schema/Agent.dhall`, and make `trigger = Trigger.Manual` the Dhall default. Add
`TriggeredByOperator` to `TriggerKind` and to `RunTriggerKind` in
`domain/shikigami/run-jobs.keiro`; `shikigami-agent-run` and `shikigami enqueue-run` use it.
The scheduler and the consumers skip `Manual` agents; `triggerKindText` and the two
catalogue renderers gain the case. GHC's incomplete-pattern warnings list every site.

*Codec treatment.* `AgentDecl` is journaled, and its JSON instances strip defaulted fields by
hand. `outputs` is omitted when empty and inserted as `[]` when absent, in the same way as
`decisionModels`; `trigger` is always present. The resolved default is never written into
`AgentDecl`; it lives only in the `resolve-outputs` step result. Add round-trip tests for both, and a test
that every manifest under `agents/` decodes, encodes and decodes to the same value. Then
`just keiro-scaffold` and the gate. This milestone replaces journaled shapes (`AgentDecl`,
`SinkIntent`, `SinkResult`, `ApprovalRequest`, the run-job enum), so the pre-release recheck
is mandatory and its `keiro-diff` findings are recorded verbatim.

Add `docs/user/outputs.md` (the contract, the two helper files, the load-time refusal) and
update `docs/user/cli.md` and `docs/operations/configuration.md`.

### Milestone 3: the portability check

Add `agents/proof/portable-note.dhall`: a `Skill` agent with a declared principal, no trigger
line, the `workspace.read` overlay and no `outputs` line, plus its `SKILL.md`, which
asks the model to summarize a repository's README and then asks for approval before
reporting. It names nothing Kikan-specific. Add `shikigami record check --run <id>` to
`Command/Record.hs`, backed by a pure `Shikigami.Record.Invariant.checkRun :: RunFacts ->
[RecordEvent] -> [InvariantViolation]` with one constructor per invariant: a missing or
paused principal (K1); an effect entry with no preceding `authority.decided` approval for
the same action (K2, K3); no `run.admitted` entry carrying the declaration digest (K4); no
resource root or deadline on the admission (K5); an effect entry outside a journaled step
or a repeated effect key (K6); and two admissions for one key (K8). K7 is asserted by
construction, not from the record, and the command says so. This plan adds the kinds
`run.admitted` and `run.finished` in the agent-run workflow for that purpose.

Run the declaration twice against the same repository. The first run uses the stock
composition: `shikigami-agent-run` under `LocalOperator`, the operator as authority,
`local.inbox`, and `local.report` reached through the composition default. The second uses
`shikigami-worker` configured with the Kikan authority (`authorization.actions.mode` set to
the Kikan mode) and a registry whose default is `kawa.digest`, against whichever Kikan-En
instance the operator can run locally; `docs/capabilities/local-integration-fixtures.md`
describes the local fixtures. Compare the two records with `shikigami record list --json`:
the sequences of kinds and action tags must be equal, and only `decidedBy`, `reference`,
`tier` and the output kind that the default resolved to may differ. Each run's
`run.admitted` entry must mark its output as a composition default. EP-10 reruns this check against its Kikan distribution.


## Concrete Steps

Work in `/Users/shinzui/Keikaku/bokuno/shikigami` inside the dev shell (`nix develop` or
direnv), with PostgreSQL started by `process-compose up` in another terminal.

Before each milestone, recheck and record (dated, in the Decision Log) the four pre-release
facts from `docs/workflow-versioning.md`: no release, no journals that must resume, no stored
payloads needing an old codec, no external wire consumers. Drain any non-terminal local run
first, as the MasterPlan requires.

```bash
git tag --list | wc -l                 # expect 0
grep -n "exception" docs/workflow-versioning.md | head -3
base=$(git rev-parse HEAD)
```

Milestone 1:

```bash
just migrate
cabal build all
cabal test shikigami-core:test:shikigami-core-test --test-options="-p '/Authority/ || /Record/'"
cabal test shikigami-core:test:shikigami-core-postgres-test --test-options="-p '/Record/'"
grep -rln "Kikan.En.Action" shikigami-*/src | grep -v "Authority/KikanEn"   # prints nothing
just haskell-conventions && just keiro-gate "$base"
cabal run -v0 shikigami-agent:exe:shikigami-agent-run -- --agent agents/triage-note.dhall
cabal run -v0 shikigami -- record list --limit 5
```

```text
2026-…Z run_01k… triage-note principal_… authority.decided emit_output kizashi:person:nadeem
        refused unavailable: per-action authorization is not configured (source: none)
```

Milestones 2 and 3 (the flags follow EP-1; adjust to what it landed):

```bash
just keiro-scaffold && just keiro-gate "$base" | tee docs/evidence/plan-133/keiro-diff-m2.txt
cabal run -v0 shikigami -- validate agents/triage-note.dhall     # under the stock registry
cabal run -v0 shikigami-agent:exe:shikigami-agent-run -- --set trust.tier=local-operator \
  --agent agents/proof/portable-note.dhall --workspace mori://shinzui/fsrs-hs
cabal run -v0 shikigami-agent:exe:shikigami-local -- approvals pending
cabal run -v0 shikigami-agent:exe:shikigami-local -- approvals resolve <review-id>
cabal run -v0 shikigami -- record check --run <workflow-id>
```

```text
validate: agents/triage-note.dhall: output kind kizashi.signal is not registered here;
  registered kinds: local.report
approval rr_… pending for run … (deadline 2026-…Z): Report the summary of fsrs-hs?
output.delivered local.report ~/.local/state/shikigami/reports/portable-note/run_…-0.md
record check: 14 events, K1 K2 K3 K4 K5 K6 K8 hold (K7 by construction)
```

Paths, ids and counts are illustrative; compare the shape.


## Validation and Acceptance

Automated checks are Haskell tests in the owning packages. In `shikigami-core/test`:
`AuthoritySpec` (every `Action` has a tag and a bounded resource; `denyAll` refuses; each
`toAgentAction` mapping, including the three capability operations and each `NoKikanAction`
case; `recorded` appends exactly one event per decision and turns a failing append into
`AuthorityUnavailable`); `RecordSpec` (`mkRecordKind` grammar, the 8 KiB payload refusal,
the file store's mode and append-only lines); `OutputSpec` (duplicate kinds refused, an
unregistered kind names the registered ones, `mkOutputRegistry` refuses a default of an
unregistered kind, `resolveOutputs` returns `DeclaredOutputs` whenever the list is non-empty,
`CompositionDefault` for an empty list with a default and `JournalOnly` otherwise, each Kikan
adapter accepts exactly its old fields, the Dhall helpers evaluate to configurations their adapters accept, the report
bound and truncation marker); `ApprovalChannelSpec` (the inbox file's mode and content, no
token in any log or record value, unregistered kind refused); `RecordInvariantSpec` (one
synthetic record per `InvariantViolation`). In `test-postgres`: the record table is
insert-only through the API and `readRecord` filters by run, kind prefix and refusals. The
existing sink, approval and workflow suites must pass unchanged in meaning. One
`test-postgres` case admits a run under one default, replays it with a registry whose default
differs, and asserts that delivery uses the journaled output.

M1 is accepted when the suites pass, the architecture test shows no `Kikan.En` import
outside the adapter, the worker started with `authorization.actions.mode` unchanged behaves
as before, and a real `shikigami-agent-run` on this Mac produces `authority.decided` rows
that `shikigami record list` prints. Stopping PostgreSQL mid-run must refuse the next action
with "action record unavailable" rather than proceed.

M2 is accepted by a real run on this Mac under `LocalOperator` against
`mori://shinzui/fsrs-hs` (`/Users/shinzui/Keikaku/bokuno/fsrs-hs`): the declaration has no
trigger line; the run parks; `shikigami-local approvals pending` lists it; the inbox file is
mode 0600 and `grep` finds its token in no log file and no record row; after `resolve`, the
report file exists with the model's summary and the record shows `approval.requested`,
`approval.resolved` and `output.delivered`. The declaration has no `outputs` line:
`shikigami validate` prints `outputs: local.report (composition default)` and the run's
`run.admitted` entry says the same. A second declaration that lists an explicit output is
delivered only there. `shikigami validate agents/triage-note.dhall`
under the stock registry refuses with the registered kinds listed, and a worker configured
with the Kikan adapters still loads it.

M3 is accepted when both runs complete, `record check` reports no violation for either, and
the two kind-and-tag sequences are equal. If no Kikan-En instance can run locally, run the
second composition against the fixture authority named in
`docs/capabilities/local-integration-fixtures.md`, record that limit in Outcomes, and leave
the live comparison to EP-10; the stock run alone does not accept M3.

Not required here, proposed only: record retention and export, a signed commitment over the
record (the attestation work), and moving any adapter out of the core (EP-10).


## Idempotence and Recovery

The migration is additive and guarded by the migration lock; rerunning `just migrate` is a
no-op. The record is append-only: a retried step may append a second `authority.decided`
for the same action, which is correct, because each is a fresh decision. The M1 refactor is
a set of ordinary commits; land the new modules first with the old ones still compiling,
convert consumers package by package, then delete `Shikigami.Action.Authorization`, so each
commit builds. If `just keiro-gate` reports a body change in M1, a journaled value changed
by accident: stop and find it. In M2 the gate must report changes; if it reports one not
listed in this plan, stop. A failed M2 is reverted with `git revert` of its commits; no data
is deleted, and the developer database is never dropped to recover (ADR-27). An inbox file
left behind by an abandoned run is harmless after its deadline and may be deleted then;
deleting one earlier makes that approval resolvable only by its timeout. Report files are
never overwritten: the run id and ordinal are in the name.


## Interfaces and Dependencies

M1 has no prerequisite. M2 and M3 require EP-1
(`docs/plans/126-run-declared-agents-on-the-operator-s-own-machine-through-a-local-operator-trust-tier.md`)
accepted: its `TrustTier`, its per-run composition and its `shikigami-local` executable.
External contract: `Kikan.En.Action` and `Kikan.En.Client` from
`mori://shinzui/kikan-en/packages/kikan-en-contract`, used only inside the adapter.

Published interfaces, final once the milestone that introduces them lands:
`Shikigami.Authority` (`Action`, `CapabilityOperation`, `Authority`, `AuthorityFailure`,
`Decision`, `DecisionSource`, `Principal`, `denyAll`, `recorded`, `actionTag`,
`actionResource`); `Shikigami.Authority.KikanEn` (`kikanEnAuthority`, `toAgentAction`);
`Shikigami.Record` (`ActionRecord`, `RecordEvent`, `RecordEntry`, `RecordKind`,
`postgresRecord`, `fileRecord`, `readRecord`) and `Shikigami.Record.Invariant.checkRun`;
`Shikigami.Output` (`OutputDecl`, `OutputAdapter`, `OutputRegistry`, `DefaultOutput`,
`mkOutputRegistry`, `validateOutputs`, `ResolvedOutputs`, `resolveOutputs`),
`Shikigami.Output.Local.localReportAdapter`, `Shikigami.Output.Kikan.kikanOutputAdapters`;
`Shikigami.Approval.Channel` (`ApprovalChannelAdapter`, `ApprovalChannels`,
`channelNotifier`), `localInboxAdapter`; `Trigger.Manual` and `TriggeredByOperator`; the
`outputs` field with `schema/outputs/{Local,Kikan}.dhall`; and `shikigami record list|check`.

How the sibling plans consume them. EP-1 implements the `LocalOperator` authority as an
`Authority`, installs it with `recorded`, sets `RecordEvent.tier` from its `TrustTier`, and
makes `shikigami-local ledger` a view over `readRecord`; it defines no ledger type of its
own. EP-2 adds `LaunchCodingAgent` to `Action` and appends `coding-agent.*` kinds. EP-3 adds
`RunDeclaredTool` and appends `tool.called`. EP-4 parks playbook approvals on
`local.inbox` through `channelNotifier` and adds no approval-channel constructor. EP-9 builds
the routine-agent short form on `Trigger.Manual` and the composition default output, and
states no output of its own. EP-1's confirmation prompt shows `resolveOutputs`' result. EP-10 moves
`Shikigami.Authority.KikanEn`, `Shikigami.Output.Kikan` and
`Shikigami.Approval.Channel.Kikan` into the Kikan binding package, registers them through
EP-5's pack API, registers `kawa.digest` as its distribution's default output, projects the
action record into Kikan run evidence, and reruns the M3 check against its distribution. EP-5 exports these port modules through
`shikigami-core:pack-sdk`. EP-11
(`docs/plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md`)
freezes this plan's surfaces in two steps: `schema/Agent.dhall` with `outputs` and
`Trigger.Manual`, the `AgentDecl` codec and `schema/outputs/Local.dhall` in its first freeze,
which requires this plan Complete; the port modules and `schema/outputs/Kikan.dhall` in its
second.
