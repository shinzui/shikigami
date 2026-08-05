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

The user-visible entry point is a dedicated executable owned by the post-plan-36 workers
package:

```bash
shikigami-run \
  --agent reviewer \
  --agent-root "$HOME/.config/shikigami" \
  --permission workspace-write \
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
`workspace-write` mode, runs one allow-listed test command, and leaves a visible uncommitted
diff. A traversal path, symlink escape, shell interpreter, unapproved command, `git commit`,
and `git push` are each rejected with typed errors.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Prerequisites: plans 12, 13, 15, 31, 36, 37, and 47 are complete, including all
      hard upstream dependencies recorded by those plans.
- [ ] M1: define canonical workspace, task, permission, command-policy, result, and error
      types; implement Git-worktree and agent-root resolution with escape tests.
- [ ] M2: register bounded read/search/status/diff tools and stale-write-safe
      edit/create/delete tools in the plan-12 `ToolRegistry`; enforce read-only mode,
      instruction discovery, path containment, symlink protection, and output limits.
- [ ] M3: add structured approved-command execution without a shell; enforce exact
      executable/argument-prefix policy, a fail-closed platform sandbox, timeout/output
      limits, workspace cwd, forbidden Git/network/destructive operations, and an invocation
      audit.
- [ ] M4: add the `shikigami-run` executable and Settei configuration, compose the task,
      workspace context, provider, MCP tools, and workspace tools, and produce text/JSON
      results without database, trigger, sink, or durable-workflow effects.
- [ ] M5: add an installable `apps.shikigami-run` flake output, user documentation, a
      deterministic external-worktree fixture, CLI/security tests, and one optional live
      provider smoke test; `cabal test all` and `nix flake check` pass.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The current `run-behavior` command already accepts an arbitrary manifest path and works
  when invoked outside this checkout, but `Shikigami.Behavior.Skill` interprets the
  declaration's skill path relative to the process working directory. Portability therefore
  requires separate explicit workspace and agent-resource roots; changing the process cwd
  would conflate the repository being acted on with the bundle defining the agent.
- Plan 12 supplies the model-facing `ToolRegistry`, MCP connection bracket, per-tool
  authorization, and bounded tool-call loop. This plan must add local workspace tools to that
  registry, not create a second tool protocol or completion loop.
- Plan 31 packages long-running NixOS services but does not define a `nix run` application
  for an ephemeral repository command. This plan extends its settled flake rather than
  changing the NixOS service module.
- MasterPlan 1 explicitly deferred executable skill scripts, MasterPlan 8 excludes source
  edits, and MasterPlan 9 is an advisory revision-pinned reviewer that must not read arbitrary
  host paths. None owns a safe local-worktree harness, so this plan does not duplicate an
  existing child plan.


## Decision Log

Record every decision made while working on the plan.

- Decision: Add a dedicated `shikigami-run` executable to `shikigami-workers`; do not add a
  cross-package umbrella subcommand.
  Rationale: Plan 36 assigns behavior-running executables to the workers package and forbids
  an umbrella dispatcher that imports both server and worker implementations. A dedicated
  binary is independently installable and preserves that package boundary.
  Date: 2026-07-30

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
  `--permission workspace-write`; require command authorization from typed Settei policy in
  both modes. There is no blanket `--yes`, arbitrary shell-string, commit, or push option.
  Rationale: An invocation flag can authorize bounded workspace mutation, but it must not
  silently grant arbitrary process or remote authority. Exact structured command rules are
  reviewable and cannot be widened by shell parsing.
  Date: 2026-07-30

- Decision: Reuse plan 12's `ToolRegistry`, tool-call loop, MCP authorization wrapper, and
  principal handling. Workspace permission is an additional local scope check and never
  grants an MCP server or remote tool.
  Rationale: One registry gives the model one collision-checked capability catalog, while
  keeping local invocation consent distinct from identity-based remote authorization.
  Date: 2026-07-30

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
`shikigami-cli/src/Shikigami/Cli/Commands/RunBehavior.hs` loads a manifest, constructs a
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
- `docs/plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md` adds
  `ToolRegistry`, `withTools`, the MCP lifecycle bracket, authorization, and a bounded
  model/tool loop to both synchronous behavior arms. Workspace tools are ordinary
  `SomeTool` values registered under reserved `workspace__*` names.
- `docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md`
  settles `flake.module.nix`, package outputs, and NixOS deployment. This plan adds an app
  output for the existing package; it does not create another NixOS service.

A **workspace** is the canonical root of one local Git worktree plus the invocation's
starting directory. A **resource root** is the canonical directory under which the agent
manifest's non-Dhall assets, such as `agents/skills/reviewer/SKILL.md`, are resolved. They
may be different. A **workspace tool** is a typed local capability registered in the same
tool registry as MCP tools. A **command policy** is a bounded list of exact executable plus
argument-prefix rules; it is not a shell allow-list and does not perform substring matching.

The runtime must preserve three trust boundaries. Repository content other than applicable
`AGENTS.md` files is untrusted model input. Agent instructions and declared remote tools do
not grant local filesystem or process authority. The CLI user's permission and Settei
command policy grant only the bounded local actions described here; plan 12's authorization
still governs every MCP connection and dispatch.


## Plan of Work

Before editing, verify every prerequisite's Progress section is complete. If any is not,
stop; do not implement temporary stubs for its promised interface. Use Mori to locate the
released `shikumi-tools`, Baikai, and process-library source before calling their APIs, and
verify the selected versions against `docs/dependency-cohort.md`, Hackage, and upstream
release tags.

### Milestone 1 — workspace and invocation domain

Create `shikigami-core/src/Shikigami/OneOff/Types.hs` and
`shikigami-core/src/Shikigami/OneOff/Workspace.hs`. Define strict domain types for the
canonical workspace root, starting directory, resource root, task, permission, bounded
limits, command rule, invocation report, and typed errors. Use direct record fields under
`DuplicateRecordFields`; do not prefix them with their type.

`resolveWorkspace` canonicalizes `--workspace` or the current directory, runs Git with
structured arguments to obtain the containing worktree root and full `HEAD` when available,
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

Create `shikigami-core/src/Shikigami/OneOff/Tools.hs` and focused modules under
`Shikigami.OneOff.Tools.*` if the implementation would otherwise become monolithic. Register
these collision-checked `SomeTool` names into plan 12's registry:

```text
workspace__list
workspace__search
workspace__read
workspace__git_status
workspace__git_diff
workspace__edit
workspace__create
workspace__delete
```

Every request uses a normalized workspace-relative path. Centralize containment in one
function that rejects absolute input, `..`, NUL, `.git` internals, and any canonical result
outside the worktree. Do not traverse or write through a symlink whose resolved target is
outside the worktree. Bound directory entries, search matches, bytes per file, total tool
result bytes, and write size with validated types from plan 37's configuration idiom.
`workspace__search` uses a library API or a structured `rg` process with fixed flags and
separate arguments; never concatenate a shell command.

At invocation start, load `AGENTS.md` from the worktree root when present and include it in
the trusted instruction context. Track applicable nested `AGENTS.md` files from root to a
requested path. A mutating request whose applicable instruction file has not yet been
returned to the model is rejected once with an `InstructionsRequired` result containing the
bounded instruction text; retry after that result may proceed. This makes nested
instructions visible before mutation without preloading the entire repository. An
instruction chain over the configured bound fails closed with `InstructionsTooLarge`; never
truncate an instruction file and then act as if the complete policy was applied.

Reads return a content hash. `workspace__edit` accepts that expected hash plus a non-empty
list of exact old/new replacements; each old value must match exactly once unless the
request explicitly sets a bounded `replaceAll`. `workspace__create` fails if the path
exists. `workspace__delete` requires the current expected hash and operates on regular
files only. Write to a sibling temporary file and atomically rename for edit/create; preserve
the original mode where applicable. All three mutations are absent from the registry in
read-only mode rather than being advertised and denied after model selection.

Acceptance is a fake-model tool-loop test that reads and edits one fixture, plus focused
tests for stale hashes, duplicate replacement text, size limits, traversal, absolute paths,
`.git`, symlink escape, unread nested instructions, and read-only registry contents.

### Milestone 3 — structured command execution

Add `shikigami-core/src/Shikigami/OneOff/Command.hs`. Register
`workspace__exec` only when at least one command rule is configured. Its input is structured:

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
`workspace__exec`; if no tested backend is present, omit the tool and report
`SandboxUnavailable` at startup when command rules were requested. There is no unsandboxed
fallback or override in this plan. Package the selected backend where the platform permits
and add policy tests that attempt outside reads, outside writes, and network access.

Regardless of configured rules, reject Git mutation or remote operations (`commit`, `push`,
`fetch`, `pull`, `reset`, `clean`, worktree removal), package publication, privilege
escalation, and commands targeting paths outside the workspace. The initial version does not
provide an override for this deny set. Advertise `workspace__exec` only in
`workspace-write` mode because even a sandboxed compiler or test may write build artifacts
inside the worktree. Read-only mode therefore exposes no local mutation or process tool.

Record executable, arguments, relative cwd, start/end time, exit status, timeout, and
truncation in memory for the final invocation report. Do not log inherited environment
values or command output. Acceptance covers exact-prefix success, near-prefix denial,
interpreter denial, Git denial, sandbox absence, outside read/write denial, network denial,
timeout cleanup, bounded output, cwd escape, and redacted environment behavior.

### Milestone 4 — one-off composition and CLI

Create `shikigami-workers/src/Shikigami/OneOff/Run.hs`,
`shikigami-workers/src/Shikigami/OneOff/Cli.hs`, and the executable component prescribed by
the post-plan-36 package layout, for example
`shikigami-workers/app/one-off/Main.hs`. Name the executable `shikigami-run`.

The parser accepts:

```text
shikigami-run
  --agent NAME|FILE
  [--agent-root DIR]
  [--workspace DIR]
  [--permission read-only|workspace-write]
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
plan-13 real `BehaviorEnv`, bracket plan-12 MCP tools, merge in workspace tools under
`workspace__*`, and call the plan-15 behavior-context seam. Reject Flow behavior with a
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
duplicate the Cabal build or create a seventh Haskell package. Prove both:

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
for plan in 12 13 15 31 36 37 47; do
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
docs/plans/12-... COMPLETE
docs/plans/13-... COMPLETE
docs/plans/15-... COMPLETE
docs/plans/31-... COMPLETE
docs/plans/36-... COMPLETE
docs/plans/37-... COMPLETE
docs/plans/47-... COMPLETE
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
  shikigami-core/src/Shikigami/OneOff \
  shikigami-workers/src/Shikigami/OneOff
