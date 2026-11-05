{-# LANGUAGE DataKinds #-}

module Shikigami.InitiativeInspectionSpec (tests) where

import Control.Monad (forM_)
import Data.Aeson (eitherDecode, encode, object, (.=))
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Hasql.Transaction (Transaction)
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Principal (AgentIdentity (..), AgentPrincipal, mkAgentPrincipal)
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Initiative.Inspection
import Shikigami.Initiative.Intake (Disposition (..), disposition)
import Shikigami.Initiative.Ledger
import Shikigami.Initiative.Settings (InitiativeSettings (..))
import Shikigami.Initiative.Types hiding (AgentActor)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "InitiativeInspection"
    [ testCase "a quiet observer shows zero usage, distinct from an absent one" $ withEnv fixture \env -> do
        view <- inspected env (Just settings)
        map (.evaluations) view.observers @?= [0]
        map (.exhausted) view.observers @?= [[]]
        view.policies @?= []
        anyExhausted view @?= False
        absent <- inspected env Nothing
        absent.observers @?= [],
      testCase "an exhausted evaluation window is named and is a stopped state" $ withEnv fixture \env -> do
        candidate <- candidateFor "act-1"
        run env (recordCandidateTx candidate (WorkflowId "run-1") t0)
        run env (markEvaluationStartedTx observer (activityCoordinate "act-1") t0)
        view <- inspected env (Just settings)
        map (.evaluations) view.observers @?= [1]
        map (.exhausted) view.observers @?= [["evaluations"]]
        anyExhausted view @?= True,
      testCase "candidates page in recording order with a stable cursor" $ withEnv fixture \env -> do
        forM_ (zip ["act-a", "act-b", "act-c"] [0 :: Int ..]) \(activity, offset) -> do
          candidate <- candidateFor activity
          run env (recordCandidateTx candidate (WorkflowId "run-1") (addUTCTime (fromIntegral offset) t0))
        page <- run env (listCandidates observer Nothing Nothing 2)
        map (.activity) page @?= ["act-a", "act-b"]
        rest <- run env (listCandidates observer (Just (addUTCTime 1 t0)) (Just (activityCoordinate "act-b")) 2)
        map (.activity) rest @?= ["act-c"],
      testCase "prune removes old terminal skips only, a batch at a time" $ withEnv fixture \env -> do
        forM_ ["skip-1", "skip-2"] \activity -> run env (recordSkipTx observer t0 Nothing (Left (ExcerptTooShort, activityCoordinate activity)))
        run env (recordSkipTx observer (addUTCTime 100 t0) Nothing (Left (ExcerptTooShort, activityCoordinate "skip-late")))
        candidate <- candidateFor "evaluating"
        run env (recordCandidateTx candidate (WorkflowId "run-1") t0)
        run env (pruneCandidatesBefore (addUTCTime 50 t0) 1) >>= (@?= 1)
        run env (pruneCandidatesBefore (addUTCTime 50 t0) 10) >>= (@?= 1)
        remaining <- run env (listCandidates observer Nothing Nothing 10)
        sort (map (.activity) remaining) @?= ["evaluating", "skip-late"],
      testCase "an empty ledger lists no proposals" $ withEnv fixture \env -> do
        run env (listProposals Nothing (Just "pending") Nothing 10) >>= \case
          Right rows -> rows @?= []
          Left problem -> assertFailure (show problem)
        run env countPendingProposals >>= (@?= 0)
    ]
  where
    inspected env configured =
      run env (inspect configured t0) >>= either (assertFailure . show) pure

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 11 4) 3600

observer :: AgentPrincipal
observer = either (error . Text.unpack) id (mkAgentPrincipal "agent_proposer")

settings :: InitiativeSettings
settings =
  either error id . eitherDecode . encode $
    object
      [ "observers"
          .= [ object
                 [ "principal" .= ("agent_proposer" :: Text),
                   "sources" .= (["chat-fixture"] :: [Text]),
                   "minimumExcerptLength" .= (5 :: Int),
                   "evaluation" .= object ["limits" .= object ["ActiveWork" .= (1 :: Int), "ModelAttempts" .= (1 :: Int), "Tokens" .= ("unbounded" :: Text), "CostMicroUsd" .= ("unbounded" :: Text)], "cutoff" .= (3600 :: Int)],
                   "evaluationsPerWindow" .= (1 :: Int),
                   "proposalsPerWindow" .= (5 :: Int),
                   "notificationsPerWindow" .= (5 :: Int),
                   "window" .= (3600 :: Int),
                   "proposalExpiry" .= (86400 :: Int),
                   "rejectionSuppression" .= (604800 :: Int),
                   "notices" .= object ["kizashiRecipient" .= ("recipient_ops" :: Text)]
                 ]
             ]
      ]

candidateFor :: Text -> IO Candidate
candidateFor activity =
  case disposition (Just settings) t0 t0 (VerifiedIdentity observer) envelope of
    Evaluate _ candidate _ -> pure candidate
    other -> assertFailure (show other)
  where
    envelope =
      ActivityEnvelope
        { activityId = activityCoordinate activity,
          occurredAt = activityCoordinate "2026-11-04T01:00:00Z",
          source = activityCoordinate "fixture/chat",
          actor = Actor {kind = HumanActor, id = activityCoordinate "customer-1", session = Nothing},
          subject = Subject {kind = activityCoordinate "chat", subjectId = activityCoordinate "thread-1"},
          verb = activityCoordinate "message.created",
          payload = object ["text" .= ("Checkout charges the card twice" :: Text)],
          contextRefs = [],
          idempotencyKey = activityCoordinate activity
        }

withEnv :: DatabaseFixture -> (AppEnv -> IO a) -> IO a
withEnv fixture use = withShikigamiFreshDatabase fixture \connection -> do
  tracer <- noopTracer
  use AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing, store = Nothing}

run :: AppEnv -> Transaction value -> IO value
run env transaction = runAppIO env (runTransaction transaction) >>= either (assertFailure . show) pure
