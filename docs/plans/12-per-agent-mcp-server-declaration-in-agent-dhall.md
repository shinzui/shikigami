---
id: 12
slug: per-agent-mcp-server-declaration-in-agent-dhall
title: "Per-agent MCP server declaration in Agent.dhall"
kind: exec-plan
created_at: 2026-06-27T17:57:56Z
intention: "intention_01kx1tyzqcerzv4ysbktgr9sw9"
master_plan: "docs/masterplans/7-platform-feature-completion-egress-schema-memory-lifecycle-delegation.md"
---

# Per-agent MCP server declaration in Agent.dhall

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today a `shikigami` agent can only call tools that someone hand-wrote in Haskell and
compiled into the runtime. There is no way for an agent author to say "this agent may also
use the GitHub tool server" or "this agent may read from the Notion server" without writing
bespoke Haskell glue for each one. **MCP** (the *Model Context Protocol*) is the
industry-standard way that external "tool servers" publish callable tools over HTTP; this
plan lets an agent reach that whole ecosystem through one line of declaration.

After this change, an agent author writes, in the agent's Dhall file (for example
`agents/triage-note.dhall`), a new `mcpServers` field naming the MCP servers that agent may
use:

```dhall
, mcpServers =
    [ A.McpServer::{ name = "github", url = "https://mcp.example.com/github" } ]
```

When that agent runs, the runtime connects to each declared server authorized for the run's
principal, asks it what tools it
offers, and registers those tools into the same tool registry the agent already uses — under
stable, collision-free names of the form `mcp__<server>__<tool>` (e.g.
`mcp__github__create_issue`). The agent's language model then sees and can call those tools
mid-run exactly as if they had been written by hand, and the connections are closed when the
run finishes. The observable win: an operator can add a remote capability to an agent by
editing one Dhall list and re-running it — no recompilation of a new tool, no code change.
The declaration is a request, not authority: before any connection or tool dispatch, the
runtime checks the upstream per-action authorization policy for the run's authenticated
principal, server, and tool. Agent files may contain credential references only; secret
material is resolved at the plan 37 Settei composition root and never rendered, logged, or
returned through a tool/API result.

This is the **integration capstone** (plan C6) of the cross-repo MasterPlan
`shinzui/baikai:docs/masterplans/6-mcp-support-across-the-agent-stack.md`. It consumes
machinery built by upstream plans (see Interfaces and Dependencies) and is the only plan in
that initiative that touches a user-facing configuration schema.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1 — Schema field: add `McpServer`/`McpTransport`/`McpAuth` and an `mcpServers` list to
  `schema/Agent.dhall`; `McpAuth` contains only `None` or a credential reference. Mirror them
  on `Shikigami.Api.Agent`; confirm the loader parses them without secret material.
- [ ] M1 — Example: add an `mcpServers` entry to one example agent and a new
  `agents/proof/mcp-echo.dhall` declaring a stub server.
- [ ] M2 — Build wiring: add `shikumi-tools` to `cabal.project` and to
  `shikigami-core.cabal` build-depends; select coherent published baikai/shikumi releases
  verified against their registries and upstream tags.
- [ ] M2 — Registry seam: give `BehaviorEnv` a `tools :: ToolRegistry` field
  (default empty) and thread it into `runBehavior`.
- [ ] Prerequisites — plans 36 and 37 have landed; baikai C1/C2, shikumi C5, and the upstream
  per-action authorization seam tracked by Kikan-En IR-3 are released and
  verified through Mori plus authoritative registry/tags. Baikai C3 is
  additionally required for non-`None` authentication.
- [ ] **Re-verified 2026-08-10: all three upstream contracts are still absent.** Baikai has no
  `Baikai.Mcp.*` module as of `baikai 0.5.0.0` — that release added `Baikai.Agent` and
  `Baikai.Evidence`, not MCP. The shikumi package set (`shikumi`, `-cache`, `-cache-postgres`,
  `-cache-redis`, `-cli`, `-compile`, `-eval`, `-jitsurei`, `-okf`, `-optimize`, `-tools`,
  `-trace`, all at the 2026-08-07 tags) contains no MCP adapter. Kikan-En IR-3 remains
  `proposed`. **Re-check all three before scheduling M3–M5 rather than trusting this line** —
  it is a snapshot, and the whole point of recording the date is that it goes stale.
- [ ] M1–M2 are startable now and do not depend on any of the above: the schema field, its
  mirror, the loader proof, the example agents, and the `ToolRegistry` seam on `BehaviorEnv` are
  all local. Only the live connect/invoke path in M3–M5 is gated.
- [ ] M3 — Run lifecycle: add `withAgentMcpTools` (connect + register + bracket-close) in
  `Shikigami/Agent/Run.hs`; wrap the `runBehavior` call in `runAgentWithMemory` with it.
- [ ] M4 — Skill loop: replace the single-completion `runSkill` with a bounded tool loop that
  surfaces the registry's `mcp__` tools to the model and dispatches tool calls.
- [ ] M4 — ShikumiProgram arm: hand the registry to `Shikumi.Agent.ReAct.react` so program
  behaviors also see the `mcp__` tools.
- [ ] M5 — End-to-end: a stub MCP server agent runs, its `mcp__` tools appear in the
  registry, the agent invokes one, and the connection is closed afterward.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: `mcpServers` is a flat list of `McpServer` records `{ name, url, transport, auth }`
  on the agent, defaulting to `[]`.
  Rationale: It mirrors how `sinks` is already modeled on the agent (`sinks : List Sink`,
  `default = []`), so an agent that declares no MCP servers is byte-compatible with today's
  files and needs no migration. The four fields map one-to-one onto baikai's
  `Baikai.Mcp.Client.McpServerConfig` (name, url, transport, auth), so the loader's job is a
  pure structural translation with no invented vocabulary.
  Date: 2026-06-27

