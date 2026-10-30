# Native inspection runtime — plan 106 M2/M3

The candidate after `7534071` adds optional authenticated administrative hosting
to the real serving roles. The shared transport is the public
`shikigami-core:inspection` component. The core main library contains only pure
settings/display descriptions; architecture tests preserve its dependency budget
and the lightweight one-off agent. Server and workers opt into hosting explicitly.
No new package, background consumer or second event store is introduced.

The selected companion descriptors, authoritative Hackage hashes and verified
release tags are in [inspection-dependencies.json](inspection-dependencies.json).
Metrics 0.4.0.0 and OTel 0.3.0.0 retain Store 0.12 compatibility; their newer patch
releases require Store 0.13. The transitive CLI TLS bound exception is limited to
`kiroku-cli:http-client-tls`; its actual public TLS API use was inspected and the
compiled cohort and listeners pass. [FRIC-34](../../friction-log/34-kiroku-metrics-0-4-pulls-a-cli-with-a-stale-tls-upper-bound.md)
records the accepted workaround.

## Actual assembly

`Shikigami.Inspection.Store.withObservedStore` installs collector, lifecycle
tracing, existing Keiro/log passthroughs and W3C enrichment before store acquisition.
Runtime roots share that actual store and collector. A real traced Execution
command preserves its prior metadata and records a valid trace context. In-memory
SDK exporters verify a native catchup span and one terminal Keiro counter for the
same callback observed by the collector. No framework-owned SQL is added.

`Shikigami.Inspection.Runtime` owns a dedicated bounded pool, already allocated
native PGMQ runtime, Keiro feed handle and tracked HTTP/raw-WebSocket server.
`composeSurfaces` preserves encoded prefixes and queries. The actual writer
store's notifier/publisher remain shared; only inspection database access uses the
dedicated pool. Explicit Kiroku providers distinguish process-local subscriptions
from durable checkpoints; checkpoint polls serialize. Native dependency health
sanitizes database detail. No protected history browser or event tail is mounted.

The worker inspection wrapper receives its actual native Master inside the single
ConsumerApp callback. Job workers use their workload timeout plus 30 seconds for
stuck detection; streams use their actual 60-second stale threshold. Scheduler and
workspace daemon host only surfaces they own. A server does not invent a worker
registry. The optional secret Settei profile supplies the address, explicit
origins, independent read/write authority and validated positive resource limits.
The [operator guide](../../operations/inspection.md) lists per-role ports, exact
credential/confirmation semantics, budgets and protocol recovery.

Kiroku metrics 0.4 lacks a per-send/encoded-frame host setting. The host supplies
those limits through the released public `Network.WebSockets.Stream.makeStream`
and `PendingConnection` adapter used by the public WAI adapter. This does not
rewrite accepted connections, native frames, Origin policy, collector or sampler
state. Mori had no registered `websockets`/`network`/`network-uri` source; their
selected Hackage source archives were inspected for the public adapter and parser
APIs. No dependency version was guessed or changed to obtain those APIs.

## Executed behavior

Tests use the source-owned fresh native PostgreSQL fixture, actual loopback
listeners and real HTTP/WebSocket clients. Required database tests do not skip.

```bash
nix develop --no-write-lock-file -c cabal build all --enable-tests -j2
nix develop --no-write-lock-file -c cabal test shikigami-server-test \
  --test-options='--pattern inspection --num-threads=1' -j2
nix develop --no-write-lock-file -c cabal test shikigami-workers-test \
  --test-options='--pattern inspection --num-threads=1' -j2
nix develop --no-write-lock-file -c cabal test shikigami-core-test \
  shikigami-server-test shikigami-workers-test --test-options='--num-threads=1' -j2
```

The focused server suite has 25 inspection cases, including the earlier three
native CLI cases. Actual HTTP tests cover authenticated metadata parity with CLI,
duplicate/absent credentials, protected payload refusal, explicit mutation
enablement, distinct write authority, actual foreign/duplicate Origin refusal,
preview/exact JSON confirmation, structured audit without tokens and refusal of
permanent deletion without governed erasure authority. Confirmed repair cannot
invent a live-only replay adapter. A real DLQ entry retains its read count and
visibility through preview, then leases once after confirmation. Arbitrary live
schema drift causes the next request to fail closed.

Controlled companion reads exhaust admission without growing a wait queue; their
deadline joins the reader and returns capacity. Oversized encoding fails before
headers. Actual Keiro sockets share one canonical view, preserve old selection on
refusal, match HTTP first pages for workflows/timers/projections, release ping
in-flight state, own no idle driver/wake cursor and fail a later schema refresh
without fabricating an empty snapshot. A held native feed read shares HTTP
admission while an independent serving journal append progresses.

Kiroku metrics unsubscribe/resubscribe and PGMQ poll-authoritative reconnect use
their actual native protocols. An actual nonreading TCP metrics client uses a
small receive buffer and enough admitted native snapshots to fill transport
capacity; its delivery deadline closes the connection and returns native
admission while HTTP stays usable. Separate tests cover oversized incoming and
encoded outgoing frames. `ResultTooLarge` on that deliberate fault is expected.

Deterministic overflow and retiring-view fault injection operate on the actual
host's public native FeedHandle: overflow precedes surviving deltas, a new
subscription gets the latest full snapshot, and a retiring view keeps its slot
until cancellation cleanup joins. These controlled queue faults are distinguished
from the separate real TCP backpressure test.

Active Keiro/Kiroku/PGMQ clients close on host return before dependent resources
release. Worker tests retain an active Shibuya socket across both normal return
and parent cancellation, then observe closure and exactly one handler ACK and
adapter cleanup. The normal case completes its admitted delivery while a
concurrent loop of real database workflow inspection requests remains active.
Optional detailed metrics remain absent under basic metrics. This is concrete
bounded fixture progress evidence, not a statistical throughput or isolation SLA.

## Limits and handoff

Native queue/feed protocols and opaque numeric/cursor values remain unchanged.
No browser event-tail client, process-manager inspector, generation fleet,
external-read contract, resource-aware foreground resume or timer-fire hook is
fabricated. Protected payloads remain live-only and unavailable through the
metadata credential. Mutation timeouts can have committed outcomes and require
reconciliation; the audit records invocation/status rather than false success.

Dedicated capacity does not isolate database CPU, I/O, locks or blackholed network
recovery. Plan 95 still owns the exact frozen solve, Linux role artifacts,
integrated recovery/load profile and first-deployment qualification. This evidence
does not claim a live external provider, deployed proxy or production workload.
