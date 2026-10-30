---
id: 94
slug: adopt-current-runtime-lifecycle-patterns-and-bounded-operator-inspection
title: "Adopt current runtime lifecycle patterns and bounded operator inspection"
kind: exec-plan
created_at: 2026-10-28T13:08:12Z
intention: "intention_01m61agcfzek98hqzkb0kxcfmg"
master_plan: "docs/masterplans/16-upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-28T13:08:12Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-28T13:21:22Z
      mode: "update"
      note: "Complete source-grounded draft and link the requested Mina intention"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-30T19:46:17Z
      mode: "update"
      note: "Expand unused-service adoption to six children, current domain census, HTTP/live inspection, Haskell corpus and first-release qualification."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-30T21:20:20Z
      mode: "implement"
      note: "Begin native delivery and registered workflow recovery after accepted plans 92 and 93"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T13:29:30Z
      verdict: "approved"
      note: "Lifecycle and bounded inspection scope is coherent; add current ADR 0054 context when reconciling plan 83."
---

# Adopt current runtime lifecycle patterns and bounded operator inspection

## Purpose / Big Picture

Make actual queue, trigger, subscription and workflow paths correct under the new delivery and resource-lifetime semantics. Inspection hosting is now owned by plan 106.

## Progress

- [x] M1 (2026-10-30): Native ownership, admission, four-attempt finalization failure, invalid configuration, callback/cancellation/cleanup and joined admitted-work drain pass. Shared store/options, bounded queue/prefetch/health policies and all258 worker cases pass.
- [x] M2 (2026-10-30): The five-family registry and current generation-specific wakes pass all375 serial PostgreSQL cases; all539 pure tests pass. Current effect interpretation changes are replay-neutral againste203470.

## Surprises & Discoveries

The October28 scope assumed a deployed population and an older domain census.
The current common resume registry covers five workflow families. Existing native
histories cover approval, conversation, execution and continuing-session recovery;
those tests are retained after plan93's reset.

M1 source review found unbracketed Shibuya application handles on both Kafka and
PGMQ consumer paths. Kafka also reconnected after a retained permanent processor
failure because waitApp returns for terminal processors. The shared allocator now
masks ownership transfer, restores cancellation inside a finally boundary, stops
exactly once and checks retained public lifecycle health. PGMQ selects
StopAllOnFailure and retains the supported runJobWorkers allocator. Current native
admission, finalization-failure, callback/cancellation cleanup and invalid-config
cases pass; additional full runtime qualification remains in progress.

The full worker candidate exposed one obsolete workspace patch-population test
left after plan93; that test is removed, with current workspace admission/refusal
coverage retained. Native permanent-finalizer failure can arrive as Shibuya's
linked ProcessorFailure or retained public-health failure; the test runs its owner
in an isolated async and accepts only those typed infrastructure paths, then
checks one handler, four finalizer attempts and exactly one adapter cleanup.

The initial eight native cases passed; final ConsumerApp covers ten policy/lifecycle cases and App runtime covers two service-interpreter cases.
The store-reuse case deliberately supplies unusable connection settings while
querying twice through the acquired handle. The options case supplies real
process metrics and checks tracer/metric presence plus bounded seed verification.
Whole consuming build and enabled test components pass, followed by all539 pure,375 PostgreSQL and258 worker cases.

The released PGMQ path exposes no application retry-budget override through
Keiro's public JobTuning. Retain its five-attempt/1.5second poll/ack default and
rely on process supervision after exhaustion; no hidden adapter field or longer
same-pool outage claim is introduced. Queue inbox capacity is now1 and initial
visibility covers two configured attempt windows plus60seconds; active work still
renews10/30seconds. Queue health uses attempt+30seconds. Idle paused processors
stay healthy; paused admitted work still expires against last progress.

Startup previously forced only RunEvidence validation explicitly. It now forces
all four generated aggregate event streams before registration. Runtime connection
settings now set the guide-required thirty-second statement timeout.

## Decision Log

2026-10-30: Introduce the service-owned Shikigami.App interpreter over the released
Kioku effect row plus a Reader of RunCommandOptions. Runtime environments may bind
their already acquired KirokuStore; standalone commands may acquire one. The public
runKirokuStoreWith interpreter removes repeated pool/notifier acquisition without
casts or private APIs. Every aggregate catalog writer takes command options from
that interpreter, carrying process tracer/metrics while preserving upstream bounds.
This changes no recorded workflow operation, seed or wire value.

2026-10-30: Apply the user's first-release policy and exhaustive current-guide adoption. Replace old-history qualification with fresh provisioning and same-build recovery. Preserve real transaction, authority and privacy invariants.

## Outcomes & Retrospective

Both milestones are accepted. The service interpreter reuses acquired stores and
threads command telemetry across all four aggregate writers. Consumers own their
Shibuya lifetimes through masked transfer and joined cleanup; infrastructure and
non-retryable Kafka failures reach process supervision. Current queue intake,
visibility and health budgets follow the configured attempt horizon, and idle
paused health no longer expires solely because work is intentionally paused.

[Native runtime evidence](../evidence/keiro-0.22/native-runtime-lifecycle.md) records
the five-family recovery census, exact consumer policies and retained boundaries.
[Results](../evidence/keiro-0.22/native-runtime-results.txt) record all539 pure,
375 PostgreSQL and258 worker cases plus the whole enabled-component build. Current
DSL diff is empty/replay-neutral; unknown guard relations/remedies now fail CI.

The38 guide groups have clause dispositions. Pending selected inspection/provider
and administrative clauses belong to106, and final artifact/Linux/load observations
to95. Their pending rows stay visible; this child does not certify those profiles.
REL20/27 inspection ownership is corrected to106 without changing the denominator.
ADR38 records accepted ownership/budget decisions. The one remaining retired
workspace patch-population test is removed; real current workspace refusal and
recovery coverage remains. No new friction met the recording threshold.

## Context and Orientation

Shikigami has seven packages: core domain/runtime, API contracts, HTTP server, workers, client/CLI, migrations and the lightweight agent runner. The last is the deliberate ADR-3 exception to the six-package pattern. Work from this repository root and locate dependencies through Mori before using their APIs. Never traverse `/nix/store`. Current objective work under MasterPlan 17 edits configuration, generated catalogs, migrations and core tests; preserve and reconcile that work rather than reverting it. The workspace currently has ten members, including ExecutionDriver, WorkerSession, ContinuingWorker and Objective. Recount from `domain/shikigami.keiro-workspace` at implementation; neither six members nor two aggregates is a valid fixed inventory.

On 2026-10-30 the user confirmed Shikigami is unused. [ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) and [ADR-37](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md) apply: establish one current first-release contract, remove obsolete compatibility branches/readers, and allow deliberate schema/wire changes. Do not require old binaries, old populated databases or cross-build replay as acceptance. This does not authorize deleting a developer database or weakening external authorization, accounting, protected payloads or same-build replay. Record exact breaking DSL findings and establish the accepted baseline without suppressing the differ. `docs/workflow-versioning.md` still governs durable bodies after that baseline.

The frozen guide inventory is `docs/architecture/keiro-0.22-coverage.json`: canonical resource, producer revision, relative source path, SHA-256, child owner, pending disposition and evidence. The readable audit is `docs/architecture/keiro-0.22-pattern-audit.md`. Pending rows are planned work, not compliance claims. Every applicable clause requires an implemented behavior or justified existing implementation and current evidence. Strict unprefixed fields, explicit deriving strategies and isolated generic-lens orphan imports apply to all touched Haskell and examples.

`Shikigami.Runtime`, `Shikigami.Workflow.Registry`, worker `Agent/Workflow/Resume.hs`, `Trigger/Consumer.hs`, `Trigger/Timer.hs`, `Trigger/Scheduler.hs`, `Workers/Subscription.hs`, `Agent/RunJob/Worker.hs` and `Health/Worker.hs` own runtime assembly. Trigger.Consumer directly constructs Shibuya AppConfig and exposes a process-local supervisor. `Execution.Store`, `Execution.Timer` and the workflow await paths own generation-specific wakes. [ADR-38](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md) defines startup, retention and resource-aware resume; [ADR-54](../adr/0054-execution-attempts-own-dispatch-fences-and-generation-wakes.md) defines dispatch and generation authority. The filename retains its historical inspection wording to preserve links; plan 106 exclusively owns that work now.

## Plan of Work

