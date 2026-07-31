---
id: 37
slug: adopt-settei-configuration-across-shikigami-binaries
title: "Adopt Settei configuration across Shikigami binaries"
kind: exec-plan
created_at: 2026-07-22T20:55:26Z
master_plan: "docs/masterplans/2-production-reality-de-stub-the-runtime-behavior-and-integration-path.md"
---

# Adopt Settei configuration across Shikigami binaries

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Every Shikigami binary currently discovers operational values through a mixture of
`getEnv`, `lookupEnv`, and unrelated command flags. After this change every process has
one typed, inspectable Settei configuration, one explicit precedence order, structurally
redacted secrets, and the same diagnostic interface. Operators can describe the complete
schema, explain where each value came from, or validate configuration without opening a
listener, acquiring a worker, or changing the database.

The visible proof is that every configurable executable supports `--describe-config`,
`--describe-config-json`, `--explain-config`, `--explain-config-json`, and
`--check-config`, and a planted secret never appears in output, errors, logs, or reports.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-07-31T05:10:00Z) M1: inventoried every environment read and configurable flag;
      declared sixteen stable keys, the flat strict `AppConfig`, the `SecretText` /
      `CredentialRef` / `Port` value types, and the validated `environmentBindings` CAF in
      `shikigami-core/src/Shikigami/App/Config.hs`. Pinned the released Settei 0.2.0.0 family
      (`settei`, `settei-env`, `settei-yaml`, `settei-optparse-applicative`).
- [x] (2026-07-31T05:10:00Z) M2: `shikigami-core/src/Shikigami/App/Config/Load.hs` assembles
      defaults → `--config` files → environment → named flags → `--set`, resolves with
      `RejectUnknownKeys`, renders all five diagnostics, and reserves exit codes 2/3/4.
      A malformed winning value is fatal and does not fall back.
- [x] (2026-07-31T05:10:00Z) M3: server, admin CLI (six subcommands), worker, scheduler,
      both consumers, run-behavior, and agent-run all resolve one `AppConfig` before opening
      anything. Named flags survive as Settei command-line sources aimed at declared keys.
- [ ] M3 remaining: `shikigami-migrate` still uses codd's `CODD_*` contract. Blocked by a
      cabal package cycle (see Surprises & Discoveries); handed to plan 38, which owns the
      migration CLI.
- [x] (2026-07-31T05:40:00Z) M4: 31 conformance cases in
      `shikigami-core/test/Shikigami/AppConfigSpec.hs` (surface, precedence, strictness,
      role requirements, diagnostics, planted secret) plus parser-to-resolution cases in
      `shikigami-workers/test/Shikigami/Workers/CommandSpec.hs` and diagnostic-surface cases
      in `shikigami-server/test/Shikigami/Server/CommandSpec.hs`. Wrote
      `docs/operations/configuration.md` and `config/shikigami.example.yaml`; updated the
      user guide and the package-architecture allowlist.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- (Review-time) Mori located the released Settei 0.2.0.0 family and confirmed that
  `settei-formats` pulls the Dhall adapter. On this repository's GHC 9.12.4/bytestring 0.12
  cohort, its `dhall-json-1.7.12` path requires project-local `allow-newer` relaxations and is
  not a coherent Hackage solve. The fleet standard therefore requires a direct adapter here:
  this plan selects `settei-yaml` and an untagged `--config PATH` contract rather than
  inheriting another repository's solver workaround. Hackage preferred metadata for both
  `settei` and `settei-yaml` lists 0.2.0.0, and upstream tag `v0.2.0.0` exists; re-check all
  three sources at implementation time before changing the cohort.

- (Implementation, 2026-07-31) The four selected packages solve cleanly on this repository's
  GHC 9.12.4 cohort with no `allow-newer` relaxation, and Hackage preferred metadata
  confirmed 0.2.0.0 for all four at implementation time. The only knock-on constraint is
  `optparse-applicative`: `settei-optparse-applicative` requires `>=0.19 && <0.20`, which is
  now pinned in every package that previously said `>=0.18`.

