---
type: "Capability"
title: "Per-run action record"
description: "Inspect admissions, authority decisions and delivery evidence and check the invariants observable from a run."
capabilityId: "CAP-38"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core", "shikigami-agent", "shikigami-server"]
interface: ["shikigami record list", "shikigami record check", "shikigami-local ledger"]
tags: ["authority", "evidence"]
generated:
  by: "process:codex-cli"
  at: "2026-11-21T13:31:35Z"
requires: ["CAP-7"]
evidence:
  - kind: test
    resource: "shikigami-core/test/Shikigami/RecordInvariantSpec.hs"
    proves: "Decision/effect pairing, admission, lease or root, repeated effects and unchecked events."
  - kind: guide
    resource: "docs/architecture/kernel-invariants.md"
    proves: "Recorded portability runs and the limits of each invariant check."
---

# Per-run action record

## Provides

The kernel-owned action record connects admissions, decisions and effects to a principal and run. A recorded authority refuses an action if its decision cannot be appended. Local reports and Kikan outbox delivery both record the action underlying delivery.

## Adopt

Read a durable run with `shikigami record list --run ID` and `shikigami record check --run ID`. A local operator can filter refusals with `shikigami-local ledger --run ID --refusals`. See the [CLI reference](../user/cli.md).

Requires [CAP-7](exact-action-authorization.md).

## Evidence

- [RecordInvariantSpec.hs](../../shikigami-core/test/Shikigami/RecordInvariantSpec.hs) covers decision/effect pairing, admission, lease or root, repeated effects and unchecked events.
- [kernel-invariants.md](../../docs/architecture/kernel-invariants.md) covers recorded portability runs and the limits of each invariant check.

## Limits

The checker reports the properties visible in the record. K7 is enforced by construction. Effect entries without an exact action are counted as unchecked. Outbox recovery across a lost receipt relies on downstream deduplication.
