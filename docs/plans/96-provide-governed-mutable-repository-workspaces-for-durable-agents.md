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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-29T13:12:10Z
      mode: "update"
      note: "Resolve review findings with exact durable workspace adapters and attempt context, a qualified Linux/systemd supervisor design, and frozen scoped repository instructions; align acceptance and ADRs."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-29T13:51:12Z
      mode: "implement"
      note: "Implement durable assignment reservations and private Git allocation with recovery fixtures"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-29T14:45:11Z
      mode: "implement"
      note: "Implement frozen repository instruction admission, exact adapter registry and actual-attempt dispatch plumbing"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-29T13:02:04Z
      verdict: "changes-requested"
      note: "Verified catalog tests and repository contracts; specify governed mutation admission/context plumbing, containment and supervisor recovery design, and pinned repository instruction delivery."
---

# Provide governed mutable repository workspaces for durable agents


This is a living ExecPlan. Keep Progress, discoveries, decisions and outcomes current.

## Purpose / Big Picture


Implement [IR-11](../improvement-requests/provide-governed-mutable-repository-workspaces.md): a durable coding agent receives an operator-approved repository identity, edits an isolated workspace, validates its changes and returns a local commit with bounded evidence. A coordinator can combine exact worker commits in a separate workspace and transfer ownership without allowing the former worker to keep writing. All nine IR-11 acceptance cases remain required. This plan does not implement IR-13 objective tracking, public HTTP addressing, push or pull-request publication.

## Progress


- [x] Milestone 1: Admit canonical repository identities and immutable bases; persist assignment-to-workspace bindings and prove isolation and recovery of allocation.
- [x] Milestone 2: Enforce fresh exact authority and conditional ownership for contained reads and structured edits, with scoped repository instructions frozen into model context; refuse malicious paths without effects.
- [ ] Milestone 3: Qualify Linux/systemd containment and independent process supervision, then execute bounded validation and local Git operations with retained receipts and restart reconciliation.
- [ ] Milestone 4: Install declared mutation providers in durable workers and prove replay-safe end-to-end dependency upgrades.
- [ ] Milestone 5: Fence real processes during handoff, integrate revision-pinned artifacts and safely clean terminal workspaces.
- [ ] Milestone 6: Qualify all IR-11 acceptance cases, update operational documentation and consumer plan gates, and distill durable decisions.

Milestone 1 verified (2026-10-29): `Workspace.Types` and `Workspace.Store` retain immutable assignment/run/root/principal/owner/epoch/repository/base/policy/source/storage-root bindings in PostgreSQL. `shikigami-workers/src/Shikigami/Workspace/Allocation.hs` allocates private Git copies with separate provider-owned metadata and atomically publishes complete staging directories. Seven real PostgreSQL/Git fixtures pass, covering concurrent reservation/allocation, conflicting coordinates, independent files/indexes, asynchronous worker interruption before publication, lost acknowledgement, non-commit refusal, symlink substitution and missing-ready-directory refusal. The source fixture compares all regular file bytes, permissions and modification times including Git metadata. The workers focused command passes seven cases, the full workers suite passes 106 cases, the migration definition suite passes five cases, and the core suite passes all 511 cases. Allocation is a trusted internal primitive; no mutation tools or worker admission are installed yet.

Milestone 2 verified (2026-10-29): `Workspace.Instructions` validates complete, scope-labelled, hash-checked instruction bundles; the workers' `Workspace.InstructionLoader` reads regular instruction blobs from the admitted immutable Git tree with bounded capture and refuses symlinks and budget overflow. `Execution.Start.admitWorkspaceSkillExecution` freezes the bundle and binding identity in protected snapshots; historical snapshots omit the new optional field. The actual model-request/restart fixture passes, and context selection and recorded summaries preserve the fixed prompt or refuse insufficient budget. `DispatchContext` now carries the real attempt/owner/generation, verified against retained executor state in the native dispatch fixture. The exact durable-adapter registry, governed pure resolver and live tool path are implemented with negative and description-only tests; no production mutation adapter is installed by default.

Validation for this partial milestone: all 520 core tests and 108 worker tests pass; all 48 execution transcript PostgreSQL cases pass. Focused workspace selections pass 16 core cases, nine worker cases (including a new approved base admitting a new instruction identity while the old assignment remains pinned), and five PostgreSQL cases. `git diff --check` passes. These results do not prove an authorized filesystem mutation, provider fencing or a qualified supervisor.

The concrete provider is now implemented (2026-10-29): `Workspace.FileProvider` checks the protected snapshot, accepted input, exact adapter/schema/recovery binding, actual attempt claim, lifecycle and conditional workspace owner at the effect boundary. Descriptor-relative native IO rejects symlink, hardlink, FIFO, traversal, metadata and substituted targets. Whole-file edits compare expected content hashes, serialize with a private OS lock, and retain prepared/applied/refused receipts before acknowledging publication. Recovery preserves the original receipt and settles its actual attempt through the existing late-receipt owner without rewriting files or inventing usage. Real Kikan producer/verifier tests invalidate changed action coordinates. The actual accepted-executor fixtures exercise both overlay gates and protected read/edit results, lost acknowledgement, frozen ownership, denied authority, conflicting content, hostile input, stale generation and an independently held lock.

