---
id: 59
slug: adopt-capability-overlays-in-the-portable-one-off-repository-harness
title: "Adopt capability overlays in the portable one-off repository harness"
kind: exec-plan
created_at: 2026-08-22T15:12:03Z
intention: "intention_01m0n043cse67vxfj52w29t6zb"
master_plan: "docs/masterplans/11-add-agent-scoped-capability-overlays-without-changing-base-capabilities.md"
---

# Adopt capability overlays in the portable one-off repository harness

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, a developer can opt a `Skill` agent into a bounded, read-only view of the
current Git worktree by adding `workspace.read` to that agent's `capabilityOverlays`. The
one-off `shikigami-run-behavior` and `shikigami-agent-run` composition roots install an
operator-owned provider for that name, resolve the request, acquire its namespaced `read`,
`grep`, and `glob` tools for only the behavior call, and release it afterward. Paths outside
the selected worktree, traversal attempts, and symlink escapes are rejected. No database is
introduced into `shikigami-run-behavior`, and no trigger or sink runs in either one-off path.

An agent without `workspace.read` sees no workspace tools and does not even discover a Git
root. A deterministic test runs two otherwise identical agents against a temporary external
repository: the opted-in agent reads and searches a fixture through the model/tool loop; the
other agent cannot name the tool. This is the first useful overlay and the integration seam
for the broader portable harness in
`docs/plans/48-add-a-portable-one-off-repository-agent-harness.md`, which retains ownership of
writes, command execution, the dedicated `shikigami-run` binary, installation, and its full
security proof.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Add Git-worktree scope discovery and containment-safe read-only `ToolEnv` operations.
- [ ] Register the immutable `workspace.read` descriptor/provider in the one-off composition
      root with an explicit local authorization rule.
- [ ] Add optional `--workspace DIR` to both one-off executables and resolve it only for agents
      that request the overlay.
- [ ] Run both behavior paths through Plan 57's acquire/derive/release helper.
- [ ] Add traversal, symlink, bounds, opt-in isolation, scripted-model, and CLI tests.
- [ ] Reconcile Plan 48 so it consumes the overlay seam and retains only its broader writable
      harness scope.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `shikigami-agent` is already the light leaf package for one-off runs, established by Plan
  55 and `docs/adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md`. The first overlay
  adapter belongs there, not in workers or server composition.
- The current `shikigami-run-behavior` command deliberately works outside a Git repository.
  Eager worktree discovery would regress every agent with no overlay. Workspace resolution
  must therefore be lazy and conditional on `workspace.read`.
- Shikumi 0.3.0.2's `Shikumi.Tool.Builtin.Fs` already defines typed read/grep/glob tools over
  a `ToolEnv`. Its `localToolEnv` is explicitly unrestricted and must not be used. A confined
  environment can reuse the typed definitions only if every reachable operation is rooted,
  bounded, and its fast-path process executor cannot escape the root.


## Decision Log

Record every decision made while working on the plan.

- Decision: Make `workspace.read` the first provider and limit it to read, grep, and glob.
  Rationale: It is useful for one-off repository agents, proves the whole overlay lifecycle,
  and has no irreversible emission. Writes and commands require the stronger stale-write,
  consent, allowlist, and sandbox work already owned by Plan 48.
  Date: 2026-08-22

- Decision: Root the provider at the explicit `--workspace` directory or, when omitted, the
  Git worktree containing the current directory; require a Git worktree in V1.
  Rationale: Git gives one unambiguous containment and repository boundary. An explicit flag
  preserves callers that operate on a checkout other than their current directory.
  Date: 2026-08-22

- Decision: Treat installation of the built-in provider plus the one-off read-only policy as
  operator authority; the agent declaration remains only a request.
  Rationale: The binary, not the agent file, fixes the provider implementation, operation
  class, root, and allowed one-off mode. The agent cannot provide an endpoint, credential, or
  path through its declaration.
  Date: 2026-08-22

- Decision: Refuse path traversal and symlink traversal rather than following a symlink whose
  final canonical target happens to remain inside the root.
  Rationale: A no-symlink rule is simpler to audit and avoids time-of-check/time-of-use swaps.
  More permissive behavior can be added only with descriptor revision and dedicated race
  tests.
  Date: 2026-08-22

- Decision: Integrate both existing one-off commands through one shared helper; do not create
  the future `shikigami-run` executable in this child plan.
  Rationale: This proves database-free and memory-backed one-off composition without
  duplicating Plan 48's broader CLI, output, packaging, and mutable-workspace work.
  Date: 2026-08-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`shikigami-agent` is a leaf library and two executables. Its Cabal file is
