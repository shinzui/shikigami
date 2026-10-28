---
id: 96
slug: provide-governed-mutable-repository-workspaces-for-durable-agents
title: "Provide governed mutable repository workspaces for durable agents"
kind: exec-plan
created_at: 2026-10-28T20:10:48Z
intention: "intention_01m6224erjenqvkc30b0f0e6rc"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-28T20:10:48Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T20:13:52Z
      mode: "implement"
      note: "Ground IR-11 implementation milestones and record missing authorization source blocking the baseline build"
---

# Provide governed mutable repository workspaces for durable agents

This is a living ExecPlan. Keep Progress, discoveries, decisions and outcomes current.

## Purpose / Big Picture

Implement [IR-11](../improvement-requests/provide-governed-mutable-repository-workspaces.md): a durable coding agent receives an operator-approved repository identity, edits an isolated workspace, validates its changes and returns a local commit with bounded evidence. A coordinator can combine exact worker commits in a separate workspace and transfer ownership without allowing the former worker to keep writing. All nine IR-11 acceptance cases remain required. This plan does not implement IR-13 objective tracking, public HTTP addressing, push or pull-request publication.

## Progress

- [ ] Milestone 1: Admit canonical repository identities and immutable bases; persist assignment-to-workspace bindings and prove isolation and recovery of allocation.
- [ ] Milestone 2: Enforce fresh exact authority and conditional ownership for contained reads and structured edits; refuse malicious paths without effects.
- [ ] Milestone 3: Execute bounded validation and local Git operations with retained operation receipts and restart reconciliation.
- [ ] Milestone 4: Install declared mutation providers in durable workers and prove replay-safe end-to-end dependency upgrades.
- [ ] Milestone 5: Fence real processes during handoff, integrate revision-pinned artifacts and safely clean terminal workspaces.
- [ ] Milestone 6: Qualify all IR-11 acceptance cases, update operational documentation and consumer plan gates, and distill durable decisions.

Milestone 1 is in progress: `Shikigami.Workspace.Catalog` now rejects duplicate/unknown identities, caller paths, mutable or unapproved revisions and malformed operator configuration. It preserves an opaque resolved source and exact base. Durable assignment bindings and real worktree allocation/isolation remain to implement. The initial missing Kikan-En packages were restored from upstream commit `16704290d527d413568bfa40c983f5c3604c35c8`; the baseline core build passes. FRIC-14 is resolved. Seven catalog tests and all 511 core tests pass (2026-10-28), including default parallelism after isolating authorization fixture provider keys (FRIC-15).

## Surprises & Discoveries

The baseline build fails before solving dependencies because `kikan-en-contract` and `kikan-en-client` are absent from the checkout referenced by `cabal.project`. The registered producer checkout has only one worktree. A clean fast-forward to the verified upstream master commit `16704290d527d413568bfa40c983f5c3604c35c8` restored both packages and the baseline core build. FRIC-14 is resolved.

## Decision Log

2026-10-28: Own IR-11 in a standalone plan. Plan 48's portable one-off command has different lifecycle and package constraints; plan 84 consumes workspace fences but does not implement them. This plan supplies the actual durable provider while retaining those ownership boundaries.

2026-10-28: Use the existing accepted operation/attempt identities and session transfer contracts. A timeout, queue lease expiry or session idle state never proves a process stopped. Unknown operations keep the workspace unavailable to successors until reconciliation proves settlement.

## Outcomes & Retrospective

The pure repository admission boundary is implemented; no full milestone has passed. FRIC-14 was resolved by restoring upstream dependency source and verifying the baseline core build. The provider, durable workspace binding, effect recovery and acceptance fixtures remain outstanding; IR-11 remains undelivered. FRIC-15 was resolved by giving the typed and dynamic authorization fixtures separate global provider keys; the parallel core suite passes all 511 tests. Existing authorization ADR constraints remain unchanged; no new durable architectural decision is claimed by this pure admission slice.

## Context and Orientation

A worktree is a separate set of mutable repository files and a separate Git index. A workspace is the durable provider's retained identity, worktree, owner and operation history. An assignment is one accepted piece of work; it has a stable identity distinct from the continuing session and from the process executing it. An ownership epoch is a monotonically increasing integer used to reject writes from an earlier owner. A fence is proof that earlier writes and their processes cannot continue, not merely an expired lease.

`shikigami-agent/src/Shikigami/Agent/Capability/Workspace.hs` supplies confined observation tools to one-off runs. It is not a durable mutation provider and must remain compatible. `shikigami-core/src/Shikigami/Capability/Provider.hs` owns descriptors, exact provider revisions, lease acquisition, composition and generic tool authorization. `CapabilityScope` contains run, principal and mode; derive assignment bindings from authoritative retained state rather than adding caller-selected filesystem paths to that scope.

