# Shikigami domain inventory

The evidence behind `domain/shikigami.keiro-workspace`. Every durable identity
Shikigami writes is listed here with the file and line that defines it, together
with an explicit statement of whether the checked specification describes it and
why. Produced by Milestone 1 of
`docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md`
on 2026-08-19 against `keiro-dsl 0.13.0.0`, language 5.

The rule this document exists to enforce is one sentence: **do not certify a
schema that differs from the codec actually executed.** A specification that
describes a contract the runtime does not run is worse than no specification,
because the evolution gate then attests to something false. So a row below is
either declared *and* true, or undeclared *and* explained.


## What the node census actually found

Keiro-dsl's node taxonomy is aggregates and their events, snapshots, read models
and projections, process managers and timers, routers, integration contracts
with inbox/outbox nodes and publishers, PGMQ work queues and dispatch, and
durable workflows with operations. Shikigami occupies a much smaller part of it
than the plan that commissioned this inventory assumed.

**Shikigami has no event-sourced aggregate.** There is no Keiro command runner
over a Shikigami-owned event stream anywhere in the repository. The one
`runCommandWithSqlEvents` call (`shikigami-core/src/Shikigami/Agent/Conversation.hs:373`)
runs against *kioku's* `sessionEventStream` with kioku's `sessionStream`, and the
inline projections it applies (`Conversation.hs:393`) are kioku's
`sessionInlineProjection` and `l1TimerScheduleProjection`. Those are another
service's aggregate and another service's read models.

`Shikigami.Flow.Lifecycle.AtRiskCustomer` looks like an aggregate and is not one.
It is a Keiki `SymTransducer` whose output type is `()`, whose every edge is
output-free, and whose own module comment says so: "this transducer is not an
event source. It is a rendered specification of the at-risk-customer lifecycle:
it produces the Mermaid diagram and nothing else. The durable state for that
lifecycle is Keiro's workflow journal." Its sibling
`Shikigami.Flow.AtRiskCustomer` is a behavior body that runs *inside* the
agent-run workflow and journals the steps `classify` and `await-ack`
(`Flow/AtRiskCustomer.hs:45,50`).

It follows that Shikigami also has **no read model, no projection, no router,
and no process manager** of its own. It has two durable workflows, one PGMQ
queue, a Kafka inbox, and a Keiro outbox.


## Durable workflows — declared

Both are real Keiro durable workflows with journaled steps, awakeables, and (for
agent-run) child workflows. Both are declared in the workspace.

| Identity | Value | Defined at | Declared |
|---|---|---|---|
| Workflow name | `shikigami.agent-run` | `Shikigami/Agent/Workflow/Name.hs:9` | yes |
| Workflow id derivation | the job's `idempotencyKey`, verbatim | `Agent/Workflow.hs:206` | yes, `id from input.idempotencyKey via idText` |
| Workflow name | `shikigami.danwa-conversation` | `Agent/Conversation.hs:96` | yes |
| Workflow id derivation | `"danwa-conversation:" <> conversationId` | `Agent/Conversation.hs:98-100` | yes, `id from input via conversationWorkflowId` |

### Agent-run journal labels

Eleven labels, all static, all valid DSL wire words, all declared in
`domain/shikigami-agent-run.keiro`.

| Label | Kind | Defined at | Path |
|---|---|---|---|
| `ingest-job` | step | `Agent/Workflow.hs:187` | always |
| `lookup-agent` | step | `Agent/Workflow.hs:188` | always |
| `open-session` | step | `Agent/Workflow.hs:228` | agent resolved |
| `recall` | step | `Agent/Workflow.hs:229` | agent resolved |
| `run-behavior` | step | `Agent/Workflow.hs:236` | non-`Flow` behaviors only |
| `classify` | step | `Flow/AtRiskCustomer.hs:45` | `Flow` behavior only |
| `await-ack` | await | `Flow/AtRiskCustomer.hs:50` | `Flow` behavior, high risk only |
| `dispatch-sinks` | step | `Agent/Workflow.hs:491` | behavior succeeded |
| `fail-session` | step | `Agent/Workflow.hs:239` | behavior failed |
| `record` | step | `Agent/Workflow.hs:249` | behavior succeeded |
| `complete` | step | `Agent/Workflow.hs:250` | behavior succeeded |

