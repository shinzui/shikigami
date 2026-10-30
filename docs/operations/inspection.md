# Administrative inspection

Inspection is optional and belongs to the answering process. Set the secret Settei
`inspection` object (environment binding `SHIKIGAMI_INSPECTION`) for each role that
needs a listener. Omission disables it. The one-off agent has no inspection host.
The seven-package boundary is preserved through the optional
`shikigami-core:inspection` component; the ordinary core and agent do not acquire
HTTP hosting dependencies.

Use a different loopback port per colocated role, for example:

| Process | Suggested port | Native mounts |
| --- | ---: | --- |
| Server | 9092 | `/keiro`, `/kiroku`, `/pgmq` |
| Job worker | 9093 | the above and its own `/shibuya` |
| Trigger stream | 9094 | the above and its own `/shibuya` |
| Event stream | 9095 | the above and its own `/shibuya` |
| Scheduler | 9096 | `/keiro`, `/kiroku`, `/pgmq` |
| Workspace daemon | 9097 | `/keiro`, `/kiroku`, `/pgmq` |

The default address is `127.0.0.1:9092`; port zero selects a temporary port and the
structured `inspection.listening` event reports it. Allocate secrets through the
deployment's secret source. A minimal profile is:

```json
{"host":"127.0.0.1","port":9092,"readToken":"replace-with-a-random-secret-of-at-least-32-characters","allowedOrigins":["https://ops.example"]}
```

Tokens must be 32–4096 printable non-space ASCII characters. The secret object has
no `Show`/JSON encoder and Settei diagnostics redact it. Unknown settings, invalid
origins and nonpositive/inconsistent budgets fail configuration. A write token
must differ from the read token. Mutations additionally require
`"mutationsEnabled":true`. Shibuya pause/resume stays disabled even in that profile.

All actual requests and WebSocket upgrades require exactly one
`Authorization: Bearer …` header. OPTIONS only performs native preflight. CORS
does not grant caller authority. Configure the actual HTTPS page Origin even
behind a TLS proxy: native Keiro normalization and Kiroku/Shibuya serialized
Origin rules remain in force. Browser WebSocket APIs cannot set this header; a
browser deployment needs an authenticated operational proxy that supplies it for
upgrades. Do not place tokens in query strings, pages, logs or subprotocol names.

For a trusted operator shell with `INSPECTION_READ_TOKEN` populated from its secret
source, a read looks like:

```bash
curl --fail-with-body -H "Authorization: Bearer ${INSPECTION_READ_TOKEN}" \
  http://127.0.0.1:9092/keiro/aggregate/types
```

The metadata grant covers safe aggregate displays and bounded workflow headers,
timers, projection/shard status, backlog counts and companion metrics, health,
subscriptions and checkpoints. Aggregate display encoders omit protected digests,
tool arguments, histories and model payloads. Kiroku capabilities explicitly
disable browse, dead-letter bodies and event tails; the host refuses raw workflow
journals and PGMQ message browsing. A valid read token is not authority to disclose
those payloads. Trusted local `shikigami ops` remains the full native console with
its own database access, preview and application policy. Its explicit
`--database-url` participates in Settei precedence without an environment adapter.

Preview a native mutation with an empty POST body and the write credential. Save
the exact target, preview, operator/incident identity, database target and binary
revision. Confirm with `Content-Type: application/json` and the exact body
`{"confirm":"execute"}`. Invalid, duplicate or foreign Origin and non-JSON
confirmation are refused. The host audits invocation UUID, bounded path, method
and HTTP status; the native typed result determines the operation outcome. A
deadline can expire after commit: retain the target/operation identity and
reconcile before deciding whether to retry. An HTTP status alone is not proof of
rollback or mutation success.

`pgmq dlq read` is a mutation that leases visible entries for 30 seconds. Its
preview does not lease. Use native peek/lookup for authorized nonleasing
observation. Preserve live-only target policies: lifecycle events cannot recreate
protected payloads, and administrative confirmation cannot invent a replay
adapter. Catalog operations use the single validated application catalog. No
process-manager, foreground timer-fire or resource-aware workflow-resume hook is
mounted without a corresponding application authority. Permanent deletion still
requires the governed erasure decision; HTTP hard-delete is refused because this
host has no such application hook. A write credential is not that decision.

