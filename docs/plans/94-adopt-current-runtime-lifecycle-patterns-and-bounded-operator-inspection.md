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
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T13:29:30Z
      verdict: "approved"
      note: "Lifecycle and bounded inspection scope is coherent; add current ADR 0054 context when reconciling plan 83."
---

# Adopt current runtime lifecycle patterns and bounded operator inspection

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture


Keep workflow, queue and trigger progress correct under the released lifecycle changes and expose useful bounded upstream inspection through the existing operator CLI. Operators can inspect the two real application aggregates and new workflow/timer/projection status surfaces without reading protected replay bodies or adding work to ordinary command paths.


## Progress


- [ ] M1: Runtime startup, delivery admission, supervision and recovery follow the new cohort's lifecycle contracts with regression evidence.
- [ ] M2: The embedded operator CLI mounts safe application aggregate inspection and preserves bounded reads, schema verification, mutation previews and typed errors.


## Surprises & Discoveries


None yet.


## Decision Log


2026-10-28: Mount application-owned aggregate inspection through the existing `keiro-ops` CLI. Do not introduce an operational HTTP/WebSocket listener or fabricate process-manager descriptors for ordinary workflow families. Keep optional libraries unlinked unless an actual consumer exists.


## Outcomes & Retrospective


To be filled during implementation.


## Context and Orientation


Hard prerequisite: `docs/plans/92-resolve-the-released-keiro-0-22-cohort-and-rehearse-the-composed-migration.md` is Complete. It already makes mandatory constructors and matches compile under the released cohort. This child verifies their behavior and adopts useful public inspection. `docs/plans/93-adopt-guarded-catalog-commands-and-qualify-current-dsl-consumer-contracts.md` is a soft dependency and integration peer; share catalog ownership and error meanings without blocking on its implementation.

`shikigami-core/src/Shikigami/Runtime.hs` registers the shared catalog before serving and installs telemetry callbacks when constructing connection settings. `shikigami-core/src/Shikigami/Workflow/Registry.hs` combines agent runs, approvals and conversations without erasing Kioku resource effects. `shikigami-workers/src/Shikigami/Agent/Workflow/Resume.hs` owns resource-aware recovery. `shikigami-workers/src/Shikigami/Trigger/Scheduler.hs` and `Trigger/Timer.hs` own the shared timer pass. `shikigami-workers/src/Shikigami/Trigger/Consumer.hs` owns Kafka trigger delivery and currently directly constructs Shibuya AppConfig; `Agent/RunJob/Worker.hs` consumes the generated queue. `shikigami-workers/src/Shikigami/Health/Worker.hs` observes processor lifecycle. These boundaries must survive new deliveryStatus, Paused, finalizer failure and startup-refusal semantics.

`shikigami-server/src/Shikigami/Server/Command/Ops.hs` embeds the upstream command tree via `emptyAppHooks`, currently mounting replay audit and the shared projection catalog. Resume and timer-drain hooks are deliberately absent because their effect rows do not carry the resource-aware runtime. New `AppHooks.aggregates` and `.processManagers` permit optional application catalogs; new workflow pages/status classes and timer/projection/shard inspection arrive through the upstream tree. This service has RunEvidence and ExecutionLifecycle aggregates, not declared reactive process managers. `Keiro.Inspection.Aggregate` exports explicit aggregate descriptors, `SomeAggregateInspector`, `aggregateInspector`, and `aggregateInspectors`. Resolve the published source with Mori before constructing them. The module is at project-relative `keiro/src/Keiro/Inspection/Aggregate.hs` in `mori://shinzui/keiro` (artifact-level source URI pending).

