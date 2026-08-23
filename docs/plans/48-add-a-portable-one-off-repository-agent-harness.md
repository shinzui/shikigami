---
id: 48
slug: add-a-portable-one-off-repository-agent-harness
title: "Add a portable one-off repository agent harness"
kind: exec-plan
created_at: 2026-07-31T04:44:53Z
intention: "intention_01kyv7saq6ew2a2k5vw230pw1f"
---

# Add a portable one-off repository agent harness

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, a developer can enter any local Git repository and run a declared
Shikigami agent against that checkout without cloning Shikigami, starting its service stack,
or creating a database. The command defaults the workspace to the current Git worktree,
loads an agent from either that repository or an explicitly supplied agent bundle, sends the
task and repository context to the configured real model, and gives the agent bounded tools
for reading, searching, editing, and running approved commands inside that worktree.

The user-visible entry point is a dedicated executable owned by **`shikigami-agent`**
(**revised 2026-08-19** — it said "the post-plan-36 workers package", which would have shipped a
binary linking PGMQ and Kafka to prove it does not use them; see
`docs/plans/55-give-one-off-agent-runs-a-light-package-that-does-not-link-the-platform.md`):

```bash
shikigami-run \
  --agent reviewer \
  --agent-root "$HOME/.config/shikigami" \
  --permission edit-workspace \
  "fix the failing parser test and explain the change"
```

With no `--workspace`, this command discovers the Git worktree containing the current
directory. It never dispatches the declaration's sinks, never starts a trigger, and never
opens Kioku or PostgreSQL. It prints the model's final response and a concise summary of
files changed and commands run. `--json` emits the same result as a stable versioned JSON
record. The default permission is `read-only`; writes and command execution require an
explicit workspace policy. The command never commits, pushes, or touches a path outside the
resolved worktree unless a future plan adds a separate, explicit capability.

The end-to-end proof runs the installed flake app from a temporary fixture repository while
the agent manifest and skill live in a different directory. A scripted model first reads and
searches the fixture, is denied a write in read-only mode, then succeeds in
`edit-workspace` mode, runs one allow-listed test command, and leaves a visible uncommitted
diff. A traversal path, symlink escape, shell interpreter, unapproved command, `git commit`,
and `git push` are each rejected with typed errors.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Prerequisites: plans 13, 15, 31, 36, 37, 47, 56, 57, and 59 are complete, including all
      hard upstream dependencies recorded by those plans.
- [x] (2026-08-10) **M0: rewrote Milestone 1 against `Baikai.Agent`.** `baikai 0.5.0.0`
      publishes the permission, capability, safety, command, result, and error vocabulary this
      plan was going to invent, plus an operator policy ceiling. Do not start M1 before reading
      Surprises & Discoveries; roughly half of M1 as written is now an import.
- [x] (2026-08-23) M0 gate cleared: the current cohort pins `baikai 0.5.0.0` and
      `kioku-core 0.5.0.0`; no local compatibility vocabulary is needed.
- [ ] M1: define the canonical workspace, task, and result types **that baikai does not already
      provide**, and implement Git-worktree and agent-root resolution with escape tests. Import
      `AgentRunRequest`, `AgentRunResult`, `AgentCapability`, `AgentSafety`, `AgentOutputMode`,
      `AgentCapturedOutput`, `AgentCommand`, `AgentRenderError`, and `AgentRunFailure` rather
      than declaring equivalents.
- [ ] M1: map the `--permission` flag onto baikai's `AgentCapability` (`read-only`,
      `edit-workspace`, `full-access`) and enforce the operator ceiling with `applyAgentCeiling`,
      which reports every violation rather than clamping an over-broad request.
- [x] (2026-08-23) M2 read-only slice: Plan 59 delivered the immutable `workspace.read`
      revision `1` provider with bounded, contained read/grep/glob tools, lazy one-off opt-in,
      symlink refusal, and the external-worktree scripted proof.
- [ ] M2 remaining: extend the overlay provider family with status/diff and stale-write-safe
      edit/create/delete tools behind new immutable descriptors; enforce write permission,
      instruction discovery, path containment, symlink protection, and output limits.
- [ ] M3: add structured approved-command execution without a shell; enforce exact
      executable/argument-prefix policy, a fail-closed platform sandbox, timeout/output
      limits, workspace cwd, forbidden Git/network/destructive operations, and an invocation
      audit.
- [ ] M4: add the `shikigami-run` executable and Settei configuration, compose the task,
      workspace context, provider, capability overlays, and optional MCP tools, and produce text/JSON
      results without database, trigger, sink, or durable-workflow effects.
- [ ] M5: add an installable `apps.shikigami-run` flake output, user documentation, a
      deterministic external-worktree fixture, CLI/security tests, and one optional live
      provider smoke test; `cabal test all` and `nix flake check` pass.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**Baikai published this plan's core vocabulary on 2026-08-05 (discovered 2026-08-10).**
`baikai 0.5.0.0` added the exposed module `Baikai.Agent`, described by its own changelog as "the
provider-neutral vocabulary for an **unattended coding-agent run** — a run with no terminal and no
human, which owns its own tool loop, may change files inside directories the caller authorized,
and returns a process result rather than a `Response`". That is this plan's subject, stated by
somebody who had not read this plan.

What it defines, against what Milestone 1 was going to invent:

