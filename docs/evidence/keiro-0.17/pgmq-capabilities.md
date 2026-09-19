# PGMQ capability inventory for the Keiro 0.17 cohort

Shikigami retains its immutable vendored PGMQ SQL snapshot. The selected client
is `mori://shinzui/pgmq-hs/packages/pgmq-hasql` 0.6.1.0, the worker adapter is
`mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter` 0.16.0.0,
and the job/operator surface is `mori://shinzui/keiro/packages/keiro-pgmq`
0.17.0.0. This inventory follows the calls Shikigami actually selects rather
than treating every API exported by those packages as an application promise.

| Selected behavior | Installed server capability | Application evidence |
|---|---|---|
| Reconcile standard main queue and DLQ | `pgmq.create` | worker startup and `RunJob.WorkerSpec` call `ensureJobQueue` repeatedly |
| Enqueue with optional headers/delay | `pgmq.send` overloads | real producer/consumer and permanent-DLQ tests |
| Lease ordinary unordered work | `pgmq.read` with JSON condition | run-job worker tests consume the production queue contract |
| Renew, retry, or park a lease | scalar and batch `pgmq.set_vt` | slow-worker heartbeat and retry tests |
| Complete or dead-letter atomically | scalar/batch `pgmq.delete`, DLQ `pgmq.send` | worker disposition and transactional adapter paths |
| Inspect and redrive DLQ entries | `pgmq.read`, `pgmq.send`, `pgmq.delete` | released Keiro 0.17 contract; Shikigami exercises operator-visible decoding |
| Retain exact inspected DLQ ids | scalar/batch `pgmq.archive` | Shikigami archives an inspected id and verifies the active row is gone |
| Guarded purge | `pgmq.metrics` plus `pgmq.purge_queue` | Shikigami proves a post-archive safe purge; the mounted operator never selects `purgeDlqForce` |
| Queue telemetry | `pgmq.metrics` and `pgmq.metrics_all` | runtime sampler and worker tests read main/DLQ depth |

The installed `metrics_result` has nullable newest/oldest ages and no
`default_partition_length`. The 0.6.1 decoder keeps the ages as `Maybe` and uses
JSON record lookup for the later field, yielding `Nothing` on this server rather
than decoding absence as zero.

The vendored snapshot contains grouped and round-robin FIFO reads and FIFO index
creation, but lacks the newer head-per-group functions exposed by the general
0.6 client. Shikigami's generated queue policy is explicitly `Unordered`, so the
adapter selects only `pgmq.read`; no FIFO capability is claimed or required by
this rollout. Topic routing, notification throttles, partitioned queues, and
producer-event APIs are likewise outside the selected runtime path.