Validation for this boundary: all 522 core tests, 125 workers tests and five migration tests pass; focused core workspace selection passes 18 cases and all 48 ExecutionTranscript PostgreSQL cases pass. `tests/workspace/probe-files-apple.sh` compiles the same native C boundary with warnings denied in a disposable Apple Linux container and passes six cases, including SIGKILL of a separate lock owner. This is native file-boundary evidence, not independent process-supervisor qualification. Native file admission explicitly retains `ascii-exact-v1`; the loader qualifies every base path for ASCII spelling and case-unambiguous directory prefixes, preventing host case/normalization aliases from bypassing frozen scopes. Historical admissions omit this field and gain no file authority. UTF-8 file contents remain supported; creation requires an existing directory and content is limited to 256 KiB.

The early parent/child integration now passes (2026-10-29). `Workspace.Settings`, workers `Workspace.Host`/`Workspace.ConfiguredHost`, the optional `workspaces` Settei setting and `Workers.Config` install the file adapter only for exact operator agent/principal grants, approved immutable bases, reviewed complete instruction digests and bounded path-prefix restrictions. The restriction contents form the retained policy identity; reusing a human revision label cannot reinterpret pending work. Allocation obtains fresh target-bound C13 authority before source IO. The real `shikigami-governed-workspaces-v1` workflow patch uses distinct governed resolution/admission labels. Historical patch snapshots and existing observation providers retain their original branches. A real parent, execution child and native file fixture passes restart/duplicate delivery with one edit and the pinned instructions in every model request. Additional cases cover old-branch refusal, principal mismatch, unreviewed instruction digest, denied allocation authority and configured write restrictions.

Current validation: all 525 core tests and 136 worker tests pass, and the updated Apple Linux native probe passes six cases. The checked DSL differ classifies the new workflow patch as additive with unchanged stored-data replay. All 353 PostgreSQL cases pass with two test threads. `nix develop --no-write-lock-file -c just keiro-gate 41cd161` passes every checked specification, scaffold/determinism, additive compatibility and conformance gate. Agent and worker leaf packages and all their executables build. Milestone 2 is complete. Run database suites with `--test-options=-j2`; default host parallelism exceeds the shared fixture connection capacity (FRIC-17).

Milestone 3 substrate experiment (2026-10-29): `tests/workspace/probe-root-apple.sh` passes 13 named checks in a disposable Apple Linux container, without host mounts or credentials. It installs Nix 2.26.3 and sudo, copies a tool closure from the repository-pinned nixpkgs revision through Nix itself into an immutable systemd `RootDirectory`, and executes it as an unprivileged workspace identity. It verifies effective private PID and privilege settings, empty effective/bounding capabilities, workspace/scratch writes, host/sibling/root-write/network/mount denials, a detached writer surviving its intermediate command parent, and whole-cgroup stop despite SIGTERM refusal. The guest run has a 300-second ceiling and always removes its own container. This proves the selected substrate can support the backend; the independent supervisor, output collector, actual launch integration, worker/supervisor restart and receipt recovery remain unimplemented, so Milestone 3 and the full `run-linux.sh --prototype` gate remain open.

Milestone 3 registration boundary (2026-10-29): `Workspace.Process` and `Workspace.ProcessStore` retain bounded exact command/profile/environment inputs, the original actual-attempt coordinates and deadline, deterministic unit identity, boot/invocation identities and factual completion metadata. A committed launch transition is consumed once, including after acknowledgement loss; it grants no external authority. Concurrent pre-launch refusal competes with that transition and proves no provider launch without fabricating a systemd receipt. Unresolved registrations block all file access. Late factual receipts require matching invocation, bounded complete output and descendant settlement and can be accepted after ownership freezes. Four real PostgreSQL fixtures pass for these races and refusals; they supply no real service or fencing evidence. All 525 core, 136 worker and five migration tests pass, including a new actual-executor regression that leaves a prior prepared edit unresolved when publication is unproven, rather than executing a replacement write and attributing it to the old attempt. The focused workspace worker selection passes 37 cases. The migration schema-isolation check passes. The final candidate also passes all 353 PostgreSQL cases, the complete workflow gate against `41cd161`, and the agent/worker executable builds.

Next implement the independent Linux/systemd supervisor and bounded full qualification runner. Milestone 4 remains incomplete because validation processes, local Git operations and the full dependency-upgrade fixture depend on Milestone 3. File operations require all repository processes settled; a queue lease or unlocked file alone supplies no process fence. Process, handoff and terminal cleanup capabilities remain unavailable.

## Surprises & Discoveries


The baseline build fails before solving dependencies because `kikan-en-contract` and `kikan-en-client` are absent from the checkout referenced by `cabal.project`. The registered producer checkout has only one worktree. A clean fast-forward to the verified upstream master commit `16704290d527d413568bfa40c983f5c3604c35c8` restored both packages and the baseline core build. FRIC-14 is resolved.

