{-# LANGUAGE TypeFamilies #-}

-- | Replay-safe semantic routing for Flow bodies.
--
-- The Flow body can request one statically registered routing call site, but
-- cannot perform live declaration/directory reads or invoke a provider itself.
-- This interpreter journals the complete candidate catalog and raw evaluator
-- value first, then strictly decodes and validates the proposal before returning
-- it to the Flow.
module Shikigami.Flow.Routing
  ( Routing,
    RouteLabel (..),
    RoutedRoute (..),
    RoutingEnv (..),
    RoutingRuntime (..),
    RoutingFailure (..),
    route,
    routeWithCatalog,
    runRouting,
    routingRuntime,
    modelRouteEvaluator,
    renderRoutingFailure,
  )
where

import Baikai.Context (systemUser)
import Baikai.Response (flattenAssistantBlocks, flattenAssistantText, responseError)
import Baikai.ResponseFormat (ResponseFormat (JsonObject))
import Control.Exception (Exception, fromException)
import Data.Aeson (Value, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Text (encodeToLazyText)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Lazy qualified as LazyText
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Exception (catchSync, throwIO)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowName (..), currentWorkflow, step)
import Shibuya.Telemetry.Effect (Span, Tracing, addAttribute, defaultSpanArguments, withSpan')
import Shikigami.Agent.Decl (AgentDecl (..), RouterConfidence (..))
import Shikigami.Agent.Loader (AgentLoadReport)
import Shikigami.Behavior.Compatibility
import Shikigami.Behavior.Run (BehaviorEnv (..), completeBehaviorRequest)
import Shikigami.Directory (DirectoryHandle, readDirectorySnapshot, renderDirectorySourceKind)
import Shikigami.Prelude hiding ((.=))
import Shikigami.Router.Catalog (CandidateAvailability (..), CandidateCatalog (..), CandidateEntry (..), CatalogVersion (..), buildCandidateCatalog)
import Shikigami.Router.Decision (RouteDecision (..), RouteOutcome (..), RouteSelection (..), RoutingError, renderRoutingError, validateRouteDecision)
import Shikigami.Router.Declaration (RouterDeclarationError, ValidatedRouterDeclaration (..), renderRouterDeclarationError, validateRouterDeclaration)

-- | Closed registry of routing call sites.  A constructor maps to two literal
-- declared step names; payload data can never become a durable label.
data RouteLabel = ArchitecturePractice
  deriving stock (Eq, Ord, Show, Generic)

-- | Process-local dependencies.  Neither function result is trusted until it
-- crosses the journal and validation boundary in 'runRouting'.
data RoutingRuntime = RoutingRuntime
  { resolveCatalog :: !(ValidatedRouterDeclaration -> IO CandidateCatalog),
    evaluateRoute :: !(BehaviorEnv -> CandidateCatalog -> Value -> IO (Either RoutingFailure Value))
  }

data RoutingEnv = RoutingEnv
  { agent :: !AgentDecl,
    sessionId :: !Text,
    behaviorEnv :: !BehaviorEnv,
    runtime :: !RoutingRuntime
  }

data RoutingFailure
  = RoutingDeclarationInvalid !(NonEmpty RouterDeclarationError)
  | RoutingEvaluationFailed !Text
  | RoutingDecisionDecodeFailed !Text
  | RoutingDecisionInvalid !(NonEmpty RoutingError)
  deriving stock (Eq, Show)

instance Exception RoutingFailure

-- | The exact journaled catalog paired with the validated semantic decision.
-- Most flows need only 'route'; the registered router retains the catalog for
-- the delegation boundary's independent availability preflight.
data RoutedRoute = RoutedRoute
  { catalog :: !CandidateCatalog,
    decision :: !RouteDecision
  }
  deriving stock (Eq, Show)

data Routing :: Effect where
  Route :: RouteLabel -> Value -> Routing m RoutedRoute

type instance DispatchOf Routing = Dynamic

route :: (Routing :> es) => RouteLabel -> Value -> Eff es RouteDecision
route label payload = (.decision) <$> routeWithCatalog label payload

routeWithCatalog :: (Routing :> es) => RouteLabel -> Value -> Eff es RoutedRoute
routeWithCatalog label payload = send (Route label payload)

runRouting ::
  (Workflow :> es, Tracing :> es, IOE :> es) =>
  RoutingEnv ->
  Eff (Routing : es) a ->
  Eff es a
runRouting RoutingEnv {agent = routerDecl@AgentDecl {name = routerAgent}, sessionId, behaviorEnv, runtime = RoutingRuntime {resolveCatalog, evaluateRoute}} =
  interpret \_ -> \case
    Route label payload ->
      withSpan' "routing.route" defaultSpanArguments \traceSpan -> do
        (WorkflowName parentWorkflowName, WorkflowId parentWorkflowId) <- currentWorkflow
        addAttribute traceSpan "routing.parent.session_id" sessionId
        addAttribute traceSpan "routing.parent.workflow" parentWorkflowName
        addAttribute traceSpan "routing.parent.workflow_id" parentWorkflowId
        addAttribute traceSpan "router.agent" routerAgent
        routeAction traceSpan label payload `catchSync` \err -> do
          forM_ (fromException @RoutingFailure err) \failure ->
            addAttribute traceSpan "routing.error.category" (routingFailureCategory failure)
          throwIO err
  where
    routeAction traceSpan label payload = do
      validatedDeclaration <-
        case validateRouterDeclaration routerDecl of
          Left errors ->
            case NonEmpty.nonEmpty errors of
              Just refusals -> throwIO (RoutingDeclarationInvalid refusals)
              Nothing -> throwIO (RoutingEvaluationFailed "router declaration validation failed without a diagnostic")
          Right validated -> pure validated
      let (catalogStepName, decisionStepName) = routeStepNames label
      catalog <- step catalogStepName (liftIO (resolveCatalog validatedDeclaration))
      recordCatalogAttributes traceSpan catalog
      rawDecision <-
        step decisionStepName do
          evaluated <- liftIO (evaluateRoute behaviorEnv catalog payload)
          either throwIO pure evaluated
      decision <-
        case Aeson.fromJSON rawDecision of
          Aeson.Error detail -> throwIO (RoutingDecisionDecodeFailed (boundedDetail (Text.pack detail)))
          Aeson.Success decoded -> pure decoded
      case validateRouteDecision ((.policy) validatedDeclaration) catalog decision of
        Left refusals -> throwIO (RoutingDecisionInvalid refusals)
        Right _ -> do
          recordDecisionAttributes traceSpan decision
          pure RoutedRoute {catalog, decision}

recordCatalogAttributes :: (Tracing :> es, IOE :> es) => Span -> CandidateCatalog -> Eff es ()
recordCatalogAttributes traceSpan CandidateCatalog {router, version = CatalogVersion catalogVersion, lifecycleSource, candidates} = do
  addAttribute traceSpan "router.agent" router
  addAttribute traceSpan "routing.catalog.version" catalogVersion
  addAttribute traceSpan "routing.lifecycle.source" (renderDirectorySourceKind lifecycleSource)
  addAttribute traceSpan "routing.candidates.available" (boundedList [name | CandidateEntry {name, availability = Available} <- candidates])
  addAttribute
    traceSpan
    "routing.candidates.excluded"
    ( boundedList
        [ name <> ":" <> boundedText 64 (Text.pack (show reason))
        | CandidateEntry {name, availability = Excluded reason} <- candidates
        ]
    )

recordDecisionAttributes :: (Tracing :> es, IOE :> es) => Span -> RouteDecision -> Eff es ()
recordDecisionAttributes traceSpan RouteDecision {outcome} =
  case outcome of
    Matched selections -> do
      addAttribute traceSpan "routing.outcome" ("matched" :: Text)
      recordSelections traceSpan "routing.selected" selections
    NoMatch rationale -> do
      addAttribute traceSpan "routing.outcome" ("no-match" :: Text)
      addAttribute traceSpan "routing.rationale" (boundedText rationaleLimit rationale)
    Ambiguous alternatives rationale -> do
      addAttribute traceSpan "routing.outcome" ("ambiguous" :: Text)
      recordSelections traceSpan "routing.alternative" alternatives
      addAttribute traceSpan "routing.rationale" (boundedText rationaleLimit rationale)

recordSelections :: (Tracing :> es, IOE :> es) => Span -> Text -> NonEmpty RouteSelection -> Eff es ()
recordSelections traceSpan prefix selections = do
  let values = NonEmpty.toList selections
  addAttribute traceSpan (prefix <> ".agents") (boundedList [agent | RouteSelection {agent} <- values])
  addAttribute traceSpan (prefix <> ".expertise") (boundedList (concat [expertise | RouteSelection {expertise} <- values]))
  addAttribute traceSpan (prefix <> ".confidence") (boundedList [confidenceText confidence | RouteSelection {confidence} <- values])
  addAttribute traceSpan (prefix <> ".rationale") (boundedRationales [rationale | RouteSelection {rationale} <- values])

routingFailureCategory :: RoutingFailure -> Text
routingFailureCategory = \case
  RoutingDeclarationInvalid {} -> "declaration"
  RoutingEvaluationFailed {} -> "evaluation"
  RoutingDecisionDecodeFailed {} -> "decode"
  RoutingDecisionInvalid {} -> "validation"

confidenceText :: RouterConfidence -> Text
confidenceText = \case
  RoutingLow -> "low"
  RoutingMedium -> "medium"
  RoutingHigh -> "high"

rationaleLimit :: Int
rationaleLimit = 512

boundedList :: [Text] -> Text
boundedList = Text.intercalate "," . fmap (boundedText 128) . take 32

boundedRationales :: [Text] -> Text
boundedRationales = Text.intercalate " | " . fmap (boundedText rationaleLimit) . take 32

boundedText :: Int -> Text -> Text
boundedText = Text.take

routeStepNames :: RouteLabel -> (StepName, StepName)
routeStepNames ArchitecturePractice =
  ( StepName "route-catalog-architecture-practice",
    StepName "route-decision-architecture-practice"
  )

-- | Production runtime over the exact startup loader report and one immutable
-- directory projection per invocation.
routingRuntime :: AgentLoadReport -> DirectoryHandle -> RoutingRuntime
routingRuntime report directory =
  RoutingRuntime
    { resolveCatalog = \validated -> do
        snapshot <- readDirectorySnapshot directory
        pure (buildCandidateCatalog report snapshot validated),
      evaluateRoute = modelRouteEvaluator
    }

-- | Evaluate one routing prompt through the active provider/model/options.
-- A sanctioned profile has already constrained this 'BehaviorEnv' before a
-- Flow is interpreted, so routing cannot silently escape that call tuple.
modelRouteEvaluator :: BehaviorEnv -> CandidateCatalog -> Value -> IO (Either RoutingFailure Value)
modelRouteEvaluator env@BehaviorEnv {model, options} catalog payload = do
  let context = systemUser routingSystemPrompt (routingUserPrompt catalog payload)
      structuredOptions = options & #responseFormat .~ Just JsonObject
  case validateResponseRequest model structuredOptions context of
    Left refusal -> pure (Left (RoutingEvaluationFailed (renderResponseCompatibilityError refusal)))
    Right () -> do
      response <- completeBehaviorRequest env model context structuredOptions
      case responseError response of
        Just failure -> pure (Left (RoutingEvaluationFailed (boundedDetail (Text.pack (show failure)))))
        Nothing ->
          let responseText = flattenAssistantText (flattenAssistantBlocks response)
           in case Aeson.eitherDecodeStrict' (Text.encodeUtf8 responseText) of
                Left detail -> pure (Left (RoutingEvaluationFailed (boundedDetail ("evaluator returned invalid JSON: " <> Text.pack detail))))
                Right value -> pure (Right value)

routingSystemPrompt :: Text
routingSystemPrompt =
  Text.unlines
    [ "You are a semantic router. Return one JSON object and no prose.",
      "Use only candidates present in the supplied catalog.",
      "The object must have version 1, the supplied catalogVersion, and outcome matched, no-match, or ambiguous.",
      "A matched object carries non-empty selections; an ambiguous object carries non-empty alternatives; each selection has agent, expertise, confidence (low, medium, or high), and rationale.",
      "Do not copy the full input into rationale."
    ]

routingUserPrompt :: CandidateCatalog -> Value -> Text
routingUserPrompt catalog payload =
  LazyText.toStrict
    ( encodeToLazyText
        ( Aeson.object
            [ "catalog" .= catalog,
              "input" .= payload
            ]
        )
    )

boundedDetail :: Text -> Text
boundedDetail = Text.take 512

renderRoutingFailure :: RoutingFailure -> Text
renderRoutingFailure = \case
  RoutingDeclarationInvalid errors ->
    Text.intercalate "; " (renderRouterDeclarationError <$> NonEmpty.toList errors)
  RoutingEvaluationFailed detail -> detail
  RoutingDecisionDecodeFailed detail -> detail
  RoutingDecisionInvalid errors ->
    Text.intercalate "; " (renderRoutingError <$> NonEmpty.toList errors)
