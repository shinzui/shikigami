---
type: "Capability"
title: "Program and Skill execution"
description: "Execute registered programs or instruction-directory Skills and return JSON, with a bounded tool loop for Skills."
capabilityId: "CAP-3"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core", "shikigami-agent"]
interface: ["Shikigami.Behavior.Run", "Shikigami.Program.Registry", "shikigami-run-behavior"]
tags: ["program-and-skill-execution"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:55:22Z"
requires: ["CAP-1"]
evidence:
  - kind: module
    resource: "shikigami-core/src/Shikigami/Agent/Skill.hs"
    proves: "Public validation of Skill directory, file, frontmatter name, and description."
  - kind: module
    resource: "shikigami-core/src/Shikigami/Program/Registry.hs"
    proves: "Compiled program dispatch and the deterministic proof tasks currently registered."
  - kind: test
    resource: "shikigami-core/test/Shikigami/BehaviorToolSpec.hs"
    proves: "Tool results reach later model turns, unknown tools are recoverable, and turn limits terminate the loop."
  - kind: test
    resource: "shikigami-core/test/Shikigami/BehaviorProviderSpec.hs"
    proves: "Provider option admission, exact model policy, typed failures, and unavailable background CLI adapters."
---

# Program and Skill execution

## Provides

The synchronous runner supplies trigger payload and recalled memory to registered programs or builds a Skill context from `SKILL.md`. The public Skill validator checks the directory/file, YAML frontmatter, directory-matching name, and nonempty description. Skills can call the runtime-supplied tool registry through a bounded model/tool loop. The shared provider builder supports a key-free stub and configured Anthropic, OpenAI Chat Completions, and OpenAI Responses HTTP providers.

## Adopt

Run `shikigami-run-behavior --agent agents/heartbeat.dhall` for a behavior-only invocation without memory or sinks. Follow [Behaviors](../user/behaviors.md) and [provider configuration](../operations/baikai-execution.md) for Skills and live HTTP models.

Builds on [CAP-1: Typed agent declarations](typed-agent-declarations.md).

## Evidence

- [Agent/Skill.hs](../../shikigami-core/src/Shikigami/Agent/Skill.hs): public Skill-directory validation.
- [Registry.hs](../../shikigami-core/src/Shikigami/Program/Registry.hs): Compiled program dispatch and the deterministic proof tasks currently registered.
- [BehaviorToolSpec.hs](../../shikigami-core/test/Shikigami/BehaviorToolSpec.hs): Tool results reach later model turns, unknown tools are recoverable, and turn limits terminate the loop.
- [BehaviorProviderSpec.hs](../../shikigami-core/test/Shikigami/BehaviorProviderSpec.hs): Provider option admission, exact model policy, typed failures, and unavailable background CLI adapters.

## Limits

Durable typed decision programs use the separate
[Flow Decision capability](typed-flow-decisions.md). They do not add entries to
the synchronous behavior task registry. Intermediate Skill model/tool turns
still require the planned durable execution harness.

The built-in researcher programs return fixed proof findings; they do not perform live research. Skill `allowed-tools` is not enforced and Skill scripts are not executed. Tools require an installed registry and authorization. Flow and durable supervisor behavior require the workflow path. Background Claude/Codex CLI responses are currently refused because the released adapters fail the cancellation contract.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
