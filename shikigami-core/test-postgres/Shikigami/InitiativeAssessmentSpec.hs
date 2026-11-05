{-# LANGUAGE DataKinds #-}

-- | A harness Flow, not registered, calling the root-accounted slot. Nothing here
-- is declared in the agent-run body; the propose-work Flow does that.
module Shikigami.InitiativeAssessmentSpec (tests) where

import Baikai.Options qualified as Options
import Baikai.Provider.Registry (ApiProvider (..))
import Baikai.Stream (liftCompleteToStream)
import Control.Exception (SomeException, fromException, try)
import Control.Lens ((&), (.~))
import Control.Monad (when)
import Data.Aeson (eitherDecode, encode, object, (.=))
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, getCurrentTime)
import Effectful (Eff, IOE, liftIO, (:>))
import Keiro.Workflow (StepName (..), Workflow, WorkflowName (..), WorkflowOutcome (..), runWorkflow, step)
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Error (StoreError)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Principal (AgentIdentity (..), mkAgentPrincipal)
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Behavior.Run (BehaviorEnv (..), newBehaviorEnv)
import Shikigami.Behavior.StubProvider (stubModel)
import Shikigami.Decision.Contract
import Shikigami.Decision.Evidence
import Shikigami.Decision.ModelCatalog
import Shikigami.Decision.StubProvider (decisionStubProvider)
import Shikigami.Execution.Counter (attemptNumber)
import Shikigami.Execution.Identity (ExecutionRootId, newExecutionRootId)
import Shikigami.Execution.Quantity (amountUnits, parseResourceAmount)
import Shikigami.Execution.Resources qualified as R
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Flow.Decision qualified as Decision
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Initiative.Intake (Disposition (..), disposition)
import Shikigami.Initiative.Settings (InitiativeSettings)
import Shikigami.Initiative.Types hiding (NotActionable)
import Shikigami.Log.Correlation (runCorrelationId)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Program.Decision (programRef)
import Shikigami.Program.Decision.Examples (Request (..), TriageResult (..), triageProgram)
import Shikigami.Program.Decision.Initiative
import Shikigami.Program.DecisionRunner (DecisionAbort (..))
import Shikigami.Repository (RepositoryId, repositoryId)
import Shikigami.RouterWorkflowSpec qualified as Fixture
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "InitiativeAssessment"
    [ testCase "under a root the slot makes one accounted call and the root's counter advances by one" $ withHarness fixture \h -> do
        root <- enroll h (limits [(R.ModelAttempts, 1)])
        outcome <- runHarness h (Just root) "assess-one"
        verdictOf outcome >>= \case
          Actionable sealed -> (assessmentFacts sealed).repository @?= repositoryId "repo_payments"
          other -> assertFailure (show other)
        h.calls >>= (@?= 1)
        report <- readDecisionReport h.evidence (runCorrelationId "assess-one") >>= either (assertFailure . show) (maybe (assertFailure "no report") pure)
        length report.calls @?= 1
        state <- inspect h root
        amounts state.usage.settled R.ModelAttempts @?= Just 1
        attemptNumber state.active @?= 0,
      testCase "a crash after the committed result resumes with the same output, no second call and no second attempt" $ withHarness fixture \h -> do
        root <- enroll h (limits [(R.ModelAttempts, 1)])
        once <- newIORef True
        let crash = do
              stop <- atomicModifyIORef' once (False,)
              when stop (ioError (userError "harness crash after the committed result"))
        first' <- try @SomeException (runAppIO h.env (runWorkflow (WorkflowName "initiative-assessment-harness") (WorkflowId "assess-crash") (Decision.runDecision (decisionEnv h (Just root)) (assessThenStep crash))))
        assertBool "the first run stopped" (either (const True) (const False) first')
        h.calls >>= (@?= 1)
        resumed <- runAppIO h.env (runWorkflow (WorkflowName "initiative-assessment-harness") (WorkflowId "assess-crash") (Decision.runDecision (decisionEnv h (Just root)) (assessThenStep crash)))
        case resumed of
          Right (Completed output) -> output.actionable @?= True
          other -> assertFailure (show (fmap (const ()) <$> other))
        h.calls >>= (@?= 1)
        state <- inspect h root
        amounts state.usage.settled R.ModelAttempts @?= Just 1,
      testCase "an envelope allowing no model attempts refuses before dispatch" $ withHarness fixture \h -> do
        root <- enroll h (limits [(R.ModelAttempts, 0)])
        refused <- try @SomeException (runHarness h (Just root) "assess-exhausted")
        refusalDetail refused >>= \detail -> assertBool (Text.unpack detail) ("resource root refused the model attempt" `Text.isInfixOf` detail)
        h.calls >>= (@?= 0)
        state <- inspect h root
        amounts state.usage.settled R.ModelAttempts @?= Nothing,
      testCase "a run without a root refuses before the prepare step is journaled" $ withHarness fixture \h -> do
        refused <- try @SomeException (runHarness h Nothing "assess-rootless")
        refusalDetail refused >>= (@?= "decision slot requires an enrolled resource root")
        h.calls >>= (@?= 0)
        h.steps >>= (@?= [StepName "decision-policy"]),
      testCase "an existing label under the same root makes its call without touching the root" $ withHarness fixture \h -> do
        root <- enroll h (limits [(R.ModelAttempts, 1)])
        outcome <- runAppIO h.env (runWorkflow (WorkflowName "initiative-assessment-harness") (WorkflowId "assess-triage") (Decision.runDecision (triageEnv h (Just root)) (Decision.decide triageStep triageAlias triageInput)))
        case outcome of
          Right (Completed result) -> result.summary @?= "Stub triage requests investigation"
          other -> assertFailure (show (fmap (const ()) <$> other))
        state <- inspect h root
        amounts state.usage.settled R.ModelAttempts @?= Nothing
        attemptNumber state.active @?= 0
    ]

data Harness = Harness
  { env :: !AppEnv,
    evidence :: !DecisionEvidenceStore,
    runtime :: !BehaviorEnv,
    services :: !Decision.DecisionServices,
    calls :: !(IO Int),
    steps :: !(IO [StepName]),
    recordStep :: !(StepName -> IO ())
  }

withHarness :: DatabaseFixture -> (Harness -> IO a) -> IO a
withHarness fixture use = withShikigamiFreshDatabase fixture \connection ->
  withStore (defaultConnectionSettings connection) \store -> do
    tracer <- noopTracer
    behavior <- newBehaviorEnv
    count <- newIORef (0 :: Int)
    seen <- newIORef []
    let counted =
          decisionStubProvider
            & #complete .~ completing
            & #stream .~ liftCompleteToStream completing
        completing model context options = do
          modifyIORef' count (+ 1)
          decisionStubProvider.complete model context options
    use
      Harness
        { env = AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing, store = Nothing},
          evidence = postgresDecisionEvidenceStore store.pool,
          runtime = behavior,
          services = Decision.defaultDecisionServices catalog & #providers .~ [counted],
          calls = readIORef count,
          steps = reverse <$> readIORef seen,
          recordStep = \name -> modifyIORef' seen (name :)
        }