`shikigami-agent/shikigami-agent.cabal`. `Shikigami.Agent.Command.RunBehavior` loads one
manifest, constructs a provider-backed `BehaviorEnv`, and calls `runBehavior` without a
database. `Shikigami.Agent.Command.AgentRun` does the same inside the Kioku one-off
session/memory lifecycle. `Shikigami.Agent.Command` owns both option parsers, and
`shikigami-agent/test/Shikigami/Agent/CommandSpec.hs` proves their flags and roles. Neither
command currently resolves a workspace or tool capability.

Plan 56 defines the declaration, catalog, resolution subject, and `OneOff` execution mode.
Plan 57 defines the provider registry and lease bracket and adds the tool registry to
`BehaviorEnv`. This plan supplies one concrete provider closure rooted at the invocation's
workspace. The provider exposes Shikumi `SomeTool`s and returns a no-resource release action;
it still uses the common bracket so later providers with sockets, child processes, or remote
sessions follow the same lifecycle.

`mori://shinzui/shikumi/packages/shikumi-tools` exposes `Shikumi.Tool.Builtin.Fs` and
`Shikumi.Tool.Env`. `localToolEnv` has full host filesystem and shell access and is explicitly
not a sandbox. A **confined ToolEnv** in this plan is a record whose path operations first
resolve a worktree-relative path, reject absolute/traversal/symlink paths, enforce input and
output bounds, and only then perform IO. Its write/remove/mkdir functions always refuse. Its
exec function must not run model-provided shell; either force Shikumi's bounded in-process
grep/glob fallback with a synthetic unavailable result or implement equally bounded local
read-only tools in this package.

The relevant ADR is
`docs/adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md`: one-off functions belong
in `shikigami-agent`, whose architecture test forbids platform dependencies. The generic
overlay ADR created by Plan 56 is also normative by the time this plan starts. No relevant
cross-repository ADR was found. Plan 48 is checked in but incomplete; it currently assumes
Plan 12 owns a generic registry and loop. This plan supersedes only that integration
assumption and its read-only tool slice, not the rest of Plan 48.


## Plan of Work

### Milestone 1: Worktree scope and safe path algebra

Add `shikigami-agent/src/Shikigami/Agent/Capability/Workspace.hs`. Define `WorkspaceScope`
with an absolute canonical root and `resolveWorkspaceScope :: Maybe FilePath -> IO (Either
WorkspaceError WorkspaceScope)`. With an explicit path, invoke `git -C <path> rev-parse
--show-toplevel` through `System.Process.proc`, never a shell string. Without one, run the
same command from the current directory. Reject a non-worktree, a missing directory, or a Git
answer that is not absolute. Do not change process cwd.

Implement `resolveWorkspacePath` and test it separately. Tool paths are relative slash-
separated paths. Reject an absolute path, `..`, empty path where a file is required, NUL,
and any existing symlink component. Walk components from the already-canonical root, inspect
each before use, and verify the final normalized path retains the root path-component prefix;
a textual prefix such as `/repo` versus `/repository` is insufficient. Reads are capped per
file and per response; traversal/search is capped by depth, file count, file size, and match
count. Skip `.git`, `dist-newstyle`, `.stack-work`, `node_modules`, device files, and binary
files. Keep limit constants named and covered by tests.

### Milestone 2: Immutable read-only provider

Create the public descriptor `workspace.read` revision `1` with logical tools `read`, `grep`,
and `glob`, all classified `Observation`. Construct a confined `ToolEnv` and reuse
`Shikumi.Tool.Builtin.Fs.readTool`, `grepTool`, and `globTool` only after verifying from the
released source that the disabled executor reaches the bounded fallback. If that proof does
not hold, define equivalent typed tools locally using `Shikumi.Tool.mkTool`; do not enable
`localToolEnv`, `bashTool`, write/edit, or any process command selected by the model.

`workspaceReadProvider :: WorkspaceScope -> CapabilityProvider` captures the scope in the
operator factory and returns exactly the descriptor's three tools. Acquisition validates
that the root still exists; release is a no-op success but emits the normal lifecycle event.
Unit tests dispatch each tool through the same `ToolRegistry`/`runToolCall` path used by a
model. They assert bounded success inside the fixture and typed refusal for traversal,
absolute paths, symlinked files/directories, excluded directories, oversized files, and
excess results.

### Milestone 3: Shared one-off capability composition

Add `shikigami-agent/src/Shikigami/Agent/Capability/OneOff.hs`. Given logger, optional
workspace argument, `AgentDecl`, and base `BehaviorEnv`, inspect
`AgentDecl.capabilityOverlays`. If empty, call the callback immediately with the unchanged
environment and do not run Git. If non-empty, lazily resolve the workspace only when
`workspace.read` is among the requests, construct a catalog/provider registry containing the
built-in descriptor, and authorize only:

