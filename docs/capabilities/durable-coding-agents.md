---
type: "Capability"
title: "Durable coding-agent workers"
description: "Run Claude Code or Codex against a granted checkout and recover the same attempt after interruption."
capabilityId: "CAP-34"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-agent", "shikigami-core", "shikigami-workers"]
interface: ["Behavior.CodingAgent", "shikigami-agent-run --resume", "shikigami.coding-agent-step"]
tags: ["coding-agent", "recovery"]
generated:
  by: "process:codex-cli"
  at: "2026-11-21T13:31:35Z"
requires: ["CAP-33"]
evidence:
  - kind: example
    resource: "agents/coding-agent-example.dhall"
    proves: "A complete provider, prompt, access, skills and deadline declaration."
  - kind: test
    resource: "shikigami-core/test/Shikigami/CodingAgentSpec.hs"
    proves: "Reattachment, lost-launcher uncertainty, final messages and commit subjects."
---

# Durable coding-agent workers

## Provides

A durable child admits, launches and settles a bounded vendor CLI attempt. The result carries exit status, change and commit evidence. Recovery can collect the retained result or reattach to the original launcher. A lost launcher without a result leaves an uncertain attempt for inspection.

## Adopt

Run the declaration under `trust.tier=local-operator` with the chosen vendor CLI, login and Baikai ceiling. To survive the submitting terminal, enqueue a granted coding agent with `--workspace` for a local-operator worker. See [CodingAgent](../user/behaviors.md#codingagent--a-vendor-coding-agent-as-a-durable-step).

Requires [CAP-33](local-operator-runs.md).

## Evidence

- [coding-agent-example.dhall](../../agents/coding-agent-example.dhall) covers a complete provider, prompt, access, skills and deadline declaration.
- [CodingAgentSpec.hs](../../shikigami-core/test/Shikigami/CodingAgentSpec.hs) covers reattachment, lost-launcher uncertainty, final messages and commit subjects.

## Limits

Contained and multi-tenant runs refuse the launch. The [foreground launcher](foreground-agent-launches.md) remains a separate entry point.
