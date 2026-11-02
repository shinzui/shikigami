---
type: Friction Entry
title: "Apple fixture selects PostgreSQL 17 for an allocator requiring 18"
description: "The disposable image default PostgreSQL server lacks the native uuidv7 function used by current workspace allocation, blocking the first native provisioning case."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-02T18:57:44Z"
frictionId: FRIC-44
status: "resolved"
impact: detour
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "Materialize the already pinned nixpkgs postgresql_18 package for the native guest and reuse the compiled runtime for another disposable run."
resolution: "The runner now materializes the existing pinned native PostgreSQL 18 package, selects its server output explicitly, and passes both provisioning cases with the unchanged runtime."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-02T19:00:55Z"
    change: "Match the native database environment to the current UUIDv7 allocator requirement."
---
# Apple fixture selects PostgreSQL 17 for an allocator requiring 18

## Attempted

Run the final --qualify native matrix on runtime 8d1ee35e

## Encountered

native-provision refused inside reserveWorkspaceTx with zero workspace/profile rows; the guest pg-init log identified PostgreSQL 17, while allocateWorkspaceId selects pg_catalog.uuidv7().

```text
/tmp/shikigami-workspace-run.fbQWG9/evidence/provision.log and pg-init.log; the first allocation did not publish any workspace or Unix identity.
```

## Workaround

Materialize the already pinned nixpkgs postgresql_18 package for the native guest and reuse the compiled runtime for another disposable run.
