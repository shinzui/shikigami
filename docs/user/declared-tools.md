---
type: "Guide"
title: "Give an agent your command-line tools"
description: "Declare the CLI tools and MCP server tools an agent may call, grant the declaration once, bind MCP servers and bound CLI tools in the operator tools file, and read every call in the action record."
docId: "DOC-22"
tags: ["tools", "local-operator", "authority", "record"]
generated:
  by: claude-code/claude-opus-5-5
  at: 2026-11-15T20:10:00Z
---

# Giving an agent your command-line tools

A declaration can name the command-line tools its agent may call: the executable, the
argument patterns it may be called with, the working directory and an operation class.
Under the `local-operator` trust tier ([local operator](local-operator.md)) your one-time
confirmation of the declaration is the grant, and every call, admitted or refused, lands in
the action record. Skills and coding agents can use declared tools. Flows and playbooks can run declared CLI tools as durable steps. A tool can be a
CLI command or an approved tool of an MCP server bound in your tools file.

## Declaring tools

```dhall
let A = ../schema/Agent.dhall

in  A.Agent::{
    , name = "repo-inventory"
    , behavior = A.Behavior.Skill { path = "agents/skills/repo-inventory" }
    , trigger = A.Trigger.Event { eventType = "repository.inventory.requested" }
    , identity = Some { principal = "principal_repo_inventory" }
    , tools =
      [ A.Tool.CliTool
          A.CliTool::{
          , name = "mori"
          , executable = A.ExecutableRef.OnPath "mori"
          , allow =
            [ A.pattern [ "registry", "show" ] A.Trailing.AnyTrailing
            , A.pattern [ "path" ] A.Trailing.AnyTrailing
            ]
          }
      ]
    }
```

* `executable` is `OnPath "name"` (found on your `PATH` when the run starts) or
  `AtPath "/absolute/path"`.
* Each `allow` pattern is a fixed prefix of argument words and what may follow it:
  `NoTrailing`, `AnyTrailing` or `AtMostTrailing n`. A call matches when one pattern does.
* `workingDirectory` defaults to `WorkspaceRoot` (the repository the run works in);
  `WorkspaceSubdirectory "path"` names a directory below it.
* `operationClass` defaults to `Observation`. The durable Skill tool loop admits observations. A durable CLI step can also perform a granted mutation, as described below.
* `limits` defaults to 60 seconds and 256 KiB per stream; set
  `Some { timeoutSeconds = …, outputBytes = … }` (up to 600 seconds and 4 MiB).
* A declaration with tools needs an `identity`.

The model sees each tool as `overlay__cli-<name>__run`, taking `{"args": [...]}`. The
command runs with no shell, standard input closed, your environment, its own process group,
the call's deadline and output bound. Anything not matching a declared pattern is refused,
and the model is told why. Output is evidence for the model, never instructions.

## Granting and checking

The first interactive run lists the declared tools in its confirmation:

```text
local-operator: repo-inventory asks for
  repository   mori://shinzui/keiro (/Users/shinzui/Keikaku/bokuno/keiro)
  tool         mori (mori, Observation): registry show …; path …
  tool         mina (mina, Observation): docket status; exec-plan remaining …
  capabilities cli.mina, cli.mori
```

Changing a tool changes the declaration, so the next run asks again; a run without a
terminal then refuses. Check a declaration without running it:

```bash
shikigami-local tools agents/repo-inventory.dhall --workspace mori://shinzui/keiro
```

It prints each tool's located executable, revision and model-facing name, and exits 0 when
granted, 3 when it awaits your confirmation and 1 when refused.

## An optional ceiling

`$XDG_CONFIG_HOME/shikigami/tools.dhall` (default `~/.config/shikigami/tools.dhall`) may
bound a tool of a given name. A declaration then needs the same executable, patterns inside
the ceiling's and an operation class no higher, or every run refuses before a model call:

```dhall
let A = ~/Keikaku/bokuno/shikigami/schema/Agent.dhall
let T = ~/Keikaku/bokuno/shikigami/schema/Tools.dhall

in  T.Catalog::{
    , cli =
      [ { name = "mori"
        , executable = A.ExecutableRef.OnPath "mori"
        , allow = [ A.pattern [ "path" ] A.Trailing.AnyTrailing ]
        , maximumOperationClass = A.OperationClass.Observation
        }
      ]
    }
```

Tools without a ceiling run on your grant alone.

## MCP server tools

