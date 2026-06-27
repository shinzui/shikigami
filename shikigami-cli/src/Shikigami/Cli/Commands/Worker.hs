module Shikigami.Cli.Commands.Worker
  ( runWorkerCmd,
  )
where

import Data.List (isSuffixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Kioku.App (AppEnv (..), noopTracer)
import Kiroku.Store.Connection qualified as StoreConnection
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Api.Agent (AgentDecl)
import Shikigami.Behavior.Run (newBehaviorEnv)
import Shikigami.Sink (DanwaConfig (..), KawaConfig (..), KizashiConfig (..))
import Shikigami.Worker (WorkerEnv (..), runWorker)
import System.Directory (listDirectory)
import System.Environment (getEnv)
import System.FilePath ((</>))

-- | @worker --agents <dir> [--kawa-url U --kizashi-url U --danwa-url U --danwa-agent P]@: boot the supervised worker
-- that drains @shikigami_run_jobs@, runs each agent end to end, and dispatches its sinks.
runWorkerCmd :: FilePath -> Text -> Text -> Text -> Text -> IO ()
runWorkerCmd agentsDir kawaUrl kizashiUrl danwaUrl danwaAgent = do
  agents <- loadAgents agentsDir
  putStrLn ("[worker] loaded " <> show (length agents) <> " agents")
  connStr <- Text.pack <$> getEnv "PG_CONNECTION_STRING"
  behEnv <- newBehaviorEnv
  StoreConnection.withStore (StoreConnection.defaultConnectionSettings connStr) $ \st -> do
    tr <- noopTracer
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
    runWorker env

loadAgents :: FilePath -> IO [AgentDecl]
loadAgents dir = do
  entries <- listDirectory dir
  loaded <- mapM loadAgent [dir </> e | e <- entries, ".dhall" `isSuffixOf` e]
  pure [a | Right a <- loaded]
