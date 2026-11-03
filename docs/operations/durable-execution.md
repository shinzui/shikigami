# Skill execution policies

New leaf Skill agent runs and conversations freeze their instructions, initial
input, exact model selection, tool menu and harness policy before starting the
durable execution child. Model and tool outcomes are protected accepted facts.
Changing a manifest or process default applies to new assignments. Unfinished
work still requires the exact pinned binding and fresh authorization.

Set operator policy through `behavior.harness` in YAML, `--set`, or the JSON
environment variable `SHIKIGAMI_BEHAVIOR_HARNESS`. For example:

```yaml
behavior:
  harness:
    maxModelTurns: 12
    outputRepairs: 2
    recoveryAttempts: 2
    contextBytes: 262144
    keepRecentMessages: 4
    deniedTools: [delete]
    humanTools: [publish]
    permissionSeconds: 600
    output: {tag: NonemptyReply}
    summaryTokens: 512
```

The defaults are eight model turns, zero repairs, 262144 context bytes, four
recent messages, no added tool restrictions, a 900-second permission window,
any reply, two safe recovery attempts per logical operation and no model-assisted summary. Summaries and output repairs consume
ordinary model turns and actual resource allowances. A summary cannot request
tools. Required context overflow refuses explicitly. Compaction preserves the
current request, complete tool groups and supported signed continuations; it
does not reset accounting or grant authority.

An agent can narrow operator policy with the canonical Dhall schema:

```dhall
let S = ../../schema/Agent.dhall

in S.Agent::{
     name = "bounded-worker",
     trigger = S.Trigger.Event { eventType = "work.requested" },
     behavior = S.Behavior.Skill { path = "agents/skills/triage-note" },
     harness = Some (S.Harness::{
       maxModelTurns = Some 6,
       output = Some S.OutputRequirement.NonemptyReply,
       deniedTools = [ "delete" ]
     })
   }
```

Agent overrides lower turn, repair, recovery, context, permission and summary ceilings;
retain at least the operator's recent-message minimum; and add denials or human
requirements. They cannot enable summaries when the operator disabled them.
Output requirements compose, including the union of required JSON fields.
The JSON output form for required fields is
`{"tag":"JsonFields","contents":["result","evidence"]}`. Tool names are exact
offered names. Naming a tool in policy grants no capability or external action.
Permission binds one accepted operation, immutable scope and absolute expiry.
Approval is followed by fresh external authorization before dispatch.

Supported operator ranges are 1–10000 model turns, 0–10 repairs, 1024–1048576
context bytes, 1–1000 recent messages, 0–100 recovery attempts, 1–86400 permission seconds and 1–32768
summary output tokens. `summaryTokens: 0` disables summaries. Unknown options and
invalid values fail configuration resolution. Root resource and admitted profile
limits still apply. `worker.run_timeout_seconds` bounds individual external
attempts; the durable executor additionally caps one attempt at 3500 seconds.

`shikigami-agent-run` opens the store, accepts durable work and locally drives
only its accepted execution child through the same fenced executor as workers.
It does not drain other queue entries. A human decision or existing live claim
leaves the run accepted for a later durable wake. Its local workspace provider
must remain available to unfinished tools; this adds no cross-process workspace
recovery provider.

`shikigami-run-behavior` opens no database. It applies the same pure policy rules
and retains a protected in-memory recording during the invocation. Its
`execution.mode` log explicitly reports `ephemeral` and `resumable: false`.
Human permission requests refuse with guidance to use the durable command.
Native tools use a private empty nested-model registry, and uncertain outcomes
are never automatically retried. Other behavior arms keep their existing runner.

Existing coarse workflow populations retain their recorded branch. Activation
and rolling forward follow [workflow versioning](../workflow-versioning.md).
Conversations retain their existing atomic reply owner and base tools;
capability overlays remain unavailable for that lifecycle.

A lost dispatched transport remains unknown. Trusted repeatable observations and
idempotent effects may spend a fresh attempt under the same accepted input and
logical key; uncertain effects await reconciliation. The old reservation stays
held, so finite active capacity can refuse a safe retry. Recovery refusal leaves
the original unresolved operation intact. Historical policies with no
`recoveryAttempts` field retain a zero allowance.

A replacement can finish while an older actual attempt still awaits a receipt.
`pendingReceipts` exposes that count. A late former-owner receipt settles its own
actual accounting without replacing the chosen output or advancing the cursor.
Partial invoice uncertainty remains visible in the resource ledger. Duplicate
queue delivery or receipt publication never authorizes another physical effect.

Inspect accepted work without acquiring replay-body access:

```bash
shikigami executions inspect EXECUTION --json
shikigami executions inspect EXECUTION --json --after 19 --limit 10
```

The versioned JSON includes the observed phase/revision, logical cursor, model
turns/repairs, pending receipts, public selection binding, protected payload
references and resource holds. It pages operations in ascending position, with
at most 20 per page and 10 attempt summaries per operation. `nextAfter` continues
history pagination; active work appears separately even when it is outside the
page. Attempt counts and `attemptsTruncated` make truncation explicit, with live
and unresolved attempts prioritized. Snapshot/input/output bodies, arguments,
credentials and wake tokens are excluded. Inspection is observational; a displayed
revision does not authorize dispatch or mutation.

Observation timers use the serving process's existing bounded timer pass. Keiro
requeues an ordinary timer left `Firing` for five minutes, and the generation-bound
handler repairs the original wake idempotently. A stale generation is cancelled
without appending to a successor journal. No second timer loop is required.

## Shared execution capacity

`worker.capacity` configures independent positive `execution` and `advances`
bounds (each 1..128). Both default to one. The worker validates database pool
headroom before intake and uses `advances` through the central workflow options
owner. All runtime replicas share the persisted execution limit; each executor
claim checks it together with its root reservation and attempt fence.

For example, an initially qualified two-call worker can use:

```bash
export SHIKIGAMI_WORKER_CAPACITY='{"execution":2,"advances":2}'
```

Initial configuration may bootstrap the shared limit once. Later changes supply
the observed revision as `expectedRevision`; mismatched replica configuration
refuses startup. An operator can read the small control record using the same
administrative database connection used for migration:

```sql
SELECT maximum, revision FROM shikigami.execution_capacity;
```

If the returned revision is 1, a configuration lowering execution to one is:

```bash
export SHIKIGAMI_WORKER_CAPACITY='{"execution":1,"advances":2,"expectedRevision":1}'
```

Existing permits drain without cancellation or duplicate work. A trusted executor releases its runtime permit after its local dispatch has
returned or unwound. Dispatched attempts without that stop acknowledgement
retain occupancy until factual reconciliation; lease expiry alone cannot free
them. Unknown root usage remains authoritative even after local execution stops
or runtime capacity is increased. Capacity
pressure acknowledges only the current queue delivery; the accepted driver's
bounded timer repairs delivery of the same reference, without spending a provider
retry or allocating a replacement operation.

The `ExecutionCapacity` worker tests qualify shared last-slot admission, bounded
rounds between ready roots, lowering and stale-replica refusal. The PostgreSQL
`ExecutionTranscript` barrier test holds two fixture provider calls open through the production executor,
records overlapping execution intervals, advances an unrelated workflow and
checks that both permits settle. Typed coordinator decision execution is a
separate acceptance gate in plan 85.
