---
type: "Capability"
title: "Advisory practice-review orchestration"
description: "Run a registered advisory review flow with pinned evidence contracts, validated verdicts, review memory, and deduplicated attention."
capabilityId: "CAP-15"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["flow-pack-practice-review", "kikan-shikigami", "shikigami-core", "shikigami-migrations"]
interface: ["FlowPack.PracticeReview", "architecture-practice-router", "opentelemetry-practice-review", "practice_review.attention_recipients"]
tags: ["advisory-practice-review"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:45:29Z"
requires: ["CAP-4", "CAP-8", "CAP-9", "CAP-13"]
evidence:
  - kind: test
    resource: "packs/flow-pack-practice-review/test/FlowPack/PracticeReview/TypesSpec.hs"
    proves: "Pinned revision/path validation and the closed classification/resolution contracts."
  - kind: test
    resource: "packs/flow-pack-practice-review/test/FlowPack/PracticeReview/OrchestrationSpec.hs"
    proves: "Complete/incomplete evidence branches, replay, resolution receipts, concurrent attention reservation, and the golden label inventory."
  - kind: guide
    resource: "docs/user/architecture-practice-reviews.md"
    proves: "Operator setup and the explicit production content-plane limitation."
---

# Advisory practice-review orchestration

## Provides

The registered specialist obtains evidence through bounded capability ports, recalls prior adjudication, validates one advisory verdict, writes review memory, and emits history plus attention when action is needed. Missing evidence skips evaluation and produces structured unresolved output. Concurrent equivalent reviews share an atomic attention reservation and outbox intent.

## Adopt

The capability ships as the flow pack `packs/flow-pack-practice-review` and runs from the `kikan-shikigami` distribution; the stock executables do not offer it. Use the architecture-practice router and reviewer declarations under the pack's `agents/`, provision their sanctioned profile (no operator command provisions one yet, FRIC-85) and permissions, and follow [Architecture-practice reviews](../user/architecture-practice-reviews.md). Fixture ports exercise the complete-evidence branches.

Builds on [CAP-4: Durable agent runs and Flows](durable-agent-flows.md), [CAP-8: Governed routing and delegation](governed-routing-and-delegation.md), [CAP-9: Authorized sink delivery and outbox](authorized-sink-outbox.md), [CAP-13: Sanctioned execution profile pinning](sanctioned-execution-profiles.md).

## Evidence

- [TypesSpec.hs](../../packs/flow-pack-practice-review/test/FlowPack/PracticeReview/TypesSpec.hs): Pinned revision/path validation and the closed classification/resolution contracts.
- [OrchestrationSpec.hs](../../packs/flow-pack-practice-review/test/FlowPack/PracticeReview/OrchestrationSpec.hs): Complete/incomplete evidence branches, replay, resolution receipts, concurrent attention reservation, and the golden label inventory.
- [architecture-practice-reviews.md](../../docs/user/architecture-practice-reviews.md): Operator setup and the explicit production content-plane limitation.

## Limits

The production evidence reader is fail-closed with `content-plane-unavailable`; live complete-evidence reviews await [the content-plane provision](mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5). The runtime never falls back to ambient Git. Verdicts cannot edit, merge, block, or gate a repository. Resolution has typed receipt handling but no production public ingress, and the recorded [review findings](../reviews/index.md) remain relevant.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
