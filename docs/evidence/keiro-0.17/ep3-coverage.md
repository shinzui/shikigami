# EP-3 messaging evidence

`Shikigami.RunJobs.runJob` now supplies the generated `Policy.jobOrdering` required
by Keiro 0.17. The domain remains `Unordered`; no business invariant justifies a
grouped FIFO identity. The physical `shikigami_run_jobs` queue, generated codec,
five-delivery retry policy, 60-second retry delay, and workflow idempotency key are
unchanged.

`shikigami-workers-test` executes the actual producer/consumer contract, validates
lease renewal for slow work, and proves permanent and route failures reach the
reconciled DLQ. `StreamInboxSpec` proves one atomic receipt-plus-fanout transaction,
rollback on handler failure, duplicate suppression, durable poison disposition,
and refusal to acknowledge when poison persistence fails. This fanout cannot use
Language 6 delegated intake because no single downstream receipt covers every job.

The server retains Keiro 0.17's embedded PGMQ operator tree. The released
`keiro-pgmq` contract preserves original headers across DLQ inspection/redrive,
archives exact inspected IDs, and refuses guarded purge when hidden rows exist.
Shikigami exercises inspection, exact-id archival, and guarded purge against its
installed SQL; the full selected-server inventory is in `pgmq-capabilities.md`.
Shikigami does not call `purgeDlqForce`. HTTP sinks remain a hand-owned durable
intent/receipt flow because they are not a Kafka producer surface; their stable
remote key and receipt-gap tests continue to define at-least-once behavior.

No application call exists to `mintIntegrationEvent`, `enqueueProducerEventTx`, or
`runProcessManager`, so the corresponding 0.17 additions do not create a migration.
