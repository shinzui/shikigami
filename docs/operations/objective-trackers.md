# Operate external objective synchronization

Tracking is disabled by default. Native objectives remain independently usable.
Configure `SHIKIGAMI_OBJECTIVE_TRACKERS` using the explicit connection example in
[the Rei guide](objective-tracker-rei.md). Enable objectives and configure a local
worker/operator identity separately. Grant the worker current objective
coordination permission or deliberately choose `AdministerAll`; connection grants
alone create no objective membership. HTTP callers retain `VerifiedCaller`
identities and need objective permission plus connection-use permission for
provider operations. Reconciliation requires an additional explicit
`reconciliationOperators` grant. Recorded agents cannot become reconcilers.

## Serving and durable admission

The authenticated objective vertical mounts these routes:

| Route below `/objectives/:id/trackers` | Behavior |
|---|---|
| `GET /` | Scoped Relay page of bindings |
| `GET /:binding` | Independent local, external and delivery state |
| `GET /:binding/observations` | Retained source observations and diagnostics |
| `GET /:binding/proposals` | Before/base/source previews, decisions and digests |
| `GET /:binding/deliveries` | Immutable intents, attempts, uncertainty and evidence |
| `POST /commands` | Closed versioned local command or durable provider-read request |
| `GET /operations/:key` | Retained status after a lost response |

Commands are at most 1 MiB. Protected replies are at most 16 KiB. Relay accepts
20 by default and at most 100; the handler returns up to three previews per page
within that budget, with valid forward/backward cursors. Cursors include resource
and history scope and are not authorization. Membership is rechecked on every
page. Text previews explicitly truncate after 160 characters; full-document
digests and source coordinates remain available for review. Historical
observations predating local timestamp retention report an unknown time.

Local commands use the existing idempotent tracker owner and return 200.
Bind, Observe, Reconcile and Verify requests first commit a protected control
record under the tracker catalog fence. New work returns 202; identical replay
returns 200 and current retained status. A provider check at admission does not
perform a remote read. Invalid documents, denied access, stale revisions, oversized
bodies and unavailable provider composition return bounded 400/403/409/413/503
problems. Inaccessible resources are hidden on inspection with 404.

A worker claims read requests with a local lease. Repeated reads
and existing command keys are safe after a crash; no public control asks for a
fresh action POST. The worker restores only the principal recorded at admission,
then checks current membership, connection grants and binding revision. A trusted
configured scheduler may retain a refusal after revocation but cannot turn it
into caller authority. Queue and local commands share operation-key ownership;
a changed request cannot claim another operation's receipt. A control's failure
is retained; retry a transient failed read with a new reviewed key.

The queue shares the existing preserved tracker command target and its operation primary key.
Migration 0037 adds versioned control columns and local observation timestamps without inventing times
for old rows. The existing objective technical event fences queue maintenance;
no agent or conversation journal step changes. The same checked transaction owns
proposal decisions, objective mutation, command receipt and publication enqueue.

## Incarnations and uncertainty

Treat endpoint, remote account and provider contract as immutable for an
incarnation. Replacing the service means a new incarnation. Retain the old context
for read-only reconciliation. Both binding and immutable publication pin a target
digest; changing configuration cannot redirect an old send or queued binding.
Opaque named environment credentials are resolved at process boundaries and
never enter payloads, operation keys, fingerprints or histories.

Follow [the exact Rei recovery procedure](objective-tracker-rei.md). Unknown
non-idempotent appends quarantine rather than resend. A verified action ID proves
matching resource/payload; explicit operator attestation supplies the audited
causal decision. The evidence kind stays visible. Suppression preserves Unknown.
Pause/revocation stops fresh export without deleting local facts. Never rewrite
an existing incarnation, receipt or operation key to make a retry happen.

## Provider qualification checklist

A new provider must implement the existing interface and run the reusable
`ObjectiveTrackerStore` conformance cases, not its own delivery engine. Qualify:

- Scoped connection/resource identities, target fences and opaque credentials.
- Ordered observation/equivocation semantics or an explicit unordered declaration.
- Exact immutable payload/timestamp reconstruction and response validation.
- Advertised idempotency validity, conditional writes and applied/settled-absence
  evidence against the actual endpoint; lack of proof preserves Unknown.
- Lost response, stale claim, restart, pause/revocation and mismatched evidence.
- Protected bounded reads, scoped cursors and isolation from legacy callbacks.

Run `tests/objective-trackers/run-rei.sh` for the real adapter and
`tests/objective-trackers/run.sh` for supported API/CLI/worker integration, inside
`nix develop`. The latter honors `SHIKIGAMI_CABAL_PROJECT`. Both use the disposable
pinned Rei launcher and clear ambient endpoint/credential defaults. Run
`tests/objective-tracking/run.sh` with tracking disabled for the independent
no-Rei gate. No real repository containment qualification follows from these
fixtures. The accepted SDK source pin is explicit; see [the dependency
cohort](../dependency-cohort.md) for the release limitation and packaged closure.