`shikigami-workers/src/Shikigami/Workers/Config.hs` is the durable composition root. `shikigami-core/src/Shikigami/Execution/Executor.hs` owns actual attempts and exposes `ExecutionRuntime.withTools` with accepted operation context. `Shikigami.Execution.Store` and `Shikigami.Execution.Transcript` retain outcomes and protected payload references. New workspace IO must integrate there, preserving operation identity and receipts across a crash between effect completion and acknowledgement.

`shikigami-core/src/Shikigami/WorkerSession/Transfer.hs` defines `WorkspaceRef`, `TransferIntent`, `FenceProof` and `WorkspaceProvider`. Its `reconcile` must prove old-owner settlement; `admitWrite` must conditionally check the owner and epoch at the actual effect boundary. A separate IR-13 ownership provider supplies objective receipts. Do not fabricate those receipts here or mark plan 84 complete without them.

[ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md) requires fresh Kikan-En authorization immediately before protected IO. [ADR 0060](../adr/0060-safe-recovery-spends-new-attempts-and-retains-independent-receipts.md) retains independent attempt receipts and conservative reservations after uncertainty. [ADR 0063](../adr/0063-handoffs-establish-epochs-only-after-fences-and-versioned-owner-receipts.md) establishes a successor only after a matching fence and objective-owner receipt. These constraints apply to all provider operations. Follow `docs/workflow-versioning.md` for any workflow-body edits, declaring patch IDs in `domain/` and running `just keiro-gate`.

## Plan of Work

Milestone 1 adds `Shikigami.Workspace.Catalog`, `Shikigami.Workspace.Types` and a durable store in `shikigami-core`, with migrations owned by `shikigami-migrations`. The operator catalog maps a canonical identity to a local approved source, immutable allowed base revisions and a policy revision. Reject duplicate identities rather than selecting the first match. Validate immutable full object identities; resolve an omitted base only through an operator-configured immutable default. Persist run, optional session/assignment, root, principal, owner epoch, repository, base and policy identity. Allocate a provider-generated workspace resource and directory, never interpolate a model-supplied path. Reserve the binding before creating the worktree and reconcile that same reservation after restart. Concurrent allocations for the same assignment converge; distinct assignments have distinct files and indexes. Test duplicate delivery, changed bindings and allocation interruption against real temporary Git repositories.

Milestone 2 adds contained operations in `Shikigami.Workspace.Provider`. Resolve operation targets under the retained workspace, reject absolute paths, traversal, Git metadata and symlink components, and prevent path substitution races at the IO boundary. Require lifecycle admission, declared mutation overlay, fresh exact authorization binding repository/base/operation/resolved target and conditional owner epoch. Existing session command authorization in `Shikigami.WorkerSession.Capability.authorizeExact` demonstrates digest-bound capability actions; verify the actual Kikan API before choosing the workspace action encoding. Perform an early producer/consumer test with the real verifier: changing any coordinate must invalidate authorization. Keep permit bytes out of journals. Edits carry expected content hashes; receipts distinguish already-applied output from conflicts. Bound input/output and retain full content only in protected payload storage. Repository instructions must be discovered from the root through the target directory, pinned by content identity and applied before a write; conflicts with parent/operator instructions refuse rather than expanding authority.

Milestone 3 supplies a supervised process owner with argument-vector execution, exact operator command rules, controlled environment, contained working directory, OS containment, timeout, bounded output and process-group cancellation. A command allowlist alone does not contain repository-controlled build scripts. Fail closed where required containment is unavailable. Persist operation and attempt identity before launch and retain completion receipts independently of the caller. On restart, observe the original execution; never redispatch an uncertain mutation just because its claim expired. Reconcile all descendants before reporting settlement. Git status/diff are bounded observations; commits disable hooks and external helpers and write only the isolated local repository. Record exact tree/commit identities and changed paths. Commit recovery inspects the accepted operation's retained parent/tree/result rather than creating a second commit.

Milestone 4 wires catalog, providers, fresh authorizer, resource policy and recovery adapters into the durable worker composition root. Add separate mutation/process/Git capabilities; absence of the declaration must mean absence of those tools. Do not silently classify mutating tools as observations or idempotent effects without provider recovery evidence. Retain the read-only overlay's identity and semantics. Build a deterministic provider fixture that addresses an upgrade agent, edits a dependency constraint, runs a fixture validation command, commits and returns structured evidence through the normal durable execution path. Redeliver and restart at effect/receipt boundaries. Assert one logical terminal result and one committed change.

Milestone 5 implements `WorkspaceProvider` against real workspaces and supervised processes. Freeze old-owner admission before waiting for pending operations; retain a deduplicated transfer intent and matching fence receipt. Unknown processes leave transfer unresolved. Successor writes require fresh authority and established ownership; delayed old-owner callbacks fail. Provide a separately allocated integration workspace consuming exact worker commits and bases, report conflicts explicitly, and validate the resulting exact integrated tree. Add operator list/cleanup commands that consult authoritative terminal ownership, conditionally mark cleanup pending and remove only the retained provider-owned worktree. Retain idle sessions and active runs; recover interrupted cleanup without broad directory deletion.

Milestone 6 adds `tests/workspace/` fixtures and operator documentation in `docs/operations/workspaces.md`. Exercise all acceptance cases below and update IR-11's status only with evidence. Update plans 84 and 86 and MasterPlan 14 to point to this provider without claiming their unrelated acceptance gates passed. Review decisions for a new ADR, preserving the existing filesystem ADR convention. Triage friction when completion is actually established.

## Concrete Steps

Run from the repository root. The configured Kikan-En checkout was restored to upstream commit `16704290d527d413568bfa40c983f5c3604c35c8`, which compiles against this project's existing imports. Discover dependencies with Mori and verify released registry versions and upstream tags before changing any pins; this plan does not authorize guessing compatible versions.

```bash
mori registry show shinzui/kikan-en --full
mori registry docs shinzui/kikan-en
nix develop --no-write-lock-file -c cabal build shikigami-core shikigami-workers
```

Add focused tests named `workspace` to the affected Cabal suites and real database/process cases to the existing PostgreSQL harness. Use the harness's established database setup rather than assuming a live service. The intended focused command is:

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-test --test-options='-p workspace' --test-show-details=direct
```

Require a nonzero count of workspace tests; a successful empty selection is not evidence. Record the actual PostgreSQL and fixture commands here as their executable interfaces land. At the final candidate:

```bash
nix develop --no-write-lock-file -c cabal build all
nix develop --no-write-lock-file -c cabal test all --test-show-details=direct
just keiro-gate
nix flake check
git diff --check
```

Expected: successful build, passing tests including real restart/fencing cases, unchanged historical replay behavior and no formatting errors. Every implementation commit carries this plan's `ExecPlan:` trailer and `Intention: intention_01m6224erjenqvkc30b0f0e6rc`.

## Validation and Acceptance

The canonical fixture upgrade must run through the durable worker, return a local commit, changed paths and validation statuses, and leave the source checkout untouched. Two simultaneous assignments must have different worktrees and indexes. Unknown identities, disallowed bases, traversal, symlink escapes, unapproved commands and denied/expired authorization must produce bounded refusals before effects. An undeclared mutation capability must expose no mutation tools.

Duplicate delivery and restart during validation must resume the same workspace and accepted operation, preserving receipts and producing one terminal result. Fault injection must cover the gaps before dispatch, after protected mutation, after process completion and before receipt acknowledgement. Retrying a committed edit or commit must not duplicate it. Cleanup must refuse active and idle-continuing workspaces and remove only a terminal fixture's exact owned directory.

Two worker commits must integrate in a third workspace; record bases, artifacts, resulting tree/commit and test statuses on that exact combined tree. Include a conflict case and a case where worker-local checks pass but integration fails. Handoff must hold a real process in flight, refuse successor writes until reconciliation, survive provider restart, preserve accepted files/uncertain operations and reject late old-owner writes. Real IR-13 checkpoint integration remains separately owned; passing workspace-side tests alone cannot close the whole continuing-session request.

Terminal evidence contains repository/base/result identities, changed paths, bounded command identities/statuses and a bounded summary. Logs and workflow journals must exclude credentials, full patches, tool inputs, unrestricted command output and bearer permits. Inspect retained journal and log fixtures to verify this exclusion.

## Idempotence and Recovery

Never mutate the operator's source checkout. Use temporary fixture repositories for destructive tests. Store stable assignment bindings and operation fingerprints before external work. Repeated matching requests converge; conflicting requests refuse. Unknown completion blocks reuse, transfer and cleanup until the process owner supplies evidence. Do not infer process death from a database timeout or attempt expiry. Explicit terminal cleanup uses a retained resource identity and a conditional state transition; never scan and delete arbitrary directories. Migrations must preserve existing journals; roll forward if a new workflow patch has executed.

## Interfaces and Dependencies

Shared types and stores belong in `shikigami-core`; durable runtime composition belongs in `shikigami-workers`; schema changes belong in `shikigami-migrations`. Keep one-off executable dependencies in `shikigami-agent`. Reuse the core `OperationId`, `AttemptId`, `ExecutionRootId`, `WorkerSessionId`, `AssignmentId`, `AgentIdentity`, `WorkspaceRef` and transfer proof contracts rather than introducing alternative identity or accounting stores.

The dependency owner is `mori://shinzui/kikan-en`, specifically its contract and client packages. The current project references local source, restored in this session to verified upstream commit `16704290d527d413568bfa40c983f5c3604c35c8`. Existing process, filesystem, serialization and database dependencies should be reused after source inspection through Mori. Select a new dependency only when the containment/recovery requirements justify it and authoritative releases have been verified.