`AgentRunRequest`, with a **required** `workingDir` — the workspace type. `AgentRunResult` — the
result type. The `AgentCapability` profile with exactly three levels, `read-only`,
`edit-workspace`, and `full-access` — the permission type, and note that this plan's `--permission
workspace-write` should become `edit-workspace` to match rather than introducing a fourth name for
the same idea. `AgentSafety`. `AgentOutputMode` and `AgentCapturedOutput` — the output discipline,
which Milestone 3's output limits should be expressed in terms of. The `AgentCommand`
renderer/runner boundary with an explicit prompt transport — the command-policy seam Milestone 3
builds on. And the `AgentRenderError` / `AgentRunFailure` taxonomies — the error types.

There is also `AgentCeiling`, `defaultAgentCeiling`, `CeilingViolation`, and the pure
`applyAgentCeiling`, which is an operator policy ceiling this plan did not think to ask for and
should adopt directly. Its behavior is the right one and is worth stating explicitly because it is
easy to get wrong: it returns a request unchanged when the request is within the ceiling, and
reports **every** violation when it is not — it never silently clamps an over-broad request down
to the permitted value. The default ceiling permits read-only and edit-workspace authority and
refuses full access and raw provider arguments, which matches this plan's stated default of
`read-only` with writes requiring an explicit policy.

Two boundaries to respect. `Baikai.Agent` is deliberately vocabulary and pure policy algebra only:
it spawns no process and renders no command-line flags. Those live in the vendor packages and in
the separate `baikai-agent` package, so Milestone 3's actual process execution is still this
plan's work — what changes is that its types are not. And the module is deliberately **not**
re-exported from the umbrella `Baikai` module, because its field accessors collide with
`Baikai.Interactive`; import `Baikai.Agent` explicitly, and expect `import Baikai` to keep
compiling unchanged.

**Effect on this plan's size.** Milestone 1 now extends Plan 59's canonical Git-worktree scope
with agent-resource roots and invocation metadata rather than implementing discovery twice. The
type-definition half of M1 becomes an import list. Plan 59 also delivered M2's read-only
read/grep/glob slice. Milestones 2, 3, and 5 retain the remaining substance: Git inspection,
stale-write-safe mutation, instruction discovery, no-shell execution policy and platform sandbox,
the flake app, and the full writable fixture-repository proof.

**Gate resolution.** The gate described in the 2026-08-10 revision has cleared:
`cabal.project` and `docs/dependency-cohort.md` now select `baikai 0.5.0.0` with
`kioku-core 0.5.0.0`. Keep importing the released vocabulary; do not recreate it locally.

- The current `run-behavior` command already accepts an arbitrary manifest path and works
  when invoked outside this checkout, but `Shikigami.Behavior.Skill` interprets the
  declaration's skill path relative to the process working directory. Portability therefore
  requires separate explicit workspace and agent-resource roots; changing the process cwd
  would conflate the repository being acted on with the bundle defining the agent.
- Plans 56 and 57 supply the declaration/catalog contract, model-facing `ToolRegistry`,
  collision-safe composition, provider lease bracket, and bounded tool-call loop. Plan 59 supplies
  the first `workspace.read` provider. This plan extends those seams instead of creating a second
  tool protocol or completion loop. Plan 12 is relevant only when the harness also enables an MCP
  provider.
- Plan 31 packages long-running NixOS services but does not define a `nix run` application
  for an ephemeral repository command. This plan extends its settled flake rather than
  changing the NixOS service module.
- MasterPlan 1 explicitly deferred executable skill scripts, MasterPlan 8 excludes source
  edits, and MasterPlan 9 is an advisory revision-pinned reviewer that must not read arbitrary
  host paths. None owns a safe local-worktree harness, so this plan does not duplicate an
  existing child plan.


## Decision Log

Record every decision made while working on the plan.

- Decision: Add a dedicated `shikigami-run` executable to `shikigami-agent`; do not add a
  cross-package umbrella subcommand.
  Rationale: Plan 55 established the light leaf for one-off behavior entry points. A dedicated
  binary is independently installable without linking the platform runtime and preserves that
  package boundary.
  Date: 2026-08-19

- Decision: Make the current Git worktree the default workspace and keep `--workspace` as an
  explicit override; require a Git worktree in the first release.
  Rationale: repository status, revision, diff, containment, and the final changed-file
  report need one unambiguous root. Accepting arbitrary directories would weaken those
  guarantees and can be added later behind a distinct mode.
  Date: 2026-07-30

- Decision: Keep agent resources separate from the workspace. `--agent-root` defaults to the
  workspace root, and agent names resolve to `<agent-root>/agents/<name>.dhall`; a manifest
  path is resolved against the agent root. Skill and other declared resource paths resolve
  against the same root.
  Rationale: repository-local agents remain concise, while a centrally installed agent
  bundle can operate on any checkout. Resolution no longer depends on incidental process
  cwd and existing Shikigami-style `agents/skills/...` paths retain their meaning when the
  Shikigami checkout is supplied as the agent root.
  Date: 2026-07-30

- Decision: Runs are synchronous, ephemeral, trigger-free, and sink-free. Persistent memory,
  durable Flow execution, delegation, and sink dispatch remain on `shikigami-agent-run` and
  the worker path.
  Rationale: Mixing a mutable local checkout with a resumable workflow would make replay
  depend on changing filesystem state. The requested one-off command needs no database and
  must not accidentally produce external side effects declared for scheduled agents.
  Date: 2026-07-30

- Decision: Default to `read-only`; enable local writes only with
  `--permission edit-workspace`; require command authorization from typed Settei policy in
  both modes. There is no blanket `--yes`, arbitrary shell-string, commit, or push option.
  Rationale: An invocation flag can authorize bounded workspace mutation, but it must not
  silently grant arbitrary process or remote authority. Exact structured command rules are
  reviewable and cannot be widened by shell parsing.
  Date: 2026-07-30

- Decision: Reuse Plans 56 and 57 for capability resolution, `ToolRegistry` composition, the
  bounded tool-call loop, provider leases, and principal handling; consume Plan 59's
  `workspace.read` provider. Plan 12 remains an optional MCP adapter only.
  Rationale: One generic overlay registry gives the model one collision-checked capability
  catalog without making local workspace authority depend on a remote transport. Local invocation
  consent remains distinct from identity-based MCP authorization.
  Date: 2026-08-23

- Decision: Never add writable or command tools to the released `workspace.read` revision `1`
  descriptor in place.
  Rationale: Capability descriptors are immutable public semantics. This plan must publish a new
  read descriptor revision for additive observations and separate write/exec capability ids for
  stronger authority, retaining old revisions while any durable journal can name them.
  Date: 2026-08-23

- Decision: Use optimistic, hash-checked file mutation rather than an unrestricted write or
  external patch command.
  Rationale: An edit can fail loudly when the file changed after the model read it, and the
  runtime can enforce path, size, instruction, and symlink checks before writing. Invoking a
  shell-level patch utility would create a second command-authorization escape hatch.
  Date: 2026-07-30


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a declared-agent runtime. An agent declaration is a typed Dhall file whose
`behavior` selects a Skill, a named Shikumi program, or a durable Flow. Today
`shikigami-agent/src/Shikigami/Agent/Command/RunBehavior.hs` loads a manifest, constructs a
`BehaviorEnv`, passes a JSON payload to `runBehavior`, and prints JSON. It does not use a
database or sinks. `shikigami-core/src/Shikigami/Agent/Loader.hs` wraps Dhall's
`inputFile`; relative Dhall imports already follow the manifest, but the decoded
`Skill.path` is plain text. `shikigami-core/src/Shikigami/Behavior/Skill.hs` currently joins
that text directly with `SKILL.md`, so it is process-cwd-relative.

Several checked-in plans deliberately change this tree before this work starts. Treat their
completed implementations—not today's legacy paths—as the source of truth:

- `docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`
  creates `shikigami-workers`, moves behavior entry points into it, and removes
  `shikigami-cli`. This plan adds its executable and command composition there.
- `docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md` makes Settei the
  sole typed process-configuration mechanism. This plan adds settings to
  `Shikigami.App.Config` and source assembly to `Shikigami.Workers.Config`; it must not read
  environment variables directly.
- `docs/plans/47-upgrade-shikigami-to-the-coherent-july-2026-dependency-cohort.md` ports
  Baikai, Shikumi, Keiro, Kioku, and other dependencies to their coherent released APIs.
  Implementation must use the versions and constructors recorded in
  `docs/dependency-cohort.md`.
- `docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md` provides typed provider
  selection and `newBehaviorEnvFor`; the one-off command requires a configured real provider
  and refuses the stub unless the user explicitly selects a test-only stub mode.
- `docs/plans/15-inject-recalled-memory-and-trigger-payload-into-behavior-context.md`
  defines the behavior input/context assembly used by both Skill and Shikumi arms. This plan
  supplies a one-off task and workspace summary through that interface instead of building a
  second prompt format.
- `docs/plans/56-declare-agent-capability-overlay-requirements-and-the-operator-catalog.md`
  adds the agent request, immutable descriptor, catalog, and pure authorization vocabulary.
  `docs/plans/57-acquire-and-release-overlay-leases-around-one-behavior-run.md` adds the
  provider registry, collision-safe tool composition, lease bracket, and bounded model/tool
  loop. Plan 59 supplies the first concrete `workspace.read` revision `1` provider in
  `shikigami-agent`. Plan 12 is an optional MCP-provider concern only.
- `docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md`
  settles `flake.module.nix`, package outputs, and NixOS deployment. This plan adds an app
  output for the existing package; it does not create another NixOS service.

A **workspace** is the canonical root of one local Git worktree plus the invocation's
starting directory. A **resource root** is the canonical directory under which the agent
manifest's non-Dhall assets, such as `agents/skills/reviewer/SKILL.md`, are resolved. They
may be different. A **workspace provider** is an operator-owned capability provider whose
logical tools enter the same run-local registry as other overlays. A **command policy** is a bounded list of exact executable plus
argument-prefix rules; it is not a shell allow-list and does not perform substring matching.

The runtime must preserve three trust boundaries. Repository content other than applicable
`AGENTS.md` files is untrusted model input. Agent instructions and declared remote tools do
not grant local filesystem or process authority. The CLI user's permission and Settei
command policy grant only the bounded local actions described here; overlay authorization
still governs every local provider, and Plan 12 governs an optional MCP provider and its
dispatch.


## Plan of Work

Before editing, verify every prerequisite's Progress section is complete. If any is not,
stop; do not implement temporary stubs for its promised interface. Use Mori to locate the
released `shikumi-tools`, Baikai, and process-library source before calling their APIs, and
verify the selected versions against `docs/dependency-cohort.md`, Hackage, and upstream
release tags.

### Milestone 1 — workspace and invocation domain

Extend the canonical workspace scope already implemented in
`shikigami-agent/src/Shikigami/Agent/Capability/Workspace.hs`, and add focused one-off
domain modules in `shikigami-agent` as needed. Define strict domain types for the
canonical workspace root, starting directory, resource root, task, permission, bounded
limits, command rule, invocation report, and typed errors. Use direct record fields under
`DuplicateRecordFields`; do not prefix them with their type.

Plan 59's `resolveWorkspaceScope` already canonicalizes `--workspace` or the current
directory and runs Git with structured arguments to obtain the containing worktree root.
Extend that value to record the full `HEAD` when available,
and records dirty/untracked status. A repository with no commit is valid and records no
revision; a directory outside a Git worktree is a typed startup error. Resolve
`--agent-root` separately. `resolveAgent` maps a bare name to
`<agent-root>/agents/<name>.dhall` and a path to an agent-root-relative path. Reject an
agent/resource path that escapes its root after canonicalization, except that the manifest
itself may be an explicitly supplied absolute file only when it remains beneath an explicitly
supplied `--agent-root`. Never call `setCurrentDirectory`.

Add `LoadedAgent` or an equivalent loader result carrying the declaration, canonical
manifest path, and resource root. Thread the root into Skill resolution and other
file-backed synchronous behavior resources. Preserve legacy command behavior by having
`shikigami-run-behavior` explicitly pass its old invocation root until its documentation is
migrated; do not change resource resolution accidentally for existing deployments.

Acceptance is a pure/tested boundary: invocation from a nested directory finds the same
worktree; an external agent root works; an unborn Git repository works; a non-repository,
missing manifest, root escape, and resource escape fail with distinct errors.

### Milestone 2 — bounded workspace file tools

Extend the provider family in `shikigami-agent/src/Shikigami/Agent/Capability/`. Preserve
the released `workspace.read` revision `1` descriptor exactly: its logical `read`, `grep`, and
`glob` observations appear on the wire as:

```text
overlay__workspace-read__read
overlay__workspace-read__grep
overlay__workspace-read__glob
```

Publish a new read descriptor revision before adding status or diff observations, and retain
revision `1` while any durable snapshot can name it. Put edit/create/delete tools under a
separate immutable write capability id so an observation request can never gain mutation by
provider upgrade. Compose every provider through Plan 57's collision-checked run-local
registry; do not merge raw maps or reserve ad-hoc global names.

Every request uses a normalized workspace-relative path. Centralize containment in one
function that rejects absolute input, `..`, NUL, `.git` internals, and any canonical result
outside the worktree. Do not traverse or write through a symlink whose resolved target is
outside the worktree. Bound directory entries, search matches, bytes per file, total tool
result bytes, and write size with validated types from plan 37's configuration idiom.
Search uses a library API or a structured `rg` process with fixed flags and
separate arguments; never concatenate a shell command.

At invocation start, load `AGENTS.md` from the worktree root when present and include it in
the trusted instruction context. Track applicable nested `AGENTS.md` files from root to a
requested path. A mutating request whose applicable instruction file has not yet been
returned to the model is rejected once with an `InstructionsRequired` result containing the
bounded instruction text; retry after that result may proceed. This makes nested
instructions visible before mutation without preloading the entire repository. An
instruction chain over the configured bound fails closed with `InstructionsTooLarge`; never
truncate an instruction file and then act as if the complete policy was applied.

Reads return a content hash. The write provider's edit tool accepts that expected hash plus a non-empty
list of exact old/new replacements; each old value must match exactly once unless the
request explicitly sets a bounded `replaceAll`. Its create tool fails if the path
exists. Its delete tool requires the current expected hash and operates on regular
files only. Write to a sibling temporary file and atomically rename for edit/create; preserve
the original mode where applicable. All three mutations are absent from the registry in
read-only mode rather than being advertised and denied after model selection.

Acceptance is a fake-model tool-loop test that reads and edits one fixture, plus focused
tests for stale hashes, duplicate replacement text, size limits, traversal, absolute paths,
`.git`, symlink escape, unread nested instructions, and read-only registry contents.

### Milestone 3 — structured command execution

Add the command adapter to `shikigami-agent` and publish a separate immutable
`workspace.exec` descriptor. Its logical `exec` tool appears as
`overlay__workspace-exec__exec` and is installed only when at least one command rule is
configured. Its input is structured:

```json
{
  "executable": "cabal",
  "arguments": ["test", "parser-test"],
  "cwd": ".",
  "timeout_seconds": 120
}
```

Use a process API with an executable and argument vector, `cwd` fixed beneath the workspace,
an explicit environment assembled by the application boundary, captured stdout/stderr,
bounded output, and a bounded timeout with process-group termination. Do not invoke
`sh`, `bash`, `zsh`, PowerShell, `env`, `xargs`, or another interpreter/dispatcher at the
model's request. A command rule matches the canonical configured executable and an exact
argument prefix element by element. Empty prefixes do not authorize a command. Resolve the
executable once at startup from a configured absolute path or a sanitized PATH, then compare
that canonical path at dispatch to prevent PATH substitution.

Run the approved child through a runtime-owned sandbox adapter. On Linux use a verified
Bubblewrap adapter; on macOS use a verified Seatbelt (`sandbox-exec`) profile while that
facility is present. The generated policy grants the minimum system/runtime reads required
to launch the selected executable, a private temporary directory, and read/write access only
to the canonical workspace. Deny network access, device access, process inspection, and
filesystem access outside those roots. The adapter builds its own structured argument
vector; it does not accept model-authored policy text. Probe the backend before advertising
`overlay__workspace-exec__exec`; if no tested backend is present, omit the tool and report
`SandboxUnavailable` at startup when command rules were requested. There is no unsandboxed
fallback or override in this plan. Package the selected backend where the platform permits
and add policy tests that attempt outside reads, outside writes, and network access.

Regardless of configured rules, reject Git mutation or remote operations (`commit`, `push`,
`fetch`, `pull`, `reset`, `clean`, worktree removal), package publication, privilege
escalation, and commands targeting paths outside the workspace. The initial version does not
provide an override for this deny set. Advertise `workspace.exec` only in
`edit-workspace` mode because even a sandboxed compiler or test may write build artifacts
inside the worktree. Read-only mode therefore exposes no local mutation or process tool.

Record executable, arguments, relative cwd, start/end time, exit status, timeout, and
truncation in memory for the final invocation report. Do not log inherited environment
values or command output. Acceptance covers exact-prefix success, near-prefix denial,
interpreter denial, Git denial, sandbox absence, outside read/write denial, network denial,
timeout cleanup, bounded output, cwd escape, and redacted environment behavior.

### Milestone 4 — one-off composition and CLI

Add `Shikigami.Agent.Command.Run` and focused capability modules to `shikigami-agent`, plus
an executable entry point under `shikigami-agent/app/`. Register a third `RoleInfo` beside
the two existing one-off commands and name the executable `shikigami-run`.

The parser accepts:

```text
shikigami-run
  --agent NAME|FILE
  [--agent-root DIR]
  [--workspace DIR]
  [--permission read-only|edit-workspace]
  [--task-file FILE | --stdin | TASK]
  [--json]
  [Settei --config/--set/diagnostic options]
