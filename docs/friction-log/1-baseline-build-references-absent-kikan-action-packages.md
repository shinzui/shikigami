---
type: Friction Entry
title: "Baseline build references absent Kikan action packages"
description: "The Cabal project requires co-developed Kikan packages absent from the registered checkout, blocking core compilation."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-25T20:32:15Z"
frictionId: FRIC-1
status: "accepted"
impact: blocked
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/kikan-en"
plan: "docs/plans/73-define-typed-decision-programs-and-authorized-model-catalogs.md"
resolution: "Validation uses an isolated upstream checkout at 16704290d527d413568bfa40c983f5c3604c35c8 through a temporary Cabal project; repository dependency declarations and the registered checkout are preserved."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-25T20:43:59Z"
    change: "The upstream packages are available; use an isolated source checkout to validate without mutating the older local dependency checkout."
---
# Baseline build references absent Kikan action packages

## Attempted

nix develop --no-write-lock-file -c cabal build shikigami-core

## Encountered

Cabal refuses package paths ../kikan-project/kikan-en/kikan-en-contract and ../kikan-project/kikan-en/kikan-en-client; the registered checkout contains only kikan-en.cabal.