* execution mode `OneOff`;
* a declared non-empty principal;
* capability id `workspace.read`;
* the fixed observation-only descriptor rooted at this invocation's worktree.

Then run Plan 56's pure resolver and Plan 57's lease bracket, derive the active
`BehaviorEnv`, and invoke the callback. Map unknown/denied requests and workspace errors to a
concise permanent CLI diagnostic. Map acquisition/release failure to a failed invocation.
Never log the contents of files or model tool arguments in lifecycle events.

### Milestone 4: Wire both one-off commands

Add optional `--workspace DIR` to `runBehaviorRoleInfo` and `agentRunRoleInfo` in
`Shikigami.Agent.Command`, thread it to both command modules, and update
`Shikigami.Agent.CommandSpec`. In `RunBehavior`, wrap only the `runBehavior` call with the
shared one-off helper after the existing sanctioned-profile refusal. It must remain database
free. In `AgentRun`, build the profile-constrained environment first, then wrap
`runAgentWithMemory`; workspace tools live only during behavior execution, not during
profile resolution, memory recall/record, or session completion. If the current
`runAgentWithMemory` seam cannot narrow the lease that tightly, add a callback at its behavior
boundary in `shikigami-core/src/Shikigami/Agent/Run.hs` rather than holding the lease for the
whole Kioku lifecycle.

Update `shikigami-agent.cabal` with only the direct libraries the implementation imports,
such as `directory`, `filepath`, `process`, `containers`, and `shikumi-tools`. Extend
`Shikigami.PackageArchitectureSpec` to continue rejecting messaging, queue, server, database-
driver, and telemetry-export dependencies. Adding process/filesystem libraries to this
trusted local leaf is allowed; adding them to Flow is not.

### Milestone 5: Agent-specific end-to-end proof and Plan 48 reconciliation

Add a proof Skill agent requesting `workspace.read` and a matching otherwise-identical agent
with an empty list. In `shikigami-agent` tests, create a temporary Git worktree outside the
Shikigami checkout with a small text fixture and an escaping symlink. Use a scripted Baikai
provider: for the opted-in agent it requests the namespaced read and grep tools and then
returns a final answer; for the unrequested agent it attempts the tool name and receives no
advertised tool. Assert the opted-in transcript/result, the empty agent's isolation, lifecycle
release, unchanged fixture bytes, and zero paths touched outside the temporary worktree. The
test is hermetic and needs no provider key or database.