An agent can also use tools of an MCP server. The server itself — its executable, arguments
and environment names — and the tools you approve live only in your tools file; a
declaration names the server and a subset of its approved tools:

```dhall
, tools = [ A.Tool.McpTools { server = "git", tools = [ "git_status", "git_log" ] } ]
```

Bind the server in `tools.dhall`. Shikigami speaks MCP over stdio; `WorkspaceRootArgument`
is replaced by the run's repository path when the server starts:

```dhall
, mcp =
  [ { server = "git"
    , command = "/absolute/path/to/mcp-server-git"
    , arguments = [ T.McpArgument.LiteralArgument "--repository", T.McpArgument.WorkspaceRootArgument ]
    , environment = [] : List Text
    , tools =
      [ { remoteName = "git_status"
        , description = "Show the working tree status of the run's repository."
        , inputSchema = "{…the schema the server reports…}"
        , operationClass = A.OperationClass.Observation
        }
      ]
    }
  ]
```

`shikigami-local mcp git --workspace mori://shinzui/keiro` starts the bound server and lists
each tool it offers as `approved`, `approved-schema-changed` or `not approved`, printing a
ready-to-edit entry with the exact schema for each one you have not approved. Choose its
operation class yourself; leave mutating tools such as `git_commit` unapproved for an agent
that only reads.

The model sees `overlay__mcp-git__git_status`, with your description and schema rather than
the server's. Only the requested approved tools are offered. When the server starts, every
requested tool must still be offered with exactly the approved schema; otherwise the run
refuses before any tool is called, and the record says why (`approved tool git_status
schema changed`). The binding's revision digests the whole binding, so editing it is visible
in every decision.

## Tools for a coding agent

A `CodingAgent` declaration takes the same `tools`. Claude Code runs its declared commands
itself, so Shikigami installs a PreToolUse hook, `shikigami-local gate`, that allows a shell
call only when it is one plain command (no pipes, redirection, substitution or variables)
matching a declared tool, and an MCP call only for a requested approved tool. Only the
requested MCP servers are configured (`--strict-mcp-config`), not the servers in your own
Claude settings. Anything else is denied and recorded, and the agent is told why. Codex gets
the requested MCP servers with only their requested tools enabled; a Codex step that declares
CLI tools is refused, because Codex cannot confine shell commands.

These settings reach the vendor CLI through Baikai's provider arguments, which your Baikai
ceiling must allow:

```kdl
// ~/.config/baikai/agents.kdl
policy {
  allow-provider-args #true
}
```

`agents/repo-inventory-coder.dhall` is an example.

## Tools as durable steps

A `Flow` declaration runs its declared tools as durable steps, which may run for hours and
change the repository. The registered flow `run-declared-tool` runs one, named by the payload:

```dhall
A.Agent::{
, name = "build-step"
, identity = Some { principal = "principal_build_step" }
, behavior = A.Behavior.Flow { name = "run-declared-tool" }
, tools =
  [ A.Tool.CliTool
      A.CliTool::{
      , name = "cabal"
      , executable = A.ExecutableRef.OnPath "cabal"
      , allow = [ A.pattern [ "build" ] A.Trailing.AnyTrailing ]
      , operationClass = A.OperationClass.IdempotentMutation
      }
  ]
}
```

```bash
shikigami-agent-run --set trust.tier=local-operator --agent build-step.dhall \
  --workspace mori://shinzui/fsrs-hs --payload '{"tool":"cabal","args":["build","all"],"deadlineMinutes":30}'
```

The step runs in the run's worktree, with a deadline of 1 to 720 minutes, and any operation
class the declaration states and you granted. It is launched at most once: if the command is
interrupted, `shikigami-agent-run --resume <WORKFLOW_ID>` collects its result or reattaches to
it, and if its launcher was lost the step ends `uncertain` and is never repeated.

## What the record shows

`shikigami-local ledger --run <WORKFLOW-ID>` shows the authority's decision for each tool
call and one `tool.called` entry:

```text
tool.called admitted cli.mori run ["registry","show","shinzui/keiro"] exit 0
tool.called admitted cli.mina run ["docket","status"] exit 0
tool.called refused cli.mori run ["registry","list"] arguments outside declared patterns for mori
tool.called admitted mcp.git git_status
tool.called refused mcp.git approved tool git_status schema changed
tool.called admitted cli.mori mori registry show shinzui/keiro          (a coding agent's call)
tool.called refused - gh pr list undeclared executable gh
```

Under the `contained` and `multi-tenant` tiers a declaration with tools is refused before
the run starts.
