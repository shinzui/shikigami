---
type: "Capability"
title: "Foreground agent launches"
description: "Launch attended vendor terminal sessions or named unattended jobs with explicit authority and preserved exit status."
capabilityId: "CAP-18"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-agent"]
interface: ["shikigami-agent-launch interactive", "shikigami-agent-launch unattended agent"]
tags: ["foreground-agent-launches"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:45:29Z"
evidence:
  - kind: test
    resource: "shikigami-agent/test/Shikigami/Agent/LaunchSpec.hs"
    proves: "Safety admission, redacted reports, fake launch argument/cwd propagation, exit status, and unattended ceiling refusal."
  - kind: guide
    resource: "docs/operations/baikai-execution.md"
    proves: "Attended terminal prerequisites and the mounted named-job parser with operator permission ceilings."
---

# Foreground agent launches

## Provides

The portable agent package offers a foreground terminal launcher for Claude or Codex with explicit provider-specific safety settings, workspace selection, prompt, and optional model/effort. An unattended command mounts the released named-job interface with repository jobs and a separate operator permission ceiling. Executed vendor exit status is propagated.

## Adopt

Configure `launch` and its safety policy and run the attended command from a terminal. For named unattended jobs, define repository jobs and operator ceilings through the mounted configuration described in [Baikai execution](../operations/baikai-execution.md).

## Evidence

- [LaunchSpec.hs](../../shikigami-agent/test/Shikigami/Agent/LaunchSpec.hs): Safety admission, redacted reports, fake launch argument/cwd propagation, exit status, and unattended ceiling refusal.
- [baikai-execution.md](../../docs/operations/baikai-execution.md): Attended terminal prerequisites and the mounted named-job parser with operator permission ceilings.

## Limits

These launches create no Shikigami workflow, memory session, or sink receipt. Attended launches need stdin/stdout terminals, a real directory, vendor executable, and login. Named unattended jobs use their separate mounted launcher; their availability does not enable the refused background CLI response providers in agent runs.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
