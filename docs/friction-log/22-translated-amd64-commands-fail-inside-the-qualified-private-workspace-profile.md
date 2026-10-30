---
type: Friction Entry
title: "Translated amd64 commands fail inside the qualified private workspace profile"
description: "The Apple amd64 guest starts services, but the first guarded command exits by SIGTRAP under the unchanged production containment profile, preventing use of a remote-built amd64 payload for local qualification."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-30T00:20:00Z"
frictionId: FRIC-22
status: logged
impact: detour
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://apple/container"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "Keep repository payloads and deadline guards native arm64. Investigate running only the trusted remote-built controller in an Apple arm64 guest with Rosetta; this has not yet qualified coupled execution."
---
# Translated amd64 commands fail inside the qualified private workspace profile

## Attempted

Run the shared-source collector/deadline/cancellation probe in an Apple amd64 guest to consume configured remote-builder outputs.

## Encountered

The first command produced a matching settled receipt with exit 133, zero stdout bytes and 115 stderr bytes; the command unit reports Result=signal and ExecMainStatus=5. The native arm64 run passes all 17 cases. Cause remains unknown.

```text
/tmp/shikigami-96-amd64-apple-runtime.log
```

## Workaround

Keep repository payloads and deadline guards native arm64. Investigate running only the trusted remote-built controller in an Apple arm64 guest with Rosetta; this has not yet qualified coupled execution.
