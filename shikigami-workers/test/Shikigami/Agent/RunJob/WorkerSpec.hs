{-# LANGUAGE TypeApplications #-}

module Shikigami.Agent.RunJob.WorkerSpec (tests) where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception)
import Control.Exception qualified as Exception
import Data.Aeson qualified as Aeson
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (liftIO, runEff)
import Keiro.PGMQ
  ( Job (..),
    JobContext (..),
    JobOutcome (Done),
    JobPolling (PollEvery),
    JobRuntime,
    JobTuning,
    PgmqRuntimeError,
    QueueMetrics (..),
    decodeJob,
    encodeJob,
    enqueue,
    ensureJobQueue,
    jobProcessorWithContext,
    jobQueueMetrics,
    mkJobTuning,
    runJobEff,
    runJobWorkers,
    withJobRuntime,
  )
import Shibuya.App (ShutdownConfig (..), SupervisionStrategy (IgnoreFailures), stopAppGracefully)
import Shikigami.Agent.RunJob (RunJob (..), TriggerKind (TriggeredByEvent))
import Shikigami.Agent.RunJob.Worker (runJob, withVisibilityHeartbeatEvery)
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "RunJob"
    [ testCase "typed codec preserves the producer's bare RunJob JSON" do
        let payload = sampleJob
            encoded = Aeson.toJSON payload
            Job {jobCodec = codec} = runJob
        assertEqual "typed decoder accepts the producer payload" (Right payload) (decodeJob codec encoded)
        assertEqual "typed encoder keeps the historical wire" encoded (encodeJob codec payload),
      testCase "worker-path heartbeat keeps one slow delivery leased" do
        withShikigamiMigratedDatabase \connStr -> do
          callCount <- newIORef (0 :: Int)
          handlerDone <- newIORef False
          let tuning = requireTuning (mkJobTuning 1 1 (PollEvery 0.1))
          processed <-
            runDb connStr \runtime ->
              runJobEff runtime do
                ensureJobQueue runJob
                _ <- enqueue runJob sampleJob
                appResult <-
                  runJobWorkers
                    IgnoreFailures
                    16
                    [ jobProcessorWithContext tuning runJob \context _payload ->
                        withVisibilityHeartbeatEvery 0.2 1 context do
                          liftIO (modifyIORef' callCount (+ 1))
                          liftIO (threadDelay 2_500_000)
                          liftIO (writeIORef handlerDone True)
                          pure Done
                    ]
                case appResult of
                  Left err -> liftIO (assertFailure ("runJobWorkers failed: " <> show err))
                  Right app -> do
                    completed <- liftIO (waitUntil (readIORef handlerDone))
                    _ <- stopAppGracefully ShutdownConfig {drainTimeout = 1} app
                    pure completed
          assertBool "slow handler completed" processed
          assertEqual "delivery entered the handler once" 1 =<< readIORef callCount
          metrics <- runDb connStr \runtime -> runJobEff runtime (jobQueueMetrics runJob)
          assertEqual "main queue is empty" 0 (queueLength metrics),
      testCase "heartbeat failure cancels work and escapes" do
        cleanedUp <- newIORef False
        let context =
              JobContext
                { extendLease = \_ -> liftIO (Exception.throwIO TestHeartbeatFailure),
                  attempt = Nothing,
                  headers = Nothing
                }
            slowWork =
              liftIO $
                Exception.finally
                  (threadDelay 5_000_000)
                  (writeIORef cleanedUp True)
        result <-
          Exception.try @TestHeartbeatFailure $
            runEff (withVisibilityHeartbeatEvery 0.01 1 context slowWork)
        case result of
          Left TestHeartbeatFailure -> pure ()
          Right () -> assertFailure "heartbeat failure did not escape"
        assertBool "failed heartbeat cancelled the work branch" =<< readIORef cleanedUp
    ]

data TestHeartbeatFailure = TestHeartbeatFailure
  deriving stock (Eq, Show)

instance Exception TestHeartbeatFailure

sampleJob :: RunJob
sampleJob =
  RunJob
    { agentName = "codec-agent",
      triggerKind = TriggeredByEvent,
      occurredAt = UTCTime (fromGregorian 2026 8 19) 0,
      triggerPayload = Aeson.object ["kind" Aeson..= ("test" :: Text)],
      idempotencyKey = "codec-agent:event:1",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing
    }

requireTuning :: Either e JobTuning -> JobTuning
requireTuning = either (const (error "invalid test job tuning")) id

runDb :: Text -> (JobRuntime -> IO (Either PgmqRuntimeError a)) -> IO a
runDb connStr action =
  withJobRuntime connStr Nothing \runtime -> do
    result <- action runtime
    either (assertFailure . ("PGMQ runtime error: " <>) . show) pure result

waitUntil :: IO Bool -> IO Bool
waitUntil predicate =
  maybe False id <$> timeout 10_000_000 loop
  where
    loop = do
      ready <- predicate
      if ready
        then pure True
        else threadDelay 100_000 >> loop
