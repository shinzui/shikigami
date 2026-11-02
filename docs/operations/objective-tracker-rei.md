# Rei objective trackers

The opt-in adapter binds an existing Rei intention. Local objective status,
external observed lifecycle and synchronization receipt state are independent.
Rei guidance is untrusted input offered as a proposal; applying it requires an
explicit local decision at the current objective revision. Rei completion cannot
supply Shikigami acceptance evidence. No intention is created, completed or
reopened by the adapter.

## Qualified protocol

Qualification uses Rei server **8.0.0.0**, contract/client **0.2.0.0**, public
source commit `c109222db550537ec998ecc6fc1866cc7a35e29a` in
`mori://shinzui/rei`. The two SDK packages have no Hackage release at selection;
`cabal.project` pins their public immutable source under the repository's
[dependency policy](../dependency-cohort.md). Rei core/server are fixture-only,
absent from Shikigami's production dependency closure.

The adapter revision is `rei-v2-objectives/1`, mapping revision
`shikigami.tracker-mapping/1`. It uses the contract-derived v2 client and both its
domain-result and transport-failure channels. Rei's GET routes are public;
authenticated Shikigami membership and connection-use grants still protect local
observations and proposal operations. Rei POSTs require the configured bearer.
The original legacy ReiAction sink continues to address `/v1/agent-actions` and
requires a compatible ingestion service. Changing its durable protocol is separate.

| Rei value | Local meaning |
|---|---|
| Intention ID | Explicit bound resource, scoped to connection incarnation |
| Title | Bounded external display metadata |
| `noteGuidance` | Optional instructions proposal; missing means an explicit clear proposal |
| Active / future | Distinct observed open / planned lifecycle; cannot reopen local terminal work |
| Completed / abandoned | Reviewed lifecycle proposal; local evidence and permissions still apply |
| `streamPosition` | Ordered projected observation token, never a linearizable freshness guarantee |
| Action acknowledgement | Exact provider-proved publication receipt |

Actions contain only objective ID/revision, publication ID/digest and allowlisted
progress counts/status. They omit objective title, goal, instructions, evidence,
paths, reasoning, arbitrary output and credentials. The original timestamp is
retained and actor override is unset. A position advance caused only by an action
does not invent an instructions change.

## Configuration

`SHIKIGAMI_OBJECTIVE_TRACKERS` supplies the `objective_trackers` JSON setting.
Disabled is the default and constructs no provider, reads no credential and
starts no tracker loop. An example enabled setting follows; replace all resource
coordinates deliberately and grant only the intended principals.

```json
{
  "enabled": "TrackersEnabled",
  "connections": [{
    "connectionId": "personal-rei",
    "incarnation": "installation-2026-11",
    "provider": "rei-v2-objectives/1",
    "endpoint": "https://rei.example.test",
    "account": "personal-account",
    "credential": "env:SHIKIGAMI_REI_TRACKER_TOKEN",
    "useGrants": [{"tag":"LocalOperator","contents":"tracker-worker"}],
    "exportGrants": [{"tag":"LocalOperator","contents":"tracker-worker"}]
  }],
  "pollSeconds": 60,
  "batchSize": 20,
  "reconciliationOperators": [{"tag":"LocalOperator","contents":"tracker-worker"}]
}
```

Credentials resolve from the named environment variable once at process startup,
are captured opaquely, and never enter tracker records, command fingerprints,
queue payloads or logs. HTTP managers are bounded and scoped to one immutable
connection/credential context; redirects are disabled. Each SDK call has a
20-second absolute duration bound. Endpoint URLs forbid userinfo, query and
fragment; HTTP is allowed only for explicit loopback fixtures.

The worker also needs an explicitly configured objective local operator. That
identity must have current objective coordination permission (or deliberate
`AdministerAll` policy), connection use and export grants. Configuration grants
never create objective membership. HTTP callers keep their authenticated caller
identity; an external Rei actor label cannot grant local authority.

