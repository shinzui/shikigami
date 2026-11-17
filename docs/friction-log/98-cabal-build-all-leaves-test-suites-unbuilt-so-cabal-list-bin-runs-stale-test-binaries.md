---
type: Friction Entry
title: "cabal build all leaves test suites unbuilt, so cabal list-bin runs stale test binaries"
description: "In this repository cabal build all builds libraries and executables but not test suites, and cabal list-bin prints the path of whatever test binary is already on disk, so suites run that way silently test old code."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T15:48:20Z"
frictionId: FRIC-98
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "https://cabal.readthedocs.io/"
affectedVersion: "3.16.1.0"
plan: "docs/plans/135-move-the-kikan-service-bindings-out-of-shikigami-core-and-compose-a-kikan-distribution.md"
workaround: "Build every test suite by name before running its binary (or use cabal test), and treat cabal build all as libraries and executables only."
tags:
  - "build"
  - "testing"
---
# cabal build all leaves test suites unbuilt, so cabal list-bin runs stale test binaries

## Attempted

After changing the output pipeline (plan 135 M3 stage a), ran cabal build all, then each suite as $(cabal list-bin test:<suite>) -j 2 from its package directory.

## Encountered

cabal build all printed Up to date while the workers, server, agent and pack test suites no longer compiled; the suites ran from binaries built before the change and passed. Building a suite by name (cabal build <pkg>:test:<suite>) exposed the compile errors.

```text
cabal build all -> Up to date; cabal build flow-pack-practice-review:test:flow-pack-practice-review-test -> error: Constructor SinkEnv does not have field danwaTarget
```

## Workaround

Build every test suite by name before running its binary (or use cabal test), and treat cabal build all as libraries and executables only.
