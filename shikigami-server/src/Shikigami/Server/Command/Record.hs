-- | @shikigami record list@: the operator's view of the kernel action record.
--
-- Every authority decision and every external effect a run performs is one
-- row in @shikigami.action_record@ (ADR-123). This command prints the most
-- recent matching rows, oldest first, either as one greppable line per event
-- or as JSON Lines for scripts.
module Shikigami.Server.Command.Record
  ( RecordListOptions (..),
    runRecordList,
    renderRecordEvent,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time.Format.ISO8601 (iso8601Show)
import Keiro.Workflow (WorkflowId (..))
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.Name (agentNameText)
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
    recordEntry,
    recordErrorText,
    recordKindText,
    tierLabelText,
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

-- | One event on one line: time, run, agent, principal, kind, then the
-- action, resource, decision and who decided when the payload carries them.
renderRecordEvent :: RecordEvent -> Text
renderRecordEvent RecordEvent {at, run, principal, tier, agent, entry} =
  let (kind, payload) = recordEntry entry
      field name = case payload of
        Object object -> case KeyMap.lookup name object of
          Just (String value) -> Just value
          _ -> Nothing
        _ -> Nothing
      decided = case (field "decision", field "detail") of
        (Just "allowed", _) -> ["allowed"]
        (Just _, Just detail) -> ["refused " <> detail]
        (Just decision, Nothing) -> ["refused " <> decision]
        _ -> []
      source = maybe [] (\by -> ["(source: " <> by <> ")"]) (field "decidedBy")
   in Text.unwords
        ( [ Text.pack (iso8601Show at),
            maybe "-" (.unWorkflowId) run,
            maybe "-" agentNameText agent,
            principal,
            tierLabelText tier,
            recordKindText kind
          ]
            <> maybe [] pure (field "action")
            <> maybe [] pure (field "resource")
            <> decided
            <> source
            <> [Text.take 200 (Text.pack (LazyChar8.unpack (Aeson.encode payload))) | null decided]
        )

die :: String -> Text -> IO a
die ctx msg = do
  hPutStrLn stderr (ctx <> ": " <> Text.unpack msg)
  exitFailure
