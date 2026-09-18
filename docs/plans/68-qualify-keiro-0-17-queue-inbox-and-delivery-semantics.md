---
id: 68
slug: qualify-keiro-0-17-queue-inbox-and-delivery-semantics
title: "Qualify Keiro 0.17 queue inbox and delivery semantics"
kind: exec-plan
created_at: 2026-09-18T16:22:03Z
master_plan: "docs/masterplans/12-adopt-keiro-0-17-and-applicable-runtime-haskell-and-postgresql-patterns.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-18T16:22:03Z
---

# Qualify Keiro 0.17 queue inbox and delivery semantics

This ExecPlan is a living document governed by agents/skills/exec-plan/PLANS.md. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Update durable decisions in docs/adr/ when implementation changes them.


## Purpose / Big Picture


Keep agent jobs, integration triggers and sink deliveries reliable on Keiro 0.17. Queue workers must enforce their declared ordering, preserve retry and dead-letter evidence, and acknowledge Kafka only after durable local work. Operators must be able to inspect and retain dead letters without accidentally purging hidden rows.


## Progress


No implementation has started. Populate a timestamped checklist at the first implementation step.


## Surprises & Discoveries


None during implementation yet.


## Decision Log


2026-09-18: Keep run_jobs Unordered because no strict per-group business ordering is currently declared. Keep the transactional inbox because one incoming integration event can fan out to several run jobs. New FIFO, delegated and reaction APIs are selected by business semantics, not release novelty.


## Outcomes & Retrospective


To be filled during implementation, with queue, inbox, DLQ and sink recovery evidence.


## Context and Orientation


Hard prerequisite: docs/plans/66-resolve-and-adopt-the-released-keiro-0-17-dependency-cohort.md provides Keiro 0.17, PGMQ 0.6 and shibuya-pgmq-adapter 0.16. A dead-letter queue (DLQ) stores poison or exhausted messages for inspection. A visibility timeout temporarily hides leased PGMQ rows; it does not delete them or guarantee exactly-once execution.

shikigami-core/src/Shikigami/RunJobs.hs constructs the application Job from generated QueueCodec and QueuePolicy. The current generated policy is Unordered with five deliveries and a 60-second retry delay. shikigami-workers/src/Shikigami/Workers/Registry.hs provisions the queue before intake and builds jobProcessorWithContext using generated tuning. shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs owns handling and lease renewal. shikigami-core/src/Shikigami/Trigger/Enqueue.hs owns transaction-composable sends. shikigami-workers/src/Shikigami/Trigger/Consumer.hs uses runInboxTransaction with PreferIntegrationMessageId; the inbox receipt and all fanout jobs commit together.

[ADR 0009](../adr/0009-kafka-offsets-advance-only-after-durable-dispositions.md) requires atomic enqueue before Kafka acknowledgement, strict serial handling, and durable poison dispositions. [ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md) forbids pretending the HTTP sink outbox is a generated Kafka producer. [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md) keeps runtime and operator owners shared. Consult docs/adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md before changing sink receipt behavior.

The 0.17 release requires jobOrdering in Job, rejects tuning that disagrees with it, and restricts legacy FIFO batch size to one. DlqEntry adds originalHeaders; purgeDlq returns PurgeDlqResult including PurgeDlqBlocked. Redrive restores original producer headers. Source research found no application call to mintIntegrationEvent, enqueueProducerEventTx or runProcessManager; therefore their release changes are applicability questions, not presumed migrations.

Normative sources are mori://shinzui/keiro-runtime-patterns/docs/messaging-pgmq-jobs, mori://shinzui/keiro-runtime-patterns/docs/messaging-pgmq-queue-reconciliation, mori://shinzui/keiro-runtime-patterns/docs/messaging-inbox, mori://shinzui/keiro-runtime-patterns/docs/messaging-outbox and mori://shinzui/keiro-runtime-patterns/docs/messaging-process-managers.


## Plan of Work


### Milestone 1 — Enforce declared queue policy end to end

Verify runJob.jobOrdering comes from Policy.jobOrdering, including one-shot and supervised paths. Validate explicit tuning before consumption and preserve generated retry disposition ownership. Extend shikigami-workers/test/Shikigami/Agent/RunJob/WorkerSpec.hs with tests that a mismatched ordering fails before a message is leased, retry attempt numbering stays correct, visibility renewal prevents concurrent work, and shutdown leaves undispatched messages recoverable.

Use the actual queue lifecycle APIs and record reconciliation actions, preserving durable queue names. Keep Unordered for the present domain; do not add grouped headers without a per-group invariant. If investigation establishes a strict ordering requirement, amend the plan and domain ADR, coordinate the declaration with docs/plans/67-adopt-language-6-and-executable-nominal-domain-contracts.md, and require verified PGMQ >=1.12 capabilities plus consumers-first rollout through docs/plans/69-adopt-guarded-timer-recovery-and-schema-isolated-migrations.md. Never substitute legacy FIFO with multi-item batches.

### Milestone 2 — Preserve dead-letter evidence and operate guarded purge

Exercise the real worker and one-shot DLQ paths separately: the supervised adapter dead-letters atomically; the one-shot library can leave a duplicate if it crashes between send and delete. Preserve downstream workflow idempotence and document this distinction. Extend the existing worker suite to read a DLQ entry, verify originalHeaders, archive exact inspected IDs with archiveDlqEntries, and check the returned IDs. Verify redrive preserves producer trace/group/application headers and leaves missing/null historical headers absent.

Through shikigami-server/src/Shikigami/Server/Command/Ops.hs retain the embedded upstream operator tree. Test that a forced ordinary purge while inspection hides rows returns refusal and leaves evidence present. Do not replace that behavior with purgeDlqForce. A full retention pass quiesces writers/operators, archives required entries, and checks active depth before purge. Use only disposable test queues for destructive acceptance tests.

### Milestone 3 — Requalify transactional delivery and applicable new APIs

Run and extend StreamInboxSpec to prove duplicate source/message identity produces one local fanout, a failed enqueue rolls back the inbox receipt, and a crash after database commit safely acknowledges on redelivery. Preserve strict serial Kafka acknowledgement and durable poison storage. Delegated intake is unsuitable for the current fanout because there is no one downstream receipt covering all effects; record this with concrete source evidence.

Inspect the actual sink outbox producer and publisher under shikigami-core/src/Shikigami/Flow/ and shikigami-workers/src/Shikigami/Flow/, plus Sink/Delivery.hs. Preserve stable sink intent identity, terminal rejection, retry and receipt semantics. Do not convert HTTP delivery to a generated Kafka publisher. If a real canonical producer call is found, migrate it to the recorded-event/emission-index API, test identical replay and typed content-drift conflict, and require a drained checkpoint or explicit historical identity mapping before replaying old random IDs. Never log conflict payloads. Replace any actual deprecated mintIntegrationEvent use with the explicit freshIntegrationEvent API.

Review messaging transport choice, process coordination, integration schemas, outbox/inbox and subscriptions. No process-manager call currently warrants conversion to reactions; workflows remain journaled sequences. Implement discovered applicable defects, and record non-applicability with runtime evidence. Update delivery/operator documentation and the pattern matrix.


## Concrete Steps


Run from /Users/shinzui/Keikaku/bokuno/shikigami inside the development shell as necessary:

```bash
rg -n 'mintIntegrationEvent|enqueueProducerEventTx|runProcessManager|purgeDlq|JobOrdering' shikigami-core shikigami-workers shikigami-server
cabal test shikigami-workers-test --test-show-details=direct
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-server-test --test-show-details=direct
cabal run shikigami -- ops --help
```

Confirm actual nested DLQ command flags with the pinned console's help before adding CLI fixtures. The worker and PostgreSQL suites create isolated databases through Shikigami.Migrations.TestSupport; missing PostgreSQL binaries are an environment failure, not a reason to skip evidence.


## Validation and Acceptance


A declared-policy mismatch consumes nothing. A retried job keeps the same workflow identity and does not repeat a completed journaled effect. DLQ redrive preserves original headers; exact-ID archival retains inspected hidden rows; guarded purge refuses hidden rows even when forced. A failed fanout leaves neither jobs nor a completed inbox receipt, and duplicate delivery does not add jobs. HTTP sink success/rejection and receipts remain truthful. Every messaging pattern row closes with test evidence or a specific semantic exclusion. No claim of distributed exactly-once delivery is introduced.


## Idempotence and Recovery


Queue provisioning is repeatable; queue renames are not part of this plan. Inspection changes visibility, so tests must account for its 30-second hiding period without depending on arbitrary sleeps. Redrive is at-least-once and may duplicate; keep workflow/receipt dedupe. Never purge user queues for validation. Restore source policy before deployment if an experiment fails; durable ordering or producer identity changes require a drain and cannot be casually rolled back.


## Interfaces and Dependencies


Hard dependency is docs/plans/66-resolve-and-adopt-the-released-keiro-0-17-dependency-cohort.md. Language-6 codec adoption and database capability qualification are integration dependencies with docs/plans/67-adopt-language-6-and-executable-nominal-domain-contracts.md and docs/plans/69-adopt-guarded-timer-recovery-and-schema-isolated-migrations.md; the current Unordered queue can be qualified independently. This plan owns Job construction and delivery policy, while the language plan owns generated codec/nominal adapters. Use mori://shinzui/keiro/packages/keiro-pgmq and mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter as library authorities. Preserve runJobCodec :: JobCodec RunJob, the physical queue and DLQ names, and the four application dispositions Enqueued, Duplicate, PermanentlyDeadLettered and TransientFailure.
