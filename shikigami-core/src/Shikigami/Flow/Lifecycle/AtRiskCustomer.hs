{-# LANGUAGE DataKinds #-}
{-# LANGUAGE QualifiedDo #-}

module Shikigami.Flow.Lifecycle.AtRiskCustomer
  ( AtRiskCustomerCommand (..),
    AtRiskCustomerLifecycle,
    AtRiskCustomerState (..),
    atRiskCustomerLifecycle,
    atRiskCustomerMermaid,
    atRiskCustomerValidationWarnings,
  )
where

import Data.Text (Text)
import Keiki.Builder qualified as B
import Keiki.Core
  ( HsPred,
    InCtor (..),
    RegFile (RNil),
    SymTransducer,
    TransducerValidationWarning,
    defaultValidationOptions,
    validateTransducer,
  )
import Keiki.Render.Mermaid (defaultMermaidOptions, toMermaidWith)
import Prelude

data AtRiskCustomerState
  = Observed
  | SettledLow
  | AwaitingAck
  | Acknowledged
  | Escalated
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data AtRiskCustomerCommand
  = ClassifyLowRisk
  | ClassifyHighRisk
  | Acknowledge
  | DeadlineExpired
  deriving stock (Eq, Show)

type AtRiskCustomerLifecycle =
  SymTransducer
    (HsPred '[] AtRiskCustomerCommand)
    '[]
    AtRiskCustomerState
    AtRiskCustomerCommand
    ()

atRiskCustomerLifecycle :: AtRiskCustomerLifecycle
atRiskCustomerLifecycle =
  B.buildTransducer Observed RNil isTerminal Prelude.do
    B.from Observed Prelude.do
      B.onCmd classifyLowRisk \_ -> B.do
        B.noEmit
        B.goto SettledLow
      B.onCmd classifyHighRisk \_ -> B.do
        B.noEmit
        B.goto AwaitingAck
    B.from AwaitingAck Prelude.do
      B.onCmd acknowledge \_ -> B.do
        B.noEmit
        B.goto Acknowledged
      B.onCmd deadlineExpired \_ -> B.do
        B.noEmit
        B.goto Escalated
    B.from SettledLow (Prelude.pure ())
    B.from Acknowledged (Prelude.pure ())
    B.from Escalated (Prelude.pure ())
  where
    isTerminal = \case
      SettledLow -> True
      Acknowledged -> True
      Escalated -> True
      Observed -> False
      AwaitingAck -> False

atRiskCustomerMermaid :: Text
atRiskCustomerMermaid =
  toMermaidWith defaultMermaidOptions atRiskCustomerLifecycle

atRiskCustomerValidationWarnings :: [TransducerValidationWarning AtRiskCustomerState]
atRiskCustomerValidationWarnings =
  validateTransducer defaultValidationOptions atRiskCustomerLifecycle

classifyLowRisk :: InCtor AtRiskCustomerCommand '[]
classifyLowRisk =
  nullary "ClassifyLowRisk" ClassifyLowRisk

classifyHighRisk :: InCtor AtRiskCustomerCommand '[]
classifyHighRisk =
  nullary "ClassifyHighRisk" ClassifyHighRisk

acknowledge :: InCtor AtRiskCustomerCommand '[]
acknowledge =
  nullary "Acknowledge" Acknowledge

deadlineExpired :: InCtor AtRiskCustomerCommand '[]
deadlineExpired =
  nullary "DeadlineExpired" DeadlineExpired

nullary :: String -> AtRiskCustomerCommand -> InCtor AtRiskCustomerCommand '[]
nullary name command =
  InCtor
    { icName = name,
      icMatch = \candidate -> if candidate == command then Just RNil else Nothing,
      icBuild = \RNil -> command
    }
