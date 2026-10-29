---
type: Friction Entry
title: "Frozen Linux runtime omitted the UTF-8 build locale"
description: "The frozen Nix runtime build reached a locale-dependent compile-time dependency splice and failed while embedding non-ASCII text, forcing a cold rebuild with an explicit UTF-8 locale."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-29T22:43:29Z"
frictionId: FRIC-20
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "Set LANG=en_US.UTF-8 and provide the glibc locale archive on glibc build platforms, following the existing pinned nixpkgs Haskell builder; retain the dependency graph unchanged and rerun the Linux build."
resolution: "The frozen Nix runtime now declares the UTF-8 locale and glibc archive used by the pinned Haskell builder; its complete aarch64-linux build passes in a disposable Apple container without changing dependency pins."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-29T23:02:05Z"
    change: "Verified the corrected locale through the complete Linux runtime build."
---
# Frozen Linux runtime omitted the UTF-8 build locale

## Attempted

Build packages.aarch64-linux.shikigami-workspace-collector from the frozen runtime graph in a disposable Apple Nix builder.

## Encountered

Shomei.Account.Password.Common.Domain failed in embedStringFile while decoding data/common-passwords.txt; the runtime derivation omitted the UTF-8 locale supplied by the pinned nixpkgs Haskell builder.

The dependency source is `mori://shinzui/shomei`, path
`shomei-core/src/Shomei/Account/Password/Common/Domain.hs`; an artifact-level URI
is pending. The retained dependency revision is
`65551cb120336b53695c0dd30ebe0e473d6efcb2`.

```text
hGetContents: invalid argument (cannot decode byte sequence starting from 197)
```

## Workaround

Set LANG=en_US.UTF-8 and provide the glibc locale archive on glibc build platforms, following the existing pinned nixpkgs Haskell builder; retain the dependency graph unchanged and rerun the Linux build.

The locale setup was checked against `mori://NixOS/nixpkgs`, path
`pkgs/development/haskell-modules/generic-builder.nix` at the repository's locked
revision `d5dfd8e6716dde34398bc14bc87c10dece9c8c68`; an artifact-level URI is pending.
