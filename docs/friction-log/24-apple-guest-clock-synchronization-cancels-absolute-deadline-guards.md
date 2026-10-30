---
type: Friction Entry
title: "Apple guest clock synchronization cancels absolute deadline guards"
description: "The Apple VM agent periodically steps realtime, cancelling guarded commands before their accepted UTC cutoff and making fixed-duration restart fixtures unreliable."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-30T02:24:48Z"
frictionId: FRIC-24
status: logged
impact: detour
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://apple/container"
affectedVersion: "1.5.0"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "Observe the next guest clock step before short fixture admission, hold payloads until the duplicate or restart boundary is proven, then explicitly release them. Keep production clock-change expiry enabled; this fixture workaround does not qualify long-running commands across clock changes."
---
# Apple guest clock synchronization cancels absolute deadline guards

## Attempted

Qualify an accepted fifteen-second validation command with the unchanged absolute-deadline guard in a disposable Apple guest.

## Encountered

The native payload wrote its markers promptly, then the guard observed timerfd ECANCELED and returned 124 before the thirty-second accepted deadline. The guest systemd-timesyncd service was inactive.

```text
/tmp/shikigami-96-prototype-clock-event-apple.log and /tmp/shikigami-workspace-run.hdqoUp/evidence; mori://apple/containerization, project-relative Sources/Containerization/TimeSyncer.swift at tag 0.47.0 (artifact URI pending), calls the guest setTime API every thirty seconds.
```

## Workaround

Observe the next guest clock step before short fixture admission, hold payloads until the duplicate or restart boundary is proven, then explicitly release them. Keep production clock-change expiry enabled; this fixture workaround does not qualify long-running commands across clock changes.