The declared body lists all eleven in reading order. That is honest because the
DSL body is a label inventory, not a control-flow program: keiro's own reference
says "the body is ordered, but replay matches journal records by label"
(`mori://shinzui/keiro`, `docs/user/typed-spec-toolchain.md`). `run-behavior`
and the `classify`/`await-ack` pair are alternatives, and `fail-session` is
mutually exclusive with `record`/`complete`.

`await-ack` is declared as returning `ApprovalDecision`, not `Ack`. The awakeable
really carries `ApprovalDecision` (`Agent/Approval.hs:109`); `Ack` is the value
`Shikigami.Flow.Acknowledgement.ackFromDecision` produces *after* the await
returns, and is never journaled.

### Agent-run labels that cannot be declared

A workflow label is parsed by keiro-dsl's `wireWord` production —
`[A-Za-z0-9][A-Za-z0-9_-]*` (`keiro-dsl/src/Keiro/Dsl/Parser/Core.hs:282-286`).
It admits neither a colon nor a value computed at run time. These labels are
therefore outside the grammar, and renaming them would not help, because their
suffixes are runtime values:

| Label family | Kind | Defined at | Owner |
|---|---|---|---|
| `approval:<SinkKind>:<ordinal>` | await | `Agent/Workflow.hs:299-300` | `docs/plans/14-approval-and-human-in-the-loop-end-to-end.md` |
| `<any await>:notify` | step | `Agent/Approval.hs:156-157` | same |
| `emit-signal:<ordinal>` | step | `Flow/Capability.hs:136` | `docs/plans/16-honest-sink-handlers-real-reiaction-and-honored-declaration-fields.md` |

### Conversation journal labels

This workflow has two label sets, chosen by `patch
shikigami-conversation-rotation-v1` once per interpreted run. Which one an
instance is on is a durable property of that instance, so both are inventoried.

The **rotating** shape is what every fresh conversation runs. One journal
generation holds exactly one turn, so no label is ever written twice in a
generation and none of them needs a computed suffix. All of it is declared in
`domain/shikigami-conversation.keiro` and gated by `just keiro-gate`.

| Label | Kind | Defined in | Declared |
|---|---|---|---|
| `ingest-start` | step | `rotatingConversation` | yes |
| `lookup-agent` | step | `resolveDeclStep` | yes |
| `resolve-session` | step | `processRotatingTurn` | yes |
| `record-user` | step | `processRotatingTurn` | yes |
| `run-behavior-v2` | step | `processRotatingTurn` | yes |
| `record-assistant-and-reply` | step | `processRotatingTurn` | yes |
| `turn-result` | step | `processRotatingTurn` | yes |
| `next-message` | await | `awaitConversationWake` | yes |
| `danwa-reply:<messageId>` | sink-intent id | `replySinkStepName` | no — not a journal step |

The **legacy** shape is the `False` branch, kept so that an instance parked
before rotation shipped replays the shape its journal was written under. It ran
every turn of a conversation in one immortal generation, which is exactly why
each per-turn label needed a `:<messageId>` or `:<ordinal>` suffix — and why
none of them could be declared.

| Label | Kind | Defined in | Declared |
|---|---|---|---|
| `record-user:<messageId>` | step | `processTurn` | no — colon |
| `run-behavior:<messageId>` | step | `processTurn` (pre behavior-retry-v1) | no — colon |
| `run-behavior-v2:<messageId>` | step | `processTurn` (post behavior-retry-v1) | no — colon |
| `record-assistant-and-reply:<messageId>` | step | `assistantReplyStepName` | no — colon |
| `turn-result:<messageId>` | step | `turnResultStepName` | no — colon |
| `next-message:<ordinal>` | await | `nextMessageStepName` | no — colon |

Making this journal declarable was
`docs/plans/26-conversation-workflow-lifecycle-idle-timeout-journal-rotation-session-completion.md`,
which did it by removing the reason for the suffixes rather than by finding a
declarable spelling of them. Retiring the legacy set — deleting the guard, the
`False` branch, and the patch block together — follows
`docs/adr/0004-one-options-value-and-a-checked-patch-set.md`.

### Child workflows

`Shikigami.Agent.Delegate.delegate` spawns a child of `shikigami.agent-run`
itself. The child id is a UUIDv5 over
`["shikigami", "delegate", parentWorkflowId, childAgent, stableKey]`.
The generic supervisor derives stable keys from the `delegates` list captured in
the journaled agent declaration; Flow callers supply a stable call-site key.
Declared as `child delegate id input via
delegatedWorkflowId -> AgentRunResult`; the `via` name records the hand-owned
derivation, which takes the parent workflow id rather than the workflow input.
`docs/plans/35-delegation-as-a-first-class-declared-capability.md` made that a
governed first-class capability.

### Operations

Two `run` operations are declared, one per workflow, naming the hand-owned
entry points `runAgentRunWorkflow` (`Agent/Workflow.hs:197`) and
`runConversationWorkflow` (`Agent/Conversation.hs:196-210`).

No `signal` operation is declared. `Shikigami.Agent.Approval.resolveApproval`
and `Shikigami.Agent.Workflow.Input.deliverInput` exist and are exported but
have **no caller anywhere in this repository**, and `resolveApproval` is keyed by
`AwakeableId` rather than by workflow key, which is not what a DSL `signal`
operation declares. The awaits an external signal would target
(`approval:<kind>:<ordinal>`, `next-message:<n>`) are not declarable labels
anyway. `docs/plans/14-approval-and-human-in-the-loop-end-to-end.md` adds the
entry point; the signal operation lands with it.


## The run-job queue — not declared

| Identity | Value | Defined at |
|---|---|---|
| Queue name | `shikigami_run_jobs` | `Trigger/Enqueue.hs` (`runQueueName`) |
| Message body | `MessageBody (toJSON job)` — a bare `RunJob` | `Trigger/Enqueue.hs` (`enqueueRunJobTx`, `enqueueRunJob`) |
| Consumer | `Aeson.fromJSON` straight to `RunJob` | `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs` (`runJob`) |

`RunJob` (`Agent/RunJob.hs`) has eleven fields: `agentName :: Text`,
`triggerKind :: TriggerKind` (a four-constructor sum saying where the job came
from, for audit and tracing), `routeKind :: RunRouteKind` (a three-constructor
sum saying which workflow the producer meant), `occurredAt :: UTCTime`,
`triggerPayload :: Data.Aeson.Value`, `idempotencyKey :: Text`, and three
optionals — `parentSessionId :: Maybe Text`, `parentRunWorkflowId :: Maybe Text`,
`delegationDepth :: Maybe Int`, plus `lineage :: [Text]` and
`delegationBudgetId :: Maybe DelegationBudgetId`.

`routeKind` is additive and hand-encoded per
[ADR 0011](../adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md):
its compatibility default `InferredLegacyRoute` emits no key at all, so a job
enqueued or journaled before the field existed is byte-identical and still
decodes. See
[ADR 0014](../adr/0014-a-run-job-declares-its-route-rather-than-being-guessed.md).
The delegation fields follow the same additive rule: absent keys decode as
`lineage = []` and `delegationBudgetId = Nothing`, and default values remain
omitted when encoding.
The keiro specification still inventories only the three fields it refers to
(`agentName`, `idempotencyKey`, `occurredAt`) in
`domain/shikigami-agent-run.keiro`, so adding the field needed no specification
edit.

