{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

-- | The record intake for stream and public integration-event triggers: one
-- delivered record becomes exactly one of the explicit durable dispositions
-- below. It decodes the record, matches the declared agents, consults the
-- packs' stream hooks and enqueues run jobs in one transaction.
--
-- It names no broker. A transport hands it a 'KafkaInboundRecord' (keiro's
-- delivery shape) and turns the disposition into its own acknowledgement with
-- 'ackDecisionFor'; the Kafka transport is the Kikan binding's intake
-- library (plan 135, M5), so no stock package links a Kafka client.
module Shikigami.Trigger.Intake
  ( StreamHit (..),
    EventHit (..),
    DeadLetterId (..),
    PayloadEvidence (..),
    DeadLetterRecord (..),
    RecordDisposition (..),
    processActivityRecord,
    processActivityRecordWithDirectory,
    processIntegrationEventRecord,
    processIntegrationEventRecordWithDirectory,
    processDecodedActivity,
    processDecodedActivityWithDirectory,
    processDecodedActivityObserving,
    processDecodedIntegrationEvent,
    processDecodedIntegrationEventWithDirectory,
    ackDecisionFor,
    permanentFailureCode,
    dispositionErrorLimit,
    logDisposition,
    ensureDeadLetterQueue,
  )
where

import Control.Exception qualified as Exception
import Data.Aeson (Value, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Word (Word8)
import Hasql.Pool (Pool, UsageError)
import Hasql.Pool qualified as Pool
import Hasql.Transaction qualified as Tx
import Keiro.Inbox (runInboxTransaction)
import Keiro.Inbox.Kafka (KafkaInboundRecord (..), integrationEventFromKafka)
import Keiro.Inbox.Types (InboxDedupePolicy (PreferIntegrationMessageId), InboxResult (..), KafkaDeliveryRef (..))
import Keiro.Integration.Event (IntegrationEvent, decodeJsonIntegrationEvent)
import Kiroku.Store.Notification (NotifierStartError)
import Kiroku.Store.Transaction (runTransaction)
import Pgmq (MessageBody (..), MessageId (..), QueueName, SendMessage (..), createQueue)
import Pgmq.Hasql.Statements.Message qualified as PgmqStatements
import Shibuya.Core.Ack (AckDecision (..), DeadLetterCode, DeadLetterReason (ApplicationFailure), HaltReason (..), mkDeadLetterCode)
import Shikigami.Activity (ActivityEnvelope, ActivityId)
import Shikigami.Agent.Decl (AgentDecl (..), IdentityDecl (..), StreamMatch, Trigger (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.Principal (AgentIdentity (..), AgentPrincipal, compatibilityIdentity, mkAgentPrincipal, resolveAgentIdentity)

import Shikigami.Agent.Conversation.Channel (ConversationChannels, channelForAgent, noConversationChannels)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (..), TriggerKind (TriggeredByEvent))
import Shikigami.Agent.RunJob qualified as RunJob
import Shikigami.App (AppEnv (..), runAppIO)
import Shikigami.Directory qualified as Directory
import Shikigami.Directory.Store (RunSkip (..), SkipStage (TriggerStage), recordRunSkipTx, reportedPrincipalClaim)
import Shikigami.Execution.Identity (ExecutionRootId, newExecutionRootId)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore (allocateRootForWorkflowTx)
import Shikigami.Log qualified as Log
import Shikigami.Prelude hiding ((.=))
import Shikigami.Trigger.Enqueue (enqueueRunJobTx, envelopeOccurredAt, integrationRunKey, runJobFromEnvelopeWithIdentity)
import Shikigami.Trigger.Hook (PackDisposition (..), StreamCandidate (..), StreamDisposition (..), StreamEvaluation (..), StreamIntake, StreamSkip (..), noStreamIntake)
import Shikigami.Trigger.Stream (IncludeAgentActors, matchesStreamWith)

data StreamHit = StreamHit
  { agentName :: !AgentName,
    envelope :: !ActivityEnvelope
  }
  deriving stock (Eq, Show)

data EventHit = EventHit
  { agentName :: !AgentName,
    eventType :: !Text,
    integrationMessageId :: !Text,
    payload :: !Value
  }
  deriving stock (Eq, Show)

data DeadLetterId
  = QueueDeadLetter !MessageId
  | InboxDeadLetter !(DeclarationCoordinate "integration-message-id")
  deriving stock (Eq, Show)

deadLetterIdText :: DeadLetterId -> Text
deadLetterIdText = \case
  QueueDeadLetter (MessageId messageId) -> Text.pack (show messageId)
  InboxDeadLetter messageId -> "keiro-inbox:" <> declarationCoordinateText messageId

-- | Bounded raw evidence. The full poison payload never enters the queue.
data PayloadEvidence = PayloadEvidence
  { byteCount :: !Int,
    sample :: ![Word8],
    truncated :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Recoverable operator evidence for an unprocessable Kafka delivery.
data DeadLetterRecord = DeadLetterRecord
  { topic :: !Text,
    partition :: !Int64,
    offset :: !Int64,
    error :: !Text,
    evidence :: !PayloadEvidence,
    recordedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data RecordDisposition
  = Enqueued
  | Duplicate
  | PermanentlyDeadLettered !DeadLetterId
  | TransientFailure !Text
  deriving stock (Eq, Show)

-- | Process a raw activity delivery. Any envelope or payload decode failure is
-- persisted before a terminal disposition is returned.
processActivityRecord ::
  Log.Logger ->
  AppEnv ->
  QueueName ->
  IncludeAgentActors ->
  [AgentDecl] ->
  (StreamHit -> IO ()) ->
  KafkaInboundRecord ->
  IO RecordDisposition
processActivityRecord logger appEnv =
  processActivityRecordWithDirectory logger appEnv Directory.disabledDirectoryHandle noStreamIntake (\_ _ _ -> pure ())

processActivityRecordWithDirectory ::
  Log.Logger ->
  AppEnv ->
  Directory.DirectoryHandle ->
  StreamIntake ->
  (Text -> Text -> Maybe Text -> IO ()) ->
  QueueName ->
  IncludeAgentActors ->
  [AgentDecl] ->
  (StreamHit -> IO ()) ->
  KafkaInboundRecord ->
  IO RecordDisposition
processActivityRecordWithDirectory logger appEnv directory intake onObservation queue include agents onHit record =
  case integrationEventFromKafka record of
    Left err -> persistPoison appEnv queue record (Text.pack (show err))
    Right (event, delivery) ->
      case decodeJsonIntegrationEvent event of
        Left err -> persistPoison appEnv queue record (Text.pack (show err))
        Right activity -> processActivity logger appEnv directory intake onObservation include agents onHit event (Just delivery) activity

-- | Process one raw public integration-event delivery.
processIntegrationEventRecord ::
  AppEnv ->
  QueueName ->
  [AgentDecl] ->
  (EventHit -> IO ()) ->
  KafkaInboundRecord ->
  IO RecordDisposition
processIntegrationEventRecord appEnv =
  processIntegrationEventRecordWithDirectory Log.silentLogger appEnv Directory.disabledDirectoryHandle noConversationChannels

-- | The channels decide which event agents take a conversation turn rather
-- than an ordinary run: those whose event type a channel serves.
processIntegrationEventRecordWithDirectory ::
  Log.Logger ->
  AppEnv ->
  Directory.DirectoryHandle ->
  ConversationChannels ->
  QueueName ->
  [AgentDecl] ->
  (EventHit -> IO ()) ->
  KafkaInboundRecord ->
  IO RecordDisposition
processIntegrationEventRecordWithDirectory logger appEnv directory channels queue agents onHit record =
  case integrationEventFromKafka record of
    Left err -> persistPoison appEnv queue record (Text.pack (show err))
    Right (event, delivery) ->
      case decodeJsonIntegrationEvent event of
        Left err -> persistPoison appEnv queue record (Text.pack (show err))
        Right payloadValue -> processIntegrationEvent logger appEnv directory channels agents onHit event (Just delivery) payloadValue

-- | Process an already decoded transport event. An invalid activity payload is
-- transient here because this broker-free entry point has no raw delivery to
-- preserve; the raw-record entry point above durably dead-letters it.
processDecodedActivity ::
  Log.Logger ->
  AppEnv ->
  IncludeAgentActors ->
  [AgentDecl] ->
  (StreamHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  IO RecordDisposition
processDecodedActivity logger appEnv =
  processDecodedActivityWithDirectory logger appEnv Directory.disabledDirectoryHandle

processDecodedActivityWithDirectory ::
  Log.Logger ->
  AppEnv ->
  Directory.DirectoryHandle ->
  IncludeAgentActors ->
  [AgentDecl] ->
  (StreamHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  IO RecordDisposition
processDecodedActivityWithDirectory logger appEnv directory =
  processDecodedActivityObserving logger appEnv directory noStreamIntake (\_ _ _ -> pure ())

-- | The broker-free entry point with observer allowances in force.
processDecodedActivityObserving ::
  Log.Logger ->
  AppEnv ->
  Directory.DirectoryHandle ->
  StreamIntake ->
  (Text -> Text -> Maybe Text -> IO ()) ->
  IncludeAgentActors ->
  [AgentDecl] ->
  (StreamHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  IO RecordDisposition
processDecodedActivityObserving logger appEnv directory intake onObservation include agents onHit event kafka =
  case decodeJsonIntegrationEvent event of
    Left err -> pure (TransientFailure (Text.pack (show err)))
    Right activity -> processActivity logger appEnv directory intake onObservation include agents onHit event kafka activity

-- | When the envelope says it happened, or this moment plus a line saying the
-- envelope did not say.
--
-- An unparseable @occurredAt@ used to become @1970-01-01T00:00:00Z@ silently,
-- which backdated the run's whole durable record by decades. Substituting the
-- receive time is the honest fallback — it is what the event-inbox path already
-- does with its @receivedAt@ — and the log line is what stops the substitution
-- from being another silence.
resolveOccurredAt :: Log.Logger -> ActivityEnvelope -> IO UTCTime
resolveOccurredAt logger activity =
  case envelopeOccurredAt activity of
    Just parsed -> pure parsed
    Nothing -> do
      now <- getCurrentTime
      Log.logError
        logger
        "stream.envelope.occurred_at_invalid"
        [ "activity_id" .= (activity ^. #activityId),
          "occurred_at" .= (activity ^. #occurredAt),
          "substituted" .= now
        ]
      pure now

processActivity ::
  Log.Logger ->
  AppEnv ->
  Directory.DirectoryHandle ->
  StreamIntake ->
  (Text -> Text -> Maybe Text -> IO ()) ->
  IncludeAgentActors ->
  [AgentDecl] ->
  (StreamHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  ActivityEnvelope ->
  IO RecordDisposition
processActivity logger appEnv directory intake onObservation include agents onHit event kafka activity = do
  -- Resolved before the transaction opens, because deciding it may need a clock
  -- and a log line and the handler runs inside Hasql.
  resolvedOccurredAt <- resolveOccurredAt logger activity
  receivedAt <- getCurrentTime
  prepared <- prepareActivityHits directory intake resolvedOccurredAt receivedAt include agents activity
  attempt <-
    Exception.try @NotifierStartError $
      runAppIO appEnv $
        runInboxTransaction Nothing PreferIntegrationMessageId event kafka (inboxHandler prepared)
  case attempt of
    Left storeStartupError -> pure (TransientFailure (Text.pack (show storeStartupError)))
    Right result -> classifyInboxResult event (reportCommitted logger "stream" onObservation onHit) result

-- | Broker-free transactional entry point for public integration events.
processDecodedIntegrationEvent ::
  AppEnv ->
  [AgentDecl] ->
  (EventHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  IO RecordDisposition
processDecodedIntegrationEvent appEnv =
  processDecodedIntegrationEventWithDirectory Log.silentLogger appEnv Directory.disabledDirectoryHandle noConversationChannels

processDecodedIntegrationEventWithDirectory ::
  Log.Logger ->
  AppEnv ->
  Directory.DirectoryHandle ->
  ConversationChannels ->
  [AgentDecl] ->
  (EventHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  IO RecordDisposition
processDecodedIntegrationEventWithDirectory logger appEnv directory channels agents onHit event kafka =
  case decodeJsonIntegrationEvent event of
    Left err -> pure (TransientFailure (Text.pack (show err)))
    Right payloadValue -> processIntegrationEvent logger appEnv directory channels agents onHit event kafka payloadValue

processIntegrationEvent ::
  Log.Logger ->
  AppEnv ->
  Directory.DirectoryHandle ->
  ConversationChannels ->
  [AgentDecl] ->
  (EventHit -> IO ()) ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  Value ->
  IO RecordDisposition
processIntegrationEvent logger appEnv directory channels agents onHit event kafka payloadValue = do
  receivedAt <- getCurrentTime
  prepared <- prepareEventHits directory channels receivedAt agents payloadValue event
  attempt <-
    Exception.try @NotifierStartError $
      runAppIO appEnv $
        runInboxTransaction Nothing PreferIntegrationMessageId event kafka (eventInboxHandler prepared)
  case attempt of
    Left storeStartupError -> pure (TransientFailure (Text.pack (show storeStartupError)))
    Right result -> classifyInboxResult event (reportCommitted logger "events" (\_ _ _ -> pure ()) onHit) result

classifyInboxResult ::
  (Show storeError, Show inboxError) =>
  IntegrationEvent ->
  (CommittedTrigger hit -> IO ()) ->
  Either storeError (Either inboxError (InboxResult [Handled hit])) ->
  IO RecordDisposition
classifyInboxResult event onHit = \case
  -- A refusal condemned the handler's transaction, so nothing here committed.
  Right (Right (InboxProcessed hits)) -> case [reason | Just reason <- map (.failure) hits] of
    reason : _ -> pure (TransientFailure reason)
    [] -> traverse_ (onHit . (.outcome)) hits >> pure Enqueued
  Right (Right InboxDuplicate) -> pure Duplicate
  Right (Right InboxInProgress) -> pure (TransientFailure "inbox row is still in progress")
  Right (Right (InboxPreviouslyFailed _)) -> pure (permanentInboxFailure event)
  Right (Right (InboxHandlerFailed _ _)) -> pure (permanentInboxFailure event)
  Right (Left inboxError) -> pure (TransientFailure (Text.pack (show inboxError)))
  Left storeError -> pure (TransientFailure (Text.pack (show storeError)))

permanentInboxFailure :: IntegrationEvent -> RecordDisposition
permanentInboxFailure event =
  PermanentlyDeadLettered (InboxDeadLetter (declarationCoordinate (event ^. #messageId)))

persistPoison :: AppEnv -> QueueName -> KafkaInboundRecord -> Text -> IO RecordDisposition
persistPoison appEnv queue KafkaInboundRecord {topic, partition, offset, payload} failure = do
  recordedAt <- getCurrentTime
  let byteCount = ByteString.length payload
      evidence =
        PayloadEvidence
          { byteCount,
            sample = ByteString.unpack (ByteString.take evidenceLimit payload),
            truncated = byteCount > evidenceLimit
          }
      deadLetter =
        DeadLetterRecord
          { topic,
            partition,
            offset,
            error = Text.take dispositionErrorLimit failure,
            evidence,
            recordedAt
          }
      send =
        Tx.statement
          SendMessage
            { queueName = queue,
              messageBody = MessageBody (Aeson.toJSON deadLetter),
              delay = Nothing
            }
          PgmqStatements.sendMessage
  attempt <- Exception.try @NotifierStartError (runAppIO appEnv (runTransaction send))
  pure $ case attempt of
    Left storeStartupError -> TransientFailure (Text.pack (show storeStartupError))
    Right (Left storeError) -> TransientFailure (Text.pack (show storeError))
    Right (Right messageId) -> PermanentlyDeadLettered (QueueDeadLetter messageId)

evidenceLimit :: Int
evidenceLimit = 256

-- | The longest error text a disposition carries to the transport.
dispositionErrorLimit :: Int
dispositionErrorLimit = 2_048

-- | The only translation from application durability to broker mechanics.
ackDecisionFor :: RecordDisposition -> AckDecision
ackDecisionFor = \case
  Enqueued -> AckOk
  Duplicate -> AckOk
  PermanentlyDeadLettered deadLetterId ->
    AckDeadLetter (ApplicationFailure permanentFailureCode ("durable dead letter " <> deadLetterIdText deadLetterId))
  TransientFailure err -> AckHalt (HaltOrderedStream (Text.take dispositionErrorLimit err))

permanentFailureCode :: DeadLetterCode
permanentFailureCode =
  case mkDeadLetterCode "shikigami.consumer_permanent" of
    Left err -> Prelude.error (Text.unpack err)
    Right code -> code

-- | Reconcile the operator-owned poison queue at startup.
ensureDeadLetterQueue :: Pool -> QueueName -> IO (Either UsageError ())
ensureDeadLetterQueue pool queue = Pool.use pool (createQueue queue)

logDisposition :: Log.Logger -> Text -> RecordDisposition -> IO ()
logDisposition logger prefix = \case
  Enqueued -> Log.logDebug logger (prefix <> ".record.enqueued") []
  Duplicate -> Log.logDebug logger (prefix <> ".record.deduped") []
  PermanentlyDeadLettered deadLetterId ->
    Log.logError logger (prefix <> ".record.dead_lettered") ["dead_letter_id" .= deadLetterIdText deadLetterId]
  TransientFailure err -> Log.logError logger (prefix <> ".record.transient_failure") ["error" .= err]

data PreparedTrigger hit
  = EnqueueTrigger !RunJob !hit
  | SkipTrigger !RunSkip
  | -- | The owning pack declined the record. Its bounded record commits and
    -- nothing is enqueued.
    SkipObservation !RunJob !Text !StreamSkip
  | -- | Worth one evaluation: a root, the pack's record and a job become one fact.
    EvaluateObservation !RunJob !hit !ExecutionRootId !Text !StreamEvaluation

data CommittedTrigger hit
  = EnqueuedTrigger !hit
  | SkippedTrigger !RunSkip
  | -- | (pack, agent, reason)
    SkippedObservation !Text !Text !Text
  | -- | A candidate's root, the pack's record and the job committed with the
    -- inbox row.
    EvaluatingObservation !Text !hit
  | -- | The pack already holds this observation, delivered under another
    -- message id: the run it funded is already owned.
    AlreadyObserved

-- | What the handler established, or why its transaction was condemned.
data Handled hit = Handled
  { outcome :: !(CommittedTrigger hit),
    failure :: !(Maybe Text)
  }

handled :: CommittedTrigger hit -> Handled hit
handled outcome = Handled {outcome, failure = Nothing}

prepareActivityHits :: Directory.DirectoryHandle -> StreamIntake -> UTCTime -> UTCTime -> IncludeAgentActors -> [AgentDecl] -> ActivityEnvelope -> IO [PreparedTrigger StreamHit]
prepareActivityHits directory intake resolvedOccurredAt receivedAt include agents activity =
  traverse
    prepare
    [ agent
    | agent <- agents,
      Just streamMatch <- [streamMatchOf agent],
      matchesStreamWith include streamMatch activity
    ]
  where
    prepare agent = do
      let job = runJobFromEnvelopeWithIdentity resolvedOccurredAt UnresolvedLegacyIdentity agent activity
          hit = StreamHit {agentName = agent ^. #name, envelope = activity}
      admitted <- prepareTrigger directory "stream" agent job hit
      observing agent admitted

    -- Applied after identity admission, so a paused agent stays a lifecycle skip
    -- and an agent no pack observes for keeps its exact job bytes.
    observing agent = \case
      prepared@(EnqueueTrigger job hit) ->
        case intake StreamCandidate {activity, agent, identity = job ^. #identity, occurredAt = resolvedOccurredAt, receivedAt} of
          Nothing -> pure prepared
          Just PackDisposition {pack, disposition} -> case disposition of
            StreamOrdinary -> pure prepared
            StreamSkipped skip -> pure (SkipObservation job pack skip)
            StreamEvaluated evaluation -> do
              root <- newExecutionRootId
              pure (EvaluateObservation job hit root pack evaluation)
      other -> pure other

-- | Queue sends and lifecycle refusals share the inbox transaction. A broker
-- offset is acknowledged only after exactly one durable effect commits.
inboxHandler :: [PreparedTrigger StreamHit] -> IntegrationEvent -> Tx.Transaction [Handled StreamHit]
inboxHandler prepared _event = traverse commitTrigger prepared

streamMatchOf :: AgentDecl -> Maybe StreamMatch
streamMatchOf agent = case agent ^. #trigger of
  Stream {match = streamMatch} -> Just streamMatch
  _ -> Nothing

prepareEventHits :: Directory.DirectoryHandle -> ConversationChannels -> UTCTime -> [AgentDecl] -> Value -> IntegrationEvent -> IO [PreparedTrigger EventHit]
prepareEventHits directory channels receivedAt agents payloadValue event =
  traverse
    prepare
    [ agent
    | agent <- agents,
      Just expectedEventType <- [eventTriggerTypeOf agent],
      expectedEventType == event ^. #eventType
    ]
  where
    prepare agent = do
      let job =
            RunJob
              { agentName = (agent ^. #name),
                identity = UnresolvedLegacyIdentity,
                triggerKind = TriggeredByEvent,
                objective = Nothing,
                repository = Nothing,
                routeKind = eventRouteOf channels agent,
                occurredAt = receivedAt,
                triggerPayload = payloadValue,
                idempotencyKey = integrationRunKey (agent ^. #name) (eventRouteOf channels agent) event,
                parentSessionId = Nothing,
                parentRunWorkflowId = Nothing,
                delegationDepth = Nothing,
                lineage = [(agent ^. #name)],
                executionRequest = Nothing,
                executionPermissions = Nothing,
                executionRootId = Nothing,
                delegationBudgetId = Nothing
              }
          hit =
            EventHit
              { agentName = agent ^. #name,
                eventType = event ^. #eventType,
                integrationMessageId = event ^. #messageId,
                payload = payloadValue
              }
      prepareTrigger directory "event" agent job hit

eventInboxHandler :: [PreparedTrigger EventHit] -> IntegrationEvent -> Tx.Transaction [Handled EventHit]
eventInboxHandler prepared _event = traverse commitTrigger prepared

prepareTrigger :: Directory.DirectoryHandle -> Text -> AgentDecl -> RunJob -> hit -> IO (PreparedTrigger hit)
prepareTrigger directory detail agent job hit = do
  let declaredPrincipalId = principalIdOf agent
  decision <- Directory.consultLifecycle directory declaredPrincipalId (agentNameText (agent ^. #name))
  pure case decision of
    Directory.AllowRun Nothing -> EnqueueTrigger ((job & #identity .~ (compatibilityIdentity (agent ^. #name)))) hit
    Directory.AllowRun (Just principal) ->
      case mkAgentPrincipal (declarationCoordinateText ((.principalId) principal)) of
        Right admittedPrincipal -> EnqueueTrigger ((job & #identity .~ (VerifiedIdentity admittedPrincipal))) hit
        Left reason -> refused (Just ((.principalId) principal)) reason
    Directory.SkipRun principal reason -> refused (Just ((.principalId) principal)) reason
    Directory.UnknownPrincipal identifier -> refused declaredPrincipalId ("unknown principal: " <> identifier)
    Directory.DirectoryUnavailable problem -> refused declaredPrincipalId ("directory unavailable: " <> problem)
  where
    refused resolvedPrincipalId reason =
      SkipTrigger
        RunSkip
          { agentName = agent ^. #name,
            principalId = (reportedPrincipalClaim . declarationCoordinateText) <$> resolvedPrincipalId,
            stage = TriggerStage,
            detail,
            reason,
            idempotencyKey = job ^. #idempotencyKey
          }

commitTrigger :: PreparedTrigger hit -> Tx.Transaction (Handled hit)
commitTrigger = \case
  EnqueueTrigger job hit -> do
    _ <- enqueueRunJobTx job
    pure (handled (EnqueuedTrigger hit))
  SkipTrigger runSkip -> do
    recordRunSkipTx runSkip
    pure (handled (SkippedTrigger runSkip))
  SkipObservation job pack skip -> do
    skip.record
    pure (handled (SkippedObservation pack (agentNameText (job ^. #agentName)) skip.reason))
  EvaluateObservation job hit root pack evaluation -> do
    let workflow = RunJob.runJobWorkflowId job
    recorded <- evaluation.alreadyOwned
    if recorded
      then pure (handled AlreadyObserved)
      else case resolveAgentIdentity (job ^. #identity) of
        Left reason -> pure (Handled AlreadyObserved (Just reason))
        Right creator ->
          allocateRootForWorkflowTx root creator (job ^. #agentName) workflow Nothing evaluation.envelope >>= \case
            -- The allocation condemned the transaction; report it as a failure so
            -- the offset does not advance past a record nothing was committed for.
            Left refusal -> pure (Handled AlreadyObserved (Just ("evaluation root refused: " <> Text.pack (show refusal))))
            Right allocated -> do
              evaluation.record workflow
              _ <- enqueueRunJobTx (job & #executionRootId .~ Just allocated)
              pure (handled (EvaluatingObservation pack hit))

reportCommitted :: Log.Logger -> Text -> (Text -> Text -> Maybe Text -> IO ()) -> (hit -> IO ()) -> CommittedTrigger hit -> IO ()
reportCommitted logger prefix onObservation onHit = \case
  EnqueuedTrigger hit -> onHit hit
  AlreadyObserved -> pure ()
  EvaluatingObservation pack hit -> do
    onObservation pack "evaluating" Nothing
    onHit hit
  SkippedObservation pack agentName reason -> do
    onObservation pack "skipped" (Just reason)
    Log.logInfo logger (prefix <> ".observation.skipped") ["pack" .= pack, "agent" .= agentName, "reason" .= reason]
  SkippedTrigger RunSkip {agentName, principalId, detail, reason, idempotencyKey} ->
    Log.logInfo
      logger
      (prefix <> ".trigger.skipped")
      [ "agent" .= agentName,
        "principal_id" .= principalId,
        "detail" .= detail,
        "reason" .= reason,
        Log.runIdKey .= idempotencyKey
      ]

principalIdOf :: AgentDecl -> Maybe (DeclarationCoordinate "principal")
principalIdOf AgentDecl {identity} = declared <$> identity
  where
    declared IdentityDecl {principal} = principal

eventTriggerTypeOf :: AgentDecl -> Maybe Text
eventTriggerTypeOf agent = case agent ^. #trigger of
  Event {eventType} -> Just (declarationCoordinateText eventType)
  _ -> Nothing

-- | The declared event type is the honest source of the conversation/agent-run
-- distinction: an agent that subscribes to an event type a conversation
-- channel serves (Danwa's @danwa.message-addressed-to-agent@, under the Kikan
-- distribution) is asking for a conversation turn, and every other event
-- trigger is an ordinary agent run. Deciding here, where the declaration is in
-- scope, is what lets the worker stop guessing from the payload's shape.
eventRouteOf :: ConversationChannels -> AgentDecl -> RunRouteKind
eventRouteOf channels agent
  | Just _ <- channelForAgent channels agent = ConversationWorkflowRoute
  | otherwise = AgentWorkflowRoute