2026-10-29 review: `Capability.Catalog.admitOperationClass` and `Execution.Tools.withBoundTools` independently reject durable mutation overlays. `withExecutionTools` passes accepted operation coordinates only to native factories; overlay acquisition receives run/principal/mode. `Execution.Start.admitSkillExecution` freezes Skill instructions without repository instructions. Installing providers alone cannot bridge these boundaries. The focused catalog command passed all seven tests during review; it supplies no process, fencing or durable mutation evidence.

2026-10-29 implementation: the package architecture gate rejects `process` in core. Keep shared types and PostgreSQL transactions in core; place Git allocation and its PostgreSQL/Git fixture in workers. FRIC-16 records the documentation mismatch and its resolution. This changes placement, not mutation admission or acceptance.

2026-10-29 environment: a disposable Apple container running the cached immutable kind node image has systemd 257 and writable cgroup v2. Installing D-Bus enables systemd-run; the effective PID/network/capability probe passes. This is environment evidence only, not supervisor/restart/RootDirectory qualification.

2026-10-29 native boundary: case-insensitive and Unicode-normalizing filesystems can resolve a path outside its literal frozen instruction scope. Native file admission now requires an explicit versioned ASCII/exact-spelling profile and rejects case-colliding base paths, including directory prefixes. Existing protected bundle codecs stay readable and historical admissions retain no new authority.

2026-10-29 process substrate: `PrivatePIDs=yes` makes the executed service PID 1 in its namespace; its exit kills that namespace's descendants. The late-writer fixture therefore retains PID 1 while an intermediate command exits, then proves the detached writer keeps writing and remains in the cgroup until whole-group stop. Do not weaken the profile to create a late descendant, or infer settlement from only a main PID. See the primary [systemd execution contract](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#PrivatePIDs=) and the executable probe.

## Decision Log


2026-10-28: Own IR-11 in a standalone plan. Plan 48's portable one-off command has different lifecycle and package constraints; plan 84 consumes workspace fences but does not implement them. This plan supplies the actual durable provider while retaining those ownership boundaries.

2026-10-28: Use the existing accepted operation/attempt identities and session transfer contracts. A timeout, queue lease expiry or session idle state never proves a process stopped. Unknown operations keep the workspace unavailable to successors until reconciliation proves settlement.

2026-10-29: Admit durable mutations only through an operator-installed, exact-revision workspace adapter with a trusted dispatch context. Preserve generic observation-only admission and the old workflow branch. A public operation-class label alone does not prove safe recovery.

2026-10-29: Select Linux with systemd system services and cgroup v2 for the first process backend. A cgroup is a kernel-managed set of processes used here to contain and settle every descendant. An independent workspace supervisor owns launches and receipts; native macOS and hosts missing required isolation refuse process admission. Qualify this design in an early bounded prototype before adding Git/process variants. A Linux VM can supply the full qualification environment for macOS contributors.

2026-10-29: Freeze repository `AGENTS.md` contents and directory scopes at assignment admission and include them in protected model context. Workspace edits cannot change an admitted assignment's governing instructions; a subsequent assignment explicitly admits the next instruction identity.

2026-10-29: Preserve the enforced core/leaf dependency boundary: shared workspace types and transactions remain in core, while Git allocation and its database/Git fixtures live in workers. Allocation receipts establish publication only and confer neither mutation authority nor fencing proof.

2026-10-29: Use Apple containers as the preferred local Linux qualification environment, per user direction. The configured remote builder is fallback only. The passing environment probe does not close the independent supervisor qualification gate.

2026-10-29: Keep the original Skill admission API and generic observation-only resolver as compatibility paths. New workspace admission is explicit, persists an optional protected snapshot field and is not installed into workflow bodies until the new governed workflow patch and real provider are ready. Description consists only of immutable schema/recovery data; actual adapter preparation receives a process-local dispatch context and cannot be reached by menu inspection.

2026-10-29: Serialize native file effects across worker processes with an OS file lock in private metadata, held through receipt persistence. Freeze/handoff and any future Git/process writer must share this boundary. Prepared receipts survive uncertain publication; final receipts settle only their original actual attempt, while the replacement attempt owns logical completion. Unknown evidence remains unresolved. These primitives do not prove supervised process settlement.

2026-10-29: The first native file policy is `ascii-exact-v1`: all initial tree paths are ASCII and unambiguous under case folding, targets require exact directory-entry spelling, contents may be UTF-8, and whole-file effects are bounded to 256 KiB. Extending filesystem semantics requires another qualified policy. An absent historical policy field grants no file authority and remains omitted on encoding.

2026-10-29: The optional worker setting selects only the file backend. It binds exact accepted principals and agents to approved canonical repositories, requires a reviewed complete instruction identity before any model request, and includes read/write prefix contents in the retained policy identity. The new workflow patch gives governed resolution and admission distinct labels; existing observation requests retain their original labels. Native process and Git providers remain disabled until their own supervisor gate passes.

