-- | @shikigami-local runs@: the local operator's runs (EP-9 M2 of MasterPlan
-- 22). A read over two existing stores, the action record and the workflow
-- journal, with no table of its own.
module Shikigami.Agent.Command.LocalRuns
  ( RunsQuery (..),
    runLocalRuns,
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time (diffUTCTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Keiro.Workflow (WorkflowId (..), loadStepIndex)
import Keiro.Workflow.Instance (WorkflowInstanceRow (..), lookupInstance, statusToText)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.App.Config (AppConfig (..), revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.Output (OutputReceipt (..))
import Shikigami.Record
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

data RunsQuery = RunsQuery
  { run :: !(Maybe Text),
    limit :: !Int
  }

runLocalRuns :: RunsQuery -> AppConfig -> IO ()
runLocalRuns RunsQuery {run, limit} config = do
  connection <- revealSecretText <$> requireDatabaseUrl "shikigami-local runs" config
  verifyShikigamiMigrations connection
  tracer <- noopTracer
  let settings = defaultConnectionSettings connection
  withStore settings \store@KirokuStore {pool} -> do
    let appEnv = AppEnv {connectionSettings = settings, tracer, metrics = Nothing, store = Just store}
        recordLimit = either (error . Text.unpack) id (mkRecordLimit 1000)
    case run of
      Just runId -> do
        events <- readRecord pool RecordQuery {run = Just (WorkflowId runId), kinds = AllKinds, limit = recordLimit} >>= either (die . recordErrorText) pure
        if null events then die ("no record of run " <> runId) else mapM_ (TextIO.putStrLn . renderRecordEvent) events
        reports appEnv (WorkflowId runId) >>= mapM_ (TextIO.putStrLn . ("report  " <>))
      Nothing -> do
        events <- readRecord pool RecordQuery {run = Nothing, kinds = AllKinds, limit = recordLimit} >>= either (die . recordErrorText) pure
        let runs = take limit (reverse (nub [runId | RecordEvent {run = Just runId} <- events]))
        if null runs then putStrLn "no runs in the action record" else pure ()
        mapM_ (summary appEnv events) runs
  where
    summary appEnv events runId = do
      let mine = [event | event@RecordEvent {run = Just other} <- events, other == runId]
          agent = case [name | RecordEvent {agent = Just name} <- mine] of
            name : _ -> agentNameText name
            [] -> "-"
          decided = [payload | RecordEvent {entry} <- mine, let (kind, payload) = recordEntry entry, recordKindText kind == "authority.decided"]
          allowed = length [() | Aeson.Object fields <- decided, KeyMap.lookup "decision" fields == Just (Aeson.String "allowed")]
          refused = length decided - allowed
          started = case mine of
            first' : _ -> Text.pack (iso8601Show first'.at)
            [] -> "-"
      instance' <- runAppIO appEnv (lookupInstance agentRunWorkflowName runId)
      let (outcome, elapsed) = case instance' of
            Right (Just row) -> (statusToText row.status, maybe "" (\done -> " in " <> Text.pack (show (round (diffUTCTime done row.createdAt) :: Integer)) <> "s") row.completedAt)
            _ -> ("unknown", "")
      found <- reports appEnv runId
      TextIO.putStrLn (Text.intercalate "  " [agent, runId.unWorkflowId, started, outcome <> elapsed, Text.pack (show allowed) <> " allowed, " <> Text.pack (show refused) <> " refused"])
      mapM_ (TextIO.putStrLn . ("  report  " <>)) found
    reports appEnv runId = do
      steps <- runAppIO appEnv (loadStepIndex agentRunWorkflowName runId 0)
      pure case either (const Nothing) (Map.lookup "deliver-outputs") steps of
        Just value | Aeson.Success (receipts :: [Either Text OutputReceipt]) <- Aeson.fromJSON value -> mapMaybe (either (const Nothing) (Just . (.location))) receipts
        _ -> []

die :: Text -> IO a
die message = hPutStrLn stderr ("shikigami-local: " <> Text.unpack message) >> exitFailure
