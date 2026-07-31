module Shikigami.Server.Command.EnqueueRun
  ( runEnqueueRun,
  )
where

import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Trigger.Enqueue (enqueueAddressedRun)
import System.Environment (getEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | @enqueue-run <agent> [--payload <json>]@: the addressed (event-trigger) producer.
-- Enqueues a RunJob onto the shared @shikigami_run_jobs@ pgmq queue (which the worker,
-- EP-5, drains). Reuses the kioku store's hasql pool.
runEnqueueRun :: String -> Maybe String -> IO ()
runEnqueueRun agent mpayload = do
  payload <- case mpayload of
    Nothing -> pure (Aeson.object [])
    Just raw -> case Aeson.decodeStrict (TE.encodeUtf8 (Text.pack raw)) of
      Just v -> pure v
      Nothing -> do
        hPutStrLn stderr ("enqueue-run: --payload is not valid JSON: " <> raw)
        exitFailure
  connStr <- Text.pack <$> getEnv "PG_CONNECTION_STRING"
  withStore (defaultConnectionSettings connStr) $ \st -> do
    res <- enqueueAddressedRun (pool st) (Text.pack agent) payload
    case res of
      Left e -> do
        hPutStrLn stderr ("enqueue-run: " <> show e)
        exitFailure
      Right mid -> putStrLn ("enqueued run job " <> show mid <> " for agent " <> agent)
