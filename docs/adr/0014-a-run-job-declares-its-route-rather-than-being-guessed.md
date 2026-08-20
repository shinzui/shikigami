# 0014. A run job declares its route rather than being guessed

Date: 2026-08-20

Status: accepted


## Context

A fired trigger becomes one JSON message, a `RunJob`, on the Postgres queue
`shikigami_run_jobs`, and the worker drains that queue. Two different
orchestrations can come out of one delivery: a *conversation turn*, which drives
one back-and-forth with a human through the danwa conversation service, and an
*ordinary agent run*, which drives the durable agent-run workflow.

The worker chose between them by trying to JSON-decode the job's
`triggerPayload` as danwa's `AddressedMessage` and seeing whether it worked.
Nothing else was consulted, although the job already carried a `triggerKind`
saying where it came from and the producer already knew which orchestration it
meant. Two failures followed from that, and neither said anything:

* A schedule or stream job whose payload happened to satisfy the addressed-message
  shape ran as a conversation.
* A job that genuinely was addressed but whose payload failed to decode — a
  producer bug — ran as an ordinary agent run instead of being reported.

Reusing `triggerKind` would not have fixed it. `TriggeredByEvent` is not
synonymous with "conversation": an agent declares `Trigger.Event { eventType }`
for any integration event, and only the danwa addressed-message event type means
a conversation.

`RunJob` also crosses two durable boundaries, not one. It sits in the PGMQ queue
as `toJSON job`, and it is written into keiro's workflow journal as the result of
the `ingest-job` step and directly by `Shikigami.Agent.Delegate.delegate`.
Journals outlive the binary that wrote them and are decoded again on replay, and
`shikigami-core/test/Shikigami/WireCompatSpec.hs` pins the exact bytes a `RunJob`
encodes to as a captured literal.


## Decision

**A `RunJob` carries an explicit `routeKind` naming the workflow its producer
meant. Payload decoding validates that choice; it never makes it.**

* `RunRouteKind` is `AgentWorkflowRoute | ConversationWorkflowRoute |
  InferredLegacyRoute`, defined beside `RunJob` in
  `shikigami-core/src/Shikigami/Agent/RunJob.hs`.
* `triggerKind` keeps its existing meaning — where the job came from, for audit
  and tracing — and no longer influences dispatch at all.
* Every producer sets the route. Stream, schedule, and delegation producers mean
  `AgentWorkflowRoute`. The event-inbox producer compares the matched agent's
  declared `eventType` against
  `Shikigami.Integration.Danwa.addressedMessageEventType`, because the
  declaration is the honest source of the distinction. The `shikigami enqueue-run`
  operator path takes `--conversation`.
* `Shikigami.Agent.RunJob.Worker.routeRunJob` decides from the field alone. A
  `ConversationWorkflowRoute` whose payload will not decode is a `RouteError` and
  dead-letters through `routeErrorJobOutcome` with the reason
  `invalid_route_payload`, rather than running the other workflow.

**The compatibility default is a named constructor, not a silent fallback.**

Per [ADR 0011](0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md),
`RunJob`'s hand-written codec omits `routeKind` when it holds
`InferredLegacyRoute`, and restores `InferredLegacyRoute` when the key is absent.
A job enqueued or journaled before this field existed is therefore byte-identical
and still replays. The worker handles that constructor by reproducing the old
duck-typed decision while logging `worker.job.route_inferred` at warning level.


## Alternatives rejected

**Infer the route from `triggerKind`.** It preserves a subtler version of the
same bug, because an event trigger can legitimately mean either orchestration.

**Default a missing `routeKind` to `AgentWorkflowRoute`.** It would quietly
reroute any conversation job queued before the deploy — turning a compatibility
problem into a wrong answer, which is the class of failure this record exists to
remove.

**Version the queue payload into an envelope.** The queue is deliberately not a
keiro-dsl-scaffolded workqueue (see
[ADR 0001](0001-declare-only-what-the-runtime-executes.md)); introducing an
envelope would strand every in-flight message and every journaled `ingest-job`
step, to add a field.


## Consequences

Adding a field to `RunJob` is a wire change and needs the omit-when-default
codec, not a derived one. `WireCompatSpec` pins both halves: the captured
pre-upgrade literal still decodes and still re-encodes identically, and a job
carrying an explicit route adds exactly one key.

`InferredLegacyRoute` is transitional and greppable on purpose. Once
`worker.job.route_inferred` has stopped appearing in production logs — meaning
the queue has drained and no parked workflow still replays a pre-upgrade
`ingest-job` — the constructor and its branch can be deleted. That deletion is
its own change; nothing forces it.

A mis-declared route now costs a dead letter instead of a wrong run. That is the
intended trade: an operator-visible message in the reconciled DLQ is recoverable,
and a conversation silently executed as an agent run is not.