nix develop --command cabal test shikigami-core-test \
  --test-options='-p "one-off"' --test-show-details=direct
nix develop --command cabal test shikigami-workers-test \
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
[read-only] workspace__read ok
[read-only] workspace__edit unavailable
[workspace-write] workspace__read ok
[workspace-write] workspace__edit changed src/Parser.txt
[workspace-write] workspace__exec test-pass exit=0
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
   workspace-write mode, a hash-matched edit creates an uncommitted diff; stale hashes,
   traversal, absolute paths, `.git`, outside symlinks, oversized values, and unapplied
   nested instructions are rejected.
4. `workspace__exec` runs only an exact configured executable/argument prefix in a contained
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
stdout/stderr is marked in the command audit. Provider or MCP failure closes plan-12
connections through the existing bracket and still renders the local invocation report.

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
This plan owns the workspace, the command policy, and the `OneOffPermission` boundary that such a key
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
- `docs/plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md` for `ToolRegistry`,
  the bounded model/tool loop, MCP lifecycle, and remote tool authorization. Completion
  includes its recorded upstream Baikai, Shikumi, and per-action authorization prerequisites.
- `docs/plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md`
  for the final flake/package/configuration surface this plan extends.

These are hard edges, not suggested landing order. Do not begin M1 while any remains
incomplete. Their own hard dependencies are transitive and remain authoritative.
MasterPlans 8 and 9 are not prerequisites: their router and architecture-review domains may
later consume this harness, but the harness must remain domain-neutral.

