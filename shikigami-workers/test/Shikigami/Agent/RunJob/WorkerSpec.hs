{-# LANGUAGE TypeApplications #-}

module Shikigami.Agent.RunJob.WorkerSpec (tests) where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception)
import Control.Exception qualified as Exception
import Data.Aeson qualified as Aeson
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (liftIO, runEff)
import Keiro.PGMQ
  ( Job (..),
    JobContext (..),
    JobOutcome (..),
    JobPolling (PollEvery),
    JobRuntime,
    JobTuning,
    PgmqRuntimeError,
    QueueMetrics (..),
    decodeJob,
    encodeJob,
    enqueue,
    ensureJobQueue,
    jobDlqMetrics,
    jobProcessorWithContext,
    jobQueueMetrics,
    mkJobTuning,
    runJobEff,
    runJobWorkers,
    withJobRuntime,
  )
import Keiro.Workflow (WorkflowOutcome (..))
import Shibuya.App (ShutdownConfig (..), SupervisionStrategy (IgnoreFailures), stopAppGracefully)
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.RunJob (RunJob (..), TriggerKind (TriggeredByEvent))
import Shikigami.Agent.RunJob.Worker (agentJobOutcome, conversationJobOutcome, runJob, transientBehaviorJobOutcome, withVisibilityHeartbeatEvery)
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Behavior.Error (TransientBehaviorFailure (..))
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
      testCase "typed outcome table covers every workflow disposition" do
        assertRetryDefault "store failure" (agentJobOutcome "agent" (Left ()))
        assertDone "completed" (agentJobOutcome "agent" (Right (Completed (Right ()))))
        assertRetryDefault
          "legacy failure"
          (agentJobOutcome "agent" (Right (Completed (Left (AgentWorkflow.LegacyBehaviorFailure "legacy")))))
        assertDeadWith
          "permanent failure"
          "shikigami.permanent_workflow_failure:"
          (agentJobOutcome "agent" (Right (Completed (Left (AgentWorkflow.PermanentAgentRunFailure "bad")))))
        assertDone "suspended" (agentJobOutcome "agent" (Right Suspended))
        assertDeadWith "cancelled" "shikigami.workflow_cancelled:" (agentJobOutcome "agent" (Right Cancelled))
        assertDeadWith "failed" "shikigami.workflow_failed:" (agentJobOutcome "agent" (Right Failed))
        assertDone "continued as new" (agentJobOutcome "agent" (Right ContinuedAsNew))
        assertRetryDefault
          "conversation transient"
          (conversationJobOutcome (Left (Conversation.ConversationTransientFailure "again")))
        assertDeadWith
          "conversation permanent"
          "shikigami.permanent_conversation_failure:"
          (conversationJobOutcome (Left (Conversation.ConversationPermanentFailure "bad")))
        assertDeadWith
          "conversation terminal"
          "shikigami.terminal_conversation_failure:"
          (conversationJobOutcome (Left (Conversation.ConversationTerminalFailure "failed")))
        assertDone "conversation completed" (conversationJobOutcome (Right ()))
        assertRetryDefault
          "transient behavior exception"
          (transientBehaviorJobOutcome (TransientBehaviorFailure "retry")),
      testCase "worker-path heartbeat keeps one slow delivery leased" do
        withShikigamiMigratedDatabase \connStr -> do
          callCount <- newIORef (0 :: Int)
          handlerDone <- newIORef False
          let tuning = requireTuning (mkJobTuning 1 1 (PollEvery 0.1))
          processed <-
            runDb connStr \runtime ->
              runJobEff runtime do
                ensureJobQueue runJob
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
          dlqMetrics <- runDb connStr \runtime -> runJobEff runtime (jobDlqMetrics runJob)
          assertEqual "main queue is empty" 0 (queueLength metrics)
          assertEqual "reconciled DLQ is empty" 0 (queueLength dlqMetrics),
      testCase "permanent outcome reaches the reconciled DLQ" do
        withShikigamiMigratedDatabase \connStr -> do
          let tuning = requireTuning (mkJobTuning 2 1 (PollEvery 0.1))
              permanent =
                agentJobOutcome
                  "codec-agent"
                  (Right (Completed (Left (AgentWorkflow.PermanentAgentRunFailure "invalid declaration"))))
          reachedDlq <-
            runDb connStr \runtime ->
              runJobEff runtime do
                ensureJobQueue runJob
                ensureJobQueue runJob
                _ <- enqueue runJob sampleJob
                appResult <-
                  runJobWorkers
                    IgnoreFailures
                    16
                    [jobProcessorWithContext tuning runJob \_context _payload -> pure permanent]
                case appResult of
                  Left err -> liftIO (assertFailure ("runJobWorkers failed: " <> show err))
                  Right app -> do
                    reached <- liftIO $ waitUntil do
                      metrics <- runDb connStr \probeRuntime -> runJobEff probeRuntime (jobDlqMetrics runJob)
                      pure (queueLength metrics == 1)
                    _ <- stopAppGracefully ShutdownConfig {drainTimeout = 1} app
                    pure reached
          assertBool "permanent message reached the DLQ" reachedDlq
          mainMetrics <- runDb connStr \runtime -> runJobEff runtime (jobQueueMetrics runJob)
          dlqMetrics <- runDb connStr \runtime -> runJobEff runtime (jobDlqMetrics runJob)
          assertEqual "main queue is empty after dead-lettering" 0 (queueLength mainMetrics)
          assertEqual "DLQ contains the permanent message" 1 (queueLength dlqMetrics),
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

assertDone :: String -> JobOutcome -> IO ()
assertDone _label Done = pure ()
assertDone label other = assertFailure (label <> ": expected Done, got " <> show other)

assertRetryDefault :: String -> JobOutcome -> IO ()
assertRetryDefault _label RetryDefault = pure ()
assertRetryDefault label other = assertFailure (label <> ": expected RetryDefault, got " <> show other)

assertDeadWith :: String -> Text -> JobOutcome -> IO ()
assertDeadWith label prefix = \case
  Dead detail -> assertBool (label <> ": missing prefix in " <> Text.unpack detail) (prefix `Text.isPrefixOf` detail)
  other -> assertFailure (label <> ": expected Dead, got " <> show other)

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
