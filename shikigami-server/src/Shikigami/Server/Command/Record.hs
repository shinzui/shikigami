-- | @shikigami record list@: the operator's view of the kernel action record.
--
-- Every authority decision and every external effect a run performs is one
-- row in @shikigami.action_record@ (ADR-123). This command prints the most
-- recent matching rows, oldest first, either as one greppable line per event
-- or as JSON Lines for scripts.
module Shikigami.Server.Command.Record
  ( RecordListOptions (..),
    runRecordList,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Keiro.Workflow (WorkflowId (..))
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.App.Config (AppConfig, revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.Record
  ( KindFilter (..),
    RecordEvent (..),
    RecordQuery (..),
    defaultRecordLimit,
    mkRecordLimit,
    readRecord,
    recordErrorText,
    renderRecordEvent,
  )
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

data RecordListOptions = RecordListOptions
  { run :: !(Maybe Text),
    refusals :: !Bool,
    kindPrefix :: !(Maybe Text),
    limit :: !(Maybe Int),
    json :: !Bool
  }

-- | @record list [--run ID] [--refusals] [--kind PREFIX] [--limit N] [--json]@.
runRecordList :: RecordListOptions -> AppConfig -> IO ()
runRecordList RecordListOptions {run, refusals, kindPrefix, limit, json} config = do
  recordLimit <- either (die "record list") pure (maybe (Right defaultRecordLimit) mkRecordLimit limit)
  kinds <- case (refusals, kindPrefix) of
    (True, Just _) -> die "record list" "--refusals and --kind are exclusive"
    (True, Nothing) -> pure RefusalsOnly
    (False, Just prefix) -> pure (KindPrefix prefix)
    (False, Nothing) -> pure AllKinds
  connStr <- revealSecretText <$> requireDatabaseUrl "record list" config
  verifyShikigamiMigrations connStr
  withStore (defaultConnectionSettings connStr) \KirokuStore {pool} ->
    readRecord pool RecordQuery {run = WorkflowId <$> run, kinds, limit = recordLimit} >>= \case
      Left failure -> die "record list" (recordErrorText failure)
      Right [] | not json -> putStrLn "no record events"
      Right events
        | json -> mapM_ (LazyChar8.putStrLn . Aeson.encode) events
        | otherwise -> mapM_ (TextIO.putStrLn . renderRecordEvent) events

die :: String -> Text -> IO a
die ctx msg = do
  hPutStrLn stderr (ctx <> ": " <> Text.unpack msg)
  exitFailure
