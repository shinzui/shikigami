---
type: "Capability"
title: "Declared CLI and MCP tools"
description: "Attach exact CLI argument patterns or approved MCP tools to the agent declaration and record admitted and refused calls."
capabilityId: "CAP-35"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-agent", "shikigami-core"]
interface: ["Agent.tools", "schema/Tools.dhall", "shikigami-local tools", "shikigami-local mcp"]
tags: ["tools", "authority"]
generated:
  by: "process:codex-cli"
  at: "2026-11-21T13:31:35Z"
requires: ["CAP-33"]
evidence:
  - kind: test
    resource: "shikigami-core/test/Shikigami/DeclaredToolsSpec.hs"
    proves: "Argument patterns, operator ceilings and executable invocation."
  - kind: example
    resource: "agents/repo-inventory-coder.dhall"
    proves: "CLI tools requested by a coding-agent declaration."
---

# Declared CLI and MCP tools

## Provides

The declaration names executable and argument patterns or a subset of an operator-bound MCP server’s tools. The Skill tool loop, coding-agent gate and durable CLI step apply the tool policy at the call boundary. A durable CLI step may run a granted mutation. The record distinguishes refused and admitted calls.

## Adopt

Start with [declared tools](../user/declared-tools.md). Inspect CLI resolution with `shikigami-local tools` and check MCP schemas with `shikigami-local mcp`. A server binding and its approved schemas belong in the operator’s tools file.

Requires [CAP-33](local-operator-runs.md).

## Evidence

- [DeclaredToolsSpec.hs](../../shikigami-core/test/Shikigami/DeclaredToolsSpec.hs) covers argument patterns, operator ceilings and executable invocation.
- [repo-inventory-coder.dhall](../../agents/repo-inventory-coder.dhall) covers cLI tools requested by a coding-agent declaration.

## Limits

The hosts have different enforcement capabilities. A Codex coding step can take approved MCP tools and refuses declared shell commands. Durable Skill overlays admit observations. Declared tools require the local-operator tier.
