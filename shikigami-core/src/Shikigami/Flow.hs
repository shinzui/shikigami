{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}

module Shikigami.Flow
  ( FlowDef (..),
    FlowEffects,
    FlowRuntime (..),
    LifecycleDiagram (..),
    atRiskCustomerLifecycleDiagram,
    flowDeclarationErrors,
    flowRegistry,
    lookupFlow,
    registeredFlowNames,
  )
where

import Data.Aeson (Value, (.=))
import Data.Aeson qualified as Aeson
import Data.List (find)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Effectful (Eff, (:>))
import Keiro.Workflow (Workflow)
import Shikigami.Agent.Approval (ApprovalEnv)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Delegate (DelegationRequest (..))
import Shikigami.Agent.Name (agentNameFromNonEmpty, agentNameText)
import Shikigami.Coordination.Capability (AdaptiveDelivery)
import Shikigami.Coordination.Decision (adaptiveSlots)
import Shikigami.Decision.Contract (DecisionSlot)
import Shikigami.Decision.ModelCatalog (slotErrors)
import Shikigami.Duration
import Shikigami.Flow.Acknowledgement (Acknowledgement)
import Shikigami.Flow.AdaptiveDelivery (adaptiveDelivery)
import Shikigami.Flow.AtRiskCustomer (atRiskCustomerFlow)
import Shikigami.Flow.Capability (Activity, Memory, Sink)
import Shikigami.Flow.Decision (Decision)
import Shikigami.Flow.Delegate (Delegate)
import Shikigami.Flow.Delegate qualified as Delegate
import Shikigami.Flow.Lifecycle.AtRiskCustomer (atRiskCustomerMermaid, atRiskCustomerValidationWarnings)
import Shikigami.Flow.ObjectiveExample (objectiveExample)
import Shikigami.Flow.Objectives (Objectives)
import Shikigami.Flow.OpenTelemetryPracticeReview
  ( opentelemetryPracticeReviewFlow,
    opentelemetryPracticeReviewFlowName,
    opentelemetryPracticeReviewMermaid,
  )
import Shikigami.Flow.Routing (Routing)
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Flow.ShikumiDecisionExample (exampleSlots, shikumiDecisionExample)
import Shikigami.Flow.ShikumiJudgmentExample (judgmentSlots, shikumiJudgmentExample)
import Shikigami.Flow.Workers (Workers)
import Shikigami.PracticeReview.Capability
  ( ExecutionContext,
    PracticeReviewAttention,
    PracticeReviewEvaluator,
    PracticeReviewEvidence,
  )
import Shikigami.PracticeReview.Memory (PracticeReviewMemory)
import Shikigami.Program.Decision qualified as Decision
import Shikigami.Program.Decision.Registry (decisionPrograms)
import Shikigami.Router.Decision (RouteDecision (..), RouteOutcome (..), RouteSelection (..))
import Shikigami.RuntimePolicy

-- | Everything a flow body may do, and therefore everything it may not.
--
-- The absence of 'Effectful.IOE' and 'Kiroku.Store.Effect.Store' is the point of
-- this alias, not an oversight. A durable workflow replays its body, answering
-- journaled steps from the journal and re-running everything else; an effect
-- with an external footprint that is not wrapped in a step therefore happens an
-- unpredictable number of times. While a flow body could @liftIO@, nothing
-- prevented that, and no reviewer could prove a flow had not done it.
--
-- So every way a flow reaches the world is a capability with a replay-safe
-- interpreter: 'Memory' journals its recalls and writes, 'Sink' journals its
-- emissions, 'Acknowledgement' parks through the approval machinery, and
-- 'Delegate' governs durable child runs, 'Routing' journals catalog/model
-- decisions before validation, and 'Activity' is pure data. 'Workflow' stays
-- so a flow can still name a pure checkpoint with 'Keiro.Workflow.step' —
-- without 'IOE' that step body cannot smuggle IO in.
--
-- Adding an effect here widens what every flow may do. Add a capability instead.
type FlowEffects es =
  ( Workflow :> es,
    Memory :> es,
    Sink :> es,
    Activity :> es,
    Acknowledgement :> es,
    Delegate :> es,
    Workers :> es,
    AdaptiveDelivery :> es,
    Objectives :> es,
    Routing :> es,
    Decision :> es,
    ExecutionContext :> es,
    PracticeReviewEvidence :> es,
    PracticeReviewEvaluator :> es,
    PracticeReviewMemory :> es,
    PracticeReviewAttention :> es
  )

