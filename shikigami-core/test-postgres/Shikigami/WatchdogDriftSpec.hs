{-# LANGUAGE DataKinds #-}

-- | A real unregistered Flow, with the normal capability and decision journal.
module Shikigami.WatchdogDriftSpec (tests) where

import Baikai.Content (AssistantContent (AssistantText), TextContent (..))
import Baikai.Evidence qualified as Evidence
import Baikai.Options qualified as Options
import Baikai.Provider.Registry (ApiProvider (..))
import Baikai.Response (Response (..))
import Baikai.Stream (liftCompleteToStream)
import Control.Concurrent.Async (concurrently)
import Control.Exception (SomeException, try)
import Control.Lens ((&), (.~))
import Control.Monad (when)
import Data.Aeson (Value, encode, object, toJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8)
import Data.Time (addUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow (StepName (..), WorkflowId (..), WorkflowName (..), WorkflowOutcome (..), loadStepIndex)
import Kioku.Id (genSessionId)
import Kiroku.Store.Connection (KirokuStore (..), withStore)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.App (AppEffects, AppEnv (..), runAppIO)
import Shikigami.Behavior.Run (BehaviorEnv (..), newBehaviorEnv)
import Shikigami.Behavior.StubProvider (stubModel)
import Shikigami.Decision.Contract
import Shikigami.Decision.Evidence
import Shikigami.Decision.ModelCatalog
import Shikigami.Decision.StubProvider (decisionStubProvider)
import Shikigami.Duration (remainingDuration)
import Shikigami.Execution.Admission (enrollRootRun)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Execution.Observation qualified as Execution
import Shikigami.Execution.Quantity (amountUnits, parseResourceAmount)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.Transcript qualified as Owner
import Shikigami.ExecutionTranscriptSpec qualified as ExecutionFixture
import Shikigami.Flow (FlowDef (..), LifecycleDiagram (..))
import Shikigami.Flow.Decision qualified as Decision
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.FlowLifecycleSpec (runFlowBodyWithDecision, spikeRuntime)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Log.Correlation (runCorrelationId)
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Objective.Observation qualified as Objective
import Shikigami.Objective.Scope qualified as Scope
import Shikigami.Objective.Types qualified as Objective
import Shikigami.ObjectiveStoreSpec (withObjective)
import Shikigami.Program.Decision
import Shikigami.Program.Decision.Drift
import Shikigami.RouterWorkflowSpec qualified as RouterFixture
import Shikigami.RuntimePolicy (DefaultModelRequirement (DefaultModelOptional))
import Shikigami.StateRevision (initialRevision)
import Shikigami.Watchdog.Drift qualified as Cadence
import Shikigami.Watchdog.Observation qualified as Observation
import Shikigami.Watchdog.Types
import Shikigami.WatchdogObservationSpec (fixtureGrant)
import Shikigami.WorkerSession.Input (workerSessionId)
import Shikigami.WorkerSession.Types qualified as WorkerSessionOwner
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "WatchdogDrift"
    [ testCase "real Flow uses owner metadata, charges its own root and leaves the objective unchanged" $ withHarness fixture \h -> do
        (workflow, root) <- enroll h "one" 1
        before <- objectiveState h
        objectiveRoot <- inspect h h.objectiveRoot
        output <- completed =<< runHarness h (decisionEnv h (Just root)) workflow Nothing
        map (.category) (NonEmpty.toList output) @?= [OutsideScope]
        map (.evidence) (NonEmpty.toList output) @?= map (NonEmpty.toList . (.evidence)) (NonEmpty.toList h.input.subjects)
        h.calls >>= (@?= 1)
        report <- decisionReport h workflow
        length report.calls @?= 1
        length report.invocations @?= 1
        charged <- inspect h root
        amount charged.usage.settled Resources.ModelAttempts @?= Just 1
        objectiveState h >>= (@?= before)
        inspect h h.objectiveRoot >>= (@?= objectiveRoot)
        prompts <- h.prompts
        assertBool "accepted tool name is available" (any (Text.isInfixOf "unrelated-export") prompts)
        assertBool "protected replay/context body excluded" (all (not . Text.isInfixOf "PRIVATE_REPLAY_MARKER") prompts),
      testCase "a committed result resumes after crash without another provider or accounting call" $ withHarness fixture \h -> do
        (workflow, root) <- enroll h "committed-replay" 1
        once <- newIORef True
        let crash = do
              index <- run h.env (loadStepIndex workflowName workflow 0)
              when (Map.member "decision-result-drift" index) do
                stop <- atomicModifyIORef' once (False,)
                when stop (ioError (userError "crash after the committed drift result"))
        first <- try @SomeException (runHarness h (decisionEnv h (Just root)) workflow (Just crash))
        assertBool "actual append boundary crashed" (either (const True) (const False) first)
        h.calls >>= (@?= 1)
        let retired = (decisionEnv h (Just root)) {Decision.services = (decisionEnv h (Just root)).services & #programs .~ must (programRegistry []) & #catalog .~ must (modelCatalog [])}
        output <- completed =<< runHarness h retired workflow Nothing
        map (.category) (NonEmpty.toList output) @?= [OutsideScope]
        h.calls >>= (@?= 1)
        charged <- inspect h root
        amount charged.usage.settled Resources.ModelAttempts @?= Just 1,
      testCase "lost result append permits another actual call and charges both attempts" $ withHarness fixture \h -> do
        (workflow, root) <- enroll h "lost-result" 2
        once <- newIORef True
        let crash (StepName name) = when (name == "decision-result-drift") do
              stop <- atomicModifyIORef' once (False,)
              when stop (ioError (userError "lost result append"))
            runtime = (decisionEnv h (Just root)) {Decision.afterStep = crash}
        first <- try @SomeException (runHarness h runtime workflow Nothing)
        assertBool "uncommitted result crashed" (either (const True) (const False) first)
        _ <- completed =<< runHarness h runtime workflow Nothing
        h.calls >>= (@?= 2)
        charged <- inspect h root
        amount charged.usage.settled Resources.ModelAttempts @?= Just 2
        assertBool "unmeasured token usage is not refunded" (maybe False (> 0) (amount charged.usage.held Resources.Tokens))
        report <- decisionReport h workflow
        length report.calls @?= 2
        length report.invocations @?= 1,
      testCase "subject substitution and invented citations fail at the input-bound seal" $ withHarness fixture \h -> do
        let valid = proposal h.input
            unknown = subjectKeyText (subjectKey (WorkerSession (workerSessionId "substituted-subject")))
        mapM_
          ( \(key, invalid) -> do
              h.reply invalid
              (workflow, root) <- enroll h key 1
              refused <- try @SomeException (runHarness h (decisionEnv h (Just root)) workflow Nothing)
              assertBool "invalid proposal produced no accepted assessment" (either (const True) (const False) refused)
          )
          [("substitution", DriftProposal [answer & #subject .~ unknown | answer <- valid.assessments]), ("invented-evidence", DriftProposal [answer & #evidenceIndexes .~ [99] | answer <- valid.assessments])],
      testCase "missing alias and missing root refuse before prepare or provider IO" $ withHarness fixture \h -> do
        (workflow, root) <- enroll h "alias-refusal" 1
        let absent = (decisionEnv h (Just root)) {Decision.agent = (decisionEnv h (Just root)).agent & #decisionModels .~ []}
        rejected <- try @SomeException (runHarness h absent workflow Nothing)
        assertBool "missing declaration alias refused" (either (const True) (const False) rejected)
        h.calls >>= (@?= 0)
        key <- pure (runJobWorkflowId (RouterFixture.routerJob "rootless-drift"))
        refused <- try @SomeException (runHarness h (decisionEnv h Nothing) key Nothing)
        assertBool "missing root refused" (either (const True) (const False) refused)
        h.calls >>= (@?= 0)
        names <- h.steps
        assertBool "no preparation journal action ran" (all (== StepName "decision-policy") names),
      testCase "an exhausted model-attempt envelope refuses before actual dispatch" $ withHarness fixture \h -> do
        (workflow, root) <- enroll h "no-attempts" 0
        refused <- try @SomeException (runHarness h (decisionEnv h (Just root)) workflow Nothing)
        assertBool "root refused the call" (either (const True) (const False) refused)
        h.calls >>= (@?= 0)
        charged <- inspect h root
        amount charged.usage.settled Resources.ModelAttempts @?= Nothing,
      testCase "stored checks converge concurrently, enforce cadence and refuse stale or changed retries" $ withHarness fixture \h -> do
        (input, subject, page) <- boundedInput h
        assessment <- right (validateDriftAssessment input (proposal input))
        checks <- right (Cadence.checksForAssessment page.observedAt input (subject :| []) assessment)
        sweep <- newSweepId
        (first, replayed) <-
          concurrently
            (run h.env (runTransaction (Cadence.recordDriftChecks sweep page.observedAt checks)))
            (run h.env (runTransaction (Cadence.recordDriftChecks sweep page.observedAt checks)))
        first @?= Right ()
        replayed @?= Right ()
        retained <- right =<< run h.env (runTransaction (Cadence.readDriftChecks (subjectKey subject.subject :| [])))
        Map.elems retained @?= NonEmpty.toList checks
        limit <- right (parseWatchdogLimit 1)
        let cadence = Cadence.DriftCadence (remainingDuration 600) limit
        Cadence.dueForDrift cadence (addUTCTime 599 page.observedAt) retained [subject] @?= Nothing
        fmap (map (.subject) . NonEmpty.toList . snd) (Cadence.dueForDrift cadence (addUTCTime 600 page.observedAt) retained [subject]) @?= Just [subject.subject]
        let altered = fmap (\check -> check & #checkedAt .~ addUTCTime 1 page.observedAt) checks
        run h.env (runTransaction (Cadence.recordDriftChecks sweep (addUTCTime 1 page.observedAt) altered)) >>= (@?= Left Cadence.DriftBindingConflict)
        stale <- newSweepId
        let old = fmap (\check -> check & #checkedAt .~ addUTCTime (-1) page.observedAt) checks
        run h.env (runTransaction (Cadence.recordDriftChecks stale (addUTCTime (-1) page.observedAt) old)) >>= (@?= Left Cadence.DriftStale)
        unchanged <- right =<< run h.env (runTransaction (Cadence.readDriftChecks (subjectKey subject.subject :| [])))
        unchanged @?= retained,
      testCase "metadata builder excludes protected bodies; corrupted cadence metadata is a typed refusal" $ withHarness fixture \h -> do
        (input, subject, page) <- boundedInput h
        let encoded = decodeUtf8 (Lazy.toStrict (encode input))
        assertBool "owner prompt/replay body excluded" (not ("PRIVATE_REPLAY_MARKER" `Text.isInfixOf` encoded))
        assertBool "accepted tool metadata retained" ("unrelated-export" `Text.isInfixOf` encoded)
        assessment <- right (validateDriftAssessment input (proposal input))
        checks <- right (Cadence.checksForAssessment page.observedAt input (subject :| []) assessment)
        sweep <- newSweepId
        right =<< run h.env (runTransaction (Cadence.recordDriftChecks sweep page.observedAt checks))
        run h.env (runTransaction (Tx.sql "UPDATE shikigami.watchdog_drift_checks SET mark_digest='invalid'"))
        run h.env (runTransaction (Cadence.readDriftChecks (subjectKey subject.subject :| []))) >>= (@?= Left Cadence.DriftCorrupt)
    ]

data Harness = Harness
  { env :: !AppEnv,
    runtime :: !BehaviorEnv,
    evidence :: !DecisionEvidenceStore,
    services :: !Decision.DecisionServices,
    input :: !DriftInput,
    calls :: !(IO Int),
    prompts :: !(IO [Text]),
    reply :: !(DriftProposal -> IO ()),
    steps :: !(IO [StepName]),
    recordStep :: !(StepName -> IO ()),
    objectiveRoot :: !ExecutionRootId
  }

withHarness :: DatabaseFixture -> (Harness -> IO a) -> IO a
withHarness fixture use = withObjective fixture \env admission objectiveId -> do
  objectiveRoot <- maybe (assertFailure "objective root missing") pure admission.context.executionRootId
  ExecutionFixture.withNamedToolFixtureForRootIn env objectiveRoot "unrelated-export" (scoped objectiveId) \_ snapshot _ -> do
    objectiveRows <- right =<< run env (runTransaction (Objective.observeObjectivesFor (objectiveId :| [])))
    executionRows <- right =<< run env (runTransaction (Execution.observeExecutionsFor (snapshot.executionId :| [])))
    objective <- case objectiveRows of [(_, Right observed)] -> pure observed; _ -> assertFailure "objective observation missing"
    execution <- case executionRows of [(_, Right observed)] -> pure observed; _ -> assertFailure "execution observation missing"
    execution.objective @?= Just objectiveId
    limit <- right (parseWatchdogLimit 1)
    let subject = DriftSubjectInput (Execution execution.executionId) Nothing [OperationSummary operation.position operation.specification | operation <- execution.operations] [] (ExecutionEvidence execution.executionId execution.cursor :| [])
        input = DriftInput objectiveId objective.revision (Objective.goalText objective.goal) [CriterionSummary criterion.key (Objective.criterionDescriptionText criterion.description) criterion.kind criterion.journeyRequired | criterion <- objective.criteria] (subject :| []) limit
    _ <- right (validateDriftInput input)
    withStore env.connectionSettings \store -> do
      runtime <- newBehaviorEnv
      count <- newIORef 0
      prompts <- newIORef []
      replies <- newIORef (proposal input)
      seen <- newIORef []
      let completing model context options = do
            atomicModifyIORef' count (\number -> (number + 1, ()))
            atomicModifyIORef' prompts (\values -> (values <> [Text.pack (show context)], ()))
            reply <- toJSON <$> readIORef replies
            response <- decisionStubProvider.complete model context options
            let evidence = (\value -> value & #responseCommitment .~ Evidence.Observed (Evidence.commitmentDigest reply)) <$> response.evidence
            pure (response & #message . #content .~ Vector.singleton (AssistantText (TextContent (decodeUtf8 (Lazy.toStrict (encode reply))))) & #evidence .~ evidence)
          provider = decisionStubProvider & #complete .~ completing & #stream .~ liftCompleteToStream completing
      use (Harness env runtime (postgresDecisionEvidenceStore store.pool) (Decision.defaultDecisionServices catalog & #providers .~ [provider]) input (readIORef count) (readIORef prompts) (writeIORef replies) (reverse <$> readIORef seen) (\name -> atomicModifyIORef' seen (\values -> (name : values, ()))) objectiveRoot)
  where
    scoped :: Objective.ObjectiveId -> Owner.ExecutionSnapshot -> Owner.ExecutionSnapshot
    scoped objective snapshot = snapshot & #objectiveScope .~ Just (Scope.ObjectiveScope V1 snapshot.runId snapshot.identity snapshot.sessionId snapshot.selection.rootId (Just (addUTCTime 3600 snapshot.selection.admittedAt)) (Just snapshot.selection.permittedAliases) (Just objective) (Scope.AgentScope snapshot.selection.assignmentId) Nothing [Scope.InspectObjectives, Scope.ApplyObjectiveCommands] Nothing)

alias :: ModelAlias
alias = modelAliasFromNonEmpty ('d' :| "rift")

driftStep :: Decision.DecisionStep DriftInput DriftProposal
driftStep = Decision.decisionStep Decision.Drift (programRef driftProgram)

catalog :: ModelCatalog
catalog = must (modelCatalog [must (modelBinding alias "1" "drift" "1" (stubModel & #modelId .~ "stub-drift" & #contextWindow .~ 128) (Options.emptyOptions & #maxTokens .~ Just 64) Nothing)])

harnessFlow :: FlowDef
harnessFlow = FlowDef (declarationCoordinate "watchdog-drift-harness") (LifecycleDiagram "flowchart LR\n start --> assessment" []) [Decision.decisionSlot driftStep [alias]] DefaultModelOptional \raw -> do
  input <- case Aeson.fromJSON raw of Aeson.Success value -> pure value; Aeson.Error _ -> Decision.refuseDecision (decisionFailure InvalidInput "invalid drift harness input")
  output <- Decision.decide driftStep alias input
  assessment <- either Decision.refuseDecision pure (validateDriftAssessment input output)
  pure (toJSON (assessmentView assessment))

decisionEnv :: Harness -> Maybe ExecutionRootId -> Decision.DecisionEnv
decisionEnv h root =
  Decision.DecisionEnv
    { agent = RouterFixture.routerDecl & #decisionModels .~ [alias],
      inventory = harnessFlow.decisionSlots,
      services = h.services,
      runtime = h.runtime.runtime,
      profile = Nothing,
      evidence = h.evidence,
      routing = Routing.RoutingRuntime (\_ -> error "unused routing") (\_ _ _ -> error "unused routing"),
      timeoutMicros = must (parseDecisionTimeout 5000000),
      root,
      beforeStep = h.recordStep,
      afterStep = const (pure ())
    }

workflowName :: WorkflowName
workflowName = WorkflowName "shikigami.flow.spike"

runHarness :: Harness -> Decision.DecisionEnv -> WorkflowId -> Maybe (IO ()) -> IO (Either StoreError (WorkflowOutcome Value))
runHarness h runtime workflow onAppend = do
  session <- genSessionId
  runFlowBodyWithDecision runtime onAppend h.env (spikeRuntime session) "router" harnessFlow workflow (toJSON h.input)

completed :: Either StoreError (WorkflowOutcome Value) -> IO (NonEmpty DriftSubjectAssessment)
completed (Right (Completed value)) = case Aeson.fromJSON value of Aeson.Success result -> pure result; Aeson.Error failure -> assertFailure failure
completed other = assertFailure (show other)

proposal :: DriftInput -> DriftProposal
proposal input = DriftProposal [DriftProposalSubject (subjectKeyText (subjectKey subject.subject)) "outside-scope" "The unrelated export tool does not serve this objective." [0] | subject <- NonEmpty.toList input.subjects]

enroll :: Harness -> Text -> Integer -> IO (WorkflowId, ExecutionRootId)
enroll h key attempts = do
  now <- getCurrentTime
  let limits = Map.fromList [(Resources.ActiveWork, limited 1), (Resources.ModelAttempts, limited attempts), (Resources.Tokens, limited 1000), (Resources.CostMicroUsd, Resources.ExplicitlyUnbounded)]
  job <- right =<< run h.env (enrollRootRun (Resources.Envelope limits (addUTCTime 3600 now)) (RouterFixture.routerJob ("drift-" <> key)))
  root <- maybe (assertFailure "enrollment returned no root") pure job.executionRootId
  pure (runJobWorkflowId job, root)
  where
    limited amount = Resources.Limited (must (parseResourceAmount amount))

inspect :: Harness -> ExecutionRootId -> IO Resources.Root
inspect h root = right =<< run h.env (Roots.inspectRoot root)

amount :: Resources.Quantities -> Resources.Dimension -> Maybe Integer
amount quantities dimension = amountUnits <$> Map.lookup dimension quantities

objectiveState :: Harness -> IO (Objective.ObjectiveObservation, Int64)
objectiveState h = do
  rows <- right =<< run h.env (runTransaction (Objective.observeObjectivesFor (h.input.objective :| [])))
  objective <- case rows of [(_, Right value)] -> pure value; _ -> assertFailure "missing objective"
  receipts <- run h.env (runTransaction (Tx.statement () (preparable "SELECT count(*) FROM shikigami.objective_receipts" E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))))
  pure (objective, receipts)

decisionReport :: Harness -> WorkflowId -> IO DecisionEvidenceReport
decisionReport h workflow = do
  report <- right =<< readDecisionReport h.evidence (runCorrelationId workflow.unWorkflowId)
  maybe (assertFailure "decision report missing") pure report

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= right

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

must :: (Show e) => Either e a -> a
must = either (error . show) id

boundedInput :: Harness -> IO (DriftInput, Observation.SubjectObservation, Observation.ObservationPage)
boundedInput h = do
  grant <- fixtureGrant
  page <- right =<< run h.env (Observation.observePage grant Observation.defaultObservationBounds Observation.initialCursor)
  let expected = (NonEmpty.head h.input.subjects).subject
  subject <- case filter ((== expected) . (.subject)) page.subjects of [value] -> pure value; _ -> assertFailure "execution absent from observation page"
  (objective, _) <- objectiveState h
  limit <- right (parseWatchdogLimit 1)
  input <- right (Cadence.buildDriftInput limit objective (subject :| []))
  pure (input, subject, page)