- Decision: Connect MCP servers **per run** (connect at the start of a run, close at the end),
  not via a long-lived pool.
  Rationale: shikigami runs are short-lived behavior executions dispatched off a queue; a run
  is already wrapped in a kioku session lifecycle in `runAgentWithMemory`. Per-run connect
  keeps the lifetime identical to the session, makes cleanup a simple `bracket`, and avoids
  introducing shared mutable connection state and its concurrency hazards. A pool can be added
  later as an optimization behind the same `withAgentMcpTools` seam without changing callers.
  Date: 2026-06-27

- Decision: Cleanup uses `Control.Exception.bracket` so connections close even when the
  behavior throws or the run fails.
  Rationale: The run can fail (the `Left runErr` arm of `runAgentWithMemory` already exists);
  a non-bracket close would leak sockets on every failed run. `bracket` guarantees
  `closeMcp` runs on both the success and exception paths.
  Date: 2026-06-27

- Decision: Authorization of *which* MCP servers and tools an agent may use is a **hard
  prerequisite** for live wiring, owned by the per-action authorization seam in `shinzui/en` /
  `shinzui/shomei` (plan `shinzui/en:docs/plans/27-per-action-authorization-for-agent-tool-and-sink-dispatch.md`,
  the "C13" seam referenced in
  `shinzui/kikan:docs/architecture/evolution/agent-infrastructure-gaps.md` gap
  #7). Kikan-En IR-3,
  `mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-3`, is the
  canonical request for exposing that seam to Shikigami MCP connection and
  exact tool invocation.
  Rationale: Treating a manifest declaration as permission would let an agent expand its own
  authority. M1/M2 may establish inert schema and seams, but M3–M5 must not connect, expose,
  or invoke a server until authorization is available. Check server access before connect and
  tool access again at dispatch so discovery cannot bypass per-action policy.
  Date: 2026-07-22

- Decision: Authenticated servers are a conditional hard dependency on
  baikai C3 (`shinzui/baikai:docs/plans/32-mcp-authentication-headers-tokens-and-oauth.md`).
  `McpAuth` is declaration-safe: `None | CredentialRef {reference : Text}`. The reference is
  resolved through plan 37's Settei configuration at the executable composition root into an
  opaque credential value with no `Show`, `ToJSON`, or `FromJSON` instance. Raw bearer
  tokens, headers, refresh tokens, and OAuth client secrets are forbidden in Dhall and public
  API records.
  Rationale: Unauthenticated servers can be delivered without C3, but a non-`None` reference
  must fail validation until a released C3 resolver exists. Separating references from secret
  values prevents agent manifests, logs, validation output, and tool results from exfiltrating
  credentials.
  Date: 2026-07-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of this repository. Read it fully before editing.

**What shikigami is.** `shinzui/shikigami` (this repo, at
`/Users/shinzui/Keikaku/bokuno/shikigami`) is a *declarative agent runtime*: you describe an
agent in a Dhall file, and when a trigger fires the runtime runs the agent's declared
*behavior* and sends the result to *sinks*. "Dhall" is a small typed configuration language;
an agent file is a Dhall value that conforms to a schema. The schema lives at
`schema/Agent.dhall`.

**The agent schema (`schema/Agent.dhall`).** This file defines the record types an agent file
uses. The top-level `Agent` record currently has exactly five fields:

```dhall
let Agent =
      { Type =
          { name : Text
          , description : Text
          , trigger : Trigger
          , behavior : Behavior
          , sinks : List Sink
          }
      , default = { description = "", sinks = [] : List Sink }
      }
```

`Behavior` is a union with three arms: `Deterministic` (a named rule — not executed by the
runner today), `ShikumiProgram` (runs a registered typed program), and `Skill` (loads a
`SKILL.md` and runs a language-model completion). `Sink` is a union of output destinations.
Example agent files live under `agents/` (e.g. `agents/triage-note.dhall`,
`agents/proof/heartbeat.dhall`); each begins `let A = ../schema/Agent.dhall` and builds
`A.Agent::{ ... }`.

**The Haskell mirror (`shikigami-api/src/Shikigami/Api/Agent.hs`).** Every Dhall type in the
schema has a matching Haskell type in this module, each deriving `FromDhall` (so Dhall values
decode straight into Haskell). The top-level Haskell record is `AgentDecl` with fields
`name, description, trigger, behavior, sinks`. **If you add a field to the Dhall `Agent`
record you must add the same field to `AgentDecl`, or decoding fails at runtime.**

**The loader (`shikigami-core/src/Shikigami/Agent/Loader.hs`).** `loadAgent :: FilePath -> IO
(Either LoadError AgentDecl)` calls Dhall's `inputFile auto path`. It is fully generic over
`AgentDecl`'s `FromDhall` instance — it needs **no change** when fields are added, but it is
where a malformed `mcpServers` value surfaces as a typed `LoadError`.

**The behavior runner (`shikigami-core/src/Shikigami/Behavior/Run.hs`).** This is where a
behavior actually executes. `BehaviorEnv` is the bundle of things a run needs, built once by
`newBehaviorEnv :: IO BehaviorEnv`:

```haskell
data BehaviorEnv = BehaviorEnv
  { runtime :: !Runtime   -- a handan program runtime
  , model   :: !Model     -- the baikai model the Skill arm completes with
  }
```

The current source still spells these `behaviorRuntime`/`behaviorModel`; plan 13's
`BehaviorEnv` migration and this plan's registry edit rename them to the direct fields above
in the same constructor-breaking change. Do not preserve the prefixed accessors in the target
interface.

`runBehavior :: BehaviorEnv -> AgentDecl -> Value -> IO (Either RunError Value)` dispatches on
`behavior decl`: the `ShikumiProgram` arm looks up and runs a typed program; the `Skill` arm
calls `runSkill`; the `Deterministic` arm is unsupported. **There is no tool registry here
today** — this is the seam we extend.

**The skill arm (`shikigami-core/src/Shikigami/Behavior/Skill.hs`).** `runSkill :: Model ->
SkillDir -> Value -> IO (Either RunError Value)` reads a `SKILL.md`, builds a baikai `Context`
with `tools = V.empty`, runs **one** completion via `Baikai.Provider.Registry.completeRequest`,
and returns the assistant's first text block as `{"reply": <text>}`. **It does not loop and it
offers the model no tools** — both must change for MCP tools to be callable.

**The run lifecycle (`shikigami-core/src/Shikigami/Agent/Run.hs`).** `runAgentWithMemory ::
AppEnv -> BehaviorEnv -> AgentDecl -> Value -> IO (Either Text AgentRunResult)` is the run
seam: it opens a kioku session, recalls prior learnings, calls `runBehavior`, records the
output as a memory, and completes (or fails) the session. **This is where the MCP
connect/register/close bracket belongs**, wrapping the `runBehavior` call so connections live
exactly as long as the run.

**Callers of these seams.** `BehaviorEnv` is constructed by `newBehaviorEnv` in three places:
`shikigami-cli/src/Shikigami/Cli/Commands/Worker.hs` (the queue worker),
`shikigami-cli/src/Shikigami/Cli/Commands/RunBehavior.hs` (the `run-behavior` CLI command,
which does **not** need a database — useful for validation), and
`shikigami-cli/src/Shikigami/Cli/Commands/AgentRun.hs` (the `agent-run` CLI command, which
goes through `runAgentWithMemory` and needs a Postgres `AppEnv`). The CLI subcommands are
wired in `shikigami-cli/src/Shikigami/Cli.hs` (`run-behavior --agent FILE [--payload JSON]`
and `agent-run --agent NAME|FILE`).

**What "tool registry" means and where it lives.** A *tool* is a named function the model can
ask to run mid-conversation; a *tool registry* is a name-keyed collection of them. shikigami
does not own this abstraction — it lives in the `shikumi-tools` package of the sibling repo
`shinzui/shikumi` (at `/Users/shinzui/Keikaku/bokuno/shikumi`), in module `Shikumi.Tool`:

```haskell
data Tool i o = Tool { ... }          -- a typed tool
data SomeTool = ...                    -- existential wrapper hiding i/o
type ToolRegistry                      -- name-keyed map of SomeTool
mkRegistry      :: [SomeTool] -> ToolRegistry
registryLookup  :: Text -> ToolRegistry -> Maybe SomeTool
registryBaikai  :: ToolRegistry -> Vector Baikai.Tool   -- lower to wire tools for a Context
registryTools   :: ToolRegistry -> [SomeTool]
runToolCall     :: ... -> ToolRegistry -> Baikai.ToolCall -> Eff es ...   -- dispatch one call
```

`registryBaikai` is exactly what converts registered tools into the `Vector Baikai.Tool` that
a baikai `Context`'s `tools` field expects — this is how MCP tools become visible to the model
in the Skill arm. The ReAct agent loop is in `Shikumi.Agent.ReAct` (`react`,
`reactWithTrajectory`, `ReActConfig`).

**Important build fact — restated 2026-08-10, because the shape of it changed.** This paragraph
previously described shikumi and baikai as `source-repository-package` commit pins. That is no
longer true: `docs/plans/47-upgrade-shikigami-to-the-coherent-july-2026-dependency-cohort.md`
moved the whole co-developed cohort onto Hackage versions selected by a `constraints:` block, and
`docs/dependency-cohort.md` is now the contract. So the instruction "do not guess a newer commit
hash" has become "do not add a `source-repository-package` stanza at all" — a co-developed
dependency is selected by released version, and a stanza is admissible only for a package with no
release.

What remains true is the gap itself. `shikigami-core.cabal` depends on `shikumi` but not
`shikumi-tools`, and the constraints block names `shikumi` but not `shikumi-tools`, so this plan
must add the package to both and give it a version bound consistent with the rest of the cohort.
As of 2026-08-10 the shikumi family is released at the 2026-08-07 tags (`shikumi 0.3.0.2`,
`shikumi-tools 0.3.0.2`), and `kioku-core 0.3.0.0` requires `shikumi ^>=0.3.0.1`, so a
`shikumi-tools` bound in that line is coherent.

The baikai half of the gap is unchanged in substance and worse in specificity than it looks:
there is no `Baikai.Mcp.*` module in any released baikai, including `0.5.0.0`. That release added
`Baikai.Agent` and `Baikai.Evidence` — neither is MCP. So there is no version to bump *to*, and
this is a missing contract rather than a stale pin. Wait for baikai C1/C2 (and C3 for
authenticated servers) and select the release that carries them, verified against the registry and
upstream tags, exactly as `docs/dependency-cohort.md` requires.

**The cross-repo surfaces this wires together** (full signatures in Interfaces and
Dependencies):

- baikai `Baikai.Mcp.Client` — `McpServerConfig`, `McpConnection`, `connectMcp`, `closeMcp`
  (defined by C1: `shinzui/baikai:docs/plans/30-mcp-transport-and-json-rpc-client-core.md`).
- baikai `Baikai.Mcp.Tool` — `listTools`, `callTool`, `McpTool` (defined by C2:
  `shinzui/baikai:docs/plans/31-mcp-tool-discovery-and-invocation.md`).
- baikai `Baikai.Mcp.Auth` — `McpAuth` credential vocabulary (defined by C3:
  `shinzui/baikai:docs/plans/32-mcp-authentication-headers-tokens-and-oauth.md`).
- shikumi adapter — `mcpTools` / `registerMcpTools`, which consume an `McpConnection` and
  produce `SomeTool`s named `mcp__<server>__<tool>` in a `ToolRegistry` (defined by C5:
  `shinzui/shikumi:docs/plans/30-mcp-to-tool-adapter-surfacing-mcp-tools-into-the-registry.md`).

**Shared integration contract (normative, from the MasterPlan).** The surfaced tools must be
named `mcp__<server>__<tool>` where `<server>` is the `name` from `McpServerConfig` and
`<tool>` is the MCP tool name; the adapter produces these into shikumi's **existing**
`ToolRegistry`; `connectMcp :: McpServerConfig -> ... -> m McpConnection` is the entry point.
This plan must match those names exactly so it composes with C5 without renegotiation.


## Plan of Work

The work proceeds in five milestones. M1–M2 are additive and verifiable before any baikai/
shikumi MCP code exists (they compile against today's pins, with `mcpServers` simply parsed
and ignored). M3–M5 require the upstream MCP modules and deliver the live behavior. Because
the upstream plans carry **deferred** intentions, M1–M2 may be implemented now and M3–M5
unblocked only when C1/C2/C5 and per-action authorization land (plus C3 for authenticated
servers); the milestones are sequenced so the plan never regresses.

### Milestone 1 — The `mcpServers` schema field (Dhall + Haskell mirror + example)

Scope: extend the declaration surface so an agent file *can carry* MCP server declarations and
the loader decodes them, with no runtime behavior yet. At the end, `schema/Agent.dhall`
exports `McpServer`, `McpTransport`, and `McpAuth`; the `Agent` record has
`mcpServers : List McpServer` defaulting to `[]`; `Shikigami.Api.Agent` has the mirrored
Haskell types and an `mcpServers` field on `AgentDecl`; and an example agent declaring a
server type-checks and loads.

In `schema/Agent.dhall`, add three new definitions before `let Agent`:

```dhall
let McpTransport = < StreamableHttp | Sse >

let McpAuth =
      < None
      | CredentialRef : { reference : Text }
      >

let McpServer =
      { Type =
          { name : Text
          , url : Text
          , transport : McpTransport
          , auth : McpAuth
          }
      , default = { transport = McpTransport.StreamableHttp, auth = McpAuth.None }
      }
```

Then add `mcpServers : List McpServer.Type` to the `Agent` record `Type`, add
`mcpServers = [] : List McpServer.Type` to the `Agent` `default`, and export the three new
names in the final record literal. This is deliberately not a mirror of baikai's resolved
authentication vocabulary: public agent declarations carry references, while the executable
composition root resolves those references into C3's secret-bearing request configuration.

In `shikigami-api/src/Shikigami/Api/Agent.hs`, add the mirrored types and field. Each derives
`FromDhall` (and `ToJSON`/`FromJSON`, matching the module's convention):

```haskell
data McpTransport = StreamableHttp | Sse
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data McpAuth
  = None
  | CredentialRef {reference :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data McpServer = McpServer
  { name :: !Text,
    url :: !Text,
    transport :: !McpTransport,
    auth :: !McpAuth
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)
```

Add `mcpServers :: ![McpServer]` to `AgentDecl` and add `McpServer (..)`, `McpTransport (..)`,
`McpAuth (..)` to the module export list. Note the field name collision: `McpServer.name`
clashes with `AgentDecl.name`. The module already lives with such overlaps (`Trigger`,
`Behavior`, `Sink`, `AgentDecl` all use record field selectors via `DuplicateRecordFields`,
which the existing `Behavior`/`Sink` records rely on); keep using qualified access or
`OverloadedRecordDot` as the surrounding code does. Verify the file still has
`DuplicateRecordFields`/`OverloadedRecordDot` enabled (the existing `Behavior` and `Sink`
unions share field names like `source` and `topic`, so it does).

The loader (`Shikigami/Agent/Loader.hs`) needs no edit — it is generic over `AgentDecl`.
`McpAuth` is safe to render only because it contains a reference, never a secret. The
internal resolved credential/configuration type belongs below plan 37's composition root and
must intentionally omit `Show`, `ToJSON`, and `FromJSON`; error messages mention the
reference name and server name, not credential contents.

Add a server to one existing example and add a new stub example. In
`agents/triage-note.dhall` add (after `sinks`):

```dhall
, mcpServers =
    [ A.McpServer::{ name = "echo", url = "http://127.0.0.1:8765/mcp" } ]
```

Create `agents/proof/mcp-echo.dhall` — a minimal Skill agent declaring one unauthenticated
server, used by the M5 end-to-end test:

```dhall
let A = ../../schema/Agent.dhall
in  A.Agent::{
    , name = "mcp-echo"
    , behavior = A.Behavior.Skill { path = "agents/skills/mcp-echo" }
    , trigger = A.Trigger.Event { eventType = "mcp.demo" }
    , mcpServers =
        [ A.McpServer::{ name = "echo", url = "http://127.0.0.1:8765/mcp" } ]
    }
```

Acceptance: `cabal build all` succeeds; `cabal run shikigami-run-behavior -- --agent
agents/proof/mcp-echo.dhall` loads the manifest without a parse/type error (it may then fail
later for lack of a live server — that is expected at M1 and proves the field parsed). A unit
test in `shikigami-core/test/Main.hs` loads `agents/proof/mcp-echo.dhall` and asserts
`mcpServers` has one entry whose `name == "echo"`.

### Milestone 2 — Build wiring and the registry seam on `BehaviorEnv`

Scope: make `shikumi-tools` and an MCP-capable `baikai` available to `shikigami-core`, and add
an (initially empty) `ToolRegistry` to `BehaviorEnv` threaded through `runBehavior`. At the
end the runtime *carries* a tool registry even though nothing populates it yet.

Use `mori registry show`/`docs` to inspect the exact released baikai and shikumi APIs and
their source. Then verify the chosen release versions against the authoritative package
registry and upstream release tags. Edit the project/package dependency declarations to use
the first coherent released versions that contain `Baikai.Mcp.*`, `shikumi-tools`, and the
adapter; choose bounds from those releases rather than guessing a commit pin from a stale
local corpus. If those releases do not exist, M3–M5 remain blocked instead of consuming an
unreleased or mismatched API.

Edit `shikigami-core/shikigami-core.cabal`: add `shikumi-tools` to the library
`build-depends` (alphabetically near the existing `shikumi`).

Edit `shikigami-core/src/Shikigami/Behavior/Run.hs`:

- Import `Shikumi.Tool (ToolRegistry, mkRegistry)`.
- Coordinate with plan 13 so the final record uses direct `runtime`, `model`, `options`,
  `traces`, and `tools` fields; remove the current `behaviorRuntime`/`behaviorModel` names.
- Add `tools :: !ToolRegistry` to `BehaviorEnv`.
- In `newBehaviorEnv`, initialize it to `mkRegistry []` (empty) so existing callers are
  unaffected.
- In `runBehavior`, pass `tools env` into the `Skill` arm (`runSkill`) and the
  `ShikumiProgram` arm (see M4). Provide a helper to build a *per-run* `BehaviorEnv` whose
  `tools` is replaced — `withTools :: ToolRegistry -> BehaviorEnv -> BehaviorEnv` —
  so M3 can inject the MCP-populated registry without mutating the shared env.

Acceptance: `cabal build all` succeeds with the new dependency; existing tests still pass
(`cabal test shikigami-core`); behavior is unchanged because the registry is empty.

### Milestone 3 — Connect, register, and close in the run lifecycle (bracket)

Scope: at run time, connect each declared MCP server, register its tools into the run's
`ToolRegistry`, run the behavior with that registry, and close every connection afterward —
even on failure. At the end, an agent declaring a (reachable) server has that server's
`mcp__<server>__<tool>` tools present in the registry the behavior runs against, and the
connections are closed when the run returns.

This milestone starts only after the authorization seam is available. Resolve the run's
authenticated principal and authorize each `(principal, server)` before connecting. After
discovery, retain authorization metadata with each registered tool and check
`(principal, server, tool)` again immediately before invocation. Denial is a typed run error,
does not call the remote server, and is recorded without request arguments or credentials.
Resolve `CredentialRef` through plan 37's Settei-owned resolver at the application boundary;
do not pass the agent declaration directly to a function that can read environment variables.

Add to `shikigami-core/src/Shikigami/Agent/Run.hs`:

```haskell
-- Connect every declared and authorized MCP server, register its tools into a fresh registry,
-- run the action with a BehaviorEnv carrying that registry, then close all
-- connections (via bracket, so they close on success and on exception alike).
withAgentMcpTools :: McpRuntime -> Principal -> BehaviorEnv -> AgentDecl -> (BehaviorEnv -> IO a) -> IO a
withAgentMcpTools runtime principal behEnv decl action =
  bracket
    (traverse connectOne (mcpServers decl))      -- acquire: [McpConnection]
    (traverse_ closeMcp)                          -- release: close each
    ( \conns -> do
        reg <- foldM registerMcpTools (mkRegistry []) conns   -- C5 adapter
        action (withTools reg behEnv)
    )
  where
    connectOne server = do
      authorizeServer runtime principal server
      credential <- resolveCredential runtime (auth server)
      connectMcp runtime (toServerConfig server credential)
```

`toServerConfig` consumes the public `McpServer` plus a separately resolved opaque
credential. It copies `name`/`url`, maps `McpTransport`, and hands C3 only the resolved
authentication value; it never accepts raw `Text` secret material. `registerMcpTools` is the
C5 adapter that lists the connection's tools and folds them
into the registry under the `mcp__<server>__<tool>` naming contract.

`McpRuntime` has strict direct fields and owns the Settei-backed credential resolver,
authorization function, and released baikai client. It has no `Show`/JSON instances. In
`runAgentWithMemory`, wrap the existing `runBehavior` call so the registry is live only for
the behavior execution and is torn down with the run:

```haskell
behaviorE <- withAgentMcpTools mcpRuntime principal behEnv decl (\behEnv' -> runBehavior behEnv' decl payload)
```

The surrounding session open/recall/record/complete logic is unchanged; only the
`runBehavior behEnv decl payload` line is replaced. Because `withAgentMcpTools` brackets the
connections around `runBehavior`, both the success arm (`Right output`) and the failure arm
(`Left runErr`) of `runAgentWithMemory` run after the connections are already closed.

Also wrap the `run-behavior` command component assigned to `shikigami-workers` by plan 36 in
`withAgentMcpTools` so MCP tools are exercisable without a database (this is the M5 validation
path). Note in the Decision Log that the same bracket is reused in both entry points.

Acceptance: with a stub MCP server running (see Concrete Steps), `cabal run shikigami --
run-behavior --agent agents/proof/mcp-echo.dhall` logs that it connected to `echo` and
registered N tools, and (with a debug log or the M5 test) `registryNames` includes
`mcp__echo__<tool>`. Killing the run mid-flight or pointing at an unreachable URL closes/does
not leak connections (verify the bracket release runs; a failed connect surfaces as a run
error, not a hang).

### Milestone 4 — Surface `mcp__` tools to the behavior's tool loop

Scope: make the registered tools actually callable by the model. The `Skill` arm currently
runs a single completion with no tools; replace it with a bounded tool loop that offers the
registry's tools and dispatches the model's tool calls. The `ShikumiProgram` arm hands the
registry to the ReAct loop. At the end, an agent's model can request `mcp__echo__<tool>` and
the result flows back into the conversation.

In `shikigami-core/src/Shikigami/Behavior/Skill.hs`, change `runSkill` to take the registry
and loop. Signature becomes `runSkill :: Model -> ToolRegistry -> SkillDir -> Value -> IO
(Either RunError Value)`. Build the `Context` with `tools = registryBaikai reg` (instead of
`V.empty`). Then loop: run `completeRequest`; if the response contains tool-call blocks, for
each `ToolCall` use `Shikumi.Tool.runToolCall reg` to execute it, append the result to the
messages (baikai's `appendToolResult`), and complete again; stop when the model returns text
with no tool calls, or after a fixed maximum number of iterations (e.g. 8) to bound runaway
loops. Return the final assistant text as `{"reply": <text>}` as today. `runToolCall` runs in
shikumi's effect row (`Eff` with `LLM` and `Error ShikumiError`); run it with shikumi's
`runProgram`/runner to get back `IO` — match whatever discharge `shikumi-tools`'
`Shikumi.Agent.ReAct` uses (read `Shikumi.Agent.ReAct.react` for the exact runner).
The registry wrapper checks authorization immediately before `runToolCall`; a previously
authorized connection does not imply permission for every advertised tool. Bound both the
number of iterations and tool-result/request sizes using validated domain values. Logs carry
server/tool names, outcome, duration, and correlation ids only—never tool arguments/results,
authorization headers, credentials, or arbitrary response bodies.

In `shikigami-core/src/Shikigami/Behavior/Run.hs`, update the `Skill` arm to pass
`tools env` and the `ShikumiProgram` arm: if the registry is non-empty, run the
program task via `Shikumi.Agent.ReAct.react` (or `reactWithTrajectory`) configured with the
registry so the program sees the `mcp__` tools; otherwise keep the current `runProgramTask`
path. (The current `ShikumiProgram` arm runs a handan task with a stub; threading the registry
here is the minimal change that makes MCP tools available to program behaviors per the SCOPE's
"and the ShikumiProgram arm where applicable" clause.)

Acceptance: the M5 end-to-end scenario — a `run-behavior` against `agents/proof/mcp-echo.dhall`
with a stub MCP server whose single tool echoes its input, where the (stub or real) model
issues one `mcp__echo__echo` call — returns a `reply` that contains the echoed value, proving
the tool was actually invoked, not merely listed.

### Milestone 5 — End-to-end demonstration and tests

Scope: prove the whole path with an observable scenario and a regression test. At the end
there is a repeatable command that starts a stub MCP server, runs the agent, and shows an
`mcp__` tool being called, plus a test in `shikigami-core/test/Main.hs` that asserts the
registry contains the surfaced tool name and (against an in-memory fake connection) that
`withAgentMcpTools` registers and then closes.

Author a tiny stub MCP server for the test (the simplest streamable-HTTP endpoint that
answers `initialize`, `tools/list` with one `echo` tool, and `tools/call` by echoing) — or, if
baikai C2 ships an in-memory fake `McpConnection` for its own tests, reuse it to drive
`registerMcpTools` directly without a socket. Prefer the in-memory fake for the unit test
(fast, hermetic) and a real stub server for the manual end-to-end transcript.

Acceptance criteria (all observable):
1. `registryNames` of the run's registry includes `mcp__echo__echo`.
2. Running `mcp-echo` produces a `reply` containing the echoed payload (tool invoked).
3. After the run returns, the stub server has received a `close`/the connection is shut (no
   leaked socket) — assert the bracket release ran (e.g. a counter the fake increments on
   close, asserted `== 1`).


## Concrete Steps

All commands run from the repo root `/Users/shinzui/Keikaku/bokuno/shikigami` unless noted.
shikigami uses a Nix dev shell (see `flake.nix`) that provides `ghc-9.12.4`, `cabal`,
`psql`/`createdb`, and `just`. Enter it first if your shell is not already inside it.

Step 1 — confirm the baseline builds and the current schema loads:

```bash
cabal build all
cabal run shikigami-run-behavior -- --agent agents/proof/heartbeat.dhall
```

Expected: a JSON result value printed (the heartbeat program's output), proving the toolchain
and loader work before any edits.

Step 2 — after the M1 edits, type-check the new schema and example without building Haskell.
If the `dhall` CLI is on PATH (it is a build dependency, so available in the dev shell):

```bash
dhall type --file agents/proof/mcp-echo.dhall
```

Expected: the inferred record type prints, including `mcpServers : List …` — no type error.
If `dhall` is not on PATH, instead run the loader path:

```bash
cabal run shikigami-run-behavior -- --agent agents/proof/mcp-echo.dhall
```

Expected at M1: the manifest parses (no `LoadError`); it then fails later because no server is
running — that downstream failure still proves `mcpServers` decoded.

Step 3 — after M2, rebuild with the new deps and run the existing tests:

```bash
cabal build all
cabal test shikigami-core
```

Expected: build succeeds with `shikumi-tools` now a dependency; all existing tests pass
(behavior unchanged, registry empty).

Step 4 — after M3–M4, run the end-to-end scenario. In one terminal start the stub MCP server
(the test helper from M5; adjust the launch command to whatever the helper exposes):

```bash
cabal run shikigami-mcp-stub -- --port 8765    # the M5 stub server (name it in the .cabal)
```

In a second terminal run the agent against it:

```bash
cabal run shikigami-run-behavior -- --agent agents/proof/mcp-echo.dhall \
  --payload '{"text":"hello mcp"}'
```

Expected transcript (shape):

```text
connected mcp server: echo (http://127.0.0.1:8765/mcp)
registered 1 mcp tool(s): mcp__echo__echo
{"reply":"echo: hello mcp"}
closed mcp server: echo
```

Step 5 — run the regression test:

```bash
cabal test shikigami-core
```

Expected: the new `Mcp` test group passes — registry contains `mcp__echo__echo`, the run
returns the echoed reply, and the fake connection's close-counter is `1`.


## Validation and Acceptance

The change is validated by behavior, not compilation. The acceptance scenario:

Given `agents/proof/mcp-echo.dhall` declaring one MCP server `echo` with a single `echo`
tool, an explicit test grant for the run principal, and the stub MCP server running on
`127.0.0.1:8765`, when an operator runs
`cabal run shikigami-run-behavior -- --agent agents/proof/mcp-echo.dhall --payload
'{"text":"hello mcp"}'`, then:

- the runtime connects to `echo` and registers its tool as `mcp__echo__echo` (observable in
  the log line and assertable via `registryNames`);
- the model issues a `mcp__echo__echo` tool call and the run's final output
  `{"reply": …}` contains the echoed text `hello mcp`, proving the tool was *invoked*, not
  merely advertised;
- after the command returns, the stub reports the connection closed (close-counter `== 1`),
  proving the bracket released even though the run was a normal success; and a second run
  against an **unreachable** URL fails cleanly with a run error and still closes/never opens a
  leaked connection.

Automated checks (exact commands): `cabal build all`; `cabal test shikigami-core` (the new
`Mcp` test group asserts the three criteria in M5 against an in-memory fake `McpConnection`,
so the suite is hermetic and needs no network). The pre/post contrast that proves
effectiveness: before this plan, `runSkill` builds a `Context` with `tools = V.empty` and runs
a single completion, so no MCP tool can ever appear or be called; after it, the same agent's
registry contains `mcp__echo__echo` and the reply embeds the tool's output.

Security acceptance is explicit: a declared-but-unauthorized server is never connected; an
unauthorized tool is never invoked even if discovery advertises it; a missing credential
reference fails before connect; and captured logs, JSON encodings, validation output, and run
errors contain neither secret values nor tool arguments/results.


## Idempotence and Recovery

The schema and Haskell edits are additive and idempotent: re-applying them is a no-op, and an
agent file with no `mcpServers` field uses the `[]` default, so existing agents are unaffected
and need no migration. Re-running `cabal build` / `cabal test` is always safe.

Connecting MCP servers is the only side-effecting step, and it is bracketed: a partial failure
(some servers connect, one fails) tears down the already-opened connections via the `bracket`
release before propagating the error, so no sockets leak and a retry starts from a clean
state. A run that fails inside the behavior still closes connections (the failure arm runs
after release). Re-running a failed agent run is safe — connections are per-run, so there is no
stale shared state to reset; just fix the URL/credentials/stub and run again.

Rollback: because the field defaults to `[]` and the registry defaults to empty, removing the
`mcpServers` entry from an agent file (or reverting the M3/M4 wiring) returns the runtime to
its prior single-completion behavior with no schema migration.


## Portfolio Reconciliation (2026-07-30)

This note supersedes older dependency-version and placeholder-API wording in this plan.

- Startable slice: M1-M2 may land after plans 36, 37, and 47; follow plan 33's additive
  declaration-field pattern when it is available.
- Blocked slice: M3-M5 require Baikai IR-2, Shikumi IR-1, and Kikan-En IR-3
  (`mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-3`). The current
  released Baikai/Shikumi sources do not expose the named MCP modules, and a declaration is
  never authorization.
- Authenticated declarations carry only a Settei-resolved credential reference. Raw headers,
  tokens, OAuth secrets, and authorization decisions never enter Dhall or journaled values.
- Implement against the released upstream signatures after the requests land; illustrative
  signatures earlier in this plan are not compatibility shims.


## Portfolio Reconciliation (2026-08-05)

The tool catalog this plan declares becomes audit evidence. `AgentArtifactSet` in
`docs/plans/49-sanctioned-execution-profile-and-attestation-contracts.md` binds a run to a
tool-catalog digest, and
`docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md` judges a run against it, so a
verifier outside this system will later prove that the agent's tools were exactly these. A digest
is only meaningful over a **stable canonical encoding**: the same declared catalog must serialise
to the same bytes across processes, library upgrades, and map-ordering changes. This plan owns that
encoding — commit to one explicitly rather than relying on whatever `toJSON` happens to emit, and
treat a change to it as a wire-format change with a schema-version bump, not an edit. Nothing else
about this plan changes.


## Interfaces and Dependencies

**Owned and defined by this plan (shikigami).**

- `schema/Agent.dhall`: new `McpTransport`, `McpAuth`, `McpServer` types and an
  `mcpServers : List McpServer.Type` field (default `[]`) on `Agent`, all exported.
- `shikigami-api/src/Shikigami/Api/Agent.hs`: mirrored `McpTransport`, `McpAuth`, `McpServer`
  Haskell types and `mcpServers :: ![McpServer]` on `AgentDecl`. Public `McpAuth` is
  reference-only and may derive Dhall/JSON; the internal resolved credential does not derive
  `Show` or JSON instances.
- `shikigami-core/src/Shikigami/Behavior/Run.hs`: `BehaviorEnv` gains
  `tools :: !ToolRegistry`; `withTools :: ToolRegistry -> BehaviorEnv -> BehaviorEnv`;
  `newBehaviorEnv` initializes the registry to `mkRegistry []`.
- `shikigami-core/src/Shikigami/Agent/Run.hs`:
  `McpRuntime` (credential resolver, authorization, released client),
  `withAgentMcpTools :: McpRuntime -> Principal -> BehaviorEnv -> AgentDecl ->
  (BehaviorEnv -> IO a) -> IO a`, and
  `toServerConfig :: McpServer -> ResolvedCredential -> McpServerConfig`;
  `runAgentWithMemory`
  wraps `runBehavior` in `withAgentMcpTools`.
- `shikigami-core/src/Shikigami/Behavior/Skill.hs`: `runSkill :: Model -> ToolRegistry ->
  SkillDir -> Value -> IO (Either RunError Value)` with a bounded tool loop using
  `registryBaikai` (to offer tools) and `runToolCall` (to dispatch).
- The worker, `run-behavior`, and `agent-run` executable components live in
  `shikigami-workers` after plan 36; legacy `shikigami-cli` paths in Context describe the
  starting tree only and are not target locations.

**Consumed from baikai (hard dep C1+C2; C3 hard for authenticated servers).** Module
namespace `Baikai.Mcp`, using a coherent published release verified against the package
registry and upstream tags after inspecting its source/docs through Mori:

- `Baikai.Mcp.Client` — `data McpServerConfig` (`name`, `url`, `transport`, `auth`),
  `data McpConnection`, `connectMcp :: McpServerConfig -> … -> m McpConnection`,
  `closeMcp :: McpConnection -> … -> m ()`. Source of truth:
  `shinzui/baikai:docs/plans/30-mcp-transport-and-json-rpc-client-core.md` (C1).
- `Baikai.Mcp.Tool` — `data McpTool`, `listTools :: McpConnection -> m [McpTool]`,
  `callTool :: McpConnection -> McpToolCall -> m McpToolResult`. Source of truth:
  `shinzui/baikai:docs/plans/31-mcp-tool-discovery-and-invocation.md` (C2, hard).
- `Baikai.Mcp.Auth` — `data McpAuth` credential vocabulary (static headers/tokens, OAuth).
  Source of truth: `shinzui/baikai:docs/plans/32-mcp-authentication-headers-tokens-and-oauth.md`
  C3 is required before any declaration using `CredentialRef` can run; `McpAuth.None`
  supports the unauthenticated proof only.

**Consumed from shikumi (hard dep C5).** Package `shikumi-tools` (add to `cabal.project`
subdir list and to `shikigami-core.cabal` build-depends):

- `Shikumi.Tool` — `type ToolRegistry`, `mkRegistry :: [SomeTool] -> ToolRegistry`,
  `registryBaikai :: ToolRegistry -> Vector Baikai.Tool`,
  `registryLookup :: Text -> ToolRegistry -> Maybe SomeTool`,
  `registryNames :: ToolRegistry -> [Text]`, `runToolCall :: …`.
- The C5 adapter — `registerMcpTools :: ToolRegistry -> McpConnection -> IO ToolRegistry`
  (and/or `mcpTools :: McpConnection -> IO [SomeTool]`), producing tools named
  `mcp__<server>__<tool>` per the MasterPlan contract. Source of truth:
  `shinzui/shikumi:docs/plans/30-mcp-to-tool-adapter-surfacing-mcp-tools-into-the-registry.md`.
  (Match the adapter's final signature when C5 lands; the fold in `withAgentMcpTools` adapts
  to either the registry-threading or list form.)

**Hard prerequisite for M3–M5.** Authorization of which MCP servers/tools an agent may use
flows through the per-action authz seam owned by `shinzui/en` /
`shinzui/shomei` — plan
`shinzui/en:docs/plans/27-per-action-authorization-for-agent-tool-and-sink-dispatch.md`, the
"C13" seam recorded in
`shinzui/kikan:docs/architecture/evolution/agent-infrastructure-gaps.md` (gap #7), exposed
to this runtime through Kikan-En IR-3 at
`mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-3`. Check the
server before connection and each tool before dispatch. A manifest declaration never grants
authority.

**Local platform prerequisites.** HARD depends on
docs/plans/36-align-shikigami-with-the-six-package-deployed-service-architecture.md for API,
application, infrastructure, and executable ownership. HARD depends on
docs/plans/37-adopt-settei-configuration-across-shikigami-binaries.md for a single startup
configuration and secret/reference resolution boundary; no library module calls
`lookupEnv` or stores raw credentials in a public record.

**Build/test toolchain.** Nix dev shell from `flake.nix` (`ghc-9.12.4`, `cabal`, `dhall`,
`just`, Postgres client). Build: `cabal build all`. Test: `cabal test shikigami-core`. Manual
end-to-end: `cabal run shikigami-run-behavior -- --agent <file> [--payload <json>]` (no DB
required) or `cabal run shikigami-agent-run -- --agent <name>` (DB-backed via `just
create-database` first). Dhall type-check: `dhall type --file <agent>.dhall`.


---

Revision note (2026-06-27): Initial authoring of this ExecPlan as MasterPlan child C6.
Sections filled from the current shikigami working tree (schema/Agent.dhall five-field `Agent`
record; `BehaviorEnv`/`runBehavior` with no registry; `runSkill` single completion;
`runAgentWithMemory` run lifecycle), the MasterPlan
`shinzui/baikai:docs/masterplans/6-mcp-support-across-the-agent-stack.md` integration contract
(the `mcp__<server>__<tool>` naming, `connectMcp`/`McpServerConfig`, `Baikai.Mcp.*` layout),
and the gap analysis `shinzui/kikan:docs/architecture/evolution/agent-infrastructure-gaps.md`
(gap #6 places per-agent MCP declaration here; gap #7 originally deferred authz). The
2026-07-22 review makes that authorization seam a hard live-wiring prerequisite. Key grounded discovery
recorded as a build fact: shikigami currently pins `shikumi` without `shikumi-tools` and
`baikai` at a pre-`Baikai.Mcp` commit, so M2 must add `shikumi-tools` and move to a verified
coherent published release.
Frontmatter left untouched per instruction.

Revision note (2026-07-22): Made upstream authorization a hard prerequisite for live MCP
wiring, replaced manifest secrets with Settei-resolved credential references, prohibited
secret rendering/JSON/logging, and required released dependency verification via Mori plus
authoritative registries/tags. Added plans 36/37 package and configuration prerequisites.

Revision note (2026-07-30): Repointed the live authorization prerequisite to
Kikan-En IR-3, the current OKF-profile request for per-action MCP connection
and exact tool invocation. M1–M2 remain startable; M3–M5 remain blocked.

Revision note (2026-08-10): Re-verified the three upstream gates and corrected a build fact that
had gone stale.

All three gates are still closed, and the check is recorded with its date so the next reader
re-checks rather than trusts it. Baikai has no `Baikai.Mcp.*` module in any released version
including `0.5.0.0` — that release added `Baikai.Agent` and `Baikai.Evidence`, neither of which is
MCP — so this is a missing contract, not a stale pin, and there is no version to bump to. The
shikumi package set at its 2026-08-07 tags contains no MCP adapter. Kikan-En IR-3 remains
`proposed`. M1–M2 stay startable and are now called out as such explicitly, since nothing local
depends on any of the three.

The build fact was rewritten because the repository changed underneath it. It described shikumi
and baikai as `source-repository-package` commit pins and told the implementer not to guess a
newer commit hash. Plan 47 moved the entire co-developed cohort onto Hackage versions selected by
a `constraints:` block, with `docs/dependency-cohort.md` as the contract, so the correct
instruction is now not to add a `source-repository-package` stanza at all. The underlying gap is
unchanged: `shikumi-tools` is in neither the constraints block nor `shikigami-core.cabal`, and
this plan must add it — at a bound coherent with the released family, which as of 2026-08-10 is
`0.3.0.2` and satisfies `kioku-core 0.3.0.0`'s `shikumi ^>=0.3.0.1`.
