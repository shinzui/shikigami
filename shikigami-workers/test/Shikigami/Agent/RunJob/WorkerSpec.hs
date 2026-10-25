{-# LANGUAGE TypeApplications #-}

module Shikigami.Agent.RunJob.WorkerSpec (tests) where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception)
import Control.Exception qualified as Exception
import Data.Aeson qualified as Aeson
import Data.Foldable (for_)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (liftIO, runEff)
import Keiro.PGMQ
  ( DlqEntry (..),
    Job (..),
    JobContext (..),
    JobOutcome (..),
    JobPolling (PollEvery),
    JobRuntime (..),
    JobTuning,
    PgmqRuntimeError,
    PurgeDlqResult (..),
    QueueMetrics (..),
    archiveDlqEntries,
    decodeJob,
    encodeJob,
    enqueue,
    ensureJobQueue,
    jobDlqMetrics,
    jobProcessorWithContext,
    jobQueueMetrics,
    mkJobTuning,
    purgeDlq,
    readDlq,
    runJobEff,
    runJobOnce,
    runJobWorkers,
    withJobRuntime,
  )
import Keiro.Workflow (WorkflowOutcome (..))
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Connection qualified as StoreConnection
import Shibuya.App (ShutdownConfig (..), SupervisionStrategy (IgnoreFailures), stopAppGracefully)
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), IdentityDecl (..), Trigger (..), defaultMemoryPolicy)
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (AgentIdentity (..), compatibilityIdentity, meiboPrincipal, principalText)
import Shikigami.Agent.Run.Key (RunKey (..))
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (..), TriggerKind (..))
import Shikigami.Agent.RunJob.Worker (DrainAdmission (..), RunRoute (..), admitRunJobWith, agentJobOutcome, conversationJobOutcome, drainAdmissionOutcome, routeErrorJobOutcome, routeRunJob, runJob, transientBehaviorJobOutcome, withVisibilityHeartbeatEvery)
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Behavior.Error (TransientBehaviorFailure (..))
import Shikigami.Directory (DirectoryHandle, Lifecycle (..), PrincipalRecord (..), newDirectoryHandle, refreshDirectory, staticDirectorySource)
import Shikigami.Directory.Store qualified as DirectoryStore
import Shikigami.Integration.Danwa (AddressedMessage (..))
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.RunJobs qualified as RunJobs
import Shikigami.Trigger.Enqueue qualified as Enqueue
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: DatabaseFixture -> TestTree
tests databaseFixture =
  testGroup
    "RunJob"
    [ testCase "typed codec uses the generated producer envelope" do
        let payload = sampleJob
            encoded = RunJobs.encodeRunJob payload
            Job {jobCodec = codec} = runJob
        assertEqual "typed decoder accepts the producer payload" (Right payload) (decodeJob codec encoded)
        assertEqual "typed encoder shares the generated wire" encoded (encodeJob codec payload),
      testCase "the real producer is consumed by the generated job contract" do
        withShikigamiFreshDatabase databaseFixture \connStr -> do
          received <- newIORef []
          runDb connStr \runtime -> do
            either (assertFailure . show) pure =<< Enqueue.ensureRunQueue runtime.runtimePool
            _ <- either (assertFailure . show) pure =<< Enqueue.enqueueRunJob runtime.runtimePool sampleJob
            runJobEff runtime do
              ensureJobQueue runJob
              runJobOnce 1 runJob \job -> do
                liftIO (modifyIORef' received (<> [job]))
                pure Done
          assertEqual "one complete domain value crossed the queue" [sampleJob] =<< readIORef received,
      testCase "typed outcome table covers every workflow disposition" do
        assertRetryDefault "store failure" (agentJobOutcome "agent" (Left ()))
        assertDone "completed" (agentJobOutcome "agent" (Right (Completed (Right ()))))
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
      testCase "trigger kind does not affect any route" do
        let kinds = [TriggeredBySchedule, TriggeredByStream, TriggeredByEvent, TriggeredByDelegation]
        for_ kinds \kind -> do
          assertAgentRun
            ("agent-run route under " <> show kind)
            (routeRunJob sampleJob {triggerKind = kind, routeKind = AgentWorkflowRoute})
          assertConversation
            ("conversation route under " <> show kind)
            (routeRunJob sampleJob {triggerKind = kind, routeKind = ConversationWorkflowRoute, triggerPayload = Aeson.toJSON sampleAddressed}),
      testCase "drain gate enforces every configured lifecycle decision" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \store -> do
            let pool = StoreConnection.pool store
                jobWith suffix = sampleJob {identity = UnresolvedLegacyIdentity, idempotencyKey = RunKey ("codec-agent:event:" <> suffix)}
            activeDirectory <- directoryWith [principalRecord Active]
            active <- admitRunJobWith pool activeDirectory [drainAgent] (jobWith "active")
            assertAllowedAs "active principal continues" "agent_codec" active

            pausedDirectory <- directoryWith [principalRecord Paused]
            paused <- admitRunJobWith pool pausedDirectory [drainAgent] (jobWith "paused")
            assertSkipped "paused" paused

            deactivatedDirectory <- directoryWith [principalRecord Deactivated]
            deactivated <- admitRunJobWith pool deactivatedDirectory [drainAgent] (jobWith "deactivated")
            assertSkipped "deactivated" deactivated

            unknownDirectory <- directoryWith [PrincipalRecord {principalId = "agent_other", handle = "codec-agent", lifecycle = Active}]
            unknown <- admitRunJobWith pool unknownDirectory [drainAgent] (jobWith "unknown")
            assertSkipped "explicit unknown id does not fall back to handle" unknown

            unavailableDirectory <- newDirectoryHandle (pure (Left "directory offline"))
            unavailable <- admitRunJobWith pool unavailableDirectory [drainAgent] (jobWith "unavailable")
            assertSkipped "unavailable configured directory fails closed" unavailable

            maybe (assertFailure "durable refusal had no terminal outcome") (assertDone "durable refusal acknowledges") (drainAdmissionOutcome paused)
            maybe (assertFailure "audit failure had no terminal outcome") (assertRetryDefault "audit failure retries") (drainAdmissionOutcome (DrainAuditFailed "write failed"))
            skips <- either (assertFailure . Text.unpack) pure =<< DirectoryStore.listRunSkips pool
            assertEqual
              "only the four refusals were recorded"
              [ "codec-agent:event:paused",
                "codec-agent:event:deactivated",
                "codec-agent:event:unknown",
                "codec-agent:event:unavailable"
              ]
              ((.idempotencyKey) <$> skips),
      testCase "worker-path heartbeat keeps one slow delivery leased" do
        (withShikigamiFreshDatabase databaseFixture) \connStr -> do
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
        (withShikigamiFreshDatabase databaseFixture) \connStr -> do
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
      testCase "operator-visible DLQ entries can be retained and safely purged" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          runDb connStr \runtime ->
            runJobEff runtime do
              ensureJobQueue runJob
              _ <- enqueue runJob sampleJob
              _ <- runJobOnce 1 runJob (const (pure (Dead "operator qualification")))
              entries <- readDlq runJob 10
              case entries of
                [entry] -> do
                  liftIO (assertEqual "DLQ retains the original payload" (Right sampleJob) entry.originalPayload)
                  archived <- archiveDlqEntries runJob [entry.dlqMessageId]
                  liftIO (assertEqual "the inspected row is archived by exact id" [entry.dlqMessageId] archived)
                  purged <- purgeDlq runJob
                  liftIO (assertEqual "no active row remains after archival" (PurgeDlqPurged 0) purged)
                other -> liftIO (assertFailure ("expected one operator-visible DLQ entry, got " <> show other)),
      -- The routing decision and its outcome mapping are the real ones here; only
      -- the workflow bodies behind them are absent. That is what makes this a
      -- proof that a mis-declared route lands in the operator-visible DLQ rather
      -- than quietly running the other workflow.
      testCase "a route error reaches the reconciled DLQ" do
        (withShikigamiFreshDatabase databaseFixture) \connStr -> do
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
    { agentName = AgentName "codec-agent",
      identity = compatibilityIdentity "codec-agent",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 8 19) 0,
      triggerPayload = Aeson.object ["kind" Aeson..= ("test" :: Text)],
      idempotencyKey = RunKey "codec-agent:event:1",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      delegationBudgetId = Nothing
    }

drainAgent :: AgentDecl
drainAgent =
  AgentDecl
    { name = "codec-agent",
      description = "drain lifecycle fixture",
      trigger = Event {eventType = "fixture.event"},
      behavior = Deterministic {rule = "test", params = Map.empty},
      sinks = [],
      delegates = [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Just IdentityDecl {principal = "agent_codec"},
      memory = defaultMemoryPolicy,
      enabled = True,
      expertise = [],
      decisionModels = [],
      routing = Nothing
    }

principalRecord :: Lifecycle -> PrincipalRecord
principalRecord lifecycle = PrincipalRecord {principalId = "agent_codec", handle = "codec-agent", lifecycle}

directoryWith :: [PrincipalRecord] -> IO DirectoryHandle
directoryWith principals = do
  directory <- newDirectoryHandle (staticDirectorySource principals)
  refreshDirectory directory >>= \case
    Left problem -> assertFailure (Text.unpack problem)
    Right () -> pure directory

assertSkipped :: String -> DrainAdmission -> IO ()
assertSkipped _ (DrainSkipped runSkip) =
  assertEqual "drain stage" DirectoryStore.DrainStage ((.stage) runSkip)
assertSkipped label other = assertFailure (label <> ": expected DrainSkipped, got " <> show other)

assertAllowedAs :: String -> Text -> DrainAdmission -> IO ()
assertAllowedAs _ expectedPrincipal (DrainAllowed RunJob {identity}) =
  assertEqual "admitted principal" (Just expectedPrincipal) (principalText <$> meiboPrincipal identity)
assertAllowedAs label _ other = assertFailure (label <> ": expected DrainAllowed, got " <> show other)

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
