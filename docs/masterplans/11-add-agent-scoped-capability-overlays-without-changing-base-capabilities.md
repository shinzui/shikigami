---
id: 11
slug: add-agent-scoped-capability-overlays-without-changing-base-capabilities
title: "Add agent-scoped capability overlays without changing base capabilities"
kind: master-plan
created_at: 2026-08-22T15:11:58Z
intention: "intention_01m0n043cse67vxfj52w29t6zb"
---

# Add agent-scoped capability overlays without changing base capabilities

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

An agent author can opt one agent into an additional, named model-facing capability without
changing the capabilities every Shikigami run already has. The declaration names an overlay;
an operator-owned catalog decides which provider and immutable revision satisfy that name;
policy authorizes the request; and the runtime acquires the selected provider only for the
behavior attempt that uses it. Every successful acquisition returns its release action at the
same boundary, partial acquisition is unwound in reverse order, and a run with an empty overlay
list follows today's code path and sends the same model request it sends now.

The first useful proof is a read-only workspace overlay for one-off repository runs. A
repository agent may request it and receive bounded read, search, and listing tools rooted at
the selected worktree. An otherwise identical agent that does not request it receives no such
tools. Later adapters, notably the MCP work already described by
`docs/plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md`, plug into the same provider
registry rather than adding another declaration field, tool registry, or lifecycle bracket.

This initiative deliberately implements an overlay, not the paper's whole dynamically
reconciled component runtime. Version 1 is limited to additive model-facing tools for `Skill`
behaviors. It does not let an overlay replace Shikigami's `Workflow`, `Memory`, `Sink`,
`Activity`, `Acknowledgement`, provider-selection, profile, session, trigger, or Flow
capabilities; those values never enter the overlay registry. It does not continuously
re-resolve an active run, unload Haskell code, turn conversational data into dependencies,
reverse tool calls that emitted external effects, or grant hostile code a sandbox. `Flow`
continues to reach the world only through its existing replay-safe effect row. Mutating tools
remain outside durable runs until they have their own idempotency and authorization contract.


## Decomposition Strategy

The work is divided at the four boundaries that can fail independently. EP-1 owns durable
names and pure resolution: the Dhall/JSON declaration, the public descriptor, and the
operator catalog. EP-2 owns temporal cleanup and model-tool composition, but no durable
workflow change. EP-3 owns the replay-sensitive step that selects and pins a descriptor for
a durable agent run. EP-4 is a leaf-package adapter and end-to-end proof in the one-off
repository path. This ordering lets the lifecycle machinery and the one-off proof be tested
before any declared Keiro workflow body changes, while EP-3 and EP-4 can proceed in parallel
after the shared contract and runtime exist.

The decomposition follows the repository's established architecture decisions:

* `docs/adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md` puts portable one-off
  functionality in `shikigami-agent` and keeps platform queues and exporters out of that
  package.
* `docs/adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md` establishes the
  run-local pinning pattern: a live request is resolved before dispatch and the complete
  public decision, rather than ambient mutable policy, is retained for the run.
* `docs/adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md` requires the
  new declaration field to default to `[]`, disappear from default JSON, and decode as `[]`
  when absent from an old `lookup-agent` journal value.
* `docs/adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md` and
  `docs/workflow-versioning.md` require EP-3's new step to exist in a new declared patch and a
  real runtime branch.
* `docs/adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md` rules out widening
  `FlowEffects` or smuggling overlay `IO` into a Flow.
* `docs/adr/0015-a-kioku-write-answers-on-two-layers-and-a-journaled-step-keeps-its-bytes.md`
  reinforces the separation between a retryable acquisition failure and a permanent,
  journalable policy refusal.

