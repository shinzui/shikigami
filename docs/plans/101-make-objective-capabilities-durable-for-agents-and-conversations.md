---
id: 101
slug: make-objective-capabilities-durable-for-agents-and-conversations
title: "Make objective capabilities durable for agents and conversations"
kind: exec-plan
created_at: 2026-10-29T00:19:50Z
intention: "intention_01m62265gjex4a0k54gsbwx4gs"
master_plan: "docs/masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-29T00:19:50Z
---

# Make objective capabilities durable for agents and conversations

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

After this plan, a durable Skill run, a compiled Flow and a Danwa conversation turn can read an objective and record progress, evidence, next actions and completion proposals through a native `objectives` tool or a typed Flow effect whose authority and operation identity come from the runtime, never from model arguments. A crash after an objective command commits but before the tool result is recorded resumes to the same operation, receipt, evidence and revision. A later run and a later conversation turn read current progress with memory recall disabled. Journals written before this change replay under the new code without consulting objective policy or acquiring tools. The observable result is `ObjectiveWorkflowSpec` and the workflow-versioning deployment cases passing with a scripted model transport against real execution and objective stores. This is EP-4 of [MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md).


## Progress

- [ ] Milestone 1: the native `objectives` tool in `Shikigami.Objective.Tools` and the Flow effect and interpreter in `Shikigami.Flow.Objectives` expose a closed command surface with journaled bounded replies and runtime-derived operation identity; their unit tests pass.
- [ ] Milestone 2: durable Skills, objective-aware Flows and conversation turns admit the tool only under trusted association and operator policy, with a patch guard declared only where a new journaled step is unavoidable; `just keiro-gate` reports the change as additive and old-shape journals replay unchanged.
- [ ] Milestone 3: `ObjectiveWorkflowSpec` crash, revocation, later-run and replay cases and the `WorkflowVersioningSpec` deployment cases pass through the real model-tool and Flow paths.

Planning baseline `3900c0e634d9b559e92a6989bb10f9943e0beab1`, inspected 2026-10-28. No implementation or test results are claimed. Hard prerequisites: plans 98 and 99 Complete.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Declare a workflow patch only where a new journaled step or a straddling shape change is unavoidable. `shikigami-objective-tracking-v1` (agent runs) and `shikigami-conversation-objective-tracking-v1` (conversations) are reserved names, not commitments to declare both.
  Rationale: A coordinator run derives objective authority from the retained coordination scope that the existing `shikigami-worker-coordination-v1` branch already journals in `worker-coordination-policy`, and its native tool can join the existing coordination tool factory without a body change; only worker-child and conversation admission that must freeze an objective binding can need a new step.
  Date: 2026-10-28

- Decision: Authority fields and operation keys are absent from model arguments; the tool binding carries its immutable contract revision and retained objective scope fingerprint, and preparation receives the accepted `OperationContext.operationId`.
  Rationale: ADR 0025 and ADR 0066: a tool name or a model-supplied identity confers no authority, and a descriptor label is not deduplication. The existing worker tool in `WorkerSession/Tools.hs` already follows this shape.
  Date: 2026-10-28


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

An objective is a goal spanning executions, with assignments, revisions, members and receipts; plan 98 defines it under `shikigami-core/src/Shikigami/Objective/` and owns authenticated command admission in `Objective/Capability.hs`, which every adapter here calls. Plan 99 adds `Objective/Association.hs` (the trusted run and conversation association committed with run acceptance), `Objective/Coordination.hs` (the retained coordination scope behind `CoordinationAuthority{admit,reacquire}`) and the operator objective-tracking enablement setting in `shikigami-core/src/Shikigami/App/Config.hs`. A workflow journal records the steps of one durable execution; a generation is one admission of a workflow body; a patch guard is a declared branch in a workflow body that old journals never enter. An operation key identifies one immutable command across retries and a receipt its committed result.

`shikigami-core/src/Shikigami/WorkerSession/Tools.hs` demonstrates a native tool whose preparation receives the accepted `OperationContext`; its description cannot execute anything, and its backend is an idempotent local effect with no provider invoice. `shikigami-core/src/Shikigami/Flow/Workers.hs` demonstrates the corresponding journaled Flow interpreter under caller-supplied static labels. `shikigami-core/src/Shikigami/Capability/Catalog.hs` keeps general capability overlays observation-only for durable runs; this plan does not change that policy. `shikigami-core/src/Shikigami/Agent/Workflow.hs` owns the agent-run lifecycle and `shikigami-core/src/Shikigami/Agent/Conversation.hs` the conversation lifecycle, with atomic assistant and reply ownership; `shikigami-core/src/Shikigami/Flow.hs` composes Flow effects; `shikigami-core/src/Shikigami/Workflow/Versioning.hs` unions patch sets and `shikigami-core/src/Shikigami/Workflow/Registry.hs` registers bodies. `domain/shikigami-agent-run.keiro` already declares `patch shikigami-worker-coordination-v1`, which journals the `worker-coordination-policy` step; `domain/shikigami-conversation.keiro` declares the conversation body. Generated code under `shikigami-core/src/Shikigami/Generated/` is never hand-edited.

