---
id: 58
slug: resolve-and-pin-capability-overlays-in-durable-agent-runs
title: "Resolve and pin capability overlays in durable agent runs"
kind: exec-plan
created_at: 2026-08-22T15:12:03Z
intention: "intention_01m0n043cse67vxfj52w29t6zb"
master_plan: "docs/masterplans/11-add-agent-scoped-capability-overlays-without-changing-base-capabilities.md"
---

# Resolve and pin capability overlays in durable agent runs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, a durable `AgentRun` resolves an agent's requested capability overlays
once, before opening the memory session, and journals the complete public descriptors it
selected. Every retry of the behavior step reacquires those exact provider revisions for the
duration of that attempt. Changing the operator catalog affects fresh runs but cannot
silently move an in-flight run from provider revision A to B.

The behavior is visible in a deploy-simulation test and in lifecycle logs. A fresh run for an
authorized `workspace.read`-style observation provider writes
`resolve-capability-overlays`, acquires its pinned revision, exposes its namespaced tools, and
releases it before the step finishes. A pre-deployment in-flight run follows the old patch
branch and sees no overlays. Unknown, denied, identity-free, non-Skill, or mutating durable
requests fail permanently before `open-session`; a temporary acquisition failure escapes the
behavior step, leaves no behavior result in the journal, and may succeed later against the
same pinned revision.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-23) Added the capability runtime bundle to `AgentRunDeps` and every
      composition/test site.
- [x] (2026-08-23) Added the declared `shikigami-capability-overlays-v1` patch and
      `resolve-capability-overlays` step to the Keiro domain source.
- [x] (2026-08-23) Regenerated the Keiro layer and updated hand-owned conformance
      expectations.
- [x] (2026-08-23) Implemented the real runtime patch branch, permanent resolution mapping,
      and old-shape fallback.
- [x] (2026-08-23) Acquired exact pinned overlay leases inside each timed
      `run-behavior-v2` attempt.
- [x] (2026-08-23) Added wire, workflow, retry, deploy-simulation, cleanup, and Danwa
      fail-closed tests. `just keiro-gate af3de569fe4f91238fefed57e2ef57575570d8ff`
      and the full Cabal matrix pass.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Adding even one new declared step to `domain/shikigami-agent-run.keiro` is classified as a
  breaking body change unless the whole addition is inside a new patch block. This is true
  even though a new runtime step name is replay-additive. `docs/workflow-versioning.md` and
  ADR 0012 require both the declaration and a real `patch` branch.
- The existing `lookup-agent` result already pins the declaration, and Plan 56 makes its new
  field backward compatible. The new resolution step must pin the operator decision, not
  reload the agent or re-read the current catalog on replay.
- Keiro step actions are at-least-once. Closing a provider lease cannot undo a tool call, so
  Plan 56's operation class is a workflow admission check, not documentation: this plan must
  refuse every non-observation tool before the step can run.
- The Keiro diff gate classified the declared patch as `ADDITIVE` and its stored-data effect
  as `replay-neutral`. The generated scaffold was a no-op after staging, which proves the
  checked-in generated facts match the domain source.
- The existing `BehaviorEnv` overlay guard supplies the Danwa fail-closed boundary without a
  second catalog lookup: a conversation with a non-empty declaration receives the explicit
  overlay-mismatch refusal before model dispatch.


## Decision Log

Record every decision made while working on the plan.

- Decision: Resolve overlays after `resolve-profile` and before `open-session` under a new
  patch id `shikigami-capability-overlays-v1`.
  Rationale: Capability policy may use the already-resolved profile, and a permanent refusal
  must not create a memory session. A dedicated patch preserves the old body for in-flight
  instances and satisfies the checked domain gate.
  Date: 2026-08-22

- Decision: Journal the complete public `ResolvedCapabilitySet`; never journal a provider
  factory, credential, endpoint secret, connection, callback, lease id, or release action.
  Rationale: Replay needs stable semantic provider identity, while live resources and secret
  values are process-local and unsafe to serialize.
  Date: 2026-08-22

- Decision: Reacquire the pinned descriptor inside every `run-behavior-v2` attempt and put the
  lease bracket inside the existing attempt timeout.
  Rationale: A crash or timeout must not retain a lease, and a retry needs a fresh live
  connection without selecting a new semantic provider.
  Date: 2026-08-22

- Decision: Classify declaration/catalog/policy incompatibility as permanent and provider
  acquisition/release failure as transient.
  Rationale: Retrying the same unknown or denied request cannot change its journaled policy
  result. Operator restoration of an exact provider revision can repair an infrastructure
  outage, so the behavior result must remain unjournaled.
  Date: 2026-08-22

