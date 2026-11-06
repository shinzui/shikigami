---
type: Friction Entry
title: "Plan 109 points schema regeneration at the unit suite"
description: "The documented migration regeneration command passes unit tests without running the schema smoke test or updating expected-schema.txt."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-06T13:55:25Z"
frictionId: FRIC-63
status: "resolved"
impact: detour
kind: documentation
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami/plans/109-observe-active-work-through-bounded-lock-free-reads-under-a-watchdog-grant"
affectedVersion: "unreleased"
plan: "docs/plans/109-observe-active-work-through-bounded-lock-free-reads-under-a-watchdog-grant.md"
workaround: "Run SHIKIGAMI_REGENERATE_EXPECTED_SCHEMA=1 cabal test shikigami-migrations-smoke and correct the active plan command."
resolution: "Corrected plan 109 to regenerate with shikigami-migrations-smoke, then rebuild and verify without the regeneration flag."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-06T14:20:01Z"
    change: "The documented smoke-suite sequence regenerates and verifies the schema; the unit suite cannot perform that work."
---
# Plan 109 points schema regeneration at the unit suite

## Attempted

SHIKIGAMI_REGENERATE_EXPECTED_SCHEMA=1 cabal test shikigami-migrations-test --test-show-details=direct

## Encountered

Nine unit tests passed in 0.03 seconds; schema regeneration is implemented in test/Migrate.hs in the separate shikigami-migrations-smoke component.

```text
All 9 tests passed (0.03s). shikigami-migrations.cabal defines shikigami-migrations-smoke with main-is Migrate.hs.
```

## Workaround

Run SHIKIGAMI_REGENERATE_EXPECTED_SCHEMA=1 cabal test shikigami-migrations-smoke and correct the active plan command.
