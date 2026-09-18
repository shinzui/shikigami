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
  )
where

import Options.Applicative
import Shikigami.Agent.Command.AgentRun (runAgentRun)
import Shikigami.Agent.Command.RunBehavior (runRunBehavior)
import Shikigami.App.Config (Role (..))
import Shikigami.App.Config.Load (withConfigOptions)
import Shikigami.App.Role (RoleInfo (..), runRole)

-- | Every one-off executable, in the order they are documented.
--
-- Exists so a test can assert that each one's @--help@ works and keeps its
-- flags, and so adding a role forces a decision about its name.
agentRoles :: [RoleInfo]
agentRoles =
  [ runBehaviorRoleInfo,
    agentRunRoleInfo
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
              <*> optional (strOption (long "payload" <> metavar "JSON" <> help "Trigger payload as JSON"))
              <*> optional (strOption (long "workspace" <> metavar "DIR" <> help "Git worktree for requested capability overlays"))
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
agentRunRoleInfo =
  RoleInfo
    { binaryName = "shikigami-agent-run",
      role = AgentRunRole,
      parserInfo =
        withConfigOptions
          "shikigami-agent-run"
          "Run an agent with the durable workflow and kioku memory lifecycle"
          ( runAgentRun
              <$> strOption (long "agent" <> metavar "NAME|FILE" <> help "Agent name (agents/<name>.dhall) or manifest path")
              <*> optional (strOption (long "from-activity" <> metavar "FILE" <> help "Record an activity.v1 envelope as a memory instead of running"))
              <*> optional (strOption (long "workspace" <> metavar "DIR" <> help "Git worktree for requested capability overlays"))
          )
          (pure [])
    }