Consult [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md) for startup/recovery/retention and [ADR 0053](../adr/0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md) for protected replay. [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) and `docs/workflow-versioning.md` govern any workflow edit. Upstream `mori://shinzui/keiro/okf/adrs/concepts/ADR-28` requires operator wrappers over public owning APIs; `mori://shinzui/keiro/okf/adrs/concepts/ADR-54` requires explicit safe aggregate displays and the shared hydration algorithm. Applicable standards include `mori://shinzui/keiro-runtime-patterns/docs/keiro-runtime-assembly`, `mori://shinzui/keiro-runtime-patterns/docs/keiro-workflow-reliability`, `mori://shinzui/keiro-runtime-patterns/docs/messaging-shibuya-processing` and `mori://shinzui/keiro-runtime-patterns/docs/inspection-hosting-and-browser-access`.


## Plan of Work


### M1 — Verify lifecycle owners and delivery semantics

Compare actual startup ordering to the current runtime assembly standard: read-only migration handshake, telemetry, bracketed store, event-stream/catalog validation and registration, then intake. The shared catalog now includes ExecutionLifecycle; test that both generated sources are validated and preserved by live factories. Keep one resource-aware workflow registry, one timer dispatcher and the deliberate workflow GC policy. Inspect upstream exports before assuming previously absent resume-success callbacks or ops resume effect support now exist. Retain justified adapters if public effect requirements still do not match.

Verify Shibuya default-based AppConfig preserves StopAllOnFailure, serial strict ordering and inbox bounds while retaining basic metrics. Handle Paused truthfully in health; a paused worker is neither failed nor proof its in-flight work drained. For application/custom test adapters, use current deliveryStatus and prove a superseded delivery invokes neither the handler nor finalizer. The released Kafka/PGMQ adapters own their acknowledgement and finalization semantics; do not wrap them with a duplicate decrement/retry protocol. Surface permanent finalizer failure as supervision failure and ensure a reconnect loop cannot repeatedly restart a deterministic definition/startup error.

Review any actual Kiroku subscriptions for validated capacities, explicit missing-checkpoint policy and typed startup/decode failures. Do not introduce namespace targets or shard resizing unless this service needs them. Document stopped-owner requirements for resize as an operator constraint if exposed through ops; never mutate checkpoint/lease tables privately. Keep PGMQ polling even when notifications exist: partitioned queues no longer emit insert notifications. Requalify queue visibility timeout, retry/dead-letter semantics, cancellation and changed DLQ `original_queue` fields against real worker behavior.

Audit custom execution wakes in `Shikigami.Execution.Store`, `Execution.Timer` and workflow await code after reconciling plan 83: durable logical row, exact awaited name, generation-race recheck, instance-row updates on resolution/abandonment, and no delivery after terminal refusal. Preserve allocated opaque awakeable IDs and historical step results. Fix deviations within existing recovery acceptance; do not add a second wake registry. Any workflow body adjustment gets a real declared patch and old/fresh deployment simulation.

M1 is accepted when startup refuses incompatible schema, all three workflow families resume, ordinary/superseded deliveries behave correctly, finalizer failure reaches supervision, timer recovery fences stale owners, and new custom wakes cannot revive cancelled/rotated work.

### M2 — Useful, bounded operator inspection

Add a small hand-owned `Shikigami.Inspection.Aggregates` module in core with two explicit descriptors using generated validated streams/categories. Supply narrow display encoders for lifecycle state, identity and revision metadata. Never delegate display to a rich replay snapshot codec or inspect protected provider data, credentials, tool arguments or model histories. Preserve the physical category/stream mapping and reject duplicate descriptor names. Register its modules in Cabal and mount the resulting catalog through `shikigamiOpsHooks.aggregates`.

Use the released ops parser to surface aggregate type/list/show commands and its workflow inspect, timer pages, projection status and shard status commands. Verify exact syntax from pinned `--help`; document runnable examples with a fixture-owned aggregate/workflow identity. New process-manager discovery remains empty/unmounted unless a real compiled manager exists. Preserve typed `InspectionFailed` instead of rendering failed reads as empty lists. Preserve upstream opaque cursor ordering/filter/version binding, bounded bytes and deadlines; do not recreate SQL or decode/rebuild cursors.

