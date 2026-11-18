---
type: Friction Entry
title: "The DhallSchema check evaluated non-agent corpora instead of loading them as the runtime does"
description: "For playbook, approvals and tool-ceiling corpora, api-baseline only evaluated each file, so a Dhall-only field the runtime cannot decode reported CHANGED while every real file stopped loading."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-18T03:48:57Z"
frictionId: FRIC-118
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md"
workaround: "loadCorpusFile now loads bundles with loadBundle, approvals files with loadLocalApprovals (a resolver that maps every identity to the repository root) and ceilings with loadToolCatalog; the same edit is now BREAKING."
tags:
  - "api-baseline"
  - "dhall"
---
# The DhallSchema check evaluated non-agent corpora instead of loading them as the runtime does

## Attempted

EP-11 M2's additive experiment: add a defaulted note field to schema/LocalOperator.dhall's Repository and run just api-baseline.

## Encountered

api-baseline: local-operator-file stable CHANGED. shikigami-local approvals: the approvals file is not valid: Expression doesn't match annotation. The agent schema was already loaded through loadAgent, which is why a Dhall-only field there was correctly BREAKING.

## Workaround

loadCorpusFile now loads bundles with loadBundle, approvals files with loadLocalApprovals (a resolver that maps every identity to the repository root) and ceilings with loadToolCatalog; the same edit is now BREAKING.
