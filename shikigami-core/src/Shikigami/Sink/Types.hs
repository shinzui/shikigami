{-# LANGUAGE DataKinds #-}

-- | The value types of the kernel's output outbox (plan 135, M3).
--
-- An output an adapter delivers asynchronously is journaled with its run as
-- a sink intent, enqueued on Keiro's outbox and later dispatched by the
-- publisher. The kernel owns that mechanism; the adapter owns the service.
-- 'OutboxRoute' is what an adapter supplies: how to address an output when
-- it is enqueued (the trigger activity is in scope only then), the exact
-- target the authority decides, and the dispatch the publisher calls.
module Shikigami.Sink.Types
  ( OutboxRoute (..),
    AddressInput (..),
    OutboxDelivery (..),
    DeliveryGuard (..),
    SinkOutcome (..),
    SinkResult (..),
    mkSourceEventId,
    deliverySubjectText,
  )
where

import Data.Aeson (Value)
import Data.List.NonEmpty (NonEmpty)
import Data.Text qualified as Text
import Kioku.Id (SessionId, idText)
import Network.HTTP.Types.Header (Header)
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.Authority (OutputKind)
import Shikigami.Log (Logger)
import Shikigami.Prelude
import Shikigami.Sink.Coordinate (SinkOrdinal, sinkOrdinalInt)

-- | What an adapter may read when an output is enqueued.
data AddressInput = AddressInput
  { -- | The output's configuration, already accepted by the adapter.
    config :: !Value,
    -- | The activity that triggered the run, when it has one.
    activity :: !(Maybe ActivityEnvelope),
    -- | The behavior's result.
    result :: !Value
  }

-- | How an adapter delivers through the outbox.
data OutboxRoute = OutboxRoute
  { -- | The adapter-owned address journaled with the intent: everything the
    -- dispatch needs that only the enqueuing run can know.
    address :: !(AddressInput -> Value),
    -- | The exact 'Shikigami.Authority.EmitOutput' target for a
    -- configuration and its address. A 'Left' refuses the output as
    -- unauthorizable before anything is sent.
    target :: !(Value -> Value -> Either Text (NonEmpty Text)),
    -- | Deliver one intent. Called by the publisher after the lifecycle,
    -- grant and authority checks, and possibly again after a retry.
    dispatch :: !(OutboxDelivery -> IO SinkOutcome)
  }

-- | Receipt operations an adapter may need while performing a multi-step
-- downstream effect. The publisher closes these functions over its database
-- pool and outbox message id; direct dispatch tests use 'Nothing'.
data DeliveryGuard = DeliveryGuard
  { lookupReceipt :: !(DeclarationCoordinate "receipt-step" -> IO (Maybe (DeclarationCoordinate "danwa-conversation"))),
    recordReceipt :: !(DeclarationCoordinate "receipt-step" -> DeclarationCoordinate "danwa-conversation" -> IO ())
  }

-- | Everything one outbox dispatch is given.
data OutboxDelivery = OutboxDelivery
  { identity :: !AgentIdentity,
    agent :: !AgentName,
    runId :: !SessionId,
    ordinal :: !SinkOrdinal,
    occurredAt :: !(Maybe UTCTime),
    kind :: !OutputKind,
    config :: !Value,
    address :: !Value,
    result :: !Value,
    -- | Allowlisted W3C propagation headers for this one dispatch.
    -- Authentication stays with the adapter's own HTTP environment.
    traceHeaders :: ![Header],
    -- | Durable intermediate effects within this delivery, when publication
    -- runs under the receipt-aware outbox transport.
    receipts :: !(Maybe DeliveryGuard),
    logger :: !Logger
  }

-- | The outcome of one dispatch. @DeniedOutcome@ is distinct from the
-- permission gate's @Denied@ newtype.
data SinkOutcome
  = Delivered !(DeclarationCoordinate "downstream-effect") -- a detail string (e.g. the returned id)
  | -- | The sink intent was durably written to Keiro's outbox. This says only
    -- that asynchronous delivery may now happen; it is deliberately distinct
    -- from 'Delivered', which is reserved for a downstream acknowledgement.
    Enqueued !(DeclarationCoordinate "outbox-receipt")
  | -- | __Deprecated: never produced.__ Kept so that journaled results that
    -- carry it still decode; see @Shikigami.WireCompatSpec@.
    Stubbed
  | DeniedOutcome !Text -- permission denied; the reason (no send)
  | AuthorizationFailed !Text -- C13 unavailable, invalid, or proof-rejected (no send)
  | SkippedLifecycle !Text -- principal paused, deactivated, unknown, or unavailable (no send)
  | Failed !Text -- the send errored (the worker decides retry)
  | -- | The transport classified a failure as permanent. The publisher maps
    -- this to Keiro's terminal publication-rejection outcome; see
    -- @mori://shinzui/keiro/plans/165-add-terminal-outbox-publication-rejection-outcomes@.
    PermanentFailure !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data SinkResult = SinkResult
  { kind :: !OutputKind,
    outcome :: !SinkOutcome
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The deterministic doorway dedup key: @"<agent>:<runId>:<ordinal>"@. A
-- retry of the same run re-sends the same key, so the doorway dedups it.
mkSourceEventId :: OutboxDelivery -> Text
mkSourceEventId delivery =
  deliverySubjectText delivery <> ":" <> idText delivery.runId <> ":" <> Text.pack (show (sinkOrdinalInt delivery.ordinal))

-- | The identity a delivery acts as, as text.
deliverySubjectText :: OutboxDelivery -> Text
deliverySubjectText delivery = either (const "unresolved-legacy") id (identityText delivery.identity)