```

Exactly one task source is required. `--workspace` defaults to the current directory;
`--agent-root` defaults to the workspace root; permission defaults to `read-only`. A task
file is read by the CLI before model construction and is not exposed as arbitrary workspace
authority. Standard plan-37 diagnostics run before workspace discovery or provider
construction.

Add bounded settings under `one_off.*` for maximum tool iterations, input/output bytes,
file bytes, search matches, directory entries, command timeout, command output, inherited
environment-name allow-list, and command rules. Extend plan 13's provider config rather than
adding provider flags. Unknown keys fail. Secret settings remain opaque and redacted.

Build one `OneOffInput` JSON/context value containing the task, worktree-relative starting
directory, optional full revision, dirty flag, root `AGENTS.md`, permission, and explicitly
non-secret invocation metadata. Do not include an unbounded tree, file contents, environment,
or Git diff in the initial prompt; the model obtains those through tools. Construct the
plan-13 real `BehaviorEnv`, resolve and bracket declared capability providers through Plans
56 and 57, optionally include an authorized Plan-12 MCP provider, and call the plan-15
behavior-context seam. Reject Flow behavior with a
typed message directing the user to the durable worker. Support Skill and synchronous
Shikumi behaviors through their shared tool loop.

Do not dispatch sinks, evaluate triggers, open PostgreSQL, create a Kioku session, enqueue a
job, or invoke a Keiro workflow. Reject an implicit stub provider; allow it only through the
existing explicit test configuration so CI remains deterministic. On success or failure,
render a final report containing version, agent, workspace, revision, permission, provider,
final response or typed error, changed paths computed from Git, and command audit. Text mode
prints the response first and a concise summary to stderr; JSON mode writes one JSON document
to stdout and diagnostics to stderr.

Acceptance is a CLI test proving that an external agent bundle can act on the current
fixture worktree without treating the bundle as the workspace, and that no database or sink
endpoint is touched.

### Milestone 5 — installation, documentation, and end-to-end proof

Extend the flake settled by plan 31 with `packages.shikigami` as the installable package
containing the command-line binaries and `apps.shikigami-run` pointing at its
`shikigami-run` executable. These outputs may alias an existing package derivation; do not
duplicate the Cabal build or create an eighth Haskell package. Prove both:

```bash
nix run .#shikigami-run -- --help
nix profile install .#shikigami
```

The installed profile must expose `shikigami-run`. Keep the NixOS service module unchanged:
this is an interactive one-shot app, not a daemon.

Add `docs/user/one-off.md`, update `docs/user/cli.md`,
`docs/user/getting-started.md`, and the generated/configuration reference owned by plan 37.
Document central agent bundles, repository-local agents, permission modes, command rules,
root/nested `AGENTS.md`, no-commit behavior, JSON output, and recovery from a failed run.

Create small deterministic fixtures under `fixtures/one-off/`: a Git repository template,
an external agent bundle, a scripted provider/tool transcript, and a harmless test command.
Tests copy them into task-specific temporary directories and initialize commits there; they
must not depend on the developer's global Git config, network, API key, or existing checkout
state. Add one optional manual smoke using the plan-13 Anthropic configuration, but never
record the credential or make it a CI requirement.

Acceptance is the external-worktree transcript described in Purpose, the full Cabal suite,
flake checks, formatting, and a clean source diff containing only the fixture edit the
scripted agent was expected to make.


## Concrete Steps

Run all implementation commands from
`/Users/shinzui/Keikaku/bokuno/shikigami`. First verify prerequisites:

```bash
for plan in 13 15 31 36 37 47 56 57 59; do
  file=$(rg --files docs/plans | rg "/${plan}-[^/]+\\.md$")
  printf '%s ' "$file"
  if rg -q '^- \[ \]' "$file"; then
    printf 'INCOMPLETE\n'
  else
    printf 'COMPLETE\n'
  fi
