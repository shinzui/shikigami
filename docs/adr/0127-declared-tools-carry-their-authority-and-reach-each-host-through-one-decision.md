# 0127. Declared tools carry their authority and reach each host through one decision

Date: 2026-11-15

Status: accepted


## Context

Before MasterPlan 22 an agent could use only the five workspace tools compiled into the core,
and no Haskell code spoke MCP. The operator's own command-line tools and MCP servers, which a
routine agent needs (`mori registry show`, `mina docket status`, a Git server), had no place in
a declaration. [ADR 0025](0025-capability-overlays-are-requests-for-additive-model-tools.md)
says a declaration requests and an operator catalog grants;
[ADR 0065](0065-mcp-provider-revisions-bind-the-approved-tool-contract.md) defines an
operator-owned MCP binding; [ADR 0124](0124-authority-is-selected-by-trust-tier-and-the-local-operator-grants-a-declaration-once.md)
makes the local operator's one-time confirmation of a declaration its grant.


## Decision

A declaration's `tools` field names CLI tools (executable, argument patterns, working
directory, operation class, limits) and MCP requests (a server and a subset of its approved
tools). Executable names and argument words are not secrets, so the declaration carries the
whole CLI tool; MCP transports, environment names and approved schemas stay in the operator's
tools file (`$XDG_CONFIG_HOME/shikigami/tools.dhall`), as ADR 0065 requires. The operator's
grant of the declaration is the grant of its CLI tools; an optional ceiling of the same name in
the tools file bounds a tool (same executable, patterns inside the ceiling's, operation class
no higher). Tiers other than `local-operator` refuse a declaration with tools before the run.

One rule decides every call: a CLI call is admitted only when its argument vector matches a
declared pattern, and an MCP call only when it names a requested approved tool. It reaches
each host differently:

* **A `Skill` model** sees each tool as an ordinary capability overlay, `cli.<name>` with the
  logical tool `run`, or `mcp.<server>` with its approved tools. The existing journaled overlay
  resolution, the per-call `UseCapability` decision of the run's authority, durable execution
  children and the durable-observations rule apply unchanged; the host adapter in
  `shikigami-core:local-host` runs the command with no shell, in its own process group, under
  the call's deadline and output bound. An MCP acquisition refuses when a requested tool is
  missing or its schema differs from the approved one.
* **A `CodingAgent`** runs its own commands, so its tools are rendered into its configuration.
  Claude Code gets a PreToolUse hook, `shikigami-local gate`, that allows a shell call only
  when it parses as one plain command matching a declared tool, and an MCP call only for a
  requested approved tool, plus `--strict-mcp-config` with only the requested servers. In an
  unattended run Claude Code denies any call nobody allowed, so a failing hook fails closed.
  Codex gets the requested MCP servers with `enabled_tools`; it cannot confine shell commands,
  so a Codex step with CLI tools is refused. The vendor arguments travel through Baikai's
  `provider-args`, which the operator's Baikai ceiling must enable.
* **A durable step** runs a declared tool through the same pattern decision and a
  `UseCapability` decision of the run's authority, as the keyed child workflow
  `shikigami.declared-tool-step`, using the restart-safe attempt machinery of
  [ADR 0126](0126-coding-agents-are-durable-workers-and-batch-qualification-is-tier-scoped.md):
  the launched program is `shikigami-local tool-attempt`, which runs the command with no shell
  and prints its result when it ends. The step host admits any operation class the grant covers
  and a deadline of up to 720 minutes, because a step is launched at most once and reports
  `uncertain` instead of repeating. A flow body calls it through `runDeclaredTool`; the
  registered flow `run-declared-tool` runs one step from its payload.

Every decision, admitted or refused, is a `tool.called` entry in the action record
([ADR 0123](0123-the-kernel-owns-its-action-vocabulary-authority-port-and-action-record.md)).


## Alternatives rejected

**A second approvals file for CLI tools.** The operator would write every tool twice before a
routine agent ran; the confirmed declaration already lists them.

**A new workflow step resolving tools.** The overlay step already journals exact descriptors;
a parallel resolved set would duplicate it and change the workflow shape.

**`--allowedTools` patterns for Claude Code.** They would need the same strings in the Baikai
ceiling's `allowed-tools`, and give no record; the hook decides, records, and fails closed.

**Waiting for Baikai's MCP client.** ADR 0065's schema check needs discovery now; the stdio
client in `local-host` sits behind a small session record so Baikai's can replace it.


## Consequences

Operators can give an agent `mori`, `mina` or any command with exact argument patterns, and
any stdio MCP server's approved tools, by editing a declaration and confirming it once.
`shikigami-local tools` checks a declaration and `shikigami-local mcp <server>` discovers a
server's tools for a binding. A coding agent's calls appear in the record only when they reach
the gate: Codex MCP calls are confined by `enabled_tools` but not recorded per call.
Declared tools inherit the operator's environment under `local-operator`.


## References

* [ADR 0025](0025-capability-overlays-are-requests-for-additive-model-tools.md),
  [ADR 0065](0065-mcp-provider-revisions-bind-the-approved-tool-contract.md) and
  [ADR 0124](0124-authority-is-selected-by-trust-tier-and-the-local-operator-grants-a-declaration-once.md)
  — the request, binding and grant this record extends.
* [docs/plans/128-let-agents-declare-cli-tools-and-mcp-servers-with-authority-attached-to-the-declaration.md](../plans/128-let-agents-declare-cli-tools-and-mcp-servers-with-authority-attached-to-the-declaration.md)
  — the implementing plan.
* [docs/user/declared-tools.md](../user/declared-tools.md) — the operator guide.
