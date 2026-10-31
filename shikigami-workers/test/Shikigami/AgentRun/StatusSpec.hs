module Shikigami.AgentRun.StatusSpec (tests) where

import Control.Exception qualified as Exception
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Effectful (Eff, IOE, (:>))
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Keiro.PGMQ (JobOutcome (..))
import Keiro.PGMQ qualified as Job
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), runWorkflow, step)
import Keiro.Workflow.Instance (WorkflowStatus (..), cancelWorkflow, lookupInstance)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (runStoreIO)
import Pgmq qualified
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (..), compatibilityIdentity)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (..), runJobWorkflowId)
import Shikigami.Agent.RunJob.Worker (admitRunJobWith, recordRunJobOutcome)
import Shikigami.Agent.Workflow (StepResult (..))
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.AgentRun.Ledger qualified as Ledger
import Shikigami.AgentRun.RequestKey
import Shikigami.AgentRun.Status
import Shikigami.Directory qualified as Directory
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport
import Shikigami.Prelude hiding (repeated, view, (.=))
import Shikigami.RunJobs qualified as RunJobs
import Shikigami.Trigger.Enqueue
import Test.Tasty
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "run status composition"
    [ testCase "automatic retry exhaustion is reconciled without a receipt callback" $
        withFixture fixture \store job connection -> do
          -- Five expired leases consume the generated retry budget without a workflow.
          forM_ ([1 .. 5] :: [Int]) \_ -> do
            _ <- right =<< Pool.use store.pool (Pgmq.readMessage (Pgmq.ReadMessage runQueueName 0 (Just 1) Nothing))
            pure ()
          calls <- newIORef (0 :: Int)
          _ <- Job.withJobRuntime connection Nothing \runtime -> do
            result <-
              Job.runJobEff
                runtime
                ( Job.ensureJobQueue RunJobs.runJob >> Job.runJobOnce 1 RunJobs.runJob \decoded -> do
                    liftIO (modifyIORef' calls (+ 1))
                    liftIO (recordRunJobOutcome Log.silentLogger store.pool decoded (Dead "exhausted"))
                    pure (Dead "exhausted")
                )
            right result
          readIORef calls >>= (@?= 0)
          metrics <- Job.withJobRuntime connection Nothing \runtime -> right =<< Job.runJobEff runtime (Job.jobDlqMetrics RunJobs.runJob)
          metrics.queueLength @?= 1
          view <- getStatus store job
          view.lifecycle @?= Failed
          fmap (.kind) view.failure @?= Just DeadLettered
          fmap (.reason) view.failure @?= Just "max_retries_exceeded"
          assertBool "reconciled failure has a completion time" (isJust view.completedAt)
          -- Retention after observation: removing the original queue evidence must
          -- not undo the committed receipt or change its completion timestamp.
          _ <- Job.withJobRuntime connection Nothing \runtime -> right =<< Job.runJobEff runtime (Job.archiveDlq RunJobs.runJob 100)
          _ <- Job.withJobRuntime connection Nothing \runtime -> right =<< Job.runJobEff runtime (Job.purgeDlq RunJobs.runJob)
          repeated <- getStatus store job
          repeated @?= view,
      testCase "reconciliation targets the original queue id and leaves unrelated dead letters available" $
        withFixture fixture \store job _connection -> do
          accepted <- acceptedRequest store job
          other <- sendDeadLetter store (accepted.queueMessageId + 1) (Aeson.String "other failure")
          _ <- sendDeadLetter store accepted.queueMessageId (Aeson.String "matching failure")
          view <- getStatus store job
          fmap (.reason) view.failure @?= Just "matching failure"
          visible <- right =<< Pool.use store.pool (Pgmq.readMessage (Pgmq.ReadMessage RunJobs.runJob.jobQueue.dlqName 0 (Just 10) Nothing))
          length visible @?= 2
          assertBool "unrelated entry was never read" (any (\entry -> entry.messageId == other && entry.readCount == 1) visible),
      testCase "an operator lease is temporary absence and is reconciled after expiry" $
        withFixture fixture \store job _connection -> do
          accepted <- acceptedRequest store job
          messageId <- sendDeadLetter store accepted.queueMessageId (Aeson.String "retained failure")
          _ <- right =<< Pool.use store.pool (Pgmq.readMessage (Pgmq.ReadMessage RunJobs.runJob.jobQueue.dlqName 30 (Just 1) Nothing))
          hidden <- getStatus store job
          hidden.lifecycle @?= Accepted
          _ <- right =<< Pool.use store.pool (Pgmq.changeVisibilityTimeout (Pgmq.VisibilityTimeoutQuery RunJobs.runJob.jobQueue.dlqName messageId 0))
          visible <- getStatus store job
          visible.lifecycle @?= Failed,
      testCase "malformed evidence is unavailable and its queue read is rolled back" $
        withFixture fixture \store job _connection -> do
          accepted <- acceptedRequest store job
          messageId <- sendDeadLetter store accepted.queueMessageId (Aeson.Number 7)
          deriveRunStatus store job.agentName (runJobWorkflowId job).unWorkflowId >>= \case
            Left _ -> pure ()
            result -> assertFailure ("malformed evidence was a lifecycle: " <> show result)
          unchanged <- acceptedRequest store job
          unchanged.disposition @?= Ledger.RunAccepted
          messages <- right =<< Pool.use store.pool (Pgmq.readMessage (Pgmq.ReadMessage RunJobs.runJob.jobQueue.dlqName 0 (Just 1) Nothing))
          case toList messages of
            [entry] -> do
              entry.messageId @?= messageId
              entry.readCount @?= 1
            _ -> assertFailure "malformed evidence was lost",
      testCase "a receipt write failure rolls back the queue read and can be retried" $
        withFixture fixture \store job _connection -> do
          accepted <- acceptedRequest store job
          _ <- sendDeadLetter store accepted.queueMessageId (Aeson.String "retryable receipt failure")
          _ <- right =<< Pool.use store.pool (Session.script "ALTER TABLE shikigami.agent_run_requests ADD CONSTRAINT simulate_receipt_failure CHECK (disposition <> 'dead_lettered')")
          deriveRunStatus store job.agentName (runJobWorkflowId job).unWorkflowId >>= \case
            Left _ -> pure ()
            _ -> assertFailure "failed receipt write was reported as a lifecycle"
          _ <- right =<< Pool.use store.pool (Session.script "ALTER TABLE shikigami.agent_run_requests DROP CONSTRAINT simulate_receipt_failure")
          recovered <- getStatus store job
          recovered.lifecycle @?= Failed
          fmap (.reason) recovered.failure @?= Just "retryable receipt failure",
      testCase "accepted, running and cancellation follow durable workflow facts" $
        withFixture fixture \store job _connection -> do
          view <- getStatus store job
          view.lifecycle @?= Accepted
          _ <- Exception.try @Exception.SomeException (runStoreIO store (runWorkflow agentRunWorkflowName (runJobWorkflowId job) (crashAfterIngest job)))
          running <- getStatus store job
          running.lifecycle @?= Running
          _ <- right =<< runStoreIO store (cancelWorkflow agentRunWorkflowName (runJobWorkflowId job))
          cancelled <- getStatus store job
          cancelled.lifecycle @?= Cancelled,
      testCase "completion requires a successful complete step and enforces the agent join" $
        withFixture fixture \store job _connection -> do
          _ <-
            right
              =<< runStoreIO
                store
                ( runWorkflow agentRunWorkflowName (runJobWorkflowId job) do
                    _ <- step (StepName "ingest-job") (pure job)
                    step (StepName "complete") (pure (StepProduced ()))
                )
          view <- getStatus store job
          view.lifecycle @?= Succeeded
          deriveRunStatus store (fixtureAgentName "other") (runJobWorkflowId job).unWorkflowId >>= (@?= Right Nothing),
      testCase "a normally completed workflow without complete is a behavior failure" $
        withFixture fixture \store job _connection -> do
          _ <- right =<< runStoreIO store (runWorkflow agentRunWorkflowName (runJobWorkflowId job) (pure ()))
          view <- getStatus store job
          view.lifecycle @?= Failed
          fmap (.kind) view.failure @?= Just BehaviorFailed
          row <- right =<< runStoreIO store (lookupInstance agentRunWorkflowName (runJobWorkflowId job))
          case row of
            Just instance_ -> do
              let facts = RunFacts Nothing (Just (instance_ & #status .~ WfFailed & #lastError .~ Just "workflow failed")) mempty Nothing Nothing
              fmap (.kind) (classifyRun job.agentName (runJobWorkflowId job).unWorkflowId facts).failure @?= Just WorkflowFailed
            Nothing -> assertFailure "workflow instance missing",
      testCase "worker dead letters close pre-workflow acceptance, without inventing rows" $
        withFixture fixture \store job _connection -> do
          recordRunJobOutcome Log.silentLogger store.pool job (Dead "retry budget exhausted")
          view <- getStatus store job
          view.lifecycle @?= Failed
          fmap (.kind) view.failure @?= Just DeadLettered
          assertBool "terminal disposition has a completion time" (isJust view.completedAt)
          let unrelated = job & #idempotencyKey .~ Ledger.httpRunKey (fixtureAgentName "heartbeat") (fixtureRequestKey "not-http-accepted")
          recordRunJobOutcome Log.silentLogger store.pool unrelated (Dead "unrelated")
          Ledger.lookupRunRequest store.pool unrelated.agentName (runJobWorkflowId unrelated).unWorkflowId >>= (@?= Right Nothing),
      testCase "drain lifecycle refusal is terminal and storage failure stays an error" $
        withFixture fixture \store job _connection -> do
          declaration <- right =<< loadAgent "../agents/heartbeat.dhall"
          directory <- Directory.newDirectoryHandle (Directory.staticDirectorySource [Directory.PrincipalRecord "agent_heartbeat" "heartbeat" Directory.Paused])
          _ <- Directory.refreshDirectory directory
          _ <- admitRunJobWith store.pool directory [declaration] (job & #identity .~ UnresolvedLegacyIdentity)
          view <- getStatus store job
          view.lifecycle @?= Failed
          fmap (.kind) view.failure @?= Just Refused
          _ <- right =<< Pool.use store.pool (Session.script "DROP TABLE shikigami.agent_run_requests")
          deriveRunStatus store job.agentName (runJobWorkflowId job).unWorkflowId >>= \case
            Left _ -> pure ()
            _ -> assertFailure "store failure was rendered as a lifecycle"
    ]

crashAfterIngest :: (Workflow :> es, IOE :> es) => RunJob -> Eff es ()
crashAfterIngest job = do
  _ <- step (StepName "ingest-job") (pure job)
  liftIO (ioError (userError "simulated interruption"))

getStatus :: KirokuStore -> RunJob -> IO RunStatusView
getStatus store job = do
  result <- right =<< deriveRunStatus store job.agentName (runJobWorkflowId job).unWorkflowId
  maybe (assertFailure "missing status") pure result

withFixture :: DatabaseFixture -> (KirokuStore -> RunJob -> Text -> IO a) -> IO a
withFixture fixture body = withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
  _ <- right =<< ensureRunQueue store.pool
  now <- getCurrentTime
  let job = addressedRunJob now (compatibilityIdentity (fixtureAgentName "heartbeat")) (fixtureAgentName "heartbeat") AgentWorkflowRoute (Aeson.object []) (Ledger.httpRunKey (fixtureAgentName "heartbeat") (fixtureRequestKey "status-test"))
  _ <- right =<< Ledger.acceptRunRequest store.pool job (fixtureRequestKey "status-test") "test"
  body store job connection

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

acceptedRequest :: KirokuStore -> RunJob -> IO Ledger.RunRequestRow
acceptedRequest store job = do
  row <- right =<< Ledger.lookupRunRequest store.pool job.agentName (runJobWorkflowId job).unWorkflowId
  maybe (assertFailure "missing accepted request") pure row

sendDeadLetter :: KirokuStore -> Int64 -> Aeson.Value -> IO Pgmq.MessageId
sendDeadLetter store originalId reason =
  right =<< Pool.use store.pool (Pgmq.sendMessage (Pgmq.SendMessage RunJobs.runJob.jobQueue.dlqName (Pgmq.MessageBody body) Nothing))
  where
    body = Aeson.object ["original_message_id" .= originalId, "original_message" .= Aeson.Null, "dead_letter_reason" .= reason]

fixtureRequestKey :: Text -> RequestKey
fixtureRequestKey = either (error . show) id . parseRequestKey

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName
