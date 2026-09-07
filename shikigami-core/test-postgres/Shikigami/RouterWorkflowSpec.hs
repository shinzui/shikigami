module Shikigami.RouterWorkflowSpec (tests) where

import Control.Exception (bracket, try)
import Control.Monad (filterM, void)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian, secondsToNominalDiffTime)
import Keiro.Workflow (WorkflowId (..), WorkflowName (..), WorkflowOutcome (..), defaultWorkflowRunOptions, loadStepIndex, runWorkflow)
import Keiro.Workflow.Child (runChildWorkflow)
import Keiro.Workflow.Child.Schema (lookupChildrenOfParent)
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Error (StoreError)
import OpenTelemetry.Attributes (Attribute (..), PrimitiveAttribute (..), getAttributeMap)
import OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)
import OpenTelemetry.Trace.Core qualified as Otel
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests)
import Shikigami.Agent.Approval (autoApprovePolicy)
import Shikigami.Agent.Approval.Workflow qualified as ApprovalWorkflow
import Shikigami.Agent.Decl
  ( AgentDecl (..),
    AmbiguousPolicy (ReturnAmbiguous),
    Behavior (..),
    ExpertiseDecl (..),
    NoMatchPolicy (ReturnNoMatch),
    RouterConfidence (..),
    RouterPolicy (..),
    Trigger (..),
    defaultDelegationBudget,
    defaultMemoryPolicy,
    mkDelegationBudget,
  )
import Shikigami.Agent.Delegate (delegatedWorkflowId)
import Shikigami.Agent.Delegate.Context (DelegationError (..))
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.Run.Key (RunKey (..))
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (AgentWorkflowRoute), TriggerKind (TriggeredByEvent), runJobWorkflowId)
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Attestation.Resolve (ProfileResolutionError (UnknownProfile))
import Shikigami.Behavior.Run (BehaviorEnv, newBehaviorEnv)
import Shikigami.Capability.Provider qualified as CapabilityProvider
import Shikigami.Directory (DirectorySnapshotVersion (..), DirectorySourceKind (DirectoryDisabledSource), disabledDirectoryHandle)
import Shikigami.Fixture.SinkHttp (testSinkHttp)
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.PracticeReview.Capability qualified as PracticeReviewCapability
import Shikigami.Router.Catalog
  ( CandidateAvailability (..),
    CandidateCatalog (..),
    CandidateEntry (..),
    CatalogVersion (..),
    ExclusionReason (Paused),
  )
import Shikigami.Router.Decision
  ( RouteDecision (..),
    RouteOutcome (..),
    RouteSelection (..),
    RoutingError (..),
  )
