---
type: Friction Entry
title: "Apple fixture reaches systemctl before the guest manager is ready"
description: "The first normal-workflow guest exited before package setup because its first systemctl invocation preceded the systemd private bus."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-30T13:43:17Z"
frictionId: FRIC-27
status: "resolved"
impact: detour
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "Retry local-fs.target for at most twenty seconds, then reuse the already built exact runtime in another disposable guest."
resolution: "The bounded retry of local-fs.target reached the guest manager, completed signed package setup and passed native provisioning in a fresh guest using the exact cached runtime."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-30T13:45:39Z"
    change: "Qualify the guest manager/local-filesystem startup retry before package and fixture IO."
---
# Apple fixture reaches systemctl before the guest manager is ready

## Attempted

Run the newly built normal durable-workflow fixture in a fresh Apple container.

## Encountered

The initial local-fs.target barrier exited before guest systemd exposed its private bus.

```text
Failed to connect to system scope bus via local transport: No such file or directory; /tmp/shikigami-96-workflow-apple.log
```

## Workaround

Retry local-fs.target for at most twenty seconds, then reuse the already built exact runtime in another disposable guest.