2026-10-29: Before enabling process-backed assignments, give them a new retained filesystem profile and an exact file-adapter revision that requires the process-registration barrier. Retain the existing file-only profile and adapter for accepted file-only snapshots. Older providers must refuse the new profile before IO; a mixed deployment must not let a pre-registration file writer bypass pending process state. This is an enablement gate for Milestones 3–4, not a claim that the process adapter exists.


## Outcomes & Retrospective


Milestones 1 and 2 are verified; the file effects and patched worker integration are delivered. Milestones 3–6 and full IR-11 acceptance remain outstanding. FRIC-14 was resolved by restoring upstream dependency source and verifying the baseline core build. The contained file provider and effect recovery are implemented and exercised through the actual executor; process supervision, handoff and complete acceptance fixtures remain outstanding. IR-11 remains undelivered. FRIC-15 was resolved by giving the typed and dynamic authorization fixtures separate global provider keys; the parallel core suite passes all 511 tests. Existing authorization ADR constraints remain unchanged. ADR-0063 distinguishes allocation receipts from fencing proof. ADR-0059 records reviewed frozen instruction admission and patched worker enablement; ADR-0025 records exact adapter/dispatch infrastructure and the delivered file-only mutation provider, with process and handoff gates pending. FRIC-16 is resolved by aligning this plan with the enforced core/leaf package boundary.

## Context and Orientation


A worktree is a separate set of mutable repository files and a separate Git index. A workspace is the durable provider's retained identity, worktree, owner and operation history. An assignment is one accepted piece of work; it has a stable identity distinct from the continuing session and from the process executing it. An ownership epoch is a monotonically increasing integer used to reject writes from an earlier owner. A fence is proof that earlier writes and their processes cannot continue, not merely an expired lease.

`shikigami-agent/src/Shikigami/Agent/Capability/Workspace.hs` supplies confined observation tools to one-off runs. It is not a durable mutation provider and must remain compatible. `shikigami-core/src/Shikigami/Capability/Provider.hs` owns descriptors, exact provider revisions, lease acquisition, composition and generic tool authorization. `CapabilityScope` contains run, principal and mode; derive assignment bindings from authoritative retained state rather than adding caller-selected filesystem paths to that scope.

`shikigami-workers/src/Shikigami/Workers/Config.hs` is the durable composition root. `shikigami-core/src/Shikigami/Execution/Executor.hs` owns actual attempts and exposes `ExecutionRuntime.withTools` with accepted operation context. `Shikigami.Execution.Store` and `Shikigami.Execution.Transcript` retain outcomes and protected payload references. New workspace IO must integrate there, preserving operation identity and receipts across a crash between effect completion and acknowledgement.

`shikigami-core/src/Shikigami/Capability/Catalog.hs` owns the pure operation-class gate; `shikigami-core/src/Shikigami/Execution/Tools.hs` owns the second gate and live tool binding. `shikigami-core/src/Shikigami/Execution/Runner.hs` defines logical `OperationContext`, which does not identify an actual attempt. Keep that distinction when adding dispatch plumbing. `shikigami-core/src/Shikigami/Execution/Start.hs`, `shikigami-core/src/Shikigami/Execution/Transcript.hs` and `shikigami-core/src/Shikigami/Execution/Policy.hs` own frozen instruction input, its protected snapshot, and context selection. These are required integration surfaces, not optional provider internals. Concrete Git/process IO belongs in workers because core is forbidden from linking process adapters; shared contracts and transactional stores remain in core.

`shikigami-core/src/Shikigami/WorkerSession/Transfer.hs` defines `WorkspaceRef`, `TransferIntent`, `FenceProof` and `WorkspaceProvider`. Its `reconcile` must prove old-owner settlement; `admitWrite` must conditionally check the owner and epoch at the actual effect boundary. A separate IR-13 ownership provider supplies objective receipts. Do not fabricate those receipts here or mark plan 84 complete without them.

[ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md) requires fresh Kikan-En authorization immediately before protected IO. [ADR 0060](../adr/0060-safe-recovery-spends-new-attempts-and-retains-independent-receipts.md) retains independent attempt receipts and conservative reservations after uncertainty. [ADR 0063](../adr/0063-handoffs-establish-epochs-only-after-fences-and-versioned-owner-receipts.md) establishes a successor only after a matching fence and objective-owner receipt. These constraints apply to all provider operations. Follow `docs/workflow-versioning.md` for any workflow-body edits, declaring patch IDs in `domain/` and running `just keiro-gate`.

[ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) preserves exact descriptors and generic mutation refusal while defining this plan's narrow durable adapter exception. [ADR 0059](../adr/0059-harness-policy-is-frozen-at-admission-and-shared-with-ephemeral-execution.md) requires accepted policy and context to survive later configuration changes. Their plan-96 amendments describe intended implementation, not delivered providers.

## Plan of Work


Deliver the minimal durable-adapter wiring described in Milestone 4 alongside Milestone 2, so one real accepted edit with pinned instructions exercises both admission gates before process/Git expansion. This early vertical slice does not complete Milestone 4; its full upgrade acceptance still depends on Milestone 3's qualified process backend. Milestone 5 consumes the same supervisor and receipt contracts rather than introducing a second process owner.

Milestone 1 adds `Shikigami.Workspace.Catalog`, `Shikigami.Workspace.Types` and a durable store in `shikigami-core`, with migrations owned by `shikigami-migrations`. The operator catalog maps a canonical identity to a local approved source, immutable allowed base revisions and a policy revision. Reject duplicate identities rather than selecting the first match. Validate immutable full object identities; resolve an omitted base only through an operator-configured immutable default. Persist run, optional session/assignment, root, principal, owner epoch, repository, base and policy identity. Allocate a provider-generated workspace resource and directory, never interpolate a model-supplied path. Reserve the binding before creating the worktree and reconcile that same reservation after restart. Concurrent allocations for the same assignment converge; distinct assignments have distinct files and indexes. Test duplicate delivery, changed bindings and allocation interruption against real temporary Git repositories.

Use a provider-owned private repository copy per workspace, with its Git directory outside the mutable files mounted into validation services. Do not create linked worktrees directly in the operator's source repository or share writable Git metadata between assignments. Verify the exact admitted object is a commit before allocation. Record source metadata as well as source file hashes in the allocation fixture so the untouched-source acceptance includes Git state.

Milestone 2 adds shared governed operation contracts in `shikigami-core/src/Shikigami/Workspace/Provider.hs` and concrete contained filesystem operations in the workers package, preserving the core/leaf adapter boundary. Resolve operation targets under the retained workspace, reject absolute paths, traversal, Git metadata and symlink components, and prevent path substitution races at the IO boundary. Require lifecycle admission, declared mutation overlay, fresh exact authorization binding repository/base/operation/resolved target and conditional owner epoch. Existing session command authorization in `Shikigami.WorkerSession.Capability.authorizeExact` demonstrates digest-bound capability actions; verify the actual Kikan API before choosing the workspace action encoding. Perform an early producer/consumer test with the real verifier: changing any coordinate must invalidate authorization. Keep permit bytes out of journals. Edits carry expected content hashes; receipts distinguish already-applied output from conflicts. Bound input/output and retain full content only in protected payload storage.

Add `shikigami-core/src/Shikigami/Workspace/Instructions.hs`. Before the first model request, discover regular `AGENTS.md` files from the admitted immutable base, retaining each relative path, content hash, text and directory scope. Refuse symlink instruction files and over-budget discovery; do not silently omit instructions. Start with limits of 64 files and 64 KiB of combined UTF-8 text, further narrowed by the admitted context budget. New paths inherit the pinned instructions from their nearest existing ancestor scopes. Root instructions apply everywhere; nested instructions add directory-specific requirements. Parent/operator restrictions remain authoritative and explicit contradictions produce a bounded refusal. Ordinary source text is never promoted to instructions.

Extend fresh admission in `Execution/Start.hs` and the protected snapshot codec in `Execution/Transcript.hs` with the workspace binding and instruction-bundle identity. Build `initialContext.systemPrompt` from the existing prompt plus the complete, scope-labelled bundle and the precedence rule; retain instruction bodies only in protected storage. `Execution/Policy.hs` must preserve that fixed context through truncation and summary operations, refusing when it cannot fit. Existing snapshots without a bundle keep their historical behavior and gain no mutation authority. Resuming an accepted execution reads its retained bundle rather than the current worktree. Edits to instruction files are proposed repository changes governed by the old bundle; they take effect only when a new assignment admits them. Process execution and Git operations receive the same pinned policy, including lookup, validation and branch/commit conventions. Verify root/nested behavior with a deterministic model fixture that inspects the actual request, then changes instruction files and restarts: the resumed request and write scope must remain pinned. This milestone is independently verifiable through provider, snapshot and context tests before worker wiring.

Milestone 3 supplies a supervised process owner with argument-vector execution, exact operator command rules, controlled environment, contained working directory, OS containment, timeout, bounded output and whole-cgroup cancellation. A command allowlist alone does not contain repository-controlled build scripts. Fail closed where required containment is unavailable. Persist operation and attempt identity before launch and retain completion receipts independently of the caller. On restart, observe the original execution; never redispatch an uncertain mutation just because its claim expired. Reconcile all descendants before reporting settlement. Git status/diff are bounded observations; commits disable hooks and external helpers and write only the isolated local repository. Record exact tree/commit identities and changed paths. Commit recovery inspects the accepted operation's retained parent/tree/result rather than creating a second commit.

Implement the backend in `shikigami-workers/src/Shikigami/Workspace/Supervisor.hs` and `shikigami-workers/src/Shikigami/Workspace/Systemd.hs`, with a separately supervised `shikigami-workspace-supervisor` executable registered in `shikigami-workers/shikigami-workers.cabal`. Workers talk to an operator-owned Unix socket with peer-credential checks; commands carry retained identities, never caller-selected unit properties or host paths. The supervisor validates them against the workspace store and performs fresh authorization and conditional epoch admission immediately before launch. Serialise mutation admission, launch registration and transfer freeze per workspace so a handoff cannot overtake an admitted but unregistered process. The supervisor is independent of the queue worker and holds no worker-lifetime parent/dependency relationship.

