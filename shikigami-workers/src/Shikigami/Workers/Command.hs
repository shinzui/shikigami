-- | Command-line surfaces of the worker-role executables.
--
-- Each worker role is its own binary — @shikigami-worker@,
-- @shikigami-scheduler@, @shikigami-workspace-supervisor@ — because an operator scales, restarts, and rolls them out independently, and
-- because a single umbrella process could not honestly import both server and
-- worker implementations without violating the package dependency graph.
--
-- The stream and event consumers are not stock roles. They link a Kafka
-- client and consume the Kawa activity stream, so they are the Kikan
-- distribution's @kikan-shikigami-consume-stream@ and
-- @kikan-shikigami-consume-events@ (plan 135, M5; the binding's @intake@
-- library).
--
-- The two one-off commands that used to live here, @shikigami-run-behavior@ and
-- @shikigami-agent-run@, moved to @shikigami-agent@. They never needed anything
-- this package links — Kafka, PGMQ, Shibuya, the OTLP exporter — but every
-- executable here depends on the whole library, so they linked all of it. Adding
-- a one-off command to this module puts that back; add it to
-- "Shikigami.Agent.Command" instead.
--
-- == How configuration reaches a role
--
-- Every role's parser produces a pair: the action to run, which takes the
-- resolved 'AppConfig', and the command-line configuration
-- sources its own flags supplied. The flags an operator already knows —
-- @--agents@ and the rest —
-- survive, but as ordinary Settei sources aimed at declared keys rather than as
-- private parsers. @--agents agents@ and
-- @--set agents.directory=agents@ are the same thing, both appear in
-- @--explain-config@ with their spelling, and neither can disagree with the
-- other about what the default is.
--
-- 'runRole' is the whole of each executable's @main@: parse, resolve, act. That
-- ordering is what makes @--check-config@ honest — configuration is fully
-- resolved and the role's required keys are checked before the action opens a
-- database, joins a consumer group, or registers a processor.
--
-- Every parser has the same result type, which is exactly why a dropped or
-- misrouted flag is invisible to the type checker; 'workerRoles' exists so a
-- test can drive every parser without listing it a second time.
module Shikigami.Workers.Command
  ( -- * Roles
    RoleInfo (..),
    workerRoles,
    runRole,

    -- * The individual roles
    workerRoleInfo,
    workerRoleInfoWith,
    workspaceSupervisorRoleInfo,
    workspaceSupervisorRoleInfoWith,
    schedulerRoleInfo,
    schedulerRoleInfoWith,
  )
where

import Data.Maybe (catMaybes)
import Options.Applicative
import Settei.Optparse (namedOption)
import Settei.Source (Source)
import Shikigami.App.Config
  ( AppConfig,
    Role (..),
    agentsDirectoryKey,
  )
import Shikigami.App.Config.Load (withConfigOptions)
import Shikigami.App.Role (RoleInfo (..), runRole)
import Shikigami.Flow.Pack (FlowPack (..))
import Shikigami.Workers.Command.Scheduler (runSchedulerCmd)
import Shikigami.Workers.Command.Worker (runResumeCmd, runWorkerCmd)
import Shikigami.Workspace.Daemon (runWorkspaceSupervisor)
import Shikigami.Workspace.Maintenance (WorkspaceMaintenance (..), runWorkspaceMaintenance)

-- | Every worker executable, in the order they are documented.
--
-- Exists so a test can assert that each one's @--help@ works and keeps its
-- flags, and so adding a role forces a decision about its name.
workerRoles :: [RoleInfo]
workerRoles =
  [ workerRoleInfo,
    schedulerRoleInfo,
    workspaceSupervisorRoleInfo
  ]

-- ── The roles ───────────────────────────────────────────────────────────────

-- | @shikigami-worker@: drain the run-job queue and run agents end to end.
workerRoleInfo :: RoleInfo
workerRoleInfo = workerRoleInfoWith []

-- | The worker composed with flow packs beside the builtin pack. Only a
-- distribution package passes a non-empty list (docs/adr/0129).
workerRoleInfoWith :: [FlowPack] -> RoleInfo
workerRoleInfoWith packs =
  RoleInfo
    { binaryName = "shikigami-worker",
      role = WorkerRole,
      packSettings = concatMap (.settings) packs,
      parserInfo =
        withConfigOptions
          "shikigami-worker"
          "Drain shikigami_run_jobs: run each agent, deliver its outputs, record the session"
          (workerAction packs)
          (sourcesOf [agentsOption])
    }