Polling scans at most `batchSize` routing coordinates with a cursor and rechecks
resource permission before protected reads. One supervised loop owns scheduling;
the shared executor owns all imports, claims and receipts. The existing outbox
publisher remains the single transport owner. Both callbacks route by destination.
A tracker transport acknowledgement never invokes legacy sink reconciliation.

## Recovery

Rei action append is unconditional and has **no server idempotency key**. A 5xx,
timeout, malformed success or lost response can follow commit. These become
`Unknown`, stop automatic POST retries and block later publications on that
binding. Local objective work remains available. An expired claim is not proof of
non-application. Valid declared 400/404/422 and bearer 401/403 are rejections;
409 is conflict; 429 is conservatively unknown. A malformed problem response
remains unknown rather than borrowing the status code's intended semantics.

For an Unknown publication, inspect the immutable attempt, incarnation and digest.
An exact action ID can be read and verified against the bound intention, payload,
timestamp and unset optional fields. Candidate discovery preserves scoped cursors
and reads at most four pages of 100. No candidate or matching marker proves
absence or authorship: another remote writer can copy a marker. The operator must
explicitly attest verified delivery with the original publication/attempt,
incarnation, remote action ID, digest, expected receipt revision and bounded
reason. The retained evidence distinguishes `OperatorAttested` from
`ProviderProved`. No free-text claim or marker can authorize resend.

Pause, detach, revocation and suppression preserve receipts. Suppression does not
rewrite an existing Unknown. Replace an endpoint or account with a **new
incarnation**, retaining the old context for read-only reconciliation. Never
retarget an accepted publication by editing a connection in place; the retained
target digest refuses that operation.

## Reproduce qualification

```bash
nix develop --no-write-lock-file -c bash tests/objective-trackers/run-rei.sh
```

The launcher discovers the pinned clean public Rei checkout through Mori, builds
its real API and projection workers, creates a fresh schema and bearer identity,
and API-creates disposable command targets. Its graph fixture is read-only and
used only for pagination. It clears ambient endpoints and credentials, binds only
loopback, uses no production Rei defaults, and cleans up on exit. Ordinary Cabal
tests do not require this live fixture.

Seventeen live cases pass, including real append/readback, bearer refusal, declared
HTTP failures, malformed committed acknowledgement, fresh dispatcher processes,
zero second POSTs, delayed projected reads after acknowledgement, exact verification/attestation, forgery refusal, guidance
proposals, scoped multi-page reads, revoked export, paused binding, cached-target
refusal and production body bounds. The shared engine's PostgreSQL conformance
also exercises stale leases, concurrent polls, stronger-provider replay and
checkpoint invalidation. A separate mixed-outbox test preserves a delivered
legacy receipt, delivered tracker receipt and quarantined tracker receipt while
calling the legacy post-success callback only for the legacy row.

## Supported control qualification

The authenticated [tracker controls](objective-trackers.md) and configured-operator
CLI are qualified with real Shikigami server and worker executables against the
same disposable Rei tuple. The full runner is:

```bash
nix develop --no-write-lock-file -c bash tests/objective-trackers/run.sh
```

The served journey binds without overwrite, imports reviewed guidance, refuses
concurrent local divergence, retains rejection, and keeps external completion and
abandonment separate from local acceptance. It restarts both Shikigami serving
processes after a committed malformed action reply and performs no second POST.
An authenticated explicitly granted caller verifies the exact action, attests
its immutable attempt, and replays the original command receipt. Further cases
qualify operator CLI pause, caller revocation before queued reads, export
revocation before pending dispatch, missing remote access with retained evidence,
and the same textual remote ID in another connection/incarnation. The runner
also executes the shared native checkpoint conflict case; actual repository
containment remains a separate gate.

Rei wire status strings are lowercase. The typed adapter handles them through
its contract codec. The real server permits reopening a completed intention but
refuses reopening an abandoned one; no adapter or fixture assumes a broader
lifecycle API.
