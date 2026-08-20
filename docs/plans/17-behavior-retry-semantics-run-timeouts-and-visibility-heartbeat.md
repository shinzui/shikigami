---
id: 17
slug: behavior-retry-semantics-run-timeouts-and-visibility-heartbeat
title: "Behavior retry semantics, run timeouts, and visibility heartbeat"
kind: exec-plan
created_at: 2026-07-08T20:14:28Z
intention: "intention_01kx1tykwvek587vr2gwtcf81j"
master_plan: "docs/masterplans/3-correctness-and-delivery-semantics-stop-dropping-and-duplicating-work.md"
---

# Behavior retry semantics, run timeouts, and visibility heartbeat

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikigami currently journals every synchronous behavior failure as the durable value of
`run-behavior`. A later queue delivery therefore replays the same `Left` instead of calling
the provider or program again. The run-job queue also has a 30-second visibility timeout
and no renewal loop, so a healthy long-running behavior can be delivered to a second
worker while the first is still executing. Permanent failures are either retried or
archived through the raw Shibuya adapter, and neither behavior attempts nor approval waits
have one operator-visible timeout policy.

After this plan, a retryable behavior failure or timeout escapes the step before a journal
record is appended, so Keiro can re-run the action on a later advance. A permanent failure
is journaled once and sent to the PGMQ dead-letter queue. The run-job consumer uses
`keiro-pgmq`'s typed `Job RunJob`, `JobOutcome`, startup queue reconciliation, and
`JobContext.extendLease`; a supervised heartbeat keeps the PGMQ delivery lease alive for
the duration of the queue handler. `worker.run_timeout_seconds` bounds one synchronous
external behavior attempt, `approval.deadline_seconds` bounds approval waits, and the
Keiro resume lease is sized above the behavior timeout.

The observable proof is a test in which the first behavior attempt fails transiently, no
`run-behavior-v2` value is journaled, a later advance calls the behavior again and
succeeds, while a slow attempt renews its PGMQ lease and is delivered only once. A
permanent failure reaches `shikigami_run_jobs_dlq`; a timeout consumes Keiro's bounded
workflow failure budget instead of becoming a permanent step result.


## Progress

- [x] (2026-08-19) Re-audited this plan against the current seven-package repository,
      [the workflow-versioning rules](../workflow-versioning.md), the released dependency
      cohort, and the applicable `keiro-runtime-patterns` documents.
- [x] (2026-08-19) Cleared the old dependency gate: Hackage and upstream tags both contain
      `keiro`/`keiro-pgmq` 0.13.0.0, `shibuya-core` 0.9.0.0,
      `shibuya-pgmq-adapter` 0.14.0.0, and the `pgmq-*` 0.5.0.0 family.
- [x] (2026-08-19) Confirmed plans 36 and 37 are implemented: worker ownership is now in
      `shikigami-workers`, and service configuration is the single Settei `AppConfig`.
- [x] (2026-08-19) Milestone 0: added `keiro-pgmq ==0.13.0.0` to the worker
      dependency cohort and documented its released tag without changing the producer's
      existing raw JSON wire shape. `nix develop --command cabal build
      shikigami-workers --dry-run` resolved the Hackage release and selected
      `keiro-pgmq-0.13.0.0`.
- [x] (2026-08-19) Milestone 1: added retryability classification,
      attempt-scoped timeouts, bounded/redacted failure details, and the versioned
      `run-behavior-v2` path for agent runs and conversations. `RetrySemantics`
      passed 5 focused cases, and the focused `v2` selection passed 4 workflow cases.
- [x] (2026-08-19) Milestone 1: declared `shikigami-behavior-retry-v1` in both
      workflow specifications, scaffolded the generated facts/runtime modules, updated
      conformance expectations, and passed all 12 conformance facts plus the 3-case
      `WorkflowVersioning` deploy simulation. The final merge-base `just keiro-gate`
      remains part of completion validation.
- [x] (2026-08-19) Milestone 2: replaced the raw run-job consumer construction with a typed
      `Job RunJob`, reconciled the main queue and DLQ at worker startup, and mapped every
      workflow result to a deliberate `JobOutcome`.
- [x] (2026-08-19) Milestone 3: ran queue work with a supervised PGMQ visibility heartbeat
      and proved lease renewal through the actual `jobProcessorWithContext` path.
- [x] (2026-08-19) Milestone 4: added `worker.run_timeout_seconds` and
      `approval.deadline_seconds` to Settei, threaded both values through the worker
      environments, and sized `WorkflowResumeOptions.leaseTtl` above the behavior timeout.
- [x] (2026-08-19) Registered focused core and worker test modules; passed the
      specification gate from baseline `664b5eb`, focused tests, `cabal build all`, and
      `cabal test all -j1` inside `nix develop`. The final worker proof covers all typed
      outcome branches, repeated queue reconciliation, heartbeat lease retention and
      cancellation, and permanent-outcome delivery to the reconciled DLQ.


## Surprises & Discoveries

- The original plan targeted files that no longer own the work. Plan 36 moved the consumer
  from the deleted `Shikigami.Worker` module to
  `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs`, with composition in
  `Shikigami.Workers.Registry` and environment construction in
  `Shikigami.Workers.Config`.