done
```

Expected before implementation:

```text
docs/plans/13-... COMPLETE
docs/plans/15-... COMPLETE
docs/plans/31-... COMPLETE
docs/plans/36-... COMPLETE
docs/plans/37-... COMPLETE
docs/plans/47-... COMPLETE
docs/plans/56-... COMPLETE
docs/plans/57-... COMPLETE
docs/plans/59-... COMPLETE
```

Locate dependency source before using APIs:

```bash
mori registry show shinzui/shikumi --full
mori registry docs shinzui/shikumi
mori registry show shinzui/baikai --full
mori registry docs shinzui/baikai
```

After each milestone, format and run the smallest affected tests. Adjust component names
only to the final plan-36 layout:

```bash
nix develop --command fourmolu -i \
  shikigami-agent/src/Shikigami/Agent/Capability \
  shikigami-agent/src/Shikigami/Agent/Command/Run.hs
nix develop --command cabal test shikigami-core-test \
  --test-options='-p "one-off"' --test-show-details=direct
nix develop --command cabal test shikigami-agent-test \
  --test-options='-p "one-off"' --test-show-details=direct
```

Exercise the parser and diagnostics without constructing a provider:

```bash
cabal run shikigami-run -- --help
cabal run shikigami-run -- --describe-config
cabal run shikigami-run -- --check-config --config fixtures/one-off/config.yaml
```

Run the hermetic end-to-end harness created in M5:

```bash
just test-one-off
```

Its concise transcript must have this shape:

```text
[read-only] overlay__workspace-read__read ok
[read-only] workspace write capability unavailable
[edit-workspace] overlay__workspace-read__read ok
[edit-workspace] workspace write tool changed src/Parser.txt
[edit-workspace] overlay__workspace-exec__exec test-pass exit=0
changed: src/Parser.txt
commits created: 0
```

Finish with the complete gates:

```bash
nix develop --command cabal build all
nix develop --command cabal test all --test-show-details=direct
nix flake check
nix run .#shikigami-run -- --help
git diff --check
git status --short
```

Update this section with the actual component names and final proof transcript as the work
lands.


## Validation and Acceptance

The plan is complete only when all of the following are observable:

1. From a temporary Git repository unrelated to the Shikigami checkout, an installed
   `shikigami-run` loads an agent and skill from a separately supplied agent root, receives a
   task, and returns a final response. No Shikigami source-relative path, database, Kafka
   broker, or sink service is required.
2. Omitting `--workspace` uses the containing Git worktree even when invoked from a nested
   directory. `--workspace` selects another worktree. Non-Git directories, missing roots,
   and ambiguous/escaping agent resources fail before provider construction with distinct
   typed errors.
3. Read-only mode advertises read/search/status/diff but no edit/create/delete/exec tools. In
   edit-workspace mode, a hash-matched edit creates an uncommitted diff; stale hashes,
   traversal, absolute paths, `.git`, outside symlinks, oversized values, and unapplied
   nested instructions are rejected.
4. `overlay__workspace-exec__exec` runs only an exact configured executable/argument prefix in a contained
   cwd. Near matches, interpreters, Git mutation/remotes, publication, privilege escalation,
   outside targets, unavailable sandbox, outside reads/writes, network access, excessive
   timeout, and excessive output fail safely. Timed-out child process groups do not remain
   running.
5. A real configured provider sees the task and workspace summary, can call workspace and
   authorized MCP tools through one bounded loop, and returns a non-stub response. The
   deterministic scripted provider proves the same sequence in CI.
6. The command never evaluates triggers, dispatches sinks, creates a Kioku session, opens
   PostgreSQL, starts Keiro, commits, pushes, or edits outside the workspace. Tests install
   fail-fast sentinels for database and sink access and assert they are untouched.
7. Text and `--json` modes agree on agent, canonical workspace, revision, permission,
   provider, changed paths, command audit, final response/error, and result schema version.
   Secrets, inherited environment values, file contents, tool arguments/results, and command
   output do not appear in logs or the summary unless they are the explicit final response.
8. `nix run .#shikigami-run -- --help`, profile installation, `cabal build all`,
   `cabal test all`, `nix flake check`, and `git diff --check` succeed. Documentation gives a
   copy-pasteable invocation from another repository.


## Idempotence and Recovery

Workspace discovery, reads, searches, Git inspection, configuration diagnostics, and
read-only runs are repeatable. File edits use expected hashes, so replaying a mutation
against changed content fails instead of applying twice. Creation fails when the target
already exists; deletion requires the current hash. A failed atomic rename leaves either
the old file or the new file, never a partially written target; task-specific temporary
files are cleaned on the normal and exception paths.

The command does not automatically roll back successful workspace edits when a later model
or command step fails. It reports every changed path and leaves recovery to the repository's
normal review tools. The user can inspect `git diff` and restore selected files explicitly.
Tests always operate on disposable fixture copies and may delete only the exact temporary
directory they created.

Process timeout sends termination to the created process group, waits for the configured
grace bound, then kills that group. It never targets a pid it did not create. Truncated
stdout/stderr is marked in the command audit. Provider or MCP failure closes every Plan-57
lease through the existing bracket and still renders the local invocation report.

Implementation should land in milestone-sized commits. If a prerequisite interface differs
from this plan, update this document's Context, Decision Log, Interfaces, and validation
before adapting; do not restore a legacy stub, direct environment read, unbounded tool loop,
or second registry as a workaround.


## Portfolio Reconciliation (2026-08-05)

Two notes, neither of which changes this plan's scope.

**Registration.** This plan belongs to no MasterPlan. That was true when it was written and is still
true; it is recorded here so the omission reads as deliberate rather than lost. Its prerequisite list
below remains authoritative.

**One external constraint on the permission boundary.**
`docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md` signs run attestations with a key
that must be unreachable from the agent's behavior, its prompt, its tools, and its repository
workspace — a requirement of both
`docs/improvement-requests/attest-sanctioned-agent-execution.md` and the shared upstream contract
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6`, whose reasoning is that a signature
produced by the same unrestricted process that could fabricate the evidence offers weaker assurance.
This plan owns the workspace, the command policy, and the `AgentCapability` boundary that such a key
must sit outside of. When implementing the permission model, treat "no path by which workspace-scoped
code reaches a signing credential" as an explicit property to assert in a test, in the same spirit as
the existing rule that a declaration is never authorization. Plan 52 asserts the exclusion against its
own boundary; if this plan lands first, plan 52 asserts it against this one instead.


## Interfaces and Dependencies

This is a standalone cross-cutting ExecPlan. Its hard prerequisites are:

- `docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md`
  for package and executable ownership.
- `docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md` for typed,
  redacted CLI configuration.
- `docs/plans/47-upgrade-shikigami-to-the-coherent-july-2026-dependency-cohort.md` for the
  released Baikai/Shikumi/process APIs.
- `docs/plans/13-wire-a-real-model-provider-into-behavior-runs.md` for explicit real model
  selection and provider construction.
- `docs/plans/15-inject-recalled-memory-and-trigger-payload-into-behavior-context.md` for one
  shared behavior input/context assembly.
- `docs/plans/56-declare-agent-capability-overlay-requirements-and-the-operator-catalog.md`
  for declaration requests, immutable descriptors, catalog resolution, and policy.
- `docs/plans/57-acquire-and-release-overlay-leases-around-one-behavior-run.md` for the
  provider registry, collision-safe `ToolRegistry` composition, bounded model/tool loop,
  and lease bracket.
- `docs/plans/59-adopt-capability-overlays-in-the-portable-one-off-repository-harness.md`
  for the canonical worktree scope, `workspace.read` revision `1`, and one-off composition
  helper.
- `docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md`
  for the final flake/package/configuration surface this plan extends.

These are hard edges, not suggested landing order. Do not begin M1 while any remains
incomplete. Their own hard dependencies are transitive and remain authoritative.
MasterPlans 8 and 9 are not prerequisites: their router and architecture-review domains may
later consume this harness, but the harness must remain domain-neutral. Plan 12 is an
optional soft dependency only when this harness also enables an MCP provider.

The final `shikigami-agent` interface should be equivalent to:

```haskell
-- Imported from Baikai.Agent; shown here only to make the boundary concrete.
data AgentCapability = ReadOnly | EditWorkspace | FullAccess

