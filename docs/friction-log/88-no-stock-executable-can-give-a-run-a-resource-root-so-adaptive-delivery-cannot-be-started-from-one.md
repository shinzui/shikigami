---
type: Friction Entry
title: "No stock executable can give a run a resource root, so adaptive delivery cannot be started from one"
description: "The run API, enqueue-run and every stock trigger enqueue a job with no execution root, and adaptive admission refuses a run without one; only a pack's hook or the Initiative standing policy funds a coordinator."
generated:
  by: "claude-code/claude-fable-5-2"
  at: "2026-11-16T21:27:49Z"
frictionId: FRIC-88
status: logged
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/131-shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems.md"
workaround: "Funded and launched the coordinator through an Initiative standing policy from the kikan-shikigami distribution, the one operator route that enrolls a root for a coordinator. A stock route would be an operator command that admits an objective run under an explicit envelope."
tags:
  - "real-use"
---
# No stock executable can give a run a resource root, so adaptive delivery cannot be started from one

## Attempted

Plan 131 M6's acceptance: run agents/proof/adaptive-delivery.dhall against an objective with the stock shikigami-worker, as docs/user/adaptive-delivery.md describes.

## Encountered

docs/user/adaptive-delivery.md says the run must carry its admitted resource root, and docs/operations/recurring-objectives.md asks for an already admitted root, but shikigami resources offers only inspect, enqueue-run and the HTTP run API set executionRootId to Nothing, and Shikigami.Coordination.Runtime.admit answers ObjectiveDenied when origin.rootId is Nothing. enrollRootRun is called only by the local one-off command. The proof manifest also lists opentelemetry-practice-reviewer as a delegate, a use case the stock worker no longer has.

## Workaround

Funded and launched the coordinator through an Initiative standing policy from the kikan-shikigami distribution, the one operator route that enrolls a root for a coordinator. A stock route would be an operator command that admits an objective run under an explicit envelope.
