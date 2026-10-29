# The operator command line

Everything an operator can inspect or change from a terminal lives behind one
binary, `shikigami`. This document maps questions to verbs, and records the
handful of behaviours that are surprising enough to cost you an incident if you
meet them for the first time at 3am.

Run everything from the repository root inside the Nix dev shell:

```bash
nix develop
cabal run shikigami -- <command>
```

An installed deployment runs `shikigami <command>` directly. Database-backed
verbs, including `agents sync`, need `database.connection_string` resolved —
from a config file, `--set database.connection_string=…`, or the
`PG_CONNECTION_STRING` environment binding. `agents list`, `validate`, and
`render-lifecycle` remain available without PostgreSQL. `shikigami
--explain-config` shows what it resolved and from where.


## Where the verbs come from

Two halves, and it matters which is which when something behaves unexpectedly.

**Shikigami's own**: `agents`, `runs`, `resources`, `executions`, `workers`, and `validate`,
`render-lifecycle`, `enqueue-run`, `resolve-approval`, `publish-fixture`, `stub-kawa`, `stub-kanmon`,
`danwa-spike`, and `grants`. These are defined in this repository.

**Keiro's**: `wf`, `timer`, `outbox`, `inbox`, `pgmq`, `projection`, `shard`,
`snapshot`, and `stream`. These come from the `keiro-ops` package, whose command
tree is mounted whole into this binary. They are documented by Keiro
(`mori://shinzui/keiro/packages/keiro-ops`), and when one of them behaves in a
way this repository did not define, that is where to look. Their global options —
`--json`, `--force`, `--database-url`, `--allow-schema-drift` — belong to that
tree and work across all of them.


## Which verb answers which question

**"Which declarations and principals are joined, and is either side missing?"**
— `agents list`.

```bash
cabal run shikigami -- agents list
```

The table is the union of one completed manifest load report and one principal
directory snapshot. `MANIFEST` distinguishes `loaded`, `failed`, and `NO
MANIFEST`; `PRINCIPAL` shows the joined stable id or `NO PRINCIPAL`; and
`LIFECYCLE` shows `active`, `paused`, or `deactivated`. `ENABLED` remains the
declaration-local switch. A failed manifest's full Dhall diagnostic prints
below the table. `--json` gives the same states machine-readably.

When `directory.mode=disabled`, loaded declarations show `NO PRINCIPAL` and
`DISABLED`. That is explicit compatibility behavior, not proof that Meibo says
the principal is active. In file mode, an unreadable or invalid initial
snapshot makes the command fail closed, just as it does for a worker process.

`agents list` opens no database. It answers when PostgreSQL is down, which is
often exactly when you are asking.

**"Persist what loaded and bind verified principals to existing grants."** —
`agents sync`.

```bash
cabal run shikigami -- agents sync
cabal run shikigami -- agents sync --json
```

Sync records the complete current manifest report in
`shikigami.agent_load_state`, including full diagnostics for failed manifests.
For each one-to-one declaration/principal join it fills null
`shikigami.sink_grants.principal_id` values or verifies the same id already
stored. It never creates or deletes grants and never replaces a different
principal id.

Each declaration without a principal, directory principal without a manifest,
failed manifest, disabled directory, or ambiguous join is printed as an
`ISSUE` and skipped. Those inventory gaps do not stop independent valid joins.
An existing conflicting grant principal prints `CONFLICT`, leaves every grant
row for that agent untouched, and makes the command exit non-zero. Repair the
identity deliberately and rerun; a clean rerun is idempotent and reports
`filled=0` with the verified count.

**"Keep a renamed agent's legacy memories available."** — `agents sync --alias`.

```bash
cabal run shikigami -- agents sync --alias old-agent-name=agent_01h000000000000000heartbeat
```

The option is repeatable. Each target is a principal id with an unambiguous current declaration/directory join.
Shikigami records the legacy name in `shikigami.agent_scope_aliases` and includes
that scope when recalling the principal's memories. It does not rewrite historical
Kioku rows. An alias already owned by another principal is a conflict.

**"How do I run the hermetic ChannelEgress downstream?"** — `stub-kanmon`.

```bash
SHIKIGAMI_KANMON_TOKEN=test-token \
  cabal run shikigami -- stub-kanmon --port 8090 --allow-conversation conv_55012
```

`--allow-conversation` is repeatable and defaults to `conv_55012` when omitted. The stub
accepts only `intercom/reply_to_conversation`, checks the token before parsing its body, and
deduplicates `(channel, idempotency_key)` in memory. Its state clears on restart, matching
Kanmon's current offline proof store. There is deliberately no token flag: the token comes
only from the secret `credentials.sinks.kanmon.token` setting, whose environment binding is
`SHIKIGAMI_KANMON_TOKEN`.