Use systemd system services with `Type=exec`, `Restart=no`, bounded `RuntimeMaxSec` and `TimeoutStopSec`, `KillMode=control-group` and `SendSIGKILL=yes`. Launch under an unprivileged workspace-specific identity in an operator-built immutable `RootDirectory`; expose only that workspace and scratch space as writable mounts. Require a private network, private PID namespace, private devices, no new privileges, an empty capability bounding set, protected kernel/cgroup interfaces and a syscall policy that prevents undoing the mount restrictions. Do not mount host credentials, supervisor sockets, other workspaces or the source checkout. Keep provider-owned Git metadata outside the validation mount. Git mutations use a separate trusted provider operation. Probe the effective isolation configuration and cgroup v2 before enabling the capability; unsupported settings or a Darwin host produce a bounded refusal, never an unsandboxed fallback.

The durable operation record moves through reserved, launch-requested, running, settled or unresolved states. A reservation can also become a proven pre-launch refusal only while no launch transition has committed; that refusal is separate from a process completion receipt. Before launch, persist the workspace/epoch, logical operation and fingerprint, actual attempt/claim generation, command policy and instruction digests, deadline and deterministic unit name. Retain the systemd invocation identity and host boot identity when observed; a PID is diagnostic only. Keep successful and failed unit evidence until the independent supervisor has durably stored a completion receipt, using `RemainAfterExit=yes` and retention of failed units rather than automatic collection. A receipt binds exit status, timeout/cancellation status, bounded protected output references and descendant settlement. Stop the entire cgroup and prove it empty before reporting settled; a successful main-process exit alone is insufficient. Route stdout/stderr to a bounded supervisor collector, not journald; drain excess bytes while recording truncation, and never put command arguments or raw output in public diagnostics. Collector loss is explicit evidence loss, not successful validation.

On worker or supervisor restart, reconcile the same unit and invocation against the retained launch record and publish the original receipt through `Execution/Store.hs` completion/late-receipt paths. A crash around launch with no conclusive unit evidence, lost systemd state, or a host reboot without a receipt leaves the mutation unresolved and blocks reuse/transfer; do not rerun it. Reconciliation performs factual receipt acceptance independently of revoked execution authority, while reading protected content or launching new work still requires fresh authority. Before expanding command or Git variants, add `tests/workspace/run-linux.sh` as a bounded prototype gate. It must prove one launch despite duplicate delivery, worker and supervisor restart during a real command, a child that outlives its parent, cancellation settlement, denied host/sibling/network access, and receipt recovery after completion but before acknowledgement. Promote this backend only when all cases pass; otherwise keep process admission disabled and revise the backend decision with evidence. This is an implementation gate, not a claim that the present macOS checkout has qualified Linux isolation.

Milestone 4 wires catalog, providers, fresh authorizer, resource policy and recovery adapters into the durable worker composition root. Add separate mutation/process/Git capabilities; absence of the declaration must mean absence of those tools. Do not silently classify mutating tools as observations or idempotent effects without provider recovery evidence. Retain the read-only overlay's identity and semantics. Build a deterministic provider fixture that addresses an upgrade agent, edits a dependency constraint, runs a fixture validation command, commits and returns structured evidence through the normal durable execution path. Redeliver and restart at effect/receipt boundaries. Assert one logical terminal result and one committed change.

Add an operator-owned durable adapter registry keyed by exact capability id, revision and descriptor digest in `Capability/Provider.hs`. It supplies immutable tool descriptions and per-tool recovery contracts separately from the callback that prepares an actual invocation. In `Capability/Catalog.hs`, add a governed resolution entry point taking this registry's pure admission view; keep the existing generic resolver observation-only. In `Execution/Tools.hs`, replace the unconditional refusal only for exact registered adapters and route those tools through the adapter, not the generic overlay acquisition path. Copying a descriptor or labelling a tool `IdempotentMutation` cannot grant this exception. Unregistered revisions, missing declarations, changed schemas and non-durable legacy branches still refuse before acquisition. Advertise the existing namespaced tool names so native tools cannot silently replace overlays.

Introduce a process-local `DispatchContext` alongside `Runner.OperationContext`, carrying the accepted logical context plus `AttemptId` and the claimed owner/generation. Pass it from `Executor.dispatchTool` through `ExecutionRuntime.withTools` and `Execution/Tools.hs` to the durable adapter's preparation callback. Description/menu construction receives no dispatch context and cannot launch or mutate. The provider derives workspace, assignment, root, principal and epoch from retained state, checks them against the accepted snapshot and claim, and closes over the verified values in its invocation callback; these coordinates are never model arguments. The callback receives the accepted tool input, obtains the exact target-specific authorization, and invokes the conditional effect boundary. Keep `CapabilityScope` unchanged for generic providers. Map recovery from the registered adapter contract, not merely the public operation class: status/diff may be repeatable observations; edits/commits become idempotent only after receipt tests pass; validation commands remain uncertain effects reconciled through the supervisor.

