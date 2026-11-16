-- | Command-line surfaces of the one-off agent executables.
--
-- Shikigami is usable two ways. The deployed service runs supervised background
-- loops against Kafka, PGMQ, and Postgres; those live in @shikigami-workers@.
-- This package is the other way: a consumer who is not running the Kikan
-- platform takes a declared agent and runs it once, from a command line.
--
-- That is why the package exists at all. Both commands below used to live in
-- @shikigami-workers@, and every executable in that package depends on its whole
-- library, so @shikigami-run-behavior@ — documented as running with no database
-- and no key — linked a Kafka client, a PGMQ adapter, and an OTLP exporter. The
-- package boundary is the mechanism that keeps that from coming back:
-- @shikigami-agent@ depends on @shikigami-core@ and nothing else, and
-- "Shikigami.PackageArchitectureSpec" fails if that changes.
--
-- Configuration reaches these roles exactly as it reaches a worker role, through
-- 'Shikigami.App.Role.runRole' in @shikigami-core@: parse, resolve, act. Sharing
-- that function rather than copying it is what keeps @--check-config@ meaning
-- the same thing in both packages.
module Shikigami.Agent.Command
  ( -- * Roles
    RoleInfo (..),
    agentRoles,
    runRole,

    -- * The individual roles
    runBehaviorRoleInfo,
    agentRunRoleInfo,
    agentRunRoleInfoWith,
    localRoleInfo,
  )
where

import Data.Text qualified as Text
import Options.Applicative
import Shikigami.Agent.Command.AgentRun (runAgentRun)
import Shikigami.Agent.Command.Doctor (runDoctor)
import Shikigami.Agent.Command.Local (LedgerOptions (..), LocalCommand (..), runLocal)
import Shikigami.Agent.Command.LocalRuns (RunsQuery (..), runLocalRuns)
import Shikigami.Agent.Command.Routine (NewRoutine (..), RunRoutine (..), runNewRoutine, runRoutine)
import Shikigami.Agent.Command.RunBehavior (runRunBehavior)
import Shikigami.Agent.Command.Up (UpOptions (..), runUp)
import Shikigami.Agent.Payload (payloadArgument)
import Shikigami.App.Config (Role (..))
import Shikigami.App.Config.Load (withConfigOptions)
import Shikigami.App.Role (RoleInfo (..), runRole)
import Shikigami.Flow.Pack (FlowPack)

-- | Every one-off executable, in the order they are documented.
--
-- Exists so a test can assert that each one's @--help@ works and keeps its
-- flags, and so adding a role forces a decision about its name.
agentRoles :: [RoleInfo]
agentRoles =
  [ runBehaviorRoleInfo,
    agentRunRoleInfo,
    localRoleInfo
  ]

-- | @shikigami-run-behavior@: run one agent's behavior, with no database.
--
-- The manifest path and the payload are per-invocation arguments; the only
-- configuration it reads is which model provider to run. That makes it both the
-- offline default (stubs, no key, no database) and the cheapest live check of a
-- real provider, depending on nothing but @behavior.provider@.
runBehaviorRoleInfo :: RoleInfo
runBehaviorRoleInfo =
  RoleInfo
    { binaryName = "shikigami-run-behavior",
      role = RunBehaviorRole,
      parserInfo =
        withConfigOptions
          "shikigami-run-behavior"
          "Run an agent's behavior once, with no database and no recalled memory"
          ( runRunBehavior
              <$> strOption (long "agent" <> metavar "FILE" <> help "Agent manifest (.dhall)")
              <*> payloadArgument
              <*> optional (strOption (long "workspace" <> metavar "DIR|mori://…" <> help "Repository for requested capability overlays: a checkout path or a Mori identity"))
              <*> switch (long "no-confirm" <> help "Never ask to grant a declaration; use only stored or file grants")
          )
          (pure [])
    }