**"What is running right now?"** — `wf list`.

```bash
cabal run shikigami -- wf list --status running
```

`--status` may be repeated. `--name` filters to one workflow definition —
`shikigami.agent-run` for agent runs, or the conversation workflow name. Paging
is by keyset: pass the last row's name and id to `--after NAME ID`.

**"What happened to this run?"** — `runs show`.

```bash
cabal run shikigami -- runs show shikigami.agent-run <workflow-id>
```

This is the one verb that shows both halves of a run. Keiro holds the workflow
instance — status, generation, attempts, last error; kioku holds the session —
which agent ran, its focus, summary, error, and turn count. Neither library
knows about the other, so nothing but this command puts them side by side.

Both arguments are required, because a workflow instance is keyed by
`(workflow_name, workflow_id)`. The workflow id of an agent run is the run job's
idempotency key, which `enqueue-run` prints when it enqueues.

The session half reports one of four things, and they mean different things:

- the session's own fields — the normal case;
- **no session opened yet on this generation** — the run has not reached its
  session step. It may still succeed;
- **kioku refused to open a session** — the run is permanently over, and the
  refusal detail says why;
- **recorded by the run, but kioku has no session row for it** — the run
  journaled a session id that kioku cannot find. That is a real inconsistency,
  not a normal state.

For the workflow half alone, `wf show` reports more — children and awakeables —
and `wf journal` and `wf steps` decode what the run actually recorded.

**"What has this continuing worker accepted, and who owns it?"** — `workers inspect`.

```bash
cabal run shikigami -- workers inspect <session-id> --json --after -1 --limit 10
```

The bounded page contains session phase, owner epoch, assignment/result references,
event and consumed cursors, and pending checkpoint/handoff metadata. Page sizes
are 1–20. An active assignment stays visible outside the requested history page.
Instruction bodies, delegation snapshots and wake tokens are protected and are
not returned by inspection. Session facts outlive terminal workflow journals.

Control commands use the accepted parent identity, original root and fresh exact
action authorization. Stable operation keys identify the intended command:

```bash
cabal run shikigami -- workers send <session-id> --operation follow-up-2 \
  --expected-revision 7 --epoch 0 --instruction-file instruction.json
cabal run shikigami -- workers interrupt <session-id> --operation interrupt-2 \
  --expected-revision 7 --epoch 0 --assignment <assignment-id> \
  --instruction-file instruction.json
cabal run shikigami -- workers cancel <session-id> --operation close-2 \
  --expected-revision 7 --epoch 0
cabal run shikigami -- workers transfer <session-id> --operation handoff-2 \
  --expected-revision 7 --epoch 0 --workspace-provider <provider> \
  --workspace-resource <resource> --target <declared-agent>
cabal run shikigami -- workers reconcile <session-id> --operation reconcile-2
cabal run shikigami -- workers integrate <session-id> --operation checkpoint-2
```

An instruction file is a closed JSON object, at most 1 MiB:

```json
{
  "text": "Check the retained finding against the current criteria.",
  "objectiveRevision": 3,
  "assignmentRevision": 2,
  "criteriaRevision": 1,
  "selection": null
}
```

Send queues a separate assignment; interruption names one exact assignment and
waits for reconciliation. Cancel closes only an idle session with no queued or
unresolved work. Reuse the original operation key and input after a lost
acknowledgement. Conflicting reuse or stale revisions refuse; retry never creates
a replacement root. Reconcile continues the retained handoff operation.

The default CLI has no selected IR-13 objective/checkpoint provider or IR-11
workspace/ownership provider. New send/interrupt/integrate and transfer work
therefore refuses until those separately owned integrations are supplied and
qualified. Deterministic provider fixtures establish consumer mechanics only.
Inspection and authorized idle closure remain available. Flows, admitted
`CoordinatingSkill` tools and qualified operator hosts use the same command owner;
declaration text alone supplies no control authority.

**"How do I answer a human approval request?"** — `resolve-approval`.

```bash
cabal run shikigami -- resolve-approval <token> --approve
cabal run shikigami -- resolve-approval <token> --reject "reason"
```

Copy the opaque UUID token from the Danwa or Kizashi ask, not its stable `review_…` identifier.
Exactly one decision flag is accepted. The first signal exits zero and prints `resolved: true`;
unknown, timed-out, and already-resolved tokens exit 1 and print the same explicit false result.
This command does not run a resume pass. The supervised worker advances the approval child and
parent after the signal, so inspect the run or outbox separately when you need its final outcome.

**"This run is stuck."** — first find out how.

```bash
cabal run shikigami -- wf show shikigami.agent-run <workflow-id>
```

