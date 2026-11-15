---
id: 128
slug: let-agents-declare-cli-tools-and-mcp-servers-with-authority-attached-to-the-declaration
title: "Let agents declare CLI tools and MCP servers with authority attached to the declaration"
kind: exec-plan
created_at: 2026-11-15T13:43:17Z
intention: "intention_01m7fq4tf3ejrt0tjxvsy8ejdt"
master_plan: "docs/masterplans/22-rebuild-shikigami-as-a-kernel-where-use-cases-are-declared-not-coded.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-15T13:43:17Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-15T14:01:05Z
      mode: "other"
      note: "Drafted plan body under MasterPlan 22"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-15T14:08:31Z
      mode: "update"
      note: "MasterPlan 22 reconciliation of cross-plan interfaces"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-15T14:50:34Z
      mode: "update"
      note: "Cascaded MasterPlan 22 review: RunDeclaredTool and tool.called on kernel ports, confirmed declaration as grant, M4 durable tool steps"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-15T20:03:27Z
      mode: "implement"
      note: "M1 accepted: declared CLI tools as cli.* overlays, shikigami-local tools, real repo-inventory run on keiro"
---

# Let agents declare CLI tools and MCP servers with authority attached to the declaration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Today a Shikigami agent can use only five tools compiled into the core (`workspace.read`,
`workspace.edit`, `workspace.exec`, `workspace.git`, `workspace.integrate`). An agent cannot
say "I need `mori registry show` and `mina docket status`", and no Haskell code speaks MCP
(Model Context Protocol, the JSON-RPC protocol through which a separate "server" process
offers tools to a model). After this plan, an agent declaration carries a `tools` field.
That field names CLI tools, with the executable, the argument patterns allowed and the
working directory, and it names tools offered by MCP servers. Under the `LocalOperator`
tier the operator grants a declaration once, and that confirmation lists its tools with
their resolved executables, so the confirmed declaration is the grant for CLI tools. The
operator's own tools file holds only what a declaration may never carry, namely MCP server
transports and credentials, plus optional explicit ceilings for operators who want them.

A declared tool reaches a run through three hosts, and one decision function,
`decideToolCall`, serves all three. A `Skill` agent's model calls it as a model-facing
tool. A `CodingAgent` (Claude Code or Codex as the worker) runs it as a shell command. A
flow body or a playbook step runs it as a durable step, where the call may mutate and may
run for hours because it reuses the restart-safe attempt machinery of EP-2. Every call,
admitted or refused, is decided by the tier's authority and appears in the kernel's action
record.

You can see it working on this Mac. A `Skill` agent pointed at a worktree of
`/Users/shinzui/Keikaku/bokuno/keiro` calls `mori registry show shinzui/keiro`, `mina docket
status` and the `git_status` tool of a local `mcp-server-git` MCP server, then reports what
it found. A `CodingAgent` running Claude Code on the same checkout runs the declared `mori`
command, but its attempt to run `gh pr list` is refused. The action record then shows both
calls, one marked admitted and one marked refused with the reason `undeclared executable
gh`. A durable step runs a declared build command on a real checkout for several minutes,
survives a worker kill, and is launched exactly once.


## Progress