The main rejected alternative was importing the paper's universal typed capability graph,
fibers, contexts, target views, and continuous reconciler wholesale. Shikigami already has a
durable workflow engine and deliberately fixed Flow effect rows; a second desired-state
orchestrator inside each run would duplicate lifecycle authority and make replay harder to
reason about. A second rejected alternative was implementing MCP first and generalizing its
types afterward. The checked-in MCP and repository-harness plans already want the same tool
registry and bracket, so the generic overlay seam should own them once. No relevant
cross-repository ADR was found through Mori; dependency APIs were instead verified directly
from `mori://shinzui/baikai/packages/baikai` and
`mori://shinzui/shikumi/packages/shikumi-tools`.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Declare agent capability overlay requirements and the operator catalog | `docs/plans/56-declare-agent-capability-overlay-requirements-and-the-operator-catalog.md` | None | None | In Progress |
| EP-2 | Acquire and release overlay leases around one behavior run | `docs/plans/57-acquire-and-release-overlay-leases-around-one-behavior-run.md` | EP-1 | None | Not Started |
| EP-3 | Resolve and pin capability overlays in durable agent runs | `docs/plans/58-resolve-and-pin-capability-overlays-in-durable-agent-runs.md` | EP-1, EP-2 | None | Not Started |
| EP-4 | Adopt capability overlays in the portable one-off repository harness | `docs/plans/59-adopt-capability-overlays-in-the-portable-one-off-repository-harness.md` | EP-1, EP-2 | EP-3 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 is the root. It defines `CapabilityId`, `CapabilityDescriptor`,
`ResolvedCapabilitySet`, the defaulted `AgentDecl.capabilityOverlays` field, and the pure
resolution/refusal vocabulary used everywhere else.

EP-2 depends on EP-1 because provider factories must advertise exactly those descriptors and
because a lease is acquired for a resolved `(capability, revision)` rather than for an
unvalidated string. It supplies `CapabilityProviderRegistry`, `CapabilityLease`, collision-
rejecting tool composition, and the derived per-run `BehaviorEnv` consumed by both later
plans.

EP-3 depends on EP-1 and EP-2. Its journal step serializes EP-1's complete resolution and its
behavior attempt acquires EP-2's exact provider revision. Without both, the workflow could
either journal a live handle or resolve ambient state again during replay, neither of which
is acceptable.

EP-4 also depends on EP-1 and EP-2 but not on EP-3: the database-free one-off command resolves
against the current invocation and has no Keiro journal to pin. EP-3 is a soft dependency
because sharing its diagnostics and policy examples is useful, but EP-4 may be completed and
demonstrated while the durable workflow work is still in review. Once EP-2 is complete, EP-3
and EP-4 may proceed in parallel.


## Integration Points

1. **Declaration and public descriptor.** EP-1 owns
   `Shikigami.Capability.Overlay` and `Shikigami.Capability.Catalog`, including the JSON wire
   shape used by EP-3. EP-2 and EP-4 import these types; they must not declare adapter-local
   capability identifiers or a second resolution result. The overlay/base separation and
   declaration-as-request rule should become a local ADR during EP-1.

2. **Provider registry and lease.** EP-2 owns
   `Shikigami.Capability.Provider`. A provider is registered under an immutable descriptor
   and returns model tools plus a release action. EP-3 supplies the resolved snapshot and
   EP-4 supplies the workspace provider. An MCP adapter later supplies another provider
   through this interface.

3. **One model-facing tool registry.** EP-2 adds the released
   `mori://shinzui/shikumi/packages/shikumi-tools` registry to `BehaviorEnv`, keeps an empty
   registry on every existing constructor, and composes overlays into a derived environment.
   EP-4 may add tools only through that seam. The generic registry and tool loop portions of
   `docs/plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md` and
   `docs/plans/48-add-a-portable-one-off-repository-agent-harness.md` are superseded by EP-2;
   those plans retain ownership of MCP transport/authorization and the full writable
   repository harness respectively.

4. **Durable resolution step.** EP-3 alone edits
   `domain/shikigami-agent-run.keiro`, generated conformance expectations,
   `Shikigami.Agent.Workflow`, and `Shikigami.Workflow.Versioning`. The step journals a
   public descriptor snapshot, never a lease id, open connection, function, secret, or
   credential value. EP-3 must create the patch in the domain source and regenerate; no
   other child may hand-edit generated modules.

