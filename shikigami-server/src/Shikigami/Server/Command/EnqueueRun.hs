module Shikigami.Server.Command.EnqueueRun
  ( runEnqueueRun,
  )
where

import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.RunJob (RunRouteKind (..))
import Shikigami.App.Config (AppConfig, revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Trigger.Enqueue (enqueueAddressedRun)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | @enqueue-run <agent> [--payload <json>] [--conversation]@: the addressed
-- (event-trigger) producer. Enqueues a RunJob onto the shared
-- @shikigami_run_jobs@ pgmq queue (which the worker, EP-5, drains). Reuses the
-- kioku store's hasql pool.
--
-- The route is declared, not inferred: without @--conversation@ the job runs the
-- durable agent-run workflow, and with it the job is a danwa conversation turn
-- whose payload must decode as an addressed message.
--
-- The connection string comes from the resolved configuration under
-- @database.connection_string@. It is demanded here rather than by the whole
-- @shikigami@ command line because sibling subcommands such as @validate@ run
-- entirely offline.
runEnqueueRun :: String -> Maybe String -> Bool -> AppConfig -> IO ()
runEnqueueRun agent mpayload conversation config = do
  payload <- case mpayload of
    Nothing -> pure (Aeson.object [])
    Just raw -> case Aeson.decodeStrict (TE.encodeUtf8 (Text.pack raw)) of
      Just v -> pure v
      Nothing -> do
        hPutStrLn stderr ("enqueue-run: --payload is not valid JSON: " <> raw)
        exitFailure
  connStr <- revealSecretText <$> requireDatabaseUrl "enqueue-run" config
  withStore (defaultConnectionSettings connStr) $ \st -> do
    let route = if conversation then ConversationWorkflowRoute else AgentWorkflowRoute
    res <- enqueueAddressedRun (pool st) (Text.pack agent) route payload
    case res of
      Left e -> do
        hPutStrLn stderr ("enqueue-run: " <> show e)
        exitFailure
      Right mid -> putStrLn ("enqueued run job " <> show mid <> " for agent " <> agent)