Wire the same admission view, registry, workspace admission and instruction loader through `Workers/Config.hs` and `shikigami-core/src/Shikigami/Agent/Workflow.hs`. Declare a new real workflow patch for changed fresh resolution/admission behavior; the historical branch continues calling the generic resolver and original Skill admission. Add positive end-to-end coverage plus negative cases for an arbitrary mutation overlay, a copied workspace descriptor without its adapter, missing/mismatched dispatch coordinates, and menu inspection causing zero effects. The early vertical fixture uses one structured edit before process/Git variants; the full milestone additionally requires the qualified Milestone 3 backend and upgrade fixture.

Milestone 5 implements `WorkspaceProvider` against real workspaces and supervised processes. Freeze old-owner admission before waiting for pending operations; retain a deduplicated transfer intent and matching fence receipt. Unknown processes leave transfer unresolved. Successor writes require fresh authority and established ownership; delayed old-owner callbacks fail. Provide a separately allocated integration workspace consuming exact worker commits and bases, report conflicts explicitly, and validate the resulting exact integrated tree. Add operator list/cleanup commands that consult authoritative terminal ownership, conditionally mark cleanup pending and remove only the retained provider-owned worktree. Retain idle sessions and active runs; recover interrupted cleanup without broad directory deletion.

Milestone 6 adds `tests/workspace/` fixtures and operator documentation in `docs/operations/workspaces.md`. Exercise all acceptance cases below and update IR-11's status only with evidence. Update plans 84 and 86 and MasterPlan 14 to point to this provider without claiming their unrelated acceptance gates passed. Review decisions for a new ADR, preserving the existing filesystem ADR convention. Triage friction when completion is actually established.

## Concrete Steps


The delivered allocation fixtures run in the workers suite because they exercise the concrete Git adapter. The core PostgreSQL workspace group remains to add for the next milestone. The environment-only Apple container probe is:

```bash
bash tests/workspace/probe-apple-container.sh
```

It creates a disposable image-pinned Linux container without host mounts, installs D-Bus, checks systemd/cgroup v2 and effective PID/network/capability isolation, prints two passing cases and stops/removes its own container. It does not replace `run-linux.sh --prototype` or `--qualify`. Apple containers are the user's preferred qualification environment; use the configured remote builder only if they cannot support the required fixture.

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

Add the provider/store/instruction cases under the `workspace` group in `shikigami-core/test-postgres/Main.hs`, using `shikigami-migrations/test-support/Shikigami/Migrations/TestSupport.hs` for migrated isolated databases. Add dispatch and supervisor adapter cases to the worker suite. Run from the repository root:

```bash
nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test --test-options='-p workspace -j1' --test-show-details=direct
nix develop --no-write-lock-file -c cabal test shikigami-workers-test --test-options='-p workspace' --test-show-details=direct
```

Require a nonzero count of workspace tests in each suite; a successful empty selection is not evidence. On a disposable Linux VM with systemd as its service manager, cgroup v2, Nix and sudo permission to provision fixture services, run the following future runner from the same checkout. It must build/provision its immutable fixture root, isolated users, supervisor and temporary repositories, run only its own units, and tear those down after receipts settle. Use only fixture data. It must refuse unsupported hosts rather than skip cases or use the operator's real repositories.

```bash
nix develop --no-write-lock-file -c bash tests/workspace/run-linux.sh --qualify
```

The runner uses sudo only for its scoped fixture service provisioning. It prints bounded named results for containment, duplicate launch, worker restart, supervisor restart, escaped-descendant cancellation, completion-receipt recovery, durable upgrade and handoff; all must pass with a nonzero case count. During the Milestone 3 prototype, `--prototype` selects the process cases and explicitly reports that full qualification is incomplete. The Linux full run remains mandatory even when pure and PostgreSQL tests pass on macOS. These are interfaces to implement, not commands claimed to exist today. At the final candidate:

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

Prove both mutation gates accept only the installed exact durable adapter. Arbitrary mutation descriptors, copied workspace descriptors without adapters and mismatched revisions must refuse. Tool-menu description must allocate no process or mutation attempt. The actual provider must observe the same operation and attempt identities retained by the executor; model-supplied substitutes and stale generations must fail before effects. Replay of a historical snapshot or workflow branch must not gain workspace mutation tools.

Use root and nested `AGENTS.md` fixtures with distinct validation and commit conventions. Assert the actual model request carries their exact texts and scopes, sibling directories do not inherit nested instructions, and the provider refuses explicit policy conflicts. Modify an instruction file, compact context, restart and resume: the accepted bundle and instructions presented to the model must remain unchanged. A new assignment at the newly approved base must admit the new bundle. Over-budget instruction sets fail admission rather than silently dropping policy. Verify the terminal evidence includes the instruction identity without copying bodies into logs or workflow journals.

Duplicate delivery and restart during validation must resume the same workspace and accepted operation, preserving receipts and producing one terminal result. Fault injection must cover the gaps before dispatch, after protected mutation, after process completion and before receipt acknowledgement. Retrying a committed edit or commit must not duplicate it. Cleanup must refuse active and idle-continuing workspaces and remove only a terminal fixture's exact owned directory.

