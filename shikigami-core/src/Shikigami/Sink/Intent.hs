{-# LANGUAGE DataKinds #-}

-- | The single durable contract between sink producers and the asynchronous
-- publisher. Agent runs, conversations, and flows all prepare and enqueue this
-- record through this module; the publisher decodes the same type here.
module Shikigami.Sink.Intent
  ( SinkIntent (..),
    PreparedSinkIntent,
    enqueueSinkIntents,
    enqueueSinkIntentStep,
    enqueueSinkIntentStepForRecipient,
    enqueuePreparedSinkIntentTx,
    prepareSinkIntent,
    prepareSinkIntentForRecipient,
    prepareSinkIntentForRecipientWithMessageId,
    preparedSinkResult,
    decodeSinkIntentEvent,
    sinkIntentEvent,
    deliveryReceiptFor,
    deliveryContextFor,
    deliveryReceiptForKey,
    sinkMessageId,
    deterministicOutboxId,
    deterministicOutboxIdForMessage,
  )
where

import Data.Aeson (Value, withObject, (.:), (.:?), (.=))
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
import Shikigami.Action.Authorization (ActionAuthorizationFailure (..), authorizationFailureDetail)
import Shikigami.Activity (ActivityEnvelope, activityCoordinateText)
import Shikigami.Activity qualified as Activity
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Decl (Sink (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity (..), mkAgentPrincipal)
import Shikigami.Directory (DirectoryHandle)
import Shikigami.Directory qualified as Directory
import Shikigami.Prelude hiding ((.=))
import Shikigami.Sink
  ( DanwaTarget,
    GrantSource,
    SinkOutcome (..),
    SinkResult (..),
    checkGrant,
    sinkKindOf,
  )
import Shikigami.Sink.Authorization (authorizeSinkAction)
import Shikigami.Sink.Coordinate (SinkOrdinal, parseSinkOrdinal, parseSinkSession)
import Shikigami.Sink.Delivery qualified as Delivery
import Shikigami.Sink.GrantStore (actionAuthorizerFor)
import Shikigami.Sink.KanmonClient (resolveConversationKey)
import Shikigami.Sink.Permission
  ( Denied (..),
    SinkKind,
  )
import Shikigami.Sink.Recipient (resolveSinkRecipient)

-- | Everything the publisher needs to dispatch one sink after the producing
-- workflow has committed. Optional fields are omitted so rows written before
-- an additive field existed keep their original bytes.
data SinkIntent = SinkIntent
  { agent :: !AgentName,
    identity :: !AgentIdentity,
    runId :: !SessionId,
    ordinal :: !SinkOrdinal,
    occurredAt :: !(Maybe UTCTime),
    danwaTarget :: !(Maybe DanwaTarget),
    resolvedRecipient :: !(Maybe (DeclarationCoordinate "recipient")),
    conversationKey :: !(Maybe (DeclarationCoordinate "conversation")),
    triggeringActivityId :: !(Maybe (ActivityCoordinate "activity-id")),
    sink :: !Sink,
    output :: !Value
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SinkIntent where
  toJSON SinkIntent {agent, identity, runId, ordinal, occurredAt, danwaTarget, resolvedRecipient, conversationKey, triggeringActivityId, sink, output} =
    Aeson.object
      ( [ "agent" .= agent,
          "runId" .= idText runId,
          "ordinal" .= ordinal,
          "sink" .= sink,
          "output" .= output
        ]
          <> ["identity" .= identity | identity /= UnresolvedLegacyIdentity]
          <> maybeField "occurredAt" occurredAt
          <> maybeField "danwaTarget" danwaTarget
          <> maybeField "resolvedRecipient" resolvedRecipient
          <> maybeField "conversationKey" conversationKey
          <> maybeField "triggeringActivityId" triggeringActivityId
      )
    where
      maybeField _ Nothing = []
      maybeField key (Just value) = [key .= value]

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
      <*> (object .: "runId" >>= either (fail . Text.unpack) pure . parseSinkSession)
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
  AgentName ->
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
      position <- admitSinkOrdinal ordinal
      let kind = sinkKindOf sink
      Directory.identityLifecycleAdmission directoryHandle identity >>= \case
        Left reason -> pure (SinkResult kind (SkippedLifecycle reason), Nothing)
        Right () ->
          checkGrant grantSource identity kind >>= \case
            Left (Denied reason) ->
              pure (SinkResult kind (DeniedOutcome reason), Nothing)
            Right () -> do
              let (resolvedConversationKey, resolvedTriggeringActivityId) = egressMetadata sink (Just activity) output
                  intent =
                    SinkIntent
                      { agent = agentName,
                        identity,
                        runId = sessionId,
                        ordinal = position,
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
              authorizeSinkAction (actionAuthorizerFor grantSource) identity sink Nothing ((.resolvedRecipient) intent) resolvedConversationKey now >>= \case
                Left failure -> pure (SinkResult kind (authorizationOutcome failure), Nothing)
                Right _ -> pure (SinkResult kind (Enqueued (declarationCoordinate ("outbox:" <> messageId))), Just (OutboxMessage outboxId event, receipt))

-- | Journal and enqueue one step-shaped sink intent. Flows and conversation
-- replies retain their shared per-run ordering key because their outputs are
-- ordered within one durable conversation or flow.
enqueueSinkIntentStep ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  DirectoryHandle ->
  GrantSource ->
  AgentIdentity ->
  StepName ->
  AgentName ->
  SessionId ->
  Int ->
  Maybe UTCTime ->
  Maybe DanwaTarget ->
  Maybe ActivityEnvelope ->
  Sink ->
  Value ->
  Eff es SinkResult
enqueueSinkIntentStep directoryHandle grantSource identity stepName agentName runIdText ordinal occurredAt danwaTarget activity sink output = do
  (_, workflowId) <- currentWorkflow
  now <- liftIO getCurrentTime
  prepared <- liftIO (prepareSinkIntent directoryHandle grantSource identity workflowId stepName agentName runIdText ordinal occurredAt danwaTarget activity sink output now)
  journalPreparedSinkIntent stepName now prepared

-- | The same journaled emission to a destination the caller already resolved from
-- configuration, so nothing in the triggering activity can choose where it goes.
enqueueSinkIntentStepForRecipient ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  DirectoryHandle ->
  GrantSource ->
  AgentIdentity ->
  StepName ->
  AgentName ->
  SessionId ->
  Int ->
  Maybe UTCTime ->
  Maybe DanwaTarget ->
  Maybe ActivityEnvelope ->
  DeclarationCoordinate "recipient" ->
  Sink ->
  Value ->
  Eff es SinkResult
enqueueSinkIntentStepForRecipient directoryHandle grantSource identity stepName agentName runIdText ordinal occurredAt danwaTarget activity recipient sink output = do
  (_, workflowId) <- currentWorkflow
  now <- liftIO getCurrentTime
  prepared <- liftIO (prepareSinkIntentForRecipient directoryHandle grantSource identity workflowId stepName agentName runIdText ordinal occurredAt danwaTarget activity recipient sink output now)
  journalPreparedSinkIntent stepName now prepared

journalPreparedSinkIntent :: (Workflow :> es, Store :> es, IOE :> es) => StepName -> UTCTime -> PreparedSinkIntent -> Eff es SinkResult
journalPreparedSinkIntent stepName now prepared = do
  (workflowName, workflowId) <- currentWorkflow
  generation <- currentRunGeneration
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
  AgentName ->
  SessionId ->
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
  AgentName ->
  SessionId ->
  Int ->
  Maybe UTCTime ->
  Maybe DanwaTarget ->
  Maybe ActivityEnvelope ->
  DeclarationCoordinate "recipient" ->
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
  AgentName ->
  SessionId ->
  Int ->
  Maybe UTCTime ->
  Maybe DanwaTarget ->
  Maybe ActivityEnvelope ->
  Delivery.SinkMessageId ->
  DeclarationCoordinate "recipient" ->
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
  AgentName ->
  SessionId ->
  Int ->
  Maybe UTCTime ->
  Maybe DanwaTarget ->
  Maybe ActivityEnvelope ->
  Maybe Delivery.SinkMessageId ->
  Maybe (DeclarationCoordinate "recipient") ->
  Sink ->
  Value ->
  UTCTime ->
  IO PreparedSinkIntent
prepareSinkIntentWithRecipient directoryHandle grantSource identity workflowId stepName agentName runId ordinal occurredAt danwaTarget activity explicitMessageId explicitRecipient sink output now = do
  position <- admitSinkOrdinal ordinal
  let runIdText = idText runId
  capturedTraceContext <- traceContextFromCurrentSpan
  let kind = sinkKindOf sink
      messageId = maybe (unWorkflowId workflowId <> ":" <> unStepName stepName) Delivery.sinkMessageIdText explicitMessageId
      outboxId = deterministicOutboxIdForMessage messageId
      deniedResult reason = SinkResult kind (DeniedOutcome reason)
      enqueuedResult = SinkResult kind (Enqueued (declarationCoordinate ("outbox:" <> messageId)))
  Directory.identityLifecycleAdmission directoryHandle identity >>= \case
    Left reason ->
      pure
        PreparedSinkIntent
          { sinkResult = SinkResult kind (SkippedLifecycle reason),
            outboxMessage = Nothing,
            deliveryReceipt = Nothing
          }
    Right () ->
      checkGrant grantSource identity kind >>= \case
        Left (Denied reason) ->
          pure
            PreparedSinkIntent
              { sinkResult = deniedResult reason,
                outboxMessage = Nothing,
                deliveryReceipt = Nothing
              }
        Right () -> do
          let (resolvedConversationKey, resolvedTriggeringActivityId) = egressMetadata sink activity output
              intent =
                SinkIntent
                  { agent = agentName,
                    identity,
                    runId,
                    ordinal = position,
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
          authorizeSinkAction (actionAuthorizerFor grantSource) identity sink danwaTarget explicitRecipient resolvedConversationKey now >>= \case
            Left failure ->
              pure
                PreparedSinkIntent
                  { sinkResult = SinkResult kind (authorizationOutcome failure),
                    outboxMessage = Nothing,
                    deliveryReceipt = Nothing
                  }
            Right _ ->
              pure
                PreparedSinkIntent
                  { sinkResult = enqueuedResult,
                    outboxMessage = Just (OutboxMessage outboxId event),
                    deliveryReceipt = Just receipt
                  }

authorizationOutcome :: ActionAuthorizationFailure -> SinkOutcome
authorizationOutcome failure@ActionPolicyDenied {} = DeniedOutcome (authorizationFailureDetail failure)
authorizationOutcome failure = AuthorizationFailed (authorizationFailureDetail failure)

egressMetadata :: Sink -> Maybe ActivityEnvelope -> Value -> (Maybe (DeclarationCoordinate "conversation"), Maybe (ActivityCoordinate "activity-id"))
egressMetadata sink activity output = case sink of
  ChannelEgress {} ->
    ( resolveConversationKey sink activity output,
      (.activityId) <$> activity
    )
  _ -> (Nothing, Nothing)

preparedSinkResult :: PreparedSinkIntent -> SinkResult
preparedSinkResult PreparedSinkIntent {sinkResult} = sinkResult

enqueuePreparedSinkIntentTx :: PreparedSinkIntent -> Tx.Transaction ()
enqueuePreparedSinkIntentTx PreparedSinkIntent {outboxMessage, deliveryReceipt} = do
  traverse_ enqueueOutboxTx outboxMessage
  traverse_ Delivery.recordDeliveryTx deliveryReceipt

deliveryContextFor :: Text -> SinkKind -> SinkIntent -> Delivery.ReceiptContext
deliveryContextFor messageId kind SinkIntent {agent, runId, ordinal} =
  Delivery.ReceiptContext (Delivery.sinkMessageId messageId) runId agent ordinal kind

deliveryReceiptFor :: Text -> SinkKind -> Delivery.DeliveryStatus -> Maybe Text -> UTCTime -> SinkIntent -> Delivery.DeliveryReceipt
deliveryReceiptFor messageId kind = deliveryReceiptForKey (Delivery.deliveryReceiptKey messageId) messageId kind

deliveryReceiptForKey :: Delivery.ReceiptKey -> Text -> SinkKind -> Delivery.DeliveryStatus -> Maybe Text -> UTCTime -> SinkIntent -> Delivery.DeliveryReceipt
deliveryReceiptForKey key messageId kind receiptStatus receiptDetail now SinkIntent {agent, runId, ordinal} =
  Delivery.DeliveryReceipt
    { Delivery.receiptKey = key,
      Delivery.outboxMessageId = Delivery.sinkMessageId messageId,
      Delivery.runId = runId,
      Delivery.agent = agent,
      Delivery.ordinal = ordinal,
      Delivery.sinkKind = kind,
      Delivery.status = receiptStatus,
      Delivery.detail = Delivery.deliveryDetailFor receiptStatus <$> receiptDetail,
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

-- Producer indices are incidental Int counters until this construction boundary.
admitSinkOrdinal :: Int -> IO SinkOrdinal
admitSinkOrdinal = either (ioError . userError . Text.unpack) pure . parseSinkOrdinal . toInteger