-- | What 'Shikigami.Flow.Acknowledgement.runAcknowledgement' needs to interpret
-- a flow's parks.
--
-- This used to be threaded into the flow body itself, because
-- 'Shikigami.Flow.Acknowledgement.awaitAcknowledgement' was a direct call and
-- needed both values in scope where the flow made it. Now the interpreter holds
-- them, so a flow body closes over nothing and 'flowRegistry' is a plain list
-- rather than a function of deployment configuration.
data FlowRuntime = FlowRuntime
  { approval :: !ApprovalEnv,
    acknowledgementDeadline :: !(Duration "approval")
  }

data LifecycleDiagram = LifecycleDiagram
  { mermaid :: !Text,
    validationWarnings :: ![Text]
  }
  deriving stock (Eq, Show)

data FlowDef = FlowDef
  { name :: !(DeclarationCoordinate "flow"),
    lifecycle :: !LifecycleDiagram,
    decisionSlots :: ![DecisionSlot],
    requiresDefaultModel :: !DefaultModelRequirement,
    run :: !(forall es. (FlowEffects es) => Value -> Eff es Value)
  }

instance Show FlowDef where
  show FlowDef {name} = "FlowDef {name = " <> show name <> "}"

atRiskCustomerLifecycleDiagram :: LifecycleDiagram
atRiskCustomerLifecycleDiagram =
  LifecycleDiagram
    { mermaid = atRiskCustomerMermaid,
      validationWarnings = Text.pack . show <$> atRiskCustomerValidationWarnings
    }

