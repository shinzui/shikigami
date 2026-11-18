---
type: Friction Entry
title: "Several shikigami-local verbs refuse --help"
description: "shikigami-local run, new, revoke, tools, mcp and playbook answer --help with \"Invalid option `--help'\" and exit 2, and approvals --help prints the top-level usage instead of its subcommands."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-18T03:23:58Z"
frictionId: FRIC-117
status: logged
impact: nuisance
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md"
workaround: "Pinned the usage text these verbs print with the refusal; the surface stays provisional."
tags:
  - "cli"
  - "local-operator"
---
# Several shikigami-local verbs refuse --help

## Attempted

Read each verb's help to register the cli-shikigami-local surface (EP-11 M2).

## Encountered

shikigami-local run --help: Invalid option `--help'. shikigami-local playbook --help: Invalid option `--help' (Usage: shikigami-local playbook COMMAND). shikigami-local approvals --help: Usage: shikigami-local (COMMAND | COMMAND) …

## Workaround

Pinned the usage text these verbs print with the refusal; the surface stays provisional.
