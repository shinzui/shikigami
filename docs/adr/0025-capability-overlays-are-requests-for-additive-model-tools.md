# 0025. Capability overlays are requests for additive model tools

Date: 2026-08-22

Status: accepted


## Context

An agent sometimes needs model-facing tools that are not part of every Shikigami run. A
repository agent may need bounded workspace reads; a later MCP adapter may supply remote
tools. Putting endpoints, transports, credentials, or provider revisions directly in an
agent-authored declaration would make the declaration both request and authority. It would
also bind durable workflow data to live configuration and secret-bearing connection details.

Shikigami already has base capabilities with different safety contracts. Workflow, Memory,
Sink, Activity, Acknowledgement, profile resolution, provider selection, sessions, triggers,
and the fixed `FlowEffects` row govern durable execution. A generic tool registry that could
replace any of them would bypass those contracts. In particular, a provider lease can release
a connection, but it cannot reverse a tool call that wrote or emitted something.


## Decision

**A capability overlay is an additive set of model-facing tools requested by stable name. The
agent declaration requests the capability; an operator-owned catalog decides whether and how
that request is satisfied.**

The `capabilityOverlays` declaration field contains validated `CapabilityId` values only. It
contains no provider revision, endpoint, transport, credential reference, secret, or live
handle. An empty list is the compatibility default: it is omitted from the journal JSON and
restored when absent from an old `lookup-agent` value.

The operator catalog maps each capability id to one immutable public descriptor. A descriptor
contains the capability id, revision, and logical tool names with an operation class:
`Observation`, `IdempotentMutation`, or `IrreversibleEmission`. Resolved sets contain complete
descriptors sorted by capability id, so request order cannot change their equality or bytes.
Provider factories and acquired leases are a separate runtime boundary and are never part of
the resolved snapshot.

Each exact provider acquisition returns one run-scoped lease containing its tools and the
release action for that concrete resource. The runtime acquires resolved providers in their
canonical order and keeps successful leases on a disposal stack. It releases the stack in
LIFO order on normal return, partial acquisition failure, tool-composition refusal, callback
exception, and asynchronous cancellation. A release failure is observable but does not stop
the runtime from attempting every remaining release.

The callback receives one immutable registry derived from the process's base registry and
the leases for that run. Overlay tools are namespaced as
`overlay__<capability-id-with-dashes>__<logical-tool-name>`, and duplicate capability groups,
duplicate logical names, or any final wire-name collision are refused before the callback.
An overlay cannot replace a base tool, and no acquisition mutates a process-global registry.

`BehaviorEnv` carries that derived registry together with the exact active capability-id set.
Before dispatch, the runtime requires the declaration's requested ids to be unique and to
equal the active set. Missing, extra, or duplicate ids are permanent refusals. This makes an
empty declaration plus an empty environment the compatibility default while preventing a
caller from silently running a declared-overlay agent without its acquired tools.

A Skill with no tools retains its original single-completion request path. A Skill with tools
advertises the one derived registry and runs a model/tool loop bounded to eight model turns by
default. Unknown and ordinary tool failures return error observations to the model; budget and
context-window exhaustion leave the loop as permanent infrastructure failures, and transient
provider/tool infrastructure failures retain their retry classification. Every model turn uses
the environment's trace sink.

Resolution is pure and fail-closed. Duplicate or unknown requests, missing identity,
authorization refusal, and non-`Skill` behavior are permanent typed refusals. Generic durable resolution
admits only observation tools. A one-off invocation may admit a mutation only when its explicit
local policy authorizes it; the operation class remains visible rather than being weakened.