- (Implementation, 2026-07-31) **The migration executable cannot use the shared declaration,
  and the obstacle is structural rather than a matter of effort.** `shikigami-core`'s test
  suite depends on `shikigami-migrations`' public `test-support` sublibrary, so adding
  `shikigami-core` to `shikigami-migrate`'s `build-depends` makes the two packages mutually
  dependent. Cabal detects cycles at *package* rather than component granularity and refuses
  the whole project:

  ```text
  Error: [Cabal-7107]
  Could not resolve dependencies:
  [__0] trying: shikigami-core-0.1.0.0 (user goal)
  [__1] trying: shikigami-migrations-0.1.0.0 (user goal)
  ...
  [_33] rejecting: shikigami-core:*test (cyclic dependencies; conflict set:
        shikigami-core, shikigami-migrations)
  ```

  `shikigami-migrate` therefore keeps codd's own `CODD_*` contract, documented at its call
  site the same way the OpenTelemetry boundary is. It calls no `getEnv`/`lookupEnv` itself —
  `Codd.Environment.getCoddSettings` does the reading — so the acceptance grep stays clean,
  but the operator surface is genuinely not yet unified. Plan 38 owns the migration CLI and
  can restructure the package boundary while replacing codd with pg-migrate.

- (Implementation, 2026-07-31) Nesting the resolved configuration into `KafkaConfig`,
  `HttpConfig`, and `SinksConfig` records was tried and abandoned. Three sink records each
  want a `baseUrl` field, and under `DuplicateRecordFields` an ambiguous field selector
  cannot be used as a plain function — every read would need a qualified import, a lens, or a
  pattern match. Nothing in the tree wants to pass "just the sink settings" around, because
  the sink clients take their own types from `Shikigami.Sink`, so the grouping bought
  nothing. `AppConfig` is flat, one field per key, named after the key.

- (Implementation, 2026-07-31) A public setting declared with `publicSetting` renders as
  `<derived>` in `--explain-config` when a default rule supplied the value, so an operator
  learns that a rule fired but not what it chose. Every public setting now carries a
  renderer, even the textual ones where it is `id`. Before and after, same command:

  ```text
  http.host = <derived>            http.host = 127.0.0.1
    from default rule loopback       from default rule loopback
  ```

- (Implementation, 2026-07-31) `cabal test all` run in parallel intermittently fails
  `shikigami-core-test` while every suite passes under `-j1`. The database-backed suites each
  stand up an ephemeral PostgreSQL and contend when run concurrently. Unrelated to this
  plan's changes, but worth knowing before trusting a parallel run's verdict.


## Decision Log

Record every decision made while working on the plan.

- Decision: Settei is the sole process-configuration mechanism; raw environment reads are forbidden outside the Settei adapter and the OpenTelemetry SDK.
  Rationale: One declaration makes the accepted surface inspectable and prevents misspelled or shadowed values from silently changing behavior.
  Date: 2026-07-22
- Decision: Agent Dhall files remain domain declarations, not process configuration, but may contain only credential references—not secret values.
  Rationale: Agent structure benefits from Dhall typing, while secrets need Settei sensitivity and provenance. This also prevents MCP credentials from deriving revealing `Show` or JSON instances.
  Date: 2026-07-22
- Decision: Standard OpenTelemetry environment variables remain owned by the OTel SDK.
  Rationale: The released SDK already defines their parsing and precedence. Settei may control a Shikigami-specific enablement policy, but `OTEL_SDK_DISABLED` and exporter variables must retain standard behavior.
  Date: 2026-07-22
- Decision: Use the released direct `settei-yaml` adapter and accept repeated untagged
  `--config PATH` arguments. Do not depend on `settei-formats`, `settei-dhall`, or accept
  `FORMAT:PATH` until a later coherent released family is verified against GHC 9.12.4.
  Rationale: configuration format breadth is not worth an unreproducible compiler solve;
  YAML covers service files and CLI files while preserving Settei provenance and strict
  unknown-key handling.
  Date: 2026-07-22
