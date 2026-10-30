# 0072. Public CLI input is explicit and diagnostics are offline

Date: 2026-10-30

Status: accepted

## Context

Operational commands carry exact workflow, revision, epoch and authority values.
A terminal picker, implicit stdin read or hidden source loader can change the
meaning of an invocation. The client needs configuration without acquiring a
runtime-core dependency. Static schema discovery must work even when a configured
file is inaccessible or a FIFO would block.

## Decision

Use Settei's declared source order for the client: built-in values, ordered YAML
files, explicitly bound environment, named options and ordered `--set` overrides.
The client owns its leaf configuration declaration; API contracts stay independent
of configuration libraries. Static schema diagnostics precede all source IO.
Resolution diagnostics retain origin information while redacting all credential
candidates. Missing files, invalid winning values and parser errors retain exits
3, 4 and 2 respectively. Migration configuration retains ADR-32's separate boundary.

Accept piped JSON only through `--stdin` or `--payload -`. An explicit literal
payload never reads stdin, and omission keeps the documented command default.
Bound input to 4 MiB and report invalid input without echoing it. Named flags,
configuration diagnostics and native optparse shell completion are the discovery
surfaces. Version actions run offline and include build identity when available.

Keep the fixed command tree and explicit IDs. Do not introduce user alias
expansion, fuzzy selection, clipboard mutation or an embedded long-form help-topic
registry: these commands expose composable reports and exact mutation targets,
while installed operation documents and typed configuration schemas carry the
long-form guidance. Adding any of these optional interfaces requires its own
product contract, including noninteractive semantics and authority checks.

The foreground agent launcher remains a prompt-driven Baikai terminal/job adapter.
It does not assemble development-assistant context, distribute a Git-hosted skill
kit or promise a project/user/per-command eight-tier model resolver. Interactive
configuration uses the declared `launch.*` Settei keys; unattended jobs use Baikai's
public job resolver and capability ceiling. Durable agent execution continues to
use frozen declarations and profile/provider policy. These three authority models
must not be merged through an implicit convenience resolver.

## Consequences

The seven-package graph remains acyclic. Client configuration has a small local
loader and build identity adapter. Public native adapters keep their owning
protocols. CLI fixtures must exercise actual process IO and exits, including
poison source files, completion, stdin bounds and secret redaction.

## References

[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
[package boundaries](../architecture/packages.md), and
[configuration](../operations/configuration.md).
The source standards are
[mori://shinzui/haskell-jitsurei/docs/cli-overview](mori://shinzui/haskell-jitsurei/docs/cli-overview),
[mori://shinzui/haskell-jitsurei/docs/cli-stdin-integration](mori://shinzui/haskell-jitsurei/docs/cli-stdin-integration), and
[mori://shinzui/keiro-runtime-patterns/docs/config-settei-cli-standard](mori://shinzui/keiro-runtime-patterns/docs/config-settei-cli-standard).