[Plan 96](../plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md) amendment (2026-10-30; file/process/Git adapters and patched worker admission qualified; handoff gates pending): a separate governed resolution path
may admit workspace mutation descriptors only through an operator-installed durable adapter
keyed by exact capability, revision and descriptor digest. `installDurableAdapters`
validates immutable logical tool schemas and explicit recovery contracts independently
of generic provider factories. `resolveGovernedCapabilityOverlays` consumes that exact
registry's pure admission view; the generic resolver remains observation-only. Both catalog admission and live
execution enforce this registry. Descriptions contain no executable preparation callbacks. Live schemas must match the
installed contracts; historical snapshots without workspace admission refuse the exception.
Actual preparation receives the
executor's trusted logical operation and actual attempt/claim coordinates. Generic providers
retain their existing scope and refusal behavior. Recovery classification comes from the
adapter's tested receipt contract, never solely from a public operation-class label. Old
workflow branches and snapshots gain no new authority. The
`shikigami-governed-workspaces-v1` guard selects separate governed resolution
and workspace Skill admission labels for the new capability family. Explicit
worker `workspaces` configuration defaults to `workspace.edit:1`, with reviewed
immutable instruction digests, exact agent/principal grants and content-bound
read/write restrictions. Actual file effects and lost-acknowledgement recovery
are exercised through the real parent, child and executor. No process or Git
adapter is installed until its independent qualification passes. The native
accepted-executor process/Git gate passed on 2026-10-30. Explicit
`workspaces.process` configuration now selects `workspace.edit:2`,
`workspace.exec:1` and `workspace.git:1`, retaining file revision 1 in the adapter
registry for historical protected snapshots. Every configured repository must
have a complete reviewed process policy and matching path restrictions.
Native support, reviewed instructions and ready reserved Unix identity are
required before model admission. The normal durable-workflow fixture passes all fourteen native cases.
Already admitted file-only snapshots can resume after supervised installation
only while their original reviewed base and exact path-policy identity remain
approved; they do not provision or gain the process profile. Handoff remains
an independent unfinished gate. Generic
observation providers, including `workspace.read`, retain their semantics.

The first concrete one-off provider is the immutable `workspace.read` revision `1` descriptor
in `shikigami-agent`. It contains exactly the logical `read`, `grep`, and `glob` observations.
The one-off composition root installs that descriptor and provider as operator-owned code,
requires a non-empty declared identity and Skill behavior, and resolves an explicit
`--workspace` or the current directory's canonical Git worktree. Resolution is lazy: an
empty declaration bypasses catalog construction and Git entirely. The provider exposes no
write, edit, delete, shell, or process tool, and model-authored arguments never become a
process command.

`workspace.read` accepts only relative slash-separated paths beneath that worktree and
refuses absolute paths, traversal, symlinks, Git or VCS internals, and noisy dependency/build
directories. It skips non-regular and binary files and enforces fixed V1 limits: 256 KiB per
read, 1 MiB per searched file, 2,000 visited files, traversal depth 16, 100 grep matches, 500
glob results, and 128 KiB per encoded response. Those semantics cannot be widened in place;
additive observations require a new read revision, and writes or command execution require
separate capability ids.

Both one-off executables use the same composition helper. The database-free behavior command
brackets only `runBehavior`. The memory-backed command supplies a callback at the behavior
boundary, so acquisition happens after session open and recall and release happens before
memory record and session completion. The activity-ingest branch does not acquire overlays.

An `AgentRun` resolves that request after its sanctioned profile and before opening a memory
session. The `shikigami-capability-overlays-v1` workflow patch gates a
`resolve-capability-overlays` step whose value is the explicit resolution result. Fresh runs
journal the complete public descriptor set or permanent refusal; an in-flight run that pinned
the old patch branch keeps the old body and writes no new step. Capability authorization
receives the already journaled profile snapshot, not an independent live profile lookup.

Each `run-behavior-v2` attempt acquires only the exact revisions named by the journaled set.
The lease bracket and derived `BehaviorEnv` live inside the attempt timeout, so normal return,
provider failure, callback exception, and timeout all reach cleanup before the attempt exits.
Catalog, declaration, and policy failures are permanent; provider acquisition, composition,
and release failures are transient and leave the behavior step without a journaled result.
Operators must therefore retain an old provider revision while any journal can still name it.

