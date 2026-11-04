# 0039. Deployment roles share a frozen Cabal source closure

Date: 2026-10-06

Status: accepted

## Context

Shikigami has seven Cabal packages, while the former default Nix output attempted
to build the repository root as one package. Local qualification needs separately
addressable CLI, server, worker and migration roles with installed schema and skill
assets. An independent Nixpkgs package solve would not preserve the qualified
Keiro 0.18 cohort. The shared runtime-package-set interface is still planned at
`mori://shinzui/haskell-nix/plans/16-create-the-keiro-runtime-package-set-and-compose-applications-on-it`.

## Decision

Export the runtime component closure of the successful Cabal solve as
`nix/qualification/cohort.json`. Pin source tarballs, revised Cabal descriptor
bytes, Git trees, selected flags and compiler identity. Disable unused dependency
executables when staging local sources so they cannot introduce a second solve.
Build that closure offline in one derivation, and expose each runtime role as a
wrapper around its executable and shared assets. Keep compilation inputs separate
from documentation and private qualification logs.

An unpublished Kikan-En contract/client source is explicitly archived from a clean
commit and checksum-verified. Its archive is an immutable source pin; it does not
establish that the commit or package is available from a public registry.

Native workspace qualification reuses a Nix-built dependency tree from the same
frozen solve. Its cache inputs include the application/fixture Cabal manifests,
exact dependency sources, descriptor bytes, flags and toolchain. Cabal builds
that layer with `--only-dependencies`. Each prototype replaces all application
sources, restores original dependency descriptors, and reruns the same cohort
verification and component restriction before compiling. Haskell fixture edits
reuse the dependency derivation; manifest changes invalidate it. This introduces
no second package solve.

The prototype selects the CLI, migration runner, workspace collector, supervisor
and fixture executables used by the native runner. Production assembly retains
the full runtime targets. Run prototype builds serially on the configured shared
builder: overlapping application builds exhausted its available temporary and
installation disk space during Plan 86. Retain the actual immutable runtime
output with every trial.

## Alternatives rejected

Building the root cannot represent the seven-package graph. Solving each role
against unrelated Nixpkgs defaults can change the runtime cohort. Depending on a
mutable sibling checkout makes deployment irreproducible. Adopting an unreleased
shared interface or upgrading dependencies would mix qualification with a separate
cohort migration.

## Consequences

Role discovery and dependency identity become explicit. A cold build compiles the
whole production closure. The qualification dependency layer avoids repeating
that dependency compilation, while application compilation remains monolithic.
Further cache decomposition must preserve the selected sources and components.
Package evaluation does not prove compilation, outside-checkout startup, actual
service authorization or production readiness; each requires separate evidence.

## References

- [Plan 31](../plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md)
- [Plan 79](../plans/79-qualify-local-agent-execution-and-prioritize-production-readiness.md)
- [Readiness report](../evidence/local-qualification/readiness.md)
- [Plan 86](../plans/86-qualify-integrated-adaptive-autonomous-delivery.md)
- [Adaptive native qualification](../evidence/adaptive-delivery/native-qualification.md)