import Shikigami.Sink (GrantSource (StaticGrants), defaultGrantTable)
import Shikigami.Sink.Config (DanwaConfig (..), KanmonConfig (..), KawaConfig (..), KizashiConfig (..), ReiConfig (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: DatabaseFixture -> TestTree
tests databaseFixture =
  testGroup
    "RouterWorkflow"
    [ testCase "journals semantic outcomes and rejects unauthorized proposals" (semanticAndAuthorizationMatrix databaseFixture),
      testCase "matched fan-out replays catalog, decision, child ids, and bounded telemetry" (matchedReplayProof databaseFixture),
      testCase "no-match and ambiguous complete without child workflows" (nonExecutableOutcomesSpawnNothing databaseFixture),
      testCase "an exhausted batch budget spawns no child" (exhaustedBatchSpawnsNothing databaseFixture),
      testCase "a delegated child failure remains an operational failure" (childFailureEscapes databaseFixture)
    ]

semanticAndAuthorizationMatrix :: DatabaseFixture -> IO ()
semanticAndAuthorizationMatrix databaseFixture =
  withTestTracer \tracer spansRef ->
    (withDatabaseTracer databaseFixture) tracer \appEnv behaviorEnv -> do
      let singleOutcome = Matched (selection "first" RoutingHigh "single" NonEmpty.:| [])
      singleProbe <- newProbe catalog (Aeson.toJSON (RouteDecision 1 testCatalogVersion singleOutcome))
      single <- runDirect appEnv behaviorEnv "router-direct-single" singleProbe
      assertDirectOutcome "one authorized specialist is a valid matched route" singleOutcome single

      noMatchProbe <- newProbe catalog (Aeson.toJSON (RouteDecision 1 testCatalogVersion (NoMatch "no specialist")))
      noMatch <- runDirect appEnv behaviorEnv "router-direct-no-match" noMatchProbe
      assertDirectOutcome "no-match is a successful semantic outcome" (NoMatch "no specialist") noMatch

      ambiguousProbe <- newProbe catalog (Aeson.toJSON (RouteDecision 1 testCatalogVersion (Ambiguous (selection "first" RoutingHigh "possible" NonEmpty.:| []) "unclear")))
      ambiguous <- runDirect appEnv behaviorEnv "router-direct-ambiguous" ambiguousProbe
      assertDirectOutcome
        "ambiguous is a successful advisory outcome"
        (Ambiguous (selection "first" RoutingHigh "possible" NonEmpty.:| []) "unclear")
        ambiguous

      let invalidCases =
            [ ( "undeclared",
                RouteDecision 1 testCatalogVersion (Matched (selection "ghost" RoutingHigh "invented" NonEmpty.:| [])),
                UndeclaredSelection "ghost"
              ),
              ( "paused",
                RouteDecision 1 testCatalogVersion (Matched (selection "paused" RoutingHigh "paused" NonEmpty.:| [])),
                UnavailableSelection "paused" Paused
              ),
              ( "low-confidence",
                RouteDecision 1 testCatalogVersion (Matched (selection "first" RoutingLow "weak" NonEmpty.:| [])),
                ConfidenceBelowMinimum "first" RoutingLow RoutingMedium
              ),
              ( "fanout",
                RouteDecision
                  1
                  testCatalogVersion
                  ( Matched
                      ( selection "first" RoutingHigh "first"
                          NonEmpty.:| [ selection "second" RoutingHigh "second",
                                        selection "third" RoutingHigh "third"
                                      ]
                      )
                  ),
                TooManySelections 3 2
              )
            ]
      traverse_ (assertInvalidProposal appEnv behaviorEnv) invalidCases
      void (Otel.forceFlushTracerProvider (Otel.getTracerTracerProvider tracer) Nothing)
      spans <- routingSpans =<< readIORef spansRef
      validationErrors <- traverse (spanHasTextAttribute "routing.error.category" "validation") spans
      assertBool "invalid proposals leave a bounded validation error category" (or validationErrors)

matchedReplayProof :: DatabaseFixture -> IO ()
matchedReplayProof databaseFixture =
  withTestTracer \tracer spansRef ->
    (withDatabaseTracer databaseFixture) tracer \appEnv behaviorEnv -> do
      let longRationale = Text.replicate 700 "r"
          decision =
            RouteDecision
              1
              testCatalogVersion
              ( Matched
                  ( selection "first" RoutingHigh longRationale
                      NonEmpty.:| [selection "second" RoutingMedium "second rationale"]
                  )
              )
          job = routerJob "router:matched-replay"
          parentWorkflowId = runJobWorkflowId job
          firstChildId = delegatedWorkflowId parentWorkflowId "first" "architecture-practice-first"
          secondChildId = delegatedWorkflowId parentWorkflowId "second" "architecture-practice-second"
      originalProbe <- newProbe catalog (Aeson.toJSON decision)
      let deps = routerDeps appEnv behaviorEnv ((.runtime) originalProbe) [routerDecl, successSpecialist "first", successSpecialist "second"]

      parked <- AgentWorkflow.runAgentRunWorkflow deps job
      assertEqual "the parent waits after spawning the complete accepted batch" (Right Suspended) parked
      assertEqual "catalog resolver runs once before the first journal append" 1 =<< readIORef ((.resolverCalls) originalProbe)
      assertEqual "evaluator runs once before the second journal append" 1 =<< readIORef ((.evaluatorCalls) originalProbe)
      initialChildren <- runAppIO appEnv (lookupChildrenOfParent (runJobWorkflowId job).unWorkflowId "shikigami.agent-run")
      assertEqual "exactly two child links are registered" (Right 2) (length <$> initialChildren)

      firstValue <- runSuccessfulChild appEnv deps firstChildId
      secondValue <- runSuccessfulChild appEnv deps secondChildId

      changedProbe <- newProbe changedCatalog (String "changed evaluator must not run")
      let changedDeps = (routerDeps appEnv behaviorEnv ((.runtime) changedProbe) [routerDecl, successSpecialist "first", successSpecialist "second"])
      resumed <- AgentWorkflow.runAgentRunWorkflow changedDeps job
      parentOutput <- case resumed of
        Right (Completed (Right AgentRunResult {behaviorOutput})) -> pure behaviorOutput
        other -> assertFailure ("matched router should complete after both children: " <> show other)
      assertEqual
        "parent preserves selection order and the recorded decision"
        (object ["decision" .= decision, "results" .= [firstValue, secondValue]])
        parentOutput
      assertEqual "changed catalog resolver is skipped on replay" 0 =<< readIORef ((.resolverCalls) changedProbe)
      assertEqual "changed evaluator is skipped on replay" 0 =<< readIORef ((.evaluatorCalls) changedProbe)
      assertEqual "the original resolver still ran exactly once" 1 =<< readIORef ((.resolverCalls) originalProbe)
      assertEqual "the original evaluator still ran exactly once" 1 =<< readIORef ((.evaluatorCalls) originalProbe)

      replayed <- AgentWorkflow.runAgentRunWorkflow changedDeps job
      assertEqual "completed replay returns the same parent value" resumed replayed
      replayChildren <- runAppIO appEnv (lookupChildrenOfParent (runJobWorkflowId job).unWorkflowId "shikigami.agent-run")
      assertEqual "replay creates no duplicate child link" (length <$> initialChildren) (length <$> replayChildren)

      stepIndex <- runAppIO appEnv (loadStepIndex AgentWorkflow.agentRunWorkflowName parentWorkflowId 0)
      assertEqual "catalog step is present once in the journal index" (Right True) (Map.member "route-catalog-architecture-practice" <$> stepIndex)
      assertEqual "decision step is present once in the journal index" (Right True) (Map.member "route-decision-architecture-practice" <$> stepIndex)

      void (Otel.forceFlushTracerProvider (Otel.getTracerTracerProvider tracer) Nothing)
      spans <- routingSpans =<< readIORef spansRef
      assertBool "initial execution and resume both emit bounded routing evidence" (length spans >= 2)
      routingSpan <- case spans of
        firstSpan : _ -> pure firstSpan
        [] -> assertFailure "routing span list became empty after the count assertion"
      hot <- readIORef (Otel.spanHot routingSpan)
      let attributes = getAttributeMap (Otel.hotAttributes hot)
      assertTextAttribute attributes "router.agent" "router"
      assertTextAttribute attributes "routing.parent.workflow" "shikigami.agent-run"
      assertTextAttribute attributes "routing.catalog.version" "catalog-v1"
      assertTextAttribute attributes "routing.lifecycle.source" "local-enabled"
      assertTextAttribute attributes "routing.selected.agents" "first,second"
      assertTextAttribute attributes "routing.selected.expertise" "observability,observability"
      assertTextAttribute attributes "routing.selected.rationale" (Text.take 512 longRationale <> " | second rationale")
      let renderedAttributes = Text.pack (show attributes)
      assertBool "trigger bodies are never trace attributes" (not (secretTrigger `Text.isInfixOf` renderedAttributes))
      assertBool "candidate descriptions are never trace attributes" (not (secretDescription `Text.isInfixOf` renderedAttributes))

nonExecutableOutcomesSpawnNothing :: DatabaseFixture -> IO ()
nonExecutableOutcomesSpawnNothing databaseFixture = do
  tracer <- noopTracer
  (withDatabaseTracer databaseFixture) tracer \appEnv behaviorEnv -> do
    let cases =
          [ ("no-match", RouteDecision 1 testCatalogVersion (NoMatch "none")),
            ("ambiguous", RouteDecision 1 testCatalogVersion (Ambiguous (selection "first" RoutingHigh "maybe" NonEmpty.:| []) "unclear"))
          ]
    traverse_ (runCase appEnv behaviorEnv) cases
  where
    runCase appEnv behaviorEnv (label, decision) = do
      probe <- newProbe catalog (Aeson.toJSON decision)
      let job = routerJob ("router:" <> label)
          deps = routerDeps appEnv behaviorEnv ((.runtime) probe) [routerDecl, successSpecialist "first"]
      outcome <- AgentWorkflow.runAgentRunWorkflow deps job
      case outcome of
        Right (Completed (Right AgentRunResult {behaviorOutput})) ->
          assertEqual
            (Text.unpack label <> " returns its typed decision")
            (object ["decision" .= decision, "results" .= ([] :: [Value])])
            behaviorOutput
        other -> assertFailure (Text.unpack label <> " should complete, got " <> show other)
      children <- runAppIO appEnv (lookupChildrenOfParent (runJobWorkflowId job).unWorkflowId "shikigami.agent-run")
      assertEqual (Text.unpack label <> " spawns zero children") (Right 0) (length <$> children)

exhaustedBatchSpawnsNothing :: DatabaseFixture -> IO ()
exhaustedBatchSpawnsNothing databaseFixture = do
  tracer <- noopTracer
  (withDatabaseTracer databaseFixture) tracer \appEnv behaviorEnv -> do
    probe <- newProbe catalog (Aeson.toJSON (matchedDecision [selection "first" RoutingHigh "route"]))
    let job = routerJob "router:budget-exhausted"
        zeroBudget = either (error . Text.unpack) id (mkDelegationBudget 0)
        constrainedRouter = routerDecl {delegationBudget = Just zeroBudget}
        deps = routerDeps appEnv behaviorEnv ((.runtime) probe) [constrainedRouter, successSpecialist "first"]
    refused <- try @DelegationError (AgentWorkflow.runAgentRunWorkflow deps job)
    assertEqual "budget exhaustion remains an operational failure" (Left DelegationBudgetExhausted) refused
    children <- runAppIO appEnv (lookupChildrenOfParent (runJobWorkflowId job).unWorkflowId "shikigami.agent-run")
    assertEqual "no child is registered after rejected batch reservation" (Right 0) (length <$> children)

childFailureEscapes :: DatabaseFixture -> IO ()
childFailureEscapes databaseFixture = do
  tracer <- noopTracer
  (withDatabaseTracer databaseFixture) tracer \appEnv behaviorEnv -> do
    let decision = matchedDecision [selection "failing" RoutingHigh "route"]
        job = routerJob "router:child-failure"
        parentWorkflowId = runJobWorkflowId job
        childWorkflowId = delegatedWorkflowId parentWorkflowId "failing" "architecture-practice-failing"
    probe <- newProbe catalog (Aeson.toJSON decision)
    let deps = routerDeps appEnv behaviorEnv ((.runtime) probe) [routerDecl, failingSpecialist]
    parked <- AgentWorkflow.runAgentRunWorkflow deps job
    assertEqual "parent parks on the failing child" (Right Suspended) parked
    child <- runAppIO appEnv (runChildWorkflow defaultWorkflowRunOptions AgentWorkflow.agentRunWorkflowName childWorkflowId (AgentWorkflow.agentRunWorkflow deps Nothing))
    case child of
      Right (Completed (Left _)) -> pure ()
      other -> assertFailure ("child should complete with a typed failure, got " <> show other)
    resumed <- try @DelegationError (AgentWorkflow.runAgentRunWorkflow deps job)
    case resumed of
      Left (DelegatedChildFailed detail) -> assertBool "the child failure detail is retained" (not (Text.null detail))
      other -> assertFailure ("parent must surface the child failure operationally, got " <> show other)

data RuntimeProbe = RuntimeProbe
  { runtime :: !Routing.RoutingRuntime,
    resolverCalls :: !(IORef Int),
    evaluatorCalls :: !(IORef Int)
  }

newProbe :: CandidateCatalog -> Value -> IO RuntimeProbe
newProbe resolvedCatalog rawDecision = do
  resolverCalls <- newIORef 0
  evaluatorCalls <- newIORef 0
  let runtime =
        Routing.RoutingRuntime
          { Routing.resolveCatalog = \_ -> do
              atomicModifyIORef' resolverCalls (\count -> (count + 1, ()))
              pure resolvedCatalog,
            Routing.evaluateRoute = \_ _ _ -> do
              atomicModifyIORef' evaluatorCalls (\count -> (count + 1, ()))
              pure (Right rawDecision)
          }
  pure RuntimeProbe {runtime, resolverCalls, evaluatorCalls}

runDirect :: AppEnv -> BehaviorEnv -> Text -> RuntimeProbe -> IO (Either StoreError (WorkflowOutcome Routing.RoutedRoute))
runDirect appEnv behaviorEnv workflowId probe =
  runAppIO
    appEnv
    ( runWorkflow
        (WorkflowName "shikigami.test-router")
        (WorkflowId workflowId)
        ( Routing.runRouting
            Routing.RoutingEnv
              { Routing.agent = routerDecl,
                Routing.sessionId = "direct-router-session",
                Routing.behaviorEnv = behaviorEnv,
                Routing.runtime = (.runtime) probe
              }
            (Routing.routeWithCatalog Routing.ArchitecturePractice secretPayload)
        )
    )

assertDirectOutcome :: String -> RouteOutcome -> Either StoreError (WorkflowOutcome Routing.RoutedRoute) -> IO ()
assertDirectOutcome label expected = \case
  Right (Completed Routing.RoutedRoute {Routing.decision = RouteDecision {outcome}}) -> assertEqual label expected outcome
  other -> assertFailure (label <> ", got " <> outcomeShape other)

assertInvalidProposal :: AppEnv -> BehaviorEnv -> (Text, RouteDecision, RoutingError) -> IO ()
assertInvalidProposal appEnv behaviorEnv (label, decision, expectedError) = do
  probe <- newProbe catalog (Aeson.toJSON decision)
  refused <- try @Routing.RoutingFailure (runDirect appEnv behaviorEnv ("router-invalid-" <> label) probe)
  case refused of
    Left (Routing.RoutingDecisionInvalid errors) ->
      assertBool (Text.unpack label <> " reports its authorization error") (expectedError `elem` NonEmpty.toList errors)
    other -> assertFailure (Text.unpack label <> " should fail route validation, got " <> showRoutingTry other)

routerDeps :: AppEnv -> BehaviorEnv -> Routing.RoutingRuntime -> [AgentDecl] -> AgentWorkflow.AgentRunDeps
routerDeps appEnv behaviorEnv routing agents =
  AgentWorkflow.AgentRunDeps
    { AgentWorkflow.appEnv,
      AgentWorkflow.behaviorEnv,
      AgentWorkflow.actionAuthorizer = allowAllActionAuthorizerForTests,
      AgentWorkflow.capabilities = CapabilityProvider.emptyCapabilityRuntime,
      AgentWorkflow.agents,
      AgentWorkflow.kizashi = KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = "recipient"},
      AgentWorkflow.kawa = KawaConfig {baseUrl = "http://localhost:1", sourceSegment = "shinzui/shikigami"},
      AgentWorkflow.kanmon = KanmonConfig {baseUrl = "http://localhost:1"},
      AgentWorkflow.danwa = DanwaConfig {baseUrl = "http://localhost:1", agentParticipant = "part_agent_test"},
      AgentWorkflow.rei = ReiConfig {baseUrl = Nothing},
      AgentWorkflow.http = testSinkHttp,
      AgentWorkflow.hooks = AgentWorkflow.defaultAgentRunHooks,
      AgentWorkflow.approvalPolicy = autoApprovePolicy (secondsToNominalDiffTime 900),
      AgentWorkflow.approvalWorkflow = ApprovalWorkflow.defaultApprovalWorkflowEnv,
      AgentWorkflow.runTimeout = secondsToNominalDiffTime 300,
      AgentWorkflow.delegationBudget = defaultDelegationBudget,
      AgentWorkflow.logger = Log.silentLogger,
      AgentWorkflow.grants = StaticGrants defaultGrantTable,
      AgentWorkflow.directory = disabledDirectoryHandle,
      AgentWorkflow.routing,
      AgentWorkflow.practiceReview = PracticeReviewCapability.unavailablePracticeReviewRuntime,
      AgentWorkflow.deliveryPool = Nothing,
      AgentWorkflow.resolveRunProfile = \profileId version -> pure (Left (UnknownProfile profileId version))
    }

runSuccessfulChild :: AppEnv -> AgentWorkflow.AgentRunDeps -> WorkflowId -> IO Value
runSuccessfulChild appEnv deps childWorkflowId = do
  child <- runAppIO appEnv (runChildWorkflow defaultWorkflowRunOptions AgentWorkflow.agentRunWorkflowName childWorkflowId (AgentWorkflow.agentRunWorkflow deps Nothing))
  case child of
    Right (Completed (Right AgentRunResult {behaviorOutput})) -> pure behaviorOutput
    other -> assertFailure ("specialist child should complete, got " <> show other)

routerJob :: Text -> RunJob
routerJob key =
  RunJob
    { agentName = AgentName "router",
      identity = compatibilityIdentity "router",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = fixedTime,
      triggerPayload = secretPayload,
      idempotencyKey = RunKey key,
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = map AgentName ["router"],
      delegationBudgetId = Nothing
    }

routerDecl :: AgentDecl
routerDecl =
  AgentDecl
    { name = "router",
      description = "routes architecture practice work",
      trigger = Event {eventType = "test.router"},
      behavior = Flow {name = "architecture-practice-router"},
      sinks = [],
      delegates = ["first", "second", "third", "paused", "failing"],
      delegationBudget = Just defaultDelegationBudget,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True,
      expertise = [],
      routing = Just routerPolicy
    }

successSpecialist :: Text -> AgentDecl
successSpecialist specialistName =
  specialist
    specialistName
    ShikumiProgram
      { task = "noop-summary",
        preferEnrichment = False,
        grounding = Nothing,
        enabledBy = Nothing
      }

failingSpecialist :: AgentDecl
failingSpecialist =
  specialist
    "failing"
    ShikumiProgram
      { task = "missing-router-test-task",
        preferEnrichment = False,
        grounding = Nothing,
        enabledBy = Nothing
      }

specialist :: Text -> Behavior -> AgentDecl
specialist specialistName specialistBehavior =
  AgentDecl
    { name = specialistName,
      description = "router specialist",
      trigger = Event {eventType = "test.specialist"},
      behavior = specialistBehavior,
      sinks = [],
      delegates = [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True,
      expertise = [expertiseEntry],
      routing = Nothing
    }

routerPolicy :: RouterPolicy
routerPolicy =
  RouterPolicy
    { maxSelections = 2,
      minimumConfidence = RoutingMedium,
      onNoMatch = ReturnNoMatch,
      onAmbiguous = ReturnAmbiguous
    }

testCatalogVersion :: CatalogVersion
testCatalogVersion = CatalogVersion "catalog-v1"

catalog :: CandidateCatalog
catalog =
  CandidateCatalog
    { router = "router",
      version = testCatalogVersion,
      lifecycleSource = DirectoryDisabledSource,
      lifecycleSourceVersion = DirectorySnapshotVersion "directory-v1",
      candidates =
        [ candidate "first" Available,
          candidate "second" Available,
          candidate "third" Available,
          candidate "paused" (Excluded Paused),
          candidate "failing" Available
        ],
      unassociatedLoadFailures = 0
    }

changedCatalog :: CandidateCatalog
changedCatalog = catalog {version = CatalogVersion "changed-catalog", candidates = []}

candidate :: Text -> CandidateAvailability -> CandidateEntry
candidate candidateName availability =
  CandidateEntry
    { name = candidateName,
      description = Just secretDescription,
      expertise = [expertiseEntry],
      availability
    }

expertiseEntry :: ExpertiseDecl
expertiseEntry =
  ExpertiseDecl
    { key = "observability",
      description = "trace architecture",
      aliases = ["otel"],
      evidenceHints = ["traceparent"]
    }

selection :: Text -> RouterConfidence -> Text -> RouteSelection
selection agent confidence rationale =
  RouteSelection
    { agent,
      expertise = ["observability"],
      confidence,
      rationale
    }

matchedDecision :: [RouteSelection] -> RouteDecision
matchedDecision selections =
  case NonEmpty.nonEmpty selections of
    Just nonEmptySelections -> RouteDecision 1 testCatalogVersion (Matched nonEmptySelections)
    Nothing -> error "matchedDecision test fixture requires a selection"

secretTrigger :: Text
secretTrigger = "SECRET-TRIGGER-BODY"

secretDescription :: Text
secretDescription = "SECRET-CANDIDATE-DESCRIPTION"

secretPayload :: Value
secretPayload = object ["document" .= secretTrigger]

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 8 23) 0

withDatabaseTracer :: DatabaseFixture -> Otel.Tracer -> (AppEnv -> BehaviorEnv -> IO a) -> IO a
withDatabaseTracer databaseFixture tracer use =
  (withShikigamiFreshDatabase databaseFixture) \connectionString ->
    withStore (defaultConnectionSettings connectionString) \_ -> do
      behaviorEnv <- newBehaviorEnv
      use
        AppEnv
          { connectionSettings = defaultConnectionSettings connectionString,
            tracer,
            metrics = Nothing
          }
        behaviorEnv

withTestTracer :: (Otel.Tracer -> IORef [Otel.ImmutableSpan] -> IO a) -> IO a
withTestTracer use =
  bracket acquire release \(tracer, spansRef) -> use tracer spansRef
  where
    acquire = do
      (processor, spansRef) <- inMemoryListExporter
      provider <- Otel.createTracerProvider [processor] Otel.emptyTracerProviderOptions
      let tracer = Otel.makeTracer provider "shikigami-router-test" Otel.tracerOptions
      pure (tracer, spansRef)
    release (tracer, _) = void (Otel.shutdownTracerProvider (Otel.getTracerTracerProvider tracer) Nothing)

routingSpans :: [Otel.ImmutableSpan] -> IO [Otel.ImmutableSpan]
routingSpans = filterM (fmap ((== "routing.route") . Otel.hotName) . readIORef . Otel.spanHot)

assertTextAttribute :: HashMap.HashMap Text Attribute -> Text -> Text -> IO ()
assertTextAttribute attributes key expected =
  case HashMap.lookup key attributes of
    Just (AttributeValue (TextAttribute actual)) -> assertEqual (Text.unpack key) expected actual
    Just other -> assertFailure (Text.unpack key <> " is not text: " <> show other)
    Nothing -> assertFailure (Text.unpack key <> " is missing")

spanHasTextAttribute :: Text -> Text -> Otel.ImmutableSpan -> IO Bool
spanHasTextAttribute key expected span' = do
  hot <- readIORef (Otel.spanHot span')
  pure $ case HashMap.lookup key (getAttributeMap (Otel.hotAttributes hot)) of
    Just (AttributeValue (TextAttribute actual)) -> actual == expected
    _ -> False

outcomeShape :: Either StoreError (WorkflowOutcome value) -> String
outcomeShape = \case
  Left _ -> "store error"
  Right Completed {} -> "completed with a different value"
  Right Suspended -> "suspended"
  Right ContinuedAsNew {} -> "continued as new"
  Right Cancelled -> "cancelled"
  Right Failed -> "failed"

showRoutingTry :: Either Routing.RoutingFailure (Either StoreError (WorkflowOutcome value)) -> String
showRoutingTry = \case
  Left failure -> show failure
  Right outcome -> outcomeShape outcome
