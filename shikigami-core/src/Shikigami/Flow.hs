{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}

module Shikigami.Flow
  ( FlowDef (..),
    DecisionMode (..),
    FlowEffects,
    FlowRuntime (..),
    LifecycleDiagram (..),
    flowDecisionSlotsFor,
  )
where

import Data.Text (Text)
import Effectful ((:>))
import Keiro.Workflow (Workflow)
import Shikigami.Agent.Approval (ApprovalEnv)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Coordination.Capability (AdaptiveDelivery)
import Shikigami.Decision.Contract (DecisionSlot (..))
import Shikigami.Duration
import Shikigami.Flow.Acknowledgement (Acknowledgement)
import Shikigami.Flow.Capability (Activity, Memory, Sink)
import Shikigami.Flow.CodingAgent (CodingAgent)
import Shikigami.Flow.Decision (Decision)
import Shikigami.Flow.DeclaredTool (DeclaredTool)
import Shikigami.Flow.Delegate (Delegate)
import Shikigami.Flow.Objectives (Objectives)
import Shikigami.Flow.Observe (Observe)
import Shikigami.Flow.Routing (Routing)
import Shikigami.Flow.Workers (Workers)
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
    CodingAgent :> es,
    DeclaredTool :> es,
    Workers :> es,
    AdaptiveDelivery :> es,
    Objectives :> es,
    Observe :> es,
    Routing :> es,
    Decision :> es
  )

-- | What 'Shikigami.Flow.Acknowledgement.runAcknowledgement' needs to interpret
-- a flow's parks.
--
-- This used to be threaded into the flow body itself, because
-- 'Shikigami.Flow.Acknowledgement.awaitAcknowledgement' was a direct call and
-- needed both values in scope where the flow made it. Now the interpreter holds
-- them, so a flow body closes over nothing and a pack's flow list is a plain value
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

-- | How a flow's decisions bind it.
--
-- A strict flow needs every slot it declares: a declaration that cannot fill
-- one is refused, and a failed decision fails the run. An advisory flow
-- treats a decision as an optional opinion: a slot none of whose models the
-- declaration lists is left out of the run's inventory, and a decision that
-- cannot be made is reported to the body instead of failing the run. This is
-- declaration data so that the kernel never has to know a flow by name.
data DecisionMode = StrictDecisions | AdvisoryDecisions
  deriving stock (Eq, Show)

-- | A flow's declaration data. The body and its interpreter live beside it in
-- 'Shikigami.Flow.Pack.PackFlow'; a caller that only wants a flow's name,
-- diagram or decision slots needs nothing that can run it.
data FlowDef = FlowDef
  { name :: !(DeclarationCoordinate "flow"),
    lifecycle :: !LifecycleDiagram,
    decisionSlots :: ![DecisionSlot],
    requiresDefaultModel :: !DefaultModelRequirement,
    decisionMode :: !DecisionMode
  }

instance Show FlowDef where
  show FlowDef {name} = "FlowDef {name = " <> show name <> "}"

-- | The decision slots one declaration's run of a flow is held to.
flowDecisionSlotsFor :: AgentDecl -> FlowDef -> [DecisionSlot]
flowDecisionSlotsFor declaration flow = case flow.decisionMode of
  StrictDecisions -> flow.decisionSlots
  AdvisoryDecisions -> [slot | slot <- flow.decisionSlots, any (`elem` declaration.decisionModels) slot.models]
