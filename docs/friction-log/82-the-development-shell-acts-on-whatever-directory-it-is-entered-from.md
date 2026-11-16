---
type: Friction Entry
title: "The development shell acts on whatever directory it is entered from"
description: "Entering Shikigami's nix shell from another repository creates a database directory, links the pre-commit config and installs commit hooks there, and replaces an exported connection string."
generated:
  by: "claude-code/claude-fable-5-2"
  at: "2026-11-16T04:57:16Z"
frictionId: FRIC-82
status: logged
impact: detour
kind: environment
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/130-move-the-extension-boundary-out-of-shikigami-core-with-flow-packs-and-an-architecture-fitness-check.md"
workaround: "Set PGHOST and PG_CONNECTION_STRING inside the shell with 'nix develop ... --command env PGHOST=... PG_CONNECTION_STRING=... cabal run', ignore db/ and .pre-commit-config.yaml, and remove the installed hooks before committing. The external repository's justfile and README carry this."
tags:
  - "flow-packs"
---
# The development shell acts on whatever directory it is entered from

## Attempted

Building and running a pack in a separate repository with 'nix develop /Users/shinzui/Keikaku/bokuno/shikigami --command cabal ...' after 'export PG_CONNECTION_STRING=...', as plan 130 M3 prescribes.

## Encountered

The shell hook ran initdb into ./db of the other repository (and of a package subdirectory), linked .pre-commit-config.yaml, installed pre-commit and commit-msg hooks into its .git/hooks, and reset PGHOST and PG_CONNECTION_STRING to that empty ./db, so the run could not connect and the first commit failed.

```text
operator-agent-run: runtime migration verification failed: connection to server on socket "/Users/shinzui/Keikaku/bokuno/shikigami-operator-packs/db/.s.PGSQL.5432" failed: No such file or directory
Error: failed to load config: failed to determine tree root: could not find [flake.nix] in /Users/shinzui/Keikaku/bokuno/shikigami-operator-packs
```

## Workaround

Set PGHOST and PG_CONNECTION_STRING inside the shell with 'nix develop ... --command env PGHOST=... PG_CONNECTION_STRING=... cabal run', ignore db/ and .pre-commit-config.yaml, and remove the installed hooks before committing. The external repository's justfile and README carry this.
