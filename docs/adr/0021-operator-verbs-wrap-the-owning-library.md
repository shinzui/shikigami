# 0021. Operator verbs wrap the owning library, and Shikigami writes only the join

Date: 2026-08-20

Status: accepted


## Context

Shikigami's durable state is not Shikigami's. A run's workflow instance, its
journal, its steps, its leases, the sink outbox, the integration-event inbox, and
the PGMQ job queues all belong to *keiro*. A run's session, its turns, and its
memories belong to *kioku*. This service composes both and owns the declarations
that drive them, but it owns almost none of the tables an operator needs to look
at when something is wrong.

`docs/plans/30-operator-cli-inspect-runs-agents-dead-letters-and-cancel.md` was
written to give operators a command line, and its first design was to write one:
read-only SQL over `keiro.keiro_workflows` and the kioku session table, a
hand-rolled cancel that appended keiro's terminal journal marker, four
dead-letter verbs, and a bespoke keyset-pagination type to bound it all.

Two things happened before it was implemented. Keiro released `keiro-ops`, an
operator console whose command tree is explicitly embeddable into a host binary.
And Keiro adopted ADR-28
(`mori://shinzui/keiro/okf/adrs/concepts/ADR-28`, "Operator commands wrap
supported library APIs and respect schema ownership"), which decides that every
operator command is a thin adapter over an exported operation of the library that
owns the affected state — no reproducing a supported mutation with ad hoc SQL,
and no querying or mutating another library's private tables.

So the original design was not merely more work than necessary; it was a
documented mistake, and one that would have had to be re-verified against Keiro's
schema on every upgrade.


## Decision

**Operator verbs over another library's state are mounted from that library, not
written here.** `shikigami` mounts `Keiro.Ops.opsCommandTree` whole, which is
where `wf`, `timer`, `outbox`, `inbox`, `pgmq`, `projection`, `shard`,
`snapshot`, and `stream` come from. This repository writes no SQL against keiro's
or kioku's tables for operator purposes, and adds no verb that duplicates one of
theirs.

**Shikigami writes the verbs that no single library can supply**, which so far
are exactly two:

- `agents list`, because the declared-agent inventory is Shikigami's own concept
  and lives in manifests rather than in any library's tables.
- `runs show`, because it joins a keiro workflow instance to its kioku session.
  Keiro has no business knowing about kioku and kioku none about keiro, so
  neither can perform that join and it is Shikigami's by construction.

**The join is read from what the run recorded, not inferred.** The workflow id
and the session id are independent — the first is the run job's idempotency key,
the second is minted fresh when the session opens — but the run journals the
link: an agent run records the session id as the result of its `open-session`
step, and a conversation records it under `resolve-session`. Keiro exposes
recorded step results through `loadStepIndex`, so `runs show` reads the link
through exported operations of both libraries and writes no query of its own.

**When a primitive is missing, it is added upstream before a command exposes
it.** That is ADR-28's rule and it binds here too: the fix for a gap in the
operator surface is a Keiro or Kioku release, not a local query.

**A mounted verb's spellings win.** Where the mounted tree and a Shikigami verb
express the same concept, Shikigami adopts the mounted spelling: `--force` for
the mutation gate, `--json` as a flag, and `NAME ID` for naming a workflow
instance. One binary with two words for one idea is a usability defect.


## Alternatives rejected

**Write the verbs here anyway.** Rejected on three counts, any one of which would
be sufficient. It violates Keiro ADR-28. It creates a maintenance obligation to
track another project's schema across every cohort upgrade, which is precisely
the coupling `docs/dependency-cohort.md`'s "released versions only" rule exists
to avoid. And it delivers less: mounting brought journal decoding, awakeable
inspection and cancellation, lease release, workflow resurrection, outbox
maintenance passes, and stuck-timer triage, none of which the plan had scoped.

**Mount the tree under a namespace, as `shikigami ops wf …`.** Rejected because
the extra word buys nothing and costs discoverability — a single `--help` listing
every group, Shikigami's and Keiro's together, is what an operator wants. The
cost of the flat mount is that Shikigami's own subcommand names and Keiro's now
share a namespace; the dispatcher resolves Shikigami's first, so a future
collision is decided deliberately in one place rather than by accident.

**Populate every `AppHooks` field because they exist.** Rejected. `replayAudit`
and `projectionCatalog` gate commands over machinery this service does not have,
and mounting them would advertise capabilities the runtime lacks — the mistake
`0001-declare-only-what-the-runtime-executes.md` exists to prevent.
`workflowResume` and `timerFire` each gate exactly one bounded-pass command over
a loop the worker process already runs continuously, so they are conveniences
rather than capabilities. The tree omits an unhooked command from the parser
entirely, so an absent hook is an absent verb rather than a verb that fails when
used.


## Consequences

An operator gets a much larger surface than this service could have justified
building, and it stays correct across Keiro upgrades without work here.

The cost is that Shikigami inherits behaviours it did not choose and cannot
change locally, and several are surprising enough to have their own section in
`docs/operations/operator-cli.md`: `pgmq dlq --queue` names the *live* queue and
derives the dead-letter queue from it; `pgmq dlq read` hides rows for 30 seconds
so a redrive issued immediately after reports affecting nothing; preview messages
name `keiro-ops` rather than `shikigami`; a mutating verb refuses under schema
drift; and `outbox dead-letters list` mounts without having any target in this
deployment. Changing any of these means an upstream release, and the runbook is
where they are written down until then.

`keiro-migrations` requires PostgreSQL 18 exactly and every mounted verb verifies
that before running, so adopting this console set the floor for the whole
repository's database version. The dev shell pins PostgreSQL 18 accordingly.

Audit logging is bounded by what the boundary can see. `Keiro.Ops` exports
`OpsInvocation` abstractly and returns only an `ExitCode`, so the audit lines
name the invocation and its exit status and deliberately claim no verb-specific
outcome — an exit code does not carry one, and `wf cancel --force` against an
already-terminal instance reports `already_completed` while exiting zero.

Two future plans extend this surface and must extend it rather than compete with
it: `docs/plans/23-agent-lifecycle-control-with-meibo-principals.md` adds to the
`agents` group, and
`docs/plans/54-key-durable-agent-state-by-meibo-principal.md` changes what
`agents list` and `runs show` display.
