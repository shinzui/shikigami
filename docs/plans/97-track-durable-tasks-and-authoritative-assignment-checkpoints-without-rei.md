---
id: 97
slug: track-durable-tasks-and-authoritative-assignment-checkpoints-without-rei
title: "Track durable tasks and authoritative assignment checkpoints without Rei"
kind: exec-plan
created_at: 2026-10-28T20:12:06Z
intention: "intention_01m62265gjex4a0k54gsbwx4gs"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-28T20:12:06Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-28T20:39:58Z
      verdict: "changes-requested"
      note: "Verified all cited modules, recipes and ADRs; checkpoint conflict defined on whole task revision would stall sibling UC-1 workers on parent reconciliation; providers sequenced after HTTP surface although plan 84 gate needs only providers; IR-11 owner plan 96 not referenced; two workflow patches pre-committed; IR lifecycle wording contradicts corpus convention"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-28T20:39:58Z
      mode: "update"
      note: "Apply review: assignment-scoped conflict semantics replacing the task-revision tradeoff; providers and associations moved to milestone 2 ahead of API/CLI; plan 96 as IR-11 owner; substrate and process-manager check; A2A Task separation and path reservation; IR-13 lifecycle convention; patch declared only where a new step is unavoidable"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-29T00:33:08Z
      mode: "update"
      note: "Superseded by MasterPlan 17 and child plans 98-102 with the record renamed Objective; body replaced by a superseded notice"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T18:29:22Z
      mode: "update"
      note: "Record supersession as a closed progress item with a successor so incomplete plan lists exclude plan 97."
---

# Track durable tasks and authoritative assignment checkpoints without Rei

**Superseded on 2026-10-28 by [MasterPlan 17: Track durable objectives and authoritative assignment checkpoints without Rei](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md).** No implementation was started under this plan. Its content was redistributed, with the record renamed from `Task` to `Objective`, into five child ExecPlans: [plan 98](98-persist-authoritative-objectives-and-conditional-commands.md) (store and conditional commands), [plan 99](99-supply-trusted-objective-associations-and-the-real-checkpoint-ownership-and-scope-providers.md) (associations and the real providers that close plan 84's IR-13 gate), [plan 100](100-expose-governed-objective-inspection-through-the-api-and-cli.md) (API and CLI), [plan 101](101-make-objective-capabilities-durable-for-agents-and-conversations.md) (durable Skill, Flow and conversation capabilities) and [plan 102](102-qualify-no-rei-objective-continuity-and-close-ir-13.md) (no-Rei qualification and IR-13 closure). Do not implement from this file.


## Purpose / Big Picture

Superseded. The purpose, the two demonstrations and the relationship to MasterPlan 14 and plan 96 are stated in MasterPlan 17's Vision & Scope.


## Progress

- [-] (2026-10-28) Durable task tracking and authoritative assignment checkpoints were re-chartered as Objective tracking under MasterPlan 17 and child plans 98–102 before implementation. {disposition=superseded-by, by=docs/masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md}

No implementation was started under this plan. The closed progress item records its supersession so plan tooling excludes it from unfinished work.


## Surprises & Discoveries

(None.)


## Decision Log

2026-10-28: Superseded by MasterPlan 17. The review of this plan recorded in its provenance found that the work was MasterPlan-scale, that the plan 84 gate closes after the provider milestones rather than after the public API, and that the record should be named `Objective` to match plans 84–87, UC-1, the worker-session code and ADRs 0061–0066 while leaving `Task` to the A2A protocol task of IR-6. The decisions this plan recorded on 2026-10-28 (Shikigami ownership and substrate check, access owner versus assignment owner, one closed command service with a native tool and a replay-safe Flow capability, scope boundary, explicit conflict reconciliation, assignment-scoped conflict, vocabulary and A2A separation, IR-13 lifecycle convention, patches only where unavoidable) were carried into MasterPlan 17's Decision Log and the children's Decision Logs in Objective vocabulary.


## Outcomes & Retrospective

Superseded without implementation. The plan's value was its research baseline and its review, both preserved in MasterPlan 17's Decomposition Strategy and provenance.


## Context and Orientation

Superseded; see MasterPlan 17 and plans 98–102, each of which repeats the context it needs.


## Plan of Work

Superseded; see plans 98–102.


## Concrete Steps

Superseded; see plans 98–102.


## Validation and Acceptance

Superseded; see plans 98–102 and MasterPlan 17's acceptance ownership matrix.


## Idempotence and Recovery

Superseded; see plans 98–102.


## Interfaces and Dependencies

Superseded; see MasterPlan 17's Integration Points.
