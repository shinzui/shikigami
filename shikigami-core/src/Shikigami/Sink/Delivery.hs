{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultilineStrings #-}

-- | Durable truth about asynchronous sink publication.
--
-- The workflow journal stops at 'Shikigami.Sink.Types.Enqueued'. This table is
-- where the publisher records what happened after that point, including the
-- downstream identifier returned by a successful transport. The main receipt
-- also acts as the send guard: only a row whose status is 'Delivered' proves
-- that a retry must not call the downstream service again.
module Shikigami.Sink.Delivery
  ( DeliveryStatus (..),
    DeliveryReceipt (..),
    DeliveryDetail (..),
    deliveryDetailFor,
    deliveryDetailText,
    ReceiptContext (..),
    lookupDeliveryFor,
    lookupDeliveryForTx,
    ReceiptKey,
    receiptKeyText,
    SinkMessageId,
    sinkMessageId,
    sinkMessageIdText,
    deliveryReceiptKey,
    subReceiptKey,
    lookupDelivery,
    lookupDeliveryTx,
    recordDelivery,
    recordDeliveryTx,
    renderDeliveryStatus,
  )
where

import Data.Aeson (withText)
import Data.Bifunctor (first)
import Data.Functor.Contravariant ((>$<))
import Data.Text qualified as Text
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as Transactions
import Kioku.Id (SessionId, idText)
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name (AgentName, agentNameText, mkAgentName)
import Shikigami.Prelude
import Shikigami.Sink.Coordinate (SinkOrdinal, parseSinkOrdinal, parseSinkSession, sinkOrdinalInt)
import Shikigami.Sink.Permission (SinkKind, parseSinkKind, sinkKindText)

-- | The observable lifecycle of one downstream delivery.
data DeliveryStatus
  = Pending
  | Attempting
  | Delivered
  | Failed
  | Dead
  | Unknown
  | ConversationStarted
  deriving stock (Eq, Show, Generic)

-- | A receipt locator preserves the existing parent or substep namespace. It
-- is a technical lookup coordinate, not a newly allocated entity identity.
newtype ReceiptKey = ReceiptKey Text
  deriving stock (Eq, Ord, Show)

receiptKeyText :: ReceiptKey -> Text
receiptKeyText (ReceiptKey value) = value

-- | Exact message id supplied by Keiro's integration-event boundary. Keiro
-- owns its grammar; workflow producers may use their existing stable recipes.
newtype SinkMessageId = SinkMessageId Text
  deriving stock (Eq, Ord, Show)

sinkMessageId :: Text -> SinkMessageId
sinkMessageId = SinkMessageId

sinkMessageIdText :: SinkMessageId -> Text
sinkMessageIdText (SinkMessageId value) = value

-- | One queryable publisher receipt.
--
-- @detail@ is the downstream id for successful deliveries and a bounded
-- diagnostic for failures. A Danwa fresh-conversation sub-receipt stores its
-- conversation id there with status 'ConversationStarted'.
data DeliveryDetail
  = DownstreamReference !(DeclarationCoordinate "downstream-effect")
  | DeliveryDiagnostic !Text
  deriving stock (Eq, Show)

deliveryDetailFor :: DeliveryStatus -> Text -> DeliveryDetail
deliveryDetailFor status raw = case status of
  Delivered -> DownstreamReference (declarationCoordinate raw)
  ConversationStarted -> DownstreamReference (declarationCoordinate raw)
  _ -> DeliveryDiagnostic raw

deliveryDetailText :: DeliveryDetail -> Text
deliveryDetailText (DownstreamReference value) = declarationCoordinateText value
deliveryDetailText (DeliveryDiagnostic value) = value

instance ToJSON DeliveryDetail where
  toJSON = toJSON . deliveryDetailText
  toEncoding = toEncoding . deliveryDetailText

data DeliveryReceipt = DeliveryReceipt
  { receiptKey :: !ReceiptKey,
    outboxMessageId :: !SinkMessageId,
    runId :: !SessionId,
    agent :: !AgentName,
    ordinal :: !SinkOrdinal,
    sinkKind :: !SinkKind,
    status :: !DeliveryStatus,
    detail :: !(Maybe DeliveryDetail),
    updatedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

-- | Coordinates supplied by the owning queued intent. A well-formed foreign
-- receipt cannot prove publication of that intent.
data ReceiptContext = ReceiptContext
  { outboxMessageId :: !SinkMessageId,
    runId :: !SessionId,
    agent :: !AgentName,
    ordinal :: !SinkOrdinal,
    sinkKind :: !SinkKind
  }
  deriving stock (Eq, Show)

lookupDeliveryFor :: Pool -> ReceiptContext -> ReceiptKey -> IO (Either Text (Maybe DeliveryReceipt))
lookupDeliveryFor pool expected key = do
  result <- Pool.use pool (Transactions.transaction Transactions.ReadCommitted Transactions.Write (lookupDeliveryForTx expected key))
  pure (renderUsage result >>= id)

lookupDeliveryForTx :: ReceiptContext -> ReceiptKey -> Tx.Transaction (Either Text (Maybe DeliveryReceipt))
lookupDeliveryForTx expected key = do
  retained <- lookupDeliveryTx key
  case retained of
    Right (Just receipt) | contextFor receipt /= expected -> Tx.condemn >> pure (Left "inconsistent retained sink delivery receipt")
    _ -> pure retained

contextFor :: DeliveryReceipt -> ReceiptContext
contextFor DeliveryReceipt {outboxMessageId, runId, agent, ordinal, sinkKind} = ReceiptContext {outboxMessageId, runId, agent, ordinal, sinkKind}

-- | The receipt that governs whether the whole sink intent may be sent.
deliveryReceiptKey :: Text -> ReceiptKey
deliveryReceiptKey = ReceiptKey

-- | A stable namespace for an intermediate effect within one sink intent.
subReceiptKey :: Text -> Text -> ReceiptKey
subReceiptKey messageId kind = ReceiptKey (messageId <> "#" <> kind)

-- | Read one receipt by its durable key.
lookupDelivery :: Pool -> ReceiptKey -> IO (Either Text (Maybe DeliveryReceipt))
lookupDelivery pool key = do
  result <- Pool.use pool (Transactions.transaction Transactions.ReadCommitted Transactions.Write (lookupDeliveryTx key))
  pure (renderUsage result >>= id)

-- | Unreadable delivery truth cannot authorize another downstream send, even
-- when a caller ignores the refusal after an earlier tentative write.
lookupDeliveryTx :: ReceiptKey -> Tx.Transaction (Either Text (Maybe DeliveryReceipt))
lookupDeliveryTx key = do
  retained <- Tx.statement key lookupStatement
  case sequence retained of
    Left _ -> Tx.condemn >> pure (Left "corrupt retained sink delivery receipt")
    Right receipt -> pure (Right receipt)

-- | Upsert one receipt using a pool-managed session.
recordDelivery :: Pool -> DeliveryReceipt -> IO (Either Text ())
recordDelivery pool receipt =
  renderUsage <$> Pool.use pool (Session.statement receipt recordStatement)

-- | Upsert one receipt inside the caller's transaction. Enqueue paths use this
-- beside the journal append and Keiro outbox insert so @pending@ cannot drift
-- from the intent it describes.
recordDeliveryTx :: DeliveryReceipt -> Tx.Transaction ()
recordDeliveryTx receipt = Tx.statement receipt recordStatement

lookupStatement :: Statement ReceiptKey (Maybe (Either Text DeliveryReceipt))
lookupStatement =
  preparable
    """
    SELECT receipt_key, outbox_message_id, run_id, agent, ordinal,
           sink_kind, status, detail, updated_at
      FROM shikigami.sink_deliveries
     WHERE receipt_key = $1
    """
    (receiptKeyText >$< Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowMaybe deliveryReceiptRow)

recordStatement :: Statement DeliveryReceipt ()
recordStatement =
  preparable
    """
    INSERT INTO shikigami.sink_deliveries
      (receipt_key, outbox_message_id, run_id, agent, ordinal,
       sink_kind, status, detail, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
    ON CONFLICT (receipt_key) DO UPDATE
      SET outbox_message_id = EXCLUDED.outbox_message_id,
          run_id = EXCLUDED.run_id,
          agent = EXCLUDED.agent,
          ordinal = EXCLUDED.ordinal,
          sink_kind = EXCLUDED.sink_kind,
          status = EXCLUDED.status,
          detail = EXCLUDED.detail,
          updated_at = EXCLUDED.updated_at
    """
    ( (receiptKeyText . (.receiptKey) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (sinkMessageIdText . (.outboxMessageId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (idText . (.runId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (agentNameText . (.agent) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (fromIntegral . sinkOrdinalInt . (.ordinal) >$< Encoders.param (Encoders.nonNullable Encoders.int4))
        <> (sinkKindText . (.sinkKind) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (renderDeliveryStatus . (.status) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((fmap deliveryDetailText . (.detail)) >$< Encoders.param (Encoders.nullable Encoders.text))
        <> ((.updatedAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz))
    )
    Decoders.noResult

deliveryReceiptRow :: Decoders.Row (Either Text DeliveryReceipt)
deliveryReceiptRow =
  assemble
    <$> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> (fromIntegral <$> Decoders.column (Decoders.nonNullable Decoders.int4))
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.timestamptz)
  where
    assemble key message run agent ordinal kind status detail updated =
      do
        parsedStatus <- parseDeliveryStatus status
        when (parsedStatus == ConversationStarted && isNothing detail) (Left "missing retained conversation locator")
        parsedKind <- maybe (Left ("unknown sink kind: " <> kind)) Right (parseSinkKind kind)
        parsedRun <- parseSinkSession run
        parsedAgent <- mkAgentName agent
        parsedOrdinal <- parseSinkOrdinal ordinal
        pure (DeliveryReceipt (ReceiptKey key) (SinkMessageId message) parsedRun parsedAgent parsedOrdinal parsedKind parsedStatus (deliveryDetailFor parsedStatus <$> detail) updated)

renderDeliveryStatus :: DeliveryStatus -> Text
renderDeliveryStatus = \case
  Pending -> "pending"
  Attempting -> "attempting"
  Delivered -> "delivered"
  Failed -> "failed"
  Dead -> "dead"
  Unknown -> "unknown"
  ConversationStarted -> "conversation-started"

parseDeliveryStatus :: Text -> Either Text DeliveryStatus
parseDeliveryStatus = \case
  "pending" -> Right Pending
  "attempting" -> Right Attempting
  "delivered" -> Right Delivered
  "failed" -> Right Failed
  "dead" -> Right Dead
  "unknown" -> Right Unknown
  "conversation-started" -> Right ConversationStarted
  other -> Left ("unknown sink delivery status: " <> other)

renderUsage :: Either Pool.UsageError a -> Either Text a
renderUsage = first (Text.pack . show)

instance ToJSON SinkMessageId where
  toJSON = toJSON . sinkMessageIdText
  toEncoding = toEncoding . sinkMessageIdText

instance FromJSON SinkMessageId where
  parseJSON = withText "sink integration message id" (pure . sinkMessageId)