- Decision: One `AppConfig` declaration for every binary, with per-binary requirements
  expressed as a `Role` rather than as separate declarations.
  Rationale: the plan's own Milestone 3 wording is "one resolved record passed during
  composition", and one declaration is what lets a single configuration file serve a whole
  deployment while `RejectUnknownKeys` stays on. Per-binary declarations would have made a
  shared file impossible to write — a key one role does not declare is an unknown key to it.
  What genuinely differs between binaries is which keys they cannot start without, and
  `missingRequirements` expresses exactly that, so `--check-config` answers for the binary it
  was run on.
  Date: 2026-07-31
- Decision: Declare only the keys something reads today. `behavior.provider`,
  `behavior.model`, `approval.*`, `worker.run_timeout_seconds`, `health.port`,
  `worker.distillation.enabled`, `http.request_max_bytes`, and the `credentials.*` keys are
  left to the plans that introduce the code reading them (13, 14, 17, 22, 29, 34).
  Rationale: Milestone 1 lists those keys with "such as", and several are explicitly
  attributed to other plans in the same paragraph. A key that no code consults is a lie told
  by `--describe-config`: an operator sets it, nothing happens, and nothing says so. The
  mechanism and the extension recipe are what this plan owes those plans, and both are in
  place — `docs/operations/configuration.md` ends with the six steps for adding a setting.
  Date: 2026-07-31
- Decision: Keep the operator-facing flags (`--broker`, `--agents`, `--topic`, `--group`,
  `--kawa-url`, and the rest) as Settei command-line sources aimed at declared keys, rather
  than removing them in favour of `--set`.
  Rationale: `Settei.Optparse.namedOption` exists for exactly this, and it costs nothing to
  keep the CLI an operator already knows. Because a flag *is* a source, it cannot drift from
  the key's default or decoder, it appears in `--explain-config` with its spelling, and
  `--broker X` and `--set kafka.broker=X` cannot disagree. Flags that name what a single
  invocation is about — a manifest path, a stub's listening port, a participant id — stay
  ordinary arguments, because they are not deployment settings.
  Date: 2026-07-31
- Decision: `shikigami`'s configuration and diagnostic options are global and precede the
  subcommand, and the subcommand itself is optional.
  Rationale: `shikigami --describe-config` has to answer without being told which command it
  is about to not run, and optparse-applicative's `subparser` consumes everything after the
  command name. Making the subcommand optional is what lets a diagnostic run alone; invoking
  the binary with neither a command nor a diagnostic prints a pointer to `--help` and exits
  with the reserved usage status.
  Date: 2026-07-31
- Decision: `database.connection_string` is `optional` in the declaration, and the
  administrative subcommands that need it demand it at the point of use via
  `requireDatabaseUrl`.
  Rationale: `shikigami validate` and `shikigami render-lifecycle` read a manifest and never
  connect. Requiring a connection string for the whole `shikigami` command line would make an
  offline command fail on a laptop with no database. The long-running roles that always need
  it get it as a `Role` requirement instead, so `--check-config` still catches a missing
  connection string for them before anything starts.
  Date: 2026-07-31


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**2026-07-31 — complete but for the migration executable.**

The purpose was that every process has one typed, inspectable configuration, one explicit
precedence order, structurally redacted secrets, and the same diagnostic interface. Nine of
the ten executables now do. The stated visible proof holds: every configurable executable
supports all five diagnostic modes, and a planted secret appears in no output, error,
report, or `Show`.

The acceptance grep finds exactly one remaining raw environment read in the whole tree,
`lookupEnv "OTEL_EXPORTER_OTLP_ENDPOINT"` in `shikigami-workers/src/Shikigami/Telemetry.hs`,
which the plan already carves out as SDK-owned and which now carries a paragraph explaining
why. Observed behavior, in the dev shell:

