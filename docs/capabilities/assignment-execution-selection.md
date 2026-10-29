---
type: Capability
title: "Governed assignment execution selection"
description: "Admit and retain exact provider, model and option bindings for whole assignments."
capabilityId: CAP-27
provider: mori://shinzui/shikigami
status: shipped
stability: experimental
since: unreleased
packages: ["shikigami-core"]
interface: ["Shikigami.Execution.Selection", "Shikigami.Execution.SelectionRuntime"]
tags: [assignment-execution-selection]
generated:
  by: process:shikigami-documentation-refresh
  at: "2026-10-29T00:00:00Z"
requires: [CAP-1]
evidence:
  - kind: module
    resource: "shikigami-core/src/Shikigami/Execution/Selection.hs"
    proves: "Intersects alias permissions, inherited constraints and profile compatibility."
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/ExecutionSelectionWorkflowSpec.hs"
    proves: "Retains accepted selection across changed defaults and workflow replay."
---

# Governed assignment execution selection

## Provides

Assignment admission uses the shared operator model catalog and intersects declared aliases, inherited permissions and any sanctioned profile. The accepted immutable tuple survives changed process defaults. Missing pinned bindings refuse explicitly.

## Adopt

Declare `execution.defaultAlias` and `execution.permittedAliases` as described in [Writing agents](../user/writing-agents.md).

Builds on [CAP-1: Typed agent declarations](typed-agent-declarations.md).

## Evidence

- [Selection.hs](../../shikigami-core/src/Shikigami/Execution/Selection.hs): Intersects alias permissions, inherited constraints and profile compatibility.
- [ExecutionSelectionWorkflowSpec.hs](../../shikigami-core/test-postgres/Shikigami/ExecutionSelectionWorkflowSpec.hs): Retains accepted selection across changed defaults and workflow replay.

## Limits

Selection grants no external authority. Per-slot Flow decisions retain their own permission list. This does not implement autonomous model adaptation or prove a live model deployment.

This implementation is experimental and unreleased; no released compatibility promise is asserted.
