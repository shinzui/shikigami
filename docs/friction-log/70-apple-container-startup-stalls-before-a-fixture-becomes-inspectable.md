---
type: Friction Entry
title: "Apple container startup stalls before a fixture becomes inspectable"
description: "Apple container 1.5.0 stalled during startup for both the existing systemd image and a minimal native Nix image, forcing Linux qualification onto the configured builder."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-13T00:40:15Z"
frictionId: FRIC-70
status: logged
impact: detour
kind: environment
origin: "mori://shinzui/shikigami"
affects: "https://github.com/apple/container"
affectedVersion: "1.5.0"
plan: "docs/plans/80-configure-model-providers-and-agent-launches-through-baikai.md"
workaround: "Use the configured builder for the immutable x86_64 Linux fixture and its native runtime probe, without restarting the shared Apple container service."
---
# Apple container startup stalls before a fixture becomes inspectable

## Attempted

bash tests/workspace/build-apple.sh packages.aarch64-linux.shikigami-baikai-contracts bin/shikigami-baikai-contracts; then start a disposable native arm64 ghcr.io/nixos/nix:2.35.2 guest.

## Encountered

The first run remained at Starting container for more than five minutes and inspect reported container not found; the minimal image also stalled at the same startup phase. Existing user containers remained running.

```text
Apple client/server 1.5.0; first startup exceeded 5m18s without a registered container. Native x86_64 fallback reports /bin/ps available.
```

## Workaround

Use the configured builder for the immutable x86_64 Linux fixture and its native runtime probe, without restarting the shared Apple container service.