Run the Linux process fixture with both worker and supervisor killed separately while the command remains in flight. Recover its original invocation and one receipt without a second launch. Include a descendant that changes its process session and outlives the command's main process; successor admission remains closed until the entire cgroup is proven empty. Attempts to access host/sibling files, credentials, provider metadata or external network must fail. Missing receipt/unit evidence must produce an inspectable unresolved state, including at the launch-requested boundary; it must never be interpreted as permission to retry. Public logs must contain neither the probe's secret marker nor unrestricted stdout/stderr.

Two worker commits must integrate in a third workspace; record bases, artifacts, resulting tree/commit and test statuses on that exact combined tree. Include a conflict case and a case where worker-local checks pass but integration fails. Handoff must hold a real process in flight, refuse successor writes until reconciliation, survive provider restart, preserve accepted files/uncertain operations and reject late old-owner writes. Real IR-13 checkpoint integration remains separately owned; passing workspace-side tests alone cannot close the whole continuing-session request.

Terminal evidence contains repository/base/result identities, changed paths, bounded command identities/statuses and a bounded summary. Logs and workflow journals must exclude credentials, full patches, tool inputs, unrestricted command output and bearer permits. Inspect retained journal and log fixtures to verify this exclusion.

## Idempotence and Recovery


Never mutate the operator's source checkout. Use temporary fixture repositories for destructive tests. Store stable assignment bindings and operation fingerprints before external work. Repeated matching requests converge; conflicting requests refuse. Unknown completion blocks reuse, transfer and cleanup until the process owner supplies evidence. Do not infer process death from a database timeout or attempt expiry. Explicit terminal cleanup uses a retained resource identity and a conditional state transition; never scan and delete arbitrary directories. Migrations must preserve existing journals; roll forward if a new workflow patch has executed.

Restart recovery joins the retained unit name, invocation and boot identity to the original operation/attempt. Do not reset failed units, collect unit state, remove protected receipts or release workspace ownership until settlement is retained. A restarted supervisor reacquires the per-workspace admission/freeze lock before acting. Existing instruction bundles remain immutable, including after repository instruction edits; never reconstruct accepted policy from current filesystem contents. Historical missing fields decode to no workspace binding and no new authority, preserving old snapshot encodings.

## Interfaces and Dependencies


Shared types and stores belong in `shikigami-core`; durable runtime composition belongs in `shikigami-workers`; schema changes belong in `shikigami-migrations`. Keep one-off executable dependencies in `shikigami-agent`. Reuse the core `OperationId`, `AttemptId`, `ExecutionRootId`, `WorkerSessionId`, `AssignmentId`, `AgentIdentity`, `WorkspaceRef` and transfer proof contracts rather than introducing alternative identity or accounting stores.

The dependency owner is `mori://shinzui/kikan-en`, specifically its contract and client packages. The current project references local source, restored in this session to verified upstream commit `16704290d527d413568bfa40c983f5c3604c35c8`. Existing process, filesystem, serialization and database dependencies should be reused after source inspection through Mori. Select a new dependency only when the containment/recovery requirements justify it and authoritative releases have been verified.

The selected operating-system backend is `mori://systemd/systemd`, project-relative `man/systemd.exec.xml`, `man/systemd.service.xml` and `man/systemd.kill.xml`; artifact-level URIs are pending. Mori has no registered systemd source at this revision, so the planning lookup used the corresponding official upstream manuals. No package version or pin is selected here. Implementation must verify the installed backend and authoritative releases before adding bounds, and the fixture must test effective containment rather than assuming a setting is supported. The supervisor owns process settlement facts, while `Shikigami.Execution.Store` remains the sole owner of accepted attempts, resource accounting and terminal publication.

Revision note (2026-10-29): Address the three review findings by defining exact durable-adapter admission and dispatch plumbing, selecting a Linux/systemd supervisor with a mandatory early recovery prototype, and freezing scoped repository instructions into protected model context. Add observable negative and restart cases, concrete suite/runner commands and matching ADR amendments. All six milestones and all nine IR-11 acceptance obligations remain open to implementation; this documentation update does not claim them passed.

Implementation revision (2026-10-29): Complete the allocation milestone with durable immutable reservations and private Git copies, align concrete Git IO with the workers package boundary, and add the preferred Apple container environment probe. Preserve all remaining mutation, instruction, supervisor, integration and fencing gates as unfinished.

Implementation revision (2026-10-29): Add bounded immutable instruction discovery, protected snapshot admission and restart/model-request tests; add actual attempt dispatch coordinates and the exact durable-adapter registry and tool path. Preserve generic and historical behavior. The concrete authorized edit provider and patched worker integration are implemented; the complete PostgreSQL suite and workflow gate pass, closing Milestone 2. Record the Apple container preference in AGENTS.md for future plans.

Implementation revision (2026-10-29): Deliver the contained file adapter, exact target/claim proofs, independent receipt recovery, explicit native path qualification, operator-reviewed worker configuration and the real governed-workspace workflow patch. The accepted parent/child fixture proves one file edit and retained model instructions across restart. Process supervision, Git operations, ownership transfer and complete IR-11 qualification remain separate unfinished milestones.