- The dependency gate in the old plan is obsolete. The current cohort already pins
  `keiro` 0.13.0.0, `shibuya-core` 0.9.0.0,
  `shibuya-pgmq-adapter` 0.14.0.0, and `pgmq-*` 0.5.0.0. `keiro-pgmq` 0.13.0.0
  exists on Hackage and has upstream tag `keiro-pgmq-0.13.0.0` at commit
  `1eef4b2f5323c419050f3584a0969a0c4f1c9308`; it is absent from
  `cabal.project` only because no current component links it.

- `Keiro.PGMQ` is the right application-facing façade, and its released
  `JobRuntime`/`runJobEff` removes the worker's need to assemble
  `Pgmq`, `PgmqAdapterEnv`, and tracing interpreters itself. The package is not a
  lightweight codec-only package, however: its Cabal library depends transitively on
  `keiro-core`, `pgmq-config`, `pgmq-core`, `pgmq-effectful`, `pgmq-hasql`,
  `shibuya-core`, and `shibuya-pgmq-adapter`. It also does not depend on or re-export
  the `keiro` workflow package. Shikigami therefore still needs a direct `keiro`
  dependency for workflows, inbox, timers, and outbox, while redundant direct lower-level
  queue dependencies should be removed after all application imports move to the façade.

- Depending on `keiro-pgmq` does not by itself change the payload wire. The selected
  `JobCodec` does. `aesonJobCodec` is already safer than the current raw handler because
  it provides one typed decode boundary and automatic malformed-payload dead-lettering,
  while remaining byte-shape compatible with queued jobs. `keiroJobCodec` additionally
  provides schema versions and upcasters, but a direct switch changes the wire to
  `{v,t,data}` and would reject existing bare jobs. Adopting it requires a dual-decoder
  rollout: consumers that accept both shapes first, versioned producers second, and
  removal of the legacy decoder only after the queue and old producer fleet are drained.

- `mkRetryPolicy` does not calculate exponential backoff. Its released signature is
  `Int64 -> RetryDelay -> Bool -> Either RetryPolicyConfigError RetryPolicy`, and it
  validates a fixed default delay. Keiro's workflow resume worker, not the PGMQ job
  policy, supplies bounded failure pacing: 2, 4, 8, 16, 32, then 64 seconds. This plan
  uses `defaultRetryPolicy` (five deliveries, 60-second explicit-retry delay, DLQ
  enabled) for transport-level redelivery and lets Keiro own workflow-attempt pacing.

- PGMQ delivery leases and Keiro workflow-instance leases are different mechanisms.
  `JobContext.extendLease` renews the current queue message's visibility. The
  `WorkflowRunOptions.leaseHeartbeat` field renews a workflow instance claimed by the
  resume worker; the resume worker populates it automatically, and direct runs must leave
  it `Nothing`. Consequently this plan must not set `leaseHeartbeat` in
  `shikigamiWorkflowRunOptions`. It must set `WorkflowResumeOptions.leaseTtl` above the
  slowest synchronous step action instead.

- `keiro-pgmq` 0.13.0.0 maps `JobOutcome.Dead detail` to
  `AckDeadLetter (PoisonPill detail)`. It does not expose a way for an application to
  construct Shibuya's `ApplicationFailure` from the typed job handler. Therefore the DLQ
  code produced by this released API is the built-in `shibuya.poison_pill`; the bounded
  detail may carry a stable `shikigami.<reason>:` prefix, but it is not an application
  dead-letter code. Bypassing `keiro-pgmq` solely to obtain `ApplicationFailure` would
  violate the fleet job pattern. If application-specific codes become an acceptance
  requirement, first extend and release `keiro-pgmq`; do not reach through to raw
  `AckDecision` here.

- The current `RunError` already includes `ProviderFailed Bool Text`; the boolean is
  Baikai's retryability classification. The plan must preserve that signal before
  converting an error to `Text`. `ProgramFailed` currently conflates deterministic input
  parsing with a runtime `ErrorS`; the implementation must make their retryability
  explicit rather than guessing after rendering.

- A wall-clock timeout around the queue handler would not protect an attempt run by the
  Keiro resume worker. The timeout belongs immediately around synchronous
  `runBehavior`, inside the workflow step body. It does not wrap a `Flow` or the
  `research-supervisor` durable child/await path, because a durable suspension is not a
  hung synchronous call.

- Conversation failures need the same treatment. Today
  `run-behavior:<messageId>` journals `Either Text Value` and then turns every `Left`
  into an `IOException`, so an in-band permanent error is replayed and thrown forever.
  Changing the interpretation of an existing journal value requires a patch or a new
  step name. This plan uses both: a checked patch chooses a new
  `run-behavior-v2:<messageId>` label for fresh instances while old instances keep their
  original path.

- Queue visibility renewal prevents a second PGMQ delivery; it does not create exactly-once
  workflow effects. Keiro steps remain at-least-once across an external-effect /
  journal-append crash window, and a direct run is intentionally lease-free. Step effects
  must remain idempotent, and the runtime's instance and step arbitration remain the
  authority for concurrent resume races.

- The Concrete Steps named `just check-adr`, but this checkout's `justfile` has no
  such recipe. `mori show --full` confirms `docs/adr/` is not a profile-governed OKF
  bundle, so ADR validation follows the repository's existing plain-filesystem
  convention. Evidence: `just check-adr` returned `justfile does not contain recipe
  check-adr`.

- `effectful` 2.6.1.0's `withEffToIO` supports the required two-thread use only with an
  explicit concurrent unlift. The heartbeat uses
  `ConcUnlift Persistent (Limited 2)` around `async`'s `race`; a sequential unlift would
  reject or unsafely share the effect environment across the work and renewal threads.

