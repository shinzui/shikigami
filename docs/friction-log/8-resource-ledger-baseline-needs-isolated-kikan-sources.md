---
type: Friction Entry
title: "Resource-ledger baseline needs isolated Kikan sources"
description: "The default Cabal project still names two absent local Kikan packages and requires the existing isolated validation project."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-28T03:47:23Z"
frictionId: FRIC-8
status: "accepted"
impact: detour
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/kikan-en"
plan: "docs/plans/81-enforce-root-resource-reservations-across-durable-work.md"
workaround: "Use the existing .dev/mp13.cabal.project and isolated upstream checkout, as in FRIC-1 and FRIC-4."
resolution: "The complete resource-ledger build and tests use the existing isolated Cabal project; repairing the unrelated Kikan checkout remains outside this initiative."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-28T04:11:36Z"
    change: "Retain the validated isolated-source workaround."
---
# Resource-ledger baseline needs isolated Kikan sources

## Attempted

nix develop --no-write-lock-file -c cabal build all

## Encountered

Cabal rejects missing ../kikan-project/kikan-en/kikan-en-contract and kikan-en-client.

## Workaround

Use the existing .dev/mp13.cabal.project and isolated upstream checkout, as in FRIC-1 and FRIC-4.
