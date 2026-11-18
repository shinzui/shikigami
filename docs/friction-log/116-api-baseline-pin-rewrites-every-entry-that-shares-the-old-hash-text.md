---
type: Friction Entry
title: "api-baseline-pin rewrites every entry that shares the old hash text"
description: "Pinning one DhallSchema surface replaces its old hash wherever that text appears in surfaces.dhall, so new entries registered with the same placeholder hash all receive the last-pinned schema's hash."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-18T03:23:56Z"
frictionId: FRIC-116
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md"
workaround: "Set each entry's hash by hand from the reported current values; all 19 surfaces then checked clean."
tags:
  - "api-baseline"
---
# api-baseline-pin rewrites every entry that shares the old hash text

## Attempted

Register playbook-bundle, local-operator-file, tools-ceiling and local-output-helper with one placeholder hash, then run just api-baseline-pin for each (EP-11 M2).

## Encountered

All four entries ended pinned to sha256:1bd12600…, the hash of schema/outputs/Local.dhall, pinned last; just api-baseline then reported three of them CHANGED.

## Workaround

Set each entry's hash by hand from the reported current values; all 19 surfaces then checked clean.