Keep inbox deduplication and projection redelivery evidence for the longest
reachable retry/replay window. Inbox GC does not promise permanent deduplication
after deletion; `mark-failed` is an operator decision, not a retry control. Outbox
requeue repairs stranded publishers only after their destination is repaired.
Sent-row GC must retain the required audit horizon and leaves rejected rows
alone; rejected, dead and sink receipt evidence has its own retention owner.
Never clear a backlog by indiscriminate timer dead-lettering, lease release or
evidence deletion. A live worker's lease/shards must not be stolen for inspection.

Default host limits are four active reads, 5-second reads, 30-second mutations,
5-second delivery, 2-second statements, 1 MiB encoded HTTP responses and 16 KiB
requests. Inspection uses a dedicated four-connection pool with 2-second connect,
10-second finite acquisition and 250-ms lock timeouts. The shorter application
deadline also covers acquisition, schema verification, reads and encoding.
Companion HTTP reads have a separate four-slot admission budget. Checkpoint
inventory is unpaginated; its polls are serialized and bounded by the same time
and byte limits. Database diagnostics in dependency health are sanitized.

The configurable socket defaults are 16 connections per surface, 16 retained
views/selections, 16 queued frames, 256 KiB Keiro/Kiroku/PGMQ frames, 512 KiB retained queue bytes and
one-second refresh. Keiro shares its HTTP/feed read budget and uses the smaller
read/delivery deadline for native feed sends. Kiroku metrics additionally enforce
the host's incoming message, encoded outgoing frame and send limits through the
public stream adapter. Shibuya retains its independent sampler/writer and native
byte/send policy. A popped frame and transient encoding can be additional to a
retained queue budget. The pool separates connection capacity; it does not isolate
database CPU, I/O, locks or a blackholed network. Keep process supervision enabled
and size cadence from the executed workload evidence.

Retain each protocol's recovery rules:

- `/keiro/ws` supplies shared workflow, timer and projection first pages. Empty
  handles own no polling driver or wake cursor. Overflow invalidates delta state;
  obtain a fresh subscription snapshot. A retiring view keeps its slot until its
  cleanup joins. Reconnect starts from a fresh first page, not a durable event cursor.
- `/kiroku/ws/metrics` sends process-local complete snapshots.
  `unsubscribe_metrics` stops sampling for that connection; `subscribe_metrics`
  requests a new snapshot. Durable checkpoint inventory is separate from the live
  subscriber registry. An empty registry does not describe another process.
- `/pgmq/ws` uses authoritative polling in this host (`push_available:false`).
  Recover overflow/reconnect through a fresh generation snapshot; partitioned
  queues supply no insert notifications. No LISTEN listener is configured.
- `/shibuya/ws` inspects the worker's actual Master. Apply snapshots as
  replacements, retain terminal stopped/failed outcomes separately and discard
  dependent deltas at `queue_overflow` until its replacement snapshot. Optional
  latency/in-flight/partition detail is unavailable under basic metrics. A paused
  processor remains distinct from stopped or failed; progress uses the role's
  workload timeout (job timeout plus 30 seconds, stream stale threshold 60 seconds).

Keep mount prefixes and opaque cursors unchanged, including filters and ordering.
Handle additive fields and unknown frame kinds. Parse signed-int64 IDs/positions
losslessly before a JavaScript `Number` can round them; converting a rounded value
to `BigInt` cannot recover it. Metrics resynchronization does not define durable
event-tail recovery. No event-tail client is selected here.

The host brackets accepted clients, feed drivers and companion runtimes before
their inspection pool and writer store. On return/cancellation, accepted sockets
close and join, native feed/PGMQ/shutdown work joins, then pools release. Goodbye
delivery is best effort. Unexpected listener failure propagates to the owning
role. The worker inspection lifetime ends before its one native consumer owner
stops and joins admitted deliveries.

Executed listener, real TCP backpressure, overflow, cancellation and ownership
cases are recorded in [the inspection evidence](../evidence/keiro-0.22/native-inspection-runtime.md).