-- | @shikigami-agent-run@: run one agent through the durable workflow lifecycle.
--
-- Unlike 'runBehaviorRoleInfo' this one does open a database, because a session
-- and its memories are the point. It stays in this package anyway: \"light\"
-- here means it does not link the platform's messaging, queueing, and telemetry
-- export stack, not that it has no dependencies.
agentRunRoleInfo :: RoleInfo
agentRunRoleInfo = agentRunRoleInfoWith []

-- | The same role composed with flow packs beside the builtin pack. Only a
-- distribution package calls this with a non-empty list (docs/adr/0129); the
-- stock executable composes none, which is why it refuses a pack's agent.
agentRunRoleInfoWith :: [FlowPack] -> RoleInfo
agentRunRoleInfoWith packs =
  RoleInfo
    { binaryName = "shikigami-agent-run",
      role = AgentRunRole,
      parserInfo =
        withConfigOptions
          "shikigami-agent-run"
          "Run an agent with the durable workflow and kioku memory lifecycle"
          ( runAgentRun packs
              <$> strOption (long "agent" <> metavar "NAME|FILE" <> help "Agent name (agents/<name>.dhall) or manifest path")
              <*> optional (strOption (long "from-activity" <> metavar "FILE" <> help "Record an activity.v1 envelope as a memory instead of running"))
              <*> optional (strOption (long "workspace" <> metavar "DIR|mori://…" <> help "Repository for requested capability overlays: a checkout path or a Mori identity"))
              <*> payloadArgument
              <*> switch (long "no-confirm" <> help "Never ask to grant a declaration; use only stored or file grants")
              <*> optional (strOption (long "resume" <> metavar "WORKFLOW_ID" <> help "Continue an interrupted run of this agent from its journal; an in-flight coding agent is reattached, never relaunched"))
          )
          (pure [])
    }