- Decision: Scope this plan to the `AgentRun` workflow. Danwa conversation execution fails
  closed on non-empty overlay declarations until a separate plan adds a conversation-local
  resolution step and patch.
  Rationale: Conversation generations have a different replay and rotation lifecycle. Using
  the live catalog there without its own journaled snapshot would violate the invariant this
  plan establishes; silently supplying an empty registry would be worse.
  Date: 2026-08-22


## Outcomes & Retrospective

Completed on 2026-08-23 in implementation commit `4649390`. Fresh durable agent runs now
journal a complete capability-resolution result after profile resolution and before memory
session creation. Each behavior attempt acquires only the exact journaled provider revision,
derives a callback-local tool registry, and releases its leases before sink, memory, or
session-completion work. Pre-patch instances retain the old body and write no added step.

The acceptance proofs cover stable journal bytes, old/fresh patch branches, permanent
refusals before `open-session`, exact `v1` restoration after the live catalog moves to `v2`,
transient acquire/release behavior, lease-boundary ordering, and Danwa's explicit fail-closed
path. `just keiro-gate af3de569fe4f91238fefed57e2ef57575570d8ff` passes and classifies the
change as additive and replay-neutral. `nix develop --command cabal test all -j1` passes all
601 repository tests, including 438 core tests.

`nix flake check` still fails only at the pre-existing
`packages.aarch64-darwin.default` output: its `cabal2nix` source is the multi-package root,
which has no root `.cabal` file. The same Plan 31 packaging issue was recorded by EP-1 and
EP-2 and is unchanged by this plan. Direct builds of the flake's `treefmt` and `pre-commit`
checks pass. ADR 0025 now records the durable patch, journal pin, attempt-local acquisition,
failure classification, provider-retention, and conversation boundaries established here.


## Context and Orientation

`shikigami-core/src/Shikigami/Agent/Workflow.hs` owns the durable agent-run body. It journals
`ingest-job`, `lookup-agent`, optionally `resolve-profile`, then opens a Kioku session,
recalls memory, runs either the patched `run-behavior-v2` or legacy `run-behavior`, dispatches
sinks, records memory, and completes or fails the session. `AgentRunDeps` carries the loaded
agents, `BehaviorEnv`, policy/profile dependencies, store environment, timeouts, and hooks
used by tests. The worker and direct runner construct it; many workflow tests use record
literals, so adding a field requires updating all of them.

`domain/shikigami-agent-run.keiro` is the hand-owned workflow specification.
`just keiro-scaffold` generates patch facts and runtime modules under
`shikigami-core/src/Shikigami/AgentRun/Generated/`; those files must never be edited by hand.
`shikigami-core/src/Shikigami/Workflow/Versioning.hs` derives the one active patch set from
generated declarations, and `shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/src/KeiroConformance/Expectations.hs`
is the hand-owned expectation updated after scaffolding. `docs/workflow-versioning.md` is the
normative review standard.

Plan 56 defines `ResolvedCapabilitySet`, pure catalog resolution, and permanent refusal
types. Plan 57 defines `CapabilityProviderRegistry`, `CapabilityScope`, the lease bracket,
and `withCapabilityTools`. The **catalog current revision** is used only when the new step
executes for the first time. A replay reads the journaled set. A **provider registry** may
hold more than one revision at once so in-flight journals can continue to reacquire an older
revision while fresh runs select the new one.

Relevant local decisions are:

* `docs/adr/0004-one-options-value-and-a-checked-patch-set.md`: all runs and resumes use the
  one generated active-patch set.
* `docs/adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md`: a complete resolution
  is a run-local pin, not a live lookup performed at every dispatch.
* `docs/adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md`: old
  `lookup-agent` values decode with no requests.
* `docs/adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md`: declaration and
  runtime patch branches must land together.
* `docs/adr/0015-a-kioku-write-answers-on-two-layers-and-a-journaled-step-keeps-its-bytes.md`:
  durable refusal and retryable execution failure are separate layers.

The Keiro semantics are documented canonically at
`mori://shinzui/keiro-runtime-patterns/docs/keiro-durable-workflows` and
`mori://shinzui/keiro-runtime-patterns/docs/keiro-evolution-and-rollout`. No additional
cross-repository ADR was found.


## Plan of Work

### Milestone 1: Inject one capability runtime bundle

Add `CapabilityRuntime` to `Shikigami.Capability.Provider` or a small
`Shikigami.Capability.Runtime` module. It groups the pure catalog, provider registry, and
authorization function used for one run; provide `emptyCapabilityRuntime`, whose empty
catalog/registry authorizes nothing but allows an empty request set. Add
`capabilities :: !CapabilityRuntime` to `AgentRunDeps` in
`Shikigami.Agent.Workflow`. Update worker construction, direct run construction, and every
test literal to use the empty value until a test explicitly installs a fake provider. Do not
put provider config or secrets into `AgentDecl` or `RunJob`.

