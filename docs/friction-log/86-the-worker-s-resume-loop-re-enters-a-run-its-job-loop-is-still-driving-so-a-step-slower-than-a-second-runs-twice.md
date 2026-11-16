---
type: Friction Entry
title: "The worker's resume loop re-enters a run its job loop is still driving, so a step slower than a second runs twice"
description: "A worker's first drive of a run held no keiro instance lease, so its own resume loop claimed the running instance and executed the in-flight step again; a real proposing run was failed by its duplicate."
generated:
  by: "claude-code/claude-fable-5-2"
  at: "2026-11-16T19:10:36Z"
frictionId: FRIC-86
status: logged
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/131-shrink-shikigami-core-to-the-kernel-by-moving-or-retiring-use-case-subsystems.md"
workaround: "Shikigami.Workflow.Versioning.runWorkflowLeased claims the instance lease the resume worker claims, renews it at each fresh step and releases it on return; the worker's job path uses it through runAgentRunWorkflowLeased. WorkflowVersioningSpec shows the unleased hazard and the leased exclusion. The conversation workflow's direct drive (runConversationWorkflow) is still unleased, and a single step longer than the lease (run timeout plus thirty seconds) can still lose it."
tags:
  - "durable-workflows"
  - "real-use"
---
# The worker's resume loop re-enters a run its job loop is still driving, so a step slower than a second runs twice

## Attempted

The plan 131 M4 acceptance: kikan-shikigami-consume-stream and kikan-shikigami-worker on an isolated database, one meeting transcript published to Kafka, the proposing flow's assessment made by a real model (about three seconds).

## Encountered

flow.selected was logged twice for the run, one second apart. The second execution replayed to the decision step while the first was waiting on the provider, was refused, wrote fail-session and __workflow_completed__, and the instance went completed. The first execution then journaled the proposal and parked on an approval that could never resume it: the approval resolved, the child result was recorded, and the proposal stayed pending. The same double flow.selected is in the M3 worker logs from before the change, on the stock worker, where it was survivable and showed up only as twice the provider calls. keiro's direct runWorkflowWith takes no lease by design and resume discovery returns every running instance without one; the fixtures never see it because a scripted model answers in under the one-second resume poll.

```text
47:12.431 decision-prepare-initiative-propose
47:13.402 fail-session
47:13.403 __workflow_completed__
47:15.191 decision-result-initiative-propose
47:15.194 initiative-proposal
47:15.196 child:review_...
50:13.735 child:review_...:result   (proposal still pending, instance completed)
```

## Workaround

Shikigami.Workflow.Versioning.runWorkflowLeased claims the instance lease the resume worker claims, renews it at each fresh step and releases it on return; the worker's job path uses it through runAgentRunWorkflowLeased. WorkflowVersioningSpec shows the unleased hazard and the leased exclusion. The conversation workflow's direct drive (runConversationWorkflow) is still unleased, and a single step longer than the lease (run timeout plus thirty seconds) can still lose it.
