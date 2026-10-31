---
type: Friction Entry
title: "Compiler boundary suite starts Cabal separately for every probe"
description: "The domain-value compiler gate invokes cabal exec for each client and buffers progress, costing several minutes for a small nominal-format batch."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-31T19:50:47Z"
frictionId: FRIC-36
status: logged
impact: slowdown
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/108-complete-the-remaining-domain-scalar-identity-and-decoder-audit.md"
---
# Compiler boundary suite starts Cabal separately for every probe

## Attempted

Run nix develop --no-write-lock-file -c just domain-value-types after adding four process-policy format probes.

## Encountered

The serial revision-domains.py subprocess loop remained active for several minutes without emitting per-case progress to the redirected evidence log.

```text
tests/types/revision-domains.py runs cabal exec -- ghc for each CASES entry; stdout print calls are buffered when redirected.
```
