# 0133. The v1 baseline names every public surface and a change obeys its stability level

Date: 2026-11-18

Status: accepted. Ends the pre-release exception of
[ADR-27](0027-the-first-release-establishes-one-clean-durable-baseline.md).


## Context

MasterPlan 22 rebuilt Shikigami as a kernel that other people and other packages write
against: agent declarations, playbooks, operator files, a pack SDK, kernel ports, an HTTP
API, a durable wire format and a handful of commands. Until
[plan 136](../plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md)
none of those surfaces was named in one place. None had an owner or a stability promise,
and nothing failed when one changed by accident. `shikigami-core` exposed 388 modules, so
in practice everything was public.

[ADR-27](0027-the-first-release-establishes-one-clean-durable-baseline.md) let an unreleased
declaration or workflow shape be replaced without a compatibility path. It expired "at the
first release or deployment". Shikigami has had neither, so the exception never ended on
its own, and every later plan in the initiative leaned on it. On 2026-11-15 the user decided
that the exception ends at an explicit API baseline gate, not at the first real run. The
user also decided to freeze in two steps, so that the operator's routine agents and
playbooks stop breaking before the core restructuring is done.


## Decision

**One inventory names every public surface.** `api-baseline/surfaces.dhall`, typed by
`api-baseline/Surface.dhall`, lists 19 surfaces. Each entry has an owner (the plan that
decides its changes), a stability level, a one-sentence rule, a check, the freeze it belongs
to and its enforcement. `just api-baseline` runs every check. Exit 1 means an enforcing
surface has a finding, and exit 2 means a check could not run, which is never reported as
clean. The policy is [the API baseline](../architecture/api-baseline.md).

**A change obeys its surface's stability level.** For a *stable* surface, a breaking change
needs a new ADR, a compatibility path and a re-pin in the same commit. The path might be a
Dhall default, a `patch`, a codec that still reads the old bytes or a route kept for one
release. For a *provisional* surface, a breaking change needs a Decision Log entry in the
owning plan, an updated corpus and a re-pin. An *internal* module has no check and no
promise, and a pack may not import it. On every level, an additive change is a reviewed
re-pin.

**Each surface has one check kind.**

| Check | Surfaces |
| --- | --- |
| `DhallSchema`: a semantic hash, plus a corpus of real declarations that must keep loading through the runtime's loaders | agent declaration, playbook bundle, local-operator file, tools ceiling, `local.report` helper, Kikan output Dhall |
| `JournalCodec`: the pinned JSON of each corpus declaration keeps decoding to the same value | agent journal codec, pack declaration codec |
| `CliHelp`: the `--help` text of listed verbs; a removed option or subcommand is breaking | `shikigami-agent-run`, `shikigami-local`, `shikigami` |
| `ExportList`: exported names from GHC interface files, with constructors and fields as `Type.member` | flow SDK, pack SDK, kernel ports, pack service ports, Kikan output helpers |
| `OpenApi`: the frozen description against the one the code generates, with asymmetric request and response rules | HTTP API |
| `KeiroGate`: `just keiro-gate` since the baseline tag | durable wire |
| `ExposedSet`: the modules `shikigami-core`'s main library re-exports | core exposed modules |

**The baseline froze in two steps.**

- The declaration baseline, at `c54933b5` on 2026-11-17, covers what an operator writes
  and runs:
  - stable: the agent declaration, its journal codec, the playbook bundle, the
    local-operator file and the `local.report` helper
  - provisional: `shikigami-agent-run`, `shikigami-local` and the tools ceiling
- The kernel baseline, at `89151747` on 2026-11-18 and tagged `api-baseline-v1`, covers
  what a pack or a service writes against:
  - stable: the flow and pack SDKs, the kernel ports, the pack service ports, the durable
    wire, the HTTP API, the `shikigami` admin command and the pack declaration codec
  - provisional: the Kikan output helpers and their Dhall, both owned by the binding, and
    the core's exposed-module set

Every surface now enforces.

**The compiler holds the core's boundary.** Every module of `shikigami-core` compiles in
the private sublibrary `shikigami-core:internal`. The main library re-exports exactly the
273 modules that a consumer imports, as `api-baseline exposure --needed` computes them. A
sibling package cannot name a private sublibrary.

**ADR-27's exception has ended.** From the kernel baseline on, the rules of
[workflow versioning](../workflow-versioning.md) apply without exception. A declared
workflow body changes only behind a `patch` or a new name, and a journaled value keeps
decoding. The durable-wire entry's `since` is the tag, so `just api-baseline` compares
every later change to the domain specification with the baseline itself, not with the
previous commit.


## Alternatives rejected

- **One freeze at the end.** That would have left the declaration, the playbook format and
  the operator files changeable throughout the core shrink and the Kikan move. The
  surfaces the operator uses every day would have kept breaking for the whole initiative.
- **Treating every schema hash change as breaking.** A new field with a default changes
  the hash and breaks nobody. Contributors would learn to re-pin without reading. Instead,
  the hash makes a change visible and the corpus decides whether it broke anything.
- **Hoogle text for export lists.** That needs documentation built for the whole dependency
  closure. Interface files exist after any build and list re-exports from other packages.
- **Moving unneeded modules to `other-modules`.** The core's own tests import internal
  modules. The private sublibrary keeps them compiling, and the compiler still refuses a
  sibling.
- **Ending the exception at the first real run.** The user rejected this on 2026-11-15. A
  run proves a path works. It does not say which shapes are promised.


## Consequences

- A rename in a schema, a dropped SDK export or port field, a removed route, a removed
  admin verb or an unpatched step label fails `just api-baseline`, and its message names
  the rule and the deliberate path. Each was demonstrated on 2026-11-18 (plan 136, M4).
- Breaking a stable surface now costs an ADR and a compatibility path. A plan that needs
  one should budget for it, or should first move the surface to provisional through a
  Decision Log entry and an ADR.
- Plans that read `git tag --list` as evidence that workflow bodies may still change will
  now find `api-baseline-v1`, and must follow the unconditional rules.
- Pack-owned workflow labels are still outside `just keiro-gate`, until keiro can declare
  fragments from separate packages
  (`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-61`). A pack's own golden
  inventory guards them.
- The inventory is a living file. An owning plan registers a new surface in report mode in
  the commit that ships it, and turns it to `Enforce` once its shape is promised.


## References

- [The API baseline](../architecture/api-baseline.md): the policy and the commands.
- [Plan 136](../plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md),
  which built the inventory and both freezes.
- [MasterPlan 22](../masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md),
  whose "Baseline" acceptance this is.
- [ADR-27](0027-the-first-release-establishes-one-clean-durable-baseline.md), whose
  exception this ends.
- [ADR-11](0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md) and
  [ADR-12](0012-a-declared-workflow-body-only-grows-behind-a-patch.md), now unconditional.
- [ADR-75](0075-service-composition-has-a-closed-reviewed-module-budget.md) and
  [ADR-129](0129-the-kernel-owns-primitives-and-use-cases-ship-as-declarations-or-packs.md),
  the module budget and the kernel classification beside which the exposed set is checked.
- [The kernel invariants audit](../architecture/kernel-invariants.md).
