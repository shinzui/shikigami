# 0131. One kernel is composed two ways, and Kikan services are bindings

Date: 2026-11-17

Status: accepted


## Context

Shikigami has to stay easy for a routine agent on one operator's machine and still serve the
Kikan platform's organizational requirements. Until plan 135 the Kikan services were compiled
into the kernel. `shikigami-core` imported the Kikan-En and Shomei clients for its
authority, held the Kawa, Kizashi, Rei, Danwa and Kanmon output clients and the Danwa and
Kizashi approval notifiers, installed the Rei tracker provider, decoded Danwa's addressed
messages inside its conversation workflow, and shipped two Kafka consumers among the stock
roles. Every stock executable linked a client of a service that most deployments will never
run, and a declaration could name a Kikan output that nothing in the stock composition
delivers.

[ADR-129](0129-the-kernel-owns-primitives-and-use-cases-ship-as-declarations-or-packs.md)
already says the kernel owns primitives and use cases ship as declarations or packs, and
[ADR-130](0130-use-case-subsystems-leave-the-kernel-by-recorded-disposition.md) moved the
organizational use cases out. EP-8 of MasterPlan 22 gave the kernel its own action, record,
output, approval and trigger ports, with local adapters. What remained was the services
themselves.


## Decision

**One kernel, two compositions.** The seven stock packages are the kernel and its local
adapters: the stock executables run declared agents for an operator with a local report, a
local approval inbox and the local-operator authority, and nothing in them knows a Kikan
service. The Kikan distribution, `packs/kikan-shikigami`, composes the same kernel with the
Kikan binding and the organizational packs into `kikan-shikigami-worker`,
`kikan-shikigami-server`, `kikan-shikigami-scheduler`, `kikan-shikigami-consume-stream`,
`kikan-shikigami-consume-events`, `kikan-shikigami-workspace-supervisor`, the
`kikan-shikigami` admin command and `kikan-shikigami-agent-run`. A declaration in kernel
vocabulary runs unchanged under both.

**Kikan services are bindings.** `packs/kikan-shikigami-binding` holds every piece that
knows a Kikan service, each behind a kernel port and registered on `FlowPack`:

| Kernel port | Binding adapter |
| --- | --- |
| Authority, by `authorization.actions.mode` | the Kikan-En authority (`kikan`), mapping the kernel's `Action` with `toAgentAction` |
| Output kinds | `kawa.digest` (the distribution's default output), `kizashi.signal`, `rei.action`, `danwa.conversation`, `channel.egress` |
| Approval channels | `danwa`, `kizashi` |
| Objective tracker providers, by revision | `rei-v2-objectives/1` |
| Conversation channels, by event type | `danwa` (`danwa.message-addressed-to-agent`) |

The binding's main library depends on `shikigami-core:flow-sdk` and `:pack-sdk` only, like
any pack. Two public sublibraries may reach further: `outputs` holds the typed output
configurations flow bodies build, and `intake` holds the Kafka transport and the two consumer
roles, depending on `shikigami-workers`, so only the consumer executables link a Kafka
client. The distribution has executables and no library; its admin verbs (`stub-kawa`,
`stub-kanmon`, `publish-fixture`) are compiled from its `admin/` sources.

**The kernel keeps the mechanism, the binding the service.** The trigger intake's record
processing (decode, match, the packs' stream hooks, the enqueue transaction) is the kernel's
`Shikigami.Trigger.Intake`; the Kafka subscription that feeds it is the binding's. The
conversation workflow (`shikigami.conversation`) is a kernel primitive: a channel says
which event addresses an agent, how its payload becomes an `InboundMessage`, and which output
carries the reply. The outbox, receipts, grants and the action record are the kernel's, and
an output delivered by a worker's publisher is recorded against the run that enqueued it.

**Enforced, not documented.** The kernel boundary check
(`shikigami-core/test/Shikigami/KernelBoundarySpec.hs`) refuses a stock stanza, test suites
included, that depends on a Kikan client or stream library (`kikanClientLibraries`), a stock
source that imports a `Kikan.`, `Danwa.`, `Rei.` or `Shomei.` module, a stock package that
depends on a pack, and a pack library that escapes the SDK.

Settings keep their keys (`authorization.actions.*`, `sinks.*`, `credentials.sinks.*`,
`kafka.*`), now accepted only by a composition whose packs declare them, except the `kafka.*`
keys, which the kernel configuration still declares for the consumer roles. Every table stays
in the one ordered migration chain.


## Alternatives rejected

* **Keep the services in the kernel behind configuration.** It was the starting point. Every
  stock executable linked clients it never used, and a declaration could name an output
  nothing delivered, which [ADR-1](0001-declare-only-what-the-runtime-executes.md) forbids.
* **Move the conversation workflow into the binding.** Its loop runs on most of the
  agent-run runtime, and only its decoder, event type and reply were Danwa's. Moving it would
  have needed a pack-contributed workflow family, a pack-registered run route replacing the
  closed `RunRouteKind` (a durable-wire change) and timer registration, all frozen later by
  the API baseline. A channel port is one small record, shaped like an approval channel. The
  user chose this on 2026-11-17.
* **Refuse stream and event triggers in the stock composition.** Event triggers are how
  stock agents are addressed by `enqueue-run`, and a stream agent is just as addressable;
  the stock role set simply has no broker consumer.


## Consequences

The stock executables and their Nix role packages (`flake.module.nix`) are a kernel with
local adapters: no Kikan-En authority, no Kikan output, no conversation channel, no stream
or event consumer and no organizational pack. `shikigami-consume-stream`,
`shikigami-consume-events` and the stock `publish-fixture` are gone. Organizational
deployment needs the distribution packaged, and no Nix package of it exists yet
(the distribution is built and run with `cabal`). The frozen qualification cohort
(`nix/qualification/cohort.json`) still lists the pre-move closure until it is regenerated.

A pack that needs a new kind of service connection adds a field to `FlowPack` with its first
executed consumer (ADR-1), as `trackerProviders` and `conversationChannels` did; it does not
define a parallel registration.

Two gaps stay open and are named where they live: the one-off `agent-run` runs as the
agent's compatibility identity even for a declaration with a principal, so a contained
one-off run cannot use principal-keyed grants (organizational runs go through the worker,
which admits the principal); and Kikan-En has no action for a declared tool or a coding-agent
launch, so the binding refuses those actions
(`mori://shinzui/kikan-en/improvement-requests/IR-5`).


## References

* [docs/plans/135-move-the-kikan-service-bindings-out-of-shikigami-core-and-compose-a-kikan-distribution.md](../plans/135-move-the-kikan-service-bindings-out-of-shikigami-core-and-compose-a-kikan-distribution.md)
  — the moves, their Decision Log and the acceptance runs.
* [docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md](../masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md)
  — the initiative and its Kikan requirement map.
* [docs/architecture/packages.md](../architecture/packages.md) — the packages and their legal
  dependencies.
