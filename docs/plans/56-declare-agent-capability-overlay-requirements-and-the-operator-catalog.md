---
id: 56
slug: declare-agent-capability-overlay-requirements-and-the-operator-catalog
title: "Declare agent capability overlay requirements and the operator catalog"
kind: exec-plan
created_at: 2026-08-22T15:12:03Z
intention: "intention_01m0n043cse67vxfj52w29t6zb"
master_plan: "docs/masterplans/11-add-agent-scoped-capability-overlays-without-changing-base-capabilities.md"
---

# Declare agent capability overlay requirements and the operator catalog

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, an agent declaration can request additional model-facing capabilities by
stable name while every existing declaration remains unchanged. For example, a one-off
repository agent may add `workspace.read` to `capabilityOverlays`; an operator-owned catalog,
not the agent file, selects the immutable provider revision and decides whether the agent's
principal may use it. Loading an old declaration produces an empty request list, and encoding
that declaration produces exactly the pre-change JSON bytes.

This plan is intentionally pure: it defines and verifies requests, descriptors, resolution,
and refusals but opens no connection and installs no tool. A test demonstrates the visible
contract by loading one proof agent, resolving its request to a descriptor, rejecting an
unknown or unauthorized request, and showing that an unchanged agent has no overlays. Plans
57, 58, and 59 consume this contract for runtime acquisition, durable pinning, and the first
one-off provider.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Add validated capability identifiers and public descriptor/resolution types.
- [ ] Add `capabilityOverlays` to the Dhall and Haskell agent declaration with an empty
      default and backward-compatible JSON.
- [ ] Implement collision-rejecting catalog construction and fail-closed pure resolution.
- [ ] Add loader, JSON-wire, catalog, and policy tests plus a proof declaration.
- [ ] Document the overlay/base boundary and update the dependency plan assumptions.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `lookup-agent` journals the entire `AgentDecl`, so this apparently configuration-only field
  is a persisted codec change. `docs/adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md`
  provides the exact safe pattern: omit the default on encode and restore it on decode.
- The existing MCP plan proposes raw server declarations in the agent manifest. A generic
  overlay should instead expose a stable capability name and keep endpoint, transport, and
  credential resolution in the operator provider registry. This prevents an agent-authored
  file from becoming authority or a secret-bearing runtime configuration source.


## Decision Log

Record every decision made while working on the plan.

- Decision: Name the declaration field `capabilityOverlays` and represent each request as a
  validated `CapabilityId`, encoded as text.
  Rationale: The name makes the additive boundary explicit; a text wire shape keeps Dhall
  declarations concise while a newtype prevents arbitrary text inside Haskell.
  Date: 2026-08-22

- Decision: A request names a capability but not a provider revision or provider config.
  Rationale: The agent says what it needs. The operator catalog chooses the current immutable
  definition, and a durable run later pins the resolved revision. Endpoints and credential
  references therefore cannot be smuggled through an agent declaration.
  Date: 2026-08-22

- Decision: V1 overlay requirements are mandatory and duplicates are errors.
  Rationale: Treating an absent provider as an optional no-op makes the model's tool menu
  depend silently on ambient state. Duplicates usually indicate a declaration or merge error
  and must not be normalized away.
  Date: 2026-08-22

- Decision: Descriptors classify each tool as `Observation`, `IdempotentMutation`, or
  `IrreversibleEmission`, although durable V1 admits only `Observation`.
  Rationale: Acquisition cleanup and tool-call reversal are different promises. Recording the
  operation class at the public boundary prevents a later adapter from presenting a write as
  harmless merely because its connection can be closed.
  Date: 2026-08-22

- Decision: Keep the catalog API pure and keep provider factories out of this plan.
  Rationale: Resolution and authorization should be testable without resources or `IO`.
  Plan 57 will pair immutable descriptors with acquisition functions in a separate registry.
  Date: 2026-08-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`schema/Agent.dhall` is the canonical declaration schema. Its `Agent` value has a `Type` and
