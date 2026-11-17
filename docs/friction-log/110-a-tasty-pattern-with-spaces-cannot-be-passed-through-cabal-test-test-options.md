---
type: Friction Entry
title: "A Tasty pattern with spaces cannot be passed through cabal test --test-options"
description: "cabal splits --test-options on spaces, so a -p pattern naming several tests fails to parse and the binary must be run directly."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T23:55:01Z"
frictionId: FRIC-110
status: logged
impact: nuisance
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "https://cabal.readthedocs.io/"
affectedVersion: "unknown"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "Ran \"$(cabal list-bin shikigami-core-postgres-test)\" -p '<pattern>' from the package directory."
tags:
  - "testing"
  - "cabal"
---
# A Tasty pattern with spaces cannot be passed through cabal test --test-options

## Attempted

cabal test shikigami-core-postgres-test --test-options="-p '/a b/ || /c d/'" to rerun eleven failed cases.

## Encountered

Option -p: Could not parse: '/unassociated is not a valid pattern

## Workaround

Ran "$(cabal list-bin shikigami-core-postgres-test)" -p '<pattern>' from the package directory.