Describing this as a Language 5 `workqueue` is *expressible*: the colon form
`field -> "wire_key" : TypeExpr` accepts `Json`, `Optional Text`, `Optional Int`,
and `Time`, and `TriggerKind` would become a `mapped structural` enum. It is not
*honest*, for three reasons that compound:

1. **The envelope.** A scaffolded queue always carries Keiro's schema-version-1
   `{v,t,data}` envelope: the generated codec is `keiroJobCodec runJobsPayloadCodec`,
   and its own generated comment says "do not adopt this codec on a non-empty
   bare-payload queue without draining it". Shikigami sends a bare payload.
2. **The type.** The generated `Queue` module defines its *own* `RunJob` record
   with generated `encodeRunJob`/`parseRunJob`. Adopting it replaces
   `Shikigami.Agent.RunJob.RunJob` on both the producer and the consumer.
3. **The existing test.** `shikigami-core/test/Shikigami/WireCompatSpec.hs:76-81`
   asserts, as a live case, that "the payload is a bare run job, not a versioned
   envelope". That test was written deliberately, its fixture is a captured
   literal, and `docs/dependency-cohort.md` records it as permanent.

So the queue keeps its own payload codec and stays out of the scaffolded
surface. Moving it is a wire change with its own commit, its own decision, and
its own fixture — `docs/plans/24-flow-versioning-with-keiro-patch-and-continue-as-new.md`
and `docs/plans/27-consolidate-sink-intent-and-run-lifecycle-machinery.md` are
the plans that would do it.


## The Kafka inbox — not declared

Two consumers decode Kafka records through Keiro's idempotent inbox
(`shikigami-workers/src/Shikigami/Trigger/Consumer.hs:158,198`), both with
`runInboxTransaction Nothing PreferIntegrationMessageId event (Just kref)
handler`. The `activity.v1` consumer matches declared stream agents against an
`ActivityEnvelope`; the integration-event consumer matches an agent's declared
`eventType` against the envelope's.

A keiro-dsl `intake` requires a declared `contract` with named events and an
`accept <Event>` clause, and generates inbox wiring with an `inboxPersistence`
value and a seven-outcome disposition table. Shikigami's handlers are agent
*matchers* over an open payload, not typed event acceptors, and they decode with
`decodeJsonIntegrationEvent` to `ActivityEnvelope` / `Data.Aeson.Value`. Adopting
a generated intake would rewrite the consumers, which is a behavior change.
`docs/plans/18-atomic-stream-consumption-offsets-inbox-and-enqueue-in-one-boundary.md`
and `docs/plans/20-explicit-trigger-routing-scheduler-catch-up-policy-and-loud-failures.md`
own that boundary.

The Danwa contract Shikigami consumes is `danwa.message-addressed-to-agent`
(`Integration/Danwa.hs:60`), whose body is a bare `AddressedMessage` object with
**no discriminator field**. A keiro-dsl `contract` requires a `discriminator` and
writes it into the encoded body, so a generated codec for it would not reproduce
the bytes Danwa publishes.


## The sink outbox — not declared

| Identity | Value | Defined at |
|---|---|---|
| Integration event type | `shikigami.sink.dispatch-requested` | `Agent/Workflow.hs:613` |
| Destination | `shikigami.sink.v1` | `Agent/Workflow.hs:611` |
| Source | `shinzui/shikigami` | `Agent/Workflow.hs:610` |
| Schema version | `1` | `Agent/Workflow.hs:614` |
| Outbox id | UUIDv5 over `"shikigami:sink:" <> messageId` | `Agent/Workflow.hs:636-641` |
| Agent-run message id | `<workflowId>:sink:<ordinal>` | `Agent/Workflow.hs:628-630` |
| Flow message id | `<workflowId>:<stepName>` | `Flow/SinkOutbox.hs:125` |