Any change to a workflow body under `shikigami-core/src/Shikigami/Agent/` or `shikigami-core/src/Shikigami/Flow/` must follow [docs/workflow-versioning.md](../workflow-versioning.md): a kept step never changes the type it decodes into, a declared body only grows behind a patch with a real old branch, labels are static, unbounded iteration rotates with `continueAsNew` after restoring a seed, and the pre-v1 reset exception is not used here. `just keiro-gate` enforces this against a baseline and `shikigami-core/test-postgres/Shikigami/WorkflowVersioningSpec.hs` holds the deployment cases.

Relevant decisions: [ADR 0011](../adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md) for additive defaulted fields; [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) for patch branches; [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md) for replay-safe Flow effects with stable write identities and no raw store access; [ADR 0017](../adr/0017-rotate-to-make-a-label-static-rather-than-computing-it.md) against computed labels; [ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) for observation-only overlays and descriptor labels; [ADR 0057](../adr/0057-skill-parents-admit-frozen-assignments-and-await-execution-children.md) for frozen tool bindings and accepted operation context; [ADR 0058](../adr/0058-conversation-acceptance-and-wakes-retain-their-generation.md) for conversation turns owning their admission and generation; [ADR 0066](../adr/0066-worker-commands-require-retained-scopes-and-fresh-exact-authority.md) for retained scopes and fresh exact authority through `authorizeExact` over `InvokeCapabilityTool` from `mori://shinzui/kikan-en`.


## Plan of Work

### Milestone 1 — The native tool and the Flow effect

Create `shikigami-core/src/Shikigami/Objective/Tools.hs` and `shikigami-core/src/Shikigami/Flow/Objectives.hs`. The native tool is a closed `objectives` command surface for authorized create, inspect, assignment progress, evidence, next action and completion proposals over plan 98's command sum. Authority fields and operation keys are absent from model arguments; the adapter injects the operation key and trusted actor. The tool binding includes its immutable contract revision and retained objective scope fingerprint. Preparation receives the accepted `OperationContext.operationId`; description invokes no command. The backend is an idempotent local effect with no provider invoice. Agent operations also pass the existing exact `InvokeCapabilityTool` action authorizer, binding objective and scope revision and the full command digest, in addition to objective membership and current principal lifecycle. No generic overlay mutation policy changes.

The Flow effect exposes typed reads and commands under caller-supplied static labels. Its interpreter journals bounded replies and derives operation identity from workflow ID, generation and label, or consumes a retained domain operation reference for cross-generation work. It grants no `IOE` or raw store access to Flow bodies. Read results are journaled within one decision; a later decision or generation rereads current authoritative state before new work, and a historical checkpoint snapshot never overwrites new instructions or owner state. Completion still requires the explicit completer grant and plan 98's evidence validation even when the tool is present. Register concrete objective Flow labels in the checked specification. Milestone 1 is accepted when the tool and interpreter unit tests pass and the checked specification test accepts the new labels.

### Milestone 2 — Admission for Skills, Flows and conversations

Extend `shikigami-core/src/Shikigami/Agent/Workflow.hs`, `shikigami-core/src/Shikigami/Agent/Conversation.hs`, `shikigami-core/src/Shikigami/Flow.hs` and runtime dependency construction. Admit objective tools for eligible durable Skills and objective-aware Flows only when the trusted association from plan 99 and the operator policy permit them. A conversation uses its own recorded turn identity, objective association and accepted operation coordinates, never a borrowed agent-run journal, and keeps the existing atomic assistant and reply ownership. Unsupported legacy coarse behavior and database-free one-off paths refuse requested objective mutation clearly; they do not fall back to an unsafe tool loop. The user can still use the authenticated objective API from plan 100 without running a local agent.

Before changing a body, establish whether a new journaled step is needed at all. A coordinator run derives objective authority from the retained coordination scope that the `shikigami-worker-coordination-v1` branch already journals, and its native tool joins the existing coordination tool factory without a body change. Where a new step is unavoidable, such as a conversation turn or a worker child whose admission must freeze an objective binding, declare a real guard in the owning `domain/` member, named `shikigami-objective-tracking-v1` for agent runs or `shikigami-conversation-objective-tracking-v1` for conversations, retain the complete old branch and codecs, and put the policy-resolution step only behind the new branch so old runs never consult objective policy or acquire tools. Never change the type a kept step decodes into; an additive defaulted field follows ADR 0011. Freeze each accepted execution's bindings and scope before dispatch. Regenerate artifacts and union patch sets through `Workflow/Versioning.hs`. If unbounded objective iteration is introduced, restore a seed first and rotate with `continueAsNew`; no dynamic label counters. Milestone 2 is accepted when `just keiro-gate` against the baseline reports only additive, declared changes and the existing journal fixtures replay with no objective policy call on their old branches.

