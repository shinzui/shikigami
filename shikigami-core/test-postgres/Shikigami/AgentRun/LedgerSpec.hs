module Shikigami.AgentRun.LedgerSpec (tests) where

import Control.Concurrent.Async (replicateConcurrently)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as Transactions
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Pgmq qualified
import Relay.Pagination qualified as Page
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Agent.Run.Key (runKeyText)
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
    [ testCase "corrupt accepted metadata refuses reads and rolls back ignored refusals" (corruptAcceptance fixture),
      testCase "accept, replay and conflict leave exactly one queue message" $
        withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
          _ <- right =<< ensureRunQueue store.pool
          now <- getCurrentTime
          let key = fixtureRequestKey "ledger-1"
              job = addressedRunJob now (compatibilityIdentity (fixtureAgentName "heartbeat")) (fixtureAgentName "heartbeat") AgentWorkflowRoute (Aeson.object []) (httpRunKey (fixtureAgentName "heartbeat") key)
          accepted <- right =<< acceptRunRequest store.pool job key (callerAttribution "test-caller")
          row <- case accepted of Accepted row -> pure row; _ -> assertFailure "first request was not accepted"
          acceptRunRequest store.pool job key (callerAttribution "other-caller") >>= (@?= Right (Replayed row))
          conflict <- right =<< acceptRunRequest store.pool (job & #triggerPayload .~ Aeson.object ["other" .= True]) key (callerAttribution "test-caller")
          conflict @?= Conflicting row
          lookupRunRequest store.pool (fixtureAgentName "heartbeat") row.runId >>= (@?= Right (Just row))
          metrics <- right =<< Pool.use store.pool (Pgmq.queueMetrics runQueueName)
          metrics.queueLength @?= 1
          row.runId @?= runJobWorkflowId job
          callerAttributionText row.requestedBy @?= "test-caller"
          messages <- right =<< Pool.use store.pool (Pgmq.readMessage (Pgmq.ReadMessage runQueueName 30 (Just 10) Nothing))
          fmap (\message -> message.body.unMessageBody) (Vector.toList messages) @?= [encodeRunJob job]
          fmap (.messageId) (Vector.toList messages) @?= [row.queueMessageId],
      testCase "separator-bearing HTTP coordinates accept independent ledger rows and sends" $
        withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
          _ <- right =<< ensureRunQueue store.pool
          now <- getCurrentTime
          let firstKey = fixtureRequestKey "c"
              secondKey = fixtureRequestKey "b:http:c"
              firstAgent = fixtureAgentName "a:http:b"
              secondAgent = fixtureAgentName "a"
              first = addressedRunJob now (compatibilityIdentity (fixtureAgentName "first")) (fixtureAgentName "a:http:b") AgentWorkflowRoute (Aeson.object []) (httpRunKey firstAgent firstKey)
              second = addressedRunJob now (compatibilityIdentity (fixtureAgentName "second")) (fixtureAgentName "a") AgentWorkflowRoute (Aeson.object []) (httpRunKey secondAgent secondKey)
          firstResult <- right =<< acceptRunRequest store.pool first firstKey (callerAttribution "caller")
          secondResult <- right =<< acceptRunRequest store.pool second secondKey (callerAttribution "caller")
          firstRow <- case firstResult of Accepted row -> pure row; _ -> assertFailure "first coordinate was not freshly accepted"
          secondRow <- case secondResult of Accepted row -> pure row; _ -> assertFailure "second coordinate was not freshly accepted"
          assertBool "workflow identities differ" (firstRow.runId /= secondRow.runId)
          firstRow.idempotencyKey @?= firstKey
          secondRow.idempotencyKey @?= secondKey
          acceptRunRequest store.pool first firstKey (callerAttribution "different-caller") >>= (@?= Right (Replayed firstRow))
          acceptRunRequest store.pool second secondKey (callerAttribution "different-caller") >>= (@?= Right (Replayed secondRow))
          metrics <- right =<< Pool.use store.pool (Pgmq.queueMetrics runQueueName)
          metrics.queueLength @?= 2,
      testCase "mismatched HTTP key coordinates refuse before queue or ledger writes" $
        withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
          _ <- right =<< ensureRunQueue store.pool
          now <- getCurrentTime
          let firstKey = fixtureRequestKey "original"
              secondKey = fixtureRequestKey "substituted"
              job = addressedRunJob now (compatibilityIdentity (fixtureAgentName "heartbeat")) (fixtureAgentName "heartbeat") AgentWorkflowRoute (Aeson.object []) (httpRunKey (fixtureAgentName "heartbeat") firstKey)
          acceptRunRequest store.pool job secondKey (callerAttribution "caller") >>= (@?= Left "HTTP run key does not match its acceptance coordinates.")
          lookupRunRequest store.pool (fixtureAgentName "heartbeat") (runJobWorkflowId job) >>= (@?= Right Nothing)
          metrics <- right =<< Pool.use store.pool (Pgmq.queueMetrics runQueueName)
          metrics.queueLength @?= 0,
      testCase "twenty concurrent accepts commit one send" $
        withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
          _ <- right =<< ensureRunQueue store.pool
          now <- getCurrentTime
          let key = fixtureRequestKey "race"
              job = addressedRunJob now (compatibilityIdentity (fixtureAgentName "heartbeat")) (fixtureAgentName "heartbeat") AgentWorkflowRoute (Aeson.object []) (httpRunKey (fixtureAgentName "heartbeat") key)
          outcomes <- replicateConcurrently 20 (acceptRunRequest store.pool job key (callerAttribution "racer")) >>= traverse right
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
              job = addressedRunJob now (compatibilityIdentity (fixtureAgentName "heartbeat")) (fixtureAgentName "heartbeat") AgentWorkflowRoute (Aeson.object []) (httpRunKey (fixtureAgentName "heartbeat") key)
          result <- acceptRunRequest store.pool job key (callerAttribution "test-caller")
          case result of Left _ -> pure (); _ -> assertFailure "unavailable ledger accepted a run"
          metrics <- right =<< Pool.use store.pool (Pgmq.queueMetrics runQueueName)
          metrics.queueLength @?= 0
    ]

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

fixtureRequestKey :: Text -> RequestKey
fixtureRequestKey = either (error . show) id . parseRequestKey

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

corruptAcceptance :: DatabaseFixture -> IO ()
corruptAcceptance fixture = withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
  _ <- right =<< ensureRunQueue store.pool
  now <- getCurrentTime
  let agent = fixtureAgentName "heartbeat"
      key = fixtureRequestKey "corruption"
      job = addressedRunJob now (compatibilityIdentity agent) agent AgentWorkflowRoute (Aeson.object []) (httpRunKey agent key)
      siblingKey = fixtureRequestKey "sibling"
      siblingJob = addressedRunJob now (compatibilityIdentity agent) agent AgentWorkflowRoute (Aeson.object []) (httpRunKey agent siblingKey)
      sql query = right =<< Pool.use store.pool (Session.statement () (preparable query E.noParams D.noResult))
      corrupt query = right =<< Pool.use store.pool (Session.statement (runJobWorkflowId job).unWorkflowId (preparable query (E.param (E.nonNullable E.text)) D.noResult))
      transaction :: Tx.Transaction a -> IO a
      transaction action = right =<< Pool.use store.pool (Transactions.transaction Transactions.ReadCommitted Transactions.Write action)
      page = Page.PageRequest 20 Page.Forward Nothing
      refusal = "The retained run acceptance is corrupt."
  lookupRunRequest store.pool agent (WorkflowId "missing") >>= (@?= Right Nothing)
  lookupRunRequestById store.pool (WorkflowId "missing") >>= (@?= Right Nothing)
  Accepted original <- right =<< acceptRunRequest store.pool job key (callerAttribution "caller")
  Accepted sibling <- right =<< acceptRunRequest store.pool siblingJob siblingKey (callerAttribution "caller")
  lookupRunRequestById store.pool original.runId >>= (@?= Right (Just original))
  payloadFingerprintText original.payloadFingerprint @?= "417e0a20-e3f9-59fc-8d1f-f51ab83a4318"
  initial <- right =<< listRunRequests store.pool agent page
  length initial.edges @?= 2
  -- Place the corrupt row beyond the returned edge in a one-element page. The
  -- extra probe must be checked before mkConnection discards it.
  corrupt "UPDATE shikigami.agent_run_requests SET accepted_at=accepted_at - interval '1 day' WHERE run_id=$1"
  ordered <- right =<< listRunRequests store.pool agent (Page.PageRequest 1 Page.Forward Nothing)
  map (.node.runId) ordered.edges @?= [sibling.runId]
  sql "ALTER TABLE shikigami.agent_run_requests DROP CONSTRAINT agent_run_requests_disposition_check"
  let mutations =
        [ ("UPDATE shikigami.agent_run_requests SET idempotency_key='' WHERE run_id=$1", "UPDATE shikigami.agent_run_requests SET idempotency_key='corruption' WHERE run_id=$1"),
          ("UPDATE shikigami.agent_run_requests SET disposition='broken' WHERE run_id=$1", "UPDATE shikigami.agent_run_requests SET disposition='accepted' WHERE run_id=$1"),
          ("UPDATE shikigami.agent_run_requests SET run_key='' WHERE run_id=$1", "UPDATE shikigami.agent_run_requests SET run_key=$2 WHERE run_id=$1"),
          ("UPDATE shikigami.agent_run_requests SET payload_fingerprint='' WHERE run_id=$1", "UPDATE shikigami.agent_run_requests SET payload_fingerprint='417e0a20-e3f9-59fc-8d1f-f51ab83a4318' WHERE run_id=$1"),
          ("UPDATE shikigami.agent_run_requests SET payload_fingerprint='417e0a20-e3f9-49fc-8d1f-f51ab83a4318' WHERE run_id=$1", "UPDATE shikigami.agent_run_requests SET payload_fingerprint='417e0a20-e3f9-59fc-8d1f-f51ab83a4318' WHERE run_id=$1"),
          ("UPDATE shikigami.agent_run_requests SET payload_fingerprint='417e0a20-e3f9-59fc-0d1f-f51ab83a4318' WHERE run_id=$1", "UPDATE shikigami.agent_run_requests SET payload_fingerprint='417e0a20-e3f9-59fc-8d1f-f51ab83a4318' WHERE run_id=$1")
        ]
  mapM_
    ( \(damage, repair) -> do
        corrupt damage
        lookupRunRequest store.pool agent original.runId >>= (@?= Left refusal)
        lookupRunRequestById store.pool original.runId >>= (@?= Left refusal)
        listRunRequests store.pool agent page >>= (@?= Left (RunListUnavailable refusal))
        listRunRequests store.pool agent (Page.PageRequest 1 Page.Forward Nothing) >>= (@?= Left (RunListUnavailable refusal))
        ignored <- transaction do
          Tx.statement () (preparable "UPDATE shikigami.agent_run_requests SET requested_by='must-rollback' WHERE idempotency_key='sibling'" E.noParams D.noResult)
          result <- lookupRunRequestTx agent original.runId
          Tx.statement () (preparable "UPDATE shikigami.agent_run_requests SET disposition_detail='also-rollback' WHERE idempotency_key='sibling'" E.noParams D.noResult)
          pure result
        ignored @?= Left refusal
        lookupRunRequest store.pool agent sibling.runId >>= (@?= Right (Just sibling))
        ignoredList <- transaction do
          Tx.statement () (preparable "UPDATE shikigami.agent_run_requests SET requested_by='must-rollback' WHERE idempotency_key='sibling'" E.noParams D.noResult)
          listRunRequestsTx agent page
        ignoredList @?= Left (RunListUnavailable refusal)
        lookupRunRequest store.pool agent sibling.runId >>= (@?= Right (Just sibling))
        refreshRunDisposition store.pool original >>= (@?= Left refusal)
        when ("payload_fingerprint=" `Text.isInfixOf` damage) (acceptRunRequest store.pool job key (callerAttribution "retry") >>= (@?= Left refusal))
        if "run_key=''" `Text.isInfixOf` damage
          then do
            acceptRunRequest store.pool job key (callerAttribution "retry") >>= (@?= Left refusal)
            _ <- right =<< Pool.use store.pool (Session.statement (original.runId.unWorkflowId, runKeyText original.runKey) (preparable repair ((fst >$< E.param (E.nonNullable E.text)) <> (snd >$< E.param (E.nonNullable E.text))) D.noResult))
            pure ()
          else corrupt repair
        metrics <- right =<< Pool.use store.pool (Pgmq.queueMetrics runQueueName)
        metrics.queueLength @?= 2
    )
    mutations
  corrupt "UPDATE shikigami.agent_run_requests SET agent_name='' WHERE run_id=$1"
  lookupRunRequestById store.pool original.runId >>= (@?= Left refusal)
  corrupt "UPDATE shikigami.agent_run_requests SET agent_name='heartbeat' WHERE run_id=$1"
  -- Recovery returns the retained winner, with no replacement queue message.
  Just recovered <- right =<< lookupRunRequest store.pool agent original.runId
  recovered.runKey @?= original.runKey
  recovered.queueMessageId @?= original.queueMessageId
  acceptRunRequest store.pool job key (callerAttribution "retry") >>= (@?= Right (Replayed recovered))
  sql "ALTER TABLE shikigami.agent_run_requests RENAME TO agent_run_requests_unavailable"
  lookupRunRequest store.pool agent original.runId >>= (@?= Left "The run acceptance store is unavailable.")
  lookupRunRequestById store.pool original.runId >>= (@?= Left "The run acceptance store is unavailable.")
  listRunRequests store.pool agent page >>= (@?= Left (RunListUnavailable "The run acceptance store is unavailable."))
  sql "ALTER TABLE shikigami.agent_run_requests_unavailable RENAME TO agent_run_requests"
