# Native runtime lifecycle and recovery

Plan94 candidate after `e203470`, qualified on2026-10-30. Core and worker fixtures
use isolated task-owned migrated databases; no database cases are skipped.

## Store and command ownership

`Shikigami.App` owns the service interpreter over the released Kioku row plus a
Reader of `RunCommandOptions`. Long-running worker, scheduler, Kafka and workspace
supervisor roots, plus the lightweight agent root, bind the KirokuStore they
already acquired. Independent actions use public `runKirokuStoreWith`; standalone
CLI actions may acquire their own store. No cast or private interpreter is used.
Agent, conversation and approval runners now use that one interpreter instead of
repeating pool/notifier acquisition in local wrappers. Scheduler initialization
uses it too. The migrations package remains independent of core and uses Kioku's
upstream registration environment.

Every application aggregate catalog command obtains its options through this
interpreter: execution, worker session, objective and evidence. Process tracing
and metric handles therefore reach command runners; defaults retain bounded seed
verification and disabled inspection provenance. AppSpec queries twice through a
bound store while supplying unusable connection settings, and supplies real
process metrics to verify both option handles and the seed-verification bound.

All runtime roots perform the full migration handshake before intake. Connection
settings retain the authoritative Kiroku schema, default ten-connection pool and
thirty-second idle timeout; application SQL is qualified. The production statement
timeout is now thirty seconds. Telemetry and the Kiroku-to-Keiro bridge precede
store acquisition. Startup explicitly forces all four generated validated streams
before registering the one shared catalog. Live-only rich payload ownership and
transactional authority remain unchanged.

## Consumer ownership

`Workers.ConsumerApp.withConsumerAppAcquisition` brackets public Shibuya allocators,
including Keiro's `runJobWorkers`. Acquisition and cleanup transfer are masked;
cancellation is restored only after finally owns the handle. Cleanup propagates
its failures and runs exactly once. Retained public lifecycle health is checked
before cleanup unregisters live metrics. Permanent processor failure reaches
process supervision, either through Shibuya's linked ProcessorFailure or the
explicit retained-health failure. Kafka clears its process-local supervisor
provider after every application exit.

Both actual consumers use StopAllOnFailure. Kafka retains StrictInOrder/Serial and
one inbox slot. Invalid Shibuya configuration fails before acquisition. Kafka bad
configuration/specification, authentication and fatal errors leave the reconnect
loop; broker outage retains capped exponential backoff. The static application
DLQ code is forced once before connection. Raw Kafka poison is committed to the
application DLQ before terminal offset intent; unavailable persistence halts the
ordered stream. The adapter is not claimed to supply its own Kafka DLQ producer.

PGMQ uses the supported typed supervised worker and framework-owned finalizers.
Its serial intake is reduced from100 to one inbox slot with batch size1. Initial
visibility covers two configured attempt windows plus60seconds:660seconds at the
default five-minute attempt. This covers the inbox and one source-held delivery;
active work continues renewing to thirty seconds every ten seconds. Invalid or
Int32-overflowing horizons refuse before acquisition. Undispatched work after a
crash may wait that initial horizon before redelivery. PollEvery1 remains
client-side standard polling; no server-side long poll occupies pool connections.
The released adapter retry defaults remain five attempts (1.5seconds cumulative
backoff), with exhausted failures reaching process supervision/restart. No longer
same-pool failover horizon is claimed, and no processor fork reaches hidden retry
fields.

Queue liveness uses the configured attempt timeout plus30seconds; it no longer
kills a legitimate five-minute attempt at one minute. Paused idle processors stay
healthy; paused processors with admitted work still expire against last progress.
Pause is not a drain or revoked lease. Detailed metrics/control stay disabled
until the inspection owner deliberately enables and authorizes them.

Native ConsumerApp cases exercise ordinary/superseded admission, one handler and
four same-decision finalizer attempts before permanent failure, callback failure,
async cancellation, cleanup failure, invalid startup, and cancellation that joins
admitted work before ownership returns. Budget tests reject invalid horizons;
health tests cover a five-minute attempt across the former minute threshold and
expiration at the configured bound.

## Workflow and wake census

The shared production registry is asserted to contain exactly:

| Family | Native current-build evidence |
|---|---|
| shikigami.agent-run | AgentWorkflowSpec: resumes after crash without rerunning journaled bodies; crash between record/complete does not duplicate memory |
| shikigami.approval | AgentWorkflowSpec: generated job/restart/approval/evidence/delivery converge; approved/rejected/timeout outcomes resume through the common registry |
| shikigami.danwa-conversation | AgentWorkflowSpec: parked conversation resumes; delivery resolves the live generation; rotation and superseded sleep tests |
| shikigami.execution | ExecutionTranscriptSpec: lost queue registration is repaired; model/tool contexts reconstruct; stale claim/rotation/cancellation/late receipt tests |
| shikigami.worker-session | WorkerSessionSpec: two assignments survive idle rotation with retained findings/distinct children; WorkerSessionStoreSpec: lost checkpoint acknowledgement deduplicates |

WorkerSessionCapabilitySpec additionally exercises exact event-await delivery,
listener-journal conflict rollback, rotated/collected listener refusal and parent
scope retention. ExecutionTranscriptSpec proves current wake republishing after
rotation and refusal of an old timer. Unknown effects remain unresolved with
reservations held; expiry is not proof an external process stopped. Supported
journal/instance operations arbitrate terminal races; no private framework-table
mutation or deterministic reconstruction of allocated awakeable IDs is introduced.

One timer dispatcher owns sleeps and application timers, draining at most100rows
per pass. TimerRecoverySpec proves ordinary and expired guarded claim recovery
and stale token fencing. Foreground Dead-timer execution stays disabled without
an application authorization/dispatch boundary. GC remains hourly,100instances
per pass after90days, independently of protected evidence and sink receipt
retention. Bounded resume continues on `advanced`, exports every released summary
field and stays at concurrency1. Its resource-aware row still cannot fit the
embedded operations ResumeHook; the worker-owned command remains necessary.

## Explicitly absent consumers and remaining owners

There is no application-owned Kiroku subscription, shard group, namespace fan-in,
process manager, reaction runner, IntegrationProducer, partitioned queue or
stream-scoped replay policy. No unused instance or descriptor is introduced.
All current catalog payload owners are LiveOnly/PreserveAndReconcile; lifecycle
history cannot reconstruct the protected data. Read-side models are immediate
and cursorless because they observe accepted atomic state. No waiting cursor or
async rebuild guarantee is fabricated. Snapshot caches remain disabled for all
four aggregates, and no application history truncation or generic erasure path
is enabled.

Plan106 owns selected inspection hosting, managed DLQ administration, aggregate
operations catalogs and provider/collector wiring. Its applicable clauses remain
pending in the source inventory, including Kiroku metrics/OTel callback composition
before acquisition, dedicated inspection resources and HTTP/feed lifetime. The
current command telemetry/store bracket does not certify those pending features.
Plan95 owns final frozen artifact/Linux qualification and any final load evidence;
these native tests do not establish deployment containment, performance acceptance,
statistical zero-slowdown or compatibility with an old deployed population.

The DSL diff against `e203470` is empty and replay-neutral. The source gate now
also denies AggGuardRelationUnknown and AggGuardRemedyUnavailable. Runtime effect
interpretation changes introduce no recorded workflow operation or wire change.