The final core interface should be equivalent to:

```haskell
data OneOffPermission = ReadOnly | WorkspaceWrite

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
  , permission :: !OneOffPermission
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
  , permission :: !OneOffPermission
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
  OneOffPermission ->
  IO (Either WorkspaceToolError ToolRegistry)

runOneOff ::
  OneOffRuntime ->
  OneOffRequest ->
  IO OneOffResult
```

Use the exact final plan-12 registry combination API; if none exists, add a
collision-rejecting `unionTools :: ToolRegistry -> ToolRegistry -> Either ToolRegistryError
ToolRegistry` to the package that owns `ToolRegistry`, not a Shikigami-specific map merge.
Reserved local names are `workspace__*`; MCP names remain `mcp__*`.

The implementation may add a released process dependency after using Mori and verifying
the current registry/tag, but it must use argument-vector execution, process groups, bounded
capture, and timeouts. The flake supplies Bubblewrap on supported Linux systems and verifies
the macOS Seatbelt executable before selecting it; unsupported systems expose no exec tool.
Never search or read `/nix/store`; dependency source comes from Mori. File APIs come from
`directory`/`filepath` or an already selected coherent library.

Configuration extends the plan-37 `Config` with strict bounded values and secret-free
command rules. `shikigami-workers` owns CLI source assembly. No new environment variable
read, configuration parser, Haskell package, HTTP server, database table, queue, or public
API route is introduced.

Every Haskell record follows
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/record-patterns.md`: direct,
unprefixed fields, `DuplicateRecordFields`, strict fields, explicit deriving strategies,
and generic-lens access/update where the final package conventions require it.

Every implementation commit includes:

```text
ExecPlan: docs/plans/48-add-a-portable-one-off-repository-agent-harness.md
Intention: intention_01kyv7saq6ew2a2k5vw230pw1f
```
