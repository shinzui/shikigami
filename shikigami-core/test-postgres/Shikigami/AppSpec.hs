module Shikigami.AppSpec (tests) where

import Control.Exception (bracket)
import Control.Monad (void)
import Data.Either (isRight)
import Keiro.Command (RunCommandOptions (..))
import Keiro.Telemetry (newKeiroMetrics)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Read (visibleGlobalHeadPosition)
import OpenTelemetry.Metric qualified as Metric
import OpenTelemetry.Resource (emptyMaterializedResources)
import Shikigami.App (AppEnv (..), commandOptions, noopTracer, runAppIO)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Telemetry.Metrics (shikigamiInstrumentationLibrary)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "App runtime"
    [ testCase "independent actions reuse the acquired store despite unusable connection settings" $
        withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
          tracer <- noopTracer
          let env = AppEnv (defaultConnectionSettings "postgresql://127.0.0.1:1/unusable") tracer Nothing (Just store)
          first <- runAppIO env visibleGlobalHeadPosition
          second <- runAppIO env visibleGlobalHeadPosition
          assertBool "first action used the owned store" (isRight first)
          second @?= first,
      testCase "command options carry process telemetry and retain bounded verification" $
        withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
          tracer <- noopTracer
          bracket
            (Metric.createMeterProvider emptyMaterializedResources Metric.defaultSdkMeterProviderOptions)
            (\(provider, _) -> void (Metric.shutdownMeterProvider provider Nothing))
            \(provider, _) -> do
              meter <- Metric.getMeter provider shikigamiInstrumentationLibrary
              metrics <- newKeiroMetrics meter
              let env = AppEnv (defaultConnectionSettings connection) tracer (Just metrics) (Just store)
              result <- runAppIO env commandOptions
              case result of
                Left failure -> assertFailure (show failure)
                Right options -> do
                  assertBool "tracer reaches every catalog command" (case options.tracer of Just _ -> True; _ -> False)
                  assertBool "metrics reach every catalog command" (case options.metrics of Just _ -> True; _ -> False)
                  options.seedVerifyInFlightLimit @?= 1
    ]