- The Settei registry has no curated documents for `shinzui/settei`; the repository's
  existing `Port` decoder is therefore the authoritative local pattern for a public,
  rendered, bounded integral setting. The two duration settings share that shape and
  accept native YAML integers plus textual environment/CLI values.


## Decision Log

- Decision: Use the released `keiro-pgmq` consumer abstraction:
  `Job RunJob`, `aesonJobCodec`, `queueRef "shikigami_run_jobs"`,
  `defaultRetryPolicy`, `ensureJobQueue`, `jobProcessorWithContext`, and
  `runJobWorkers`, all imported through `Keiro.PGMQ`. Run the effect stack through
  `JobRuntime`/`runJobEff`.
  Rationale: This is the applicable fleet standard and removes raw message decoding,
  adapter/interpreter construction, retry-ceiling wiring, and DLQ construction from
  application code. Remove direct `pgmq-effectful` and
  `shibuya-pgmq-adapter` dependencies from `shikigami-workers` once no remaining source
  imports them; retain direct packages only for modules actually imported elsewhere.
  `aesonJobCodec` is deliberately the raw Aeson codec, so messages already on the queue
  retain their current JSON shape.
  Date: 2026-08-19

- Decision: Keep the producer in `Shikigami.Trigger.Enqueue` on `pgmq-hasql` and test its
  raw `toJSON RunJob` payload against `aesonJobCodec`.
  Rationale: Plan 36 deliberately keeps the producer contract in `shikigami-core`, which
  both server and worker packages may depend on, while forbidding the supervised queue
  adapter (and `pgmq-effectful`) from the core-only link. `keiro-pgmq` currently bundles
  its producer codec with Shibuya/adapter dependencies. Moving the producer to workers
  would invert the package DAG; linking `keiro-pgmq` into core would violate the existing
  architecture decision. This is a documented applicability exception to the full
  producer-and-consumer job pattern, not an accidental second wire contract.
  Date: 2026-08-19

- Decision: Do not switch this plan directly from `aesonJobCodec` to
  `keiroJobCodec`.
  Rationale: The versioned codec is the safer long-term evolution format, but the queue
  already contains bare `RunJob` JSON and producers live in more than one deployable
  process. A one-step codec change would turn valid in-flight work into malformed payloads.
  A future adoption must include the dual-read rollout described in Surprises &
  Discoveries; the compatibility test added here creates the baseline for that migration.
  Date: 2026-08-19

- Decision: Use `defaultRetryPolicy` for queue-level retries; do not describe it as
  exponential backoff.
  Rationale: Explicit `RetryDefault` is for a transient queue/store/initial-drive failure.
  Retryable exceptions after a workflow instance exists are paced and bounded by Keiro's
  resume worker. A second backoff algorithm in the queue layer would obscure which budget
  failed.
  Date: 2026-08-19

- Decision: Classify a `RunError` before rendering it. Unknown task, skill load failure,
  unsupported behavior, a non-retryable provider failure, and deterministic program-input
  failure are permanent. Retryable provider failure, skill execution failure, and a
  program runtime `ErrorS` are transient. A behavior timeout is transient.
  Rationale: Only a transient exception escaping before the step append causes genuine
  re-execution. Once an `Either Text Value` is journaled, its value is permanent.
  Date: 2026-08-19

- Decision: Introduce one patch id, `shikigami-behavior-retry-v1`, in both workflow
  specifications. Fresh agent runs use `run-behavior-v2`; fresh conversation turns use
  `run-behavior-v2:<messageId>`. Pre-patch instances retain the old labels and old
  interpretation.
  Rationale: The result encoding at an existing step must not change. A new label gives
  the new action a clean journal slot, and the patch preserves replay coherence for
  suspended instances. The per-message conversation label remains undeclarable, so its
  specification patch block is intentionally empty and documents the hand-owned dynamic
  family.
  Date: 2026-08-19

- Decision: Give the queue layer an explicit legacy outcome. A pre-patch agent result that
  contains a journaled behavior `Left` returns `RetryDefault`; the queue's delivery ceiling
  eventually DLQs it. A v2 permanent result returns `Dead`; v2 transients never become
  completed workflow results.
  Rationale: Old journal values contain only rendered text and cannot be reclassified
  reliably. Treating them conservatively as retryable preserves the pre-deploy behavior
  without string parsing. The workflow's top-level result is not itself the completion
  marker, so it may carry a non-journaled legacy/permanent disposition while every kept
  step result retains its old decoder.
  Date: 2026-08-19

- Decision: `worker.run_timeout_seconds` is a positive duration with a 300-second default
  and bounds each synchronous external behavior attempt, not an entire durable workflow.
  `approval.deadline_seconds` is a positive duration with a 900-second default. Both are
  whole seconds bounded to 1-86400.
  Rationale: A durable workflow may legitimately remain suspended for hours or continue
  through children; timing the whole queue handler would neither survive resumption nor
  distinguish waiting from hanging. The key name is retained because plan 37 and the
  master-plan portfolio already reserved it.
  Date: 2026-08-19

- Decision: Derive the resume worker's instance `leaseTtl` as
  `worker.run_timeout_seconds + 30 seconds`, while leaving direct
  `WorkflowRunOptions.leaseHeartbeat = Nothing`.
  Rationale: Keiro renews the claimed instance lease before a fresh step but not during
  that step. The TTL must exceed the slowest permitted behavior action, with a small
  scheduling/database margin, and must not be confused with the PGMQ heartbeat.
  Date: 2026-08-19

- Decision: Renew PGMQ visibility every 10 seconds by extending it 30 seconds, and supervise
  the heartbeat with `race` (or an equivalent linked primitive) so a renewal failure
  cancels and fails the handler.
  Rationale: A detached `withAsync` child can fail silently while the main action continues.
  The heartbeat and work are one failure domain: successful work cancels the infinite
  heartbeat; a failed heartbeat prevents an unsafe acknowledgement.
  Date: 2026-08-19

- Decision: Use `withEffToIO (ConcUnlift Persistent (Limited 2))` to place the typed
  handler action and `JobContext.extendLease` loop under `async`'s `race`.
  Rationale: `jobProcessorWithContext` fixes the handler's effect row and does not supply
  a `Concurrent` effect. The explicit bounded concurrent unlift safely makes that row
  available to exactly the work and heartbeat threads while preserving `race`'s sibling
  cancellation and exception propagation.
  Date: 2026-08-19

- Decision: Represent non-journaled workflow dispositions with
  `AgentRunFailure` and `ConversationTurnFailure` rather than returning undifferentiated
  `Text` to the queue worker.
  Rationale: the worker can now distinguish legacy retry, transient store/resume
  failure, permanent v2 failure, and terminal workflow failure without parsing rendered
  constructor text. Journaled behavior step values remain `Either Text Value` under
  their respective old or v2 labels.
  Date: 2026-08-19


## Outcomes & Retrospective

Implemented the retry boundary where it matters: a transient behavior error or timeout
now escapes before Keiro can append a step result, while a permanent error is bounded,
redacted, and journaled once. Both durable workflow families use patch id
`shikigami-behavior-retry-v1`; fresh agent runs write `run-behavior-v2`, fresh Danwa turns
write `run-behavior-v2:<messageId>`, and pre-patch instances retain their old branch. The
scaffolded artifacts are
`Shikigami.AgentRun.Generated.WorkflowFacts`,
`Shikigami.AgentRun.Generated.WorkflowRuntime`,
`Shikigami.DanwaConversation.Generated.WorkflowFacts`,
`Shikigami.DanwaConversation.Generated.WorkflowRuntime`, and
`Shikigami.Generated.Conformance`.

The run-job consumer now uses `keiro-pgmq` 0.13.0.0's typed `Job RunJob` surface with the
wire-compatible `aesonJobCodec`, startup main-queue/DLQ reconciliation, explicit
`JobOutcome` mapping, and the released default five-delivery transport policy. A linked
heartbeat renews visibility every 10 seconds to 30 seconds; the integration proof held a
handler for 2.5 seconds under a one-second initial visibility timeout and observed one
handler entry plus an empty queue. The outcome-table proof covers every `WorkflowOutcome`
constructor as well as store, legacy, transient, and permanent failures; a second integration
proof sends a permanent result through the actual processor and observes it in the reconciled
DLQ. Repeating startup reconciliation is also covered. The released façade still represents
application dead letters as Shibuya's `shibuya.poison_pill`; stable bounded
`shikigami.<reason>:` detail is the one intentional operational deviation already recorded in
this plan.

Settei now exposes `worker.run_timeout_seconds` (300 default) and
`approval.deadline_seconds` (900 default), both bounded to 1-86400 whole seconds. The
first reaches synchronous behavior attempts and derives a Keiro resume lease with a
30-second margin; the second reaches ordinary approvals and flow acknowledgements.
Direct workflow runs continue to leave `WorkflowRunOptions.leaseHeartbeat` unset.

Validation completed with `just keiro-gate 664b5eb` (both patch additions additive and
replay-neutral, all 12 conformance facts), `cabal build all`, and serialized
`cabal test all -j1`. The full suite passed 8 agent, 15 API, 3 client, 259 core, 5
migration, 20 server, and 24 worker tests in addition to conformance. The focused suites
also passed 5 retry-semantics, 5 run-job/heartbeat, 34 configuration, 4 workflow-versioning,
and 15 worker-command cases.

ADR review found no new record to create. The durable workflow-option and patch-set
decision is already captured by ADR-0004, including the separation between PGMQ delivery
heartbeats and Keiro instance leases; the typed consumer and exact retry/timeout values
are implementation and operational policy kept in this ExecPlan. The repository has no
`just check-adr` recipe, as recorded under Surprises & Discoveries.


## Context and Orientation

The domain error is `shikigami-core/src/Shikigami/Behavior/Error.hs`. Synchronous
behavior dispatch is in `Shikigami.Behavior.Run`; Baikai skill execution is in
`Shikigami.Behavior.Skill`. The agent workflow lives in
`shikigami-core/src/Shikigami/Agent/Workflow.hs`. Its ordinary behavior path journals
`Either Text Value` under `run-behavior`; the flow and research-supervisor branches are
durable paths and must not receive the synchronous attempt timeout.

The long-lived Danwa workflow is
`shikigami-core/src/Shikigami/Agent/Conversation.hs`. Every turn has dynamic labels such
as `run-behavior:<messageId>`, then waits on `next-message:<ordinal>`. Its checked
specification is `domain/shikigami-conversation.keiro`; the agent-run specification is
`domain/shikigami-agent-run.keiro`. The normative evolution procedure is
[docs/workflow-versioning.md](../workflow-versioning.md), and the central options value is
explained by [ADR-0004](../adr/0004-one-options-value-and-a-checked-patch-set.md).

The queue consumer is
`shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs`; worker-loop composition is
`shikigami-workers/src/Shikigami/Workers/Registry.hs`; `WorkerEnv` construction is
`shikigami-workers/src/Shikigami/Workers/Config.hs`. The producer remains
`shikigami-core/src/Shikigami/Trigger/Enqueue.hs`. Plan 18 owns transactional producer
enqueue, and plan 20 owns explicit trigger routing and removal of per-send queue creation;
this plan must not absorb those changes.

Configuration is declared once in
`shikigami-core/src/Shikigami/App/Config.hs`, documented in
`docs/operations/configuration.md`, and tested in
`shikigami-core/test/Shikigami/AppConfigSpec.hs`. Every new key needs a typed field,
bounded decoder, schema entry, default, environment binding, renderer, documentation, and
precedence/strictness tests.

The relevant accepted local architecture records are
[ADR-0003](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md), which
preserves the light-package dependency budget, and
[ADR-0004](../adr/0004-one-options-value-and-a-checked-patch-set.md), which governs
workflow options and patches. The deployed-service package ownership is the implemented
decision in
[plan 36](36-align-shikigami-with-the-six-package-deployed-service-architecture.md).

Applicable fleet standards:

- `mori://shinzui/keiro-runtime-patterns/docs/messaging-pgmq-jobs`
- `mori://shinzui/keiro-runtime-patterns/docs/messaging-pgmq-queue-reconciliation`
- `mori://shinzui/keiro-runtime-patterns/docs/keiro-durable-workflows`
- `mori://shinzui/keiro-runtime-patterns/docs/keiro-workflow-reliability`
- `mori://shinzui/keiro-runtime-patterns/docs/keiro-evolution-and-rollout`
- `mori://shinzui/keiro-runtime-patterns/docs/config-settei-service-standard`

The dependency source and released APIs are owned by
`mori://shinzui/keiro`, `mori://shinzui/shibuya`,
`mori://shinzui/shibuya-pgmq-adapter`, and `mori://shinzui/pgmq-hs`.


## Plan of Work

### Milestone 0 — adopt the released typed consumer dependency

Add `keiro-pgmq` to the `shikigami-workers` library dependencies and pin
`keiro-pgmq ==0.13.0.0` beside the other Keiro packages in `cabal.project`. Add its
release-matrix row to `docs/dependency-cohort.md` with tag
`keiro-pgmq-0.13.0.0` and commit
`1eef4b2f5323c419050f3584a0969a0c4f1c9308`; remove the statement that it
"resolves into nothing" now that the worker links it. Do not add `keiro-pgmq` to
`shikigami-core`.

Import queue-job APIs through the umbrella `Keiro.PGMQ` module and replace the hand-built
effect stack in `Shikigami.Workers.Registry` with `JobRuntime`/`runJobEff`. After the
source migration, audit `shikigami-workers.cabal` against actual imports: remove direct
`pgmq-effectful`, `shibuya-pgmq-adapter`, and `keiro-core` dependencies when unused.
Do not remove `keiro`, because worker modules directly import its workflow, inbox, timer,
and outbox APIs; do not remove `shibuya-core` while worker supervision or telemetry imports
its public types.

Before coding against the API, re-run the Hackage/package-page and upstream-tag checks.
The local Mori checkout may contain post-release commits, so the chosen implementation
must compile against the tagged 0.13.0.0 surface rather than a newer working tree.

### Milestone 1 — make behavior failure retryable before journaling

In `Shikigami.Behavior.Error`, introduce `FailureClass = Transient | Permanent`,
`classifyRunError`, and an exception such as
`TransientBehaviorFailure {detail :: Text}`. Preserve upstream retryability in the error
constructors: split or annotate `ProgramFailed` so task-argument parsing is permanent and
a runtime `ErrorS` is transient; keep `ProviderFailed Bool Text` authoritative. Rendering
is for logs and journal detail only, never for classification.

Create one helper for synchronous v2 attempts. It applies `System.Timeout.timeout` using
`worker.run_timeout_seconds`, calls `runBehavior`, throws
`TransientBehaviorFailure` for timeouts and transient `RunError`s, and returns
`Left boundedDetail` only for permanent errors. It must not catch asynchronous exceptions.
Keep details bounded and redacted before they enter a journal or DLQ.

In the agent workflow, call `patch (PatchId "shikigami-behavior-retry-v1")`. The active
branch uses a newly named `run-behavior-v2` step and the helper above. The inactive branch
retains the existing `run-behavior` action and result decoder. Carry a non-journaled
top-level failure disposition so the worker can distinguish a legacy recorded `Left` from
a v2 permanent `Left`; do not parse constructor text.

Apply the same patch in the conversation workflow. The active branch uses
`run-behavior-v2:<messageId>` and returns a permanent failure as a terminal
`Completed (Left ...)`; a transient exception escapes without a step record. The inactive
branch retains `run-behavior:<messageId>` and its current behavior. Adjust
`runConversationTurn` and the registry result type consistently. Keiro's completion marker
does not serialize the workflow's Haskell result, but every journaled step decoder remains
unchanged.

Declare the patch in both `.keiro` workflow bodies. The AgentRun block contains the new
static `run-behavior-v2` step. The DanwaConversation patch block documents the dynamic v2
family but remains empty because labels containing `:<messageId>` cannot be declared.
Run the scaffold, copy the generated Cabal/conformance fragments as prescribed by the
repository, update `KeiroConformance.Expectations`, and add a deploy-simulation test: an
old journal takes the old branch and decodes; a fresh journal records the patch and uses
only the v2 label.

### Milestone 2 — consume run jobs through `keiro-pgmq`

Define the run-job consumer declaration in the worker package:

```haskell
runJob :: Job RunJob
runJob =
  Job
    { jobName = "shikigami_run_jobs",
      jobQueue = queueRef "shikigami_run_jobs",
      jobCodec = aesonJobCodec,
      jobPolicy = defaultRetryPolicy
    }
```

Build the processor with `jobProcessorWithContext defaultJobTuning runJob`, then start it
with `runJobWorkers IgnoreFailures 100`. Run the whole queue action through
`runJobEff JobRuntime {runtimePool = pool env, runtimeTracer = Just (tracer (appEnv env))}`
instead of importing the PGMQ interpreter and adapter environment directly. Run
`ensureJobQueue runJob` before starting the app so both `shikigami_run_jobs` and
`shikigami_run_jobs_dlq` are reconciled idempotently. Log successful reconciliation and
fail worker startup on reconciliation or processor construction failure; do not start a
worker that cannot guarantee its DLQ.

Replace `handleRunJob :: WorkerEnv -> Value -> IO AckDecision` with a typed handler whose
application result is `JobOutcome`. Codec failure is owned by `aesonJobCodec` and
`keiro-pgmq`: malformed JSON is dead-lettered before application dispatch. Preserve the
current trigger-routing decision until plan 20 replaces it.

Map outcomes explicitly:

- successful agent or conversation completion: `Done`;
- `Suspended` or `ContinuedAsNew`: `Done`, because the Keiro resume worker owns progress;
- v2 permanent failure, unknown agent, cancelled workflow, or terminal `Failed`: `Dead`
  with bounded, redacted detail and a stable `shikigami.<reason>:` prefix;
- legacy recorded behavior failure, transient store failure, or
  `TransientBehaviorFailure` from the initial direct advance: `RetryDefault`;
- an unexpected synchronous exception: let it escape so Shibuya leaves the message
  unacknowledged and crash-redelivery follows the visibility timeout.

Do not add an application retry counter. `JobContext.attempt` is zero-based diagnostic
data; the adapter enforces `defaultRetryPolicy.maxRetries` from PGMQ's delivery count and
routes exhausted messages to the DLQ before application handling.

Add a compatibility test that the existing producer's `toJSON RunJob` decodes through
`runJob.jobCodec`, and that `encodeJob runJob.jobCodec` remains the same bare JSON. This
test is the guard for the documented producer-side pattern exception.

### Milestone 3 — supervise the PGMQ visibility heartbeat

Wrap only the queue handler's in-flight work, not the durable lifetime of the workflow.
Using the `JobContext` supplied by `jobProcessorWithContext`, wait 10 seconds, call
`extendLease 30`, and repeat until work finishes. Run the work and heartbeat under
`race` or an equivalent linked primitive:

- work completion cancels the heartbeat and returns its `JobOutcome`;
- heartbeat failure cancels the work and escapes, so no acknowledgement is emitted;
- cancellation and asynchronous shutdown propagate normally.

Do not write raw PGMQ `changeVisibilityTimeout` calls in application code. The acceptance
test must run through `jobProcessorWithContext` (or `runJobWorkers`) with a deliberately
short test visibility timeout, block the handler longer than that initial timeout, renew
through `JobContext.extendLease`, and assert one handler entry plus an empty main queue.
A companion negative control without renewal should demonstrate redelivery, but may be
kept as a local diagnostic if timing makes it unsuitable for the default suite.

### Milestone 4 — configure attempt and approval budgets coherently

Extend the single `AppConfig` with direct record fields
`runTimeout :: NominalDiffTime` and
`approvalDeadline :: NominalDiffTime`. Declare:

- `worker.run_timeout_seconds`, environment
  `SHIKIGAMI_RUN_TIMEOUT_SECONDS`, default 300;
- `approval.deadline_seconds`, environment
  `SHIKIGAMI_APPROVAL_DEADLINE_SECONDS`, default 900.

Use bounded positive-second decoders and renderers following the existing Settei pattern.
The upper bound must keep conversion to microseconds safe; document it beside the setting.
Add both fields to `defaultAppConfig`, `environmentBindings`, declared-key tests,
YAML/environment/CLI precedence tests, `--describe-config`/`--explain-config` coverage,
and `docs/operations/configuration.md`.

Thread the values through `WorkerEnv`, `AgentRunDeps`, and `ConversationEnv`.
`approvalDeadline` replaces the worker's current `deadline = Nothing`; both ordinary
approval awaits and flow acknowledgement deadlines use it. `runTimeout` reaches only the
synchronous v2 behavior helper.

Change the central resume-options constructor to accept the configured behavior timeout,
for example:

```haskell
shikigamiWorkflowResumeOptions :: NominalDiffTime -> WorkflowResumeOptions
shikigamiWorkflowResumeOptions timeout =
  defaultWorkflowResumeOptions
    { runOptions = shikigamiWorkflowRunOptions,
      leaseTtl = timeout + 30
    }
```

Use generic-lens field updates if required by duplicate fields in the released API. The
resume worker passes the configured timeout from `WorkerEnv`. First/direct workflow runs
continue to use `shikigamiWorkflowRunOptions` with `leaseHeartbeat = Nothing`.


## Concrete Steps

From the repository root:

1. Verify dependency identity and released surfaces:

   ```bash
   mori registry show shinzui/keiro --full
   mori registry docs shinzui/keiro
   mori registry show shinzui/keiro-runtime-patterns --full
   mori registry docs shinzui/keiro-runtime-patterns
   keiro_source="$(mori path mori://shinzui/keiro)"
   git -C "$keiro_source" show keiro-pgmq-0.13.0.0:keiro-pgmq/src/Keiro/PGMQ/Job.hs
   ```

   Also verify Hackage's latest package pages and upstream tags before changing bounds.

2. Add the dependency pin/cohort row and implement the shared failure classifier and v2
   attempt helper. Add focused pure tests before editing workflow bodies.

3. Declare and scaffold the workflow patch:

   ```bash
   just keiro-scaffold
   just check-adr
   ```

   Update hand-owned conformance expectations and run the focused specification tests.
   Before merging, calculate the real merge base and run:

   ```bash
   just keiro-gate <merge-base>
   ```

4. Implement the agent and conversation v2 branches and deploy-simulation tests. Confirm
   old journals decode without running a v2 action and fresh journals never write the old
   label.

5. Replace the raw consumer construction with the typed job processor, add startup
   reconciliation and outcome mapping, then add the supervised heartbeat.

6. Add the two Settei settings and thread them through the worker and central resume
   options.

7. Validate in the dev shell:

   ```bash
   nix develop --command cabal test shikigami-core-test --test-options='--pattern RetrySemantics'
   nix develop --command cabal test shikigami-workers-test --test-options='--pattern RunJob'
   nix develop --command cabal build all
   nix develop --command cabal test all -j1
   ```

Record exact commands and results in Progress as each milestone completes.


## Validation and Acceptance

Acceptance is behavioral, not merely a successful build.

- A transient `ProviderFailed True`, transient program runtime failure, and behavior
  timeout throw before `run-behavior-v2` is appended. A later advance invokes the behavior
  again and can complete.
- `UnknownTask`, malformed/missing skill, unsupported behavior, non-retryable provider
  failure, and deterministic program-input failure append one permanent v2 result and
  replay without a second behavior call.
- Conversation turns have the same transient/permanent behavior. A permanent v2 failure
  completes as a typed failure rather than replaying an `IOException` indefinitely.
- A deploy simulation proves pre-patch AgentRun and DanwaConversation journals stay on
  their old labels and fresh instances record `shikigami-behavior-retry-v1`.
- Raw producer JSON round-trips through `aesonJobCodec`; no `{v,t,data}` envelope appears.
- Worker startup reconciles both the main queue and
  `shikigami_run_jobs_dlq`; repeating startup is a no-op.
- Typed outcome table tests cover every `WorkflowOutcome` plus store, legacy, transient,
  and permanent failure cases. No application branch constructs `AckDecision`.
- The integration heartbeat test holds work beyond the initial visibility timeout and
  records exactly one handler entry. A heartbeat failure prevents acknowledgement.
- `worker.run_timeout_seconds` and `approval.deadline_seconds` reject zero, negative,
  malformed, and out-of-range values; defaults and source precedence are visible through
  the config diagnostics.
- `shikigamiWorkflowResumeOptions runTimeout` has
  `leaseTtl > runTimeout`, and first-run options leave `leaseHeartbeat` unset.
- `just keiro-gate <merge-base>`, focused suites, `cabal build all`, and
  `cabal test all -j1` pass under `nix develop`.


## Idempotence and Recovery

All specification, Haskell, Cabal, and documentation edits are repeatable. Queue
reconciliation is additive and idempotent; it never drops or recreates an existing queue.
`aesonJobCodec` preserves messages already present on `shikigami_run_jobs`.

A crash during a transient behavior attempt leaves no v2 result, so the action may run
again. External behavior calls and all step bodies therefore remain at-least-once and must
use stable request/idempotency identities wherever a provider supports them. A crash after
a permanent v2 result append replays that result without another external call.

If heartbeat renewal fails, the handler must not acknowledge. PGMQ redelivers after the
last visibility extension. If the queue retry ceiling is exhausted, the adapter moves the
message to the DLQ. Operators recover a terminal Keiro workflow through the supported
`resurrectFailedWorkflow` API after repairing the cause; they must not edit workflow
instance/journal tables by hand.

Rollback across the new patch is unsafe after fresh instances have journaled the active
branch. Follow `docs/workflow-versioning.md`: keep both branches until no pre-patch
instance can resume, and retire the patch id and old branch together in a later,
separately reviewed change.


## Portfolio Reconciliation

Plan 17 owns behavior failure classification, synchronous behavior-attempt timeouts,
run-job consumer outcomes, PGMQ visibility heartbeat, and approval deadline wiring.

Plan 18 continues to own atomic inbox plus transactional producer enqueue and its
`ensureRunQueue` producer bootstrap. Plan 20 continues to own explicit trigger routing,
addressed-run idempotency, removal of per-send `createQueue`, and other enqueue hardening.
The typed consumer introduced here must preserve their raw `RunJob` wire contract.