5. **Failure classification.** EP-1 owns permanent resolution errors such as unknown,
   duplicate, denied, or behavior-incompatible capabilities. EP-2 owns transient acquisition
   and aggregate release failures. EP-3 maps only the former into a journaled terminal result;
   acquisition faults escape the behavior step so Keiro may retry. Tool invocation is not an
   inverse: durable execution admits observation-only tools in this initiative.

6. **Package boundary.** EP-1 through EP-3 live in `shikigami-core`; EP-4's workspace
   provider and CLI wiring live in `shikigami-agent`. EP-4 must not add queue, Kafka, server,
   or telemetry-export dependencies to the leaf package.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-1: Add the defaulted declaration field and byte-compatibility fixtures.
- [ ] EP-1: Add pure catalog resolution, authorization, descriptor pinning, and validation.
- [ ] EP-2: Add provider/lease acquisition with partial rollback and collision rejection.
- [ ] EP-2: Run `Skill` behaviors through one bounded tool loop while preserving the empty path.
- [ ] EP-3: Declare, scaffold, and runtime-gate the durable resolution step.
- [ ] EP-3: Prove fresh-run pinning, old-run compatibility, exact-version retries, and cleanup.
- [ ] EP-4: Supply a confined read-only workspace provider in `shikigami-agent`.
- [ ] EP-4: Prove agent-specific opt-in through the database-free one-off command and reconcile
      the older MCP/repository plan assumptions.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Baikai 0.5.0.0 already exposes `runToolLoop`/`runToolLoopWith`, and the current Shikumi
  0.3.0.2 release family includes `shikumi-tools` 0.3.0.2 with a heterogeneous
  `ToolRegistry`. The initiative therefore needs lifecycle and policy composition, not a new
  tool protocol. Evidence: `mori://shinzui/baikai/packages/baikai`,
  `mori://shinzui/shikumi/packages/shikumi-tools`, and the upstream release tags
  `baikai-0.5.0.0` / `shikumi-tools-0.3.0.2`.
- `AgentDecl` itself is journaled by the existing `lookup-agent` step. The overlay request
  field therefore has a wire-compatibility obligation before EP-3 adds any new step: default
  values must omit the key and old values must decode to an empty list.
- `docs/plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md` and
  `docs/plans/48-add-a-portable-one-off-repository-agent-harness.md` both assign ownership of
  the future registry and loop to the MCP plan. The generic ownership must move to EP-2 to
  avoid making every non-MCP overlay depend on MCP.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Implement an additive, run-scoped model-tool overlay rather than the paper's full
  dynamic component/fiber runtime.
  Rationale: It solves the concrete one-off capability need while preserving Keiro as durable
  lifecycle authority and the fixed replay-safe Flow capability row.
  Date: 2026-08-22

- Decision: Keep base capabilities structurally outside the overlay registry.
  Rationale: A different type and composition path is stronger than a reserved-name check;
  an overlay can add namespaced tools but has no operation that replaces memory, sinks,
  workflows, profiles, model selection, or other ambient runtime services.
  Date: 2026-08-22

- Decision: Treat an agent declaration as a required request, not authority, and omit optional
  overlays in V1.
  Rationale: Silently dropping an unavailable optional provider makes the model's tool menu
  history-dependent and hides operator mistakes. Unknown or denied requests fail before any
  provider is acquired.
  Date: 2026-08-22

- Decision: Pin the complete public capability descriptor for durable runs but keep live
  leases and secrets ephemeral.
  Rationale: Provider identity and revision are semantic; replay must not silently select a
  replacement, while connections and credential values are neither serializable nor safe to
  journal.
  Date: 2026-08-22

- Decision: Allow observation-only tools in durable runs in V1; keep writes, commands, and
  irreversible emissions on the explicitly one-off path.
  Rationale: Releasing a connection does not reverse a tool call. Keiro step actions are
  at-least-once, so mutating tools need an independent operation-id/idempotency contract.
  Date: 2026-08-22

- Decision: Make the one-off workspace adapter the first proof and leave MCP transport in the
  existing MCP plan as a downstream provider.
  Rationale: A local, read-only provider can exercise declaration, resolution, acquisition,
  dispatch, and cleanup without an unavailable upstream MCP adapter or secret-bearing test.
  Date: 2026-08-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

(To be filled during and after implementation.)
