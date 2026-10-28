---
type: Friction Entry
title: "Configured Kikan authorization packages are absent"
description: "The project build references two missing local authorization packages, blocking compilation before IR-11 implementation."
generated:
  by: "codex-cli/gpt-6-astra"
  at: "2026-10-28T20:11:29Z"
frictionId: FRIC-14
status: "resolved"
impact: blocked
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
resolution: "Restored the missing packages by fast-forwarding the clean configured Kikan-En checkout to upstream commit 16704290d527d413568bfa40c983f5c3604c35c8; cabal build shikigami-core passes."
amended:
  - by: "codex-cli/gpt-6-astra"
    at: "2026-10-28T20:15:37Z"
    change: "Restore upstream dependency source and verify the baseline core build"
---
# Configured Kikan authorization packages are absent

## Attempted

nix develop --no-write-lock-file -c cabal test shikigami-core-test

## Encountered

cabal.project package locations ../kikan-project/kikan-en/kikan-en-contract and ../kikan-project/kikan-en/kikan-en-client do not exist
