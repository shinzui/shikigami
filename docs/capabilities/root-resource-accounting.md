---
type: Capability
title: "Root resource accounting"
description: "Reserve root-wide time, capacity, token and cost allowances across descendants and retain uncertain usage."
capabilityId: CAP-26
provider: mori://shinzui/shikigami
status: shipped
stability: experimental
since: unreleased
packages: ["shikigami-core", "shikigami-server", "shikigami-migrations"]
interface: ["Shikigami.Execution.Admission.enrollRootRun", "shikigami resources inspect"]
tags: [root-resource-accounting]
generated:
  by: process:shikigami-documentation-refresh
  at: "2026-10-29T00:00:00Z"
requires: [CAP-1]
evidence:
  - kind: module
    resource: "shikigami-core/src/Shikigami/Execution/Resources.hs"
    proves: "Atomic multidimensional reservations and conservative unknown-usage accounting."
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/ExecutionResourcesSpec.hs"
    proves: "Admission races, held capacity, settlement and descendant conservation."
---

# Root resource accounting

## Provides

A trusted producer enrolls a root with an absolute cutoff and dimension policies. Descendants inherit its allowance. Each actual attempt reserves capacity before dispatch; cancellation and reduced caps deny new work while allowing accepted results to settle.

## Adopt

[Resource accounting](../operations/execution-resources.md) describes admission and bounded inspection.

Builds on [CAP-1: Typed agent declarations](typed-agent-declarations.md).

## Evidence

- [Resources.hs](../../shikigami-core/src/Shikigami/Execution/Resources.hs): Atomic multidimensional reservations and conservative unknown-usage accounting.
- [ExecutionResourcesSpec.hs](../../shikigami-core/test-postgres/Shikigami/ExecutionResourcesSpec.hs): Admission races, held capacity, settlement and descendant conservation.

## Limits

Ordinary producers remain unenrolled unless trusted admission supplies an envelope. Unknown effects keep reservations held; expiry never proves that an effect did not happen. This foundation does not implement adaptive scheduling.

This implementation is experimental and unreleased; no released compatibility promise is asserted.