M1 validates migration handshake before intake, telemetry before store acquisition, validated event streams/catalog before queries and workers, and bracketed shutdown. Preserve each source's projection set as execution, evidence, worker-session and objective owners are composed. Use defaultAppConfig with the existing StopAllOnFailure, serial strict ordering and inbox bounds. Distinguish Paused from failed and drained. Exercise deliveryStatus admission so superseded deliveries invoke neither handler nor finalizer, and permanent finalizer failure reaches supervision. Native adapters own acknowledgement/finalization; do not duplicate their counters or retry ownership. Deterministic configuration failure must not reconnect forever.

For each real subscription, validate capacities, missing-checkpoint policy, target identity, startup/decode failure, retry budget and checkpoint-after-success. Use namespace targets only when the intended input domain actually spans that namespace; exact category consumers keep their scope. Record stopped-owner resize/rebind constraints. Retain PGMQ polling after 0007 removes partitioned-queue notifications. Test visibility extension, duplicate deliveries, poison/exhausted jobs, original_queue DLQ metadata and native redrive authorization. Kafka offsets advance only after the service's durable disposition; test unavailable persistence rather than logging acceptance. HTTP sink outbox delivery retains its own receipt and uncertainty semantics.

M2 recenses the workflow registry and tests every real family, including execution drivers and continuing workers, rather than the old fixed three. Reuse Kioku resource-aware resume without casts/private APIs; remove adapters only when current released APIs genuinely replace their capability. Prove one generation-specific wake before extending fixtures: accepted wake and exact await name, rotation/cancellation races, stale owner/claim refusal, terminal instances not revived, durable resolution/abandonment, and no duplicate external dispatch on replay. Keep allocated opaque IDs and authoritative receipts within the new same-build baseline. Preserve late outcomes as reconciliation evidence and unknown effects as unresolved; expiry is not proof an external process stopped. Maintain one timer dispatcher and explicit workflow GC/idempotency horizon, distinct from protected payload and application retention.

Workflow shape cleanup is coordinated with plan 93. No fake historical patch branch is required, but same-build restart still cannot repeat committed model/tool/accounting work. Hand plan 106 a bracketed process-local metrics provider owned by the real Shibuya AppHandle; inspection must not allocate a second runtime.

## Concrete Steps

Run from the repository root in the declared development shell. Use disposable task-owned databases and the existing source-owned fixtures. These are implementation commands, not evidence of tests already run:

```bash
nix develop --no-write-lock-file -c cabal test shikigami-workers-test shikigami-core-test
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test --test-options=-j1
nix develop --no-write-lock-file -c cabal test keiro-shikigami-conformance
nix develop --no-write-lock-file -c just keiro-check
```

Record actual cases and concise output under `docs/evidence/keiro-0.22/`. Database tests that skip are not accepted. Before claiming Linux is unavailable, inspect `container --help`, `container list --all` and `tests/workspace/build-apple.sh`; use native ARM64 Apple containers, retaining the documented remote-builder fallback only when needed. Do not claim runtime containment from compilation alone.

## Validation and Acceptance

Regression cases cover ordinary and superseded delivery, poison/no checkpoint advance, finalizer failure, deterministic startup refusal, cancellation and joined cleanup. Every current workflow family resumes from its own new-build suspended state; stale wakes/claims cannot resurrect work or settle twice. Record actual test names and owner/source inventory. Dead-timer recovery uses supported claims and rejects stale tokens.

## Idempotence and Recovery

Repeat generation against an isolated coherent candidate so concurrent uncommitted work cannot masquerade as generated drift. Preserve create-once holes. Recreate only task-owned disposable fixtures after failure; never clear shared journals, leases or bindings to obtain a passing test. Record the source/dirty diff and current input artifacts for reproducibility, without requiring a successful old build before refactoring. A released-schema rollback is not promised. Future post-release evolution resumes the ordinary versioning rules. Record friction through `agents/skills/exec-plan/FRICTION.md`, promote durable decisions through the local plain-Markdown ADR convention, and scan touched code and prose for stale prefixed fields.

## Interfaces and Dependencies

Requires plan 92 Complete. Plan 93 is a soft dependency and integration peer for command result meanings and workflow baseline; coordinate edits to Execution.Store with its owner. Own runtime lifecycle and the process-local metrics lifetime consumed by plan 106. Plan 95 requires this child Complete.

## Revision Notes

2026-10-30: Expanded MasterPlan 16 under the user's unused-service confirmation; replaced compatibility-driven scope with current-contract adoption and explicit behavioral evidence. Previous provenance entries and review verdicts remain historical and do not certify this revision.
