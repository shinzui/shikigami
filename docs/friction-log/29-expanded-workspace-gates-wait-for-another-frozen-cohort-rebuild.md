---
type: Friction Entry
title: "Expanded workspace gates wait for another frozen cohort rebuild"
description: "The integration and continuing-workspace fixture candidate rebuilds the complete frozen Linux cohort before its native tests can start, repeating FRIC-23 and FRIC-26."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-30T16:35:55Z"
frictionId: FRIC-29
status: logged
impact: slowdown
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "Batch the integration, continuing-write and process-fence fixtures into one committed runtime; finish host-wide checks and consumer documentation while it builds."
---
# Expanded workspace gates wait for another frozen cohort rebuild

## Attempted

Build the committed b9922af Linux workspace prototype with nix build .#packages.x86_64-linux.shikigami-workspace-prototype --max-jobs 0 --cores 2 --no-link --no-write-lock-file --json.

## Encountered

The monolithic qualification derivation rebuilds the complete frozen Cabal graph; the host-wide build and test suites finish while native execution is still waiting for compilation.

```text
/tmp/shikigami-96-native-gates-build.log; shikigami-workspace-prototype-0.1.0.0-b9922af remains building on the configured remote builder after five minutes.
```

## Workaround

Batch the integration, continuing-write and process-fence fixtures into one committed runtime; finish host-wide checks and consumer documentation while it builds.
