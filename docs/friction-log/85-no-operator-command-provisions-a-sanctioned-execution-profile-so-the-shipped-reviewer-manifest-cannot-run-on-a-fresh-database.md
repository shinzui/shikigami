---
type: Friction Entry
title: "No operator command provisions a sanctioned execution profile, so the shipped reviewer manifest cannot run on a fresh database"
description: "opentelemetry-practice-reviewer pins sanctioned-review version 1, the profile store is read through PostgreSQL only, and no shikigami verb writes a digest-correct profile row."
generated:
  by: "claude-code/claude-fable-5-2"
  at: "2026-11-16T15:52:37Z"
frictionId: FRIC-85
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/131-shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems.md"
workaround: "The before and after runs used a copy of the reviewer manifest without its sanctionedProfile field, on both builds, so the comparison still exercised every pack interpreter the unresolved path reaches. The shipped manifest is unchanged."
tags:
  - "sanctioned-profile"
  - "real-use"
---
# No operator command provisions a sanctioned execution profile, so the shipped reviewer manifest cannot run on a fresh database

## Attempted

Plan 131 M3 real run of packs/flow-pack-practice-review/agents/opentelemetry-practice-reviewer.dhall on an isolated database, following docs/user/architecture-practice-reviews.md, which says to provision the immutable active profile in the deployment profile store.

## Encountered

shikigami --help lists no profile command, and the only writers of profile rows are test fixtures. A run of the unmodified manifest would be refused before the review session with an unknown-profile error.

## Workaround

The before and after runs used a copy of the reviewer manifest without its sanctionedProfile field, on both builds, so the comparison still exercised every pack interpreter the unresolved path reaches. The shipped manifest is unchanged.
