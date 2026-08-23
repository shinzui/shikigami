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
import Baikai.Provider (completeRequest)
import Baikai.Response (flattenAssistantBlocks, flattenAssistantText, responseError)
import Baikai.ResponseFormat (ResponseFormat (JsonObject))
import Baikai.Trace qualified as BaikaiTrace
import Control.Exception (Exception)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Text (encodeToLazyText)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Lazy qualified as LazyText
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Exception (throwIO)
import Keiro.Workflow (StepName (..), Workflow, step)
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.Agent.Loader (AgentLoadReport)
import Shikigami.Behavior.Run (BehaviorEnv (..))
import Shikigami.Directory (DirectoryHandle, readDirectorySnapshot)
import Shikigami.Prelude
import Shikigami.Router.Catalog (CandidateCatalog, buildCandidateCatalog)
import Shikigami.Router.Decision (RouteDecision, RoutingError, renderRoutingError, validateRouteDecision)
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
route label payload = decision <$> routeWithCatalog label payload

routeWithCatalog :: (Routing :> es) => RouteLabel -> Value -> Eff es RoutedRoute
routeWithCatalog label payload = send (Route label payload)

runRouting ::
  (Workflow :> es, IOE :> es) =>
  RoutingEnv ->
  Eff (Routing : es) a ->
  Eff es a
runRouting RoutingEnv {agent, behaviorEnv, runtime = RoutingRuntime {resolveCatalog, evaluateRoute}} =
  interpret \_ -> \case
    Route label payload -> do
      validatedDeclaration <-
        case validateRouterDeclaration agent of
          Left errors ->
            case NonEmpty.nonEmpty errors of
              Just refusals -> throwIO (RoutingDeclarationInvalid refusals)
              Nothing -> throwIO (RoutingEvaluationFailed "router declaration validation failed without a diagnostic")
          Right validated -> pure validated
      let (catalogStepName, decisionStepName) = routeStepNames label
      catalog <- step catalogStepName (liftIO (resolveCatalog validatedDeclaration))
      rawDecision <-
        step decisionStepName do
          evaluated <- liftIO (evaluateRoute behaviorEnv catalog payload)
          either throwIO pure evaluated
      decision <-
        case Aeson.fromJSON rawDecision of
          Aeson.Error detail -> throwIO (RoutingDecisionDecodeFailed (boundedDetail (Text.pack detail)))
          Aeson.Success decoded -> pure decoded
      case validateRouteDecision (policy validatedDeclaration) catalog decision of
        Left refusals -> throwIO (RoutingDecisionInvalid refusals)
        Right _ -> pure RoutedRoute {catalog, decision}

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
modelRouteEvaluator BehaviorEnv {model, options, traceSink} catalog payload = do
  let context = systemUser routingSystemPrompt (routingUserPrompt catalog payload)
      structuredOptions = options & #responseFormat .~ Just JsonObject
  response <- case traceSink of
    Nothing -> completeRequest model context structuredOptions
    Just sink -> BaikaiTrace.withTrace sink model context structuredOptions
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
            [ "catalog" Aeson..= catalog,
              "input" Aeson..= payload
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
