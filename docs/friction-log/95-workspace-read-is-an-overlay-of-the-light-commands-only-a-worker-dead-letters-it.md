---
type: Friction Entry
title: "workspace.read is an overlay of the light commands only; a worker dead-letters it"
description: "A worker's capability runtime holds only its workspace host's workspace.edit/exec/git, so a declaration requesting workspace.read fails permanently under shikigami-worker while it runs under shikigami-agent-run."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-17T04:07:22Z"
frictionId: FRIC-95
status: logged
impact: detour
kind: interface
origin: "mori://shinzui/shikigami"
affects: "mori://shinzui/shikigami"
affectedVersion: "unreleased"
plan: "docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md"
workaround: "The portable declaration names no capability overlay; the README reaches the Skill as the trigger payload in both compositions."
tags:
  - "ep-8"
  - "portability"
---
# workspace.read is an overlay of the light commands only; a worker dead-letters it

## Attempted

shikigami enqueue-run portable-note --workspace mori://shinzui/fsrs-hs against shikigami-worker with authorization.actions.mode=kikan and a workspaces catalog granting the agent the repository.

## Encountered

The job was dead-lettered: worker.job.dead_lettered permanent_workflow_failure UnknownCapability {capability = CapabilityId "workspace.read"}.

## Workaround

The portable declaration names no capability overlay; the README reaches the Skill as the trigger payload in both compositions.
