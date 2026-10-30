---
type: Friction Entry
title: "Fresh Apple guests lose the package signature temporary file"
description: "The native file probe failed twice during apt signature verification because the freshly created temporary signature disappeared, preventing compilation."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-30T13:24:24Z"
frictionId: FRIC-25
status: "resolved"
impact: slowdown
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
resolution: "Waiting for local-fs.target before apt package setup lets the unchanged signed image compile and pass all nine native file and cleanup cases."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-30T13:24:55Z"
    change: "Add a guest local-filesystem startup barrier before package setup; retain signature verification."
---
# Fresh Apple guests lose the package signature temporary file

## Attempted

Run bash tests/workspace/probe-files-apple.sh in two fresh disposable Apple containers.

## Encountered

Both apt-get update attempts refused the signed Debian repository after sqv reported its /tmp/apt.sig file missing.

```text
Error: Reading /tmp/apt.sig.5jBzpP: No such file or directory; E: The repository http://deb.debian.org/debian trixie InRelease is not signed.
```
