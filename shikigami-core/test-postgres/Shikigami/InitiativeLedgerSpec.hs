{-# LANGUAGE DataKinds #-}

module Shikigami.InitiativeLedgerSpec (tests) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM_)
import Data.Aeson (eitherDecode, encode, object, (.=))
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, fromGregorian)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Principal (AgentIdentity (..), AgentPrincipal, mkAgentPrincipal, principalText)
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Duration (Duration, remainingDuration)
import Shikigami.Initiative.Intake (Disposition (..), disposition)
import Shikigami.Initiative.Ledger
import Shikigami.Initiative.Settings (InitiativeSettings (..), ObserverAllowance (..))
import Shikigami.Initiative.Types hiding (AgentActor, NotActionable)
import Shikigami.Initiative.Types qualified as Initiative
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Objective.Keys (ObservedSource (..))
import Shikigami.Objective.Types (ObjectiveId, objectiveIdText, parseObjectiveId)
import Shikigami.Program.Decision.Examples (parseModelConfidence)
import Shikigami.Program.Decision.Initiative
import Shikigami.Repository (repositoryId)
import Shikigami.StateRevision (advanceRevision, initialRevision)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "InitiativeLedger"
    [ testCase "skip rows are bounded and carry no excerpt" $ withFixture fixture \env -> do
        (_, observed) <- observedFor "act-1" "thread-1" secretText
        run env (recordSkipTx proposer t0 Nothing (Right (ExcerptTooShort, observed)))
        run env (recordSkipTx proposer t0 Nothing (Left (Initiative.AgentActor, activityCoordinate "act-2")))
        rows <- candidateRows env
        rows @?= [("act-1", "skipped", Just "excerpt-too-short", Just "thread-1"), ("act-2", "skipped", Just "agent-actor", Nothing)]
        document <- wholeTableText env "shikigami.initiative_candidates"
        assertBool "the excerpt never reaches a row" (not (secretText `Text.isInfixOf` document)),
      testCase "a skip moves an evaluating row but never a row past evaluation" $ withFixture fixture \env -> do
        candidate <- candidateFor "act-1" "thread-1"
        run env (recordCandidateTx candidate runOne t0)
        (_, observed) <- observedFor "act-1" "thread-1" secretText
        run env (recordSkipTx proposer t1 Nothing (Right (Initiative.NotActionable, observed)))
        (fmap (\(_, v, r, _) -> (v, r)) <$> candidateRows env) >>= (@?= [("not-actionable", Just "not-actionable")])
        proposal <- newProposalId
        run env (markCandidateProposedTx proposer (activityCoordinate "act-1") proposal)
        run env (recordSkipTx proposer t1 Nothing (Right (EvaluationsExhausted, observed)))
        (fmap (\(_, v, _, _) -> v) <$> candidateRows env) >>= (@?= ["proposed"]),
      testCase "two proposals for one key from two connections converge on one row" $ withFixture fixture \env -> do
        candidate <- candidateFor "act-1" "thread-1"
        assessment <- assessmentFor candidate
        ids <- sequence [newProposalId, newProposalId]
        receipts <- concurrently (zipWith (\identifier run' -> propose env identifier candidate assessment t0 run') ids [runOne, runOne'])
        length (filter ((== Created) . (.disposition)) receipts) @?= 1
        length (filter ((== Converged) . (.disposition)) receipts) @?= 1
        countProposals env >>= (@?= 1)
        case receipts of
          [one, two] -> one.proposalId @?= two.proposalId
          other -> assertFailure (show other),
      testCase "a run's retry of its own proposal stays created and creates nothing" $ withFixture fixture \env -> do
        candidate <- candidateFor "act-1" "thread-1"
        assessment <- assessmentFor candidate
        first' <- newProposalId
        retry <- newProposalId
        one <- propose env first' candidate assessment t0 runOne
        two <- propose env retry candidate assessment t0 runOne
        one.disposition @?= Created
        two.disposition @?= Created
        two.proposalId @?= first'
        countProposals env >>= (@?= 1),
      testCase "a pending key is owned; accepted-open owns it; completed does not; a rejection suppresses until it lapses" $ withFixture fixture \env -> do
        candidate <- candidateFor "act-1" "thread-1"
        assessment <- assessmentFor candidate
        allowed <- run env (checkOwner proposer thread t0)
        allowed @?= Right (Right ())
        proposal <- newProposalId
        receipt <- propose env proposal candidate assessment t0 runOne
        owner <- run env (checkOwner proposer thread t0)
        owner @?= Right (Left (AlreadyProposed receipt.proposalId))
        run env (checkOwner agentOther thread t0) >>= (@?= Right (Right ()))
        -- Accepted while its objective is open, then completed.
        objective <- fixtureObjective env "Open"
        _ <- run env (resolveProposal proposal initialRevision (Accepted objective) t1 suppression) >>= right
        run env (checkOwner proposer thread t1) >>= (@?= Right (Left (AlreadyOwned objective)))
        setObjectiveStatus env objective "Blocked"
        run env (checkOwner proposer thread t1) >>= (@?= Right (Left (AlreadyOwned objective)))
        setObjectiveStatus env objective "Completed"
        run env (checkOwner proposer thread t1) >>= (@?= Right (Right ()))
        -- A second proposal for the key, rejected: suppressed until the instant.
        secondId <- newProposalId
        second <- propose env secondId candidate assessment t1 runTwo
        second.disposition @?= Created
        _ <- run env (resolveProposal secondId initialRevision (Rejected t1) t1 suppression) >>= right
        let lapses = addUTCTime suppressionSeconds t1
        run env (checkOwner proposer thread t1) >>= (@?= Right (Left (Suppressed lapses)))
        run env (checkOwner proposer thread (addUTCTime 1 lapses)) >>= (@?= Right (Right ())),
      testCase "an expired proposal suppresses like a rejection" $ withFixture fixture \env -> do
        candidate <- candidateFor "act-1" "thread-1"
        assessment <- assessmentFor candidate
        proposal <- newProposalId
        _ <- propose env proposal candidate assessment t0 runOne
        _ <- run env (resolveProposal proposal initialRevision (Expired t1) t1 suppression) >>= right
        run env (checkOwner proposer thread t1) >>= (@?= Right (Left (Suppressed (addUTCTime suppressionSeconds t1)))),
      testCase "windows count only rows inside the window and report exhaustion at the limit" $ withFixture fixture \env -> do
        allowance <- allowanceOf 2 1 1
        forM_ (zip ["act-1", "act-2", "act-3"] [t0, t0, addUTCTime (negate 7200) t0]) \(activity, at) -> do
          candidate <- candidateFor activity ("thread-" <> activity)
          run env (recordCandidateTx candidate runOne at)
          run env (markEvaluationStartedTx proposer (activityCoordinate activity) at)
        usage <- run env (checkWindows allowance Nothing t0)
        usage.evaluations @?= 2
        usage.exhausted @?= [EvaluationsAt 2]
        excluded <- run env (checkWindows allowance (Just (activityCoordinate "act-1")) t0)
        excluded.evaluations @?= 1
        excluded.exhausted @?= []
        later <- run env (checkWindows allowance Nothing (addUTCTime 3700 t0))
        later.evaluations @?= 0
        later.exhausted @?= [],
      testCase "a queued evaluation does not spend a slot until its run starts it" $ withFixture fixture \env -> do
        allowance <- allowanceOf 1 1 1
        candidate <- candidateFor "act-1" "thread-1"
        run env (recordCandidateTx candidate runOne t0)
        (.evaluations) <$> run env (checkWindows allowance Nothing t0) >>= (@?= 0)
        run env (markEvaluationStartedTx proposer (activityCoordinate "act-1") t0)
        run env (markEvaluationStartedTx proposer (activityCoordinate "act-1") t1)
        (.evaluations) <$> run env (checkWindows allowance Nothing t1) >>= (@?= 1),
      testCase "proposal and notification windows count their own instants" $ withFixture fixture \env -> do
        allowance <- allowanceOf 9 1 1
        candidate <- candidateFor "act-1" "thread-1"
        assessment <- assessmentFor candidate
        proposal <- newProposalId
        _ <- propose env proposal candidate assessment t0 runOne
        usage <- run env (checkWindows allowance Nothing t0)
        usage.proposals @?= 1
        usage.notifications @?= 0
        usage.exhausted @?= [ProposalsAt 1]
        run env (recordNotificationTx proposal t0)
        run env (recordNotificationTx proposal t1)
        ((.notifications) <$> run env (checkWindows allowance Nothing t1)) >>= (@?= 1),
      testCase "resolution requires the exact revision; a stale one refuses and a retry converges" $ withFixture fixture \env -> do
        candidate <- candidateFor "act-1" "thread-1"
        assessment <- assessmentFor candidate
        proposal <- newProposalId
        _ <- propose env proposal candidate assessment t0 runOne
        run env (resolveProposal proposal (advanceRevision (advanceRevision initialRevision)) (Rejected t1) t1 suppression) >>= (@?= Left LedgerConflict)
        run env (resolveProposal proposal initialRevision (Rejected t1) t1 suppression) >>= (@?= Right (advanceRevision initialRevision))
        run env (resolveProposal proposal initialRevision (Rejected t1) t1 suppression) >>= (@?= Right (advanceRevision initialRevision))
        run env (resolveProposal proposal initialRevision (Expired t1) t1 suppression) >>= (@?= Left LedgerConflict)
        missing <- newProposalId
        run env (resolveProposal missing initialRevision (Rejected t1) t1 suppression) >>= (@?= Left LedgerMissing),
      testCase "a corrupt assessment column is a typed refusal, not an exception" $ withFixture fixture \env -> do
        candidate <- candidateFor "act-1" "thread-1"
        assessment <- assessmentFor candidate
        proposal <- newProposalId
        _ <- propose env proposal candidate assessment t0 runOne
        execute env "UPDATE shikigami.initiative_proposals SET assessment='{\"nonsense\":true}'"
        run env (readProposal proposal) >>= (@?= Left (LedgerCorrupt "assessment"))
    ]

secretText :: Text
secretText = "a private customer quote about the double charge"

thread :: ObservedSource
thread = ObservedSource (activityCoordinate "fixture/chat") (activityCoordinate "chat") (activityCoordinate "thread-1")

proposer, agentOther :: AgentPrincipal
proposer = either (error . Text.unpack) id (mkAgentPrincipal "agent_proposer")
agentOther = either (error . Text.unpack) id (mkAgentPrincipal "agent_other")

t0, t1 :: UTCTime
t0 = UTCTime (fromGregorian 2026 11 4) 3600
t1 = addUTCTime 60 t0

runOne, runOne', runTwo :: WorkflowId
runOne = WorkflowId "run-one"
runOne' = WorkflowId "run-one-prime"
runTwo = WorkflowId "run-two"

expiry :: Duration "initiative-proposal"
expiry = remainingDuration 86400

suppressionSeconds :: NominalDiffTime
suppressionSeconds = 604800

suppression :: Duration "initiative-suppression"
suppression = remainingDuration suppressionSeconds

requested :: RequestedAuthority
requested = RequestedAuthority {repository = repositoryId "repo_payments", actionClass = ReproduceAndDiagnose, limits = Map.empty, objectiveWindow = remainingDuration 0}

settingsWith :: Int -> Int -> Int -> IO InitiativeSettings
settingsWith evaluations proposals notifications =
  either assertFailure pure (eitherDecode (encode document))
  where
    document =
      object
        [ "observers"
            .= [ object
                   [ "principal" .= principalText proposer,
                     "sources" .= (["chat-fixture"] :: [Text]),
                     "minimumExcerptLength" .= (5 :: Int),
                     "evaluation" .= object ["limits" .= object ["ActiveWork" .= (1 :: Int), "ModelAttempts" .= (1 :: Int), "Tokens" .= ("unbounded" :: Text), "CostMicroUsd" .= ("unbounded" :: Text)], "cutoff" .= (3600 :: Int)],
                     "evaluationsPerWindow" .= evaluations,
                     "proposalsPerWindow" .= proposals,
                     "notificationsPerWindow" .= notifications,
                     "window" .= (3600 :: Int),
                     "proposalExpiry" .= (86400 :: Int),
                     "rejectionSuppression" .= (604800 :: Int),
                     "notices" .= object ["kizashiRecipient" .= ("recipient_ops" :: Text)]
                   ]
               ]
        ]

allowanceOf :: Int -> Int -> Int -> IO ObserverAllowance
allowanceOf evaluations proposals notifications = do
  settings <- settingsWith evaluations proposals notifications
  case settings.observers of
    [allowance] -> pure allowance
    other -> assertFailure (show (length other))

envelope :: Text -> Text -> Text -> ActivityEnvelope
envelope activity subject text =
  ActivityEnvelope
    { activityId = activityCoordinate activity,
      occurredAt = activityCoordinate "2026-11-04T01:00:00Z",
      source = activityCoordinate "fixture/chat",
      actor = Actor {kind = HumanActor, id = activityCoordinate "customer-1", session = Nothing},
      subject = Subject {kind = activityCoordinate "chat", subjectId = activityCoordinate subject},
      verb = activityCoordinate "message.created",
      payload = object ["text" .= text],
      contextRefs = [],
      idempotencyKey = activityCoordinate activity
    }

candidateFor :: Text -> Text -> IO Candidate
candidateFor activity subject = do
  settings <- settingsWith 10 10 10
  case disposition (Just settings) t0 t0 (VerifiedIdentity proposer) (envelope activity subject secretText) of
    Evaluate _ candidate _ -> pure candidate
    other -> assertFailure (show other)

observedFor :: Text -> Text -> Text -> IO (Candidate, Observed)
observedFor activity subject _text = do
  candidate <- candidateFor activity subject
  pure (candidate, (candidateFacts candidate).observed)

assessmentFor :: Candidate -> IO Assessment
assessmentFor candidate =
  case validateAssessment candidate ((repositoryId "repo_payments", "Payments") :| []) allActionClasses output of
    Right (Actionable sealed) -> pure sealed
    other -> assertFailure (show other)
  where
    output =
      AssessmentOutput
        { actionable = True,
          outcome = "Checkout charges a card once per order",
          criteria = ["A double click produces one charge"],
          repositoryIndex = Just 0,
          actionClass = Just "reproduce-and-diagnose",
          confidence = either (error . show) id (parseModelConfidence 0.9),
          evidenceIndexes = [0],
          rationale = "The message describes a reproducible defect"
        }

concurrently :: [IO value] -> IO [value]
concurrently actions = do
  gates <- traverse (const newEmptyMVar) actions
  forM_ (zip gates actions) \(gate, action) -> forkIO (action >>= putMVar gate)
  traverse takeMVar gates

propose :: AppEnv -> ProposalId -> Candidate -> Assessment -> UTCTime -> WorkflowId -> IO ProposalReceipt
propose env identifier candidate assessment at owner =
  runAppIO env (recordProposal identifier candidate assessment requested at expiry owner) >>= right >>= right

withFixture :: DatabaseFixture -> (AppEnv -> IO a) -> IO a
withFixture fixture use = withShikigamiFreshDatabase fixture \connection -> do
  tracer <- noopTracer
  use AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing, store = Nothing}

run :: AppEnv -> Tx.Transaction a -> IO a
run = runTx

runTx :: AppEnv -> Tx.Transaction a -> IO a
runTx env tx = runAppIO env (runTransaction tx) >>= either (assertFailure . show) pure

right :: (Show failure) => Either failure value -> IO value
right = either (assertFailure . show) pure

execute :: AppEnv -> Text -> IO ()
execute env text = runTx env (Tx.statement () (preparable text E.noParams D.noResult))

candidateRows :: AppEnv -> IO [(Text, Text, Maybe Text, Maybe Text)]
candidateRows env =
  sort
    <$> runTx
      env
      ( Tx.statement
          ()
          ( preparable
              "SELECT activity_id,verdict,skip_reason,subject_id FROM shikigami.initiative_candidates"
              E.noParams
              (D.rowList ((,,,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text) <*> D.column (D.nullable D.text) <*> D.column (D.nullable D.text)))
          )
      )

countProposals :: AppEnv -> IO Int
countProposals env =
  fromIntegral
    <$> runTx env (Tx.statement () (preparable "SELECT count(*) FROM shikigami.initiative_proposals" E.noParams (D.singleRow (D.column (D.nonNullable D.int8)))))

wholeTableText :: AppEnv -> Text -> IO Text
wholeTableText env table =
  Text.concat
    <$> runTx env (Tx.statement () (preparable ("SELECT row_to_json(t)::text FROM " <> table <> " t") E.noParams (D.rowList (D.column (D.nonNullable D.text)))))

fixtureObjective :: AppEnv -> Text -> IO ObjectiveId
fixtureObjective env status = do
  objective <- either (assertFailure . Text.unpack) pure (parseObjectiveId "shikigami_objective_01h455vb4pex5vsknk084sn02q")
  execute env ("INSERT INTO shikigami.objectives(objective_id,state) VALUES ('" <> objectiveIdText objective <> "','{\"status\":\"" <> status <> "\"}')")
  pure objective

setObjectiveStatus :: AppEnv -> ObjectiveId -> Text -> IO ()
setObjectiveStatus env objective status =
  execute env ("UPDATE shikigami.objectives SET state='{\"status\":\"" <> status <> "\"}' WHERE objective_id='" <> objectiveIdText objective <> "'")