```text
$ shikigami-worker --check-config --config config/shikigami.example.yaml
configuration valid                                                    # exit 0

$ shikigami-worker --set http.port=not-a-port
http.port: expected a TCP port between 1 and 65535 from command-line
option --set http.port occurrence 1, rejected "not-a-port"             # exit 4

$ shikigami-worker --config bad.yaml
bad.yaml (bad.yaml:3:1) at $: while parsing a flow sequence: did not
find expected ',' or ']'                                               # exit 3

$ env -u PG_CONNECTION_STRING shikigami-worker
shikigami-worker: database.connection_string is required by this
process but no source supplied it                                      # exit 4

$ shikigami-worker --nonsense                                          # exit 2
```

`--check-config` was verified not to connect: pointed at an unroutable database
(`postgresql://nobody@203.0.113.1:5432/nope`) it still answers `configuration valid`
immediately.

What remains: `shikigami-migrate` still uses codd's `CODD_*` contract. That is not an
oversight or a shortcut — cabal refuses to build the project if the migration executable
depends on `shikigami-core`, because `shikigami-core`'s test suite already depends on
`shikigami-migrations:test-support` and the solver rejects package-level cycles. The
transcript is in Surprises & Discoveries. Plan 38 owns the migration CLI, is already a hard
predecessor of every database-evolution plan, and can restructure that boundary while
replacing codd with pg-migrate. An operator therefore configures the migration step
separately today; `docs/operations/configuration.md` says so plainly rather than implying
uniformity that does not exist.

Two lessons worth carrying forward. First, a flag and a setting do not have to be
alternatives: making every named flag a Settei source aimed at a declared key kept the
familiar CLI and removed the possibility of the two disagreeing, which was the real risk.
Second, the schema is only as honest as its renderers — a defaulted setting with no
renderer prints `<derived>`, which reads like a working diagnostic while telling an operator
nothing. That is the kind of thing only running the command catches.


## Context and Orientation

The commands this plan starts from read `PG_CONNECTION_STRING` with `getEnv`. Plan 36 has
since redistributed them, so the paths are
`shikigami-server/src/Shikigami/Server/Command/EnqueueRun.hs`,
`shikigami-workers/src/Shikigami/Workers/Command/{Worker,Scheduler,AgentRun}.hs`, and
`shikigami-workers/src/Shikigami/Workers/Subscription.hs`; the older
`shikigami-cli/src/Shikigami/Cli/Commands` path no longer exists. Plans 13, 14, 17, 22, 32,
and 34 propose additional
`lookupEnv` resolvers for model selection, approvals, deadlines, tokens, channel egress,
and memory distillation. Plan 31 proposes documenting that fragmented surface. This plan
replaces the convention before those features are implemented.

Settei separates a `Setting a`—one stable hierarchical key, decoder, description, and
sensitivity—from `Config a`, an applicative declaration of the complete typed result.
A `Source` provides candidate values. Resolution is positional: later sources win while
the report retains shadowed provenance. A secret setting redacts every candidate regardless
of whether it arrived from a file, mounted secret, environment variable, or CLI override.

This plan begins after
`docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`.
Core owns shared configuration vocabulary in `Shikigami.App.Config`; server and workers
own their composition modules. Secret-bearing constructors stay private and do not derive
`Show`.


## Plan of Work

Milestone 1 inventories and declares the complete surface. Search production Haskell,
Nix, process-compose, and documentation for environment reads and configurable flags.
Create settings with stable keys such as `database.connection_string`,
`agents.directory`, `kafka.broker`, `kafka.activity.topic`, `kafka.events.topic`,
consumer-group keys under `kafka.groups.*`, `behavior.provider`, `behavior.model`,
`approval.require`, `approval.channel`,
`approval.deadline_seconds`, `worker.run_timeout_seconds`, `http.port` for the main server,
`health.port` for worker-role probe listeners,
`worker.distillation.enabled`, `sinks.<name>.base_url`, and
`credentials.sinks.<name>.token`, plus plan 13's
`credentials.providers.anthropic.api_key`. Plan 22 additionally declares
`http.request_max_bytes` and `http.response_max_bytes`; both default to 8 MiB, accept 1 KiB
through 64 MiB, decode to a positive bounded `ByteLimit`, and feed every direct and
servant-generated sink client. Use bounded decoders for
durations, ports, retry counts, HTTP body bytes, recall limits, maintenance batch sizes, and
delegation budgets. Declare database URLs,
API keys, bearer tokens, MCP credentials, and private headers with `secretSetting`.

