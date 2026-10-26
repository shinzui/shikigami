module Shikigami.AgentRun.StatusSpec (tests) where

import Control.Exception qualified as Exception
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Effectful (Eff, IOE, liftIO, (:>))
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Keiro.PGMQ (JobOutcome (..))
import Keiro.PGMQ qualified as Job
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), loadStepIndex, runWorkflow, step)
import Keiro.Workflow.Instance (WorkflowStatus (..), cancelWorkflow, lookupInstance)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (runStoreIO)
import Pgmq qualified
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (AgentIdentity (..), compatibilityIdentity)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (..), runJobWorkflowId)
import Shikigami.Agent.RunJob.Worker (admitRunJobWith, recordRunJobOutcome)
import Shikigami.Agent.Workflow (StepResult (..))
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.AgentRun.Ledger qualified as Ledger
import Shikigami.AgentRun.Status
import Shikigami.Directory qualified as Directory
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport
import Shikigami.Prelude
import Shikigami.RunJobs qualified as RunJobs
import Shikigami.Trigger.Enqueue
import Test.Tasty
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "run status composition"
    [ testCase "external gate: automatic retry exhaustion bypasses the receipt hook" $
        withFixture fixture \store job connection -> do
          -- Five expired leases consume the generated retry budget without a workflow.
          -- Replace the accepted assertion with Failed once a supported owning-library
          -- disposition callback is released and wired into both worker/drain paths.
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
          view.lifecycle @?= Accepted,
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
          deriveRunStatus store (AgentName "other") (runJobWorkflowId job).unWorkflowId >>= (@?= Right Nothing),
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
          let unrelated = job & #idempotencyKey .~ Ledger.httpRunKey (AgentName "heartbeat") "not-http-accepted"
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
  let job = addressedRunJob now (compatibilityIdentity "heartbeat") "heartbeat" AgentWorkflowRoute (Aeson.object []) (Ledger.httpRunKey (AgentName "heartbeat") "status-test")
  _ <- right =<< Ledger.acceptRunRequest store.pool job "test"
  body store job connection

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure
