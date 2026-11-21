---
type: "Capability"
title: "Durable Dhall playbooks"
description: "Compose coding, tool, approval and reflection steps across repositories in a pinned Dhall bundle."
capabilityId: "CAP-36"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "stable"
since: "unreleased"
packages: ["shikigami-core", "shikigami-agent"]
interface: ["schema/Playbook.dhall", "Behavior.Playbook", "shikigami-local playbook validate"]
tags: ["playbook", "durability"]
generated:
  by: "process:codex-cli"
  at: "2026-11-21T13:31:35Z"
requires: ["CAP-33"]
evidence:
  - kind: test
    resource: "shikigami-core/test/Shikigami/PlaybookSpec.hs"
    proves: "Bundle and template checks and interpreter outcomes."
  - kind: example
    resource: "agents/campaigns/keiro-modernization/playbook.dhall"
    proves: "The multi-repository modernization procedure expressed in Dhall."
---

# Durable Dhall playbooks

## Provides

One durable interpreter runs named sibling playbooks. It can iterate over a literal list, payload or earlier step output, select an approved repository for a step, await an approval and recall learnings on a later run. It pins the bundle at run start.

## Adopt

Check the bundle with `shikigami-local playbook validate FILE`. Start the owning declaration with its repository grants and payload, answer any inbox request, then resume with the workflow ID. See [playbooks](../user/playbooks.md) and the [campaign results](../plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md#outcomes--retrospective).

Requires [CAP-33](local-operator-runs.md).

## Evidence

- [PlaybookSpec.hs](../../shikigami-core/test/Shikigami/PlaybookSpec.hs) covers bundle and template checks and interpreter outcomes.
- [playbook.dhall](../../agents/campaigns/keiro-modernization/playbook.dhall) covers the multi-repository modernization procedure expressed in Dhall.

## Limits

The [API baseline](../architecture/api-baseline.md) marks the playbook bundle schema stable and the local CLI provisional. Iteration is sequential. Observed step output may supply item data, while workspace selection must come from trusted input. A failed coding step stops the playbook. The operator reviews any proposed change before it affects a later run.
