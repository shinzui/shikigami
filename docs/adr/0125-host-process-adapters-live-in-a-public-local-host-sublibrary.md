# 0125. Host-process adapters live in a public local-host sublibrary

Date: 2026-11-15

Status: accepted


## Context

`shikigami-core`'s domain library links no process library: the package-architecture test treats
`process` as a provider adapter and keeps it in leaf packages. The local-operator tier of
[ADR 0124](0124-authority-is-selected-by-trust-tier-and-the-local-operator-grants-a-declaration-once.md)
needs host processes all the same: `git` and `mori` to find checkouts, `git worktree` to give a run
its own worktree, an approved command launched under a deadline, and `git commit` for the run's
work. The light commands in `shikigami-agent` compose that tier today, and EP-2 of MasterPlan 22
lets `shikigami-worker` compose it too. `shikigami-workers` may not depend on `shikigami-agent`,
and [ADR 0039](0039-deployment-roles-share-a-frozen-cabal-source-closure.md) fixes the seven
packages.


## Decision

The host adapters of the local-operator tier live in the public sublibrary
`shikigami-core:local-host` (`shikigami-core/local-host/`), the same shape as the existing
`shikigami-core:inspection`:

* `Shikigami.Workspace.Local.Launcher.hostProcessLauncher` — one approved command in its own
  process group with a cleared environment, both streams drained while it runs and bounded, and
  the whole group terminated then killed at the deadline.
* `Shikigami.Workspace.Local.Worktree.openRunWorktree` — the run's worktree and branch, derived
  from the run and the repository, or the checkout itself under `InPlace` with an exclusive lock.
* `Shikigami.Workspace.Local.Adapters` — `workspace.edit`, `workspace.exec` and `workspace.git`
  at revision `local-1`, and the workspace host that admits them under the `LocalHostFilesV1`
  file policy and the provider `shikigami.workspace.local/1`.

The domain library holds only the ports and values they implement: `Shikigami.Workspace.Launch`
(`ProcessLauncher`, `LaunchRequest`, `WorktreeRoot`) and the approvals module's
`CheckoutResolver`. A composition chooses an implementation; the light commands use
`local-host`, and the checkout resolver is `Shikigami.Agent.Checkout` in `shikigami-agent`.


## Alternatives rejected

**Link `process` into the domain library.** Rejected because the rule that keeps provider
adapters out of the kernel would then have one exception for every future host adapter.

**Put the adapters in `shikigami-agent`.** Rejected because the worker could not reuse them
without a forbidden package edge, and EP-2 needs them there.

**A new package.** Rejected because ADR 0039 freezes the seven packages, and a sublibrary inside
`shikigami-core` gives the same boundary without changing the closure.


## Consequences

A local tool's effects are checked by the compiler to stay out of the domain library. A pack or
distribution that needs host processes depends on `shikigami-core:local-host` explicitly.

The persisted execution snapshot now accepts the local provider beside `shikigami.workspace/1`,
and `FilePolicy` gains `local-host-v1`; both are additive. A run's worktree is opened when its
ports are resolved, so a run that fails before its first tool still leaves its branch; discard it
with `git worktree remove` and `git branch -D` (a cleanup command is future work).


## References

* [ADR 0124](0124-authority-is-selected-by-trust-tier-and-the-local-operator-grants-a-declaration-once.md)
  — the tier these adapters serve.
* [ADR 0039](0039-deployment-roles-share-a-frozen-cabal-source-closure.md) — the frozen
  seven-package closure.
* [docs/plans/126-run-declared-agents-on-the-operator-s-own-machine-through-a-local-operator-trust-tier.md](../plans/126-run-declared-agents-on-the-operator-s-own-machine-through-a-local-operator-trust-tier.md)
  — the implementing plan.
