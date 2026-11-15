# 0123. The kernel owns its action vocabulary, authority port and action record

Date: 2026-11-15

Status: accepted


## Context

[ADR 0036](0036-external-agent-actions-require-fresh-exact-authorization.md) requires a fresh,
exact decision immediately before every external agent action. It was implemented by typing
every decision with Kikan-En's closed `AgentAction`, imported from
`mori://shinzui/kikan-en/packages/kikan-en-contract`. About twenty core modules built Kikan
targets directly, and the authorizer record carried a Kawa source field for one sink.

That made Kikan-En's vocabulary the kernel's. The kernel could not name an action Kikan-En has no
constructor for, such as running a declared CLI tool or launching a coding agent, without a
Kikan-En release. And a decision was only a log line: nothing durable answered "what did this
run do, and who allowed it". MasterPlan 22
([docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md](../masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md))
states two kernel invariants these gaps break: K2, exactly one authority decides every external
action and fails closed, and K3, every decision is recorded before the effect proceeds.


## Decision

The kernel names its actions in `Shikigami.Authority`:

```haskell
data Action
  = UseCapability !CapabilityOperation !CapabilityTarget   -- ConnectProvider | InvokeTool name
  | EmitOutput !OutputKind !OutputTarget
```

The sum is closed over what the kernel executes today, following
[ADR 0001](0001-declare-only-what-the-runtime-executes.md). The kernel's own effects (workspace,
worker sessions, objectives, maintenance) remain capability tools of the reserved `shikigami.*`
capabilities, as they were under ADR 0036. A plan that adds a kernel effect adds its constructor
in the same change. `OutputKind` is an open, checked dotted name, so an output adapter extends the
vocabulary without a kernel change.

An `Authority` is the one port that decides. Its constructor is private; it is built with
`authority source decide`, read with `authority.decide` and `authority.source`, and `denyAll` is
the value when nothing is composed. A service authorizer is an adapter: the Kikan-En adapter,
`Shikigami.Authority.KikanEn`, maps each kernel action onto exactly one `AgentAction` and refuses,
as a policy denial, any action it cannot map. It never substitutes a nearby Kikan action. The
Kawa source and the autonomy context are the adapter's concern, not the port's. Only the adapter
modules import the Kikan-En contract or client, and a package-architecture test enforces it.

Every decision is appended to the action record (`Shikigami.Record`) before the authority
returns. `recorded` installs an authority over a record and turns a failed append into
`AuthorityUnavailable "action record unavailable"`, so an unrecorded action never proceeds. Each
durable composition root installs its authority with `recordedIn` over
`shikigami.action_record`; the database-free one-off command records JSON Lines under the
operator's state directory, and refuses every action if that file cannot be opened. The agent-run
workflow scopes its authority to the run, so each event carries the run and agent.

A record event is a checked dotted kind and a payload bounded at 8 KiB. The producer of an effect
owns its kind and payload constructor, so a new kind of effect changes no shared sum. Payloads
carry bounded coordinates only: never tool input, file content, a credential or a proof.
`shikigami record list` is the operator's view.

The rest of ADR 0036 is unchanged: authorization is fresh and exact immediately before the IO,
sinks keep lifecycle admission and the C11 grant, and the publisher decides again before
delivery.


## Alternatives rejected

**Keep `AgentAction` and add constructors to Kikan-En as needed.** Rejected because every new
kernel effect would wait on another product's release, and a composition without Kikan would
still have to speak Kikan's vocabulary.

**Mirror every Kikan-En constructor in the kernel type.** Rejected because three of them
(`ReadWorkspace`, `WriteWorkspace`, `ExecuteWorkspace`) and tool discovery have no executed call
site, and ADR 0001 forbids declaring what the runtime does not execute.

**Log decisions and add a table later.** Rejected because "every action is remembered" is a
requirement of every composition, and a log is neither queryable per run nor guaranteed to be
written before the effect.

**Let a failed record append fall back to proceeding.** Rejected because an action that is not
recorded is exactly the action an operator cannot audit.


## Consequences

A Kikan-En outage still fails closed, and now also leaves a refusal row. A record-store outage
refuses every action in that process, including ones the authority would allow. Each decision
costs one insert.

Rendered resources change spelling: an emitted output is named by its kind
(`kizashi.signal:person-nadeem`), not by Kikan's object type. The Kikan-En request and proof are
unchanged, so Kikan-En policy and grants need no change.

Server HTTP handlers and the workspace maintenance command still compose `denyAll` without a
record; their decisions are refusals that reach no effect. Recording them is follow-up work for
the composition that owns them.

EP-1 of MasterPlan 22 adds the `LocalOperator` authority as another adapter and sets the record's
tier. EP-2 and EP-3 add `LaunchCodingAgent` and `RunDeclaredTool`. EP-10 moves the Kikan-En
adapter into the Kikan binding package.


## References

* [ADR 0036](0036-external-agent-actions-require-fresh-exact-authorization.md) — restated here
  over the kernel's own type.
* [ADR 0001](0001-declare-only-what-the-runtime-executes.md) — why the sum holds only executed
  actions.
* [docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md](../plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md)
  — the implementing plan.
* `mori://shinzui/kikan/docs/cross-cutting-contracts` — C3 (every action is remembered) and C13
  (authorization at every dispatch, fail closed).
