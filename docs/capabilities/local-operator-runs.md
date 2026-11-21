---
type: "Capability"
title: "Local operator runs and repository grants"
description: "Run and schedule a declared agent in a checkout under a reusable repository-specific grant."
capabilityId: "CAP-33"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-agent", "shikigami-core"]
interface: ["shikigami-local", "schema/Routine.dhall", "schema/LocalOperator.dhall"]
tags: ["local-operator", "routine"]
generated:
  by: "process:codex-cli"
  at: "2026-11-21T13:31:35Z"
requires: ["CAP-1", "CAP-7"]
evidence:
  - kind: test
    resource: "shikigami-core/test/Shikigami/LocalOperatorSpec.hs"
    proves: "Grant reuse, placement, digest changes and unattended refusal."
  - kind: test
    resource: "shikigami-agent/test/Shikigami/Agent/RoutineSpec.hs"
    proves: "Scaffolding a manual Skill or scheduled coding agent."
  - kind: test
    resource: "shikigami-core/test/Shikigami/OutputsSpec.hs"
    proves: "Composition defaults, private idempotent local reports and local inbox requests."
---

# Local operator runs and repository grants

## Provides

The local operator grants a declaration digest access to a particular repository. The grant records the approved capabilities, budget and workspace placement. A manual run and the local scheduler reuse it. The default placement for edits is a separate Git worktree. An explicit in-place grant uses a clean checkout and a run lock.

## Adopt

Use `shikigami-local new NAME` and `shikigami-local run NAME` from a checkout. Use `grant` to approve a repository before an unattended run, `up` to run approved schedules and `runs` to find the report. See [routine agents](../user/routine-agents.md) and [local grants](../user/local-operator.md).

Requires [CAP-1](typed-agent-declarations.md), [CAP-7](exact-action-authorization.md).

## Evidence

- [LocalOperatorSpec.hs](../../shikigami-core/test/Shikigami/LocalOperatorSpec.hs) covers grant reuse, placement, digest changes and unattended refusal.
- [RoutineSpec.hs](../../shikigami-agent/test/Shikigami/Agent/RoutineSpec.hs) covers scaffolding a manual Skill or scheduled coding agent.
- [OutputsSpec.hs](../../shikigami-core/test/Shikigami/OutputsSpec.hs) checks the default destination, private report and local inbox.

## Limits

Durable runs need a migrated PostgreSQL database. A changed declaration or a different repository needs its own grant. Local processes act with the operator’s host identity.
