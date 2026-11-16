{-# LANGUAGE DataKinds #-}

-- | Thin operator adapters over the scoped watchdog ledger readers, as one
-- admin verb. It is written against 'AdminContext' and names no process
-- configuration, so it moves with its use case (docs/adr/0129).
module Shikigami.Server.Command.Watchdog (watchdogVerb, runWatchdogInspect, overdueExitCode) where

import Control.Exception (IOException, try)
import Data.Aeson (ToJSON, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Text qualified as Text
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Transaction (runTransactionNoRetry)
import Options.Applicative
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), Trigger (..))
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Loader (AgentLoadEntry (..), AgentLoadReport (..), loadAgentsReport)
import Shikigami.Duration (Duration, remainingDuration)
import Shikigami.Flow.Pack (AdminContext (..), AdminVerb (..))
import Shikigami.Objective.Types (parseObjectiveId)
import Shikigami.Trigger.Schedule (cronExpressionText, parseCron)
import Shikigami.Watchdog.Inspection
import Shikigami.Watchdog.Settings
import Shikigami.Watchdog.Store qualified as Store
import Shikigami.Watchdog.Types
import System.Exit (ExitCode (..), die, exitWith)
import Text.Read (readMaybe)

watchdogVerb :: AdminVerb
watchdogVerb =
  AdminVerb
    { name = "watchdog",
      parser = info (subparser commands <**> helper) (progDesc "Inspect watchdog coverage, overdue sweeps and advisory findings")
    }
  where
    commands =
      command "inspect" (info (inspect <**> helper) (progDesc "Show latest completion, separate latest attempt and coverage"))
        <> command "episodes" (info (episodes <**> helper) (progDesc "Page scoped advisory episodes"))
        <> command "findings" (info (findings <**> helper) (progDesc "Page findings for one scoped episode"))
    inspect =
      (\path grace failOverdue _json -> runWatchdogInspect path (remainingDuration (fromIntegral grace)) failOverdue)
        <$> strOption (long "agents" <> value "agents" <> metavar "DIR")
        <*> option nonnegative (long "grace" <> value 60 <> metavar "SECONDS")
        <*> switch (long "fail-when-overdue")
        <*> switch (long "json")
    episodes =
      (\openOnly objective after limit _json -> runEpisodes (EpisodeFilter openOnly objective) after limit)
        <$> switch (long "open")
        <*> optional (option (checkedReader parseObjectiveId) (long "objective" <> metavar "OBJECTIVE"))
        <*> optional (option (checkedReader parseEpisodeId) (long "after" <> metavar "EPISODE"))
        <*> pageLimit
        <*> switch (long "json")
    findings =
      (\episode after limit _json -> runFindings episode after limit)
        <$> argument (checkedReader parseEpisodeId) (metavar "EPISODE")
        <*> optional (option (checkedReader parseFindingId) (long "after" <> metavar "FINDING"))
        <*> pageLimit
        <*> switch (long "json")
    pageLimit = option (eitherReader (\raw -> case readMaybe raw of Just n | n >= 1 && n <= 100 -> Right n; _ -> Left "watchdog limit must be in 1..100")) (long "limit" <> value 20 <> metavar "COUNT")
    nonnegative = eitherReader (\raw -> case readMaybe raw :: Maybe Int of Just n | n >= 0 -> Right n; _ -> Left "watchdog grace must be nonnegative")
    checkedReader parse = eitherReader (either (Left . Text.unpack) Right . parse . Text.pack)

runWatchdogInspect :: FilePath -> Duration "watchdog-grace" -> Bool -> AdminContext -> IO ()
runWatchdogInspect directory grace failOverdue context = do
  settings <- requireSettings context
  loaded <- try @IOException (loadAgentsReport directory)
  report <- either (const (die "watchdog declaration directory is unavailable")) pure loaded
  case [() | AgentLoadFailed {} <- report.entries] of
    [] -> pure ()
    _ -> die "watchdog declaration directory contains invalid manifests"
  declared <- case [declaration | AgentLoaded {declaration} <- report.entries, case declaration.behavior of Flow {name} -> name == declarationCoordinate "watchdog-sweep"; _ -> False] of
    [declaration] -> pure declaration
    [] -> die "watchdog declaration was not found in the agents directory"
    _ -> die "watchdog declaration is ambiguous in the agents directory"
  cron <- case declared.trigger of
    Schedule {cron} -> either (const (die "watchdog schedule is invalid")) pure (parseCron (cronExpressionText cron))
    _ -> die "watchdog declaration requires a schedule trigger"
  view <- reading context (Store.inspectWatchdog settings.principal settings.scope)
  let verdict = overdueVerdict cron grace view.inspectedAt view.lastCompletedSweep
  emit (object ["inspection" .= view, "verdict" .= verdict, "windows" .= object ["stuck" .= settings.stuckWindowSeconds, "parked" .= settings.parkedWindowSeconds, "coordinator" .= settings.coordinatorWindowSeconds], "subjectsPerSweep" .= settings.subjectsPerSweep, "driftIntervalSeconds" .= settings.driftIntervalSeconds, "driftSubjectsPerSweep" .= settings.driftSubjectsPerSweep])
  case overdueExitCode failOverdue verdict of ExitSuccess -> pure (); code -> exitWith code

overdueExitCode :: Bool -> OverdueVerdict -> ExitCode
overdueExitCode False _ = ExitSuccess
overdueExitCode True SweepFresh = ExitSuccess
overdueExitCode True _ = ExitFailure 2

runEpisodes :: EpisodeFilter -> Maybe EpisodeId -> Int -> AdminContext -> IO ()
runEpisodes filter after limit context = do
  settings <- requireSettings context
  reading context (Store.listEpisodes settings.principal settings.scope filter after limit) >>= emit

runFindings :: EpisodeId -> Maybe FindingId -> Int -> AdminContext -> IO ()
runFindings episode after limit context = do
  settings <- requireSettings context
  reading context (Store.listFindings settings.principal settings.scope episode after limit) >>= emit

requireSettings :: AdminContext -> IO WatchdogSettings
requireSettings context = maybe (die "watchdog is disabled; configure its principal and observation scope") pure (watchdogSettingsFrom context.settings)

-- | One repeatable-read snapshot through the context's store, which verifies
-- the schema before it opens.
reading :: AdminContext -> Transaction (Either Store.WatchdogError a) -> IO a
reading AdminContext {runStore} action = do
  result <- runStore (runTransactionNoRetry (Tx.sql "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY" >> action))
  case result of
    Left _ -> die "watchdog ledger is unavailable"
    Right (Left _) -> die "watchdog inspection was refused; verify metadata and page bounds"
    Right (Right value) -> pure value

emit :: (ToJSON a) => a -> IO ()
emit = Lazy.putStrLn . Aeson.encode