Add helpers that build the `ResolutionSubject` from `AgentDecl.identity`, execution mode
`Durable`, behavior, and the already resolved sanctioned profile when present. The
authorization callback receives this subject and the descriptor. If the request list is
empty, this bundle is never asked to acquire or authorize anything.

### Milestone 2: Declare and generate the new workflow patch

Edit `domain/shikigami-agent-run.keiro`. Immediately after the existing
`shikigami-resolve-profile-v1` block, add:

```text
patch shikigami-capability-overlays-v1 {
  step resolve-capability-overlays -> CapabilityOverlayResolution
}
```

Run `just keiro-scaffold`. Inspect the generated patch facts and update the hand-owned
conformance expectation with the new patch and step. Do not hand-edit a generated module.
Update the journal census in `docs/workflow-versioning.md` and the agent-run inventory in
`docs/architecture/shikigami-domain-inventory.md` with the new declarable label.

### Milestone 3: Runtime resolution branch and compatible old shape

In `runResolvedAgent`, call `patch` with the generated/declared patch id after profile
resolution succeeds. On `True`, execute
`runStep deps (StepName "resolve-capability-overlays")` around the pure catalog and policy
resolution. Its result type is
`Either CapabilityResolutionError ResolvedCapabilitySet`, with explicit stable JSON.
Map a `Left` to `PermanentAgentRunFailure` before `open-session`. On `False`, use
`emptyResolvedCapabilitySet` without writing a new step. Pass the successful set through
`runProfiledAgent`, `runProfiledAgentWith`, `runSessionedAgent`, and the behavior helper;
do not re-read the catalog after this point.

Use a named `capabilityOverlayPatch` constant sourced from the declared generated surface in
the same style as existing patch constants. Ensure the real False branch retains the old
control flow. Extend `Shikigami.AgentWorkflowSpec`, `Shikigami.WireCompatSpec`, and
`Shikigami.WorkflowVersioningSpec`: old `AgentDecl` JSON decodes with an empty request;
pre-patch instances do not write the step; fresh instances do; and a permanent refusal
never writes `open-session`.

### Milestone 4: Exact-revision acquisition inside the behavior attempt

For a `Skill` with a successful resolved set, construct `CapabilityScope` from the workflow
id/idempotency key and principal. Inside the action passed to `runBehaviorAttemptWith`, call
Plan 57's `withCapabilityOverlays` using the base registry from `BehaviorEnv`, derive the
active environment with `withCapabilityTools`, and call `runBehavior`. Convert acquisition,
composition, and release failures into `TransientBehaviorFailure` so `run-behavior-v2` does
not append a value. Keep the bracket inside the existing timeout so cancellation releases
leases. Empty sets use Plan 57's no-acquire fast path.

Do not wrap Flow execution or widen `FlowEffects`; Plan 56 has already rejected non-empty
overlays on non-Skill declarations. Do not add a retry loop inside the step. Keiro/worker
retry policy remains the single owner. Add tests proving acquisition happens after recall and
before model dispatch, release happens before the behavior step returns, and no lease remains
during sink dispatch, memory recording, or session completion.

### Milestone 5: Replay, rollout, and exact-provider proofs

Add a deploy-simulation using the patterns in
`shikigami-core/test/Shikigami/WorkflowVersioningSpec.hs`. Start an old-shape instance,
suspend it before the changed region, then run new-shape code: it must take the False branch
and never resolve/acquire. Start a fresh instance under the new active patch: it must journal
the resolution step.

For provider replacement, let the fresh instance journal revision `v1`, fault after
resolution but before the behavior result commits, change the catalog's current descriptor
to `v2` while retaining both providers, and resume. The resumed attempt must acquire `v1`.
Repeat with `v1` temporarily absent: the attempt fails transiently without a behavior journal
record; restoring `v1` lets it finish. Verify `v2` is used only by a newly started run.

Run the specification gate against the actual merge base and retain its JSON/text evidence in
the plan's Progress/Surprises section while implementing. If the boundary or result type
changes from the accepted overlay ADR, update that ADR in the same change.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`. Reopen Keiro's authoritative source before
using a workflow API:

```bash
mori registry show shinzui/keiro --full
mori registry docs shinzui/keiro
```

After editing the domain source, regenerate and inspect:

```bash
just keiro-scaffold
git diff -- domain/shikigami-agent-run.keiro \
  shikigami-core/src/Shikigami/AgentRun/Generated \
  shikigami-core/src/keiro-dsl-conformance.workspace.shikigami
