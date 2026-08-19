{-# LANGUAGE ConstraintKinds #-}
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

import Data.Aeson (Value)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, (:>))
import Keiro.Workflow (Workflow)
import Kiroku.Store.Effect (Store)
import Shikigami.Agent.Approval (ApprovalEnv)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Flow.AtRiskCustomer (atRiskCustomerFlow)
import Shikigami.Flow.Capability (Activity, Memory, Sink)
import Shikigami.Flow.Lifecycle.AtRiskCustomer (atRiskCustomerMermaid, atRiskCustomerValidationWarnings)

type FlowEffects es = (Workflow :> es, Store :> es, IOE :> es, Memory :> es, Sink :> es, Activity :> es)

data FlowRuntime = FlowRuntime
  { approval :: !ApprovalEnv,
    acknowledgementDeadline :: !NominalDiffTime
  }

data LifecycleDiagram = LifecycleDiagram
  { mermaid :: !Text,
    validationWarnings :: ![Text]
  }
  deriving stock (Eq, Show)

data FlowDef = FlowDef
  { name :: !Text,
    lifecycle :: !LifecycleDiagram,
    run :: forall es. (FlowEffects es) => Value -> Eff es Value
  }

instance Show FlowDef where
  show FlowDef {name} = "FlowDef {name = " <> show name <> "}"

atRiskCustomerLifecycleDiagram :: LifecycleDiagram
atRiskCustomerLifecycleDiagram =
  LifecycleDiagram
    { mermaid = atRiskCustomerMermaid,
      validationWarnings = Text.pack . show <$> atRiskCustomerValidationWarnings
    }

-- | One flow this build knows how to run.
--
-- Only 'build' needs a 'FlowRuntime' (a flow's body closes over the approval
-- environment and the acknowledgement deadline); a flow's name and lifecycle
-- diagram do not. Splitting them is what lets 'registeredFlowNames' answer
-- \"which flows exist\" without constructing an approval environment, which is
-- what the @validate@ command and worker boot need.
--
-- Deliberately not exported: it exists so 'flowRegistry' and
-- 'registeredFlowNames' are two projections of __one__ list rather than two
-- lists that can disagree. A flow that were runnable but missing from the name
-- list would be rejected at boot despite working; one that were listed but not
-- registered would pass validation and then fail mid-run — the exact failure
-- 'registeredFlowNames' exists to close.
data FlowRegistration = FlowRegistration
  { name :: !Text,
    lifecycle :: !LifecycleDiagram,
    build :: FlowRuntime -> (forall es. (FlowEffects es) => Value -> Eff es Value)
  }

-- | Every flow this build registers. Add a flow here and nowhere else.
flowRegistrations :: [FlowRegistration]
flowRegistrations =
  [ FlowRegistration
      { name = "at-risk-customer",
        lifecycle = atRiskCustomerLifecycleDiagram,
        build = \runtime -> atRiskCustomerFlow (approval runtime) (acknowledgementDeadline runtime)
      }
  ]

flowRegistry :: FlowRuntime -> [FlowDef]
flowRegistry runtime =
  [ FlowDef {name, lifecycle, run = build runtime}
  | FlowRegistration {name, lifecycle, build} <- flowRegistrations
  ]

-- | The name of every registered flow, resolvable without a 'FlowRuntime'.
--
-- This is what an agent manifest's @Behavior.Flow { name }@ must match. Before
-- it existed the only check happened inside a running workflow, so a typo in a
-- manifest became a failed agent run rather than a refused deployment.
registeredFlowNames :: [Text]
registeredFlowNames = [name | FlowRegistration {name} <- flowRegistrations]

lookupFlow :: FlowRuntime -> Text -> Maybe FlowDef
lookupFlow runtime requested =
  find (\FlowDef {name} -> name == requested) (flowRegistry runtime)

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
flowDeclarationErrors AgentDecl {behavior} =
  case behavior of
    Flow {name = flowName}
      | flowName `notElem` registeredFlowNames ->
          [ "unknown flow "
              <> flowName
              <> "; registered flows: "
              <> Text.intercalate ", " registeredFlowNames
          ]
    _ -> []
