# 0129. The kernel owns primitives, and use cases ship as declarations or packs

Date: 2026-11-16

Status: accepted


## Context

MasterPlan 22 rebuilds Shikigami as a kernel where use cases are declared, not coded. Until
now the only way to add a Haskell flow or a Shikumi program was to edit `shikigami-core`: add a
module under `Shikigami/Flow/`, list it in the `.cabal` file and append it to
`Shikigami.Flow.flowRegistry`. Every use case therefore ended up in the core, next to the
primitives other features build on. The watchdog, initiative and practice-review subsystems,
the at-risk-customer teaching flow and the Kikan service clients all live there today.

Neither existing check could stop the next one. [ADR-75](0075-service-composition-has-a-closed-reviewed-module-budget.md)'s
root budget (`domainRoots` in `tools/style/module-ownership.json`) checks that every
`Shikigami.<Root>` module has a reviewed root, repository-wide and per root; it does not know
which package a module is in or whether a root is a use case. `PackageArchitectureSpec` reads
only the seven `shikigami-*` packages, so it cannot see a pack.

[ADR-128](0128-playbooks-are-the-default-extension-mechanism.md) made Dhall playbooks the
default way to add a procedure. This record covers what is left: where Haskell that a playbook
cannot express goes, and how the core is kept from growing back.


## Decision

`shikigami-core` owns primitives only: agent runs, execution, objectives, approvals, resources,
memory, workspaces, capabilities, authority, worker sessions, the output and trigger mechanisms,
coding agents, declared tools, playbooks, trust tiers and composition. A use case ships as a
declaration under `agents/` (a skill or a playbook) or as a *flow pack* outside the core.

* **The kernel list is closed and only shrinks.** The `kernel` section of
  `tools/style/module-ownership.json` maps every top-level namespace under
  `shikigami-core/src/Shikigami/` to `kernel`, `flow-pack` (EP-6 moves it) or `kikan-binding`
  (EP-10 moves it), and freezes every module of a leaving group, including leaving modules
  inside kernel roots (for example `Shikigami.Flow.Watchdog` and `Shikigami.Sink.KawaClient`).
  The kernel fitness check (`just kernel-fitness`, the `kernel boundary` group of
  `shikigami-core-test`) walks the source directory and fails on an unclassified namespace,
  a new module under a leaving namespace, a frozen module that no longer exists, an empty
  namespace and a kernel root that neither the root budget nor the composition list reviews.
  Its message for a new namespace names the playbook and pack routes. A genuine new primitive
  needs an ADR and a `kernel` entry.
* **A pack depends only on the SDK.** The SDK is two public sublibraries of `shikigami-core`:
  `flow-sdk` (what a flow body may import, with no `IOE` and no `Store`) and `pack-sdk` (what an
  interpreter needs). A pack is a Cabal library named `flow-pack-<name>` under `packs/` or in
  another repository; it may depend on no other Shikigami component, obeys the light-package
  exclusions, keeps its flow bodies in a `bodies` sublibrary that depends on `flow-sdk` alone,
  ships a test suite and no executable, and never takes the `shikigami-` prefix.
* **A pack flow is a body plus a pack-owned interpreter.** Only the interpreter may use IO; the
  body reaches the world through capabilities, as
  [ADR-13](0013-flow-bodies-reach-the-world-only-through-capabilities.md) requires of every
  body. The interpreter is given `IOE`, `Store`, the store's error channel and a read view of
  the run (`FlowRunContext`); it never receives the job or the kernel's composition record.
* **A flow's behavior under the kernel is declaration data.** The kernel does not know a flow
  by name. A flow declares its decision mode (`StrictDecisions` or `AdvisoryDecisions`) in its
  `FlowDef`, and the kernel selects the decision interpreter and the optional-slot rule from
  that value. The representative check against the watchdog (plan 130, M2) added this rule;
  the watchdog's remaining by-name branches leave the kernel with the watchdog (EP-6).
* **Executables compose registries.** Stock role packages compose only the builtin pack and
  never depend on a pack. A *distribution* package, which has executables and no library,
  composes role packages and packs. The check refuses a stock stanza that names a pack.
* **Pack labels belong to the pack.** A pack flow's step and capability labels carry the pack's
  prefix and leave the core keiro specification with the flow, together with its `patch`
  gates. `just keiro-diff` cannot see pack labels; until keiro can declare workflow fragments
  from separate packages, each pack ships a golden inventory of its labels in its own tests,
  and runs are drained before a flow moves (the ADR-27 pre-release exception). The inventory
  is derived from a real keiro journal, because keiro has no store-free interpreter of its
  workflow effect. Both gaps are raised with keiro as
  `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-61`.


## Alternatives rejected

**Extend the root budget.** The budget answers "is this root reviewed?", not "is this root a
use case, and which package may own it?". Encoding statuses there would mix two rules in one
list. The fitness check instead asserts that every kernel key is also reviewed by the budget, so
the two lists cannot drift.

**Check the `exposed-modules` list.** A planted file that nobody has listed yet would pass. The
check walks the directory.

**Supply the flow registry at composition and leave the rest.** `FlowEffects` is a closed row
with use-case effects, and `runFlowBehavior` stacks every interpreter for every flow, so moving
the list would not move the coupling. A pack flow carries its own interpreter instead.


## Consequences

`shikigami-core` cannot gain a use-case namespace without a failing test and an explicit ADR.
The leaving groups are named and can only shrink as EP-6 and EP-10 move them. The pack rules
hold vacuously until EP-5's second milestone creates `packs/`, the two SDK components and the
pack API; the SDK re-export lists are pinned in the policy now and checked once the components
exist.

[ADR-3](0003-a-seventh-package-keeps-one-off-agent-runs-light.md) still holds: packs and
distributions are not among the seven packages, and the "exactly seven" test keeps counting
only `shikigami-*` names.
[ADR-39](0039-deployment-roles-share-a-frozen-cabal-source-closure.md) still holds: the frozen
closure covers the seven packages, and packaging a distribution with Nix is a follow-up.

Mixed modules are not frozen, because part of each stays: `Shikigami.Directory` holds the Meibo
directory source and `Shikigami.Sink.Authorization` constructs the Kikan-En authorizer. EP-10
splits them.

This record amends ADR-75 (the kernel section is a second check beside the root budget) and
ADR-13 (a pack flow's body and interpreter are split across the SDK components).

The first pack with interpreters of its own (practice review, plan 131 M3) extended the
boundary in three ways, each with that consumer. A pack owns its configuration settings: it
lists `PackSetting` values in `FlowPack.settings`, an executable composed with the pack
accepts and validates those keys, and a stock executable still refuses them as unknown, so
the configuration surface stays closed per composition. `FlowRunContext` carries what an
interpreter reads of its run beyond the declaration and identity: the job's own identity, the
delegating run, the validated pack settings, the kernel's stores and the grant source. And a
pack reaches a model only through `RunModel`, one JSON-object completion the kernel builds
from the run's behavior environment after its sanctioned profile narrowed it; no pack holds
a provider or a registry.


## References

* [docs/plans/130-move-the-extension-boundary-out-of-shikigami-core-with-flow-packs-and-an-architecture-fitness-check.md](../plans/130-move-the-extension-boundary-out-of-shikigami-core-with-flow-packs-and-an-architecture-fitness-check.md)
  — the implementing plan.
* [docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md](../masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md)
  — the initiative and the kernel classification.
* `shikigami-core/test/Shikigami/KernelBoundarySpec.hs` — the fitness check.
