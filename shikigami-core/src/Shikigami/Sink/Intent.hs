-- | The single durable contract between sink producers and the asynchronous
-- publisher. Agent runs, conversations, and flows all prepare and enqueue this
-- record through this module; the publisher decodes the same type here.
module Shikigami.Sink.Intent
  ( SinkIntent (..),
    PreparedSinkIntent,
    enqueueSinkIntents,
    enqueueSinkIntentStep,
    enqueuePreparedSinkIntentTx,
    prepareSinkIntent,
    prepareSinkIntentForRecipient,
    prepareSinkIntentForRecipientWithMessageId,
    preparedSinkResult,
    decodeSinkIntentEvent,
    sinkIntentEvent,
    deliveryReceiptFor,
    deliveryReceiptForKey,
    sinkMessageId,
    deterministicOutboxId,
    deterministicOutboxIdForMessage,
  )
where

import Data.Aeson (Value, withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.Foldable (traverse_)
import Data.Text qualified as Text
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, (:>))
import Hasql.Transaction qualified as Tx
import Keiro.Integration.Event
  ( IntegrationContentType (ApplicationJson),
    IntegrationEvent (..),
    IntegrationEventError,
    TraceContext,
    decodeJsonIntegrationEvent,
    encodeJsonIntegrationEvent,
  )
import Keiro.Outbox (OutboxId (..), OutboxMessage (..), enqueueOutboxTx)
import Keiro.Telemetry (traceContextFromCurrentSpan)
import Keiro.Workflow
  ( JournalAppendOutcome (..),
    StepName (..),
    Workflow,
    WorkflowId (..),
    WorkflowJournalEvent (StepRecorded),
    currentRunGeneration,
    currentWorkflow,
    prepareJournalAppend,
  )
import Kioku.Id (SessionId, idText)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Activity qualified as Activity
import Shikigami.Agent.Decl (Sink (..))
import Shikigami.Agent.Principal (AgentIdentity (..), mkAgentPrincipal)
import Shikigami.Directory (DirectoryHandle)
import Shikigami.Directory qualified as Directory
import Shikigami.Id.Name (nameBytes)
import Shikigami.Prelude
import Shikigami.Sink
  ( DanwaTarget,
    GrantSource,
    SinkOutcome (..),
    SinkResult (..),
    checkGrant,
    sinkKindOf,
  )
import Shikigami.Sink.Delivery qualified as Delivery
import Shikigami.Sink.KanmonClient (resolveConversationKey)
import Shikigami.Sink.Permission
  ( Denied (..),
    SinkKind,
    sinkKindText,
  )
import Shikigami.Sink.Recipient (resolveSinkRecipient)

-- | Everything the publisher needs to dispatch one sink after the producing
-- workflow has committed. Optional fields are omitted so rows written before
-- an additive field existed keep their original bytes.
data SinkIntent = SinkIntent
  { agent :: !Text,
    identity :: !AgentIdentity,
    runId :: !Text,
    ordinal :: !Int,
    occurredAt :: !(Maybe UTCTime),
    danwaTarget :: !(Maybe DanwaTarget),
    resolvedRecipient :: !(Maybe Text),
    conversationKey :: !(Maybe Text),
    triggeringActivityId :: !(Maybe Text),
    sink :: !Sink,
    output :: !Value
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SinkIntent where
  toJSON SinkIntent {agent, identity, runId, ordinal, occurredAt, danwaTarget, resolvedRecipient, conversationKey, triggeringActivityId, sink, output} =
    Aeson.object
      ( [ "agent" Aeson..= agent,
          "runId" Aeson..= runId,
          "ordinal" Aeson..= ordinal,
          "sink" Aeson..= sink,
          "output" Aeson..= output
        ]
          <> ["identity" Aeson..= identity | identity /= UnresolvedLegacyIdentity]
          <> maybeField "occurredAt" occurredAt
          <> maybeField "danwaTarget" danwaTarget
          <> maybeField "resolvedRecipient" resolvedRecipient
          <> maybeField "conversationKey" conversationKey
          <> maybeField "triggeringActivityId" triggeringActivityId
      )
    where
      maybeField _ Nothing = []
      maybeField key (Just value) = [key Aeson..= value]

instance FromJSON SinkIntent where
  parseJSON = withObject "SinkIntent" \object -> do
    explicitIdentity <- object .:? "identity"
    legacyPrincipal <- object .:? "principalId"
    identity <- case explicitIdentity of
      Just recorded -> pure recorded
      Nothing -> case legacyPrincipal of
        Just raw -> either (fail . Text.unpack) (pure . VerifiedIdentity) (mkAgentPrincipal raw)
        Nothing -> pure UnresolvedLegacyIdentity
    SinkIntent
      <$> object .: "agent"
      <*> pure identity
      <*> object .: "runId"
      <*> object .: "ordinal"
      <*> object .:? "occurredAt"
      <*> object .:? "danwaTarget"
      <*> object .:? "resolvedRecipient"
      <*> object .:? "conversationKey"
      <*> object .:? "triggeringActivityId"
      <*> object .: "sink"
      <*> object .: "output"

data PreparedSinkIntent = PreparedSinkIntent
  { sinkResult :: !SinkResult,
    outboxMessage :: !(Maybe OutboxMessage),
    deliveryReceipt :: !(Maybe Delivery.DeliveryReceipt)
  }

-- | Atomically journal and enqueue every independent sink declared for one
-- agent run. Each sink gets its own ordering key so one retrying transport does
-- not block its siblings.
enqueueSinkIntents ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  DirectoryHandle ->
  GrantSource ->
  Text ->
  AgentIdentity ->
  UTCTime ->
  ActivityEnvelope ->
  [Sink] ->
  SessionId ->
  Value ->
  Eff es [SinkResult]
enqueueSinkIntents directoryHandle grantSource agentName identity jobOccurredAt activity sinks sessionId output = do
  (workflowName, workflowId) <- currentWorkflow
  generation <- currentRunGeneration
  capturedTraceContext <- traceContextFromCurrentSpan
  now <- liftIO getCurrentTime
  prepared <- liftIO (traverse (buildSinkIntent capturedTraceContext workflowId now) (zip [0 ..] sinks))
  let results = fst <$> prepared
      enqueued = mapMaybe snd prepared
      encoded = Aeson.toJSON results
  appendTx <- prepareJournalAppend workflowName workflowId generation (StepRecorded (unStepName dispatchSinksStep) encoded now)
  txResult <- runTransaction do
    appendTx >>= \case
      JournalAppended {} -> do
        traverse_ (enqueueOutboxTx . fst) enqueued
        traverse_ (Delivery.recordDeliveryTx . snd) enqueued
        pure (Right results)
      JournalAlreadyPresent stored ->
        case parseEither Aeson.parseJSON stored of
          Right replayed -> pure (Right replayed)
          Left err -> pure (Left ("dispatch-sinks replay decode failed: " <> Text.pack err))
      JournalRefusedTerminal marker ->
        pure (Left ("dispatch-sinks journal append refused by terminal marker: " <> marker))
      JournalAppendConflict err ->
        pure (Left ("dispatch-sinks journal append conflict: " <> Text.pack (show err)))
  case txResult of
    Right results' -> pure results'
    Left err -> liftIO (ioError (userError (Text.unpack err)))
  where
    dispatchSinksStep = StepName "dispatch-sinks"
    runIdText = idText sessionId

    buildSinkIntent capturedTraceContext workflowId now (ordinal, sink) = do
      let kind = sinkKindOf sink
      Directory.identityLifecycleAdmission directoryHandle identity >>= \case
        Left reason -> pure (SinkResult kind (SkippedLifecycle reason), Nothing)
        Right () ->
          checkGrant grantSource identity kind <&> \case
            Left (Denied reason) ->
              (SinkResult kind (DeniedOutcome reason), Nothing)
            Right () ->
              let (resolvedConversationKey, resolvedTriggeringActivityId) = egressMetadata sink (Just activity) output
                  intent =
                    SinkIntent
                      { agent = agentName,
                        identity,
                        runId = runIdText,
                        ordinal,
                        occurredAt = Just jobOccurredAt,
                        danwaTarget = Nothing,
                        resolvedRecipient = resolveSinkRecipient sink (Just activity),
                        conversationKey = resolvedConversationKey,
                        triggeringActivityId = resolvedTriggeringActivityId,
                        sink,
                        output
                      }
                  messageId = sinkMessageId workflowId ordinal
                  orderingKey = runIdText <> ":" <> Text.pack (show ordinal)
                  event = sinkIntentEvent messageId orderingKey jobOccurredAt capturedTraceContext intent
                  outboxId = deterministicOutboxId workflowId ordinal
                  receipt = pendingDeliveryReceipt messageId kind now intent
               in (SinkResult kind (Enqueued ("outbox:" <> messageId)), Just (OutboxMessage outboxId event, receipt))

-- | Journal and enqueue one step-shaped sink intent. Flows and conversation
-- replies retain their shared per-run ordering key because their outputs are
-- ordered within one durable conversation or flow.
enqueueSinkIntentStep ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  DirectoryHandle ->
  GrantSource ->
  AgentIdentity ->
  StepName ->
  Text ->
  Text ->
  Int ->
  Maybe UTCTime ->
  Maybe DanwaTarget ->
  Maybe ActivityEnvelope ->
  Sink ->
  Value ->
  Eff es SinkResult
enqueueSinkIntentStep directoryHandle grantSource identity stepName agentName runIdText ordinal occurredAt danwaTarget activity sink output = do
  (workflowName, workflowId) <- currentWorkflow
  generation <- currentRunGeneration
  now <- liftIO getCurrentTime
  prepared <- liftIO (prepareSinkIntent directoryHandle grantSource identity workflowId stepName agentName runIdText ordinal occurredAt danwaTarget activity sink output now)
  let result = preparedSinkResult prepared
  appendTx <- prepareJournalAppend workflowName workflowId generation (StepRecorded (unStepName stepName) (Aeson.toJSON result) now)
  txResult <- runTransaction do
    appendTx >>= \case
      JournalAppended {} -> do
        enqueuePreparedSinkIntentTx prepared
        pure (Right result)
      JournalAlreadyPresent stored ->
        case parseEither Aeson.parseJSON stored of
          Right replayed -> pure (Right replayed)
          Left err -> pure (Left ("sink intent replay decode failed: " <> Text.pack err))
      JournalRefusedTerminal marker ->
        pure (Left ("sink intent journal append refused by terminal marker: " <> marker))
      JournalAppendConflict err ->
        pure (Left ("sink intent journal append conflict: " <> Text.pack (show err)))
  case txResult of
    Right result' -> pure result'
    Left err -> liftIO (ioError (userError (Text.unpack err)))

prepareSinkIntent ::
  DirectoryHandle ->
  GrantSource ->
  AgentIdentity ->
  WorkflowId ->
  StepName ->
  Text ->
  Text ->
  Int ->
  Maybe UTCTime ->
  Maybe DanwaTarget ->
  Maybe ActivityEnvelope ->
  Sink ->
  Value ->
  UTCTime ->
  IO PreparedSinkIntent
prepareSinkIntent directoryHandle grantSource identity workflowId stepName agentName runIdText ordinal occurredAt danwaTarget activity sink output now = do
  prepareSinkIntentWithRecipient
    directoryHandle
    grantSource
    identity
    workflowId
    stepName
    agentName
    runIdText
    ordinal
    occurredAt
    danwaTarget
    activity
    Nothing
    (resolveSinkRecipient sink activity)
    sink
    output
    now

-- | Prepare one sink with a deployment-resolved recipient. This is narrower
-- than a global fallback: callers must supply the concrete destination and the
-- resulting intent records it before entering the outbox transaction.
prepareSinkIntentForRecipient ::
  DirectoryHandle ->
  GrantSource ->
  AgentIdentity ->
  WorkflowId ->
  StepName ->
  Text ->
  Text ->
  Int ->
  Maybe UTCTime ->
  Maybe DanwaTarget ->
  Maybe ActivityEnvelope ->
  Text ->
  Sink ->
  Value ->
  UTCTime ->
  IO PreparedSinkIntent
prepareSinkIntentForRecipient directoryHandle grantSource identity workflowId stepName agentName runIdText ordinal occurredAt danwaTarget activity recipient sink output now =
  prepareSinkIntentWithRecipient directoryHandle grantSource identity workflowId stepName agentName runIdText ordinal occurredAt danwaTarget activity Nothing (Just recipient) sink output now

-- | Explicit-recipient preparation with a semantic message id shared by
-- equivalent producers. Only the reservation winner may enqueue the result.
prepareSinkIntentForRecipientWithMessageId ::
  DirectoryHandle ->
  GrantSource ->
  AgentIdentity ->
  WorkflowId ->
  StepName ->
  Text ->
  Text ->
  Int ->
  Maybe UTCTime ->
  Maybe DanwaTarget ->
  Maybe ActivityEnvelope ->
  Text ->
  Text ->
  Sink ->
  Value ->
  UTCTime ->
  IO PreparedSinkIntent
prepareSinkIntentForRecipientWithMessageId directoryHandle grantSource identity workflowId stepName agentName runIdText ordinal occurredAt danwaTarget activity messageId recipient sink output now =
  prepareSinkIntentWithRecipient directoryHandle grantSource identity workflowId stepName agentName runIdText ordinal occurredAt danwaTarget activity (Just messageId) (Just recipient) sink output now

prepareSinkIntentWithRecipient ::
  DirectoryHandle ->
  GrantSource ->
  AgentIdentity ->
  WorkflowId ->
  StepName ->
  Text ->
  Text ->
  Int ->
  Maybe UTCTime ->
  Maybe DanwaTarget ->
  Maybe ActivityEnvelope ->
  Maybe Text ->
  Maybe Text ->
  Sink ->
  Value ->
  UTCTime ->
  IO PreparedSinkIntent
prepareSinkIntentWithRecipient directoryHandle grantSource identity workflowId stepName agentName runIdText ordinal occurredAt danwaTarget activity explicitMessageId explicitRecipient sink output now = do
  capturedTraceContext <- traceContextFromCurrentSpan
  let kind = sinkKindOf sink
      messageId = fromMaybe (unWorkflowId workflowId <> ":" <> unStepName stepName) explicitMessageId
      outboxId = deterministicOutboxIdForMessage messageId
      deniedResult reason = SinkResult kind (DeniedOutcome reason)
      enqueuedResult = SinkResult kind (Enqueued ("outbox:" <> messageId))
  Directory.identityLifecycleAdmission directoryHandle identity >>= \case
    Left reason ->
      pure
        PreparedSinkIntent
          { sinkResult = SinkResult kind (SkippedLifecycle reason),
            outboxMessage = Nothing,
            deliveryReceipt = Nothing
          }
    Right () ->
      checkGrant grantSource identity kind <&> \case
        Left (Denied reason) ->
          PreparedSinkIntent
            { sinkResult = deniedResult reason,
              outboxMessage = Nothing,
              deliveryReceipt = Nothing
            }
        Right () ->
          let (resolvedConversationKey, resolvedTriggeringActivityId) = egressMetadata sink activity output
              intent =
                SinkIntent
                  { agent = agentName,
                    identity,
                    runId = runIdText,
                    ordinal,
                    occurredAt,
                    danwaTarget,
                    resolvedRecipient = explicitRecipient,
                    conversationKey = resolvedConversationKey,
                    triggeringActivityId = resolvedTriggeringActivityId,
                    sink,
                    output
                  }
              event = sinkIntentEvent messageId runIdText now capturedTraceContext intent
              receipt = pendingDeliveryReceipt messageId kind now intent
           in PreparedSinkIntent
                { sinkResult = enqueuedResult,
                  outboxMessage = Just (OutboxMessage outboxId event),
                  deliveryReceipt = Just receipt
                }

egressMetadata :: Sink -> Maybe ActivityEnvelope -> Value -> (Maybe Text, Maybe Text)
egressMetadata sink activity output = case sink of
  ChannelEgress {} ->
    ( resolveConversationKey sink activity output,
      Activity.activityId <$> activity
    )
  _ -> (Nothing, Nothing)

preparedSinkResult :: PreparedSinkIntent -> SinkResult
preparedSinkResult PreparedSinkIntent {sinkResult} = sinkResult

enqueuePreparedSinkIntentTx :: PreparedSinkIntent -> Tx.Transaction ()
enqueuePreparedSinkIntentTx PreparedSinkIntent {outboxMessage, deliveryReceipt} = do
  traverse_ enqueueOutboxTx outboxMessage
  traverse_ Delivery.recordDeliveryTx deliveryReceipt

deliveryReceiptFor :: Text -> SinkKind -> Delivery.DeliveryStatus -> Maybe Text -> UTCTime -> SinkIntent -> Delivery.DeliveryReceipt
deliveryReceiptFor messageId kind = deliveryReceiptForKey (Delivery.deliveryReceiptKey messageId) messageId kind

deliveryReceiptForKey :: Text -> Text -> SinkKind -> Delivery.DeliveryStatus -> Maybe Text -> UTCTime -> SinkIntent -> Delivery.DeliveryReceipt
deliveryReceiptForKey key messageId kind receiptStatus receiptDetail now SinkIntent {agent, runId, ordinal} =
  Delivery.DeliveryReceipt
    { Delivery.receiptKey = key,
      Delivery.outboxMessageId = messageId,
      Delivery.runId = runId,
      Delivery.agent = agent,
      Delivery.ordinal = ordinal,
      Delivery.sinkKind = sinkKindText kind,
      Delivery.status = receiptStatus,
      Delivery.detail = receiptDetail,
      Delivery.updatedAt = now
    }

pendingDeliveryReceipt :: Text -> SinkKind -> UTCTime -> SinkIntent -> Delivery.DeliveryReceipt
pendingDeliveryReceipt messageId kind = deliveryReceiptFor messageId kind Delivery.Pending Nothing

decodeSinkIntentEvent :: IntegrationEvent -> Either IntegrationEventError SinkIntent
decodeSinkIntentEvent = decodeJsonIntegrationEvent

sinkIntentEvent :: Text -> Text -> UTCTime -> Maybe TraceContext -> SinkIntent -> IntegrationEvent
sinkIntentEvent messageId orderingKey occurredAt traceContext intent =
  encodeJsonIntegrationEvent
    IntegrationEvent
      { messageId,
        source = "shinzui/shikigami",
        destination = "shikigami.sink.v1",
        key = Just orderingKey,
        eventType = "shikigami.sink.dispatch-requested",
        schemaVersion = 1,
        contentType = ApplicationJson,
        schemaReference = Nothing,
        sourceEventId = Nothing,
        sourceGlobalPosition = Nothing,
        payloadBytes = mempty,
        occurredAt,
        causationId = Nothing,
        correlationId = Nothing,
        traceContext,
        attributes = Nothing
      }
    intent

sinkMessageId :: WorkflowId -> Int -> Text
sinkMessageId workflowId ordinal =
  unWorkflowId workflowId <> ":sink:" <> Text.pack (show ordinal)

deterministicOutboxId :: WorkflowId -> Int -> OutboxId
deterministicOutboxId workflowId ordinal =
  deterministicOutboxIdForMessage (sinkMessageId workflowId ordinal)

deterministicOutboxIdForMessage :: Text -> OutboxId
deterministicOutboxIdForMessage messageId =
  OutboxId $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      nameBytes ("shikigami:sink:" <> messageId)
