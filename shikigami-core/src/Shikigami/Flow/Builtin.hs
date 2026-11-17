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
import Shikigami.Flow.Pack
import Shikigami.Flow.Routing qualified as Routing
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
      tasks = programRegistry,
      settings = [],
      triggers = noTriggerHooks,
      adminVerbs = [],
      gauges = [],
      authorities = [],
      outputs = [],
      approvalChannels = [],
      trackerProviders = []
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
      FlowDef
        { name = declarationCoordinate "adaptive-delivery",
          decisionSlots = adaptiveSlots,
          requiresDefaultModel = DefaultModelOptional,
          decisionMode = StrictDecisions,
          lifecycle = LifecycleDiagram "flowchart LR\n Checkpoint --> Decision --> Validate --> Commands --> Findings --> Checkpoint\n Validate --> ExactCompletionProposal" []
        }
      adaptiveDelivery
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
