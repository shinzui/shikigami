---
type: Friction Entry
title: "Cabal configure stayed blocked after its strip helper exited"
description: "A cold Apple-container Nix runtime build stopped making progress because one Cabal configure process retained an unreaped exited helper and never returned, requiring cancellation and another bounded build attempt."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-29T22:49:23Z"
frictionId: FRIC-21
status: "logged"
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://haskell/cabal"
affectedVersion: "3.16.1.0"
plan: "docs/plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md"
workaround: "One complete two-core Apple build succeeded, but a later two-core build repeated the configure stall with an unreaped strip helper for more than ten minutes. Cancel only the task-owned stalled attempt and use the configured remote builder for the larger Haskell build; retain Apple containers for native qualification. The cause is unestablished."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-29T23:02:12Z"
    change: "Record the successful two-core Apple build without claiming a cause or a general fix."
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-29T23:46:10Z"
    change: "Two-core retry is not a reliable workaround; the same configure/defunct-helper symptom recurred during the profile/primitives build."
---
# Cabal configure stayed blocked after its strip helper exited

## Attempted

Compile the frozen runtime with Cabal 3.16.1.0, GHC 9.12.4 and eight build jobs in an isolated Apple Linux container.

## Encountered

The parser-combinators configure process remained in futex_wait for more than ten minutes after its strip helper became a zombie; other jobs finished and an explicit SIGCHLD did not release the configure process. The cause is not established.

```text
Linux 6.18.15: Cabal configure Sl/futex_wait; child strip Z/defunct; the configure reader remained registered on an EPOLLONESHOT pipe.
```

## Workaround

Cancel only the task-owned failed build and retry with two build cores and complete logs. This is an experimental retry, not an established fix or proof of a cause.
