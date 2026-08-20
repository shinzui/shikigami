module Shikigami.Workers.Command.Worker
  ( runWorkerCmd,
  )
where

import Baikai.Trace.Sink.OpenTelemetry (otelSink)
import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Kioku.App (AppEnv (..))
import Kiroku.Store.Connection qualified as StoreConnection
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (loadAgentsIn)
import Shikigami.App.Config (AppConfig)
import Shikigami.App.Config qualified as Config
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Behavior.Provider (newBehaviorEnvFor)
import Shikigami.Flow (flowDeclarationErrors)
import Shikigami.Log qualified as Log
import Shikigami.Sink (DanwaConfig (..), GrantSource (DbGrants), KawaConfig (..), KizashiConfig (..), ReiConfig (..))
import Shikigami.Telemetry (withRunTracer)
import Shikigami.Workers.Config (WorkerEnv (..))
import Shikigami.Workers.Registry (runWorkers)
import System.Exit qualified as Exit

-- | Boot the supervised worker that drains @shikigami_run_jobs@, runs each agent
-- end to end, and dispatches its sinks.
--
-- Every value it needs comes from the one resolved configuration: the manifest
-- directory from @agents.directory@, the connection string from
-- @database.connection_string@, the model provider from @behavior.provider@ and
-- its branch, and each downstream from its @sinks.*@ keys. The @--agents@,
-- @--kawa-url@, @--kizashi-url@, @--danwa-url@ and @--danwa-agent@ flags are
-- command-line sources for exactly those keys.
--
-- The logger is built first, before anything that could want to log, and every
-- line this process writes goes through it as one JSON object per line.
runWorkerCmd :: AppConfig -> IO ()
runWorkerCmd config = do
  logger <- Log.newStderrLogger Log.Info
  agents <- loadAgentsIn (Config.agentsDirectory config)
  Log.logInfo logger "worker.agents.loaded" ["count" Aeson..= length agents]
  refuseUndeployableAgents logger agents
  connStr <- Config.revealSecretText <$> requireDatabaseUrl "shikigami-worker" config
  withRunTracer \tr -> do
    behEnv <- newBehaviorEnvFor logger (Config.behaviorProvider config) (Just (otelSink tr))
    let settings = StoreConnection.defaultConnectionSettings connStr
    StoreConnection.withStore settings $ \st -> do
      let appEnv = AppEnv {connectionSettings = settings, tracer = tr, metrics = Nothing}
          env =
            WorkerEnv
              { pool = StoreConnection.pool st,
                appEnv,
                agents,
                behaviorEnv = behEnv,
                runTimeout = Config.runTimeout config,
                approvalDeadline = Config.approvalDeadline config,
                kizashi =
                  KizashiConfig
                    { baseUrl = Config.kizashiBaseUrl config,
                      defaultRecipient = Config.kizashiDefaultRecipient config
                    },
                kawa =
                  KawaConfig
                    { baseUrl = Config.kawaBaseUrl config,
                      sourceSegment = Config.kawaSourceSegment config
                    },
                danwa =
                  DanwaConfig
                    { baseUrl = Config.danwaBaseUrl config,
                      agentParticipant = Config.danwaAgentParticipant config
                    },
                rei = ReiConfig {baseUrl = Config.reiBaseUrl config},
                logger,
                -- The C11 gate reads shikigami.sink_grants over the same pool
                -- the rest of the process uses, so a grant change is visible on
                -- the next dispatch without a restart.
                grants = DbGrants (StoreConnection.pool st)
              }
      runWorkers env

-- | Refuse to boot when a loaded manifest declares a behavior this build cannot
-- run, naming every offender.
--
-- The only such check today is a @Behavior.Flow { name }@ with no registered
-- flow behind it. Without this, the process starts happily and the mistake
-- surfaces as a failed agent run every time that agent's trigger fires — once
-- per matching activity, indefinitely, with nothing said at boot. A worker that
-- cannot run one of its agents is misconfigured, and the loud failure belongs
-- where a deploy can see it.
--
-- This is deliberately fatal rather than a skip: silently dropping the agent is
-- what 'Shikigami.Agent.Loader.loadAgentsIn' already does to an unparseable
-- manifest, and that behavior is documented there as preserved-not-endorsed.
refuseUndeployableAgents :: Log.Logger -> [AgentDecl] -> IO ()
refuseUndeployableAgents logger agents =
  case [(name, err) | decl@AgentDecl {name} <- agents, err <- flowDeclarationErrors decl] of
    [] -> pure ()
    problems -> do
      traverse_
        ( \(agent, err) ->
            Log.logError logger "worker.agents.undeployable" ["agent" Aeson..= agent, "error" Aeson..= err]
        )
        problems
      Exit.die
        ( "shikigami-worker: refusing to start; "
            <> show (length problems)
            <> " agent declaration(s) name a behavior this build cannot run"
        )