a `default`; checked-in declarations normally use record completion such as `A.Agent::{ ... }`,
so a field in `default` reaches old manifests without editing every file. The Haskell mirror
is `shikigami-core/src/Shikigami/Agent/Decl.hs`. `AgentDecl` derives `FromDhall` but owns custom
`ToJSON` and `FromJSON` instances because the `lookup-agent` Keiro step persists it.
`shikigami-core/src/Shikigami/Agent/Loader.hs` loads Dhall declarations, and
`shikigami-core/test/Shikigami/AgentLoaderSpec.hs` proves declaration defaults and the old
JSON shape.

An **overlay** in this initiative is an additive set of model tools made available to one
behavior run. A **base capability** is an existing runtime authority such as Workflow,
Memory, Sink, Activity, Acknowledgement, profile resolution, provider selection, session, or
trigger processing. Base capabilities are not members of the overlay catalog and there is no
conversion from an overlay descriptor to a Flow effect. A **descriptor** is the serializable,
non-secret public identity of one immutable overlay revision. A **catalog** selects the
current descriptor for a requested capability. A later **provider registry** supplies the IO
factory for an exact descriptor; it is deliberately a different type.

The relevant local decisions are:

* `docs/adr/0007-a-resolved-profile-is-a-run-local-policy-snapshot.md`: resolve policy before
  dispatch and retain a complete run-local public decision.
* `docs/adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md`: additive
  defaulted fields disappear from default JSON and decode when absent.
* `docs/adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md`: Flow may not acquire
  ambient `IO`; this plan does not modify `Shikigami.Flow.FlowEffects`.

No cross-repository ADR governs this declaration boundary. The later tool representation is
provided by `mori://shinzui/shikumi/packages/shikumi-tools`, but this plan does not depend on
that package yet.


## Plan of Work

### Milestone 1: Public overlay vocabulary

Add `shikigami-core/src/Shikigami/Capability/Overlay.hs`. Define validated textual
`CapabilityId` and `CapabilityRevision` newtypes, `CapabilityOperationClass`,
`CapabilityToolDescriptor`, `CapabilityDescriptor`, `ResolvedCapability`, and
`ResolvedCapabilitySet`. Follow the direct-field convention from the repository
`AGENTS.md`; use fields such as `capability`, `revision`, `tools`, and `operationClass`, not
type-prefixed fields. Give every journal-bound type explicit JSON tests. `CapabilityId`
accepts lowercase dotted names matching `[a-z][a-z0-9.-]*`; reject empty identifiers,
uppercase text, whitespace, slashes, and consecutive dots. Revisions are non-empty,
operator-chosen immutable wire words.

`CapabilityDescriptor` contains only public, stable data: the capability id, revision, and
the logical names and operation classes of the tools it provides. It contains no endpoint,
credential value, open handle, callback, or live lease id. `ResolvedCapabilitySet` is sorted
by capability id so declaration ordering cannot change its serialized meaning. At the end of
this milestone the types round-trip and malformed ids fail at the boundary.

### Milestone 2: Backward-compatible agent requests

In `schema/Agent.dhall`, add `capabilityOverlays : List Text` to `Agent.Type` and
`capabilityOverlays = [] : List Text` to `Agent.default`. In
`shikigami-core/src/Shikigami/Agent/Decl.hs`, add
`capabilityOverlays :: ![CapabilityId]` to `AgentDecl`, export the overlay id type from its
own module, include non-empty lists in `ToJSON`, and decode a missing key as `[]`. Update all
direct `AgentDecl` constructors across source and tests with `capabilityOverlays = []`; do
not introduce a prefixed record selector or a compatibility accessor.

