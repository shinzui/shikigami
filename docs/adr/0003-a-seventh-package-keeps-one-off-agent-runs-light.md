# 0003. A seventh package keeps one-off agent runs light

Date: 2026-08-19

Status: accepted


## Context

Shikigami is usable two ways, and the second is a requirement rather than an
accident. The **deployed service** runs a server and supervised background loops
against Kafka, PGMQ, and Postgres, with the Kikan platform around it. A
**one-off agent run** is someone who is *not* running Kikan taking a declared
agent and running it once, from a command line. That second mode is what makes
Shikigami versatile to consumers with simpler needs; Kikan itself does not use
it.

The fleet standard at
`mori://shinzui/keiro-runtime-patterns/docs/architecture-service-packages` opens
with "A deployed keiro service is exactly six cabal packages with explicit
dependency budgets", and
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`
adopted it "without an exception" on 2026-07-22. In doing so it deleted
`shikigami-cli`, which had depended on `shikigami-api`, `shikigami-core`,
`shikigami-server`, **and** `shikigami-workers` at once — a package sitting above
every other package, whose single binary linked the HTTP server, the Kafka
consumers, the OTel exporter, and the worker loops together. That deletion was
right, and this record does not disturb it.

What plan 36 did not know is that `shikigami-cli` also carried the one-off use
case. That intent appeared in no plan, no MasterPlan, no improvement request, and
no architecture document, so the package read as pure architecture and was
removed as such. Its two one-off commands moved to `shikigami-workers`, where
every executable is `build-depends: base, optparse-applicative,
shikigami-workers` — so `shikigami-run-behavior`, documented in
`docs/architecture/packages.md` as running "with deterministic stubs (no
database, no key)", linked `hw-kafka-client`, `kafka-effectful`,
`pgmq-effectful`, `shibuya-pgmq-adapter`, `hs-opentelemetry-sdk`,
`hs-opentelemetry-exporter-otlp`, and `baikai-trace-otel`. `hw-kafka-client`
binds `librdkafka`, a C library, which is why a bare `cabal build all` in this
repository fails at link outside the Nix dev shell.

Neither command was ever coupled to any of that.
`Shikigami.Workers.Command.RunBehavior` imported only `shikigami-core`;
`AgentRun` added only kioku and kiroku, which it genuinely needs. The coupling
was one module — `Shikigami.Workers.Command` — importing the two light commands
alongside the scheduler, the worker, and the Kafka subscription.


## Decision

**Add a seventh package, `shikigami-agent`, depending on `shikigami-core` and
nothing else, and give it the one-off executables.** This is a deliberate
divergence from the fleet's six-package standard, recorded here so it is a
decision rather than a drift.

**Enforce the distinction that makes it legitimate.** An executable belongs to a
package and links that package's library.
`shikigami-core/test/Shikigami/PackageArchitectureSpec.hs` fails if any
executable in any package depends on a sibling library other than its own, and
applies the `forbiddenInLightPackages` list — listeners, exporters, queue
adapters, stream clients — to `shikigami-agent` as well as `shikigami-core`.

**Write the use case into `docs/architecture/packages.md` as a constraint**, so a
future architecture change has to argue against it rather than delete it by not
knowing about it.


## Alternatives rejected

**Split `Shikigami.Workers.Command` in two and point the light executables at
`shikigami-core`.** Cheaper, and needs no divergence from the standard. Rejected
because it leaves the one-off binaries in a package named for supervised
background loops, and nothing prevents the coupling returning the next time
someone adds an import to a shared command module. The whole reason plan 36 moved
to packages is that "Cabal, not convention, enforces the arrows"
(`docs/architecture/packages.md`). A property worth protecting is worth
protecting with the mechanism that actually holds.

**Restore the name `shikigami-cli`.** Rejected: nineteen open plans cite
`shikigami-cli/src/Shikigami/Cli/Commands/*.hs`, and a package that exists but no
longer holds those modules is a worse failure than a missing path. The name
`shikigami-agent` also matches the vertical its modules occupy.

**Leave it alone and accept the weight.** Rejected because the cost falls
entirely on the consumer this mode exists for: building a Kafka C library to run
one agent once is the difference between a usable option and a theoretical one.


## Consequences

The repository has seven packages, and `expectedPackages` in the architecture
test is the authority on that number. A future service-package review will find
this divergence; the argument it must engage with is that the standard's
objection is to edges *between* existing packages, and this adds a lighter leaf
*under* core.

`shikigami-agent` is not dependency-free. `shikigami-core` still carries `hasql`,
`hasql-pool`, `pgmq-hasql`, `shibuya-core`, `kiroku-store`, `kioku-*`, `keiro`,
`keiki`, `baikai`, and `dhall`. "Light" here means it does not link the
platform's messaging, queueing, and telemetry-export stack. Making
`shikigami-core` itself lighter is separate work that nothing currently plans, and
if it happens, `shikigami-agent` is where the benefit lands.

`RoleInfo` and `runRole` moved to `Shikigami.App.Role` in `shikigami-core` so both
packages share one configuration-resolution order. That module is now on the
composition-name allowlist in `docs/architecture/packages.md`. A third package
shipping executables inherits it rather than copying it.

`docs/plans/48-add-a-portable-one-off-repository-agent-harness.md` gains an
honest home: its `shikigami-run` command, whose stated contract is that it "never
opens Kioku or PostgreSQL", belongs in `shikigami-agent` rather than in the
workers package it was originally assigned to.

The general lesson is worth more than the package. **An architecture document
that lists what each package *is* does not protect what a package is *for*.**
Plan 36's reasoning was sound and its outcome removed a capability, because the
capability's rationale lived in someone's head. When a package exists for a
reason that is not visible from its dependency graph, that reason belongs in
`docs/architecture/packages.md`.


## References

* `docs/plans/55-give-one-off-agent-runs-a-light-package-that-does-not-link-the-platform.md`
  — the implementation and its Decision Log.
* `docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`
  — the six-package adoption, and the reconciliation section recording what it
  missed.
* `docs/architecture/packages.md` — the authoritative package map, the two usage
  modes, and the umbrella-dispatcher rule.
* `mori://shinzui/keiro-runtime-patterns/docs/architecture-service-packages` — the
  fleet standard this diverges from.
