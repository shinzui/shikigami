{-# LANGUAGE DataKinds #-}

-- | The single durable contract between output producers and the
-- asynchronous publisher. Agent runs, conversations, and flows all prepare and
-- enqueue this record through this module; the publisher decodes the same
-- type here. An intent names its output ('OutputDecl') and carries the
-- address its adapter computed when it was enqueued (plan 135, M3).
module Shikigami.Sink.Intent
  ( SinkIntent (..),
    AddressedOutput (..),
    PreparedSinkIntent,
    enqueueSinkIntents,
    enqueueSinkIntentStep,
    enqueueSinkIntentBatch,
    enqueuePreparedSinkIntentTx,
    prepareSinkIntent,
    prepareSinkIntentWithMessageId,
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
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
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
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity (..), mkAgentPrincipal)
import Shikigami.Authority (AuthorityFailure (..), OutputKind, authorityFailureDetail, outputKindText)
import Shikigami.Directory (DirectoryHandle)
import Shikigami.Directory qualified as Directory
import Shikigami.Output (OutputDecl (..), OutputRegistry, lookupAdapter, outboxRouteOf)
import Shikigami.Prelude hiding ((.=))
import Shikigami.Sink
  ( GrantSource,
    SinkOutcome (..),
    SinkResult (..),
    checkGrant,
  )
import Shikigami.Sink.Authorization (authorizeOutput)
import Shikigami.Sink.Coordinate (SinkOrdinal, parseSinkOrdinal, parseSinkSession)
import Shikigami.Sink.Delivery qualified as Delivery
import Shikigami.Sink.GrantStore (authorityFor)
import Shikigami.Sink.Permission (Denied (..))
import Shikigami.Sink.Types (AddressInput (..), OutboxRoute (..))

-- | Everything the publisher needs to dispatch one output after the
-- producing workflow has committed.
data SinkIntent = SinkIntent
  { agent :: !AgentName,
    identity :: !AgentIdentity,
    runId :: !SessionId,
    -- | The workflow that enqueued the output, which the action record
    -- attributes the delivery to (plan 135, M6). Absent on an intent written
    -- before it existed or by a producer with no run of its own.
    run :: !(Maybe WorkflowId),
    ordinal :: !SinkOrdinal,
    occurredAt :: !(Maybe UTCTime),
    output :: !OutputDecl,
    -- | What the adapter computed at enqueue; opaque to the kernel.
    address :: !Value,
    -- | The behavior's result the output carries.
    result :: !Value
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SinkIntent where
  toJSON SinkIntent {agent, identity, runId, run, ordinal, occurredAt, output, address, result} =
    Aeson.object
      ( [ "agent" .= agent,
          "runId" .= idText runId,
          "ordinal" .= ordinal,
          "output" .= output,
          "address" .= address,
          "result" .= result
        ]
          <> ["identity" .= identity | identity /= UnresolvedLegacyIdentity]
          <> maybe [] (\value -> ["occurredAt" .= value]) occurredAt
          <> maybe [] (\WorkflowId {unWorkflowId} -> ["run" .= unWorkflowId]) run
      )

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
      <*> (fmap WorkflowId <$> object .:? "run")
      <*> object .: "ordinal"
      <*> object .:? "occurredAt"
      <*> object .: "output"
      <*> object .: "address"
      <*> object .: "result"

-- | One output a flow emits in a batch: the output, already directed by its
-- configuration, and the result it carries.
data AddressedOutput = AddressedOutput {output :: !OutputDecl, result :: !Value}
  deriving stock (Eq, Show, Generic)

data PreparedSinkIntent = PreparedSinkIntent
  { sinkResult :: !SinkResult,
    outboxMessage :: !(Maybe OutboxMessage),
    deliveryReceipt :: !(Maybe Delivery.DeliveryReceipt)
  }

-- | What one producer supplies for one intent.
data Producer = Producer
  { registry :: !OutputRegistry,
    directory :: !DirectoryHandle,
    grants :: !GrantSource,
    identity :: !AgentIdentity,
    agent :: !AgentName,
    runId :: !SessionId,
    -- | The enqueuing workflow, recorded on the intent.
    run :: !(Maybe WorkflowId),
    occurredAt :: !(Maybe UTCTime),
    activity :: !(Maybe ActivityEnvelope)
  }

-- | Where one intent goes in the outbox.
data Placement = Placement
  { messageId :: !Text,
    orderingKey :: !Text,
    eventTime :: !UTCTime
  }

-- | Atomically journal and enqueue every outbox output of one agent run,
-- each at its position in the run's resolved outputs. Each output gets its
-- own ordering key so one retrying transport does not block its siblings.
enqueueSinkIntents ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  OutputRegistry ->
  DirectoryHandle ->
  GrantSource ->
  AgentName ->
  AgentIdentity ->
  UTCTime ->
  ActivityEnvelope ->
  [(Int, OutputDecl)] ->
  SessionId ->
  Value ->
  Eff es [SinkResult]
enqueueSinkIntents registry directoryHandle grantSource agentName identity jobOccurredAt activity outputs sessionId result = do
  (workflowName, workflowId) <- currentWorkflow
  generation <- currentRunGeneration
  now <- liftIO getCurrentTime
  let producer = Producer {registry, directory = directoryHandle, grants = grantSource, identity, agent = agentName, runId = sessionId, run = Just workflowId, occurredAt = Just jobOccurredAt, activity = Just activity}
      placement ordinal = Placement {messageId = sinkMessageId workflowId ordinal, orderingKey = idText sessionId <> ":" <> Text.pack (show ordinal), eventTime = jobOccurredAt}
  prepared <- liftIO (traverse (\(ordinal, output) -> prepareIntent producer (placement ordinal) ordinal output result now) outputs)
  let results = preparedSinkResult <$> prepared
  appendTx <- prepareJournalAppend workflowName workflowId generation (StepRecorded (unStepName dispatchSinksStep) (Aeson.toJSON results) now)
  txResult <- runTransaction do
    appendTx >>= \case
      JournalAppended {} -> do
        traverse_ enqueuePreparedSinkIntentTx prepared
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

-- | Journal and enqueue one step-shaped intent. Flows and conversation
-- replies retain their shared per-run ordering key because their outputs are
-- ordered within one durable conversation or flow.
enqueueSinkIntentStep ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  OutputRegistry ->
  DirectoryHandle ->
  GrantSource ->
  AgentIdentity ->
  StepName ->
  AgentName ->
  SessionId ->
  Int ->
  Maybe UTCTime ->
  Maybe ActivityEnvelope ->
  OutputDecl ->
  Value ->
  Eff es SinkResult
enqueueSinkIntentStep registry directoryHandle grantSource identity stepName agentName runId ordinal occurredAt activity output result = do
  (_, workflowId) <- currentWorkflow
  now <- liftIO getCurrentTime
  prepared <- liftIO (prepareSinkIntent registry directoryHandle grantSource identity workflowId stepName agentName runId ordinal occurredAt activity output result now)
  journalPreparedSinkIntent stepName now prepared

-- | One static journal record and one atomic outbox/receipt batch. Admission is
-- checked afresh for every intent; replay returns the committed batch verbatim.
enqueueSinkIntentBatch :: (Workflow :> es, Store :> es, IOE :> es) => IO () -> OutputRegistry -> DirectoryHandle -> GrantSource -> AgentIdentity -> StepName -> AgentName -> SessionId -> Int -> Maybe UTCTime -> NonEmpty AddressedOutput -> Eff es [SinkResult]
enqueueSinkIntentBatch onCommitted registry directory grants identity label agent run first occurredAt outputs = do
  when (NonEmpty.length outputs > 192) (liftIO (ioError (userError "sink batch exceeds 192")))
  (workflowName, workflowId) <- currentWorkflow
  now <- liftIO getCurrentTime
  let producer = Producer {registry, directory, grants, identity, agent, runId = run, run = Just workflowId, occurredAt, activity = Nothing}
      prepare (ordinal, AddressedOutput {output, result}) =
        let message = workflowId.unWorkflowId <> ":" <> unStepName label <> ":" <> Text.pack (show ordinal)
         in prepareIntent producer Placement {messageId = message, orderingKey = idText run, eventTime = now} ordinal output result now
  prepared <- liftIO (traverse prepare (zip [first ..] (NonEmpty.toList outputs)))
  generation <- currentRunGeneration
  let results = map preparedSinkResult prepared
  appendTx <- prepareJournalAppend workflowName workflowId generation (StepRecorded (unStepName label) (Aeson.toJSON results) now)
  outcome <- runTransaction do
    appendTx >>= \case
      JournalAppended {} -> traverse_ enqueuePreparedSinkIntentTx prepared >> pure (Right (True, results))
      JournalAlreadyPresent stored -> pure ((False,) <$> parseEither Aeson.parseJSON stored)
      JournalRefusedTerminal marker -> pure (Left (Text.unpack marker))
      JournalAppendConflict err -> pure (Left (show err))
  (fresh, retained) <- either (liftIO . ioError . userError) pure outcome
  when fresh (liftIO onCommitted)
  pure retained

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

-- | Prepare one intent whose message id is the workflow and step.
prepareSinkIntent ::
  OutputRegistry ->
  DirectoryHandle ->
  GrantSource ->
  AgentIdentity ->
  WorkflowId ->
  StepName ->
  AgentName ->
  SessionId ->
  Int ->
  Maybe UTCTime ->
  Maybe ActivityEnvelope ->
  OutputDecl ->
  Value ->
  UTCTime ->
  IO PreparedSinkIntent
prepareSinkIntent registry directoryHandle grantSource identity workflowId stepName agentName runId ordinal occurredAt activity output result now =
  prepareIntent
    Producer {registry, directory = directoryHandle, grants = grantSource, identity, agent = agentName, runId, run = Just workflowId, occurredAt, activity}
    Placement {messageId = unWorkflowId workflowId <> ":" <> unStepName stepName, orderingKey = idText runId, eventTime = now}
    ordinal
    output
    result
    now

-- | Preparation with a semantic message id shared by equivalent producers.
-- Only the reservation winner may enqueue the result.
prepareSinkIntentWithMessageId ::
  OutputRegistry ->
  DirectoryHandle ->
  GrantSource ->
  AgentIdentity ->
  AgentName ->
  SessionId ->
  Int ->
  Maybe UTCTime ->
  Maybe ActivityEnvelope ->
  Delivery.SinkMessageId ->
  OutputDecl ->
  Value ->
  UTCTime ->
  IO PreparedSinkIntent
prepareSinkIntentWithMessageId registry directoryHandle grantSource identity agentName runId ordinal occurredAt activity messageId output result now =
  prepareIntent
    Producer {registry, directory = directoryHandle, grants = grantSource, identity, agent = agentName, runId, run = Nothing, occurredAt, activity}
    Placement {messageId = Delivery.sinkMessageIdText messageId, orderingKey = idText runId, eventTime = now}
    ordinal
    output
    result
    now

-- | The enqueue-time gates, in order: the output's adapter routes through
-- the outbox, the principal's lifecycle admits it, C11 grants the kind, and
-- the authority allows the exact target the adapter names. Any refusal is a
-- result with nothing enqueued.
prepareIntent :: Producer -> Placement -> Int -> OutputDecl -> Value -> UTCTime -> IO PreparedSinkIntent
prepareIntent producer Placement {messageId, orderingKey, eventTime} ordinal output result now = do
  position <- admitSinkOrdinal ordinal
  capturedTraceContext <- traceContextFromCurrentSpan
  let kind = output.kind
      refusedWith outcome = pure PreparedSinkIntent {sinkResult = SinkResult kind outcome, outboxMessage = Nothing, deliveryReceipt = Nothing}
  case lookupAdapter producer.registry kind >>= outboxRouteOf of
    Nothing -> refusedWith (DeniedOutcome (unroutable kind))
    Just route ->
      Directory.identityLifecycleAdmission producer.directory producer.identity >>= \case
        Left reason -> refusedWith (SkippedLifecycle reason)
        Right () ->
          checkGrant producer.grants producer.identity kind >>= \case
            Left (Denied reason) -> refusedWith (DeniedOutcome reason)
            Right () -> do
              let address = route.address AddressInput {config = output.config, activity = producer.activity, result}
                  intent =
                    SinkIntent
                      { agent = producer.agent,
                        identity = producer.identity,
                        runId = producer.runId,
                        run = producer.run,
                        ordinal = position,
                        occurredAt = producer.occurredAt,
                        output,
                        address,
                        result
                      }
                  event = sinkIntentEvent messageId orderingKey eventTime capturedTraceContext intent
                  receipt = pendingDeliveryReceipt messageId kind now intent
              authorizeOutput (authorityFor producer.grants) producer.identity kind (route.target output.config address) >>= \case
                Left failure -> refusedWith (authorizationOutcome failure)
                Right _ ->
                  pure
                    PreparedSinkIntent
                      { sinkResult = SinkResult kind (Enqueued (declarationCoordinate ("outbox:" <> messageId))),
                        outboxMessage = Just (OutboxMessage (deterministicOutboxIdForMessage messageId) event),
                        deliveryReceipt = Just receipt
                      }

unroutable :: OutputKind -> Text
unroutable kind = "output kind " <> outputKindText kind <> " is not delivered through the outbox here"

authorizationOutcome :: AuthorityFailure -> SinkOutcome
authorizationOutcome failure@PolicyDenied {} = DeniedOutcome (authorityFailureDetail failure)
authorizationOutcome failure = AuthorizationFailed (authorityFailureDetail failure)

preparedSinkResult :: PreparedSinkIntent -> SinkResult
preparedSinkResult PreparedSinkIntent {sinkResult} = sinkResult

enqueuePreparedSinkIntentTx :: PreparedSinkIntent -> Tx.Transaction ()
enqueuePreparedSinkIntentTx PreparedSinkIntent {outboxMessage, deliveryReceipt} = do
  traverse_ enqueueOutboxTx outboxMessage
  traverse_ Delivery.recordDeliveryTx deliveryReceipt

deliveryContextFor :: Text -> OutputKind -> SinkIntent -> Delivery.ReceiptContext
deliveryContextFor messageId kind SinkIntent {agent, runId, ordinal} =
  Delivery.ReceiptContext (Delivery.sinkMessageId messageId) runId agent ordinal kind

deliveryReceiptFor :: Text -> OutputKind -> Delivery.DeliveryStatus -> Maybe Text -> UTCTime -> SinkIntent -> Delivery.DeliveryReceipt
deliveryReceiptFor messageId kind = deliveryReceiptForKey (Delivery.deliveryReceiptKey messageId) messageId kind

deliveryReceiptForKey :: Delivery.ReceiptKey -> Text -> OutputKind -> Delivery.DeliveryStatus -> Maybe Text -> UTCTime -> SinkIntent -> Delivery.DeliveryReceipt
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

pendingDeliveryReceipt :: Text -> OutputKind -> UTCTime -> SinkIntent -> Delivery.DeliveryReceipt
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