Extend `shikigami-core/test/Shikigami/AgentLoaderSpec.hs` so `agents/heartbeat.dhall` still
encodes to the exact old object and does not contain a `capabilityOverlays` key. Add
`agents/proof/capability-overlay.dhall` using
`capabilityOverlays = [ "workspace.read" ]`, and prove it loads as one validated id and
round-trips through JSON. Add malformed Dhall fixtures for an invalid id and a duplicate
request; the malformed id fails during decoding, while the duplicate is rejected by
resolution in Milestone 3.

### Milestone 3: Operator catalog and pure fail-closed resolution

Add `shikigami-core/src/Shikigami/Capability/Catalog.hs`. `mkCapabilityCatalog` rejects two
current definitions with the same `CapabilityId`, an empty tool set, duplicate logical tool
names inside one descriptor, and a descriptor whose tool name is empty. Do not use
`Map.fromList`'s last-wins behavior. Expose a lookup by id and a deterministic list operation
for diagnostics.

Implement `resolveCapabilityOverlays`. It takes the catalog, a `ResolutionSubject` describing
the principal, execution mode, and behavior kind, an authorization callback, and the
requested ids. It rejects duplicate requests, unknown ids, a missing identity when a request
is present, authorization refusal, non-`Skill` use, and a non-observation tool in durable
mode. It returns a sorted `ResolvedCapabilitySet` containing the complete selected
descriptors. An empty request list succeeds without consulting identity, policy, or catalog.
Resolution performs no acquisition and no logging of secret configuration.

Register a new `Shikigami.CapabilityOverlaySpec` in
`shikigami-core/test/Main.hs` and `shikigami-core/shikigami-core.cabal`. Cover empty identity-
free resolution, successful authorized resolution, duplicate/unknown/denied/non-Skill
refusals, durable mutation refusal, one-off mutation admission, catalog collision refusal,
and deterministic ordering. Add the two new library modules to the Cabal exposed-module
list.

### Milestone 4: Boundary documentation and consumer reconciliation

Add an ADR in `docs/adr/` recording that overlay capabilities are additive model tools,
declarations are requests rather than authority, provider configuration is operator-owned,
and Flow/base capabilities remain outside the overlay registry. Use the next available ADR
number discovered at implementation time. Update `docs/architecture/packages.md` only as
needed to name the new core contract and the leaf-package adapter ownership.

Add a dated revision note to
`docs/plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md` stating that its
`mcpServers` agent field is superseded by `capabilityOverlays` and that MCP becomes an
operator-registered provider. Do not change that plan's master-plan parent or claim that its
transport and per-action authorization work is complete. Add an equivalent dependency note
to `docs/plans/48-add-a-portable-one-off-repository-agent-harness.md`: its full workspace
sandbox remains there, but it consumes this catalog and Plan 57's registry rather than Plan
12's bespoke generic seam.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/shikigami`. Before using a dependency API
during implementation, refresh its location and current release evidence:

```bash
mori registry show shinzui/shikumi --full
mori registry docs shinzui/shikumi
shikumi_root=$(mori path mori://shinzui/shikumi)
git -C "$shikumi_root" ls-remote --tags origin
```

After Milestones 1 through 3, format and run the core suite inside the project shell:

```bash
nix fmt
nix develop --command cabal test shikigami-core-test -j1
```

Expected summary:

```text
Test suite shikigami-core-test: PASS
```

Inspect the compatibility-sensitive diff and ensure the default encoder condition is
visible:

```bash
git diff -- schema/Agent.dhall shikigami-core/src/Shikigami/Agent/Decl.hs \
  shikigami-core/test/Shikigami/AgentLoaderSpec.hs
git diff --check
```

Run the full repository validation after the ADR and plan reconciliations:

```bash
nix develop --command cabal test all -j1
nix flake check
```

Expected: every suite passes, existing manifests load without edits, and the proof manifest
loads with exactly `workspace.read`.


## Validation and Acceptance

The plan is accepted when all of the following observations hold:

* Loading `agents/heartbeat.dhall` produces `capabilityOverlays = []`, and its JSON value is
  byte-for-byte the same five-key object used before this change. Decoding that old literal
  produces the same declaration with an empty list.