data Workspace = Workspace
  { root :: !WorkspaceRoot
  , startDirectory :: !RelativePath
  , revision :: !(Maybe Revision)
  , dirty :: !Bool
  }

data AgentResources = AgentResources
  { root :: !ResourceRoot
  , manifest :: !FilePath
  }

data OneOffRequest = OneOffRequest
  { task :: !OneOffTask
  , workspace :: !Workspace
  , resources :: !AgentResources
  , permission :: !AgentCapability
  }

data CommandRule = CommandRule
  { executable :: !CanonicalExecutable
  , argumentPrefix :: !(NonEmpty Text)
  }

data OneOffResult = OneOffResult
  { version :: !Natural
  , agent :: !Text
  , workspace :: !WorkspaceRoot
  , revision :: !(Maybe Revision)
  , permission :: !AgentCapability
  , provider :: !Text
  , response :: !(Maybe Value)
  , changedPaths :: ![RelativePath]
  , commands :: ![CommandAudit]
  , error :: !(Maybe OneOffError)
  }

resolveWorkspace ::
  Maybe FilePath ->
  IO (Either WorkspaceError Workspace)

resolveAgentResources ::
  Workspace ->
  Maybe FilePath ->
  String ->
  IO (Either AgentResourceError AgentResources)

workspaceTools ::
  OneOffConfig ->
  Workspace ->
  AgentCapability ->
  IO (Either WorkspaceToolError [CapabilityProvider])

runOneOff ::
  OneOffRuntime ->
  OneOffRequest ->
  IO OneOffResult
```

Use Plan 57's exact provider registry and lease combination API. Each descriptor publishes
logical tool names; the shared runtime derives collision-checked wire names such as
`overlay__workspace-read__read`. Do not add a Shikigami-specific map merge or bypass the
run-scoped active capability set.

The implementation may add a released process dependency after using Mori and verifying
the current registry/tag, but it must use argument-vector execution, process groups, bounded
capture, and timeouts. The flake supplies Bubblewrap on supported Linux systems and verifies
the macOS Seatbelt executable before selecting it; unsupported systems expose no exec tool.
Never search or read `/nix/store`; dependency source comes from Mori. File APIs come from
`directory`/`filepath` or an already selected coherent library.

Configuration extends the plan-37 `Config` with strict bounded values and secret-free
command rules. `shikigami-agent` owns CLI source assembly. No new environment variable
read, configuration parser, Haskell package, HTTP server, database table, queue, or public
API route is introduced.

Every Haskell record follows
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`: direct,
unprefixed fields, `DuplicateRecordFields`, strict fields, explicit deriving strategies,
and generic-lens access/update where the final package conventions require it.

Every implementation commit includes:

```text
ExecPlan: docs/plans/48-add-a-portable-one-off-repository-agent-harness.md
Intention: intention_01kyv7saq6ew2a2k5vw230pw1f
```


## Revision Notes

