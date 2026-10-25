---
type: Friction Entry
title: "Legacy Cabal package mirror rejects a required source archive"
description: "The full package test build encounters a 403 on the configured HTTP Hackage mirror and needs an authoritative archive cache fill."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-25T21:37:03Z"
frictionId: FRIC-3
status: "accepted"
impact: detour
kind: environment
origin: "mori://shinzui/shikigami"
affects: "https://hackage.haskell.org/package/hw-kafka-streamly-0.2.0.0"
affectedVersion: "0.2.0.0"
plan: "docs/plans/76-compose-and-verify-typed-shikumi-decisions-in-durable-flows.md"
workaround: "Fetch the exact selected release archive over HTTPS from hackage.haskell.org into the Cabal source cache, then rerun the unchanged build."
resolution: "Use the authoritative HTTPS source archive for the exact selected version; dependency pins remain unchanged and the full build proceeds."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-25T21:37:27Z"
    change: "The HTTPS archive cache fill bypassed the 403 without changing package selection."
---
# Legacy Cabal package mirror rejects a required source archive

## Attempted

cabal test all --test-options=-j1 through the temporary MP13 project

## Encountered

Download of hw-kafka-streamly-0.2.0.0 fails with HTTP 403 from objects-us-east-1.dream.io/hackage-mirror.

## Workaround

Fetch the exact selected release archive over HTTPS from hackage.haskell.org into the Cabal source cache, then rerun the unchanged build.
