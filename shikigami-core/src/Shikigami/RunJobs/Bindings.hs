{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}

-- Total consumer bindings; the generated closed enum codecs own wire admission.
module Shikigami.RunJobs.Bindings
  ( triggerKindCases,
    triggerKindBinding,
    routeKindCases,
    routeKindBinding,
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))
import Shikigami.Agent.RunJob (RunRouteKind, TriggerKind)
import Shikigami.Agent.RunJob qualified as RunJob
import Shikigami.Generated.Structural.Shape.RunRouteKind qualified as ShapeRunRouteKind
import Shikigami.Generated.Structural.Shape.RunTriggerKind qualified as RunTriggerKind

triggerKindCases :: FixtureCases TriggerKind
triggerKindCases = FixtureCases (("schedule", RunJob.TriggeredBySchedule) :| [("stream", RunJob.TriggeredByStream), ("event", RunJob.TriggeredByEvent), ("delegation", RunJob.TriggeredByDelegation)])

triggerKindBinding :: StructuralBinding TriggerKind RunTriggerKind.RunTriggerKindShape
triggerKindBinding =
  StructuralBinding
    { bindingToShape = \case
        RunJob.TriggeredBySchedule -> RunTriggerKind.TriggeredBySchedule
        RunJob.TriggeredByStream -> RunTriggerKind.TriggeredByStream
        RunJob.TriggeredByEvent -> RunTriggerKind.TriggeredByEvent
        RunJob.TriggeredByDelegation -> RunTriggerKind.TriggeredByDelegation,
      bindingFromShape = \case
        RunTriggerKind.TriggeredBySchedule -> RunJob.TriggeredBySchedule
        RunTriggerKind.TriggeredByStream -> RunJob.TriggeredByStream
        RunTriggerKind.TriggeredByEvent -> RunJob.TriggeredByEvent
        RunTriggerKind.TriggeredByDelegation -> RunJob.TriggeredByDelegation
    }

routeKindCases :: FixtureCases RunRouteKind
routeKindCases = FixtureCases (("agent", RunJob.AgentWorkflowRoute) :| [("conversation", RunJob.ConversationWorkflowRoute), ("execution", RunJob.ExecutionOperationRoute)])

routeKindBinding :: StructuralBinding RunRouteKind ShapeRunRouteKind.RunRouteKindShape
routeKindBinding =
  StructuralBinding
    { bindingToShape = \case
        RunJob.AgentWorkflowRoute -> ShapeRunRouteKind.AgentWorkflowRoute
        RunJob.ConversationWorkflowRoute -> ShapeRunRouteKind.ConversationWorkflowRoute
        RunJob.ExecutionOperationRoute -> ShapeRunRouteKind.ExecutionOperationRoute,
      bindingFromShape = \case
        ShapeRunRouteKind.AgentWorkflowRoute -> RunJob.AgentWorkflowRoute
        ShapeRunRouteKind.ConversationWorkflowRoute -> RunJob.ConversationWorkflowRoute
        ShapeRunRouteKind.ExecutionOperationRoute -> RunJob.ExecutionOperationRoute
    }
