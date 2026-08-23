---
id: 57
slug: acquire-and-release-overlay-leases-around-one-behavior-run
title: "Acquire and release overlay leases around one behavior run"
kind: exec-plan
created_at: 2026-08-22T15:12:03Z
intention: "intention_01m0n043cse67vxfj52w29t6zb"
master_plan: "docs/masterplans/11-add-agent-scoped-capability-overlays-without-changing-base-capabilities.md"
---

# Acquire and release overlay leases around one behavior run

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, a resolved overlay becomes a real, run-scoped set of model tools without
mutating the process-wide behavior environment. The runtime looks up the exact provider
revision selected by Plan 56, acquires providers in deterministic order, combines their
namespaced tools with the existing registry only if there are no collisions, runs one
behavior attempt, and releases every acquired provider in reverse order. If acquisition or
composition fails halfway through, everything acquired so far is released before the error
is returned.

`Skill` behaviors with tools use a bounded model/tool loop. Skills with no overlays retain
today's single-completion path, so every existing agent keeps the same request and response
behavior. Tests make the lifecycle visible with `IORef`-backed providers: they record
`acquire A, acquire B, release B, release A`, prove partial rollback, and prove that one
agent's derived registry cannot leak into the next run.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-22) Add the released `shikumi-tools` package and document its verified cohort version.
- [x] (2026-08-22) Define the provider registry, acquisition scope, lease, and typed runtime
      failures.
- [x] (2026-08-22) Implement masked deterministic acquisition, collision-safe composition, and LIFO
      release, including partial-failure rollback.
- [x] (2026-08-22) Add an empty default tool registry and active overlay set to `BehaviorEnv` plus a
      derived-environment constructor.
- [x] (2026-08-22) Add the bounded Skill model/tool loop and preserve the exact empty-registry path.
- [x] (2026-08-22) Add lifecycle, failure, isolation, dispatch, timeout, and tracing tests.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `mori://shinzui/baikai/packages/baikai` at 0.5.0.0 already provides the public tool wire
  types, `appendToolResult`, and bounded `runToolLoop`/`runToolLoopWith`. Shikigami does not
  need to invent another model/tool protocol.
- `mori://shinzui/shikumi/packages/shikumi-tools` at 0.3.0.2 already provides typed
  `SomeTool`, `ToolRegistry`, `mkRegistry`, `registryBaikai`, `registryNames`, and
  `runToolCall`. It is released in the same upstream cohort as the already-pinned
  `shikumi 0.3.0.2`, but Shikigami does not yet constrain or link the package.
- The current trace seam injects a completion function into `runSkillWith`, whereas Baikai's
  `runToolLoop` chooses its completion function internally. The implementation must preserve
  per-turn tracing. A small completion-function-driven loop using Baikai's public context
  operations is acceptable; silently bypassing `BehaviorEnv.traceSink` on overlay runs is
  not.
- Released `Shikumi.Tool.Tool` does not derive `Generic`, so the repository's normal
  generic-lens record update cannot rename an existential tool. The namespace adapter instead
  pattern-matches and reconstructs `Tool`, preserving its existential dictionaries,
  description, and rank-2 body while changing only `name`. Evidence: the first core build
  failed with `No instance for Generic (Shikumi.Tool.Tool i o)` at `#name`; constructor-based
  matching and construction are explicitly permitted by the record-pattern standard.
- The full 420-case `shikigami-core-test` suite passed after the provider milestone,
  including timeout cancellation, partial-acquisition rollback, LIFO cleanup, continued
  cleanup after a release failure, exact revision selection, collision refusal, and
  concurrent derived-registry isolation.
- The completed behavior milestone passes all 431 core tests. Its bracketed end-to-end case
  records two traced model turns, carries the namespaced tool result into the second context,
  returns the unchanged `{"reply": ...}` shape, and releases the provider afterward.
- Repository-wide Cabal validation passes all 594 tests. The flake's treefmt and pre-commit
  checks also pass. The full `nix flake check` still reaches the pre-existing default-package
  failure: `nix/haskell.nix` points `callCabal2nix` at the multi-package repository root,
  which has no root `.cabal` or `package.yaml`. The same definition is present on
  `origin/master`, is owned by Plan 31, and was not changed by this plan.


## Decision Log

Record every decision made while working on the plan.

