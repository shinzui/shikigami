---
type: Friction Entry
title: "Embedded Git metadata rebuilds the runtime closure at audit checkpoints"
description: "A required coherent build after each source checkpoint recompiles and relinks downstream runtime packages because the core library embeds changing Git metadata."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-01T01:11:53Z"
frictionId: FRIC-37
status: "accepted"
impact: slowdown
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/108-complete-the-remaining-domain-scalar-identity-and-decoder-audit.md"
workaround: "Commit source before the last required Cabal build, refresh the census after all Cabal gates, and keep the evidence-only commit last; this avoids redundant cycles but still incurs one closure build per source checkpoint."
resolution: "Keep embedded Git provenance within this bounded migration; commit the complete production source before the last compatibility/build/census sequence and keep the evidence-only commit last."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-01T22:55:02Z"
    change: "Accepted the existing Git metadata rebuild cost with a single final source boundary; changing version embedding is outside this type migration."
---
# Embedded Git metadata rebuilds the runtime closure at audit checkpoints

## Attempted

After source commits e7aa4ae and f556e24, run nix develop --no-write-lock-file -c cabal build all --enable-tests -j1 before refreshing the source/interface census.

## Encountered

Shikigami.App.Version recompiles when .git/index changes, and the version-bearing core dependency closure then rebuilds worker, agent, client and server components; each coherent checkpoint costs minutes even after focused code checks pass.

```text
Compiling Shikigami.App.Version [.../.git/index changed]; Compiling Shikigami.Server.Boot [Shikigami.App.Config changed]; Linking shikigami-server-test [Objects changed].
```

## Workaround

Commit source before the last required Cabal build, refresh the census after all Cabal gates, and keep the evidence-only commit last; this avoids redundant cycles but still incurs one closure build per source checkpoint.