### Milestone 3 — Replay, crash and revocation proof

Add `shikigami-core/test-postgres/Shikigami/ObjectiveWorkflowSpec.hs` and deployment cases to `shikigami-core/test-postgres/Shikigami/WorkflowVersioningSpec.hs`. With a scripted model transport and real execution and objective stores: crash after an objective command commits but before its tool result is recorded, resume, and verify the same operation, receipt, evidence and objective revision; revoke objective membership between admission and dispatch and verify no new write; start a later run and a later conversation turn with memory recall disabled and verify they read current progress; inject unavailable objective authority and verify refusal before model or tool dispatch where admission requires it; replay old-shape agent and conversation journals and verify their original behavior; verify an accepted execution retains its original tool binding while fresh commands still respect revocation and version changes. Milestone 3 is accepted when those cases pass through the actual model-tool and Flow paths, not through a direct store call.


## Concrete Steps

Run commands from the repository root, `/Users/shinzui/Keikaku/bokuno/shikigami`, inside `nix develop --no-write-lock-file` if needed. Capture `git rev-parse HEAD` as the implementation baseline and confirm the build and the inherited suites:

```bash
cabal build all
cabal test shikigami-core-postgres-test --test-show-details=direct --test-options='--num-threads=1'
```

If the checked-in project cannot resolve its co-developed dependencies, follow `docs/dependency-cohort.md` and plan 98's local-project convention consistently and record it in evidence. After any `domain/` change, regenerate and check isolation:

```bash
cabal run -v0 keiro-dsl -- scaffold domain/shikigami.keiro-workspace --out shikigami-core/src
just migration-schema-isolation
```

Run focused checks while implementing and the affected suites at each boundary:

```bash
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-agent-test shikigami-workers-test --test-show-details=direct --test-options='--num-threads=1'
```

At a coherent commit, run the gate against the saved baseline and check whitespace:

```bash
just keiro-gate IMPLEMENTATION_BASELINE
git diff --check
```

`keiro-scaffold` inside the gate compares `shikigami-core/src` against the committed candidate, so commit the intended source and generated changes before using it as final evidence. The report must show each declared guard with a real old branch and no unexplained breaking findings; do not weaken the gate or hide a declared step. Every commit follows Conventional Commits and ends with:

```text
MasterPlan: docs/masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md
ExecPlan: docs/plans/101-make-objective-capabilities-durable-for-agents-and-conversations.md
Intention: intention_01m62265gjex4a0k54gsbwx4gs
```


## Validation and Acceptance

End-to-end replay through real durable execution and conversation admission: with memory recall disabled in the fixture, a second run and a conversation still obtain the exact current objective revision and evidence. A crash after tool commit followed by a retry returns the accepted operation. A historical journal restored under new code shows no added objective policy call on its old branch. Unavailable objective authority is refused before model or tool dispatch where admission requires it. An accepted execution retains its original tool binding while fresh commands respect revocation and version changes. Required acceptance is the passing `ObjectiveWorkflowSpec`, the `WorkflowVersioningSpec` deployment cases, the agent and worker suites and an additive gate report. Record actual passing counts only after running them.


## Idempotence and Recovery

Roll forward after introducing a patch or a durable enum value; never remove a declared branch. Disable new objective admissions if necessary while retaining readers and reconciliation for accepted operations; disabling must not select an older unsafe mutation path or drop associations. A retried tool call with the same accepted operation returns the original receipt. Regenerating the scaffold is safe; redeclaring a patch id is not, because old journals must keep meeting the same guard.


## Interfaces and Dependencies

Hard prerequisites: plan 98 Complete (`Shikigami.Objective.Capability` and the command sum) and plan 99 Complete (`Shikigami.Objective.Association`, `Shikigami.Objective.Coordination` and the enablement setting). `Shikigami.Objective.Tools` owns the native tool; `Shikigami.Flow.Objectives` owns the Flow effect and interpreter; both are adapters over `Shikigami.Objective.Capability`. This plan owns the reserved patch ids `shikigami-objective-tracking-v1` and `shikigami-conversation-objective-tracking-v1` and declares them only where unavoidable. Plan 102 drives the tool path from its fixture; plan 85's coordinator Flow later consumes the Flow effect. Dependencies and cohort are unchanged: `mori://shinzui/keiro` for workflow bodies and patches, `mori://shinzui/kikan-en` for the exact action contract.