catalog :: ModelCatalog
catalog =
  either (error . show) id $
    modelCatalog
      [ either (error . show) id (modelBinding Decision.proposeAlias "1" "propose" "1" (stubModel & #modelId .~ "stub-propose") Options.emptyOptions Nothing),
        either (error . show) id (modelBinding triageAlias "1" "triage" "1" (stubModel & #modelId .~ "stub-triage") Options.emptyOptions Nothing)
      ]

triageAlias :: ModelAlias
triageAlias = modelAliasFromNonEmpty ('t' :| "riage")

triageStep :: Decision.DecisionStep Request TriageResult
triageStep = Decision.decisionStep Decision.Triage (programRef triageProgram)

triageInput :: Request
triageInput = Request {request = "Investigate the checkout"}

decisionEnv :: Harness -> Maybe ExecutionRootId -> Decision.DecisionEnv
decisionEnv h root =
  Decision.DecisionEnv
    { agent = Fixture.routerDecl & #decisionModels .~ [Decision.proposeAlias],
      inventory = [Decision.decisionSlot Decision.proposeStep [Decision.proposeAlias]],
      services = h.services,
      runtime = h.runtime.runtime,
      profile = Nothing,
      evidence = h.evidence,
      routing = Routing.RoutingRuntime (\_ -> error "unused routing catalog") (\_ _ _ -> error "unused routing evaluation"),
      timeoutMicros = either (error . show) id (parseDecisionTimeout 5_000_000),
      root,
      beforeStep = h.recordStep,
      afterStep = const (pure ())
    }

triageEnv :: Harness -> Maybe ExecutionRootId -> Decision.DecisionEnv
triageEnv h root =
  (decisionEnv h root)
    { Decision.agent = Fixture.routerDecl & #decisionModels .~ [triageAlias],
      Decision.inventory = [Decision.decisionSlot triageStep [triageAlias]]
    }

assessThenStep :: (Decision.Decision :> es, Workflow :> es, IOE :> es) => IO () -> Eff es AssessmentOutput
assessThenStep crash = do
  output <- Decision.decide Decision.proposeStep Decision.proposeAlias inputValue
  _ <- step (StepName "harness-after") (liftIO crash)
  pure output

runHarness :: Harness -> Maybe ExecutionRootId -> Text -> IO (Either StoreError (WorkflowOutcome AssessmentOutput))
runHarness h root key =
  runAppIO h.env (runWorkflow (WorkflowName "initiative-assessment-harness") (WorkflowId key) (Decision.runDecision (decisionEnv h root) (Decision.decide Decision.proposeStep Decision.proposeAlias inputValue)))

verdictOf :: (Show failure) => Either failure (WorkflowOutcome AssessmentOutput) -> IO Verdict
verdictOf = \case
  Right (Completed output) -> do
    either (assertFailure . show) pure (validateAssessment candidateFixture repositories allActionClasses output)
  Right _ -> assertFailure "the harness did not complete"
  Left failure -> assertFailure (show failure)

refusalDetail :: Either SomeException a -> IO Text
refusalDetail = \case
  Right _ -> assertFailure "expected a refusal"
  Left failure -> case fromException failure of
    Just (DecisionAbort refusal) -> pure (renderDecisionFailure refusal)
    Nothing -> assertFailure (show failure)

enroll :: Harness -> R.Limits -> IO ExecutionRootId
enroll h bounded = do
  root <- newExecutionRootId
  now <- getCurrentTime
  runAppIO h.env (Roots.enrollRoot root (R.Envelope bounded (addUTCTime 3600 now))) >>= either (assertFailure . show) (either (assertFailure . show) (const (pure root)))

inspect :: Harness -> ExecutionRootId -> IO R.Root
inspect h root = runAppIO h.env (Roots.inspectRoot root) >>= either (assertFailure . show) (either (assertFailure . show) pure)

amounts :: R.Quantities -> R.Dimension -> Maybe Integer
amounts quantities dimension = amountUnits <$> Map.lookup dimension quantities

-- | What the envelope admits besides the dimensions under test.
limits :: [(R.Dimension, Integer)] -> R.Limits
limits overrides =
  Map.union
    (Map.fromList [(dimension, R.Limited (either (error . show) id (parseResourceAmount amount))) | (dimension, amount) <- overrides])
    (Map.fromList [(R.ActiveWork, R.Limited (either (error . show) id (parseResourceAmount 1))), (R.ModelAttempts, R.ExplicitlyUnbounded), (R.Tokens, R.ExplicitlyUnbounded), (R.CostMicroUsd, R.ExplicitlyUnbounded)])

repositories :: NonEmpty (RepositoryId, Text)
repositories = (repositoryId "repo_payments", "Payments") :| [(repositoryId "repo_billing", "Billing")]

inputValue :: AssessmentInput
inputValue = assessmentInput candidateFixture repositories allActionClasses

candidateFixture :: Candidate
candidateFixture =
  case disposition (Just settingsFixture) instantFixture instantFixture (VerifiedIdentity (either (error . Text.unpack) id (mkAgentPrincipal "agent_proposer"))) envelopeFixture of
    Evaluate _ candidate _ -> candidate
    other -> error (show other)

settingsFixture :: InitiativeSettings
settingsFixture =
  either error id . eitherDecode . encode $
    object
      [ "observers"
          .= [ object
                 [ "principal" .= ("agent_proposer" :: Text),
                   "sources" .= (["chat-fixture"] :: [Text]),
                   "minimumExcerptLength" .= (5 :: Int),
                   "evaluation" .= object ["limits" .= object ["ActiveWork" .= (1 :: Int), "ModelAttempts" .= (1 :: Int), "Tokens" .= ("unbounded" :: Text), "CostMicroUsd" .= ("unbounded" :: Text)], "cutoff" .= (3600 :: Int)],
                   "evaluationsPerWindow" .= (10 :: Int),
                   "proposalsPerWindow" .= (5 :: Int),
                   "notificationsPerWindow" .= (5 :: Int),
                   "window" .= (3600 :: Int),
                   "proposalExpiry" .= (86400 :: Int),
                   "rejectionSuppression" .= (604800 :: Int),
                   "notices" .= object ["kizashiRecipient" .= ("recipient_ops" :: Text)]
                 ]
             ]
      ]

instantFixture :: UTCTime
instantFixture = UTCTime (fromGregorian 2026 11 4) 60

envelopeFixture :: ActivityEnvelope
envelopeFixture =
  ActivityEnvelope
    { activityId = activityCoordinate "activity-1",
      occurredAt = activityCoordinate "2026-11-04T00:01:00Z",
      source = activityCoordinate "fixture/chat",
      actor = Actor {kind = HumanActor, id = activityCoordinate "customer-1", session = Nothing},
      subject = Subject {kind = activityCoordinate "chat", subjectId = activityCoordinate "thread-1"},
      verb = activityCoordinate "message.created",
      payload = object ["text" .= ("Double-clicking checkout charges the card twice on every attempt" :: Text)],
      contextRefs = [],
      idempotencyKey = activityCoordinate "key-1"
    }
