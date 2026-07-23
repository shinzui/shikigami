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

- [ ] M1: inventory every environment variable and flag; declare stable keys, strict typed records, settings, and explicit environment bindings.
- [ ] M2: implement service and CLI source assembly with fixed precedence, rejected unknown keys, standard diagnostics, and exit codes 2/3/4.
- [ ] M3: migrate worker, server, scheduler, consumers, model provider, approvals, sinks, operator commands, and migration executable away from `getEnv`/`lookupEnv`.
- [ ] M4: add precedence, malformed-winner, binding-construction, diagnostics, and planted-secret conformance tests; update operational documentation.


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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The existing commands under `shikigami-cli/src/Shikigami/Cli/Commands` read
`PG_CONNECTION_STRING` with `getEnv`. Plans 13, 14, 17, 22, 32, and 34 propose additional
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

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`:

```bash
nix develop
cabal build all
cabal test all
```

Exercise diagnostics without starting runtime resources:

```bash
cabal run shikigami-worker -- --describe-config
cabal run shikigami-worker -- --describe-config-json
cabal run shikigami-worker -- --check-config --config config/example.yaml
cabal run shikigami -- --explain-config --set worker.run_timeout_seconds=60
```

Invalid input must use the reserved status:

```bash
cabal run shikigami-worker -- --set health.port=not-a-port
echo $?
```

Expected exit code: `4`. No listener or worker starts.


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
`settei-optparse-applicative`, and `settei-kubernetes`) together. Do not add
`settei-formats`/`settei-dhall` or copy the Settei source checkout's project-local
`allow-newer` stanza.


Revision note (2026-07-22): Created from the portfolio conformance review to replace the
previous `lookupEnv` convention with the fleet Settei service and CLI standards.