* Loading `agents/proof/capability-overlay.dhall` produces exactly
  `[CapabilityId "workspace.read"]`, and JSON round-tripping preserves it.
* `mkCapabilityCatalog` refuses duplicate capability ids and duplicate tool names instead of
  selecting the last value.
* Empty resolution succeeds without an identity. A non-empty request with no identity,
  unknown id, duplicate id, denied policy, or non-`Skill` behavior returns a typed permanent
  refusal and acquires nothing.
* Durable resolution rejects a descriptor containing `IdempotentMutation` or
  `IrreversibleEmission`; one-off resolution may retain an authorized mutation descriptor
  for Plan 59's explicit local policy.
* Two equivalent request lists in different order resolve to equal, identically encoded
  snapshots.
* `Shikigami.Flow.FlowEffects` and all existing base-capability modules are unchanged.


## Idempotence and Recovery

Schema and source edits are additive and the tests are safe to repeat. `nix fmt`, Cabal
tests, and `nix flake check` may be rerun without changing runtime state. No database
migration or external resource is involved.

If the JSON compatibility fixture fails, do not update the old expected bytes. Restore the
conditional omission and missing-field default until the pre-change literal decodes and
re-encodes unchanged. If a new identifier rule proves too strict for a real requested name,
adjust `mkCapabilityId` and its tests before any descriptor is released; once an id appears
in a journal it is a durable wire word. If plan 12 or 48 contains implementation work that
has landed by then, reconcile against the implemented source and preserve it rather than
blindly applying the planned revision note.


## Interfaces and Dependencies

`Shikigami.Capability.Overlay` must expose an interface equivalent to:

```haskell
newtype CapabilityId = CapabilityId Text
newtype CapabilityRevision = CapabilityRevision Text

data CapabilityOperationClass
  = Observation
  | IdempotentMutation
  | IrreversibleEmission

data CapabilityToolDescriptor = CapabilityToolDescriptor
  { name :: !Text
  , operationClass :: !CapabilityOperationClass
  }

data CapabilityDescriptor = CapabilityDescriptor
  { capability :: !CapabilityId
  , revision :: !CapabilityRevision
  , tools :: ![CapabilityToolDescriptor]
  }

newtype ResolvedCapabilitySet = ResolvedCapabilitySet [CapabilityDescriptor]

mkCapabilityId :: Text -> Either CapabilityIdError CapabilityId
mkCapabilityRevision :: Text -> Either CapabilityRevisionError CapabilityRevision
emptyResolvedCapabilitySet :: ResolvedCapabilitySet
```

`Shikigami.Capability.Catalog` must expose an interface equivalent to:

```haskell
data ExecutionMode = Durable | OneOff

data ResolutionSubject = ResolutionSubject
  { principal :: !(Maybe Text)
  , mode :: !ExecutionMode
  , behavior :: !Behavior
  }

newtype CapabilityCatalog = CapabilityCatalog (Map CapabilityId CapabilityDescriptor)

mkCapabilityCatalog
  :: [CapabilityDescriptor]
  -> Either CapabilityCatalogError CapabilityCatalog

resolveCapabilityOverlays
  :: CapabilityCatalog
  -> (ResolutionSubject -> CapabilityDescriptor -> Either CapabilityResolutionError ())
  -> ResolutionSubject
  -> [CapabilityId]
  -> Either CapabilityResolutionError ResolvedCapabilitySet
```

The exact constructor exposure may be narrowed, but downstream plans must be able to encode
the complete resolved descriptors and compare them for equality. All record fields follow
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`.

This plan uses existing `aeson`, `containers`, `dhall`, and `text` dependencies only. It
does not add `shikumi-tools`, STM, async, MCP, a database table, or a generic `TypeRep`
registry. EP-2 owns the verified `shikumi-tools` dependency and live-provider functions.
