{-# LANGUAGE DataKinds #-}

module FlowPack.Watchdog.CommandSpec (tests) where

import Control.Exception (try)
import Control.Lens ((&), (.~))
import Data.Aeson (eitherDecode, toJSON)
import Data.Generics.Labels ()
import Data.Time (getCurrentTime)
import FlowPack.Watchdog.Command (runWatchdogInspect)
import FlowPack.Watchdog.Grant
import FlowPack.Watchdog.Observation (PassCompletion (PassIncomplete))
import FlowPack.Watchdog.Observation.Read
import FlowPack.Watchdog.Setting (watchdogKey)
import FlowPack.Watchdog.Store qualified as Store
import FlowPack.Watchdog.Types
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Principal (AgentIdentity (..), mkAgentPrincipal)
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.App.Config (AppConfig (..), defaultAppConfig, opaqueSecretText)
import Shikigami.Duration (remainingDuration)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Pack.Setting (packSettingsFromList)
import Shikigami.Server.Command (adminContext)
import System.Exit (ExitCode (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "WatchdogCommand"
    [ testCase "inspect exits two when no completion exists" $ withCommand fixture \_ config _ -> do
        try @ExitCode (runWatchdogInspect "../packs/flow-pack-watchdog/agents" (remainingDuration 0) True (adminContext "watchdog" config)) >>= (@?= Left (ExitFailure 2)),
      testCase "fresh completed ledger exits successfully" $ withCommand fixture \env config settings -> do
        seed env settings
        try @ExitCode (runWatchdogInspect "../packs/flow-pack-watchdog/agents" (remainingDuration 0) True (adminContext "watchdog" config)) >>= (@?= Right ()),
      testCase "stale completed ledger exits two even with a newer unfinished attempt" $ withCommand fixture \env config settings -> do
        seed env settings
        _ <- right =<< runAppIO env (runTransaction (Tx.sql "UPDATE shikigami.watchdog_sweeps SET opened_at=opened_at-interval '11 minutes',completed_at=completed_at-interval '10 minutes'"))
        grant <- right (resolveObservationGrant (Just settings) settings.principal)
        identifier <- newSweepId
        at <- getCurrentTime
        _ <- right =<< (right =<< runAppIO env (runTransaction (Store.openSweep identifier (Store.SweepOrigin agentRunWorkflowName (WorkflowId "watchdog-new-attempt") at settings.principal) (snapshotGrant grant))))
        try @ExitCode (runWatchdogInspect "../packs/flow-pack-watchdog/agents" (remainingDuration 0) True (adminContext "watchdog" config)) >>= (@?= Left (ExitFailure 2))
    ]

withCommand :: DatabaseFixture -> (AppEnv -> AppConfig -> WatchdogSettings -> IO a) -> IO a
withCommand fixture use = withShikigamiFreshDatabase fixture \connection -> do
  tracer <- noopTracer
  settings <- right (eitherDecode "{\"principal\":\"agent_watchdog\",\"scope\":\"all\",\"stuckWindowSeconds\":60,\"parkedWindowSeconds\":30,\"coordinatorWindowSeconds\":60,\"subjectsPerSweep\":9}")
  let env = AppEnv (defaultConnectionSettings connection) tracer Nothing Nothing
      config = defaultAppConfig & #databaseUrl .~ Just (opaqueSecretText connection) & #packSettings .~ packSettingsFromList [(watchdogKey, toJSON settings)]
  use env config settings

seed :: AppEnv -> WatchdogSettings -> IO ()
seed env settings = do
  grant <- right (resolveObservationGrant (Just settings) settings.principal)
  at <- getCurrentTime
  identifier <- newSweepId
  _ <- right =<< (right =<< runAppIO env (runTransaction (Store.openSweep identifier (Store.SweepOrigin agentRunWorkflowName (WorkflowId "watchdog-command-seed") at settings.principal) (snapshotGrant grant))))
  _ <- right =<< (right =<< runAppIO env (runTransaction (Store.closeSweep identifier (Store.SweepSummary at 0 0 0 PassIncomplete))))
  pure ()

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure
