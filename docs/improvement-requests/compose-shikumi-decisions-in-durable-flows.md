---
type: Improvement Request
title: Compose Shikumi decisions in durable Flows with per-step model selection
description: Let compiled Flows invoke registered typed Shikumi programs at named, replay-safe decision steps and select an authorized model for each invocation.
timestamp: "2026-09-26T18:23:02Z"
generated:
  by: process:codex
  at: "2026-09-26T18:23:02Z"
requestId: IR-12
status: proposed
origin: mori://shinzui/shikigami
---

# Improvement Request: compose Shikumi decisions in durable Flows with per-step model selection

## Status

**Proposed.** No accepted ExecPlan covers this request. The completed declarative-router work
provides one journaled model decision and governed delegation, but does not let a Flow run a
registered Shikumi program at each decision point or choose a model for each such invocation.

## Context

Shikigami has two useful but separate behavior paths. A `ShikumiProgram` runs a registered typed
program through Handan and returns one result. A compiled Haskell `Flow` owns durable control flow:
it can journal steps, branch, wait, resume, and delegate. Its routing capability currently evaluates
one dedicated prompt with the active `BehaviorEnv` model. `FlowEffects` has no general Shikumi
program capability, and the agent declaration has no per-step model choice. A workflow that needs a
cheap model to triage, a stronger model to investigate, and a typed Shikumi decision to choose the
next branch cannot express those calls as independently journaled, governed Flow steps.

The completed [declarative-router request](add-declarative-router-agents.md) and
[MasterPlan 8](../masterplans/8-declarative-router-agents.md) establish the catalog, validation,
and delegation boundary for specialist routing. The in-progress
[sanctioned-execution request](attest-sanctioned-agent-execution.md) establishes profile pinning
and call evidence, including mixed-model runs. This request composes those capabilities; it does
not replace their authority or evidence contracts.

## Requested Change

1. Add a replay-safe Flow capability for invoking a registered, typed Shikumi program at a
   statically named decision step. The flow supplies typed or validated input and receives a
   validated result on which Haskell control flow can branch. The interpreter, rather than the
   flow body, owns model IO and the Keiro journal boundary. An unknown program or incompatible
   input/output contract fails with a bounded diagnostic.
2. Let each invocation name or derive a model choice from an operator-owned catalog and the
   agent's resolved, pinned execution policy. A flow may choose among models that policy permits,
   including based on an earlier journaled decision. Neither inbound payload nor model output
   grants access to an undeclared provider, model, credential, or thinking mode. A denied or
   unavailable choice fails before provider dispatch.
3. Record the step's stable identity, program/version identity, effective model-call tuple,
   validated decision, and any inputs needed for deterministic replay under the workflow's
   versioning rules. On resume, a completed decision reuses the journaled result without rerunning
   Shikumi or selecting a different model. A changed program, model catalog, or deployment policy
   must not silently reinterpret an in-flight step.
4. Preserve call-level evidence for every actual provider call, including calls inside a
   multi-node Shikumi program, and associate it with the parent run and decision step. Apply the
   pinned sanctioned profile and existing limits to the effective call tuple. The final run
   evidence must identify mixed-model execution accurately.
5. Keep branch authority in the Flow. Validate Shikumi output against its declared result schema
   and any domain-specific policy before a branch triggers delegation, a sink, memory write, or
   other protected effect. Reuse the completed router's catalog and decision validator when the
   result selects specialist agents.
6. Provide an authoring example and documentation for a multi-step Flow: triage with one model,
   branch on the typed decision, investigate with another permitted model, and return or delegate
   based on a second typed decision. State how step names and program/result changes follow
   [workflow versioning](../workflow-versioning.md).

## Acceptance

1. A registered Flow runs two distinct Shikumi decision steps using two different permitted model
   ids. The first typed result selects which later step runs; the resulting journal and run evidence
   identify each executed step, program, and effective model.
2. Replaying the same workflow id after changing the configured default model, available program
   implementation, or model response yields the original branches and results without new model
   calls or duplicate child runs and sinks.
3. A program result that fails decoding or domain validation cannot authorize the next effect.
   An undeclared or profile-forbidden model is rejected before a provider call. Both failures have
   bounded, inspectable run outcomes.
4. A sanctioned profile allowing both models admits the example and records both call identities.
   A profile allowing only one rejects the other step. Actual multi-node calls remain individually
   visible to the run-evidence roll-up.
5. Crash and resume between the two decisions reuses the first result, executes the pending second
   decision once, and preserves the same final outcome as an uninterrupted run.
6. The checked workflow declaration and evolution gate cover every new durable step name and any
   necessary patch or rotation for existing journals.

## Scope boundary

This request selects a model per **Flow decision invocation**. It does not require a different
model for each internal node of one Shikumi program, arbitrary model ids in Dhall or payloads,
or a visual workflow editor. An implementation may add finer-grained Shikumi model routing
later, provided it preserves the same pinned policy and per-call evidence boundary.

## Dependencies

- [IR-3](add-declarative-router-agents.md) supplies validated, replay-safe specialist routing
  and governed delegation when a decision selects a child agent.
- [IR-7](attest-sanctioned-agent-execution.md) supplies pinned execution profiles and call-level
  evidence for runs that use multiple models. Its remaining signing/read-API work is separate
  from executing the decision steps.
- `mori://shinzui/shikumi` supplies typed programs and ambient model routing;
  `mori://shinzui/handan` supplies the current registered-task execution path. Planning must
  verify their released APIs and decide whether the Flow capability can use the existing runner
  or needs an upstream extension.
