{-# LANGUAGE DataKinds #-}

-- | The flows, decision programs and program tasks still compiled into the
-- core, as one pack. Stock roles compose this pack and nothing else; a
-- distribution adds its own packs beside it. The module is frozen
-- (docs/adr/0129): nothing joins it, and it shrinks as each use case leaves
-- for a pack of its own.
module Shikigami.Flow.Builtin
  ( builtinPack,
    builtinFlowRegistry,
  )
where

import Data.Aeson (Value, (.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Delegate (DelegationRequest (..))
import Shikigami.Agent.Name (agentNameFromNonEmpty, agentNameText)
import Shikigami.Capability.Declared (mkToolName)
import Shikigami.Coordination.Capability (AdaptiveDelivery)
import Shikigami.Coordination.Decision (adaptiveSlots)
import Shikigami.DeclaredTool.Workflow qualified as DeclaredToolWorkflow
import Shikigami.Flow (DecisionMode (..), FlowDef (..), FlowEffects, LifecycleDiagram (..))
import Shikigami.Flow.AdaptiveDelivery (adaptiveDelivery)
import Shikigami.Flow.DeclaredTool qualified as DeclaredTool
import Shikigami.Flow.Delegate qualified as Delegate
import Shikigami.Flow.Initiative (proposeWork, proposeWorkFlowName, proposeWorkSlots)
import Shikigami.Flow.ObjectiveExample (objectiveExample)
import Shikigami.Flow.OpenTelemetryPracticeReview
  ( opentelemetryPracticeReviewFlow,
    opentelemetryPracticeReviewFlowName,
    opentelemetryPracticeReviewMermaid,
  )
import Shikigami.Flow.Pack
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Flow.ShikumiDecisionExample (exampleSlots, shikumiDecisionExample)
import Shikigami.Flow.ShikumiJudgmentExample (judgmentSlots, shikumiJudgmentExample)
import Shikigami.Flow.Watchdog (watchdogFlowName, watchdogSlots, watchdogSweep)
import Shikigami.Program.Decision.Registry (builtinDecisionPrograms, builtinRetainedCodecs)
import Shikigami.Program.Registry (programRegistry)
import Shikigami.Router.Decision (RouteDecision (..), RouteOutcome (..), RouteSelection (..))
import Shikigami.RuntimePolicy

-- | The one pack the stock roles compose.
builtinPack :: FlowPack
builtinPack =
  FlowPack
    { name = either (error . show) id (parseFlowPackName "builtin"),
      flows = builtinFlows,
      decisionPrograms = builtinDecisionPrograms,
      retainedCodecs = builtinRetainedCodecs,
      tasks = programRegistry
    }

-- | The builtin pack alone, composed. It cannot fail for a reviewed build, so
-- it errors at construction the way the decision registry always has; tests
-- and the stub environment use it where no distribution composes packs.
builtinFlowRegistry :: FlowRegistry
builtinFlowRegistry = either (error . show) id (composeFlowRegistry [builtinPack])

builtinFlows :: [PackFlow]
builtinFlows =
  [ kernelCapabilityFlow
      FlowDef
        { name = declarationCoordinate "run-declared-tool",
          decisionSlots = [],
          requiresDefaultModel = DefaultModelOptional,
          decisionMode = StrictDecisions,
          lifecycle = LifecycleDiagram "flowchart LR\n Admit --> Attempt --> Settle" []
        }
      runDeclaredToolFlow,
    kernelCapabilityFlow
      FlowDef {name = watchdogFlowName, decisionSlots = watchdogSlots, requiresDefaultModel = DefaultModelOptional, decisionMode = AdvisoryDecisions, lifecycle = LifecycleDiagram "flowchart LR\n Grant --> Observe --> Classify --> Record --> Drift --> Deliver --> Close" []}
      watchdogSweep,
    kernelCapabilityFlow
      FlowDef
        { name = proposeWorkFlowName,
          decisionSlots = proposeWorkSlots,
          requiresDefaultModel = DefaultModelOptional,
          decisionMode = StrictDecisions,
          lifecycle = LifecycleDiagram "flowchart LR\n Observe --> Prefilter --> Assess --> Propose --> Await --> Accept" []
        }
      proposeWork,
    kernelCapabilityFlow
      FlowDef
        { name = declarationCoordinate "adaptive-delivery",
          decisionSlots = adaptiveSlots,
          requiresDefaultModel = DefaultModelOptional,
          decisionMode = StrictDecisions,
          lifecycle = LifecycleDiagram "flowchart LR\n Checkpoint --> Decision --> Validate --> Commands --> Findings --> Checkpoint\n Validate --> ExactCompletionProposal" []
        }
      adaptiveDelivery,
    kernelCapabilityFlow
      FlowDef
        { name = declarationCoordinate "objective-example",
          decisionSlots = [],
          requiresDefaultModel = DefaultModelOptional,
          decisionMode = StrictDecisions,
          lifecycle = LifecycleDiagram "flowchart LR\n Create --> Plan --> Progress --> Inspect" []
        }
      objectiveExample,
    kernelCapabilityFlow
      FlowDef
        { name = declarationCoordinate "shikumi-decision-example",
          decisionSlots = exampleSlots,
          requiresDefaultModel = DefaultModelOptional,
          decisionMode = StrictDecisions,
          lifecycle = LifecycleDiagram "flowchart LR\n Request --> Triage --> Investigation --> Specialist" []
        }
      shikumiDecisionExample,
    kernelCapabilityFlow
      FlowDef
        { name = declarationCoordinate "shikumi-judgment-example",
          decisionSlots = judgmentSlots,
          requiresDefaultModel = DefaultModelOptional,
          decisionMode = StrictDecisions,
          lifecycle = LifecycleDiagram "flowchart LR\n Ticket --> Judgment --> Result" []
        }
      shikumiJudgmentExample,
    kernelCapabilityFlow
      FlowDef
        { name = declarationCoordinate "delegation-proof",
          decisionSlots = [],
          requiresDefaultModel = DefaultModelRequired,
          decisionMode = StrictDecisions,
          lifecycle =
            LifecycleDiagram
              { mermaid = "flowchart LR\n  Supervisor --> WebResearcher",
                validationWarnings = []
              }
        }
      delegationProofFlow,
    kernelCapabilityFlow
      FlowDef
        { name = declarationCoordinate "architecture-practice-router",
          decisionSlots = [],
          requiresDefaultModel = DefaultModelRequired,
          decisionMode = StrictDecisions,
          lifecycle =
            LifecycleDiagram
              { mermaid = "flowchart LR\n  Input --> Router --> Specialist",
                validationWarnings = []
              }
        }
      architecturePracticeRouterFlow,
    kernelCapabilityFlow
      FlowDef
        { name = declarationCoordinate opentelemetryPracticeReviewFlowName,
          decisionSlots = [],
          requiresDefaultModel = DefaultModelRequired,
          decisionMode = StrictDecisions,
          lifecycle =
            LifecycleDiagram
              { mermaid = opentelemetryPracticeReviewMermaid,
                validationWarnings = []
              }
        }
      opentelemetryPracticeReviewFlow
  ]

-- | Run one of the declaration's tools as a durable step (EP-3 M4). The
-- payload names it: @{"tool": "cabal", "args": ["build"], "deadlineMinutes": 30}@.
-- The command may run for hours and change the run's worktree; a replay
-- reads the journaled outcome, and a lost launcher ends uncertain.
runDeclaredToolFlow :: (FlowEffects es) => Value -> Eff es Value
runDeclaredToolFlow payload = case parseMaybe parseStep payload of
  Nothing -> pure (Aeson.object ["outcome" .= ("refused" :: Text), "reason" .= ("the payload must name a tool, its args and deadlineMinutes" :: Text)])
  Just requested -> do
    outcome <- DeclaredTool.runDeclaredTool (DeclaredTool.toolStepKey "step") requested
    pure (Aeson.object ["outcome" .= DeclaredToolWorkflow.toolStepOutcomeLabel outcome, "summary" .= DeclaredToolWorkflow.renderToolStepOutcome outcome, "result" .= outcome])
  where
    parseStep = Aeson.withObject "declared-tool step" \fields -> do
      toolText <- fields .: "tool"
      arguments <- fields .:? "args" .!= []
      minutes <- fields .:? "deadlineMinutes" .!= 30
      tool <- either (fail . Text.unpack) pure (mkToolName toolText)
      either (fail . Text.unpack) pure (DeclaredToolWorkflow.mkToolStep tool arguments minutes)

-- | Minimal registered proof that Flow can reach the same governed child-run
-- machinery as an imperative supervisor. The target and call-site key are
-- static durable vocabulary; the triggering payload remains the child's input.
delegationProofFlow :: (FlowEffects es) => Value -> Eff es Value
delegationProofFlow payload = do
  child <- Delegate.delegate (declarationCoordinate "web-researcher") (agentNameFromNonEmpty ('w' :| "eb-researcher")) payload
  Delegate.awaitOne child

-- | First registered routing call site.  A matched decision reserves every
-- selection before any child is spawned, then awaits successful results in
-- selection order.  Semantic no-match and ambiguous outcomes spawn nothing;
-- operational and child failures escape the flow.
architecturePracticeRouterFlow :: (FlowEffects es) => Value -> Eff es Value
architecturePracticeRouterFlow payload = do
  Routing.RoutedRoute {catalog, decision = decision@RouteDecision {outcome}} <-
    Routing.routeWithCatalog (Routing.routeSite "architecture-practice") payload
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
        { key = declarationCoordinate ("architecture-practice-" <> agentNameText agent),
          target = agent,
          payload
        }

    semanticResult decision =
      Aeson.object
        [ "decision" .= decision,
          "results" .= ([] :: [Value])
        ]
