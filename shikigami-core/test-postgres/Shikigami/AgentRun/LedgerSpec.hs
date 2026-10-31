module Shikigami.AgentRun.LedgerSpec (tests) where

import Control.Concurrent.Async (replicateConcurrently)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Vector qualified as Vector
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Pgmq qualified
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Agent.RunJob (RunRouteKind (..), runJobWorkflowId)
import Shikigami.AgentRun.Ledger
import Shikigami.AgentRun.RequestKey
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
          let key = fixtureRequestKey "ledger-1"
              job = addressedRunJob now (compatibilityIdentity "heartbeat") "heartbeat" AgentWorkflowRoute (Aeson.object []) (httpRunKey (AgentName "heartbeat") key)
          accepted <- right =<< acceptRunRequest store.pool job key "test-caller"
          row <- case accepted of Accepted row -> pure row; _ -> assertFailure "first request was not accepted"
          acceptRunRequest store.pool job key "other-caller" >>= (@?= Right (Replayed row))
          conflict <- right =<< acceptRunRequest store.pool (job & #triggerPayload .~ Aeson.object ["other" .= True]) key "test-caller"
          conflict @?= Conflicting row
          lookupRunRequest store.pool (AgentName "heartbeat") row.runId >>= (@?= Right (Just row))
          metrics <- right =<< Pool.use store.pool (Pgmq.queueMetrics runQueueName)
          metrics.queueLength @?= 1
          messages <- right =<< Pool.use store.pool (Pgmq.readMessage (Pgmq.ReadMessage runQueueName 30 (Just 10) Nothing))
          fmap (\message -> message.body.unMessageBody) (Vector.toList messages) @?= [encodeRunJob job],
      testCase "separator-bearing HTTP coordinates accept independent ledger rows and sends" $
        withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
          _ <- right =<< ensureRunQueue store.pool
          now <- getCurrentTime
          let firstKey = fixtureRequestKey "c"
              secondKey = fixtureRequestKey "b:http:c"
              firstAgent = AgentName "a:http:b"
              secondAgent = AgentName "a"
              first = addressedRunJob now (compatibilityIdentity "first") "a:http:b" AgentWorkflowRoute (Aeson.object []) (httpRunKey firstAgent firstKey)
              second = addressedRunJob now (compatibilityIdentity "second") "a" AgentWorkflowRoute (Aeson.object []) (httpRunKey secondAgent secondKey)
          firstResult <- right =<< acceptRunRequest store.pool first firstKey "caller"
          secondResult <- right =<< acceptRunRequest store.pool second secondKey "caller"
          firstRow <- case firstResult of Accepted row -> pure row; _ -> assertFailure "first coordinate was not freshly accepted"
          secondRow <- case secondResult of Accepted row -> pure row; _ -> assertFailure "second coordinate was not freshly accepted"
          assertBool "workflow identities differ" (firstRow.runId /= secondRow.runId)
          firstRow.idempotencyKey @?= firstKey
          secondRow.idempotencyKey @?= secondKey
          acceptRunRequest store.pool first firstKey "different-caller" >>= (@?= Right (Replayed firstRow))
          acceptRunRequest store.pool second secondKey "different-caller" >>= (@?= Right (Replayed secondRow))
          metrics <- right =<< Pool.use store.pool (Pgmq.queueMetrics runQueueName)
          metrics.queueLength @?= 2,
      testCase "mismatched HTTP key coordinates refuse before queue or ledger writes" $
        withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
          _ <- right =<< ensureRunQueue store.pool
          now <- getCurrentTime
          let firstKey = fixtureRequestKey "original"
              secondKey = fixtureRequestKey "substituted"
              job = addressedRunJob now (compatibilityIdentity "heartbeat") "heartbeat" AgentWorkflowRoute (Aeson.object []) (httpRunKey (AgentName "heartbeat") firstKey)
          acceptRunRequest store.pool job secondKey "caller" >>= (@?= Left "HTTP run key does not match its acceptance coordinates.")
          lookupRunRequest store.pool (AgentName "heartbeat") (runJobWorkflowId job).unWorkflowId >>= (@?= Right Nothing)
          metrics <- right =<< Pool.use store.pool (Pgmq.queueMetrics runQueueName)
          metrics.queueLength @?= 0,
      testCase "twenty concurrent accepts commit one send" $
        withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
          _ <- right =<< ensureRunQueue store.pool
          now <- getCurrentTime
          let key = fixtureRequestKey "race"
              job = addressedRunJob now (compatibilityIdentity "heartbeat") "heartbeat" AgentWorkflowRoute (Aeson.object []) (httpRunKey (AgentName "heartbeat") key)
          outcomes <- replicateConcurrently 20 (acceptRunRequest store.pool job key "racer") >>= traverse right
          length [() | Accepted _ <- outcomes] @?= 1
          length [() | Replayed _ <- outcomes] @?= 19
          metrics <- right =<< Pool.use store.pool (Pgmq.queueMetrics runQueueName)
          metrics.queueLength @?= 1,
      testCase "an unavailable ledger reports a store error" $
        withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
          now <- getCurrentTime
          _ <- right =<< ensureRunQueue store.pool
          _ <- right =<< Pool.use store.pool (Session.script "DROP TABLE shikigami.agent_run_requests")
          let key = fixtureRequestKey "closed"
              job = addressedRunJob now (compatibilityIdentity "heartbeat") "heartbeat" AgentWorkflowRoute (Aeson.object []) (httpRunKey (AgentName "heartbeat") key)
          result <- acceptRunRequest store.pool job key "test-caller"
          case result of Left _ -> pure (); _ -> assertFailure "unavailable ledger accepted a run"
          metrics <- right =<< Pool.use store.pool (Pgmq.queueMetrics runQueueName)
          metrics.queueLength @?= 0
    ]

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

fixtureRequestKey :: Text -> RequestKey
fixtureRequestKey = either (error . show) id . parseRequestKey
