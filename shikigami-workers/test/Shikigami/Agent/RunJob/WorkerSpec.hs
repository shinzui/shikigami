{-# LANGUAGE TypeApplications #-}

module Shikigami.Agent.RunJob.WorkerSpec (tests) where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception)
import Control.Exception qualified as Exception
import Data.Aeson qualified as Aeson
import Data.Foldable (for_)
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
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (..), TriggerKind (..))
import Shikigami.Agent.RunJob.Worker (RunRoute (..), agentJobOutcome, conversationJobOutcome, routeErrorJobOutcome, routeRunJob, runJob, transientBehaviorJobOutcome, withVisibilityHeartbeatEvery)
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Behavior.Error (TransientBehaviorFailure (..))
import Shikigami.Integration.Danwa (AddressedMessage (..))
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
          (transientBehaviorJobOutcome (TransientBehaviorFailure "retry"))
        assertDeadWith
          "route error"
          "shikigami.invalid_route_payload:"
          (routeErrorJobOutcome "not an addressed message"),
      -- Routing is declared, not guessed. Before this table the worker decided
      -- by trying to decode the payload as an addressed message, so a schedule
      -- job whose payload happened to look addressed ran as a conversation and a
      -- genuinely addressed payload that failed to decode ran as an agent run.
      testCase "schedule job with addressed-looking payload routes to agent-run" do
        assertAgentRun
          "an explicit agent-run route ignores the payload's shape"
          (routeRunJob sampleJob {triggerKind = TriggeredBySchedule, routeKind = AgentWorkflowRoute, triggerPayload = Aeson.toJSON sampleAddressed}),
      testCase "event job on the danwa event type routes to conversation" do
        assertConversation
          "a declared conversation route with a decodable payload"
          (routeRunJob sampleJob {routeKind = ConversationWorkflowRoute, triggerPayload = Aeson.toJSON sampleAddressed}),
      testCase "undecodable payload on a conversation route dead-letters" do
        assertRouteError
          "a declared conversation route with an undecodable payload"
          (routeRunJob sampleJob {routeKind = ConversationWorkflowRoute}),
      testCase "a legacy job with no routeKind reproduces the old decision" do
        assertConversation
          "an addressed-looking payload"
          (routeRunJob sampleJob {routeKind = InferredLegacyRoute, triggerPayload = Aeson.toJSON sampleAddressed})
        assertAgentRun
          "anything else"
          (routeRunJob sampleJob {routeKind = InferredLegacyRoute}),
      testCase "trigger kind does not affect any route" do
        let kinds = [TriggeredBySchedule, TriggeredByStream, TriggeredByEvent, TriggeredByDelegation]
        for_ kinds \kind -> do
          assertAgentRun
            ("agent-run route under " <> show kind)
            (routeRunJob sampleJob {triggerKind = kind, routeKind = AgentWorkflowRoute})
          assertConversation
            ("conversation route under " <> show kind)
            (routeRunJob sampleJob {triggerKind = kind, routeKind = ConversationWorkflowRoute, triggerPayload = Aeson.toJSON sampleAddressed}),
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
      -- The routing decision and its outcome mapping are the real ones here; only
      -- the workflow bodies behind them are absent. That is what makes this a
      -- proof that a mis-declared route lands in the operator-visible DLQ rather
      -- than quietly running the other workflow.
      testCase "a route error reaches the reconciled DLQ" do
        withShikigamiMigratedDatabase \connStr -> do
          let tuning = requireTuning (mkJobTuning 2 1 (PollEvery 0.1))
              misdeclared = sampleJob {routeKind = ConversationWorkflowRoute}
          reachedDlq <-
            runDb connStr \runtime ->
              runJobEff runtime do
                ensureJobQueue runJob
                ensureJobQueue runJob
                _ <- enqueue runJob misdeclared
                appResult <-
                  runJobWorkers
                    IgnoreFailures
                    16
                    [ jobProcessorWithContext tuning runJob \_context payload ->
                        pure case routeRunJob payload of
                          RouteError detail -> routeErrorJobOutcome detail
                          _ -> Done
                    ]
                case appResult of
                  Left err -> liftIO (assertFailure ("runJobWorkers failed: " <> show err))
                  Right app -> do
                    reached <- liftIO $ waitUntil do
                      metrics <- runDb connStr \probeRuntime -> runJobEff probeRuntime (jobDlqMetrics runJob)
                      pure (queueLength metrics == 1)
                    _ <- stopAppGracefully ShutdownConfig {drainTimeout = 1} app
                    pure reached
          assertBool "the mis-declared job reached the DLQ" reachedDlq
          mainMetrics <- runDb connStr \runtime -> runJobEff runtime (jobQueueMetrics runJob)
          assertEqual "main queue is empty after dead-lettering" 0 (queueLength mainMetrics),
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

assertAgentRun :: String -> RunRoute -> IO ()
assertAgentRun _label AgentRunRoute = pure ()
assertAgentRun label other = assertFailure (label <> ": expected AgentRunRoute, got " <> showRoute other)

assertConversation :: String -> RunRoute -> IO ()
assertConversation _label (ConversationRoute _) = pure ()
assertConversation label other = assertFailure (label <> ": expected ConversationRoute, got " <> showRoute other)

assertRouteError :: String -> RunRoute -> IO ()
assertRouteError _label (RouteError _) = pure ()
assertRouteError label other = assertFailure (label <> ": expected RouteError, got " <> showRoute other)

showRoute :: RunRoute -> String
showRoute = \case
  ConversationRoute _ -> "ConversationRoute"
  AgentRunRoute -> "AgentRunRoute"
  RouteError detail -> "RouteError " <> Text.unpack detail

sampleAddressed :: AddressedMessage
sampleAddressed =
  AddressedMessage
    { conversationId = "conv_1",
      messageId = "msg_1",
      parentMessageId = Nothing,
      author = "person_1",
      content = "how are the numbers?",
      agentParticipantId = "participant_1",
      embellishmentId = "emb_1",
      mentionedBy = "person_1",
      occurredAt = UTCTime (fromGregorian 2026 8 19) 0
    }

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
      routeKind = AgentWorkflowRoute,
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
