{-# LANGUAGE DataKinds #-}

-- | Operator adapters over the same command and durable read-request owners.
module Shikigami.Server.Command.ObjectiveTrackers where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.ByteString.Lazy.Char8 qualified as Char8
import Data.Text qualified as Text
import Effectful (Eff)
import Kiroku.Store.Connection (withStore)
import Shikigami.Action.Authorization (denyAllActionAuthorizer)
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.App.Config (AppConfig (..), revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Execution.Identity (parseOperationId)
import Shikigami.Log qualified as Log
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.Objective.Tracker.Api (TrackerCommand (..))
import Shikigami.Objective.Tracker.Command qualified as C
import Shikigami.Objective.Tracker.Control qualified as Control
import Shikigami.Objective.Tracker.Control.Types
import Shikigami.Objective.Tracker.Handler (localOperationView, operationView)
import Shikigami.Objective.Tracker.Inspection qualified as View
import Shikigami.Objective.Tracker.Runtime qualified as Runtime
import Shikigami.Objective.Tracker.Store qualified as Store
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types qualified as O
import Shikigami.Prelude hiding ((.=))
import Shikigami.Runtime (registerRuntimeCatalog, runtimeConnectionSettings)
import Shikigami.Server.Command.Objectives (readDocument)
import Shikigami.Sink.Http (HttpLimits (..))
import System.Exit (die)

runTrackerSubmit :: Bool -> Text -> FilePath -> Bool -> AppConfig -> IO ()
runTrackerSubmit bindOnly raw path _json config = do
  objective <- checked (O.parseObjectiveId raw)
  body <- readDocument path :: IO TrackerCommand
  when bindOnly case body.request of RunCommand C.Bind {} -> pure (); _ -> die "bind requires a RunCommand Bind document"
  withTrackers config \host ->
    if Control.networkRequest body.request
      then fmap (fmap (\(fresh, record) -> Aeson.object ["queued" .= fresh, "operation" .= operationView record])) (Control.enqueue host objective body.operationKey body.request)
      else case body.request of
        RunCommand command -> fmap (fmap (Aeson.toJSON . localOperationView)) (Store.execute host objective body.operationKey command)
        _ -> pure (Left (TrackerInvalid "invalid tracker request"))

runTrackerInspect :: Text -> Maybe Text -> Maybe Text -> Int -> Bool -> AppConfig -> IO ()
runTrackerInspect raw selected after limit _json config = do
  objective <- checked (O.parseObjectiveId raw)
  pageBounds limit
  withTrackers config \host -> case selected of
    Just identifier -> do
      binding <- either (const (pure Nothing)) (pure . Just) (parseCoordinate identifier)
      maybe (pure (Left TrackerMissing)) (fmap (fmap toJSON) . View.binding host objective) binding
    Nothing -> do
      rows <- View.bindings host objective
      pure (fmap (\values -> let eligible = filter (\row -> maybe True (< row.identity) after) values; page = take (min 3 limit) eligible in Aeson.object ["items" .= page, "next" .= (if length eligible > length page then case reverse page of value : _ -> Just value.identity; _ -> Nothing else Nothing)]) rows)

runTrackerHistory :: HistoryKind -> Text -> Text -> Maybe Text -> Int -> Bool -> AppConfig -> IO ()
runTrackerHistory kind raw identifier after limit _json config = do
  objective <- checked (O.parseObjectiveId raw)
  binding <- checked (parseCoordinate identifier)
  pageBounds limit
  withTrackers config \host -> do
    rows <- View.history host objective binding kind True after (min 3 limit + 1)
    pure (fmap (\values -> let page = take (min 3 limit) values in Aeson.object ["items" .= page, "next" .= (if length values > length page then case reverse page of value : _ -> Just value.identity; _ -> Nothing else Nothing)]) rows)

runTrackerOperation :: Text -> Text -> Bool -> AppConfig -> IO ()
runTrackerOperation raw key _json config = do
  objective <- checked (O.parseObjectiveId raw)
  operation <- checked (parseOperationId key)
  withTrackers config \host -> do
    queued <- Control.inspect host objective operation
    case queued of
      Right record -> pure (Right (toJSON (operationView record)))
      Left TrackerMissing -> fmap (fmap (toJSON . localOperationView)) (View.localReceipt host objective operation)
      Left err -> pure (Left err)

withTrackers :: AppConfig -> (Store.TrackerHost -> Eff AppEffects (Either TrackerError Aeson.Value)) -> IO ()
withTrackers config action = do
  unless (config.objectiveSettings.enabled == O.ObjectivesEnabled) (die "objective tracking is disabled")
  objective <- either (const (die "tracker commands require a configured local operator")) pure (Runtime.operatorHost config.objectiveSettings denyAllActionAuthorizer)
  connection <- revealSecretText <$> requireDatabaseUrl "objective trackers" config
  verifyShikigamiMigrations connection
  tracer <- noopTracer
  let settings = runtimeConnectionSettings Log.silentLogger Nothing connection
  Runtime.withTrackerProviders (HttpLimits config.httpRequestMaxBytes config.httpResponseMaxBytes) config.trackerSettings \available -> do
    providers <- either (const (die "objective tracker provider configuration is unavailable")) pure available
    let host = Store.TrackerHost objective config.trackerSettings (Runtime.providerFor providers config.trackerSettings)
    withStore settings \store -> do
      registerRuntimeCatalog store
      result <- runAppIO (AppEnv settings tracer Nothing (Just store)) (action host)
      case result of
        Right (Right value) | Lazy.length (Aeson.encode value) <= 16384 -> Char8.putStrLn (Aeson.encode value)
        Right (Right _) -> die "tracker reply exceeds 16 KiB; request a smaller page"
        Right (Left err) -> die ("tracker operation refused: " <> case err of TrackerDenied -> "denied"; TrackerMissing -> "missing"; TrackerConflict -> "conflict"; TrackerInvalid _ -> "invalid"; TrackerUnavailable -> "unavailable")
        Left _ -> die "tracker authority is unavailable"

pageBounds :: Int -> IO ()
pageBounds count = unless (count >= 1 && count <= 100) (die "tracker page size must be 1..100")

checked :: Either Text a -> IO a
checked = either (die . Text.unpack) pure