- Decision: Reuse Shikumi's `ToolRegistry` and Baikai's tool-call wire model rather than
  defining Shikigami tool types.
  Rationale: The released packages already own typed erasure, JSON-schema lowering, lookup,
  dispatch, and provider-neutral tool messages. A local duplicate would immediately diverge
  from the MCP and repository consumers.
  Date: 2026-08-22

- Decision: Pair every acquisition with a release action in one returned `CapabilityLease`;
  acquire in sorted capability order and release in LIFO order.
  Rationale: The inverse is produced at the only point that knows what was acquired, and
  deterministic ordering makes failure histories and tests reproducible.
  Date: 2026-08-22

- Decision: Build a derived `BehaviorEnv` per callback and never mutate the process's base
  environment or a global tool registry.
  Rationale: Concurrent runs may request different overlays. Immutable derivation prevents
  cross-run leakage and ensures releasing one run cannot remove another run's tools.
  Date: 2026-08-22

- Decision: Namespace every overlay tool as
  `overlay__<capability-id-with-dashes>__<logical-tool-name>` and reject all collisions.
  Rationale: Provider-local names need not be globally unique, while last-wins registry
  behavior would let an overlay replace a base or another overlay tool. Namespacing plus
  collision refusal makes composition additive.
  Date: 2026-08-22

- Decision: Preserve the existing one-completion Skill path when the composed registry is
  empty; use a hard default of eight model turns when tools are present.
  Rationale: Empty declarations must be observationally unchanged. A hard bound prevents an
  agent from looping forever; configurable budgets and policy interception can be added
  later without weakening the V1 ceiling.
  Date: 2026-08-22

- Decision: Release every lease even when another release fails; preserve a body exception
  as the primary failure and report cleanup failures separately.
  Rationale: Stopping after the first disposer failure maximizes leaks. Replacing the original
  exception with cleanup noise hides the cause of the failed run.
  Date: 2026-08-22

- Decision: Treat a declaration/environment overlay mismatch and exhaustion of the hard
  model-turn ceiling as permanent behavior failures. Preserve Shikumi's transient/permanent
  classification when a tool body reports an infrastructure failure.
  Rationale: Neither a retry nor a model observation can repair missing authority, a fixed
  local ceiling, budget exhaustion, or context overflow. Provider and timeout faults may
  recover and continue to use the existing retry path.
  Date: 2026-08-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Completed on 2026-08-22. A resolved capability set now crosses exactly one live boundary:
exact-revision providers return run-scoped leases, collision-safe composition produces an
immutable derived tool registry, and masked cleanup releases every acquired lease in LIFO
order on success, refusal, exception, or cancellation. The base registry never changes.

`BehaviorEnv` now defaults to no tools and no active overlays. Its declaration guard refuses
missing, extra, and duplicate ids before behavior dispatch. Tool-enabled Skills advertise the
derived registry, dispatch typed Shikumi tools through Baikai's public result protocol, trace
every model turn, and stop after eight model turns by default. Empty registries keep the
original one-completion request and `{"reply": ...}` response shape.

Validation covered normal and partial acquisition, exact descriptor selection, collision
refusal, callback exception and timeout cleanup, continued cleanup after release failure,
concurrent isolation, empty-path compatibility, unknown tool recovery, infrastructure error
classification, bounded looping, tracing, and end-to-end release after the final response.
All 431 core tests and all 594 repository tests pass. The flake's directly addressable
treefmt/pre-commit checks pass; the unrelated root-package output remains broken as described
under Surprises & Discoveries.


## Context and Orientation

Plan 56 (`docs/plans/56-declare-agent-capability-overlay-requirements-and-the-operator-catalog.md`)
defines a pure `CapabilityCatalog` and a serializable `ResolvedCapabilitySet`. A resolved
descriptor says which immutable capability revision and public logical tools were selected,
but it deliberately contains no `IO` factory.

`shikigami-core/src/Shikigami/Behavior/Run.hs` defines `BehaviorEnv`, currently a shared
bundle of Handan runtime, Baikai model/options, and optional trace sink. `runBehavior`
dispatches `ShikumiProgram` to a static Handan task and `Skill` to
`shikigami-core/src/Shikigami/Behavior/Skill.hs`. The Skill module builds a Baikai `Context`
with `tools = V.empty`, makes one completion, and extracts text. Its `runSkillWith` seam
accepts a completion function so tests and tracing can observe each model call.