Define explicit environment bindings as a top-level validated CAF. Preserve accepted
legacy names—including `PG_CONNECTION_STRING`, `ANTHROPIC_API_KEY`, and the existing
`SHIKIGAMI_*` variables—by mapping them to the new keys; do not scan prefixes. Force the
exact binding CAF in tests. Before adding bounds to Cabal, use Mori to locate Settei and
verify the current coherent released package family on Hackage and upstream tags; pin the
whole family together and do not mix versions.

Milestone 2 creates two source assemblers. Long-running services resolve low-to-high from
general configuration files, mounted secret directories, and explicitly bound environment
variables using `RejectUnknownKeys`. Configurable CLI actions resolve built-in defaults,
repeated `--config PATH` YAML sources in occurrence order, environment, and repeated
`--set KEY=VALUE` overrides in occurrence order. Keep each assembly in one function per
binary. Use public `Settei`, `Settei.Env`, `Settei.Yaml`, and `Settei.Optparse` APIs;
compose `setteiOptions`, `overrideOptions`, and `diagnosticModeOptions`, and do not import
family internals or the tagged multi-format parser.

Wire `diagnosticModeOptions` before normal startup. Schema diagnostics run without loading
sources. Resolution diagnostics use the exact normal source assembly. `--check-config`
must stop before database acquisition, queue creation, provider construction, listener
startup, or worker registration. Reserve exit code 2 for usage, 3 for source IO/parsing,
and 4 for typed resolution. A malformed winning value is fatal; resolution must not fall
back to a lower candidate.

Milestone 3 migrates callers. Replace raw reads in server, worker, scheduler, consumer,
model-provider, approval, sink-auth, operator, memory-lifecycle, and migration entry points
with one resolved record passed during composition. Plans 12–35 extend this declaration where
applicable instead of adding new resolvers. Agent manifests may refer to a
credential by a stable name such as `credentials.mcp.<ref>`; runtime composition resolves
that reference to a private secret type. The OpenTelemetry SDK continues reading its
standard `OTEL_*` variables after Shikigami configuration succeeds.

