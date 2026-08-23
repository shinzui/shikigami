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
| EP-1 | Declare agent capability overlay requirements and the operator catalog | `docs/plans/56-declare-agent-capability-overlay-requirements-and-the-operator-catalog.md` | None | None | Complete |
| EP-2 | Acquire and release overlay leases around one behavior run | `docs/plans/57-acquire-and-release-overlay-leases-around-one-behavior-run.md` | EP-1 | None | Complete |
| EP-3 | Resolve and pin capability overlays in durable agent runs | `docs/plans/58-resolve-and-pin-capability-overlays-in-durable-agent-runs.md` | EP-1, EP-2 | None | Complete |
| EP-4 | Adopt capability overlays in the portable one-off repository harness | `docs/plans/59-adopt-capability-overlays-in-the-portable-one-off-repository-harness.md` | EP-1, EP-2 | EP-3 | Complete |

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

- [x] (2026-08-22) EP-1: Added the defaulted declaration field and byte-compatibility
      fixtures.
- [x] (2026-08-22) EP-1: Added pure catalog resolution, authorization, descriptor pinning,
      and validation.
- [x] (2026-08-22) EP-2: Add provider/lease acquisition with partial rollback and collision
      rejection.
- [x] (2026-08-22) EP-2: Run `Skill` behaviors through one bounded tool loop while preserving
      the empty path.
- [x] (2026-08-23) EP-3: Declared, scaffolded, and runtime-gated the durable resolution step.
- [x] (2026-08-23) EP-3: Proved fresh-run pinning, old-run compatibility, exact-version
      retries, cleanup, and conversation fail-closed behavior.
- [x] (2026-08-23) EP-4: Supplied a confined read-only workspace provider in `shikigami-agent`.
- [x] (2026-08-23) EP-4: Proved agent-specific opt-in through the database-free one-off command and reconciled
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
- Released `Shikumi.Tool.Tool` is existentially wrapped but does not derive `Generic`, so
  namespacing must reconstruct its constructor rather than use the repository's normal lens
  update. The operation preserves its dictionaries, description, and rank-2 body and changes
  only the wire name.
- Keiro classifies a newly declared step as additive only when the entire body change sits
  inside a new patch. EP-3's `shikigami-capability-overlays-v1` declaration and runtime branch
  satisfy that rule: the gate reports `ADDITIVE` and `replay-neutral`, and an in-flight deploy
  simulation proves the false branch writes no resolution step.
- Exact-revision restoration does not require the current catalog to point back to the old
  descriptor. The provider registry may retain `v1` while the catalog selects `v2`; a resumed
  run reacquires journaled `v1`, while a new run resolves and acquires `v2`.
- The released Shikumi filesystem fallback bounds depth and returned results but not the total
  visited-file set or encoded response size. EP-4 therefore uses the released `mkTool`,
  registry, and dispatch protocol while implementing the three confined operations locally.


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

- Decision: Keep `workspace.read` revision `1` immutable and put future mutation or command
  authority behind separate capability ids.
  Rationale: Adding stronger operations to an installed observation descriptor would silently
  widen old declarations and durable snapshots. A new read revision can carry additive
  observations; write and exec remain independently authorizable requests.
  Date: 2026-08-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

EP-1 completed on 2026-08-22. The declaration and pure catalog boundary now exists with
backward-compatible agent JSON, validated capability names, immutable public descriptors,
canonical resolved snapshots, and typed permanent refusals. ADR 0025 records that overlay
declarations are requests for additive model tools rather than authority or replacements for
base capabilities. All 569 repository tests pass, including 406 core tests. The flake's
formatting and pre-commit checks pass; its old default-package output still fails because it
points `cabal2nix` at a multi-package root with no root `.cabal` file, a packaging concern
already owned by Plan 31 and unchanged by EP-1.

EP-2 completed on 2026-08-22 in commits `83f1adb`, `b5e29e9`, and `7d66944`. Exact-revision
providers now return run-scoped leases; acquisition is deterministic and masked; partial and
exceptional exits release in LIFO order; collision-safe namespacing produces one immutable
derived registry; and every existing `BehaviorEnv` constructor defaults to empty overlay
state. Tool-enabled Skills use a traced eight-turn model/tool loop, while empty registries
retain the original single-completion path. A permanent pre-dispatch guard requires requested
overlay ids to be unique and exactly equal the environment's active ids.

All 594 repository tests pass, including 431 core tests. Direct flake treefmt and pre-commit
checks pass. The unchanged default-package output still fails because the seihou-managed
`callCabal2nix` target points at a multi-package root with no root Cabal file; that existing
Plan 31 packaging issue does not affect the Cabal test matrix. ADR 0025 now records the final
lease, registry, guard, loop, and cleanup boundaries.

EP-3 and EP-4 became unblocked after EP-2; EP-3 is now complete. The MasterPlan remains
active until EP-4 completes.

EP-3 completed on 2026-08-23 in commit `4649390`. A fresh `AgentRun` now journals its public
capability descriptors after profile resolution and before `open-session`; each timed behavior
attempt reacquires only those exact revisions and releases them before downstream lifecycle
work. Permanent declaration, catalog, and policy refusals are journaled before session
creation, while transient provider failures leave the behavior result absent for retry.
Pre-patch runs retain their old shape, and Danwa conversations with declared overlays fail
closed until they gain their own durable resolution boundary.

The Keiro gate passes from merge base `af3de569fe4f91238fefed57e2ef57575570d8ff` and reports
the patch additive and replay-neutral. All 601 repository tests pass, including 438 core
tests. `nix flake check` retains only the previously documented Plan 31 default-package
failure at the multi-package root; direct `treefmt` and `pre-commit` flake checks pass. ADR
0025 records the durable replay and provider-retention contract. EP-4 then became the sole
remaining child and was dependency-ready.

EP-4 completed on 2026-08-23. An identity-bearing one-off Skill may now request the immutable
`workspace.read` revision `1` and receive only namespaced, bounded read, grep, and glob
observations rooted at an explicit or discovered Git worktree. The empty declaration path
does no catalog or workspace work. Both one-off commands share the same provider lease
boundary; the memory-backed path acquires after recall and releases before record and session
completion. A scripted external-worktree proof demonstrates opt-in isolation, tool dispatch,
cleanup, log redaction, and unchanged bytes inside and outside the fixture.

Plan 48 was reconciled to consume the generic overlay catalog/provider seams and the delivered
read-only slice while retaining its larger writable and sandboxed-command scope. ADR 0025 now
records the concrete V1 provider, limits, package placement, lazy resolution, and immutable
revision rule. The 27-test agent suite, 438-test core suite, and complete Cabal test matrix
pass; both executable help surfaces expose `--workspace`; direct treefmt and pre-commit flake
checks pass. `nix flake check`
retains only the already documented Plan-31 default-package failure at the multi-package root.

All four ExecPlans are complete. The initiative delivered additive agent-scoped model tools
without placing base capabilities in the overlay registry, widening `FlowEffects`, or changing
the empty-run behavior path.