-- | Every flow this build registers. Add a flow here and nowhere else.
--
-- This is __one__ list, and 'registeredFlowNames' is a projection of it rather
-- than a second list beside it. A flow that were runnable but missing from the
-- name list would be rejected at boot despite working; one that were listed but
-- not registered would pass validation and then fail mid-run — the exact failure
-- 'registeredFlowNames' exists to close.
--
-- It is a plain value now. It used to be a function of a 'FlowRuntime', because
-- a flow body closed over the approval environment and the acknowledgement
-- deadline; a caller that only wanted to know a flow's /name/ or /diagram/ still
-- had to mint an approval environment to ask. Acknowledgement is a capability
-- now, so the body closes over nothing and the question is answerable directly.
flowRegistry :: [FlowDef]
flowRegistry =
  [ FlowDef
      { name = declarationCoordinate "adaptive-delivery",
        decisionSlots = adaptiveSlots,
        requiresDefaultModel = DefaultModelOptional,
        lifecycle = LifecycleDiagram "flowchart LR\n Checkpoint --> Decision --> Validate --> Commands --> Findings --> Checkpoint\n Validate --> ExactCompletionProposal" [],
        run = adaptiveDelivery
      },
    FlowDef
      { name = declarationCoordinate "objective-example",
        decisionSlots = [],
        requiresDefaultModel = DefaultModelOptional,
        lifecycle = LifecycleDiagram "flowchart LR\n Create --> Plan --> Progress --> Inspect" [],
        run = objectiveExample
      },
    FlowDef
      { name = declarationCoordinate "shikumi-decision-example",
        decisionSlots = exampleSlots,
        requiresDefaultModel = DefaultModelOptional,
        lifecycle = LifecycleDiagram "flowchart LR\n Request --> Triage --> Investigation --> Specialist" [],
        run = shikumiDecisionExample
      },
    FlowDef
      { name = declarationCoordinate "shikumi-judgment-example",
        decisionSlots = judgmentSlots,
        requiresDefaultModel = DefaultModelOptional,
        lifecycle = LifecycleDiagram "flowchart LR\n Ticket --> Judgment --> Result" [],
        run = shikumiJudgmentExample
      },
    FlowDef
      { name = declarationCoordinate "at-risk-customer",
        decisionSlots = [],
        requiresDefaultModel = DefaultModelRequired,
        lifecycle = atRiskCustomerLifecycleDiagram,
        run = atRiskCustomerFlow
      },
    FlowDef
      { name = declarationCoordinate "delegation-proof",
        decisionSlots = [],
        requiresDefaultModel = DefaultModelRequired,
        lifecycle =
          LifecycleDiagram
            { mermaid = "flowchart LR\n  Supervisor --> WebResearcher",
              validationWarnings = []
            },
        run = delegationProofFlow
      },
    FlowDef
      { name = declarationCoordinate "architecture-practice-router",
        decisionSlots = [],
        requiresDefaultModel = DefaultModelRequired,
        lifecycle =
          LifecycleDiagram
            { mermaid = "flowchart LR\n  Input --> Router --> Specialist",
              validationWarnings = []
            },
        run = architecturePracticeRouterFlow
      },
    FlowDef
      { name = declarationCoordinate opentelemetryPracticeReviewFlowName,
        decisionSlots = [],
        requiresDefaultModel = DefaultModelRequired,
        lifecycle =
          LifecycleDiagram
            { mermaid = opentelemetryPracticeReviewMermaid,
              validationWarnings = []
            },
        run = opentelemetryPracticeReviewFlow
      }
  ]

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
    Routing.routeWithCatalog Routing.ArchitecturePractice payload
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

-- | The name of every registered flow.
--
-- This is what an agent manifest's @Behavior.Flow { name }@ must match. Before
-- it existed the only check happened inside a running workflow, so a typo in a
-- manifest became a failed agent run rather than a refused deployment.
registeredFlowNames :: [DeclarationCoordinate "flow"]
registeredFlowNames = [name | FlowDef {name} <- flowRegistry]

lookupFlow :: DeclarationCoordinate "flow" -> Maybe FlowDef
lookupFlow requested =
  find (\FlowDef {name} -> name == requested) flowRegistry

-- | Every declaration error in an agent's behavior that this build can decide
-- without running it, in declaration order. An empty list means the behavior is
-- deployable.
--
-- Today that is exactly one check: a @Behavior.Flow { name }@ naming a flow no
-- registration provides. It used to surface only from inside a running workflow
-- — @runFlowBehavior@ returns @Left \"unknown flow ...\"@ on a registry miss —
-- which means a typo in a manifest cost a failed agent run per trigger instead
-- of a refused deployment. Mirrors 'Shikigami.Sink.Validate.sinkDeclarationErrors'.
flowDeclarationErrors :: AgentDecl -> [Text]
flowDeclarationErrors declaration@AgentDecl {behavior} =
  case behavior of
    Flow {name = flowName}
      | flowName `notElem` registeredFlowNames ->
          [ "unknown flow "
              <> declarationCoordinateText flowName
              <> "; registered flows: "
              <> Text.intercalate ", " (map declarationCoordinateText registeredFlowNames)
          ]
    Flow {name = flowName} ->
      case lookupFlow flowName of
        Nothing -> []
        Just flow -> slotErrors decisionProgramRegistry declaration flow.decisionSlots
    _ -> []

-- The typed decision registry is finite and validated at construction. The
-- example integration adds its immutable registrations here.
decisionProgramRegistry :: Decision.ProgramRegistry
decisionProgramRegistry = decisionPrograms
