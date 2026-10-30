module Shikigami.AgentRun.LedgerSpec (tests) where

import Control.Concurrent.Async (replicateConcurrently)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Vector qualified as Vector
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Pgmq qualified
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Agent.RunJob (RunRouteKind (..))
import Shikigami.AgentRun.Ledger
import Shikigami.Migrations.TestSupport
import Shikigami.Prelude hiding ((.=))
import Shikigami.RunJobs (encodeRunJob)
import Shikigami.Trigger.Enqueue
import Test.Tasty
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "HTTP acceptance ledger"
    [ testCase "accept, replay and conflict leave exactly one queue message" $
        withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
          _ <- right =<< ensureRunQueue store.pool
          now <- getCurrentTime
          let job = addressedRunJob now (compatibilityIdentity "heartbeat") "heartbeat" AgentWorkflowRoute (Aeson.object []) (httpRunKey (AgentName "heartbeat") "ledger-1")
          accepted <- right =<< acceptRunRequest store.pool job "test-caller"
          row <- case accepted of Accepted row -> pure row; _ -> assertFailure "first request was not accepted"
          acceptRunRequest store.pool job "other-caller" >>= (@?= Right (Replayed row))
          conflict <- right =<< acceptRunRequest store.pool (job & #triggerPayload .~ Aeson.object ["other" .= True]) "test-caller"
          conflict @?= Conflicting row
          lookupRunRequest store.pool (AgentName "heartbeat") row.runId >>= (@?= Right (Just row))
          metrics <- right =<< Pool.use store.pool (Pgmq.queueMetrics runQueueName)
          metrics.queueLength @?= 1
          messages <- right =<< Pool.use store.pool (Pgmq.readMessage (Pgmq.ReadMessage runQueueName 30 (Just 10) Nothing))
          fmap (\message -> message.body.unMessageBody) (Vector.toList messages) @?= [encodeRunJob job],
      testCase "twenty concurrent accepts commit one send" $
        withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
          _ <- right =<< ensureRunQueue store.pool
          now <- getCurrentTime
          let job = addressedRunJob now (compatibilityIdentity "heartbeat") "heartbeat" AgentWorkflowRoute (Aeson.object []) (httpRunKey (AgentName "heartbeat") "race")
          outcomes <- replicateConcurrently 20 (acceptRunRequest store.pool job "racer") >>= traverse right
          length [() | Accepted _ <- outcomes] @?= 1
          length [() | Replayed _ <- outcomes] @?= 19
          metrics <- right =<< Pool.use store.pool (Pgmq.queueMetrics runQueueName)
          metrics.queueLength @?= 1,
      testCase "an unavailable ledger reports a store error" $
        withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
          now <- getCurrentTime
          _ <- right =<< ensureRunQueue store.pool
          _ <- right =<< Pool.use store.pool (Session.script "DROP TABLE shikigami.agent_run_requests")
          let job = addressedRunJob now (compatibilityIdentity "heartbeat") "heartbeat" AgentWorkflowRoute (Aeson.object []) (httpRunKey (AgentName "heartbeat") "closed")
          result <- acceptRunRequest store.pool job "test-caller"
          case result of Left _ -> pure (); _ -> assertFailure "unavailable ledger accepted a run"
          metrics <- right =<< Pool.use store.pool (Pgmq.queueMetrics runQueueName)
          metrics.queueLength @?= 0
    ]

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure
