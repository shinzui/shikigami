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
import GHC.Generics (Generic)
import Keiki.Builder qualified as B
import Keiki.Core
  ( HsPred,
    InCtor,
    RegFile (RNil),
    SymTransducer,
    TransducerValidationWarning,
    ValidationOptions (..),
    defaultValidationOptions,
    validateTransducer,
  )
import Keiki.Generics (mkInCtorVia)
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
  deriving stock (Eq, Generic, Show)

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

-- | The checks this transducer is held to.
--
-- Keiki 0.4 added @checkStateChangingEpsilon@, which rejects an output-free edge
-- that changes vertex: if you persist only emitted events, replaying the log
-- cannot reproduce the forward state. Every edge here is output-free — the
-- transducer's output type is @()@ — so the check fires on all four.
--
-- It is disabled, and the reason is that this transducer is not an event source.
-- It is a rendered specification of the at-risk-customer lifecycle: it produces
-- the Mermaid diagram and nothing else. The durable state for that lifecycle is
-- Keiro's workflow journal, written by "Shikigami.Flow.AtRiskCustomer", and this
-- transducer neither writes nor reads it. Keiki's warning — "never disable this
-- for a transducer whose events are persisted" — is about a case that does not
-- exist here.
--
-- Giving the lifecycle a real emitted-event type, so it could be validated under
-- the full default option set, is a modelling change that belongs with
-- @docs\/plans\/39-adopt-the-checked-keiro-dsl-for-durable-topology.md@, which
-- owns durable topology and identifiers. Every other replay-safety check stays
-- on.
diagramValidationOptions :: ValidationOptions
diagramValidationOptions =
  defaultValidationOptions {checkStateChangingEpsilon = False}

atRiskCustomerValidationWarnings :: [TransducerValidationWarning AtRiskCustomerState]
atRiskCustomerValidationWarnings =
  validateTransducer diagramValidationOptions atRiskCustomerLifecycle

-- Keiki 0.9 sealed @InCtor@ behind a read-only pattern synonym: manual record
-- construction no longer compiles. Of the two ways back in, @mkInCtorVia@ is
-- the one that preserves structural evidence, so @validateTransducer@ keeps
-- returning verified results instead of degrading to @UnverifiedOpaque@;
-- @unavailableInCtor@ would have compiled just as readily and silently cost us
-- that. It derives match and build from @AtRiskCustomerCommand@'s @Generic@
-- representation, which is why the deriving clause above grew @Generic@.

classifyLowRisk :: InCtor AtRiskCustomerCommand '[]
classifyLowRisk =
  mkInCtorVia @"ClassifyLowRisk"

classifyHighRisk :: InCtor AtRiskCustomerCommand '[]
classifyHighRisk =
  mkInCtorVia @"ClassifyHighRisk"

acknowledge :: InCtor AtRiskCustomerCommand '[]
acknowledge =
  mkInCtorVia @"Acknowledge"

deadlineExpired :: InCtor AtRiskCustomerCommand '[]
deadlineExpired =
  mkInCtorVia @"DeadlineExpired"