`shikigami-core/src/Shikigami/Behavior/Provider.hs` is the only production constructor family
for provider-specific `BehaviorEnv` values. Every constructor and test record literal must
receive empty overlay state. `shikigami-core/src/Shikigami/Behavior/Error.hs` owns permanent
versus transient behavior classification, and `runBehaviorAttemptWith` in `Behavior.Run`
applies the attempt timeout. The acquisition bracket must be inside that timed attempt in
durable callers so timeout cancellation also releases leases.

A **provider** is an operator-installed factory for one exact descriptor. A **lease** is one
successful runtime acquisition: its tools plus the release action for the concrete resource.
It is never encoded or shared across runs. A **base registry** is the tool registry already
present in a `BehaviorEnv`; it is empty initially but remains a distinct input so an overlay
can only be added to it, never replace it.

Relevant local decisions are
`docs/adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md` (derive a constrained
run-local environment), `docs/adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md`
(do not widen Flow with this IO runtime), and
`docs/adr/0015-a-kioku-write-answers-on-two-layers-and-a-journaled-step-keeps-its-bytes.md`
(keep retryable infrastructure failure distinct from a permanent refusal). No additional
cross-repository ADR was found. The dependency source and public contracts are the canonical
Mori artifacts `mori://shinzui/shikumi/packages/shikumi-tools` and
`mori://shinzui/baikai/packages/baikai`.


## Plan of Work

### Milestone 1: Released tool dependency and collision-safe algebra

Before editing bounds, use Mori to reopen Shikumi's source, query Hackage, and inspect the
upstream release tags. At plan creation the coherent selection is `shikumi-tools 0.3.0.2`,
tag `shikumi-tools-0.3.0.2`, commit
`5e3680e52608d7e88698fa9485f78619853ced98`; reverify that it is still the newest compatible
release at implementation time. Add an exact `shikumi-tools` constraint beside `shikumi` in
`cabal.project`, add it to `shikigami-core` library/test dependencies, and add the released
row to `docs/dependency-cohort.md`. Do not use a Git source package or `allow-newer` for this
released package.

Add `shikigami-core/src/Shikigami/Capability/Tools.hs`. Build collision-rejecting operations
over `Shikumi.Tool.ToolRegistry`; do not rely on `mkRegistry`'s last-wins map construction.
The module takes a base registry and `(CapabilityId, [SomeTool])` groups, rewrites each tool's
wire name into the stable overlay namespace while retaining its existential dictionaries,
rejects duplicate logical names and any final-name collision, and only then calls
`mkRegistry`. It also returns the final sorted tool-name list for observability. Tests prove
two providers may both expose logical `search` without colliding after namespacing and that
two copies of the same capability are refused.

### Milestone 2: Provider registry and revertible lease bracket

Add `shikigami-core/src/Shikigami/Capability/Provider.hs`. A
`CapabilityProviderRegistry` is built from providers keyed by `(CapabilityId,
CapabilityRevision)` and refuses duplicate keys or a key that disagrees with its descriptor.
`resolveProvider` requires exact equality between the descriptor pinned by Plan 56 and the
provider's public descriptor. A provider missing that exact revision or configured under the
same key with different public semantics is a typed acquisition failure; never fall back to
the catalog's current revision.

Implement `withCapabilityOverlays` with `Control.Exception.mask`. Acquire in the sorted order
already carried by `ResolvedCapabilitySet`, restoring asynchronous exceptions only around
each provider action and the callback. After each successful acquire, prepend its release to
the local disposal stack. If a later acquire, descriptor check, namespace operation, or
callback fails, run all accumulated releases in stack order. Attempt every release even when
one fails. Synchronous acquisition failures return `Left CapabilityRuntimeError`; asynchronous
exceptions are rethrown after cleanup. On a successful callback, aggregate release failures
into a typed `Left`; on a failed callback, rethrow the callback exception after logging every
cleanup failure through the supplied `Shikigami.Log.Logger`.

Add structured events `capability.overlay.acquiring`, `.acquired`, `.releasing`, `.released`,
`.acquire_failed`, and `.release_failed`. Include capability id, revision, run id, and tool
names; never include provider-private config or credentials. Lifecycle tests use fake
providers and `IORef [Text]` to prove normal LIFO release, rollback after the second acquire,
cleanup on callback exception, cleanup on async timeout, continued cleanup after one release
failure, and exact descriptor selection.

### Milestone 3: Derived behavior environment and bounded Skill loop

