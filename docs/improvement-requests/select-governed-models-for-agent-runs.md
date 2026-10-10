---
type: Improvement Request
title: Select governed models and reasoning settings for agent runs
description: Resolve and pin operator-approved provider, model, and reasoning choices per agent or delegated assignment so coordinators and workers can use different execution settings within shared authority.
timestamp: "2026-10-10T23:44:58Z"
generated:
  by: process:codex
  at: "2026-10-10T23:44:58Z"
requestId: IR-17
status: proposed
origin: mori://shinzui/shikigami
---

# Select governed models and reasoning settings for agent runs

## Status

**Proposed; implementation planned but not started.** [MasterPlan 14](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md) assigns
whole-assignment execution selection to [plan 82](../plans/82-pin-governed-execution-settings-for-agent-assignments.md), with durable-turn and
continuing-session integration in [plan 83](../plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md) and [plan 84](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md).
[plan 85](../plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md) owns the real typed-Flow decision-permission regression, and
[plan 86](../plans/86-qualify-integrated-adaptive-autonomous-delivery.md) qualifies distinct permitted settings in integrated delivery.
The existing plan 73 catalog remains a prerequisite. This supplies role-appropriate
execution for [UC-1](../use-cases/adaptive-autonomous-delivery.md), without prescribing
particular models or a permanent coordinator/worker pairing.

## Problem and existing plan coverage

The current [BehaviorEnv](../../shikigami-core/src/Shikigami/Behavior/Run.hs) has one
process-selected model and options. A sanctioned profile constrains that tuple but does
not select a different model for each declared agent or delegated assignment. The
[agent schema](../../schema/Agent.dhall) has no such execution selection.

[IR-12](compose-shikumi-decisions-in-durable-flows.md) and its unimplemented
[plans 73–76](../masterplans/13-compose-shikumi-decisions-in-durable-flows.md) select models
for typed Flow decision invocations. They explicitly stop at that boundary; an entire
Skill worker loop and its delegated run are not decision invocations. Reuse their model
catalog and governed dispatch contracts where suitable, rather than broadening those
plans silently or duplicating provider configuration.

[Plan 80](../plans/80-configure-model-providers-and-agent-launches-through-baikai.md)
delivered HTTP options and foreground launch configuration. Background CLI response
adapters remain blocked on released cancellation-safe lifecycle support. Foreground
named jobs may have different settings, but their process results are not durable agent
runs. This request can start with HTTP providers; CLI transport is optional.

## Requested change

1. Let a declaration request operator-defined execution aliases/defaults for its behavior.
   Let a delegated assignment choose or propose an alias within the target agent's admitted
   choices and the parent's authority. Resolve both through an operator-owned catalog;
   inbound data cannot supply arbitrary model ids, credentials, endpoints, or vendor flags.
2. Resolve and journal the complete non-secret effective execution descriptor before the
   first model call: provider/API, endpoint class, model, reasoning preference, compatible
   options, immutable binding/version identities, and applicable policy. Credentials stay
   behind opaque live bindings. Preserve explicit user model preferences, and reject
   unsupported options or unavailable choices rather than silently substituting models.
3. Define policy intersection and precedence among user requirements, operator ceilings,
   target declaration, parent delegation, sanctioned profiles, and harness limits. A child
   can narrow these constraints, not broaden them. A per-run model setting cannot bypass
   exact per-action authorization or shared resource accounting.
4. Keep admitted settings fixed for an active run/turn according to the selected durable
   boundary. A coordinator may request a different permitted configuration for later work
   or an explicit escalation; record that new choice and its rationale. Do not mutate a
   committed call or reset worker context, consumed budget, or authority through escalation.
5. Dispatch the effective tuple through the shared compatible provider builder and validate
   it immediately before each call. Record requested/configured identities separately from
   provider-reported identities and attach actual call evidence to the run and assignment.
   Pending work must use its pinned binding or fail clearly if unavailable after restart.
6. Define compatible defaults for historical declarations and journals. Expose selected
   settings and refusal reasons to operators without credential leakage. Document how
   run-level selection composes with separately pinned IR-12 decision slots.

## Acceptance

1. In one configured deployment, a coordinator and two workers use distinct permitted
   model/reasoning aliases. Provider fixtures and stored evidence establish each effective
   tuple, rather than merely recording aliases in model-authored prose.
2. A hard diagnosis triggers an explicitly permitted escalation for subsequent work.
   Earlier results, relevant context, lineage, and root budget usage remain intact.
3. Change the process default and catalog while work is suspended. Completed calls replay
   without dispatch; pending work retains its admitted tuple or reports an unavailable
   pinned binding. A fresh assignment may adopt the new approved configuration.
4. A forbidden alias, cross-provider option, unsupported reasoning value, profile conflict,
   or parent/user restriction fails before a model call. No fallback occurs.
5. Historical declarations retain their documented default behavior. A Flow using an
   IR-12 decision alias respects its decision policy independently of unused run defaults.
6. Actual provider usage settles the shared budget, and a missing usage report remains
   explicitly unknown. Choosing a faster model or new worker does not restore allowances.

## Dependencies and scope

Build on [sanctioned profiles](../capabilities/sanctioned-execution-profiles.md),
[run evidence](../capabilities/run-evidence-and-compliance.md), and
[provider compatibility](../operations/baikai-execution.md). Remaining signing/read-API
work in [IR-7](attest-sanctioned-agent-execution.md) is not a prerequisite for selecting
and enforcing an execution tuple.

Coordinate catalog ownership with [IR-12](compose-shikumi-decisions-in-durable-flows.md),
turn/configuration pinning with [IR-14](record-durable-model-tool-turns-and-compose-harness-policies.md),
and shared limits with [IR-16](support-adaptive-durable-orchestration.md). No cross-runtime
A2A protocol, automatic choice of a supposedly best model, new provider implementation,
or background CLI workaround is required. Workflow changes follow
[workflow versioning](../workflow-versioning.md).
