module Shikigami.Workers.Command.Worker
  ( runWorkerCmd,
  )
where

import Baikai.Trace.Sink.OpenTelemetry (otelSink)
import Data.Aeson qualified as Aeson
import Kioku.App (AppEnv (..))
import Kiroku.Store.Connection qualified as StoreConnection
import Shikigami.Agent.Loader (loadAgentsIn)
import Shikigami.App.Config (AppConfig)
import Shikigami.App.Config qualified as Config
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Behavior.Provider (newBehaviorEnvFor)
import Shikigami.Log qualified as Log
import Shikigami.Sink (DanwaConfig (..), KawaConfig (..), KizashiConfig (..), ReiConfig (..))
import Shikigami.Telemetry (withRunTracer)
import Shikigami.Workers.Config (WorkerEnv (..))
import Shikigami.Workers.Registry (runWorkers)

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
                logger
              }
      runWorkers env