The rows are `Keiro.Outbox` rows carrying `IntegrationEvent`s, delivered by
`shikigami-workers/src/Shikigami/Flow/SinkOutbox/Publisher.hs`, which calls
`publishSinkIntent` — an **HTTP sink dispatcher**, not a Kafka publish. A
keiro-dsl `emit` maps aggregate events onto contract events on a Kafka topic and
requires both an aggregate and a contract, and a `publisher` models publishing
those to Kafka. Neither is what this outbox does, so declaring them would certify
a publication that does not happen.

### `SinkIntent` and its duplicate

`SinkIntent` is declared twice — `Agent/Workflow.hs:125-138` and
`Flow/SinkOutbox.hs:49-58` — with identical fields and identical
`omitNothingFields` options, because `Flow/SinkOutbox` cannot import
`Agent/Workflow` without a module cycle. The only guard today is a comment
reading "Must match ... exactly" (`Flow/SinkOutbox.hs:40,65`) plus
`WireCompatSpec.hs:147-148`, which asserts the two encoders agree.

Milestone 1 of plan 39 intended to retire that duplication by giving `SinkIntent`
one owning workspace member, so `WorkspaceDuplicateDeclaration` would enforce
what the comment asks for. **That is not achievable at keiro-dsl 0.13**, and the
tool says so itself. A `mapped structural record SinkIntent` checks clean, but
`check --explain-bindings` reports the obligation as "structural type SinkIntent
(not currently used by an aggregate root)" and the coverage report lists zero
roots on every surface. An unconsumed mapped declaration generates a shape, a
binding skeleton, projections, and conformance assertions — but **no wire
codec**. Declaring `SinkIntent`'s wire shape there would state a JSON policy that
nothing executes, which is exactly the failure this document opens by forbidding,
and it would cost three mapped declarations (`SinkIntent`, `DanwaTarget`, and the
four-constructor `Sink` union) and three hand-owned binding modules to do it.

The duplication therefore stays guarded by `WireCompatSpec` until
`docs/plans/27-consolidate-sink-intent-and-run-lifecycle-machinery.md`
consolidates the two records into one hand-owned `Shikigami.Sink.Intent` module.
Plan 27's Decision Log entry — "Plan 39's generated module owns the `SinkIntent`
structural wire type and codec" — is superseded by this finding; plan 39's
Milestone 4 records the correction.


## Timers — not declared

Two timer families exist, both as raw `Keiro.Timer` rows fired by one
hand-written loop (`shikigami-workers/src/Shikigami/Trigger/Timer.hs`) because a
timer table with two independent readers would race.

| Timer | Id derivation | Defined at |
|---|---|---|
| Approval timeout | UUIDv5 over `["shikigami","approval-timeout",workflowName,workflowId,generation,stepName]` | `Agent/Approval.hs:182-187` |
| Schedule | UUIDv5 over `["shikigami","schedule",agent,dueAt]` | `shikigami-workers/src/Shikigami/Trigger/Scheduler.hs:63-69` |
| Schedule fired-event id | UUIDv5 over `["shikigami","schedule-fired",agent,dueAt]` | `Trigger/Scheduler.hs:71-77` |
| Schedule payload kind | `shikigami.schedule` | `Trigger/Scheduler.hs:49-50` |
| Approval payload kind | `shikigami.approval-timeout` | `Agent/Approval.hs:204-205` |

A keiro-dsl `timer` is a clause *inside* a `process` node, and a `process`
requires a saga aggregate, a target aggregate, and command dispatches. Shikigami
has no aggregate, so it has no process manager to hang a timer on. These timers
become declarable when an aggregate exists —
`docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md` is the first
plan that introduces one.


## Sink kinds and grants — not declared

`SinkKind` (`Sink/Permission.hs:30-37`) has five constructors, whose persisted
spellings are `KawaDigest`, `KizashiSignal`, `ReiAction`, `DanwaConversation`,
and `ChannelEgress` (`Sink/Permission.hs:50-67`). They key the database-backed
grant table (`Sink/GrantStore.hs`). A DSL `enum` is usable only inside a node
payload, and no declared node carries one, so declaring it would add an unused
declaration. `docs/plans/21-database-backed-sink-permission-grants.md` owns the
grant table.