-- | @shikigami-local@: what the local operator granted and what their agents
-- did, under the @local-operator@ trust tier.
localRoleInfo :: RoleInfo
localRoleInfo =
  RoleInfo
    { binaryName = "shikigami-local",
      role = LocalRole,
      parserInfo =
        withConfigOptions
          "shikigami-local"
          "Inspect local-operator grants and the action record"
          (subparser (newRoutine <> runRoutineCommand <> runsCommand <> doctor <> up) <|> (runLocal <$> subparser (approvals <> revoke <> ledger <> tools <> mcp <> gate <> toolAttempt <> playbook)))
          (pure [])
    }
  where
    tools =
      command
        "tools"
        ( info
            ( CheckTools
                <$> strArgument (metavar "AGENT.dhall" <> help "The declaration whose tools to check")
                <*> optional (strOption (long "workspace" <> metavar "DIR|mori://…" <> help "The repository it would run in (default: the current directory)"))
            )
            (progDesc "Check a declaration's CLI tools: located, within any ceiling, and granted (exit 0), awaiting confirmation (3) or refused (1)")
        )
    mcp =
      command
        "mcp"
        ( info
            ( DiscoverMcp . Text.pack
                <$> strArgument (metavar "SERVER" <> help "A server bound in the tools file")
                <*> optional (strOption (long "workspace" <> metavar "DIR|mori://…" <> help "The repository to start it in (default: the current directory)"))
            )
            (progDesc "Connect to a bound MCP server and list its tools as approved, approved-schema-changed or not approved")
        )
    newRoutine =
      command
        "new"
        ( info
            ( fmap
                runNewRoutine
                ( NewRoutine . Text.pack
                    <$> strArgument (metavar "NAME" <> help "The agent's name")
                    <*> switch (long "coder" <> help "A Claude Code coding agent instead of a Skill")
                    <*> optional (Text.pack <$> strOption (long "every" <> metavar "CRON" <> help "Run on this schedule instead of by hand"))
                )
            )
            (progDesc "Write a routine agent's declaration and skill under ~/.config/shikigami/agents")
        )
    runRoutineCommand =
      command
        "run"
        ( info
            ( fmap
                runRoutine
                ( RunRoutine
                    <$> strArgument (metavar "AGENT" <> help "A routine agent's name, or a declaration path")
                    <*> many (Text.pack <$> strArgument (metavar "TASK…" <> help "What to do this time; becomes the payload's task"))
                    <*> optional (strOption (long "in" <> metavar "DIR|mori://…" <> help "The repository (default: the current checkout)"))
                    <*> switch (long "no-confirm" <> help "Never ask; use only stored or file grants")
                )
            )
            (progDesc "Run a routine agent in this repository under the local-operator tier")
        )
    up =
      command
        "up"
        ( info
            (runUp . UpOptions <$> optional (option auto (long "for" <> metavar "MINUTES" <> help "Stop after this many minutes")))
            (progDesc "Run scheduled routine agents on this machine: arms each agent with a stored approval and says why the others are not armed")
        )
    doctor = command "doctor" (info (pure runDoctor) (progDesc "Check every prerequisite of routine agents; each failure names its fix"))
    runsCommand =
      command
        "runs"
        ( info
            ( fmap
                runLocalRuns
                ( RunsQuery
                    <$> optional (Text.pack <$> strArgument (metavar "RUN-ID" <> help "Show one run's record and outputs"))
                    <*> option auto (long "limit" <> metavar "N" <> value 20 <> help "How many recent runs (default 20)")
                )
            )
            (progDesc "List recent runs with outcome, decisions and report, or show one run")
        )
    toolAttempt =
      command
        "tool-attempt"
        ( info
            ( ToolAttempt
                <$> option auto (long "deadline-seconds" <> metavar "N")
                <*> option auto (long "output-limit" <> metavar "BYTES")
                <*> strOption (long "stdout" <> metavar "FILE")
                <*> strOption (long "stderr" <> metavar "FILE")
                <*> strArgument (metavar "PROGRAM")
                <*> many (Text.pack <$> strArgument (metavar "ARG…"))
            )
            (progDesc "Internal: run one declared command for a durable step and print its result")
        )
    playbook =
      command
        "playbook"
        ( info
            (hsubparser (command "validate" (info (ValidatePlaybook <$> strArgument (metavar "BUNDLE.dhall")) (progDesc "Load and check a playbook bundle and print its step tree"))))
            (progDesc "Work with playbook bundles")
        )
    gate = command "gate" (info (Gate <$> strArgument (metavar "TOOLS.json" <> help "The run's declared tools, written by the coding-agent runner")) (progDesc "Claude Code's PreToolUse hook: allow or deny one call against a run's declared tools"))
    approvals =
      command
        "approvals"
        ( info
            ( hsubparser
                ( command "pending" (info (pure PendingApprovals) (progDesc "List the asks waiting in the local approval inbox"))
                    <> command "resolve" (info (ResolveApproval . Text.pack <$> strArgument (metavar "REVIEW-ID") <*> optional (Text.pack <$> strOption (long "reject" <> metavar "REASON" <> help "Reject instead of approving"))) (progDesc "Approve (or reject) one ask; then continue the run with --resume"))
                )
                <|> pure ShowApprovals
            )
            (progDesc "Validate the approvals file and list every grant; or `pending` / `resolve` approval asks")
        )
    revoke = command "revoke" (info (RevokeGrant . Text.pack <$> strArgument (metavar "DIGEST" <> help "At least eight characters of a stored grant's digest")) (progDesc "Delete a stored confirmation"))
    ledger =
      command
        "ledger"
        ( info
            ( fmap
                Ledger
                ( LedgerOptions
                    <$> optional (Text.pack <$> strOption (long "run" <> metavar "WORKFLOW-ID" <> help "Only events of this run"))
                    <*> switch (long "refusals" <> help "Only decisions that did not allow")
                    <*> optional (option auto (long "limit" <> metavar "N" <> help "Most recent N events (1-1000, default 50)"))
                    <*> switch (long "json" <> help "Print JSON Lines")
                )
            )
            (progDesc "Print the action record, oldest first")
        )
