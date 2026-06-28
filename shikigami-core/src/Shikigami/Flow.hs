{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RankNTypes #-}

module Shikigami.Flow
  ( FlowDef (..),
    FlowEffects,
    LifecycleDiagram (..),
    atRiskCustomerLifecycleDiagram,
    flowRegistry,
    lookupFlow,
  )
where

import Data.Aeson (Value)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Keiro.Workflow (Workflow)
import Kiroku.Store.Effect (Store)
import Shikigami.Flow.Lifecycle.AtRiskCustomer (atRiskCustomerMermaid, atRiskCustomerValidationWarnings)

type FlowEffects es = (Workflow :> es, Store :> es, IOE :> es)

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

flowRegistry :: [FlowDef]
flowRegistry = []

lookupFlow :: Text -> Maybe FlowDef
lookupFlow requested =
  findByName flowRegistry
  where
    findByName = \case
      [] -> Nothing
      flow@FlowDef {name = candidate} : rest
        | candidate == requested -> Just flow
        | otherwise -> findByName rest