Plan 36's deployed-service package boundary remains authoritative:
`shikigami-workers` owns supervised consumer mechanics and `shikigami-core` owns the
producer contract. ADR-0003's later seventh-package exception does not change that arrow;
it strengthens the reason not to pull the adapter stack into core, because
`shikigami-agent` is a light leaf over core. Plan 37's single Settei declaration remains
the only configuration surface. Plan 39 and `docs/workflow-versioning.md` own
scaffold/gate mechanics and patch retirement.


## Interfaces and Dependencies

New or changed core interfaces are expected to have this shape; exact constructor names
may vary, but the separation of classification, journal detail, and transient exception
must not:

```haskell
data FailureClass = Transient | Permanent

classifyRunError :: RunError -> FailureClass

data TransientBehaviorFailure = TransientBehaviorFailure
  { detail :: !Text
  }

runBehaviorAttempt ::
  NominalDiffTime ->
  BehaviorEnv ->
  AgentDecl ->
  BehaviorInput ->
  IO (Either Text Value)
```

The worker-side typed queue surface is:

```haskell
runJob :: Job RunJob

handleRunJob ::
  WorkerEnv ->
  JobContext es ->
  RunJob ->
  Eff es JobOutcome

withVisibilityHeartbeat ::
  JobContext es ->
  Eff es a ->
  Eff es a
```

`AgentRunDeps` and `ConversationEnv` gain `runTimeout` and use the configured approval
deadline where applicable. `WorkerEnv` carries both resolved values. The central resume
options become a function of the synchronous behavior timeout.

Released dependencies used by the implementation:

- `keiro-pgmq ==0.13.0.0`: typed job, codec, retry policy, reconciliation, context lease,
  processor, effect-stack façade, and runner APIs;
- `keiro ==0.13.0.0`: workflow patches, outcomes, resume options, and workflow-instance
  leases; it remains a direct dependency because `keiro-pgmq` does not re-export these
  modules;
- `shibuya-core ==0.9.0.0`: public supervision and telemetry types still imported by the
  worker; `shibuya-pgmq-adapter` remains transitive behind `keiro-pgmq`, not a direct
  application dependency;
- `pgmq-hasql ==0.5.0.0`: the existing lightweight producer path in
  `shikigami-core`; lower-level PGMQ runtime packages remain transitive behind
  `keiro-pgmq` unless another Shikigami module directly imports them;
- `async`: supervised `race` for heartbeat/work lifetime;
- `base`: `System.Timeout` and the typed exception;
- `settei ==0.2.0.0` plus the existing env/YAML/CLI integrations.

No database migration is required. The new DLQ is a reconciled PGMQ queue, and the workflow
patch is a journaled compatibility decision declared through the Keiro specification.


## Revision Notes

- 2026-08-19: Rewrote the plan after a full current-code and dependency audit. Replaced
  stale monolithic worker paths and the obsolete keiro/shibuya gate; corrected
  `mkRetryPolicy` and the fixed PGMQ retry policy; separated PGMQ delivery renewal from
  Keiro instance leasing; moved the timeout from the whole queue handler to synchronous
  behavior attempts so resumed workflows are covered; added conversation semantics and a
  checked v2 patch path; adopted `keiro-pgmq` on the consumer side; documented the
  producer-side package-boundary exception; removed the unsupported promise of
  application-specific DLQ codes; and aligned configuration, tests, and validation with
  the current Settei and workflow-versioning rules.
- 2026-08-19: Clarified the dependency and payload boundary after review:
  `Keiro.PGMQ` is the sole application-facing queue façade and replaces redundant direct
  runtime/adapter dependencies, but it does not replace the separate `keiro` workflow
  package and is not codec-only internally. Kept `aesonJobCodec` for a wire-compatible
  typed migration and documented the dual-read rollout required before adopting
  `keiroJobCodec`.
- 2026-08-19: Implemented milestones 0 and 1. Added the released `keiro-pgmq`
  dependency, introduced classified attempt failures and bounded synchronous timeouts,
  scaffolded the shared retry patch, and added retry/replay and deploy-simulation tests.
- 2026-08-19: Implemented milestones 2 and 3. Replaced raw Shibuya/PGMQ consumer wiring
  with the typed `Job RunJob` façade, startup queue/DLQ reconciliation, explicit
  `JobOutcome` mapping, and a linked 10/30-second visibility heartbeat. Added a wire
  compatibility test, a real `jobProcessorWithContext` slow-handler test, and a renewal
  failure cancellation test; the focused `RunJob` selection passed all three cases.
- 2026-08-19: Implemented milestone 4. Declared and documented the two Settei duration
  settings, replaced worker boot constants with resolved values, wired the approval
  deadline into approvals and acknowledgements, and derived the Keiro resume lease as
  the behavior timeout plus 30 seconds. The focused configuration suite passed 34 cases,
  workflow versioning passed 4, and worker command configuration passed 15.
- 2026-08-19: Completed validation and retrospective. The workflow gate classified both
  patch additions as additive and replay-neutral, the all-target build passed, the full
  serialized suite passed, and ADR review confirmed ADR-0004 already owns the durable
  architecture decision.
- 2026-08-19: Strengthened the final worker acceptance proof with a pure typed outcome table,
  idempotent queue reconciliation, and a real processor-to-DLQ permanent-failure test. The
  focused `RunJob` selection passed all 5 cases and the full worker suite passed all 24.