Overlay descriptors have no operation that replaces or widens a base capability. They do not
enter `FlowEffects`, and a Flow reaches the world only through its existing replay-safe
capabilities.


## Alternatives rejected

**Declare MCP servers or workspace provider configuration directly on each agent.** This
would let agent-authored files select endpoints and credential references, make transport
details durable, and require another declaration field for every provider family. MCP instead
becomes one operator-registered provider for a stable capability name.

**Put base capabilities and model tools in one universal registry.** This would make a tool
provider capable of replacing memory, sinks, workflow control, or profile enforcement and
would undo the fixed capability boundary established for replay safety.

**Resolve optional overlays best-effort.** Silently dropping an unknown, unavailable, or denied
request makes the model's tool menu depend on ambient state and hides operator mistakes.

**Admit mutations to durable runs because acquisition cleanup is bracketed.** Closing a lease
does not undo a tool call. Durable workflow attempts are at-least-once, so writes and emissions
need an independent operation-id and idempotency contract before they can be admitted.


## Consequences

Existing agent manifests and historical journal values remain compatible. New declarations
gain a concise, provider-neutral request surface, while operators retain ownership of provider
selection, policy, and secrets.

The JSON shapes of `CapabilityDescriptor`, `ResolvedCapabilitySet`, and
`CapabilityResolutionError` are durable public vocabulary for the later journaled resolution
step. Changing a released capability id or revision means publishing a new immutable
descriptor rather than editing a live meaning in place.

Provider registries must key factories by the exact `(CapabilityId, CapabilityRevision)` and
must acquire only the descriptors already resolved. Concrete adapters such as the first
read-only workspace provider live at the leaf package that owns their runtime resources;
generic resolution and lifecycle contracts remain in `shikigami-core`.

The V1 workspace adapter deliberately implements its three tools locally on Shikumi's public
`mkTool` and registry protocol. The released built-in filesystem fallback bounded returned
results but not total files visited or final encoded response bytes, so wrapping it could not
establish the descriptor's confinement contract.

Providers must pair every successful acquisition with its inverse in the returned lease.
The lifecycle bracket can release resources but cannot reverse writes or emissions performed
by a tool; replay-safety policy therefore remains independent of cleanup correctness.

Callers that acquire overlays must derive the behavior environment inside the lease callback.
The environment guard intentionally refuses declared overlays on paths that do not yet acquire
them, including conversation execution until its durable integration is added.

Danwa conversation execution remains such a path in this decision. A declaration with a
non-empty overlay list fails explicitly at the behavior-environment guard; it does not resolve
against the current catalog, silently omit tools, or borrow the `AgentRun` snapshot. Adding
conversation overlays requires a separately declared, patch-gated resolution boundary for the
conversation lifecycle.


## References

* `docs/plans/56-declare-agent-capability-overlay-requirements-and-the-operator-catalog.md`
  — declaration, catalog, wire, and policy implementation.
* `docs/plans/57-acquire-and-release-overlay-leases-around-one-behavior-run.md` — provider
  registry, tool-loop, and cleanup consumer.
* `docs/plans/58-resolve-and-pin-capability-overlays-in-durable-agent-runs.md` — durable
  resolution and journal pinning consumer.
* `docs/plans/59-adopt-capability-overlays-in-the-portable-one-off-repository-harness.md` —
  first read-only workspace provider.
* [ADR-0011](0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md) — defaulted
  declaration fields preserve historical journal bytes.
* [ADR-0013](0013-flow-bodies-reach-the-world-only-through-capabilities.md) — the fixed replay-safe
  Flow capability boundary.
* `mori://shinzui/shikumi/packages/shikumi-tools` — the released model-tool registry consumed
  by the provider-lifecycle plan.
