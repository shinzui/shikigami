---
type: Friction Entry
title: "keiro-gate reports the generated layer stale whenever shikigami-core/src has uncommitted edits"
description: "keiro-scaffold checks git diff --exit-code over all of shikigami-core/src, so just api-baseline reports durable-wire BREAKING for any uncommitted core change."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T23:54:59Z"
frictionId: FRIC-109
status: logged
impact: nuisance
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/132-modernize-the-keiro-services-with-a-declared-campaign-playbook.md"
workaround: "Committed, then reran just api-baseline: all 14 surfaces clean."
tags:
  - "api-baseline"
  - "keiro-gate"
---
# keiro-gate reports the generated layer stale whenever shikigami-core/src has uncommitted edits

## Attempted

Run just api-baseline before committing the ADR-132 change.

## Encountered

durable-wire (provisional): BREAKING / keiro-scaffold: the committed generated layer is out of date; commit the regeneration. No generated file had changed; the diff was the uncommitted Capacity, Executor and Store edits.

## Workaround

Committed, then reran just api-baseline: all 14 surfaces clean.