Milestone 4 proves security and precedence. Add tests for source ordering, repeated files
and overrides, rejected unknown keys, malformed winners, complete error accumulation,
binding construction, and every diagnostic mode. Plant a unique token in each source and
assert it appears nowhere in standard output, standard error, reports, exceptions, startup
summaries, or `Show`. Update `docs/operations/configuration.md` from the declared schema and
delete documentation that teaches direct `getEnv`/`lookupEnv`.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`. Every build and test must go through the
Nix dev shell: a bare `cabal build all` compiles and then fails at link with
`ld: library not found for -lrdkafka`.

```bash
nix develop --command cabal build all
nix develop --command cabal test all -j1
```

Use `-j1` for the test run. The database-backed suites each stand up an ephemeral
PostgreSQL and contend with one another when run concurrently, which makes a parallel run's
verdict unreliable.

Exercise diagnostics without starting runtime resources:

```bash
nix develop --command cabal run shikigami-workers:exe:shikigami-worker -- --describe-config
nix develop --command cabal run shikigami-workers:exe:shikigami-worker -- --describe-config-json
nix develop --command cabal run shikigami-workers:exe:shikigami-worker -- --check-config --config config/shikigami.example.yaml
nix develop --command cabal run shikigami-server:exe:shikigami -- --explain-config --set agents.directory=/tmp/agents
```

Component-qualified targets are needed because `shikigami-server` names both a package and
an executable. Repeated runs are easier against the built binaries:

```bash
W=$(nix develop --command cabal list-bin shikigami-workers:exe:shikigami-worker | tail -1)
"$W" --describe-config
```

Invalid input must use the reserved status:

```bash
"$W" --set http.port=not-a-port
echo $?
```

Expected exit code: `4`, with the message
`http.port: expected a TCP port between 1 and 65535 …, rejected "not-a-port"`. No listener
or worker starts. A missing required key uses the same status:

```bash
env -u PG_CONNECTION_STRING "$W"
echo $?
```

Expected: `shikigami-worker: database.connection_string is required by this process but no
source supplied it`, exit `4`. A file that does not parse exits `3`; an unknown flag exits
`2`.

To prove `--check-config` never connects, point it at an unroutable database — it should
still answer immediately:

```bash
"$W" --check-config --set database.connection_string=postgresql://nobody@203.0.113.1:5432/nope
```

Expected: `configuration valid`, exit `0`.


## Validation and Acceptance

Acceptance requires `rg 'System.Environment.*(getEnv|lookupEnv)|\b(getEnv|lookupEnv)\b'
shikigami-* --glob '*.hs'` to find only the centralized adapter or documented OTel boundary.
Every configurable executable exposes all five diagnostic modes. A `--check-config` run
with valid sources exits zero without touching PostgreSQL; invalid source syntax exits 3;
typed invalidity exits 4. Tests prove later sources win and that a planted secret is absent
from all renderings.


## Idempotence and Recovery

Keep legacy environment bindings during migration so deployed values do not change. Move
one binary at a time and retain its old parser only until parity tests pass. Resolution and
diagnostic commands are read-only. Rolling back code leaves the old environment names
usable; do not remove a binding until deployment configuration and documentation have
already moved to its replacement key.


## Portfolio Reconciliation (2026-07-30)

The foundation order is plan 36 → this plan → plan 47. Target Settei 0.2.0.0 and use
`settei`, `settei-env`, the selected YAML/formats package, and
`settei-optparse-applicative`. Do not add `settei-kubernetes`: plan 31 identifies
process-compose and NixOS as the real deployment targets. Standard `OTEL_*` variables remain
owned by the OpenTelemetry SDK; all Shikigami process settings use the single typed Settei value.


## Interfaces and Dependencies

Core exports the inspectable declaration and non-secret domain config types from
`Shikigami.App.Config`. `Shikigami.Server.Config` and `Shikigami.Workers.Config` own source
assembly for their binaries. CLI parsers compose `setteiOptions`, `overrideOptions`,
and `diagnosticModeOptions`. Secret values use private wrappers without `Show`. Records use
strict unprefixed fields and generic-lens access. `CredentialRef` is a non-secret stable name;
`CredentialValue` is an opaque secret wrapper with no `Show`, `Read`, or JSON instances.
`ByteLimit` is a positive bounded domain type, not an unchecked `Int`. This plan hard-precedes all new raw-config
work in plans 12–35 where applicable.

Pin the coherent released direct-adapter family (`settei`, `settei-env`, `settei-yaml`,
and `settei-optparse-applicative`) together. Do not add `settei-kubernetes`,
`settei-formats`, or `settei-dhall` without a concrete source/deployment requirement, and do
not copy the Settei source checkout's project-local `allow-newer` stanza.


Revision note (2026-07-22): Created from the portfolio conformance review to replace the
previous `lookupEnv` convention with the fleet Settei service and CLI standards.

Revision note (2026-07-30): Verified Settei 0.2.0.0 and removed the Kubernetes adapter from
the target family because Shikigami's declared deployment targets are process-compose and
NixOS. Kept standard OpenTelemetry environment variables SDK-owned.

Revision note (2026-07-31): Implemented. Progress, Surprises & Discoveries, Decision Log and
Outcomes & Retrospective are filled in from the work; Concrete Steps now shows the commands
that were actually run, including the Nix dev shell requirement, the component-qualified
`cabal run` targets, and the `-j1` test caveat; and Context and Orientation corrects the
`shikigami-cli` paths that plan 36 made stale. The substantive scope changes recorded in the
Decision Log are one shared `AppConfig` with per-binary requirements expressed as a `Role`,
declaring only keys that something reads today, and keeping the operator-facing flags as
Settei sources. The one part of Milestone 3 not delivered — the migration executable — is
recorded with its cabal transcript in Surprises & Discoveries and handed to plan 38.
