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

Resolution is pure and fail-closed. Duplicate or unknown requests, missing identity,
authorization refusal, and non-`Skill` behavior are permanent typed refusals. Durable runs
admit only observation tools. A one-off invocation may admit a mutation only when its explicit
local policy authorizes it; the operation class remains visible rather than being weakened.

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

Providers must pair every successful acquisition with its inverse in the returned lease.
The lifecycle bracket can release resources but cannot reverse writes or emissions performed
by a tool; replay-safety policy therefore remains independent of cleanup correctness.


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
