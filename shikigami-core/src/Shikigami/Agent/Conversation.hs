module Shikigami.Agent.Conversation
  ( ConversationEnv (..),
    ConversationTurnFailure (..),
    conversationTurnFailureDetail,
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
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Keiro.Command (defaultRunCommandOptions, runCommandWithSqlEvents)
import Keiro.Projection (InlineProjection (InlineProjection, apply))
import Keiro.Workflow
  ( PatchId (..),
    StepName (..),
    Workflow,
    WorkflowId (..),
    WorkflowName (..),
    WorkflowOutcome (..),
    awakeableAllocStepPrefix,
    currentGeneration,
    loadStepIndex,
    patch,
    runWorkflowWith,
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
import Kiroku.Store.Effect (Store, runStoreResource)
import Kiroku.Store.Effect.Resource (KirokuStoreResource, withKirokuStore)
import Kiroku.Store.Error (StoreError)
import Shibuya.Telemetry.Effect (runTracing)
import Shikigami.Agent.Conversation.SessionIndex qualified as SessionIndex
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Decl qualified as Agent
import Shikigami.Agent.Run (renderLearning)
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Agent.Workflow.Input (awaitInput)
import Shikigami.Behavior.Run (BehaviorEnv, runBehavior, runBehaviorAttempt, triggerOnly)
import Shikigami.DanwaConversation.Generated.WorkflowRuntime qualified as ConversationGenerated
import Shikigami.Integration.Danwa (AddressedMessage (..))
import Shikigami.Memory.Access (agentActor, shikigamiMemorySpace)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Prelude
import Shikigami.Sink.Config (DanwaConfig)
import Shikigami.Sink.GrantStore (GrantSource)
import Shikigami.Sink.Types (DanwaTarget (..), SinkOutcome (Delivered), SinkResult (..))
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)

data ConversationEnv = ConversationEnv
  { appEnv :: !AppEnv,
    behaviorEnv :: !BehaviorEnv,
    runTimeout :: !NominalDiffTime,
    danwa :: !DanwaConfig,
    agents :: ![AgentDecl],
    -- | Which grant source the conversation reply's C11 check consults.
    grants :: !GrantSource
  }

conversationRunTimeout :: ConversationEnv -> NominalDiffTime
conversationRunTimeout ConversationEnv {runTimeout = timeout} = timeout

data ConversationTurnResult = ConversationTurnResult
  { sessionId :: !SessionId,
    userTurnId :: !Text,
    asstTurnId :: !Text,
    replyMessageId :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ConversationTurnFailure
  = ConversationPermanentFailure !Text
  | ConversationTransientFailure !Text
  | ConversationTerminalFailure !Text
  deriving stock (Eq, Show)

conversationTurnFailureDetail :: ConversationTurnFailure -> Text
conversationTurnFailureDetail = \case
  ConversationPermanentFailure detail -> detail
  ConversationTransientFailure detail -> detail
  ConversationTerminalFailure detail -> detail

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

-- | The literal lives in @domain\/shikigami-conversation.keiro@ and reaches
-- Haskell through the generated
-- "Shikigami.DanwaConversation.Generated.WorkflowRuntime", so a rename has
-- exactly one place to happen and is gated by @keiro-dsl diff@.
conversationWorkflowName :: WorkflowName
conversationWorkflowName = ConversationGenerated.workflowName

conversationWorkflowId :: AddressedMessage -> WorkflowId
conversationWorkflowId AddressedMessage {conversationId} =
  WorkflowId ("danwa-conversation:" <> conversationId)

runConversationTurn :: ConversationEnv -> AgentDecl -> AddressedMessage -> IO (Either ConversationTurnFailure ConversationTurnResult)
runConversationTurn env decl msg = do
  delivered <- deliverConversationInput env msg
  outcomeE <- runConversationWorkflow env (if delivered then Nothing else Just (ConversationStart (name decl) msg)) msg
  case outcomeE of
    Left err -> pure (Left (ConversationTransientFailure (Text.pack (show err))))
    Right Failed -> pure (Left (ConversationTerminalFailure "conversation workflow failed"))
    Right Cancelled -> pure (Left (ConversationTerminalFailure "conversation workflow cancelled"))
    Right ContinuedAsNew -> pure (Left (ConversationTerminalFailure "conversation workflow continued as new unexpectedly"))
    Right (Completed result) -> pure (first ConversationPermanentFailure result)
    Right Suspended -> do
      loaded <- loadConversationResult env (conversationWorkflowId msg) (messageId msg)
      pure case loaded of
        Just result -> Right result
        Nothing -> Left (ConversationTransientFailure ("conversation workflow suspended before recording turn result for " <> messageId msg))

conversationRegistry :: ConversationEnv -> WorkflowRegistry AppEffects
conversationRegistry env =
  Map.singleton conversationWorkflowName (WorkflowDef \_wid -> conversationWorkflow env Nothing)

conversationWorkflow ::
  ConversationEnv ->
  Maybe ConversationStart ->
  Eff (Workflow : AppEffects) (Either Text ConversationTurnResult)
conversationWorkflow env mStart = do
  start <- step (StepName "ingest-start") (ingestStart mStart)
  decl <- resolveDeclStep env start
  firstResult <- processTurn env decl (initialMessage start)
  case firstResult of
    Left err -> pure (Left err)
    Right result -> loop env decl 1 result

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
  Eff (Workflow : AppEffects) (Either Text ConversationTurnResult)
loop env decl nextOrdinal _previous = do
  nextMessage <- awaitInput (nextMessageStepName nextOrdinal)
  result <- processTurn env decl nextMessage
  case result of
    Left err -> pure (Left err)
    Right completed -> loop env decl (nextOrdinal + 1) completed

processTurn ::
  ConversationEnv ->
  AgentDecl ->
  AddressedMessage ->
  Eff (Workflow : AppEffects) (Either Text ConversationTurnResult)
processTurn env decl msg@AddressedMessage {conversationId = msgConversationId, messageId = msgMessageId, content = msgContent} = do
  sid <- step (StepName "resolve-session") (liftIO (requireRight =<< resolveSession env decl msgConversationId))
  userTurn <-
    step (StepName ("record-user:" <> msgMessageId)) $
      liftIO do
        turns <- loadTurns env sid
        recordTurnOnce env decl sid ("danwa:user:" <> msgMessageId) Nothing "user" msgContent turns
  useRetrySemantics <- patch behaviorRetryPatch
  outputE <-
    if useRetrySemantics
      then step (StepName ("run-behavior-v2:" <> msgMessageId)) do
        prior <- liftIO (loadTurns env sid)
        liftIO
          ( runBehaviorAttempt
              (conversationRunTimeout env)
              (behaviorEnv env)
              decl
              (triggerOnly (behaviorPayload msg prior))
          )
      else do
        legacy <-
          step (StepName ("run-behavior:" <> msgMessageId)) do
            prior <- liftIO (loadTurns env sid)
            -- No recalled memories: a conversation turn's context is the turn
            -- history, and that already travels inside the payload.
            liftIO (first (Text.pack . show) <$> runBehavior (behaviorEnv env) decl (triggerOnly (behaviorPayload msg prior)))
        Right <$> either (liftIO . ioError . userError . Text.unpack) pure legacy
  case outputE of
    Left err -> pure (Left err)
    Right output -> do
      let replyText = renderLearning output
      (asstTurn, sinkResult) <-
        step (assistantReplyStepName msgMessageId) do
          turns <- liftIO (loadTurns env sid)
          let RecordedTurn {turnIndex = userTurnIndex} = userTurn
          assistantAndReplyE <- recordAssistantTurnAndEnqueueReply (grants env) decl sid msg replyText userTurnIndex turns
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
      Right <$> step (turnResultStepName msgMessageId) (pure result)

behaviorRetryPatch :: PatchId
behaviorRetryPatch = PatchId "shikigami-behavior-retry-v1"

runConversationWorkflow ::
  ConversationEnv ->
  Maybe ConversationStart ->
  AddressedMessage ->
  IO (Either StoreError (WorkflowOutcome (Either Text ConversationTurnResult)))
runConversationWorkflow env mStart msg =
  let AppEnv {connectionSettings, tracer} = appEnv env
   in runEff
        . runTracing tracer
        . runErrorNoCallStack
        . withKirokuStore connectionSettings
        . runStoreResource
        $ runWorkflowWith
          shikigamiWorkflowRunOptions
          conversationWorkflowName
          (conversationWorkflowId msg)
          (conversationWorkflow env mStart)

deliverConversationInput :: ConversationEnv -> AddressedMessage -> IO Bool
deliverConversationInput env = deliverConversationInputFromApp (appEnv env)

-- | Signal the live @next-message@ awakeable, if one is armed.
--
-- __The generation is resolved, never assumed.__ This read used to pass a
-- literal @0@, which was correct only because nothing rotated the journal. An
-- awakeable id is allocated fresh in each generation and journaled under
-- @awkid:next-message@ in /that/ generation's step index, so once
-- 'continueAsNew' moves the conversation to generation 1 a generation-0 read
-- finds the previous generation's abandoned id and signals something nobody is
-- awaiting.
deliverConversationInputFromApp :: AppEnv -> AddressedMessage -> IO Bool
deliverConversationInputFromApp appEnv' msg = do
  result <- runAppIO appEnv' do
    let wid = conversationWorkflowId msg
    generation <- currentGeneration conversationWorkflowName wid
    stepIndex <- loadStepIndex conversationWorkflowName wid generation
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

-- | Read a turn result back out of the journal, from the live generation.
--
-- Same latent bug as 'deliverConversationInputFromApp' had: the literal @0@ was
-- right only while nothing rotated.
loadConversationResult :: ConversationEnv -> WorkflowId -> Text -> IO (Maybe ConversationTurnResult)
loadConversationResult env workflowId msgMessageId = do
  result <- runAppIO (appEnv env) do
    generation <- currentGeneration conversationWorkflowName workflowId
    loadStepIndex conversationWorkflowName workflowId generation
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
behaviorPayload AddressedMessage {conversationId = msgConversationId, messageId = msgMessageId, author = msgAuthor, content = msgContent, agentParticipantId = msgAgentParticipantId} priorTurns =
  Aeson.object
    [ "conversationId" Aeson..= msgConversationId,
      "messageId" Aeson..= msgMessageId,
      "author" Aeson..= msgAuthor,
      "content" Aeson..= msgContent,
      "agentParticipantId" Aeson..= msgAgentParticipantId,
      "turns" Aeson..= fmap turnPayload priorTurns
    ]

turnPayload :: TurnRow -> Value
turnPayload TurnRow {turnIndex, role, content} =
  Aeson.object
    [ "turnIndex" Aeson..= turnIndex,
      "role" Aeson..= role,
      "content" Aeson..= content
    ]

-- | Which kioku session this conversation is being recorded into.
--
-- __Keyed, not scanned.__ This used to ask kioku for every session the agent had
-- ever had ('Session.getByScope') and then linearly scan for one whose
-- @subjectRef@ matched — O(sessions per agent) on every turn, over a set that
-- only grows because nothing ever completed a session. It now asks
-- @shikigami.conversation_sessions@ for this one conversation's session id.
--
-- Kioku remains the authority. The index answers with an id and kioku is still
-- asked to produce the row, so a stale or wrong pointer can only cause a miss —
-- it can never invent a session that does not exist.
--
-- Three arms, in cost order:
--
-- 1. The index hits and kioku confirms a running session for this conversation.
--    That is the routine case and the only one a healthy conversation takes.
-- 2. The index misses, or points at something that is no longer this
--    conversation's running session, so the old scan runs and __backfills the
--    index__ if it finds one. This is what repairs a session started before the
--    index existed, and a session whose index write was lost to a crash between
--    the two transactions.
-- 3. Nothing exists, so a session is started (which writes the index).
resolveSession :: ConversationEnv -> AgentDecl -> Text -> IO (Either Text SessionId)
resolveSession env decl conversationId = do
  indexedE <- runKioku env (SessionIndex.lookupConversationSession conversationId)
  case indexedE of
    Left err -> pure (Left (Text.pack (show err)))
    Right indexed -> do
      confirmed <- maybe (pure Nothing) (confirmIndexedSession env conversationId) indexed
      case confirmed of
        Just sid -> pure (Right sid)
        Nothing -> scanForConversationSession env decl conversationId

-- | Re-read an indexed pointer through kioku before trusting it.
--
-- Every way this can disagree with kioku — an unparseable id, a session that was
-- deleted, one that belongs to a different conversation, one that is no longer
-- running — resolves to 'Nothing', which sends the caller to the scan. The index
-- is never allowed to be the reason a turn fails.
confirmIndexedSession :: ConversationEnv -> Text -> Text -> IO (Maybe SessionId)
confirmIndexedSession env conversationId sidText =
  case parseId sidText of
    Left _ -> pure Nothing
    Right sid -> do
      rowE <- runKioku env (Session.getById shikigamiMemorySpace sid)
      pure case rowE of
        Right (Right (Just row))
          | isRunningConversationSession conversationId row -> Just sid
        _ -> Nothing

-- | The pre-index resolution path, kept as the repair arm behind an index miss.
scanForConversationSession :: ConversationEnv -> AgentDecl -> Text -> IO (Either Text SessionId)
scanForConversationSession env decl conversationId = do
  let scope = agentScope (name decl)
  rowsE <- runKioku env (Session.getByScope shikigamiMemorySpace scope)
  case rowsE of
    Left err -> pure (Left (Text.pack (show err)))
    Right (Left err) -> pure (Left (Text.pack (show err)))
    Right (Right rows) ->
      case find (isRunningConversationSession conversationId) rows of
        Just (SessionRow {sessionId = sidText}) ->
          case parseId sidText of
            Left err -> pure (Left ("parse session id: " <> err))
            Right sid -> fmap (const sid) <$> rememberSession env conversationId sid
        Nothing -> startSession env decl conversationId

-- | Point the index at this conversation's session.
--
-- The failure is propagated rather than swallowed. An upsert has no domain
-- refusal layer, so the only way it fails is that the store was unreachable —
-- and 'resolveSession' runs inside the @resolve-session@ journaled step, so
-- surfacing it retries the turn, which re-runs the scan and re-attempts the
-- write. Discarding it would leave the conversation permanently on the scan
-- path with nothing anywhere saying so.
rememberSession :: ConversationEnv -> Text -> SessionId -> IO (Either Text ())
rememberSession env conversationId sid = do
  now <- getCurrentTime
  result <- runKioku env (SessionIndex.rememberConversationSession conversationId (idText sid) now)
  pure (first (\err -> "index conversation session: " <> Text.pack (show err)) result)

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
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor (name decl),
            ownerPrincipal = Nothing,
            agentId = name decl,
            focus = "conversation",
            scope = agentScope (name decl),
            subjectRef = Just conversationId,
            previousSessionId = Nothing,
            parentSessionId = Nothing,
            delegationDepth = 0,
            startedAt = now
          }
  case result of
    Left err -> pure (Left (Text.pack (show err)))
    Right (Left err) -> pure (Left (Text.pack (show err)))
    -- The index write follows the session it points at, so a crash between the
    -- two leaves a pointer-less session rather than a pointer to nothing. That
    -- is the direction 'scanForConversationSession' can repair.
    Right (Right _) -> fmap (const sid) <$> rememberSession env conversationId sid

loadTurns :: ConversationEnv -> SessionId -> IO [TurnRow]
loadTurns env sid = do
  result <- runKioku env (Session.getTurns shikigamiMemorySpace sid)
  pure case result of
    Right (Right turns) -> turns
    _ -> []

recordTurnOnce :: ConversationEnv -> AgentDecl -> SessionId -> Text -> Maybe Int -> Text -> Text -> [TurnRow] -> IO RecordedTurn
recordTurnOnce env decl sid turnId desiredIndex role content turns =
  case find (\TurnRow {turnId = existingTurnId} -> existingTurnId == turnId) turns of
    Just TurnRow {turnIndex} -> pure RecordedTurn {turnId, turnIndex}
    Nothing -> do
      let turnIndex = fromMaybe (length turns) desiredIndex
      requireRight =<< recordTurn env decl sid turnId turnIndex role content
      pure RecordedTurn {turnId, turnIndex}

recordAssistantTurnAndEnqueueReply ::
  (IOE :> es, Store :> es, KirokuStoreResource :> es, Error StoreError :> es) =>
  GrantSource ->
  AgentDecl ->
  SessionId ->
  AddressedMessage ->
  Text ->
  Int ->
  [TurnRow] ->
  Eff es (Either Text (RecordedTurn, SinkResult))
recordAssistantTurnAndEnqueueReply grantSource decl sid msg@AddressedMessage {messageId = msgMessageId} replyText userTurnIndex turns =
  case find (\TurnRow {turnId = existingTurnId} -> existingTurnId == turnId) turns of
    Just TurnRow {turnIndex = existingTurnIndex} -> do
      now <- liftIO getCurrentTime
      prepared <- liftIO (prepareConversationReplySinkIntent grantSource decl sid msg replyText now)
      pure (Right (RecordedTurn {turnId, turnIndex = existingTurnIndex}, AgentWorkflow.preparedSinkResult prepared))
    Nothing -> do
      now <- liftIO getCurrentTime
      prepared <- liftIO (prepareConversationReplySinkIntent grantSource decl sid msg replyText now)
      existing <- Session.getById shikigamiMemorySpace sid
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
                  memorySpaceId = shikigamiMemorySpace,
                  actorPrincipal = agentActor (name decl),
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
  GrantSource ->
  AgentDecl ->
  SessionId ->
  AddressedMessage ->
  Text ->
  UTCTime ->
  IO AgentWorkflow.PreparedSinkIntent
prepareConversationReplySinkIntent grantSource decl sid msg@AddressedMessage {conversationId = msgConversationId, messageId = msgMessageId} replyText now =
  AgentWorkflow.prepareSinkIntent
    grantSource
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
    -- No resolved recipient: a conversation reply is a danwa sink, which has no
    -- recipientFrom strategy, and the turn was triggered by an addressed message
    -- rather than by an activity envelope.
    Nothing
    Agent.DanwaConversation {Agent.topic = "danwa-conversation"}
    (Aeson.object ["reply" Aeson..= replyText])
    now

recordTurn :: ConversationEnv -> AgentDecl -> SessionId -> Text -> Int -> Text -> Text -> IO (Either Text ())
recordTurn env decl sid turnId turnIndex role content = do
  now <- getCurrentTime
  result <-
    runKioku env $
      Session.recordTurn
        RecordTurnData
          { sessionId = sid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor (name decl),
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
