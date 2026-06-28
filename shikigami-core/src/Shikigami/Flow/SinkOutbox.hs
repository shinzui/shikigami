module Shikigami.Flow.SinkOutbox
  ( enqueueSinkIntentStep,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.Foldable (traverse_)
import Data.Text qualified as Text
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, liftIO, (:>))
import Hasql.Transaction qualified as Tx
import Keiro.Integration.Event (IntegrationContentType (ApplicationJson), IntegrationEvent (..), encodeJsonIntegrationEvent)
import Keiro.Outbox (OutboxId (..), OutboxMessage (..), enqueueOutboxTx)
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
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Api.Agent (Sink)
import Shikigami.Prelude
import Shikigami.Sink (DanwaTarget, SinkOutcome (..), SinkResult (..), checkGrant, sinkKindOf)
import Shikigami.Sink.Permission (AgentIdentity (AgentIdentity), Denied (..))

data SinkIntent = SinkIntent
  { agent :: !Text,
    runId :: !Text,
    ordinal :: !Int,
    occurredAt :: !(Maybe UTCTime),
    danwaTarget :: !(Maybe DanwaTarget),
    sink :: !Sink,
    output :: !Value
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data PreparedSinkIntent = PreparedSinkIntent
  { sinkResult :: !SinkResult,
    outboxMessage :: !(Maybe OutboxMessage)
  }

enqueueSinkIntentStep ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  StepName ->
  Text ->
  Text ->
  Int ->
  Maybe UTCTime ->
  Maybe DanwaTarget ->
  Sink ->
  Value ->
  Eff es SinkResult
enqueueSinkIntentStep stepName agentName' runIdText ordinal occurredAt' danwaTarget' sink output = do
  (workflowName, workflowId) <- currentWorkflow
  generation <- currentRunGeneration
  now <- liftIO getCurrentTime
  prepared <- liftIO (prepareSinkIntent workflowId stepName agentName' runIdText ordinal occurredAt' danwaTarget' sink output now)
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
      JournalAppendConflict err ->
        pure (Left ("sink intent journal append conflict: " <> Text.pack (show err)))
  case txResult of
    Right result' -> pure result'
    Left err -> liftIO (ioError (userError (Text.unpack err)))

prepareSinkIntent ::
  WorkflowId ->
  StepName ->
  Text ->
  Text ->
  Int ->
  Maybe UTCTime ->
  Maybe DanwaTarget ->
  Sink ->
  Value ->
  UTCTime ->
  IO PreparedSinkIntent
prepareSinkIntent workflowId stepName agentName' runIdText ordinal occurredAt' danwaTarget' sink output now = do
  let kind = sinkKindOf sink
      messageId = unWorkflowId workflowId <> ":" <> unStepName stepName
      outboxId = deterministicOutboxIdForMessage messageId
      deniedResult reason = SinkResult kind (DeniedOutcome reason)
      deliveredResult = SinkResult kind (Delivered ("outbox:" <> messageId))
  checkGrant (AgentIdentity agentName') kind <&> \case
    Left (Denied reason) ->
      PreparedSinkIntent
        { sinkResult = deniedResult reason,
          outboxMessage = Nothing
        }
    Right () ->
      let intent =
            SinkIntent
              { agent = agentName',
                runId = runIdText,
                ordinal,
                occurredAt = occurredAt',
                danwaTarget = danwaTarget',
                sink,
                output
              }
          event = sinkIntentEvent messageId runIdText now intent
       in PreparedSinkIntent
            { sinkResult = deliveredResult,
              outboxMessage = Just (OutboxMessage outboxId event)
            }

preparedSinkResult :: PreparedSinkIntent -> SinkResult
preparedSinkResult PreparedSinkIntent {sinkResult} = sinkResult

enqueuePreparedSinkIntentTx :: PreparedSinkIntent -> Tx.Transaction ()
enqueuePreparedSinkIntentTx PreparedSinkIntent {outboxMessage} =
  traverse_ enqueueOutboxTx outboxMessage

sinkIntentEvent :: Text -> Text -> UTCTime -> SinkIntent -> IntegrationEvent
sinkIntentEvent messageId runId occurredAt intent =
  encodeJsonIntegrationEvent
    IntegrationEvent
      { messageId,
        source = "shinzui/shikigami",
        destination = "shikigami.sink.v1",
        key = Just runId,
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
        traceContext = Nothing,
        attributes = Nothing
      }
    intent

deterministicOutboxIdForMessage :: Text -> OutboxId
deterministicOutboxIdForMessage messageId =
  OutboxId $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      fmap (fromIntegral . fromEnum) $
        Text.unpack ("shikigami:sink:" <> messageId)
