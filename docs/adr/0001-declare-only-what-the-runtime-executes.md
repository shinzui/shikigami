# 0001. The keiro-dsl specification declares only what the runtime executes

Date: 2026-08-19

Status: accepted


## Context

`domain/shikigami.keiro-workspace` is a checked specification of this service's
durable contracts, and `just keiro-gate` refuses a change that would move one
incompatibly. The gate's whole value is that it attests to something true. A
specification that describes a codec, a queue envelope, or a wire shape the
runtime does not actually use is worse than no specification, because the gate
then certifies a claim nobody is honouring, and a future contributor reads the
declaration rather than the code.

The pressure to declare more than is true is real and recurring, because
keiro-dsl's grammar happily accepts declarations that no runtime path consumes.
Adopting the specification surfaced four separate instances of it in one pass:

* `shikigami_run_jobs` can be declared as a Language 5 `workqueue`, but a
  scaffolded queue always carries Keiro's schema-version-1 `{v,t,data}` envelope
  and defines its own payload record, while `Shikigami.Trigger.Enqueue` sends a
  bare `RunJob` and `Shikigami.Agent.RunJob.Worker` decodes one.
* `SinkIntent` can be declared as a `mapped structural record`, and `check`
  passes — but no declared node consumes it, so the scaffold emits a shape, a
  binding skeleton, projections, and conformance assertions, and **no codec**.
  `check --explain-bindings` says so in as many words: "structural type
  SinkIntent (not currently used by an aggregate root)".
* The Danwa integration contract can be declared as a `contract`, but a
  generated contract codec writes its discriminator into the body, and Danwa's
  `danwa.message-addressed-to-agent` body has no discriminator field.
* The sink outbox can be declared as an `emit` plus a `publisher`, but those
  model publishing contract events to a Kafka topic, and this outbox's publisher
  calls HTTP sink clients.

In every case the declaration would have compiled, checked green, and made the
specification look more complete.


## Decision

**Declare a contract only when the specification's generated artifact is the
one the runtime executes.** Where that is not true, leave the surface
undeclared, record the identity and the reason in
`docs/architecture/shikigami-domain-inventory.md`, and name the plan that will
make it declarable.

Moving a surface into the specification is therefore a wire change, not a
documentation change. It gets its own commit, its own recorded decision, and its
own fixture proving what the bytes did before and after.


## Alternatives rejected

**Declare the shape and leave the runtime alone.** This is the tempting one,
because it costs nothing today and the specification looks finished. It converts
the evolution gate from a guarantee into a decoration: `keiro-dsl diff` would
gate changes to a document that no executing code reads, so a real wire change
could pass the gate untouched while a documentation edit failed it.

**Adopt every generated codec immediately, so the specification is complete.**
Honest, but it is several wire migrations wearing a documentation hat. Each one
needs a drain story or a transitional decoder, its own fixture, and its own
rollout — and bundling them into an adoption change means a single revert
undoes all of them.


## Consequences

The specification is small and will stay small until the service grows the node
kinds keiro-dsl is built around. Today it declares two durable workflows, their
journaled label inventories, and their `run` operations; the coverage report
shows zero mapped roots on every surface, and `behavior-obligations` reports
`required: 0`.

That smallness is a true statement about this service, not a gap in the
adoption. It is also why `--deny-warnings` currently passes with nothing to
justify: every emittable warning code belongs to an aggregate, process, router,
queue, intake, or read-model surface, and this service declares none of them.

The undeclared surfaces are not invisible. Each has an owner and evidence in
`docs/architecture/shikigami-domain-inventory.md`, and each is guarded in the
meantime by the literal wire fixtures in
`shikigami-core/test/Shikigami/WireCompatSpec.hs`, whose assertions — including
"the payload is a bare run job, not a versioned envelope" — are the tripwire
that fires if someone declares a surface without moving the runtime with it.

The undeclared sink contract has one hand-owned runtime owner:
`Shikigami.Sink.Intent`. Agent runs, conversations, flows, and the outbox
publisher share its `SinkIntent` codec, preparation, deterministic identity,
delivery-receipt, and enqueue behavior. Its dedicated golden test pins the
literal bytes and integration-event identity. This is consolidation within the
hand-owned side of the generated-code firewall, not an exception to it.

A corollary that has already bitten one downstream plan: a declaration is not
made real by wanting it. `docs/plans/27-consolidate-sink-intent-and-run-lifecycle-machinery.md`
was written expecting a generated `SinkIntent` module to exist; it does not, and
its consolidation is ordinary Haskell work instead.


## References

* `docs/architecture/shikigami-domain-inventory.md` — the surface-by-surface
  census, with the evidence for every declared and undeclared row.
* `docs/plans/39-adopt-a-checked-keiro-dsl-specification-and-evolution-gate.md`
  — the adoption, and the Decision Log entries this record distils.
* `mori://shinzui/keiro-runtime-patterns/docs/keiro-dsl-adoption` — the fleet
  standard for what belongs in a specification.
* `mori://shinzui/keiro-runtime-patterns/docs/keiro-mapped-consumer-surfaces` —
  why a green harness is not evidence that an old queued payload is compatible.