-- | @shikigami-scheduler@: arm Schedule triggers and drive timer firing.
schedulerRoleInfo :: RoleInfo
schedulerRoleInfo = schedulerRoleInfoWith []

-- | The scheduler composed with flow packs, whose schedule hooks decide
-- whether a due tick runs under an enrolled resource root.
schedulerRoleInfoWith :: [FlowPack] -> RoleInfo
schedulerRoleInfoWith packs =
  RoleInfo
    { binaryName = "shikigami-scheduler",
      role = SchedulerRole,
      packSettings = concatMap (.settings) packs,
      parserInfo =
        withConfigOptions
          "shikigami-scheduler"
          "Arm Schedule triggers and drive keiro timer firing"
          (pure (runSchedulerCmd packs))
          (sourcesOf [agentsOption])
    }

-- ── Command-line configuration sources ──────────────────────────────────────

-- | Collect the flags that were actually given. An absent flag contributes no
-- source, which is what leaves a configuration file, the environment, or the
-- declared default in place.
sourcesOf :: [Parser (Maybe Source)] -> Parser [Source]
sourcesOf parsers = catMaybes <$> sequenceA parsers

agentsOption :: Parser (Maybe Source)
agentsOption =
  namedOption
    "--agents"
    agentsDirectoryKey
    (long "agents" <> metavar "DIR" <> help "Agents manifest directory (sets agents.directory)")

-- Bounded maintenance stays in the resource-owning worker binary; the embedded
-- server hook cannot interpret the application's Kioku effect row.
workerAction :: [FlowPack] -> Parser (AppConfig -> IO ())
workerAction packs = workspaceMaintenanceAction packs <|> resumeAction packs

workspaceMaintenanceAction :: [FlowPack] -> Parser (AppConfig -> IO ())
workspaceMaintenanceAction packs =
  runWorkspaceMaintenance (concatMap (.authorities) packs)
    <$> strOption (long "workspace-actor" <> metavar "PRINCIPAL" <> help "Active principal requiring fresh exact maintenance authority")
    <*> ( (ListWorkspaces <$> (flag' () (long "workspace-list" <> help "List at most 20 retained workspaces") *> optional (strOption (long "workspace-after" <> metavar "RESOURCE"))))
            <|> (CleanupWorkspace <$> strOption (long "workspace-cleanup" <> metavar "RESOURCE" <> help "Remove the exact terminal workspace files and scratch; retain receipts"))
        )

resumeAction :: [FlowPack] -> Parser (AppConfig -> IO ())
resumeAction packs =
  choose
    <$> optional (option positiveInt (long "resume-passes" <> metavar "N" <> help "Preview bounded workflow resume; use --force to advance"))
    <*> option positiveInt (long "resume-limit" <> value 100 <> metavar "N" <> help "Maximum candidates per bounded resume pass")
    <*> switch (long "force" <> help "Execute the bounded resume action")
  where
    choose Nothing _ _ = runWorkerCmd packs
    choose (Just passes) candidates force = runResumeCmd packs passes candidates force
    positiveInt = eitherReader \raw -> case reads raw of
      [(value, "")] | value > 0 -> Right value
      _ -> Left "expected a positive integer"

-- Socket activation and factual receipt recovery have an independent lifetime.
workspaceSupervisorRoleInfo :: RoleInfo
workspaceSupervisorRoleInfo = workspaceSupervisorRoleInfoWith []

-- | The workspace supervisor composed with packs, so it decides protected
-- actions with the authority a pack registers (the Kikan binding's, under
-- the Kikan distribution).
workspaceSupervisorRoleInfoWith :: [FlowPack] -> RoleInfo
workspaceSupervisorRoleInfoWith packs =
  RoleInfo
    "shikigami-workspace-supervisor"
    WorkspaceSupervisorRole
    (concatMap (.settings) packs)
    (withConfigOptions "shikigami-workspace-supervisor" "Supervise governed workspace processes and recover original receipts" (pure (runWorkspaceSupervisor (concatMap (.authorities) packs))) (pure []))