If it is genuinely stuck and should stop, `wf cancel`. If a worker died holding
its lease and the instance is not being picked up, `wf lease release`. If it
failed terminally and should be retried from its journal rather than abandoned,
`wf resurrect`. Cancel is not the answer to all three, and using it for the
second loses the run.

```bash
cabal run shikigami -- wf cancel shikigami.agent-run <workflow-id>          # preview
cabal run shikigami -- wf cancel shikigami.agent-run <workflow-id> --force  # do it
```

**"Jobs are disappearing."** — look in the dead-letter queue.

```bash
cabal run shikigami -- pgmq dlq read --queue shikigami_run_jobs
```

Each row carries the reason it was dead-lettered and the original payload. Once
you have fixed whatever rejected them:

```bash
cabal run shikigami -- pgmq dlq redrive --queue shikigami_run_jobs --force
```

Read [the DLQ gotchas](#the-two-dlq-gotchas) before you do — both of them bite
here.

**"Sinks are not being delivered."** — `outbox backlog`, then `outbox list`.

```bash
cabal run shikigami -- outbox backlog
cabal run shikigami -- outbox list --source shikigami --status pending
```

`outbox backlog` counts claimable rows; a number that only grows means the
publisher loop is not running or not succeeding. `outbox show <id>` inspects one
row. `outbox requeue-stuck` returns rows abandoned mid-publish by a dead worker,
and `outbox maintenance-pass` runs the routine sweep.

**"Timers are not firing."** — `timer stuck list`.

```bash
cabal run shikigami -- timer stuck list --min-age 5m
```

Timers left in `firing` by an interrupted worker show up here. `timer requeue`
returns one to the scheduled queue, `timer cancel` withdraws it, and
`timer dead-letter` abandons it with a recorded reason.


## Nothing changes without `--force`

Every mutating verb from the Keiro half previews by default: it prints what it
would do, prints the exact command to run for real, and exits non-zero.

```text
$ shikigami wf cancel shikigami.agent-run heartbeat:evt:0aa8…
preview only; re-run with --force: 'keiro-ops' 'wf' 'cancel' 'shikigami.agent-run' 'heartbeat:evt:0aa8…' '--force'
operation  name                 id                  disposition       status
---------  -------------------  ------------------  ----------------  ---------
cancel     shikigami.agent-run  heartbeat:evt:0aa8…  already_terminal  completed
```

Two things to know about that message. It says **`keiro-ops`** because the
mounted tree composes its own name; substitute `shikigami` and the rest of the
line is correct as printed. And the non-zero exit is the contract, not a
failure — scripts must not treat it as one.

`pgmq dlq purge --force` additionally prompts on standard input for the queue
name, unless `--json` is also passed, in which case it proceeds unprompted.
Be careful automating it.

Every invocation of a Keiro-half verb emits two JSON audit lines on stderr, one
before and one after, sharing an `invocation` id:

```json
{"command":"pgmq dlq redrive --queue shikigami_run_jobs --force","event":"operator.ops.invoked","invocation":"c76fdbdd-…","level":"info","ts":"…"}
{"command":"pgmq dlq redrive --queue shikigami_run_jobs --force","event":"operator.ops.finished","exit_code":0,"invocation":"c76fdbdd-…","level":"info","ts":"…"}
```

They name the command and the exit code, and deliberately claim nothing about
the outcome — see [exit codes](#an-exit-code-is-not-an-outcome). Any
`--database-url` value is redacted before the line is written.


## The two DLQ gotchas

**`--queue` names the live queue, not the dead-letter queue.** Pass
`shikigami_run_jobs`; Keiro derives `shikigami_run_jobs_dlq` from it. Passing the
DLQ's own name does not merely double the suffix — a queue name already ending in
`_dlq` gets hashed, so you address a queue that does not exist.

**`pgmq dlq read` hides for 30 seconds what it shows you.** The read takes a 30
second visibility lease so concurrent inspections do not collide. A `redrive` or
`archive` issued inside that window can only claim *visible* rows, so it reports
`affected 0` — while the preview, which counts queue length including invisible
rows, cheerfully said it would affect them all:

```text
$ shikigami pgmq dlq read --queue shikigami_run_jobs      # 1 row shown, now hidden for 30s
$ shikigami pgmq dlq redrive --queue shikigami_run_jobs   # preview: available 1, would_affect 1
$ shikigami pgmq dlq redrive --queue shikigami_run_jobs --force
redrive    shikigami_run_jobs  0                          # <-- nothing moved
```

Nothing is wrong and nothing is lost. Wait out the window and redrive again.
The failure mode to avoid is concluding that redrive is broken and reaching for
`purge`.

Redrive is at-least-once by design: a crash between re-enqueueing a payload and
deleting the DLQ row leaves it in both places, so handlers must be idempotent.


## Two refusals that look like bugs

### Schema drift

Every Keiro-half invocation checks the live schema against the one its binary was
built for. Drift is reported as a warning on reads, and **refuses** any mutation:

```text
refusing mutation because the live schema differs from this binary; inspect the
warnings or pass --allow-schema-drift
```

`--allow-schema-drift` is right there and is almost never the answer. Drift means
the database has not been migrated to what this build expects; the fix is
`just migrate`. Reach for the flag only when you have read the warnings and
decided the difference is irrelevant to the command you are running.

Relatedly, `keiro-migrations` requires **PostgreSQL 18**. On any other major
version every one of these verbs fails before it runs, read-only ones included,
with `schema verification failed: UnsupportedPostgresVersion N`. The dev shell
pins PostgreSQL 18 for this reason.

### An exit code is not an outcome

`wf cancel --force` against an instance that has already finished reports
`already_completed` and exits **zero**. It did not cancel anything — there was
nothing left to cancel, and saying so is the honest answer. The same holds for
the other mutating verbs: read the `outcome` or `disposition` column, not the
exit status. This is why the audit lines record the command and exit code but do
not claim a verb-specific outcome; nothing at that layer can observe one.


## What is mounted but has no target here

`outbox dead-letters list` requires `--dispatcher NAME`, naming a process-manager
or router dispatcher. Shikigami has no process-manager or router dispatcher registered, so there
is no dispatcher to name. Its RunEvidence, execution and worker-session aggregates
and query models do not create such a dispatcher. It is present because the Keiro tree
mounts whole, not because it answers a question here.

The mounted `projection`, `shard`, `snapshot`, `stream`, `inbox` and `rebuild`
commands operate Keiro machinery. Shikigami registers application projection
catalogs; use their owning APIs and preserve-only operations. Rich execution,
worker-session and evidence payloads cannot be reconstructed from compact lifecycle
events. See [the domain inventory](../architecture/shikigami-domain-inventory.md).


## Related documents

- [`configuration.md`](configuration.md) — every configuration key, including
  `database.connection_string` and `agents.directory`.
- `docs/adr/0001-declare-only-what-the-runtime-executes.md` — why this document
  names what a verb cannot answer instead of quietly listing it.
- `docs/adr/0018-a-workflow-that-ends-is-re-keyed-by-epoch.md` — why inspecting a
  conversation workflow inspects one epoch of it.
- `docs/adr/0021-operator-verbs-wrap-the-owning-library.md` — why the substrate
  verbs are mounted from Keiro rather than written here.

## Foreground model/agent launches

The light agent package supplies `shikigami-agent-launch interactive` for attended sessions and `shikigami-agent-launch unattended agent run|show|list` for mounted Baikai named jobs. Explicit safety and operator ceilings remain mode-specific. These return process results and create no durable run, memory session or sink receipt. See [Baikai execution](baikai-execution.md) for configuration, exit semantics and login ownership.

The public HTTP equivalent of the declared-agent inventory is `GET /agents`
(with Relay pagination) and `GET /agents/{agentName}`. The typed client exposes
`shikigami-client agents list` and `shikigami-client agents show NAME`. These read
the server deployment’s boot-time declarations and its current lifecycle directory.

The HTTP run resource is `GET /agents/{agentName}/runs/{runId}`; the acceptance
index is `GET /agents/{agentName}/runs`. The typed client provides `runs show`,
`runs list`, and `runs wait`. Wait exits 0 on success, 1 on failure/cancellation,
2 on timeout, and 3 on a transport or problem response. `runs show --json` in the
operator CLI adds the same derived lifecycle alongside its existing workflow and
session objects. Supply the returned workflow UUID verbatim.

For an HTTP-accepted run without a workflow, status reads reconcile a matching
dead-letter entry by its original queue message id and persist a terminal receipt.
This covers automatic exhaustion before the domain handler runs. The matching
entry stays available for operators; its DLQ read count increases. An entry leased
by `pgmq dlq read` can delay reconciliation until that 30-second lease expires.

Retain DLQ entries until their HTTP runs have been reconciled. Before archive,
redrive or purge, run `shikigami-client runs show AGENT RUN_ID` or
`shikigami runs show shikigami.agent-run RUN_ID --json` for each corresponding
accepted run and verify `failed` with `dead_lettered`. If the read is unavailable
or still accepted, keep the evidence and retry after any inspection lease expires.
The operator JSON command works before a workflow exists, with null workflow and
session objects. Once recorded, the receipt survives archive, purge and restart;
redrive may later create a workflow whose lifecycle takes precedence. Destructive
DLQ commands do not enforce this retention policy, and cleanup before
reconciliation can erase the only evidence. See
[ADR 0050](../adr/0050-run-status-reconciles-retained-dead-letters-through-the-released-read-api.md).
