---
type: Friction Entry
title: "Queue payload additions have no optional compatibility policy"
description: "The queue generator requires every new field and rejects omission defaults, so resource metadata needs a versioned application codec."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-28T03:59:09Z"
frictionId: FRIC-9
status: "accepted"
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/keiro/packages/keiro-dsl"
affectedVersion: "0.18.0.0"
plan: "docs/plans/81-enforce-root-resource-reservations-across-durable-work.md"
workaround: "Keep the generated structural fields; use the public Keiro.Codec version/upcaster API to wrap the opaque triggerPayload in v2 and retain the literal v1 decoder path."
resolution: "The public versioned application codec preserves the generated structural payload, retains literal v1 input semantics and carries root metadata in v2."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-28T04:11:36Z"
    change: "Accept the versioned codec solution and document the worker-before-producer rollout in ADR 0051."
---
# Queue payload additions have no optional compatibility policy

## Attempted

Add optional executionRootId to the generated run queue without invalidating retained v1 messages.

## Encountered

The workqueue parser supports required fields only; its diff classifies every payload field addition as breaking. This remains true in the Mori checkout at the released 0.22 cohort.

## Workaround

Keep the generated structural fields; use the public Keiro.Codec version/upcaster API to wrap the opaque triggerPayload in v2 and retain the literal v1 decoder path.
