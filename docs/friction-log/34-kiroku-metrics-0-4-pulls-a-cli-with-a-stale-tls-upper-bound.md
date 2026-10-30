---
type: Friction Entry
title: "Kiroku metrics 0.4 pulls a CLI with a stale TLS upper bound"
description: "The released metrics dependency introduces a transitive CLI TLS bound conflict with the selected runtime cohort."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-30T22:10:02Z"
frictionId: FRIC-34
status: "accepted"
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/kiroku/packages/kiroku-cli"
affectedVersion: "0.2.0.11"
plan: "docs/plans/106-expose-bounded-administrative-inspection-and-live-feeds.md"
workaround: "Retain Store 0.12-compatible metrics 0.4.0.0 and CLI 0.2.0.11; inspect the sole tlsManagerSettings API use, then scope allow-newer to kiroku-cli:http-client-tls and require the real compiled HTTP fixtures."
tags:
  - "dependencies"
resolution: "The Store 0.12-compatible released CLI uses the unchanged public TLS manager API; a package-scoped upper-bound relaxation builds with the selected cohort and actual HTTP/socket fixtures pass. Retain the narrow exception until a compatible descriptor revision is released."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-30T23:05:10Z"
    change: "Accepted the narrow kiroku-cli TLS exception after compiled listener qualification."
---
# Kiroku metrics 0.4 pulls a CLI with a stale TLS upper bound

## Attempted

nix develop --no-write-lock-file -c cabal build shikigami-core -j2 after adding kiroku-metrics 0.4.0.0

## Encountered

The solver refuses kiroku-cli 0.2.0.11 because its http-client-tls bound excludes 0.4.0, already required by the selected TLS cohort. The newer CLI and metrics releases require Store 0.13.

```text
kiroku-cli-0.2.0.11 (conflict: http-client-tls==0.4.0, kiroku-cli => http-client-tls>=0.3 && <0.4)
```

## Workaround

Retain Store 0.12-compatible metrics 0.4.0.0 and CLI 0.2.0.11; inspect the sole tlsManagerSettings API use, then scope allow-newer to kiroku-cli:http-client-tls and require the real compiled HTTP fixtures.