Extend `BehaviorEnv` in `shikigami-core/src/Shikigami/Behavior/Run.hs` with
`tools :: !ToolRegistry`, `activeOverlays :: !(Set CapabilityId)`, and
`toolTurnLimit :: !Int`. Update `newBehaviorEnv`, `newBehaviorEnvWithTraceSink`, every branch
of `newBehaviorEnvFor`, and all test literals to use `mkRegistry []`, an empty set, and
`defaultToolTurnLimit = 8`. Add a pure `withCapabilityTools` that returns a record update with
the composed registry and exact active ids. It must not mutate the source environment.

Before dispatch, compare the declaration's requested id set with `activeOverlays`. An empty
request on an empty environment succeeds. Any missing, extra, or duplicate active id returns
a permanent `CapabilityOverlayMismatch` from `Shikigami.Behavior.Error`; this prevents a
caller such as the not-yet-supported conversation path from silently running a declared
overlay agent without its overlays. Non-`Skill` overlay requests were already refused by
Plan 56's resolver.

Change `Shikigami.Behavior.Skill` so `runSkill`/`runSkillWith` receive a `ToolRegistry` and a
positive turn limit. When `registryNames` is empty, execute the existing single-completion
branch byte-for-byte. Otherwise attach `registryBaikai` to `Context.tools`, repeatedly call
the injected completion function, dispatch each complete `ToolCall` through
`Shikumi.Tool.runToolCall`, append tool results with Baikai's public context operations, and
stop on final response, provider error, or the turn limit. Use Baikai's documented
`runToolLoop` semantics as the reference and share the dispatcher/result conversion with it;
the injection-friendly loop is needed only to keep `BaikaiTrace.withTrace` around every
turn. Unknown and ordinary tool failures become error tool results so the model may recover.
Provider, budget, context-window, and final response failures retain the existing
`RunError`/retry classification.

Add deterministic tests in `Shikigami.BehaviorProviderSpec` or a new
`Shikigami.BehaviorToolSpec`. A scripted completion first emits a tool call and then a final
reply. Assert that the request advertises only the namespaced tool, the tool result is in the
second context, the final JSON is unchanged (`{"reply": ...}`), the limit stops a provider
that always requests tools, and a trace sink sees every model turn. Also assert that the
empty registry invokes the completion function exactly once with `Context.tools = V.empty`.

### Milestone 4: Package and architecture guards

