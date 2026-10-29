---
type: Friction Entry
title: "Workspace allocation placement conflicts with core package boundary"
description: "Plan 96 placed workspace implementation in core while the package architecture gate forbids core from linking process, requiring relocation and retesting."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-29T14:00:16Z"
frictionId: FRIC-16
status: "resolved"
impact: detour
kind: documentation
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "Keep shared workspace types and PostgreSQL transactions in core; move Git allocation and its database/Git fixtures into shikigami-workers."
resolution: "Plan 96 now places concrete Git allocation in workers and keeps shared types and PostgreSQL transactions in core; the architecture gate passes."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-29T14:01:53Z"
    change: "Align the implementation plan with the enforced package boundary."
---
# Workspace allocation placement conflicts with core package boundary

## Attempted

Implemented Git allocation alongside Workspace.Store in shikigami-core and ran cabal test shikigami-core-test.

## Encountered

PackageArchitectureSpec rejected process as a provider adapter dependency in core.

```text
provider adapters belong in leaf composition packages; core links ["process"]
```

## Workaround

Keep shared workspace types and PostgreSQL transactions in core; move Git allocation and its database/Git fixtures into shikigami-workers.
