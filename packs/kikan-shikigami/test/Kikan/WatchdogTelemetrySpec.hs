module Kikan.WatchdogTelemetrySpec (tests) where

import Data.Aeson (eitherDecode)
import Data.Time (getCurrentTime)
import FlowPack.Initiative.Fixture.Proposing qualified as P
import FlowPack.Watchdog.Grant
import FlowPack.Watchdog.Ledger (SweepOrigin (..), SweepSummary (..))
import FlowPack.Watchdog.Observation (PassCompletion (PassCompleted))
import FlowPack.Watchdog.Observation.Read
import FlowPack.Watchdog.Runtime (sweepAgeGauge)
import FlowPack.Watchdog.Settings (WatchdogSettings (..))
import FlowPack.Watchdog.Store qualified as Ledger
import FlowPack.Watchdog.Types
import Keiro.Workflow (WorkflowId (..), WorkflowName (..))
import Kikan.Fixture.Watchdog (watchdogPackSettings)
import Shikigami.App (runAppIO)
import Shikigami.Flow.Pack (PackGauge (..))
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "Telemetry"
    [ testCase "the sweep-age gauge has no level until a sweep completes, and none without a policy" $ P.withProposing fixture P.defaultOptions \h -> do
        configured <- right (eitherDecode "{\"principal\":\"agent_watchdog\",\"scope\":\"all\",\"stuckWindowSeconds\":60,\"parkedWindowSeconds\":30,\"coordinatorWindowSeconds\":60,\"subjectsPerSweep\":9}")
        grant <- right (resolveObservationGrant (Just configured) configured.principal)
        let sample settings = runAppIO h.env (sweepAgeGauge.sample (watchdogPackSettings settings)) >>= right
        sweepAgeGauge.name @?= "sweep.age"
        sample (Just configured) >>= (@?= Right Nothing)
        now <- getCurrentTime
        sweep <- newSweepId
        _ <- P.runTx h (Ledger.openSweep sweep (SweepOrigin (WorkflowName "telemetry-fixture") (WorkflowId "ledger-only") now configured.principal) (snapshotGrant grant)) >>= right
        _ <- P.runTx h (Ledger.closeSweep sweep (SweepSummary now 0 1 0 PassCompleted)) >>= right
        sample (Just configured) >>= \case
          Right (Just age) -> assertBool "the database-clock age is nonnegative" (age >= 0)
          other -> assertFailure ("expected an age, got " <> show other)
        sample Nothing >>= (@?= Right Nothing)
    ]

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure
