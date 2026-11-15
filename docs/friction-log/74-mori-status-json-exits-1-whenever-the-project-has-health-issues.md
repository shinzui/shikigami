---
type: Friction Entry
title: "mori status --json exits 1 whenever the project has health issues"
description: "mori status --json prints a complete status document but exits 1 when it lists any issue (a stale schema pin, a stale registration), so a caller that trusts the exit code concludes the checkout has no Mori identity."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-15T16:38:33Z"
frictionId: FRIC-74
status: logged
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/mori"
plan: "docs/plans/126-run-declared-agents-on-the-operator-s-own-machine-through-a-local-operator-trust-tier.md"
workaround: "parse the JSON document whatever the exit code"
---
# mori status --json exits 1 whenever the project has health issues

## Attempted

Derive the Mori identity of a checkout passed by path to shikigami-agent-run --workspace

## Encountered

the stored grant made by identity was not found by path, because the resolver treated exit 1 as no identity

```text
cd fsrs-hs && mori status --json >/dev/null; echo $? -> 1, with issues [stale schema pin on mori.dhall, registration stale, not observed]
```

## Workaround

parse the JSON document whatever the exit code
