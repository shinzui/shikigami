---
type: Friction Entry
title: "Default Cabal project points at missing Kikan packages"
description: "The checked-in Cabal project cannot resolve its local Kikan package paths in this workspace."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-25T23:20:12Z"
frictionId: FRIC-4
status: "accepted"
impact: detour
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/88-serve-the-declared-agent-catalog-over-http.md"
workaround: "Use the pre-existing .dev/mp13.cabal.project with its isolated Kikan checkout for validation."
resolution: "Validation uses the existing isolated Cabal project; repairing the unrelated Kikan source closure remains outside this initiative."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-25T23:24:02Z"
    change: "Catalog validation completed through the existing local override."
---
# Default Cabal project points at missing Kikan packages

## Attempted

nix develop -c cabal build shikigami-server shikigami-client shikigami-api

## Encountered

Both ../kikan-project/kikan-en/kikan-en-contract and kikan-en-client are absent.

## Workaround

Use the pre-existing .dev/mp13.cabal.project with its isolated Kikan checkout for validation.