Expose the new core modules and register tests in `shikigami-core.cabal` and
`shikigami-core/test/Main.hs`. Extend `Shikigami.PackageArchitectureSpec` if necessary to
state that `shikigami-tools` is a core library dependency while provider adapters remain in
their leaf composition packages. Do not add an MCP library, process runner, queue adapter,
or server dependency. Update the overlay ADR created by Plan 56 with the final lease and
single-registry boundary if its accepted interface differs from the plan.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`. Reverify source and releases before
changing the cohort:

```bash
mori registry show shinzui/shikumi --full
mori registry show shinzui/baikai --full
mori registry docs shinzui/baikai
curl -fsSL https://hackage.haskell.org/package/shikumi-tools | rg -m1 'shikumi-tools-[0-9]'
curl -fsSL https://hackage.haskell.org/package/baikai | rg -m1 'baikai-[0-9]'
shikumi_root=$(mori path mori://shinzui/shikumi)
baikai_root=$(mori path mori://shinzui/baikai)
git -C "$shikumi_root" ls-remote --tags origin
git -C "$baikai_root" ls-remote --tags origin
```

Confirm the solver selects the intended released package:

```bash
nix develop --command cabal build all --dry-run
```

Expected plan fragment:

```text
shikumi-tools-0.3.0.2
shikigami-core-0.1.0.0
```

Format and run focused and full tests:

```bash
nix fmt
nix develop --command cabal test shikigami-core-test -j1
nix develop --command cabal test all -j1
nix flake check
git diff --check
```

Expected: the core lifecycle and behavior-tool cases pass, all existing empty-overlay
behavior tests remain green, and the full suite and flake checks exit zero.


## Validation and Acceptance

Acceptance requires behavior, not only compilation:

* Acquiring resolved A then B and returning normally records
  `acquire:A, acquire:B, release:B, release:A` exactly once.
* If B fails to acquire, A is released before `Left AcquireFailed` is returned. If the
  callback times out or throws asynchronously, every acquired lease is still released.
* A failing release does not prevent later releases. Cleanup failure is observable and never
  replaces an already-thrown callback failure.
* A pinned descriptor for revision 1 never acquires revision 2. Missing revision 1 and a
  descriptor mismatch both fail; there is no current-provider fallback.
* Two concurrent callbacks derived from the same base `BehaviorEnv` see only their own active
  overlay ids and tools. Releasing either callback does not alter the base or the other run.
* A final-name collision is rejected before the model is called, and all leases acquired for
  the rejected composition are released.
* A Skill with no tools calls the injected completion exactly once with an empty tool vector
  and produces the same JSON as before.
* A scripted two-turn Skill sees its namespaced tool, dispatches it once, receives the result
  in context, emits a final reply, and releases its provider afterward. A provider that never
  stops requesting tools is bounded at eight calls.
* A trace sink records each model turn on the overlay path.
* No `FlowEffects` type, durable workflow body, or process-global Baikai registry is changed
  by this plan.


## Idempotence and Recovery

Dependency resolution, formatting, and tests are repeatable. Fake-provider tests hold no
external resources. Runtime acquisition is safe to retry only according to each provider's
documented acquire contract; the bracket guarantees cleanup of resources it successfully
received but cannot reverse an arbitrary external emission performed inside `acquire` before
the provider returned its lease. Providers must therefore perform only acquisition steps and
return the inverse immediately.

If a test hangs, terminate it and inspect whether asynchronous exceptions were masked across
the callback; only bookkeeping and release-stack mutation may remain masked. If a release
fails, the runtime cannot claim exact recovery: it reports the aggregate, continues other
releases, and leaves operator remediation to that provider. Do not add a blind retry loop to
release unless the provider documents idempotent release. Revert the exact `shikumi-tools`
constraint and Cabal dependency together if the verified release cannot solve; do not add
`allow-newer` or a Git pin for an already released package.


## Interfaces and Dependencies

`Shikigami.Capability.Provider` must expose an interface equivalent to:

```haskell
data CapabilityScope = CapabilityScope
  { runId :: !Text
  , principal :: !Text
  , mode :: !ExecutionMode
  }

data CapabilityLease = CapabilityLease
  { descriptor :: !CapabilityDescriptor
  , tools :: ![SomeTool]
  , release :: !(IO (Either CapabilityReleaseError ()))
  }

data CapabilityProvider = CapabilityProvider
  { descriptor :: !CapabilityDescriptor
  , acquire
      :: !(CapabilityScope -> IO (Either CapabilityAcquireError CapabilityLease))
  }

newtype CapabilityProviderRegistry =
  CapabilityProviderRegistry
    (Map (CapabilityId, CapabilityRevision) CapabilityProvider)

mkCapabilityProviderRegistry
  :: [CapabilityProvider]
  -> Either CapabilityProviderRegistryError CapabilityProviderRegistry

withCapabilityOverlays
  :: Log.Logger
  -> CapabilityProviderRegistry
  -> CapabilityScope
  -> ResolvedCapabilitySet
  -> ToolRegistry
  -> (ToolRegistry -> Set CapabilityId -> IO a)
  -> IO (Either CapabilityRuntimeError a)
```

The callback's synchronous and asynchronous exceptions may propagate after cleanup rather
than being represented in `CapabilityRuntimeError`; acquisition, composition, and successful-
body release failures are the typed `Left` cases. The final implementation must document
that distinction.

`Shikigami.Capability.Tools` must expose collision-safe functions equivalent to:

```haskell
namespaceCapabilityTools
  :: CapabilityId
  -> [SomeTool]
  -> Either CapabilityToolError [SomeTool]

composeCapabilityTools
  :: ToolRegistry
  -> [(CapabilityId, [SomeTool])]
  -> Either CapabilityToolError ToolRegistry
```

`Shikigami.Behavior.Run` must expose:

```haskell
defaultToolTurnLimit :: Int

withCapabilityTools
  :: ResolvedCapabilitySet
  -> ToolRegistry
  -> BehaviorEnv
  -> BehaviorEnv
```

The existing `runBehavior` public shape may remain unchanged because the derived environment
carries the active registry and ids. `BehaviorEnv` constructors must use direct fields per
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`.

The implementation consumes `mori://shinzui/shikumi/packages/shikumi-tools` and
`mori://shinzui/baikai/packages/baikai`. As of 2026-08-22, the authoritative released pairing
is `shikumi-tools 0.3.0.2` with the existing `shikumi 0.3.0.2` and `baikai 0.5.0.0` cohort.
Reverify Hackage and upstream tags immediately before editing bounds. No MCP API is required.
