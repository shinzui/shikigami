-- | The architecture-practice router: one routing decision over the declared
-- specialists, then one governed child per selection.
module FlowPack.PracticeReview.Body.Router
  ( architecturePracticeRouterFlow,
    architecturePracticeRouteSite,
  )
where

import Data.Aeson (Value, (.=))
import Data.Aeson qualified as Aeson
import Data.List.NonEmpty qualified as NonEmpty
import Shikigami.Agent.Delegate (DelegationRequest (..))
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Flow.Delegate qualified as Delegate
import Shikigami.Flow.Routing (RouteSite, RoutedRoute (..), routeSite, routeWithCatalog)
import Shikigami.Flow.Sdk (Eff, FlowEffects, declarationCoordinate)
import Shikigami.Router.Decision (RouteDecision (..), RouteOutcome (..), RouteSelection (..))

-- | The pack's one route site. It journals
-- @route-catalog-practice-review-architecture-practice@ and
-- @route-decision-practice-review-architecture-practice@.
architecturePracticeRouteSite :: RouteSite
architecturePracticeRouteSite = routeSite "practice-review-architecture-practice"

-- | A matched decision reserves every selection before any child is spawned,
-- then awaits successful results in selection order. Semantic no-match and
-- ambiguous outcomes spawn nothing; operational and child failures escape the
-- flow.
architecturePracticeRouterFlow :: (FlowEffects es) => Value -> Eff es Value
architecturePracticeRouterFlow payload = do
  RoutedRoute {catalog, decision = decision@RouteDecision {outcome}} <-
    routeWithCatalog architecturePracticeRouteSite payload
  case outcome of
    Matched selections -> do
      children <- Delegate.delegateBatch catalog (toRequest <$> selections)
      results <- traverse Delegate.awaitOne children
      pure
        ( Aeson.object
            [ "decision" .= decision,
              "results" .= NonEmpty.toList results
            ]
        )
    NoMatch _ -> pure (semanticResult decision)
    Ambiguous _ _ -> pure (semanticResult decision)
  where
    toRequest RouteSelection {agent} =
      DelegationRequest
        { key = declarationCoordinate ("practice-review-" <> agentNameText agent),
          target = agent,
          payload
        }

    semanticResult decision =
      Aeson.object
        [ "decision" .= decision,
          "results" .= ([] :: [Value])
        ]
