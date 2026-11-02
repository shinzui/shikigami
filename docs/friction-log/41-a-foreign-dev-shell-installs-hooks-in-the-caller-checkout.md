---
type: Friction Entry
title: "A foreign dev shell installs hooks in the caller checkout"
description: "Entering the Rei fixture development shell from Shikigami reinstalls development hooks in the caller working directory, requiring explicit checkout scoping."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-02T12:06:10Z"
frictionId: FRIC-41
status: "accepted"
impact: detour
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/rei"
plan: "docs/plans/104-adapt-rei-intentions-and-actions-to-objective-tracker-contracts.md"
workaround: "Enter the owning Rei checkout before nix develop and restore the Shikigami development shell hooks"
resolution: "The fixture enters the owning Rei checkout before its Nix shell; cross-project shell hooks remain scoped to their owner."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-02T12:29:34Z"
    change: "Accept the isolated launcher workaround; no upstream repository changes are needed for this qualification."
---
# A foreign dev shell installs hooks in the caller checkout

## Attempted

Build the real Rei fixture through its declared Nix development shell from the Shikigami launcher

## Encountered

The shell hook reported uninstalling and reinstalling commit-msg and pre-commit hooks in the current checkout

```text
commit-msg uninstalled; pre-commit uninstalled; pre-commit installed at .git/hooks/pre-commit
```

## Workaround

Enter the owning Rei checkout before nix develop and restore the Shikigami development shell hooks
