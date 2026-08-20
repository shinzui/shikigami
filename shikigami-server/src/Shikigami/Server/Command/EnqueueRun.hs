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
import Shikigami.Trigger.Enqueue (addressedRunKey, enqueueAddressedRunWithKey, ensureRunQueue)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | @enqueue-run <agent> [--payload <json>] [--conversation] [--key <text>]@:
-- the addressed (event-trigger) producer. Enqueues a RunJob onto the shared
-- @shikigami_run_jobs@ pgmq queue (which the worker, EP-5, drains). Reuses the
-- kioku store's hasql pool.
--
-- The route is declared, not inferred: without @--conversation@ the job runs the
-- durable agent-run workflow, and with it the job is a danwa conversation turn
-- whose payload must decode as an addressed message.
--
-- The idempotency key is derived from the agent and the payload unless @--key@
-- supplies one, so invoking this twice for the same logical event produces one
-- run. It used to be derived from the wall clock, which made a retried
-- invocation a second run.
--
-- The connection string comes from the resolved configuration under
-- @database.connection_string@. It is demanded here rather than by the whole
-- @shikigami@ command line because sibling subcommands such as @validate@ run
-- entirely offline.
runEnqueueRun :: String -> Maybe String -> Bool -> Maybe String -> AppConfig -> IO ()
runEnqueueRun agent mpayload conversation mkey config = do
  payload <- case mpayload of
    Nothing -> pure (Aeson.object [])
    Just raw -> case Aeson.decodeStrict (TE.encodeUtf8 (Text.pack raw)) of
      Just v -> pure v
      Nothing -> do
        hPutStrLn stderr ("enqueue-run: --payload is not valid JSON: " <> raw)
        exitFailure
  connStr <- revealSecretText <$> requireDatabaseUrl "enqueue-run" config
  withStore (defaultConnectionSettings connStr) $ \st -> do
    -- This is one of the two startup paths that used to rely on the per-send
    -- createQueue inside enqueueRunJob, so it reconciles the queue itself now.
    queueResult <- ensureRunQueue (pool st)
    case queueResult of
      Left e -> do
        hPutStrLn stderr ("enqueue-run: run-job queue reconciliation failed: " <> show e)
        exitFailure
      Right () -> pure ()
    let route = if conversation then ConversationWorkflowRoute else AgentWorkflowRoute
        key = maybe (addressedRunKey (Text.pack agent) payload) Text.pack mkey
    res <- enqueueAddressedRunWithKey (pool st) (Text.pack agent) route payload key
    case res of
      Left e -> do
        hPutStrLn stderr ("enqueue-run: " <> show e)
        exitFailure
      Right mid ->
        putStrLn
          ( "enqueued run job "
              <> show mid
              <> " for agent "
              <> agent
              <> " with idempotency key "
              <> Text.unpack key
          )
