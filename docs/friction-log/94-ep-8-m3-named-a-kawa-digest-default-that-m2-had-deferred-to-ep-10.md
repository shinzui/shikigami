---
type: Friction Entry
title: "EP-8 M3 named a kawa.digest default that M2 had deferred to EP-10"
description: "The M3 portability check required a Kikan composition whose default output is kawa.digest, but M2 had decided the Kikan sinks stay off the output registry until EP-10, so the two records could not be equal."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T04:07:20Z"
frictionId: FRIC-94
status: logged
impact: detour
kind: process
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters"
plan: "docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md"
workaround: "The user chose on 2026-11-16 to pull only the kawa.digest output adapter forward (Shikigami.Output.Kikan) and register it as the default through outputs.default=kawa.digest."
tags:
  - "ep-8"
  - "plan-coordination"
---
# EP-8 M3 named a kawa.digest default that M2 had deferred to EP-10

## Attempted

Reading M3's acceptance against the worker composition: shikigami-workers Workers/Config.hs set AgentWorkflow.outputs = emptyOutputRegistry.

## Encountered

A Kikan worker resolved a declaration with no outputs to JournalOnly, so its record would have no emit_output decision while the stock run has one.

## Workaround

The user chose on 2026-11-16 to pull only the kawa.digest output adapter forward (Shikigami.Output.Kikan) and register it as the default through outputs.default=kawa.digest.