```

Expected: generated facts include `shikigami-capability-overlays-v1` and
`resolve-capability-overlays`; no generated file has a hand-written edit unrelated to
scaffolding.

Format and run focused tests:

```bash
nix fmt
nix develop --command cabal test shikigami-core-test -j1
nix develop --command cabal test keiro-shikigami-conformance -j1
```

Run the gate from the actual branch merge base:

```bash
merge_base=$(git merge-base HEAD origin/master)
just keiro-gate "$merge_base"
```

Expected gate result:

```text
PASS
```

Finish with repository-wide validation:

```bash
nix develop --command cabal test all -j1
nix flake check
git diff --check
```


## Validation and Acceptance

The plan is accepted when:

* A pre-patch in-flight workflow follows the old branch, writes no
  `resolve-capability-overlays`, acquires nothing, and completes under the old body shape.
* A fresh empty-overlay run journals an empty successful resolution and performs zero
  provider operations; its model request remains on the empty-registry path.
* A fresh authorized observation request journals the complete descriptor before
  `open-session`, then acquires and releases its exact revision around each behavior attempt.
* Unknown, duplicate, denied, identity-free, non-Skill, and non-observation durable requests
  end as permanent failures before `open-session`, with no acquire event.
* A provider acquire or release failure leaves `run-behavior-v2` unjournaled and is surfaced
  as transient. Every successfully acquired earlier provider is released.
* After revision `v1` is journaled, changing the current catalog to `v2` does not change a
  resumed run. Removing `v1` causes a transient failure; restoring it resumes successfully;
  a new run selects `v2`.
* Provider leases are gone before sink dispatch, memory recording, or session completion.
* `just keiro-gate` passes with the new patch represented in the domain, generated active
  set, runtime branch, conformance expectation, and deploy-simulation test.
* A Danwa conversation attempting to run a declaration with non-empty overlays receives the
  explicit capability-overlay mismatch/unsupported error rather than silently running with
  no tools or resolving the live catalog.


## Idempotence and Recovery

Scaffolding, formatting, tests, and the gate are repeatable. The resolution step is pure and
idempotent for its captured inputs. Once its result is journaled, replay decodes the result
and does not execute the resolver again. Provider acquisition may repeat because the behavior
step is at-least-once; this plan admits only observation tools and requires provider acquire
to be a reversible resource operation.

Never rename `resolve-capability-overlays`, reuse its patch id, or change its decoded result
type in place. If the result needs a breaking type change, give the step a new stable name and
follow `docs/workflow-versioning.md`. If deployment reaches instances that journaled the new
patch, roll forward; do not roll back to code without the True branch. Retain old provider
revisions until no journal can still reference them. If an old revision was removed too
early, restore it under the exact same public descriptor; do not alias the key to a newer
provider.


## Interfaces and Dependencies

The runtime bundle must have an interface equivalent to:

```haskell
data CapabilityRuntime = CapabilityRuntime
  { catalog :: !CapabilityCatalog
  , providers :: !CapabilityProviderRegistry
  , authorize
      :: !(ResolutionSubject
           -> CapabilityDescriptor
           -> Either CapabilityResolutionError ())
  }

emptyCapabilityRuntime :: CapabilityRuntime
```

`AgentRunDeps` gains one direct field:

```haskell
data AgentRunDeps = AgentRunDeps
  { -- existing fields remain
    capabilities :: !CapabilityRuntime
  }
```

The pure workflow action and attempt wrapper should be separable for tests, with interfaces
equivalent to:

```haskell
resolveCapabilitiesForRun
  :: CapabilityRuntime
  -> AgentDecl
  -> Maybe ResolvedProfile
  -> Either CapabilityResolutionError ResolvedCapabilitySet

runBehaviorWithCapabilities
  :: Log.Logger
  -> CapabilityRuntime
  -> CapabilityScope
  -> ResolvedCapabilitySet
  -> BehaviorEnv
  -> AgentDecl
  -> BehaviorInput
  -> IO (Either CapabilityRuntimeError (Either RunError Value))
```

The journaled step result uses Plan 56's stable Aeson instances. `CapabilityRuntime`,
provider registries, and leases have no Aeson instances. Runtime coordination uses Keiro
0.13's `patch`, `step`, and existing Shikigami run options through
`Shikigami.Workflow.Versioning`; it must not construct a second `WorkflowRunOptions` value.

This plan hard-depends on Plans 56 and 57 and on the local workflow rules. It adds no database
table or migration. Provider configuration is injected at worker composition and the
`shikigami-agent` composition root; it is never loaded from the durable journal as executable
configuration.
