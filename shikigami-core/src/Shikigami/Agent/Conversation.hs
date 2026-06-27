module Shikigami.Agent.Conversation
  ( ConversationEnv (..),
    ConversationTurnResult (..),
    conversationRegistry,
    conversationWorkflowId,
    conversationWorkflowName,
    deliverConversationInput,
    deliverConversationInputFromApp,
    runConversationTurn,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Bifunctor (first)
import Data.Foldable (traverse_)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Keiro.Command (defaultRunCommandOptions, runCommandWithSqlEvents)
import Keiro.Projection (InlineProjection (InlineProjection, apply))
import Keiro.Workflow
  ( StepName (..),
    Workflow,
    WorkflowId (..),
    WorkflowName (..),
    WorkflowOutcome (..),
    awakeableAllocStepPrefix,
    loadStepIndex,
    runWorkflow,
    step,
  )
import Keiro.Workflow.Awakeable (AwakeableId, signalAwakeable)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Kioku.App (AppEffects, AppEnv (..), runAppIO)
import Kioku.Distill.Timer (l1TimerScheduleProjection)
import Kioku.Id (SessionId, genSessionId, idText, parseId)
import Kioku.Session qualified as Session
import Kioku.Session.Domain (RecordTurnData (..), SessionCommand (..), StartSessionData (..))
import Kioku.Session.EventStream (sessionEventStream, sessionStream)
import Kioku.Session.ReadModel (SessionRow (..), TurnRow (..), sessionInlineProjection)
import Kiroku.Store.Effect (Store, runStorePool)
import Kiroku.Store.Error (StoreError)
import Shibuya.Telemetry.Effect (runTracing)
import Shikigami.Agent.Run (renderLearning)
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Agent.Workflow.Input (awaitInput)
import Shikigami.Api.Agent (AgentDecl (..))
import Shikigami.Api.Agent qualified as Agent
import Shikigami.Behavior.Run (BehaviorEnv, runBehavior)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Prelude
import Shikigami.Sink.Config (DanwaConfig)
import Shikigami.Sink.Types (DanwaTarget (..), SinkOutcome (Delivered), SinkResult (..))
import Shikigami.Trigger.Danwa (AddressedMessage (..))

data ConversationEnv = ConversationEnv
  { appEnv :: !AppEnv,
    behaviorEnv :: !BehaviorEnv,
    danwa :: !DanwaConfig,
    agents :: ![AgentDecl]
  }

data ConversationTurnResult = ConversationTurnResult
  { sessionId :: !SessionId,
    userTurnId :: !Text,
    asstTurnId :: !Text,
    replyMessageId :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ConversationStart = ConversationStart
  { agentName :: !Text,
    initialMessage :: !AddressedMessage
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data RecordedTurn = RecordedTurn
  { turnId :: !Text,
    turnIndex :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

conversationWorkflowName :: WorkflowName
conversationWorkflowName = WorkflowName "shikigami.danwa-conversation"

conversationWorkflowId :: AddressedMessage -> WorkflowId
conversationWorkflowId AddressedMessage {conversationId} =
  WorkflowId ("danwa-conversation:" <> conversationId)

runConversationTurn :: ConversationEnv -> AgentDecl -> AddressedMessage -> IO (Either Text ConversationTurnResult)
runConversationTurn env decl msg = do
  delivered <- deliverConversationInput env msg
  outcomeE <- runConversationWorkflow env (if delivered then Nothing else Just (ConversationStart (name decl) msg)) msg
  case outcomeE of
    Left err -> pure (Left (Text.pack (show err)))
    Right Failed -> pure (Left "conversation workflow failed")
    Right Cancelled -> pure (Left "conversation workflow cancelled")
    Right ContinuedAsNew -> pure (Left "conversation workflow continued as new unexpectedly")
    Right (Completed result) -> pure (Right result)
    Right Suspended -> do
      loaded <- loadConversationResult env (conversationWorkflowId msg) (messageId msg)
      pure case loaded of
        Just result -> Right result
        Nothing -> Left ("conversation workflow suspended before recording turn result for " <> messageId msg)

conversationRegistry :: ConversationEnv -> WorkflowRegistry AppEffects
conversationRegistry env =
  Map.singleton conversationWorkflowName (WorkflowDef \_wid -> conversationWorkflow env Nothing)

conversationWorkflow ::
  ConversationEnv ->
  Maybe ConversationStart ->
  Eff (Workflow : AppEffects) ConversationTurnResult
conversationWorkflow env mStart = do
  start <- step (StepName "ingest-start") (ingestStart mStart)
  decl <- resolveDeclStep env start
  firstResult <- processTurn env decl (initialMessage start)
  loop env decl 1 firstResult

ingestStart :: (IOE :> es) => Maybe ConversationStart -> Eff es ConversationStart
ingestStart = \case
  Just start -> pure start
  Nothing -> liftIO (ioError (userError "danwa conversation workflow resumed before ingest-start was journaled"))

resolveDeclStep :: ConversationEnv -> ConversationStart -> Eff (Workflow : AppEffects) AgentDecl
resolveDeclStep env ConversationStart {agentName} =
  step (StepName "lookup-agent") do
    case find ((== agentName) . name) (agents env) of
      Just decl -> pure decl
      Nothing -> liftIO (ioError (userError ("unknown conversation agent " <> Text.unpack agentName)))

loop ::
  ConversationEnv ->
  AgentDecl ->
  Int ->
  ConversationTurnResult ->
  Eff (Workflow : AppEffects) ConversationTurnResult
loop env decl nextOrdinal _previous = do
  nextMessage <- awaitInput (nextMessageStepName nextOrdinal)
  result <- processTurn env decl nextMessage
  loop env decl (nextOrdinal + 1) result

processTurn ::
  ConversationEnv ->
  AgentDecl ->
  AddressedMessage ->
  Eff (Workflow : AppEffects) ConversationTurnResult
processTurn env decl msg@AddressedMessage {conversationId = msgConversationId, messageId = msgMessageId, content = msgContent} = do
  sid <- step (StepName "resolve-session") (liftIO (requireRight =<< resolveSession env decl msgConversationId))
  userTurn <-
    step (StepName ("record-user:" <> msgMessageId)) $
      liftIO do
        turns <- loadTurns env sid
        recordTurnOnce env sid ("danwa:user:" <> msgMessageId) Nothing "user" msgContent turns
  outputE <-
    step (StepName ("run-behavior:" <> msgMessageId)) do
      prior <- liftIO (loadTurns env sid)
      liftIO (first (Text.pack . show) <$> runBehavior (behaviorEnv env) decl (behaviorPayload msg prior))
  output <- either (liftIO . ioError . userError . Text.unpack) pure outputE
  let replyText = renderLearning output
  (asstTurn, sinkResult) <-
    step (assistantReplyStepName msgMessageId) do
      turns <- liftIO (loadTurns env sid)
      let RecordedTurn {turnIndex = userTurnIndex} = userTurn
      assistantAndReplyE <- recordAssistantTurnAndEnqueueReply decl sid msg replyText userTurnIndex turns
      either (liftIO . ioError . userError . Text.unpack) pure assistantAndReplyE
  let replyMessageId = sinkResultDetail sinkResult
      RecordedTurn {turnId = recordedUserTurnId} = userTurn
      RecordedTurn {turnId = recordedAsstTurnId} = asstTurn
      result =
        ConversationTurnResult
          { sessionId = sid,
            userTurnId = recordedUserTurnId,
            asstTurnId = recordedAsstTurnId,
            replyMessageId
          }
  step (turnResultStepName msgMessageId) (pure result)

runConversationWorkflow ::
  ConversationEnv ->
  Maybe ConversationStart ->
  AddressedMessage ->
  IO (Either StoreError (WorkflowOutcome ConversationTurnResult))
runConversationWorkflow env mStart msg =
  let AppEnv {store, tracer} = appEnv env
   in runEff
        . runTracing tracer
        . runErrorNoCallStack
        . runStorePool store
        $ runWorkflow
          conversationWorkflowName
          (conversationWorkflowId msg)
          (conversationWorkflow env mStart)

deliverConversationInput :: ConversationEnv -> AddressedMessage -> IO Bool
deliverConversationInput env = deliverConversationInputFromApp (appEnv env)

deliverConversationInputFromApp :: AppEnv -> AddressedMessage -> IO Bool
deliverConversationInputFromApp appEnv' msg = do
  result <- runAppIO appEnv' do
    stepIndex <- loadStepIndex conversationWorkflowName (conversationWorkflowId msg) 0
    let aids = pendingInputAids stepIndex
    signalFirst msg aids
  pure case result of
    Right delivered -> delivered
    Left _ -> False

pendingInputAids :: Map.Map Text Value -> [AwakeableId]
pendingInputAids stepIndex =
  mapMaybe parseAid $
    filter (Text.isPrefixOf (awakeableAllocStepPrefix <> "next-message:")) (Map.keys stepIndex)
  where
    parseAid key =
      Map.lookup key stepIndex >>= parseMaybe Aeson.parseJSON

signalFirst :: (Store :> es, IOE :> es, ToJSON a) => a -> [AwakeableId] -> Eff es Bool
signalFirst value = \case
  [] -> pure False
  aid : rest ->
    signalAwakeable aid value >>= \case
      True -> pure True
      False -> signalFirst value rest

loadConversationResult :: ConversationEnv -> WorkflowId -> Text -> IO (Maybe ConversationTurnResult)
loadConversationResult env workflowId msgMessageId = do
  result <- runAppIO (appEnv env) (loadStepIndex conversationWorkflowName workflowId 0)
  pure case result of
    Right stepIndex -> Map.lookup (unStepName (turnResultStepName msgMessageId)) stepIndex >>= parseMaybe Aeson.parseJSON
    Left _ -> Nothing

nextMessageStepName :: Int -> StepName
nextMessageStepName ordinal =
  StepName ("next-message:" <> Text.pack (show ordinal))

turnResultStepName :: Text -> StepName
turnResultStepName msgMessageId =
  StepName ("turn-result:" <> msgMessageId)

assistantReplyStepName :: Text -> StepName
assistantReplyStepName msgMessageId =
  StepName ("record-assistant-and-reply:" <> msgMessageId)

replySinkStepName :: Text -> StepName
replySinkStepName msgMessageId =
  StepName ("danwa-reply:" <> msgMessageId)

behaviorPayload :: AddressedMessage -> [TurnRow] -> Value
behaviorPayload AddressedMessage {conversationId = msgConversationId, messageId = msgMessageId, author = msgAuthor, content = msgContent, agentParticipant = msgAgentParticipant} priorTurns =
  Aeson.object
    [ "conversationId" Aeson..= msgConversationId,
      "messageId" Aeson..= msgMessageId,
      "author" Aeson..= msgAuthor,
      "content" Aeson..= msgContent,
      "agentParticipant" Aeson..= msgAgentParticipant,
      "turns" Aeson..= fmap turnPayload priorTurns
    ]

turnPayload :: TurnRow -> Value
turnPayload TurnRow {turnIndex, role, content} =
  Aeson.object
    [ "turnIndex" Aeson..= turnIndex,
      "role" Aeson..= role,
      "content" Aeson..= content
    ]

resolveSession :: ConversationEnv -> AgentDecl -> Text -> IO (Either Text SessionId)
resolveSession env decl conversationId = do
  let scope = agentScope (name decl)
  rowsE <- runKioku env (Session.getByScope scope)
  case rowsE of
    Left err -> pure (Left (Text.pack (show err)))
    Right (Left err) -> pure (Left (Text.pack (show err)))
    Right (Right rows) ->
      case find (isRunningConversationSession conversationId) rows of
        Just (SessionRow {sessionId = sidText}) -> pure (first ("parse session id: " <>) (parseId sidText))
        Nothing -> startSession env decl conversationId

isRunningConversationSession :: Text -> SessionRow -> Bool
isRunningConversationSession conversationId (SessionRow {subjectRef = rowSubjectRef, status = rowStatus}) =
  rowSubjectRef == Just conversationId && rowStatus == "running"

startSession :: ConversationEnv -> AgentDecl -> Text -> IO (Either Text SessionId)
startSession env decl conversationId = do
  now <- getCurrentTime
  sid <- genSessionId
  result <-
    runKioku env $
      Session.start
        StartSessionData
          { sessionId = sid,
            agentId = name decl,
            focus = "conversation",
            scope = agentScope (name decl),
            subjectRef = Just conversationId,
            previousSessionId = Nothing,
            parentSessionId = Nothing,
            delegationDepth = 0,
            startedAt = now
          }
  pure case result of
    Left err -> Left (Text.pack (show err))
    Right (Left err) -> Left (Text.pack (show err))
    Right (Right _) -> Right sid

loadTurns :: ConversationEnv -> SessionId -> IO [TurnRow]
loadTurns env sid = do
  result <- runKioku env (Session.getTurns sid)
  pure case result of
    Right (Right turns) -> turns
    _ -> []

recordTurnOnce :: ConversationEnv -> SessionId -> Text -> Maybe Int -> Text -> Text -> [TurnRow] -> IO RecordedTurn
recordTurnOnce env sid turnId desiredIndex role content turns =
  case find (\TurnRow {turnId = existingTurnId} -> existingTurnId == turnId) turns of
    Just TurnRow {turnIndex} -> pure RecordedTurn {turnId, turnIndex}
    Nothing -> do
      let turnIndex = fromMaybe (length turns) desiredIndex
      requireRight =<< recordTurn env sid turnId turnIndex role content
      pure RecordedTurn {turnId, turnIndex}

recordAssistantTurnAndEnqueueReply ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  AgentDecl ->
  SessionId ->
  AddressedMessage ->
  Text ->
  Int ->
  [TurnRow] ->
  Eff es (Either Text (RecordedTurn, SinkResult))
recordAssistantTurnAndEnqueueReply decl sid msg@AddressedMessage {messageId = msgMessageId} replyText userTurnIndex turns =
  case find (\TurnRow {turnId = existingTurnId} -> existingTurnId == turnId) turns of
    Just TurnRow {turnIndex = existingTurnIndex} -> do
      now <- liftIO getCurrentTime
      prepared <- liftIO (prepareConversationReplySinkIntent decl sid msg replyText now)
      pure (Right (RecordedTurn {turnId, turnIndex = existingTurnIndex}, AgentWorkflow.preparedSinkResult prepared))
    Nothing -> do
      now <- liftIO getCurrentTime
      prepared <- liftIO (prepareConversationReplySinkIntent decl sid msg replyText now)
      existing <- Session.getById sid
      case existing of
        Left err -> pure (Left (Text.pack (show err)))
        Right Nothing -> pure (Left "SessionNotFound")
        Right (Just SessionRow {status = rowStatus})
          | rowStatus /= "running" -> pure (Left "SessionNotRunning")
          | otherwise -> appendAssistantTurn now prepared
  where
    turnId = "danwa:assistant:" <> msgMessageId
    turnIndex = userTurnIndex + 1

    appendAssistantTurn recordedAt prepared = do
      commandResult <-
        runCommandWithSqlEvents
          defaultRunCommandOptions
          sessionEventStream
          (sessionStream sid)
          ( RecordTurn
              RecordTurnData
                { sessionId = sid,
                  turnId,
                  turnIndex,
                  role = "assistant",
                  content = replyText,
                  toolSummary = Nothing,
                  promptTokens = Nothing,
                  outputTokens = Nothing,
                  recordedAt
                }
          )
          ( \pairs _appendResult -> do
              applyInlineProjections pairs [sessionInlineProjection, l1TimerScheduleProjection]
              AgentWorkflow.enqueuePreparedSinkIntentTx prepared
          )
      pure case commandResult of
        Left err -> Left (Text.pack (show err))
        Right _ -> Right (RecordedTurn {turnId, turnIndex}, AgentWorkflow.preparedSinkResult prepared)

    applyInlineProjections pairs projections =
      traverse_
        ( \InlineProjection {apply = applyProjection} ->
            traverse_ (uncurry applyProjection) pairs
        )
        projections

prepareConversationReplySinkIntent ::
  AgentDecl ->
  SessionId ->
  AddressedMessage ->
  Text ->
  UTCTime ->
  IO AgentWorkflow.PreparedSinkIntent
prepareConversationReplySinkIntent decl sid msg@AddressedMessage {conversationId = msgConversationId, messageId = msgMessageId} replyText now =
  AgentWorkflow.prepareSinkIntent
    (conversationWorkflowId msg)
    (replySinkStepName msgMessageId)
    (name decl)
    (idText sid)
    0
    Nothing
    ( Just
        DanwaTarget
          { conversationId = msgConversationId,
            parentMessageId = Just msgMessageId
          }
    )
    Agent.DanwaConversation {Agent.topic = "danwa-conversation"}
    (Aeson.object ["reply" Aeson..= replyText])
    now

recordTurn :: ConversationEnv -> SessionId -> Text -> Int -> Text -> Text -> IO (Either Text ())
recordTurn env sid turnId turnIndex role content = do
  now <- getCurrentTime
  result <-
    runKioku env $
      Session.recordTurn
        RecordTurnData
          { sessionId = sid,
            turnId,
            turnIndex,
            role,
            content,
            toolSummary = Nothing,
            promptTokens = Nothing,
            outputTokens = Nothing,
            recordedAt = now
          }
  pure case result of
    Left err -> Left (Text.pack (show err))
    Right (Left err) -> Left (Text.pack (show err))
    Right (Right _) -> Right ()

runKioku :: ConversationEnv -> Eff AppEffects a -> IO (Either StoreError a)
runKioku env action = runAppIO (appEnv env) action

requireRight :: Either Text a -> IO a
requireRight = \case
  Right value -> pure value
  Left err -> ioError (userError (Text.unpack err))

sinkResultDetail :: SinkResult -> Text
sinkResultDetail SinkResult {outcome = Delivered detail} = detail
sinkResultDetail SinkResult {outcome = other} = Text.pack (show other)
