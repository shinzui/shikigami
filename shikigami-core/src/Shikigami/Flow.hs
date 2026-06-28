{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RankNTypes #-}

module Shikigami.Flow
  ( FlowDef (..),
    FlowEffects,
    FlowRuntime (..),
    LifecycleDiagram (..),
    atRiskCustomerLifecycleDiagram,
    flowRegistry,
    lookupFlow,
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

flowRegistry :: FlowRuntime -> [FlowDef]
flowRegistry runtime =
  [ FlowDef
      { name = "at-risk-customer",
        lifecycle = atRiskCustomerLifecycleDiagram,
        run = atRiskCustomerFlow (approval runtime) (acknowledgementDeadline runtime)
      }
  ]

lookupFlow :: FlowRuntime -> Text -> Maybe FlowDef
lookupFlow runtime requested =
  find ((== requested) . name) (flowRegistry runtime)