Keep existing audit/catalog hooks, Settei database selection and redacted invocation logging. Recheck whether the new release adds a supported configured-connection entry point before retaining the process-local environment adapter; remove it only if the released API actually replaces it. Preserve preview/force behavior, especially `pgmq dlq read`, which now leases rows for 30 seconds and requires explicit mutation authorization. Aggregate inspection is read-only and must not run workflow resumption or seed verification, create a periodic task, or enable legacy process-manager provenance on ordinary command options.

Extend the existing operator and health tests plus a PostgreSQL fixture for both aggregate descriptors. Update ADR 0038 or a focused local ADR for durable inspection display boundaries when accepted. Classify optional HTTP, composed browser mounts and feeds explicitly in the audit; no new listener is needed to complete this child.


## Concrete Steps


From the repository root:

```bash
mori registry show shinzui/keiro --full
mori registry docs shinzui/keiro-runtime-patterns
nix develop --no-write-lock-file -c cabal run shikigami -- ops --help
nix develop --no-write-lock-file -c cabal run shikigami -- ops wf --help
nix develop --no-write-lock-file -c cabal test shikigami-workers-test shikigami-server-test
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test --test-options=-j1
nix develop --no-write-lock-file -c cabal test keiro-shikigami-conformance
git diff --check
```

Use the pinned parser help to add exact aggregate/timer/projection inspection examples to `docs/operations/keiro-0.22-rollout.md` during implementation. Database commands run only against a disposable fixture's supplied configuration. Store concise runtime and inspection evidence under `docs/evidence/keiro-0.22/`; never retain protected payload bodies.


## Validation and Acceptance


The existing `shikigami-workers/test/Shikigami/Workers/SupervisionSpec.hs`, `Health/WorkerSpec.hs`, `TimerRecoverySpec.hs`, `Agent/RunJob/WorkerSpec.hs` and core PostgreSQL workflow/selection tests are the main regression paths. Add focused lifecycle cases only where new behavior is not already covered. A paused or superseded processor must not be reported as successful work. A schema mismatch refuses before listeners/intake; all supported workflow families retain progress under restart and timer recovery.

Server command tests preserve redaction, explicit database precedence, catalog hooks and mutation-preview exit semantics. An inspection fixture shows the folded state/version of both real aggregates, proves protected replay bodies are absent, returns a typed error for an invalid target/cursor, and pages without draining hidden extra pages to fill results. Reading inspection must not alter event counts, checkpoints, claim ownership or command options. A large or sparse query stays within the chosen finite operational budget. HTTP/feeds remain an explicit non-selected capability rather than an untested claim of adoption.


## Idempotence and Recovery


Default-based assembly and read-only inspection are repeatable. Preserve workflow labels, retained result decoders, queue identities and allocated awakeable IDs. If a patch is necessary, retain the genuine pre-change branch until its population is empty; the upgrade does not renew the old pre-v1 reset exception. Keep failed startup cleanup bracketed and do not retry deterministic refusals forever. A deadline after an operator mutation can leave an uncertain committed result; retain target identity and reconcile with public reads instead of blindly repeating. No production mutation, destructive replay or new listener is authorized by this child.


## Interfaces and Dependencies


This child defines the application aggregate inspector catalog and its safe display contract. It consumes the generated streams/catalog from the completed dependency child and shares them with `docs/plans/93-adopt-guarded-catalog-commands-and-qualify-current-dsl-consumer-contracts.md`. Keiro owns hydration, cursors, schema checks and ops parsing; Shikigami owns which application state is mounted, configuration, redaction and resource-aware progress workers. Do not cast away Kioku effects to fill an incompatible upstream hook. `docs/plans/95-close-the-runtime-pattern-audit-and-qualify-the-keiro-0-22-rollout.md` requires this entire child Complete and performs final cross-build and package qualification.