Revise `docs/plans/48-add-a-portable-one-off-repository-agent-harness.md` throughout, not just
in one note. Replace its generic Plan-12 `ToolRegistry`/loop/lifecycle dependency with Plans
56 and 57, mark this plan's read-only scope as delivered when complete, and retain Plan 48's
ownership of stale-write-safe edit/create/delete, structured command policy, platform
sandbox, dedicated `shikigami-run`, JSON/audit result, flake app, and full external-worktree
proof. Do not mark Plan 48 complete. Update `docs/user/cli.md`, README examples, and
`docs/architecture/packages.md` for the new optional flag and overlay behavior.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/shikigami`. Reverify Shikumi's released filesystem
tool implementation before deciding whether to reuse it:

```bash
mori registry show shinzui/shikumi --full
shikumi_root=$(mori path mori://shinzui/shikumi)
sed -n '1,320p' "$shikumi_root/shikumi-tools/src/Shikumi/Tool/Builtin/Fs.hs"
sed -n '1,240p' "$shikumi_root/shikumi-tools/src/Shikumi/Tool/Env.hs"
```

Format and run the leaf and core suites:

```bash
nix fmt
nix develop --command cabal test shikigami-agent-test -j1
nix develop --command cabal test shikigami-core-test -j1
```

Check the command surfaces:

```bash
nix develop --command cabal run shikigami-run-behavior -- --help
nix develop --command cabal run shikigami-agent-run -- --help
```

Expected excerpts:

```text
--agent FILE
--workspace DIR
```

Run the deterministic external-worktree integration test through the test suite; it must not
require credentials. An optional manual live check may then use a temporary repository and
the proof agent:

```bash
nix develop --command cabal run shikigami-run-behavior -- \
  --agent agents/proof/workspace-read.dhall \
  --workspace . \
  --payload '{"task":"read README.md and report its first heading"}'
```

Expected: the final JSON reports the README heading and stderr lifecycle events name
`workspace.read` revision `1`; no file changes occur. Use a temporary Git worktree instead
when validating outside this checkout.

Finish with architecture and repository checks:

```bash
nix develop --command cabal test all -j1
nix flake check
rg -n "plan 12.*ToolRegistry|Plan 12.*ToolRegistry" \
  docs/plans/48-add-a-portable-one-off-repository-agent-harness.md
git diff --check
```

Expected: tests and flake checks pass; the final `rg` returns no generic-registry dependency
in Plan 48 (MCP-specific references may remain).


## Validation and Acceptance

Acceptance requires all of these observations:

* An agent with an empty overlay list runs from a non-Git directory exactly as before. Git is
  not invoked, `Context.tools` remains empty, and no capability lifecycle event is emitted.
* An identity-bearing Skill agent requesting `workspace.read` resolves revision `1`, advertises
  only its three namespaced tools, reads/searches/lists inside the selected worktree through a
  scripted model, and releases the lease after the final response.
* The same model/tool attempt against an agent that did not request the overlay cannot access
  the tool; no process-global registry or prior-run state makes it visible.
* An absolute path, `..`, sibling-prefix path, symlinked file, symlinked directory, `.git`
  path, oversized file, excessive traversal, and excessive match set each produce a typed,
  bounded refusal without reading outside the worktree.
* The provider exposes no write, edit, delete, shell, or command tool and leaves the fixture
  worktree byte-for-byte unchanged.
* `--workspace` appears on both one-off commands. Omitting it discovers the current Git root
  only for a requesting agent; an explicit path selects that worktree without changing cwd.
* `shikigami-run-behavior` still opens no database. `shikigami-agent-run` does not retain the
  workspace lease during memory or session operations.
* `shikigami-agent` remains a light leaf: package architecture tests reject platform runtime
  dependencies.
* Plan 48 points to the generic overlay contract and accurately retains its unimplemented
  writable/command/package scope; it is not incorrectly marked complete.


## Idempotence and Recovery

All V1 workspace tools are read-only and bounded, so focused and end-to-end tests may be
repeated without restoring fixture content. Temporary worktrees should be created under the
test framework's temporary directory and removed by its bracket; if a test aborts, print the
exact temporary path so a developer can inspect and remove that specific directory. Never
use a broad recursive cleanup target.

Worktree discovery and provider acquisition may be retried. A path that becomes a symlink or
moves between validation and read is refused where detectable; the provider must open and
validate within one operation rather than cache unchecked resolved child paths across calls.
If the released Shikumi fallback cannot be safely confined, implement the three tools locally
instead of weakening containment or invoking `localToolEnv`. If future Plan 48 work has
already landed when this plan starts, preserve its code and revise this plan's adapter
composition around the implemented interfaces rather than reverting it.


## Interfaces and Dependencies

The workspace module must expose an interface equivalent to:

```haskell
data WorkspaceScope = WorkspaceScope
  { root :: !FilePath
  }

data WorkspaceError
  = NotGitWorktree !FilePath
  | InvalidWorkspacePath !FilePath
  | WorkspacePathEscapes !FilePath
  | WorkspaceSymlinkRefused !FilePath
  | WorkspaceLimitExceeded !Text
  | WorkspaceIoFailed !Text

resolveWorkspaceScope
  :: Maybe FilePath
  -> IO (Either WorkspaceError WorkspaceScope)

resolveWorkspacePath
  :: WorkspaceScope
  -> FilePath
  -> IO (Either WorkspaceError FilePath)

workspaceReadDescriptor :: CapabilityDescriptor

workspaceReadProvider
  :: WorkspaceScope
  -> CapabilityProvider
```

The one-off composition helper must expose an interface equivalent to:

```haskell
withOneOffCapabilityOverlays
  :: Log.Logger
  -> Maybe FilePath
  -> AgentDecl
  -> BehaviorEnv
  -> (BehaviorEnv -> IO a)
  -> IO (Either OneOffCapabilityError a)
```

It takes the principal from `AgentDecl.identity`, constructs a `OneOff`
`ResolutionSubject`, and uses Plans 56/57 rather than directly updating `BehaviorEnv.tools`.
The empty-request branch must pass the original environment to the callback without workspace
IO.

This plan consumes `mori://shinzui/shikumi/packages/shikumi-tools`, already selected and
verified by Plan 57, plus ordinary `directory`, `filepath`, and `process` APIs. Before using
those APIs, inspect their current source/docs through Mori when they are external
dependencies; do not guess. It must not add `shikumi-tools` to a Flow effect row, use
`localToolEnv`, add MCP as a prerequisite, or add server/worker platform packages to
`shikigami-agent`.