## The keep-or-rename call

Milestone 1 is the last window in which any of these names is free: Shikigami has
no users, so no workflow is parked and no queue holds a message. Every identity
above was reviewed and **kept**. There is no rename in this change, so every
existing golden stays byte-identical, which is the evidence that adoption changed
no behavior.

Two names were argued about and kept anyway:

* `classify` and `await-ack` are at-risk-customer flow labels journaled into the
  general `shikigami.agent-run` workflow, so the agent-run journal carries two
  labels that belong to one behavior. Renaming them would not fix that; moving
  them out of the shared workflow would, and that is a modelling change belonging
  to whichever plan gives the flow its own aggregate.
* `record` and `complete` are generic enough to collide with a future label.
  They are kept because they are the deployed names, they are unambiguous inside
  this workflow, and the workspace now makes a collision a `check` failure rather
  than a silent overwrite.


## The gate

Run this before merging anything that touches `domain/`, the generated layer
under `shikigami-core/src/Shikigami/*/Generated/`, or a durable identity named
above:

```bash
nix develop
just keiro-gate                 # or `just keiro-gate <merge-base>` on a branch
```

It runs, in the order a failure is cheapest to read:

| Recipe | What it fails on |
|---|---|
| `just keiro-check` | any error, any warning (`--deny-warnings`), an effective language below 5 (`--min-language 5`), a new opaque boundary on a persisted root (`--fail-on-opaque`) |
| `just keiro-inspect` | a member that does not declare its language, or whose effective version is not 5, or a contract that is not `stable` |
| `just keiro-scaffold` | a committed generated layer that the current specification would not produce |
| `just keiro-diff <ref>` | a `BREAKING` finding on any gated compatibility surface |
| `cabal test keiro-shikigami-conformance` | a workflow fact that no longer matches the reviewed `KeiroConformance.Expectations` |

`cabal test all` additionally runs `Shikigami.KeiroSpecificationSpec`, which
covers what the toolchain structurally cannot: a `.keiro` file in `domain/` that
the manifest does not list is not part of the service, so `check`, `inspect`, and
`scaffold` never see it.

Each gate was verified against the failure it claims to catch. Deleting a
member's preamble:

```text
domain/shikigami-agent-run.keiro:18: error[WorkspaceLanguageVersionMismatch]:
  workspace members select different effective language versions (5, 1)
  domain/shikigami-conversation.keiro:14: note: member selects effective language version 1
```

Removing a generated module's banner:

```text
error: refusing to overwrite 1 file(s) at Generated paths that lack the '-- @generated' banner
  Shikigami/AgentRun/Generated/WorkflowFacts.hs
nothing was written
```

Renaming a durable workflow name:

```text
BREAKING: AgentRun workflow-name AgentRun: stable name changed
  'shikigami.agent-run' -> 'shikigami.agent-run-v2';
  in-flight journals remain under the old stream name [WorkflowStableNameChanged]
    vector: persisted-identity=breaking
    remedy: revert the re-keying change or perform an explicit operational identity migration
```


## How to reproduce this inventory

```bash
nix develop
cabal run -v0 keiro-dsl -- check domain/shikigami.keiro-workspace \
  --min-language 5 --deny-warnings --explain-bindings \
  --coverage-report build/keiro-coverage.json --fail-on-opaque
cabal run -v0 keiro-dsl -- inspect domain/shikigami.keiro-workspace --format=json
cabal run -v0 keiro-dsl -- behavior-obligations domain/shikigami.keiro-workspace --format=text
```

As of 2026-08-19 the first exits `0` with every boundary reporting zero mapped
roots, the second reports both members `"sourceForm": "declared"` at effective
language 5 with `"languageSupport": "stable"`, and the third reports
`required: 0` because there is no aggregate to carry a behavior obligation.
