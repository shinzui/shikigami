module Shikigami.Workers.Command.Worker
  ( runWorkerCmd,
  )
where

import Baikai.Trace.Sink.OpenTelemetry (otelSink)
import Data.Text (Text)
import Data.Text qualified as Text
import Kioku.App (AppEnv (..))
import Kiroku.Store.Connection qualified as StoreConnection
import Shikigami.Agent.Loader (loadAgentsIn)
import Shikigami.Behavior.Run (newBehaviorEnvWithTraceSink)
import Shikigami.Sink (DanwaConfig (..), KawaConfig (..), KizashiConfig (..))
import Shikigami.Telemetry (withRunTracer)
import Shikigami.Workers.Config (WorkerEnv (..))
import Shikigami.Workers.Registry (runWorkers)
import System.Environment (getEnv)

-- | @worker --agents <dir> [--kawa-url U --kizashi-url U --danwa-url U --danwa-agent P]@: boot the supervised worker
-- that drains @shikigami_run_jobs@, runs each agent end to end, and dispatches its sinks.
runWorkerCmd :: FilePath -> Text -> Text -> Text -> Text -> IO ()
runWorkerCmd agentsDir kawaUrl kizashiUrl danwaUrl danwaAgent = do
  agents <- loadAgentsIn agentsDir
  putStrLn ("[worker] loaded " <> show (length agents) <> " agents")
  connStr <- Text.pack <$> getEnv "PG_CONNECTION_STRING"
  withRunTracer \tr -> do
    behEnv <- newBehaviorEnvWithTraceSink (Just (otelSink tr))
    StoreConnection.withStore (StoreConnection.defaultConnectionSettings connStr) $ \st -> do
      let appEnv = AppEnv {store = st, tracer = tr, metrics = Nothing}
          env =
            WorkerEnv
              { pool = StoreConnection.pool st,
                appEnv,
                agents,
                behaviorEnv = behEnv,
                kizashi = KizashiConfig {baseUrl = kizashiUrl, defaultRecipient = "recipient:default"},
                kawa = KawaConfig {baseUrl = kawaUrl, sourceSegment = "shinzui/shikigami"},
                danwa = DanwaConfig {baseUrl = danwaUrl, agentParticipant = danwaAgent}
              }
      runWorkers env