- [x] M1 (2026-11-15): Declared CLI tools run for `Skill` agents under `LocalOperator`. With no tools
  file, a real Skill run on a keiro worktree asks the operator once, listing the declared
  `mori` and `mina` tools, then calls them; a call outside the declared argument patterns is
  refused, and the action record shows both. `shikigami-tools check` prints the resolution
  and whether each tool is granted.
  Evidence: `agents/repo-inventory.dhall` ran under `local-operator` with
  `--workspace mori://shinzui/keiro` and OpenAI `gpt-5.4-mini`. The one confirmation listed
  `mori (mori, Observation): registry show …; path …` and `mina (mina, Observation): docket
  status; exec-plan remaining …`. A second run (`b787f0f4-e84f-532e-8273-411a4d926fd8`, no
  terminal) asked nothing and its reply quoted the Mori registration ("Event sourcing
  framework and workflow engine", registered path `/Users/shinzui/Keikaku/bokuno/keiro`) and
  the unfinished plans from `mina docket status`. Asked also to run `mori registry list`, the
  agent's call was refused. `shikigami-local ledger --run b787f0f4-…` shows:

  ```text
  tool.called admitted cli.mori run ["registry","show","shinzui/keiro"] exit 0
  tool.called admitted cli.mina run ["docket","status"] exit 0
  tool.called refused cli.mori run ["registry","list"] arguments outside declared patterns for mori
  ```

  Adding a `mina` pattern made `shikigami-local tools` report `needs confirmation` (exit 3) and
  a run with no terminal refuse with "no stored grant for this declaration". A ceiling file
  allowing `mori` only `["path"]` made the check print `refused: mori pattern [registry show
  …] is outside the operator ceiling` and a run refuse with the same message. Under
  `trust.tier=contained` the run refused with "declared tools need trust.tier=local-operator".
  Tests: the `declared tools` group in `shikigami-core:test` (10 cases: patterns, ceilings,
  checked words, the example's codecs and journal bytes, the revision, and the runner with
  `/bin/echo`, `/bin/sleep` and `/usr/bin/yes`).
- [x] M2 (2026-11-15): MCP bindings (ADR-65) work for `Skill` agents. `shikigami-tools mcp discover git`
  lists a real `mcp-server-git`, a Skill run calls its approved `git_status` tool on the
  keiro worktree, unapproved tools are never offered, and a changed schema refuses
  acquisition.
  Evidence: `mcp-server-git` 2026.11.11 (installed with `uv tool install` into a scratch
  tool directory) is bound in the operator tools file with `--repository
  WorkspaceRootArgument` and approves `git_status` and `git_log`.
  `shikigami-local mcp git --workspace mori://shinzui/keiro` lists those two as `approved`
  and `git_commit`, `git_add` and the rest as `not approved`, each with a pasteable entry. The
  `repo-inventory` declaration, now also requesting `McpTools {server = "git", tools =
  ["git_status","git_log"]}`, asked again (its tools changed), listed `git (MCP): git_status,
  git_log`, and its reply quoted "On branch master … nothing to commit, working tree clean"
  from `overlay__mcp-git__git_status` (run `1a2fc199-f95d-53f1-9d50-d491eaf02cac`). Its ledger
  shows the `mcp.git` provider and `git_status` tool decisions and `tool.called admitted
  mcp.git git_status`. With one character of the approved `git_status` schema changed, the
  next run refused acquisition before any call and recorded `tool.called refused mcp.git
  approved tool git_status schema changed` (run `33871149-5207-5bd0-9594-df477198164d`).
  Tests: 3 more `declared tools` cases (discovery verification including an ignored extra
  tool, catalog checks, revision change with a schema).
- [ ] M3: The resolved tool set is rendered for coding agents. The representative check
  passes: a Claude Code `CodingAgent` on the keiro worktree runs declared `mori registry
  show` and the MCP `git_status`, and its `gh` call is refused and appears in the action record.
  A Codex run uses the rendered MCP configuration. The new ADR is written.
- [ ] M4: Declared tools run as durable steps. The flow capability `runDeclaredTool` runs a
  declared, mutating build command on a real checkout with a deadline of minutes to hours.
  Killing the worker mid-run and restarting reattaches without a second launch, and a lost
  launcher ends `Uncertain`. Needs EP-2 M2.


## Surprises & Discoveries

- Observation: Claude Code's own allow-list and a PreToolUse hook both enforce exactly what
  this plan needs in unattended mode. This was checked on 2026-11-15 with Claude Code
  2.1.325, using `claude -p --permission-mode acceptEdits --strict-mcp-config --tools Bash`.
  With `--allowedTools 'Bash(mori registry show:*)'`, `mori registry show shinzui/baikai`
  ran and `gh --version` was denied without running. In a second run without
  `--allowedTools`, a `--settings` JSON string installed a PreToolUse hook. Returning
  `permissionDecision: "allow"` let `mori` run, and returning `"deny"` blocked `gh`. The
  hook receives `tool_name`, `tool_input.command`, `tool_use_id`, `cwd` and `session_id`
  on standard input.
  Evidence:

  ```text
  DENIALS [{"tool_name": "Bash", "tool_use_id": "toolu_01AY1i…", "tool_input": {"command": "gh --version", …}}]
  hook stdin keys: cwd effort hook_event_name permission_mode prompt_id session_id tool_input tool_name tool_use_id transcript_path
  ```

- Observation: The portfolio still has no Haskell MCP client. `mori registry search mcp`
  finds only `@orval/mcp` (TypeScript). The Baikai MCP plans 30–32 are all unchecked, and
  `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-2` and
  `mori://shinzui/shikumi/okf/improvement-requests/concepts/IR-1` are still `proposed`.
- Observation: A durable run that requests any overlay needs a declared principal: without
  `identity` the composition refuses with `MissingCapabilityIdentity`.
  Evidence: the first `repo-inventory` run; the declaration now names
  `principal_repo_inventory`, as `agents/local-maintainer.dhall` does.
- Observation: The Dhall decoder treats a one-constructor Haskell sum as its record, so
  `ToolDecl` needs a hand-written union decoder until M2 adds `McpTools`.
  Evidence: `Expression doesn't match annotation … (a record type) + < … > (a union type)`.
- Observation: Codex 0.169.0 has no tool allow-list flag; Baikai's
  `docs/user/unattended-agent-runs.md` (in `mori://shinzui/baikai`) refuses a non-empty
  `allowed-tools` for Codex for the same reason. Codex lists a stable `hooks` feature,
  reads `~/.codex/hooks.json` in Claude-compatible format, requires hook trust (or
  `--dangerously-bypass-hook-trust`), and accepts `-c mcp_servers.<id>.…` overrides. No MCP
  server is configured for either harness on this machine (`codex mcp list`, and
  `mcpServers` in `~/.claude.json` is empty), so M2 installs one.


## Decision Log

- Decision (amended by the MasterPlan 22 review entries at the end of this log: the
  ceiling is now optional and the confirmed declaration is the grant): The declaration
  carries the full shape of each CLI tool, and the operator catalog is a ceiling the
  declaration must fit under. A declared tool resolves only if
  the catalog has an entry of the same name with the same executable, every declared
  argument pattern lies inside a ceiling pattern, and the declared operation class and
  limits do not exceed the ceiling's. This follows Baikai's operator-ceiling model
  (repository file declares, operator file bounds) and extends ADR-25's catalog instead of
  adding a parallel approvals mechanism.
  Rationale: "Authority attaches to the declaration": the ledger and the runner enforce the
  narrow declared patterns, while the operator keeps sole control of what may ever be
  granted. An executable name and argument words are not secrets, so ADR-25's objection
  to agent-authored endpoints does not apply to them.
  Date: 2026-11-15
- Decision: MCP server transport (command, arguments, environment) stays in the operator
  catalog as an ADR-65 binding. The agent declaration names only a server id and a subset
  of its approved tool names.
  Rationale: ADR-65 and ADR-25 keep endpoints and credentials out of declarations and
  journals. A subset request keeps the agent's menu minimal.
  Date: 2026-11-15
- Decision: Ship a minimal stdio-only MCP client in `shikigami-agent`
  (`Shikigami.Agent.Tools.Mcp.Stdio`). It covers `initialize`, `tools/list` with a page
  limit, and `tools/call`, and has no HTTP, SSE or OAuth support. It sits behind the
  narrow `McpSession` record so that it can be swapped for Baikai's client once IR-2
  ships. This deliberately departs from plan 12's rule "do not write a private downstream
  JSON-RPC client" (`docs/plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md`).
  Plan 12's remaining MCP scope is superseded by this plan, and the MasterPlan owner
  should mark it so.
  Rationale: ADR-65's schema check needs Shikigami to run discovery itself, and the
  MasterPlan requires real use now. The stdio transport is small, and the owning upstream
  work has not started.
  Date: 2026-11-15
- Decision: A `CodingAgent` runs its own commands, so authority is enforced in two
  independent layers. The rendered `--allowedTools` mirrors the declared patterns, so
  Claude Code itself denies anything else. A PreToolUse hook (`shikigami-tools gate`)
  applies the same pure decision function used by the Skill runner and writes one decision
  per call. A failing hook therefore still leaves Claude Code's own denial in force.
  Shell access inside a coding agent is exactly the declared CLI tools. A compound
  command, redirection or substitution is refused with a reason that tells the model to
  issue one declared command per call.
  Rationale: The allow-list alone gives no ledger entries, and a hook alone fails open if
  it crashes.
  Date: 2026-11-15
- Decision: Codex receives rendered MCP servers restricted with `enabled_tools`. A non-empty
  CLI tool set is rendered for Codex only if the M3 check shows that a per-run PreToolUse
  hook can be installed without editing the operator's `~/.codex`. Otherwise
  `renderCodexTools` returns `CodexCannotConfineCommands`.
  Rationale: Codex has no allow-list, and it must never run with more authority than was
  declared.
  Date: 2026-11-15
- Decision: Durable `Skill` runs admit only `Observation` tools, which leaves ADR-25
  unchanged. One-off Skill runs and `CodingAgent` runs admit any class the ceiling allows.
  Rationale: Durable attempts can repeat, and mutation needs an idempotency contract that is
  out of scope. EP-2's coding-agent outcome already models "uncertain after restart".
  Date: 2026-11-15
- Decision: For CLI tools the operator's confirmed declaration is the grant. EP-1's
  one-time confirmation lists each declared tool with its resolved executable and patterns,
  and its digest covers the declaration, so changing a tool asks again. The operator tools
  file holds MCP bindings and optional explicit ceilings. A ceiling, when present for a
  tool name, still bounds the declaration exactly as before.
  Rationale: The user chose "confirm once per declaration" on 2026-11-15. The first draft
  made the operator write every tool twice, once in the declaration and once as a ceiling,
  before a routine agent could run. MCP transports and credentials stay operator-owned
  because ADR-25 and ADR-65 keep endpoints out of declarations.
  Date: 2026-11-15
- Decision: A declared tool call is authorized as `RunDeclaredTool` on the kernel's own
  `Action` type and recorded under the record kind `tool.called`, which this plan owns.
  There is no `ToolCalled` constructor on a shared sum and no predicate over Kikan-En's
  `AgentAction`.
  Rationale: MasterPlan 22's review moved authority and the record to EP-8's kernel ports
  (`docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md`).
  `AgentAction` is a closed sum in `mori://shinzui/kikan-en/packages/kikan-en-contract`
  with no constructor for a CLI tool.
  Date: 2026-11-15
- Decision: Add a third host and a fourth milestone. A flow body or playbook step runs a
  declared tool through the capability `runDeclaredTool`, as a keyed child workflow built
  on EP-2 M2's command-parameterized attempt machinery. In this host only, a call may have
  any operation class the grant covers and a deadline of up to 720 minutes, and a call
  whose fate is unknown ends `Uncertain` and is never repeated. The model-facing host keeps
  its 600-second limit, and durable `Skill` runs still admit only observations.
  Rationale: MasterPlan 22's review found no owner for playbook `Tool` steps. EP-7's
  campaign runs `seihou agent run --batch`, `mori register` and repository builds, which
  mutate and run far longer than ten minutes. A model-facing tool call cannot be made
  restart-safe, but a step can, with the machinery EP-2 already builds.
  Date: 2026-11-15


- Decision: Each declared CLI tool is offered as an ordinary capability overlay, `cli.<name>`,
  and `requestedOverlays decl` (declared overlays plus `cli.*` ids) replaces
  `decl.capabilityOverlays` wherever overlays are requested: the journaled
  `resolve-capability-overlays` step, the behavior environment check, the grant and the
  one-off path. There is no new `resolve-declared-tools` step and no `ResolvedToolSet`.
  Rationale: The overlay path already journals exact descriptors, decides connect and each
  invocation through the run's authority, rebuilds providers in durable execution children,
  and refuses non-observations in durable runs. Reusing it changes no workflow shape, so no
  pre-release recheck or patch is needed for M1. A refused resolution surfaces before the run
  starts (in the composition), which is earlier than the planned step.
  Date: 2026-11-15
- Decision: Each call is authorized as the existing `UseCapability (InvokeTool cli.<name>
  run)` decision, and `tool.called` records the pattern decision and exit; no
  `RunDeclaredTool` action is added in M1.
  Rationale: The overlay guard already asks the authority per call and records it. A second
  action per call would decide the same thing twice. EP-3 M3's coding-agent gate and M4's
  durable step, which have no overlay guard, are where `RunDeclaredTool` is needed.
  Date: 2026-11-15
- Decision: The check is `shikigami-local tools <agent> [--workspace]`, not a new
  `shikigami-tools` executable; the confirmation lists each tool by its declared executable
  and patterns, and the located path appears in the check, the revision and the tool
  description.
  Rationale: `shikigami-local` is already the local operator's inspection command; a new
  executable would need a new configuration role. The grant request is built from the
  declaration alone.
  Date: 2026-11-15
- Decision: Declared tools run with the operator's whole environment under `local-operator`.
  Rationale: The first real run failed because `mori` needs `MORI_PG_CONNECTION_STRING`; the
  launcher's cleared environment suits approved rules, but a declared tool is the operator's
  own command, as the plan's runner section says.
  Date: 2026-11-15
- Decision: The tools file is `$XDG_CONFIG_HOME/shikigami/tools.dhall` with only CLI
  ceilings in M1 (`schema/Tools.dhall`); refusing a catalog file inside the workspace is not
  implemented.
  Rationale: The XDG location is enough for one operator; the file is the operator's, not the
  repository's. M2 adds MCP bindings to the same file.
  Date: 2026-11-15

- Decision: The MCP client and provider live in `shikigami-core:local-host`
  (`Shikigami.Capability.Mcp.Local`), the pure binding in `Shikigami.Capability.Mcp`, and the
  discovery command is `shikigami-local mcp <server>`.
  Rationale: As for CLI tools (ADR 0125): the worker needs the same provider later, and the
  local operator's inspection command already exists.
  Date: 2026-11-15
- Decision: The connection and each call are decided by the existing overlay guard
  (`UseCapability` on the provider and on each tool); no separate discovery decision is made.
  An acquisition refused by the schema check is recorded as `tool.called refused`.
  Rationale: Discovery happens inside acquisition, after the connection decision, and offers
  nothing outside the approved set.
  Date: 2026-11-15
- Decision: Schemas are compared as decoded JSON values (key order ignored), and the
  revision digests the canonicalized binding; the stdio client reads one line per message and
  bounds each request by 60 seconds and discovery by 10 pages.
  Rationale: Enough for `mcp-server-git`; a per-message byte bound and configurable limits
  wait for a server that needs them.
  Date: 2026-11-15

## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a Haskell (GHC, Cabal) multi-package repository. An agent is a Dhall file under
`agents/` that type-checks against `schema/Agent.dhall`. It is decoded into
`Shikigami.Agent.Decl.AgentDecl` (`shikigami-core/src/Shikigami/Agent/Decl.hs`), a record of
unprefixed strict fields such as `behavior`, `capabilityOverlays` and `identity`. The
`behavior` field is a sum type. Its `Skill {path}` arm runs a model with a system prompt
from a skill directory and a tool loop bounded to eight model turns
(`shikigami-core/src/Shikigami/Behavior/Skill.hs`).

Model-facing tools are Shikumi values. `Shikumi.Tool.SomeTool` comes from
`mori://shinzui/shikumi/packages/shikumi-tools`, and its `DynTool name description schema
run` constructor takes a runtime JSON schema. The overlay machinery wraps those tools
today, and a "capability overlay" is an operator-supplied bundle of extra tools.
`shikigami-core/src/Shikigami/Capability/Overlay.hs` defines `CapabilityId` (checked,
`[a-z][a-z0-9.-]*`), `CapabilityRevision`, `CapabilityOperationClass` (`Observation |
IdempotentMutation | IrreversibleEmission`, whose derived `Ord` follows that order), and
`CapabilityDescriptor {capability, revision, tools}`.
`Capability/Catalog.hs` resolves requested ids against an operator `CapabilityCatalog`
purely and fails closed. `Capability/Provider.hs` holds `CapabilityProvider {descriptor,
acquire}`, a registry keyed by exact `(CapabilityId, CapabilityRevision)`, and
`withCapabilityOverlays`. That function acquires leases, authorizes `ConnectCapability` and
then each `InvokeCapabilityTool` through an `ActionAuthorizer` (`guardCapabilityTool`),
composes names as `overlay__<id-with-dashes>__<logical>` (`Capability/Tools.hs`), and
releases everything in LIFO order. `shikigami-core/src/Shikigami/Execution/Tools.hs` reuses
the same providers for durable Skill execution children.
`shikigami-agent/src/Shikigami/Agent/Capability/OneOff.hs` is the composition root for the
light `shikigami-agent` package (ADR-3), and today it installs only `workspace.read`.

Durable runs are keiro workflows (keiro is the durable-workflow library at
`mori://shinzui/keiro`). `shikigami-core/src/Shikigami/Agent/Workflow.hs`
(`runResolvedAgent`) journals a `resolve-capability-overlays` step before running the
behavior. Steps are declared in `domain/shikigami/agent-run.keiro`, and the generated
layer is refreshed with `just keiro-scaffold`. `just keiro-gate <merge-base>` checks a
workflow change against `docs/workflow-versioning.md`. Action authorization uses
`Kikan.En.Action.AgentAction` from `mori://shinzui/kikan-en/packages/kikan-en-contract`,
whose arms include `ConnectCapability`, `DiscoverCapabilityTools` and
`InvokeCapabilityTool (CapabilityToolTarget id revision logicalName)`.

Three sibling plans supply what this plan consumes. None had landed when this plan was
written, so their names below are provisional. EP-8,
`docs/plans/133-give-the-kernel-its-own-action-record-output-approval-and-trigger-contracts-with-local-adapters.md`,
gives the kernel its own contracts in its first milestone: `Shikigami.Authority`, with a
closed `Action` sum and the port `Authority {decide :: Principal -> Action -> IO (Either
AuthorityFailure Decision)}`, and `Shikigami.Record.ActionRecord`, an append-only record of
`RecordEntry {kind, payload}` values in which each producer owns its dotted kind. After it,
`withCapabilityOverlays` decides connect, discover and invoke as `UseCapability` actions
instead of the Kikan-En arms named above. EP-1,
`docs/plans/126-run-declared-agents-on-the-operator-s-own-machine-through-a-local-operator-trust-tier.md`,
defines `data TrustTier = LocalOperator | Contained | MultiTenant` and `TierComposition`,
whose `resolve :: RunSubject -> IO (Either TierRefusal TierRuntime)` yields the ports for
one run and one repository: the authority, the action record, the capability runtime, the
workspace host (for `LocalOperator`, a Git worktree of a real checkout) and the process
launcher. EP-1 also defines the *grant*: the operator confirms what a declaration asks for
once, and the answer is stored under the digest of the declaration and the repository; a
run with no terminal uses only stored grants. EP-2,
`docs/plans/127-run-claude-code-and-codex-as-durable-harness-workers-inside-agent-runs.md`,
adds the `CodingAgent` behavior arm, a durable coding-agent step whose input has a slot for
this plan's resolved tool set, and, in its second milestone, the command-parameterized
attempt machinery `Shikigami.Process.Attempt` that this plan's M4 reuses. Under the
MasterPlan's integration rule, this plan adds a field to EP-1's `TierRuntime`, extends
EP-1's grant and confirmation with tools, and fills EP-2's slot. It never branches on the
tier in use-case code.

The relevant ADRs are summarized below.
[ADR-25](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) says a
declaration requests and an operator catalog grants. Resolved descriptors are journaled,
and providers are acquired by exact revision. Durable runs admit only observations, and
overlay tools never replace base tools.
[ADR-65](../adr/0065-mcp-provider-revisions-bind-the-approved-tool-contract.md) defines an
operator-owned MCP binding listing approved tools: remote name, logical name, operator
description, input and output schema, and operation class. Its revision is `mcp-v1-` plus
`versionedDigest "shikigami.mcp-binding/1"` over the binding. Missing approved tools or
changed schemas refuse acquisition, unapproved remote tools are never exposed, and
connect, discovery and invocation are each authorized afresh.
[ADR-36](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md) requires
fresh exact authorization per external action; EP-8 restates it over the kernel's `Action`
type and EP-1 amends it to select the authority by tier.
[ADR-27](../adr/0027-the-first-release-establishes-one-clean-durable-baseline.md) and
[docs/workflow-versioning.md](../workflow-versioning.md) let unreleased workflow shapes
change directly until the first release or deployment.
[ADR-11](../adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md) omits
defaulted empty fields from the journal JSON.
[ADR-1](../adr/0001-declare-only-what-the-runtime-executes.md) says not to declare what the
runtime will not execute, so non-supporting behaviors must refuse a non-empty `tools`.
[ADR-80](../adr/0080-opaque-checked-values-do-not-expose-generic-construction.md),
[ADR-81](../adr/0081-validated-results-use-private-seals-and-public-read-views.md) and
[ADR-87](../adr/0087-agent-values-retain-checked-meaning-and-separate-compatibility-scopes.md)
govern the type shapes: private checked newtypes without `Generic`, sealed validated values
with public read views, and agent values that retain checked meaning.
[ADR-112](../adr/0112-observed-content-is-evidence-and-never-instruction.md) says tool
output is evidence, never instruction.
[ADR-75](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md) keeps
domain roots closed, which is why all new core modules live under the existing
`Capability` root.


## Plan of Work

The work has four milestones. Each one ends with a real run on this Mac. The pure core
(declaration, catalog, resolution, call decision and renderers) lives in `shikigami-core`
under `Shikigami.Capability.Declared` and `Shikigami.Capability.Mcp`. Everything that spawns
processes lives in the leaf package `shikigami-agent` under `Shikigami.Agent.Tools`, plus a
new executable `shikigami-tools`.

### M1 — Declared CLI tools for Skill agents

Start by rechecking the pre-release facts. Confirm that `git tag --list` is empty, that
`docs/workflow-versioning.md` still records the 2026-10-30 "unused" confirmation, and that
the MasterPlan's Decision Log does not yet record a first deployment by EP-7. Record the
result in this plan's Decision Log. If a deployment has happened, gate the new workflow
step below behind the patch id `shikigami-declared-tools-v1` instead of adding it
directly.

Add `shikigami-core/src/Shikigami/Capability/Declared.hs` with the declaration vocabulary.
Every scalar is a private newtype with a checked factory and a `FromDhall`/`FromJSON`
instance that calls the factory, following the `CapabilityId` pattern in `Overlay.hs` and
ADR-80. Choices are closed sums rather than booleans.

```haskell
newtype ToolName = ToolName Text            -- [a-z][a-z0-9-]{0,31}; mkToolName, toolNameText
newtype ExecutableName = ExecutableName Text -- nonempty, no '/', no whitespace
newtype ArgumentWord = ArgumentWord Text     -- nonempty, no NUL, no newline

data ExecutableRef = OnPath !ExecutableName | AtPath !AbsoluteFilePath
data Trailing = NoTrailing | AnyTrailing | AtMostTrailing !TrailingCount
data ArgumentPattern = ArgumentPattern {prefix :: ![ArgumentWord], trailing :: !Trailing}
data WorkingDirectoryPolicy = WorkspaceRoot | WorkspaceSubdirectory !RelativePath
data CallLimits = CallLimits {timeout :: !CallTimeout, outputLimit :: !OutputLimit}

data CliToolDecl = CliToolDecl
  { name :: !ToolName,
    executable :: !ExecutableRef,
    allow :: !(NonEmpty ArgumentPattern),
    workingDirectory :: !WorkingDirectoryPolicy,
    operationClass :: !CapabilityOperationClass,
    limits :: !(Maybe CallLimits)
  }

data McpToolRequest = McpToolRequest {server :: !McpServerId, tools :: !(NonEmpty McpToolName)}
data ToolDecl = CliTool !CliToolDecl | McpTools !McpToolRequest
```

`RelativePath` is the existing checked type in `shikigami-core/src/Shikigami/Repository.hs`.
`CallTimeout` (1–600 seconds, default 60) and `OutputLimit` (1 byte to 4 MiB per stream,
default 256 KiB) are checked newtypes. A pattern matches an argument vector when the
vector starts with `prefix` and the remaining words satisfy `trailing`. Pattern `p` lies
inside ceiling pattern `c` when `c.prefix` is a prefix of `p.prefix`. The extra words of
`p` must then fit `c.trailing`, and so must any trailing words `p` admits.
`AtMostTrailing 2` allows arbitrary words, but at most two of them.

Add `tools :: ![ToolDecl]` to `AgentDecl`, omitted from JSON when empty like
`decisionModels`. Add the matching Dhall union to `schema/Agent.dhall` with the default
`tools = [] : List Tool`. Also add small helpers (`CliTool::{…}` with defaults
`workingDirectory = WorkspaceRoot` and `limits = None`, plus a `pattern` function). The
existing agents keep loading unchanged.

Add `shikigami-core/src/Shikigami/Capability/Declared/Catalog.hs`, which defines the
operator tools file. The file holds the MCP bindings of milestone M2 and, optionally,
explicit ceilings for CLI tools; it is not required for a CLI tool to run. `loadToolCatalog`
decodes a Dhall file against a new `schema/Tools.dhall`, and a missing file is the empty
catalog. `locateExecutable` resolves an `OnPath` executable against `PATH`, taking the
first match without resolving symlinks, so `~/.nix-profile/bin/mina` stays stable across
profile upgrades. `loadToolCatalog` refuses a catalog file located inside the workspace
repository. The result is sealed per ADR-81.

```haskell
data LocatedExecutable = LocatedExecutable {requested :: !ExecutableRef, path :: !AbsoluteFilePath}
data CliToolCeiling = CliToolCeiling
  { name :: !ToolName,
    executable :: !LocatedExecutable,
    allow :: !(NonEmpty ArgumentPattern),
    maximumOperationClass :: !CapabilityOperationClass,
    maximumLimits :: !CallLimits
  }
data ToolCatalog -- sealed; mkToolCatalog :: [CliToolCeiling] -> [McpBinding] -> Either ToolCatalogError ToolCatalog
emptyToolCatalog :: ToolCatalog
loadToolCatalog :: FilePath -> IO (Either ToolCatalogError ToolCatalog)
locateExecutable :: ExecutableRef -> IO (Either ToolCatalogError LocatedExecutable)

-- Whether the operator granted this declaration's tools. Built by the tier composition:
-- LocalOperator derives it from EP-1's grant; Contained and MultiTenant have none.
data ToolGrant = GrantedWithDeclaration !GrantDigest | NoToolGrant
```

**The grant.** Extend EP-1's `GrantRequest` and `renderGrantRequest`
(`Shikigami.Trust.LocalOperator.Grant`) with the declaration's tools, so the one
confirmation the operator sees lists every declared CLI tool with its located executable,
its argument patterns and its operation class, and every requested MCP server with its
tool names. EP-1's grant digest already covers the whole declaration, so adding or
widening a tool asks again. An approvals-file entry (EP-1's explicit form) grants tools
through a new `tools : List Text` field naming the declared tools it covers. A confirmed or
explicit grant yields `GrantedWithDeclaration`; without one the result is `NoToolGrant`.

In `LocalOperator` the catalog file is `$XDG_CONFIG_HOME/shikigami/tools.dhall`, which
defaults to `~/.config/shikigami/tools.dhall`. If EP-1's operator configuration names
another location, follow EP-1 and record that here. Add
`tools :: ToolAuthority` to EP-1's `Shikigami.Trust.Runtime.TierRuntime` record, where
`data ToolAuthority = ToolAuthority {catalog :: !ToolCatalog, grant :: !ToolGrant}`. It is
resolved per run with the rest of the runtime. Tool decisions append `tool.called` entries
through the runtime's existing `record :: ActionRecord` field. `LocalOperator` loads the
file and derives the grant. `Contained` and `MultiTenant` use `emptyToolCatalog` and
`NoToolGrant`, so any declared tool refuses as ungranted there. That preserves what those
tiers do today.

Add `shikigami-core/src/Shikigami/Capability/Declared/Resolve.hs`, which is pure and fails
closed.

```haskell
data ToolHost = SkillHost | CodingAgentHost | StepHost   -- StepHost is added in M4
data ToolResolutionSubject = ToolResolutionSubject
  {principal :: !(DeclarationCoordinate "principal"), host :: !ToolHost, mode :: !ExecutionMode}

data ResolvedToolSet -- sealed; canonical order by tool name; checked FromJSON recomputes revisions
data ResolvedToolSetView = ResolvedToolSetView {cli :: ![ResolvedCliTool], mcp :: ![ResolvedMcpTools]}
data ResolvedCliTool = ResolvedCliTool
  { name :: !ToolName, capability :: !CapabilityId, revision :: !CapabilityRevision,
    executable :: !LocatedExecutable, allow :: !(NonEmpty ArgumentPattern),
    workingDirectory :: !WorkingDirectoryPolicy, operationClass :: !CapabilityOperationClass,
    limits :: !CallLimits }

resolveDeclaredTools ::
  ToolAuthority -> Map ExecutableRef LocatedExecutable -> ToolResolutionSubject -> [ToolDecl] ->
  Either ToolResolutionError ResolvedToolSet
resolvedToolSetView :: ResolvedToolSet -> ResolvedToolSetView
resolvedToolDescriptors :: ResolvedToolSet -> [CapabilityDescriptor]
emptyResolvedToolSet :: ResolvedToolSet

data ToolResolutionError
  = DuplicateToolDeclaration !ToolName
  | UngrantedCliTool !ToolName            -- no grant covers this declaration
  | ExecutableNotFound !ToolName
  | ExecutableDiffersFromCatalog !ToolName
  | PatternOutsideCeiling !ToolName !ArgumentPattern
  | OperationClassAboveCeiling !ToolName !CapabilityOperationClass !CapabilityOperationClass
  | LimitsAboveCeiling !ToolName
  | UncataloguedMcpServer !McpServerId
  | McpToolNotApproved !McpServerId !McpToolName
  | DurableToolOperationNotAllowed !ToolName !CapabilityOperationClass
  | ToolsUnsupportedForBehavior !Text
  | MissingToolIdentity
```

A declared CLI tool resolves under these rules, in order. Its executable must be located;
the caller locates every declared executable once, in IO, and passes the map in, which
keeps resolution pure. The tool must be granted: `NoToolGrant` yields `UngrantedCliTool`.
If the catalog holds a ceiling of the same name, the declaration must fit under it exactly
as the ceiling rules above state (same executable, every pattern inside a ceiling pattern,
operation class and limits not above the ceiling's); with no ceiling of that name, the
grant alone suffices. An MCP request always needs its server's binding in the catalog, and
it needs the grant as well.

Each resolved CLI tool becomes one capability descriptor with id `cli.<name>`, revision
`cli-v1-<versionedDigest "shikigami.cli-tool/1" view>`, and a single logical tool `run`
carrying the declared operation class. The model therefore sees
`overlay__cli-mori__run`, and every existing guard, name-collision check and execution
path applies unchanged. Check that the `cli-v1-…` revision passes kikan-en's
`mkCapabilityRevision`. The behaviors that support `tools` are `Skill` and `CodingAgent`
from the milestones that implement them, and `Flow` and `Playbook` from M4, where a body
or a playbook step uses them through the step host. `ToolsUnsupportedForBehavior` is
returned for `ShikumiProgram`, `Deterministic` and conversations, and for `Flow` and
`Playbook` until M4 lands. ADR-1 requires that refusal to be visible, and the tools must
never be silently dropped.

Add `shikigami-core/src/Shikigami/Capability/Declared/Call.hs` with the one decision
function that all three hosts use: the Skill runner (M1), the coding-agent gate (M3) and
the durable step (M4).

```haskell
data ToolCall
  = CliInvocation {tool :: !ToolName, arguments :: ![Text]}
  | ShellCommandLine {command :: !Text, workingDirectory :: !FilePath}
  | McpInvocation {server :: !Text, tool :: !Text}
data ToolDecision = Admitted !AdmittedCall | Refused !ToolRefusal
data ToolRefusal
  = UndeclaredExecutable !Text
  | ArgumentsOutsideDeclaredPatterns !ToolName
  | UnsupportedShellSyntax !ShellSyntax     -- CompoundCommand | Redirection | Substitution | Expansion | UnterminatedQuote
  | WorkingDirectoryOutsidePolicy !ToolName
  | UndeclaredMcpServer !Text
  | UnapprovedMcpTool !McpServerId !Text
decideToolCall :: ResolvedToolSet -> WorkspaceRootPath -> ToolCall -> ToolDecision
parseSimpleCommand :: Text -> Either ShellSyntax (Text, [Text])
renderToolRefusal :: ToolRefusal -> Text
```

`parseSimpleCommand` accepts only plain words, single-quoted words and double-quoted words
without `$`, backticks or backslashes. It refuses `;`, `&`, `|`, `<`, `>`, `(`, `)`, `$`,
backticks and newlines. The first word must equal a declared `OnPath` name or a declared
absolute path.

Add the IO runner `shikigami-agent/src/Shikigami/Agent/Tools/Cli.hs`. `cliToolProvider ::
Authority -> ActionRecord -> WorkspaceRootPath -> ResolvedCliTool -> CapabilityProvider`
returns a provider whose lease holds one `DynTool`. Its input schema is `{"args": array of string}`, and its
description lists the allowed patterns in plain words. On each call it runs
`decideToolCall` and, for an admitted call, asks the authority to decide
`RunDeclaredTool` with a `DeclaredToolTarget` naming the tool, the host and the repository.
If both admit the call, it starts the located executable with
`System.Process` as an argument vector, with no shell, standard input closed, the
operator's environment inherited (`LocalOperator`) and the working directory taken from the
policy. It runs the child in its own process group, drains both streams up to
`outputLimit`, and kills the group at `timeout`. It returns `{exitCode, stdout, stderr,
truncated}` as an observation for the model; per ADR-112 that output is evidence, never
instruction. A refusal returns an error observation naming the reason. Either way it
appends one `tool.called` record entry before returning.

```haskell
-- Shikigami.Capability.Declared.Record: this plan owns the record kind "tool.called" and
-- its typed payload. Nothing is added to a shared sum. Calls append through the resolved
-- TierRuntime.record :: ActionRecord (EP-8's Shikigami.Record).
data ToolCalled = ToolCalled
  { host :: !ToolHost, callKey :: !Text, call :: !ToolCallSummary,
    decision :: !ToolDecisionSummary, outcome :: !(Maybe ToolCallOutcome) }
toolCalled :: ToolCalled -> RecordEntry
```

`ToolCallSummary` holds the tool name and the arguments, truncated to 512 bytes. It never
holds output.

Wire the runner into both run paths. In `OneOff.hs`, or in EP-1's `LocalOperator`
composition if it replaced that file, resolve the declared tools beside the overlays. Then
extend the provider registry for that run with `cliToolProvider` for each resolved tool,
and pass the union of overlay and tool descriptors to `withCapabilityOverlays`. Relax the
behavior-environment guard so that the active set equals the declared overlays plus the
`cli.*`/`mcp.*` ids derived from the resolved tools. In
`shikigami-core/src/Shikigami/Agent/Workflow.hs`, add the step `resolve-declared-tools`
immediately after `resolve-capability-overlays`. Its journaled value is `Either
ToolResolutionError ResolvedToolSet` (named `DeclaredToolResolution` in
`domain/shikigami/agent-run.keiro`). Pass the result to the behavior attempt and to
`Execution/Tools.hs`, whose pending-tool dispatch must rebuild declared-tool providers
from the journaled set. Then run `just keiro-scaffold`, update
`shikigami-core/src/keiro-dsl-conformance.workspace.shikigami/src/KeiroConformance/Expectations.hs`,
and run `just keiro-gate`.

Extend EP-1's `decideLocalAction` for declared tools. It approves `RunDeclaredTool` when
the run's grant covers the named tool, and it approves `UseCapability` for a `cli.*` or
`mcp.*` capability id under the same condition; the MCP case also requires the server's
binding in the catalog. EP-8's `Action` sum has the `RunDeclaredTool !DeclaredToolTarget`
constructor; if EP-8 M1 left its payload abstract, define `DeclaredToolTarget` (tool name,
host, repository) there in the same change, as MasterPlan 22 requires of a plan that adds a
kernel effect. No predicate over Kikan-En's `AgentAction` is written.

Add the executable `shikigami-tools` to `shikigami-agent/shikigami-agent.cabal`, with the
subcommand `check <agent.dhall> [--catalog PATH] [--workspace DIR]`. It never prompts. It
prints each declared tool as `granted` (with its located executable, its revision, its
final model-facing name and whether an explicit ceiling bounds it), as `needs confirmation`
(it would resolve, but no stored grant or approvals entry covers this declaration yet), or
as `refused` (with the rendered `ToolResolutionError`). It exits 0 only if everything is
granted, and 3 if the only obstacle is a missing confirmation.

Write `agents/repo-inventory.dhall` and `agents/skills/repo-inventory/SKILL.md`. The skill
says: given a repository name, report its Mori registration and its unfinished plans
using only the declared tools. Declare `mori` with the patterns `["registry","show"]` and
`["path"]` (`AnyTrailing`), and `mina` with `["docket","status"]` (`NoTrailing`) and
`["exec-plan","remaining"]` (`AnyTrailing`). All of them are `Observation`. No operator
tools file is written for M1: the first interactive run asks once and stores the grant.
For the ceiling check in V1, write `~/.config/shikigami/tools.dhall` with one explicit
ceiling for `mori` that allows only `["path"]`. Add `docs/user/declared-tools.md`
explaining the declaration, the confirmation and the optional tools file.

Acceptance for M1 is the real run in Validation (step V1), plus the pure Hspec specs listed
there.

### M2 — MCP bindings for Skill agents (ADR-65)

Add `shikigami-core/src/Shikigami/Capability/Mcp/Binding.hs`.

```haskell
newtype McpServerId = McpServerId Text   -- [a-z][a-z0-9-]{0,31}
newtype McpToolName = McpToolName Text   -- [A-Za-z0-9_.-]{1,64}, the server's native name
data McpArgument = LiteralArgument !Text | WorkspaceRootArgument
data EnvironmentSource = InheritFromOperator | LiteralValue !Text
data McpTransport = McpStdio
  {command :: !AbsoluteFilePath, arguments :: ![McpArgument], environment :: ![(EnvironmentName, EnvironmentSource)]}
data ApprovedMcpTool = ApprovedMcpTool
  { remoteName :: !McpToolName, logicalName :: !(ExecutionCoordinate "tool-name"),
    description :: !Text, inputSchema :: !CanonicalJson, outputSchema :: !(Maybe CanonicalJson),
    operationClass :: !CapabilityOperationClass }
data McpLimits = McpLimits {callTimeout :: !CallTimeout, responseLimit :: !OutputLimit, discoveryPages :: !PageLimit}
data McpBinding -- sealed: mkMcpBinding validates unique remote/logical names and computes the revision
data McpBindingView = McpBindingView
  {server :: !McpServerId, transport :: !McpTransport, tools :: ![ApprovedMcpTool], limits :: !McpLimits, revision :: !CapabilityRevision}
mcpBindingView :: McpBinding -> McpBindingView
verifyDiscoveredTools :: McpBinding -> NonEmpty McpToolName -> [DiscoveredMcpTool] -> Either McpBindingMismatch ()
data McpBindingMismatch = ApprovedToolMissing !McpToolName | ApprovedSchemaChanged !McpToolName | DuplicateRemoteTool !McpToolName
```

The revision is `mcp-v1-` plus `versionedDigest "shikigami.mcp-binding/1"` over the view
without its revision, with tools sorted by logical name. That is exactly ADR-65's
definition. `WorkspaceRootArgument` is a symbol in the binding, and the run's workspace
path is substituted only at acquisition, so the revision stays independent of any single
run. `InheritFromOperator` passes a variable through by name, and its value is never
stored (ADR-26). Schemas are written in the Dhall file as JSON text and canonicalized when
loaded. The comparison is canonical-encoding equality, never semantic equivalence.

Add `shikigami-agent/src/Shikigami/Agent/Tools/Mcp/Stdio.hs`, the interim client. MCP's
stdio transport exchanges newline-delimited JSON-RPC 2.0 messages over the child's
standard input and output. The client works in these steps:

1. It spawns the command and sends `initialize` with `protocolVersion "2025-06-18"`. It
   accepts any server reply version in `["2025-06-18", "2025-03-26", "2024-11-05"]`.
2. It sends `notifications/initialized`.
3. It pages through `tools/list`, following `nextCursor` up to `discoveryPages` pages.
4. It calls `tools/call {name, arguments}`, rendering `text` content blocks and noting the
   type of any other block. The result's `isError` field becomes a tool error observation.

Reads are bounded by `responseLimit`, and every request is bounded by `callTimeout`. On a
timeout or on release, the client closes standard input, waits two seconds and kills the
process group.

```haskell
data McpSession = McpSession
  {discovered :: ![DiscoveredMcpTool], call :: McpToolName -> Value -> IO (Either McpCallError McpCallResult), close :: IO ()}
openMcpSession :: McpLimits -> WorkspaceRootPath -> McpBinding -> IO (Either McpSessionError McpSession)
```

Add `shikigami-agent/src/Shikigami/Agent/Tools/Mcp/Provider.hs`. `mcpToolProvider ::
ActionRecord -> Authority -> WorkspaceRootPath -> ResolvedMcpTools -> CapabilityProvider`
acquires a provider in four steps:

1. It asks the authority to decide the discovery as a `UseCapability` action (the common
   wrapper has already decided the connection).
2. It opens the session.
3. It runs `verifyDiscoveredTools` against the declared subset.
4. It returns a lease. The lease holds a `DynTool` per requested approved tool, using the
   approved description and schema rather than the remote ones, and its release action is
   `close`.

Capability id is `mcp.<server>`; the model sees `overlay__mcp-git__git_status`. Each call
appends a `tool.called` record entry, and so does each refused acquisition. Extend `shikigami-tools`
with `mcp discover <server> [--catalog PATH] [--workspace DIR]`. It connects, lists every
remote tool with its status (`approved`, `approved-schema-changed`, `not approved`), and
prints a ready-to-paste `ApprovedTool` Dhall entry with the canonical schema text for each
unapproved tool. Operators use it to author bindings.

The real server for acceptance is the reference `mcp-server-git` (Python). Install it once
as a pinned tool so that runs need no network. Add the binding to `tools.dhall` with
`command` set to its absolute path, `arguments = [Literal "--repository",
WorkspaceRoot]`, and approved observation tools `git_status` and `git_log`. Leave its
mutating tools (for example `git_commit` and `git_add`) unapproved. Declare `McpTools
{server = "git", tools = ["git_status", "git_log"]}` in `agents/repo-inventory.dhall`.

### M3 — Render the resolved set into coding-agent configuration

This milestone needs EP-2's `CodingAgent` arm and durable step. Before writing code, check
two things. First, confirm that EP-2's Claude Code invocation does not pass `--bare`;
`claude --help` says `--bare` skips settings hooks. If it does pass `--bare`, check
whether hooks from `--settings` still run and record the answer. Second, confirm that
EP-2's built-in tool list (`--tools`) does not include `Bash` unless this plan adds it.

Add `shikigami-core/src/Shikigami/Capability/Declared/Render.hs`, whose functions are pure.

```haskell
data GateInvocation = GateInvocation {executable :: !AbsoluteFilePath, grantFile :: !AbsoluteFilePath}
data ClaudeCodeTools = ClaudeCodeTools
  {requiredBuiltins :: ![Text], allowedTools :: ![Text], mcpConfig :: !Value, settings :: !Value}
renderClaudeCodeTools :: GateInvocation -> WorkspaceRootPath -> ResolvedToolSet -> ClaudeCodeTools
claudeCodeArguments :: FilePath -> ClaudeCodeTools -> [Text]
  -- ["--allowedTools", …, "--mcp-config", <file>, "--strict-mcp-config", "--settings", <json>]

data CodexCommandConfinement = CodexHookGate !GateInvocation | CodexNoCommandConfinement
newtype CodexTools = CodexTools {overrides :: [CodexOverride]}   -- each renders as -c key=<toml>
data CodexRenderRefusal = CodexCannotConfineCommands !(NonEmpty ToolName)
renderCodexTools :: CodexCommandConfinement -> WorkspaceRootPath -> ResolvedToolSet -> Either CodexRenderRefusal CodexTools
codexArguments :: CodexTools -> [Text]
```

For Claude Code, each CLI pattern renders as a permission rule. A pattern with
`AnyTrailing` or `AtMostTrailing` renders as `Bash(<exe> <prefix words>:*)`, and the gate
enforces the count. A pattern with `NoTrailing` renders as `Bash(<exe> <prefix words>)`.
Each requested MCP tool renders as `mcp__<server>__<remoteName>`. `mcpConfig` is
`{"mcpServers": {"<server>": {"command": …, "args": […], "env": {…}}}}` with the workspace
substituted. `settings` installs one PreToolUse hook with matcher `Bash|mcp__.*` whose
command is `<gate executable> gate --grant <grant file>`. `requiredBuiltins` is `["Bash"]`
when CLI tools exist, and otherwise it is empty. For Codex, each MCP server renders as
`mcp_servers.<server>.command`, `.args`, `.env` and `.enabled_tools`. The CLI tools render
as the hook only under `CodexHookGate`, and otherwise the function returns the refusal.

Add `shikigami-agent/src/Shikigami/Agent/Tools/CodingAgent.hs`.

```haskell
prepareCodingAgentTools ::
  CodingAgentProvider ->   -- EP-2's sum: ClaudeCode | Codex
  RunToolDirectory -> WorkspaceRootPath -> ResolvedToolSet -> IO (Either ToolPreparationError [Text])
foldGateDecisions :: ActionRecord -> RunToolDirectory -> IO (Either Text Int)
```

`RunToolDirectory` is `$XDG_STATE_HOME/shikigami/tool-grants/<run-id>/`, created with mode
0700 and lying outside the workspace. `prepareCodingAgentTools` works in four steps:

1. It opens each MCP binding once and runs `verifyDiscoveredTools`, so schema drift
   refuses before the harness starts.
2. It writes `grant.json` (the resolved set plus run id and workspace, mode 0600) and
   `mcp.json`.
3. It renders the configuration.
4. It returns the extra argument vector for EP-2's launcher.

`foldGateDecisions` reads `decisions.jsonl` and appends each decision to the action record
as a `tool.called` entry with host `CodingAgentHost`. It is keyed by `tool_use_id`, so
folding again after a restart adds nothing. The gate runs inside the vendor tool's process
tree and cannot reach the authority port, so the launch-time `LaunchCodingAgent` decision
(EP-2) together with the grant file is the authority for these calls, and the fold is
their record. Edit EP-2's
coding-agent step to call `prepareCodingAgentTools` before launch and `foldGateDecisions`
on every outcome, including timeout and failure.

Add `shikigami-tools gate --grant FILE`. It reads the hook JSON from standard input. It
decodes `grant.json` through the checked `FromJSON`, which recomputes the revisions and
refuses a tampered file. From `tool_name` it builds a `ToolCall`: `Bash` becomes
`ShellCommandLine` from `tool_input.command` and `cwd`, and `mcp__s__t` becomes
`McpInvocation`. It calls `decideToolCall` and appends one line to `decisions.jsonl` with
`O_APPEND`. It then prints `{"hookSpecificOutput": {"hookEventName": "PreToolUse",
"permissionDecision": "allow"|"deny", "permissionDecisionReason": <renderToolRefusal>}}`
and exits 0. If the gate cannot decode its input or grant, it denies.

For Codex, check whether hooks can be supplied per invocation. Try `-c
'hooks.PreToolUse=[…]'` together with `--dangerously-bypass-hook-trust`. If that works,
use `CodexHookGate`. Otherwise use `CodexNoCommandConfinement` and record that in this
plan.

Finally, write the ADR (next free number in `docs/adr/` at the time of writing, since EP-1
and EP-2 also add ADRs). Its title is "Agents declare CLI tools and MCP servers, and the
operator grants the declaration". It records the declaration, grant and optional ceiling model (extending ADR-25), ADR-65
implemented with an interim stdio client, the confirmed declaration as the grant, the three
hosts under one decision function, the two-layer coding-agent enforcement, the Codex
limitation, and observation-only durable Skill tools. M4 adds the durable-step host to it.
Update the Limits section of `docs/capabilities/revision-pinned-tool-overlays.md` to point
to it.

### M4 — Declared tools as durable steps

This milestone needs EP-2 M2: the command-parameterized attempt machinery in
`Shikigami.Process.Attempt` (`AttemptCommand`, `AttemptHandlers`, `attemptBody`,
`recoverAttempt`) and its IO half `Shikigami.Agent.Process.Attempt.runAttempt`. Recheck the
pre-release facts first, as in M1, because this milestone adds a child to the `AgentRun`
body.

A flow body or a playbook step cannot call a model-facing tool. It needs a capability that
runs one declared command to completion as a journaled step, and such a command may run for
an hour and change the repository. Add `shikigami-core/src/Shikigami/Flow/DeclaredTool.hs`:

```haskell
newtype StepDeadline = StepDeadline Natural     -- 1 .. 720 minutes; mkStepDeadline

data ToolStep = ToolStep
  { tool :: !ToolName,
    arguments :: ![ArgumentWord],
    deadline :: !StepDeadline,
    outputLimit :: !OutputLimit,          -- per stream, kept in the outcome; the rest is counted
    workspace :: !CodingAgentWorkspace    -- EP-2's selector: the run's worktree, or EP-4's repository selector
  }

data ToolStepOutcome
  = ToolCompleted !ToolRun                -- any exit code
  | ToolRefused !ToolRefusal              -- decideToolCall said no; nothing was launched
  | ToolFailed !ToolStepFailure           -- Unstartable | DeadlineBeforeLaunch | NotGranted | WorkspaceUnavailable
  | ToolTimedOut !PartialToolRun
  | ToolUncertain !UncertainReason        -- from Shikigami.Process.Attempt; never retried
data ToolRun = ToolRun
  {exit :: !Int, stdout :: !BoundedText, stderr :: !BoundedText, droppedBytes :: !Natural, elapsedMs :: !Natural}

data DeclaredTool :: Effect where
  RunToolStep :: DeclarationCoordinate "tool-step-key" -> ToolStep -> DeclaredTool m ToolStepOutcome

runDeclaredTool :: (DeclaredTool :> es) => DeclarationCoordinate "tool-step-key" -> ToolStep -> Eff es ToolStepOutcome
runDeclaredToolCapability :: (Workflow :> es, Store :> es, IOE :> es) => DeclaredToolEnv -> Eff (DeclaredTool : es) a -> Eff es a
```

The capability is keyed like EP-2's `codingAgent`: the interpreter starts or awaits a keyed
child workflow, and a replay returns the journaled child result. Declare
`domain/shikigami/declared-tool.keiro` with the workflow `DeclaredToolStep`, named
`shikigami.declared-tool-step`, whose body has the three static steps `admit`, `attempt`
and `settle`, and add `child declared-tool id input via declaredToolStepWorkflowId ->
ToolStepOutcome` to `domain/shikigami/agent-run.keiro` beside `child coding-agent`. Run
`just keiro-scaffold`. The body is EP-2's `attemptBody` with these handlers:

- `admit` resolves the subject's ports through `TierComposition.resolve`, runs
  `decideToolCall` on a `CliInvocation`, and asks the authority to decide `RunDeclaredTool`
  with host `StepHost`. A refusal by either ends the step with no launch. It fixes the
  absolute deadline and the attempt directory.
- `command` builds the launch. A declared command does not write a result file, so the
  launched program is a wrapper: `shikigami-tools attempt --result FILE --stdout FILE
  --stderr FILE --deadline SECONDS --output-limit BYTES -- <located executable>
  <arguments…>`. The wrapper runs the command as an argument vector in its own process
  group with standard input closed, drains both streams to their files up to the limit,
  kills the group at the deadline, and then writes the result file atomically (exit code,
  timed-out flag, byte counts, elapsed time). Because the wrapper outlives the worker, a
  restarted worker either collects the result or reattaches.
- `settle` maps the result to a `ToolStepOutcome` and appends one `tool.called` entry with
  host `StepHost`, keyed by the child workflow id.

The limits differ by host, and only by host. The model-facing hosts keep `CallTimeout` at
1 to 600 seconds, and durable `Skill` runs still admit only `Observation` tools. The step
host takes its deadline from the `ToolStep`, up to 720 minutes, and admits any operation
class the declaration states and the grant covers, because a step is launched at most once
and reports `ToolUncertain` instead of repeating. `resolveDeclaredTools` with host
`StepHost` therefore skips `DurableToolOperationNotAllowed`. Add `DeclaredTool :> es` to
`FlowEffects` and its interpreter to the stack in `runFlowBehavior`, as EP-2 does for
`CodingAgent`, and stop returning `ToolsUnsupportedForBehavior` for `Flow` and `Playbook`.
EP-4's `Tool` playbook step
(`docs/plans/129-execute-dhall-declared-playbooks-with-fan-out-approval-gates-and-learning-capture.md`)
calls only `runDeclaredTool`. Add a test-only registered flow, or extend the one EP-2 M3
adds, that calls `runDeclaredTool` under two keys. Extend the ADR and
`docs/user/declared-tools.md` with the step host.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/shikigami` unless stated otherwise.
Commits follow Conventional Commits and carry both trailers:

```text
feat(capability): resolve declared CLI tools against the operator's grant

ExecPlan: docs/plans/128-let-agents-declare-cli-tools-and-mcp-servers-with-authority-attached-to-the-declaration.md
Intention: intention_01m7fq4tf3ejrt0tjxvsy8ejdt
```

Recheck the pre-release facts first:

```bash
git tag --list | wc -l            # expect 0
sed -n 16p docs/workflow-versioning.md
```

Build and run the focused checks while developing:

```bash
cabal build all
cabal test shikigami-core-test --test-options='--match "Declared tools"'
cabal test shikigami-agent-test
just keiro-scaffold
just keiro-gate "$(git merge-base HEAD master)"
just haskell-conventions
just user-docs-validate
```

Install the MCP server once for M2. Pick the current version from PyPI and record it in
Surprises & Discoveries:

```bash
uv tool install mcp-server-git==<version>
command -v mcp-server-git        # expect /Users/shinzui/.local/bin/mcp-server-git
```

For M4, the real run uses a declared build command on a real checkout, through the
test-only flow or, once EP-4 lands, a one-step playbook:

```bash
cabal test shikigami-agent:test:shikigami-agent-test --test-options='--match "tool attempt"'
just keiro-gate "$(git merge-base HEAD master)"
```

Prepare a real worktree through EP-1's `LocalOperator` workspace provider. Then inspect the
resolution and the MCP server:

```bash
cabal run shikigami-tools -- check agents/repo-inventory.dhall --workspace /Users/shinzui/Keikaku/bokuno/keiro
cabal run shikigami-tools -- mcp discover git --workspace /Users/shinzui/Keikaku/bokuno/keiro
```

Before the first interactive run, the `check` command should print something like this
and exit 3; after the operator has confirmed the declaration, the same lines read
`granted` and it exits 0:

```text
cli.mori   needs confirmation  /Users/shinzui/.nix-profile/bin/mori  revision cli-v1-3f…  as overlay__cli-mori__run   (Observation)
cli.mina   needs confirmation  /Users/shinzui/.nix-profile/bin/mina  revision cli-v1-a9…  as overlay__cli-mina__run   (Observation)
mcp.git    needs confirmation  revision mcp-v1-7c…  tools git_status, git_log  (Observation)
```


## Validation and Acceptance

The pure Hspec specs live in `shikigami-core/test/Shikigami/Capability/DeclaredSpec.hs`,
`DeclaredCallSpec.hs`, `McpBindingSpec.hs` and `DeclaredRenderSpec.hs`. They must cover
the following, and each must fail before the corresponding change:

- Every `ToolResolutionError` arm, including `UngrantedCliTool` under `NoToolGrant`, a tool
  that resolves on the grant alone when the catalog has no ceiling for it, and a declared
  pattern wider than an explicit ceiling.
- Revision stability under reordering of declarations, plus a revision change when a
  pattern changes.
- Every `parseSimpleCommand` refusal class.
- `decideToolCall` for an undeclared executable, out-of-pattern arguments and an unapproved
  MCP tool.
- The ADR-65 revision, and `verifyDiscoveredTools` for a missing tool, a changed schema
  and an extra unapproved tool (which is ignored).
- Golden argument vectors and JSON for `renderClaudeCodeTools` and `renderCodexTools`.

`shikigami-agent/test/Shikigami/Agent/Tools/CliSpec.hs` runs `/bin/echo` through the
provider and checks the output bound with `/usr/bin/yes`. It checks the timeout and
process-group kill with `/bin/sleep 30` and a one-second limit.

Required real-use acceptance runs on this Mac under `LocalOperator` against a worktree of
`/Users/shinzui/Keikaku/bokuno/keiro`. Run agents with EP-1's operator command, written
below as `<run>`. Read the action record with EP-1's `shikigami-local ledger` command, written below as `<ledger>`.
Substitute their final spellings from EP-1 and record them here.

V1 (M1). Start with no `~/.config/shikigami/tools.dhall`. Run `<run>
agents/repo-inventory.dhall` in a terminal with input naming `shinzui/keiro`. The command
asks once, and the request lists `mori` and `mina` with their located executables and
patterns; answer `y`. The agent's reply quotes facts from `mori registry show shinzui/keiro` (for example the
registered path `/Users/shinzui/Keikaku/bokuno/keiro`) and from `mina docket status`. Next,
run it again with an instruction to also call `mori registry list`, which the declaration
does not allow. `<ledger> --run <id>` must show:

```text
admitted  cli.mori run  ["registry","show","shinzui/keiro"]  exit 0
admitted  cli.mina run  ["docket","status"]                  exit 0
refused   cli.mori run  ["registry","list"]                  arguments outside declared patterns for mori
```

A second run does not ask. Then add one argument pattern to `mina` in the declaration: the
next interactive run asks again, and the same run with no terminal fails at
`resolve-declared-tools` with `mina is not granted for this declaration`, as
`shikigami-tools check` reports with `needs confirmation`. Finally write the ceiling-only
tools file from M1, which allows `mori` only `["path"]`: `shikigami-tools check` must report
`refused: mori pattern ["registry","show"] is outside the operator ceiling`, and a new run
must fail at `resolve-declared-tools` with that message. Remove the ceiling afterwards.

V2 (M2). `shikigami-tools mcp discover git` lists `git_status` and `git_log` as `approved`
and `git_commit` as `not approved`. A `repo-inventory` run reports the worktree's branch
and its clean or dirty state from `overlay__mcp-git__git_status`. The ledger shows
`authorized connect mcp.git`, `authorized discover mcp.git` and `admitted mcp.git
git_status`. Then edit one character of the approved `git_status` schema in `tools.dhall`.
The next run must refuse acquisition with `approved tool git_status schema changed`, and
the server must not be called.

V3 (M3, the MasterPlan's representative check). Run a `CodingAgent` agent
`agents/repo-inventory-coder.dhall` (provider Claude Code, same `tools` as
`repo-inventory`) on the keiro worktree. The prompt asks it to run `mori registry show
shinzui/keiro`, then `gh pr list`, then use the git MCP status tool, and to report the
results. The run completes. Its reply contains the Mori output and the git status, and it
states that `gh` was refused. The ledger shows:

```text
admitted  Bash  mori registry show shinzui/keiro   cli.mori
refused   Bash  gh pr list                         undeclared executable gh
admitted  mcp__git__git_status                     mcp.git
```

Then run a Codex `CodingAgent` with the same declaration. If the Codex hook check failed,
restrict that agent's `tools` to the MCP entry. Its reply must contain the `git_status`
result obtained through the rendered `mcp_servers.git` override. If CLI tools remain
declared without confinement, `shikigami-tools check` must show
`CodexCannotConfineCommands` and the run must refuse before launch.

V4 (M4). Declare a tool `build` in a `Flow` agent that uses the test flow: executable
`nix`, pattern `["develop","--command","cabal","build","all"]` with `NoTrailing`, operation
class `IdempotentMutation`. Run it under `shikigami-worker` (EP-2 M2b) on a worktree of
`/Users/shinzui/Keikaku/bokuno/fsrs-hs` with a step deadline of 60 minutes, after
confirming the declaration once with the light command. While the build runs, kill the
worker by its saved PID and start it again. The log must show exactly one launch and a
reattach, and the step must end `ToolCompleted` with the build's exit code. The action
record must show one approved `RunDeclaredTool` decision and one `tool.called` entry with
host `StepHost`. Repeat with the wrapper's process group killed as well: the step must end
`ToolUncertain` and must not launch again. A call with arguments outside the declared
pattern must end `ToolRefused` with nothing launched. The two-key flow test must show two
children with distinct ids, and a replay must not launch.

Proposals for later scope, which are not required here: HTTP MCP transports and
credentials (after Baikai IR-2), mutation-class tools in durable Skill runs, and per-call
revocation by reloading the catalog file.


## Idempotence and Recovery

All build, test, `check` and `discover` steps can be repeated safely. `discover` never
calls a tool. `uv tool install` of a pinned version can be repeated. The operator files
under `~/.config/shikigami/` are owned by the operator; this plan only adds entries to
them. A tool is revoked at the next resolution by revoking the stored grant with EP-1's
`shikigami-local revoke <digest>`, or by removing its MCP binding. A durable tool step is
launched at most once per key; its attempt directory is its recovery state and must not be
deleted while the run is unfinished. A grant
directory under `~/.local/state/shikigami/tool-grants/` can be deleted once its run has
ended and its decisions have been folded. Folding is keyed by `tool_use_id`, so repeating
it is a no-op. If `just keiro-gate` fails after the new step is added, treat the
diagnostic as authoritative. Under the pre-release exception, regenerate with `just
keiro-scaffold` and update `Expectations.hs`. If the facts show the exception has ended,
gate the step behind `shikigami-declared-tools-v1` instead. Real runs use a worktree from
EP-1's provider, never the primary keiro checkout, and the declared tools are all
observations, so a failed run leaves keiro unchanged.


## Interfaces and Dependencies

This plan has a hard prerequisite: EP-1 must be accepted, and through it EP-8 M1. EP-3
consumes `TierComposition.resolve` and its `TierRuntime` record, adds the field
`tools :: ToolAuthority`, and appends `tool.called` entries through its
`record :: ActionRecord`. It extends EP-1's `GrantRequest`, `renderGrantRequest` and
`decideLocalAction` for declared tools, and consumes EP-8's `Authority` with the
`RunDeclaredTool` action; the record reader behind `shikigami-local ledger`; the
`LocalOperator` worktree provider, which yields a `WorkspaceRootPath`; and the operator
run command. M3 additionally requires EP-2's `CodingAgent` arm and durable step to be
accepted (EP-2 M1). M4 additionally requires EP-2 M2, the command-parameterized attempt
machinery; MasterPlan 22's registry records these as "EP-2 M1 (for M3); EP-2 M2 (for
M4)". EP-2's slot has the type `Shikigami.Capability.Declared.Resolve.ResolvedToolSet`.
If EP-2 lands first with a placeholder type, M3 replaces the placeholder with this type.
EP-2 must not grant `Bash` wholesale and must preserve settings hooks.

This plan publishes the following interfaces, which EP-2, EP-4 and EP-7 depend on:

- `Shikigami.Capability.Declared` (`ToolDecl` and its parts, plus the `tools` field of
  `AgentDecl` and `schema/Agent.dhall`).
- `Shikigami.Capability.Declared.Catalog` (`ToolCatalog`, `loadToolCatalog`,
  `emptyToolCatalog`, `ToolGrant`, `ToolAuthority`, `schema/Tools.dhall`). The schema file
  is a public surface of MasterPlan 22 that this plan owns.
- `Shikigami.Capability.Declared.Record` (the `tool.called` record kind).
- `Shikigami.Flow.DeclaredTool` (`runDeclaredTool`, `ToolStep`, `ToolStepOutcome`) and the
  `shikigami.declared-tool-step` child, from M4.
- `Shikigami.Capability.Declared.Resolve` (`resolveDeclaredTools`, `ResolvedToolSet`,
  `resolvedToolSetView`, `resolvedToolDescriptors`, `emptyResolvedToolSet`).
- `Shikigami.Capability.Declared.Call` (`decideToolCall`, `ToolDecision`, `ToolRefusal`).
- `Shikigami.Capability.Declared.Render` (`renderClaudeCodeTools`, `renderCodexTools`).
- `Shikigami.Capability.Mcp.Binding` (`McpBinding`, `verifyDiscoveredTools`).
- `Shikigami.Agent.Tools.CodingAgent` (`prepareCodingAgentTools`, `foldGateDecisions`).
- The `shikigami-tools` executable (`check`, `mcp discover`, `gate`, `attempt`).

EP-4's `Tool` playbook step and EP-7's campaign reuse the `tools` field and call
`runDeclaredTool`. They do not spawn processes themselves. EP-9
(`docs/plans/134-declare-and-run-a-routine-agent-with-one-file-and-one-command.md`) relies
on the confirmed declaration being the grant, so a routine agent that declares tools needs
no tools file.

These libraries matter. `process` (already a dependency of `shikigami-agent`) spawns
processes. `dhall` and `aeson` decode the files. `Shikigami.Decision.Contract.versionedDigest`
computes revisions. `mori://shinzui/shikumi/packages/shikumi-tools` supplies `DynTool`, and
`mori://shinzui/kikan-en/packages/kikan-en-contract` supplies `AgentAction`. Do not add an
MCP library dependency. The interim client is replaced by the Baikai client tracked in
`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-2` when that ships. The
external CLIs are Claude Code 2.1.325, Codex 0.169.0, `mori`, `mina` and `mcp-server-git`.
The plan's behavior depends on their flags as observed on 2026-11-15, so recheck
`claude --help` and `codex exec --help` when either is upgraded.

Revision note (2026-11-15): cascaded the MasterPlan 22 review. Calls are decided as
`RunDeclaredTool` and recorded as `tool.called` through EP-8's kernel ports, the confirmed
declaration is the grant for CLI tools, and M4 adds declared tools as durable steps on
EP-2 M2's attempt machinery.