- 2026-08-10: Re-pointed Milestone 1 at `Baikai.Agent`, and added a gate so the plan is not
  implemented against a vocabulary it should be importing.

  `baikai 0.5.0.0`, released 2026-08-05, added `Baikai.Agent` — its changelog calls it "the
  provider-neutral vocabulary for an unattended coding-agent run", which is this plan's subject
  described by somebody who had not read this plan. It publishes `AgentRunRequest` (with a
  required `workingDir`), `AgentRunResult`, the three-level `AgentCapability` profile,
  `AgentSafety`, `AgentOutputMode` and `AgentCapturedOutput`, the `AgentCommand` renderer/runner
  boundary, and the `AgentRenderError` / `AgentRunFailure` taxonomies. Milestone 1 was going to
  define workspace, task, permission, command-policy, result, and error types; most of that list
  now has a published counterpart, and defining local equivalents would leave shikigami
  translating between two vocabularies for one concept.

  One adoption is a genuine addition rather than a substitution: `AgentCeiling` /
  `applyAgentCeiling`, an operator policy ceiling this plan did not think to ask for. Its
  behavior is the part worth having — it returns a request unchanged when within the ceiling and
  reports every violation when not, never silently clamping an over-broad request to the permitted
  value — and its default matches this plan's stated posture of read-only by default with writes
  requiring explicit policy.

  One naming change follows: `--permission workspace-write` should become `edit-workspace`, to
  match `AgentCapability` rather than introduce a fourth name for the same idea.

  What did not shrink is worth stating, because the plan is not mostly obsolete. `Baikai.Agent` is
  vocabulary and pure policy algebra only — it spawns no process and renders no flags, which live
  in the vendor packages and the separate `baikai-agent` package. So Milestone 1's Git-worktree
  discovery, escape tests, and the separation of workspace root from agent-resource root are
  untouched, and Milestones 2, 3, and 5 keep their substance: bounded workspace providers in
  Plan 57's run-local `ToolRegistry`, path containment and symlink protection, no-shell execution with a fail-closed
  platform sandbox, the flake app, and the external-fixture proof.

  One import caution recorded in Surprises & Discoveries: `Baikai.Agent` is deliberately not
  re-exported from the umbrella `Baikai` module because its field accessors collide with
  `Baikai.Interactive`. Import it explicitly.

  Gate: `kioku-core 0.3.0.0` caps `baikai ^>=0.4.1.0`, so the cohort cannot take 0.5 yet — the
  same gate as plans 51 and 52, owned by plan 53. The plan explicitly rejects working around it by
  defining the vocabulary locally "for now", since that produces exactly the duplicate this
  revision exists to prevent.

- 2026-08-23: Consumed Plan 59's delivered `workspace.read` revision `1`, canonical Git
  worktree scope, lazy one-off resolution, and behavior-scoped provider lease. The remaining
  harness work extends that provider family in `shikigami-agent`: additive observations need
  a new read revision, while mutations and command execution need separate capability ids.
  Plan 12 is now only an optional MCP-provider integration, not the generic tool registry or
  lifecycle prerequisite.


## Reconciliation with plan 55 (2026-08-19)

`shikigami-run` belongs in **`shikigami-agent`**, not `shikigami-workers`.

This plan's Purpose says the command "never dispatches the declaration's sinks, never starts a
trigger, and never opens Kioku or PostgreSQL", and then assigned its executable to the workers
package. Every executable there is `build-depends: base, optparse-applicative,
shikigami-workers`, and that library links `hw-kafka-client`, `kafka-effectful`,
`pgmq-effectful`, `shibuya-pgmq-adapter`, `hs-opentelemetry-sdk`,
`hs-opentelemetry-exporter-otlp`, and `baikai-trace-otel`. The binary would have linked a Kafka
C library in order to demonstrate that it does not use one — which also defeats the plan's own
"without cloning Shikigami, starting its service stack, or creating a database" premise for the
consumer who has to build it.

`docs/plans/55-...md` added `shikigami-agent`, which depends on `shikigami-core` and nothing
else and already owns `shikigami-run-behavior` and `shikigami-agent-run`. Add `shikigami-run`
there, as a third `RoleInfo` in `Shikigami.Agent.Command`, with its command module at
`shikigami-agent/src/Shikigami/Agent/Command/Run.hs`. Two consequences for this plan's
milestones:

- The architecture test now enforces the boundary. `Shikigami.PackageArchitectureSpec` fails if
  `shikigami-agent`'s library acquires a sibling other than `shikigami-core`, or any of the
  listener, exporter, queue-adapter, or stream-client packages, or if an executable links a
  sibling other than its own package. If this plan's tooling needs something that trips those,
  that is a finding to resolve deliberately, not a test to relax.
- Configuration resolution is shared. Use `Shikigami.App.Role.runRole` from `shikigami-core`
  and `withConfigOptions` as the existing two roles do, rather than a private `main`; that is
  what makes `--check-config` and the other diagnostic flags work identically across every
  Shikigami binary.

The durable rationale for the package is
[ADR 0003](../adr/0003-a-seventh-package-keeps-one-off-agent-runs-light.md). This plan is the
second consumer of the mode it protects, and remains unregistered under any MasterPlan — worth
resolving when it is scheduled.


## Reconciliation with capability overlay plans (2026-08-22)

The full writable workspace sandbox in this plan remains in scope: contained file mutation,
structured command execution, platform sandboxing, instruction discovery, installation, and
the external-worktree proof still belong here. Its generic model-tool prerequisites no longer
come from Plan 12's MCP-specific seam.

`docs/plans/56-declare-agent-capability-overlay-requirements-and-the-operator-catalog.md` now
owns capability ids, operator catalog resolution, and the defaulted declaration request.
`docs/plans/57-acquire-and-release-overlay-leases-around-one-behavior-run.md` owns the shared
provider registry, `ToolRegistry` composition, bounded model/tool loop, and acquire/release
bracket. Plan 59, `docs/plans/59-adopt-capability-overlays-in-the-portable-one-off-repository-harness.md`,
owns the first confined read-only workspace provider and one-off opt-in proof. This plan
consumes those seams, then extends the provider with its broader writable and command-backed
sandbox. Plan 12 remains relevant only when the harness also consumes an MCP provider; it is
no longer the owner or hard prerequisite of the generic registry and loop.
