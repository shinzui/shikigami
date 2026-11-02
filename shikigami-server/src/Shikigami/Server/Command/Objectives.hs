{-# LANGUAGE DataKinds #-}

-- | A configured local operator is a distinct recorded principal. No CLI flag
-- can impersonate an API caller or an agent.
module Shikigami.Server.Command.Objectives where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.ByteString.Lazy.Char8 qualified as Char8
import Data.Text qualified as Text
import Effectful (Eff)
import Kiroku.Store.Connection (withStore)
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.App.Config (AppConfig (..), revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Log qualified as Log
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.Objective.Capability qualified as Owner
import Shikigami.Objective.Command (Command)
import Shikigami.Objective.Handler (historyView, objectiveHost, receiptView)
import Shikigami.Objective.Inspection (objectiveViewPage)
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.Runtime (registerRuntimeCatalog, runtimeConnectionSettings)
import System.Exit (die)
import System.IO (IOMode (ReadMode), withBinaryFile)

runObjectivesCreate :: OperationId -> FilePath -> Bool -> AppConfig -> IO ()
runObjectivesCreate operation path _json config = do
  request <- readDocument path
  withObjectives config \host -> fmap (fmap receiptView) (Owner.createObjective host operation Nothing request)

runObjectivesInspect :: Text -> Int -> Int -> Bool -> AppConfig -> IO ()
runObjectivesInspect raw after limit _json config = do
  unless (after >= 0 && after <= 10000 && limit >= 1 && limit <= 100) (die "invalid objective page bounds")
  objective <- checked (parseObjectiveId raw)
  withObjectives config \host -> fmap (fmap (objectiveViewPage after limit)) (Owner.readObjective host objective)

runObjectivesHistory :: Text -> Maybe Integer -> Int -> Bool -> AppConfig -> IO ()
runObjectivesHistory raw after limit _json config = do
  objective <- checked (parseObjectiveId raw)
  cursor <- traverse (checked . parseRevision) after
  unless (limit >= 1 && limit <= 100) (die "objective page size must be 1..100")
  withObjectives config \host -> fmap (fmap (map historyView)) (Owner.readHistory host objective cursor limit)

runObjectivesCommand :: Text -> OperationId -> StateRevision "objective" -> FilePath -> Bool -> AppConfig -> IO ()
runObjectivesCommand raw operation expected path _json config = do
  objective <- checked (parseObjectiveId raw)
  command <- readDocument path :: IO Command
  withObjectives config \host -> fmap (fmap receiptView) (Owner.executeCommand host objective expected operation command)

withObjectives :: (ToJSON a) => AppConfig -> (Owner.ObjectiveHost -> Eff AppEffects (Either ObjectiveError a)) -> IO ()
withObjectives config action = do
  unless (config.objectiveSettings.enabled == ObjectivesEnabled) (die "objective tracking is disabled")
  operator <- maybe (die "objective commands require a configured local operator identity") pure config.objectiveSettings.operator
  connection <- revealSecretText <$> requireDatabaseUrl "objectives" config
  verifyShikigamiMigrations connection
  tracer <- noopTracer
  let settings = runtimeConnectionSettings Log.silentLogger Nothing connection
      host = objectiveHost config.objectiveSettings (pure (Right (LocalOperator operator)))
  withStore settings \store -> do
    registerRuntimeCatalog store
    result <- runAppIO (AppEnv settings tracer Nothing (Just store)) (action host)
    case result of
      Right (Right value) -> Char8.putStrLn (Aeson.encode value)
      Right (Left err) -> die ("objective command refused: " <> show err)
      Left _ -> die "objective authority is unavailable"

readDocument :: (FromJSON a) => FilePath -> IO a
readDocument path = withBinaryFile path ReadMode \handle -> do
  bytes <- Lazy.hGet handle 1048577
  when (Lazy.length bytes > 1048576) (die "objective document exceeds 1 MiB")
  either (const (die "invalid closed objective JSON document")) pure (Aeson.eitherDecode bytes)

checked :: Either Text a -> IO a
checked = either (die . Text.unpack) pure
