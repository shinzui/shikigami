# Operate the active-work watchdog

The `watchdog-sweep` Flow observes authoritative objective, coordinator, continuing
worker and execution metadata. It reads accepted operation names and references,
root controls, process deadlines and exact approval associations. It excludes
prompts, replay bodies, tool arguments/results and approval bodies. Its read grant
cannot cancel, transfer, complete or rewrite work. Findings are advisory.

## Enable a scheduled watchdog

Apply migrations, copy `agents/proof/watchdog.dhall` into the configured agents
directory, and replace its placeholder principal with your directory's verified,
active watchdog principal. The proof declaration uses a five-minute cron. Configure
both scheduler and worker with the same `watchdog` object; omission disables it.
Use the directory setup in [configuration](configuration.md) and inspect the
loaded declaration with `shikigami agents list` before enabling its schedule.
For example, set `directory.mode` to `file` and `directory.file.path` to your
projection file, containing an entry such as:

```json
[{"principal_id":"agent_watchdog","handle":"watchdog","lifecycle":"active"}]
```

Use your allocated principal consistently in that entry, the declaration and
the settings. The `watchdog` object can also come from `SHIKIGAMI_WATCHDOG`.

This complete settings example illustrates every key; choose windows and budgets
from observed workloads before deployment. These numbers are examples, not tuned
defaults:

```json
{
  "watchdog": {
    "principal": "agent_watchdog",
    "scope": "all",
    "stuckWindowSeconds": 900,
    "parkedWindowSeconds": 1800,
    "coordinatorWindowSeconds": 1200,
    "subjectsPerSweep": 48,
    "driftIntervalSeconds": 1800,
    "driftSubjectsPerSweep": 4,
    "delivery": {
      "operatorRecipient": "operator",
      "operatorSink": {"tag": "DanwaConversation", "topic": "watchdog-advisories"},
      "conversationSink": {"tag": "DanwaConversation", "topic": "watchdog"}
    },
    "allowance": {
      "principal": "agent_watchdog",
      "flow": "watchdog-sweep",
      "cutoffSeconds": 240,
      "limits": {"ActiveWork": 1, "ModelAttempts": 2, "Tokens": 131072, "CostMicroUsd": "unbounded"}
    }
  }
}
```

`scope` can instead be `{"objectives":["OBJECTIVE_ID"]}` with real allocated
objective identities. Subject pages are limited to 96. Drift needs both cadence
keys together and at most 16 subjects; omit both to disable it. Remove the `drift`
alias from the declaration as well when no assessment should run. For Drift,
configure an admitted `drift` model binding under `behavior.decisionModels`, with
a positive maximum output token count. See [typed decisions](../user/typed-decisions.md).
A finite token reservation covers the model's context window plus maximum output,
so an envelope smaller than that sum refuses before provider dispatch.

Installing a declaration grants no spend. The schedule trigger requires the same
verified principal in the directory, settings and allowance, and the exact
`watchdog-sweep` Flow. Each admitted tick receives an independent root; its first
receipt fixes its cutoff. ActiveWork, ModelAttempts and Tokens must be positive
and finite. CostMicroUsd must explicitly be `unbounded`: this runtime cannot
reserve a pre-call cost ceiling. Other named dimensions must be bounded. Observed
roots never pay, including when stopped or exhausted. Non-schedule invocations do
not receive this allowance.

Configure the Danwa sink endpoint, C11 grant and exact C13 action authorization
for the intended destinations ([action authorization](action-authorization.md)):

```bash
shikigami --config config.json grants grant watchdog DanwaConversation --by operator
shikigami --config config.json grants list
```

A trusted objective conversation receives its own finding. Unbound work goes to
`delivery.operatorRecipient`; observed text and model output cannot select either
address. Removing delivery retains findings with refusals. A missing grant or a
paused identity refuses emission without granting intervention authority.

## Inspect independently of the schedule

```bash
shikigami --config config.json watchdog inspect --agents agents --json
shikigami --config config.json watchdog inspect --agents agents --grace 60 --fail-when-overdue --json
shikigami --config config.json watchdog episodes --open --limit 20 --json
shikigami --config config.json watchdog findings EPISODE_ID --limit 20 --json
```

Pages accept `--after ID`; episode pages also accept `--objective ID`. Limits are
1..100. Reads are scoped to the configured principal and scope, bounded and read
only. `inspect` shows the latest attempt separately from the last completed sweep,
coverage, open episode count, windows and budgets. Null coverage means unavailable,
not an empty population. Incomplete passes cannot establish absence or clear an
episode. Refusal totals remain visible in the retained sweep summary.

The command loads the actual schedule declaration. A completion is fresh until
`nextDue cron completedAt + grace`; a later incomplete attempt does not reset that
clock. `--fail-when-overdue` exits 2 for an overdue completion, no completion or an
uncomputable schedule. Invalid configuration or unavailable/corrupt storage fails
the command. Use this command from your monitoring system. Readiness and liveness
HTTP probes retain their existing meanings and do not inspect watchdog cadence.

With OTel configured, the worker's independent fifteen-second sampler publishes
`shikigami.watchdog.sweep.age` in seconds from the database clock, even when no
watchdog run is active. No completion means no gauge value. A failed read logs a
bounded failure event and records no new age; an older exported point can remain,
so monitor its timestamp too. Other samplers continue. Runtime callbacks increment
`shikigami.watchdog.sweeps` (`outcome`: completed/refused/failed),
`shikigami.watchdog.findings` (`detection.kind`: stuck/unresolved/stuck-coordinator/drift)
and `shikigami.watchdog.refusals` (`refusal.kind`: retained/uncompleted). Attributes
contain no subject IDs or error bodies. These callbacks are at least once around
a lost journal append; use the ledger for exact audit counts.

## Respond to a finding

A first observation or a changed semantic mark establishes progress. A later
unchanged mark can establish quiet work after its window. Accepted permission,
approval and command waits suppress a finding within their deadlines. Uncertain
operations remain distinct from ordinary stuck work. Idle coordinators have their
own window. Drift is an input-bound typed assessment over bounded metadata and
citations, not permission to expand scope. Identical episodes coalesce; material
changes can produce another notice.

Follow references with [objective inspection](objective-tracking.md),
[execution inspection](durable-execution.md) and [worker operations](operator-cli.md).
Choose an intervention using the existing authorized commands after checking the
current revision and owner. A finding neither proves a failed business outcome nor
allows the watchdog to intervene. Partial coverage, corrupt metadata, unavailable
owner reads, missing model bindings, exhausted own allowance and denied delivery
are observation or admission refusals; investigate `runs`, inspection and the
retained evidence rather than interpreting silence as health.

The [IR-19 qualification](../evidence/plan-113/acceptance.md) uses deterministic
providers and accepted owner records through real timers, queue workers and
resume. Native command execution and live model quality are separate trials.
